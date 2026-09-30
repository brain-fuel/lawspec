# Generation and shrinking

A property test is only as good as its inputs. LawSpec plans inputs once, from
the typed Core, and every backend follows the same plan with its own framework.

## What a generated test runs

For each law, the testing plan combines:

1. **Examples**: the concrete inputs and expected results you wrote.
2. **Boundary cases**: deterministic values at the edges of each domain, such
   as integer minimum and maximum, empty and singleton lists, and special text.
3. **Exhaustive cases**: when the whole input domain has at most
   `exhaustiveLimit` values, every one of them.
4. **Generated cases**: otherwise, `cases` inputs from the framework's
   generators.

Examples and boundaries always run. Custom generators and narrow refinements
cannot remove them.

## Never pass vacuously

A property that checked no inputs has proved nothing, so LawSpec treats every
way of checking nothing as a failure:

- An input domain that is empty or unreachable fails; it does not pass.
- A generator that cannot find a valid input within `maxAttempts` fails with
  reproduction information. Exhausting a search does not prove the domain is
  empty, so it is never reported that way.
- A statically empty domain is a compile error, and so is an example outside
  its domain.
- A type with no values cannot supply an argument, although containers of it,
  such as `List Empty`, still can.

## Dependent refinements

A refined input can depend on earlier inputs, as in
`(y :: Int8 where y > Int8.max - x)`. Filtering random pairs would waste most
samples, and for some `x` no `y` exists at all. The planner instead:

- derives integer bounds from linear comparisons and conjunctions, and uses them
  to generate `y` directly in range;
- seeds comparison values and boundaries from the predicates;
- when an earlier choice leaves no valid continuation, goes back and chooses
  again, without counting the dead end as a pass;
- falls back to bounded sampling for predicates outside that analysis, always
  checking the full predicate.

A predicate that raises an error is a failure, not a rejection. Hiding errors as
rejected samples could turn a crash into a silently skipped case.

## Constructing instead of filtering

Some predicates are solved rather than sampled. A constraint `m x == e`, where
`m` is a linear structural measure over declared data, such as the length of a
list or the size of a tree, is met by building values backwards from the
constructor equations: a vector of length 3 is `VCons` on a vector of length 2.
[Indexed families](../reference/language/indexed-families.md) depend on this.
Sampling random vectors and keeping those of length 3 would almost never
succeed for larger lengths.

## Shrinking inside the domain

When a test fails, the framework shrinks the counterexample. LawSpec keeps the
framework's own shrinker, and makes sure every shrink stays valid:

- refinements are re-checked on every candidate;
- when an earlier input shrinks, later dependent inputs are repaired;
- recursive values shrink within their structural size budget;
- indexed values shrink within their index.

An overflowing pair can shrink to `(1, 127)` but never to `(0, 127)`, which is
outside the domain. Shrinking to an invalid input would report a failure that
the law does not actually claim.

## Structural size

Recursive data has a structural budget that counts each scalar, container and
constructor. Each constructor reserves the minimum its fields need before the
remainder is shared out, so every shape stays reachable and generation always
terminates. List lengths and element budgets vary together, so deep singletons
are possible and there is no hidden length cap.

## Custom generators

A [native generator binding](../how-to/custom-codecs-and-generators.md) replaces
the generated distribution for a type with your own. The tests still compose
your generator natively, so its shrinker is kept; validate every sample and
shrink; filter by refinements; and run examples, boundaries and exhaustive
cases as before. A finite domain is enumerated without calling your factory.

## Framework differences

Each framework has its own filtering and shrinking model, so the limits map
differently: JetCheck caps a filter at 100 attempts, Rapid at five, and
Hedgehog uses separate test, discard and shrink limits. The details are in the
[refinement reference](../reference/refinements.md#target-generation-limits).
No framework promises the smallest possible counterexample.
