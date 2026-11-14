---
id: lawspec.explanation.roadmap
kind: explanation
title: Roadmap
---
# Roadmap

Each minor release (0.x.0) is a roadmap milestone; everything else ships as a
patch (0.x.y). This page records what has shipped and what comes next. ref:DEC-release-cadence

## Released

| Release | Theme | Still open |
| --- | --- | --- |
| 0.12 | Proved indices: checked definitions over indexed families prove their result indices | Non-linear claims are checked at run time, not proved |
| 0.13 | Domain modelling: wrappers, constrained primitives and workflows | Workflows compose only infallible steps (see 0.18) |
| 0.14 | Imports and packages | Re-exports of imported names; several versions of one package in one build |
| 0.15 | Evidence and discharge: every obligation reports how it is checked | — |
| 0.16 | More dependent types: GADTs, index arithmetic, shared indices and the core of flow typing | Several flow parameters per function; flow calls inside match branches |
| 0.17 | Portable collections and asynchronous functions | Size-indexed queues and stacks; native bindings for asynchronous adapters |
| 0.18 | Railway-oriented workflows and resilience policies | — |
| 0.19 | Stateful models, protocols, actors, supervision and distribution | Deadlock freedom beyond tree-shaped connections; channel ends move between nodes by relay, not migration |
| 0.20 | Concurrent workflows, channel migration, indexed collections, flow typing and package re-exports | Scenarios with mailboxes or `or else` keep the tree rule |
| 0.21 | Abilities and handlers, built-ins, secure distribution and the test harness | — |
| 0.22 | Erlang, Elixir and Gleam targets, with native tests and OTP processes | — |
| 0.23 | F# and C# targets; typed native code; records, sequences and handlers of several abilities; where tests ran; parallel CI | A typed fast path for Erlang, Elixir and Gleam |
| 0.24 | Scala, Groovy, Clojure and Swift targets; typed native code on Erlang, Elixir and Gleam | Groovy and Clojure reuse the Java model rather than generating their own; Swift's post-quantum crypto and secure network need macOS 26 (CryptoKit); on the BEAM, a definition or handler without native forms stays dynamic, and a large handler state peaks at several times its live heap |
| 0.25 | Canonical authoring, records, quantifiers, mappings, optional law layers and compiler-backed authoring tools | Readability exercise deferred |
| 0.26 | Explicit named endings for every block and grammar profile `1.0-rc.2`; pre-1.0 migration support removed | Readability and final compatibility sign-off remain open |
| 0.27 | Completed CALM execution evidence, Prolog and HCL, YAML, ANTLR and Make artifact targets | Folio, the remaining demonstration and verification commitments, and human/external 1.0 gates remain open |
| 0.28 | Solver proofs over data, recursion, text and numbers; validated counterexamples; law-set analysis; model and history laws | No kernel-checked proof tier; native implementations, effects and resources are not given to the solver |
| 0.29 | Syntax-only formatting by default and record type layout | — |
| 0.30 | Triple-quoted multiline text and known discrepancies | — |
| 0.31 | Compact finite test plans and shared scoped searches on all 18 executable targets; unified EDN manifests and components | Teaching review of the learning course |
| 0.32 | Shared compiler, generation and tooling corrections (S1.j): checked strategies, evaluation allowance and deferral, the `mutate` command, and an opt-in component runtime | Original-project confirmations; native x64 and WSL2 cache checks; default-runtime cutover; larger models and checked mutual recursion |
| 0.33 | Apache Pekko and Spring actor runtimes for the JVM targets, checking hand-written Pekko and Spring actors against LawSpec actors, `restart keeps state`, Pekko Cluster `serve` and `connect`, faster model checking, checked mutual recursion, list `map` and `filter`, `lawspec init` that leaves a project ready to test, and the first application-port checkpoint | The LawSpec JVM runtime stays the default; no network partitions on Pekko Cluster, no symmetry reduction, no capability over type constructors |

0.16 in detail:

