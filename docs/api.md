# API

## `estimate/3`

Starts a `metering@1.0` session and, when the p4 request wraps a bundler upload,
estimates the ANS-104 serialized byte size of the uploaded item.

## `price/3`

Closes the metering session and prices consumed `arweave-bytes`.

## `quote/3`

Prices an explicit `arweave-bytes` resource amount:

```erlang
#{<<"path">> => <<"quote">>, <<"resource">> => <<"arweave-bytes">>, <<"amount">> => Bytes}
```

Configuration keys:

- `arweave-byte-price`: integer fixed price per byte, or `dynamic`.
- `bundler-premium` / `bundler_premium`: percentage added after the base quote.
- `bundler-free-byte-limit` / `bundler_free_byte_limit`: bytes at or below this value quote as `0`; `0` disables it.
- `oracle-device`: defaults to `simple-oracle@1.0`.
- `metering-device`: defaults to `metering@1.0`.
