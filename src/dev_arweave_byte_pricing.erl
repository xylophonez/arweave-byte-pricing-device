%%% @doc P4 pricing adapter for Arweave byte costs in AO base units.
%%%
%%% This device keeps `metering@1.0' generic. It opens/closes the canonical
%%% metering session, reads the consumed `arweave-bytes' count using a unit
%%% metering rate, and converts the Arweave gateway `/price' result into AO
%%% base units using `simple-oracle@1.0' AR and AO USD prices.
-module(dev_arweave_byte_pricing).
-implements(<<"arweave-byte-pricing@1.11">>).
-export([device_info/0, info/1, estimate/3, price/3, quote/3]).

-include_lib("hb/include/hb.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(ORACLE_SCALE, 1_000_000_000).
-define(BEAM_REDUCTIONS, <<"beam-reductions">>).

%% @doc Device API information.
device_info() ->
    #{ exports => [<<"estimate">>, <<"price">>, <<"quote">>] }.

%% @doc Legacy metadata entry point for existing Erlang callers.
info(_) -> device_info().

%% @doc Open metering and estimate the cost of a bundler upload if possible.
estimate(Base, Req, Opts) ->
    case hb_ao:resolve(metering_msg(Base, Opts), Req#{ <<"path">> => <<"estimate">> }, Opts) of
        {ok, _} ->
            case bundler_upload_subject(Req, Opts) of
                {ok, Item} ->
                    quote_bundled_item(Item, Base, Opts);
                false ->
                    {ok, 0}
            end;
        Error ->
            Error
    end.

%% @doc Close metering and dynamically price consumed Arweave bytes.
price(Base, Req, Opts) ->
    UnitOpts =
        Opts#{
            <<"metering-rates">> => #{
                <<"arweave-bytes">> => 1,
                ?BEAM_REDUCTIONS => 0
            }
        },
    case hb_ao:resolve(
        metering_msg(Base, Opts),
        Req#{ <<"path">> => <<"price">> },
        UnitOpts
    ) of
        {ok, Amount} ->
            quote_amount(Amount, Base, Opts);
        Error ->
            Error
    end.

