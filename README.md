# Arweave Byte Pricing Device

Standalone HyperBEAM Forge package for `arweave-byte-pricing@1.11`.

Prices Arweave bundled bytes in AO base units for p4@1.0.

It opens/closes metering@1.0 sessions, reads arweave-bytes usage, supports fixed byte prices for tests/operators, applies an optional bundler premium, preserves the byte-limit free tier, and can dynamically convert Arweave gateway prices through simple-oracle@1.0 AR/AO USD quotes.

## Compatibility

- HyperBEAM pin: `ad415bdaaf887fb76c0a8b4f54d91fab3f9fccd8`
- Device name: `arweave-byte-pricing@1.11`

## Build

```sh
rebar3 compile
rebar3 device package
rebar3 device verify
```

## Test

```sh
ORACLE_DEVICE_SRC=/path/to/simple-oracle-device/src scripts/pre-push-test.sh
```

The oracle source is a test dependency; the default path is the sibling
`../simple-oracle-device/src`. Validation used upstream commit
`bdd44b41630b38feedbff34559483e86e1dd21a0`.

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
