---
id: lawspec.explanation.content-identity
kind: explanation
title: Content identity
---
# Content identity

The compiler gives every type, declaration, handler, ability and law two
hashes. The **semantic hash** identifies its checked structure. The
**presentation hash** records names, documentation and source positions. Caches, test results, proof receipts and remote
evaluation use the semantic hash. Presentation-bearing compiler memos and file
rewriting also use the presentation hash. ref:DEC-content-identity

## What the semantic hash covers

The semantic hash is BLAKE3-256 over a tagged, versioned encoding of checked
Core (`lawspec.semantic.v1`). The encoding follows four rules.

- **Binders are positions.** A bound value or type variable is written as
  the position of its binder in traversal order. Its spelling is not written.
- **References are hashes.** A call, a construction, a type or a handler
  names its target by the target's semantic hash. A constructor is its type's
  hash and its position.
- **Presentation is left out.** Names, documentation, rationale, trace
  links, source spans and origins are not written.
- **Literals are normalized.** Decimals drop trailing zeros and rationals are
  reduced, as structural record identities already do.

Mutually recursive declarations form one group. Each member roots a traversal
of that group in Core field and reference order. First encounters assign
positions; back-references use those positions. Each member reaches the whole
group, so its hash covers all members and all edges. Renaming or reordering
members cannot change the traversal. Symmetric rooted groups share an identity.
There is no name-based tie-break and no factorial search for a permutation.

This uses the positional back-reference technique registered for CBOR shared
values (tags 28 and 29), rather than copying Unison's cycle-ordering shortcut:
Unison explicitly reports ambiguous equal-shape cycle ordering. LawSpec's
versioned, ordered Core serializer and traversal are compiler code that must
be trusted and tested; this is structural identity, not a proof of equivalent
behaviour. ref:DEC-content-identity

Hashing is structural. It never evaluates. `2 + 2` and `4` have different
hashes. This is Rune's rule: identity up to computation would mean running
programs to compare names.

## What does not change it

- Renaming a local, a parameter or a type variable.
- Reformatting, or moving a declaration.
- Renaming a definition. Its callers still name it by hash.
- Editing a description, rationale or comment.
- Editing a definition the thing does not reach.

A change to checked structure changes the hash. So does a change to the
checked structure of a dependency, because references carry target hashes.
An equivalent calculation written differently can have a different hash;
hashing does not decide equivalence by evaluation.

## The presentation hash

The presentation hash covers what the semantic hash leaves out: names,
identity spellings, docs and spans. It is a Merkle hash over the presentation
hashes of what the node reaches. It changes exactly when one of those changes.

A compiler memo whose result shows names, such as a plan or emitted code, is
keyed by both hashes. A result that only depends on behaviour, such as a test
outcome or a proof, is keyed by the semantic hash alone. So editing a
description rewrites a comment and reruns nothing.

## Where each hash is used

| Use | Key |
| --- | --- |
| Plan, expansion and emit memos | both hashes |
| `lawspec test` results | semantic hash, compiler build, target, toolchain, adapters; changed presentation is compiled/parsed first |
| Acceptance execution results | semantic hashes, build, toolchain, adapters, mutants; changed presentation is formatted and compiled first |
| Ordinary law proof receipts | per-law semantic fingerprint, encoding, positional proof settings, compiler/host build and actual solver identity; original execution retained |
| Law-set/model solver queries | semantic goal, encoding/build/solver context; current model decoding, checking and replay still run |
| Remote `contentHash` | `blake3-semantic-1:` then the semantic hash |

Generated files keep their `file:line` source links. The links change the
bytes, not the keys.

## The BLAKE3 implementation

LawSpec hashes with its own pure Haskell BLAKE3, so native and WASM builds
agree. It follows goforge's blake3sum: unboxed words, an unrolled compression
function, one compression for inputs of one block, and `hashMany` for many
small nodes. It is checked against the official test vectors and blake3sum's
output. ref:DEC-blake3-port

