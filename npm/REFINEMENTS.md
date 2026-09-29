# Refinements and abstract integers (0.11.0)

A refinement restricts a scalar domain with a pure Boolean expression. LawSpec
checks concrete examples, generates satisfying input tuples, and checks adapter
contracts during testing. It does not prove that an adapter is correct.

## Exact integers without a storage width

`Integer` is the mathematical integer domain. Integer literals default to it;
integer addition, subtraction, multiplication, negation, quotient, and remainder
produce it. Calculations use arbitrary precision internally. `BigInt` remains
available when a concrete arbitrary-precision adapter representation is wanted.

```lawspec
unit example.increment
successor :: (x :: Int8) -> (result :: Integer where result == x + 1)
```

This signature generates contract tests without a separate law. The maximum
input, `127`, requires the value `128`. Returning a wrapped `-128` fails.
`Integer` does not assert which storage width the implementation used.

Abstract integer results accept Python `int` (excluding `bool`), JavaScript or
TypeScript `bigint` and safe integral `number` values, Java/Kotlin standard signed
integral wrappers and `BigInteger` through `Number`, and Go signed/unsigned integer
values or `big.Int` values/pointers through `any`. Floating representations are
rejected even when their current value is integral. Haskell uses `IntegerValue`:

```haskell
successor :: Int8 -> IntegerValue
successor x = integerValue (toInteger x + 1)
```

`integerValue :: Integral a => a -> IntegerValue` erases the width losslessly.
Abstract integer arguments use the target's arbitrary-precision integer type.
Concrete signatures keep their existing checked native mappings.

## Inline and named refinements

Use `where` on a quantified input, function argument, or function result:

```lawspec
`for all` (x :: Int8) (y :: Int8 where y > Int8.max - x) .
  add x y = x + y
```

A predicate can reference its own value and earlier inputs. A function result
predicate can also reference the function's named arguments. Forward value
references are errors. `Int8.min` and `Int8.max` denote representation bounds;
machine-sized bounds use the requested `machineBits` profile.

Named refinements distinguish type parameters from value parameters:

```lawspec
refinement Between
  (T :: Type) (minimum :: T) (maximum :: T)
  requires Ordered T is
  (value :: T where minimum <= value && value <= maximum)
end

refinement AdditionOverflows
  (T :: Type) (left :: T)
  requires Integer T Bounded T is
  (right :: T where left + right > T.max)
end

add :: (x :: Int8)
    -> (y :: AdditionOverflows Int8 x)
    -> (result :: Integer where result == x + y)
```

`(x :: Between Int8 1 10)` applies a refinement. Parenthesize compound arguments,
for example `Between Int8 (-10) (5 + 5)`. Later value-parameter types can use
earlier parameters. Value arguments must satisfy their declared domains,
including refinements. Substitution avoids capturing names from the call site.
Declarations can appear in any order within a unit; recursive aliases are errors.
Fixed refinements are the zero-parameter form:

```lawspec
refinement PositiveInt8 is (value :: Int8 where value > 0) end
```

Aliases preserve their underlying native representation. They can be nested in
`Nullable` and `Optional`; inner predicates are checked only for present values.
Type parameters range over supported value types, including structural types.
Their declared capabilities determine which operations are available.

`requires Integer T` describes integer capabilities in a generic declaration.
`Integer` entails `Eq` and `Ordered`. `Ordered` currently covers exact real numbers
and floats, with the existing IEEE comparisons (including NaN behavior).
`Bounded` covers fixed and machine-sized integers. Bounds refer to the underlying
integer representation, rather than a tighter interval inferred from a predicate.
Capabilities are checked on generic declarations and their specializations.

## Predicate expressions and contracts

Predicates support existing pure arithmetic, comparisons, scalar constructors,
conversions, and built-in helpers. `&&`, `||`, and `!` short-circuit; comparisons
bind more tightly than `&&`, which binds more tightly than `||`. Assertion `and`
continues to combine law conclusions. Exact/inexact mixing still needs an explicit
conversion, and floating expressions retain their declared precision.

`prelude.length` counts Unicode scalars for Text, code points for CodePointText,
UTF-16 units for Utf16Text, and octets for Bytes. `prelude.isPresent` and
`prelude.presentValue` inspect tagged presence values; guard extraction with
`isPresent` before accessing a possibly absent value.

Adapter calls are forbidden in refinements. Predicate errors such as division by
zero are reported as failures when evaluated; they are not ordinary rejection of
an input. Short-circuited branches are not evaluated by generation optimizations.

In the 0.9 frontend, predicates can call checked total definitions, including
generic definitions specialized to the predicate's concrete types:

