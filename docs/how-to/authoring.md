---
id: lawspec.how-to.authoring
kind: how-to
title: Author with the prelude and generated models
---
# Author with the prelude and generated models

Inspect what LawSpec provides before creating another implementation or
representation. Start with `lawspec --version` and the library reference shipped
for that compiler version. Search the prelude operations and reusable laws,
then compare their semantics with the requirement. A familiar name is not enough:
check the domain, equality constraints, ordering, duplicate counts, exactness,
absence and failure behavior. ref:DEC-prelude-first-authoring

Run `lawspec check`, then `lawspec generate --target <target>` for the configured
target. Read the actual generated types, constructors, checked definitions,
runtime support and required adapter signatures before implementing native code.
For read-only discovery the SDK's `planGeneration` returns planned files without
writing them. Generation preserves user-owned adapters; edit those adapters,
not compiler-owned files. Run `lawspec check`, `lawspec test --target <target>`
and the relevant application tests after the change. New projects default to no
selected law checks. When native example and property testing is intended, set
`:verification {:layers [:examples :property]}` in `lawspec.edn` before generation.
Preserve an existing project's deliberate verification selection. Inspect actual
executed counts: a successful command with zero selected checks is not test evidence.

Prefer migration of corresponding application types to generated types within
the authorized scope. Update imports and constructor calls, compile the affected
application, and remove the superseded declaration once its callers migrate.
If compatibility requires retaining the application model, record that reason
and configure checked native bindings or supported codecs. Matching field names
do not establish nominal type identity or matching meaning. Never guess a native
representation from a LawSpec type name.

These twelve cases separate duplication from incorrect substitution. Custom
logic remains useful for domain meaning, different semantics, missing library
functionality, independent reference models and identified teaching examples.
The examples compile; a law mentioning an external adapter still needs native
execution. Definition validation is mandatory even when law verification is off.

## 1. Round trips

Requirement: recover the original flag after encoding. Apply `left inverse`
with the decoder first, or `round trip identity is preserved` with the encoder
first. A hand-expanded equation is unnecessary duplication when its domain and
meaning are identical. Reversing the functions is a semantic error: encoding
a decoded `2` gives `0`, not `2`. A restricted codec can instead use a conditional
law or a domain-specific reference model.

```lawspec include=examples/authoring/round-trip.lawspec
```

## 2. Idempotence

Requirement: repeating normalization makes no further change. Reuse the
`idempotent` law. A second hand-written nested-call equation adds maintenance;
requiring the result to equal the input is a different, stronger claim, refuted
by `-3`. A domain normalization may need custom logic even though its law is
reusable. Idempotence alone permits a constant function, so add domain examples.

```lawspec include=examples/authoring/idempotence.lawspec
```

## 3. Membership

Requirement: decide whether a value occurs at all. Use `member`; the wrapper
below only names the domain question and is not a new search algorithm. A
recursive scan duplicates an available operation. Membership cannot check
multiplicity: both `[1]` and `[1, 1]` contain `1`. A custom search is justified
when matching uses materially different domain semantics. Generic membership
requires the equality capability; do not erase that constraint.

```lawspec include=examples/authoring/membership.lawspec
```

## 4. Occurrence preservation

Requirement: sorting keeps every input occurrence. Use `sameItems`. Repeated
membership tests or set equality silently allow a duplicate to disappear.
`[3, 1, 1]` and `[1, 3]` are the counterexample. An independent multiset oracle
may deliberately implement counting for cross-checking; label it independent.

```lawspec include=examples/authoring/occurrences.lawspec
```

The contrasting false law is rejected by law verification, not by parsing or
mandatory definition admission:

```lawspec fragment include=examples/authoring/negative/lost-duplicate.lawspec
```

## 5. Set semantics

Requirement: summarize distinct readings. Compare `setOf` values; duplicate
counts and input order are deliberately discarded. Using `sameItems` here
rejects a valid deduplication. Conversely, set equality is incorrect for an
occurrence-preserving sort. Use a custom equivalence only when the domain has
an explicit different notion of a distinct reading.

