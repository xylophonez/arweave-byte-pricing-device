# Arweave Byte Pricing Device

Standalone HyperBEAM Forge package for `arweave-byte-pricing@1.0`.

Prices Arweave bundled bytes in AO base units for p4@1.0.

It opens/closes metering@1.0 sessions, reads arweave-bytes usage, supports fixed byte prices for tests/operators, applies an optional bundler premium, preserves the byte-limit free tier, and can dynamically convert Arweave gateway prices through simple-oracle@1.0 AR/AO USD quotes.

## Compatibility

- HyperBEAM pin: `4177b91993b2f590f4906bc9ca548724f8408875`
- Device name: `arweave-byte-pricing@1.0`

## Build

```sh
rebar3 compile
rebar3 device package
rebar3 device verify
```

## Test

```sh
scripts/pre-push-test.sh
```

Install the local pre-push hook with:

```sh
scripts/install-git-hooks.sh
```

## Docs

- `docs/api.md`
- `docs/integration.md`
- `docs/generated.md`

Regenerate EDoc HTML with:

```sh
scripts/generate-docs.sh
```

## Publish

After tests pass, publish the Forge package artifacts generated under
`_build/device-packages/` with your normal ANS-104 item pipeline. Then pin the
published spec ID in your node's `name-resolvers` and trust the publisher
address in `trusted-device-signers`.
