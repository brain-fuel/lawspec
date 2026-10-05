# Changelog

## Unreleased

- An `all` group with an asynchronous step runs its steps at the same time,
  on each target's own concurrency, so it takes as long as its slowest step.
  Results and accumulated errors keep the order of declaration, and every
  step finishes before the group fails. Groups of synchronous steps still run
  in turn.
- `lawspec.json` can bind an `async` adapter to native code returning the
  target's task: a coroutine, `Promise`, `CompletableFuture`, `suspend fun`,
  `LawSpecTask`, Rust future or `IO` action. The bridge stays asynchronous
  and converts the result once the task completes.
- A Rust unit with native bindings keeps its generated remote, session, actor
  and mailbox code.
- A match may leave out constructors that the value's index rules out: taking
  the head of a `Vec (n + 1) a` needs no `VNil` branch. The compiler proves
  each one impossible, and names a constructor the index allows.
- `SizedStack n a` and `SizedQueue n a` are stacks and queues indexed by their
  size: `prelude.sizedPop`, `sizedTop`, `sizedDequeue` and `sizedFront` take a
  non-empty one by type.
- A function may take several flow parameters (`A / A'`); a call passes a
  state to each (`pushBoth x ~a ~b`), and a definition may update each.
- Flow calls may sit in the branches of an `if` or a `match`. A state the
  branches leave at different types cannot be used afterwards, and the error
  names each branch's type.
- `if c then a else b` in laws and checked definitions. Only the selected
  branch is evaluated, and the totality audit checks each branch knowing which
  way the condition went. `prelude.select` now means the same.
- The totality audit bounds products: `x * x` for an `Int16` `x` fits `Int64`,
  and factors with known bounds give their product's bounds.
- Scenarios may close cycles between processes: LawSpec accepts channels that
  form a cycle when no process can wait for another in a cycle, and names the
  waits when one could. Scenarios with mailboxes or `or else` keep the tree
  rule.
- A unit can re-export names it imports with an `export` line after its
  imports (`export Band, rates.rateOf`), so a package can offer one facade
  unit. Re-exported names are the original declarations, not copies.
- A build can hold several versions of one package. Each unit sees the version
  its own package's range selects (the highest supplied version the range
  accepts), and each version's units are compiled under names with the
  version after the package name (`shop.tax.v2x0x0.api`), so their types and
  native names stay apart. A mismatch between two versions' types names both
  versions. A package supplied in one version is unchanged.

## 0.19.1

- A handle's Kotlin type binding can give the native class's type
  `arguments` (`["kotlin.Int"]`), so generated Kotlin names the handle's type
  in full instead of `kotlin.Any`.
- A Haskell method binding on a handle with no type binding names the handle
  and the `lawspec.json` entry to add.
- The sessions example's adapters are asynchronous, so the JavaScript and
  TypeScript ones await each receive instead of using `receiveNow`.

## 0.19.0

### Stateful models

- A `model` pairs a system's commands with a reference: a model state and a
  checked definition per command. LawSpec generates runs of commands from the
  model, runs them against the adapters, and checks every result, abstracted
  state and invariant. See [models](docs/reference/language/models.md).
- **Linear** models thread a flow-typed state, and each command's typestate
  comes from its flow signature, so runs never take a step the types forbid.
  **Shared** models share one handle; `when` preconditions come from the
  model state.
- Generation and shrinking are portable: a SplitMix64 generator over type
  descriptors gives the same runs and the same shrinks on every target for
  the same seed. A failing run is shrunk by dropping commands and shrinking
  arguments.
- Shared models also run in parallel: a short prefix, then a branch per
  thread, run at the same time with random yields, repeated, and each history
  must be linearizable. Sets and maps are checked key by key.
- `consistency sequential`, `causal` or `eventual` relaxes what a shared
  model's histories must satisfy, for replicated systems.
- `behaves like Queue a` (and `Stack`, `Deque`, `Set`, `KeyVal`) checks a
  model against a built-in collection, with no reference definitions to write.
- `handle Name` declares a type only adapters create. With native bindings,
  a handle can be a target's own class, such as a concurrent queue, and
  commands can call its methods and constructors directly.

### Protocols, scenarios and typed channels