```lawspec
definition nonempty (xs :: List a) :: Bool is
  match xs with
    | Nil -> false
    | Cons head tail -> true
  end
end

refinement Nonempty (T :: Type) is
  (xs :: List T where nonempty xs)
end
```

The same closed definitions evaluate example inputs, constant refinement
arguments, finite domains, and boundaries, and run in generated predicate and
contract checks on all eight targets. Calls to adapters cannot enter that closed
environment. Definitions can also refine their own parameters and results.
Their bodies must be proved total under the ordered input preconditions, and
every result refinement must follow from the body.

Every refined adapter signature creates a standalone property. Calls from other
laws also check argument preconditions, invoke the adapter once, snapshot its
result, and check postconditions. Calling a function outside its precondition is
a test failure, not a discarded example. Ordinary `implies` guards retain their
existing conditional behavior.

## Dependent generation and shrinking

A quantified law ranges over satisfying tuples. For `AdditionOverflows Int8 x`,
`x = 0` has no admissible `y`. The generator backtracks to choose another `x`;
it does not count that dead end as a passing test. Valid pairs satisfy:

```text
1 <= x <= 127
128 - x <= y <= 127
```

The generator derives integer bounds from affine comparisons and conjunctions,
seeds direct comparison values and boundaries, and checks the complete predicate.
Predicates outside that analysis use bounded sampling. Small finite base-domain
products are enumerated exhaustively, retaining only satisfying tuples.