- [GADTs](../reference/language/gadts.md) refine type arguments per
  constructor, with polymorphic recursion and type witnesses for field-only
  existentials.
- [Index arithmetic](../reference/language/indexed-families.md): `+ - * div mod
  ^`, subtraction that never truncates, and shared indices such as perfect
  trees.
- [Flow types](../reference/language/flow-types.md): `A / A'` state parameters
  whose type changes with each call, checked left to right.

0.17 in detail:

- [Collections](../reference/language/collections.md): `Set`, `KeyVal`,
  `Queue`, `Stack` and `Deque`, with a portable total order of keys and each
  target's own native collections.
- [Asynchronous functions](../reference/language/async-functions.md): `async`
  adapters return each target's task, and the generated tests await them.

0.18 in detail:

- [Combinators](../reference/language/expressions-and-arithmetic.md) such as
  `>>=`, `<$>`, `<|>` and `??` sequence, map and recover `Either` values.
- [Workflows](../reference/language/workflows.md) are generated on every
  target from steps that may fail, with a generated or declared error type,
  `all` groups that may accumulate errors, and laws that a failed step stops
  the workflow.
- Policies on steps: retries, timeouts, rate limits, circuit breakers,
  bulkheads, caches, compensation and hedging. They run under a workflow
  runtime with a real or virtual clock.
- [Durations](../reference/language/durations.md) with literals such as
  `250ms`, exact on every target.

0.19 in detail:

- [Stateful models](../reference/language/models.md): commands checked
  against a reference model in sequence and in parallel, with portable
  generation and shrinking, `behaves like` collections, handles and native
  method bindings, and consistency models.
- [Protocols and scenarios](../reference/language/scenarios.md), proved
  deadlock-free and race-free, run on many schedules, with failures and over
  a faulty network; typed channel ends on every target.
- [Actors and supervisors](../reference/language/actors.md) with restarts,
  links and monitors, checked with injected crashes.
- [Distribution](../reference/language/distribution.md): nodes, transports
  (in memory, TCP, HTTP), a canonical wire encoding, and remote evaluation by
  content hash.

0.20 in detail:

- `if c then a else b` in checked definitions, with each branch's
  condition known to the totality audit.
- Proofs about multiplication of bounded integers.
- Deadlock freedom beyond tree-shaped connections: priorities on channel
  steps allow cycles that cannot deadlock.
- Channel ends that move to another node, instead of being relayed: the
  end's state moves and its peer is told the new address; local ends are
  still relayed.
- `all` groups in workflows run their steps at the same time.
- Size-indexed queues and stacks.
- Native bindings for asynchronous adapters.
- Several flow parameters per function, and flow calls inside `match`
  branches.
- Re-exports of imported names, and several versions of one package in one
  build.

0.21 in detail:

What real test suites need, on every target and in each target's own test
framework:

- fixtures with setup and teardown per test, group, unit or run, and
  temporary directories, files, ports and environment variables;
- groups, tags, skip, pending and expected failures, with selection by tag;
- example tables;
- matchers with structured diffs: collections, approximate numbers,
  patterns, text and snapshots;
- assertions on errors and their messages, on messages received within a
  time, and on what happens eventually or never;
- adapter doubles: fakes, stubs and spies, with checks on how they were
  called;
- a virtual clock and seeded randomness for adapters, and a scheduler
  that replays by seed;
- generator weighting, labels, coverage requirements, targeted search and
  a database of failures;
- timeouts, repeats, retries for flaky tests, random order and
  parallelism per unit;
- JUnit XML reports and coverage, doctests and benchmarks.

0.22 in detail:

Canonical vetting remains pending until 1.0.

Erlang, Elixir and Gleam join the targets, with actors on real processes
and OTP supervisors.

0.23 in detail:

- F# is written from scratch as idiomatic, functional .NET code, and it is
  the .NET runtime; C# runs over it, with a C# compatibility layer where an
  F# idiom would make C# awkward. Properties run on FsCheck.
- Checked definitions and stateful handlers compile to typed native code on
  every target but Erlang, Elixir and Gleam, with an embedding API.