- A `protocol` lists what one end of a channel sends and receives. A
  `scenario` runs a shared model's commands from processes (`par ... with ...
  end`) that talk over channels (`send`, `receive`, `expect`). LawSpec proves
  each scenario deadlock-free (its channels form a tree) and race-free (every
  channel end has one owner; sending it gives it up), then runs it on many
  schedules. See [scenarios](docs/reference/language/scenarios.md).
- Every protocol becomes typed channel ends on every target, for
  implementation code: a type per step, so an out-of-order send does not
  compile. A used end fails if used again (in Rust, it does not compile).
  `spawn` and `par` run processes on the target's own concurrency.

### Actors and supervision

- An `actor` owns a state and handles one message at a time. Handlers are
  plain functions from the state to a reply and the next state. Actors are
  checked like shared models, with injected crashes, and generated as typed
  actor classes on every target. See
  [actors](docs/reference/language/actors.md).
- A failing handler crashes the actor. `restart from f by g` says how it
  restarts. A `supervisor` restarts its children one for one, one for all or
  rest for one. Children are permanent, transient or temporary, within a
  restart limit that escalates to the parent supervisor. Actors also have
  links and monitors.
- Failures are affine in scenarios: a receive from a failed process fails,
  or runs its `or else`, instead of blocking. One run in three crashes a
  process. Typed channel ends raise `PeerFailed` when the other end gives up.

### Mailboxes

- `mailbox jobs of Job` declares a typed queue with many senders and one
  receiver. Every target generates `JobsMailbox`, which can also be served on
  a node and sent to from others.
- In scenarios, `mailbox m of T` sits beside `channel`. One process receives,
  every message sent must be received, and senders join the receiver in the
  deadlock-freedom tree. A receive whose senders have all failed fails, or
  runs its `or else`.

### Distribution

- Nodes talk over a transport: in memory (with loss, duplication, delay and
  partitions, for testing), TCP or HTTP. Actors can be served and called
  across nodes, protocols can listen and dial, and checked definitions can be
  evaluated on another node by content hash. See
  [distribution](docs/reference/language/distribution.md).
- Values cross the network in one canonical encoding, the same bytes on every
  target, checked against shared vectors.
- Calls and mailbox sends across nodes are resent until answered and run once.
  Channels number, acknowledge and resend their messages, so loss,
  duplication and reordering are repaired.
- A channel end sent to another node keeps working there: the sending node
  relays the conversation. Every protocol can `listen` and `dial`.
- One scenario run in three sends every channel over a faulty network.

### Generation

- A refinement's constant integer bounds narrow generation on every target,
  so `(amount :: Int32 where amount >= 1 && amount <= 1000)` is drawn from
  `1..1000` instead of being filtered out of every `Int32`.
- Generated Python property tests no longer have a per-example deadline, since
  adapters may wait on networks or timers.

### Evidence

- `lawspec evidence` lists models, consistency, restarts and supervision as
  property-tested, and each scenario as proved deadlock-free and race-free.

## 0.18.0

### Railway combinators

- `>>=`, `<$>`, `<!>`, `<|>`, `??`, `>=>`, `|>` and `<*>`, and the prelude
  names `bind`, `then`, `map`, `mapError`, `orElse`, `fallback`, `fromEither`,
  `andThen`, `pipe`, `both`, `ensure`, `isLeft` and `isRight`, sequence, map
  and recover `Either` values in laws and checked definitions on every target.
  See [expressions](docs/reference/language/expressions-and-arithmetic.md).
- `Pair` joins the built-in collections unit, and `prelude.select` chooses
  between two values.

### Generated workflows

- LawSpec now generates each `workflow` on every target from its stages:
  steps, `then`, `map`, `mapError`, `tap`, `ensure`, `orElse`, `fallback`, and
  `all` groups whose results `combine` joins. With `accumulate`, an `all`
  group reports every failing step's error. See
  [workflows](docs/reference/language/workflows.md).
- Steps may fail with different error types. A declared error type takes them
  through `mapError`; with `Either _ T`, LawSpec generates an error type named
  after the workflow, with a constructor per failing step
  (`PlaceOrderValidateOrderFailed`).
- Generated laws check that each workflow composes its stages, succeeds when
  every stage does, stops when a step fails, and recovers with each handler.
- **Migration:** hand-written workflow adapters are no longer called. Remove
  them, and move any behaviour they had into the steps.

### Policies

- A step can run under `retry` (immediate, fixed, linear, exponential,
  fibonacci or custom, with optional jitter and a `when` predicate),
  `timeout`, `rateLimit` (token bucket, leaky bucket, fixed or sliding
  window; wait or reject), `circuitBreaker`, `bulkhead`, `cache`,
  `compensate` and `hedge`. A policy failure becomes a constructor of a
  generated error type, or the value a declared error type names with `else`.
- Workflows run under a workflow runtime: a real or virtual clock, a SplitMix64
  random source identical on every target, a trace, and the state of
  limiters, breakers, bulkheads and caches. Callers create one to give a
  workflow its own state or a virtual clock; otherwise a shared runtime is used.
- The rate limits, breaker and bulkhead are written once, as checked
  definitions of a built-in unit, `lawspec.resilience`, so they behave the same
  on every target. A new resilience acceptance suite checks each target's
  runtime against them.
- Generated tests run workflows on a virtual clock with stateful policies,
  timeouts and hedges off; retries still apply.

### Durations

- `Duration` is a whole number of microseconds, exact on every target, with
  literals (`250ms`, `2s`, `5min`), arithmetic, comparisons and native types
  (`timedelta`, `time.Duration`, `java.time.Duration`,
  `kotlin.time.Duration`, `std::time::Duration`). See
  [durations](docs/reference/language/durations.md).
- The totality audit proves more: products and quotients are atoms, quotients
  are bounded, calls satisfy their definitions' postconditions, and unwrapped
  wrapper values satisfy their constraints.

### Other changes

- A definition or adapter named with a target keyword is emitted with a
  leading underscore on that target (`class` is `_class` in Python); such names
  were rejected or broke the build before.
- On JavaScript and TypeScript, a checked definition that calls an `async`
  adapter, directly or through another definition, is itself `async`.
- Kotlin workflows can call `suspend` adapters. The Kotlin scaffold depends on
  `kotlinx-coroutines-core`, and `lawspec doctor` reports it missing.
- Python: a synchronous definition called from inside a running event loop
  (from an `async` adapter) awaits its asynchronous steps on a thread of its
  own instead of failing.
- Python property tests have no per-example deadline, since adapters may do
  real work.

## 0.17.5

### `lawspec test` confirms that each law's tests ran

- A test filter that matches nothing makes Go, Rust, Node, Kotest and hspec
  report success without running anything. `lawspec test` now reads each
  runner's own report (pytest and Node JUnit XML, `go test -json`, the
  Surefire and Gradle reports, and Rust's and hspec's per-test output) and
  records a law as passing only if at least one of its tests ran and was not
  skipped. A selected law with no executed test fails the run, naming the law.
- Results and runner reports live in `.lawspec/results` and `.lawspec/reports`,
  each with its own `.gitignore`.

## 0.17.4

### `lawspec test`

- Runs the generated tests of only the laws whose results may have changed
  since their last passing run, through each target's own runner, and records
  the laws that pass. A law runs again when the law changes, or anything it
  depends on: the types and definitions it reaches, its unit's generated
  tests, the LawSpec version, the target's settings, the project's build and
  lock files, the toolchain, and, for a law that calls adapters, any file in
  the project LawSpec did not generate. `--fresh` runs every law. See
  [`lawspec test`](docs/reference/cli.md#test).
- Every run uses one random seed for all property tests, printed in the
  summary and recorded with each pass; `--seed` fixes it.
- `planGeneration` responses list each law's generated test file, its
  position in the unit, its dependency key and whether it calls adapters
  (`tests`).

### Changes to generated tests

- Property tests read their seed from `LAWSPEC_SEED` on every target, so a
  failing run can be repeated exactly.
- Kotlin and Haskell property tests are named `law<n>Property: <law>` like
  their example and boundary tests, so each law's tests can be selected by
  name.

## 0.17.3

### Incremental front end

- Each law's expansion and type checking, and its elaboration to Core, are
  keyed by exactly their inputs: the law, the laws it invokes, its unit's
  signatures and the program's data types. Editing a definition's body, or
  another unit's laws, no longer re-checks a law; the dependency keys of
  0.17.2 still replan the laws that reach the edit.
- Unit validation and totality checks are keyed by the unit.
- Evidence discharge shares the test planner's work, and builds the type
  registry once per program rather than once per law.

### On-disk compiler cache

- `lawspec check`, `evidence`, `explain` and `generate` keep the compiler's
  work in `.lawspec/cache` and reuse it across runs. Results are identical to
  an uncached run. With every bundled example in one project, a repeated
  `lawspec check` takes 4.7 seconds instead of 8.4, and generating Python
  tests through the API 9.2 instead of 18.2 (natively, a third of the time).
- One folder per compiler build, with its own `.gitignore`; damaged entries
  are recomputed. `--no-cache` or `"cache": false` turns it off. See
  [the compiler cache](docs/reference/cli.md#the-compiler-cache).
- API requests may name a `cacheDirectory` to share work the same way.

## 0.17.2

### Dependency-tracked incremental compilation

- The compiler builds a dependency graph of each program. Its nodes are data
  types and declarations (with their contracts and checked definitions), and
  each node has a Merkle digest (SHA-256) of its content and of everything it
  references, with recursive groups digested together.
- A law is planned again only when it, or a type or definition it can reach,
  changes. A unit's files are emitted again only when the unit or one of its
  laws' plans changes, when a data type changes (emitters name types across
  the whole program), or when a checked definition is added, removed or
  renamed. Editing one definition's body no longer replans and re-emits the
  whole program, and reverting an edit reuses the earlier results.
- Each law is planned from only the types and definitions it reaches, which
  cuts planning time for the bundled examples by two thirds. Evidence
  discharge plans laws the same way, so `lawspec evidence` reports the boundary
  cases the generated tests use.

### Changes to generated tests

- Boundary search for constrained data took its depth from the number of data
  types in the whole program, and seeded scalar boundaries with literals from
  every type's constructor predicates. Both now come from the types the law
  reaches, so adding an unrelated type no longer changes a law's tests.
  Regenerating can change the boundary cases of laws over indexed families and
  constrained data; among the bundled examples, `indexed_arithmetic`,
  `domain_modeling` and the shop package's domain unit gain or lose cases.

## 0.17.1

### Faster compilation

- The compiler reuses work for whatever did not change. A compiler instance
  (one `createCompiler()`, one wasm instance or one process) compiles,
  discharges and plans a set of sources once for every method and target, plans
  each law again only when it or the program's types, declarations, contracts
  or definitions changed, and emits each unit again only when it, its laws or
  that interface changed. Results are identical to a full compile.
- `lawspec examples` and other multi-target runs compile once instead of once
  per target: generating every bundled example for all eight targets takes
  about 105 seconds instead of about 270.
- A single compile is faster too: kind lookups use a map instead of scanning
  every type in the program, boundary candidates are deduplicated in
  `n log n`, and long failure messages are split by bisection. Compiling all
  bundled examples together takes a quarter less time.

### Incremental local checks

- `lawspec-dev ci` records passing results by content. Acceptance suites key
  each run by the generated project and everything else its tests read, so a
  compiler change that leaves a target's output unchanged skips that target's
  native tests. Core steps key by the repository files they read.
- `lawspec-dev ci --fresh` (`make ci-fresh`) runs every step, and releases use
  it. See [CONTRIBUTING](CONTRIBUTING.md#checks).

## 0.17.0

### Collections

`Set a`, `KeyVal k v`, `Queue a`, `Stack a` and `Deque a` are built in, with
`Entry k v` and `Ordering`. Operations are total prelude functions, such as
`prelude.setOf`, `prelude.lookup`, `prelude.push` and `prelude.popBack`, and
`prelude.compare` orders two keyed values. A unit that declares a type of the
same name keeps its own.

- Set elements and KeyVal keys need the new `Keyed` capability: a total order
  shared by every target. Exact numbers order by value, text by code point,
  lists element by element and data by constructor, then fields. Floats,
  complex numbers and symbols are not keyed.
- Adapters use each target's own collections: `frozenset` and `dict` in
  Python, `Set` and `Map` in JavaScript, sorted slices in Go, `java.util.Set`
  and `Map` in Java and Kotlin, `BTreeSet` and `BTreeMap` in Rust, and
  `Data.Set` and `Data.Map` in Haskell. Python and JavaScript use sorted tuples
  or arrays where elements are structured. Codecs sort, deduplicate and keep
  the last value for a repeated key.
- Generated Haskell projects depend on `containers`. Rust and Haskell
  generated data derive `Ord` when it is keyed.

See [collections](docs/reference/language/collections.md).

### Asynchronous functions

`async price :: Text -> Int32` declares an asynchronous adapter. It returns a
coroutine in Python, a `Promise` in JavaScript and TypeScript, a
`CompletableFuture` in Java, a `suspend fun` in Kotlin, a goroutine-backed
`lawspec.Task` in Go, an `IO` action in Haskell and a `Future` in Rust. The
generated tests await each call where it is made, and check contracts on the
awaited result. See
[asynchronous functions](docs/reference/language/async-functions.md).

### Other changes

- A numeric literal passed to a generic function takes the type its other
  arguments fix: `prelude.insert 1 s` with `s :: Set Int32` needs no
  annotation.
- Generated schemas no longer revalidate a whole value on each construction,
  match or checked-definition call; values are checked at the adapter
  boundary. Large recursive values test much faster.
- The list example is now `examples/specs/lists.lawspec`;
  `collections.lawspec` covers the new collections.

## 0.16.0

### GADTs

A constructor can fix a type parameter: `| Number value :: BigInt where a =
BigInt` builds only `Expr BigInt`. Matching refines the parameter in each
branch, so `definition eval (e :: Expr a) :: a` type-checks. A constructor that
cannot build a type is no value of it: matches need no branch for it, and
decoding rejects it. Definitions may call themselves at other instances
(polymorphic recursion), up to 64 instances each. Existentials determined by
the type (`where a = Pair b c`) are supported, and so are existentials only a
field mentions: each such value carries its type as a trailing `witness` field,
and generated values draw it from `Bool` and `Int32`. Native types use each
target's own GADT form where it has one: sealed interfaces of records in Java,
Kotlin data classes, Haskell GADT syntax, TypeScript conditional unions and
`Expr[int]` in Python. See [GADTs](docs/reference/language/gadts.md).

### Index arithmetic and shared indices

- Index expressions accept `+ - * div mod ^`. Subtraction never truncates:
  `n = m - 1` requires `m >= 1`, as a runtime-checked constructor constraint.
- A variable bound by several fields makes their indices equal, so
  `Node left :: Perfect m right :: Perfect m` declares perfect trees.
- An implicit index may first appear as `v + k` or `k * v`:
  `dropFirst :: (xs :: Row (k + 1)) -> (r :: Rest k)`.
- Products and powers are uninterpreted atoms in the prover, so `r * c` and
  `c * r` agree. A definition's non-linear result index that cannot be proved
  is checked on each result and reported as `runtime-checked`; a linear one is
  still an error.
- Generation solves any equation backwards over the indices each constructor
  can reach, in all seven runtimes. This fixes `n = m + m`, which used to build
  children of the wrong size, and builds balanced trees even without a fixed
  index.

See [indexed families](docs/reference/language/indexed-families.md).

### Flow types

`pop :: Stack (n + 1) / Stack n -> Int8` declares a flow parameter: the call
takes the stack from one type to another. In laws, `~s` passes a state and
rebinds it to the state the call leaves, and `e1; e2` sequences:
`(push x ~s; pop ~s) = x`. Each clause is checked left to right, so a pop the
stack cannot take is a compile error that suggests a bound. A definition
updates its flow parameter with `~s := e`. Each flow function returns a
generated product (`PopFlow` with `result` and `state`), indexed by the state
it leaves, so adapters' output states are runtime checked. See
[flow types](docs/reference/language/flow-types.md).

### Other changes

- A type variable that only a field mentions is now an existential, not an
  error.
- Rust property tests run on a thread with a 64 MiB stack, for deep generated
  values.
- New acceptance suites `gadt` and `flow`, and `indexed` gains
  `examples/specs/indexed_arithmetic.lawspec`, with mutants for every target.
- The [roadmap](docs/explanation/roadmap.md) records 0.12 to 0.19.

## 0.15.2

Generated data types are the types you would write by hand, so adapters no
longer cast. A product (a type with one constructor) is named after its type
and read directly; a sum (several constructors) is a closed family that the
language's own pattern matching checks for exhaustiveness. Laws, tests,
evidence and codec checks are unchanged, but the generated types adapters
compile against change:

| Target | Before | After |
| --- | --- | --- |
| Java | `var d = (Drink.DrinkCase) value0; d.shots` | `value0.shots()` (a `record`) |
| Java | `new Size.LargeCase()`, `x instanceof Size.LargeCase` | `new Size.Large()`, `case Size.Large large ->` (sealed interface of records) |
| Kotlin | `(value0 as Drink.DrinkCase).shots` | `value0.shots` (a `data class`) |
| Kotlin | `Size.SmallCase()`, `is Size.LargeCase` | `Size.Small` (a `data object`), `is Size.Large` |
| Go | `value0.(DrinkDrink).Shots`, `DrinkDrink{...}` | `value0.Shots`, `Drink{...}` (a plain struct) |
| Rust | `let Drink::Drink { shots, .. } = value0;` | `value0.shots` (a `struct` with public fields) |
| Python | `data.DrinkDrink(...)` | `data.Drink(...)` |
| JavaScript, TypeScript | `new data.DrinkDrink(...)` | `new data.Drink(...)`; TypeScript's `Drink` is the class |
| Haskell | `Data.DrinkDrink size shots` | `Data.Drink size shots` |

- A case is named after its constructor. When that name equals the type's name
  or clashes with another case, Java and Kotlin keep a `Case` suffix.
- Java records compare by value. A field named like a `java.lang.Object`
  method (`hashCode`, `toString`, ...) is rejected, since its accessor would
  override that method.
- A nullary case of a generic Kotlin sum is a class with value equality
  (`Chain.Stop<T>()`); other nullary cases are `data object`s.
- Sums in Go, Rust, Python, JavaScript, TypeScript and Haskell keep their
  names (`SizeSmall`, `Size::Small`).

## 0.15.1

A maintenance release. The language and generated code are unchanged.

- **Documentation** moves into a [Diátaxis](https://diataxis.fr) site in
  `docs/`: tutorials, how-to guides, reference and explanation. It replaces the
  README's version-history sections, the per-target guides, `LANGUAGE.md`,
  `NATIVE-BINDINGS.md`, `PRIMITIVES.md`, `REFINEMENTS.md`, `API-MIGRATION.md`
  and the separate release notes, which this changelog now collects.
- **Lessons.** Eight tutorials build a coffee shop's ordering system, in Java,
  Python and JavaScript tracks. Each lesson's specification is editable and
  compiles in the browser, and the JavaScript tests run in the page. The lesson
  implementations are a new acceptance suite, `lessons`, with a mutant per
  lesson on each of the three targets.
- **The site** is static and built with `make docs`: `make docs-serve` previews
  it and `make docs-deploy` deploys it to Cloudflare Pages. It runs the npm
  package's `core.wasm` through a browser launcher with a minimal WASI shim,
  and highlights LawSpec and every target language, in the editor too. Every
  example is an editable sandbox: **Check** shows each law's evidence, and
  lessons' **▶ Run** runs the generated JavaScript or TypeScript tests against
  an editable implementation in an isolated frame, reporting each law's
  examples, boundary cases and generated cases. Generated tests are read-only.
  The `lessons` acceptance suite also covers TypeScript.
- **Evidence.** A law whose equation compares two Boolean expressions now shows
  its claim as written (`isWeekend d == (d == 0 || d == 6)`), not as the
  equivalence the prover uses.
- **Generated JavaScript.** Every JavaScript file in the repository is generated
  from `templates/` by `lawspec-dev generate`, with the version, targets,
  scaffolds and test commands filled in from the Haskell sources. The
  compiler's own facts are no longer copied by hand into the npm CLI.
- **Development.** 121 unmaintained integration scripts, most of which needed
  manual setup and no longer ran, are removed; the acceptance suites and the
  Hspec tests cover what they did. The TypeScript API type check becomes an npm
  test. The Makefile covers every task (`make` lists them), `lawspec-dev bump`
  sets the version everywhere, and `RELEASING.md` documents the release.
- The npm package ships `README.md`, `CHANGELOG.md` and `LICENSE`; the
  documentation is online.

## 0.15.0

### Evidence and discharge

Every obligation of a program reports how it is discharged, strongest first:

- `proved`: statically. Definition postconditions and indices, as since 0.12,
  and now laws that call only checked definitions.
- `exhaustively-checked`: every input of a finite domain, by the compiler for
  laws over checked definitions and otherwise by the generated tests. A law with
  no inputs is a single case.
- `property-tested`: generated cases, boundary cases and examples.
- `runtime-checked`: adapter contracts, definition preconditions, constructor
  constraints and native type bindings, at every native boundary.
- `assumed`: adapters, native functions, custom generators and codec hooks,
  taken on trust. Each adapter reports how many laws call it, or that none does.

`lawspec check` summarizes the obligations by status, and the new
`lawspec evidence` lists each with its claim and reason (`--json` for the API
records, and a unit or `unit::declaration` filter). See
[evidence and discharge](docs/reference/language/evidence-and-discharge.md).

### Laws proved and refuted by the compiler

A law over checked definitions is attempted as a proof by the same exact linear
arithmetic that proves definition results, from its input refinements, with
definitions that have no preconditions unfolded into the claim. When it is not
proved and its domain is finite, the compiler evaluates every input; a
counterexample is a compile error with code `refuted`, such as
`law always positive is false for x = -128`. Specifications that compiled
before may therefore be rejected if a law over definitions is false.

The prover also handles constant factors on integer expressions (`x * 2`),
which it previously treated as non-linear, so more definition results are
proved.

### API

`evidence` items have the five statuses above and new stages: `law`,
`adapter`, and, with native bindings, `binding`, `codec`, `generator` and
`native-function`. `claim` is `null` for obligations without one. The
TypeScript API declares `ObligationEvidence` and `DischargeStatus`. See
[API migration](docs/explanation/api-migration.md#evidence-and-discharge-0150).

## 0.14.0

### Imports

```lawspec fragment
unit shop.orders
import shop.domain as domain (Money, Cents, `commutative`)
```

A unit imports other units by name. Every declaration of an imported unit is
available through the alias (`domain.Usd`, `domain.centsOf`), and listed names
also unqualified. Types, wrappers, indexed families, refinements, checked
definitions and generic laws can be imported. Adapters and concrete laws stay
with their unit. Import cycles, unknown units and missing or ambiguous names are
reported at the import, with the reason: an adapter, a constructor listed
without its type, or a law without parameters.

Names are scoped to their unit, so units compiled together no longer need
distinct constructor names. Targets with one data namespace (Python,
JavaScript, TypeScript, Go and Haskell) name colliding types after their unit,
`ShopDomainCurrency` and `ShopOrdersCurrency`, and their constructors
`ShopDomainCurrencyUsd`. Java, Kotlin and Rust qualify only the type. Earlier
versions qualified only the colliding names, for example
`ShopDomainTypeCurrencyUsd` next to `CurrencyEur`.

Imports are resolved before type checking, like indexed families and domain
models, so Core and the eight backends are unchanged.

### Packages

A `lawspec-package.json` names a package, its version, its source directories
and the version ranges of its dependencies. Package units are named after the
package, a unit imports only from its own package and direct dependencies, and
every range must accept the supplied version. A project lists `dependencies` and
the `packages` directories in `lawspec.json`. A package's adapters and laws are a
published contract: dependent projects implement and test them as their own.
`lawspec package` checks a package and summarizes it. See
[imports and packages](docs/reference/language/imports-and-packages.md).

The compiler API accepts `dependencies`, `packages` and `package`, and reports
the resolved packages (see
[API migration](docs/explanation/api-migration.md#imports-and-packages-0140)).

### Other changes

- Rust: a law without quantified inputs no longer emits an untyped empty case
  vector, which did not compile.
- The VS Code grammar highlights `import` and `as`.
- A new acceptance suite, `packages`, runs the
  [package example](examples/packages) on all eight targets in both machine
  profiles and rejects five adapter mutants plus the bare stubs. `lawspec-dev ci`
  includes it.

## 0.13.2

A maintenance release. The language, generated code and API are unchanged.

- The repository has no hosted CI. `stack run lawspec-dev -- ci` runs the
  complete check locally: compiler, npm, parity, package and editor checks, then
  for each target the dependency bootstrap, every acceptance suite in both
  machine profiles, and the installed native-binding example. It logs each step to
  `.artifacts/ci/` and exits non-zero on any failure. `--target`, `--core`,
  `--fail-fast`, `--rust-toolchains` and `--rust-targets` select what to run.
  `make ci` is equivalent.
- The JavaScript acceptance runners and fixture modules replaced by
  `lawspec-acceptance` are removed.
- The package smoke test's per-command timeout is ten minutes: exporting every
  bundled example had exceeded the former two-minute limit on slower machines.
- The integration bootstrap restores missing scaffold files in existing projects.

## 0.13.1

A maintenance release. The language, generated code and API are unchanged from
0.13.0.

- Repository checks move from JavaScript to Haskell. `lawspec-dev boundaries` and
  `lawspec-dev integrity` replace `tools/check-boundaries.mjs` and
  `tools/build-integrity.mjs`. The integrity check now also rejects staged npm
  copies of documentation and examples that differ from their sources.
- `lawspec-acceptance` runs the bundled-example acceptance suites
  (`integration`, `algebra`, `scalar`, `refinement`, `indexed`, `domain`) in
  process. Adapters and mutants are real files under `acceptance/`, and a
  mutant that only breaks the build now fails the suite. This exposed a
  TypeScript scalar mutant that previously counted as rejected because it
  failed type-checking; it now exercises the laws.
- Build-file scaffolds are defined once in Haskell (`LawSpec.Scaffold`) and
  checked against the npm templates byte for byte.
- Compiler API contract tests formerly in `npm/test` run in hspec against the
  same JSON boundary that `core.wasm` exports. A new npm test checks that
  generation never rewrites build files and that regeneration is a no-op on
  every target.

## 0.13.0

### Wrappers and constrained primitives

```lawspec fragment
wrapper UnitQuantity is Int32 where value >= 1 && value <= 1000 end
wrapper NonEmptyList (a :: Type) is List a where prelude.length value > 0 end
```

A wrapper declares a distinct nominal type with one field, `value`, and an
optional constraint. Its constructor checks the constraint, so an invalid value
cannot be constructed in an example (the compiler rejects `UnitQuantity 0`),
produced by a generator, or decoded from native code. `valueOf<Name>` unwraps a
value. Wrappers may take type parameters. They elaborate to a single-constructor
product with a refined field, so all eight targets represent them natively with
no new runtime machinery.

### Workflows and state distinctions

```lawspec fragment
workflow placeOrder :: UnvalidatedOrder -> Either OrderError PricedOrder is
  validateOrder :: UnvalidatedOrder -> Either OrderError ValidatedOrder
  priceOrder :: ValidatedOrder -> Either OrderError PricedOrder
