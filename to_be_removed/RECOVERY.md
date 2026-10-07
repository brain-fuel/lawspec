# Recovery after accidental deletion (2026-09-26)

Backup of the surviving Git metadata, source, npm, examples, and package.yaml:
`/private/tmp/lawspec-recovery-1790460473.tar.gz`.

51 deleted tracked files were restored from HEAD without resetting surviving
modified files. All eight embedded runtime sources were recovered verbatim from
src/LawSpec/RuntimeSources.hs, including the Kotlin generator helpers. The
compiler's modified Core, parser, inference, elaboration, emitters, JavaData,
Schema, document renderer, and structural examples survived.

Restored tracked tests/tools/docs are the committed 0.8 baseline, not the lost
0.9 versions. Recreated PLAN-0.9.md records the full release acceptance scope.
Repaired cabal module enumeration and API minify entry point.

Outstanding recovery includes remaining lost 0.9 compiler test cases, native
integration scripts and runtime checks, and tracked 0.9 documentation edits. Historical
.artifacts test logs and generated fixtures survive and can guide reconstruction;
they do not substitute for source tests or fresh verification.

Do not regenerate embedded runtimes from the committed baseline. Do not claim
that the original 183-test suite has been restored until its tests are rebuilt.
The user-owned untracked PUBLISHING.md was lost; do not invent its contents.

## Reverification and reconstructed coverage

The rebuilt compiler matched the surviving pre-deletion binary on 40 generation
requests (five bundled specs across all eight targets). The baseline tests and
reconstructed DocumentSpec, StructuralSpec, and SourceDataSpec now pass 151
examples. These cover kinds/arity, positivity, phantom Eq, recursive boundaries,
constructor validation, IEEE/Symbol equality, absence nesting, match laziness and
coverage, contextual literals, rejected source programs, and both-width bundled
example execution. This is reconstructed coverage, not a byte-for-byte recovery
of the lost test modules.

Rebuilt tools/java-data-fixture.hs and tools/java-data-integration.mjs. Recovered
the native declaration execution check from the surviving generated fixture.
Fresh Java 25 compilation/execution passes for readable and compact declaration
layouts; readable fixtures exactly match Google Java Format.

The Java schema runtime and its checks have now been reconstructed and connected
to JavaData emission. Generated LawSpecDataSchema.java derives from the shared
Core.Schema metadata. Java 25 checks pass with both layout modes and machine
profiles, including malformed nested values, range diagnostics, constructor
identity, copied recursive lists, IEEE NaN/zero equality, symbols, and absence.
This does not yet enable custom data through the main Java property emitter;
its native adapter bridges and generators are still unfinished.

Generated LawSpecDataCodecs.java now supplies typed native conversion bridges for
custom Java declarations, including recursive fields and composed List/Maybe/
Either codecs. Both directions validate; copied containers and checked scalar
bridges preserve UInt64, raw UTF-16, IEEE and Symbol semantics. Native tests pass
in both layouts/profiles and generated readable code matches Google Java Format.
The main property emitter still needs these codecs connected to adapter wrappers
and custom generators before its custom-data target gate can be removed.

The main Java property emitter now consumes custom Core data declarations and
emits native adapter signatures, generated schema/codecs, checked calls,
construction/matching/equality, examples, boundaries, and native JetCheck data
generators. The custom-data Java gate is removed. Reconstructed
`tools/java-data-properties.mjs` compiles/runs the actual compiler output with
correct and deliberately incorrect adapters under both machine profiles.
`DataStrategiesTest.java` verifies valid bounded candidates, native shrinking,
and budget allocation for uneven product field sizes. Main generated test
formatting/minify, custom layouts, declaration-name collisions across units, and
full all-target acceptance still require work.

Data generation now allocates each product field's minimum budget before sharing
remaining nodes, and grows the main generator's bound with JetCheck's size hint.
This avoids excluding uneven products or exhausting uniqueness for lists whose
elements have one inhabitant. Added a 250-case regression for the latter, while
fixed-budget tests verify valid candidates and valid native shrinking.

Java declaration names are now planned across all units: ambiguous short names
are qualified by Core identity, with lossless suffixes for qualification
collisions. Reconstructed property integration covers two units defining Pair
and separate custom source/test roots, alongside the default single-unit layout.
The compiler suite still passes 151 examples after this change; native schema
and codec checks pass in both formatting modes and both machine profiles.
Fresh Java property runs passed for all four width/layout combinations,
including correct native adapters and mutants for wrong trees, ignored product
fields, and dropped nested-list elements. Logs: .artifacts/java-data-properties.log.

Continued implementation after recovery added native Rust and Python data support
and reconstructed their integration suites. Current compiler coverage is 155
examples. Python dependencies for local checks were recovered from existing uv
wheel archives into .artifacts/python-data-deps; no global environment was changed.
This still does not recover every original untracked test or document verbatim.

Reconstruction continued with JavaScript/TypeScript native data and fast-check
integration. The compiler suite now has 157 passing examples. Direct native
fixtures pass in both layouts/profiles, and generated data and standalone
collection projects compile/run with correct adapters and expose eight mutants
per target. Logs: .artifacts/web-data-integration.log and
.artifacts/web-data-properties.log. This extends the recovered implementation;
it does not establish byte-for-byte recovery of deleted untracked files.

Added Go native declaration/schema groundwork and reproducible fixture checks.
Native generic payload rejection, recursion, schema validation, equality, and
readable/compact execution pass. Readable declarations/schema sources match
gofmt. Reconstructed compiler coverage now reaches 159 passing examples. Go's
main custom-data backend remains gated pending checked bridges and generators.

Go typed conversion factories and runtime checks have been reconstructed and
extended. Readable and compact fixtures pass native/schema/codec execution,
including copied containers, scalar fidelity, nested absence, cyclic-value
rejection, and native machine-profile checks. Generated codecs match gofmt.
Compiler coverage is now 160 passing examples; main Go emission is still gated
until the new bridges and Rapid generators are connected.

Reconstructed Go Rapid integration now verifies recursive native generation and
shrinking, uneven product budgets, empty domains, and nested absence costs.
Expected-failure shrink logs prove minimization to length five and Leaf 1, while
normal fixture checks pass. Go remains gated in the main emitter pending wiring
of the recovered native declarations, schemas, codecs, and generator support.

Go's main-emitter connection is now complete for the reconstructed data path.
Fresh generated projects pass with native adapters, contracts, matching, scalar
examples, and collection laws under both machine profiles and custom layouts;
eight adapter mutants fail as intended. The previous main-Go target gate is
removed. Logs: .artifacts/go-data-properties.log. Compiler checks still pass all
160 examples. GO.md is included in the package-build documentation inputs.

Added Haskell native algebraic declarations and named scalar/presence support.
Reconstructed readable/compact fixture checks compile and execute, covering
recursion, phantom Eq, native Text versus linked lists, raw text, and nested
absence. GHC rejects invalid native assignments. Compiler coverage is now 162
examples. This is declaration groundwork, not completed main-Haskell integration.

Reconstructed Haskell schema emission/validation and conformance checks now pass
in readable/compact layouts and both machine profiles. Added a compiled
cross-constructor record-selector collision regression. Compiler coverage is
163 passing examples. Haskell native custom-data codecs and main emission remain
unfinished.

Haskell native codec emission and runtime conformance checks now pass in both
layouts/profiles, with contextual conversion failures and full-binding machine
checks. Fixed and tested CodeUnit16's Word16 bridge. Compiler coverage is 164
passing examples. Haskell generator/main-emitter integration remains unfinished.

Continued reconstruction added separate Haskell Hedgehog strategies, composing
native choices, lists, and primitive generators with cached bounded construction.
Fresh fixture checks pass in both layouts/profiles, including uneven product
minima, deep singletons, empty domains, and actual Hedgehog shrink trees reaching
five-element lists and Leaf 1. The strategy runtime is embedded for subsequent
main-emitter integration; the Haskell custom-data target gate remains in place.

Haskell's main custom-data connection is now reconstructed and enabled, including
checked native calls/contracts, construction/matching/equality, boundaries,
examples, and native Hedgehog properties. Rebuilt integration scripts execute
data/collection projects under both widths and custom layouts, exposing five
mutants per scenario. Scalar adapter/catalog checks expose four further mutants.
Duplicate cross-unit Pair names and finite domains pass in the 32-bit project.
Native generator candidates/shrinks cover every primitive under both profiles.
Compiler coverage is 166 passing examples. HASKELL.md and scaffold dependency
updates are included in the source package inputs; packaged/WASM artifacts have
not yet been rebuilt for 0.9.

Added Kotlin native declaration/schema groundwork and reproducible fixture
checks. Readable/compact native compilation and execution pass, including
recursive fields, phantom parameters, empty types, raw values, nested absence,
Symbol identity, and Kotlin-name shadowing regressions. Four invalid native
payload assignments are rejected. Compiler coverage is 168 passing examples.
Kotlin codecs/generators and the main emitter remain unfinished.

Kotlin typed codecs and their reconstructed native conformance checks are now
implemented. Checks cover recursive round trips, copied containers/raw arrays,
exact and IEEE values, nested absence, identity, contextual invalid-value
rejection, and both machine widths. Five invalid native/codec payload programs
are rejected by Kotlin. Compiler coverage is 169 passing examples. Kotest
strategies and the main custom-data connection remain to be implemented.

Added Kotlin's schema-driven native Kotest generators and reconstructed shrinking
checks. Both layouts/profiles pass budget, empty-domain, recursive-candidate,
list-length, scalar-payload, and constructor-choice shrink checks. A helper
preserves source shrink trees that Kotest 5.9.1 flatMap drops. The runtime remains
separate from native declaration/codecs, and main Kotlin custom-data integration
is still pending. Compiler checks remain at 169 passing examples.

Kotlin main-emitter integration is now reconstructed and enabled. Fresh generated
projects pass under both widths, with custom layouts, duplicate type names,
finite domains, contracts, matching, and native scalar/structural properties.
Data and collection projects expose five incorrect adapters per scenario/profile;
scalar projects expose four mutants per profile. The custom 32-bit data project
executes 1,918 Kotest tests. KOTLIN.md is included in source package inputs; all
packaged/WASM release checks remain outstanding.

Rechecked the recovered checkout after the deletion confirmation: Git reports no
missing tracked files. A fresh native compiler-test build and run passes 184
examples, and the Core/backend boundary check passes for 25 modules. Surviving
modified and reconstructed files have been preserved rather than reset to HEAD.

The latest implementation adds a typed Core total-definition record and a pure
termination/definedness validator, with 13 regression tests. It checks exhaustive
typed bodies, closed definition dependencies, consistent structural descent,
short-circuit guards for partial operations, and safe conversions. Source syntax,
definition elaboration, evaluation, and backend emission remain unfinished;
this audit foundation does not yet enable source-level total definitions.


Continued after recovery with source total-definition parsing/elaboration,
whole-program termination validation, and closed reference evaluation. Checked
bodies now survive in Core and the schema-3 API view. Backend emission remains
explicitly gated for definition-bearing programs until generated implementations
are connected; no adapter stub can silently stand in for a checked body.


Continued with framework-independent Rust total-definition emission and shared
Core expression rendering. Reconstructed integration checks pass under both
machine profiles and readable/compact layouts; native signatures, incorrect
adapters, custom layouts, framework-free compilation, and ownership are checked.
Existing Rust data and scalar suites pass after updating the scalar fixture's
stub matcher for multiline formatted signatures. Compiler coverage is now 191
examples. Remaining backends and full 0.9 acceptance are still outstanding.


Continued with Java definition emission, shared typed expression rendering, and
native checked entry points. Reconstructed integration covers Google-formatted
and compact source, both profiles, custom layouts, native type rejection,
incorrect adapters, framework-independent javac, and regeneration protection.
Existing Java data/scalar checks pass; the scalar fixture now handles multiline
stubs and supplies its own runtime import. Compiler coverage is 193 examples.
The shared definition corpus is preserved in test/fixtures; release work remains.


Continued with Kotlin total-definition emission over shared JVM bodies, preserving
native public types and framework-independent source helpers. Fresh checks cover
both machine profiles, custom roots, native type errors, recursion, mutants,
compact execution, and regeneration. Existing Kotlin data properties and five
mutants pass under 64 bits; compiler coverage is 195 examples. Git still reports
no missing tracked files. Deleted untracked files cannot all be recovered
verbatim; PUBLISHING.md remains unavailable. Release acceptance is unfinished.


Continued with Python total definitions, shared typed expression documents, native
checked entry points, and framework-independent source execution. Reconstructed
checks cover both profiles, readable/compact source, recursive properties,
parameterized product payloads, mutants, native validation, custom roots, and
regeneration protection. Existing Python structural and scalar checks pass;
compiler coverage is 197 examples. The scalar integration tool can now use
LAWSPEC_PYTHON with recovered dependencies instead of requiring a deleted venv.
Full 0.9 acceptance remains outstanding.


Continued with JavaScript/TypeScript total definitions, native typed entry points,
shared expression documents, and single-quoted string escaping. Fresh checks pass
both targets/profiles and readable/compact source, strict TypeScript assignments,
recursive properties, native validation, mutants, and regeneration. Existing web
data/collection and scalar suites pass. The deleted TypeScript integration folder
was reconstructed using cached dependencies. Compiler coverage is 199 examples;
full 0.9 acceptance remains unfinished.


Continued with Go total definitions and shared typed expression rendering. Native
methods retain public types and avoid data/function name collisions. Fresh checks
pass source-only compilation/execution, both profiles and architecture diagnostics,
strict native type errors, properties, mutants, gofmt agreement, compact source,
and regeneration protection. Compact Go documents now preserve tabs. Existing Go
data, shrinking, collection, and scalar regressions pass; scalar fixtures handle
multiline stubs and typed presence. Compiler coverage is 202 examples. Full 0.9
acceptance remains unfinished.

Rechecked the checkout after the deletion confirmation: no tracked files are
missing, and fresh compiler checks pass 202 examples with zero failures. The
39-module Core/backend boundary check and whitespace checks pass. Fixed a
reconstructed Haskell Symbol codec's missing scoped-identity encoder branch;
the standalone scoped Symbol checks now execute successfully. The new Haskell
definition modules typecheck, but their generated output and main-emitter
integration still require verification. A further source checkpoint is saved at
`/private/tmp/lawspec-recovered-source-checkpoint-20260926.tar.gz`.


Continued reconstruction with Haskell total-definition emission, checked native
entry points, shared expression rendering, and example-scoped Symbol identity.
Fresh integration passes both profiles, source-only/native compilation, compact
output, native type errors, mutants, and ownership. Existing Haskell native
shrinking, data, collection, and scalar regressions pass. Compiler coverage is 203
examples. All eight concrete-definition emitters are now connected; generic and
refined definitions and the remaining 0.9 acceptance work are unfinished.


Added explicit declaration type schemes as groundwork for generic definitions,
with fresh per-use variables and retained capability obligations. Existing
quantified values and pattern binders stay monomorphic. Compiler coverage is 214
passing examples; 288 generation requests across all targets/profiles are unchanged
from the preceding compiler. Generic source definitions are not enabled yet.


Added explicit definition capabilities and template typing/capability audits.
Concrete unused requirements are checked; generic execution remains gated pending
totality/specialization. Added the bundled total_functions example and 14 compiler
checks, bringing coverage to 228 passing examples. Existing output remains identical
for 288 generation requests. The new example's generated Haskell tests pass in
both machine profiles. Full 0.9 acceptance remains unfinished.


Added the shared Core.Totality proof checker and typed-template proof lowering.
Concrete source and Core definitions use the same recursion/definedness rules;
generic templates now have direct totality coverage but still await executable
specialization. Compiler coverage is 241 passing examples. The 304 existing
all-target/profile generation requests are unchanged, and 42 modules pass the
Core/backend boundary check. Full 0.9 work remains unfinished.


## Generic definition specialization checkpoint

Generic source definitions now execute through closed specialization before Core
elaboration. Every template is audited for typing, capabilities, termination, and
definedness, including unused templates. Concrete calls create instances with
stable signature-derived names and collision handling. Calls in properties,
examples, and other definitions discover instances; direct recursion reuses one
instance with monomorphic self-calls. Backend code still consumes independently
validated concrete Core. Ambiguous instances and polymorphic recursion fail with
diagnostics. Unused templates produce no adapter stubs or artificial instances.

Compiler coverage is 255 passing examples, including contextual/result-only
inference, constrained promotion, nested data, reusable-law function annotations,
lexical shadowing, example-only calls, recursive reuse, and naming collisions.
The bundled total_functions example now demonstrates generic capabilities and
list counting at multiple element types. Its examples execute in the reference
evaluator and emit on all eight targets under both profiles.

Fresh definition integration suites pass for Java, Kotlin, Python, JavaScript,
TypeScript, Go, Haskell, and Rust under both profiles. They exercise generic
identity and recursive counting behind concrete native entry points, native
properties, compact output, standalone source, mutants, and regeneration.
Long specialization names exposed layout omissions in Rust/Python; their
structured documents now break those expressions correctly. Rust's compact
fixture also now shares the same source as its property fixture. Logs are
.artifacts/{java,kotlin,python,web,go,haskell,rust}-definitions-integration.log.

An unoptimized compiler build exposed a separate IEEE bug: realToFrac depended
on GHC rewrite rules to preserve special floating values. Explicit float2Double
and double2Float conversions now preserve NaN, infinities, and signed zero at
-O0. Added regression coverage and contextual scalar expectation diagnostics.
Core/backend boundary checks pass for 42 modules; git diff --check is clean.

This checkpoint does not complete 0.9. Refined definition signatures and calls
inside predicates, structural refinements, complete output formatting/minify,
WASM/API parity, packaged installation, and release updates remain outstanding.
No release was built or published.


## Definition calls in refinement predicates

The source frontend now permits checked total definitions in refinement
predicates and adapter preconditions/postconditions. Generic calls specialize
from predicates and contracts as well as ordinary laws. Contract-only calls
resolve their instantiated capability obligations before validation. Adapter
calls remain forbidden, including calls hidden behind a short-circuit guard.
Core validates the complete closed definition graph before any domain execution.

Definition elaboration is shared by the frontend and compile-time example-domain
checking. Constant refinement arguments are retained through expansion and
specialization, then evaluated through the closed Core dispatcher even when no
examples exist. Test planning uses the same dispatcher to filter finite domains,
boundaries, and concrete examples; dependent predicates keep their prefix scope.
Bounds/hints still require their existing conservative total-pure criteria and
do not eagerly extract definition calls from guarded predicates.

Compiler coverage is 267 passing examples. New tests cover generic aliases,
postcondition-only capability specialization, constant refinement arguments,
example rejection, dependent finite domains, recursive structural predicates,
empty domains, contracts, forbidden adapters, and unsafe Core definitions.
The total_functions example includes a generic nonempty predicate in a law.

Fresh definition suites pass on all eight targets under both machine profiles,
including predicate-based filtering, calls in adapter preconditions and
postconditions, compact/readable source, source-only compilation, mutants,
custom layouts, and regeneration. The JavaScript sum mutant now fails explicitly
at its postcondition, before the law equality assertion. Integration logs remain
.artifacts/{java,kotlin,python,web,go,haskell,rust}-definitions-integration.log.
Core/backend boundary checks pass for 42 modules; git diff --check is clean.

Remaining work includes refinement-bearing definition signatures and their
proof obligations, structural refinements, complete formatting/minify,
WASM/API parity, packaged installation, and release updates. This checkpoint
implements calls from predicates to total definitions; it does not erase the
unsupported refined-signature gate or claim those signatures are proved. The
0.9 goal remains active and no release was built or published.


## Exact implication groundwork for refined definition signatures

Core.RefinementProof now supplies bounded exact linear implication checking over
rational coefficients. Boolean normalization and Fourier-Motzkin elimination
preserve strict inequalities and arbitrary precision; work exhaustion returns
Unknown rather than accepting an obligation. Rational reasoning is conservative
for integer domains and does not assume that rational variables are integral.
No floating expression is lowered into this proof theory.

Core.Totality uses this checker to establish nonzero exact denominators from
combined guards, affine expressions, and disjunctions. Both typed-template and
Core proof extraction preserve exact arithmetic and safe exact conversions,
while IEEE arithmetic/comparisons remain outside rational normalization. Existing
closed-call and structural-descent audits remain authoritative.

The compiler suite passes 281 examples. New checks cover exact decimal arithmetic,
strict boundaries, dependent inequalities, signed and unsigned narrowing
obligations, both machine widths, negative/rational coefficients, Boolean
assumptions, contradictory domains, work limits, and conservative rational
semantics. Proven implications are checked against independently evaluated exact
assignments. A guarded reciprocal is evaluated across every Int8 value under both
profiles, and NaN/infinity-sensitive false rational identities remain rejected.
The bundled total_functions example and shared native definition corpus now
include guarded promoted division.

This groundwork does not enable refinement-bearing definition signatures yet.
Their assumptions, callee preconditions, result obligations, and checked native
entry points still need connecting before removing the source gate. Structural
refinements, complete formatting/minify, WASM/API parity, packaged installation,
and release updates also remain outstanding. No release was built or published.

Fresh native definition suites pass on all eight targets in both profiles after
adding guarded affine division to the shared corpus. Readable/compact source,
standalone compilation, contracts, mutants, and ownership checks remain green.
An additional direct-Core regression rejects NaN/infinity-sensitive proof
shortcuts. Core/backend boundaries pass for 43 modules. Integration logs remain
.artifacts/{java,kotlin,python,web,go,haskell,rust}-definitions-integration.log.


## Refined definition contract audit foundation

Core.Total.validateDefinitionContracts now independently checks typed definition
contracts before lowering them to Core.Totality.auditWithContracts. Contract
signatures, binder identities/scopes, Boolean predicate types, and constants are
validated before proof extraction. The existing unrestricted audit delegates to
this path with an empty contract set; source admission remains gated.

The shared proof audit evaluates precondition definedness in order, then assumes
each checked condition while auditing the body. Every definition call must prove
its callee's preconditions with actual arguments substituted. Result refinements
are checked for definedness and proved after capture-avoiding substitution of the
body. Contract calls participate in dependency auditing; direct self-contract
calls and mutual dependencies through contracts are rejected. Proof-call arity
is now checked independently as well.

