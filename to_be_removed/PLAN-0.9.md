# LawSpec 0.9 implementation and acceptance

Implement structural data and total definitions on the typed front end, across
Java, Python, JavaScript, TypeScript, Go, Haskell, Kotlin, and Rust. Preserve
scalar arithmetic, refinements, contracts, custom layouts, and adapter ownership.

## Structural data

- List a: nested contextual literals, structural equality, length, native
  property-framework generators and shrinking.
- Maybe a (Nothing / Just), Either a b (Left / Right), distinct from Nullable
  and Optional interoperability states.
- User-defined parameterized products and sums, named constructors and fields,
  kind/arity checks, constructor expressions, structural equality and generation.
- Total definitions, exhaustive matching, checked structural recursion; reject
  partial matches and recursion whose termination is not established.
- Shared Core declarations, construction, matching, evaluation, and validation.
  Backends consume checked Core rather than interpreting source syntax.
- Size-bounded recursive generation and valid shrinking; deterministic boundaries
  and finite enumeration; diagnostics for empty and nongeneratable domains.

GADTs, indexed families, and general dependent types belong to the following
release. Preserve the existing distinction between type and value arguments.

## Implementation reference

Follow the actual Go+ implementation in ../goforge/goplus, inspected at commit
78407b0bf6f0ef551b552cc60585bf983c54b721:

- internal/gen/enumgen.go plans package-wide names and resolved variants;
  internal/lower/enum.go emits named native types and fields. Erased views are
  implementation helpers, not replacements for native public data types.
- internal/javabackend/backend.go consumes fully lowered, type-checked input
  and rejects unsupported constructs without emitting partial artifacts.
- internal/javabackend/emitter.go preserves native generic types, copying, and
  type-directed equality. stmt.go evaluates match scrutinees once and confines
  erased generic casts to checked branches.
- internal/core/total.go tracks parameter roots and strict subterms;
  internal/resolve/total.go audits callees.

Use LawSpec's typed Core for that boundary. Runtime schemas support validation
and generators; they do not replace native declarations and typed adapters.
Preserve LawSpec's IEEE equality and Symbol identity at native boundaries.

## Formatting

Readable output by default for every emitted runtime, test, adapter, API wrapper,
declaration, and scaffold. Follow Google language-specific guidance where
published, Google's Kotlin style, PEP 8 for Python, and standard Rust formatting.
Python follows PEP 8's four-space indentation, 79-column code limit, and
72-column wrapping for prose comments/docstrings. This supersedes the earlier
Google/YAPF Python target recorded in historical checkpoints.

Thread explicit --minify through CLI, compiler API, examples, regeneration, and
manifests. Use pure deterministic native/WASM layout without runtime formatter
downloads or arbitrary-code regex rewriting. Preserve required indentation,
newlines, token separators, and literal contents. Protect edited adapters.

## Acceptance

- Compiler checks: kinds/arity, specialization, contextual literals, constructors,
  exhaustive matching, termination, and rejected definitions.
- Native/WASM parity for structural values and both formatting modes.
- All eight backends compile and execute generated support, native adapters,
  examples, properties, boundaries, shrinking, and custom layouts.
- Examples: reverse involution; sorting idempotence, sortedness, length and
  permutation; Maybe/Either; parameterized products/sums; recursive data;
  total definitions.
- Mutants: dropped/replaced/reordered elements, wrong tags, ignored fields,
  collapsed nested presence, incorrect recursion.
- Formatter checks, compact/readable execution equivalence, unchanged literal
  payloads, both machine widths, ownership/regeneration, packaged installation.
- Version 0.9.0, API migration, reference, examples, release notes, rebuilt WASM
  and fingerprints agree. Publication is separate from implementation.

## Current implementation evidence (2026-09-26)

Java custom data passes native adapter and mutation checks in both machine
profiles, with multi-unit name collisions and custom source/test placement.
Rust now emits native named generic enums, recursive indirection, phantom and
empty types, and checked conversion traits. Its integration covers recursive
and mutually recursive native adapters, raw scalar fields, schema rejection,
IEEE/Symbol equality, multi-unit collisions, and custom Cargo layouts.
Both machine profiles run; mismatched native machine fields fail contextually.
Five deliberately incorrect Rust adapters are exposed by generated tests.
A deterministic shrink check validates every sampled value, simplification, and
backtrack through the shared schema. Rust generation now reserves uneven field
minima and varies list lengths with available nodes. Regression cases cover an
exact 16-node product, deep singletons, lists longer than four, empty domains,
absence states, and Either's constructor cost.
`tools/rust-data-integration.mjs` checks native declarations, schemas, and both
runtime support files against rustfmt; runtime sources use Rust edition 2024
formatting. The compiler suite has 153 passing examples and the standalone Rust
runtime has 17 passing tests.

This is partial implementation evidence. Remaining work includes custom data on
two other targets, total definitions/termination, structural refinements, complete
output formatting and public minify plumbing, WASM/API parity, full acceptance
reconstruction, release documentation, and version/package updates. Java and
Rust test/adaptor output formatting is not yet complete.

Python custom data now uses generic dataclasses with checked native bridges.
List/Maybe/Either adapters share those bridges even when no user data is declared,
so extracting a structural field and returning it has a consistent representation.
Standalone runtime checks cover copied recursive lists, native matching, raw
units/bytes, unsigned maxima, IEEE/Symbol equality, nested absence, and metadata
errors. Hypothesis checks cover recursive shrinking, uneven field budgets,
deep singletons, longer lists, empty domains, and constructor costs.
Generated data and collection examples run under both profiles and custom
layouts, with eight deliberately incorrect adapters exposed across the two
integration suites. Native Python support uses four-space indentation and
80-column layouts; complete test/adapter/scalar-runtime formatting remains open. The compiler suite
now passes 155 examples. The Python custom-data matrix includes a field-extraction
regression and four Hypothesis generation/shrinking checks; the standalone
native/schema suite passes nine checks in readable and compact layouts.

JavaScript and TypeScript custom data now use named native variant classes and
TypeScript generic unions, with checked schema bridges for adapters. Shared
schema support is independent of fast-check; a separate test helper composes
native arbitraries and shrinkers with minimum field budgets and variable list
lengths. Both readable/compact native fixtures and both machine profiles pass
14 runtime/generator checks, and TypeScript 5.9.3 checks generic payload types.
Main generated data and standalone collection projects pass under both profiles,
including custom layouts and duplicate names across units. Eight adapter mutants
per target cover dropped trees/lists, ignored fields, raw-unit loss, replaced
sorting elements, and collapsed Maybe/Either states. The reconstructed compiler
suite now passes 157 examples. Complete output formatting, main minify plumbing,
and remaining all-target acceptance are still outstanding.

Go native declaration and schema groundwork is now implemented in GoData and
lawspec_schema.go. As in Go+'s enum lowering, each data type has a sealed generic
interface and named native variant structs; marker signatures retain phantom
parameters. Recursive and mutually recursive declarations compile without erased
public fields. Named scalar/presence support preserves generic field domains.
Schema descriptions derive from Core.Schema and validate logical values with
contextual constructor/field errors, copied containers, IEEE equality, Symbol
identity, and distinct nested absence states. Metadata is copied on registration.
`tools/go-data-integration.mjs` passes native/schema checks in readable and compact
layouts, verifies exact gofmt output, and confirms rejection of five ill-typed
native assignments. The compiler suite now has 159 passing examples.
This is groundwork: Go native conversion bridges, Rapid generation/shrinking,
and main-emitter integration are still required; its custom-data gate remains.

Go now also has generated typed codec factories. Recursive and mutually recursive
native values round-trip through checked Core schemas; container/scalar copies
prevent adapter mutation from changing logical fixtures. Native tests cover
UInt64/big integers, exact decimal/rational, IEEE floats/complex, supplementary
characters, raw surrogate units, bytes, Symbol identity, native absence values,
and nested Nullable/Optional/Maybe/Either. Invalid native variants, nil variants,
invalid UTF-8 Text, nil exact-number representations, and cyclic native/logical
values fail contextually; shared acyclic subtrees remain valid. Native machine
profiles are checked for the complete binding, including unselected variant
fields. Generated codecs and runtime support match gofmt, and all native checks
pass in both layouts and both profiles. Compiler coverage is now 160 examples.
Go Rapid generators and main-emitter connection remain outstanding.

Go schema generation now composes native Rapid arbitrary choices, slices, and
scalar generators. Each product reserves field minima, lists choose a length
within the available structural budget, and nullary constructors use Rapid.Just.
Construction caches are completed before draws, rather than mutated while a
property runs. Reconstructed checks cover an exact 16-node uneven product, deep
singletons, recursive validity, empty domains, and absence/Either constructor
costs. Deliberately failing properties exercise actual Rapid shrinking and finish
at a five-element list and Leaf 1; each candidate is schema-validated and checked
against its budget. These checks pass in both declaration layouts, and validity
checks cover both machine profiles. Test support is emitted separately from the
framework-independent runtime/schema/codecs and matches gofmt. The main Go
emitter still needs this support wired to native adapters, examples, properties,
boundaries, contracts, and custom layouts before its custom-data gate is removed.

The main Go backend now emits native data declarations, schemas, typed codecs,
and separate Rapid test helpers. Its custom-data target gate is removed. Native
adapter signatures, calls and contracts, construction/matching/equality, examples,
boundaries, finite cases, and structural/refined generators use the checked
schema path. Nullable boundary and literal encoding retains complete type
arguments, including nested presence. Adapter/native-name collisions fail before
artifact emission. `tools/go-data-properties.mjs` compiles and runs data,
contracts, matching, standalone collections, and scalar-catalog examples under
both machine profiles, with duplicate declarations across units and custom
source/test placement. Eight incorrect adapters are exposed per profile.
GO.md documents the native public representations and generated support files.
Compiler coverage remains 160 passing examples. Haskell/Kotlin custom-data
integration, total definitions, structural refinements, complete default/minified
formatting, WASM parity, package verification, and release updates remain open.

Haskell native declaration groundwork now uses ordinary algebraic data types,
parameterized constructors, and named record fields, with package-wide name
planning. Native Text is Data.Text.Text; List Char is [Char]. Native Maybe,
Either, recursive/mutually recursive types, phantom parameters, and empty data
compile in readable and compact declaration layouts. Stock Eq preserves IEEE
component behavior and does not add an unnecessary phantom Eq constraint.
New named support types cover Decimal, raw code-point/UTF-16 text, Symbol,
Null/Undefined, and distinct Nullable/Optional states. Their scalar bridges
preserve exact values and raw units; nonfinite base-ten fractions are rejected.
`tools/haskell-data-integration.mjs` compiles/executes native checks and confirms
GHC rejects wrong generic payloads, fake empty inhabitants, and String-as-Text.
Compiler coverage is 162 passing examples. Haskell schema/codecs, native
Hedgehog generation/shrinking, and main-emitter integration are still pending;
its custom-data gate remains in place.

Haskell now emits framework-independent schema metadata from Core.Schema, with
checked type references, parameter substitution, constructor/field validation,
List/Maybe/Either and presence composition, equality, and lazy branch selection.
Malformed nested fields fail with their constructor/field context, including when
an equality or match could otherwise ignore that payload. Checks cover raw text,
UInt64 maxima, IEEE NaN/signed zero, Symbol identity, finite/empty domains,
metadata rejection, and both machine profiles in readable/compact output.
Haskell record selector names are planned across all constructors: ambiguous
constructor/field concatenations receive stable unique identities. A compiled
regression covers that collision. The compiler suite now passes 163 examples.
Native custom-data codecs, Hedgehog strategies, and the main Haskell connection
remain outstanding.

Haskell typed custom-data codecs are now emitted separately from native data and
schema declarations. Recursive/mutually recursive data and composed native
List/Maybe/Either/Nullable/Optional fields round-trip through checked schemas.
Encoders return contextual Either failures for invalid characters, negative
BigUInt, and nonfinite decimal conversions. Tests cover exact/large numbers,
IEEE NaN/signed zero, complex values, supplementary/raw text, arbitrary bytes,
Symbol identity, absence, invalid tags/arity, and empty types. Native machine
profile checks inspect the whole binding, including unselected variant fields.
A pre-existing Word16 bridge bug for CodeUnit16 was fixed and regression-tested.
Readable/compact fixtures pass both machine profiles; compiler coverage is now
164 examples. Hedgehog strategies and the main Haskell emitter connection are
still required before its custom-data gate can be removed.

Haskell now has separate native Hedgehog strategy support for instantiated Core
schemas. Bounded construction caches generator results, reserves each product
field's minimum size, and varies list lengths using native Hedgehog generators.
Fresh checks validate recursive candidates and shrink trees in both machine
profiles and both declaration layouts. They cover empty domains, exact uneven
product budgets, deep singleton lists, and shrinking to a five-element list or
Leaf 1. These checks run via tools/haskell-data-integration.mjs with an optional
LAWSPEC_GHC_PACKAGE_DB for the locally installed Hedgehog package. Connecting
strategies and typed codecs to the main Haskell emitter is still outstanding.

The main Haskell backend now emits native declarations, schema metadata, typed
codecs, and separate Hedgehog test support. Custom data construction, matching,
equality, native adapter calls, contracts, examples, boundaries, and recursive
properties use checked Core schemas; its custom-data target gate is removed.
Haskell scalar properties use native Hedgehog primitive generators, including
exact numbers, IEEE bit patterns, raw text, bytes, and distinct presence states.
Primitive candidates and immediate shrinks validate in both machine profiles.
Generated data and standalone collection projects pass under both profiles and
custom source/test roots; each scenario exposes five incorrect adapters. The
scalar adapter/catalog project passes at native width and exposes four mutants
for promoted arithmetic, Symbol identity, raw text, and collapsed absence.
Cross-unit duplicate Pair declarations and finite domains pass in the custom
32-bit project. Compiler coverage is now 166 passing examples, and 23 Core/backend
modules satisfy the checked-Core boundary. HASKELL.md is included in package-build
inputs; its scaffold declares containers/mtl test dependencies. Kotlin custom
data, total definitions, structural refinements, full formatting/minify, WASM
parity, and release/package acceptance remain unfinished.