end
```

A workflow declares its steps as adapters and checks the pipeline: each step
must accept the previous step's state, and fallible steps must share an error
type. The workflow's result must match `Either E T` when any step can fail, or
`T` otherwise. The compiler adds the law `placeOrder composes its steps`: the
native workflow must equal the railway composition of the native steps.
Diagnostics name the step and the mismatched types, with the workflow's source
location. See [domain modeling](docs/reference/language/domain-modeling.md).

### Evidence

Constructor field constraints, including wrapper constraints, appear in the
evidence as `construction` obligations with status `runtime-checked`, next to
the contract obligations introduced in 0.12. The TypeScript API declares these
records as `ObligationEvidence`; the 0.12 typing was not published.

### Examples and acceptance

`examples/specs/domain_modeling.lawspec` combines wrappers, a parameterized
`NonEmptyList`, order states and the workflow. It runs on all eight targets in
both machine profiles. Correct adapters pass; mutants that break a wrapper
invariant, the railway composition, or a non-empty list operation fail.

### Compatibility

`wrapper` and `workflow` begin new declarations. Specifications that do not use
them compile as in 0.12. API schemas 3 and 4 are unchanged, apart from the
additive `construction` stage in `evidence`.

## 0.12.0

### Proved indices

Checked definitions may return natural-indexed families, and the compiler
proves their result indices statically:

```lawspec fragment
definition concatV (xs :: Vec n Int8) (ys :: Vec m Int8) :: Vec (n + m) Int8 is
  match xs with
  | VNil -> ys
  | VCons h t -> VCons h (concatV t ys)
  end