The compiler suite passes 289 examples. Eight new cases cover assumption-backed
division, correct/incorrect affine result claims, precondition ordering, guarded
and unguarded call sites, partial postconditions, malformed contract metadata and
constants, contract dependency cycles, and capture avoidance. All 304 successful
generation requests from the bundled corpus plus native total-definition fixture
remain byte-for-byte unchanged across eight targets and both machine profiles.
Log: .artifacts/contract-proof-parity.log. Core/backend boundaries pass for 43
modules and git diff --check is clean.

This is proof infrastructure, not source-level refined-definition completion.
Proof extraction currently discharges supported exact linear/Boolean/presence
obligations conservatively; unsupported obligations remain unproved. Primitive
domain bounds, callee result guarantees, guarded checked conversions, template
signature elaboration, and native entry-point enforcement still need integration.
The source refined-signature gate remains intact. Structural refinements,
complete formatting/minify, WASM/API parity, packaging, and release work also
remain outstanding. No release was built or published.


## Primitive domains and guarded integer conversions

Typed-template and Core proof extraction now supply primitive argument ranges,
including the selected machine-width profile and BigUInt's nonnegative domain.
The proof checker uses these type-established facts before checking executable
preconditions. Definition result obligations can therefore use ranges already
guaranteed by the declared inputs.

Integer-to-integer conversions now carry explicit range obligations. The checker
proves those bounds under the current guards before treating the conversion as
value-preserving. Fractional and IEEE inputs retain separate conversion checks;
range constraints alone never establish integrality. Typed proof expressions
retain an Integral marker, and exact implication normalization tightens strict
integer comparisons (including negation and disequality) without applying that
rule to arbitrary rational or decimal values. This fixes the otherwise-too-weak
rational relaxation of x < 127 when proving that x + 1 fits in Int8.

The compiler suite passes 295 examples, covering implicit primitive domains,
BigUInt versus BigInt, safe/overflowing conversions, guarded arbitrary-integer
narrowing, rejected fractional conversions, both machine widths, refined result
bounds, and independent exact checks of integer implication normalization.
Reference execution checks every Int8 value under both profiles for guarded
narrowing. The bundled total_functions example and shared native corpus include
explicit skip-overflow and largest-valid-conversion examples.

Fresh native definition suites pass on all eight targets under both profiles,
including the new guarded conversion, readable/compact source, source-only
compilation, contracts, mutants, custom layouts, and regeneration. Logs remain
.artifacts/{java,kotlin,python,web,go,haskell,rust}-definitions-integration.log.
Core/backend boundaries pass for 43 modules; git diff --check is clean.

Remaining refined-definition work includes domain facts for pattern-bound fields,
callee result guarantees, template signature elaboration, and checked native
entry-point enforcement. The source refined-signature gate remains intact.
Structural refinements, complete formatting/minify, WASM/API parity, packaged
installation, and release updates are also unfinished. No release was published.


## Pattern-bound primitive domains and branch result obligations

Typed-template and Core proof extraction now attach primitive field domains to
match branches through a scoped TypedDomain proof node. Nested list/constructor
matches keep those facts local. Totality auditing checks the scrutinee first,
retains structural descent provenance, and then checks the branch using its
validated field types. Fractional fields acquire no artificial integer bounds.

Refined result auditing now enumerates explicit result branches, carrying each
branch's local domains and provenance into result substitution. It does not
treat an entire match as an affine expression or merge sibling assumptions.
The source refined-signature gate remains intact pending complete frontend and
native enforcement; this change extends the independent contract audit.

The compiler suite passes 299 examples. New coverage includes nested and named
matches, rejected Rational-field assumptions, Int8/Int64 branch isolation,
per-branch positive result proofs, and a direct-Core regression that deliberately
reuses one local identity in sibling branches with different field types.
Reference execution checks matched-field arithmetic for every Int8 value under
both machine profiles. The shared native corpus adds reciprocalHead examples for
empty, minimum-field, and maximum-field inputs.

Fresh definition integration suites pass on all eight targets under both profiles,
including readable/compact source, standalone compilation, properties, contracts,
mutants, custom layouts, and regeneration. Logs remain
.artifacts/{java,kotlin,python,web,go,haskell,rust}-definitions-integration.log.
Core/backend boundaries pass for 43 modules; git diff --check is clean.

Remaining work includes callee result guarantees, template signature elaboration,
checked native entry-point enforcement, structural refinements, complete
formatting/minify, WASM/API parity, packaged installation, and release updates.
No release was built or published.


## Shared generated-document formatting selector

CoreEmit now provides emitPlanWithFormat and emitPlanWithOptions; the existing
emitPlan and emitPlanWithLayout entry points retain readable defaults. The shared
Doc.selectLayout selector preserves Go tabs in compact mode. Structured generated
data, schema/codecs, and definition documents consume the selector across all
eight targets, including Rust's schema source and Go's package-local support.
Artifact placement remains independent of document presentation.

The compiler suite passes 308 examples, including new all-target checks for
readable compatibility, smaller compact output, preserved artifact identities,
custom layouts, and stable user-owned adapter stub content. Core boundaries pass
for 43 modules. No tracked files are missing following recovery.

This is internal formatting groundwork: the public generation API/CLI selector
is not yet exposed. Legacy runtime/test/scaffold templates still require migration;
adapter stub layout remains canonical until adapter identity can be separated
from presentation without false update reports. Full formatting, refined source
definition admission/native enforcement, structural refinements, WASM parity,
packaging, and release work remain unfinished. No release was published.


## Explicit formatting mode and canonical adapter references

The native API now accepts minify?: boolean, default false, and generation CLI
and examples forward --minify without persisting it in project configuration.
Generated TypeScript declarations were regenerated from Gen. Formatting and
artifact placement remain independent. Legacy runtime/test/scaffold migration
and bundled WASM parity remain unfinished; init currently rejects --minify.

User-owned artifacts carry an optional adapterReference containing the canonical
readable scaffold. The manifest writer hashes that instead of displayed compact
content, falls back to content for older producers, and preserves version-1
manifests. User implementations remain untouched. Java/Go/Rust structured stubs
now consume the selector. Python/Web stubs were migrated to Docs with legal
signature breaks; comments preserve declared LawSpec types that native types
can erase. Rust includes the same declaration information. Mandatory comment
markers and newlines survive compact rendering.

All 309 compiler tests pass, and the Core/backend boundary check passes for 43
modules. tools/formatting-integration.mjs verifies all eight targets through the
native API: readable defaults, invalid flag types, smaller compact source,
canonical adapter metadata, legacy manifest migration, formatting switches,
real interface changes (including Int8/Int16 native erasure), and protection of
edited generated files. It also executes the real CLI generation/dry-run/check
and examples modules with a native compiler bridge; toolchain discovery is
explicitly stubbed in that CLI plumbing check, not claimed as native validation.
Fresh Python, JavaScript, TypeScript, and Rust native definition suites pass
both machine profiles, including standalone code, properties, and mutants.

Remaining release gates include complete output formatting, refined definition
signature admission/native enforcement, structural refinements, WASM/API parity,
package installation, versioning and release documentation. No release was built
or published.


## Readable Web runtimes and remaining structured adapter stubs

Formatted the JavaScript runtime, schema runtime, and native fast-check helper
sources with pinned Prettier 3.6.2 (two-space indentation, single quotes, 80-column
target). Added tools/format-web-runtimes.mjs for repeatable checks/write mode;
its formatter is a development dependency, never a compiler/runtime dependency.
Regenerated embedded runtimes. tools/embed-runtimes.py --check now verifies the
embedding without writing. Existing Java, Go, and Rust static runtime sources
were checked and already match Google Java Format, gofmt, and rustfmt.
The TypeScript schema annotation retains readable single-line layout.

Haskell and Kotlin adapter stubs now use structured Docs, and Go adapter
parameters have legal wrapping points. Haskell's unimplemented stub names the
function in its error and preserves the declared interface in wrapped comments.
All eight targets now exercise compact adapter rendering in the formatting
integration corpus. Long readable adapter signatures/comments satisfy the
corpus's 80/100-column target; canonical references still preserve implementations
and distinguish interface changes. This is not a claim that every emitted test
or runtime source now satisfies the formatting requirement.

Fresh Go, Haskell, Kotlin, JavaScript and TypeScript definition suites pass under
both machine profiles. The Web native data suite passes both formatting modes
and profiles, including structural schemas, generators/shrinking, and strict
TypeScript compilation. All-target API/CLI/manifest formatting checks pass.
The compiler suite remains at 309 passing examples; Core/backend boundaries pass
for 43 modules. Embedded-source verification and git diff --check pass.

Python YAPF 0.43.0 is not cached; an isolated workspace-local installation failed
because this environment cannot resolve pypi.org. This is not a blocker to other
work. Legacy runtime/test/scaffold formatting, refined-definition admission and
native contracts, structural refinements, WASM rebuilding/parity, packaging and
release work remain unfinished. No release was built or published.


## Readable and compact project scaffolds

Maven scaffolds now render a structured XML tree with one element per line and
two-space nesting by default. Kotlin Gradle scaffolds render readable blocks
and blank lines between sections. templates(target, {minify}) emits compact XML,
JSON, and Gradle blocks when requested. Existing already-readable TOML, Go,
Haskell, and Rust bootstrap source retains its required line structure.

CLI init now accepts --minify and applies it to newly created build files and
configuration JSON. The choice is never saved as a project setting. Existing
build files retain the same user-owned protection. Added
tools/scaffold-formatting-integration.mjs to verify
all eight targets under both modes, JSON/XML semantic equivalence, explicit-mode
handling, preserved build files, nested project placement, and machineBits.
The actual CLI is used for init; it needs no compiler/WASM stub for that path.

Scaffold checks pass. Both generated Maven variants pass offline Maven validate,
and parsing confirms that the new readable POM preserves the previous namespace,
property, dependency, and plugin structure. Gradle validation could not start:
the sandbox denies the socket opened by Gradle's FileLockContentionHandler.
The log is .artifacts/scaffold-gradle-readable.log; this is an environment limit,
not a successful native Gradle check. Kotlin native source execution evidence
from the preceding checkpoint remains separate from Gradle scaffold validation.
All-target source formatting/manifest and CLI generation/examples checks pass
again. Core/backend boundaries and git diff --check pass.

Legacy runtime/test formatting, refined-definition admission/native enforcement,
structural refinements, WASM parity, packaged installation, and release updates
remain unfinished. No release was built or published.


## Structured Python/Web generator and assertion-helper documents

Introduced PortableGenerator and PortableTestHelpers, both downstream of checked
Core and independent of parsing/inference. Python and JavaScript/TypeScript
primitive/container generator expressions now retain call, object, collection,
and lambda break points. The primitive registry and assertion helpers render
those documents with the requested layout. Helpers use four-space Python suites
and readable JavaScript try/catch blocks, preserving evaluation order and
contextual assertion failures. The fixed arbitrary-integer sampling bounds are
rendered as exact powers of two instead of 78-digit tokens; their values remain
plus/minus 2^256. Web generator strings use the existing safe single-quote emitter.

Four new layout checks cover both machine profiles and Python/Web helper maps
at 80 columns. The full compiler suite passes 313 examples. Core/backend
boundaries pass for 45 modules. Fresh Python, JavaScript, and TypeScript native
definition suites pass both profiles. Each target also passes 2,690 scalar and
exact conformance checks in readable/compact output under both machine profiles.
Readable and compact 64-bit runs reject the stub and all scalar mutants: integer
overflow, precision loss, decimal rounding, surrogate replacement, collapsed
absence, and Symbol-description equality.

The scalar fixture installer had assumed single-line JavaScript stubs. It now
fills named placeholder bodies independently of header layout; its Web mutant
replacement accepts multiline function bodies. Python/Kotlin placeholder filling
also avoids signature-layout assumptions. scalar-integration.mjs now accepts
LAWSPEC_MINIFY=1 and writes compact fixtures to separate artifact directories.
Evidence is in .artifacts/portable-scalars-{python,web,compact32,compact64,readable32}.log.
All-target API/CLI/manifest formatting checks, syntax checks for fixture tools,
and git diff --check pass.

This migration does not yet cover all property bodies, contract wrappers,
refinement search code, runtime templates, or other-target test helpers. Refined
source definition admission/native enforcement, structural refinements, WASM/API
parity, packaging, and release work remain unfinished. No release was published.


## Portable property documents and literal-preserving Rust layouts

Python, JavaScript, and TypeScript property bodies, assertions, guards, examples,
boundaries, contract wrappers, seeded refinement search and native filtered
properties now retain structured documents until final layout. Python uses
four-space suites and Web callback bodies use two-space blocks. Native calls
retain checked conversions, result validation, and one Symbol context per case.
Compiler-owned metadata comments wrap without changing executable literals.
Long diagnostic strings use literal additions that preserve their exact contents.

The compiler suite passes 318 examples. Three layout regressions cover portable
property bodies; two further checks cover Rust fixture preservation in readable
and compact custom layouts. tools/portable-message-integration.mjs independently
parses Python/Web output and checks exact diagnostic strings containing quotes,
backslashes, and supplementary Unicode in all six target/mode combinations.
Fresh Python/Web definition suites pass both profiles, including compact output,
native calls, ownership, and mutants. Portable scalar checks and seven mutants
pass in compact 64-bit mode. Refinement suites and their four mutants pass in
readable 64-bit and compact 32-bit modes, including dependent overflow domains
and standalone contracts. All-target API/CLI/manifest formatting checks pass.

A reproduced Rust custom-layout bug rewrote Text fixtures beginning ../src/ as
though they were module paths. Relocation now matches only generated module
path attributes at the start of a line. The native Rust layout check accepts a
native compiler override, verifies these literal payloads, and uses cached Cargo
dependencies offline for both discovery and execution. Readable and compact custom-layout
execution and regeneration/edit-protection checks pass.

Core/backend boundaries pass for 45 modules, embedded runtime sources match,
and git diff --check passes. No tracked files are missing. Remaining work includes
other-target test/runtime formatting, refined definition signature admission and
native enforcement, structural refinements, WASM rebuilding/parity, package
installation, and release updates. No release was built or published.


## Structured Rust property and contract documents

Rust test generation now retains Docs for contract wrappers, assertions, guards,
examples, deterministic/finite cases, dependent seeded strategies, refinement
filters, runner configuration, and native checked bridges. Module declarations
use separate attributes and declarations, sorted in the source module registry.
Native argument/result temporaries keep conversion steps readable and preserve
precondition-before-call/postcondition-after-call behavior. Guard expressions
are evaluated once; per-case Symbol contexts and native proptest shrinking remain
intact. Property output observes the public explicit formatting selector.

RustExpr now exposes a string-literal Doc using compile-time concat! chunks for
long Text/Symbol literals, diagnostic labels and call contexts. Escaping occurs
after splitting Unicode scalar sequences. tools/rust-message-integration.mjs
compiles and runs both modes, checking fixture payloads against independent raw
Rust strings and exact contextual failure prefixes against an incorrect adapter.

The full compiler suite passes 319 examples, including a 100-column escaped-label
Rust property regression. Fresh native definition suites and native custom data
suites pass both machine profiles, with recursive generation/shrinking, checked
bridges, custom layouts and mutants. Compact scalar checks reject the stub and
all six behavioral mutants; compact 32-bit refinement checks reject overflow,
precision, refinement and standalone-contract mutants. Readable 64-bit scalar
and refinement checks also passed earlier in this migration. Compact custom-layout
execution/regeneration passes. All-target API/CLI/manifest checks pass, as do
Core/backend boundaries (45 modules), embedded-source and whitespace checks.

This removes the legacy Rust property string templates, but does not establish
complete rustfmt equivalence of property output. Independent snapshots in
.artifacts/rust-property-format show remaining differences in nested calls,
arrays and layout heuristics. Existing strict rustfmt checks for standalone
Rust definitions/data remain passing. An initial property-format check had
mistakenly inspected the deliberate '// user edit' fixture left by the ownership
test; that observation is invalid and is not evidence of generated formatting.

Remaining release work includes completing formatting across targets, refined
source definition admission/native contracts, structural refinements, WASM/API
parity, package installation, versioning and release documentation. No release
was built or published.


## Rust formatter conformance and contextual document layout (2026-09-27)

The document renderer now supports first-line width constraints, UTF-8 token
measurement, and context-sensitive hanging prefixes. A first-line constraint
expires after wrapping, allowing subsequent lines to use the page width. Hanging
assignments move a short right-hand side only if it fits the new line; explicitly
expanded arguments and mandatory block indentation remain intact. Compact mode
preserves literal bytes and removes optional layout. Six focused layout tests
cover these behaviors and existing layout tests continue to pass.

Rust integer literals within signed 128-bit range use exact native i128-to-BigInt
conversion. Larger integers retain arbitrary-precision decimal parsing in a
readable block. Long literal chunks are measured in encoded UTF-8 bytes and split
before escaping. The native message integration now checks signed-128 boundaries,
values immediately outside them, positive/negative 2^256 against independently
parsed native decimal strings, and a 40-emoji text suffix in both formatting modes.

Added tools/rust-formatting-integration.mjs. It compares untouched generated
artifacts against rustfmt and saves differing pairs; successful comparisons remove
stale pairs. Its default corpus covers total definitions, total-function examples,
collections, finite data, and matching. All 64 artifacts match rustfmt under both
machine profiles, including property bodies, adapters, declarations and support.
This is corpus-scoped evidence, not a claim of universal formatter equivalence.
The four scalar-heavy sources (scalars, scalar_catalog, scalar_adapters,
refinements) still expose nested complex/presence-constructor and dependent-bound
layout differences. Their current snapshots/log are under .artifacts/rust-formatting
and .artifacts/rust-formatting-scalars.log. Those differences remain a release gate.

The full compiler suite passes 325 examples. Fresh Rust total-definition and
native-data suites pass both profiles, including recursive generators/shrinking,
checked bridges and mutants. Compact 64-bit scalar checks reject the stub and all
six behavioral mutants; compact 32-bit refinement checks reject all four mutants.
Native literal/message checks pass both formatting modes. All-target formatting,
canonical adapter ownership, legacy manifests and CLI integration pass. Core
boundaries (45 modules), embedded runtime freshness and git diff --check pass.

Remaining work includes the scalar-heavy Rust layout differences and other-target
formatting, refined source definition admission/native enforcement, structural
refinements, WASM parity, packaged installation, versioning and release documents.
No release was built or published.


## Rust formatting across all bundled examples (2026-09-27)

The remaining scalar-heavy formatting cases are resolved. Complex literals emit
native IEEE from_bits components directly at their declared precision, preserving
bit patterns without unnecessary tagged-value round trips. Large exact decimal
and rational literals name their arbitrary-precision components before native
construction. Nested presence literals name each payload before wrapping it,
retaining every absence state and evaluating each payload exactly once.
Dependent-bound tuples preserve their block indentation. External calls now
materialize arguments into separate locals in left-to-right order before the
shared context is borrowed for the call.

The formatter tool's default corpus now includes every bundled .lawspec example
and the total-definition fixture. All 208 Rust artifacts match rustfmt under both
machine profiles, including algebra, scalars, refinements, structural data,
matching, declarations, adapters, tests and runtime support. This supersedes the
preceding checkpoint's known scalar-heavy corpus differences. RUST.md now reflects
specialized generic definitions, definition predicates and development minify
support; rebuilt WASM/publication remain explicitly pending.

All 325 compiler tests pass. Fresh Rust definition suites pass both profiles.
Readable and compact 64-bit scalar suites pass and reject the stub plus six
behavioral mutants. Compact 32-bit refinement checks pass and reject all four
mutants. Native message/literal checks retain exact Unicode, diagnostics and
signed-128/arbitrary-integer boundaries. All-target API/CLI/manifest formatting
checks pass. tools/algebra-integration.mjs now accepts a native compiler override,
explicit minify and machineBits, keeping output roots separate. Native algebra
and currying pass in readable 64-bit and compact 32-bit modes, rejecting three
algebra mutants (including wrapping) and the currying mutant. These checks
exercise nested external calls after argument materialization.

Core/backend boundaries remain clean for 45 modules; embedded runtime freshness,
syntax checks and git diff --check pass. No tracked files are missing. Remaining
release work includes other-target formatting, refined source definition
admission/native enforcement, structural refinements, WASM/API parity, package
installation, versioning and release documentation. No release was published.

## Go generator and assertion documents

Migrated the native Go scalar/structural generator expressions, primitive
registry and assertion helpers from dense strings to GoTestHelpers documents.
Native Rapid combinators, generator domains, exact numeric construction,
Unicode validation, identity and presence states, and structural generation
budgets are preserved. Documents use tab indentation in readable mode and the
explicit compact selector in minify mode. Go property-body templates remain
legacy strings and are the next formatting migration; this checkpoint does not
claim whole-file gofmt compliance for generated property files.

The Go definitions integration now compares each shared assertion/generator
helper directly against gofmt. Native definition suites pass both machine
profiles, including properties, compact definition source, ownership and
mutants. Readable and compact 64-bit Go scalar/conformance suites pass; readable
execution rejects the stub and six behavioral mutants (overflow, large-integer
precision, decimal rounding, raw text, nested presence and symbol identity).
All 325 compiler tests pass, all-target formatting/ownership/CLI checks pass,
and Core boundaries pass for 46 modules. No release was built or published.

## Go property documents and bundled formatter conformance

Added GoProperties as a checked-Core/Testing consumer. Go examples, finite and
boundary cases, ordinary scalar properties, structural Rapid strategies,
dependent scalar domains, guarded assertions and contract wrappers now remain
documents until rendering. Adapter calls use typed document conversions instead
of falling back to legacy strings. Argument checks, native copies, Unit
normalization, pre/postcondition ordering, fresh symbol contexts and existing
native generation/shrinking algorithms are preserved. Scalar literals are shared
with GoExpr, including structural boundary payloads. Empty data/codec declaration
files no longer have extra trailing blank lines.

The new tools/go-formatting-integration.mjs compares every Go artifact from all
bundled examples and the total-definition fixture against gofmt for 32/64-bit
profiles: 238 artifacts pass. Go definitions integration now checks whole
property files against gofmt and executes a full minified generation plan under
both profiles, in addition to its existing native-only, compile-negative,
mutant and regeneration checks. GO.md documents this development functionality;
bundled WASM remains pending.