Kotlin native declaration groundwork now emits sealed interfaces with named,
typed generic variants, recursively using native lists and JVM Maybe/Either.
Named nullable/optional wrappers retain nested presence type arguments; native
support covers absence and Symbol identity. Scalar fields use explicit native
representations, including exact Java numbers, Ratio/Complex, and raw units.
Primitive Kotlin names are qualified so user types such as String cannot shadow
them. Compiled regressions cover a type named T0 and a variant sharing its
owner's simple name. The shared JVM schema renderer consumes Core.Schema without
reinterpreting surface syntax. tools/kotlin-data-integration.mjs passes native
execution and schema checks in both layouts/profiles and rejects four invalid
native assignments. Compiler coverage is 168 passing examples; 24 modules satisfy
the checked-Core boundary. Kotlin typed codecs, Kotest data generation, and the
main custom-data connection remain outstanding; its target gate is still active.

Kotlin now emits typed native codec factories separately from its declarations
and shared JVM schema. Recursive and mutually recursive fields compose codecs
inside conversion bodies, avoiding eager recursive factory construction.
List/Maybe/Either and named Nullable/Optional fields retain their payload types.
Dedicated Kotlin bridges handle Unit, absence, Symbol tokens, and raw code-point
arrays without depending on Kotest. Round-trip checks cover copied mutable native
containers, UInt64 maxima, exact numbers, supplementary/surrogate text, raw bytes,
IEEE NaN/signed zero/infinity, nested absence, and Symbol identity. Invalid fields
report constructor/field context; machine domains use checked BigInteger values
under both profiles. Five negative Kotlin compilation cases include a codec with
an incompatible generic payload. Compiler coverage is 169 passing examples.
Kotlin native generation/shrinking and main-emitter wiring remain unfinished;
the custom-data target gate stays active until those paths are executable.

Kotlin recursive generation now composes native Kotest arbitraries from shared
schemas, with cached bounded construction, field-minimum allocation, variable
list lengths, finite absence, and diagnostics for empty domains. Checked the
cached Kotest 5.9.1 implementation: flatMap discards the source Sample shrink tree.
The new lawspecFlatMap helper retains source and dependent native RTree branches,
so constructor choices and list lengths shrink alongside payloads. No scalar
values are generated by mapping integer seeds. Fresh native checks pass in both
layouts/profiles: uneven products at their exact minimum, deep singletons, empty
containers, recursive validity, shrinking to five list elements and Leaf 1, and
constructor-choice shrink candidates. All inspected candidates stay within their
node budgets and pass schema validation. Kotlin's main compiler connection and
actual generated property/mutant projects are still required before removing its
custom-data target gate. Compiler checks remain at 169 passing examples.

Kotlin's main custom-data path is now connected and its target gate removed.
Native adapter signatures and checked codecs, construction/matching, equality,
contracts, examples, boundaries, finite cases, and Kotest generators all consume
checked Core/schema types. List matching validates before branch selection and
preserves the checked tail; presence literals retain full type arguments.
Ordinary scalar properties now use native Kotest generators as well. Generated
data and standalone collection projects pass under both machine profiles, each
exposing five incorrect adapters. The 32-bit data project executes 1,918 tests,
including duplicate Pair declarations across units, finite domains, matching,
contracts, and separate custom source/test roots. Scalar adapter/catalog projects
pass under both profiles and expose four further mutants per profile. Kotlin
adapter/JVM runtime name collisions and reserved Kotlin packages fail before
output. KOTLIN.md is included in package-build inputs. All eight targets now have
main custom-data paths, but this does not complete the release: total definitions,
structural refinements, complete default/minified formatting, native/WASM parity,
regeneration/package acceptance, and 0.9 documentation/version updates remain.


Total definitions now have a source frontend and closed reference execution.
A unit-level `definition size (xs :: List Int8) :: BigInt is ... end` supplies
its signature and body together. The frontend resolves forward references and
custom constructor identities, keeps lexical parameter scope, contextualizes
results, and retains bodies in Core units. Whole-program validation audits every
body, including unused definitions, and checks declaration ownership. Expression
validation is split into Core.Expression to avoid a dependency cycle with the
totality auditor. Core.Definitions prepares a closed evaluator after validation;
its calls validate argument counts, value domains, and results without invoking
external adapters. The public schema-3 view and generated TypeScript declarations
now expose definition bodies.

This is not complete total-definition support. Generic specialization,
refinement-bearing signatures and calls in refinement predicates, and generated
source functions across all eight backends remain outstanding. Until emission is
implemented, generation rejects programs containing definitions before producing
artifacts; it never creates replacement user-owned stubs. Existing bundled
examples remain executable. Source/reference regressions cover both profiles,
list recursion, forward calls, custom sums, lexical shadowing, malformed inputs,
unsafe unused definitions, Core ownership, and the temporary emission diagnostic.


Rust now emits checked total definitions into a reusable generated source module,
with public native signatures grouped by unit and private resolved-ID calls.
Generated properties and source functions share RustExpr's typed expression
renderer. Definition bodies do not become adapter stubs; ordinary external
functions retain user-owned adapters. Native entry points validate values,
preserve raw nested code units and absence, share Symbol context, and check
native machine widths across complete bindings. Definitions themselves have no
property-framework dependency.

Fresh tools/rust-definitions-integration.mjs checks pass under both profiles,
including a custom 32-bit layout, recursive lists/trees, forward calls, duplicate
function names across units, exact promotion/decimal arithmetic, lazy guarded
remainder, sums, raw units, Symbol identity, and nested absence. Readable sources
match rustfmt exactly; separately emitted compact definitions compile and run.
Three adapter mutants fail per profile. A native-only Cargo project declares no
Proptest dependency and passes 19 tests. Regeneration preserves edited adapters
and rejects edits to generated definition source. Existing Rust data integration
and the scalar conformance suite pass, including five data mutants per profile
and seven scalar mutants (one is the stub). Compiler coverage is 191 examples;
29 modules satisfy the Core/backend boundary. Logs:
.artifacts/rust-definitions-integration.log, .artifacts/rust-data-integration.log,
and .artifacts/rust-scalar-integration.log.

The other seven definition emitters, generic/refinement definition integration,
structural refinements, complete project formatting/minify, native/WASM parity,
package acceptance, and release updates remain outstanding.


Java now emits total-definition bodies as framework-independent generated source
and supplies native entry points under lawspec.definitions. Native schemas and
codecs preserve public data types, checked value domains, copies, raw code units,
Symbol context, and presence states. Exceptions at definition boundaries include
the resolved definition identity. Java properties and definitions share a typed
JavaExpr renderer; public wrappers use structured type/codec documents rather
than formatting rendered text. Other declarations remain user-owned adapters.

The integration corpus is now shared at test/fixtures/total_definitions.lawspec.
Java checks cover both profiles, custom layouts, forward and recursive calls,
native entry points, malformed native values, four native type-mismatch programs,
three adapter mutants, compact source, and regeneration. Readable definition
files match Google Java Format exactly. Source-only javac checks have no JUnit
or JetCheck classpath. Existing Java data properties pass all four width/layout
combinations; scalar conformance and seven adapter mutants also pass. Compiler
coverage is 193 examples, and 31 modules satisfy the Core/backend boundary.
JAVA.md is included in the source/package build inputs. Logs:
.artifacts/java-definitions-integration.log, .artifacts/java-data-properties.log,
and .artifacts/java-scalar-integration.log.

Definition emission for Python, JavaScript, TypeScript, Go, Haskell, and Kotlin
remains unfinished, as do generic/refinement definition integration, structural
refinements, complete formatting/minify, WASM/package acceptance, and release
updates. No release artifacts have been rebuilt or published for this milestone.


Kotlin now emits native typed total-definition entry points over the shared JVM
implementation bodies. Source helpers compile and execute without Kotest;
properties invoke checked bodies directly, while ordinary adapters retain user
ownership. Lists, custom variants, presence payloads, raw units, Symbol identity,
exact arithmetic, and portable machine integers pass checked native boundaries.
Kotlin and Java share body emission without generating Java native wrappers for
Kotlin targets. Kotlin wrapper types and codecs use structured documents.

Fresh definition integration passes both machine profiles, including custom
32-bit roots, recursive properties, four rejected native type mismatches, three
incorrect adapters per profile, compact execution, and regeneration protection.
Shared Java bodies match Google Java Format. External Kotlin formatter agreement
remains unverified. Existing Kotlin data properties and five mutants pass under
64 bits. Compiler coverage is 195 examples; 32 modules pass the Core boundary
check. Logs: .artifacts/kotlin-definitions-integration.log and
.artifacts/kotlin-data-properties64.log.

Definition emission for Python, JavaScript, TypeScript, Go, and Haskell remains
outstanding, along with generic/refinement definition integration, structural
refinements, complete formatting/minify, WASM/package acceptance, and release
updates. This milestone does not complete 0.9 or publish any release.


Python now emits checked total definitions with typed native entry points under
lawspec_definitions and shared logical implementations in source directories.
Source calls run with Python's site initialization disabled and import neither
Hypothesis nor pytest. Definition bodies and properties share PythonExpr's typed
renderer, including lazy guards/matches, structural equality, checked conversions,
and lossless tagged literals rendered as structured Python values. Public wrappers
validate native payloads and add definition context to errors. User functions can
be named str without shadowing validation built-ins. Module/package and generated
support-name collisions fail before output; definitions never become adapter stubs.

The definition corpus passes under both machine profiles, custom 32-bit roots,
and readable/compact source. Checks cover recursive lists/trees, forward calls,
parameterized product payloads, raw units and copies, Symbol contexts, all nested
absence states, ambient Decimal rounding independence, machine ranges, malformed
native values, three incorrect adapters per profile, and regeneration protection.
Readable definition files fit 80 columns with four-space indentation; exact
external formatter agreement remains unverified. Existing Python data integration
passes both profiles and four mutants each. Scalar conformance passes 2,690 tests
and seven mutants. Compiler coverage is 197 examples; 34 modules satisfy the Core
boundary check. Logs: .artifacts/python-definitions-integration.log,
.artifacts/python-data-integration.log, .artifacts/python-scalar-integration.log.

Definition emission for JavaScript, TypeScript, Go, and Haskell remains unfinished.
Generic/refinement definition integration, structural refinements, complete
formatting/minify, WASM/package acceptance, and release updates remain required.
No release artifact was rebuilt or published for this milestone.


JavaScript and TypeScript now emit total definitions into generated source modules,
with public native entry points grouped by unit and resolved-ID implementation
calls. TypeScript wrappers retain generic lists, sums, products, and nested
presence types. Implementation bodies use explicit unknown values behind checked
schema boundaries and compile strictly without any or ts-nocheck. Existing scalar
and schema support still uses ts-nocheck; this milestone does not claim otherwise.
Source-only execution has no fast-check dependency. Properties and definitions
share WebExpr; portable runtime type keys are centralized in Backend. Web presence
values consistently use schema conversions, even without custom declarations.

Fresh tools/web-definitions-integration.mjs passes both targets/profiles, readable
and compact source, custom 32-bit roots, recursive lists/trees, forward calls,
parameterized products, six rejected TypeScript assignments, native malformed
values, raw units/copies, Symbol identity, exact numbers, presence, sparse arrays,
three adapter mutants per target/profile, and regeneration protection. Definition
files fit 80 columns with two-space blocks and four-space continuations. Shared
JavaScript string escaping emits single quotes and preserves apostrophes,
backslashes, newlines, supplementary characters, and Unicode line separators.
Exact external formatter agreement remains unverified.

Existing web data and standalone collection suites pass all eight target/profile
combinations with their mutants. Each scalar target passes 2,690 tests and seven
mutants. The scalar adapter fixture avoids duplicate runtime imports when schemas
are present. Cached TypeScript 5.9.3 dependencies were linked locally to replace
the deleted integration directory; no download or global install was needed.
Compiler coverage is 199 examples; 37 modules pass the Core/backend boundary.
WEB.md is included in package-build inputs. Logs:
.artifacts/web-definitions-integration.log, .artifacts/web-data-properties.log,
and .artifacts/web-scalar-integration.log.

Go and Haskell definition emission remain unfinished, along with generic/refined
definition integration, structural refinements, complete formatting/minify,
WASM/package acceptance, and release updates. No release has been published.


Go now emits native definition methods on LawSpecDefinitions in each unit's source
package, with checked logical bodies and shared GoExpr rendering for properties.
The dedicated method namespace permits a definition and data type to share a name
without erasing native types or changing adapter names. Public signatures retain
native lists, generic products/sums, and presence. Codecs validate/copy values,
share Symbol context, and audit whole-binding native machine profiles. Pure bodies
use the configured profile; native machine bindings reject architecture mismatch.