end
```

The totality prover now treats calls of checked definitions as pure linear
atoms, so equal calls have equal results. A single-argument definition that
matches on its argument unfolds on a known constructor, so `nOfVec (VCons h t)`
is `nOfVec t + 1`. Natural measures are non-negative. Together with the existing
match facts and the induction hypothesis from recursive calls, this proves
definitions such as `concatV`, and tree flattening through nested calls. It
rejects definitions whose result indices do not follow, including an unchanged
length, a dropped element, an extra element and a wrong recursive argument.
See [proved indices](docs/reference/language/indexed-families.md#proved-indices).

### Evidence

Every contract obligation is recorded as `proved` or `runtime-checked`.
Definition postconditions are proved, and generated code on all eight targets no
longer re-checks them at runtime. Definition preconditions, which guard native
callers, and adapter contracts remain runtime-checked. `lawspec check` prints a
summary, and API responses include an additive `evidence` array; see
[API migration](docs/explanation/api-migration.md#evidence-0120).

The indexed example now includes proved definitions `concatV` and `flattenV`,
used as reference models for the native `append` and `flatten` adapters. The
eight-target acceptance runner executes them in both machine profiles and still
rejects every index-breaking adapter mutant.

### Compatibility

Specifications that compiled with 0.11 compile unchanged. Generated definition
code omits postcondition checks that are now proved, which changes generated
output but not behavior. API schemas 3 and 4 are unchanged apart from the
additive `evidence` field. Index equalities between sibling fields, non-linear
indices and type-refining GADTs remain open; see the
[current limits](docs/reference/language/index.md#current-limits).

## 0.11.0

### Natural-indexed families

Data declarations may take `Natural` parameters, and each constructor states
its index equation:

```lawspec fragment
type Vec (n :: Natural) (a :: Type) is
  | VNil where n = 0
  | VCons head :: a tail :: Vec m a where n = m + 1