Readable and compact 64-bit scalar/conformance suites pass, and the readable
suite rejects the stub plus six behavioral mutants. Readable 64-bit and compact
32-bit refinement suites pass and reject four mutants each. Compact 32-bit exact
algebra/currying passes. All-target formatting/CLI/ownership checks pass. Core
boundaries are clean for 47 modules, and embedded runtime sources are fresh.
Remaining release requirements include Java/Kotlin/Haskell property formatting,
Python runtime formatting, refined definition signature admission/enforcement,
structural refinements, rebuilt WASM parity, package installation and release
versioning/documentation. No release was built or published.

## Java generator and assertion documents

Migrated native Java generator expressions, primitive registry and assertion
helpers to JavaTestHelpers. Existing JetCheck combinators, byte widths/sign
rules, exact decimal/rational construction, Unicode filters, Symbol identity,
presence wrappers, list strategies and structural node budgets are retained.
Helper expressions use structured chains, lambda continuations and blocks.
Legacy property-body templates are still pending; whole Java property-file
formatter compliance is not claimed at this checkpoint.

Added Doc.multiline for block-valued arguments whose enclosing pretty groups
must expand, while nested groups remain independently width-sensitive. Compact
mode still flattens optional breaks and preserves mandatory newlines. A focused
DocumentSpec check covers both layouts. Existing document behavior is unchanged
when this new form is absent.

tools/java-helper-formatting-integration.mjs compares the generated primitive
registry and assertion members against Google Java Format for both machine
profiles. Both pass. Native Java definition suites pass 32/64-bit profiles,
including standalone native calls, properties, compact definition source,
compile-negative cases, mutants and ownership. Readable and compact 64-bit Java
scalar/conformance suites pass; the readable suite rejects the stub and six
behavioral mutants. All-target formatting/ownership/CLI checks pass, and the full
bundled Go (238 artifacts) and Rust (208 artifacts) formatter comparisons remain
clean. Core boundaries pass for 48 modules. Source versions and packaged WASM
remain unchanged; no release was built or published.

## Java property documents and bundled formatter conformance

Added JavaProperties as a checked-Core/Testing consumer. Examples, boundaries,
finite cases, scalar and structural properties, dependent refinement domains,
guarded assertions and contract wrappers now remain documents until rendering.
Java adapter calls use typed document bridges instead of legacy string fallback;
checked conversion, native copying, Unit normalization, contract ordering,
symbol scopes and native JetCheck generation/shrinking behavior are preserved.
Generator chains retain their receiver/method structure when nested inside sums.

JavaExpr now shares scalar literal documents with property boundaries. Long
strings become compile-time concatenations without changing whitespace, escapes
or supplementary characters. Native definition errors name the context before
combining it with the caught exception. Schema/codec imports reflect actual
use. Added Doc.flow for packed primitive arrays and Doc.prefixChoice for qualified
calls whose opening token cannot fit; focused tests cover readable and compact
layouts. Both are opt-in document forms and leave other emitters unchanged.

tools/java-formatting-integration.mjs checks all bundled examples and the total
fixture: 166 Java artifacts match Google Java Format in both profiles. Native
Java definition checks now verify entire property files and execute full compact
generation plans as well as compact standalone definition sources. Both profiles
pass properties, native-only calls, compile-negative cases, mutants and ownership.
The shared JVM definition bodies also pass Kotlin native suites in both profiles.
tools/java-message-integration.mjs independently validates exact long strings,
diagnostic prefixes, Unicode/escaping and signed-128/arbitrary integers using
Java itself in readable and compact modes.

All 328 compiler tests pass. Readable 64-bit Java scalar/conformance checks pass
and reject the stub plus six behavioral mutants. Compact 32-bit refinement checks
pass and reject four mutants; compact 32-bit algebra/currying passes and rejects
all four mutants including wrapping. Go and Rust bundled formatter checks remain
clean (238 and 208 artifacts respectively); all-target formatting/ownership/CLI
checks pass. Core boundaries are clean for 49 modules; embedded runtimes are fresh.
Remaining release work includes Kotlin/Haskell property formatting, Python runtime
formatting, refined definition signature admission/native enforcement, structural
refinements, rebuilt WASM/API parity, package installation and release versioning.
No release was built or published.

## Kotlin generator and assertion documents

Migrated Kotlin primitive/structural generator expressions, scalar registry and
assertion helpers into KotlinTestHelpers documents. Kotest choice, bind and list
combinators retain their existing generation/shrinking behavior; exact integer
byte widths, decimal/rational construction, Unicode filtering, Symbol identity,
nested presence and structural node budgets are unchanged. Pretty mode uses
two-space blocks and structured calls/lambdas; explicit compact mode preserves
required Kotlin syntax. Property-body templates remain legacy strings, and an
external Kotlin formatter is not available in the local caches, so complete
Kotlin formatter conformance is still pending.

The native kotlin-data-properties harness now accepts explicit minify and keeps
compact output roots separate. Adapter fixture filling targets named TODO bodies,
and mutation anchors accept formatted multiline signatures. Its scalar scenario
now includes scalar examples and shared arithmetic conformance vectors, with
correct discovery of generated specs in the default package. These tests use the
cached Kotlin compiler and Kotest libraries directly, avoiding the unavailable
Gradle daemon socket.

Native Kotlin definition suites pass both profiles, including standalone calls,
properties, compact definition source, typed misuse, mutants and ownership.
Readable 64-bit structural data and compact 32-bit collections pass and reject
five mutants each. Readable 64-bit and compact 32-bit scalar/conformance suites
each execute 2690 generated tests and reject all four mutants. All 328 compiler
tests pass; all-target formatting/CLI/ownership checks pass. Core boundaries are
clean for 50 modules and embedded runtimes are fresh. Kotlin property formatting,
Haskell formatting, Python runtime formatting, refined-definition admission and
native enforcement, structural refinements, WASM parity and package/release work
remain pending. No release was built or published.

## Recovery snapshot audit (2026-09-27)

After the deletion confirmation, compared the working source with
`/private/tmp/lawspec-source-kotlin-helper-docs-20260927.tar.gz`: all 298 archived
files were present and byte-identical, with no tracked deletions. No reset or
archive extraction was necessary; recovered development changes remain intact.
The recovered compiler test executable passed 328 examples with zero failures
(`.artifacts/recovery-audit-tests.log`). Embedded runtime consistency and the
50-module, eight-emitter boundary check also passed. This audit verifies the
recovered checkpoint; it does not complete the remaining 0.9 release work.

## Kotlin checked expression documents

Added KotlinExpr as a checked-Core consumer and connected the Kotlin property
emitter to it. Constants, arithmetic, short-circuit Boolean expressions, checked
conversions, constructors, structural equality and matches now remain documents
until rendering. Native adapter calls compose document codec bridges; total
definition calls and contract wrappers retain their established ABI. Matches
continue to use the validating Kotlin codec helper, evaluating the scrutinee once.
Removed the superseded Kotlin branches from the legacy expression walker and
exposed concrete Kotlin type-reference documents for reuse. Property bodies and
boundary fixtures still require their separate document migration; external
Kotlin formatter conformance remains pending.

The compiler suite passed 328 examples. Native readable 64-bit data properties
passed and rejected five mutants. Compact 32-bit collections passed and rejected
five mutants; compact 32-bit scalars ran 2690 generated tests and rejected four
mutants. Native 64-bit total definitions passed standalone calls, negative native
types, properties, compact definition source, ownership and mutants. Logs are
`.artifacts/kotlin-expression-data.log`, `kotlin-expression-compact.log` and
`kotlin-expression-definitions.log`. All-target formatting/CLI/ownership checks
passed; embedded runtimes match and Core boundaries pass for 51 modules.
No release was built or published. Remaining 0.9 acceptance scope is unchanged.

## Kotlin property documents and dependent-domain execution

Added KotlinProperties as a checked-Core/Testing consumer and routed complete
Kotlin test files through it. Imports, helpers, examples, boundaries/finite
cases, assertions, native Kotest tuple strategies, dependent refinement domains
and contract wrappers now stay documents until rendering. Native codec bridges
and structural fixture values compose documents too. Existing generator/shrinker
combinators, per-case Symbol contexts, guarded evaluation and pre/postcondition
ordering are preserved. Exact external Kotlin formatter agreement remains
unverified; this migration does not close that release gate.

The native Kotlin data harness now includes the bundled refinement example and
four runtime-valid mutants: wrapping, precision loss, invalid refined results,
and broken standalone contracts. The precision mutant converts through Double
and back to BigInteger so the native API accepts it and the contract detects the
loss. Definition integration now compiles and runs complete minified generation
plans in addition to standalone compact definition sources.

All 328 compiler tests pass. Native readable 64-bit and compact 32-bit data suites
pass and reject five mutants each; the latter includes finite data and custom
layouts. Refinement suites pass in readable 64-bit and compact 32-bit modes and
reject four mutants each. Compact 32-bit scalar/conformance execution runs 2690
tests and rejects four mutants. Native total-definition suites pass both machine
profiles, including complete minified plans (1129 tests each), native calls,
negative native type checks, mutants and regeneration protection. Logs:
`.artifacts/kotlin-property-data.log`, `kotlin-property-data-compact.log`,
`kotlin-property-compact.log`, `kotlin-property-refinements-readable.log`, and
`kotlin-property-definitions.log`. All-target formatting/CLI/ownership checks
pass; embedded runtimes match; Core boundaries pass for 52 modules.

Remaining 0.9 work includes exact Kotlin formatter conformance, Haskell property
formatting, Python runtime formatting, refined definition signature admission and
native enforcement, structural refinements, rebuilt WASM parity, package checks
and release versioning. No release was built or published.

## Haskell generator and assertion documents

Added HaskellTestHelpers and connected assertion/schema helpers and native
Hedgehog strategies to document generation. Exception handling keeps evaluation
failures contextual; native integral/list/maybe/choice generation and shrinking,
Unicode representations and Symbol scope are unchanged. The remaining property
wrapper temporarily renders generator documents compactly inside its legacy
strings; complete Haskell property and typed adapter-bridge migration remains
pending. No whole-file formatter agreement is claimed at this checkpoint.

The Haskell property harness now accepts explicit compact mode and machine-width
selection, keeps compact artifacts separate, and includes scalar examples and
shared arithmetic vectors in its scalar scenario. Native scalar bindings still
require the host width: a 32-bit probe on this 64-bit host reported six expected
machine-profile failures, all for machineEcho; it is not a passing scalar suite.
The matching 64-bit compact scalar run passed 2978 tests and rejected four
mutants. Readable 64-bit data passed and rejected five mutants. Native total
schema/definition suites passed both profiles, native calls, generic definitions,
negative type checks, properties, mutants, compact source and regeneration.

All 328 compiler tests passed; all-target formatting/CLI/ownership checks passed;
embedded runtime sources match; Core boundaries pass for 53 modules. Logs:
`.artifacts/haskell-helper-data.log`, `haskell-helper-scalars-compact.log`, and
`haskell-helper-definitions.log`. The mismatched-width probe remains recorded in
`.artifacts/haskell-data-properties-compact/scalars/32/correct.log`.
HASKELL.md now distinguishes completed generic specialization from the pending
refined-definition signature admission/enforcement. Other 0.9 release gates,
including external formatter conformance, WASM parity and package/release work,
remain open. No release was built or published.

## Haskell property documents and checked native calls

Added HaskellProperties as a checked-Core/Testing consumer for whole Hspec files:
imports, helpers, examples, finite/boundary cases, native Hedgehog strategies,
dependent scalar domains, guarded assertions and contracts. Typed adapter calls
now compose document codec bridges without falling back to legacy source strings.
Checked arguments are named and forced before native invocation; guards stay
lazy, and contract results are forced before postcondition checks. Refined
property callbacks have an explicit fresh Symbol context. Native generator trees,
shrinking, finite-domain handling and machine-profile checks are preserved.
Long scalar literals/diagnostics and exact formatter acceptance remain pending;
whole-file Haskell formatting conformance is not yet claimed.

The Haskell harness now includes bundled refinements with four runtime-valid
mutants (overflow, precision loss, refined result and standalone contract).
Definition integration executes complete minified generation plans, separately
from its standalone native compact-source checks. Native readable 64-bit data
passes and rejects five mutants. Readable 64-bit and compact 32-bit refinements
pass and reject four mutants each. Compact native 64-bit scalars/conformance pass
2978 tests and reject four mutants. Definition integration passes both profiles,
including full minified plans (1141 cases per profile), standalone native calls,
generic specializations, negative native types, mutants and regeneration.

All 328 compiler tests passed; all-target formatting/CLI/ownership checks pass;
embedded runtime sources match; Core boundaries pass for 54 modules. Logs:
`.artifacts/haskell-property-data.log`, `haskell-property-scalars-compact.log`,
`haskell-property-refinements.log`, `haskell-property-refinements-compact.log`, and
`haskell-property-definitions.log`. Remaining 0.9 gates include Haskell literal
and final formatter work, Kotlin external formatter conformance, Python runtime
formatting, refined-definition admission/enforcement, structural refinements,
WASM parity and package/release acceptance. No release was built or published.

## Haskell lossless literal and diagnostic documents

HaskellExpr now encodes scalar constructors as documents rather than opaque Show
output. Long strings concatenate separately escaped character chunks; large
integer tokens parse exact decimal strings at their required Integer type.
Property fixtures, generator bounds and definition contexts share the new
encoding. String splitting examines a bounded prefix per chunk. Metadata comments
retain unbroken source tokens and URLs; complete external formatter conformance
is still pending, and no Haskell formatter executable was found locally.

Added tools/haskell-message-integration.mjs. Its expected native strings use
numeric code points and its integers use independent native constants, bypassing
the emitter's quoting/chunking code. Readable and compact checks preserve spaces,
tabs/newlines, quotes, backslashes, supplementary Unicode, diagnostic prefixes,
and signed values around 2^127 and 2^256. All executable lines in its readable
fixture fit within 80 columns; the width check intentionally excludes metadata
comments with unbroken source tokens.

All 328 compiler tests pass. Native compact scalar/conformance tests pass 2978
cases and reject four mutants. Definition suites pass both profiles, complete
minified plans, native calls, negative types, mutants and regeneration. A freshly
built fixture also emits standalone native definitions in both layouts/profiles;
all four compile/run without a property-framework package database. Logs:
`.artifacts/haskell-message-integration.log`, `haskell-literal-scalars.log`,
`haskell-literal-definitions.log`, and `haskell-literal-native.log`.
All-target formatting/CLI/ownership checks pass; embedded runtimes match; Core
boundaries remain clean for 54 modules. Remaining 0.9 release gates are unchanged,
including final formatter conformance, Python runtime formatting, refined source
definition signatures, structural refinements, rebuilt WASM/API parity and
package/release acceptance. No release was built or published.

## Closed reference execution of definition contracts

Inspected refined-definition admission: Refinement.lowerUnit deliberately rejects
refined source signatures, template totality currently lacks their assumptions,
and native definition entry points still need contract enforcement before that
gate can safely open. No source capability was enabled prematurely.

Core.Definitions.prepareDefinitions now validates attached definition contracts
with the shared proof engine before preparing closed execution. It checks
preconditions sequentially using the contract's binder identities, evaluates the
body with its separate parameter identities, validates the result type and checks
postconditions. Failures identify the definition and contract stage. A false
precondition prevents evaluation of later predicates. Programs with no definition
contracts avoid a redundant proof audit. Adapter contracts remain outside the
closed definition table; no adapter hook was introduced.

Added four reference-execution regressions for rejected arguments, guarded exact
division in ordered preconditions, aliased binder identities with promoted
results, and rejection of duplicate/unproved contracts. The full compiler suite
passed 332 examples; the focused proof/runtime suite passed after the no-contract
fast path change. CLI rebuilt, Core boundaries remain clean for 54 modules, and
diff checks pass. Log: `.artifacts/definition-contract-runtime-tests.log`.
Native contract enforcement, source admission, structural refinements and the
previous formatting/WASM/package release gates remain unfinished. No release was
built or published.

## JVM native definition contract enforcement

Added Core.DefinitionContracts to select only contracts owned by closed
definitions and audit them through the shared proof engine. The reference
interpreter reuses this selection. JavaDefinitions now validates attached
contracts before returning artifacts and emits ordered precondition checks after
argument validation, then validates the result before postcondition checks.
Contract binder identities map explicitly to argument/result locals; nested
predicate binders retain their own local scope. Kotlin shares these JVM bodies,
so both native wrappers and direct logical entry points enforce the domains.
Ordinary definitions without attached contracts keep their previous output.

Added a direct Core fixture and native integration harness. All eight JVM
language/profile/layout combinations pass: promoted results, safe reciprocal and
narrowing domains, ordered predicate failures, guarded nested calls and direct
logical-entry rejection. Deliberately corrupted generated result bodies are
caught by postconditions. Duplicate contracts and unproved claims fail emission.
Pretty JVM bodies match Google Java Format. Native Java/Kotlin compilation and
execution use no property-framework dependency. Log:
`.artifacts/jvm-definition-contract-integration.log`.

All 332 compiler tests pass; all-target formatting/CLI/ownership checks pass;
Core boundaries pass for 55 modules. Source signature admission remains gated:
template/elaboration changes and native enforcement on the other six targets
must land before enabling it. Other 0.9 formatting, structural refinement,
WASM/package and release gates remain open. No release was built or published.

## Python and web native definition contract enforcement

PythonDefinitions and WebDefinitions now use the shared definition-contract
proof audit and emit ordered precondition checks after argument validation, then
postcondition checks on a validated result. Native wrappers and direct logical
entry points share these checks. Contract parameter/result identities map
explicitly to generated locals, including nested predicate binders. These
runtimes use native Bool representations, so predicates feed their existing
require_contract/requireContract functions directly. Ordinary definitions without
attached contracts keep the previous output.

Extracted the JVM fixture into test/DefinitionContractFixture.hs and reused it
for portable native checks. Invalid duplicate contracts and unproved result
claims reject emission. All twelve Python/JavaScript/TypeScript profile/layout
combinations pass native promotion, exact division, checked narrowing, ordered
predicate rejection, nested calls and direct logical-entry checks. Corrupted
result bodies are rejected by postconditions. TypeScript compiles with strict
checking; all three execute without property frameworks. Log:
`.artifacts/portable-definition-contract-integration.log`. The JVM fixture also
rebuilds and emits successfully against the shared vectors; existing JVM behavior
is unchanged.

All 332 compiler tests pass; all-target formatting/CLI/ownership checks pass;
embedded runtime sources match; Core boundaries remain clean for 55 modules.
Go, Haskell and Rust still need native definition-contract enforcement, followed
by frontend/template admission before refined source signatures can be enabled.
The other formatting, structural refinement, WASM/package and release gates stay
open. No release was built or published.

## Go definition contracts and recovery verification (2026-09-27)

Go definition emission now uses the shared contract proof audit and emits ordered
preconditions and postconditions around validated arguments/results. Native and
logical entry points share enforcement. The shared fixture covers exact division,
promotion, checked narrowing, nested calls, ordered predicates, invalid contract
rejection, and postcondition rejection of corrupted results. All four machine
profile/format combinations passed; readable bodies match gofmt. Verification:
`.artifacts/go-definition-contract-integration.log`; 332 compiler tests passed;
all eight targets passed formatting/CLI/ownership checks; embedded runtime sources
match. Haskell and Rust native enforcement and source admission remain pending.

Rechecked the checkout after the deletion report: no tracked files or files from
the preceding portable-contract snapshot are missing. Surviving changes were
preserved. A fresh source snapshot is saved at
`/private/tmp/lawspec-source-go-definition-contracts-20260927.tar.gz`.
The lost untracked PUBLISHING.md remains unrecovered. Release 0.9 is incomplete;
no release was built or published.

## Haskell and Rust definition contracts (2026-09-27)

Both remaining native definition emitters now audit attached Core contracts
before emission. Haskell sequences preconditions through Either before forcing
the body and validating/checking its result. Rust sequences checks through Result
and adds definition context to failures. Both map contract argument/result IDs
separately from body binder IDs and preserve unchanged output for definitions
without attached contracts. Native wrappers share logical entry-point checks.

New shared-vector fixture tools and native integration scripts cover 32/64-bit
profiles and readable/compact output for both backends (eight combinations).
All pass valid promotion, exact division, narrowing, nested calls, rejection at
native and logical entry points, ordered predicates, proof rejection of invalid
contracts, and postcondition rejection of deliberately corrupted results. Native
source compiles without property frameworks. Rust readable bodies match rustfmt;
Haskell readable fixture lines fit 80 columns (external formatter still pending).
Logs: `.artifacts/haskell-definition-contract-integration.log` and
`.artifacts/rust-definition-contract-integration.log`.

Fresh compiler verification passes all 332 tests. All eight targets pass
formatting/CLI/ownership checks; embedded runtimes match; 55 Core/emit modules
pass boundary checks. All eight native backends now enforce attached definition
contracts. Source admission remains gated pending frontend contract elaboration,
generic template/specialization integration, and whole-program contract-aware
validation. Structural refinements, remaining external formatter conformance,
WASM/package parity, and release acceptance are still open. No release published.

Verified source checkpoint:
`/private/tmp/lawspec-source-native-definition-contracts-20260927.tar.gz`.

## Whole-program definition contract admission (2026-09-27)

Core.Validate now invokes validateDefinitionContracts with definition-only
contracts after structural/type validation. Partial bodies can therefore be
admitted under proved preconditions, while missing contracts, invalid result
claims, duplicate contracts, and unchecked closed callers fail program admission.
Adapter contracts remain outside the closed proof audit. prepareDefinitions uses
this authoritative audit instead of repeating it after an unconditional proof
that previously rejected partial-under-precondition bodies.

Extracted elaborateContract from Frontend into the shared Elaboration module.
elaborateDefinitionUnit preserves definition-only contracts for closed example
and domain execution; final frontend elaboration uses the same lowering for all
contracts. This closes a path that previously dropped attached contracts before
prepareDefinitions. Source refined signatures remain gated: template auditing,
contract derivation from source signatures, and generic specialization still need
coordinated implementation before that gate can be removed.

Six regression tests cover whole-program admission/execution under contracts,
missing/invalid contracts, unchecked callers, adapter isolation, intermediate and
final elaboration parity, and planning/emission on all eight backends under both
machine profiles. All 338 compiler tests pass. All-target formatting/CLI/ownership
checks pass; embedded sources match; 55 modules pass Core boundary checks. No
release built or published. Other 0.9 acceptance gates remain open.