## Prior art

- **Rune** (goforge): BLAKE3 over checked core, De Bruijn binders, names as
  display metadata, groups hashed as a unit, and no hashing up to computation.
- **Unison**: names are metadata, arguments are numbered by position,
  dependencies are hashes, and a cycle is ordered by its members' hashes.
- **Dhall**: a semantic integrity hash over the αβ-normal form. LawSpec takes
  the α part only, by Rune's rule.
- **Salsa and rustc's red-green algorithm**: a recomputed result that hashes
  the same stops invalidation there (early cutoff). Acceptance keeps this.
- **Lean's Lake, Bazel and Nix**: build results are keyed by the hashes of
  their inputs, so the same inputs reuse the same output.

## Surface compilation and native interfaces

Elaboration and expansion precede checked Core identity. Their cached results
contain the source's actual names and spans, so they keep presentation-bearing
keys. A conservative dependency slice closes structured AST names through
signatures, nominal types and constructor fields. Structural records remain a
common input until their checked identities exist. The complete environment
still undergoes mandatory validation and is passed to elaboration; the slice
only narrows the memo key. These source memos are not alpha-equivalent result
substitution.

A native adapter's declaration and configured binding identify a real entry
point. Its public type and constructor/field names remain inputs to native
result keys. Local bindings inside checked bodies stay out. Public exported names and
keyword parameter names belong to native interfaces where the target exposes
them. The host additionally hashes actual adapter sources, toolchain and
binding configuration.

Opaque native code can call a generated helper that its law never references,
or look up an actor/handler/session interface dynamically. Such laws therefore
also key on a conservative generated public API footprint: callable checked
bodies, public type/constructor/field names and runtime interfaces. An edit to
a potentially callable generated helper invalidates these adapter results
until precise native dependency metadata can establish that it is unrelated.
Pure laws and solver goals retain precise semantic dependency closure. These
keys assume adapters use the documented generated API, rather than reflecting
private helper spellings or formatted source text.

A cached acceptance execution is separate from presentation validation. A
changed generated file is formatted and compiled/parsed by its native tools
before its earlier semantic execution is reused. An exact byte hit may reuse
both checks. The law-receipt cache reuses completed `unsat` law goals, retaining
original exact task/run fingerprints and marking reused provenance. Law-set
queries use a stable logical goal identity. A saved SAT answer retains its
original ordered constant names; the compiler decodes values positionally and
validates the current claim. A failed revalidation retries the current query.

Model queries key on the checked state/start/transition/claim structure and
the obligation's position. A query cache hit does not establish a model proof:
the current compiler still requires every induction or invariant re-check,
and replays a bounded counterexample against the current reference model.
Spacer's output remains a proposed invariant until plain re-checks succeed.
Raw completed SAT/UNSAT query results can be memoized; unknown, unsupported,
incomplete and failed process results cannot. Receipts retain original exact
execution fingerprints, with a separate current association. The cache is a
trusted local memo, not an authenticated or kernel-checked certificate.

Both the CLI and acceptance runner separately validate changed generated
presentation with native compilers/parsers without property cases. Readable
and compact layouts share execution keys; only byte-exact compiler-owned
scaffold alternatives normalize to one build input. User edits to build files
always invalidate execution keys. Fresh requests still execute tests.

Machine-sized primitive identities include their selected bounds. Remote
functions involving `IntSize`, `UIntSize` or `UIntPtr` consequently differ
between 32 and 64 bits, while fixed-width/exact functions remain portable.


## Emission chunks

Rust typed function and type documents are cached separately. A dependency's
semantic and presentation hashes, plus current native names and bridge
context, key each structured document. Editing an independent function adds
one cache entry rather than re-lowering both functions. The document's Binary
encoding preserves layout choices; no emitted source text is parsed back.