Fresh tools/go-definitions-integration.mjs passes both profiles, a custom 32-bit
root, source-only packages without Rapid, four native compilation failures,
recursive properties, forward calls, parameterized products, raw units/copies,
exact arithmetic, nested absence, Symbol identity, malformed native values,
architecture mismatch (including an unselected alternative), three adapter mutants
per profile, compact execution, and ownership/regeneration. Readable source
matches gofmt exactly. CompactTabs preserves Go indentation without expanding tabs;
Go data/schema/codec documents use it too. Existing Go native data and shrinking
checks pass in both layouts, and data/collection properties plus mutants pass in
both profiles. Scalar conformance and seven mutants pass after adapting the scalar
fixture to formatted Go stubs and typed presence results. Compiler coverage is 202
examples; 39 modules pass the Core boundary. Logs:
.artifacts/go-definitions-integration.log, .artifacts/go-data-integration.log,
.artifacts/go-data-properties.log, and .artifacts/go-scalar-integration.log.

Haskell definition emission, generic/refined definition integration, structural
refinements, complete formatting/minify, WASM/package acceptance, and release
updates remain unfinished. No release has been published.


Haskell now emits native total-definition entry points and shared checked bodies
as framework-independent source. Properties and definitions use the same typed
expression renderer. Native arguments/results retain concrete types and checked
codecs, with contextual errors and whole-binding machine-profile checks. Symbol
fixtures use an explicit context backed by Data.Unique; codecs preserve scoped
identity, and generated tests allocate contexts per example/property iteration.
A missing scoped Symbol codec branch was fixed and independently exercised.

Fresh tools/haskell-definitions-integration.mjs passes both profiles, readable and
compact definitions, custom roots, recursive lists/trees, forward calls, generic
product payloads, duplicate function names across units, raw UTF-16, exact numeric
promotion, lazy guards, nested absence, Symbol identity, invalid native values,
four rejected native type assignments, three adapter mutants per profile, and
regeneration protection. Source-only compilation has no property-framework package
database. The generated definition corpus fits 80 columns; this does not establish
formatter agreement or complete formatting of legacy tests/runtime source.

Existing Haskell native data/schema/codec/generator/shrinking checks pass in both
layouts. Data and collection properties pass both profiles with five mutants per
scenario; scalar properties pass under 64 bits with four mutants. Compiler coverage
is 203 passing examples; 41 modules satisfy the Core/backend boundary. Logs:
.artifacts/haskell-definitions-integration.log, .artifacts/haskell-data-integration.log,
and .artifacts/haskell-data-properties.log.

All eight targets now emit concrete total definitions. Generic/refinement-bearing
definitions, structural refinements, complete default/minified formatting,
WASM/API parity, package acceptance, and release updates remain unfinished.


Generic-definition groundwork now distinguishes monomorphic environment bindings
from explicitly universal type schemes in LawSpec.Inference. Instantiation
freshens only quantified variables and retains free monomorphic variables and
capability obligations. Typed-expression inference links curried applications,
composition members, contextual literals, and final binder types to the same
substitutions. typedExpressionWithSchemes returns both the resolved tree and its
instantiated obligations, so a specialization caller can audit capabilities.

Eleven inference regressions cover independent uses, shared parameters within one
signature, curried applications, annotated empty lists, composition, free
variables, monomorphic function parameters, match-binder shadowing, duplicate
quantifiers, and per-instantiation capabilities. The complete compiler suite passes
214 examples. All 288 generation requests across bundled specs plus the total
corpus, both profiles, and all eight targets match the pre-refactor compiler's
successful output exactly (.artifacts/inference-output-parity.log).

This does not yet enable generic source definitions. Next work must build source
schemes, audit unused templates and their capabilities/termination, and specialize
the closed definition call graph into concrete Core definitions with stable IDs.
Parameters and recursive self-calls must remain monomorphic within a template;
polymorphic recursion must not create an unbounded specialization worklist.
Do not erase a Universal binding through environmentTypes when adding scheme-aware
elaboration: current callers of that compatibility accessor contain only
monomorphic bindings. Generic/refined definitions and full release acceptance
remain unfinished.


Definition syntax now accepts an explicit requires clause after the result type.
The source model retains requirements through refinement expansion and data-name
qualification. Concrete definitions check those capabilities even when unused.
validateDefinitionTypes also provides a template type/capability audit using
rigid signature variables, monomorphic recursive self-calls, lexical parameter
scope, and independently instantiated calls to other definitions. It checks
unbound annotations/requirements and structural Eq through named products.
Symbolic machine bounds remain symbolic until specialization.

Abstract comparisons no longer assume that separate Eq or Ordered requirements
provide cross-type numeric compatibility. Separate abstract operand types require
a shared Integer domain (ordered numeric literals retain contextual handling).
This preserves existing exact/inexact restrictions under specialization.

The compiler suite passes 228 examples, including 14 new definition/template
checks. The new bundled examples/specs/total_functions.lawspec covers explicit
capabilities, exact promotion, recursive counting, and structural equality; its
expected values execute in the reference evaluator and it emits for all targets
under both profiles. Generated Haskell tests execute under both profiles (284
examples in each). The 288 prior generation requests remain unchanged from the
pre-scheme compiler. Logs: .artifacts/definition-capability-parity.log and
.artifacts/total-functions-haskell.log.

The generic template audit currently proves typing/capability requirements only.
It does not establish structural descent, closed dependencies, or definedness.
Generic source execution remains gated by the concrete-signature check; the next
step must connect template totality auditing and closed-call specialization before
removing it. Refined definitions, structural refinements, full formatting/minify,
WASM/API parity, package acceptance, and release updates remain outstanding.


Generic-template totality now uses a shared proof checker in Core.Totality.
Core.Total validates concrete expressions first, then lowers them to proof
obligations. DefinitionTotality lowers already-typed templates to the same
obligations; it never fabricates executable Core evidence or passes surface nodes
to backends. The shared audit checks closed dependencies, mutual recursion,
strict structural descent on a common parameter, lazy nonzero/presence facts,
and conversion obligations. Identity conversions preserve subterm provenance.

The frontend runs both typing/capability and proof audits for concrete definitions.
Generic template checks directly exercise list/tree recursion, rebuilt arguments,
alternating descent, shadowed pattern binders from different roots, guarded
remainder, presence, widening/narrowing, decimal scale conversions, skipped
branches, adapter calls, mutual recursion, and both machine profiles. Generic
Integer parameters now support explicit numeric conversions and exact rounding;
capabilities still control whether those operations typecheck. Core constants
are validated before proof extraction, even in skipped branches.

The compiler suite passes 241 examples. All 304 generation requests (bundled
specs plus the shared total-definition corpus, both profiles, eight targets)
match the preceding compiler exactly. Core/backend boundaries pass for 42
modules. Log: .artifacts/totality-proof-parity.log.

Generic source execution remains gated: the remaining step is to specialize
closed generic calls into concrete Core definitions with stable identities and
checked capabilities. Preserve independently instantiated calls, monomorphic
self-recursion, lexical scopes, all example/property/contract expressions, and
unused-template auditing when connecting this. Refined definitions, structural
refinements, full formatting/minify, WASM/API parity, packaging, and release work
also remain unfinished.


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


## Source List payload refinements (2026-09-27)

Enabled List payload predicates through an internal scoped surface expression,
monomorphic binder inference, capture-avoiding substitution, generic helper
specialization, template definedness auditing, and typed Core AllElements
elaboration. Public schema-3 JSON and npm declarations describe the node.
Nested Lists and Lists mixed with Maybe/Either preserve element scope; example
inputs outside these domains are rejected. Generic definition contracts check
their List payloads at entry. Missing capabilities and unguarded division in
definition predicates remain rejected.

Added examples/specs/list_refinements.lawspec with independent recursive
validators, nested lists, prior-input dependencies, empty continuations at the
Int8 maximum, and guarded exact division. All data integration harnesses now
include this spec. Java composes native list generation with element preparation
and filtering, preserving valid lists and native shrink trees instead of relying
on rejection of entire large nested lists. A JetCheck regression proves valid
shrinking to a five-element counterexample and the empty-list witness.

Fixed scoped-node public serialization, qualified Haskell Bool literals in
definition bodies, and Rust nested-list literal documents. The compiler suite
passes 365 examples; the npm declarations type-check. Both machine profiles and
readable/compact native acceptance are recorded in RECOVERY.md after completion.
Universal List precondition implication at closed definition calls is still
conservative. Named field/payload refinements, remaining external formatter
conformance, WASM/parity, packaged-install acceptance, and release metadata
remain unfinished. No 0.9 release has been prepared or published.


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

## Verified callee-result guarantees (2026-09-27)

The shared proof checker now names evaluated call results and introduces their
postconditions after proving call preconditions and recursive descent. It can
use those guarantees in exact arithmetic, checked narrowing, nested calls,
Boolean result predicates, and universal List predicates. Recursive List
construction proves element guarantees by structural induction. Returned values
never acquire structural provenance merely from their arguments. Result-case
facts respect matching and short-circuit evaluation. Fixed a pre-existing loop
in nonzero fact extraction when both comparison operands were literals.

The expanded source contract fixture exercises a recursive copy with a refined
result and uses a nonzero-returning helper in exact reciprocal sums. All eight
native targets pass both width profiles and readable/compact modes (32 cases),
including existing invalid-input and corrupted-result checks. Rust constructor
fields now materialize complex expressions in ordered locals; all 260 bundled
Rust artifacts match rustfmt. Compiler tests cover safe and unsafe uses, false
callee guarantees, recursive descent, unrelated variables, and branch scoping.

Remaining release work includes named field/payload refinements, outstanding
formatter conformance, WASM/parity and package acceptance, and 0.9 metadata/docs.
No version bump or publication has occurred.

## Rebuilt WASM and packaged installation (2026-09-27)

Rebuilt the actual WASM compiler with the cached WASI toolchain. Added concrete
specialization-helper signatures for GHC 9.14 and synchronized Cabal dependencies
(directory/filepath), bundled examples, and fixture source files with package.yaml.
The build script accepts an explicitly supplied LAWSPEC_CORE; it retains the
normal Stack build when none is supplied. Build fingerprints now include the
Cabal manifest. Generated API declarations pass TypeScript checking.

Expanded native/WASM parity to all 22 bundled specs plus invalid-range/Unicode
fixtures, all eight targets, both widths and both layouts: 768 generation cases
pass. Check and expand also agree for all 24 fixtures at both widths (96 calls).
Dedicated WASM tests check nested Maybe states, Either payloads, raw UTF-16/octet
values, named product fields, and recursive sum declarations.

The packed installation passes offline using locally cached exact npm and Cargo
dependencies. It executes installed JavaScript and Rust scaffolds/tests, doctor,
regeneration, the API, all-target examples export, and bundled documentation.
The tarball is a development verification artifact still labeled 0.8.0; it has
not been published and is not the final 0.9 release. Native compiler tests remain
384/384. Logs: .artifacts/structural-wasm-parity.log,
.artifacts/package-structural-smoke.log, .artifacts/npm-structural-api-tests.log.

The complete npm suite is also being reverified after correcting old hard-coded
artifact counts to distinguish property tests from reusable strategy helpers.
Named field/payload refinements, remaining formatter conformance and complete
release metadata/documentation still need work. Later compiler changes require
another WASM/fingerprint/parity rebuild before release.

Complete npm verification finished: 38 existing tests pass, including all-target
example exports, preservation of edited adapters/tests, and unsafe-output-path
rejection. The two new structural API tests pass separately (40 tests total).

## Constructor-sensitive contract proofs (2026-09-27)

Shared proof terms now preserve constructor identities and tagged match branches.
Template and concrete Core lowering use the same representation. Known constructor
results substitute actual fields into the selected branch; unknown matches bind
fresh fields and instantiate only the matching value/constructor's predicates.
This supports refined Maybe/Either results, nested sum construction, safe payload
arithmetic, and whole-value product refinements relating multiple fields.

A named Range example in compiler tests proves upper > lower, safely evaluates
1/(upper-lower), and transfers the result guarantee through build and gap helper
calls. Reversed fields, wrong Either alternatives, unrelated divisors, shadowed
binders, and capture-prone substitutions are rejected. This is a prerequisite for
direct field contracts, not their implementation: declaring refinements on named
fields and refined named type arguments remains unsupported.

389 compiler tests pass. The native fixture carries refined values through
Maybe and Either before exact division; all 32 target/profile/layout cases pass.
Updated bundled-example checks match Google Java Format (18 artifacts), gofmt
(20), and rustfmt (14). WASM was rebuilt and its fingerprints match current
sources. Targeted parity is being checked for the affected examples; full release
parity/package acceptance will be repeated after the remaining compiler work.

Targeted constructor-contract parity completed: 128 generation cases and 16 check/expand calls passed across both widths/layouts and all eight targets.


## Python PEP 8 verification (2026-09-27)

Python now uses PEP 8 rather than Google/YAPF. The independent pycodestyle
2.14.0 audit passes for 218 generated artifacts across bundled examples and the
total-definition fixture, both machine widths. Readable and compact outputs
have identical ASTs, including literal values. Static runtime/schema/strategy
sources also pass the checker with 79 code columns and 72 prose columns.

Shared Python documents handle lambda spacing, scoped short binder names,
wrapped type annotations and lossless adjacent string literals. Primitive
integers, booleans, raw character units, and bytes use faithful Python literal
representations to avoid excessive nesting. Runtime sources remain independent
of Hypothesis. Native scalar execution passed 2,690 cases; List/Maybe/Either
properties and deliberately incorrect adapters passed both width profiles.


## Structural language reference (2026-09-27)

LANGUAGE.md now documents implemented 0.9 List/Maybe/Either syntax, named
parameterized products/sums, exhaustive matching, native representation and
structural equality, recursive generation, finite/empty domains, and Haskell
Text versus List Char. Its grammar includes data declarations and total
functions. GADTs/indexed families and general dependent types remain explicitly
future work; unfinished direct named field/argument refinements remain marked
as rejected. No implementation requirement was dropped from this plan.

