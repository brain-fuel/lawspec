#!/usr/bin/env bash
# Build the npm package's compiler: generated sources, native compiler, WASM
# core and JavaScript glue, then stage the shipped files and record their
# fingerprints. Requires wasm32-wasi-ghc and wasm32-wasi-cabal (ghc-wasm-meta).
set -euo pipefail
cd "$(dirname "$0")/.."
stack --no-terminal run lawspec-dev -- generate
stack --no-terminal build
unset GHC_PACKAGE_PATH
if [ -f "$HOME/.ghc-wasm/env" ]; then source "$HOME/.ghc-wasm/env"; fi
command -v wasm32-wasi-cabal >/dev/null
(cd wasm && wasm32-wasi-cabal build lawspec-wasm)
core_file="$(cd wasm && wasm32-wasi-cabal list-bin lawspec-wasm)"
"$(wasm32-wasi-ghc --print-libdir)/post-link.mjs" --input "$core_file" --output npm/core_jsffi.js
cp "$core_file" npm/core.wasm
cp examples/specs/atoi_codec.lawspec npm/starter.lawspec
rm -rf npm/examples
mkdir -p npm/examples/specs npm/examples/native-payments npm/examples/packages
cp examples/specs/*.lawspec npm/examples/specs/
cp -R examples/native-payments/. npm/examples/native-payments/
cp -R examples/packages/. npm/examples/packages/
cp README.md CHANGELOG.md LICENSE npm/
stack --no-terminal run lawspec-dev -- integrity --record
