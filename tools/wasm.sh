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
# A wasm32 address is unsigned, but reaches JavaScript as a signed 32-bit
# number: past 2 GiB of memory (lawspec examples on every bundled example)
# the text codecs would read before the buffer. Read addresses unsigned.
sed -i.bak -e 's/memory\.buffer, \$1, \$2)/memory.buffer, $1 >>> 0, $2)/' \
  -e 's/memory\.buffer, \$2, \$3)/memory.buffer, $2 >>> 0, $3)/' npm/core_jsffi.js
rm -f npm/core_jsffi.js.bak
grep -q 'memory.buffer, \$1 >>> 0' npm/core_jsffi.js
cp "$core_file" npm/core.wasm
cp examples/specs/atoi_codec.lawspec npm/starter.lawspec
rm -rf npm/examples
mkdir -p npm/examples/specs npm/examples/native-payments npm/examples/packages
cp examples/specs/*.lawspec npm/examples/specs/
cp -R examples/native-payments/. npm/examples/native-payments/
cp -R examples/packages/. npm/examples/packages/
cp LICENSE npm/
stack --no-terminal run lawspec-dev -- integrity --record