```lawspec include=examples/authoring/sets.lawspec
```

## 6. Text comparison

Requirement: choose exact text or case-folded comparison explicitly. Use the
prelude's Unicode case folding when that is the required meaning. Host lowercase
or locale-sensitive ordering is not a substitute: `Straße` and `STRASSE` expose
the difference. Case folding does not promise locale collation or arbitrary
normalization. Those requirements need a separately specified operation.

```lawspec include=examples/authoring/text.lawspec
```

## 7. Failure composition

Requirement: stop on the first typed rejection and otherwise continue. Use
`bind` (or `>>=`) over `Either`. Repeating nested matches obscures that structure;
returning a success after rejection is a semantic defect, exposed by input `0`.
Accumulating independent validation errors has different semantics and deserves
its own operation. Do not force Result-like composition into simple total code.

```lawspec include=examples/authoring/failure.lawspec
```

## 8. Justified custom ordering

Requirement: every adjacent Int32 value is ascending. The current prelude has
no ascending-list predicate, so this checked recursive helper is appropriate.
Occurrence preservation still uses `sameItems`. An empty output is ordered;
unchanged unsorted input preserves occurrences. Sorting needs both claims.
A domain priority order can justify a different predicate.

```lawspec include=examples/authoring/ordering.lawspec
```

## 9. Generated records

Requirement: use the declared Point in the application. Generate, read its actual
native declaration and constructor, then import it. Copying a same-shaped Point
creates another model and may violate nominal identity. The compiler rejects
returning an unrelated named record even with identical fields. Retain an
application type only through explicit checked bindings or supported codecs.

```lawspec include=examples/authoring/records.lawspec
```

```lawspec reject=definition include=examples/authoring/negative/nominal-record.lawspec
```

## 10. Unions and wrappers

Requirement: preserve both reply alternatives and the RequestId wrapper. Use
the generated constructors. An integer is not automatically a RequestId, and
an untagged payload cannot distinguish alternatives. Do not invent a JSON tag,
class hierarchy or tuple layout; inspect target output. A wire protocol is a
legitimate separate representation with an explicit codec and round-trip laws.

```lawspec include=examples/authoring/variants.lawspec
```

## 11. Exactness and absence

Requirement: exact decimal arithmetic and nested optional values. Use the
runtime representations required by generated signatures. Binary floating
point can lose decimal exactness; collapsing nested presence loses the
difference between `Absent` and `Present Absent`. A lossy display format may
be deliberate, but its conversion must specify the loss and must not claim an
exact round trip. The payment example also tests values beyond safe-number bounds.

```lawspec include=examples/authoring/exact-absence.lawspec
```

## 12. Migrate or explicitly bind

Requirement: application fee calculation agrees with a checked definition.
First consider using the generated Money and feeModel directly. Generate into
an isolated project, read the native signature, update application imports and
constructors, then run application tests. Copying feeModel into another function
is unnecessary unless it is deliberately an independent oracle or its semantics
differ. This skeleton leaves addFee external so its evidence remains explicit.

```lawspec include=examples/authoring/migration.lawspec
```

When a public API must retain Price, use the runnable payment project:

```sh
lawspec examples --example payments --target fsharp
```

Read its `lawspec.edn`, generated model, adapter and application Price. The
binding maps resolved Money, its constructor and fields to Price; it does not
change decimal meaning. Run `lawspec check` and `lawspec test --target fsharp`
in the exported project. For a migration trial, remove the native type/function
bindings in a disposable copy, regenerate, and implement the new adapter stubs
against the resulting generated types before changing application callers.
Removing bindings alone cannot migrate imports or public interfaces.

See [native bindings](bind-native-types.md),
[custom codecs](custom-codecs-and-generators.md),
[generated model entry points](embed-a-generated-model.md) and
[the runnable payment project](generate-example-artifacts.md#export-the-runnable-payment-project).
Native F#/.NET execution is separate from the Learn browser's Fable/JavaScript
harness. This guide does not change the course's pending teaching-review status.