Five complete or unit-wrapped LawSpec reference snippets pass planGeneration
on all eight backends and both machine widths (80 cases). The README distinguishes
the development feature set from the installed 0.8 release. Java, Python, Go,
Web and Kotlin guides no longer incorrectly claim that generic definitions or
refined signatures are unsupported. Updated guides are byte-synchronized with
npm/; npm pack --dry-run confirms they are included. Build fingerprints still
match. Logs: .artifacts/language-reference-check.log and
.artifacts/language-docs-package.json. This is documentation acceptance, not a
replacement for native execution or the remaining implementation/release gates.


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


### Constructor domain validation checkpoint (2026-09-27)

Common planning now filters fully enumerated constructor domains through their
field contracts. A provably empty field eliminates its constructor even when
another field is recursive or infinite. Contract reachability follows stored
parameters, preserving phantom parameters and unrelated scalar boundaries.
Finite constrained properties can be planned; nonfinite constrained boundaries
still report that a bounded witness plan is needed. Public native generation
remains gated while native enforcement and generator context work are incomplete.

Core candidate validation distinguishes false refinements from malformed values
and evaluator errors. Python uses the corresponding RefinementViolation subtype;
Hypothesis retries only rejected refinements, preserving unexpected failures.
The transformers dependency is explicitly declared for packaged/WASM builds.

Verification: 431 compiler tests, ten direct Python contract tests, generated
Python contract integration at both widths and layouts (including two mutants
per configuration), and existing Python native matrices at both widths pass.
The 222-artifact Python formatting corpus and twelve generated contract artifacts
pass PEP 8 and readable/compact AST parity. Python remains PEP 8 by user choice;
compact output requires --minify. Native/WASM builds, embedded-runtime checks,
source fingerprints and the 56-module compiler boundary pass.

Logs: .artifacts/constructor-domain-{tests,python,existing,formatting,wasm,parity}.log.
No version bump or publication occurred. General constrained witness planning,
generator Symbol context/hints, remaining native field-contract backends,
recursive refined payloads and final release/style acceptance remain open.

Focused native/WASM parity passes 128 generation responses and 16 check/expand requests. Field-contract generation still produces explicit gate diagnostics.
Recovery snapshot: `/private/tmp/lawspec-constructor-domains-20260927.tar.gz`, verified byte-for-byte.


### Bounded constructor witnesses (2026-09-27)

Replaced the blanket nonfinite-constructor boundary rejection with a bounded,
memoized witness search. It combines field extremes and contract scalar literals,
checks all candidates with the reference evaluator, and preserves valid sum
alternatives when another branch has no witness. Recursive expansion uses a global
node budget and a declaration-aware depth bound; combinations are capped. Failure
to find a witness is an explicit search-exhaustion diagnostic, never an empty-domain
proof. Finite enumeration remains separate.

Verified dependent Int8 gaps and Symbol fixture identities at both machine widths,
recursive impossible alternatives, constrained lists and forty-declaration acyclic
chains. All 435 compiler tests pass, followed by fourteen focused planning tests
after extracting the source fixture. Native/WASM parity passes 128 generation
responses and sixteen check/expand requests; native contract generation still
returns the explicit runtime-enforcement gate. WASM/source fingerprints, the
56-module backend boundary and whitespace checks pass. No native emitter or
formatting behavior changed in this checkpoint.

Logs: `.artifacts/constructor-witness-tests.log`,
`.artifacts/constructor-witness-focused.log`,
`.artifacts/constructor-witness-wasm.log`,
`.artifacts/constructor-witness-parity.log`.

The next integration remains context-aware native generators with fixture hints,
then field-contract enforcement/emission for the other native backends. Recursive
refined named payloads, remaining style acceptance and release/package gates are
still open. Version remains 0.8.0; no publication occurred.

Recovery snapshot: `/private/tmp/lawspec-constructor-witnesses-20260927.tar.gz`, verified byte-for-byte.


### Python witness strategy integration (2026-09-27)

The native Hypothesis structural strategy accepts optional checked witnesses in
the caller's Symbol context. It recursively seeds stored fields and List, Maybe,
Either, Nullable and Optional payloads, preserving tags and fixture identities.
Witness node costs constrain each nested strategy's budget. Invalid witnesses
fail immediately. Native strategies remain available alongside sampled witness
alternatives; sampled alternatives may retain large counterexamples rather than
shrink to a global minimum. This behavior is documented in the runtime API.

Thirteen direct runtime checks pass, including nested Symbol identity, invalid
context/seed rejection, wrapper traversal, budget enforcement and nonseed native
generation/shrinking. Generated source callbacks pass both machine widths and
readable/compact layouts; the new test generates three Symbol-bearing elements
from a one-element witness and checks public native APIs with the same context.
Twelve generated artifacts pass PEP 8 and AST parity, and all eight callback
mutants remain detected. Existing native Python matrices pass at both widths.
WASM rebuild/fingerprints, embedded sources and whitespace checks pass. Focused
native/WASM parity passes 96 generation responses and twelve check/expand requests;
field-contract generation still reports its explicit runtime-enforcement gate.

Logs: `.artifacts/python-witness-{integration,existing,wasm,parity}.log`.

Public emitter integration remains: create a fresh shared Symbol context per
property draw, render boundary witnesses in it, pass both to the native strategy,
and retain that same context through assertions/adapter contracts. The current
emitter creates generator context separately from assertion context; do not lift
the public field-contract gate before that integration and its execution tests.
Other backends, recursive refined payloads and final release/style gates remain
open. Version remains 0.8.0 and no publication occurred.

Recovery snapshot: `/private/tmp/lawspec-python-witness-strategies-20260927.tar.gz`, verified byte-for-byte.


### Public Python constructor-contract generation (2026-09-27)

Python public generation is now enabled for constructor field contracts. Each
structural property uses a native Hypothesis data draw with a fresh Symbol map.
Boundary witnesses, nested/scalar strategies, adapter conversion, contract checks
and assertions share that map. Input refinements still filter the complete case.
Scalar-only properties retain their existing generation path. Required direct
Symbol identity equalities use a native singleton strategy; only necessary
conjuncts qualify, never equalities under disjunction. This avoids excessive
rejection when a scalar fixture input accompanies a constrained data input.
Other seven targets retain the explicit native-enforcement gate.

The new tools/python-field-properties.mjs executes public planGeneration output
for dependent Gap, Identity, generic nonempty Bucket, nested positive lists,
sum alternatives, machine fields, guarded division, mixed fixture inputs and
nested identities. Both machine widths and layouts pass, including the custom
32-bit source/test layout. A Symbol-description adapter mutant fails in each
configuration. A deliberately false property proves disjunctive identity
constraints still generate other identities. Sixteen public generated files pass
readable/compact AST parity; readable output passes PEP 8.

All 435 compiler tests, the ordinary 222-artifact Python formatting corpus, and
existing native Python matrices at both widths pass. WASM rebuild/fingerprints,
embedded sources, whitespace checks and the 56-module backend boundary pass.
Native/WASM parity passes 128 generation responses and sixteen check/expand
requests; these include successful Python field-contract generation and explicit
unsupported diagnostics for the other backends.

Logs: `.artifacts/python-field-properties.log`,
`.artifacts/python-field-emitter-{tests,formatting,existing,wasm,parity}.log`.
Per-configuration pytest, adapter-mutant and disjunction logs are under
`.artifacts/python-field-properties/`.

Remaining work includes native enforcement/emission/generation for the other
backends, recursively refined named payloads, remaining formatting acceptance
and release/package gates. Version stays 0.8.0 during development; no publication
occurred. REFINEMENTS.md now describes the verified Python support accurately.

Recovery snapshot: `/private/tmp/lawspec-python-field-emitter-20260927.tar.gz`, verified byte-for-byte.


### Web constructor runtime enforcement (2026-09-27)

The shared JavaScript/TypeScript schema supports ordered constructor predicates
and an explicit Symbol map through validation, native bridges, construction,
matching and equality. Generic constructor instantiation preserves callbacks.
Only actual Boolean true accepts a value; false raises RefinementViolation, while
malformed results and evaluator errors remain contextual TypeErrors. Nested data
and List paths preserve the rejection subtype. Native fast-check tuple strategies
filter only constrained constructors and only catch RefinementViolation, retaining
native shrinking and propagating evaluator faults.

Updated both public-emitter and low-level TypeScript fixture import relocation
for the strategy's new schema dependency. No web public contract-generation gate
was lifted: typed predicate emission, witness seeding and per-case Symbol context
wiring remain necessary.

The web native matrix passes all nineteen tests in every target/width/layout
configuration, including five new tests for all schema boundaries, ordered and
strict predicates, generic Symbol fixtures under List/Maybe/Either/Nullable/
Optional, shared generator context, native shrinking and evaluator errors.
Existing JavaScript/TypeScript data and collection matrices pass at both widths,
including custom layouts and adapter mutants. All 492 generated JS/TS artifacts
pass the continuation/column/quote/operator/whitespace audit and readable/compact
AST comparison. Runtime formatter checks, embedded runtime checks, WASM/source
fingerprints, the 56-module compiler boundary and whitespace checks pass. Focused
native/WASM parity passes 96 generation responses and twelve check/expand requests.

Logs: `.artifacts/web-field-{runtime,properties,formatting,wasm,parity}.log`.
Further web emitter/generator integration, the remaining native backends,
recursively refined payloads and final style/release gates remain open. Version
stays 0.8.0; no publication occurred.

Recovery snapshot: `/private/tmp/lawspec-web-field-runtime-20260927.tar.gz`, verified byte-for-byte.


### Typed web constructor callbacks (2026-09-27)

Separated web native type/reference helpers into LawSpec.WebTypes to keep data
and expression emitters acyclic. WebExpr now accepts contextual type references,
keys and machine width; schema operations carry the caller's Symbol map.
WebData's profile-aware emitter audits constructor contracts, emits callbacks
using that shared renderer, substitutes generic references and preserves callback
metadata. Nested match/element binder identities receive distinct local names.
WebDefinitions propagates the context through native input/result validation.
The reusable schema exports substitution and concrete scalar-runtime type keys;
TypeScript has an explicit FieldPredicate type instead of inferring never[].

New low-level fixture/integration tools compile the constructor source and execute
native JS and strict TypeScript output at both widths and layouts. Checks cover
Int8 full-width differences and exact 1/255 division, nonempty generic lists,
positive elements, sums, guarded division, machine integers and shared Symbol
identity. Each of eight configurations rejects two altered callbacks (ignored
gap and Symbol-description equality). Twenty generated files pass layout and
readable/compact AST checks. This is an executable source-to-native callback path,
not yet public web property generation.

All 435 compiler tests and existing JS/TS data/collection property matrices and
adapter mutants pass. The ordinary 492-artifact web style/AST corpus, embedded
runtimes, WASM/source fingerprints, whitespace checks and the now 57-module
Core/backend boundary pass. Focused native/WASM parity covers 128 generation
responses and sixteen check/expand requests; unsupported web field-contract
property generation remains an explicit gate diagnostic.

Logs: `.artifacts/web-generated-fields.log` and
`.artifacts/web-generated-fields-{tests,properties,formatting,wasm,parity}.log`.

Next: add web native witness seeding and wire one Symbol map through each generated
property case, including CoreScalarEmit schema calls and structural assertion
helpers, before lifting the web gate. The other native backends, recursive refined
payloads, remaining style acceptance and release/package gates remain open.
Version remains 0.8.0; no publication occurred.

Recovery snapshot: `/private/tmp/lawspec-web-generated-fields-20260927.tar.gz`, verified byte-for-byte.


### Web witnesses and bounded native rejection (2026-09-27)

The fast-check structural strategy accepts checked witness values and recursively
seeds stored fields and container payloads in the supplied Symbol context. Node
costs constrain each nested seed, and native arbitraries remain available alongside
constant alternatives with cross-shrinking enabled.

Inspection of the installed fast-check FilterArbitrary showed its generate loop
retries forever. Replaced constructor filtering with a small checked Arbitrary
wrapper that delegates to the native generator and retains its Value/shrink
context. It retries complete candidates, not constrained children, so an
impossible nested branch cannot trap generation before a viable enclosing
alternative is tried. The explicit attempt budget defaults to 1000; exhaustion
raises a contextual error and does not claim the domain is empty. Only false
refinements are retried; evaluator errors propagate.

Twenty-three runtime tests pass in all eight JS/TS width/layout configurations.
New coverage includes sparse nested Symbol fixtures, generation beyond supplied
witnesses, invalid context/seed rejection, node budgets, native nonseed candidates
and shrinking, exact attempt limits, and impossible direct/nested sum alternatives.
Generated callback integration passes all eight configurations with witness-driven
native strategies, sixteen callback mutants, and twenty-four artifact layout/AST
comparisons. The original native JS/TS data and collection properties, custom
layouts and mutants pass at both widths. All 492 ordinary web artifacts pass
style/AST checks. Embedded runtimes, WASM/source fingerprints, the 57-module
compiler boundary and whitespace checks pass. Focused native/WASM parity passes
96 generation responses and twelve check/expand requests.

Logs: `.artifacts/web-witness-{runtime,generated,properties,formatting,wasm,parity}.log`.

Public web generation is still gated. Next, create one Symbol context per native
property case, render witnesses within it, pass maxAttempts to the strategy and
retain the context through assertions and adapter conversions before lifting that
gate. Other native backends, recursive refined payloads and final style/release
gates remain open. Version remains 0.8.0; no publication occurred.

Recovery snapshot: `/private/tmp/lawspec-web-witness-strategies-20260927.tar.gz`, verified byte-for-byte.


### Public web constructor-contract generation (2026-09-27)

