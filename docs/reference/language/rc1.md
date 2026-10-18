---
id: lawspec.reference.language.rc1
kind: reference
title: Minor-version authoring contract
---
# Minor-version authoring contract

The authoritative implementation contract and remaining gates are in
[the single review packet](../../../LAWSPEC-PRE-1.0-REVIEW.md). The current
authoring milestone is a minor version, not a release candidate. The existing
technical profile `1.0-rc.1` uses API schema 5 and configuration version 2;
its identifier does not designate a released RC or final 1.0.

Current syntax still uses bare `end` for laws, sections, quantifiers and some
other blocks. The immediately following minor milestone must give every
end-delimited block a named closer and reject bare `end` in normal source.
That requires coordinated grammar, parser, formatter, migration, editor and
example changes. The syntax and examples on this page describe the current
implementation; they do not claim that the all-named-ending milestone is done.

Automatic exhaustiveness, termination, definedness, refinements and definition
contracts stay intrinsic. A pure `function` has no ability operations; a
`procedure` declares or infers its effects. Law verification is independent:
`verification.layers` defaults to `[]`. No selections means no selected law
checks, and does not constitute verification success. Deferred definition
postconditions still run at native boundaries.

Canonical expressions retain explicit `;` sequencing, `~state := value` updates
and performance budgets. A stateful handler's declaration `is` ends its initial
state expression before the first operation clause, including a delegated `by`
clause. Initializers may contain conditionals, Boolean wording and `let` bindings;
parentheses distinguish an initial worded equality from the declaration boundary.
Performance budgets in laws, named examples and tables use the existing clock
ability, which must be imported with `import lawspec.time`.

Native ability boundaries preserve every logical argument and its evaluation.
Swift protocols omit unit parameters, and checked handler calls restore them in
their original positions. F# methods use `()` for a sole unit parameter while
retaining units in mixed parameter tuples; the checked module functions still
receive their named unit arguments. C# follows that shared F# model. Go ability
methods receive native unit values through the ordinary codec. These boundary
conventions do not remove an argument's computation or change a handler's state.

Canonical `=`, `is`, `must be` and `must =` equality binds above worded `not`,
symbolic/worded conjunction, disjunction and right-associative `implies`.
Existing symbolic comparisons and matcher precedence stay intact. In particular,
`a = b && c = d` compares both pairs. Expectations reserve their outer `=` as
the expected-value separator; delimited expressions such as `expect same (a = b)
= expected` retain ordinary Boolean equality.

Collection models may use `behaves like SortedSet T` to retain the existing
ordered-set reference operations. Canonical `Set T` uses the equality-based set
operations. The compiler generates ordinary checked reference functions; preparing
or emitting a model does not establish that an application conforms to it.

```text
unit example.identity

function same (value of type Integer) -> Integer is
  value
end function

law identity is
  definition:
    for all (value of type Integer) =>
      same value must be value
    end
  end

  expect same value = expected
  in table (value, expected):
    row -1, -1
    row 0, 0
    row 1, 1
  end
end
```

Laws may start with optional scalar `id` and `owner` metadata. Each takes one
text value or documentary identifier, such as `id: "REVIEW-001"` and
`owner: Payments.Review`. Entries precede all sections, occur at most once each,
and have no closing `end`. Documentary identifiers need no import resolution.
These fields do not change the law's qualified identity, proposition or
verification evidence. The [review example](../../../examples/rc1/law-metadata.lawspec)
shows both scalar orders. Formatting preserves the chosen order and spelling;
`id` and `owner` remain ordinary identifiers in other contexts.

A `references:` section contains documentary links, as in the
[documented review requirements](../../../examples/rc1/documentary-review.lawspec):

```text
references:
  #S{ref law "|allowed requests are approved| definition,
     ref function review}
  ref law "|other requests are declined| references."|Review policy|
  "|Review policy|: "Allowed requests are approved; all other requests are declined."
end
```

`ref law` accepts a local name, an imported alias, or a full unit-qualified
name. Dots within phrase delimiters belong to the name. Local declarations
resolve first, followed by explicitly listed imports and the prelude; ambiguous
unqualified links require qualification. Facades preserve the original target
identity and source location. Full qualification also respects package
visibility. When several package versions are loaded, full-unit paths select
the same dependency version as imports, without rewriting reference text or
moving its source span. A concrete law can be linked through an alias without importing it
for reusable-law application.

