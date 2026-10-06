# Configuration

## `lawspec.json`

The project configuration. Commands read `./lawspec.json` unless `--config`
names another file. Relative paths resolve from the file's directory.

```json
{
  "version": 1,
  "sources": ["laws"],
  "machineBits": 64,
  "generation": {"cases": 100, "maxAttempts": 10000, "maxShrinks": 1000, "exhaustiveLimit": 4096},
  "dependencies": {"shop.domain": "^1.0.0"},
  "packages": ["../shop-domain"],
  "targets": [
    {"language": "java", "root": "java"},
    {"language": "python", "root": "python", "python": ".venv/bin/python", "testDir": "tests"}
  ]
}
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `version` | `1` | Yes | The configuration format version. |
| `sources` | array of paths | Yes | `.lawspec` files, or directories scanned recursively for them. A file may hold a unit or a [harness](language/harness.md) for one. |
| `targets` | array of targets | Yes | The target projects. |
| `machineBits` | `32` or `64` | No | The machine profile. Default `64`. `--machine-bits` overrides it. |
| `generation` | object | No | Property-test limits; see [below](#generation). |
| `dependencies` | object | No | Package names mapped to version ranges. |
| `packages` | array of paths | No | Package directories to load, each with a `lawspec-package.json`. It must include every package required directly or indirectly. |
| `cache` | boolean | No | Keep the compiler's work in `.lawspec/cache` between runs. Default `true`; see [the compiler cache](cli.md#the-compiler-cache). |

How laws are tested (strategies, handlers, adequacy, tags, timeouts and
retries) is not configured here: it is a [harness unit](language/harness.md),
written in LawSpec beside the laws. `lawspec.json` keeps only what concerns the
toolchain. `lawspec test` keeps its state next to this file: results in
`.lawspec/results`, runner reports and harness statistics in
`.lawspec/reports`, the [failure database](cli.md#the-failure-database) in
`.lawspec/failures` and coverage in `.lawspec/coverage`. None is committed.

### Targets

| Field | Targets | Meaning |
| --- | --- | --- |
| `language` | all | `java`, `python`, `javascript`, `typescript`, `go`, `haskell`, `kotlin` or `rust`. |
| `root` | all | The target's project root. Each target needs its own root. |
| `sourceDir` | all | Source directory, relative to the root. |
| `testDir` | all | Test directory, relative to the root. |
| `python` | `python` | Interpreter command. Default `python3`. |
| `maven` | `java` | Maven command. Default `mvn`. |
| `gradle` | `kotlin` | Gradle command. Default: `gradlew` in the root, otherwise `gradle`. |
| `rustc`, `cargo` | `rust` | Rust compiler and Cargo commands. Defaults `rustc` and `cargo`. |
| `nativeBindings` | all | Native type, function and generator bindings; see [native bindings](native-bindings.md). |

Default directories:

| Target | `sourceDir` | `testDir` |
| --- | --- | --- |
| `java` | `src/main/java` | `src/test/java` |
| `kotlin` | `src/main/kotlin` | `src/test/kotlin` |
| `python`, `rust` | `src` | `tests` |
| `javascript`, `typescript`, `haskell` | `src` | `test` |
| `go` | the root | the root |

Directories must be relative paths whose segments contain only letters, digits,
`_` and `-`. For Go, `sourceDir` and `testDir` must be equal.

### Generation

| Field | Default | Meaning |
| --- | --- | --- |
| `cases` | 100 | Accepted generated inputs per property. Examples and boundary cases are extra. |
| `maxAttempts` | 10000 | Attempts to find inputs that satisfy refinements. |
| `maxShrinks` | 1000 | Shrink steps. |
| `exhaustiveLimit` | 4096 | The largest finite domain enumerated in full, by the generated tests or by the compiler for laws over checked definitions. |

All limits are positive integers. Omitted fields keep their defaults. Each
framework applies them in its own way; see
[refinements](refinements.md#target-generation-limits).

## `lawspec-package.json`

Describes a package directory.

```json
{
  "name": "shop.domain",
  "version": "1.2.0",
  "sources": ["src"],
  "dependencies": {},
  "packages": []
}
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `name` | string | Yes | The package name. Every unit in the package is named `<name>` or `<name>.<suffix>`. |
| `version` | string | Yes | `MAJOR.MINOR.PATCH`, with an optional prerelease. |
| `sources` | array of paths | Yes | Source files or directories, relative to the package directory. |
| `dependencies` | object | No | Package names mapped to version ranges. |
| `packages` | array of paths | No | Package directories to load when checking this package on its own with `lawspec package`. |

Version ranges combine `1.2.3`, `^1.2.3`, `~1.2.3`, `>=`, `>`, `<=`, `<` and
`*`, with npm's meaning. See
[imports and packages](language/imports-and-packages.md#packages).

## Generated state

Each target root also contains `.lawspec/generated.json`, the ownership
manifest that `generate` maintains. Commit it with the generated files; do not
edit it. Projects exported by `lawspec examples --example payments` also contain
`.lawspec/example.json`, the export's own manifest.