- Field access and record update, operations that fail with a type,
  handlers of several abilities, sequences, and bounded arithmetic.
- `lawspec evidence` reports where tests ran, from an environment
  attestation.
- `lawspec-dev ci` runs its steps in parallel.

0.24 in detail:

- Scala runs over the shared JVM runtime, with ScalaTest and ScalaCheck.
  Groovy (Spock and JetCheck) and Clojure (`clojure.test` and test.check)
  run over the Java target's model.
- Swift is written for Swift 6 with strict concurrency. Its properties run on
  a small shrink-tree engine.
- Checked definitions and spec handlers compile to typed native Erlang on
  Erlang, Elixir and Gleam. `lawspec-dev bench kafka` has a driver for each
  new target.

The [changelog](../../CHANGELOG.md) records patch releases and the complete
changes for each milestone.

### 0.26: explicit endings for every block

Every keyword-delimited block has a named closer, including units, ability laws
groups, harness law groups, lets and generator binds. Handler clauses require
`operation ... end operation`. Bare `end` is invalid. Formatting, diagnostics,
editor services, examples and compiler-owned sources share the grammar profile
`1.0-rc.2`. This is an ordinary minor milestone, not an RC release designation.

Pre-1.0 migration support is removed. Until the API is stable, active sources
and consumers are updated directly. See the [syntax](../reference/language/syntax.md)
and the [approved contract](../../LAWSPEC-PRE-1.0-REVIEW.md).

### 0.27: execution evidence, Prolog and configuration

Completed Ironframe runs link LawSpec law evidence to architecture, topology,
application and dependency identities, distinguishing real providers from
fixtures. Startup wiring stays planned until execution completes. The same
application laws run against real, twin and mixed Kafka/HTTP bindings.

HCL and YAML now emit configuration artifacts from checked Core, with
explicit supported fragments and incomplete-input reporting. ANTLR emits
data syntax grammars with companion validation schemas, and Make emits
ordered check, generation and test pipelines. Their
[artifact contract](../reference/artifact-targets.md) distinguishes generation
from execution evidence.

Prolog now has public generation, Janus bindings and PLUnit execution over the
checked Python target, with the shared native acceptance matrix checked in
both machine profiles. Artifact generation remains distinct from law execution.

### 0.33: Pekko and Spring actor runtimes

Each JVM target (Java, Kotlin, Scala, Groovy and Clojure) chooses its actor
runtime in `lawspec.edn` with `:actors {:runtime ...}`: LawSpec's own (the
default, unchanged), Apache Pekko Typed, or Pekko through the Spring Boot actor
starter. Generated actors keep their public methods on every runtime, and
supervisors keep OTP's strategies, lifetimes, restart limits and escalation.
Hand-written Pekko and Spring actors can be bound to a LawSpec `actor` and
checked against its model, with injected crashes. A new phrase,
`restart keeps state`, says a restarted actor resumes with the state it had,
on every target. `serve` and `connect` map to Pekko Cluster on those runtimes,
and four `apache/pekko-samples` become acceptance suites. The decisions are
DEC-pekko-runtime, DEC-pekko-otp-supervision, DEC-restart-keeps-state,
DEC-pekko-cluster-remote and DEC-spring-actor-starter.

0.33 also admits mutually recursive definitions, adds list `map` and `filter`
and text pieces on every target, checks larger actor models quickly (partial
order reduction, per-value fairness, honest counts of refused steps), and
ships the first application-port checkpoint: manifest admission and version
selection in typed Haskell services. `lawspec init` now leaves a project ready
to generate and test: it fetches dependencies and runs the `doctor` checks.

### 0.34: answers to the first adoption report