Verified source checkpoint:
`/private/tmp/lawspec-source-program-definition-contracts-20260927.tar.gz`.

## Refined template contract auditing (2026-09-27)

Added definitionContractFor, deriving ordered pre/postconditions from explicit
definition parameter/result types while preserving argument names for dependent
predicates. Result binders cannot shadow arguments; an unnamed result receives
a fresh fallback identity. The template typing phase checks predicates as Bool
under rigid generic parameters, exposes input binders only in declaration order,
and checks predicate/domain capabilities against the declared requirements.

DefinitionTotality now lowers typed preconditions and postconditions alongside
each body into shared ProofContracts, with distinct result identities and common
nested-binder allocation. The shared audit proves body definedness, narrowing,
result claims and callee domains before specialization, even for unused generic
templates. Four new test groups directly exercise parsed templates: nonzero
generic division, dependent parameter bounds, promoted result claims, guarded
narrowing, invalid scopes/types/capabilities, unchecked callees, and contract
cycles. Focused suite: 34 cases pass. Full compiler suite: 342 cases pass.

Public lowerUnit deliberately still rejects refined definition signatures: source
contract lowering and concrete/generic specialization must preserve these proved
contracts before that gate can be removed. The direct template tests exercise
the internal audit without implying public syntax admission. All eight target
formatting/CLI/ownership checks pass; embedded runtime sources match; 55 modules
pass Core boundary checks. Other 0.9 gates remain open; no release published.

Verified source checkpoint:
`/private/tmp/lawspec-source-template-definition-contracts-20260927.tar.gz`.

## Public refined definitions and specialized contracts (2026-09-27)

Specialization now carries an optional contract with every definition instance.
It substitutes concrete types in contract binders and predicates, rewrites generic
helper calls in pre/postconditions, and drains instances discovered only through
those predicates. Concrete-only refined definitions follow the same path. Value
signatures lose refinements only after an attached contract has been retained.
Existing unrefined concrete-only units retain their previous fast path/output.

Removed the public refined-definition gate in lowerUnit. Definition signatures
retain expanded refinements for template auditing and specialization; adapter
signatures alone generate synthetic contract laws. Definition contracts are
proved rather than pretending an external adapter needs testing. Contracts are
then preserved in closed example/domain evaluation and final Core validation.

Added examples/specs/refined_definitions.lawspec with generic exact reciprocals,
proved Int8 narrowing, dependent bounds, and concrete expectations. Six new
tests cover source aliases and unused invalid definitions, distinct contracted
generic instances, helper-only predicate specialization, concrete-only contracts,
and bundled examples under both profiles. Emission checks cover all eight targets.
Updated the older rejection fixture to reject an insufficient precondition rather
than a now-supported valid refined identity. All 348 compiler tests pass; all
eight targets pass formatting/CLI/ownership checks; embedded runtimes and Core
boundaries pass. Reference and per-target documentation now describe public
refined signatures.

Native contract harnesses previously passed all eight targets from typed Core;
the next acceptance step is feeding source-compiled contracts through those native
harnesses, including both profiles/layouts and corrupted-result rejection.
Structural field/element refinements, remaining formatter conformance, rebuilt
WASM/package parity, and full release acceptance remain open. No release published.

Verified source checkpoint:
`/private/tmp/lawspec-source-refined-definitions-20260927.tar.gz`.

## Source-to-native definition contract acceptance (2026-09-27)

All five native contract fixture tools now accept LAWSPEC_CONTRACT_SOURCE=1 via
the shared DefinitionContractFixture module. Source mode compiles the public
test/fixtures/definition_contracts.lawspec fixture through parsing, alias
expansion, template proof, generic specialization and whole-program admission.
The fixture includes the same native entry points plus a specialized generic
reciprocal helper; definition ordering preserves the harnesses' logical slots.
Core mode remains the default, with its separate malformed-contract fixtures.
Source-mode generated projects have separate artifact directories.

All 32 source-mode target/profile/layout combinations passed native execution:
Java/Kotlin 8, Python/JavaScript/TypeScript 12, Go/Haskell/Rust 4 each. Checks
cover valid exact arithmetic, ordered preconditions, narrowing, nested calls,
direct logical calls, and rejection of deliberately corrupted results. Generated
source compiles without property-framework dependencies. Java/Kotlin JVM bodies
match Google Java Format, Go matches gofmt, Rust matches rustfmt, and Haskell
fixture lines fit 80 columns. External Kotlin/Haskell formatter acceptance and
Python static runtime formatting remain separate unfinished gates. Logs are
`.artifacts/{jvm,portable,go,haskell,rust}-source-definition-contract-integration.log`.

Fresh compiler suite: 348 tests pass. Core boundaries (55 modules), embedded
runtime equality and diff whitespace checks pass. No compiler changes in this
checkpoint required rerunning the already-passing general regeneration suite.
Structural field/element refinements, remaining formatter conformance, WASM/API
and packaged installation parity, release metadata and full acceptance remain
open. No release built or published.

Verified source checkpoint:
`/private/tmp/lawspec-source-native-source-contracts-20260927.tar.gz`.

## Sum payload refinements (2026-09-27)

YAPF 0.43.0 is still absent from local caches. The isolated installation retry
terminated with PyPI DNS resolution failures; log .artifacts/yapf-install.log.
Python runtime formatter conformance remains unverified. Work continued on
structural refinements rather than treating that tooling issue as a global block.

Maybe/Either payload refinements now elaborate through Model.typePredicates to
ordinary exhaustive MatchExpr predicates, preserving lazy branch selection and
ordered conjunctions. Fresh payload locals avoid capturing dependencies on outer
inputs; nesting composes through the same lowering. No target-specific surface
refinement interpretation was introduced. Closed example validation, finite
domains and all eight emitters consume the resulting Core matches.

Also closed a pre-existing erasure hole: unary named type applications could
retain unsupported refined arguments past expansion and subsequently lose those
constraints. Only supported Maybe/Nullable/Optional payloads may carry refinements
there; named fields/payloads and List element refinements stay explicitly gated.

Four tests cover Maybe/Either/nested payload examples, invalid values, unselected
variants, outer-name capture, finite domain cardinalities and named payload
rejection. Full suite: 352 tests pass. All-target formatting/CLI/ownership checks
pass; 55 Core boundary checks and embedded-runtime equality pass. Native execution
acceptance for the new sum cases remains pending, along with List and named data
field refinement support, remaining formatters, WASM/package parity and release
acceptance. No release published.

Verified source checkpoint:
`/private/tmp/lawspec-source-sum-payload-refinements-20260927.tar.gz`.

## Native sum payload refinement acceptance (2026-09-27)

Added examples/specs/sum_refinements.lawspec and included it in the existing
native data/property harnesses for all eight targets. Its five laws cover positive
Maybe payloads, branch-specific Either bounds, nested finite Maybe states, finite
Either variants, and dependent payload bounds whose generated names must not
capture an outer input. Explicit examples retain absent and present continuations.
The law assertions independently check the domains native generators produce.

All native suites completed under both machine profiles and readable/compact
output. Existing structural adapter mutations were also rejected. Java additionally
checks both default/custom layouts; Web and Go run data/collection scenarios;
Haskell and Kotlin ran their data scenarios. There are 48 completed suite
configurations across the harnesses (24 per formatting mode), covering the full
32-target/profile/layout matrix plus scenario/custom-layout combinations. Logs:
`.artifacts/{python,web,go,java,rust,haskell,kotlin}-sum-refinement[-compact]-integration.log`.

Fixed outdated Web/Go mutation matchers to handle formatted multiline adapter
signatures. Added LAWSPEC_MINIFY support and separate compact artifact paths to
the remaining data harnesses; compact Rust execution does not incorrectly demand
readable rustfmt layout. Both new refinement examples independently match formatters
under both profiles: 24 Java, 38 Go, 24 Rust artifacts. Logs:
`.artifacts/{java,go,rust}-refinement-formatting.log`.

No compiler code changed in this checkpoint; the previous 352-test suite remains
the current compiler result. Core boundaries, embedded-runtime equality and diff
checks pass. List/named-field refinements, remaining external formatters, WASM
and package parity, and release acceptance remain open. No release published.

Verified source checkpoint:
`/private/tmp/lawspec-source-native-sum-refinements-20260927.tar.gz`.

## Qualified synthesized constructor identities (2026-09-27)

While tracing the structural lowering needed for List payloads, found and fixed
a name-resolution hazard in synthesized Maybe/Either predicates. Adapter contract
predicates are built before qualifyDataNames; unqualified Just/Nothing/Left/Right
could be captured by same-named user constructors. Synthesized branches now use
fully qualified builtin identities, and Elaboration.constructorTag recognizes
explicit builtin IDs alongside user IDs instead of qualifying them a second time.
This also prepares qualified List constructors for future structural lowering.

A regression unit declares all four conflicting constructor spellings and refined
Maybe/Either adapter signatures, then plans and emits all eight targets. Focused
source-data suite: 44 cases pass. Full compiler suite: 353 cases pass. All-target
formatting/CLI/ownership checks pass; 55 Core boundaries and embedded-runtime
equality pass. List element refinement lowering is not implemented yet; named
field refinements and the other 0.9 acceptance gates remain open. No release built
or published.

Verified source checkpoint:
`/private/tmp/lawspec-source-qualified-refinement-tags-20260927.tar.gz`.

## Recovery confirmation and scoped List predicate checkpoint (2026-09-27)

Confirmed all 318 source files in the qualified-refinement-tags snapshot remain
present. No tracked files are missing. Preserved the subsequent in-progress Core
List predicate edits rather than resetting the recovered 0.9 work to HEAD.

Added five regression cases covering scoped element binders, empty/populated
lists, short-circuiting, contextual failures, malformed Core rejection, guarded
division, and primitive element bounds in totality proofs. Fresh cached-GHC
builds pass 358 compiler examples. All eight target formatting/adapter-ownership
checks, CLI formatting checks, embedded-runtime checks, and compiler boundaries
pass. Public List payload refinements remain gated; native predicate emission
is not implemented yet. This is an implementation checkpoint, not a release.

Verified source backup:
`/private/tmp/lawspec-source-recovery-list-core-20260927.tar.gz`.

## Native scoped List predicates (2026-09-27)

All seven expression renderers (covering eight targets) now emit the Core
AllElements operation. Framework-independent runtime helpers iterate with
short-circuiting and empty-list truth. Definition binder planning includes
scoped element binders; nested predicates preserve references to outer elements.
Rust uses fallible mutable closures and deterministic rustfmt-compatible layout.
The common Core pretty-printer also recognizes the operation.

Expanded the five native definition-contract fixtures with guarded per-element
division and nested List predicates referencing the outer row length. Correct
native execution, existing contract mutants, and callback-count short-circuit
checks pass in 32 target/profile/layout configurations: all eight runtimes,
both machine profiles, readable and compact. The Kotlin fixture also executes
KotlinExpr output directly, in addition to its shared Java definition bodies.
Logs: .artifacts/{portable,go,haskell,jvm,rust}-list-predicate-integration.log.
Java bodies match Google Java Format; Go bodies match gofmt; Rust bodies match
rustfmt. The compiler suite passes all 358 examples. Embedded runtime sources
and compiler boundaries pass.

Surface List payload refinements are still gated. Next: an internal scoped
surface predicate node, inference/substitution/elaboration, then enable List
payload predicates with full native property and contract acceptance. Named
data field/payload refinements and the remaining PLAN-0.9 release gates remain
unfinished. This checkpoint does not imply a completed 0.9 release.

Verified source snapshot:
`/private/tmp/lawspec-source-native-list-predicates-20260927.tar.gz`.

## Source List payload refinements enabled (2026-09-27)

Connected the internal AllElementsExpr through inference, scoped substitution,
qualification, specialization, template auditing, and Core elaboration. Lists
now admit nested element predicates, mixed Maybe/Either payloads, and earlier
input dependencies. Added public JSON and npm expression declarations, API
migration notes, documented semantics, and list_refinements.lawspec.

Fresh verification: 365 compiler examples pass; npm declarations type-check;
embedded runtimes and compiler boundaries match; formatting/ownership and CLI
checks pass on all eight targets. Source property integrations pass 48 suite
configurations across all eight runtimes, both profiles, and readable/compact
modes, including existing adapter mutants. Logs:
.artifacts/{python-data-integration,web-data-properties,go-data-properties,
java-data-properties,rust-data-integration,haskell-data-properties,
kotlin-data-properties}-list-refinements[-compact].log.

Java whole-list rejection sampling exhausted JetCheck attempts on nested
refinements. Generation now maps native list trees through recursive element
preparation/filtering, preserving every already-valid list and the empty-list
witness. Final whole-input checks remain. A runtime regression proves native
shrinking to length five, empty refined domains, and valid-list preservation.
Fixed Haskell definition Bool qualification and Rust nested-list documents.
Full bundled formatting checks pass for 208 Java and 246 Rust artifacts; the
new Go example passes gofmt. External Python/Kotlin/Haskell formatter checks
remain outstanding as previously recorded.

The prover still conservatively rejects closed calls requiring implication
between universal List contracts. Named field/payload refinements, remaining
formatter work, WASM/parity, package acceptance, and 0.9 release metadata remain
unfinished. No release or publication performed.

Verified source snapshot:
`/private/tmp/lawspec-source-list-payload-refinements-20260927.tar.gz`.


## Universal List contract proofs (2026-09-27)

The shared proof view now retains AllElements, ListNil, and ListCons instead of
approximating universal predicates as matches. True universal facts stay keyed
to the same List variable. Proof checking introduces a fresh hypothetical
member, substitutes its binder without capture, and combines applicable element
facts locally. No membership assumption escapes that scope and no inhabitation
claim is made. Exact numeric implications and nested universals compose;
matching pure Boolean helper calls can be reused only when the proof view
preserves their argument identity. Erased computations are not equated.

Template and concrete Core audits now admit compatible List contract calls,
including generic helper specializations. Universal postconditions are proved
for returned inputs, empty Lists, and explicit cons/literal construction. Added
list_contracts.lawspec as both a source fixture and a bundled executable example.
Negative regressions cover weaker domains, unrelated Lists/scalars, vacuous
empty domains, shadowed proof IDs, capture-avoiding substitution, and distinct
floating predicates with otherwise identical erased proof views.

Verification: 373 compiler examples pass, plus a focused diagnostic-code check
for the erased-computation regression. Source-derived definition fixtures pass
32 native/profile/layout configurations across all eight targets, both widths,
and readable/compact modes, including invalid-input rejection and existing
corrupted-result checks. Logs: .artifacts/{portable,go,haskell,jvm,rust}-list-contract-integration.log.
Java array argument layout was adjusted to match Google Java Format. Full
bundled checks pass for 226 Java, 316 Go, and 260 Rust artifacts. All-target CLI,
formatting/ownership, compiler boundaries, and embedded-runtime checks pass.

List pattern membership facts, callee-result guarantees, named field/payload
refinements, remaining external formatter checks, WASM/parity, package acceptance,
and release metadata are still unfinished. Version remains 0.8.0; no release
or publication was performed.

Verified source snapshot:
`/private/tmp/lawspec-source-universal-list-contracts-20260927.tar.gz`.


## Scoped List pattern facts (2026-09-27)

The shared proof view now distinguishes ListMatch from a generic data match.
Concrete and template lowering preserve the Nil/Cons split. Nil records the
matched variable as empty; Cons instantiates universal element facts for a fresh
head and transfers the original predicate to a fresh tail. Outer dependencies
are retained. Facts remain local to the branch, and both fields retain strict
structural provenance for recursive-call auditing. Result-case proof checking
uses the same scoped facts. Capture-avoiding substitution includes both binders.

Definitions can now safely divide by nonzero heads, recursively process refined
tails, call refined row helpers, and prove positive-head/positive-tail result
contracts. Expanded the shared source fixture and bundled list_contracts example
with exact reciprocal sums, nested rows, and branch-specific postconditions.
Negative checks reject unsafe Nil branches, unconstrained heads, unrelated Lists
and scalars, changed dependent bounds, non-decreasing recursion, and leaking empty
facts across identities or branches. Direct proof tests cover shadowing/capture.

Verification: 379 compiler examples pass. Source-derived definition integration
passes all 32 target/profile/layout configurations across eight runtimes and both
formatting modes. Logs: .artifacts/{portable,go,haskell,jvm,rust}-list-pattern-integration.log.
The updated bundled example passes independent formatter checks for 18 Java,
20 Go, and 14 Rust artifacts. Embedded runtime and compiler-boundary checks pass.
No emitter/runtime changes were needed to execute the newly admitted programs.

Callee-result guarantees, named field/payload refinements, remaining external
formatter checks, WASM/parity, package acceptance, and release metadata remain
unfinished. Version is still 0.8.0; no publication or release was performed.

Verified source snapshot:
`/private/tmp/lawspec-source-list-pattern-facts-20260927.tar.gz`.

## Recovery integrity recheck (2026-09-27)

All 321 source files in the list-pattern-facts checkpoint remain present.
Only src/LawSpec/Core/Totality.hs differs from that checkpoint: the pending
callee-result guarantee implementation. The current compiler builds and all
379 compiler examples pass. Embedded runtime consistency, compiler boundaries,
and git diff whitespace checks pass. These existing tests do not complete
verification of the new callee-result guarantee feature; targeted acceptance
and rejection tests are still required before considering it finished.

A byte-verified snapshot of the current source, before this log entry, is saved
outside the checkout at:
`/private/tmp/lawspec-source-recovery-current-20260927.tar.gz`.

## Callee-result proof checkpoint (2026-09-27)

Implemented proof-only call-result bindings, branch-local result guarantees,
structural induction for recursive List results, and scoped Boolean/universal
postcondition checking. Added regression cases for missing preconditions, invalid
helper guarantees, non-decreasing recursion, unrelated divisors, and branch
leakage. Fixed nonzero-fact extraction looping on literal-vs-literal comparisons.
Updated source/native fixtures and bundled examples. Rust complex constructor
fields now use ordered locals to match rustfmt.

Native verification passed 32 target/profile/layout configurations. Logs:
.artifacts/{portable,go,haskell,jvm,rust}-callee-result-integration.log.
All 260 bundled Rust artifacts pass formatter comparison. Embedded-runtime,
compiler-boundary and whitespace checks pass. Release work remains active.

Four processes launched before the loop fix remain stuck: 63357, 63417, 63473,
63521. The sandbox denied termination; the user was given the exact kill command.
They are obsolete test/probe binaries, not ongoing verification jobs.

Final compiler verification: 384 examples, 0 failures.
Verified source snapshot: `/private/tmp/lawspec-source-callee-results-20260927.tar.gz`.

## WASM and package recovery checkpoint (2026-09-27)

The cached WASI compiler now builds current sources. Cabal dependencies and source
lists were synchronized with package.yaml; two specialization helpers have
explicit monomorphic signatures for newer GHC. tools/wasm.sh supports a supplied
native compiler and build-integrity checks include lawspec.cabal.

Fresh verification: 384 compiler tests, 38 existing npm tests, two new structural
API tests, 768 native/WASM generation comparisons and 96 check/expand comparisons
pass. The installed tarball smoke test passes JavaScript and Rust execution,
regeneration, all-target examples export, API use and packaged documentation.
Network access was unavailable, so package verification used exact dependencies
already present in the local npm/Cargo caches. No publication occurred. Metadata
remains 0.8.0 while 0.9 implementation and release preparation are unfinished.

Logs: .artifacts/wasm-rebuild.log, .artifacts/structural-wasm-parity.log,
.artifacts/npm-rebuilt-wasm-tests.log, .artifacts/npm-structural-api-tests.log,
.artifacts/package-structural-smoke.log. Compiler source, WASM and generated API
fingerprints match. The generated API declaration passes TypeScript checking.

Byte-verified source snapshot:
`/private/tmp/lawspec-source-wasm-package-20260927.tar.gz`.

## Constructor proof checkpoint (2026-09-27)

Added tagged constructor/match proof nodes, fresh branch binders, and scoped
payload-predicate instantiation to the shared template/Core totality checker.
Known constructors select their actual branch and fields. Existing runtime and
emitter logic executes the newly admitted definitions without representation
changes. Direct named field contracts remain a separate unfinished task.

389 compiler tests pass, including named Range field relations and safe helper
composition, nested sums, negative constructor cases, and capture avoidance.
Native refined Maybe/Either execution passes 32 configurations across eight
targets. Updated example formatter checks pass for Java, Go, and Rust. Logs:
.artifacts/{portable,go,haskell,jvm,rust}-constructor-contract-integration.log,
.artifacts/{java,go,rust}-constructor-formatting.log.

Current WASM rebuilt successfully. tools/parity.mjs now accepts optional fixture
paths for focused checks while retaining the complete bundled matrix by default.

Targeted native/WASM verification passed 128 generation cases and 16 check/expand calls. Log: .artifacts/constructor-wasm-parity.log.
Byte-verified source snapshot: `/private/tmp/lawspec-source-constructor-proofs-20260927.tar.gz`.

## Python style preference (2026-09-27)

The user selected PEP 8 for Python, superseding the Google/YAPF target.
PLAN-0.9.md and PYTHON.md now record four-space indentation, 79-column code,
72-column prose comments/docstrings, and normal top-level spacing. Python
compiler document layouts now use 79 columns; Web layouts remain 80.

The scalar runtime's compressed statements were expanded and long expressions
wrapped. Its AST was compared with the pre-edit source and is unchanged; every
runtime line fits 79 columns. Embedded sources were regenerated. This is not yet
proof of complete PEP 8 conformance: remaining runtimes, generated documents,
and an independent PEP 8 checker still need auditing. WASM/package fingerprints
are stale after these compiler/runtime edits and must be rebuilt before release.


## Verified Python PEP 8 checkpoint (2026-09-27)

Supersedes the incomplete audit note above. Official PyCQA pycodestyle 2.14.0
was fetched read-only from its tagged GitHub source (no GitHub CLI). The checker
is saved at `.artifacts/python-format-tools/pycodestyle.py`; it is a development
check, not a runtime dependency. No npm publish or Git mutation was performed.

- All three static Python runtime modules pass with max-line-length 79 and
  max-doc-length 72.