A law selector is `definition`, `description`, `rationale`, `references`, or
`references.` followed by a named external reference's phrase name. A selector
may follow whitespace or a dot after the law name. A known section selector
addresses that documentary field; an omitted optional section has empty text
or entries. A named selector requires an actual entry on the selected law.
`ref function` selects a checked function or procedure definition. Public
prelude aliases such as `prelude.caseFold` and `prelude.setOf` select their
original checked definitions. Local and explicitly imported functions take
priority for unqualified links. An adapter signature or primitive operation
has no source definition to select. An unselected law link addresses
the law as a whole. Named external entries use a phrase name, a colon and one
text resource; unnamed quoted citations are also external links. Named entries
are unique within their law. Resources are documentary text, with no network
lookup or implicit proof authority.

`#S{...}` groups complete links. `ref law #S{first, second} description`
selects the same field on each target. Groups flatten into ordered links and
do not construct a runtime set. Resolution diagnoses missing or wrong-kind
targets before elaboration. Links retain declaration and use spans, permit
cycles, and never copy or expand a linked obligation. They do not discharge
laws. Developer and business explanations show the links; formal propositions
and evidence retain their existing meaning. Editor navigation uses the same
resolved identities and spans.

Developer, business and formal explanations render anonymous record input
domains from their checked field metadata, including nested products, generic
type arguments and field restrictions. Named records retain their nominal
names. For example, the positive-weight domain in the
[parcel example](../../../examples/rc1/parcel-measurements.lawspec) displays as
`record{weight of type (weight of type Measurement Integer where (weight.reading.value > 0))}`.
The repeated `weight` names the refinement's local binder. Generated storage
views are hidden only when they copy the complete structural product; unhandled
expression forms retain their checked text. The JSON still contains the original
typed inputs, assertion and evidence. A readable domain adds no verification
evidence.

Expression views also show structural record values by label and nominal or
alternative constructors as checked terms such as
`Parcel(details = record{weight = Measurement(reading = record{value = 1})})`.
`Constructor(field = value)` and the view's case/handler terms are presentation
notation, rather than additional authoring syntax. Constructor names keep
their identities; ambiguous names are qualified. Primitive constructor names
and field order come from the compiler's existing registry.

Fields appear in evaluation order. A chain of strict lets can display as a
constructor value only when every binding supplies exactly one field and no
later value depends on an earlier binding. Dependent, repeated or unused
bindings remain explicit. Projections retain their complete subject, including
unselected computations. Branch order, short-circuit conditions, checked versus
explicit conversions and handler choices remain visible. If a term or its
metadata cannot be presented, the whole expression retains its original
checked text, including its binders. The views do not execute expressions or
turn them into verification evidence.
Known abilities use their checked source names, qualifying collisions;
unresolved type-argument keys remain explicit.

`must be`, `is`, `=`, `must =`, and leading `must` elaborate to the same typed
Eq obligation. Equality in a value context is Boolean. Existing IEEE equality
and refinement predicates retain their meaning. Worded `not`, `and`, `or`, and
right-associative `implies` have their logical precedence; named infix
application is nonassociative immediately above comparisons.

Logical quantifiers keep their lexical order and own their closing `end`:

```text
law witnesses is
  definition:
    for all (value of type Bool) =>
      there must exist a (witness of type Bool where witness = value) such that
        witness must be value
      end
    end
  end
end
```

Restrictions bind left to right. A name is visible in its own restriction;
existential restrictions must hold for a witness. Universal restrictions are
antecedents. An inner binder may shadow an outer name without capturing its
identity. Existential propositions remain distinct from existentially packaged
data. `must not P` negates a proposition, including a reusable law application.
`there does not exist` and `there must not exist` both negate existence.

In a restriction, `the` may precede an already bound name: `where the reply =
the value`. This includes the current binder, earlier and enclosing binders,
and field projections such as `the authorization.granted`. The same wording
works in `given ... when` conditions and harness `such that` filters. It does
not make a later or sibling binder visible. The article changes no predicate
or obligation; formatting preserves its spelling and diagnostics retain the
original name's location.

The words `a`, `an` and `the` remain ordinary names elsewhere. A local or
explicitly imported function named `the`, or a bound variable named `the`,
keeps ordinary application semantics even inside a restriction. Use the
bound name directly when that ordinary declaration takes precedence. Function
purity and refinement checks still apply.

Complete finite search currently supports enumerable primitive and algebraic
domains within the exhaustive limit. The shared execution plan lowers logical
binders to ordinary typed terms, retaining the scoped proposition in API and
explanation views. Empty nested domains and false restrictions have their
logical meanings. Swapping `for all` and `there exists` can change the result.
The [authorization snapshots](../../../examples/rc1/authorization-snapshots.lawspec)
use exactly two approval identities, explicit activation snapshots and a
payment-matching relation, including complete absence claims after revocation.
Their domain does not describe an unbounded history or future executions.