F# typed functions cache their structured layout and their literal/helper
requests independently. Byte literals receive checked content-derived names
before lowering, so adding a literal to an earlier independent function does
not change a later function's cache key. Replaying a function merges its
requests into the current module; no prior module request set is part of its
key. The current called names, native type names and target context remain
presentation inputs.

Python, JavaScript and TypeScript likewise cache individual checked functions
with structured documents or syntax trees. Helper allocation walks the checked
argument, result, expression and instantiated field types before lowering.
Each cached function replays only its requested helper/type set. Its context
contains the names of called functions and reachable native types, alongside
the selected helper names, rather than the previously accumulated module.
An unplanned helper is an explicit compiler error, not an order-dependent
name-allocation fallback.

Go and Haskell cache independent typed function and data documents. They
replay helper requests into the current module, and Haskell likewise replays
its content-named Text/Bytes literals. Go's effectful path consumes an abstract
`GoOperationPlan`: the same checked plan supplies both typed and dynamic
rendering, including the selected handler/interface, native codecs, failure
mapping and machine profile. Thus an operation profile change invalidates its
function while an independent pure function remains reusable. No function
closure is treated as a cache identity.

The Python/Web/Go/Haskell codec and comparison helpers are also independent
per-type chunks. Their cached structured products replay only newly requested
helper/type dependencies. A changed nominal type recomputes its own codecs;
codecs for an independent nominal type retain their entries even when the
outer unit must be assembled again.

The JVM emitter caches independent typed function, data, boundary-codec and
native-conversion documents. Each function starts with a fresh collision-checked
local scope, preserving source names and generated field/selection roles. Native
conversions and codec fields are named from checked types before lowering,
rather than numbered by previous requests. Cached conversion chunks replay only
their requested conversions; reachable allocated typed/native names and target
style remain part of their presentation context. Helper allocation also checks
friendly names against digest fallbacks, so a user-chosen name cannot alias a
fallback merely by resembling it.

Public Java, Kotlin and Scala data declarations and codec methods likewise
cache structured documents per declaration. Each context retains only reached
allocated names, handle/native interfaces, and selected explicit bindings.
Whole-program registry validation, public namespace validation and checked
schema construction still run on every request. Dynamic existential dispatch
and public schema assembly remain outside these declaration caches, so adding
a public type updates the API without invalidating independent documents.

Public Python/Web/Go/Haskell type documents and Go/Haskell codec documents
are likewise cached independently. Their exact contexts include reached
constructor allocations and, for Haskell, actual record selectors and deriving
capabilities. Generic parameter scopes reserve the interfaces the declaration
can actually name; adding an unrelated type no longer changes a parameter's
spelling merely because it resembles a compiler-chosen parameter. Constructor
predicate callbacks, schema metadata and dynamic dispatch are assembled afresh
under the validated registry, separately from cached native type documents.

Public Rust declaration chunks include their checked conversions and exact
recursive-boxing/ordering dependencies. F# caches independent native shape,
codec, bound-codec, handle and alias products. A recursive codec's keyword is
an assembly choice around a serializable signature and `Layout.F` body; no
function closure is stored or hashed. Pattern aliases use readable allocated
type names, reserve user type names, and add checked semantic suffixes only
for collisions. Their actual allocation is part of the codec presentation
context. A namespace regression adds a colliding user type after warming the
cache; its output matches a cold compile, and the resulting F# project also
passes Fantomas and its native tests.

`memoizedState` remains an exact state-transition primitive for emitters whose
incoming helper state is relevant. Independent chunks instead isolate their
request sets as above; hashing the accumulated prior module state would make
an unrelated earlier function invalidate later chunks.

The outer test/stub product cache now keys reachable type contents and their
actual allocated native names, the call mappings it can read, and real global
flags. An unused checked body is emitted separately and no longer stales its
unit's test/stub product. Full definition admission and namespace checks still
run before reuse. Public Go data/schema/codec artifacts are assembled outside
this unit memo, preserving the complete public API in every package.