- `tools/python-formatting-integration.mjs` passes for 218 generated Python
  artifacts at both widths, including complete readable/compact AST equality.
- Compiler suite: 389 examples, zero failures.
- Scalar suite: 2,690 cases each for readable 64-bit and compact 32-bit output.
- Python native custom data and List/Maybe/Either properties/mutants pass both
  widths. Standalone definitions, compact execution, ownership/regeneration and
  overflow/tree/sum mutants pass both widths.
- WASM rebuilt; compiler/API/runtime fingerprints match. Focused parity passes
  128 generation cases across all eight backends, both widths/layouts, plus 16
  check/expand calls. Full 0.9 feature/release acceptance is still unfinished.
- Embedded runtime verification, 55-module boundary check and diff whitespace
  check pass.

Logs: `.artifacts/python-formatting-integration.log`, `recovery-tests.log`,
`python-pep8-scalars.log`, `python-pep8-scalars32-compact.log`,
`python-pep8-data.log`, `python-pep8-structure.log`, `python-pep8-definitions.log`,
`python-pep8-wasm-build.log`, and `python-pep8-parity.log` in `.artifacts/`.

Recovery snapshot: `/private/tmp/lawspec-source-python-pep8-20260927.tar.gz`.


## Structural reference checkpoint (2026-09-27)

Expanded LANGUAGE.md for implemented 0.9 structural data and total definitions;
updated README development status and removed stale unsupported-feature claims
from Java/Python/Go/Web/Kotlin guides. Five reference snippets pass all eight
targets at both widths (80 generation cases). A reserved `guide.data` unit name
was caught and corrected to `guide.trees`. Source/package docs agree bytewise;
`npm pack --dry-run` includes every changed guide. Compiler fingerprints and
whitespace checks pass. No compiler or version/publication changes in this turn.

The goal remains active: direct named field/payload contracts, remaining output
formatter conformance, and final 0.9 metadata/full release acceptance are still
outstanding. Recovery snapshot:
`/private/tmp/lawspec-source-language-reference-20260927.tar.gz`.


## JavaScript/TypeScript style audit (2026-09-27)

Added tools/web-formatting-integration.mjs using pinned Prettier 3.6.2 and the
independent TypeScript parser. Google JavaScript guidance requires at least
four-space continuation indentation, while Prettier uses different layouts;
exact Prettier equality is therefore informational, not a Google-conformance
criterion. The 194 differences remain available as generated/formatted snapshots
for inspection; full indentation/column acceptance is still outstanding.

Fixed web adapter error strings to use the shared single-quote renderer, tagged
scalar generator literals to use WebExpr documents instead of raw JSON, binary
operators to precede line breaks, and redundant blank lines before helpers.
Python retains its PEP 8 operator layout. JS/TS fixture adapter replacements now
accept both old and new quoting, without changing user-owned adapter behavior.

The full audit passes for 484 artifacts at both widths across all bundled specs
and the total-definition fixture. Checks cover quote choice, operator wrapping,
trailing whitespace/tabs, and readable/compact AST equivalence with literal
contents, declaration flags and unary operators retained. Three negative checks
ensure the comparison distinguishes changed literals, let/const, and unary signs.
This is partial style evidence, not proof of every Google-style requirement.

389 compiler tests pass. Native JavaScript/TypeScript data and collection suites,
including incorrect adapters, pass both widths in readable and compact modes.
Portable diagnostic literal checks pass Python/JS/TS in both layouts. All-target
formatting, canonical adapters, legacy manifests, signature updates, edit
protection and CLI generate/dry-run/check/examples checks pass. WASM rebuilt and
fingerprints match; focused parity passes 128 generation cases and 16 check/expand
calls across all eight targets and both widths/layouts. Embedded runtime,
55-module boundary, and whitespace checks pass. Version remains development 0.8;
no publishing or Git mutations occurred.

Logs in .artifacts/: web-formatting-integration.log, web-formatting-report.json,
web-style-message-check.log, web-style-properties.log,
web-style-compact-properties.log, web-style-regeneration.log,
web-style-wasm-build.log, web-style-parity.log, recovery-tests.log.

Byte-verified source snapshot:
`/private/tmp/lawspec-source-web-style-20260927.tar.gz`.
Remaining goal scope includes direct named field/payload contracts, complete
formatter acceptance, and final 0.9 metadata and full release acceptance.

## Named payload contracts and formatting checkpoint (2026-09-27)

Nonrecursive named products and sums now compose refinements on type arguments
into exhaustive Core match predicates. Nested acyclic named types, lists,
Maybe/Either payloads, finite domains, outer dependencies, and definition
pre/postconditions are covered. Predicate binders cannot capture caller names;
constructor fields with the same spelling retain their separate scope. Definition
contracts stay in implementation bodies rather than generating adapter wrappers
for functions that are not adapters.

The bundled data_types example uses Pair Positive Bool and proves exact division
safe from the selected payload predicate. SourceDataSpec covers valid/invalid
examples, finite enumeration, binder collisions and all-target emission. Native
data checks passed on all eight targets with deliberately incorrect adapters.
Integration scripts now select the data module rather than fragile law ordinals.

Inline refinement-bearing expression annotations are rejected instead of silently
erasing predicates. Compiler-synthesized result annotations use base types while
separate definition contracts retain the predicates. All 399 compiler tests pass.
Direct constructor-field refinements and recursively constrained named parameters
remain explicit diagnostics and unfinished implementation work.

Fixed Haskell wrapped implication guards so their closing parentheses stay inside
the statement's layout. Native scalar properties and four mutants pass at 64 bits;
refinement properties and four mutants pass at both widths. Kotlin data, collections,
scalars and refinements all pass at both widths. The current Python corpus has
222 artifacts passing pycodestyle 2.14.0 at 79 code/72 prose columns and matching
readable/compact syntax trees; all three Python runtime source files pass too.

WASM rebuilt after the inference and layout fixes. Focused parity covers data_types,
scalars, refined_definitions and two automatic fixtures: 160 generation combinations
across all eight targets, both widths and layouts, plus 20 check/expand comparisons.
Compiler/WASM fingerprints, the 55-module boundary check, and git diff --check pass.
REFINEMENTS.md documents the named payload behavior and annotation restriction.
Version remains 0.8.0 during development; no publication or Git mutation occurred.

Evidence in .artifacts/: recovery-tests.log, named-payload-haskell-recheck.log,
named-payload-kotlin.log, named-payload-python.log, named-payload-java.log,
named-payload-rust.log, named-payload-go.log, named-payload-web.log,
named-payload-wasm-recheck.log, named-payload-parity-recheck.log,
python-style-report.json.

Remaining: recursive named payload and direct field contracts, full formatter
acceptance (including remaining JS/TS indentation/columns and Kotlin checks),
final 0.9 metadata/release notes, and complete release acceptance.

Byte-verified source snapshot: `/private/tmp/lawspec-source-named-payload-20260927.tar.gz`.

## JS/TS column-limit enforcement (2026-09-27)

The independent TypeScript-parser audit now enforces 80 columns in generated
JS/TS, with explicit Google-style exceptions for module imports/re-exports and
indivisible source excerpts on their own comment line. Negative checks reject
long code and ordinary prose; exception checks retain searchable excerpts.
492 artifacts pass at both machine widths across all bundled examples and the
total-definition fixture, with readable/compact syntax-tree equality. Prettier
still differs on 202 artifacts and remains informational; complete indentation
conformance is not established by this check.

Fixed long contextual error expressions, TypeScript annotation breaks, and
serialized scalar string values. JavaScript value strings concatenate chunks
bounded by escaped width; property names remain single tokens. Chunking does
bounded work per chunk, avoiding repeated traversal of the remaining payload.
Two runtime template diagnostics now wrap without changing their exact messages.
A native definition fixture repeats its apostrophe/backslash/newline/supplementary
Unicode/U+2028 Symbol description to exercise splitting across escaped chunks.

399 compiler tests pass. JS/TS data and collection properties and mutants pass
both widths. Definition/native-call/compact/regeneration/mutant suites pass both
widths, including exact long Symbol descriptions. Scalar suites pass 2,690 tests
per target for readable 64-bit and compact 32-bit output. Focused native/WASM
parity passes 128 generation cases plus 16 check/expand comparisons. WASM was
rebuilt again after the equivalent bounded-traversal optimization; source and
artifact fingerprints match. Embedded sources, boundaries, and whitespace checks
pass. WEB.md documents the audit and exceptions.

Logs: .artifacts/web-columns.log, web-columns-focused.log,
web-columns-properties.log, web-columns-definitions.log, web-columns-scalars.log,
web-columns-scalars-compact.log, web-columns-parity.log, web-columns-wasm.log,
web-formatting-report.json, recovery-tests.log.

Named constructor field refinements remain unimplemented: construction/schema
validation must enforce them in addition to lowered input predicates. Recursive
named payload constraints, complete remaining style checks, final 0.9 metadata,
and release acceptance remain open. No version bump, publishing, or Git mutation.

Byte-verified source snapshot: `/private/tmp/lawspec-source-web-columns-20260927.tar.gz`.

## JS/TS continuation and statement-block indentation (2026-09-27)

Added a TypeScript-AST-based continuation audit shared with the development-only
runtime formatter. Checks cover wrapped arguments/parameters, initializers,
operator expressions, conditional arms, arrow bodies, method chains, if/while
conditions, and ordinary statement blocks. Grouped operator chains retain the
original grouping line as their indentation baseline. Arrays/object blocks and
callback bodies are distinct from continuation lines. Negative and positive
fixtures verify these distinctions.

The three reviewed web runtimes now use at least four-space continuations.
The formatter shifts whole child expressions, preserving nested block indentation,
compares parsed JavaScript tokens before/after, and rejects shifts inside multiline
template literals. Its repeatability and 80-column checks pass. No formatting
parser/tool is introduced into generated projects. Two emitters also needed fixes:
TypeScript adapter parameters and chained property-generator method arguments
now use four-space continuation indentation.

The full 492-artifact JS/TS corpus passes continuation, statement-block, column,
quote, operator and whitespace checks plus readable/compact AST equality. The
406 Prettier differences are informational (Prettier uses different continuation
indentation). Other style cases, such as switch/type-declaration indentation,
remain outside this audit and still need final acceptance.

399 compiler tests pass. Native JS/TS data and collection suites pass both widths
with mutants; native readable scalar suites pass 2,690 tests per target. All-target
formatting, canonical adapters, legacy manifests, signature update/edit protection
and CLI generate/dry-run/check/examples checks pass. WASM rebuilt; fingerprints,
embedded runtime sources, 55-module boundaries and whitespace checks pass.

Logs: .artifacts/web-continuations.log, web-continuations-self-check.log,
web-continuations-properties.log, web-continuations-scalars.log,
web-continuations-regeneration.log, web-continuations-wasm.log,
web-continuations-parity.log, recovery-tests.log.

Scope remains open for named field/recursive payload contracts, remaining full
formatting acceptance, final 0.9 metadata and release acceptance. No publishing
or Git mutation occurred.

Focused native/WASM parity passes 128 generation combinations and 16 check/expand comparisons across all eight targets and both widths/layouts.

Byte-verified source snapshot: `/private/tmp/lawspec-source-web-continuations-20260927.tar.gz`.

## Kotlin independent layout checks (2026-09-27)

Aligned Kotlin output with the published Google Android Kotlin guide: four-space
blocks and wrapped argument/parameter indentation, 100 code columns. This corrects
the earlier two-space Kotlin output. Java support retains its Java layout and
Python retains PEP 8. Kotlin-only document emitters and adapter wrappers changed;
reviewed Kotlin support sources were reformatted with parsed-tree equality checks.

Added tools/KotlinFormatCheck.java and tools/kotlin-formatting-integration.mjs.
They use the independently installed Kotlin compiler's PSI parser (local 2.4.10),
without downloading a formatter or adding dependencies to generated projects.
Both output modes parse and compare as syntax trees, retaining signs, modifiers,
type arguments and string-template contents while ignoring trivia, semicolons
and optional trailing commas. Negative fixtures distinguish signs, val/var,
changed literal contents and escaped dollars from interpolation. The full corpus
has 346 Kotlin artifacts at both machine widths; parsing, syntax parity, block
and wrapped argument/parameter indentation, columns, whitespace and explicit
sorted imports all pass. Runtime block/argument formatting is idempotent.

Fixed long Kotlin diagnostics with escaped string-expression chunks, contextual
error wrapping, class-reference wrapping, lambda-body breaks, and metadata comment
widths that account for enclosing indentation. Nested filtered generators now
force a multiline argument rather than misaligning callback bodies. The Kotlin
codec List branch and long native signatures also wrap within the column limit.

399 compiler tests pass. Focused native/WASM parity passes 128 generation cases
and 16 check/expand comparisons across eight targets and both widths/layouts.
All-target formatting/regeneration, canonical adapters, legacy manifests,
signature update/edit protection and CLI formatting-mode checks pass. WASM rebuilt;
compiler/artifact fingerprints, embedded runtime sources, 55-module boundaries,
and whitespace checks pass. KOTLIN.md documents the selected guide and toolchain.

Current native evidence: Kotlin data and collection properties and mutants pass
both widths. The final scalar/refinement runs and compact data run are recorded
below when completed. Earlier in this change, scalar properties and four mutants
also passed both widths before the final class-reference/argument layout fixes.

Logs: .artifacts/kotlin-formatting.log, kotlin-layout-native.log,
kotlin-layout-compact.log, kotlin-formatting-scalars.log,
kotlin-layout-parity.log, kotlin-layout-regeneration.log, kotlin-layout-wasm.log,
recovery-tests.log. The corpus manifest is
.artifacts/kotlin-format-check/manifest.tsv.

Remaining style work includes Kotlin operator wrapping and other layout details;
this audit does not certify every guide rule. Named field and recursive payload
contracts, final 0.9 metadata and complete release acceptance remain open.
No publishing or Git mutation occurred.

Final native matrix: Kotlin data, collections, scalars and refinements pass at 32 and 64 bits with all scenario mutants. Minified 32-bit data tests and five mutants also pass.

Byte-verified source snapshot: `/private/tmp/lawspec-source-kotlin-layout-20260927.tar.gz`.

## Kotlin operators, control braces and Gradle scripts (2026-09-27)

Added PSI-based operator and brace checks, with positive/negative fixtures.
The initial operator audit found 24 generated refinement-test violations.
Short-circuit and conjunction documents now keep operators before line breaks.
Multiline scalar-generator branches and match fallbacks now have explicit blocks;
Kotlin presence/list support uses braced multiline conditionals and when branches.
Integer generation uses a multiline braced initializer while preserving the exact
native BigInteger construction. Runtime comments now follow block indentation.
The audit checks if/when and loop braces as well as block comments' indentation.

Gradle Kotlin scaffolds were still using two-space indentation and were outside
the .kt-only audit. They now use four spaces, and the checker parses both .kts
scaffolds explicitly as scripts. The independent corpus now contains 348 artifacts.
All pass parsing, readable/compact syntax-tree equality, block/argument/comment
indentation, columns, explicit sorted imports, operator wrapping and braces.

399 compiler tests pass. Native Kotlin refinement properties and four mutants pass
readable 64-bit and compact 32-bit output. Native data and collection suites pass
at 64 bits with five mutants each; compact 32-bit scalar properties and four
mutants pass after the brace changes. Final whitespace-only adjustments are
covered by the independent syntax-tree audit. Focused native/WASM parity passes
96 generation combinations and 12 check/expand calls across all eight targets and
both widths/layouts. All-target scaffold initialization/config preservation and
nested project/machine-profile checks pass. WASM rebuilt; source fingerprints,
embedded runtimes, 55-module boundaries and whitespace checks pass.

Logs: .artifacts/kotlin-operators-before.log, kotlin-operators.log,
kotlin-operators-native.log, kotlin-operators-compact.log,
kotlin-braces-before.log, kotlin-braces.log, kotlin-braces-native.log,
kotlin-braces-compact.log, kotlin-braces-wasm.log, kotlin-braces-parity.log,
kotlin-scaffold-layout.log, recovery-tests.log.

The overall 0.9 goal remains open: named constructor field contracts, recursive
named payload refinements, remaining cross-target style acceptance, final version
metadata/release notes and complete packaged release acceptance. No publication
or Git mutation occurred.

Byte-verified source snapshot: `/private/tmp/lawspec-source-kotlin-braces-20260927.tar.gz`.

## Constructor contract proof groundwork (2026-09-27)

Core.Totality now accepts explicit constructor contracts with ordered predicates
and declaration-owned field identities. Construction must prove the instantiated
predicates. Pattern matching introduces them only for the selected constructor,
with fresh field identities; the guarantees remain available when proving result
contracts. Contract arity, duplicate identities, scope and predicate totality are
checked. Constructor dependency cycles are rejected pending inductive proof;
calls from constructor predicates into definitions are explicitly rejected pending
combined dependency auditing. Existing definition auditing uses an empty
constructor-contract table and retains its behavior.

Eight new tests cover valid/invalid construction, unknown inputs, constructor and
pattern arity, alternative isolation, binder shadowing, ordered definedness,
dependent fields, result contracts, malformed metadata and circular predicates.
All 407 compiler tests pass. Native and WASM compilers rebuild successfully;
source fingerprints, embedded runtimes and the 55-module backend boundary pass.
The proof log is `.artifacts/constructor-contract-proof-tests.log`; the WASM log
is `.artifacts/constructor-contract-proof-wasm.log`.

This is groundwork, not source admission: direct refined constructor fields
remain rejected. Typed metadata/lowering, native boundary validation, generators,
shrinking, concrete examples and recursively refined named payloads still need
integration before that rejection can be removed. Remaining style acceptance and
0.9 release/package gates remain open; no version bump or publication occurred.

Final focused native/WASM parity passes 96 generation combinations and 12
check/expand requests (all eight targets, both widths and layouts). Log:
`.artifacts/constructor-contract-proof-parity.log`. Recovery snapshot:
`/private/tmp/lawspec-source-constructor-proof-20260927.tar.gz` (archive contents verified byte-for-byte).

## Typed constructor predicates and reference execution (2026-09-27)

Core.DataConstructor now retains ordered typed predicate expressions alongside
its field binders. Core.Total validates their Bool result, binder scope, literal
representations and arithmetic evidence before extracting constructor proof
contracts. Primitive field domains use the selected machine width. Construction
proofs and match/result proofs consume those checked contracts.

The reference interpreter validates constructor predicates at construction,
external results, local values and closed definition entry/result boundaries.
Validation descends through structural values and presence wrappers, checks the
field shapes first, then stops at the first failed predicate. Generic predicate
expression types, local binder types and arithmetic evidence are instantiated
from the actual data type arguments. Predicate execution receives no adapter
hook. The shape-only validation API refuses constrained values when no predicate
evaluator is available, rather than silently dropping their contracts.

Ten new typed-Core tests cover stored positive fields, failed construction,
malformed predicates, primitive bounds, both machine profiles, dependent fields,
ordered division guards, nested containers/presence, generic substitution and
incorrect external results. All 417 compiler tests pass. Six standalone native
data fixture generators compile after the Core constructor shape update. The
native and WASM compilers rebuild, 96 generation comparisons plus 12 check/expand
requests pass, and fingerprints, embedded runtime checks and the 55-module
backend boundary pass. Logs: `.artifacts/constructor-core-tests.log`,
`.artifacts/constructor-core-fixtures.log`, `.artifacts/constructor-core-wasm.log`,
and `.artifacts/constructor-core-parity.log`.

Source refined fields remain rejected. Testing plans, native schema conversion
and the all-target emission entry point explicitly refuse this new Core metadata
until native validators/generators/shrinkers enforce it. These guards are
unfinished-work diagnostics, not the intended final feature. The remaining work
includes source lowering/template proof integration, all-target runtime and
generator support, recursively refined named payloads, remaining style acceptance
and final 0.9 packaging/release gates. No version bump or publication occurred.

Recovery snapshot: `/private/tmp/lawspec-source-constructor-core-20260927.tar.gz`; all archived source files
were verified byte-for-byte against the worktree.

## Source constructor field lowering (2026-09-27)

Direct constructor field refinements now lower into typed Core predicates.
Declaration processing first resolves all constructor shapes, then checks each
field predicate against that field and earlier fields. Generic field type
identities and named type references remain qualified. Refinement aliases and
capability requirements are checked through shared front-end capability
resolution. Both machine profiles are passed through declaration checking.

Core.Total now exposes checked constructor proof contracts to template auditing,
so a source match can use a stored positive/dependent field invariant and source
construction must establish it. Malformed or partial predicates are rejected
also in unused declarations. Concrete property values, including expected
constructor literals, are validated after the complete constructor cycle audit;
a regression test prevents executing a cyclic contract during validation.

Seven source tests replace the former blanket rejection, covering construction,
matching, dependent field scope, aliases, malformed declarations, concrete
examples, machine widths, generic fields and nested element predicates. Together
with the Core audit-order regression, all 424 compiler tests pass. The native
and WASM compiler builds succeed, source fingerprints and embedded runtimes match,
and the 55-module syntax/inference boundary passes. Logs:
`.artifacts/source-field-tests.log` and `.artifacts/source-field-wasm.log`.
`test/fixtures/constructor_fields.lawspec` checks a stored dependent gap and its
exact reciprocal; native API checking succeeds at both machine widths.

REFINEMENTS.md documents this development front-end support and its current
limit: native emission/testing plans still reject field contracts until all
runtime validators, generators and shrinkers enforce them. That gate remains
unfinished work, alongside recursively refined named payloads, remaining style
acceptance and final 0.9 packaging/release checks. No version bump or publication
occurred.

Focused native/WASM parity passes 128 target/width/layout comparisons and
16 check/expand requests. For the new field-contract fixture, generation parity
means identical explicit unsupported-runtime diagnostics, not native execution.
Log: `.artifacts/source-field-parity.log`. Recovery snapshot:
`/private/tmp/lawspec-source-field-lowering-20260927.tar.gz` (verified byte-for-byte).

## Python native schema field checks (2026-09-27)

The Python runtime Constructor metadata now accepts ordered predicate callbacks.
Schema validation first checks every field shape, then runs predicates in order
and stops on failure; only the actual Bool True passes. Instantiated type
arguments, logical field values, machine width and the Symbol fixture context
are explicit callback inputs. Native conversion, construction, matching and
equality enforce the same checks, including nested containers and presence.
Callbacks preserve their metadata when constructor fields are instantiated.

