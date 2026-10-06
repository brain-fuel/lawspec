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
| `g such that p at most n discards` | The same, failing the run after `n` values that do not satisfy `p` (default 100). |
| `bind x :: S from g in g'` | `x` from `g`, then a value of `g'`, which may use `x`. |
| `name` | Another strategy of the harness. |
| `( gen )` | Grouping. |

Within `frequency`, an alternative that is not a name or `any` is written in
parentheses: `frequency 3 (one of 0, 1), 1 any`.

A strategy's type may be an inline refinement. Its values are then kept
only when they satisfy it, as `such that` keeps them (at most 100 discards):

```lawspec fragment
strategy small :: (o :: Order where itemsOf o <= 3) is any end
```

A strategy is used for one input of one law:

```lawspec fragment
for law `a discount is never more than the total`
  use orders for order
```

The compiler checks that the strategy's type is the input's type, and that
strategies are not recursive. When the tests run, every value a strategy draws
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

`target maximize` steers generation on every target. On Python, Hypothesis
searches for higher scores itself. The other targets' libraries have no
targeted search, so LawSpec climbs after the property test: it generates
inputs from the run's seed, keeps the best-scoring case, and moves its
integers (one step, doubling, halving the distance to a bound) while the
score rises, drawing afresh when it does not. Every case it tries is checked
against the law, at most 400 of them, and the best score is printed. A law
whose inputs have no [wire descriptor](../cli.md#the-failure-database) (a
float, a handle, a generic data type) is not climbed.

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
| `timeout 2 s` | Fail a test that takes longer (`ms`, `s` or `min`). |
| `repeat n` | Run each test `n` times; every run must pass. |
| `retry flaky n` | Run a failing test again, up to `n` times. A test that then passes is reported as flaky, and evidence shows `flaky` until a clean run. A harness failure (an unmet `cover`, a strategy's value outside the refinement) is never retried. |
| `order random` | (unit) Run the law tests in an order chosen by the run's seed. |
| `parallel` | (unit) Let the law tests run at the same time. |

`known failing` cannot be put on a law the compiler proves or evaluates
itself: such a law is either true or a compile error.

`order random` and `parallel` hold on every target:

| Target | `order random` | `parallel` |
| --- | --- | --- |
| Python | the tests are registered in a seeded order | pytest-xdist (`-n auto`), when `lawspec test` finds it installed; without it the tests run one after another, and `lawspec test` says so |
| JavaScript, TypeScript | registered in a seeded order | one `describe` suite with `concurrency: true` |
| Go | `-test.shuffle` with the run's seed, set in `TestMain` | `t.Parallel()` |
| Java | JUnit's random method order | JUnit's concurrent mode, when enabled in its configuration |
| Kotlin | Kotest's random order | Kotest's `concurrency`, one thread per processor |
| Rust | each law test waits its turn; the seed ranks the tests waiting | libtest runs tests in parallel already (a unit with `order random` runs them one at a time) |
| Haskell | each law's tests in one block, the blocks shuffled with the seed | hspec's `parallel` |

The seed is the run's (`LAWSPEC_SEED`, which `lawspec test` sets), so an
order can be repeated.

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

A benchmark measures an expression with each target's lightest timer (Go
uses `testing.Benchmark`), and reports the mean and fastest time. It is never
asserted: a performance requirement belongs in a law, as a budget. A
benchmark may call adapters and checked definitions, and what it calls may
use abilities: it runs under each ability's production handler (the one
bound in `lawspec.json`, the native one, or the runtime's default), installed
around it. Benchmarks run with the target's own test command, and with
`lawspec test --benchmarks`.

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

## Not yet

- `any` in a strategy of a refined type draws the base type and discards
  what the refinement rejects; it does not yet aim at the refinement.
