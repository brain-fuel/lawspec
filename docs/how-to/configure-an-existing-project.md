---
id: lawspec.how-to.configure-an-existing-project
kind: how-to
title: Configure an existing project
---
# Configure an existing project

This guide shows how to point LawSpec at an existing codebase: where your
specifications live, which targets to generate for, and how to match your
directory layout. The complete schema is in the
[configuration reference](../reference/configuration.md).

## Create the configuration

Run `init` for the first target. It creates `lawspec.json` and a starter
specification in `laws/`. It creates build files only when it detects none in
the target root:

```sh
npx lawspec init --target java --project java
```

Existing build files are never changed. `init` prints the dependencies and
test-runner settings the target needs; add them to your build yourself.

To add another target, run `init` again with a different target and project
directory:

```sh
npx lawspec init --target python --project python
```

Use `--config <path>` with any command to select a configuration file other than
`./lawspec.json`.

## Choose sources and targets

```json
{
  "version": 1,
  "sources": ["laws"],
  "targets": [
    {"language": "java", "root": "java"},
    {"language": "python", "root": "python", "python": ".venv/bin/python"},
    {"language": "haskell", "root": "haskell"}
  ]
}
```

- `sources` lists `.lawspec` files or directories, relative to the
  configuration file. Directories are scanned recursively for `.lawspec` files.
- Every entry in `targets` has its own project `root`. Two targets cannot share
  a root.

## Match your source and test directories

Each target writes to a default source and test directory under its root:

| Target | `sourceDir` | `testDir` |
| --- | --- | --- |
| `java` | `src/main/java` | `src/test/java` |
| `kotlin` | `src/main/kotlin` | `src/test/kotlin` |
| `python` | `src` | `tests` |
| `rust` | `src` | `tests` |
| `javascript`, `typescript`, `haskell` | `src` | `test` |
| `go` | the project root, in unit-based package directories | the same |

Override them per target with relative paths:

```json
{"language": "python", "root": "service", "sourceDir": "lib", "testDir": "checks"}
```

Paths must be relative, without `..` segments. Go's source and test directories
must be the same, because Go tests live beside the package they test. Configure
your build so it compiles and discovers those directories before you generate;
`doctor` checks that it does.

## Select the build tools

Some targets accept the command to run:

| Target | Field | Default |
| --- | --- | --- |
| `python` | `python`: the interpreter | `python3` |
| `java` | `maven`: the Maven command | `mvn` |
| `kotlin` | `gradle`: the Gradle command | a local `gradlew`, otherwise `gradle` on `PATH` |
| `rust` | `rustc` and `cargo` | `rustc` and `cargo` on `PATH` |

For Python, create a 3.13+ virtual environment, install the test dependencies
`init` prints, and set `python` to its interpreter.

For Haskell with Stack, run `stack build --test --no-run-tests` once before
`doctor`. This resolves the snapshot and generates the Cabal description through
Hpack; `doctor` reads that description without rewriting it.

## Set the machine profile and generation limits

```json
{
  "version": 1,
  "sources": ["laws"],
  "machineBits": 32,
  "generation": {"cases": 200, "exhaustiveLimit": 1024},
  "targets": [{"language": "go", "root": "."}]
}
```

- `machineBits` is `32` or `64` (the default). It sets the range of `IntSize`,
  `UIntSize` and `UIntPtr`. See [32-bit and compact profiles](use-32-bit-and-compact-profiles.md).
- `generation` sets property-test limits. Any field you omit keeps its default:
  `cases` 100, `maxAttempts` 10000, `maxShrinks` 1000, `exhaustiveLimit` 4096.
  See the [configuration reference](../reference/configuration.md#generation).

## Depend on packages

`dependencies` maps package names to version ranges. `packages` lists the
package directories to load, each containing a `lawspec-package.json`:

```json
{
  "version": 1,
  "sources": ["orders.lawspec"],
  "dependencies": {"shop.domain": "^1.0.0"},
  "packages": ["../shop-domain"],
  "targets": [{"language": "java", "root": "java"}]
}
```

See [Use imports and packages](use-imports-and-packages.md).

## Bind existing application code

A target's `nativeBindings` connects LawSpec types and adapters to types and
functions your application already has. See
[Bind native types and functions](bind-native-types.md).

## Check the result

```sh
npx lawspec check
npx lawspec doctor
npx lawspec generate --dry-run
```

`check` needs no target tools. `doctor` inspects each target's environment and
prints what to change. `generate --dry-run` lists the files generation would
write, without writing them.