Quantified propositions compose with explicit `and`, `or`, `not` and
right-associative `implies`. Parentheses group propositions. Each clause keeps
its own binders: an empty universal domain in one clause cannot hide a false
sibling clause. Only an uninterrupted leading universal prefix becomes law
inputs; a repeated name stays in its nested scope. Reusable requirements keep
the same scope when expanded. The
[composed requirements](../../../examples/rc1/requirement-composition.lawspec)
exercise conjunction, alternatives, implications and distinct nominal domains.
These words express logical obligations; their textual order establishes no
policy priority. Explanation views derive their wording from the typed
proposition, including alternatives and implications represented through
negation and conjunction.

## Constructive witness search

A harness can supply a checked expression for an existential binder:

```text
harness example.testing for example is
  for law successors
    witness value + 1 for definition.value.answer
end
```

The [complete constructive example](../../../examples/rc1/constructive-witnesses.lawspec)
includes an unbounded integer theorem, nominal record witnesses, a later
witness depending on an earlier one, sibling binders, complete finite absence,
and an empty outer domain. A witness setting belongs inside `for law` or
`for laws`; it is not a unit default or a new law declaration. Like existing
harness expressions, the setting occupies one line. Complex construction can
live in an ordinary checked function, called from the setting.

Paths follow the expanded law's lexical binders, including its leading
universal inputs. `definition.value.answer` and `value.answer` name the same
binder. A bare `answer` is accepted when exactly one existential has that name.
Conjunction siblings introduce `branch1`, `branch2`, and so on; use the listed
qualified path if names repeat. Negation does not add a path segment. Paths
address the expanded typed obligation, including reusable-law expansion. These
branch labels are search addresses and establish no policy priority. This
path spelling is an explicit mechanical default. Names inside phrase
delimiters remain atomic and case-sensitive.

An expression sees enclosing binders, with the nearest same-named binder
winning, and cannot depend on its own target or a later binder. Imported names
resolve after that lexical scope is known. Its result must have the witness's
type, including nominal boundaries. The candidate must also satisfy the
binder's restriction when checked. Expressions call only checked functions;
unchecked native calls and effectful operations are rejected, including calls
hidden behind a checked wrapper. Checked recursion, polymorphism, capability
requirements and constructor contracts retain their ordinary checks.

A successful candidate establishes the existential subclaim for its enclosing
inputs. A failed candidate leaves it undecided unless complete finite search
settles it. Finite fallback remains available. Negation preserves the undecided
outcome: a miss is never proof of nonexistence. A verified witness can refute a
nonexistence claim. The native execution plan uses ordinary typed lets and
conditionals and evaluates each visited candidate once. An undecided attempt
reports `quantifier-search-incomplete`, rather than returning Boolean false.

The existing contract prover checks a sufficient constructive proof goal; it
can prove a theorem such as every integer having a successor without sampling
that infinite domain. Complete checking of finite outer inputs is reported as
exhaustive checking. Property execution is planned until it actually runs and
can supply witnesses only for the inputs it checked. Neither a sample nor a
configured expression proves an unbounded universal theorem. Empty outer
domains still produce zero cases and no witness values. No selected law layers
still means `not-verified`.

Schema 5 exposes configured choices in `law.harness.witnesses`, each with a
binder identity, normalized path and typed expression. These are strategy
settings, not completed evidence. Developer and evidence explanations label
them accordingly; business and formal wording retain the declared proposition.
Detailed concrete witness-value traces, shrinking individual existential
witnesses and snapshot-aware effectful search remain required work.

## Bounded witness strategies

Existing harness strategies can select a scoped existential or universal binder:

```text
strategy answers of type Integer is one of 1, 2 end
for law selected
  use answers for definition.allowed.answer
```

Scoped paths use the same lexical convention as configured witnesses. A short
name is accepted when unambiguous; an outer input keeps its existing short name.
`definition.` is optional. Reusable laws expand before paths resolve. Two paths
that select the same binder are rejected. Ordinary outer-input strategies
continue to use the target's property framework and shrinker.

Scoped search uses a bounded deterministic schedule. `one of` supplies candidate
expressions; `frequency` uses weighted cycles; `bind` explores dependent pairs
diagonally; `such that` retains its checked filter and discard budget. Named
strategy references keep their own lexical bindings and declared refinements.
Generic checked functions used only by a strategy are specialized normally.
Candidate computations become ordinary typed lets and conditionals, including
filters and dependent binds, and every visited computation is evaluated once.