Enabled JavaScript and TypeScript field-contract generation. Native fast-check
chains create one fresh Symbol map per case, seed each input's strategy within
that context, preserve earlier inputs for dependent fixture equalities, and carry
the map through adapter conversions and structural assertions. Required Symbol
equalities use singleton strategies; disjunctive constraints stay unrestricted.
Input guards use fast-check preconditions rather than an unbounded generation
filter. maxAttempts reaches the whole-candidate native strategy wrapper.
Python keeps its Hypothesis draw path through the shared strategy renderer.

The new constructor_properties fixture and tools/web-field-properties.mjs exercise
public generation for dependent gaps, generic nonempty lists, positive elements,
sums, machine fields, guarded division, nested identities, dependent scalar Symbol
inputs, finite Bool fields, Nullable and Optional. All eight target/width/layout
configurations pass, including custom source/test directories at 32 bits. Each
rejects a Symbol-description adapter mutant and a deliberately false disjunctive
identity law. Strict TypeScript compilation caught and verified a Bool callback
bridge: the checked Core predicate result receives an erased boolean type
assertion; runtime validation still requires an actual Boolean.

Thirty-two new public artifacts pass the full web style/AST audit, and the
ordinary 492-artifact corpus passes. Python's four public field configurations,
mutants and sixteen-artifact AST/PEP 8 checks pass. All 435 compiler tests and
existing JS/TS data/collection property matrices and mutants pass. WASM rebuild,
source fingerprints, embedded runtimes, whitespace checks and the 57-module
Core/backend boundary pass. Native/WASM parity covers 128 generation responses
and sixteen check/expand requests, including successful public JS/TS field output
and explicit gates for the remaining five native targets.

Logs: `.artifacts/web-field-emitter.log` and
`.artifacts/web-field-emitter-{tests,style,python,existing,corpus,wasm,parity}.log`.
Per-configuration correct/mutant/disjunction logs are under
`.artifacts/web-field-properties/`.

REFINEMENTS.md now documents Python and web support and bounded native rejection.
Remaining: constructor enforcement/emission/generation for Rust, Java, Go,
Haskell and Kotlin; recursively refined named payloads; remaining style acceptance
and final release/package gates. Version remains 0.8.0 during development; no
publication occurred.

Recovery snapshot: `/private/tmp/lawspec-web-field-emitter-20260927.tar.gz`, verified byte-for-byte.


### Rust constructor-contract runtime (2026-09-27)

Added framework-independent typed FieldPredicate callbacks and ConstructorContract
metadata through Schema::with_contracts, retaining Schema::new for unconstrained
callers. Unknown and duplicate contract tags fail during registration. Callbacks
receive instantiated type arguments, logical fields, machine width and the
caller's mutable Symbol Context.

Schema::check_with_context distinguishes ValueCheck::Rejected from evaluator or
shape errors. validate_with_context enforces contracts at logical boundaries;
native_value_with_context validates the entire logical value before converting
raw code-unit payloads to native integers. Nested paths preserve rejection
classification. Existing validate/native_value APIs delegate with a fresh context.
Predicate order short-circuits and logical predicates are not re-evaluated on
converted native payloads.

All 22 standalone Rust runtime tests pass offline, including five new tests for
machine profiles, typed generics, ordered predicates, error classification,
CodeUnit16 conversion order, nested Symbol contexts under List/Maybe/Either/
Nullable/Optional, and corrupt contract metadata. Existing generated Rust native
data matrices pass at both widths, including custom layouts, architecture checks,
recursive generators and adapter mutants. Rustfmt, embedded runtime checks,
WASM/source fingerprints, the 57-module compiler boundary and whitespace checks
pass. Focused native/WASM parity passes 96 generation responses and twelve
check/expand requests.

Logs: `.artifacts/rust-field-{runtime,data,wasm,parity}.log`.

Rust public field-contract generation remains gated. Next, emit typed predicate
callbacks through the shared Rust expression renderer, pass Context through
schema bridges, then integrate checked native generation/shrinking and witnesses.
Java, Go, Haskell and Kotlin contracts, recursive refined payloads, remaining
style acceptance and final package/release gates remain open. Version remains
0.8.0; no publication occurred.

Recovery snapshot: `/private/tmp/lawspec-rust-field-runtime-20260927.tar.gz`, verified byte-for-byte.

Rust conformance build output in `runtime/rust/target/` is ignored and excluded from source recovery snapshots.

## Rust definition boundary contexts (2026-09-27)

Generated Rust definitions now pass the caller's Context through argument
validation, logical result validation, and native result conversion. Each used
an implicit fresh Context before this change, which would reject valid Symbol
identities once schema predicates were installed.

The native definition integration fixture installs a context-sensitive schema
predicate separately from source predicate emission. It executes a named Symbol
product through the generated native API, accepts the shared identity, and
rejects a symbol with the same fixture ID/description from another context.
Both readable and compact definitions pass at both machine widths. Three
independent executable mutants reset argument, result, or native-conversion
contexts; each compiles and fails the behavioral test. Existing native methods,
properties, overflow/collection mutants, architecture diagnostics, custom
layouts, framework-free compilation and regeneration checks also pass.

All 435 compiler examples pass. Generated readable definitions match rustfmt.
The WASM rebuild and source fingerprints, embedded runtime check, 57-module
boundary, whitespace check and 96 native/WASM generation combinations plus
12 check/expand requests pass. Logs: `.artifacts/rust-context-*.log`.

This completes definition-boundary context plumbing only. Rust typed schema
callback emission, property contexts, witnesses and checked native shrinking
remain open; public Rust constructor contracts remain gated. Other outstanding
0.9 scope above remains unchanged. Python retains PEP 8, and version stays
0.8.0 during development. No publication occurred.

Recovery snapshot: `/private/tmp/lawspec-rust-definition-context-20260927.tar.gz`,
verified byte-for-byte.

## Rust typed schema callbacks (2026-09-27)

The profile-aware Rust schema emitter now audits constructor proof contracts,
emits callbacks from typed Core via the shared expression renderer, and attaches
ordered predicate metadata to runtime schemas. Callbacks receive logical fields,
type arguments, the machine width and the caller's Symbol Context; results use
strict Bool extraction. The shared renderer accepts runtime width/type-key
expressions, and TypeRef exposes checked substitution and expression keys.
Existing unconstrained schemas keep their previous generated layout.

A source-driven low-level fixture executes generated data, schema and definition
modules without a test-framework dependency. Both widths and readable/compact
layouts pass exact gap arithmetic (1/255), invalid gaps, generic nonempty lists,
refined list elements, sums, guarded division, architecture compatibility,
Symbol identities and concrete IEEE equality (NaN and signed zero). The runtime
key/substitution API rejects unbound parameters. Readable data/schema/definition
modules match rustfmt, and compact output formats to the same source. Eight
callback mutants (accept-all and fresh Symbol context across four configurations)
are detected through execution rather than compile failures.

The exploratory generic equality predicate was correctly rejected by the
frontend's unresolved Eq capability check. The fixture therefore uses supported
generic containers plus concrete Float64 equality; this checkpoint does not
claim generic capability-bearing constructor contracts are enabled.

All 435 compiler examples and 22 standalone Rust runtime tests pass. Existing
native data matrices at both widths, custom layouts, recursive generators,
architecture checks and mutants pass. Embedded runtimes, formatting, whitespace,
the 57-module boundary, WASM/source fingerprints and focused parity (128
generation responses and sixteen check/expand requests) pass. Gated constructor
responses are parity evidence, not public Rust property execution.

Logs: `.artifacts/rust-callback-*.log`. Public Rust constructor-contract emission
remains gated until checked generation/shrinking, witness handling and property
context integration are complete. Java/Go/Haskell/Kotlin contracts, recursive
refined payloads, remaining style acceptance and release packaging remain open.
Python retains PEP 8; development version remains 0.8.0. No publication occurred.

Recovery snapshot: `/private/tmp/lawspec-rust-schema-callbacks-20260927.tar.gz`,
verified byte-for-byte.

## Rust checked constructor strategies (2026-09-27)

Added checked_schema_strategy with caller Context and validated typed witnesses.
It composes the existing native recursive proptest strategies and filters whole
candidates using proptest's prop_filter_map. False predicates consume bounded
native rejection attempts; evaluator errors remain Result::Err values that the
property caller must report as failures. This also preserves errors encountered
while shrinking. Context clones retain Symbol identities without introducing
mutable shrink history. Schema metadata is cloneable; the shape-only public
strategy explicitly rejects schemas containing contracts rather than silently
ignoring predicates.

Witnesses are validated, checked against structural budgets, and collected by
instantiated type through named and builtin containers. Native list/option/sum
structures consume payload witnesses and retain their structural shrinkers.
A regression caught whole-list sampled witnesses preventing length shrinking;
those container samples were removed. Named witness samples remain fallback
alternatives alongside native strategies for uneven recursive allocations; such
fallback samples may still yield larger counterexamples than native branches.
This limitation should remain visible when documenting property integration.

Four new runtime integration tests cover dependent-field shrinking, nested
Symbol witnesses shrinking a list to length two, invalid/oversized witnesses,
impossible branches within a viable sum, bounded empty-domain exhaustion, and
visible evaluator errors. All four schema width/layout configurations pass
26 tests (22 existing runtime plus four new strategy tests). Eight executable
mutants hiding errors or resetting Symbol contexts are detected. Existing Rust
native data matrices pass in readable and minified output at both widths,
including custom layouts, architecture checks, recursive generators and mutants.

Rustfmt, embedded runtime checks, whitespace, 57-module boundary, WASM/source
fingerprints and focused parity (96 generation responses plus twelve check/expand
requests) pass. Compiler logic did not change; the last full compiler suite was
435 passing examples in the preceding checkpoint. Logs:
`.artifacts/rust-strategy-*.log`.

Public Rust constructor contracts remain gated pending emitter witness handling,
per-property shared context construction, and explicit reporting of strategy
Result errors. Other backend contracts, recursive refined payloads, remaining
formatting acceptance and packaging/release work remain open. Python stays PEP 8;
development version stays 0.8.0. No publication occurred.

Recovery snapshot: `/private/tmp/lawspec-rust-checked-strategies-20260927.tar.gz`,
verified byte-for-byte.

## Public Rust constructor contracts (2026-09-27)

Rust public generation now accepts audited constructor field contracts. The
emitter constructs validated witnesses in the case's Symbol Context, feeds them
to checked native strategies, and shares the same Context with dependent inputs,
definition calls, adapter bridges and assertions. Required conjunctive Symbol
equalities draw the required identity, including prior inputs; disjunctions do
not narrow the domain to a singleton. Schema checks at adapter and law boundaries
also receive that Context.

Strategy Result errors are stored in Case.error, bypass rejection predicates,
and reach the property's failure result before values are indexed. Native local
and global retry limits both use maxAttempts. Finite cases still execute
exhaustively, and fixed/example contexts stay local to their case. The public
field-contract gate now permits Python, JS, TS and Rust; Java, Go, Haskell and
Kotlin remain gated.

The new public integration covers four configurations (both widths and layouts),
32-bit custom source/test placement, adapters and definitions, exact gaps,
generic nonempty lists, positive elements, sums, guarded division, mixed and
dependent Symbols, nested lists, finite Bool products, Nullable/Optional and
machine profiles. Logical machine definitions pass both profiles; native adapter
calls reject architecture mismatch. Symbol-description adapter mutants fail.
Random-only checks (with deterministic boundary blocks removed from the harness)
prove evaluator errors are reported and disjunctions retain other identities.
Generated artifacts match rustfmt and compact output formats identically.

The wider formatter audit exposed a definition-contract wrapping mismatch from
long context-aware validation calls. Document layout now selects hanging versus
argument wrapping consistently with rustfmt. All 262 existing Rust artifacts
match rustfmt. Existing native data matrices pass at both widths, including
custom layouts, recursive shrinking, native bridges and mutants. All 435 compiler
examples pass. Embedded runtimes, whitespace, the 57-module boundary,
WASM/source fingerprints and focused native/WASM parity (96 generation responses
plus twelve check/expand requests) pass. Logs: `.artifacts/rust-public-*.log`.

REFINEMENTS.md and RUST.md describe the supported path and witness shrinking
limits. Remaining 0.9 work includes Java/Go/Haskell/Kotlin contracts, recursive
refined named payloads, remaining formatting acceptance and final packaging and
release checks. Python retains PEP 8. Development version remains 0.8.0 and no
publication occurred.

Recovery snapshot: `/private/tmp/lawspec-rust-public-contracts-20260927.tar.gz`,
verified byte-for-byte.

## Java constructor-contract runtime (2026-09-27)

Java schema metadata now carries ordered typed FieldPredicate callbacks, with
legacy two-argument Constructor initializers preserved. Predicates receive the
schema, instantiated type arguments, validated logical fields, machine width
and caller Symbol map. False predicates throw a dedicated RefinementViolation;
check returns Accepted/Rejected only for actual predicate outcomes, while
representation and evaluator errors remain contextual exceptions. Recursive
field validation and encodeField preserve that classification.

Added context-aware validation, construction, matching, equality and codec
entry points, including supported/list/maybe/either codecs. These propagate the
same Symbol map through nested boundaries. Callbacks run before native decoding,
so raw CodeUnit16 values retain their logical representation. Substitution is
public for future generic callback emission and rejects unbound parameters.
Legacy shape-only JetCheck generators explicitly reject contracted schemas
pending checked generation rather than silently ignoring predicates.

