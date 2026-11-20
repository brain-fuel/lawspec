#!/usr/bin/env bash
# Build the host-effect core (docs/reference/host-effects.md): the plain WASI
# reactor that every host loads: the npm package's CLI ships it as
# npm/host-core.wasm (ignored by git, recorded in npm/build.json as hostCore),
# and tools/hosts.sh copies it into the Go module. Writes npm/host-core.wasm
# and prints its size and SHA-256. Requires wasm32-wasi-ghc and wasm32-wasi-cabal (ghc-wasm-meta).
set -euo pipefail
cd "$(dirname "$0")/.."
# lawspec.cabal is written from package.yaml (hpack) and not kept in Git;
# a dry-run build writes it without compiling.
stack --no-terminal build --dry-run >/dev/null
unset GHC_PACKAGE_PATH
if [ -f "$HOME/.ghc-wasm/env" ]; then source "$HOME/.ghc-wasm/env"; fi
command -v wasm32-wasi-cabal >/dev/null
(cd wasm && wasm32-wasi-cabal build lawspec-host-core)
core_file="$(cd wasm && wasm32-wasi-cabal list-bin lawspec-host-core)"
cp "$core_file" npm/host-core.wasm
wc -c < npm/host-core.wasm | tr -d ' ' | sed 's/$/ bytes/'
shasum -a 256 npm/host-core.wasm
