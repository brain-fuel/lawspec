---
id: lawspec.explanation.generation-and-shrinking
kind: explanation
title: Generation and shrinking
---
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

In the canonical profile, [complete integer ranges](../reference/language/rc1.md#complete-integer-ranges)
include domains made finite by restrictions and fixed-width intervals depending
on earlier inputs. Every candidate is checked against all its restrictions.
This complete enumeration is separate from bounded sampling: exceeding the
expansion limit supplies no proof of nonexistence.

Canonical [scoped witness strategies](../reference/language/rc1.md#bounded-witness-strategies)
use a bounded deterministic schedule alongside complete finite search. Their
restrictions are checked with the current enclosing inputs on every attempt
and every outer shrinking recheck. A bounded miss remains inconclusive, even
when all configured candidates were tried. Individual witness-value shrinking
and concrete search traces remain separate implementation work.

Examples and boundaries always run. Custom generators and narrow refinements
cannot remove them.

## Never pass vacuously

A property test that checked no inputs supplies no verification evidence.
A generator that cannot find a valid input within `maxAttempts` reports the
bounded search failure with reproduction information. Exhausting that search
does not prove the domain empty. Examples outside their input domain are
rejected. A type with no values cannot supply an argument, while containers
such as `List Empty` can still contain the empty list.
ref:DEC-never-pass-vacuously

In the canonical `1.0-rc.2` profile, universal propositions retain their
mathematical meaning over empty domains. When the compiler establishes that
the entire input domain is empty, selected proof or exhaustive verification
reports that fact explicitly, with zero evaluated cases and no produced
witnesses. Property testing alone reports `incomplete` because no cases ran.
The execution plan supplies no generators or boundary cases for this domain.
Examples still require valid inputs. Failure to generate a sample within a
budget never establishes emptiness. See the
[RC1 logical contract](../reference/language/rc1.md) for nested quantifiers and
incomplete search.

## Refinement bounds

When a refinement puts constant bounds on an integer, as in
`(amount :: Int32 where amount >= 1 && amount <= 1000)`, generation draws
from that range instead of filtering every `Int32`. This holds on every
target, for one input or many. The refinement is still checked on every
value, so a refinement with more than bounds (`amount mod 7 == 0`) narrows
first and then filters.

## Texts a regex describes

When a refinement says a text matches a regex, as in
`(t :: Text where t matches regex "[a-z0-9._-]+")`, or calls a checked
definition whose body says so (`(t :: Text where validTopic t)`), generation
starts from texts the regex matches: the compiler samples them from the
regex, varied in their choices and lengths, and every target draws among them
and uses a few as boundary cases, also when the law has record or list
inputs beside the text. Almost no random text matches a regex, so
filtering would reject nearly every draw. The whole refinement is still
checked on every value.

## Dependent refinements

A refined input can depend on earlier inputs, as in
`(y :: Int8 where y > Int8.max - x)`. Filtering random pairs would waste most
samples, and for some `x` no `y` exists at all. The planner instead: ref:DEC-planned-generation

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
succeed for larger lengths. ref:DEC-planned-generation

## Shrinking inside the domain

When a test fails, the framework shrinks the counterexample. LawSpec keeps the
framework's own shrinker, and makes sure every shrink stays valid: ref:DEC-shrink-within-domain

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
are possible and there is no hidden length cap. ref:DEC-structural-size-budget

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
