#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/embed-runtimes.py
if [ -n "${LAWSPEC_CORE:-}" ]; then
  "$LAWSPEC_CORE" --generate-api
else
  stack --no-terminal build
  stack --no-terminal exec lawspec-core -- --generate-api
fi
unset GHC_PACKAGE_PATH
if [ -f "$HOME/.ghc-wasm/env" ]; then source "$HOME/.ghc-wasm/env"; fi
command -v wasm32-wasi-cabal >/dev/null
(cd wasm && wasm32-wasi-cabal build lawspec-wasm)
core_file="$(cd wasm && wasm32-wasi-cabal list-bin lawspec-wasm)"
"$(wasm32-wasi-ghc --print-libdir)/post-link.mjs" --input "$core_file" --output npm/core_jsffi.js
cp "$core_file" npm/core.wasm
cp examples/specs/atoi_codec.lawspec npm/starter.lawspec
mkdir -p npm/examples/specs
cp examples/specs/*.lawspec npm/examples/specs/
cp README.md PRIMITIVES.md REFINEMENTS.md RUST.md JAVA.md PYTHON.md GO.md HASKELL.md KOTLIN.md WEB.md LANGUAGE.md API-MIGRATION.md RELEASE-0.9.md LICENSE npm/
node tools/build-integrity.mjs --record
