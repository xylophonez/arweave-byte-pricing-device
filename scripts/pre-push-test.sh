#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REBAR_BASE_DIR:-$ROOT/_build}"
cd "$ROOT"
ORACLE_DEVICE_SRC="${ORACLE_DEVICE_SRC:-$ROOT/../simple-oracle-device/src}"
if [[ ! -f "$ORACLE_DEVICE_SRC/dev_simple_oracle.erl" ]]; then
    echo "Set ORACLE_DEVICE_SRC to a checkout of simple-oracle-device/src." >&2
    exit 1
fi

echo "==> compile"
rebar3 compile

echo "==> forge device tests with HyperBEAM core devices"
rebar3 device test \
    --with-core \
    --device-src "src,$ORACLE_DEVICE_SRC" \
    --devices "dev_arweave_byte_pricing,dev_simple_oracle" \
    --module "dev_arweave_byte_pricing,arweave-byte-pricing@1.11"

echo "==> package and verify"
rm -rf "$BUILD_DIR/device-packages"
rebar3 device package
rebar3 device verify

echo "==> pre-push checks passed"
