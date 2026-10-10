---
id: lawspec.reference.language.harness
kind: reference
title: Harness units
---
# Harness units

A unit's laws say what the program must satisfy. A *harness* says how those
laws are tested: which handlers the tests run against, how inputs are drawn,
how many cases are enough, and how the tests run. It lives on its own
plane, and it can never change what a law means.

See [Abilities, and laws kept apart from the harness](../../explanation/abilities.md)
for why the two planes are kept apart.

```lawspec
unit guide.shop

type Order is Order items :: Int32 total :: Int32 end

definition itemsOf (order :: Order) :: Int32 is
  match order with | Order items total -> items end
end
definition totalOf (order :: Order) :: Int32 is
  match order with | Order items total -> total end
end
definition isEmpty (order :: Order) :: Bool is itemsOf order == 0 end

discount :: Order -> Int32

law `a discount is never more than the total` is
  definition is
    `for all` (order :: Order where itemsOf order >= 0 && totalOf order >= 0) .
      (discount order <= totalOf order) = true
  end
end

harness guide.shop.testing for guide.shop is
  strategy smallOrder :: Order is
    bind items :: Int32 from (one of 0, 1, 2, 3) in one of Order items (items * 100)
  end
  strategy bulkOrder :: Order is
    any such that itemsOf it > 10 && totalOf it >= 0 at most 1000 discards
  end
  strategy orders :: Order is frequency 9 smallOrder, 1 bulkOrder end

  tags pricing

  for law `a discount is never more than the total`
    use orders for order
    cover 5% "empty order" when isEmpty order
    classify totalOf order > 1000 as "large"
    label if isEmpty order then "empty" else "some items"
    timeout 10 s

  benchmark `discount of a bulk order` is discount (Order 30 50000) end
end
```

## Which plane a thing belongs to

| Law plane (the unit) | Harness plane (the harness) | Toolchain (`lawspec.json`, the CLI) |
| --- | --- | --- |
| laws, examples, definitions, types | strategies: how inputs are drawn | report paths: `--report junit=…` |
| abilities and handlers | `test with`: which lawful handlers tests use | coverage: `--coverage` |
| `using`: a handler that is part of the claim | adequacy: `cover`, `classify`, `label`, `target maximize` | the failure database, `.lawspec/failures` |
| resources, and whether they can `reset` | run metadata: `tags`, `skip`, `known failing`, `timeout`, `repeat`, `retry flaky`, `order random`, `parallel` | selection: `--tag`, `--exclude-tag` |
| refinements of inputs | `share R per group \| unit \| run` | native handler bindings |
| performance budgets | `benchmark`: measured, never asserted | |

The rule: **a law says what must hold for every lawful handler and every
input.** Anything that only chooses *which* handlers and inputs the tests try,
or how the tests run, belongs to the harness.

## Declaring a harness

```lawspec fragment
harness name for unit is
  item ...
end
```

- A harness serves exactly one unit, the one named after `for`. A unit has at
  most one harness.
- It can be written in a file of its own (the file starts with `harness`), or
  after the unit's members in the unit's own file.
- It may refer only to the laws, handlers and resources of the unit it serves,
  and to the types and checked definitions that unit can see.
- It may not declare laws, definitions, abilities, handlers, types,
  refinements, resources or signatures. Each is a compile error: "a harness
  cannot declare a law: …".
- A setting that carries an expression (`cover`, `classify`, `label`,
  `target maximize`) ends at the end of its line.

Items:

| Item | Meaning |
| --- | --- |
| `strategy name :: T is gen end` | A way to draw values of `T`. |
| `for law \`a\`` | Settings for one law, on the lines after it. |
| `for laws \`a\`, \`b\`` | Settings for a group of laws. |
| any setting below, before the first `for` | The setting for every law of the unit. |
| `share R per group \| unit \| run` | Share a resource between laws. |
| `benchmark \`name\` is e end` | Measure an expression. |
| `order random` | Run the unit's law tests in an order chosen by the run's seed. |
| `parallel` | Let the unit's law tests run at the same time. |

A law named in a `for` block is the law as written: `for law \`charges once\``
applies to each of its handler variants, `charges once [native]` and
`charges once [fakeGateway]`, and an ability's law applies to its copy for
each handler.

## Strategies

```lawspec fragment
strategy name :: T is gen end
```

A strategy draws values of its type. Its forms:

| Form | Draws |
| --- | --- |
| `any` | The default, refinement-directed generator of the type. |
| `any T` | The default generator of `T` (inside `bind`). |
| `one of e1, e2, …` | One of these values, each as likely. |
| `frequency w1 g1, w2 g2, …` | `g1` with weight `w1`, and so on. |
| `g such that p` | A value of `g` for which `p` holds; `p` names the value `it`. |
| `g such that p at most n discards` | The same, allowing at most `n` rejected values before failing the run (default 100). |
| `bind x :: S from g in g'` | `x` from `g`, then a value of `g'`, which may use `x`. |
| `name` | Another strategy of the harness. |
| `( gen )` | Grouping. |