Without a selected strategy, the compiler tries safe restriction hints and
nearby integers, closed literal values, existing type boundaries and small
integers. An `any` strategy uses this pool. Structural default search currently
uses existing boundary values and closed literals; it does not claim the breadth
of each framework's random generator. The schedule is deterministic for the
typed obligation and enclosing inputs, so no additional random seed is needed.
The outer framework's seed still reproduces its generated inputs.

`generation.cases` bounds candidates per binder and `maxAttempts` bounds the
expanded candidate evaluation plan for a scoped branch, including its nesting.
Independent conjunction branches retain their own budgets. Complete finite coverage has its separate
`exhaustiveLimit` and remains available independently of the selected strategy.
A configured `witness` is tried first; without a selected strategy it retains
its complete finite fallback. With a selected strategy it can cooperate with
those bounded candidates.

A found existential witness establishes that subclaim for the current inputs.
A failed or exhausted search is incomplete, including beneath negation. A
counterexample can refute a universal subclaim, but passing bounded universal
samples cannot establish it. A strategy's finite choice list is never treated
as complete coverage of the law's type. Only complete finite coverage or a proof
can establish absence. Proof certificates go through the existing contract
prover; a candidate list is not itself a proof of an unbounded universal law.

Dependent restrictions are checked with the actual enclosing values on every
attempt and every outer shrinking recheck. No strategy changes the proposition,
widens its domain, bypasses intrinsic definition checking or permits unchecked
native/effectful candidate computations. Schema 5 exposes configured scoped
strategies as `law.harness.searches`, with binder identity, normalized path and
strategy name. Explanation views label these as configuration rather than
completed evidence.

The [bounded-search example](../../../examples/rc1/bounded-witness-search.lawspec)
includes cooperating witnesses, nominal record candidates, independent expected
replies, sibling paths, dependent filters, weighted choices, finite absence,
an empty domain and a universal counterexample. Concrete witness-value traces,
broader stochastic candidate generation and shrinking individual witness values
remain implementation requirements.

## Complete integer ranges

An integer restriction can make an otherwise unbounded domain finite. The
canonical profile checks all values when mandatory conjuncts establish a
complete interval within `exhaustiveLimit`:

```text
there does not exist (value of type Integer where value >= 0 and value < 4) such that
  value = 4
end
```

The same planning applies to leading universal inputs and scoped quantifiers.
Strict endpoints, reversed comparisons, equality and exact affine arithmetic
are supported. Finite-width bounds are intersected before values are constructed;
`Whole` includes zero and `Nat` retains its positive restriction. Additional
predicates are checked for every candidate, in lexical order.

Exact signed integer ranges may depend on enclosing binders when both endpoints
have the same variable coefficients, such as `next > amount` and
`next <= amount + 3`. This is a complete three-value cover for every amount,
including an unbounded universal input. A later restriction is checked with
the actual earlier values. The
[settlement example](../../../examples/rc1/finite-integer-domains.lawspec)
includes fixed and dependent ranges, positive attempt counts and an empty gap
between consecutive cents.

These are complete covers, not samples. An interval with contradictory endpoints
is empty without searching an unreachable inner domain. A complete finite miss
can establish nonexistence. A cover that exceeds the expansion budget remains
incomplete; it is never truncated into an absence proof. A proof of an unbounded
universal claim still requires the prover. Otherwise native property checks
remain planned until executed.

Range inference uses required conjunctions only. It does not extract a bound
from an optional disjunct, treat rational or floating-point intervals as discrete,
or infer nonlinear bounds. Variable-width dependent intervals and opaque
function-based bounds still need further search support. The declared
proposition and source restrictions are preserved in every explanation view.

A search that cannot decide its proposition reports `incomplete`, with no proof
of absence. No selected law layers still reports `not-verified`.
Broader stochastic search, shrinking individual witness values, complete
variable-width or opaque refined integer covers, and effectful search
with explicit snapshot semantics remain required implementation work. A
candidate evaluation error reports
`verification-incomplete`, rather than refuting existence.
An effectful sibling clause retains its chosen handler and executes outside
the finite search. Effects repeated within a logical search still report the
missing snapshot semantics.