A refinement `m x == e` over declared data, where `m` is a linear structural
measure (each branch is a constant plus `m` of that branch's fields), is solved
rather than sampled: values are constructed with measure exactly `e`. Indexed
families rely on this; see [natural-indexed families](LANGUAGE.md#natural-indexed-families).

Shrinking checks refinements again and repairs dependent later inputs when an
earlier value changes. An overflowing counterexample can shrink to `(1, 127)`;
it cannot shrink to `(0, 127)` because that pair is outside the domain.

Compiler requests and `lawspec.json` accept:

```json
{
  "generation": {
    "cases": 100,
    "maxAttempts": 10000,
    "maxShrinks": 1000,
    "exhaustiveLimit": 4096
  }
}
```

All limits are positive integers. These are the defaults for refinement properties.
`cases` counts accepted property inputs; explicit examples and boundary fixtures
are additional checks. Exhausted searches report an error with reproduction
information. Exhaustion does not prove that the mathematical domain is empty.
Statically established empty executable domains and invalid examples are rejected.

See [the bundled examples](examples/specs/refinements.lawspec) for overflow,
abstract integer arguments/results, dependent bounds, optional refinements,
floating classification, and raw-byte lengths.


## Refined definitions

```lawspec
definition increment (x :: Int8 where x < 127)
  :: (result :: Int8 where result > x)
is
  prelude.Int8 (x + 1)
end
```

Arithmetic promotes before the explicit Int8 conversion. The compiler proves
that the precondition makes the conversion safe and that the result exceeds x.
Later parameters may depend on earlier parameters. Result binders must differ
from argument names.

Generic definitions retain their contracts through specialization. Templates,
including unused ones, must pass type, capability, termination and definedness
checks before concrete instances are emitted. Each closed call must satisfy its
callee's preconditions. Contracts cannot depend cyclically on their definitions
or call adapters. A claim the proof checker cannot establish is rejected.

The reference evaluator and all eight native backends validate arguments, check
preconditions in order, evaluate the body, validate its result, and check
postconditions. An invalid native call fails before unsafe body arithmetic.
Definitions are proved during compilation; adapter contracts instead generate
standalone properties because their implementations are external.

See [refined definitions](examples/specs/refined_definitions.lawspec) for generic
reciprocals, checked narrowing and dependent bounds. Both the native compiler
and packaged WASM build support these contracts.

The native definition-contract harnesses accept `LAWSPEC_CONTRACT_SOURCE=1`.
This compiles `test/fixtures/definition_contracts.lawspec` through the public
frontend before emitting native code. All eight targets pass both machine
profiles and readable/compact modes, including ordered predicate checks, exact
division through a specialized generic helper, narrowing, direct logical calls,
and postcondition rejection of deliberately corrupted results. The default mode
retains the independently constructed Core fixture.

## Sum payload refinements

`Maybe (value :: Int8 where value > 0)` admits `Nothing` and positive `Just`
payloads. `Either (value :: Int8 where value > 0) Bool` checks the positive bound
only for `Left`; `Right` retains its Bool domain. Nested sums compose these
checks, and payload predicates may refer to earlier quantified inputs.

These refinements elaborate to exhaustive Core matches. Unselected branches are
not evaluated, and generated binder names preserve outer dependencies. Finite
domains retain distinct absence and variant states. Named data payload and constructor-field refinements are also supported. The bundled [sum refinement examples](examples/specs/sum_refinements.lawspec)
pass native framework execution on all eight targets under both machine profiles
and readable/compact layouts. The data integration harnesses include these laws
with their existing structural and incorrect-adapter checks.


## List payload refinements

`List (value :: Int8 where value > 0)` constrains every element and admits the
empty list. Lists compose with other Lists, Maybe, and Either. An element
predicate can refer to an earlier quantified input, for example:

```lawspec
law `elements exceed the earlier bound` is
  definition is `for all` (floor :: Int8)
    (xs :: List (value :: Int8 where value > floor)) .
    prelude.length xs >= 0
  end
end
```

These domains elaborate to a typed, scoped Core `AllElements` predicate. It
checks elements in order, stops at the first false result, and returns true for
an empty list. Its binder is fresh with respect to outer dependencies. There is
no new user-facing predicate syntax. Explicit examples outside the domain are
rejected; nested predicates keep their element scope during specialization.
See [the List refinement examples](examples/specs/list_refinements.lawspec).

Generic definition signatures can contain List payload refinements, including
calls to generic Boolean helpers. Native entry points check these contracts.
The totality prover retains universal element facts for each List identity.
A stronger exact numeric bound can satisfy a weaker callee contract, including
nested Lists. Matching calls to pure Boolean helpers can also be reused after
specialization. Returned inputs and explicitly constructed Lists can establish
universal postconditions; the empty list satisfies every element predicate.
See [the List contract examples](examples/specs/list_contracts.lawspec).

Proof binders are fresh and scoped. An element condition never implies that a
list is nonempty, and facts about one list do not transfer to another list or to
an unrelated scalar. In a `Cons first rest` branch, `first` inherits the element
predicate and `rest` retains the universal predicate with its original outer
dependencies. Both are strict structural subterms for termination checking. A
`Nil` branch knows only that its matched list is empty. These facts stay inside
their branch and can establish branch-specific result contracts.

For example, a definition over `List (value :: Int8 where value != 0)` can divide
by each matched head and recursively process the tail. The bundled List contract
examples include exact reciprocal sums and nested rows. More complex implications,
including facts requiring a callee's result contract to be unfolded, remain
conservative and may be rejected.

Verified callee results are available to the total-definition proof checker.
A helper's postcondition can establish a nonzero divisor, justify checked integer
narrowing, or satisfy the next helper's input contract. For example:

```lawspec
definition nonzero (value :: Int8 where value != 0)
  :: (result :: Int8 where result != 0)
is value end

definition reciprocal (value :: Int8 where value != 0) :: Rational is
  1 / nonzero value
end
```

The checker first proves the call's preconditions and, for recursive calls,
strict structural descent. Only then does it use the result guarantee. Recursive
List construction can therefore prove element postconditions by induction over
the tail. A returned List does not itself acquire structural-subterm status.
Guarantees remain scoped to evaluated branches and short-circuit operands;
a skipped call cannot justify arithmetic elsewhere. Every helper's own result
contract is checked, including helpers unused by laws.

Constructor-sensitive matching also preserves payload refinements in total
functions. A `Maybe` payload fact is available in the `Just` branch; an `Either`
fact belongs to its corresponding `Left` or `Right` branch. Constructed results
are checked against the matching alternative, including nested sums.

Whole-value refinements on named products can relate fields explicitly:

```lawspec
type Range is Range lower :: Int8 upper :: Int8 end

definition gap
  (range :: Range where match range with | Range lo hi -> hi > lo end)
  :: Rational
is
  match range with | Range lo hi -> 1 / (hi - lo) end
end
```

The field relation justifies the nonzero denominator within that branch. It
cannot establish a fact about a different value or another constructor's payload.
This example uses a refinement on the function's whole input value; direct
constructor-field refinements can express the relation at the data declaration.


## Named data payloads

A product or sum can receive refined type arguments. The predicate
applies wherever that parameter is stored, including recursive named
types, List elements, and Maybe/Either payloads. Other alternatives remain
unconstrained when they do not store that parameter.

```lawspec
unit example.positive_pair

type Pair (a :: Type) (b :: Type) is
  Pair first :: a second :: b
end

refinement Positive is (value :: Int8 where value > 0) end

definition reciprocal (pair :: Pair Positive Bool) :: Rational is
  match pair with
    | Pair first second -> 1 / first
  end
end

law `half` is
  definition is
    `for all` (pair :: Pair Positive Bool) . reciprocal pair > 0
  end
  example `two` is
    pair = Pair 2 false
    expect reciprocal pair = rational(1, 2)
  end
end
```

The compiler lowers the payload requirement to a scoped traversal in the shared
Core. Generators, concrete examples, adapter contracts, and checked definition
entry points use that predicate. The native representation remains
`Pair Int8 Bool`; the refinement does not introduce a new wrapper type. Definition proofs
can use the selected field's predicate to establish that division is defined.

Free value names in a type argument retain the scope where the argument was
written. In `Pair Int8 (n :: Int8 where n > first)`, `first` refers to an earlier
outer input; a constructor field also named `first` does not capture it.

Recursive payloads such as `Tree Positive` use the same operation. Traversal
follows stored parameter positions, including mutual recursion and growing
arguments such as `Nest (List a)`. A fixed `Int8` field is not constrained merely
because another parameter is instantiated as `Int8`. Empty and phantom storage
satisfies its payload predicate without evaluating a callback. See the bundled
[recursive refinement example](examples/specs/recursive_refinements.lawspec),
which proves a positive result for a recursive sum and preserves outer thresholds.

The front end checks direct constructor field contracts:

```lawspec
type Gap is
  Gap first :: Int8 second :: (n :: Int8 where n > first)
end

definition inverseGap (gap :: Gap) :: Rational is
  match gap with | Gap x y -> 1 / (y - x) end
end
```

A field predicate may refer to that field and earlier fields. Construction in a
total definition must prove the predicates; matching makes them available in the
selected branch. Concrete example inputs and expected values are checked too.
The reference interpreter enforces predicates on definition inputs and results.
All eight backends enforce these
contracts in generated runtime checks and native Hypothesis/fast-check/proptest/
JetCheck/Kotest/Rapid/Hedgehog strategies. Each generated case
shares one Symbol fixture context across witnesses, inputs, adapter checks and
assertions. Witnesses supplement native strategies; sampled alternatives may
retain large counterexamples even when native branches can shrink further.
Web and Rust generation bound whole-value retries with `maxAttempts`; an exhausted search
reports failure rather than claiming that the domain is empty. Input guards use
fast-check preconditions, preserving its skip and shrink handling. Rust carries
predicate evaluation errors into property failures rather than treating them as
rejected candidates. Java preserves native JetCheck filtering/shrinking, caps each
filter at the smaller of `maxAttempts` and the framework's 100-attempt limit, and
reports evaluator errors as contextual generation failures. It uses one native
session per requested constructor-contract case to avoid session-wide draw
uniqueness exhaustion for fixture identities. Kotlin bounds candidate sampling
while retaining native shrink trees; case state carries evaluator errors past
input guards to the property failure. Go uses Rapid's bounded native filtering
and replay-based shrinking, with per-sample error state that prevents later fields
from hiding an evaluator failure. Required conjunctive Symbol equalities bind the
fixture identity directly; disjunctions retain their alternatives. Go's structural
properties honor `cases` with scoped Rapid settings, restoring the previous flag
after each sequential generated test. Rapid's explicit short-test mode may reduce
that count. Each filter uses at most the smaller of `maxAttempts` and Rapid's
five-attempt native limit; enclosing native generators and the engine retain
their own retry limits. For structural Go properties, minimization uses Rapid's
`-rapid.shrinktime` setting, not the scalar refinement engine's `maxShrinks`
step budget. Haskell constructor properties use native Hedgehog strategies with
one Symbol context per case. Each dependent draw is forced before the next draw;
evaluator failures cannot disappear behind a later discard. Native `filterT`
prunes rejected shrink branches instead of searching all their descendants.
Hedgehog receives `cases` as its test limit, `maxAttempts` as its property discard
limit, and `maxShrinks` as its shrink limit. Internal generator filters retain
Hedgehog's own retry policy; `maxAttempts` is not a total count of candidate draws.
Recursively refined named payloads use scoped payload predicates that follow
declared type-parameter positions through constructor fields.

Common domain planning filters finite constructor domains through their field
predicates. For larger domains, it searches combinations of field boundaries and
literal values from contracts. This covers dependent fields such as `Gap` and
sparse Symbol fixture identities. Recursive expansion and candidate combinations
have finite search budgets; every returned witness satisfies the contracts.
Exhausting that search reports that no witness was found, rather than declaring
the domain empty. Bounded samples are never reported as an exhaustive domain.

Expression annotations select a representation, such as `(127 :: Int8)`; they
do not establish a refinement contract. Inline refinement predicates in expression
annotations are rejected. Put the refinement on a quantified input or function
signature so that generation, checking, and definition proofs enforce it.
