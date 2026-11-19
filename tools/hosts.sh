#!/usr/bin/env bash
# Host checks for the host-effect ABI (docs/reference/host-effects.md):
#   conformance  the core's conformance suite over the native interpreter,
#                the Node Worker host and the Go host, after the Go host's
#                vet and unit tests; standard input is /dev/null, which the
#                suite's terminal check requires
#   parity       ported commands, byte for byte, across the legacy Node CLI,
#                lawspec-native, the Node Worker host, the Go host and the
#                JVM launcher (after jvm); lawspec-native and the Go host run
#                the Canon bundle tools/build-canon.sh builds (built first
#                unless it is), the JVM launcher its platform jar's, and the
#                Node host, like the legacy CLI, the ricestax package
#   go           only build the Go host (below) and print its CLI's path
#   jvm          stage lawspec-native for this platform, build the JVM
#                packages (hosts/jvm) with their launcher tests, install
#                them into .artifacts/jvm/repository and lay the launcher out
#                with its platform and resources jars in .artifacts/host-jvm,
#                as java -jar finds them
#   jvm-maven    after jvm: the sample Maven project (hosts/jvm/samples/
#                maven-java) through mvn verify: generate, compile, its
#                generated tests, lawspec check and lawspec test
#   jvm-gradle   after jvm: the Gradle plugin's build with its TestKit
#                functional tests, published to that repository, then the
#                sample Gradle project (samples/gradle-kotlin) through
#                gradle check
# The JVM steps read Maven's and Gradle's caches but install only into
# .artifacts/jvm/repository (Maven 3.9's maven.repo.local.tail keeps
# ~/.m2/repository read-only); no daemon outlives them.
# Builds the host-effect core first (tools/wasm-host-core.sh) and the Go
# host's commands into .artifacts/host-go. The Go host runs that core through
# LAWSPEC_HOST_CORE; a release downloads its pinned one instead
# (ref:DEC-go-core-download).
# Expects the stack build step to have built lawspec-native.
# ref:DEC-host-effect-abi
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
jvm_repository="$root/.artifacts/jvm/repository"
jvm_bin="$root/.artifacts/host-jvm"
jvm_version="$(sed -n 's/^version: //p' package.yaml)-SNAPSHOT"
# Every Maven or Gradle run of the JVM steps, the nested ones lawspec starts
# included, uses the repository the JVM packages are installed into.
jvm_environment()
{
  export MAVEN_ARGS="-B -Dmaven.repo.local=$jvm_repository -Dmaven.repo.local.tail=$HOME/.m2/repository"
  export ORG_GRADLE_PROJECT_lawspecRepository="$jvm_repository"
}
gradle_command()
{
  if [ -x .tools/gradle-9.3.0/bin/gradle ]; then
    echo "$root/.tools/gradle-9.3.0/bin/gradle"
  else
    echo gradle
  fi
}
jvm_jar()
{
  echo "$jvm_repository/dev/goforge/$1/$jvm_version/$1-$jvm_version.jar"
}
jvm_build()
{
  (jvm_environment && hosts/jvm/stage-native.sh && mvn -f hosts/jvm install)
}
# The jars, built first when the repository lacks them (a cached jvm step
# leaves none in a fresh checkout).
jvm_ensure()
{
  local artifact
  for artifact in lawspec lawspec-resources lawspec-maven-plugin "lawspec-$(platform)"; do
    [ -f "$(jvm_jar "$artifact")" ] || { jvm_build; return; }
  done
}
jvm_layout()
{
  local artifact
  jvm_ensure
  mkdir -p "$jvm_bin"
  for artifact in lawspec lawspec-resources "lawspec-$(platform)"; do
    cp -f "$(jvm_jar "$artifact")" "$jvm_bin/"
  done
}
platform()
{
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo darwin-arm64 ;;
    Darwin-x86_64) echo darwin-x64 ;;
    Linux-aarch64) echo linux-arm64 ;;
    Linux-x86_64) echo linux-x64 ;;
    *) echo "hosts: no JVM platform jar for $(uname -s) $(uname -m)" >&2; exit 1 ;;
  esac
}
case "${1:-}" in
  jvm)
    jvm_build
    jvm_layout
    echo "$jvm_bin/lawspec-$jvm_version.jar"
    exit 0
    ;;
  jvm-maven)
    jvm_ensure
    jvm_environment
    (cd hosts/jvm/samples/maven-java && rm -rf target .lawspec && mvn verify)
    exit 0
    ;;
  jvm-gradle)
    jvm_ensure
    jvm_environment
    gradle="$(gradle_command)"
    export PATH="$(dirname "$gradle"):$PATH"
    (cd hosts/jvm/gradle-plugin && "$gradle" --console=plain --no-daemon build publishAllPublicationsToLawspecLocalRepository)
    (cd hosts/jvm/samples/gradle-kotlin && git clean -qfdX . && "$gradle" --console=plain --no-daemon check)
    exit 0
    ;;
esac
./tools/wasm-host-core.sh >/dev/null
core=npm/host-core.wasm
go_bin=.artifacts/host-go
mkdir -p "$go_bin"
(cd hosts/go && go build -o "../../$go_bin/" ./cmd/lawspec ./internal/cmd/conformance)
case "${1:-}" in
  conformance)
    (cd hosts/go && go vet ./... && go test ./...)
    native="$(stack --no-terminal path --local-install-root)/bin/lawspec-native"
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    mkdir "$scratch/native" "$scratch/node" "$scratch/go"
    echo "native interpreter:"
    "$native" --host-conformance "$scratch/native" </dev/null
    echo "Node Worker host:"
    LAWSPEC_HOST_CORE="$core" NODE_NO_WARNINGS=1 node hosts/node/conformance.mjs "$scratch/node" </dev/null
    echo "Go host:"
    LAWSPEC_HOST_CORE="$core" "$go_bin/conformance" "$scratch/go" </dev/null
    ;;
  parity)
    native="$(stack --no-terminal path --local-install-root)/bin/lawspec-native"
    shift
    jvm_layout
    canon="$(tools/build-canon.sh --print)"
    node tools/host-parity.mjs --native "$native" --core "$core" --go "$go_bin/lawspec" --jvm "$jvm_bin/lawspec-$jvm_version.jar" --canon "$canon" "$@"
    ;;
  go)
    echo "$go_bin/lawspec"
    ;;
  *)
    echo "usage: tools/hosts.sh conformance|parity|go|jvm|jvm-maven|jvm-gradle" >&2
    exit 2
    ;;
esac
