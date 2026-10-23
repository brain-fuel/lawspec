---
id: lawspec.reference.cli
kind: reference
title: CLI
---
# CLI

```text
lawspec fmt [paths...] [--check] [--compile] [--json] [--config <path>]
lawspec lsp --stdio
lawspec init --target <language> [--project <directory>] [--machine-bits <32|64>] [--minify] [--config <path>]
lawspec prove [--solver <z3-executable>] [--proof-timeout <ms>] [--proof-memory <MB>] [--proof-rlimit <n>] [--proof-seed <n>] [--machine-bits <32|64>] [--json] [--no-cache] [--config <path>]
lawspec check [--warn-matches] [--target <language>] [--machine-bits <32|64>] [--json] [--no-cache] [--config <path>]
lawspec evidence [<unit> | <unit>::<declaration>] [--attestation <file>] [--target <language>] [--machine-bits <32|64>] [--json] [--no-cache] [--config <path>]
lawspec explain [<unit>::<law>] [--view eng|math|dev] [--machine-bits <32|64>] [--json] [--no-cache] [--config <path>]
lawspec doctor [--target <language>] [--json] [--config <path>]
lawspec generate [--target <language>] [--dry-run | --check] [--minify] [--machine-bits <32|64>] [--json] [--no-cache] [--config <path>]
lawspec test [--target <language>] [--fresh] [--seed <n>] [--attestation <file>] [--update-recorded] [--tag <t>] [--exclude-tag <t>] [--report junit=<path>] [--coverage] [--benchmarks] [--minify] [--machine-bits <32|64>] [--json] [--no-cache] [--config <path>]
lawspec package [--project <package directory>] [--machine-bits <32|64>] [--json]
lawspec examples [--example payments] [--target <language>] [--output <directory>] [--machine-bits <32|64>] [--minify] [--json]
lawspec --version
lawspec help
```

Run the locally installed CLI with `npx lawspec`. `<language>` is one of `java`,
`python`, `javascript`, `typescript`, `go`, `haskell`, `kotlin`, `rust`, `erlang`,
`elixir`, `gleam`, `fsharp`, `csharp`, `scala`, `groovy`, `clojure` or `swift`.

## Common options

| Option | Meaning |
| --- | --- |
| `--config <path>` | The project configuration file. Default: `./lawspec.json`. Relative paths in it resolve from its directory. |
| `--target <language>` | Select configured targets of this language. Without it, generation uses every configured target and testing uses the configured program targets. |
| `--machine-bits <32\|64>` | Override the configuration's machine profile for this command. |
| `--json` | Print machine-readable output. Errors are printed as `{"diagnostics": [...]}`. |
| `--minify` | Compact output. Accepted only by `init`, `generate` and `examples`. |
| `--no-cache` | Do not read or write the compiler cache for this command. |

## Optional match warnings

`lawspec check --warn-matches` reports structurally unreachable case branches
(`case-unreachable`) and unnecessary fallbacks (`case-unnecessary-fallback`).
Warnings include source spans, do not fail the command, and are separate from
mandatory compiler errors. With `--json`, they appear in `warnings`, alongside
`warningAnalysis` describing the analysis scope. SDK requests select them with
`warnMatches: true`. They default to off and do not select law verification.

The analysis reuses ordered-pattern specialization. Guards do not establish
coverage. It is incomplete: an empty warning list does not prove that every
branch is reachable. Constructor/refinement facts that are only available after
typing may establish further unreachable branches without producing warnings.
Mandatory exhaustiveness, definedness and contract validation still apply.

In VS Code, enable `lawspec.warnMatches`. Other LSP clients can send
`initializationOptions: {warnMatches: true}`, or update the Boolean
`settings.lawspec.warnMatches` through `workspace/didChangeConfiguration`.
Warnings use severity 2 and UTF-16 source ranges; compiler errors use severity 1.

## `fmt`

`fmt` formats the supplied paths, or the configured project sources when paths
are omitted. By default it parses canonical syntax without compiling or
validating definitions and does not require package resolution, so work in
progress can be formatted. Independent syntax errors are reported together
across files; syntax errors prevent all writes. Add `--compile` to compile before
and after formatting, including mandatory definition validation; a compile
error also prevents all writes. No optional law checks are selected.