end

append :: (xs :: Vec n Int8) -> (ys :: Vec m Int8) -> (r :: Vec (n + m) Int8)
```

A family elaborates before inference into ordinary erased data, a checked
structural measure per index (`nOfVec`), and a refinement relating the measure
to the index. Core and all eight emitters are unchanged. Native code works with
the erased type, and every index claim is evidence checked at test time: a
dependent result such as `Vec (n + m) Int8` is an adapter postcondition.

An index variable that is otherwise unbound is implicit. The first binder whose
family type mentions it determines it, and later occurrences read that binder's
measure. Index expressions are sums of natural literals and index variables.
`Natural` is also available as a value type. Diagnostics use the `indexed` code.
See [indexed families](docs/reference/language/indexed-families.md).

### Index-directed generation

A quantifier constrained by a linear structural measure, including a fixed index
(`Vec 3 Int8`) or a shared one (`zip`'s second argument), is generated by solving
the constructor equations backwards instead of filtering. Multi-field equations
such as `Bin … where n = l + r + 1` split the remaining index across fields.
Python, JavaScript, TypeScript, Java, Kotlin, Go, Haskell and Rust construct these
values natively, and framework shrinking stays within the index. The same
planning applies to user-written linear measures over declared data.

`examples/specs/indexed_families.lawspec` runs on all eight targets. Correct
adapters pass free, fixed and shared index laws; mutants that add, drop or lose
elements fail their dependent contracts.

### Tower-polymorphic Integer results restored

0.9 had narrowed Kotlin and Haskell adapters whose result is the abstract
`Integer` to `BigInteger` and `Integer`. They again return `Number` (Kotlin) and
`LS.IntegerValue` (Haskell), as in 0.8 and as Java always did. `Integer` is the top
of the integral tower: an implementation may return any integral native value,
and the result bridge rejects non-integral values and checks the logical domain.
Adapters written against 0.9 or 0.10 stubs that return `BigInteger` or `Integer`
still compile, because both are integral.

This regression had kept the Kotlin and Haskell target checks failing since
0.9. Those checks, and the scalar mutation fixtures, now pass with the documented
typed Symbol, Decimal, Utf16Text and Optional representations.

### Compatibility

Specifications without indexed families generate the same code as 0.10, apart
from the Integer result signatures above. API schemas 3 and 4 are unchanged.
GADTs that refine type arguments, non-linear indices and index equalities between
sibling fields remain future work.

## 0.10.0

### Existing application models

Native bindings connect LawSpec products and sums to existing application types
on Java, Python, JavaScript, TypeScript, Go, Haskell, Kotlin and Rust. Configure
constructor and field mappings, bind adapter declarations to existing functions,
or supply paired conversion hooks for representations requiring custom code.
Bindings resolve against typed declaration identities; they do not change the
meaning of arithmetic, equality, definitions or refinements. See
[Bind native types and functions](docs/how-to/bind-native-types.md).

Checked bridges compose through generic and recursive types and the built-in
containers. They preserve exact numeric values, Symbol identity and distinct
absence states. Invalid native inputs, results, generator samples and shrink
candidates fail with context.

### Native generators

Factories return their framework's generator: JetCheck, Hypothesis, fast-check,
Rapid, Hedgehog, Kotest or Proptest. Generic factories receive child generators.
Composition retains native shrinking. Explicit examples, deterministic boundaries
and finite-domain enumeration still run when the factory's distribution excludes
those values.

A factory can ignore an uninhabited parameter, as in `Phantom Empty`. Requesting a
value from that parameter fails generation; it cannot turn a property into a
vacuous success. Finite inhabited containers such as `List Empty` still enumerate.

Optional `stub: true` generator bindings create user-owned implementation files.
Regeneration preserves edits and reports changed factory signatures for review.

### API and migration

Native binding requests negotiate schema 4. Schema 3 remains supported for
specifications without bindings. Structured native references and strict
configuration validation prevent older compilers from silently ignoring mappings.
Go additionally supports explicit import aliases; Rust binds tests to the
application library's type identities.

Existing adapter files cannot be overwritten by adopting a binding. Move their
implementations into the application module and save the old adapters before
generation. Generated source bridges, test helpers and user-owned application
files retain separate placement and ownership. See the
[migration guide](docs/explanation/api-migration.md#native-bindings-schema-4-0100) and
[adopting bindings](docs/how-to/bind-native-types.md#adopt-bindings-in-an-existing-project).

### Runnable payment projects

`lawspec examples --example payments` exports a project for every target; use
`--target rust` or another language to select one. Each project includes an
application model, native generator, configuration, build files and instructions.
The shared specification checks exact fees, currency preservation, sum payloads,
ordered archives, duplicates and absence. Re-exporting preserves application
edits and the separate compiler generation manifest.

Both 32-bit and 64-bit logical machine profiles and readable/compact output are
covered by the acceptance matrices. Java 25+, Python 3.13+ and the other published
toolchain baselines remain unchanged. Python output follows PEP 8.

## 0.9.0

This release adds structural data and checked total definitions across Java,
Python, JavaScript, TypeScript, Go, Haskell, Kotlin and Rust.

### Language

- `List a` supports nested contextual literals, structural equality, exact
  length, deterministic boundaries, and native framework generation/shrinking.
- Algebraic `Maybe a` and `Either a b` provide `Nothing`/`Just` and `Left`/`Right`.
  They remain distinct from interoperability `Nullable` and `Optional` values.
- Named parameterized products and sums have constructors and ordered fields.
  Generated native types and typed adapters preserve their structure.
- Total definitions support exhaustive matching and checked structural recursion.
  The compiler rejects partial matches and recursion it cannot establish as
  terminating. Generic definitions specialize to their concrete uses.
- Refined definition signatures become executable native contracts. Scoped
  payload predicates preserve type-parameter roles through recursive and mutual
  data declarations, including predicates that depend on preceding inputs.

Existing scalar semantics remain intact: exact arithmetic does not wrap,
conversions to bounded adapter parameters are checked, floating equality follows
IEEE rules, and Symbol equality uses identity.

### Generated output

Readable code is the default for runtimes, declarations, definitions, adapters,
tests, and scaffolds. Explicit `--minify` selects compact output for `init`,
`generate`, and `examples`; the compiler API accepts `minify: true`.

Output follows Google language-specific guidance where applicable, PEP 8 for
Python, standard Go and Rust formatting, and an 80-column Haskell layout.
Formatting is deterministic in both native and WASM compilation and requires
no formatter download. Compact output preserves required layout, literal
contents, and semantics. Changing formatting mode does not overwrite edited
adapters or create false adapter-signature updates.

### API and compatibility

API schema 3 adds named data declarations, structural values, checked definitions,
construction/matching expressions, and scoped payload predicates. Existing scalar
wire encodings are unchanged. Exhaustive expression visitors must handle the
new variants; see [API migration](docs/explanation/api-migration.md#structural-data-and-definitions-090).

Java 25+, Python 3.13+, Node 22+, and Rust 1.85+ baselines remain unchanged.
Machine-width profiles, custom source/test directories, generation manifests,
and user ownership of adapters/build files remain supported. Framework-specific
strategies stay separate from reusable runtime source.

### Examples and release acceptance

Bundled examples cover reverse involution, sorting idempotence/sortedness/length/
permutation, nested presence, products/sums, exhaustive matches, total functions,
and recursive payload refinements. Release acceptance includes compiler and
native/WASM checks, native execution on all eight targets, deliberately incorrect
adapters, independent formatting/syntax checks, regeneration protection, and
installation of the packed npm artifact.

## 0.8.0

Rust support and a shared typed compiler boundary are the focus of this release.
The compiler remains implemented in Haskell and ships as prebuilt WebAssembly.

### Changes

- Rust 2024, with Rust 1.85 as the minimum toolchain, Cargo scaffolding, Proptest
  generation/shrinking, the complete scalar catalog, refinements, and contracts.
- An independent numeric Rust runtime with owned native bridges, exact arithmetic,
  checked conversions, direct IEEE rounding, raw text, Symbol identity, and
  distinct nested absence states. Proptest support is emitted separately.
- A typed core and proposition tree shared by all eight emitters. Resolved IDs,
  parsed source ranges, contextual literals, arithmetic evidence, and conversions
  survive elaboration. Emitters no longer import source syntax or inference.
- An independent core validator and evaluator. Testing plans distinguish semantic
  validity from execution feasibility and preserve dependent refinement domains.
- API schema v3 with explicit wire views and unchanged lossless scalar encodings.
  Explicit schema-v2 requests receive a migration diagnostic.
- Rust module wiring, custom layouts, Cargo preflight, adapter preservation,
  generation manifests, bundled examples, and installed-package coverage.
- Exact algebra and numeric currying examples. Logical `Integer` replaces their
  former modular Int32 contracts. Examples cover Int32 overflow, large products,
  Int32-minimum negation, and values beyond machine/safe-number bounds; deliberately
  wrapping adapters are rejected on every target.

See [Rust](docs/how-to/targets/rust.md), [the language reference](docs/reference/language/index.md),
[primitives](docs/reference/primitives.md), [refinements](docs/reference/refinements.md), and
[API migration](docs/explanation/api-migration.md#schema-2-to-schema-3-080).

### Compatibility and scope

Java 25+, Python 3.13+, and Node 22+ baselines remain unchanged. Existing LawSpec
source remains compatible. API clients must migrate to schema v3. All nonempty
plans emit scalar runtime source; existing Haskell projects need direct `text`
and `bytestring` dependencies in the component compiling that source. Build
files and implementation adapters remain user-owned.

Machine-sized domains use an explicit 32/64-bit profile. Native machine-sized
bindings reject an architecture mismatch. Rust adapters take owned values;
borrowing/lifetimes do not become LawSpec language constructs.