An empty outer universal domain is valid in the canonical profile. Complete
verification states that the domain is empty and that zero cases were evaluated;
it produces no witness for an actual input. Property testing alone reports that
no cases ran. Examples still need valid inputs. The
[empty-domain example](../../../examples/rc1/empty-domains.lawspec) contrasts an
empty universal obligation with the absence of existential witnesses. The
legacy profile retains its nonempty test-domain requirement until migration.
A law with no input binders has one case: its proposition is evaluated once.
This differs from a universal binder whose domain has zero values.

```text
function "|adds the values| (a :: Integer) (b :: Integer) -> Integer is
  a + b
end function

"|adds the values| 1 2
1 `|adds the values| 2
1 `adds 2
```

The last expression calls the ordinary function `adds`; it is not an alias for
`"|adds the values|`. Dots outside phrase delimiters qualify a name. Dots inside
belong to the name. Phrase bodies preserve case and spelling, permit escaped
pipes and backslashes, and reject emptiness, edge whitespace and line breaks.

`Whole` includes zero, and `Nat` is strictly positive; their phrase aliases are
`"|whole number|` and `"|natural number|`. Canonical integers are unbounded
`Integer`. Legacy numeric names require migration. Collection indices and
lengths retain their zero-inclusive semantics.

Reusable requirements use `apply law` followed by the law's name and arguments
in declaration order. Applying the prelude's left-inverse law takes the decoder
first and encoder second:

```text
law roundTrip is
  definition:
    apply law "|left inverse| decode encode
  end
end
```

The same typed expansion checks polymorphism, capabilities, argument count and
recursive reuse. Local and explicitly imported laws resolve before the prelude;
`prelude."|left inverse|` selects the built-in law explicitly. An import such as
`import codec.requirements as c (law "|recovers the input|)` offers qualified
`c."|recovers the input|` and unqualified use. A facade can write
`export law c."|recovers the input|`. Phrase spelling, including internal dots
and backticks, survives both forms. Law application does not change expression
or function-name resolution. Expectation tables bind the expanded law's inputs.

