---
id: lawspec.reference.configuration
kind: reference
title: Configuration
---
# Configuration

## `lawspec.edn`

The component and contract package manifest. Commands find the nearest `lawspec.edn`
in the current directory or its parents, unless `--config` names a file. Relative
paths resolve from that file’s directory. EDN is read as data; reader evaluation,
tags and executable forms are rejected. JSON manifests are no longer accepted.

```edn
{
  :manifest-version 1
  :component {
    :name "example"
    :version "0.1.0"
  }
  :language-profile "1.0-rc.2"
  :verification {
    :layers []
  }
  :sources ["laws"]
  :machine-bits 64
  :generation {
    :cases 100
    :max-attempts 10000
    :max-shrinks 1000
    :exhaustive-limit 4096
  }
  :dependencies {
    "shop.domain" "^1.0.0"
  }
  :packages ["../shop-domain"]
  :targets [
    {
      :language :java
      :root "java"
    }
    {
      :language :python
      :root "python"
      :python ".venv/bin/python"
      :test-dir "tests"
    }
  ]
}
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `manifest-version` | `1` | Yes | The manifest format. |
| `component` | identity map | One identity required | The component’s `:name` and exact semantic `:version`. |
| `package` | identity map | One identity required | A published contract package’s `:name` and exact semantic `:version`. A manifest may declare both identities. |
| `language-profile` | `1.0-rc.2` | Yes | The explicit canonical grammar and semantics. |
| `component.version` / `package.version` | semantic version | Yes | An exemption written `until 1.2.0` expires at this version; see [law sets](language/law-sets.md). Component identity takes precedence when both are present. |
| `verification` | object | No | `layers` defaults to `[]`, selecting none of the optional law checks. Choices: proof, exhaustive, property, examples, runtime, model, analysis. Intrinsic definition checks and their runtime enforcement remain automatic. |
| `verification.evaluation` | object | No | Optional compiler evaluation: `:max-steps` is a positive integer (default 1,000,000); `:defer-laws` lists fully qualified public law identities (default `[]`). Unknown identities are rejected. Definition admission and solver settings remain independent; see [step accounting and evidence statuses](language/evidence-and-discharge.md#compiler-evaluation-allowance). |
| `sources` | array of paths | Yes | `.lawspec` files, or directories scanned recursively for them. A file may hold a unit or a [harness](language/harness.md) for one. |
| `targets` | vector of targets | No | Native target settings for this component. Package-only manifests may omit targets. |
| `machine-bits` | `32` or `64` | No | The machine profile. Default `64`. `--machine-bits` overrides it. |
| `generation` | object | No | Property-test limits; see [below](#generation). |
| `dependencies` | map | No | Package names mapped to ranges or source maps: `:version` plus `:path`, `:git` or `:archive`. |
| `packages` | array of paths | No | Package directories to load, each with a `lawspec.edn`. Explicit path dependencies may also select local packages; Git and archive dependencies are fetched automatically. |
| `inputs` | array of paths | No | Native implementation or data files and directories, relative to this manifest; sibling directories are supported. See component descriptions below. |
| `cache` | boolean | No | Keep the compiler's work in `.lawspec/cache` between runs. Default `true`; see [the compiler cache](cli.md#the-compiler-cache). |
| `attestation` | path | No | An environment attestation that `lawspec test` and `lawspec evidence` read when `--attestation` is not given; see [where the tests ran](language/evidence-and-discharge.md#where-the-tests-ran). |

Which optional law layers are selected is explicit in the manifest. How those checks run (strategies, handlers, adequacy, tags, timeouts and
retries) is not configured here: it is a [harness unit](language/harness.md),
written in LawSpec beside the laws. `lawspec.edn` keeps only what concerns the
toolchain. `lawspec test` keeps its state next to this file: results in
`.lawspec/results`, runner reports and harness statistics in
`.lawspec/reports`, the [failure database](cli.md#the-failure-database) in
`.lawspec/failures` and coverage in `.lawspec/coverage`. None is committed.

The `model` layer selects native model, parallel-history, scenario and supervision
checks on all targets. Ordinary law properties and examples can run with this
layer omitted, including laws that call the generated actor and supervisor APIs.
Reference definitions retain mandatory contract checks regardless of selection.

### Targets

In addition to program languages, `hcl`, `yaml`, `antlr4` and `make` produce
[configuration and build artifacts](artifact-targets.md). These targets have
no executable law-test interface. Their optional `source-dir` contains all
generated files; `test-dir` and native bindings are rejected.

| Field | Targets | Meaning |
| --- | --- | --- |
| `language` | all | `java`, `python`, `javascript`, `typescript`, `go`, `haskell`, `kotlin`, `rust`, `scala`, `groovy`, `clojure`, `swift`, `fsharp`, `csharp`, `erlang`, `elixir`, `gleam`, `prolog`, `hcl`, `yaml`, `antlr4` or `make`. |
| `root` | all | The target's project root. Each target needs its own root. |
| `source-dir` | all | Source directory, relative to the root. |
| `test-dir` | all | Test directory, relative to the root. |
| `python` | `python`, `prolog` | Interpreter command. Default `python3`. |
| `maven` | `java` | Maven command. Default `mvn`. |
| `gradle` | `kotlin` | Gradle command. Default: `gradlew` in the root, otherwise `gradle`. |
| `rustc`, `cargo` | `rust` | Rust compiler and Cargo commands. Defaults `rustc` and `cargo`. |
| `native-bindings` | all | Native type, function and generator bindings; see [native bindings](native-bindings.md). |
| `actors` | `java`, `kotlin`, `scala`, `groovy`, `clojure` | The runtime generated actors and supervisors run on; see [below](#actor-runtimes). |

Default directories:

| Target | `source-dir` | `test-dir` |
| --- | --- | --- |
| `java` | `src/main/java` | `src/test/java` |
| `kotlin` | `src/main/kotlin` | `src/test/kotlin` |
| `python`, `rust`, `prolog` | `src` | `tests` |
| `javascript`, `typescript`, `haskell` | `src` | `test` |
| `go` | the root | the root |

### Actor runtimes

A JVM target can run its generated [actors and supervisors](language/actors.md)
on Apache Pekko instead of LawSpec's own runtime:

```edn
{
  :language :java
  :root "java"
  :actors {
    :runtime :pekko
  }
}
```

| Field | Values | Meaning |
| --- | --- | --- |
| `runtime` | `:lawspec` (default), `:pekko`, `:spring` | `:lawspec` is LawSpec's runtime, unchanged. `:pekko` runs each actor as a Pekko Typed behaviour and each supervisor as an OTP-style Pekko parent; the build gains `org.apache.pekko:pekko-actor-typed_3` 1.7.1. `:spring` runs them through the Spring Boot actor starter. |
| `remote` | `:cluster` | `serve` and `connect` use Pekko Cluster. Needs `:runtime :pekko` or `:spring`. |

The spec does not change with the runtime. Generated actors keep the same
methods, so adapters, laws and tests stay the same, and the same laws and
mutants are checked on every runtime. `:pekko` and `:spring` are only for Java,
Kotlin, Scala, Groovy and Clojure; another target with either is rejected.
Groovy and Clojure use the Java classes, so they run on Pekko when their target
selects it.

On `:pekko`, a call waits for its reply for up to 30 seconds by default.
Set the `lawspec.pekko.ask-timeout` system property (for example `5s` or
`500ms`) to change it. A call that times out throws
`LawSpecPekko.AskTimedOut`; it is never treated as a reply.

On `:pekko`, generated actors have no `serve` and `connect` methods until
`:remote :cluster` is implemented. `:spring`, Scala on `:pekko` and
`:remote :cluster` are planned for 0.33 and are not implemented yet; generation
reports them as unsupported.

Directories must be relative paths whose segments contain only letters, digits,
`_` and `-`. For Go, `source-dir` and `test-dir` must be equal.

The [Prolog target](prolog.md) supports function, handler and Hypothesis
generator bindings. Unsupported representation and instrumentation options are
reported explicitly.

### Generation

| Field | Default | Meaning |
| --- | --- | --- |
| `cases` | 100 | Accepted generated inputs per property. Examples and boundary cases are extra. |
| `max-attempts` | 10000 | Attempts to find inputs that satisfy refinements. |
| `max-shrinks` | 1000 | Shrink steps. |
| `exhaustive-limit` | 4096 | The largest finite domain enumerated in full, by the generated tests or by the compiler for laws over checked definitions. |

All limits are positive integers. Omitted fields keep their defaults. Each
framework applies them in its own way; see
[refinements](refinements.md#target-generation-limits).

## `lawspec.edn`

Describes a package directory.

```edn
{
  :manifest-version 1
  :package {
    :name "shop.domain"
    :version "1.2.0"
  }
  :language-profile "1.0-rc.2"
  :sources ["src"]
  :dependencies {

  }
  :packages []
}
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `name` | string | Yes | The package name. Every unit in the package is named `<name>` or `<name>.<suffix>`. |
| `version` | string | Yes | `MAJOR.MINOR.PATCH`, with an optional prerelease. |
| `verification.evaluation` | object | No | Optional compiler evaluation: `:max-steps` is a positive integer (default 1,000,000); `:defer-laws` lists fully qualified public law identities (default `[]`). Unknown identities are rejected. Definition admission and solver settings remain independent; see [step accounting and evidence statuses](language/evidence-and-discharge.md#compiler-evaluation-allowance). |
| `sources` | array of paths | Yes | Source files or directories, relative to the package directory. |
| `dependencies` | map | No | Package names mapped to ranges or source maps: `:version` plus `:path`, `:git` or `:archive`. |
| `packages` | array of paths | No | Package directories to load when checking this package on its own with `lawspec package`. |

Version ranges combine `1.2.3`, `^1.2.3`, `~1.2.3`, `>=`, `>`, `<=`, `<` and
`*`, with npm's meaning. See
[imports and packages](language/imports-and-packages.md#packages).

## Generated state

Each target root also contains `.lawspec/generated.json`, the ownership
manifest that `generate` maintains. Commit it with the generated files; do not
edit it. Projects exported by `lawspec examples --example payments` also contain
`.lawspec/example.json`, the export's own manifest.

## Contract resolution and component descriptions

A dependency source is a local path, a Git repository or an HTTPS archive:

```edn
{:dependencies
 {"shop.domain" {:version "^1.2.0" :git "https://example.org/contracts.git"}
  "shop.tax" {:version "^2.0.0" :path "../shop-tax"}}}
```

Git dependencies select the highest matching `vMAJOR.MINOR.PATCH` tag.
`:tag-prefix` changes that prefix, `:subdir` selects a package in a monorepo,
and `:rev` selects a revision instead of choosing a tag. A selected tag must
agree with the manifest version. Archive sources use `:archive` and a required
lowercase SHA-256 `:sha256`. Archives contain `lawspec.edn` at their root.

`lawspec fetch` resolves dependencies and writes `lawspec.lock.edn`. Commit that
file. Ordinary commands retain locked Git selections; `lawspec update [PACKAGE]`
selects newer matching versions. `--locked` rejects lock changes, and `--offline`
uses cached packages without network access. Changed downloaded content is
rejected. Local dependencies remain editable and their current content enters
the component fingerprint.

`lawspec package --output contract.tgz` checks and packs a package deterministically.
The archive includes its manifest, declared law sources, `:assets` and bundled path dependencies within its root. Published path dependencies cannot escape that root; editable local sibling packages remain supported during development. It excludes
generated consumers and build outputs unless declared as assets. Publish it using
your archive hosting tools, or publish the package directory with Git tags.
There is no LawSpec package registry.

`:provides` declares contract packages and checked ability identities implemented
by the component. Named `:requires` entries declare the contract, abilities, native
`:declarations` and injected `:settings` needed by a connection. `:inputs` lists
native code and data that contribute to the component fingerprint. They also
enter native result and evidence freshness keys for laws that observe native
implementations, including implementations outside the target root. Ordinary
laws over checked definitions do not acquire those external inputs.

Declared-input scans exclude build and cache directories, generated crypto
outputs and environment-attestation JSON. Native execution fingerprints also
exclude files recorded as compiler-owned output. A source generated by another
tool still counts. Target-root files already enter the native project digest;
only external declared files are added separately. Exact compiler-owned
readable and compact build scaffolds share a digest, while user edits count.

Native execution keys additionally bind the SDK runner, selection and evidence
code, the Node executable and runtime flags, and the installed dependency code,
as well as the compiler, target, machine profile and native toolchain. This
execution context is separate from WASM compiler memos and optional solver
receipts: a host change can require new native execution without moving the
WASM cache. Changed generated presentation must pass native source validation
before a cached outcome is reused. `--fresh` always requests actual execution.

A `recorded` comparison also depends on the reached data interface names and
files under `recorded/` beside the manifest. Changing them invalidates its
native observation; ordinary checked laws retain their independent keys.

`lawspec describe --json` returns the checked `lawspec-component` version 1
descriptor, including component identity, fingerprint, targets, resolved contract
versions and contract-closure digests, requirements and declaration identities. Physical archive/cache integrity remains separate from the resolved transitive contract identity. Its SDK interface
is exported from `lawspec/component`. Mandatory definition and native-binding
validation runs even when optional law verification is disabled.

CALM and Ironframe connect component descriptors. LawSpec does not deploy or
orchestrate a workspace. Each Rust or F# component keeps its own manifest and
native toolchain; `ironframe test --env local` starts the declared dependencies,
runs fresh native laws, consumes completed attestations, and cleans up processes
it owns.