The framework-independent Java 25 harness passes at both widths: positive
machine fields and range checks, ordered false-before-error callbacks, dependent
fields, contextual error classification, Symbol identity across codecs and
nested presence/sum/list values, and lone UTF-16 surrogate round trips. Six
executable mutants (accept-all, lost nested context, and hidden errors at both
widths) are detected. Google Java Format 1.36 checks pass. Existing generated
native data/schema fixtures pass readable and compact layouts; existing public
native property matrices pass both widths and default/custom multi-unit layouts,
including adapter mutants. Logs: `.artifacts/java-field-*.log` and
`.artifacts/java-constructor-runtime/`.

The Java expression renderer now owns its canonical type-key function, removing
its dependency on JavaData while preserving JavaData's re-export. This permits
the upcoming schema callback emitter to reuse typed expressions without a cycle.
All 435 compiler examples pass after this refactor. The 57-module boundary,
embedded runtimes, whitespace, rebuilt WASM/source fingerprints and focused
parity (96 generation responses plus twelve check/expand requests) pass.

Public Java constructor generation remains gated: typed callback emission,
context-aware generated codec/definition wiring and checked native strategies
still need integration. Go/Haskell/Kotlin contracts and the remaining 0.9 scope
also remain open. Python stays PEP 8; development version stays 0.8.0. No
publication occurred.

Recovery snapshot: `/private/tmp/lawspec-java-field-runtime-20260927.tar.gz`,
verified byte-for-byte.

## Java typed schema callbacks (2026-09-27)

Added profile-aware emitJavaSchema, which audits constructor proof contracts and
emits ordered typed Java callbacks plus method-reference metadata. The shared
Java expression renderer now accepts runtime width, schema references and type
keys. Schema operations receive symbols, generic container payloads use schema
validation, and nested presence literals resolve their runtime type keys.
Callback-local element and match binders receive distinct names.

A source-derived fixture covers dependent Gap fields, fixture Symbols, generic
nonempty lists, refined list elements, sums, machine values, guarded division,
nested list predicates and generic Maybe matches with scalar and named Symbol
payloads. Four width/layout configurations compile and execute without test
framework dependencies. Readable schemas match Google Java Format; compact
schemas format identically. Eight callback mutants (accept-all and reset Symbol
context) fail behaviorally.

That fixture exposed a frontend bug in generic constructor matching: unification
bound a declared type parameter to a fresh constructor variable, leaving typed
Core binder and expression identities inconsistent. constructorParameters now
binds fresh constructor variables to the caller's type instead. A source-level
regression checks the generic predicate at both widths. All 436 compiler
examples pass after the fix.

Existing Java definition integrations pass at both widths, covering native
calls, properties, compact source, ownership/regeneration and adapter mutants.
All 230 existing Java artifacts match Google Java Format. The 57-module boundary,
whitespace, WASM/source fingerprints and focused parity (128 generation responses
plus sixteen check/expand requests, including the generic fixture) pass. Logs:
`.artifacts/java-callback-*.log`.

This is low-level schema emission. Public Java constructor generation remains
gated until generated codecs and definition boundaries carry the caller context
and checked JetCheck generation/witnesses are integrated. Go/Haskell/Kotlin
contracts, recursive refined payloads and remaining 0.9 style/package/release
checks remain open. Python stays PEP 8; development version stays 0.8.0. No
publication occurred.

Recovery snapshot: `/private/tmp/lawspec-java-schema-callbacks-20260927.tar.gz`,
verified byte-for-byte.


## Java native constructor codecs and definition contexts (2026-09-27)

Java data emission now uses profile-aware typed schemas. Generated codec
factories accept an explicit Symbol context, propagate it through named and
container codecs, and validate encoded/decoded values against constructor
contracts. Legacy overloads remain available with a fresh context. Native
and logical definition argument/result boundaries pass the caller's context.
Long native method signatures wrap according to Google Java Format.

The source-derived native fixture exercises dependent fields, generic and
refined lists, sums, guarded division, machine ranges, nested Maybe, Nullable,
Optional, Symbol identity and lone UTF-16 surrogate units. All four width/layout
configurations compile and execute with Java 25. Four compiled context-reset
mutants fail behaviorally. Readable output matches Google Java Format and
compact output formats identically.

All 436 compiler examples pass. Existing Java and Kotlin native definition,
property, compact-source, ownership and mutant suites pass at both widths;
Kotlin is included because it shares the changed JVM definition bodies. All
230 ordinary Java artifacts match Google Java Format. Embedded runtimes,
57-module architectural boundaries, whitespace and rebuilt WASM fingerprints
pass. Focused parity covers 128 generation responses and sixteen check/expand
requests; gated generation responses are parity evidence, not backend execution.
Logs are in `.artifacts/java-codec-*.log`.

Public Java constructor contracts remain gated until checked JetCheck strategies,
witnesses and property contexts are integrated. Go/Haskell/Kotlin contracts,
recursive refined payloads and remaining style/package/release checks remain
open. Python retains PEP 8, development version remains 0.8.0, and no publication
occurred.

Recovery snapshot: `/private/tmp/lawspec-java-context-codecs-20260927.tar.gz`,
verified byte-for-byte.


## Java checked native strategies (2026-09-27)

Added checkedGenerator to the JetCheck helper. It generates raw constructor shapes,
validates typed witnesses before recursively indexing their nested payloads, and
composes native suchThat filters at nested and outer boundaries with the supplied
Symbol map. False predicates reject candidates; evaluator errors are delivered as
Checked errors so properties can report them. Existing unchecked-schema entry
points still reject schemas containing contracts.

A manual whole-candidate retry prototype was replaced after inspecting JetCheck
replay behavior: native filtering discards invalid shrinking replays, whereas a
returned exhaustion value can become a spurious counterexample. A nested-witness
stress test also exposed poor diversity from filtering only complete lists; nested
filtering now validates refined elements before list assembly. JetCheck 0.3's
native filter limit is 100 attempts per filter, not yet the configurable law
attempt budget. Sampled witnesses can limit payload shrinking, and tests assert
valid non-growing shrinks rather than a globally minimal counterexample.

The standalone strategy check passes at both widths: valid generation and shrinking,
nested seed use even with an always-invalid scalar generator, bounded exhaustion,
evaluator-error classification, invalid witness rejection and shared Symbol identity.
Eight compiled mutants (accept-all, lost context, omitted nested seeds and hidden
errors across both widths) are detected. Runtime and test sources match Google Java
Format. Existing Java data-property/adapters/ownership matrices pass at both widths
and layouts. All 436 compiler examples pass. Embedded source checks, architectural
boundaries, whitespace and rebuilt WASM fingerprints pass; focused parity covers
128 generation responses and sixteen check/expand requests. Logs:
`.artifacts/java-checked-*.log`.

Public Java constructor contracts remain gated pending property emitter integration
of checked strategies, witnesses and case contexts; configurable retry-budget
semantics also need reconciliation with native JetCheck filtering. Other native
backend contracts, recursive refined payloads, style audits and release/package
acceptance remain open. Python retains PEP 8 and the development version remains
0.8.0. No publication occurred.

Recovery snapshot: `/private/tmp/lawspec-java-checked-strategies-20260927.tar.gz`,
verified byte-for-byte.


## Public Java constructor contracts (2026-09-27)

Enabled public Java emission for constructor field contracts. Typed boundary
literals, adapter codecs, definition calls and structural assertions now use the
same per-case Symbol map. Property generation supplies validated boundary/hint
witnesses to checked native JetCheck strategies. Required conjunctive Symbol
equalities can draw the fixture or prior input directly; disjunctions retain all
candidate alternatives and keep their final predicate check.

Constructor-contract properties run the requested case count as one-iteration
JetCheck sessions with increasing size hints. The public integration exposed
session-wide draw uniqueness exhaustion for valid singleton fixture identities
and sparse witnesses. Per-case sessions preserve native shrinking without
padding draws or claiming an unproven finite domain. Core-proven finite domains
still emit exhaustive cases, with no random property test.

The checked strategy accepts maxAttempts, stopping smaller budgets before an
additional draw. Each native filter is bounded by min(maxAttempts, 100), since
JetCheck 0.3 independently caps suchThat at 100. Budget counters are fresh during
replay; rejected shrinks remain native rejections, rather than becoming false
exhaustion counterexamples. Standalone checks verify exactly three attempted
invalid draws for a budget of three and valid shrinking with that budget.

The public matrix passes both widths and readable/compact layouts, using custom
source/test placement at 32 bits. It covers dependent numeric fields, generic
lists, refined list elements, sum alternatives, machines, guarded division,
Symbol fixtures, dependent inputs, nested lists, Nullable/Optional and finite
Bool field domains. Twelve compiled mutants across the four configurations
expose same-description/different-identity adapters, incorrect Symbol comparisons
under disjunctive inputs and hidden generation-time evaluator errors. Generated sources match Google Java
Format; compact sources format identically. Standalone checked strategies pass
both widths and eight behavioral mutants.

All 436 compiler examples pass after updating the backend capability test. All
230 ordinary Java artifacts match Google Java Format. Embedded runtime, module
boundary, whitespace and rebuilt WASM fingerprint checks pass. Native/WASM parity
passes 128 ordinary/constructor fixture responses plus sixteen check/expand
requests, and a further 96 responses plus twelve check/expand requests using the
Java-valid fixture namespace. Logs are `.artifacts/java-field-*.log`.

The ordinary Java data-property/native-adapter matrix passes at both widths and
default/custom layouts, including its native shrinking and adapter mutants.

Go/Haskell/Kotlin constructor contracts, recursive refined named payloads and
remaining style/package/release acceptance remain open. Sampled witnesses can
limit payload shrinking; no global-minimum shrinking guarantee is made. Python
retains PEP 8 and development version remains 0.8.0. No publication occurred.


Recovery snapshot: `/private/tmp/lawspec-java-public-contracts-20260927.tar.gz`,
verified byte-for-byte.


## Kotlin native constructor schemas and contexts (2026-09-27)

Kotlin data emission now delegates to profile-aware typed JVM schema callbacks,
reusing the checked Java predicate renderer. Generated named codecs accept a
caller Symbol map and pass it through nested named/container bridges and schema
construction/validation. Native definition inputs and results use those contextual
codecs. Kotlin Nullable/Optional bridges and construct/match helpers now accept
contexts while preserving existing source calls through defaults or overloads.
Primitive-only codecs do not acquire test-framework dependencies.

The native fixture covers dependent Gap fields, generic/refined lists, sum
alternatives, guarded division, machine ranges, fixture identity, raw UTF-16 units,
List (Maybe Identity), Bucket Identity, and Optional (Nullable Identity). Wrong
contexts and equal-description replacement Symbols are rejected. Both absent
branches of nested presence remain distinct. Four native width/layout configurations
compile and execute, and four compiled codec-context mutants fail behaviorally.

The expanded fixture exposed a development checker bug: function-body indentation
was measured from the final continuation line of a wrapped return type. The PSI
checker now uses the named function's declaration line; a positive/negative
wrapped-return regression verifies the rule. Full Kotlin parsing/layout and
compact syntax-tree audits pass for the ordinary 348-artifact corpus. Java
companions match Google Java Format.

All 436 compiler examples pass. Existing Kotlin native definition/property,
compact-source, ownership and adapter-mutant suites pass at both widths. Embedded
source, 57-module boundaries, whitespace and rebuilt WASM fingerprints pass.
Focused native/WASM parity covers 128 generation responses plus sixteen check/
expand requests, with another 96 responses plus twelve check/expand requests for
the expanded native fixture. Gated backend responses count as parity evidence;
actual Kotlin execution is covered by the native fixture. Logs:
`.artifacts/kotlin-context-*.log`.

The expanded native fixture also passes the 24-artifact Kotlin formatting and
compact syntax-tree comparison after the checker correction.

Public Kotlin constructor properties remain gated until checked Kotest strategies,
witnesses and property contexts are integrated. Go/Haskell contracts, recursively
refined named payloads and remaining style/package/release acceptance remain open.
Python retains PEP 8, development version remains 0.8.0, and no publication occurred.


Recovery snapshot: `/private/tmp/lawspec-kotlin-context-codecs-20260927.tar.gz`,
verified byte-for-byte.


## Kotlin checked native strategies (2026-09-27)

Added checkedGenerator to the Kotlin test helper. It validates witnesses against
the instantiated schema and caller Symbol context, recursively indexes their
typed payloads, and supplements the native list/product/choice arbitraries with
those seeds. Nested and outer value boundaries reject false constructor
predicates, while evaluator errors remain Checked errors for properties to
report. The legacy unchecked API now rejects schemas containing contracts.

Inspection of the installed Kotest 5.9 implementation showed that its arbitrary
filter can sample indefinitely on an empty domain. A bounded wrapper therefore
samples the existing native arbitrary at most maxAttempts times and delegates
shrink filtering to Kotest RTree.filter. No global framework settings change.
Shrinks retain native trees and discard rejected nodes; errors discovered during
shrinking are preserved. Sampled witness alternatives can limit payload shrinking,
and no global-minimum shrinking guarantee is made.

Standalone checks pass at both widths, covering valid generation/shrinking,
nested witness reuse with an otherwise invalid scalar generator, exactly three
draws on a three-attempt empty domain, root and shrink-time evaluator errors,
fixture identity, invalid witnesses and the legacy API guard. Eight compiled
accept-all, reset-context, omitted-nested-witness and hidden-error mutants fail
behaviorally. A multiline when branch was given braces to satisfy the Kotlin
style audit; the full 348-artifact parsing/layout/compact-syntax corpus passes.

Ordinary Kotlin data and collection integration passes at both widths, including
native representations, generated properties and twenty adapter-mutant checks.
All 436 compiler examples pass. Embedded sources, 57-module boundaries,
whitespace, rebuilt WASM fingerprints and focused native/WASM parity (128
generation responses plus sixteen check/expand requests) pass. Logs:
`.artifacts/kotlin-checked-*.log`.