Native phrase names use deterministic word splitting and the target's naming
rules. Colliding public names require an explicit
[`nativeBindings.names` override](../native-bindings.md#configuration) by resolved
declaration identity. Overrides preserve typed behavior and all call identities;
they do not substitute an unchecked implementation.

The [bit codec](../../../examples/rc1/bit-codec.lawspec) combines a checked
mapping, Maybe-valued decoding, direct round trips, the reusable inverse and
independent expected encodings. Its reversed-encoding mutant retains round-trip
agreement but fails the expected encodings. This distinguishes agreement
between derived functions from conformance to an external requirement.

Named records are nominal products with an explicit constructor:

```text
type Picture is a record{
  fileName of type Text
  width of type Nat
}
end type

function picture (width of type Nat) -> Picture is
  Picture record{fileName = "photo.jpg", width = width}
end function
```

Anonymous records are closed structural products. Their field labels and
resolved types determine identity independently of declaration order; every
supplied value is evaluated in source order. A bare `record{...}` constructs
an anonymous value, including the empty product `record{}`. The empty product
is distinct from `()`. Matching fields do not convert a nominal record into
an anonymous one or make different nominal records interchangeable.

```text
function double (value of type record{count of type Integer})
    -> record{count of type Integer} is
  record{count = value.count + value.count}
end function
```

The [structural record example](../../../examples/rc1/structural-records.lawspec)
includes record-valued table inputs and expected results, a generic wrapper,
field-order equality, nested projection and empty products. Type fields may
use optional commas; value fields require commas. Duplicate labels and missing
or extra value fields are errors. Exact scalar contexts, positive field
restrictions and automatic definedness checks apply to these constructions.
Anonymous products may also appear directly inside named records and alternative
payloads, including parameterized products:

```text
type Envelope (a of type Type) is a record{
  payload of type record{value of type a copy of type a}
}
end type

function extract (envelope of type Envelope a) -> a is
  envelope.payload.value
end function
```

The [payload example](../../../examples/rc1/record-payloads.lawspec) exercises
nested positive dimensions, alternative matching, generic projections, complete
product returns and record-valued table inputs. Its reproducible suite is
`make acceptance SUITE=rc1-record-payloads TARGET=java`; CI schedules every target
in both machine profiles. Mutants independently return the wrong dimension,
download label and generic field.

Source constructor contexts preserve structural field types and GADT equations
through inference. Instantiating a nominal product retains its storage layout;
ordinary checked constructor matches and constructions reconcile equivalent
structural representations. This introduces no implicit nominal conversion.
Automatic field refinements, capability requirements and definedness still apply.

Structural field restrictions can inspect products stored inside generic named
records. The [parcel measurements example](../../../examples/rc1/parcel-measurements.lawspec)
requires positive measurements and checks named-record table values by label,
including labels supplied in a different order. Its checked functions, field
restrictions and table inputs remain validated when no law layers are selected.

All 17 targets consume constructor field contracts through their schema emitters.
The parcel fixture runs on every target in both profiles, with separate checks
for native field enforcement. Run its reproducible suite with
`make acceptance SUITE=rc1-record-refinements TARGET=java` (or another target);
CI schedules every target/profile and three independent result mutants.

Generic nominal payloads can contain structural records inside `List`, `Maybe`
and user-defined recursive containers. The compiler reconstructs equivalent
storage with ordinary checked recursive functions; their matches, recursion and
constructor restrictions pass the same mandatory validators as source functions.
The [container fixture](../../../test/fixtures/canonical-container-records.lawspec)
exercises these paths, named-record projections and record-valued table inputs.
Run `make acceptance SUITE=minor-container-records TARGET=java` (or another
target) for native execution and independent result/type mutants. Five finite
Boolean laws admit complete checking; the two requirements over unbounded lists
retain planned example evidence rather than a claim of complete verification.
Explanations hide compiler-marked storage calls only when their complete typed
signature matches; the authoritative typed assertion retains those calls.

Structural GADT index arguments retain their stored field restrictions, as in
the [refined-index fixture](../../../test/fixtures/canonical-refined-gadt-indices.lawspec).
Checked functions used in anonymous field restrictions expand through the
ordinary definition machinery; the
[predicate-function fixture](../../../test/fixtures/canonical-record-predicate-functions.lawspec)
also checks dependent sibling fields. These checks remain mandatory with no
law layers selected. Opaque storage and infinitely expanding type
specializations do not acquire implicit conversions.

Recursive record and constructor patterns preserve structural descent for
checked recursive functions. The
[approval-chain example](../../../examples/rc1/recursive-records.lawspec)
counts nested records and distinguishes productive chains from recursive types
with no finite construction. Projecting a field of a newly built record or a
function result does not establish descent from the function's original input.

Alternatives have no payload or one explicitly typed payload. Ordered cases
bind the selected expression once as `it`; guards continue to later branches
when false. Intrinsic exhaustiveness still applies.

```text
type Answer is one of
  | Yes of type Integer
  | No
end type

function answerValue (answer of type Answer) -> Integer is
  first matching case of answer:
    when Yes value then value
    when No then 0
  end case
end function
```

Nested constructor and record patterns keep the same ordered behavior. Record
patterns use `field = pattern` entries, may omit fields, and reject unknown or
duplicate fields and repeated variable bindings. Boolean literal patterns may
cover both values without a fallback. A whole-value binding requires
`it matches name`.

```text
first matching case of delivery:
  when Email record{document = Invoice record{file = Pdf record{fileName = name}}}
    then Just name
  otherwise Nothing
end case
```

The [eight delivery/document/file examples](../../../examples/rc1/nesting/rrr.lawspec)
cover each record/alternative combination using inline anonymous products inside
nominal record and alternative payloads. Their 20 closed outcome laws are
checked by exhaustive compiler evaluation. All eight examples generate through all
17 targets and their 20 outcomes also pass native execution on each target.
Run the reproducible suite with `make acceptance SUITE=rc1-nesting TARGET=java`
(or another supported target); CI schedules it for every target. Eight mutants
remove the extracted filename and must be rejected during exhaustive checking. The
examples count domain layers; explicit record payloads add product nodes.

Finite mappings lower to ordinary checked lookup definitions. Constant keys
must be distinct and reflexive under Eq. Complete finite coverage of the
restricted key domain or an explicit `otherwise` is required. Names, aliases,
nominal identities and contextual literals resolve before this check, using
the selected machine width. Record, constructor and collection constants use
ordinary typed equality; record field order and set iteration order cannot
distinguish duplicate keys. Complete mappings derive finite preimages;
an inverse is Maybe-valued and derived when outputs are unique and reflexive.
A fallback does not silently acquire an incomplete finite inverse.
A partial lookup is explicitly Maybe-valued and supplies `otherwise Nothing`;
the generated function remains total. Preimages group outputs using typed Eq
and retain matching keys in source row order, including their refinements.
Signed zeros compare equal; NaN keys are rejected and NaN outputs cannot
justify an inverse. Existing definition admission and finite-domain analysis
limits still apply; a bounded sample never establishes complete coverage.

Nominal keys use explicit construction:

```lawspec
unit example.preferenceLabels

type Preference is a record{
  enabled of type Bool
}
end type

mapping preferenceLabel of type Preference -> Text is
  row Preference record{enabled = false}, "disabled"
  row Preference record{enabled = true}, "enabled"
end mapping

law "|enabled preferences retain their label| is
  definition:
    preferenceLabel (Preference record{enabled = true}) must be "enabled"
  end
end
```

The [delivery mapping specification](../../../test/fixtures/canonical-typed-mappings.lawspec)
also covers payload constructors, list fallbacks, sets, refined keys and shared
output labels. Its seven laws and ten independent expectation rows run in the
native acceptance suite on all 17 targets at both machine profiles.

```text
mapping answerText of type Answer -> Text is
  row No, "no"
  otherwise "yes"
end mapping
```

Completed proofs and compiler-evaluated exhaustive results remain evidence.
Generated native tests are `planned` until an execution supplies results.
Incomplete and unsupported analyses report their limits.

Canonical `Set a` construction and membership require `Eq a`: equality detects
duplicates and compares a candidate with stored elements. These operations do
not require ordering. Iteration, size and emptiness do not compare elements
and need no `Eq` requirement. Equal duplicates retain their first occurrence;
set equality compares membership independently of stored iteration order.
IEEE equality remains authoritative: signed zeros compare equal, and a NaN
remains unequal to itself even when stored in a set.

`#S{3, 1, 3}` constructs a set whose iteration order is `[3, 1]`. Empty and
nested sets are supported, including constant table and example values under
records and alternatives. `prelude.setOf`, `member`, `insert`, `remove`,
`union`, `intersection` and `difference` use ordinary checked definitions.
Use `SortedSet a` and `prelude.sortedSetOf` for the old portable sorted
representation, requiring `Keyed a`. Explicit `lawspec.collections` imports
expose these same resolved identities and operations. Their constructors and
storage fields are private. User sources cannot replace compiler-owned units.

Local declarations and explicit imports take precedence over implicit collection
names. Native metadata distinguishes `Set` from `SortedSet`; canonical set
values use checked data storage. Complete finite set checks preserve every
observable storage order: five inputs for `Set Bool` and 114 for
`Set (Set Bool)`. Insufficient budgets and unavailable or non-reflexive element
domains retain incomplete coverage. Property generation and shrinking retain
checked element and dependent restrictions; planned tests remain planned.
`prelude.member value members`, `value in members`, `value is in members`
and `value must be in members` use Eq-based membership over List, Set,
SortedSet, Queue, Stack, Deque and Bytes. `prelude.any predicate members`
uses checked iteration with no additional element Eq requirement. Captured
predicate arguments and membership arguments are strict and evaluated once;
empty collections do not bypass their mandatory checks. Maps select keys,
values or entries explicitly. Sized containers use their existing checked
item-list operations. Literal element context does not reinterpret computed
collections. Opaque dependency fields retain conservative provider discovery;
unresolved or ambiguous names require qualification. Project migration writes
require complete source, population, binding and target-generation
correspondence, and do not establish native implementation conformance. A
finite example does not prove a law over all sets. The review packet tracks all
remaining gates.

In `let name = value in body`, the first `in` outside a delimited
subexpression ends the initializer. Write membership in a parenthesized
initializer, such as `let present = (value in members) in present`. Membership
inside records, lists, sets, conditionals and cases retains its ordinary
meaning. A nested let initializer has its own delimiter; its body remains
within the enclosing initializer.

The implemented syntax below describes the canonical frontend entry point.
The review packet also specifies grammar still awaiting implementation,
including the remaining generic structural-payload cases and broader witness evidence. The legacy grammar remains the migration input language.

```ebnf
annotation = "of" "type" | "::" ;
parameter = "(" identifier annotation type ["where" boolean] ")" ;
function = "function" name parameter+ "->" type "is" expression "end" "function" ;
procedure = "procedure" name parameter+ ["->" type] "is" expression "end" "procedure" ;
record = "type" name "is" "a" "record" "{" field* "}" "end" "type" ;
field = identifier annotation type [","] ;
alternatives = "type" name "is" "one" "of" alternative* "end" "type" ;
alternative = ["|"] name [annotation type] ;
anonymousRecordType = "record" "{" field* "}" ;
recordValue = [name] "record" "{" [entry {"," entry}] "}" ;
recordLiteral = [name] "record" "{" [literalEntry {"," literalEntry}] "}" ;
literalEntry = identifier "=" literal ;
setValue = "#S{" [expression {"," expression}] "}" ;
setLiteral = "#S{" [literal {"," literal}] "}" ;
entry = identifier "=" expression ;
selection = "first" "matching" "case" "of" expression ":"
            branch+ ["otherwise" expression] "end" "case" ;
branch = "when" ["it" "matches"] pattern ["if" boolean "then"] ["then"] expression ;
pattern = "#any" | "_" | literal | constructorPattern | recordPattern | "(" pattern ")" ;
recordPattern = [name] "record" "{" [patternEntry {"," patternEntry}] "}" ;
patternEntry = identifier "=" pattern ;
law = "law" name parameter* "is" metadata* section+ "end" ;
metadata = ("id" | "owner") ":" (text | documentaryIdentifier) ;
section = "definition" ":" proposition "end"
        | ("description" | "rationale") ":" text "end"
        | "references" ":" reference* "end"
        | namedExample | expectationTable ;
reference = "ref" "law" referenceTargets [referenceSelector]
          | "ref" "function" referenceTargets
          | phraseName ":" text | text
          | "#S{" [reference {"," reference}] "}" ;
referenceTargets = qualifiedName | "#S{" qualifiedName {"," qualifiedName} "}" ;
referenceSelector = ["."] ("definition" | "description" | "rationale"
                  | "references" ["." phraseName]) ;
proposition = "for" "all" parameter+ "=>" proposition "end"
            | existential parameter+ "such" "that" proposition "end"
            | "must" "not" proposition
            | "given" parameter+ ["when" boolean] "then" proposition "end"
            | "apply" "law" qualifiedName argument*
            | ["must"] boolean ;
existential = "there" ("exists" | "must" "exist"
            | "does" "not" "exist" | "must" "not" "exist") ["a" | "an"] ;
importItem = name | "law" qualifiedName ;
mapping = "mapping" name annotation type "->" type "is"
          ("row" literal "," literal)+ ["otherwise" literal] "end" "mapping" ;
witnessSetting = "witness" expression "for" ["definition" "."] qualifiedBinderPath ;
strategySetting = "use" identifier "for" ["definition" "."] qualifiedBinderPath ;
expectationTable = ("expect" expression "=" expected)+ "in" "table"
                   "(" identifier {"," identifier} ")" ":"
                   ("row" literal {"," literal})+ "end" ;
```

Each law has exactly one `definition:`. Description, rationale and references
are singletons; examples and tables may repeat. Constructor arity determines
its nested pattern arguments. Boolean branch conditions are an additional
selection form; whole-value variable patterns require explicit `it matches`.
Function/procedure requirements, resources, handlers and existing type features
continue through the established typed pipeline.

### Checked rejection examples

Documentation can record a compiler rejection with a `lawspec reject=<code>`
fence. Each fixture compiles independently with no optional law checks selected.
Exactly one diagnostic must have the specified code. Unexpected acceptance,
another code or additional diagnostics fail the documentation check. Messages
and source positions are displayed without making their wording part of the
expectation. Rejection examples cannot be `fragment` fences or request native
implementations or execution.

For an included fixture, write an opening fence such as
` ```lawspec reject=total include=test/fixtures/rejected.lawspec ` and close it
with ` ``` `. Keep rejection fixtures outside the application's configured
sources; ordinary project compilation continues to reject them.

The following function divides by a known zero denominator. Mandatory definition
validation rejects it with `total`, independently of law verification.

```lawspec reject=total include=test/fixtures/canonical-rejection-denominator.lawspec
```

A Boolean cannot be the result of a function declared to return an integer.
This fixture expects the `definition` diagnostic code.

```lawspec reject=definition include=test/fixtures/canonical-rejection-result-type.lawspec
```

An address must fit its refinement. The out-of-range constant is rejected with
`total`; it cannot become a runtime example of a valid `Address`.

```lawspec reject=total include=test/fixtures/canonical-rejection-address.lawspec
```

The pattern follows Lean's
[`#guard_msgs` diagnostic assertions](https://lean-lang.org/doc/reference/latest/Interacting-with-Lean/).
LawSpec checks its existing compiler's stable codes. A matching rejection is a
check of compiler behavior and establishes no law or native implementation
evidence.

The translations use one typed Core: `given ... when C then P` becomes universal
inputs and implication; each equality wording becomes typed Eq; nominal records
become single-constructor products; anonymous products use canonical structural
identities with source-ordered construction; ordered patterns become a typed decision
tree; mappings become ordinary checked functions. Formatting retains section
order, equality wording, annotation choices, infix notation, comments and
literal spelling. It uses two spaces and targets 80 columns without splitting
indivisible literals or reflowing line-scoped harness settings.
