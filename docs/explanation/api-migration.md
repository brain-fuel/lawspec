---
id: lawspec.explanation.api-migration
kind: explanation
title: API migration
---
# API migration

This page records how the compiler API has changed, for clients upgrading from
earlier versions. The current protocol is specified in the
[API reference](../reference/api.md).

## Source migration from 0.24

`lawspec migrate --from 0.24 --json` reports the checked legacy declarations,
laws, constructor payloads and native bindings, together with a proposed
version-2 configuration selecting the prior law layers. The report remains
read-only.

`sourcePreview` now includes planned edits for checked computation declarations,
their result arrows and named closers, conditional closers, and ordinary text
literals beginning with the reserved `"|` sequence. Effect rows determine
`function` versus `procedure`. Edits use the compiler's original source spans;
comments and other literal contents remain intact. Each source includes the
original UTF-16 offset ranges, replacement text and retained-source segments
for reviewing the changes.

Legacy `==` edits use checked equality-expression operands and parser-owned
value-equality tokens, including Boolean values, IEEE values, refinements and
uninstantiated generic bodies.
Occurrences inside comments or text literals keep their original spelling.

`baseline.sourceSyntax` supplements the concrete Core baseline with the
frontend's original source inventory. It retains generic definitions and
reusable laws even when they have not been instantiated. Checked effect rows
let the computation preview select `function` or `procedure` for those generic
definitions. Nested conditionals and equality tokens use the actual parser's
source ranges. The inventory also records law sections, constructor fields,
patterns, table rows and closers for the remaining transformation stages.

The preview also migrates quoted law and example names, law import/export
markers, explicit reusable-law applications, law section delimiters, universal
binder arrows and scopes, expectation-first tables, legacy case selections and
payload-free alternatives. Moving expectations retains their comments, literal
values and source-coordinate segments. Existing scenario and benchmark label
syntax is preserved. A branch referring to an existing `it` requires an
explicit rename before migration introduces a case's scoped `it`; names with
edge whitespace and tables without expectations also require an authoring
decision.

Record previews now include nominal braces and explicit single or record
payloads for alternatives, together with construction, literal, case-pattern,
field-access and field-update edits. `baseline.sourceFields` maps exact suffix
spans to compiler-resolved constructor fields, including unused generic bodies.
Grouped updates rebuild the outer constructor around its updated record payload;
the replacement is still evaluated before the base, and the base is evaluated
once. Nested and imported fields use their resolved identities. Namespace bindings from the checked import resolver identify constructors
across aliases and facade re-exports, including same-spelled local types. The
planner indexes all supplied source declarations before applying uses, so
source-file order does not decide which record a constructor denotes. Nominal
record fields retain their existing identities. Grouped alternative fields
receive checked native field paths and original argument positions; generation
support for those layouts remains target-specific. Indexed/GADT payload conversions,
dependency-package migration and validated project writing remain unfinished.

Each configured target now has a separate `bindingPreview` entry. The source
baseline is compiled independently of target bindings; the compiler then checks
each actual native request against the legacy source and derives a destination
proposal. API-supplied bindings are checked in the same way, rather than being
sent to the binding-blind schema-3 request. They have a separate input entry
and never replace target configurations or become implicit target defaults.
A binding error in one target keeps project-wide binding correspondence
unestablished.

For a single alternative payload, the proposal changes its logical field label
to `value` and preserves the existing native field and constructor. Accepted
proposals appear explicitly in `proposedConfiguration.targets`; the original
configuration and files stay unchanged. No explicit bindings means there is no
binding configuration to adapt, rather than evidence that generated application
interfaces have been verified. The report records the configuration count.

Grouped native payloads still require a checked layout preserving every native
field and positional constructor argument; their pending proposal records both
the original argument positions and destination record paths. Opaque codecs
receiving changed logical data and factories over changed generated types need
independent correspondence checks. Their destination configuration may pass
validation while implementation correspondence remains unknown. Binding facts
retain the existing runtime-enforcement and assumption classifications and do
not establish native execution, target generation, or law truth.