%% @doc Price an explicit `arweave-bytes' resource amount.
quote(Base, Req, Opts) ->
    Resource = hb_ao:normalize_key(hb_maps:get(<<"resource">>, Req, <<>>, Opts)),
    case Resource of
        <<"arweave-bytes">> ->
            Amount = hb_util:int(hb_maps:get(<<"amount">>, Req, 0, Opts)),
            quote_amount(Amount, Base, Opts);
        _ ->
            {error, {unsupported_resource, Resource}}
    end.

%% @doc Return the configured metering device message.
metering_msg(Base, Opts) ->
    Device0 =
        hb_maps:get(
            <<"metering-device">>,
            Base,
            hb_opts:get(
                arweave_byte_pricing_metering_device,
                <<"metering@1.0">>,
                Opts
            ),
            Opts
        ),
    Device = named_device_ref(Device0, Opts),
    #{ <<"device">> => Device }.

%% @doc Extract a bundler upload subject from a P4 pricing request.
bundler_upload_subject(Req, Opts) ->
    Request = pricing_request(Req, Opts),
    case is_bundler_upload(Request, Opts) of
        true ->
            {ok, bundler_subject(Request, Opts)};
        false ->
            false
    end.

pricing_request(Req, Opts) ->
    hb_ao:get(
        <<"request">>,
        Req,
        undefined,
        Opts#{ <<"hashpath">> => ignore }
    ).

%% @doc Return whether a request targets the bundler upload route.
is_bundler_upload(Req, Opts) when is_map(Req) ->
    Path = path_without_query(hb_maps:get(<<"path">>, Req, <<>>, Opts)),
    lists:member(
        Path,
        [
            <<"/~bundler@1.0/tx">>,
            <<"~bundler@1.0/tx">>,
            <<"/~bundler@1.0/item">>,
            <<"~bundler@1.0/item">>
        ]
    );
is_bundler_upload(_, _) ->
    false.

%% @doc Remove query parameters from a path.
path_without_query(Path) when is_binary(Path) ->
    case binary:split(Path, <<"?">>) of
        [CleanPath, _Query] -> CleanPath;
        [CleanPath] -> CleanPath
    end;
path_without_query(Path) ->
    Path.

%% @doc Resolve the message being uploaded to the bundler.
bundler_subject(Req, Opts) ->
    case hb_maps:find(<<"bundler-subject">>, Req, Opts) of
        {ok, SubjectKey} -> hb_maps:get(SubjectKey, Req, Req, Opts);
        error -> Req
    end.

%% @doc Estimate a bundled item's byte cost.
quote_bundled_item(Item, Base, Opts) ->
    try quote_amount(bundled_item_size(Item, Opts), Base, Opts)
    catch
        Class:Reason:Stack ->
            ?event(
                debug_pricing,
                {bundled_item_estimate_failed, Class, Reason, {trace, Stack}},
                Opts
            ),
            {error, #{
                <<"status">> => 503,
                <<"body">> => <<"Unable to quote this upload. Retry when pricing is available.">>
            }}
    end.

%% @doc Return the ANS-104 serialized size of a bundled item.
bundled_item_size(Item, Opts) ->
    TX =
        hb_message:convert(
            Item,
            #{ <<"device">> => <<"ans104@1.0">>, <<"bundle">> => true },
            <<"structured@1.0">>,
            Opts
        ),
    byte_size(ar_bundles:serialize(TX)).

%% @doc Price an Arweave byte amount in AO base units.
quote_amount(Amount, _Base, _Opts) when Amount =< 0 ->
    {ok, 0};
quote_amount(Amount, Base, Opts) ->
    case free_bundler_quote(Amount, Base, Opts) of
        true ->
            {ok, 0};
        false ->
            Quote =
                case fixed_byte_price(Base, Opts) of
                    {ok, Rate} ->
                        {ok, Amount * Rate};
                    error ->
                        dynamic_quote_amount(Amount, Base, Opts)
                end,
            apply_bundler_premium(Quote, Base, Opts)
    end.

%% @doc Return true when an amount is inside the configured free bundle tier.
free_bundler_quote(Amount, Base, Opts) ->
    Limit = bundler_free_byte_limit(Base, Opts),
    Limit > 0 andalso Amount =< Limit.

%% @doc Apply the configured operator premium percentage to a base quote.
apply_bundler_premium({ok, Quote}, Base, Opts) ->
    {ok, add_premium(Quote, bundler_premium_percent(Base, Opts))};
apply_bundler_premium(Error, _Base, _Opts) ->
    Error.

add_premium(Quote, PremiumPercent) when Quote =< 0; PremiumPercent =< 0 ->
    Quote;
add_premium(Quote, PremiumPercent) ->
    PremiumBps = round(PremiumPercent * 100),
    div_ceil(Quote * (10000 + PremiumBps), 10000).

%% @doc Read a percentage premium. Prefer repo-style hyphenated JSON, but accept
%% the underscore spelling used in meeting notes and shell-style opts.
bundler_premium_percent(Base, Opts) ->
    Raw =
        first_configured(
            [
                {base, <<"bundler-premium">>},
                {base, <<"bundler_premium">>},
                {opts, <<"bundler-premium">>},
                {opts, <<"bundler_premium">>},
                {opts, bundler_premium}
            ],
            Base,
            Opts
        ),
    try max(0.0, hb_util:float(Raw))
    catch _:_ -> 0.0
    end.

%% @doc Read the maximum bundled byte amount that is free to upload. Prefer the
%% profile-style hyphenated key, while accepting the underscore spelling used by
%% notes and shell-style opts.
bundler_free_byte_limit(Base, Opts) ->
    Raw =
        first_configured(
            [
                {base, <<"bundler-free-byte-limit">>},
                {base, <<"bundler_free_byte_limit">>},
                {opts, <<"bundler-free-byte-limit">>},
                {opts, <<"bundler_free_byte_limit">>},
                {opts, bundler_free_byte_limit}
            ],
            Base,
            Opts
        ),
    try max(0, hb_util:int(Raw))
    catch _:_ -> 0
    end.

first_configured([{base, Key} | Rest], Base, Opts) ->
    case hb_maps:get(Key, Base, not_found, Opts) of
        not_found -> first_configured(Rest, Base, Opts);
        Value -> Value
    end;
first_configured([{opts, Key} | Rest], Base, Opts) ->
    case hb_opts:get(Key, not_found, Opts) of
        not_found -> first_configured(Rest, Base, Opts);
        Value -> Value
    end;
first_configured([], _Base, _Opts) ->
    0.

%% @doc Return an explicit test/operator byte price if configured.
fixed_byte_price(Base, Opts) ->
    Price =
        hb_maps:get(
            <<"arweave-byte-price">>,
            Base,
            hb_opts:get(<<"arweave-byte-price">>, dynamic, Opts),
            Opts
        ),
    try {ok, hb_util:int(Price)}
    catch _:_ -> error
    end.

%% @doc Price an Arweave byte amount using live gateway and oracle data.
dynamic_quote_amount(Amount, Base, Opts) ->
    {ok, ARWinstons} =
        hb_ao:resolve(
            #{ <<"device">> => <<"arweave@2.9">> },
            #{ <<"path">> => <<"/price">>, <<"size">> => Amount },
            Opts
        ),
    {ok, ARPrice} = oracle_price(<<"AR">>, Base, Opts),
    {ok, AOPrice} = oracle_price(<<"AO">>, Base, Opts),
    {ok,
        div_ceil(
            ARWinstons * scaled_price(ARPrice),
            scaled_price(AOPrice)
        )
    }.

%% @doc Resolve a ticker price through the configured oracle device.
oracle_price(Ticker, Base, Opts) ->
    OracleDevice0 =
        hb_maps:get(
            <<"oracle-device">>,
            Base,
            hb_opts:get(
                arweave_byte_pricing_oracle_device,
                <<"simple-oracle@1.0">>,
                Opts
            ),
            Opts
        ),
    OracleDevice = named_device_ref(OracleDevice0, Opts),
    hb_ao:resolve(
        #{ <<"device">> => OracleDevice },
        #{ <<"path">> => <<"price-now">>, <<"ticker">> => Ticker },
        Opts
    ).

named_device_ref(Name, Opts) ->
    named_device_ref_1(Name, list_opt(<<"name-resolvers">>, Opts), Opts).

named_device_ref_1(Name, [Resolver | Rest], Opts) when is_map(Resolver) ->
    case hb_maps:get(Name, Resolver, not_found, Opts) of
        not_found -> named_device_ref_1(Name, Rest, Opts);
        Ref -> Ref
    end;
named_device_ref_1(Name, [_ | Rest], Opts) ->
    named_device_ref_1(Name, Rest, Opts);
named_device_ref_1(Name, [], _Opts) ->
    Name.

list_opt(Key, Msg) ->
    case hb_maps:get(Key, Msg, [], Msg) of
        Value when is_list(Value) -> Value;
        Value when is_map(Value) ->
            case hb_util:is_ordered_list(Value, Msg) of
                true -> hb_util:message_to_ordered_list(Value, Msg);
                false -> []
            end;
        _ -> []
    end.

%% @doc Convert a decimal price to a fixed-point integer.
scaled_price(Price) ->
    max(1, round(hb_util:float(Price) * ?ORACLE_SCALE)).

%% @doc Integer ceiling division.
div_ceil(Numerator, Denominator) ->
    (Numerator + Denominator - 1) div Denominator.

-ifdef(TEST).

%%% Tests

%% @doc A configured byte price bypasses gateway and oracle lookups.
fixed_byte_price_quote_test() ->
    {ok, 35} =
        quote(
            #{},
            #{
                <<"path">> => <<"quote">>,
                <<"resource">> => <<"arweave-bytes">>,
                <<"amount">> => 5
            },
            #{
                <<"store">> => hb_test_utils:test_store(),
                <<"arweave-byte-price">> => 7
            }
        ).

%% @doc A configured premium percentage is applied to fixed byte prices.
fixed_byte_price_premium_quote_test() ->
    {ok, 39} =
        quote(
            #{},
            #{
                <<"path">> => <<"quote">>,
                <<"resource">> => <<"arweave-bytes">>,
                <<"amount">> => 5
            },
            #{
                <<"store">> => hb_test_utils:test_store(),
                <<"arweave-byte-price">> => 7,
                <<"bundler-premium">> => 10
            }
        ).

%% @doc Amounts inside the configured free tier bypass price and premium.
fixed_byte_price_free_byte_limit_quote_test() ->
    {ok, 0} =
        quote(
            #{},
            #{
                <<"path">> => <<"quote">>,
                <<"resource">> => <<"arweave-bytes">>,
                <<"amount">> => 102400
            },
            #{
                <<"store">> => hb_test_utils:test_store(),
                <<"arweave-byte-price">> => 1,
                <<"bundler-premium">> => 100,
                <<"bundler-free-byte-limit">> => 102400
            }
        ).

%% @doc Amounts above the free tier fall through to normal priced quotes.
fixed_byte_price_free_byte_limit_overage_quote_test() ->
    {ok, 204802} =
        quote(
            #{},
            #{
                <<"path">> => <<"quote">>,
                <<"resource">> => <<"arweave-bytes">>,
                <<"amount">> => 102401
            },
            #{
                <<"store">> => hb_test_utils:test_store(),
                <<"arweave-byte-price">> => 1,
                <<"bundler-premium">> => 100,
                <<"bundler-free-byte-limit">> => 102400
            }
        ).

%% @doc The underscore spelling is accepted as an alias for profile drafts.
fixed_byte_price_underscore_free_byte_limit_quote_test() ->
    {ok, 0} =
        quote(
            #{},
            #{
                <<"path">> => <<"quote">>,
                <<"resource">> => <<"arweave-bytes">>,
                <<"amount">> => 5
            },
            #{
                <<"store">> => hb_test_utils:test_store(),
                <<"arweave-byte-price">> => 7,
                <<"bundler_free_byte_limit">> => 5
            }
        ).

%% @doc The underscore spelling is accepted as an alias for profile drafts.
fixed_byte_price_underscore_premium_quote_test() ->
    {ok, 44} =
        quote(
            #{},
            #{
                <<"path">> => <<"quote">>,
                <<"resource">> => <<"arweave-bytes">>,
                <<"amount">> => 5
            },
            #{
                <<"store">> => hb_test_utils:test_store(),
                <<"arweave-byte-price">> => 7,
                <<"bundler_premium">> => 25
            }
        ).

add_premium_rounds_up_test() ->
    ?assertEqual(39, add_premium(35, 10.0)),
    ?assertEqual(44, add_premium(35, 25.0)),
    ?assertEqual(35, add_premium(35, 0.0)),
    ?assertEqual(35, add_premium(35, -10.0)).

%% @doc Dynamic quotes combine Arweave gateway price and oracle AR/AO prices.
dynamic_quote_test() ->
    {GatewayHandle, GatewayOpts} =
        hb_mock_server:start_arweave_gateway(#{ price => {200, <<"100">>} }),
    {ok, OracleURL, OracleHandle} =
        hb_mock_server:start(
            [
                {"/ar", ar, {200, <<"{\"prices\":[[1,6.0]]}">>}},
                {"/ao", ao, {200, <<"{\"prices\":[[1,3.0]]}">>}}
            ]
    ),
    try
        {ok, 200} =
            quote(
                #{},
                #{
                    <<"path">> => <<"quote">>,
                    <<"resource">> => <<"arweave-bytes">>,
                    <<"amount">> => 123
                },
                oracle_opts(GatewayOpts, OracleURL)
            ),
        ?assertEqual(
            1,
            length(hb_mock_server:get_requests(price, 1, GatewayHandle))
        )
    after
        hb_mock_server:stop(OracleHandle),
        hb_mock_server:stop(GatewayHandle)
    end.

%% @doc The adapter reads canonical metering and then applies dynamic pricing.
metered_price_test() ->
    {GatewayHandle, GatewayOpts} =
        hb_mock_server:start_arweave_gateway(#{ price => {200, <<"100">>} }),
    {ok, OracleURL, OracleHandle} =
        hb_mock_server:start(
            [
                {"/ar", ar, {200, <<"{\"prices\":[[1,6.0]]}">>}},
                {"/ao", ao, {200, <<"{\"prices\":[[1,3.0]]}">>}}
            ]
        ),
    try
        Pricing = #{ <<"device">> => <<"arweave-byte-pricing@1.11">> },
        Opts = oracle_opts(GatewayOpts, OracleURL),
        {ok, 0} =
            hb_ao:resolve(Pricing, #{ <<"path">> => <<"estimate">> }, Opts),
        ok = metering_consume(<<"arweave-bytes">>, 123, Opts),
        {ok, 200} =
            hb_ao:resolve(Pricing, #{ <<"path">> => <<"price">> }, Opts),
        ?assertEqual(
            1,
            length(hb_mock_server:get_requests(price, 1, GatewayHandle))
        )
    after
        hb_mock_server:stop(OracleHandle),
        hb_mock_server:stop(GatewayHandle)
    end.

%% @doc P4 rejects unfunded raw ANS-104 uploads before the bundler runs.
unfunded_raw_bundler_upload_rejected_test() ->
    HostWallet = ar_wallet:new(),
    UploaderWallet = ar_wallet:new(),
    {ServerHandle, GatewayOpts} =
        hb_mock_server:start_arweave_gateway(
            #{
                price => {200, <<"12345">>},
                tx_anchor => {200, hb_util:encode(rand:bytes(32))}
            }
        ),
    Processor =
        #{
            <<"device">> => <<"p4@1.0">>,
            <<"ledger-device">> => <<"simple-pay@1.0">>,
            <<"pricing-device">> => <<"arweave-byte-pricing@1.11">>
        },
    Opts =
        GatewayOpts#{
            <<"priv-wallet">> => HostWallet,
            <<"store">> => hb_test_utils:test_store(),
            <<"bundler-max-items">> => 1,
            <<"arweave-byte-price">> => 2,
            <<"metering-rates">> => #{ ?BEAM_REDUCTIONS => 0 },
            <<"operator">> => ar_wallet:to_address(HostWallet),
            <<"on">> => #{
                <<"request">> => Processor,
                <<"response">> => Processor
            }
        },
    try
        Node = hb_http_server:start_node(Opts),
        RawItem =
            ar_bundles:serialize(
                ar_bundles:sign_item(
                    #tx{
                        data = <<"unfunded-raw-bundler-upload">>,
                        tags = [{<<"content-type">>, <<"text/plain">>}]
                    },
                    UploaderWallet
                )
            ),
        BaseURL = base_url(Node),
        URL =
            binary_to_list(
                <<BaseURL/binary, "/~bundler@1.0/item?codec-device=ans104@1.0">>
            ),
        {ok, {{_, Status, _}, _Headers, _Body}} =
            httpc:request(
                post,
                {
                    URL,
                    [{"content-type", "application/octet-stream"}],
                    "application/octet-stream",
                    RawItem
                },
                [],
                [{body_format, binary}]
            ),
        ?assertEqual(402, Status),
        ?assertEqual(
            0,
            length(hb_mock_server:get_requests(tx, 0, ServerHandle, 200))
        ),
        ?assertEqual(
            0,
            length(hb_mock_server:get_requests(chunk, 0, ServerHandle, 200))
        )
    after
        hb_mock_server:stop(ServerHandle),
        ok
    end.

metering_consume(Resource, Amount, Opts) ->
    {ok, Metering} = hb_device_load:reference(<<"metering@1.0">>, Opts),
    Metering:consume(Resource, Amount, Opts).

oracle_opts(GatewayOpts, OracleURL) ->
    GatewayOpts#{
        <<"store">> => hb_test_utils:test_store(),
        <<"oracle-sources">> => #{
            <<"AR">> => [
                #{
                    <<"shape">> => <<"coingecko-market-chart">>,
                    <<"url">> => <<OracleURL/binary, "/ar">>
                }
            ],
            <<"AO">> => [
                #{
                    <<"shape">> => <<"coingecko-market-chart">>,
                    <<"url">> => <<OracleURL/binary, "/ao">>
                }
            ]
        },
        <<"oracle-cache-ttl-ms">> => 0,
        <<"relay-http-client">> => httpc,
        <<"relay-block-internal">> => false,
        <<"metering-rates">> => #{ ?BEAM_REDUCTIONS => 0 }
    }.

base_url(Node) ->
    case binary:last(Node) of
        $/ -> binary:part(Node, 0, byte_size(Node) - 1);
        _ -> Node
    end.


%% @doc Unavailable native Arweave pricing cannot admit a free paid upload.
unavailable_gateway_estimate_fails_closed_test() ->
    Store = hb_test_utils:test_store(hb_store_fs, <<"pricing-outage">>),
    Opts = #{
        <<"store">> => [Store],
        <<"priv-store">> => [Store],
        <<"priv-wallet">> => ar_wallet:new(),
        <<"arweave-byte-price">> => <<"dynamic">>,
        <<"http-timeout">> => 1000,
        <<"http-connect-timeout">> => 1000,
        <<"routes">> => [#{
            <<"template">> => <<"^/arweave">>,
            <<"node">> => #{
                <<"match">> => <<"^/arweave">>,
                <<"with">> => <<"http://127.0.0.1:1">>,
                <<"opts">> => #{<<"http-client">> => httpc, <<"protocol">> => http2}
            }
        }]
    },
    ?assertMatch({error, _}, hb_ao:resolve(
        #{<<"device">> => <<"arweave@2.9">>},
        #{<<"path">> => <<"price">>, <<"size">> => 100}, Opts)),
    Item = hb_message:commit(
        #{<<"data">> => <<"synthetic-price-outage">>}, Opts, <<"ans104@1.0">>),
    Request = #{
        <<"path">> => <<"/~bundler@1.0/tx">>,
        <<"bundler-subject">> => <<"body">>,
        <<"body">> => Item
    },
    ?assertMatch({error, #{<<"status">> := 503}}, hb_ao:resolve(
        #{<<"device">> => <<"arweave-byte-pricing@1.11">>},
        #{<<"path">> => <<"estimate">>, <<"request">> => Request,
            <<"body">> => [Request]}, Opts)).

-endif.
