# CLI

```text
lawspec init --target <language> [--project <directory>] [--machine-bits <32|64>] [--minify] [--config <path>]
lawspec check [--target <language>] [--machine-bits <32|64>] [--json] [--no-cache] [--config <path>]
lawspec evidence [<unit> | <unit>::<declaration>] [--target <language>] [--machine-bits <32|64>] [--json] [--no-cache] [--config <path>]
lawspec explain [<unit>::<law>] [--machine-bits <32|64>] [--json] [--no-cache] [--config <path>]
lawspec doctor [--target <language>] [--json] [--config <path>]
lawspec generate [--target <language>] [--dry-run | --check] [--minify] [--machine-bits <32|64>] [--json] [--no-cache] [--config <path>]
lawspec test [--target <language>] [--fresh] [--seed <n>] [--update-recorded] [--tag <t>] [--exclude-tag <t>] [--report junit=<path>] [--coverage] [--benchmarks] [--minify] [--machine-bits <32|64>] [--json] [--no-cache] [--config <path>]
lawspec package [--project <package directory>] [--machine-bits <32|64>] [--json]
lawspec examples [--example payments] [--target <language>] [--output <directory>] [--machine-bits <32|64>] [--minify] [--json]
lawspec --version
lawspec help
```

Run the locally installed CLI with `npx lawspec`. `<language>` is one of `java`,
`python`, `javascript`, `typescript`, `go`, `haskell`, `kotlin` or `rust`.

## Common options

| Option | Meaning |
| --- | --- |
| `--config <path>` | The project configuration file. Default: `./lawspec.json`. Relative paths in it resolve from its directory. |
| `--target <language>` | Select configured targets of this language. Without it, commands use every configured target. |
| `--machine-bits <32\|64>` | Override the configuration's machine profile for this command. |
| `--json` | Print machine-readable output. Errors are printed as `{"diagnostics": [...]}`. |
| `--minify` | Compact output. Accepted only by `init`, `generate` and `examples`. |
| `--no-cache` | Do not read or write the compiler cache for this command. |

## The compiler cache

`check`, `evidence`, `explain` and `generate` keep the compiler's work in
`.lawspec/cache` next to the configuration file, and reuse it on later runs:
each law is expanded, elaborated and planned again only when it or something
it depends on changes, and each unit's files are emitted again only when
their inputs change. The results are the same as without the cache.

- The cache holds one folder per compiler build; upgrading LawSpec discards
  the previous build's folder.
- It contains its own `.gitignore`, so it is never committed.
- A damaged entry is recomputed and replaced. Deleting the folder is always
  safe.
- `--no-cache`, or `"cache": false` in `lawspec.json`, turns it off. It is also
  off when the configuration file is outside the working directory, which the
  WebAssembly compiler cannot reach.

Options that take a value require one. Unknown options, and positional
arguments where none are expected, are errors. The command exits with status 1
on any error.

## `init`

Creates or extends a project configuration.

- `--target <language>` (required): the target to add.
- `--project <directory>`: the target's root, relative to the configuration
  file. Default: the configuration file's directory.
- `--machine-bits <32|64>`: write `machineBits` into the configuration.
- `--minify`: write compact scaffolds and configuration JSON.

When there is no configuration file, `init` creates `lawspec.json` with
`sources: ["laws"]` and a starter specification `laws/atoi_codec.lawspec`. It
fails if the starter already exists. When the file exists, it adds the target.
A target of the same language with the same root is an error.

If the target root has no build files (such as `pom.xml`, `pyproject.toml`,
`package.json`, `go.mod`, `stack.yaml`, `package.yaml`, a `.cabal` file,
`Cargo.toml` or Gradle files), `init` creates the target's scaffold. Otherwise
it leaves the build alone. Either way it prints the target's setup instructions.
It never overwrites a file.

## `check`

Parses, resolves, type-checks and expands every law, without target tools.
Prints the number of laws and the count of obligations with each
[evidence status](language/evidence-and-discharge.md). Validates the native
bindings of the selected targets. `--json` prints the compiler's full result.

## `evidence`

Lists every obligation with its stage, identity, claim and reason, grouped by
status from `PROVED` to `ASSUMED / EXTERNAL`, then the harness plane's
`KNOWN FAILING`, `FLAKY` and `SKIPPED`. A `HARNESS` section follows: for each
law with a [harness](language/harness.md), how it is tested (strategies,
`cover`, `classify`, `label`, tags, timeout, retries) and, from the last
`lawspec test`, how many cases ran and what they covered. The law's obligation
and its harness are kept apart: the harness can never change the obligation.

- `<unit>` limits the list to one unit.
- `<unit>::<declaration>` limits it to one obligation, such as
  `example.atoi_codec::itoa and then atoi yields a` or `example.atoi_codec::itoa`.
  No match is an error.
- Binding, codec, generator and native-function obligations of the selected
  targets are included and labelled with their target.
- `--json` prints the `ObligationEvidence` records; a law with a harness has
  `harness` (its settings) and, after a run, `adequacy` (its statistics).

## `explain`

Prints each law's expansion trace, its final property, and each example's input
bindings and expected results. It does not run adapters.

- `<unit>::<law>` selects one law, named without backticks. No match is an
  error. Without it, every law is explained.
- `--json` prints the expanded law records with their expansions.

## `doctor`

Inspects each selected target's environment and prints `ready`, or a message
and setup instructions. Exits with status 1 if any target is not ready. See
[Diagnose your environment with doctor](../how-to/run-doctor.md).

## `generate`