Public Kotlin constructor properties remain gated pending emitter integration of
checked strategies, witnesses and shared case contexts. Go/Haskell constructor
contracts, recursively refined named payloads, final style audits and package/
release acceptance remain open. Python retains PEP 8 and the development version
remains 0.8.0. No publication occurred.

Recovery snapshot: `/private/tmp/lawspec-kotlin-checked-strategies-20260927.tar.gz`,
verified byte-for-byte.


## Public Kotlin constructor contracts (2026-09-27)

Enabled Kotlin public generation for constructor field contracts. Expression
validation, construction, matching, adapter codecs and structural assertions now
share the generated case's Symbol map. Native checked strategies receive typed
boundary/hint witnesses and per-law retry budgets. Required conjunctive Symbol
equalities can use fixture/prior-input values; disjunctions retain alternatives
and their final predicate check.

A sampled Case owns its context exactly once. Its shrink tree reuses that map;
separate samples receive separate maps. Dependent inputs compose through the
existing native-tree-preserving lawspecFlatMap helper. Checked errors become case
state, skip later draws, bypass input guards for reporting and are raised before
binding the completed tuple. Bounded case filtering uses the same native RTree
filter as value generation. Core-proven finite constructor domains still emit
exhaustive cases without random properties.

The public integration matrix passes at both widths and readable/compact layouts,
with custom source/test placement at 32 bits. It exercises dependent numeric
fields, generic/refined lists, sums, machines, guarded arithmetic, nested lists,
Nullable/Optional, fixture identity, dependent Symbols and finite Bool fields.
Twelve compiled mutations across four configurations expose replacement Symbol
identities, incorrect comparisons under disjunctive Symbol inputs and injected
evaluator errors. The public 32-artifact and ordinary 348-artifact Kotlin parsing,
layout and compact syntax-tree audits pass; Java companions match Google Java
Format. Runtime checks also verify stable per-sample contexts and preserving
errors ahead of guard evaluation, alongside the eight existing strategy mutants.

Ordinary Kotlin data/collection properties pass at both widths, with twenty
adapter-mutant checks. All 436 compiler examples pass after updating the backend
capability test. Embedded runtimes, module boundaries, whitespace and rebuilt
WASM fingerprints pass. Focused native/WASM parity covers 128 generation
responses and sixteen check/expand requests, including the public fixture.
Logs: `.artifacts/kotlin-field-*.log`.

Go and Haskell constructor contracts, recursively refined named payloads and
remaining style/package/release acceptance remain open. Sampled witness branches
retain their documented shrinking limitation. Python stays PEP 8 and the
development version stays 0.8.0. No publication occurred.

Recovery snapshot: `/private/tmp/lawspec-kotlin-public-contracts-20260927.tar.gz`,
verified byte-for-byte.

## Go constructor-contract runtime checkpoint (2026-09-27)

The framework-independent Go schema now accepts separately registered ordered
constructor predicates without changing positional constructor-schema metadata.
Registration copies callback slices and rejects unknown/duplicate registrations
and nil predicates. Recursive representation validation precedes predicates.
Validation, construction and equality share an optional Symbol context through
nested List, Maybe, Either, Nullable, Optional and named values.

False predicates raise a distinct refinement rejection, preserved through field
and list diagnostic paths. Candidate classification catches only that rejection;
evaluation failures remain contextual panics. Legacy Rapid generation rejects
contract-bearing schemas until checked generation is implemented.

tools/go-constructor-contracts.mjs executes direct runtime tests at both machine
widths, checks gofmt, and detects five regressions: bypassed predicates, aliased
registration metadata, dropped nested Symbol context, accepted rejections and
swallowed evaluator errors. Existing Go native data/schema/codec/generator/shrinker
checks pass in pretty and compact modes. All 436 compiler examples pass.
Embedding, the 57-module boundary, diff checks, rebuilt WASM fingerprints and
96 native/WASM generation responses (plus 12 check/expand responses) pass.

This is an internal runtime checkpoint. Go public constructor contracts remain
gated: contextual native codecs, typed callback emission and checked Rapid
generation/shrinking still need implementation and execution. Haskell contracts,
recursive named refined payloads and final formatting/packaging acceptance also
remain open. Python retains PEP 8. Development version remains 0.8.0; no
publication occurred.

## Go native codec contract contexts (2026-09-27)

Runtime codec factories now accept an optional shared Symbol context and retain
it through both conversion directions, built-in containers and constructor
validation. Native contextual errors preserve the refinement-rejection type;
evaluation errors remain failures. Generated named codec factories carry the
context into recursive child factories and schema construction. GoData exposes
goCodecWithContext; native definition bridges use it, and Go definition and
expression schema checks pass their existing symbols map.

GoConstructorCodecsCheck exercises generic recursive trees, lists, Maybe, Either,
and nested Nullable/Optional states at both machine widths. Both native
conversion directions reject equal-description/different-identity Symbols.
Separate contexts reject fixture values; contextual evaluation errors survive.
The existing Go data integration runs this check for readable and compact
output and detects three dropped-context mutations per layout (six total).
Existing native data, schema, codec, generation, shrinking and compile-negative
checks remain green and emitted readable files match gofmt.

Go definition integration passes both widths, custom layouts, native-only
execution, properties, compact definitions, ownership and mutants. All 436
compiler examples pass. Embedding and the 57-module boundary pass. WASM is
rebuilt with matching fingerprints; 128 generation responses and 16 check/expand
responses match the native compiler.

Go constructor contracts are still publicly gated pending typed callback
emission and checked Rapid strategies, including contextual property wiring.
Haskell contracts, recursive named refined payloads and final formatting and
release acceptance remain open. Python retains PEP 8; version remains 0.8.0.

## Go typed constructor predicate emission (2026-09-27)

GoData.emitGoSchemaWithProfile now audits constructorProofContracts, consumes
dataSchemasWithContracts, and emits ordered predicate callbacks into the runtime
registry. The default emitGoSchema retains a 64-bit wrapper. Production emission
supplies the requested profile. Shared GoTypeRefs separates type-reference
rendering from data/expression emission and prevents an import cycle;
the compiler boundary now covers 58 modules.

GoExpr.renderExpressionWithContext accepts runtime width, type references and
keys. Constructor callbacks instantiate generic references with lsSubstitute,
resolve field/nested binder identities and preserve short-circuit semantics.
Callbacks consume typed Core and reject external calls; the frontend's generic
equality capability restriction remains intact.

The new go-constructor-native fixture/integration compiles the shared constructor
fixture plus nested identity definitions and a generic Maybe-match predicate.
Four configurations (both widths, readable/compact) execute native definitions
without a property framework. Coverage includes dependent Int8 gaps with exact
promoted division, nested element refinements, nonempty generic containers, sum
branches, guarded division, shared Symbol identity, nested presence states,
generic match substitution and native architecture mismatch. Eight mutants
(disabled predicates or lost identity-codec context) fail compiled tests.
Readable schema callbacks and generated native sources match gofmt.

Existing Go data integration (including six codec-context mutants) passes.
All 436 compiler examples pass; 318 generated Go artifacts pass gofmt. Embedding,
diff checks, WASM rebuild/fingerprints and focused parity pass: 96 generation
responses and 12 check/expand responses match between native and WASM.

Public Go constructor contracts remain gated until checked Rapid strategies and
property wiring are implemented. Haskell contracts, recursive named refined
payloads and final formatting/packaging acceptance remain open. Python stays
PEP 8; development version remains 0.8.0 and nothing was published.

## Go checked Rapid strategy runtime (2026-09-27)

lsCheckedDataStrategy composes the existing native Rapid structural generators
with checked constructor filtering and validated, recursively indexed typed
witnesses. Each nested type filters invalid candidates with Rapid.Filter;
seed alternatives use Rapid.SampledFrom. Scalar/native field strategies and
collection combinators retain their replay-based shrinking. Arbitrary node
budgets also apply to seed alternatives. Invalid witnesses fail immediately.

Validation alone is caught into a checked result: false contracts are rejected,
while evaluator/representation errors become explicit failures. Rapid's own
discard panics are never intercepted. Per-sample/replay state stops later fields
from evaluating after a failure, so an impossible sibling cannot obscure the
original diagnostic. Later fields use a native constant placeholder to satisfy
Rapid's requirement that Custom generators draw from built-in generators.
The placeholder is never exposed as a successful result.

Rejection uses Rapid 1.2.0's bounded native Filter (five tries per filter);
Rapid's containing generators and test engine retain their own bounded retry
policies. This runtime does not introduce a separate configurable per-filter
attempt limit. Public property integration still needs to account for the
existing maximumAttempts configuration. Sampling a seed alternative retains
native index shrinking, not a guarantee of globally minimal payloads.

tools/go-checked-strategies.mjs tests both widths, positive nested generation,
node budgets, descendant seeds in new shapes, invalid witnesses, Symbol fixture
identity, separate contexts, explicit evaluation failures, per-sample error
isolation and stopping after a failed field. A deliberately failing native
property shrinks to three positive payloads [1, 1, 1]. An impossible contract
terminates with Rapid's 0-valid-tests diagnostic. Three compiled mutants detect
bypassed rejection, swallowed errors and missing descendant witness indexing.

Existing Go data/codec/generator/shrinker integration passes in both layouts,
including six context mutants. All 436 compiler tests, embedding, 58-module
boundary and diff checks pass. Rebuilt WASM fingerprints match; native/WASM parity
passes 96 generation responses and 12 check/expand responses.

Go public contracts remain gated pending contextual property generation,
boundaries/assertions/adapter wiring and full public execution. Haskell contracts,
recursive named refined payloads and final formatting/packaging acceptance
remain open. Python retains PEP 8; development version stays 0.8.0.

## Go public constructor contracts (2026-09-27)

Enabled Go at the constructor-contract capability gate. Properties with these
declarations draw checked Rapid values in binder order, supply typed boundary
witnesses and safe same-type constant/local hints, and share a Symbol map across
generation, guards, definitions, adapters, boundaries and assertions. Conjunctive
required Symbol equalities draw the required identity directly; disjunctions keep
their alternatives. Checked draw failures escape before subsequent binders/guards.
Proven finite domains still enumerate their accepted cases instead of drawing.

Native adapter codec emission uses goCodecWithContext. Structural literals,
boundary validation and assertion helpers pass the same context. REFINEMENTS.md
now lists Go/Rapid enforcement and explicitly records that per-law generation
settings need acceptance review: structural properties currently use Rapid's
native check/retry settings, including its existing bounded filters. This issue
must be resolved or explicitly specified before full release acceptance.

tools/go-field-properties.mjs executes the public compiler output in four
configurations: both widths and both formatting modes, including a custom Go
source/test package root. All laws, boundaries and properties pass, including
machine-integer laws evaluated in checked definitions, finite Flag enumeration,
nullable/optional identities, nested lists and conjunctive/dependent/disjunctive
Symbol fixtures. Twelve compiled mutants expose new same-description Symbol
identities, an always-true Symbol adapter and suppressed checked-strategy errors.
The fixture's machine laws do not cross a native int adapter boundary; architecture
mismatch remains covered by the native constructor integration.

All 436 compiler examples pass. The 318-artifact gofmt audit and Go definition
integration pass, including both profiles, compact source, native-only execution,
custom layouts, ownership and mutants. Embedding, 58-module compiler boundary,
diff checks, rebuilt WASM and fingerprints pass. Native/WASM parity covers
128 generation responses and 16 check/expand responses.

Haskell constructor contracts, recursive named refined payloads, the Rapid
configuration audit, remaining formatting and full packaging/release acceptance
remain open. Python retains PEP 8. Development version remains 0.8.0 and no
publication occurred.

## Go native generation settings (2026-09-27)

Audited Rapid 1.2.0's actual public API. It has process-wide case-count and
shrink-time flags, not per-property options or an exposed shrink-step budget.
Structural Go properties now invoke lsRapidCheck with the law's cases value.
Generated tests are sequential; a scoped mutex protects these generated calls,
and a deferred restoration resets the prior rapid.checks setting even on failure.
Explicit Go short-test mode retains Rapid's native count reduction.

Both ordinary structural and constructor-contract input guards use
lsBoundedFilter. Checked descendant generators also receive maximumAttempts.
Each filter is capped at min(maxAttempts, 5), preserving Rapid's native discard
and replay handling; surrounding generators and the engine retain their own
bounded retries. The smaller-limit wrapper uses native Custom/Filter and native
SkipNow, never catches Rapid's discard signals and never treats exhaustion as a
counterexample. The default runtime entry remains available with native limit 5.

The shrinking contract is now explicit in REFINEMENTS.md: structural Go uses
rapid.shrinktime, while maxShrinks remains the scalar refinement engine's step
budget. No unsupported numeric-to-time conversion or private Rapid API is used.

Runtime tests verify requested counts 1/7/13, restoration, invalid limits, exact
bounded native draw behavior, valid shrinking with limit 2, and five compiled
mutants (including wrong case counts and ignored retry caps). Public tests now
request seven cases and two attempts and instrument the native adapter, proving
seven property calls plus separately counted boundaries in all four profile/
layout configurations. Twelve public mutants still fail. Existing Go definition
integration passes both profiles, including native-only execution, compact
source, ownership and mutants. All 436 compiler examples and 318 Go formatting
artifacts pass. Embedding, 58-module boundary, diff checks, rebuilt WASM and
fingerprints pass; parity covers 96 generation and 12 check/expand responses.

Haskell constructor contracts, recursive named refined payloads, remaining
formatting and full packaging/release acceptance remain open. Python retains
PEP 8. Development version remains 0.8.0 and no publication occurred.

## Haskell constructor-contract runtime (2026-09-27)

