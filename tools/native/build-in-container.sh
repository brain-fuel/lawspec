#!/usr/bin/env bash
# Runs inside the tools/native/Containerfile image: builds, from the source
# tree that arrives as a tar archive on standard input, either one
# executable of that stack project or (with --canon) LawSpec's Canon bundle
# through the tree's tools/build-canon.sh, links it fully statically,
# strips it, and leaves in /out:
#   <exe>            the stripped executable (without --canon)
#   canon/           the Canon bundle (with --canon)
#   dependencies.txt stack ls dependencies, to compare with the macOS build's
#                    (without --canon)
#   linkage.txt      file, readelf -d and ldd of the executable
#                    (canon-linkage.txt with --canon)
#   ghc.txt          ghc --version and stack --version
# tools/build-native.sh runs it; it is not meant to be run by hand.
#   build-in-container.sh --target <package:exe:name> --exe <name> [--jobs N]
#   build-in-container.sh --canon <platform> [--jobs N]
set -euo pipefail

target=""
exe=""
canon=""
jobs=2
while [ $# -gt 0 ]; do
  case "$1" in
    --target) target="${2:?--target needs a stack target}"; shift 2 ;;
    --exe) exe="${2:?--exe needs an executable name}"; shift 2 ;;
    --canon) canon="${2:?--canon needs a platform}"; shift 2 ;;
    --jobs) jobs="${2:?--jobs needs a number}"; shift 2 ;;
    *) echo "build-in-container: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$canon" ] || { [ -n "$target" ] && [ -n "$exe" ]; } || { echo "build-in-container: --target and --exe, or --canon, are required" >&2; exit 2; }

mkdir -p /build/src /out
tar -x -C /build/src
cd /build/src

{
  ghc --version
  stack --version
} >/out/ghc.txt

# Cabal's --enable-executable-static links each local executable with
# -static -optl-static: musl's static libc, libgmp.a and libffi.a make it
# self-contained. Only the executable link sees it. (--ghc-options would
# reach the local library's shared-object link too, which a static link
# cannot do; this GHC is dynamic, so Cabal builds shared libraries.)
# Dependencies build as usual. jobs bounds stack's parallel package builds,
# tools/build-canon.sh's included. The configuration is the throwaway
# container's, so it is not the image's or the project's.
printf 'jobs: %s\nconfigure-options:\n  $locals:\n  - --enable-executable-static\n' "$jobs" >>/etc/stack/config.yaml

if [ -n "$canon" ]; then
  # build-canon.sh clones canon and Rice's Tax at their pinned commits
  # (CANON_SOURCE and RICESTAX_SOURCE, passed through, or their GitHub
  # repositories) into its scratch directory.
  CANON_BUILD=/build/canon-build tools/build-canon.sh --platform "$canon" --out /out/canon
  executable=/out/canon/canon
else
  # The resolved versions, before building, so a drift shows even when the
  # build fails.
  stack --no-terminal ls dependencies >/out/dependencies.txt
  stack --no-terminal build "$target"
  binary="$(stack --no-terminal path --local-install-root)/bin/$exe"
  cp "$binary" "/out/$exe"
  strip "/out/$exe"
  executable="/out/$exe"
fi

name="$(basename "$executable")"
linkage=/out/linkage.txt
if [ -n "$canon" ]; then
  linkage=/out/canon-linkage.txt
fi
{
  echo "\$ file $name"
  file "$executable"
  echo
  echo "\$ readelf -d $name"
  readelf -d "$executable" 2>&1 || true
  echo
  echo "\$ readelf -l $name | grep -i interpreter"
  readelf -l "$executable" | grep -i interpreter || echo "(no program interpreter)"
  echo
  echo "\$ ldd $name"
  ldd "$executable" 2>&1 || true
} >"$linkage"

# A dynamic section or a program interpreter means something was left
# shared: the build is not the self-contained binary the platform jar needs.
if readelf -d "$executable" | grep -q NEEDED || readelf -l "$executable" | grep -qi interpreter; then
  echo "build-in-container: $name is not fully static:" >&2
  cat "$linkage" >&2
  exit 1
fi
echo "build-in-container: built $executable, fully static"
