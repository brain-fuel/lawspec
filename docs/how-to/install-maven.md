---
id: lawspec.how-to.install-maven
kind: how-to
title: Install from Maven
---
# Install from Maven

> Platform jars are published for darwin-arm64, darwin-x64, linux-arm64 and
> linux-x64. To build the snapshot from a checkout, see
> [Build and install from a checkout](#build-and-install-from-a-checkout).

On the JVM, LawSpec is the natively compiled `lawspec`, one jar per platform,
behind a small Java launcher. The launcher holds no LawSpec logic: it picks
this platform's jar, unpacks the binary once into a cache, checks its SHA-256
against its own manifest and runs it with your arguments, working directory,
environment and terminal. Output is the same, byte for byte, as the npm
package's and the Go host's. ref:DEC-jvm-native-host

| Coordinates | What it is |
| --- | --- |
| `dev.goforge:lawspec` | The launcher (`java -jar`) and the compiler API. |
| `dev.goforge:lawspec-darwin-arm64`, `-darwin-x64`, `-linux-arm64`, `-linux-x64` | The binary for one platform. |
| `dev.goforge:lawspec-resources` | The Learn site, for `lawspec learn` only. |
| `dev.goforge:lawspec-maven-plugin` | The Maven plugin. |
| `dev.goforge:lawspec-gradle-plugin` | The Gradle plugin `dev.goforge.lawspec` ([Install the Gradle plugin](install-gradle.md)). |

Platforms: macOS and Linux on ARM64 and x86-64. The Linux binaries are
statically linked, so they run on glibc and musl distributions alike. Java 17
or later runs the launcher and the plugin; your project's targets need their
own toolchains (`lawspec doctor` lists them).

## Use the Maven plugin

```xml
<plugin>
  <groupId>dev.goforge</groupId>
  <artifactId>lawspec-maven-plugin</artifactId>
  <version>0.36.2</version>
  <executions>
    <execution>
      <goals>
        <goal>generate</goal>
        <goal>check</goal>
        <goal>test</goal>
      </goals>
    </execution>
  </executions>
</plugin>
```

`generate` runs in `generate-sources`, before the main code compiles; `check`
and `test` run in `verify`, so `mvn verify` checks the specifications and runs
`lawspec test` after the build's own tests. The plugin resolves this
platform's `dev.goforge:lawspec-<platform>` jar of its own version from your
plugin repositories.

After generating, `generate` adds the directories it generated into to the
build, as `lawspec describe --json` reports the targets: a Java target's
`:generated-source-dir` becomes a compile source root, and its
`:generated-test-dir` a test compile source root and a test resource
directory (without the `.java` files). No `build-helper-maven-plugin`
executions are needed; `lawspec doctor` accepts the `generate` goal in their
place. A target without those directories generates into `src/main` and
`src/test`, which Maven already compiles. Only the targets whose `:root` is
the project's directory count, and only the one `target` names when it is
set. To register the directories yourself, set `addSourceRoots` to `false`
(`-Dlawspec.generate.addSourceRoots=false`); to generate at another point,
give the goal an execution with its own `<phase>`.
`hosts/jvm/samples/maven-java` uses the defaults.

Every command is a goal: `check`, `generate`, `test`, `prove`, `explain`,
`doctor`, `fmt`, `mutate`, `package`, `evidence`, `advise`, `inspect`,
`prelude`, `describe`, `fetch`, `update`, `examples`, `init`, `project`,
`learn`, and `run` for any other (`mvn lawspec:run -Dlawspec.arguments=mcp`).

```sh
mvn lawspec:explain -Dlawspec.explain.view=math
mvn lawspec:prove -Dlawspec.json
```

| Parameter | Property | Passes |
| --- | --- | --- |
| `config` | `lawspec.config` | `--config <file>` (by default lawspec finds `lawspec.edn`) |
| `target` | `lawspec.target` | `--target` |
| `machineBits` | `lawspec.machineBits` | `--machine-bits` |
| `json`, `noCache`, `timings`, `locked` | `lawspec.json` … | the flag |
| `offline` | `lawspec.offline`, Maven's `-o` | `--offline` |
| `arguments` | `lawspec.arguments` | further arguments, as given |
| `environment` | | variables for lawspec |
| `workingDirectory` | `lawspec.workingDirectory` | where lawspec runs (`${project.basedir}`) |
| `skip` | `lawspec.skip` | skips every goal |

Each goal has its own flags (for example `lawspec.test.seed`,
`lawspec.generate.check`, `lawspec.fmt.check`, `lawspec.prove.solver`; `mvn
help:describe -Dplugin=dev.goforge:lawspec-maven-plugin -Ddetail` lists them)
and its own skip switch, `lawspec.<goal>.skip`. `lawspec:test` also honours
`-DskipTests` and `-Dmaven.test.skip`.

## Run the CLI with `java -jar`

Put the launcher and this platform's jar in one directory (`lawspec-resources`
too, for `lawspec learn`):