Within `frequency`, an alternative that is not a name or `any` is written in
parentheses: `frequency 3 (one of 0, 1), 1 any`.

A strategy's type may be an inline refinement. Its values are then kept
only when they satisfy it, as `such that` keeps them (at most 100 discards).
`any` of the strategy's type aims at the refinement the way a law input's
generator aims at the input's: constant integer bounds in the refinement
(`n >= 1 && n <= 10`) narrow the range `any` draws from, so it does not
draw the whole type and discard most of it. What the bounds do not capture
is still checked:

```lawspec fragment
strategy small :: (o :: Order where itemsOf o <= 3) is any end
strategy digits :: (n :: Int32 where n >= 0 && n <= 9) is any end
```

A strategy is used for one input of one law:

```lawspec fragment
for law `a discount is never more than the total`
  use orders for order
```

The compiler checks that the strategy's type is the input's type, and that
strategies are not recursive. A reference to another strategy retains that
strategy's declared type and refinement, including inside `frequency` and
`bind`. A referenced strategy has its own local bindings; it does not capture
the caller's bound variables. When the tests run, every value a strategy draws
is checked against the input's refinements (`where …`): a value outside them is
a failure of the harness ("the strategy orders produced … for order, which is
outside the input's refinement"), never a reason to skip the case. A strategy
can choose which values are tried; it cannot widen what the law is about.

The strategies draw through each target's own property-testing library, so a
failing case still shrinks: Hypothesis (Python), fast-check (JavaScript and
TypeScript), rapid (Go), JetCheck (Java), Kotest (Kotlin), Hedgehog (Haskell)
and proptest (Rust, which draws the strategy from a seed proptest chooses).

## Handlers: `test with`

```lawspec fragment
test with fakeGateway, native
```

Without a harness, a law that uses an ability runs once for each lawful
handler: the native production handler, then each spec handler. `test with`
narrows that choice to the handlers it names (`native` is the production
handler), for each ability that has one of them.

- It never changes a handler a law names with `using`: that handler is part
  of the law's claim.
- A handler variant it leaves out is still an obligation. Evidence reports it
  as `skipped`, with the reason, and its test is reported as skipped.

## Adequacy

| Setting | Meaning |
| --- | --- |
| `cover p% "label" when e` | At least `p` percent of the generated cases must satisfy `e`. A run that falls short fails. |
| `classify e as "label"` | Report the share of cases that satisfy `e`. |
| `label e` | Report the share of cases for each value of `e` (a `Text`). |
| `target maximize e` | Steer generation toward cases where `e` (a number) is larger. |

These expressions are over the law's inputs, and may call checked definitions
only: calling native code or an ability could change what the law observes.
They count only generated cases, not examples or boundary cases.

On Erlang, Elixir and Gleam, each accepted initial draw counts once. Rejected
tuples, shrinking and failure rechecks do not increase the count. Repeated
classifications or labels with the same text count a case once; separate
`cover` clauses have independent counters, even when their labels match.
An exhaustive law has zero generated cases, so it cannot satisfy a `cover`
clause, including one requiring zero percent. Coverage is decided from exact
counts; rounded display percentages cannot turn a shortfall into a pass.

`target maximize` steers generation on every target. On Python, Hypothesis
searches for higher scores itself. The other targets' libraries have no
targeted search, so LawSpec climbs after the property test: it generates
inputs from the run's seed, keeps the best-scoring case, and moves its
integers (one step, doubling, halving the distance to a bound) while the
score rises, drawing afresh when it does not. Every case it tries is checked
against the law, at most 400 of them, and the best score is printed. A law
whose inputs have no [wire descriptor](../cli.md#the-failure-database) (a
float, a handle, a generic data type) is not climbed.

The BEAM targets keep integer, decimal and rational scores exact, including
integers beyond the precision of a native float. A floating-point NaN cannot
be a best score. Targeted search checks the input refinements before running
the law, reports its trials separately, and does not change property coverage.

Each property test prints its statistics, and `lawspec test` keeps them:

```text
example.harness::a discount is never more than the total: 100 generated case(s)
  cover 5% "empty order": 22.0%
  large: 4.0%
  label empty: 22.0%
  label some items: 78.0%
```

## Run metadata

| Setting | Meaning |
| --- | --- |
| `tags a, b` | Tags for selecting laws: `lawspec test --tag a --exclude-tag b`. |
| `skip "reason"` | Run none of the law's tests. The law is still an obligation, reported as `skipped`. |
| `known failing "reason"` | The law's tests must fail. If they pass, the run fails: "… is marked known failing (…), but it passes; remove `known failing` from its harness". Evidence reports `known-failing`. |
| `timeout 2 s` | Fail a test that takes longer (`ms`, `s` or `min`), in real time, even for a law `using virtual clock`: a virtual clock moves only when the law moves it, so a stuck law would never time out by it. |
| `repeat n` | Run each test `n` times; every run must pass. |
| `retry flaky n` | Run a failing test again, up to `n` times. A test that then passes is reported as flaky, and evidence shows `flaky` until a clean run. A harness failure (an unmet `cover`, a strategy's value outside the refinement) is never retried. |
| `order random` | (unit) Run the law tests in an order chosen by the run's seed. |
| `parallel` | (unit) Let the law tests run at the same time. |

`known failing` cannot be put on a law the compiler proves or evaluates
itself: such a law is either true or a compile error.

On Erlang, Elixir and Gleam, `repeat` applies separately to each example,
exhaustive or boundary case, native property check, and targeted search.
A retry restarts that test's repeat sequence. Every
repetition has fresh coverage counters and must meet its own coverage
requirements; counts from different repetitions cannot hide a shortfall.
Statistics keep the final run's counts and a `runs` list with the outcome
and observations of each attempt and repetition. A successful retry has
the outcome `flaky`. Invalid strategy values and exhausted strategy discard
limits fail without retrying.

On these three targets, `timeout` bounds one such repetition, including its
native generation and shrinking. It stops the test worker and joins its
LawSpec asynchronous children. Resource owners then finish cleanup within
their separate [cleanup allowance](resources.md#beam-ownership-and-cancellation).
A timeout or cleanup failure is a harness failure: it cannot be retried or
accepted by `known failing`. Native runner timeouts include extra room for
the configured repetitions and cleanup.

On BEAM, a known-failing law runs its checks until the first law failure.
Its report includes the checks it attempted and the original failure.
Generator errors and unmet coverage requirements remain harness failures;
they cannot satisfy a known-failing annotation. If all checks pass, including
after configured retries, the run fails and asks you to remove the annotation.
The shared search policy excludes known-failing laws from extra targeted
searches; their native property cases still report target scores.

Elixir reports skipped laws with ExUnit's native skip tag. Erlang and Gleam
use EUnit, which has no public intentional-skip descriptor: LawSpec prints
`SKIPPED` with the reason and writes a skipped statistics record, while
returning an empty test group. These laws do not increase the native pass
count. No skipped example, generator, adapter or resource acquisition runs.

LawSpec owns how a unit's tests are scheduled: each runtime has a small
harness driver, and the target's test framework only hosts and reports the
tests. `order random` is seeded by the run's seed (`--seed`, which
`lawspec test` passes as `LAWSPEC_SEED`; otherwise one is chosen), printed
as "order random seed N … LAWSPEC_SEED=N replays this order", and the same
seed gives the same order:

| Target | `order random` | `parallel` |
| --- | --- | --- |
| Python | the driver's `pytest_collection_modifyitems`, in a generated `conftest.py` | pytest-xdist processes when `lawspec test` finds it installed; otherwise the driver runs the unit's tests on a thread pool |
| JavaScript, TypeScript | the tests are registered in the seeded order | node:test runs the unit's tests concurrently, and `lawspec test` runs test files concurrently |
| Go | `-test.shuffle` with the seed, set in `TestMain` | `t.Parallel()` |
| Java | a seeded `MethodOrderer` (`LawSpecOrder`) | JUnit's concurrent mode, enabled in a generated `junit-platform.properties` |
| Kotlin | the tests are registered in the seeded order | Kotest concurrency, a thread per processor |
| Rust | each test waits for its seeded turn (stable libtest cannot shuffle) | libtest's test threads; with `order random` too, tests start in order, then overlap |
| Haskell | each law's tests in one block, the blocks in the seeded order | hspec's `parallel`, on the threaded runtime (`-with-rtsopts=-N`) |
| Erlang, Gleam | law blocks in seeded order through native EUnit descriptors | EUnit runs individual cases in separate BEAM processes |
| Elixir | selected law blocks in seeded order through the LawSpec driver | a bounded BEAM process pool; each named ExUnit test receives its original result |

The BEAM drivers apply native selection before scheduling. Examples,
boundaries and properties keep their native test names, and each executing
case has its own handler and property-framework state, and borrows resources
from their dedicated owners. The recorded
worker count is the peak number of live case processes. With `order random`
and `parallel` together, the seed controls dispatch order; overlapping
operations can still finish in a different order.

Each runtime records the parallelism it achieved, and `lawspec test` prints
it ("parallel example.shop: threads …, 8 worker(s)"). The genuine platform
limits:

- **Python**: without pytest-xdist, threads run truly in parallel only on
  free-threaded CPython (3.13t and later); under the GIL they interleave, so
  sleeps and I/O overlap but computation takes turns. The record says which.
- **JavaScript and TypeScript**: one process runs the unit's tests
  concurrently, so asynchronous laws overlap and synchronous ones take turns
  on the event loop.

`parallel` cannot change what laws observe: each test has its own handler
table, and a resource shared under `parallel` must be declared
`resource T is concurrent` (cases cannot interfere through it), or the
compiler rejects the harness.

Every harness setting holds on every target:

| Setting | Python | JS, TS | Go | Java | Kotlin | Rust | Haskell |
| --- | --- | --- | --- | --- | --- | --- | --- |
| strategies | yes | yes | yes | yes | yes | yes | yes |
| `cover`, `classify`, `label` | yes | yes | yes | yes | yes | yes | yes |
| `target maximize` | yes (Hypothesis) | yes (LawSpec climbs) | yes (LawSpec) | yes (LawSpec) | yes (LawSpec) | yes (LawSpec) | yes (LawSpec) |
| `tags`, `skip`, `known failing` | yes | yes | yes | yes | yes | yes | yes |
| `timeout`, `repeat`, `retry flaky` | yes | yes | yes | yes | yes | yes | yes |
| `order random` | yes | yes | yes | yes | yes | yes | yes |
| `parallel` | yes (see above) | yes (see above) | yes | yes | yes | yes | yes |
| `share` | yes | yes | yes | yes | yes | yes | yes |
| benchmarks | yes | yes | yes | yes | yes | yes | yes |
| failing inputs replayed | yes | yes | yes | yes | yes | yes | yes |

The `scheduling` acceptance suite checks, on all eight targets, that the
same seed gives the same order and other seeds other orders, and that a
`parallel` unit's laws overlap.

## Sharing resources

```lawspec fragment
share Database per unit
```

A resource a law takes as an input is acquired and released for each case.
`share` lets laws share one, per `group` (a `for laws` block), `unit` or
`run`. It is allowed only for a resource that declares `reset`: otherwise one
law would observe what another left behind, which would change what laws
observe. Sharing a resource without `reset` is a compile error.

At run time the first case acquires the resource; each later case in the
scope waits until no other case holds it, resets it, and uses it; it is
released when the test process ends. See
[Resources](resources.md#sharing-a-resource).

## Benchmarks

```lawspec fragment
benchmark `discount of a bulk order` is discount (Order 30 50000) end
```

A benchmark measures an expression with each target's lightest monotonic
timer, the real clock the `Clock` ability's default handler also reads (Go
uses `testing.Benchmark`), and reports the mean and fastest time; what it
calls that uses `Clock` runs under the default (real) handler, never a
virtual one. It is never
asserted: a performance requirement belongs in a law, as a budget. A
benchmark may call adapters and checked definitions, and what it calls may
use abilities: it runs under each ability's production handler (the one
bound in `lawspec.json`, the native one, or the runtime's default), installed
around it. Benchmarks run with the target's own test command, and with
`lawspec test --benchmarks`.

On Erlang, Elixir and Gleam, the measurement uses BEAM's monotonic
nanosecond timer, takes at least three samples, and stops after about
200 ms or 100,000 iterations. The time budget is checked between complete
iterations. A returned `false` is still a measured value; an exception
fails the native benchmark and produces no completed timing record.
The statistics include the unit as well as the original benchmark label.
Benchmarks also work in a unit with no laws, and labels that normalize to
the same native identifier receive distinct names for selection.

## Test names

Generated tests are named after law labels, as identifiers each target
accepts, unique within a unit:

| Target | `a discount is never more than the total` |
| --- | --- |
| Python | `test_a_discount_is_never_more_than_the_total__property` |
| Go | `TestADiscountIsNeverMoreThanTheTotal_Property` |
| Java, Kotlin, Haskell | `lawADiscountIsNeverMoreThanTheTotal_property` |
| Rust | `law_a_discount_is_never_more_than_the_total` |
| JavaScript, TypeScript | `example.shop::a discount is never more than the total property` |

A law's examples and boundary cases add `example0`, `boundary0` and so on.
A law with generated cases also has a `replay` test, which replays the
failing inputs the [failure database](../cli.md#the-failure-database) kept
(Java and Rust replay at the start of the property test instead), and a law
with `target maximize` a `search` test, LawSpec's climb (Java and Rust climb
at its end). The
test manifest (`tests` in a generation result) carries each law's name, tags,
`skip` and `knownFailing`, which `lawspec test` uses to select tests.

## Evidence

`lawspec evidence` keeps the two planes apart. Each law's obligation comes
from the law; how it was discharged comes from the harness, shown after the
obligations, with the last run's adequacy. The harness adds three statuses:
`known-failing`, `flaky` and `skipped`. See
[Evidence and discharge](evidence-and-discharge.md).