`--check` reports files that need formatting and exits with status 1 without
writing. It can be combined with `--compile` to check both formatting and
compilation. An ordinary `fmt` success establishes syntax only; use `check`
or `fmt --compile` for compiler validation. Available package sources contribute
parser headers for imported generic types; missing package directories are
ignored unless `--compile` is requested. Package bodies are not checked in
parse-only mode.

Source layout uses two spaces and an 80-column target. Comments, literal
values, names, equality wording, annotations and infix notation retain their
spelling. Long indivisible names and literals may exceed the target. Harness
settings keep their line boundaries; settings under `for law` or `for laws`
are indented within their group. Scenario commands also keep their line
boundaries, including long arguments in parallel branches and recovery blocks.
Other code in the same unit can still wrap. Resource operations, workflow groups
and parallel scenario branches retain their enclosing block indentation.
Multiline literal contents keep their whitespace, including blank lines;
block endings after the closing quote still close the enclosing formatter scope.
Optional record-type field commas are omitted. Commas in record values,
patterns, tuple types and tuple values are retained.

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

New configurations use version 2, `languageProfile: "1.0-rc.2"` and
`verification.layers: []`. Select optional law checks explicitly; intrinsic
definition validation remains mandatory.

If the target root has no build files (such as `pom.xml`, `pyproject.toml`,
`package.json`, `go.mod`, `stack.yaml`, `package.yaml`, a `.cabal` file,
`Cargo.toml` or Gradle files), `init` creates the target's scaffold. Otherwise
it leaves the build alone. Either way it prints the target's setup instructions.
It never overwrites a file.

## `check`

Parses, resolves and type-checks the project, validates definitions and expands
every law, without target tools. Prints the number of laws and the count of
obligations with each [evidence status](language/evidence-and-discharge.md).
Optional law layers default to none; those laws remain `not-verified`.
Configured native tests are planned until their execution supplies evidence.
The command also validates native bindings of selected targets. `--json` prints
the compiler's full result.

## `prove`

Requires configuration version 2 and selects the configured `proof` layer.
The compiler prepares typed tasks; the Node host invokes the specified Z3
executable, or `z3` on `PATH`. With no proof layer selected, no solver is invoked.
See [proof with Z3](../explanation/smt-proof.md) for supported theories, resource
limits, model-validation limits and the recorded trust boundary.

A successful solver proof updates the matching law's evidence. When Z3 finds
the law's negation satisfiable, it gives values for the law's outer inputs.
The compiler checks the law at those values with its reference evaluator. The
law is `refuted` only when the evaluator confirms it. Values the evaluator
does not confirm are reported as a `proof-translation` diagnostic. Unknown,
timeout, resource-limit, unavailable and unsupported outcomes do not establish
a law. `prove` also runs the [law-set checks](language/law-sets.md) the
compiler could not decide, with the same confirmation. `--json` includes task identities,
solver evidence and raw output. Other verification layers and intrinsic
contracts retain their own guarantees.

## `evidence`

Lists every obligation with its stage, identity, claim and reason, grouped by
status. Completed evidence, `PLANNED`, `NOT VERIFIED`, `INCOMPLETE`,
`UNSUPPORTED`, `ASSUMED / EXTERNAL`, `EXEMPTED` and `PENDING` retain their distinct meanings, alongside
the harness plane's `KNOWN FAILING`, `FLAKY` and `SKIPPED`. A `HARNESS` section
follows: for each
law with a [harness](language/harness.md), how it is tested (strategies,
`cover`, `classify`, `label`, tags, timeout, retries) and, from the last
`lawspec test`, how many cases ran and what they covered. The law's obligation
and its harness are kept apart: the harness can never change the obligation.

- `<unit>` limits the list to one unit.
- `<unit>::<declaration>` limits it to one obligation, such as
  `example.codec::codec` or `example.codec::itoa`.
  No match is an error.
- Binding, codec, generator and native-function obligations of the selected
  targets are included and labelled with their target.