Hypothesis strategies filter constrained constructor tuples with schema
validation, preserving the framework's generation and shrinking. An impossible
prefix (Int8 127 with a required larger Int8) rejects the whole tuple rather
than committing to a prefix with no possible continuation. The optional Symbol
context propagates through recursive validation, both equality operands and
strategies, so description equality cannot replace fixture identity.

Nine direct native tests pass, including both widths, ordered division guards,
malformed callbacks, generic metadata, nested bridges, Symbol identity,
dependent shrinking and impossible-prefix retry. The generated Python data
integration matrix passes (2179 tests at 32 bits, 2164 at 64 bits), with its
incorrect-adapter mutants rejected; that matrix now includes the callback
checks. The final added prefix test also passes in the direct runtime suite.
All 222 generated Python artifacts pass pycodestyle 2.14.0 and readable/compact
AST comparison; edited runtime/test Python also passes PEP 8. All 424 compiler
tests and 96 native/WASM generation comparisons plus 12 check/expand requests
pass. Native/WASM rebuilds, fingerprints, embedded runtimes, backend boundaries
and diff whitespace checks pass.

Logs: `.artifacts/python-field-callback-tests.log`,
`.artifacts/python-field-native.log`, `.artifacts/python-field-formatting.log`,
`.artifacts/python-field-compiler-tests.log`, `.artifacts/python-field-wasm.log`,
and `.artifacts/python-field-parity.log`.

This is the native callback/runtime path, tested with explicit metadata.
Generated predicate callbacks and caller Symbol-context plumbing are not wired
in yet. Source generation for field contracts therefore stays explicitly gated.
Remaining work includes those emitters, all other native runtimes, planner
boundaries/finite domains, generator hints, recursively refined named payloads,
remaining formatting acceptance and final 0.9 release/package gates.

Recovery snapshot: `/private/tmp/lawspec-python-field-runtime-20260927.tar.gz`, verified byte-for-byte.

## Generated Python constructor callbacks (2026-09-27)

Python's data emitter now consumes typed constructor predicates and emits ordered
callbacks into its schema factory. Core.Schema exposes shapes and contract
metadata together through an explicit API; existing shape-only consumers still
reject contracts. The emitter audits predicates at the selected machine profile
before producing files. Python type/name rendering moved into PythonTypes to
avoid a declaration/expression emitter import cycle.

The shared expression renderer now supports schema callback contexts with runtime
width and instantiated type references/keys, while ordinary expressions retain
closed-type rendering. Generic list fields substitute declaration parameters;
scalar and structural operations retain their existing runtime semantics.
Symbol fixture contexts now flow through expression schema operations, definition
entry/result bridges and structural assertion helpers. Callback names avoid
native data names and remain local to the schema factory.

`tools/python-constructor-fixture.hs` lowers
`test/fixtures/python_constructor_fields.lawspec` through the real front end and
emits reusable native data/schema/definition files. The integration runner is
`tools/python-constructor-integration.mjs` (requires the compiled fixture through
LAWSPEC_PYTHON_CONSTRUCTOR_FIXTURE, plus LAWSPEC_PYTHON and LAWSPEC_PYCODESTYLE).
Generated code checks full-width Int8 dependent gaps, exact reciprocal results,
Symbol fixture identity, generic nonempty lists, nested positive elements, sum
variants, guarded division and machine bounds. It runs without importing property
frameworks until the separate native generation/shrinking checks start.

All four width/layout configurations pass; each exposes ignored-gap and
Symbol-description mutants. Twelve generated artifacts pass PEP 8 and independent
readable/compact AST comparison. Existing Python data matrices pass (2180 tests
at 32 bits and 2165 at 64 bits) and reject their adapter mutants. The ordinary
222-artifact Python formatting corpus and all 424 compiler tests pass. Native
and WASM rebuilds, fingerprints, embedded runtimes, whitespace checks and the
56-module backend boundary pass. Focused parity covers 128 generation responses
and 16 check/expand requests; constrained-source generation responses remain the
explicit gate diagnostic, rather than a claim of public CLI generation support.

Logs: `.artifacts/python-generated-fields-integration.log`,
`.artifacts/python-generated-fields-existing.log`,
`.artifacts/python-generated-fields-formatting.log`,
`.artifacts/python-generated-fields-compiler.log`,
`.artifacts/python-generated-fields-wasm.log`, and
`.artifacts/python-generated-fields-parity.log`.

The low-level Python source-to-native path is now executable, but public generation
stays gated pending common finite-domain/boundary planning and generator context/
hint integration. Other native backends still need constructor enforcement and
emission. Recursively refined named payloads, remaining formatting acceptance and
final 0.9 packaging/release gates also remain open. No version bump or publication
occurred.

Recovery snapshot: `/private/tmp/lawspec-python-generated-fields-20260927.tar.gz`, verified byte-for-byte.

## Constructor domain checkpoint — 2026-09-27

Snapshot: `/private/tmp/lawspec-constructor-domains-20260927.tar.gz`. Finite constructor-contract planning and Python rejection/error separation are implemented. All 431 compiler tests, Python contract/native/formatting matrices and focused native/WASM parity pass. See the latest PLAN-0.9.md checkpoint for remaining work and logs. Version remains 0.8.0.

## Bounded constructor witnesses — 2026-09-27

Snapshot: `/private/tmp/lawspec-constructor-witnesses-20260927.tar.gz`. Common constrained-boundary search now produces validated witnesses with bounded recursion and combinations; no-witness diagnostics do not claim emptiness. All 435 tests and focused native/WASM parity pass. See PLAN-0.9.md for logs and remaining work.

## Python witness strategies — 2026-09-27

Snapshot: `/private/tmp/lawspec-python-witness-strategies-20260927.tar.gz`. Hypothesis strategies accept validated, budgeted nested witness seeds in an explicit Symbol context. Direct and generated runtime tests, PEP 8, existing Python matrices and focused native/WASM parity pass. Public emitter context wiring remains open; see PLAN-0.9.md.

## Public Python field contracts — 2026-09-27

Snapshot: `/private/tmp/lawspec-python-field-emitter-20260927.tar.gz`. Public Python generation now supports constructor predicates with shared per-draw Symbol contexts and checked native strategies. Four width/layout execution matrices, negative adapters/disjunctions, formatting, 435 compiler tests and focused parity pass. Other native targets remain gated; see PLAN-0.9.md for remaining scope.

## Web field-contract runtime — 2026-09-27

Snapshot: `/private/tmp/lawspec-web-field-runtime-20260927.tar.gz`. Shared JS/TS runtime checks constructor predicates with nested Symbol context, classified rejection errors and native fast-check filtering/shrinking. All native runtime/property matrices, 492-artifact style/AST checks and focused native/WASM parity pass. Public web contract emission remains gated pending callbacks and context/witness integration.

## Typed web field callbacks — 2026-09-27

Snapshot: `/private/tmp/lawspec-web-generated-fields-20260927.tar.gz`. JS/TS data emission now renders audited typed constructor predicates with generic substitutions and caller Symbol context. Eight native configurations, sixteen callback mutants, style/AST audits, compiler tests and focused parity pass. Public web property generation remains gated pending witness/context wiring.

## Web witness strategies — 2026-09-27

Snapshot: `/private/tmp/lawspec-web-witness-strategies-20260927.tar.gz`. Fast-check strategies support validated nested witness seeds and bounded whole-candidate rejection while preserving native shrinking. Runtime/generated/native matrices, formatting and focused parity pass. Public web context wiring remains open; see PLAN-0.9.md.

## Public web field contracts — 2026-09-27

Snapshot: `/private/tmp/lawspec-web-field-emitter-20260927.tar.gz`. Public JS/TS generation now supports constructor contracts with native fast-check chains and shared per-case Symbol maps. Eight native configurations, mutants/disjunctions, finite/absence cases, style/AST checks, compiler tests and parity pass. Five native backends and remaining release scope are still open; see PLAN-0.9.md.

## Rust field-contract runtime — 2026-09-27

Snapshot: `/private/tmp/lawspec-rust-field-runtime-20260927.tar.gz`. Typed constructor callbacks, classified candidate validation and context-aware logical/native bridges are implemented. Twenty-two runtime tests, existing Rust native matrices and focused parity pass. Public Rust emission remains gated pending callback/generator integration.

## Rust definition contexts — 2026-09-27

Snapshot: `/private/tmp/lawspec-rust-definition-context-20260927.tar.gz`. Generated argument/result/native boundaries now preserve caller Symbol context. Both widths and layouts pass native execution; three independent context-reset mutants fail behaviorally. All 435 compiler examples and focused native/WASM parity pass. Typed schema callbacks and Rust public property integration remain open.

## Rust typed schema callbacks — 2026-09-27

Snapshot: `/private/tmp/lawspec-rust-schema-callbacks-20260927.tar.gz`. Audited Core predicates now emit as typed Rust schema callbacks. Four source/native configurations, eight callback mutants, rustfmt/compact parity, 435 compiler examples, 22 runtime tests and focused native/WASM parity pass. Public property generation remains gated pending checked strategies/witness/context integration.

## Rust checked constructor strategies — 2026-09-27

Snapshot: `/private/tmp/lawspec-rust-checked-strategies-20260927.tar.gz`. Native proptest filtering, classified failures and typed nested witnesses are implemented. Four configurations pass 26 runtime/strategy tests and eight mutants; existing readable/minified native matrices and parity pass. Named sampled witnesses retain a documented shrinking limitation. Public Rust property context/witness integration remains open.

## Public Rust constructor contracts — 2026-09-27

Snapshot: `/private/tmp/lawspec-rust-public-contracts-20260927.tar.gz`. Rust public properties now share Symbol contexts through witnesses, native strategies, adapters and assertions, and report evaluator errors explicitly. Four configuration matrices, adapter mutants, random-only error/disjunction checks, rustfmt/compact parity, 435 compiler tests and native/WASM parity pass. Four remaining native backends and remaining 0.9 scope are still open.

## Java constructor-contract runtime — 2026-09-27

Snapshot: `/private/tmp/lawspec-java-field-runtime-20260927.tar.gz`. Ordered typed callbacks, classified validation and context-aware codecs are implemented. Both-width runtime checks, six mutants, existing native matrices, Google formatting, 435 compiler examples and parity pass. JavaExpr no longer depends on JavaData, enabling the next callback-emission step. Public Java contracts remain gated pending emitter/generator integration.

## Java typed schema callbacks — 2026-09-27

Snapshot: `/private/tmp/lawspec-java-schema-callbacks-20260927.tar.gz`. Audited Core predicates now emit as Java schema callbacks with generic runtime references and shared Symbol maps. Generic constructor matching now preserves declared parameter identities. Four callback configurations, eight mutants, 436 compiler examples, Java definition integrations, formatting and parity pass. Public Java codec/context/generator integration remains open.


## Java native constructor contexts — 2026-09-27

Snapshot: `/private/tmp/lawspec-java-context-codecs-20260927.tar.gz`. Profile-aware schemas, native codecs and logical/native definition boundaries preserve the caller Symbol context. Four native configurations and four context-reset mutants pass, alongside 436 compiler examples, both-width Java/Kotlin definition suites, Google formatting and native/WASM parity. Public Java contracts still await checked JetCheck strategies and property context integration; see PLAN-0.9.md.


## Java checked native strategies — 2026-09-27

Snapshot: `/private/tmp/lawspec-java-checked-strategies-20260927.tar.gz`. Native JetCheck filters preserve valid shrink replays, distinguish false predicates from evaluator errors, and reuse validated typed nested witnesses with shared Symbol context. Both-width strategy checks and eight mutants pass, alongside compiler tests, existing Java data matrices, formatting and focused native/WASM parity. Public emitter integration and per-law retry semantics remain open; see PLAN-0.9.md.


## Public Java constructor contracts — 2026-09-27

Snapshot: `/private/tmp/lawspec-java-public-contracts-20260927.tar.gz`. Public Java generation now shares fixture contexts through checked strategies, witnesses, native adapter conversions and structural assertions. Per-case JetCheck sessions avoid draw-uniqueness exhaustion while preserving native shrinking. Smaller retry budgets are enforced within the native 100-attempt filter cap. Four public configurations, twelve mutants, both-width standalone strategies, 436 compiler tests, ordinary Java property matrices, formatting and native/WASM parity pass. Go/Haskell/Kotlin contracts and remaining 0.9 scope remain open.


## Kotlin native constructor contexts — 2026-09-27

Snapshot: `/private/tmp/lawspec-kotlin-context-codecs-20260927.tar.gz`. Kotlin data emission uses typed profile-aware JVM schema callbacks; named and presence codecs plus native definition boundaries preserve the caller Symbol context. Four native configurations and four context-reset mutants pass, including generic named payloads and nested absence. A wrapped-return indentation checker regression is fixed. The 348-artifact ordinary and 24-artifact native Kotlin audits, 436 compiler tests, both-width definition/property suites and focused parity pass. Public Kotlin property generation remains gated pending Kotest integration.


## Kotlin checked native strategies — 2026-09-27

Snapshot: `/private/tmp/lawspec-kotlin-checked-strategies-20260927.tar.gz`. Checked Kotest strategies preserve native candidate/shrink trees, bound rejection, reuse typed nested witnesses and retain root/shrink-time evaluator errors with shared Symbol context. Both profiles and eight mutants pass, together with ordinary data/collection matrices, twenty adapter mutants, 436 compiler examples, formatting and native/WASM parity. Public Kotlin property emitter integration remains open.


## Public Kotlin constructor contracts — 2026-09-27

Snapshot: `/private/tmp/lawspec-kotlin-public-contracts-20260927.tar.gz`. Public Kotlin properties now compose checked Kotest strategies with stable per-case Symbol contexts through witnesses, dependent inputs, adapters and assertions. Error state survives input filtering and reaches property failures. Four public configurations and twelve mutants pass, plus ordinary data/collection matrices, 436 compiler examples, formatting and native/WASM parity. Go/Haskell contracts and remaining 0.9 acceptance remain open.

## Go constructor-contract runtime checkpoint (2026-09-27)

Added schema predicate registration, ordered recursive contract enforcement,
shared Symbol contexts, typed candidate rejection and contextual evaluator
failures. Public Go emission stays gated pending codecs/emission/checked Rapid
strategies. Direct runtime tests cover both widths and five failing mutants;
existing Go data integration, 436 compiler examples and focused native/WASM
parity pass. See PLAN-0.9.md for exact coverage and remaining work.

Recovery archive: /private/tmp/lawspec-go-contract-runtime-20260927.tar.gz.

## Go native codec contract contexts (2026-09-27)

Runtime and generated Go codecs now carry shared Symbol contexts. Definition
bridges and expression validation use those contexts. Native context wrapping
preserves typed refinement rejection. New GoConstructorCodecsCheck runs through
go-data-integration in both layouts with six dropped-context mutants.
Go definitions pass both profiles; all 436 compiler tests and focused native/WASM
parity pass. Public Go contracts remain gated pending callbacks and strategies.

Recovery archive: /private/tmp/lawspec-go-context-codecs-20260927.tar.gz.

## Go typed constructor predicate emission (2026-09-27)

Go schema generation now emits audited typed constructor callbacks with runtime
generic substitution and the requested machine profile. GoTypeRefs removes
the data/expression module cycle. Four native fixture configurations and eight
mutants pass, along with existing data integration, 436 compiler examples,
318-artifact gofmt audit, embedding, 58-module boundary and focused parity.
Public Go remains gated pending checked Rapid strategies/property wiring.
The new integration entry is tools/go-constructor-native-integration.mjs.

Recovery archive: /private/tmp/lawspec-go-predicate-emission-20260927.tar.gz.

## Go checked Rapid strategy runtime (2026-09-27)

Added checked native Rapid strategies with typed nested witness seeds, native
rejection/shrinking, explicit errors and isolated sample/replay failure state.
Later fields cannot obscure earlier evaluator failures. Both-width runtime
tests, three mutants, deliberate shrink/empty-domain tests, existing Go data
integration, 436 compiler examples and focused parity pass. See PLAN-0.9.md
for native retry limits and remaining public integration work.

Recovery archive: /private/tmp/lawspec-go-checked-strategies-20260927.tar.gz.

## Go public constructor contracts (2026-09-27)

Enabled checked Go property generation and shared contexts through native
adapters, boundaries and assertions. Four public configurations and twelve
mutants pass, as do 436 compiler tests, 318 Go formatting artifacts, existing
definition integration and focused native/WASM parity. Proven finite domains
remain exhaustive. REFINEMENTS.md records the remaining Rapid per-law generation
configuration audit; full 0.9 acceptance is still incomplete.

Recovery archive: /private/tmp/lawspec-go-public-contracts-20260927.tar.gz.

## Go native generation settings (2026-09-27)

Go structural properties honor per-law case counts with scoped/restored Rapid
flags and cap native filters by maximumAttempts. Runtime tests check counts,
restoration, limits and shrinking; five runtime mutants and twelve public
mutants pass. Public adapter counters prove seven cases plus boundaries across
both profiles/layouts. Native shrink-time versus scalar shrink-step behavior is
explicitly documented. Compiler, formatting, definition integration and parity
checks pass; see PLAN-0.9.md for coverage and remaining work.

Recovery archive: /private/tmp/lawspec-go-generation-settings-20260927.tar.gz.

## Haskell constructor-contract runtime (2026-09-27)

Added ordered schema predicates, explicit rejection/evaluation-failure types and
contextual validation/construction/equality/matching. Legacy Hedgehog strategies
reject contract-bearing schemas. Both-width runtime checks and four compiled
mutants pass, along with existing Haskell data integration, 436 compiler examples
and focused native/WASM parity. Public Haskell remains gated; next integration
steps are codecs, typed callbacks and checked strategies.

Recovery archive: /private/tmp/lawspec-haskell-contract-runtime-20260927.tar.gz.

## Haskell native codec contexts (2026-09-27)

Added optional contexts to runtime/generated codecs while preserving old calls.
Definition bridges and expression schema checks carry their existing scope.
New constructor codec tests pass both profiles and layouts with four compiled
scope-loss mutants. Full Haskell definition integration, 436 compiler examples
and focused native/WASM parity pass. Public Haskell remains gated pending
typed callback emission and checked Hedgehog integration.

Recovery archive: /private/tmp/lawspec-haskell-context-codecs-20260927.tar.gz.

## Haskell typed constructor predicate emission (2026-09-27)

Added profile-aware audited schema callbacks and generic runtime substitution.
HaskellTypeRefs removes the data/expression cycle. Four native configurations
and eight compiled mutants pass, alongside full definition integration,
436 compiler examples and focused native/WASM parity. Public Haskell stays
gated pending checked Hedgehog strategies and property integration.
New tool: tools/haskell-constructor-native-integration.mjs.

Recovery archive: /private/tmp/lawspec-haskell-predicate-emission-20260927.tar.gz.

## Haskell checked strategies and contextual boundaries (2026-09-27)

Checkpoint includes native checked Hedgehog strategies, typed subtree witnesses,
Symbol scopes, budget filtering and error propagation, with both-width shrinking
checks and five compiled mutants. Property test codecs/validation/construction
now carry Symbol contexts; the boundary-only emitter matrix passes 196 examples
per width/layout and six context-loss mutants. Nested absence literals compile
in native definitions; constructor-native checks and eight mutants pass.
436 compiler examples pass. See PLAN-0.9.md for precise scope and remaining work.
Public Haskell randomized contracts remain gated; no release was published.
WASM/fingerprints and 128-generation/16-check-expand native parity pass. Ordinary
Haskell property regression continues in tool session 79028, log
`.artifacts/haskell-property-context-regression.log`; first data/32 correct run
passed 2473 examples. Poll the existing handle rather than restarting it.
Recovery archive: `/private/tmp/lawspec-haskell-checked-context-20260927.tar.gz`.

## Public Haskell constructor properties (2026-09-27)

Public Haskell constructor contracts are enabled. The emitter shares case Symbol
contexts, performs dependent checked draws and forces each before the next.
Hedgehog receives explicit cases/discard/shrink limits. Checked native filters
use filterT to avoid expensive traversal of rejected shrink subtrees, with a
compiled mutant regression. Runtime checks pass both widths and six mutants;
public integration passes 209 examples per width/layout and sixteen mutants,
including exact two-discard exhaustion and seven-case execution. The prior
ordinary Haskell regression run completed successfully. 436 compiler examples
pass. Remaining scope is recorded in PLAN-0.9.md; version stays 0.8.0.
WASM/fingerprint checks and native/WASM parity (128 generation combinations,
16 check/expand responses) pass. All test processes completed.
Recovery archive: `/private/tmp/lawspec-haskell-public-contracts-20260927.tar.gz`.

## Recursive payload traversal groundwork (2026-09-27)

New Core.Payload.checkPayloads interprets finite parameter-provenance recipes
against validated values. It supports recursive and mutual data, parameter
permutations, growing applications, containers, absence, phantom parameters and
short-circuiting without confusing unrelated equal concrete field types.
PayloadSpec adds ten focused tests; all 446 compiler/Core examples pass and the
boundary audit covers 60 modules. The new module is registered in lawspec.cabal.

IMPORTANT: this module is reference groundwork, not yet wired to a Core expression
node or source lowering. Tree Positive remains rejected. Next integrate a typed
payload-predicate node (argument binders, scoped predicates), reference evaluation
using this module, validation/proof propagation, source lowering and all eight
backend runtime equivalents. Do not remove the source guard prematurely or
introduce different native wrapper types. Remaining formatting/release acceptance
is unchanged. Version remains 0.8.0 and no publication occurred.
WASM/fingerprints, embedding and diff checks pass; existing public native/WASM
parity passes 96 generation combinations and 12 check/expand responses. All test
processes completed. Recovery archive:
`/private/tmp/lawspec-recursive-payload-traversal-20260927.tar.gz`.

## Typed recursive payload predicates (2026-09-27)

AllPayloads is now a Core node with ordered scoped callbacks. Core.Expression
validates binder types/arity/identity/scope and Boolean results; Core.Eval uses
Core.Payload. Children, free binders, purity, type substitution, Public wire
views and backend binder collectors recognize it. Source lowering is still
unimplemented and Tree Positive remains rejected. Core.Total explicitly gates
pending proof rules; CoreEmit and individual expression emitters explicitly gate
pending native traversal, without crashes or erased predicates.

