#!/usr/bin/env bash
# Builds the native Canon that LawSpec ships with every host, from pinned
# commits, into a Canon bundle:
#   <out>/canon          the canon executable, stripped
#   <out>/canon.sha256   its SHA-256
#   <out>/presets/       Rice's Tax's grammar presets, which lawspec project
#                        init and adopt copy into .ricestax/
#   <out>/canon.json     what was built, from which commits
# Usage: tools/build-canon.sh [--platform <platform>] [--out <directory>] [--print]
#   --platform  darwin-arm64, darwin-x64, linux-arm64 or linux-x64; it must
#               be the platform this runs on (GHC does not cross-compile
#               canon, so build each platform on that platform, as for
#               lawspec-native; see hosts/jvm/stage-native.sh). The default
#               is this machine's platform.
#   --out       the bundle directory; .artifacts/canon/<platform> by default.
#   --print     print only the bundle directory on standard output (the
#               build's own output goes to standard error).
# A bundle whose canon.json already records these pins is kept as it is.
# Inputs:
#   CANON_SOURCE     a Git URL or path of the canon repository
#                    (https://github.com/brain-fuel/canon.git by default)
#   RICESTAX_SOURCE  a Git URL or path of the Rice's Tax repository
#                    (https://github.com/brain-fuel/ricestax.git by default)
#   CANON_BUILD      the scratch directory for the clones and Stack's work
#                    (.artifacts/canon-build/<platform> by default)
#   stack            on PATH; canon's own stack.yaml at the pinned commit
#                    names the snapshot (LTS 24.58, GHC 9.10).
# The pins: canon's release 0.2.3 (tag v0.2.3) and the Rice's Tax release
# built against it in lockstep, 0.4.3 (tag v0.4.3), whose npm package the
# legacy CLI runs. The executable is canon's own `canon`, the command the CANON
# variable names; the presets are byte for byte the ones the npm package
# copies. Nothing is written into either repository: each is cloned into the
# scratch directory and checked out at its pinned commit.
# ref:DEC-native-canon
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

canon_commit=441b21233d044959ff431bd0107841258bb65cd7
canon_version=0.2.3
ricestax_commit=483dbb2ebfa41231ea3df31a12762c9b4d2f1ff2
ricestax_version=0.4.3
platforms=(darwin-arm64 darwin-x64 linux-arm64 linux-x64)

host_platform()
{
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) echo "build-canon: unsupported build system $(uname -s)" >&2; exit 2 ;;
  esac
  case "$(uname -m)" in
    arm64 | aarch64) arch=arm64 ;;
    x86_64 | amd64) arch=x64 ;;
    *) echo "build-canon: unsupported architecture $(uname -m)" >&2; exit 2 ;;
  esac
  echo "$os-$arch"
}

platform="$(host_platform)"
out=""
print=false
while [ $# -gt 0 ]; do
  case "$1" in
    --platform)
      platform="${2:?--platform needs a platform}"
      shift 2
      ;;
    --out)
      out="${2:?--out needs a directory}"
      shift 2
      ;;
    --print)
      print=true
      shift
      ;;
    *)
      echo "usage: tools/build-canon.sh [--platform <platform>] [--out <directory>] [--print]" >&2
      exit 2
      ;;
  esac
done
case " ${platforms[*]} " in
  *" $platform "*) ;;
  *) echo "build-canon: unknown platform $platform (one of ${platforms[*]})" >&2; exit 2 ;;
esac
if [ "$platform" != "$(host_platform)" ]; then
  echo "build-canon: this is $(host_platform); build $platform on $platform" >&2
  exit 2
fi
out="${out:-$root/.artifacts/canon/$platform}"
build="${CANON_BUILD:-$root/.artifacts/canon-build/$platform}"
canon_source="${CANON_SOURCE:-https://github.com/brain-fuel/canon.git}"
ricestax_source="${RICESTAX_SOURCE:-https://github.com/brain-fuel/ricestax.git}"

# A clone at the pinned commit, without submodules (canon's language samples
# are submodules the build does not read). An existing clone is reused when
# it is already at that commit.
checkout()
{
  local source="$1" directory="$2" commit="$3"
  if [ -d "$directory/.git" ] && [ "$(git -C "$directory" rev-parse HEAD)" = "$commit" ]; then
    git -C "$directory" checkout --quiet -- .
  else
    rm -rf "$directory"
    git clone --quiet --no-checkout "$source" "$directory"
    git -C "$directory" -c advice.detachedHead=false checkout --quiet "$commit"
  fi
}

# What canon.json records: the pins, then the platform and the digest.
pins()
{
  echo "  \"canon\": \"$canon_version\","
  echo "  \"canonCommit\": \"$canon_commit\","
  echo "  \"ricestax\": \"$ricestax_version\","
  echo "  \"ricestaxCommit\": \"$ricestax_commit\","
  echo "  \"platform\": \"$platform\","
}
if [ -f "$out/canon.json" ] && [ -f "$out/canon" ] &&
  [ "$(sed -n '2,6p' "$out/canon.json")" = "$(pins)" ] &&
  [ "$(shasum -a 256 "$out/canon" | cut -d' ' -f1)" = "$(cat "$out/canon.sha256")" ]; then
  if $print; then echo "$out"; else echo "$platform: canon $canon_version $(cat "$out/canon.sha256") $out (already built)"; fi
  exit 0
fi
# Everything below reports on standard error under --print.
if $print; then exec 3>&1 1>&2; fi

mkdir -p "$build"
checkout "$canon_source" "$build/canon" "$canon_commit"
checkout "$ricestax_source" "$build/ricestax" "$ricestax_commit"
reported="$(sed -n 's/^version: *//p' "$build/canon/package.yaml")"
[ "$reported" = "$canon_version" ] || { echo "build-canon: canon at $canon_commit is $reported, not $canon_version" >&2; exit 1; }
reported="$(sed -n 's/^ *"version": *"\(.*\)",$/\1/p' "$build/ricestax/npm/package.json")"
[ "$reported" = "$ricestax_version" ] || { echo "build-canon: ricestax at $ricestax_commit is $reported, not $ricestax_version" >&2; exit 1; }

(cd "$build/canon" && stack --no-terminal build canon:exe:canon --copy-bins --local-bin-path "$build/bin")
binary="$build/bin/canon"
"$binary" version | grep -qx "canon $canon_version" || { echo "build-canon: $binary does not report canon $canon_version" >&2; exit 1; }

# The bundle is assembled beside its destination and renamed into place, so a
# failed build never leaves a partial one.
rm -rf "$out.tmp"
mkdir -p "$out.tmp"
cp "$binary" "$out.tmp/canon"
chmod 755 "$out.tmp/canon"
strip "$out.tmp/canon"
cp -R "$build/ricestax/npm/presets" "$out.tmp/presets"
find "$out.tmp/presets" -type d -exec chmod 755 {} +
find "$out.tmp/presets" -type f -exec chmod 644 {} +
digest="$(shasum -a 256 "$out.tmp/canon" | cut -d' ' -f1)"
echo "$digest" >"$out.tmp/canon.sha256"
{
  echo "{"
  pins
  echo "  \"sha256\": \"$digest\""
  echo "}"
} >"$out.tmp/canon.json"
rm -rf "$out"
mkdir -p "$(dirname "$out")"
mv "$out.tmp" "$out"
echo "$platform: canon $canon_version $digest $out"
if $print; then echo "$out" >&3; fi