0.34 answers a team's report of adopting 0.32 in a Spring Boot service on
Windows. Compiling is faster: a repeated `check` reuses one warm compiler and
its cache, compiler-provided units are admitted once, and `--timings` and a
progress line show where time goes. The command line runs natively on Windows
with the JVM and JavaScript targets, and the compiler cache has short paths, a
configurable place and a warning when it cannot be written. A failed test run
no longer keeps new laws from running. A law whose consequence no generated
case reached is `vacuous`, not passed, and the compiler derives generators
from guards and says how to fix the rest. The Java target compiles at release
21, runs on JUnit 6 and can write generated files apart from user-owned ones.
Records gain rules with stable ids, an accumulating validator, drafts that
break one rule each, JSON Schema, and a `masking` block that hides fields in
renderings, violation messages and logs. Generated code uses the parameter
names the spec declares, and `init` names the project.

## Planned

### S1.j follow-ups: remaining

0.33.1 shipped one `map` for lists and `Either` through a capability over type
constructors (`requires Mappable m`), stored parses so a repeated `check` reads
each source's parse from the cache directory, and a faster compile for projects
with structural records. Still open: persisted definition admission, list `map`
and `filter` in the typed fast-path backends, mutual tail calls as loops,
constructor predicates that call recursive definitions, and the rest of the
`generate` slowdown. The canon and Rice's Tax pin bump waits on their releases.
See [the S1.j follow-up](s1j-followup.md).

### Next: Haskell application port, with Maven, Gradle and Go hosts

Every command runs end to end in the Haskell core; Node, the JVM and Go become
thin hosts that only perform primitive effects (files, processes, fetch,
environment, clock, standard streams and serving HTTP). LawSpec is published to
Maven Central as `dev.goforge:lawspec`, with a Maven plugin and the Gradle
plugin `dev.goforge.lawspec`, and as the Go module `goforge.dev/lawspec`. Go
runs the WASM core on wazero. The JVM ships a natively compiled compiler in one
jar per platform with a logic-free launcher, because the engine study (wazero
1.22× V8; Chicory without SIMD support; GraalWasm 2.94× V8 on GraalVM only)
found no pure-JVM engine that meets the bar yet. The opt-in component runtime
becomes the default once the platform and application acceptance in
[the host SDK reference](../reference/host-sdk.md) is met. The first port
checkpoint, manifest admission and version selection, shipped in 0.33.

### Folio

Folio remains to emit documentation pages, and is deferred by the owner until
the rest of the system has settled. Completing that target will make
every required language canon reads a target. The remaining demonstration and
verification commitments stay in the approved pre-1.0 contract. C and C++ remain optional.

### Later: C and C++

C and C++ targets are optional and are not required for the 1.0 release.

C and C++ wait until the cost of generating code for every type they are
used at (monomorphisation) has been measured.

### Stub simulation, now a separate product

Simulated external dependencies (Kafka, HTTP and OpenAPI first, then SQL,
key-value stores, blob storage, queues and the rest) are built as a separate
product, LawTwin, on dependency contracts written in LawSpec. LawSpec itself
stays the business contract and knows nothing about the stand-ins; the
features those contracts need are LawSpec work.

### 1.0: rewrite, clean-up and sign-off

Once the features above are roughly in place, the code is rewritten and
cleaned up, and every canonical comment, decision, reference and page that
0.20.1 recorded as pending is reviewed and signed off with Rice's Tax.

### Larger models and mutual recursion

Continue the S1.j [measured scaling work](s1j-disposition.md): track CPU time,
peak memory and logical evaluation work across record widths, nesting depths and
recursive input counts. Avoid repeated proof expansion and subtree validation
without weakening constructor contracts or mandatory definition admission.
Optional law evaluation has an explicit allowance and deferral mechanism;
exhaustion does not establish a law.

Mutually recursive total definitions are admitted from 0.33.0 by size-change
analysis, with a checked `decreases` clause as fallback
([definitions](../reference/language/definitions.md#recursion-that-must-end)).
The compiler generates and discharges these obligations itself; there is no
solver run and no separate proof checker. Mutual induction in law proofs is
still reported as unsupported. The model checker has no symmetry reduction
yet, and the five-hakker table is checked as a model, not against the running
Pekko sample. This work does not remove the teaching review
or human/external release gates.