Gen.hs is the authoritative generator of npm/index.d.ts. It now emits allPayloads,
PayloadPredicate, and the previously omitted allElements case. The new
`tools/api-types-integration.mjs` compiles an exhaustive TypeScript visitor after
normal generation. Nine new Core tests bring the suite to 455 passing examples;
API layout, TypeScript, boundary (60 modules), embedding, diff, WASM/fingerprint
checks and public native/WASM parity (128 generation + 16 check/expand) pass.
All test processes completed. Next: recursive proof facts, source lowering and
all-target native traversal. Remaining formatting/release work stays open.
Recovery archive: `/private/tmp/lawspec-payload-core-operation-20260927.tar.gz`.

## Recursive payload proof propagation (2026-09-27)

Core definition admission now supports AllPayloads. A shared PayloadPlan schema
supplies parameter-origin recipes to reference evaluation and proof extraction;
its least fixed point identifies stored parameters without unfolding recursive
types. Matching introduces guarantees only for the same scrutinee and selected
constructor. Fixed fields, phantom parameters, mutually recursive parameter
permutations, growing type arguments, and nested presence retain their distinct
semantics. Callback substitution avoids capture, and callbacks are audited for
stored parameter positions. Result obligations inspect constructed fields or
known payload guarantees. Presence implications activate only under their exact
guards; guarded projections retain strict-subterm provenance for recursion.

Eleven proof tests cover both machine widths, reference execution, valid and
invalid divisions/results, unrelated inputs, disjunction/negation, vacuity,
partial callbacks, growing/mutual recursion, nested presence and binder capture.
All 466 compiler examples pass. Four compiled unsoundness mutants are rejected:
foreign-source facts, negated universal facts, unguarded presence implications,
and accidental constraints on fixed fields. The negation test was corrected to
avoid an unrelated recursive-call rejection masking the fault.

WASM rebuild, source fingerprints, generated TypeScript exhaustive visitor,
61-module boundary audit, embedding and diff checks pass. Logs are under
.artifacts/payload-proof-{tests,mutants,wasm,parity}.log.

Constructor payload contracts still explicitly require dependency-cycle auditing;
source Tree Positive and all eight native AllPayloads emission paths remain
gated. Next implement that audit, source elaboration/template proof adaptation,
and native traversal before opening source support. Remaining formatting and
full packaging/release acceptance stay open. Python retains PEP 8 and the
development version remains 0.8.0; nothing was published.

Existing public native/WASM parity passes 128 generation combinations and
16 check/expand responses; this does not establish source payload support.
All verification processes completed. Recovery archive:
`/private/tmp/lawspec-payload-proof-rules-20260927.tar.gz`, verified byte-for-byte.

## Constructor payload proof admission (2026-09-27)

Removed the remaining Core.Total gate on constructor AllPayloads predicates.
The existing constructor dependency graph recursively visits callback matches
and constructions, so those references remain invariant dependency edges.
Payload traversal alone follows finite stored subvalues and does not assume
constructor invariants. Cyclic invariant dependencies still require an inductive
proof and are rejected. Ordered predicates are checked before their guarantees
become available to later predicates.

Three additional tests cover nested recursive values under constructor payload
contracts at both widths, rejected zero leaves, matching-based transfer of a
constructor guarantee to a function precondition, ordered partial callbacks,
direct and mutual callback cycles, and an accepted acyclic counterpart. Cycle
tests require the specific cyclic-constructor diagnostic rather than any failure.
All 469 compiler examples pass. The compiled mutant suite now catches five
unsound changes, including omitting callback dependencies from the cycle graph.

Native CLI and WASM are rebuilt; generated TypeScript declarations, fingerprints,
61-module architecture boundaries, embedded runtimes and diff checks pass.
Logs: .artifacts/payload-constructor-{build,tests,mutants,wasm,parity}.log.
Source recursive named payload elaboration and native AllPayloads execution
remain gated. Next implement source/template proof lowering and traversal across
all eight targets, then complete the outstanding formatting and release checks.
Python retains PEP 8. Development version remains 0.8.0; nothing was published.

Public native/WASM parity passes 128 generation combinations and 16
check/expand responses. This covers existing public behavior, not pending source
payload support. All verification processes completed. Recovery archive:
`/private/tmp/lawspec-payload-constructor-proof-20260927.tar.gz`, verified byte-for-byte.

## Scoped front-end payload predicates (2026-09-27)

The internal surface model now has AllPayloadsExpr with independently scoped
callbacks. Capture-avoiding substitution is shared with AllElements, and free
variables, type mapping, location stripping, pretty printing, qualification,
resolution, normalization and closedness checking traverse every callback.
Inference accepts registered data/presence types, checks argument/callback arity
and Boolean bodies, and assigns each callback its declared parameter type.
Sibling callbacks may reuse a source name while lowering to distinct Core IDs.

Typed elaboration emits Core.AllPayloads. Definition specialization preserves
callback scopes and contextual types; template totality lowering uses the same
PayloadPlan schema and proof operation as Core admission. Five added tests cover
both widths, executable typed lowering, independently typed sibling binders,
malformed domains/arity/results, cross-callback references, capture avoidance,
and refined identity contracts through template audit, specialization, Core
admission and reference invocation. An invalid constructed result is rejected by
the template proof. All 474 compiler examples pass; native CLI, boundary audit,
embedding and diff checks pass.

This is an internal front-end node, not new parser syntax. Automatic recursive
named-refinement expansion still rejects pending native execution, and all eight
backend traversal gates remain. Next implement native traversal and enable
recursive refinement expansion with end-to-end tests. Remaining formatting and
full release acceptance are still open. Python retains PEP 8; version remains
0.8.0 and nothing was published. Logs use .artifacts/payload-surface-*.log.

WASM rebuild/fingerprints and exhaustive TypeScript visitor checks pass.
Existing public native/WASM parity passes 128 generation combinations and
16 check/expand responses. This does not claim source recursive refinement
acceptance. All verification processes completed. Recovery archive:
`/private/tmp/lawspec-payload-surface-lowering-20260927.tar.gz`, verified byte-for-byte.

## Python recursive payload runtime (2026-09-27)

The framework-independent Python Schema now provides all_payloads. It validates
the full value, including constructor contracts, before invoking callbacks;
callbacks must return actual Bool values. Finite recipes retain parameter origin
through custom constructors, List/Maybe/Either and tagged presence, including
mutual recursion and growing type arguments. Fixed fields and phantom positions
are ignored. Traversal short-circuits false results and reports constructor-field,
list-index and presence context for callback errors. No concrete-type equality
is used to select fields.

Nine standalone runtime tests pass, covering both widths, depth-40 recursive
storage, identical concrete types in distinct roles, swapped mutual parameters,
growing List arguments, nested presence, sums/phantoms, short-circuiting, faults,
malformed metadata/callbacks and validation/constructor-contract ordering.
The new tools/python-payload-runtime.mjs detects four independent mutants:
wrong parameter index, constrained fixed fields, bypassed validation and ignored
false callback results. Existing constructor runtime checks pass (13 tests) using
cached Hypothesis dependencies. The system interpreter initially lacked those
dependencies; the successful rerun used .artifacts/python-data-deps.

Runtime and test sources pass PEP 8. The 222-artifact generated Python corpus
passes pycodestyle 2.14.0 and readable/compact AST equivalence at both widths.
Embedded runtime sources, native compiler and WASM are updated; fingerprints,
TypeScript declarations and the 61-module boundary audit pass. No compiler
semantics changed in this runtime-only step.

Python expression emission is not connected yet, and all eight public traversal
gates remain. Next connect Python emission with generated execution tests and
implement equivalent runtime traversal on the remaining targets before enabling
recursive named-refinement expansion. Remaining formatting and full release
acceptance stay open. Python retains PEP 8; version remains 0.8.0 and no
publication occurred. Logs: .artifacts/python-payload-*.log.

The nine runtime checks also execute against freshly generated readable and
compact runtime artifacts at both machine widths (four configurations).
Existing public native/WASM parity passes 96 generation combinations and
12 check/expand responses. All verification processes completed. Recovery
archive: `/private/tmp/lawspec-python-payload-runtime-20260927.tar.gz`, verified byte-for-byte.

## Python recursive payload emission (2026-09-27)

PythonExpr now emits scoped callbacks to Schema.all_payloads, retaining outer
references, schema type references, machine width and the per-example Symbol
context. This shared path serves source definitions, properties and constructor
predicates. CoreEmit permits Python payload nodes while retaining explicit gates
for the other seven targets. Schema dependency detection now recognizes the
operation itself, so property-only built-in container cases receive the data
schema artifact and imports without custom declarations or definitions.

The new typed-Core fixture and tools/python-payload-emission.mjs exercise public
planTesting/emitPlanWithFormat output at both widths and layouts. Generated native
wrappers correctly evaluate positive/negative recursive trees with captured
thresholds, List payloads and vacuous truth, and reject invalid constructor
payloads. Generated Hypothesis properties execute, including a separate unit
with no definitions or custom data. Generated files pass PEP 8 and readable/
compact AST equivalence in both normal and property-only configurations.
All 474 compiler examples pass; the target-gate regression now requires Python
success and diagnostics for pending targets. Native CLI, architecture boundaries,
embedded sources and diff checks pass. Logs use
.artifacts/python-payload-{emission,emitter-*,fixture-build}.log.

Automatic recursive named-refinement expansion remains gated until equivalent
native traversal is available on every target. Next implement the remaining
seven target emitters/runtimes, then source acceptance and complete formatting/
release checks. Python retains PEP 8; development version remains 0.8.0 and no
publication occurred.

WASM rebuild/fingerprints and exhaustive TypeScript visitor checks pass.
Existing public native/WASM parity passes 96 generation combinations and
12 check/expand responses. All verification processes completed. Recovery
archive: `/private/tmp/lawspec-python-payload-emitter-20260927.tar.gz`, verified byte-for-byte.

## Shared JavaScript/TypeScript payload runtime (2026-09-27)

Schema.allPayloads now implements parameter-origin traversal in the shared web
runtime. It validates the complete value and callback vector before evaluation,
including constructor contracts and rejection of array holes. Recipes compose
through recursive definitions, changing type arguments, built-in containers and
presence without applying predicates to coincidentally equal fixed-field types.
Callbacks must return Boolean values; false short-circuits, and faults retain
field/index/presence context and their original cause (including thrown null).

Eight standalone tests cover both widths, depth-40 recursive storage, parameter
roles and mutual swaps, growing List arguments, vacuous/unselected/phantom
storage, whole-argument semantics, nested presence, short-circuiting, faults and
validation order. Four runtime mutants are caught: wrong parameter index,
constrained fixed fields, skipped validation and ignored predicate rejection.
The same tests execute against generated JavaScript and transpiled TypeScript
runtime artifacts across both widths and readable/compact layouts (eight
configurations). Runtime Google-style formatting, embedded-source consistency,
61-module boundary audit and diff checks pass. CLI/WASM are rebuilt and their
fingerprints and TypeScript API visitor checks pass.

This step only adds runtime traversal. Web expression emitters still explicitly
reject AllPayloads; next connect them with generated definition/property and
constructor-contract execution tests. Java, Kotlin, Go, Haskell and Rust traversal,
recursive source expansion, remaining formatting and final release acceptance
remain open. Python retains PEP 8; version remains 0.8.0 and nothing was
published. Logs use .artifacts/web-payload-*.log.

The 492-artifact JS/TS corpus passes configured continuation/column/quote/
operator/whitespace and readable/compact AST checks. Prettier comparison is
informational (406 differences), not an exact Google-style oracle. Existing
public native/WASM parity passes 96 generation combinations and 12 check/expand
responses. All verification processes completed. Recovery archive:
`/private/tmp/lawspec-web-payload-runtime-20260927.tar.gz`, verified byte-for-byte.

## JavaScript/TypeScript recursive payload emission (2026-09-27)

WebExpr now renders AllPayloads as scoped callbacks to Schema.allPayloads with
the scrutinee's schema reference, machine width and per-example Symbol context.
TypeScript callback parameters use unknown and remain under strict type checking;
no any or ts-nocheck escape was added to generated definition code. The same
renderer serves definitions, constructor predicates and generated properties.
CoreEmit now permits Python, JavaScript and TypeScript payload nodes, keeping
explicit diagnostics on the remaining five targets.

The shared typed-Core fixture (tools/python-payload-fixture.hs) now accepts web
targets. tools/web-payload-emission.mjs checks 16 configurations: JS/TS, 32/64,
readable/compact, and custom-data/standalone-built-in-property units. Native
wrappers evaluate recursive trees with captured thresholds, List predicates and
vacuous truth; constructor contracts reject a zero leaf. Generated fast-check
properties run in every configuration. TypeScript output compiles with strict
NodeNext settings. Readable output passes 80-column/continuation/whitespace
checks and structural AST comparison against compact output. Property-only
built-in units verify schema artifact/import inclusion without definitions or
custom types. All 474 compiler examples pass; CLI, architecture boundaries,
embedded sources and diff checks pass. Logs use .artifacts/web-payload-emitter-*
and .artifacts/web-payload-emission.log.

Next prioritize Rust traversal/emission, then Java, Kotlin, Go and Haskell.
Automatic recursive named-refinement expansion remains gated until equivalent
execution exists across all eight targets. Remaining formatting and complete
release acceptance stay open. Python retains PEP 8; version remains 0.8.0 and no
publication occurred.

WASM rebuild/fingerprints and exhaustive TypeScript API visitor checks pass.
Existing public native/WASM parity passes 96 generation combinations and
12 check/expand responses. All verification processes completed. Recovery
archive: `/private/tmp/lawspec-web-payload-emitter-20260927.tar.gz`, verified byte-for-byte.

## Rust recursive payload runtime (2026-09-27)

Schema.all_payloads_with_context validates the entire logical value and its
constructor contracts before traversing stored type arguments. Private recipes
preserve parameter positions through custom data, List/Maybe/Either and tagged
presence; fixed fields and phantom occurrences remain unconstrained. The runtime
uses one indexed FnMut dispatcher receiving the shared mutable Context, avoiding
conflicting mutable borrows between closures while preserving Symbol identity.
False results short-circuit and callback faults retain constructor-field and
container context. Callbacks return Value and must produce Bool.

Seven new runtime tests cover both widths, recursive depth 40, distinct roles
at equal concrete types, mutual swaps, growing arguments, nested presence,
whole-argument semantics, vacuity, short-circuiting, diagnostics, validation and
constructor-contract ordering, and mutable Symbol-context reuse. These and the
22 existing runtime tests pass. Four compiled unsoundness mutants are caught:
wrong parameter index, constrained fixed fields, skipped validation and ignored
predicate rejection. The same suite compiles and runs against freshly generated
readable/compact runtime artifacts at both widths. The 262-artifact Rust corpus
matches rustfmt in both machine profiles. Runtime/test rustfmt, embedded sources,
61-module boundaries and diff checks pass; CLI/WASM and fingerprints are rebuilt.
TypeScript API visitor checks pass. Logs use .artifacts/rust-payload-*.log.

Rust expression emission remains gated until its dispatcher is connected and
verified in generated definitions, constructor predicates and properties. Next
complete that Rust emission work, followed by Java, Kotlin, Go and Haskell
traversal/emission. Recursive source refinement expansion, remaining formatting
and final release acceptance remain open. Python retains PEP 8; development
version remains 0.8.0 and no publication occurred.

Existing public native/WASM parity passes 96 generation combinations and
12 check/expand responses. All verification processes completed. Recovery
archive: `/private/tmp/lawspec-rust-payload-runtime-20260927.tar.gz`, verified byte-for-byte.

## Rust recursive payload emission (2026-09-27)

RustExpr now emits an indexed closure dispatcher to
Schema.all_payloads_with_context. It materializes the scrutinee and type before
borrowing Context, keeps outer bindings available in callback arms, and supplies
ctx as a closure parameter for nested Symbol literals and function calls.
Contextual rendering accepts schema/type-reference resolvers so generic
constructor predicates instantiate their declared type arguments. Ordinary
expressions use the generated schema factory; constructor callbacks reuse their
schema argument. Property-only AllPayloads expressions now request the schema
artifact and module import without custom data or definitions. CoreEmit enables
Rust alongside Python, JavaScript and TypeScript.

The shared fixture now includes a generic constructor payload predicate and a
Symbol-identity definition. tools/rust-payload-emission.mjs compiles and runs
eight combinations of 32/64, readable/compact and custom-data/property-only units.
Checks cover captured thresholds, positive/negative recursive leaves, empty and
nonempty Lists, constructor rejection, instantiated generic predicates, shared
Symbol IDs and distinct identities with equal descriptions. Generated proptest
properties execute in all configurations. Readable generated artifacts match
rustfmt. The initial property-only case caught a missing schema import, now
fixed; rustfmt also identified redundant closure blocks, now emitted canonically.

All 474 compiler examples pass. The expanded fixture also passes Python execution,
PEP 8 and AST parity, and all 16 JS/TS configurations with strict tsc, style and
AST parity. Architecture boundaries, embedded sources and diff checks pass;
CLI is rebuilt. Logs use .artifacts/rust-payload-emitter-*,
.artifacts/rust-payload-emission.log and .artifacts/rust-payload-*-regression.log.

Next implement Java, Kotlin, Go and Haskell payload traversal/emission. Recursive
source refinement expansion remains gated pending that target parity. Remaining
formatting and final release acceptance stay open. Python retains PEP 8;
development version remains 0.8.0 and no publication occurred.

WASM rebuild/fingerprints and exhaustive TypeScript API visitor checks pass.
Existing public native/WASM parity passes 96 generation combinations and
12 check/expand responses. The Rust driver explicitly requires the emitted
payload operation and proptest runner before executing its tests. All
verification processes completed. Recovery archive:
`/private/tmp/lawspec-rust-payload-emitter-20260927.tar.gz`, verified byte-for-byte.

## Java recursive payload runtime (2026-09-27)

LawSpecSchema.allPayloads validates the full tagged value and constructor
contracts before dispatching scoped Value-to-Value callbacks. Private recipes
track parameter positions through custom constructors, List/Maybe/Either and
presence. Fixed fields are ignored regardless of concrete type equality; empty,
phantom and unselected storage is vacuously true. Callback results must be Bool,
false results short-circuit, and runtime exceptions retain constructor-field and
container context and their cause. Schema validation uses the supplied Symbol
map and machine width.

JavaPayloadCheck exercises both widths, depth-40 recursive storage, equal
concrete types with different parameter roles, swapped mutual recursion, growing
List arguments, nested presence, empty/sum/phantom cases, short-circuiting,
callback faults/results, invalid representations/arity and constructor rejection
before callback evaluation. All checks pass on handwritten runtime sources and
freshly generated readable/compact artifacts at both widths. Four independently
compiled mutations are detected: wrong parameter index, constrained fixed fields,
skipped validation and ignored rejection. Existing constructor validation and
context-aware codec checks pass both profiles and retain their six mutation
checks. Runtime and test sources match Google Java Format 1.36.0. CLI/WASM and
fingerprints are rebuilt, TypeScript API visitor checks pass, and embedded
sources, 61-module architecture boundaries and diff checks pass.

Java expression emission remains gated. Next connect the Java emitter and verify
generated definitions, constructor predicates and properties, then implement
Kotlin, Go and Haskell traversal/emission. Recursive source expansion, remaining
formatting and final release acceptance stay open. Python retains PEP 8;
version remains 0.8.0 and no publication occurred.
Logs use .artifacts/java-payload-*.log.

The final runtime suite also verifies that a declared Optional argument is
passed whole to its callback rather than flattened. Existing public native/WASM
parity passes 96 generation combinations and 12 check/expand responses.
The full Java formatting corpus is still running under tool session 70081;
poll that handle and .artifacts/java-payload-formatting.log before claiming it
passed. All other checks above completed. Recovery archive:
`/private/tmp/lawspec-java-payload-runtime-20260927.tar.gz`, verified byte-for-byte.

## Java recursive payload emission and Python style confirmation (2026-09-27)

JavaExpr now emits scoped allPayloads callbacks with contextual type references,
machine width and shared Symbol identities. Schema dependencies are included
for property-only units without custom declarations or definitions. CoreEmit
admits Java alongside Python, JavaScript, TypeScript and Rust; Kotlin, Go and
Haskell remain explicitly gated for this internal operation.

The shared typed-Core fixture and tools/java-payload-emission.mjs compile and
execute eight width/layout/domain configurations with Maven offline. Checks
cover recursive payloads, captured thresholds, generic constructor predicates,
Symbol identity, rejection, empty lists and generated JetCheck properties.
Readable artifacts match Google Java Format; compact artifacts format to the
same result. All 474 compiler tests pass. Native CLI and WASM are rebuilt;
fingerprints, exhaustive API visitor, embedded runtime and architecture checks
pass. API migration notes now include Java.

The user's Python preference is PEP 8. Runtime Python files pass pycodestyle;
the full 222-artifact corpus passes the independent style checker at 79 code
columns and 72 prose columns, plus readable/compact AST parity at both widths.
This preference remains documented in PYTHON.md, LANGUAGE.md and README.md.
Logs: .artifacts/pep8-confirmation.log and .artifacts/java-payload-emitter-*.

Next implement Kotlin, Go and Haskell payload traversal/emission before enabling
automatic recursive named refinement expansion. Remaining formatting and full
release acceptance stay open. Version remains 0.8.0; nothing was published.

Existing public native/WASM parity also passes 96 generation combinations and
12 check/expand responses. The separate full Java formatting corpus remains
running under session 70081; poll that handle and
.artifacts/java-payload-formatting.log before claiming completion. Recovery
archive: /private/tmp/lawspec-java-payload-emitter-20260927.tar.gz.

## Kotlin recursive payload emission (2026-09-27)

KotlinExpr emits scoped Java Function callbacks to the existing shared JVM
LawSpecSchema.allPayloads runtime. Kotlin total-definition bodies and constructor
predicates already use the Java Core emitter; property expressions now call the
same validated traversal directly. There is no duplicate Kotlin traversal
algorithm. CoreEmit admits Kotlin, retaining the Go/Haskell diagnostic gates.
The existing Kotlin schema artifacts and property helpers already cover units
without custom data or definitions.

