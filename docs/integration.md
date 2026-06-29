# Integration

Use this as a p4 pricing device for bundler upload routes. In the full LapEE
profile, `pricing-router@1.0` sends `/~bundler@1.0/tx` and
`/~bundler@1.0/item` to this device.

Minimal p4 route entry:

```erlang
#{
    <<"template">> => <<"/~bundler@1.0/item">>,
    <<"pricing-device">> => <<"arweave-byte-pricing@1.0">>
}
```