```sh
mvn dependency:copy -Dartifact=dev.goforge:lawspec:0.36.2 -DoutputDirectory=lawspec
mvn dependency:copy -Dartifact=dev.goforge:lawspec-darwin-arm64:0.36.2 -DoutputDirectory=lawspec
java -jar lawspec/lawspec-0.36.2.jar check
```

The launcher also finds the jars in the local Maven repository, or where
`-Dlawspec.native.jar` (`LAWSPEC_NATIVE_JAR`) and `-Dlawspec.resources.jar`
(`LAWSPEC_RESOURCES_JAR`) name them. The platform jar also carries the
Canon that `lawspec project` runs (the `canon` executable and Rice's Tax
0.4.3's grammar presets); the launcher unpacks it beside the binary, checks
the executable's SHA-256 the same way, and names it to `lawspec` with
`LAWSPEC_CANON` unless that is set. `CANON` still overrides the executable
for `project status` and `validate`. The binary is unpacked into
`lawspec/jvm` under the user cache directory (`~/Library/Caches` on macOS,
`$XDG_CACHE_HOME` or `~/.cache` on Linux), or `-Dlawspec.jvm.cache`
(`LAWSPEC_JVM_CACHE`); delete it to reclaim the space. A binary whose SHA-256
the launcher does not record is refused. Exit codes are the CLI's; 1 also
means the launcher could not find, unpack or verify the binary.

## Use the compiler API

```java
import dev.goforge.lawspec.LawSpec;

var compiler = LawSpec.createCompiler();
String response = compiler.check("{\"sources\":[{\"path\":\"a.lawspec\",\"text\":\"unit a\\n\"}]}");
```

The methods are the npm package's `createCompiler()` methods (`prelude`,
`inspect`, `advise`, `format`, `check`, `expand`, `explain`, `proofTasks`,
`planGeneration`), each taking the request object and returning the response
object as JSON text, as in the [compiler API](../reference/api.md). Each call
runs `lawspec --api <method>`.

## Build and install from a checkout

```sh
stack build lawspec:exe:lawspec-native
node tools/learn-build.mjs          # the Learn assets for lawspec-resources
hosts/jvm/stage-native.sh           # strips and stages this platform's binary
mvn -f hosts/jvm install            # 0.36.2-SNAPSHOT into ~/.m2/repository
```

`bash tools/hosts.sh jvm` does the same into `.artifacts/jvm/repository`
instead, which is what `lawspec-dev ci` uses.

## Build the platform jars

GHC builds `lawspec-native` for the platform it runs on; it is not
cross-built. (The npm `@goforgedev/compiler-<platform>` packages are
Wasmtime components, which Wasmtime cross-compiles; that route does not apply
to a GHC executable.) A Maven build makes the jar of each platform whose
binary is staged in `.artifacts/jvm/natives/`, and fails with the
instruction below for one that is not: by default the build machine's own
platform, all four with `-Pall-platforms`.

`tools/build-native.sh` builds all four on one Apple Silicon Mac: the Linux
binaries fully static (musl) in podman containers, `darwin-x64` under Rosetta;
see [Build the native binaries](build-native.md). Then stage each one:

```sh
for p in darwin-arm64 darwin-x64 linux-arm64 linux-x64; do
  hosts/jvm/stage-native.sh --platform $p \
    --binary .artifacts/native-build/$p/lawspec-native --canon .artifacts/native-build/$p/canon
done
hosts/jvm/stage-native.sh --check-all
```

`tools/build-native.sh --platform <platform> --canon` builds the Canon bundle
(`tools/build-canon.sh`) in the same environment. `stage-native.sh` checks
each executable's format with `file` and records its SHA-256 and size in the
launcher's manifest; `--check-all` confirms all four are staged, each with
its Canon bundle.

## Publish a release (owner)

The Maven build never signs or uploads. GoForge's
[assayxport](https://goforge.dev/assayxport/) publishes, as it does for the
other `dev.goforge` artifacts. From a clean checkout of the release tag,
with the platform binaries staged and the Learn assets built:

```sh
hosts/jvm/stage-native.sh --check-all
rm -rf hosts/jvm/target/central-staging
mvn -f hosts/jvm -Prelease,all-platforms -Drevision=0.36.2 -DskipTests \
  package deploy:deploy \
  -DaltDeploymentRepository=staging::file:$PWD/hosts/jvm/target/central-staging
(cd hosts/jvm/gradle-plugin && gradle -Pversion=0.36.2 publishAllPublicationsToCentralStagingRepository)
ax publish --maven-settings-path ~/para/projects/goforge/maven_settings.xml
```

The release profile attaches sources and javadoc jars, and `deploy:deploy`
writes them, unsigned, into a repository layout under `hosts/jvm/target/`;
the Gradle build adds the Gradle plugin and its plugin marker there.
`ax publish` reads `assayxport.toml` (the `maven-repository` policy and the
artifacts), checks every POM for Central's required metadata, signs each
file with the GoForge Central key, uploads one bundle, waits for Central to
validate it and publishes it. Run `ax publish --prepare` first to check and
sign without uploading. The Portal token stays outside the repository.
ref:DEC-maven-central-coordinates