The shared typed-Core fixture now compares payload traversal to AllElements
using a separately generated Int8 threshold, exercising captured inputs and
false callback results. Python, JavaScript, TypeScript, Rust and Java all pass
this stronger property in their existing width/layout/domain configurations,
including their style and compact parity checks.

All 474 compiler tests pass. The full Kotlin corpus passes parsing, syntax-tree
parity and configured Google style checks for 348 artifacts. Native CLI and
WASM are rebuilt; fingerprints, exhaustive TypeScript visitor, embedded runtime,
61-module architecture boundaries and diff checks pass. Existing public
native/WASM parity passes 96 generation combinations and 12 check/expand
responses. Logs use .artifacts/kotlin-payload-*.

Next implement Go and Haskell traversal/emission, then enable automatic recursive
named refinement expansion. Remaining formatting and full release acceptance
stay open. Python retains PEP 8; version remains 0.8.0 and nothing was published.

tools/kotlin-payload-emission.mjs completes all eight profile/layout/domain
configurations. Native checks cover recursive values, captured thresholds,
generic constructor predicates, empty/rejected lists and shared/distinct Symbol
identities. Kotest runs generated properties in every configuration, including
property-only units. Readable Kotlin passes style checks and compact syntax-tree
parity. An independently compiled accept-all JVM traversal mutant fails the
64-bit property-only Kotest suite with AssertionError, confirming the property
is nonvacuous. All Kotlin and cross-target payload checks above are terminal.

The separate full Java formatting corpus is still live under session 70081;
poll that handle and .artifacts/java-payload-formatting.log before claiming it
passed. Recovery archive:
/private/tmp/lawspec-kotlin-payload-emitter-20260927.tar.gz.

## Go recursive payload runtime (2026-09-27)

The framework-independent Go schema now implements allPayloads. Finite payload
recipes preserve declaration parameter identity through recursive, mutual and
growing type applications. Fixed fields are ignored independently of concrete
type equality; List, Maybe, Either, Nullable and Optional retain their stored
parameter roles. Whole arguments are passed intact to callbacks. Full recursive
validation and constructor contracts precede callback execution, sharing the
supplied Symbol context. Callbacks are snapshotted before use, return strict
runtime Bool values, short-circuit false results and retain contextual errors.

GoPayloadCheck covers both widths, depth-40 trees, equal-concrete-type parameter
roles, mutually swapped arguments, growing List arguments, phantom/empty/sum
storage, nested presence, whole Optional arguments, callback order/snapshots,
contextual faults, invalid Bool results, invalid fixed fields/arity/scalar roots,
constructor rejection before callbacks, cyclic slices and Symbol identity through
constructor validation and callbacks. tools/go-payload-runtime.mjs passes these
checks on handwritten sources and freshly generated readable/compact runtimes
at both widths. Six independently compiled mutants are rejected: wrong parameter
index, constrained fixed fields, skipped validation, accept-all traversal,
reset Symbol context and unsnapshotted callbacks. The generated-runtime fixture
uses a structural declaration so the compiler includes its schema artifact.

Existing Go constructor-contract checks pass both profiles and five mutations.
All 318 generated Go artifacts match gofmt. Native CLI and WASM are rebuilt;
fingerprints, exhaustive API visitor, embedded runtimes, architecture boundaries
and diff checks pass. Existing public native/WASM parity passes 96 generation
combinations and 12 check/expand responses. Logs use .artifacts/go-payload-*.
No compiler behavior changed in this runtime-only checkpoint; the previous
474 compiler-test result remains the latest full Hspec run.

Go emission is still gated: connect its expression renderer and verify native
APIs, generic constructor predicates and Rapid properties next. Then implement
Haskell traversal/emission and enable automatic recursive named refinements.
Remaining formatting and release acceptance stay open. Python retains PEP 8;
version remains 0.8.0 and no publication occurred.

The separate full Java formatting corpus is still live under session 70081;
poll that handle and .artifacts/java-payload-formatting.log before claiming it
passed. All Go checks above have completed. Recovery archive:
/private/tmp/lawspec-go-payload-runtime-20260927.tar.gz.

## Go recursive payload emission (2026-09-27)

GoExpr now emits scoped function callbacks to schema.allPayloads using contextual
type references, width and Symbol state. CoreNativeScalarEmit explicitly requests
schema support for payload expressions, including property-only units without
custom declarations. CoreEmit admits Go alongside Python/web/Rust/JVM; Haskell
remains gated. The shared typed-Core fixture accepts Go, and the compiler gate
regression requires its success. API migration notes describe the seven admitted
emitters.

tools/go-payload-emission.mjs compiles and runs eight width/layout/domain
configurations offline. Native APIs exercise captured thresholds, recursive
payloads, fixed-field independence, rejected/empty lists, generic constructor
predicates and Symbol identity. Rapid executes the nontrivial threshold property
and rejects an independently compiled accept-all traversal mutant. Readable
output matches gofmt. Because gofmt intentionally retains certain input line
breaks, compact parity uses the independent Go parser via tools/GoSyntaxCheck.go:
AST comparison removes positions/comments but retains tokens and literal values.
The oracle was checked against changed numbers, operators and string contents.
Initial driver checks were corrected to recognize lsRapidCheck, put package
arguments before framework flags, and avoid comparing gofmt-preserved line breaks.
The final full driver run passes.

All 474 compiler tests pass. Native CLI and WASM are rebuilt; fingerprints,
exhaustive TypeScript API visitor, embedded runtimes, architecture boundaries and
diff checks pass. Logs use .artifacts/go-payload-emitter-* and
.artifacts/go-payload-emission.log. The previous full 318-artifact Go formatting
check remains valid; this turn additionally audits every new fixture artifact.

Next implement Haskell traversal/emission, then enable automatic recursive named
refinement expansion. Remaining formatting and full release acceptance stay open.
Python retains PEP 8; version remains 0.8.0 and nothing was published.

The final mutation run selects TestLaw0Property explicitly: Rapid itself reports
the counterexample, rather than a prior deterministic boundary aborting the test
process. The complete driver passes after this strengthening. Existing public
native/WASM parity passes 96 generation combinations and 12 check/expand
responses. All checks above completed. The separate full Java formatting corpus
remains live under session 70081; poll it and
.artifacts/java-payload-formatting.log before claiming completion.
Recovery archive: /private/tmp/lawspec-go-payload-emitter-20260927.tar.gz.

## Haskell recursive payload runtime (2026-09-27)

LawSpecSchema now exports allPayloads/allPayloadsWith. Private finite recipes
preserve parameter positions through recursive custom declarations, containers
and presence. Callback results use Either String Scalar, enforce Bool, propagate
contextual failures and short-circuit false results. Whole-value validation and
constructor contracts complete through Either before callback traversal; an
invalid later list element cannot be hidden by an early false callback. Phantom
parameters and unselected branches leave their callbacks unevaluated. Declared
Optional arguments are passed whole rather than flattened.

HaskellPayloadCheck covers both widths, depth-40 trees, equal-concrete-type
parameter roles, mutually swapped parameters, growing List arguments, empty and
phantom storage, sum branches, nested presence, whole arguments, short-circuiting,
contextual callback errors, non-Bool results, malformed roots/arity/fixed fields,
constructor rejection before callbacks, later invalid values and Symbol identity
through constructor validation and callbacks. tools/haskell-payload-runtime.mjs
compiles and runs handwritten sources plus generated readable/compact runtime
copies at both widths. Six compiled mutants fail execution: wrong parameter
index, constrained fixed fields, skipped validation, accept-all traversal, reset
Symbol context and eager traversal after rejection. Existing Haskell constructor
checks pass both widths and all four mutations.

Native CLI and WASM are rebuilt; fingerprints, exhaustive TypeScript API visitor,
embedded runtime, architecture boundaries and diff checks pass. Logs use
.artifacts/haskell-payload-*. No compiler behavior changed in this runtime-only
checkpoint; the latest full Hspec result remains 474 passing tests. Full Haskell
runtime formatting remains part of the pending acceptance work; no complete
formatter-conformance claim is made here.

Next connect Haskell expression emission and verify generated native APIs,
generic constructor predicates and Hedgehog properties, then enable automatic
recursive named refinement expansion. Remaining formatting and full release
acceptance stay open. Python retains PEP 8; version remains 0.8.0 and no
publication occurred.

Existing public native/WASM parity passes 96 generation combinations and
12 check/expand responses. All Haskell checks above have completed. The separate
full Java formatting corpus remains live under session 70081; poll it and
.artifacts/java-payload-formatting.log before claiming completion.
Recovery archive: /private/tmp/lawspec-haskell-payload-runtime-20260927.tar.gz.

## Haskell recursive payload emission (2026-09-27)

HaskellExpr now emits scoped callbacks to Schema.allPayloadsWith with the
contextual type reference, width and Symbol scope. The checked Either result
feeds existing expression evaluation. Definitions, generic constructor predicates
and property expressions share this renderer. CoreEmit's temporary payload gate
is removed, and the compiler regression requires successful emission on every
supported target. Automatic source refinement expansion is still gated pending
frontend integration and source-level acceptance, as documented in API migration
notes.

tools/haskell-payload-emission.mjs compiles and executes eight combinations of
width, layout and custom-data/property-only units using cached GHC packages.
Native API checks cover recursive payloads, captured thresholds, fixed fields,
empty/rejected lists, generic constructor predicates and shared/distinct Symbol
identity. Both existing Hedgehog execution paths run the nontrivial generated
threshold property. An independently compiled accept-all traversal mutant fails
that property specifically after three tests and two shrinks. All generated
definition and schema lines checked by this driver fit 80 columns. Full Haskell
property/runtime formatting and independent compact syntax-tree auditing remain
open; execution of both layouts is established here.

All 474 compiler tests pass. Native CLI and WASM are rebuilt; fingerprints,
exhaustive TypeScript API visitor, embedded runtimes, architecture boundaries and
diff checks pass. Logs use .artifacts/haskell-payload-emitter-* and
.artifacts/haskell-payload-emission.log.

Next replace eager named-payload refinement expansion with the checked scoped
operation, then verify recursive source specifications across all eight targets.
Remaining formatting and final release acceptance stay open. Python retains
PEP 8; version remains 0.8.0 and nothing was published.

Existing public native/WASM parity passes 96 generation combinations and
12 check/expand responses. All Haskell checks above have completed. The separate
full Java formatting corpus remains live under session 70081; poll it and
.artifacts/java-payload-formatting.log before claiming completion.
Recovery archive: /private/tmp/lawspec-haskell-payload-emitter-20260927.tar.gz.

## Source recursive named-payload refinements (2026-09-27)

Refinement.expandType now creates scoped AllPayloadsExpr callbacks from refined
arguments instead of recursively expanding constructor fields into matches.
Recursive applications no longer hit the temporary gate. Each callback retains
its own type argument and outer dependencies; runtime traversal follows declared
parameter positions, leaving fixed fields independent. Whole argument refinements
and existing capability metadata remain attached to the original application.

SourceDataSpec now accepts valid recursive trees and rejects invalid nested
payloads, including mutually swapped parameters and growing Nest (List a)
applications. The bundled recursive_refinements.lawspec proves a positive result
for a recursive sum using Tree Positive, includes negative fixed fields, and
checks an outer threshold below nested forks. Its compiler test checks both
profiles and emission on every target. All 478 compiler tests pass.

The source example exposed presentation gaps not covered by the internal fixture.
Shared backend names now render payload binder depth/index as short safe target
identifiers, avoiding synthetic '$' names in Go/Kotlin/Haskell. Opaque quoted
layout choices account for trailing punctuation, fixing an 80-column Python line
under the 79-column limit. Long comment tokens wrap without dropping characters.
Rust custom-constructor guard documents retain conjunction structure and reserve
room for the arm opener, matching rustfmt for long qualified constructor names.
Document tests cover punctuation and long comment tokens.

Generated Python execution of the new source passes seven tests in each of the
four width/layout configurations. Its definitions and properties use the actual
source-derived predicates and recursive contracts. Source-specific style checks
pass for Go (gofmt), Rust (rustfmt), Kotlin (independent parser/style/syntax-tree
parity), and JS/TS (style/syntax parity). The full Python corpus and final Java
source style checks are recorded below after completion. Broader native execution
of this public source on the other seven targets remains the next acceptance
step; prior internal payload fixtures already execute on all eight.

Documentation now describes scoped recursive payloads and supported direct field
contracts; the example is bundled into npm. Native CLI/WASM are rebuilt. Full
Haskell property/runtime formatting, broad post-change formatter regression and
final 0.9 release acceptance remain open. Python retains PEP 8; development
version remains 0.8.0 and nothing was published. Logs use .artifacts/source-payload-*.

Final verification: all 238 Python artifacts pass PEP 8 and readable/compact
syntax-tree parity. All 20 Java artifacts for the new source match Google Java
Format. Targeted Go/Rust/Kotlin/web checks and all 478 compiler tests pass.
Native/WASM parity, including the new recursive source, passes 96 generation
combinations and 12 check/expand responses. Fingerprints, exhaustive API visitor,
embedded runtimes, architecture boundaries and diff checks pass.

All checks for this checkpoint completed. The old full Java formatting run
remains live under session 70081; it started before the latest source/layout
changes and must not be treated as verification of them. Poll its handle and
.artifacts/java-payload-formatting.log rather than restarting it on a timeout.
Recovery archive: /private/tmp/lawspec-source-payload-expansion-20260927.tar.gz.

## Public recursive source execution on every backend (2026-09-27)

tools/recursive-refinements-integration.mjs now compiles the bundled public
recursive_refinements.lawspec through the normal compiler request, writes its
untouched generated artifacts and executes them with the native frameworks.
All 32 configurations pass: eight targets, 32/64-bit profiles, and readable/
compact layouts. Python runs pytest/Hypothesis, JS/TS run fast-check (with strict
tsc for TypeScript), Go runs Rapid, Rust runs proptest, Java runs JetCheck,
Kotlin runs Kotest and Haskell runs Hedgehog. The harness checks that payload
operations and the recursive definition are actually emitted and that tests run.
It uses cached dependencies/offline build options and preserves per-configuration
build and execution logs under .artifacts/recursive-refinements/. Driver logs:
.artifacts/recursive-refinements-{portable,rust,jvm,haskell}.log.

This closes the source-to-native execution gap recorded in the preceding
checkpoint. Recursive contracts, outer dependent thresholds, concrete examples,
deterministic boundaries and properties execute at both widths/layouts on every
target. All integration processes completed successfully. No compiler/runtime
code changed in this checkpoint; the latest full compiler result remains
478 passing tests. WASM/API/source fingerprints and diff checks still pass.

Next address Haskell property-helper and runtime formatting, independent Haskell
syntax parity, broader formatter regressions after the recent shared layout
changes, and the remaining release acceptance checklist. Neither ormolu nor
fourmolu is installed. Cached GHC is available for independent parsing/validation;
its package database includes haskell-lexer but no standalone formatter.
Version remains 0.8.0 until full 0.9 acceptance; Python retains PEP 8. Nothing was
published. The old Java full-format process is still tracked separately as
session 70081 and is not evidence for current source/layout changes.
Recovery archive: /private/tmp/lawspec-recursive-source-all-targets-20260927.tar.gz.

## Haskell layout and independent syntax audit (2026-09-27)

Haskell expression parentheses no longer add an extra indentation level around
all arguments. Contextual `do` generators retain mandatory multiline layout.
List-cons match arms now break before their let binding, and structural example
constructor identities use the existing lossless chunked-string document.
The matching and recursive-refinement examples pass GHC parsed-AST equivalence
for 40 artifacts (20 unique pairs), both widths and both layouts. Their generated
properties now have no 80-column violations.

LawSpecSchema, LawSpecCodecs, and LawSpecDataStrategies are manually laid out to
80 columns. GHC parsed-AST comparison against the pre-format files passes for
all three. The independent development checker is tools/HaskellSyntaxCheck.hs;
tools/haskell-formatting-integration.mjs checks generated artifacts and records
style failures. An isolated artifact directory is configurable to keep concurrent
checks from overwriting one another. The syntax oracle rejects deliberate numeric,
operator, and string changes. No external formatter runs during generation.

All 478 compiler tests pass. The recursive public example compiles and executes
on Haskell at both widths and layouts. Runtime embedding, rebuilt native/WASM
fingerprints, exhaustive API visitor, 61-module architecture boundary, and 96
native/WASM generation comparisons pass. Python's full 238-artifact PEP 8 and
AST parity check also passed before these Haskell-only edits.

The full current Haskell style report contains only LawSpecRuntime.hs violations
(147 lines per emitted copy). Formatting that scalar runtime remains open. The
full GHC corpus parser audit is still running on handle 7265; its partial report
is not a syntax pass. Historical audit handles 66206 and 70081 remain live and
are not evidence for the current source. The targeted syntax audit and native
recursive runs above completed successfully. Final formatter regressions and
release/package acceptance remain open; version stays 0.8.0 until they pass.

Recovery checkpoint: /private/tmp/lawspec-haskell-layout-20260927.tar.gz.

## Haskell scalar formatting and current corpus regression (2026-09-27)

Manually formatted the remaining scalar runtime. Every line now fits within 80
columns with no tabs or trailing whitespace. Independent GHC parsed-AST comparison
against /private/tmp/lawspec-scalar-before-format.hs passes for the complete file,
retaining literal values and operators. Re-embedded the runtime and rebuilt both
native and WASM compilers. The current full Haskell style report has zero
violations. The preceding full parsed-corpus audit completed: 460 artifacts,
119 unique readable/compact pairs. The audit including the latest scalar layout
is still running on handle 93609 (.artifacts/haskell-scalar-formatting.log).

Runtime behavior checks pass: payload validation at both machine widths with six
compiled mutants, generated readable/compact payload runtimes at both widths,
constructor contracts at both widths with four compiled mutants, literal/integer/
diagnostic preservation in both layouts, and all four recursive public-example
configurations. Scalar native properties, shared arithmetic vectors, and four
faulty adapters pass in each layout on the 64-bit host. The constructor-contract
mutation anchor was updated for the schema's new line break; the mutation remains
an executable behavior check rather than a compile failure.

All 478 compiler tests pass. Current full formatter checks pass for 250 Java,
366 Kotlin, 338 Go, 278 Rust, and 524 JS/TS artifacts. Python's unchanged full
238-artifact PEP 8/AST check passed earlier. The Java formatting audit now caches
identical source strings, still checks every artifact, and supports an isolated
snapshot root so an older audit cannot overwrite its results. Current Java
results completed on handle 26400; older Java handle 70081 is superseded evidence.
All eight scaffold modes/configurations preserve user-owned build files, including
nested placement and machine-profile settings. Native/WASM parity passes 96
combinations; fingerprints, API visitor, runtime embedding, boundary audit, and
diff whitespace checks pass. The full npm suite is still running on handle 34178
(.artifacts/haskell-scalar-npm-tests.log); it is not yet counted as passing.

Updated Haskell formatting documentation and removed stale claims that recursive
payload refinements, refined Haskell definitions, and the bundled WASM minify
path were unimplemented. Bundled copies match. Development version remains
0.8.0 until the final requirement audit and package/release checks. Nothing was
published. Historical handles 66206 and 70081 are not current acceptance evidence.

Recovery checkpoint: /private/tmp/lawspec-haskell-scalar-layout-20260927.tar.gz.

## 0.9.0 release candidate and package verification (2026-09-27)

The previously pending Haskell audit completed: 460 artifacts, 119 unique parsed
pairs, zero style violations. The npm suite completed with all 40 tests passing.
The offline candidate package installed JavaScript and Rust projects, executed
their generated tests, regenerated safely, and exercised the installed structural
API across all eight targets, widths and layouts. This adds installation evidence
for collections, named data, total definitions, and recursive payload refinements.

Versioned manifests and CLI now report 0.9.0. Native/WASM builds and fingerprints
are rebuilt. RELEASE-0.9.md is included in npm and Cabal source distributions;
references and bundled examples match their source copies. Corrected stale
unimplemented/rebuild-pending claims in the target and migration guides, and
added explicit structural wire-format migration notes. ACCEPTANCE-0.9.md maps
release requirements to implementation/test evidence and lists pending gates.

The final archive .artifacts/package-smoke/lawspec-0.9.0.tgz passes the installed
CLI/API smoke test, JavaScript and Rust execution, regeneration, all-target
structural generation, and required-document checks. All 53 packaged files match
npm/ byte-for-byte. SHA-256:
7fb4f02a9837a21712dec3e4924775db2103e12c954fe6811efd395760caa90e.
The 22-test standalone Rust runtime passes. Independent Python Fraction vectors
regenerate identically (57 vectors). All 32 native public recursive-refinement
configurations are present in the eight-target execution logs.

Final 0.9 native/WASM parity passes the targeted 96-comparison matrix. The full
25-fixture corpus is still running on handle 39798, with both check/expand
profiles and the first generation profile complete. Final-version npm tests are
still live on handle 2508. These two gates are not yet counted as passing; the
goal remains active. Logs: .artifacts/release-09-parity-full.log and
.artifacts/release-09-npm-tests.log. Package run handle 15552 completed successfully.
Nothing was committed, tagged, pushed, or published during this release work.

Recovery checkpoint: /private/tmp/lawspec-09-release-candidate-20260927.tar.gz.

## 0.9.0 implementation and acceptance complete (2026-09-27)

The final npm suite completed with all 40 tests passing. Full native/WASM parity
completed with 800 generation comparisons across 25 fixtures, eight targets,
both machine widths, and both layouts; check/expand comparisons pass at both
widths too. These resolve the final pending handles 2508 and 39798.
ACCEPTANCE-0.9.md now records the completed requirement audit, including language,
native runtime/mutation, formatting, ownership, distribution and installation
evidence. All 478 compiler tests, eight-target native integrations and current
formatter corpora are covered by the report. Scope remains the original 0.9
plan; GADTs/general dependent types remain later work as specified there.

The final 0.9.0 package is .artifacts/package-smoke/lawspec-0.9.0.tgz, with
SHA-256 7fb4f02a9837a21712dec3e4924775db2103e12c954fe6811efd395760caa90e.
It is installed and tested, and all 53 archive files match npm/ byte-for-byte.
No publication, tag, commit or push occurred. The implementation goal can now
be completed; publishing is separate.

Final recovery archive: /private/tmp/lawspec-09-complete-20260927.tar.gz.