Model products use the same checked dependency closure: machine callbacks,
argument descriptors, scenarios and contracts retain their real dependencies,
while unrelated type contents and unused bodies do not invalidate them. Public
Go scalar registry and assertion helpers are assembled as a separate test
companion, preserving exactly the previously selected primitive generators.
Adding a public type with a new scalar updates that companion without
re-lowering independent unit tests. Schema metadata, global dispatch tables and module assembly still run under
the current validated registry. They are distinct from the independent native
type/function/codec chunks; no cached execution bypasses current definition
admission or validation of newly generated presentation.

The regression oracle compares warm products against a cold compiler baseline
that bypasses all Haskell memo-table reads and writes. It covers type/name and
constructor-contract changes, source-line moves, and a public Go type newly
colliding with an adapter. The cold wrapper restores lookup after failures;
it does not disable mandatory admission or alter solver/native execution.

Generated type suffixes use checked semantic identities. Specialization
structurally lowers the already-checked concrete carrier rather than hashing
its printed surface type. Distinct native nominal interfaces with equal
semantic shapes receive deterministic presentation disambiguation. F# aliases
also retain their readable public type name.


Native dependency classification follows the checked call graph transitively,
including a workflow whose stages are native adapters. Explicit native binding
requests also make law results opaque: user codecs, constructors and generators
can invoke native code or any generated public API, even when a law calls only
checked definitions. Their implementation and public generated API therefore
remain cache inputs. A generated-name override alone stays presentation for a
pure law; a native adapter can observe that public name and retains it.

The JVM-family (including Groovy/Clojure), Go and Haskell generators currently
share a node budget: the greater of 64 and the largest structural boundary
value in the plan. Their native result keys include that actual sampling
context. An otherwise independent edit that changes this shared budget may
therefore rerun those tests; removing that dependency requires making the
sampling budget local, not merely weakening its key. Python/Web use their own
generator contexts and do not acquire the shared dependency.

## Scenario bindings

A checked scenario stores lexical variable and channel/end names as strings.
Identity traverses that structured AST and numbers bindings in lexical order.
A fork captures its incoming bindings and keeps new branch bindings local;
a receive-or-else handler cannot see a value that was never received.
Machine command references use their positions inside the enclosing checked
machine. The command's real adapter/reference identities remain semantic.
Constructor literals resolve through their type identity and constructor
position. A model's retained short state-type name resolves in the namespace
of its already-resolved system entry point.

Sequential/parallel model checks exclude scenario bodies from their keys;
a selected scenario includes its own body. Changing one scenario therefore
stales that scenario's execution without invalidating unrelated random-run
checks. Model/scenario titles and bound local/channel names are presentation.
Free machine/protocol/type descriptor strings outside an enclosing checked
context remain identity inputs, rather than being guessed or erased.


## Resources and persisted host caches

Resource binders are registered before the law body and examples encode their
uses. Generated sharing keys retain their runtime spelling and carry explicit
scope provenance (law, unit, run or named group). Mandatory Core validation
checks the key and group against that provenance. Only validated generated
spellings are presentation; unknown or explicit user keys remain semantic.
Resolved strategy aliases and harness names are presentation beside their
actual draw ASTs. Benchmarks are measured independently on every request.

The Node SDK mounts an explicitly requested host cache root at a dedicated
WASI path and puts compiler memos below the actual `core.wasm` SHA-256. Calls
that switch cache roots are serialized and use independent instances. The
proof host keeps the original host directory for its receipts. An absolute
host path is never accidentally treated as a path below the working directory,
and two binaries with the same package version cannot share compiler memos.

A cached bounded SAT model that the current evaluator cannot replay is deleted
and its current solver task is retried once. A structured compiler replay
result controls the retry; the host does not classify diagnostic prose or
rewrite solver/model text. This covers obsolete public constructor symbols
while preserving explicit incomplete outcomes for unconfirmed fresh models.
