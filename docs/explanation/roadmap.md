---
id: lawspec.explanation.roadmap
kind: explanation
title: Roadmap
---
# Roadmap

Each minor release (0.x.0) is a roadmap milestone; everything else ships as a
patch (0.x.y). This page records what has shipped and what comes next.

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

## Planned

### 0.19.1: fixes

- A bound handle's Kotlin type is its native class, not `Any`.
- A method bound on a Haskell handle with no type binding is a clear
  compile error.
- JavaScript and TypeScript session adapters await receives instead of
  using the synchronous shortcut.

### 0.20: concurrency and language completeness

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

### 0.20.1: canonical format

The repository moves to the canon
rules: one canonical home for every decision, reference and document;
documentation pages in the Folio; Keep a Changelog; and less duplication.

### 0.20.2: vetting

Every canonical comment, decision, reference and page is reviewed and
signed off.

### 0.21: test harness

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

### 0.22: BEAM targets

Erlang, Elixir and Gleam join the targets, with actors on real processes
and OTP supervisors.

### 0.23: JVM and .NET targets

Scala, Groovy, Clojure, C# and F#.

### 0.24: Prolog, configuration and documents

Prolog joins as a program target. HCL and YAML become configuration
targets: types become Terraform variables with validation and YAML
schemas, and values become checked configuration. ANTLR (grammars for the
text form of data), Make (build and test pipelines) and Folio
(documentation pages) complete the list, so every language canon reads is
a target.

### 0.25: stub simulation

Simulated external dependencies, so a system can be modelled and tested
against what it depends on:

- first: SQL (PostgreSQL), HTTP (REST and OpenAPI), key-value stores (Redis,
  Valkey), blob storage (S3), streams (Kafka) and queues (SQS, RabbitMQ);
- then: wide-column stores (Cassandra, ScyllaDB), document stores (MongoDB,
  DynamoDB), search (Elasticsearch, OpenSearch), gRPC, SMTP, and identity
  (OAuth, OIDC);
- and the network around them: virtual networks, subnets and load balancers,
  emitted as Terraform and Pulumi YAML.