LawSpecSchema now supports ordered FieldPredicate callbacks through separately
registered constructor contracts, preserving existing constructor metadata.
Registration rejects duplicate and unknown contract tags. Validation checks
representation and nested payloads before running predicates, which receive
resolved type arguments, the machine profile and an optional SymbolContext.

validateChecked returns distinct Rejected and EvaluationFailure results, preserving
the distinction through field/list diagnostic paths. False predicates short-circuit
later predicates; explicit callback evaluation failures retain contextual messages.
Pure unexpected Haskell exceptions are not caught or converted into rejection.
Legacy validate/construct/equal/match signatures remain available; new contextual
variants carry scopes through all recursive validation. Legacy Hedgehog generation
rejects contract-bearing schemas until checked strategies are implemented.

The standalone HaskellConstructorContractsCheck executes at both widths without
a property framework. It covers generic arguments, profile validation, ranges,
field arity, guard ordering, nested rejection paths, callback errors, identity
versus descriptions, distinct contexts, List/Maybe/Either/presence wrappers,
contextual construction/equality/matching, branch laziness, registration errors
and legacy schema behavior. Four compiled mutants detect disabled predicates,
lost nested scope, collapsed failure categories and reversed predicate order.

Existing Haskell native data/schema/codec/generation/budget/shrinking integration
passes in readable and compact modes, including rejected native payload types.
All 436 compiler examples, embedding, 58-module boundary and diff checks pass.
WASM is rebuilt with matching fingerprints; native/WASM parity passes 96
generation responses and 12 check/expand responses.

This is an internal runtime checkpoint. Public Haskell constructor contracts
remain gated pending contextual native codecs, typed predicate emission and
checked Hedgehog generation/properties. Recursive named refined payloads and
remaining formatting/packaging/release acceptance also remain open. Python
retains PEP 8 and development version remains 0.8.0. Nothing was published.

## Haskell native codec contexts (2026-09-27)

Runtime codecs now provide context-aware codecWith and container factories while
retaining the original context-free signatures. Both conversion directions call
validateWith using the supplied optional SymbolContext. Generated named codecs
provide corresponding With factories, passing the scope through recursive child
codecs; old factory names delegate with Nothing. HaskellData exposes
haskellCodecDocWithContext for typed native call sites.

Definition input/result codecs use the definition's SymbolContext. Definition
checks and expression validation/construction/equality also pass that context.
No property framework is imported into source codecs or native definitions.

HaskellConstructorCodecsCheck exercises generated generic recursive Tree codecs,
List/Maybe/Either, nested Nullable/Optional states, same-description different
identities, separate scopes, context-free rejection of scoped constrained values,
and evaluator diagnostics at encode/decode boundaries. The data integration runs
this at both widths in readable/compact output and detects two scope-loss mutants
per layout (four compiled mutants). Existing native data, schema, codec, budget,
generation, shrinking and rejected-payload checks pass.

The complete Haskell definition matrix passes both widths, custom layouts,
native-only execution, property tests, mutants, compact definitions and ownership/
regeneration protection. All 436 compiler examples pass. Embedding, 58-module
boundary and diff checks pass. WASM and fingerprints are rebuilt and verified;
native/WASM parity covers 128 generation and 16 check/expand responses.

Public Haskell constructor contracts remain gated pending typed predicate
emission and checked Hedgehog generation/properties. Recursive named refined
payloads, remaining formatting and full packaging/release acceptance remain
open. Python retains PEP 8; version remains 0.8.0 and nothing was published.

## Haskell typed constructor predicate emission (2026-09-27)

HaskellData.emitHaskellSchemaWithProfile audits constructorProofContracts and emits
ordered callbacks from dataSchemasWithContracts. Production uses the requested
profile; the old schema entry remains a 64-bit wrapper. Shared HaskellTypeRefs
removes the data/expression import cycle and centralizes runtime references; the
compiler boundary now covers 59 modules.

HaskellExpr.renderExpressionWithContext accepts runtime width, optional scope,
resolved reference/key renderers and binder resolution. Callback references
substitute generic type parameters; constants use the optional Symbol scope.
Existing Boolean short-circuiting and checked structural matching are preserved.
Generic conversion targets that lack a resolved scalar key fail emission instead
of acquiring fabricated type names. Callbacks only consume audited typed Core;
external calls remain rejected.

The new Haskell constructor-native integration compiles the common constructor
fixture with nested identity definitions and a generic Maybe-match predicate.
All four profile/layout configurations run without a property framework.
Coverage includes dependent gaps and promoted exact division, list element
refinements, generic nonempty containers, sum branches, guarded division,
Symbol identity and separate scopes, nested absence states, generic pattern
matching and native architecture mismatch. Eight compiled mutants expose
disabled predicates and lost decode contexts.

Existing Haskell definition integration passes both widths, custom layouts,
native-only calls, properties, mutants, compact definitions and regeneration/
ownership checks. All 436 compiler examples pass. Embedding, the 59-module
boundary and diff checks pass; WASM and fingerprints are rebuilt and verified.
Native/WASM parity passes 128 generation and 16 check/expand responses.

Public Haskell constructor contracts remain gated pending checked Hedgehog
generation and property wiring. Recursive named refined payloads and remaining
formatting/packaging/release acceptance remain open. Python retains PEP 8;
development version remains 0.8.0 and nothing was published.

## Haskell checked strategies and contextual test boundaries (2026-09-27)

LawSpecDataStrategies.checkedStrategy validates and indexes typed witness
subtrees, scopes generated Symbols, enforces the structural node budget on
witnesses, and filters native Hedgehog generation/shrink trees with constructor
contracts. Predicate rejection remains a native discard; evaluator failures
remain exceptions and are not turned into retries. The existing strategy entry
still rejects contract schemas. No custom shrinker or unsafe IO was added.
The runtime currently uses Hedgehog's native filter policy; public configuration
and property-emitter wiring remain outstanding.

The dedicated runtime checks pass both machine profiles. They demonstrate actual
list shrinking to three positive ones, nested witness reuse without admitting
oversized roots, foreign Symbol scope rejection, scoped native Symbols, empty
domains, and evaluator errors that survive a later empty field. Five compiled
mutants exercise filtering, errors, budgets, scopes and descendant indexing.

Haskell property adapter encode/decode, checked structural values and boundary
construction now carry the example's Symbol context. A dedicated emitter fixture
runs deterministic boundaries while the public randomized-contract gate remains
in place. It passes 196 examples in each width/layout configuration and detects
six compiled context-loss mutants. These boundary-only runs do not claim public
randomized constructor support. Nested absence constants now use qualified
Prelude constructors; native definitions returning Undefined, present Null and
present nested values compile and execute in both widths/layouts. The native
constructor matrix also retains its eight predicate/codec mutants.

All 436 compiler examples pass, as do embedded source and 59-module boundary
checks. Existing ordinary Haskell data integration remains verified for checked
strategy changes. Public randomized Haskell constructor properties, recursive
named refined payloads, remaining formatting and full release acceptance remain
open. Python retains PEP 8; development version remains 0.8.0.

WASM and source fingerprints are rebuilt and verified. Native/WASM parity passes
128 generation combinations and 16 check/expand responses. The ordinary Haskell
property regression is still running at this checkpoint; its first data/32
configuration passed 2473 examples. Do not treat this as a completed full matrix.

## Public Haskell constructor properties (2026-09-27)

HaskellProperties now draws checked native Hedgehog values in binder order,
passing typed boundary witnesses and safe local/constant hints. Each case shares
one Symbol context. Required conjunctive Symbol equalities bind directly;
disjunctive equalities retain all alternatives. Every draw is forced before the
next binder, so a later discard cannot hide an earlier evaluator failure.
Finite domains remain exhaustive. The public constructor-contract gate now
permits all eight targets.

Constructor properties run Hedgehog with explicit test, discard and shrink
limits from cases/maxAttempts/maxShrinks. The discard limit governs property
attempts; internal native filters retain their own retry policy, rather than
pretending maxAttempts counts all underlying candidates. REFINEMENTS.md records
this target-specific behavior.

The public failure checks exposed expensive sparse-predicate shrinking with
Gen.filter. Checked structural generators and contextual input filtering now use
native Gen.filterT, which prunes rejected subtrees rather than searching their
descendants. Native positive-list shrinking still reaches three positive ones.
A finite exponentially branching rejected subtree is tested under a bounded
observation; replacing filterT with filter fails that check. Runtime tests pass
both profiles and six compiled mutants.

The public integration runs both widths and readable/compact output, including
custom source/test directories, generic and dependent fields, Symbol scopes,
nullable/optional payloads and disjunctive predicates. Each configuration passes
209 examples, including thirteen randomized properties with exactly seven cases.
Sixteen compiled mutants expose bad identity adapters, always-true comparisons,
checked evaluation faults and all-rejected generation. The latter reports exactly
two discards in every affected property, matching the requested limit.

The earlier ordinary Haskell regression run completed: data, collections and
refinements at both widths, plus the scalar/conformance corpus at 64 bits, with
all corresponding faulty adapters detected. All 436 compiler examples pass with
the updated all-target contract expectation. WASM and fingerprints are rebuilt;
embedding, the 59-module boundary and diff checks pass.

Recursive named refined payloads, remaining formatting (including Haskell runtime
sources), and full packaging/release acceptance remain open. Python stays PEP 8;
development version remains 0.8.0. No publication occurred.
Native/WASM parity for this checkpoint passes 128 generation combinations and
16 check/expand responses, including successful Haskell constructor output.

## Recursive payload traversal groundwork (2026-09-27)

Core.Payload.checkPayloads supplies a shared reference traversal for refinements
on stored generic parameters. It keeps finite parameter-provenance recipes and
interprets recursive references only while descending through actual values.
A parameter instantiated with Int8 does not constrain an unrelated fixed Int8
field. Recipes compose through List/Maybe/Either and tagged absence, preserve
parameter permutations across mutually recursive declarations, and follow
growing type arguments such as Nest (List a). Phantom parameters and unselected
sum branches do not evaluate their predicates.

The caller supplies full value validation, which runs before payload predicates;
this permits constructor contracts without a Value/Eval import cycle. Predicates
short-circuit false results and retain contextual field paths for evaluator
errors. No recursion-depth cutoff, new native wrapper or eager recursive type
unfolding was introduced. The operation is framework-independent.

Ten focused Core tests cover recursive positive leaves and unrelated fixed
fields, depth 80, equal concrete types with different predicate roles, mutual
recursion with swapped parameters, growing type arguments, nested containers and
absence, phantom/unselected predicates, short-circuiting, contextual errors,
invalid shapes/ranges, callback arity and validation order. All 446 compiler/Core
examples pass. The boundary audit now covers 60 modules.

This is groundwork, not public support for Tree Positive: no new expression node,
source lowering, proof rule or backend callback was enabled in this checkpoint.
The next step is a typed payload-predicate operation using this traversal,
including binder scope/type validation and proof propagation through matching,
then source elaboration and equivalent execution on all eight targets. Keep the
existing source rejection until those paths are enforced rather than erasing
predicates. Remaining formatting and full packaging/release acceptance also stay
open; Python retains PEP 8 and development version remains 0.8.0.
WASM/fingerprints, embedding and diff checks pass. Existing public behavior has
native/WASM parity across 96 generation combinations and 12 check/expand
responses; this does not claim API exposure of the new traversal.

## Typed recursive payload predicates (2026-09-27)

Core now has AllPayloads with an ordered vector of scoped (Binder, Expr)
predicates. Expression validation checks the scrutinee's data/container type,
callback count and argument types, distinct binder identities, isolation from
outer and sibling scopes, Boolean predicates, and Boolean result type. Child and
free-binder traversal, purity, generic constructor-predicate substitution and
backend binder collection recognize the operation.

Reference execution uses Core.Payload.checkPayloads, retaining parameter origin
through recursive storage, outer dependencies, full constructor validation,
short-circuiting and contextual evaluation faults. Public.expressionView exposes
allPayloads with typed callback records. API-MIGRATION.md documents its scope.
The authoritative Gen.hs API generator now emits PayloadPredicate and both
allPayloads and the previously missing allElements union cases. A TypeScript
exhaustive visitor checks the generated declarations and rejects malformed binder
metadata; the check passes after the normal WASM/API rebuild, not a manual edit
to generated index.d.ts.

Nine further tests cover typed execution, guards, malformed callbacks, sibling
scope isolation, free variables/purity, generic substitution, wire metadata,
pending proof admission, and target diagnostics. All 455 compiler/Core examples
pass. The generated API layout tests retain the 80-column limit. Boundary and
embedding checks pass; WASM and fingerprints are rebuilt, and public native/WASM
parity passes 128 generation combinations and 16 check/expand responses.

Source Tree Positive remains rejected. Definition/constructor admission explicitly
rejects AllPayloads until the structural proof rules exist; all eight target
paths return diagnostics before emitting artifacts until native traversal is
implemented. This preserves invariants rather than silently dropping predicates.
Next add shared recursive payload proof facts, source elaboration and native
runtime traversal across all eight targets. Remaining formatting and complete
packaging/release acceptance are also open. Python remains PEP 8; version remains
0.8.0 and no publication occurred.

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

## Continuation after 0.10 (2026-09-29)

This plan deferred "GADTs, indexed families, and general dependent types" to
the following release (see Structural data above). 0.10 shipped native bindings
instead. The deferred item continues in PLAN-0.11.md as natural-indexed
families, which keep this plan's distinction between type and value arguments:
indices elaborate to erased data, structural measures and refinements, so the
checked Core boundary and all eight backends from 0.9 stay unchanged. Index-
directed generation extends the 0.9 node-budget allocators in each runtime.
GADTs that refine type arguments and general dependent types remain open.