Plans every selected target's files, runs the `doctor` checks, validates every
write against the ownership manifest, and then writes. Prints, per target, the
number of changes, the number of preserved adapters, any required adapter
signatures, and the command that runs the tests.

- `--dry-run`: print the planned changes; write nothing.
- `--check`: write nothing, and exit with status 1 if any file would change.
- `--minify`: compact generated code.

`--dry-run` and `--check` cannot be combined. If any target fails its checks,
nothing is written for any target.

## `test`

Runs the generated tests of the laws whose results may have changed since their
last passing run, through each target's own test runner, and records the laws
that pass.

```text
$ lawspec test
python: ran 2 law(s) with seed 1219107216, 41 unchanged since their last passing run.
$ lawspec test
python: nothing to run, 43 unchanged since their last passing run.
```

A law runs again when anything its result depends on changes:

- the law, or a type, definition, signature or contract it reaches;
- its unit's generated tests, the LawSpec version, or the target's settings;
- the project's build and lock files, or the toolchain `doctor` reports;
- for a law that calls adapters, any file in the target project that LawSpec
  did not generate, such as an adapter or a helper it imports.

The generated files must be current; run `generate` first. A failing run
records nothing for the laws it ran, so they run again next time. A law is
recorded as passing only if the runner's own report shows that its tests ran:
a test filter that matches nothing makes many runners succeed without running
anything, so a selected law with no executed test fails the run instead.
Results are kept in `.lawspec/results`, and runner reports in
`.lawspec/reports`; neither is committed.

- `--fresh`: run every law's tests.
- `--update-recorded`: run every law's tests, and record each value a law
  compares with `recorded "name"` again, under `recorded/<unit>/<name>` beside
  `lawspec.json`. Without it, a missing or different recording fails its law.
  See [recorded values](language/laws-and-examples.md#recorded-values).
- `--seed <n>`: the property tests' random seed. Without it, each run draws a
  new one, and the summary prints it. A recorded pass keeps the seed it ran
  with.
- `--minify`: the generated files are compact (as `generate --minify` wrote).
- `--tag <t>`, `--exclude-tag <t>`: run only the laws whose
  [harness](language/harness.md) gives them one of the `--tag` tags, and none of
  the `--exclude-tag` ones. Each may be repeated or list several: `--tag a,b`.
- `--report junit=<path>`: write one JUnit XML report for every target's run,
  each target's suites named after it. Runners without a JUnit report of their
  own (Go, Rust, Haskell) contribute their tests, passed or failed.
- `--coverage`: measure code coverage with each target's tool, into
  `.lawspec/coverage/<target>`: coverage.py (Python), c8 (JavaScript and
  TypeScript), `go test -cover`, JaCoCo (Java, through Maven), Kover (Kotlin, if
  the build applies its plugin), cargo-llvm-cov (Rust) and hpc
  (`stack test --coverage`). A missing tool is reported, with how to install
  it, and the run goes on without coverage. Coverage runs every selected law.
- `--benchmarks`: after the laws, run the harness's
  [benchmarks](language/harness.md#benchmarks) with each target's test runner,
  every time (they are never cached), and print their measurements.
- `--json`: print a summary per target (`ran`, `unchanged`, `seed`, `ok`, and
  `flaky`, `unmetCover`, `benchmarks` and `coverage` when there are any); the
  test runners' output goes to standard error.

A law's [harness](language/harness.md) shapes the run: a skipped law has no
test to run, a known-failing law's one test is expected to fail, flaky retries
and unmet `cover` requirements are listed after the summary. Benchmarks are
not laws, so `lawspec test` runs them only with `--benchmarks`; the target's
own test command runs them too, and prints their measurements. The harness runtimes write their statistics to
`.lawspec/reports/<target>/statistics`; `lawspec test` keeps each law's in its
results, and `lawspec evidence` shows them.

### The failure database

A law whose run fails is recorded in `.lawspec/failures/<target>/laws.json`
with the seed that exposed it. The next `lawspec test` runs those laws first,
each with its failing seed, so the same inputs are generated again; a law
leaves the database when it passes. `--seed` overrides it. The Python and Rust
runtimes also keep their libraries' counterexamples there (Hypothesis's
example database and proptest's regressions), which they replay first.

Generated property tests read the seed from `LAWSPEC_SEED`, so a failure can
be repeated with the same seed outside LawSpec. Haskell tests also read hspec's
`HSPEC_SEED`, which `lawspec test` sets as well.

## `package`

Checks a package directory on its own and prints its name, version, units, laws,
data types and dependencies.

- `--project <directory>`: the package directory, containing
  `lawspec-package.json`. Default: the current directory.

The package's own `dependencies` and `packages` fields are used to resolve its
dependencies. See [configuration](configuration.md#lawspec-packagejson).

## `examples`

Exports the bundled examples. Needs no configuration and no target tools.

- Without `--example`, compiles every bundled specification and writes its
  generated tests and adapter stubs to `<output>/<language>/`. Default output:
  `example_artifacts`.
- `--example payments` exports the runnable native-binding project for each
  target to `<output>/<language>/`. Default output: `native_payments`.
- `--target <language>` selects one target; default, all eight.
- `--output <directory>` must be relative, without parent traversal or symbolic
  links.

`examples` accepts only `--example`, `--target`, `--output`, `--machine-bits`,
`--json` and `--minify`. See
[Generate example artifacts](../how-to/generate-example-artifacts.md).

## Exit status

`0` on success. `1` when a command fails, `doctor` finds a target that is not
ready, or `generate --check` finds changes.