- `--attestation <file>`: an environment attestation, a versioned JSON
  document any tool may write, that says where each dependency of a run was
  wired and whether it was the real dependency or a stand-in. Each tested law
  that relies on an attested dependency gets a line saying where it ran and
  against what, and an `ENVIRONMENT` section lists the dependencies. Without
  it, the `attestation` path in `lawspec.json` is read; without either, each
  law shows the attested `lawspec test` run it last passed in, if any. When
  the named attestation's run id is one `lawspec test` recorded, each law
  run in it is reported as completed, with its outcome, the run's exit code
  and whether a real provider or a fixture implemented each dependency;
  unless the attestation's `execution.status` is `wired` (wiring only) or
  `running` (in progress), when it stays planned. No status changes. See
  [where the tests ran](language/evidence-and-discharge.md#where-the-tests-ran).
  The cached document is the snapshot read by `lawspec test`. If Ironframe
  completes the run after that child exits, pass the completed file to
  `lawspec evidence --attestation <file>` to consume its final state. Without
  it, the cached running snapshot retains `plannedAgainst` and makes no
  completed environment claim, even when the native tests passed.
- `--json` prints the `ObligationEvidence` records; a law with a harness has
  `harness` (its settings) and, after a run, `adequacy` (its statistics); a law
  an attestation touches has `environment`, `environmentRun`, `against` and
  `environmentProviders`, with `environmentOutcome` when a completed run is
  linked, or the `planned` forms of these when none is.

## `explain`

Explains a checked law in one of three views. The compiler writes every view
from the same typed law. Explaining a law changes no obligation and runs no
adapter or law test.

- `<unit>::<law>` selects the exact owner and name that `check --json`
  returns. Without it, every law is explained. A selector that matches no law
  is an error.
- `--view eng` explains the law in plain English. This is the default. Each
  condition gets its own line. An input reads as "this request" after it is
  introduced. A function call reads as "the refund for this request", and a
  union case reads as `the refund decision "approved"`.
- `--view math` uses mathematical notation: quantifiers over sets
  (`∀ request ∈ RefundRequest`, `ℕ`, `ℤ`, `𝔹`), `∧`, `∨`, `¬`, `⇒`, `≤`, `≥`
  and `≠`.
- `--view dev` is for programmers: LawSpec notation with types. It shows the
  law's identity, documentary references, expansion trace, configured
  witness and search settings, inputs, the property, its source and every
  example. Brackets appear only where LawSpec's precedence needs them. Recorded
  native conformance appears last.
- `--json` prints the chosen view as structured records. Each record has
  `view`, `law`, `name` and an ordered `sections` list. Each section has a
  `kind` and its `lines`. The text output is every section's lines, in order,
  with a blank line between laws. In `eng`, a section that mentions a union
  case also has `cases`, which names each case's type, the case, and all of
  that type's cases.
- The former views `developer`, `business`, `formal` and `evidence` are
  errors. Each error names the replacement: `dev`, `eng`, `math`, or
  `lawspec evidence <unit>::<law>`.

For example, with the refund law from
[examples/rc1/refund-policy.lawspec](../../examples/rc1/refund-policy.lawspec):

```text
$ npx lawspec explain 'example.refunds::"|an eligible flagged refund requires review|'
Law: an eligible flagged refund requires review
For every request (a RefundRequest):
  If all of these are true:
    - the requested amount of this request is greater than 0
    - the requested amount of this request is at most its captured amount
    - this request is flagged
  then the refund for this request must be the refund decision "review required".

$ npx lawspec explain 'example.refunds::"|an eligible flagged refund requires review|' --view math
Law: an eligible flagged refund requires review
∀ request ∈ RefundRequest.
  (request.requestedAmount > 0 ∧ request.requestedAmount ≤ request.capturedAmount ∧ request.flagged) ⇒ refund(request) = ReviewRequired

$ npx lawspec explain 'example.refunds::"|an eligible flagged refund requires review|' --view dev
example.refunds::law::"|an eligible flagged refund requires review|
"|an eligible flagged refund requires review|
Inputs: request of type RefundRequest
request.requestedAmount > 0 and request.requestedAmount <= request.capturedAmount and request.flagged implies refund request = ReviewRequired
Source: refund-policy.lawspec:47:1
Examples: 0
```

`--json` on the first command prints a record of this shape:

```json
[
  {
    "law": "example.refunds::law::\"|an eligible flagged refund requires review|",
    "name": "\"|an eligible flagged refund requires review|",
    "sections": [
      { "kind": "title", "lines": ["Law: an eligible flagged refund requires review"] },
      { "kind": "inputs", "lines": ["For every request (a RefundRequest):"] },
      {
        "cases": [
          { "case": "review required", "cases": ["approved", "review required", "rejected"], "type": "refund decision" }
        ],
        "kind": "statement",
        "lines": [
          "  If all of these are true:",
          "    - the requested amount of this request is greater than 0",
          "    - the requested amount of this request is at most its captured amount",
          "    - this request is flagged",
          "  then the refund for this request must be the refund decision \"review required\"."
        ]
      }
    ],
    "view": "eng"
  }
]
```

A law's evidence is reported by [`evidence`](#evidence), not by `explain`.

Canonical phrase names keep their `"|...|` delimiters in a selector. Quote the
whole selector for the shell, as above. The same qualified spelling selects
that law in `evidence`.

## `doctor`

Artifact targets report `generation ready`; their downstream validators and
build tools are checked by the [artifact acceptance workflow](artifact-targets.md#acceptance-tools).

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

On Erlang, Elixir and Gleam, a selection keeps the selected units in one
native test run, preserving shared resource lifetimes. Law identities include
their unit, so identical labels in different units remain independently
selectable. EUnit and ExUnit completion events supply the execution report;
an incomplete report or a report from an earlier invocation cannot count as
evidence. Skipped laws run no checks. A known-failing BEAM law must complete
its native test to count as checked.

BEAM selections also include each model's sequential check, its parallel
check when shared, each scenario and the unit's supervision check. These
checks have separate cache entries and appear in native and JUnit reports.
A failed model or scenario retains its seed for the next run, just as a
failed law does. They have no harness tags, so a `--tag` selection excludes
them.

- `--fresh`: run every law's tests.
- `--update-recorded`: run every law's tests, and record each value a law
  compares with `recorded "name"` again, under `recorded/<unit>/<name>` beside
  `lawspec.json`. Without it, a missing or different recording fails its law.
  See [recorded values](language/laws-and-examples.md#recorded-values).
- `--attestation <file>`: the environment attestation of the environment the
  tests run in (default: the `attestation` path in `lawspec.json`). It is
  checked, kept with the run's results, and each law it touches that passes
  names it, so `lawspec evidence` later shows which laws ran against
  stand-ins. A law it touches runs again when its dependencies are wired
  differently: by endpoint, kind, and a stand-in's product, version and
  conformance, never by what the run observed, such as a history digest. An
  attestation stored inside the project is not one of its inputs. It
  changes no law and no outcome.
- `--seed <n>`: the property tests' random seed. Without it, each run draws a
  new one, and the summary prints it. A recorded pass keeps the seed it ran
  with.
- `--minify`: the generated files are compact (as `generate --minify` wrote).
- `--tag <t>`, `--exclude-tag <t>`: run only the laws whose
  [harness](language/harness.md) gives them one of the `--tag` tags, and none of
  the `--exclude-tag` ones. Each may be repeated or list several: `--tag a,b`.
- `--report junit=<path>`: write one JUnit XML report for every target's run,
  each suite identified by its target language and project root. Runners without a JUnit report of their
  own (JavaScript, TypeScript, Go, Rust, Haskell, Erlang, Elixir and Gleam) contribute their tests,
  passed or failed. BEAM reports retain native failure details and durations.
  JavaScript and TypeScript use [Node's structured reporter API](https://nodejs.org/api/test.html#custom-reporters)
  to preserve exact phrase names, including quotes and literal XML entities.
  Skipped tests do not count as passes. Missing, stale or incomplete structured
  reports do not establish that the selected laws ran.
- `--coverage`: measure code coverage with each target's tool, into
  `.lawspec/coverage/<target>/<project-hash>`: coverage.py (Python), c8 (JavaScript and
  TypeScript), `go test -cover`, JaCoCo (Java, through Maven), Kover (Kotlin, if
  the build applies its plugin), cargo-llvm-cov (Rust) and hpc
  (`stack test --coverage`), OTP `cover` (Erlang, Elixir and Gleam), and
  scoverage (Scala: Scala 3 instruments the sources, not the tests, and the
  scoverage reporter, which Scala CLI fetches, writes Cobertura, scoverage XML
  and HTML under `report/`).
  BEAM reports use `.lawspec/coverage/<target>/<project-hash>/index.html`
  and `coverage.json`, with native exports retained under `runs/`. Each report
  combines this invocation's replay batches and includes suite cleanup;
  separate project roots have separate reports. Gleam source coverage requires
  Gleam 1.19, whose counters map to the original `.gleam` and foreign Erlang
  source lines; with 1.18 the CLI reports the upgrade needed and runs without
  coverage. Elixir uses the default
  `Mix.Tasks.Test.Coverage` tool and respects `test_coverage[:output]`.
  Benchmarks run after collection and do not contribute to BEAM law coverage.
  A failed test can still produce coverage; a missing export or failed report
  collection makes the command fail with `coverageError` in the JSON summary.
  With no selected laws, BEAM writes no report. A missing tool is reported, with how to install
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

A law whose run fails is recorded in
`.lawspec/failures/<target>/<project-hash>/laws.json`
with the seed that exposed it. The next `lawspec test` runs those laws first,
each with its failing seed, so the same inputs are generated again; a law
leaves the database when it passes. `--seed` overrides it. The Python and Rust
runtimes also keep their libraries' counterexamples there (Hypothesis's
example database and proptest's regressions), which they replay first.

The project hash identifies its resolved root directory, as it does for cached
results and reports. Projects using the same target language have independent
failures; a passing project cannot clear another project's failures. Removing
and re-adding a target keeps its project identity.
JSON test summaries include each target's `root`, and text summaries distinguish
the roots when more than one project uses the same language.

Older databases without a project hash are preserved. Their seeds and saved
inputs are copied once into each project's initial database; subsequent runs
update only that project's copy.

Every target also keeps a failing case's inputs, not only its seed: in
`.lawspec/failures/<target>/<project-hash>/inputs/<law-id>.json`, each input in LawSpec's
[wire encoding](language/distribution.md#the-wire-encoding), the last (and
so, after shrinking, the smallest) failing case. The law's tests replay them
before new generated cases, with the message "replaying the failing inputs kept in
.lawspec/failures", and drop them once the law holds for them. A law whose
inputs the wire encoding cannot describe (a float, a handle, a generic data
type) is kept by its seed only.

On BEAM targets, the file name hashes the full law name so labels differing only
in punctuation remain separate. Its JSON record contains the readable law name
and wire inputs. Replays check the current refinements before calling an adapter
or acquiring a resource; incompatible inputs from an older law are discarded.

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
This command exports program targets; artifact projects use `init` and `generate`.

- Without `--example`, compiles every bundled specification and writes its
  generated tests and adapter stubs to `<output>/<language>/`. Default output:
  `example_artifacts`.
- `--example payments` exports the runnable native-binding project for each
  target to `<output>/<language>/`. Default output: `native_payments`.
- `--target <language>` selects one program target; default, all program targets.
- `--output <directory>` must be relative, without parent traversal or symbolic
  links.

`examples` accepts only `--example`, `--target`, `--output`, `--machine-bits`,
`--json` and `--minify`. See
[Generate example artifacts](../how-to/generate-example-artifacts.md).

## Exit status

`0` on success. `1` when a command fails, a law is refuted, `doctor` finds a
target that is not ready, or `generate --check` finds changes. `evidence`
still lists a refuted law under `REFUTED` before it exits with status `1`. `prove` uses status `1` when a
law is refuted, and status `2` when a selected task remains incomplete or
unsupported. An `exempted` law-set check does not change the status until its
exemption expires.