`generationPreview` separately invokes the compiler's
[`migrationGeneration`](../reference/api.md#migration-target-generation) for
each configured target whose binding proposal matches. It checks both the
legacy and canonical emitter plans, including the original harnesses, output
directories and requested layout. The JSON report retains each side's
diagnostics and complete artifact digest manifest. `correspondence.targetGeneration`
records this gate; zero configured targets report `not-requested`. The plain
report also shows how many target configurations were accepted.

`correspondence.nativeBoundary` separately compares resolved native interfaces
under their original external implementation assumptions. Each generation row
retains its boundary comparison and full compiler receipt. The comparison
includes native field types and order, callable signatures, handlers and data
layouts exposed by generated unbound adapters. Accepted generation can therefore
coexist with a changed boundary. Zero configured targets report `not-requested`.
The plain report shows how many boundary comparisons match. Existing explicit
native argument positions survive payload grouping, and native exception
mappings retain their original first-match order.

Generation acceptance does not establish native implementation correspondence
or execute laws. `correspondence.generatedBehavior` and project-wide writing
remain unestablished until their remaining checks are satisfied.

When the canonical preview compiles, `correspondence.payloads` compares its
checked constructor shapes with the original compiler input, including unused
generic declarations. It derives grouped record identities through ordinary
record elaboration, checks complete stored descriptors and restrictions, and
records field permutations explicitly. A separate `executableTransport`
component compares a copy of the complete checked Core after transporting
constructions, matches, projections and updates. Ordinary record normalization
and mandatory validation must admit that copy. Definition and law-body
matches remain separate from changed population policies, unused source
schemes, native field bindings, generated behavior and project-wide writing.
Intrinsic sorted-set and keyed-map order, comparison, recording, concurrency
and payload traversal can observe the
representation change; affected cases report their limits until explicit
behavior-preserving migrations exist. No native execution or law proof is
claimed by a body match.

Canonical law recordings now retain the existing `value = recorded "name"`
meaning under all valid equality wording, including `must be`. Recording keys
still obey the same name rules; recordings still belong to concrete laws or
examples, rather than one recording for every quantified input.

The preview also converts actual legacy ordered `Set` types to `SortedSet`
and their seven operations to the corresponding `sortedSet` names. Checked
free-reference spans include original declaration identities through imports
and facade exports. The compiler's existing lexical traversal excludes bound
parameters, lets, patterns and quantifiers; a user function named `setOf` does
not become a collection operation. Import and export lists change together
with their uses.

Primitive `BigUInt` annotations become `Whole`, retaining bounds, predicates
and the existing native representation. A user refinement named `BigUInt`
stays intact; the current canonical grammar's conflict with that spelling
remains an explicit compilation diagnostic. General `Natural`/positive-number
and `BigInt`/native-representation migration remain unfinished.

The preserved Chapter 6 preview now passes canonical compilation at both
machine widths while retaining all 23 laws, 65 table rows, one named example,
25 definitions, seven ADTs and two refinements. The
[Python conformance demonstration](../../examples/chap06/README.md) checks its
emitted codec functions and a native assembler against independent instruction
vectors. These finite native checks do not establish source-template,
input-domain or project-wide migration correspondence.

`sourcePreview.canonicalCheck` separately reports whether the partial preview
passes canonical compilation. This check selects no optional law verification
and retains mandatory definition validation. An accepted preview still does
not establish project correspondence. A rejected preview includes diagnostics
for transformations that remain unfinished, such as record payloads.

The report's `baseline.coreSnapshot` and
`sourcePreview.canonicalCheck.coreSnapshot` contain versioned fingerprints of
the compiler's complete checked concrete Core. They include nominal constructor
restrictions, GADT equations, definition policies, model metadata and deferred
runtime postconditions that the documentary API views omit. Source coordinates
and origins are excluded; lexical binder identities and approved law-name
delimiters are normalized. Two strict, once-only selector and record-construction
let forms are normalized without reordering their initializers. Literal values,
nominal identities, operand order and the actual input-domain policy remain.

`correspondence` compares those fingerprints and lists changed, added and removed
definition, contract and data-type comparison identities. A matching fingerprint
covers that concrete Core projection only. Checked source templates,
native bindings and generated behavior remain separate gates;
the overall result remains `not-established` while native bindings and generated
behavior lack correspondence evidence. The law-body fingerprint covers the
complete Core with only root population policies erased. Matching that body
and independently establishing the input-domain correspondence can establish
Core correspondence. A body match alone cannot justify a policy change.

When a payload representation changes, the compiler must supply an admitted
comparison copy anchored to both actual programs. Its definition, body and
whole-program fingerprint pairs must be consistent. Verified domain evidence
then accounts for changed population policies. This establishes correspondence
within the checked Core under the recorded value transport; native adapters
must separately respect that transport. Chapter 6 retains its raw shape and
definition differences while its transported concrete Core corresponds.
Missing or inconsistent certificates, changed bodies and unestablished domains
remain explicit. None of these matches establishes a law's truth.

Schema-5 clients may request the same `migrationSemantics` metadata with
`migrationSnapshot: true`. Explicit legacy `migrationBaseline` requests include
it automatically. Ordinary compile responses do not include these fingerprints,
and requesting them does not change mandatory checks or law evidence. Snapshot
versions and machine widths must agree before comparison.

`migrationSemantics.sourceTemplates` separately fingerprints the complete
checked source units, typed definition bodies and contracts, expanded reusable
laws, and resolved constructor context before specialization. It retains unused
generic definitions and reusable laws that concrete Core omits. The captured
typed bodies are the same values used by mandatory definition admission; the
metadata does not introduce another type checker or execution path. The typed
template cache has a bounded node budget.

`correspondence.sourceTemplates` compares declaration, typed-definition and
expanded-law fingerprints, lists changed unit/definition/law identities, and
keeps actual law-domain policies separate from the projection excluding those
policies. This includes unused versioned prelude laws. Compiler-provided
templates retain the language profile in which their versioned source was
parsed, including its population policy. Applying one in a canonical caller
still gives the caller universal semantics. Unchanged dependency policies can
correspond while their generic input domains remain explicitly unsupported.
Changed authored policies still require the independent evidence below. Literal
values, capability requirements, effects, refinements, parameter relationships
and nonempty effect annotations remain. Comments and coordinates are excluded.
Explicit empty effect rows on checked pure definitions agree with inferred
empty rows; expansion traces normalize only a uniquely recognized law-name
prefix, preserving their argument text. Other source-shape differences remain
conservative blockers. Neither a template match nor a concrete Core match
establishes native binding or generated-behavior correspondence.

`migrationComparison.definitionTemplates` additionally compares the complete
unspecialized definition plane through the ordinary frontend, Core validator
and certified payload transport. Generic type variables remain symbolic; no
sample type or sampled input stands in for a generic declaration. All source
definitions and their dependencies are retained together, including unused
bodies. Source interfaces, capability requirements and source/template
identities have a separate fingerprint because concrete Core does not store
every source requirement. Both complete source-template snapshots anchor this
evidence.

The host accepts a definition-template match only when those anchors, the
matching interfaces and the validated Core fingerprint pairs agree at the same
machine width. `lawTemplates` separately covers complete expanded laws with
fresh abstract declarations for their parameters. Known function bodies remain
present; abstract law parameters do not choose implementations or witnesses.
`sourceUnits` combines those two certificates with complete remaining source
metadata and the compiler-owned payload plan. Stale, partial or mismatched
certificates cannot clear those components.

Declared generic `Eq` requirements now provide lexical operation-typing evidence.
They do not provide `Keyed`, generators or a law of reflexivity. The normal
executable compiler still starts with no symbolic assumptions. Unsupported
numeric or other schemes report their limits. Matching remains structural after
narrow certified rewrites, including total product projections and exact ordered
structural-storage round trips. Other equivalent-looking shapes may still be
unestablished; that does not refute their equivalence. Source matching does not
prove a law or a native implementation's conformance, and does not enable
project writing.

The optional `sourceTemplates.inputDomains` snapshot supplies domain-only rows
for those same expanded templates, including reusable laws without executable
instances. All four surrounding source-template digests anchor the evidence.
The compiler reuses concrete input tuples where available and otherwise lowers
a domain-only copy through its ordinary specialization and mandatory checks.
It does not evaluate a law body or choose one sample function for a law
parameter. Parameter-dependent restrictions and unsupported generic domains
remain explicit blockers. Matching domain dependencies and verified uniform
input witnesses can justify an individual population-policy change; the full
policy-erased template must still match before its laws correspond. Complete
empty domains, bounded misses and unavailable searches cannot justify the
change. Every unused authored reusable law remains visible, so one matched
concrete or reusable domain does not clear the entire source-template gate.
The migration writer remains unvalidated.

`domainPolicyChanges` records legacy nonempty input-domain handling versus
canonical universal quantification. Empty and dependent domains require
explicit correspondence checks before the migration can be validated; a
successful recompile does not establish that correspondence.

`migrationSemantics.inputDomains` provides separate domain-only evidence for
concrete checked laws. An `inhabited` result carries a verified input tuple;
`empty` requires a complete finite product with only Boolean rejection and no
evaluation error. A bounded miss is `incomplete`, and unavailable generation is
`unsupported`. Opaque native handles and existential witness pools cannot be
used as complete covers. Closed examples, the existing finite enumerator,
boundary candidates and restriction hints feed the ordinary checked evaluator.
Every accepted tuple rechecks intrinsic types and dependent restrictions in
lexical order. No law body or example expectation is evaluated by this analysis.

The corresponding fingerprint includes the transitive type, constructor,
definition and contract dependencies of the domain, including deferred runtime
postconditions. Unrelated definition edits do not invalidate it. A changed
predicate or nominal field restriction does invalidate it, even when its name
stays the same. The report clears a changed population policy only when both
snapshots provide verified input witnesses and matching domain fingerprints.
That is population-policy correspondence, not verification of the law or the
complete migration. Abstract reusable-law domains still need their own evidence.

Chapter 6 currently has verified input tuples for all 23 concrete domains.
Seventeen population-policy changes have matching dependencies directly. Six
more match after the certified payload transport. The compiler independently
checks inputs on the mandatory-validated comparison copy and the canonical
program; it does not reinterpret serialized old witnesses. `sourceBeforeDigest`
anchors that copy to the original admitted program, and its target fingerprint
must match the actual canonical snapshot. Witnesses from this comparison are
labeled `transported-before-and-canonical-after`. Changed transitive predicates,
empty domains, incomplete searches and stale anchors cannot clear a changed
population policy. The report retains independent direct matches when transport
evidence is unavailable. These domain facts do not discharge Chapter 6's laws,
unused reusable-law schemes, native bindings or complete migration.

This preview is a step toward the complete project transformation. The report
keeps `validated: false` and lists the remaining correspondence gates.
`--write` reports `migration-incomplete` and writes nothing until the complete
source, constructor and native-binding transformation passes project-wide
semantic and generated-behavior validation. The current authoring syntax is
specified in the [minor-version contract](../reference/language/rc1.md).
That grammar still has plain law, section, quantifier and table endings. The
immediately following minor milestone requires named endings for every block
and rejects every bare `end`; this preview does not preempt that grammar change.

## Schema 2 to schema 3 (0.8.0)

Schema 3 replaced serialized internal Haskell constructors with explicitly
defined wire views. Specification syntax did not change.

- Requests may omit `schemaVersion` or send `3`. An explicit `2` receives a
  diagnostic; it is never reinterpreted.
- Read `result.laws[i].examples` instead of `law.original.examples`. A binding
  is `{id, name, type, value}` instead of `[name, value]`. Values keep the
  lossless tagged scalar encoding from schema 2.
- Expected results are typed expressions inside assertions, such as
  `example.expectations[0].right.node.value`.
- Every expression is `{type, origin, text, node}`. The `typedExpressions` side
  table is gone.
- Assertions are the tree `equal` / `implies` / `all`. The `left`, `right` and
  `guards` projections on laws are removed; traverse the tree instead.
- Inputs are `{id, name, type, predicates, bounds}`. `generationPlan` and
  `inputRefinements` are replaced by these fields.
- Types are discriminated views (`constructor`, `function`, `variable`), not
  `tag`/`contents` encodings.
- Origins are `source` spans or `generated` declarations.
- Rust became a target. Artifacts gained `placement`, separate from
  `ownership`.
- All non-empty test plans emit the scalar runtime. Existing Haskell projects
  need `text` and `bytestring` in the component that compiles it.

## Structural data and definitions (0.9.0)

Still schema 3, with additions that exhaustive visitors must handle:

- `dataTypes`: named declarations with resolved constructor IDs and typed
  fields.
- `DataValue`: example values may be `{kind: "data", type, constructor,
  fields}`. Lists use `List::Nil` and `List::Cons`.
- Expression nodes `construct` and `match`, and later `allElements` and
  `allPayloads` for list and data payload refinements.
- `definitions`: checked definitions, as concrete specialized instances. Join
  calls to them by ID.
- `minify?: boolean` on generation requests.
- `adapterReference` on user-owned artifacts: hash it, rather than `content`,
  to detect interface changes independently of formatting. Existing version-1
  manifests stay readable.

## Native bindings: schema 4 (0.10.0)

- Requests with `nativeBindings` use `schemaVersion: 4`. The JavaScript API
  selects it automatically. Schema 3 remains for requests without bindings, and
  a non-empty binding configuration on schema 3 is rejected.
- `nativeBindings` has `types`, `functions`, `generators`, `rustCrate` and
  `goImports`; v0.22 adds `erlangIncludes` for native record headers.
  Unknown fields are rejected.
- Type bindings take `constructors` or a `codec` pair; generator bindings take
  an optional `stub`.
- Adopting bindings where adapters already exist requires moving the adapters
  aside first; see [ownership](ownership-and-regeneration.md#native-bindings).

## Indexed families (0.11.0)

No wire changes. Kotlin and Haskell adapters whose result is the abstract
`Integer` again return `Number` and `LS.IntegerValue`. Adapters written to
return `BigInteger` or `Integer` still compile.

## Evidence (0.12.0)

Check, expand and generation results gained an `evidence` array. Items have
`owner`, `declaration`, `stage` (`precondition` or `postcondition`), `status`
(`proved` or `runtime-checked`), `reason` and `claim`. Generated definition code
no longer re-checks proved postconditions.

## Construction evidence (0.13.0)

`evidence` items may have stage `construction`, for constructor field and
wrapper constraints, with status `runtime-checked`. The TypeScript declarations
name these records `ObligationEvidence`.

## Imports and packages (0.14.0)

Requests on schema 3 or 4 may add `dependencies`, `packages` and `package`.
When any is present, results add `packages` and `project`. Package errors use
code `package`, import errors `import`. Requests without these fields produce
the same results as before. Imported declarations need no new wire forms.

A compiler older than 0.14 ignores the fields and reports the imports it cannot
resolve.

## Evidence and discharge (0.15.0)

- `status` may now be `proved`, `exhaustively-checked`, `property-tested`,
  `runtime-checked` or `assumed` (`DischargeStatus`). Clients that compared only
  against `proved` and `runtime-checked` must handle the new values.
- New stages: `law`, `adapter`, and with bindings `binding`, `codec`,
  `generator` and `native-function`. `claim` is `null` for obligations without
  one.
- Order: laws, contracts, adapters, constructions, bindings.
- A false law over checked definitions with a finite domain is now a `refuted`
  diagnostic instead of compiling.
