# LawSpec 1.0 design and business review draft

**Minor authoring implementation contract — updated 20 October 2026**

Repository: brain-fuel/lawspec\
Audience: business readers, product owners, developers, language designers, and verification practitioners.

LawSpec describes what software must do and connects those requirements to implementation, tests, and verification evidence. The intended language combines approachable words and explicit structure with advanced types and formal precision.

The user-deferred readability exercise will establish whether actual business readers can understand these specifications. Agreement between programmers about attractive syntax is insufficient. Readers should be able to predict outcomes, explain obligations, identify missing requirements, and understand what the evidence establishes.

The latest approved milestone direction below is authoritative. The implementation contract originally called RC1 remains the implementation baseline, subject to the later decisions recorded here. Earlier discussion and superseded alternatives remain history.

**0.25.0 acceptance history (before the later tag authorization):** version 0.25.0 has completed the current minor's implementation and full acceptance gates and remains **unpublished, not a release candidate**. Package rebuilding, installed-package validation and read-only release checks pass. No RC designation, tag or publication is authorized. The technical profile identifier `1.0-rc.1` remains an implementation identifier, not a release designation. The final acceptance receipt below supersedes earlier pending execution statuses. Historical design examples are not, by themselves, claims that the parser accepts them; current executable examples and their evidence are identified in the receipts. Code blocks deliberately use plain text rather than simulated syntax highlighting.

Examples are independent unless a section explicitly connects them. Repeated unit names and simplified signatures are separate presentations, not declarations intended to coexist in one source file.

## Approved cross-project path to 1.0 — 20 October 2026

The next integration is **LawSpec contracts → CALM architecture and Ironframe
bindings → real services or LawTwin fixtures → execution evidence**. Continue
ordinary minor releases while completing these gates; no 1.0 designation follows
from this direction alone.

LawSpec owns business laws, dependency abilities, checked reference models and
verification evidence. Mandatory definition validation remains independent of
optional law verification. LawTwin owns protocol fixtures around those models,
declared faults, deterministic time, control APIs, histories, replay and provider
conformance. Ironframe owns CALM service nodes and dependency edges, resolved
LawSpec contract identities and explicit per-environment real/twin bindings;
applications receive settings through their normal configuration mechanisms.

Use CALM 1.2 and validated decorators attached by architecture element identity
for contracts and environment bindings. Generate diagrams, connection settings
and OpenTofu/Terraform from the same resolved topology, reusing CALM diagram
tooling and existing Ironframe modules. Architecture validation, diagram export,
infrastructure export and configuration injection work independently of optional
Ironframe deployment of dependencies or applications. Exported artifacts remain
usable by other deployment tools. Evidence carries architecture, contract,
implementation and run identities, distinguishes planned wiring from completed
execution, and identifies real-provider versus fixture results.

| Order | Required completion gate | Status at adoption |
| --- | --- | --- |
| 1 | Upgrade LawTwin's 0.23 compiler pin, contracts, configuration, OpenAPI importer and generated consumers to 0.26; recheck the historical gap report; replace source scraping with supported embedding interfaces; pass Kafka/HTTP conformance, replay and mutation controls. | Open. |
| 2 | CALM identity resolution and compatible real/twin bindings; Kafka/HTTP demonstrations with unchanged application laws; diagrams, infrastructure, external application deployment and optional managed applications; completed-run attestations consumed by LawSpec; refuse unresolved or incompatible bindings. | Open. |
| 3 | Measure existing fixtures, a Cassandra prototype and real Cassandra before setting budgets. Separate downloads, readiness, reset, memory and full-stack costs. Prefer one fixture container with logical replicas, tunable consistency, replication faults and lightweight transactions; verify distributed cases against a real cluster. A single-node fallback requires measured justification and explicit reduced coverage. | Open; no numerical budget selected. |
| 4 | LawTwin core per program target with shared black-box conformance. Finish LawSpec Prolog, HCL, YAML, ANTLR, Make and Folio targets. C/C++ remain optional for 1.0. | Open. |
| 5 | Extend integrated Z3 numeric/data reasoning, recursive proofs, validated counterexamples, conflict/completeness and advanced temporal verification. Study primary SPARK/Why3, Lean 4, Idris 2 and Rocq sources first; record supported fragments and trust boundaries. Complete the retained demonstration portfolio below. | Signed off by the owner on 22 October 2026 (receipt below); integrated from `gate5-proofs` in 0.28.0. Existing scoped solver receipts retain their meaning. |
| 6 | Architecture cleanup; API, grammar and configuration compatibility contracts; documentation and canonical review through Rice's Tax; full release and cross-project acceptance; human and external sign-off. | Open. |

LawTwin's 1.0 dependency families are **Kafka, HTTP/OpenAPI and Cassandra**.
Other dependency families remain later work. The retained LawSpec portfolio is
Chapter 6 implementations and verification in all 17 existing languages with its
inventory, independent instruction oracles and repeated-call checks; Projects
7–8 and 10–11 in Java, Python, TypeScript, F#, Rust, Elixir and Clojure; testable
Jack Snake and the complete public Jack OS API; full selected API coverage of
fast-json-patch, cachetools, shopspring/decimal, NimbleOptions and semver; and the
authorization, existence, policy-conflict and stateful workflow demonstrations
with their remaining advanced analyses.

Acceptance runs the same application against real, twin and mixed bindings
without law edits, exercising shared dependencies, independent fixtures, faults,
resets and deterministic replay. Compare diagrams, infrastructure and injected
settings against the resolved CALM topology and exercise external and framework
deployment. Independent provider conformance and meaningful mutation controls
are required: agreement with generated models alone does not establish fidelity.
Complete compiler, native/WASM, target, editor, documentation, packaging and
cross-project regression checks.

The user-deferred readership gate stays open: three readers, ten questions, at
least eight correct each, all distinguishing incomplete search from proof of
nonexistence. Begin independent adoption and GitHub Linguist work early;
upstream recognition remains external and pre-1.0. Pre-1.0 migration support
remains removed. This direction supersedes earlier conflicting scope decisions,
without relabelling historical execution receipts.

Precedents: [CALM decorators](https://calm.finos.org/core-concepts/decorators/),
[CALM tooling](https://calm.finos.org/working-with-calm/cli/),
[Cassandra architecture](https://cassandra.apache.org/doc/latest/cassandra/architecture/dynamo.html),
[Cassandra guarantees](https://cassandra.apache.org/doc/latest/cassandra/architecture/guarantees.html).

### Gate 5 proof work — 22 October 2026

The proof work for Gate 5 (row 5 above) is integrated from `gate5-proofs`
through `7b2fd6b7` in fourteen increments for 0.28.0, with documentation
closeout `9260ac5f`, following the owner decisions recorded with the proposal.
The owner signed off Gate 5 on 22 October 2026, accepting the fragments,
trust boundaries, limits and portfolio results below, and accepting the
full-Unicode Text encoding in place of the earlier refusal above U+2FFFF.
This sign-off does not cover the remaining implementation and human acceptance gates. Mandatory definition admission stays independent of optional law verification:
Fourier–Motzkin stays its only engine, it never calls Z3, and it works in WASM
and without Z3. Optional law verification stays a separate selection. Every
`lawspec-smtlib-v1` task keeps its script and fingerprint byte for byte (a
frozen-corpus test guards it); everything new is `lawspec-smtlib-v2`. There is
no kernel-checked proof tier: `proved` by Z3 trusts the typed translation and
the solver, and every receipt says so.

**Supported fragments and trust boundaries.**

| Fragment | How it is decided | Trusted |
| --- | --- | --- |
| Integers, Booleans, exact arithmetic, non-recursive calls | Z3 (v1, frozen) | Translation and Z3 |
| Enums, records, alternatives, `Maybe`, `List`, `Either` | SMT datatypes with well-formedness; wrong-constructor reads are undefined | Translation and Z3 |
| Recursive definitions | Unfolding step by step (guarded axioms with fuel, as Why3 and Dafny), then solver recursion (`define-fun-rec`); harness may choose | Translation, Z3, and admission's facts that a definition is defined and in its result type on its domain |
| Induction | Structural or integer countdown on a named input (Why3's `induction_ty_lex`/`induction_int_lex`), lemmas cited with `using`, one task per case | Translation, Z3, schema generator |
| Text and regexes | UTF-32BE in SMT strings preserves all Unicode scalars; aligned text operations and regexes are differentially tested against `LawSpec.Regex` | Translation and Z3's string theory |
| `Rational`, `Decimal`, IEEE floats | Rational as integer over positive integer; Decimal exact (universal over Reals, witnesses multiples of 10^-18); Float32/Float64 as SMT FloatingPoint with IEEE equality | Translation and Z3 |
| Counterexamples | `get-value`, then the reference evaluator re-checks; an unconfirmed model is never a refutation | Reference evaluator |
| Law sets | Completeness, overlap, conflict, vacuity on by default; exhaustive for finite domains, Z3 otherwise; `laws for` claims and dated exemptions | Evaluator for refutations; translation and Z3 for proofs |
| Model laws | In-house explicit-state LTL with weak and strong fairness (GPVW tableau, Tarjan, Lichtenstein–Pnueli), shared by native and WASM; deadlines in microsecond ticks | Evaluator, tableau and search |
| Unbounded models | Z3 induction; Spacer proposes invariants that plain queries re-check; bounded runs replayed by the evaluator | Translation and Z3; Spacer is trusted for nothing |
| Histories | Complete histories proved or refuted; open histories three-valued (LTL3) with `pending` | Evaluator and automata |

New evidence statuses, `refuted`, `exempted` and `pending`, add values without
changing any existing one; the API schema stays 5.

**Portfolio.**

| Item | Demonstration | Where |
| --- | --- | --- |
| 13.1 Chapter 6 reference models | Five unbounded laws proved: labels add no instruction, instruction counts add across joined programs (induction), fitting labels keep the program in ROM (induction generalized over the counter), `bits` gives as many digits as asked (integer induction), every word has 16 digits (solver recursion). The 17-language implementations belong to the implementation gates. | `test/fixtures/chapter6-proofs.lawspec`, `SmtTextSpec` |
| 13.3 Codec | Direct round trip and the applied left-inverse law, both proved; a text tag round trip proved | `test/fixtures/codec-proofs.lawspec` |
| 13.4 Existence | Solver-established nonexistence kept apart from failing to find a candidate; complete finite refutation reported `refuted`; bounded search reported incomplete | `SmtSpec`, `CounterexampleSpec`, RC1 witness search |
| 13.5 Revocation and histories | Complete snapshot proved; open history `pending` (holds so far, or not yet); deadline refuted as soon as observed time passes it; invariant, bounded history and unbounded future kept apart | `test/fixtures/history-revocation.lawspec`, `ModelCheckSpec` |
| 13.6 Policy conflicts | Compatible requirements proved with witnesses; contradiction refuted at amount = 0, captured = 0 naming both laws; suspected overlap Z3 cannot resolve reported incomplete; partial law proved in scope; uncovered input exempted without refuting the law | `test/fixtures/law-sets.lawspec`, `LawAnalysisSpec` |
| 13.7 Order workflow | Invariants and orderings proved over all reachable states; an invalid-transition mutant refuted with its run; liveness proved under weak fairness and refuted without it; deadlines proved under a clock rule and refuted with `authorize, wait 25h`; model results separate from native conformance | `test/fixtures/order-workflow.lawspec`, `test/fixtures/model-deadlines.lawspec`, `ModelCheckSpec` |
| 13.8 Advanced type regressions | Matcher facts and refined operation results in admission (Gaps A and B); checked recursion proved by unfolding and induction | Increments 1, 2, 7 and 8 |
| 14.10 Validated counterexamples in views | Every refutation shows the inputs the evaluator confirmed | Evidence reasons, `lawspec evidence` |

**Limits kept explicit.** Native implementations, effects and resources are
not given to Z3. Functional induction per definition branch is not generated.
Text operations that expose a code point are unsupported. A data type with a
float field is refused. Deadlines are checked as `whenever P, Q within d` and
`Q within d`. The explicit search stops at 20000 states, and the bounded run
search at 8 steps. The owner confirmed both syntax choices: history laws say
`the complete history holds` or `the history so far holds`; model time
advances only through an explicit `wait` command, in automatic ticks of the
greatest common divisor of the deadline and one hour. A deadline without
that command is unsupported. The decisions are `DEC-validated-counterexamples`,
`DEC-smt-datatypes`, `DEC-refuted-status`, `DEC-law-set-analysis`,
`DEC-smt-recursive-definitions`, `DEC-smt-induction`, `DEC-smt-text`,
`DEC-smt-numbers`, `DEC-model-checking`, `DEC-model-induction`,
`DEC-history-checking` and `DEC-gate-5-receipt`.

**Acceptance.** Each increment passed its focused compiler, npm, WASM,
documentation, generation and Canon checks. The source-branch full CI on
`7b2fd6b7` ran 2,738 steps without cache reuse: 2,735 passed and three Scala
acceptance steps (`asyncbindings`, `minor-stateful-initializers` and its
32-bit compact variant) failed on stale Bloop build state in their working
directories (`FileAlreadyExistsException`). With those directories cleared,
the three suites passed in focused reruns. The source closeout changes only
this document and the decision ledger.

The merged candidate `d94c9622` completed a separate content-addressed
`make ci` checkpoint of 2,739 steps: 2,738 passed, including 2,406 compiler
examples with zero failures, all target acceptance checks, 6,416 complete
native/WASM response comparisons, package smoke, Canon and documentation
(123 pages and 121 compiled snippets). Matching generated projects reused
2,029 native acceptance records; four core steps reused their exact input
records. No tracked input changed during the checkpoint.

The SDK catalog reported 373 passing tests, five opt-in skips and one stale
assertion that U+30000 was unsupported. Full Unicode support correctly
refutes that false law. Only its test and generated test were corrected to
require an evaluator-confirmed counterexample; the complete proof SDK file
then passed all 23 tests with zero failures or skips. The raw CI failure
and focused recovery remain separate records. Subsequent changes affect
only documentation and those two test files; compiler and packaged bytes
match the checkpoint. Logs and receipts are retained locally under
`.artifacts/gate5-integration-20261022/`.

The WASM core was rebuilt with `tools/wasm.sh`: 76,208,086 bytes, SHA-256
`d991fd3b5d54e86d4bb516d0cf46adc94f17e13647d7cb207f4364c51c7f77fb`.
The packed 0.28.0 archive matches the installed-package smoke archive byte
for byte. Integration review also adds regressions for missing induction
obligations, bounded reachability and open-history deadlines; main's
runtime-correlated BEAM overlap controls and stalled-hedge controls are retained.

### Working-tree alignment increment — 20 October 2026

LawTwin's contracts and configuration now consume 0.26 syntax, configuration
version 2 and profile `1.0-rc.2`, with explicit verification layers. Native
acceptance executes **613 law instances**: 79 Kafka instances on each of Rust,
Python, Go, Java, Kotlin, F# and C#, and 14 Petstore plus 16 GitHub instances
on Rust and Python. The first no-layer trial runs remain incomplete historical
attempts; they are not counted as law execution.

The Kafka and HTTP build scripts that scraped generated Rust bodies are removed.
Kafka uses public generated handler operations and typed snapshots. The HTTP
importer emits adapters from its OpenAPI IR and links generated models as normal
Cargo libraries with distinct package identities. Its registry is explicit.
Fresh 3.0/3.1 fixture imports and their adapters compile, including constrained
records, maps, singleton alternatives and unions. The historical LawTwin gap
report now distinguishes its discovery record from current supported mechanisms.

A constrained 3.1 fixture also exposed missing public embedding methods on the
Rust dynamic path. That path now shares the existing failure-returning wrapper
emission and provides construction and native state snapshot/restoration methods.
Restoration validates the declared schema; it does not prove state reachability.
The implementation uses the existing runtime and schema infrastructure and adds
no proof engine, solver execution or proof-checking backend. Mandatory definition
validation and explicit incomplete/unsupported verification outcomes remain.
Native regressions pass at both integer widths and in both output layouts,
including refusal recovery, restoration, concurrent updates and a rejected
arithmetic mutation.

The full compiler suite passes **2,253 examples, zero failures**. The WASM build,
source/API integrity, all 122 generated-file checks and the 232-module compiler
boundary check pass. The rebuilt Kafka and HTTP black-box protocol suites pass.
The unfiltered SDK sweep is **incomplete**: 333 tests passed, five opt-in tests
were skipped and the example-export test was cancelled when closing this scoped
increment. The broad native/WASM sweep was also stopped after its 68 frontend
fixtures at both widths and the 17-target 32-bit noncompact generation profile.
These interrupted runs are not relabelled as successful full acceptance.

A completed focused parity run compares **303 complete responses** across all
17 targets, both widths and both output layouts, including the changed dynamic
embedding model, the codec control, invalid-input controls and packaged inputs.
Its 231 accepted and 72 rejected responses agree exactly. The locally packed SDK
also passes both native embedding regressions across both widths/layouts and
rejects the arithmetic mutation. Full installed-package smoke and release
acceptance remain separate gates. The frozen 0.26 technical receipt
below still identifies its original source commit and artifacts; it does not
certify these later working-tree changes.

LawTwin's scoped receipt is `docs/reference/lawspec-026-upgrade.md` in that
repository. Local logs are in LawTwin's `.artifacts/upgrade-026/` and LawSpec's
`.artifacts/integration-1/`. Use the companion compiler checkout for the new
dynamic embedding support until a package containing it is released. No new tag,
push or publication is performed by this increment. CALM integration, Cassandra,
the remaining target/demonstration work, advanced verification and final sign-off
remain open; recording their direction is not their implementation.

### Working-tree artifact target increment — 20 October 2026

HCL, YAML, ANTLR and Make now have compiler, API, CLI, scaffold and package
entry points. They consume checked Core through a separate artifact emitter;
the executable program inventory remains the existing 17 languages. Artifact
targets emit no native law-test or benchmark slots. Both the public compiler
entry points and the artifact emitter itself enforce definition validation
independently of optional law layers.

The [artifact contract](docs/reference/artifact-targets.md) records the supported
configuration fragment and explicit unsupported cases. Checked `Unit -> T`
definitions supply values through the existing total-definition interpreter.
Missing external values are incomplete and do not produce a complete YAML
document. Empty data types use an unsatisfiable JSON Schema. HCL refuses
unbounded integer domains and generated text literals whose normalization it
cannot preserve. Its existing cty input conversions remain explicit. ANTLR
generates syntax parsers and companion schemas, with semantic validation after
decoding; Make orders ordinary CLI stages and propagates failure. No new solver,
normalization algorithm or proof checker is introduced.

Independent acceptance uses JSON Schema 2020-12 and PyYAML, OpenTofu validation
and planning, ANTLR compilation and its generated Java parser, and parallel Make.
Rejection controls, literal template strings, empty types and Unicode round trips
pass. Canon parses the same four emitted formats; its current inventory matches
the public compiler inventory of 17 program and four artifact targets. Its
Prolog grammar's six tests also pass, which is grammar evidence, not a Prolog
compiler backend.

The scoped checks pass **ten compiler tests and 11 SDK/CLI tests**, including
both machine profiles and layouts, incomplete configuration, unsupported
representations, layout/binding refusal and forged-definition admission checks.
The locally packed SDK passes the same 11 tests and includes the normalization
dependencies' licenses. A completed **411-response native/WASM comparison** has
291 accepted and 120 rejected responses, including all existing program targets,
the four artifact targets and intrinsic-validation, incomplete-input, empty-type
and normalization controls. All **124 generated-file checks**, source/API/WASM
integrity and the **233-module boundary check** pass.

The first broad compiler run exposed one erroneous new test fixture: a value
adapter was written without its required `Unit` input. Its 2,260-example result
was 2,259 passes and that fixture failure. The fixture is corrected and the
targeted checks pass. The replacement broad regression run passes **2,262
examples, zero failures**; its executable predates the final UTF-8 serialization
and type-only metadata corrections, which are covered by the focused native, WASM,
independent-validator and installed-package checks above. The CI graph now
includes each artifact validator with a shared, pinned tool bootstrap.
This increment does not claim full release acceptance. Logs are under
`.artifacts/integration-1/artifact-*`. That artifact cohort left Prolog's program
backend unregistered; the later public integration is recorded below. The authoritative Folio and wider 1.0 commitments
remain before final sign-off. No tag, push or publication is performed.

### Prolog execution infrastructure — 20 October 2026

The experimental Prolog emitter now derives functional adapters, checked-model
entry points and PLUnit slots from Core over the existing Python emitter.
It does not scrape generated source. Janus supplies the FFI and thread
attachment; existing Core schemas check both directions, including opaque
handle identity. SWI's determinism guard rejects logical failure and choicepoints.
A returned `false`, typed native failure, an explicitly incomplete result and an
unexpected exception stay distinct. Exact numbers, IEEE payloads, raw text units,
constructor identities and nested presence have explicit term representations.

The decision ledger records the precedents from SPARK, Why3, Lean 4, Idris 2
and Rocq and their mapping to this execution trust boundary. No obligation
generator, solver or proof checker is added. Definition validation remains
mandatory. Three compiler admission tests and 19 independent runtime tests
pass. The functional prototype runs three PLUnit slots in each width/layout
profile, observing 518 host cases per profile, including a Hypothesis property.
All twelve wrong-result, logical-failure and nondeterminism mutants are rejected.
The host framework's JUnit records are retained as observed execution evidence.
Runtime capability proxies and per-instance production tokens also pass state,
release, concurrency, failure-payload and undefined-truth controls. Undefined
Prolog truth stays explicitly incomplete. Core-derived handler metadata now
generates production factories and operation schemas. Seven effect/recording
slots observe 1,537 cases per profile across all four width/layout combinations;
twelve state, bypassed-operation and malformed-refusal mutants are rejected.
Checked-model entry points offer explicit reusable contexts for symbol identity.
Generated predicates use an `ls_` prefix to avoid protected SWI predicates such
as `close/2`.

Model slots now come from the existing test manifest. Property slots select
their case groups; model slots select exact host tests. The actor example passes
seven slots (517 native cases), including sequential/parallel histories, two
scenarios and supervision; an incorrect state transition is rejected. An async
shared-counter fixture passes sequential, parallel and scenario checks in all
four profiles and rejects four incorrect-update mutants. Async adapters use
the standard `asyncio.to_thread` bridge; cancelling a waiting task does not
forcibly terminate an already running predicate.

That prototype cohort did not establish public Prolog target completion:
dispatch, consistent host lowering, native bindings, CLI integration and native
incomplete-result evidence still needed integration. The public increment follows.
The runtime source parses with Canon's Prolog grammar. Logs and experimental
execution records are under `.artifacts/integration-1/prolog-*`.

### Completed-run attestation merge — 20 October 2026

`gate2-attestation` (`de143a52`) is merged into main by `06fbcab5`.
`tools/wasm.sh` rebuilt the compiler and its fingerprints; `9be3042f` records
those artifacts and is pushed to GitHub main. Ironframe main is `40a1154`.
The unfinished target implementation is restored separately on
`codex/prolog-artifact-targets`; it is not part of this main checkpoint.

On the merged, rebuilt compiler, 13 native attestation tests, 180 native
ability and related tests, 56 JavaScript runner/evidence tests and 303 complete
native/WASM response comparisons pass. Ironframe's workspace passes 113 tests
with two container acceptance tests intentionally ignored by that command.
An isolated variant of its CALM acceptance test then passes against the local
rebuilt npm archive: unchanged laws run against twin, real and mixed bindings,
with shared dependencies, managed and external applications, faults, resets
and deterministic replay. It asserts completed run identities and outcomes
under `against` rather than the previous planned fields. All three
environments are torn down. The variant and receipts are retained under
`.artifacts/integration-1/gate2-*` and `e2e_calm_candidate.rs`.

This establishes the merged execution-evidence path against Ironframe's
current example and existing provider/fixture images. It is not the complete
release matrix, independent provider fidelity, human review or 1.0 signoff.

### Haskell/WASM CALM reacceptance — 21 October 2026

Ironframe `f4d88c3` reaccepts the Haskell/WASM port at `b178230`, using the
merged LawSpec compiler and fresh LawTwin `8c592d7` fixtures. All 46 recorded
Ironframe core source/artifact fingerprints remain unchanged. The same two
application laws produce four native instances per environment, all executed
and property tested against twin, real and mixed bindings. Each completed law-run
attestation reaches LawSpec with the matching run, provider kind and fixture
history digest. Managed processes, a freshly built managed image and an
externally run application exercise the intended shared Kafka dependency.

Kafka/HTTP faults, recovery, resets and deterministic replay pass; an audit
against an emptied log produces a completed failed-run attestation. CALM CLI
1.65.0 validates and renders the architecture. Exported diagrams, settings and
infrastructure pass correspondence checks and missing-edge/key/module negative
controls. The exported staging root initializes and validates without cloud
deployment. All four cloud modules pass 14 mocked provider tests. The port's
2,231 native examples, 1,417 Node tests, configuration-service container test,
packaged CLI smoke checks, generated-source and artifact-integrity checks pass.
Both opt-in container suites execute separately and remove their containers.

The strict completed-versus-planned checks found a CLI defect: without an
explicit completed file, the cached startup attestation was relabelled as
executed wiring. LawSpec `03218926` preserves that snapshot's `plannedAgainst`
fields and planned dependency counts. It retains historical receipt semantics
when no execution state was recorded. To consume Ironframe's final state,
provide its completed file to `lawspec evidence --attestation`; a child's
passing native tests do not complete the enclosing environment run.

The final full LawSpec SDK regression on `9ce9d0cf` passes: 361 tests passed,
zero failures or cancellations, and five existing native opt-in cases skipped.
The complete bundled-example export exercises all 18 target inventories,
repeat export, adapter preservation, edited-output refusal and path controls.
Ironframe `df6417c` also checks exact architecture/decorator/topology digests;
its strengthened three-environment chain passes. The installed packed CLI's
matched staging topology, diagram and unedited infrastructure root initialize
and validate with the declared repository modules.

The local integration acceptance is complete. Its reviewable logs, exports,
attestations, package equivalence and execution audit are retained under
`.artifacts/ironframe-port-20261021/`; Ironframe's CALM demonstration guide
records reproduction instructions. Independent provider conformance remains
LawTwin's separate obligation. This does not close the remaining release,
Cassandra, target, demonstration, human or external 1.0 gates.

### Public Prolog integration — 20 October 2026

Prolog is now registered in the public compiler, SDK, scaffold, doctor and test
interfaces. The working inventory is **18 program targets and four artifact
targets**; Canon's parity inventory agrees. This extends the program inventory
without changing the retained 17-language Chapter 6 requirement. Checked Core
supplies the host name/witness lowering, model signatures, ability identities,
PLUnit slots and native manifests. Custom nested source/test directories work.
Empty host adapters become generated support; application implementations stay
user-owned Prolog files. No generated-source scraping is used.

Native functions and production handlers bind by module/predicate identity.
Prolog generator factories return genuine Hypothesis strategies through Janus,
including child strategies for generic parameters. The existing Python native
generator traversal validates every sample and shrink. Structured incomplete
results survive native calls, factories, worker threads, pytest/JUnit and native
attempt records. Human-readable exception text never determines this status.
Method/constructor call bindings, native type/codec mappings, native exception
mappings and coverage instrumentation remain explicitly unsupported. PLUnit law
slots run sequentially; declared concurrent model histories still run workers.

Six compiler admission checks, six public SDK checks, 21 independent runtime
checks and the worker-thread reporting control pass. The shared native manifest
checks include Prolog. At both 64-bit readable and 32-bit compact profiles,
the repeatable bridge suite observes **2,058 native cases in 13 PLUnit slots**
and rejects seven incorrect arithmetic, determinism, effect and async-state
mutants. The shared refund/order suite observes **83 cases in eight slots** and
rejects nine policy/state mutations. The shared cryptography suite observes
**63 cases in 20 slots**, including independent provider known-answer vectors,
and rejects two adapter mutations. Provider results retain their existing
cryptography trust boundary; this is no new solver or proof checker.

The shared definitions suite also passes at both profiles, with 2,012 native
cases in 13 slots and its incorrect-count mutation rejected. The shared
nesting suite passes 20 cases in 20 slots and eight structural mutations at
both profiles. Examples and exhaustive layers retain their slots independently
of property selection. Complete empty input domains retain their Core proof
without planning a nonexistent native test; unexpected empty collection still
cannot pass. The first 64-bit search acceptance run passes its four mutations
after this manifest correction. These remain separate receipts from the
earlier parity and full compiler cohorts.

After the attestation merge, `tools/wasm.sh` rebuilds the combined target
branch. Its 64 selected SDK/runner tests and 20 focused native compiler tests
pass, including both the new empty-domain slot check across all program
targets and completed-run attestation checks. The bridge's seven mutation
controls and the 32-bit compact search suite's four mutation controls also
pass. All 126 generated files, the 234-module boundary, version consistency
and compiler/artifact fingerprints match. The preceding full compiler cohort
passes 2,271 examples with no failures; that binary predates the empty-domain
manifest correction and this merge, so it is not a full final-source claim.
Final combined-branch parity agrees on 520 complete native/WASM responses
(388 accepted, 132 rejected), including bounded witness search, all 22
targets and both widths/layouts. Documentation checks pass 122 pages and
119 compiled snippets, with links resolving.
Post-merge logs are under `.artifacts/integration-1/post-gate2-*`.

The installed payment example passes both profiles, including a wrong-fee
mutation, selective invalidation, failure replay and regeneration preservation.
Fresh CLI projects also pass both profiles with nested layouts, doctor checks,
exact audited benchmark callback counts, unchanged-result caching and a native
incomplete-result mutation. All-target native payment export checks pass.
The initial public parity cohort matches **428 complete native/WASM responses**:
304 accepted and 124 rejected. Later runtime refinements require the current
artifact checks as well; historical receipts are not overwritten as newer proof.

The full shared native acceptance matrix, complete SDK/release regression and
remaining 1.0 gates are still open. In particular, registration and these
executions do not establish every native suite, LawTwin's core-per-target
commitment, external provider fidelity, Folio completion or human canonical
review. The [Prolog reference](docs/reference/prolog.md) records the supported
interfaces and execution scope. Current logs are under
`.artifacts/integration-1/prolog-*`.

### Shared Prolog acceptance and module locality — 20 October 2026

The initial audit runs all 40 shared suites that require no application-owned
Python adapters or bindings. Both 64-bit readable and 32-bit compact profiles
pass, rejecting 107 mutation controls each. This includes recursive records,
dependent payloads, collection semantics, bounded search and mandatory
definition checks. These audit cohorts precede the loader correction below;
they are scoped receipts rather than a full final-source matrix claim.

Independent Prolog application fixtures now exercise collections, algebra,
exact scalars, typed synchronous/asynchronous failures, indexed vectors and
trees, existential carriers, opaque shared queues, domain workflows, tables,
native capabilities, keyword hygiene and the general integration examples.
The established Python portable generator is exercised through Janus against
the shared fixed generation/shrinking vectors. Harness controls include
coverage requirements and a known-failing law that must reject an unexpected
pass. Recorded-value checks pass both profiles and reject alias, byte and
signed-zero mutations. The indexed suite rejects ten distinct native
algorithm/index mutations at both profiles. The shared native-name binding
override also passes its source mutation at both profiles.

Two otherwise valid price/quantity mutations escaped the domain suite's
sampled inputs. Five explicit boundary examples now check quantities 800,
801, 1000, 1001 and zero against the already declared policy. Python and
Prolog both pass; the Prolog price and upper-quantity mutations are rejected.

The integration suite exposed conflicting imports when separate Prolog
modules exported equal predicate names. Application and generator modules
now use SWI `load_files/2` with an empty import list and qualified calls.
The independent module-locality control passes; the integration suite passes
all 15 mutations without import errors in its correct-run log. The existing
Janus conversion options preserve Text as Prolog strings and retained native
collections as opaque objects. No proof machinery or execution-status
relaxation is introduced.

The rebuilt package passes 22 independent runtime controls, structured
worker-thread reporting, 56 selected SDK/runner tests, 20 focused native
compiler tests, the fresh CLI workflow and installed payments. All 520 full
native/WASM responses agree. Canon parses all 38 native Prolog fixture files;
documentation retains 122 pages and 119 compiled snippets with links resolving.
The compiler and artifact fingerprints match. Logs and per-suite receipts are
under `.artifacts/integration-1/prolog-*`.

Fifteen shared fixture families remain: mapped failure products, workflows,
resilience, models, concurrent collections, asynchronous/handler bindings,
built-in capabilities, resources, scheduling, sessions, actors, consistency,
distribution and composition. In particular, separate pytest invocations per
PLUnit slot still prevent the host's cross-slot scheduling and shared-resource
scopes from being fully exercised. The existing Python harness supplies the
precedent for that work. Full compiler/SDK/release regression and canonical
human review remain open; no target-completion or 1.0 signoff is claimed.

### Prolog scheduling and scoped execution — 20 October 2026

Selected host cases now run once in one pytest session. The established host
harness controls seeded ordering, parallel execution and resource sharing;
PLUnit consumes per-slot results from actual observations. Collection and
JUnit node identities must agree. Duplicate, ambiguous, missing and malformed
reports remain incomplete, and a broken report cannot re-execute the batch.
Context variables retain worker ownership; ambiguous child-thread events
conservatively invalidate active cases. Late events remain attached to their
originating case even after pytest produced that case's report.

Ten independent reporting controls pass, including mixed parallel success,
failure and incomplete results, unscoped and late workers, partial selection,
equal unittest method names, fail-fast behavior within one law and malformed
reports. Correctly skipped cases after an incomplete computation remain
skipped; they are not invented native executions.

The scheduling suite passes repeatable seed ordering, changed-seed ordering
and real overlap at both 64-bit readable and 32-bit compact profiles. Native
resource fixtures pass release, reset, state-isolation and accidental
unsharing controls at both profiles. Native indexed-stack/counter models,
shared queue/set/map histories and eventual-consistency replicas also pass
both profiles and their mutations. Bound built-in capabilities exercise a
wall-anchored monotonic clock, secure bytes, recording logs and a real local
listening socket; backwards-clock, elapsed-time, duplicate-log and wrong-length
mutations are rejected at both profiles. These execution checks add no solver
or proof checker and preserve mandatory definition validation.

Both updated shared 40-suite audits pass all 107 controls per profile. Those
cohorts precede the final node-identity/report refinements, which have their
own reporting and rebuilt-package checks. The preceding shared-coverage
cohort's limitations remain historical; they no longer describe the current
scheduler. The current reference documents batching and conservative unknown
scope. Nine fixture families remain: mapped failure products, workflows,
resilience, asynchronous and handler bindings, sessions, actors, distribution
and composition. Full final-source compiler, SDK, native matrix, packaging and
human canonical review still remain required. Detailed receipts are under
`.artifacts/integration-1/prolog-batch-*`.

### Prolog workflows, processes and distributed clients — 20 October 2026

Native Prolog fixtures now cover workflow steps and real-clock overlap,
retry and jitter runtime conformance, virtual rate-limit state, compensation,
timeouts and hedging, typed session delegation, actor restart and concurrent
callers, shared handler resources and distributed clients. The distributed
clients exercise memory-network faults, real TCP and HTTP transports, mailbox
delivery, repeated channel handoff, sealed frames and shared handshake/wire
vectors. Checked definitions and history/scenario oracles retain their
existing implementation; the native steps and protocol peers are independent.

The real-clock hedge check exposed event-loop shutdown joining a losing
`asyncio.to_thread` call. Async dispatch now reuses the existing host Async
task runner, copies context variables and shields a wrapped future. Cancelling
a waiter returns without joining its still-running predicate; late exceptions
are consumed without erasing structured incomplete status. Janus's documented
`query_once` callback path supplies worker-thread engine attachment. These
changes add no solver or proof checker.

The distributed checks also exposed duplicate replies being sent after a
caller closed. Cached and original replies now share the existing treatment
of `Unreachable`; unexpected transport exceptions remain visible. A regression
checks once-only definition execution, identical cached replies, closed peers
and unexpected errors. All 26 runtime controls and ten reporting controls pass.
The initial fixture failures and thread warnings are retained separately from
the final reruns, under `.artifacts/integration-1/prolog-workflow-final/` and
the `prolog-network-*` logs. Final combined acceptance remains open.

The final six-suite rerun passes 2,063 observed native cases per profile at
64-bit readable and 32-bit compact output, rejecting all 18 mutations per
profile with no thread warnings. The original Python actor and distribution
suites also pass their mutations against the shared reply repair. All 520
complete native/WASM responses agree. The rebuilt package passes both fresh
CLI profiles and installed payments; 86 scoped SDK checks pass, with the
declared Rust embedding opt-in separately executed and passing both tests.
Independent YAML, OpenTofu, ANTLR and Make validators pass. Canon parses all
54 native fixture modules; all 126 generated outputs, 234 boundary modules,
artifact integrity and 122 documentation pages with 119 compiled snippets
pass. The full compiler regression for this checkpoint subsequently passes
2,280 examples with zero failures in 1,836.7 seconds. The following native
binding increment has separate evidence and still requires final combined
acceptance.

Mapped failure products, asynchronous constructor/method bindings and native
handler/type/exception bindings remain required. Their unsupported diagnostics
are retained; canonical-data substitutes do not satisfy those native mapping
requirements. The complete shared target matrix, compiler, SDK, editor,
packaging and canonical human review gates must pass before target sign-off.

### Native Prolog representation and call bindings — 20 October 2026

Resolved Core bindings now generate native tagged dicts, variant terms and
unit atoms, with qualified constructor identities and explicit native field
layouts. Nested record layouts preserve native argument positions. Native
constructors return retained ground handle tokens; method calls receive the
bound receiver first. A weak interner resolves hash collisions by exact term
identity and adds no strong references. Core's existing handle registry and
the application's resource operations retain their lifetime responsibilities.

Native exception mappings build their resolved typed message/product payloads,
which still pass existing schema validation. Native handler calls and explicit
capability proxies use the same conversions. Invalid fields, wrong handle
types, undeclared failures and canonical values substituted for a configured
native representation are rejected. Custom native codec hooks and coverage
instrumentation remain explicit unsupported fragments.

The three formerly missing shared suites now pass at 64-bit readable and
32-bit compact output. Each profile rejects seven mutations, including an
empty native exception message that violates its intrinsic field refinement.
All 31 runtime controls and eleven execution-reporting controls pass. Thirteen
focused SDK checks pass, including actual native nested-layout execution and
rejection controls across all four width/layout profiles. Canon parses all 59
fixture/runtime modules. Native/WASM agrees on 520 complete responses from a
focused four-fixture set and 20 additional binding-specific responses covering
all profiles, accepted interop and explicit rejections. The full corpus parity
run remains a separate requirement.

An 81 MB generated till suite exposed excessive pytest AST work when reporting
its failing mutations. Isolated runs retained the same four observed failures
with plain assertions and standard Python tracebacks, completing in 19.2
seconds; the earlier default-formatting run remained active for over fifteen
minutes and was superseded after the repaired suite passed. Its incomplete
mutation run is not counted as a pass. The repaired complete till suite,
including both mutations, passes in 88.3 seconds. Optimized Python is rejected
before execution and before CLI cache reuse; acceptance cache keys include
the relevant Python execution options. Detailed receipts are under
`.artifacts/integration-1/prolog-native-bindings-*`.

All shared fixture adapters are present. Complete final-source compiler, SDK,
native matrix, editor, packaging and canonical release checks remain required;
the earlier full compiler pass covers the preceding checkpoint. No target or
1.0 release sign-off is claimed by these scoped checks.

### Target CI graph and Canon correspondence — 20 October 2026

Fresh independent YAML, OpenTofu, ANTLR and Make acceptance passes against
the current compiler. Canon parses the same four emitted formats, and its
supported inventory agrees exactly with LawSpec's 18 program and four artifact
targets. Folio remains planned. The receipt is
`.artifacts/integration-1/target-canon-artifact-receipt.json`.

Review found that the Rust embedding check was registered for each program
target, producing 18 copies with the same step identity in the default graph.
It now belongs to Rust, follows Rust's bootstrap and claims its environment.
The worker pool rejects duplicate identities before starting any work. All
13 scheduler checks pass, including that rejection control. All 26 inspected
graph configurations have unique names and correct target ownership; the
complete default graph contains 2,738 distinct steps. These are graph checks;
execution acceptance remains a separate requirement.

The ongoing selected-target CI run retains its original 158 steps, including
the Rust check once. The corrected selected graph has 157 steps. The running
check is preserved while the new scheduler regression and graph checks verify
the correction. Full compiler, SDK, native acceptance, packaging and canonical
results remain open. Logs are under `.artifacts/integration-1/target-*`.

The packed npm smoke passes the complete 18-target example export, structural
API generation at both widths and layouts, installed JavaScript and Rust
execution, license packaging and unchanged regeneration. The full export takes
2,840.7 seconds; the complete smoke takes 3,059.1 seconds on this run.

The selected CI run exposed two model-layer harness failures before generation:
Prolog's Python setting was missing, selecting the system interpreter. The
shared harness now selects each Python-backed target's own pinned environment.
Both repaired profiles pass independent actor laws, five model checks, rejection
of the incorrect reference transition, stale-result handling, all evidence
views and empty selections. The original failure logs remain recorded. The
ongoing CI run and a final cached run over the corrected source remain required.

### ANTLR signature inputs and concrete entry points — 20 October 2026

Public generation omitted concrete generic types used only in argument
positions. ANTLR roots now include concrete inputs and results. Each root also
exports an EOF-consuming parser entry and its exact companion-schema reference
in `entryPoints`. This keeps the expected Core type explicit when generic
instances share constructor spelling and record shape. Closed natural indices
are recognized as closed, so indexed inputs receive the existing unsupported
diagnostic rather than disappearing from the grammar.

The correction follows ANTLR's generated start-rule methods and JSON Schema's
standard subschema references. Public native and WASM artifacts are rebuilt with
`tools/wasm.sh`. All 12 focused compiler checks and 13 SDK/CLI checks pass; the
same 13 SDK/CLI checks also pass against a packed and freshly installed npm
archive, with no skips. Independent generated Java parser calls, selected-schema
validation and Canon parsing pass, including overlapping UInt8/UInt16 domains,
trailing-input rejection and unsupported indexed inputs. The YAML, OpenTofu and
Make validators also pass. Generated-file and artifact fingerprints match;
documentation checks pass for 122 pages and 119 compiled snippets. Automated
canonical checks pass with the existing deferred human-review exemptions.

It adds no decoder, obligation generator, solver or proof checker. Updated full
native/WASM parity and complete final-source acceptance remain required before
merge. Logs are under `.artifacts/integration-1/target-antlr-worktree-*`.

### Shared native target matrix checkpoint — 20 October 2026

The original 158-step selected-target CI has completed all 129 scheduled native
acceptance steps: 81 default 64-bit readable suites, 46 selected 32-bit compact
variants and two 32-bit readable variants. The default suite includes indexed
and refined data, generators, bindings, handlers, state, workflows, sessions,
actors, distribution and the shared process/network fixtures. This matrix does
not run every suite in every profile. The two model-selection harness failures
and their successful replacement runs remain recorded above. The full tracked
compiler passes 2,281 examples with zero failures; this run precedes the two
additional ANTLR compiler checks, which pass separately. Per-step logs and
hashes are recorded in
`.artifacts/integration-1/target-native-matrix-initial-receipt.json`.

At this checkpoint 154 original CI steps pass and two have the recorded harness
failures. Full SDK and native/WASM parity steps are still running. Their results
and a green final combined run over the corrected source remain required. The
native matrix result does not close Folio, LawTwin's per-target conformance,
the retained demonstrations, human readability/adoption gates or 1.0 sign-off.

### SDK harness and real Make execution checkpoint — 20 October 2026

The original full SDK run completes with 364 tests: 356 pass, three fail and
five require separate Rust, Clojure or Haskell acceptance environments. Its
failure record remains intact. The arity assertion now checks Prolog's exported
13-argument predicate and its actual clause, representing twelve inputs and
one result. The runtime-placement inventory now names `lawspec_prolog.pl`.
Both complete algebra and scalar groups pass all nine tests with no skips.
The examples test's JSON output exceeded its capture buffer; the harness now
allows a bounded 16 MiB. All complete-corpus exports, independent expected-file
comparisons, adapter-preservation, edited-test protection and path checks remain
required. Their full replay is still pending. The corrections are published at
`0d18261e`; generated consumers and artifact integrity checks pass. Compiler,
runtime, public SDK/CLI implementation and parity inputs remain unchanged.

A generated Makefile also runs against a freshly installed rebuilt npm archive
and a configuration containing both Prolog and Make targets. Parallel Make
orders the real CLI's `check`, `generate` and `test` commands. Native payments
execution runs all three authored laws and passes 45 cases with no skips; the
Make artifact contributes no native test result. An incorrect native fee fails
the actual assertion with expected value 0.3 and actual value 0.4, propagating
failure through Make. An out-of-range UInt8 definition stops at `check`, before
generation or native execution. Restoring both sources passes all 45 cases
again. The installed build manifest matches the rebuilt public package.

Canon's own repository check and both target-inventory properties pass. Every
listed target has a grammar, profile, dialect and sample, and every grammar
directory belongs to a listed target. Its current inventory matches the public
18 program and four artifact targets exactly as a set, without duplicates.
Folio remains planned. The existing human-review exemptions remain in force;
human 1.0 sign-off remains open.

Updated full native/WASM parity has completed the 32-bit readable generation
phase across all 22 targets. Its other three generation profiles and final
package checks remain running. The original CI still retains its two repaired
model-selection failures and the SDK failure above. Complete updated parity and
a green corrected 157-step combined CI run remain required before the main
merge and Canon inventory push. Detailed evidence is under
`.artifacts/integration-1/target-sdk-*`, `target-make-real-cli-*`,
`target-canon-own-*` and `target-full-parity-scope.json`.

### Combined target CI preflight — 20 October 2026

The original fresh 158-step run is terminal: 155 steps pass and three retain
their historical harness failures. Complete original native/WASM parity passes
6,408 full-response comparisons over 68 fixtures, all 22 targets and all four
width/layout profiles: 5,624 responses are accepted and 784 rejected. Generation
accounts for 5,370 accepted outputs and 764 matching rejections. This cohort
precedes the isolated ANTLR input-root correction; its updated full parity run
remains required. Every original step log is preserved under
`.artifacts/integration-1/target-initial-ci-86959-logs/`, with counts and hashes
in `target-initial-ci-receipt.json`. The original run remains failed.

The parent feature branch now includes the rebuilt ANTLR correction, SDK
harness fixes and checked documentation through `b4007c99`. The combined
checkout has rebuilt native and WASM artifacts with `tools/wasm.sh`. All 22
SDK preflight checks, all four independent artifact validators and both Rust
dynamic-embedding checks pass against this rebuild; the SDK checks have no
failures or skips. Generated files and source/artifact fingerprints match.
The corrected 157-step CI run, its full SDK/examples replay and complete
updated parity must pass before the main merge and Canon inventory push.

### Five-target acceptance completed — 20 October 2026

The corrected **157-step CI passes every step** on frozen `8d57bd2b`, covering
Prolog, HCL, YAML, ANTLR and Make. Native and WASM artifacts were rebuilt with
`tools/wasm.sh`; the committed source, shipped WASM, glue and build manifest
retain their frozen fingerprints throughout acceptance. Stack's standard
test/build reconfiguration relinks the native reference executable from the
same source; its observed identities are recorded separately.

The compiler passes **2,283 examples with zero failures**. The full SDK passes
**361 of 366 tests, with zero failures or cancellations and five existing native
opt-in skips**. Its complete example test passes all 18-target exports,
independent expected-file comparisons, legacy Kotlin refresh, application
adapter preservation, edited-generated-file protection and output-path guards.
The exact shipped WASM agrees with native on **6,416 complete responses** across
68 fixtures, all 22 targets and all four width/layout profiles: 5,624 accepted
responses and 792 matching rejections, including 5,370 accepted generations and
772 rejected generations. No response fields are omitted or normalized.

All **129 configured Prolog native acceptance steps** pass: 81 default 64-bit
readable suites, 46 selected 32-bit compact variants and two 32-bit readable
variants. Both repaired model-selection profiles pass within the complete CI.
Independent YAML, OpenTofu, generated ANTLR Java parser/schema and Make checks
pass. Installed-package smoke passes the full 18-target export, structural
profiles, JavaScript execution and Rust scaffold/test/regeneration. Editor,
126 generated files, source/artifact integrity, compiler boundaries, version,
122 documentation pages with 119 compiled snippets and automated canonical
checks pass. Fresh Rust embedding opt-in checks also pass on this artifact.

Canon's matching 18-program/four-artifact inventory and its own two inventory
properties pass. The original failed CI and SDK attempts remain preserved;
the successful corrected run has its own 157 hashed step logs and receipts at
`.artifacts/integration-1/target-final-ci-7823-logs/`,
`target-final-ci-receipt.json`, `target-final-sdk-receipt.json`,
`target-final-parity-receipt.json` and `target-final-native-matrix-receipt.json`.
This completes the five-target implementation increment. Folio, LawTwin's
per-program conformance, Cassandra, the retained demonstrations, advanced
verification and human/external 1.0 gates remain open. Version 0.26.0 remains
an ordinary minor; no tag or package publication is part of this increment.

## Approved 0.26.0 contract — 19 October 2026

Implementation and technical acceptance are complete on `2444621f`, as recorded
in the final receipt below. Version 0.26.0 remains an ordinary minor version,
with technical language profile `1.0-rc.2`; that identifier is not an RC release
designation. No new tag, push or publication was performed in this iteration.
The user approved mandatory named closers for **every block**, including unit
bodies, ability `laws` groups, harness `for law` / `for laws` groups, let
expressions and generator binds. The complete 45-kind catalogue is maintained
in `src/LawSpec/Blocks.hs` and the published syntax reference. Quantifiers close
with `end for all`, `end exists` (all positive/negative wordings), and `end given`.
Handler clauses, including delegation, require `operation ... end operation`.
Closers occupy one physical line and identify the construct rather than a user
name. Punctuation-delimited products/collections keep their delimiters; branch
clauses belong to their enclosing block. Bare `end` is invalid.

The user explicitly removed pre-1.0 migration from scope and authorized deleting
its implementation: no migration command, API, compatibility grammar, snapshot
or correspondence engine ships in 0.26. Active sources and compiler-owned
libraries are converted directly. This supersedes every earlier requirement
for migration support or acceptance. Historical requirements and receipts below
remain historical evidence, not requirements to retain the deleted feature.
API schema 5 and configuration version 2 remain; ordinary consumers require the
new profile.

**Later Chapter 6 correction:** the user explicitly requested updating and
formatting the root `chap06.lawspec` as well. It now follows the maintained
canonical example, with named endings for every block. This supersedes the
earlier instruction to leave the root source unchanged. Its original bytes
remain in Git history and a local backup; the oracle harness checks that the
two active Chapter 6 entry points agree.

The corrected source compiles and formats idempotently, including through the
WASM CLI's `fmt --check`. Separate native 64-bit and compact 32-bit runs each
exercise all 23 laws: 66 examples, 16 properties, 453 boundaries and ten replay
hooks. Independent oracles cover 32,768 A-addresses, 1,792 C-instructions and
13 stateful programs with repeated-call isolation; each run rejects all six
mutation controls. The original inventory remains 65 table rows, one named
example, 25 authored definitions, seven ADTs and two refinements, including six
checked mappings. The final combined run repeats these scoped checks. They
establish Python implementation and checked-codec conformance, not all 17
Chapter 6 implementations or proofs of the unbounded program laws.

**Earlier 0.26 checkpoint, superseded by the projection fix below:** the direct
index generator did not solve through intervening records; record payloads
retained their index predicates and constructor guards through ordinary checked
generation and shrinking. Native conformance subsequently found that filtering
could exhaust its attempts for inhabited fixed-size stacks.

The implementation extends the existing index-generation plan through closed
structural products. Each intermediate product receives a projection equation
in the generation plan; authoritative typed schemas, constructor guards,
dependent predicates and shrinking restrictions remain intact. This traverses
multiple structural layers without unwrapping nominal types. Different index
projections of the same product, multiple independently indexed projections
within one payload, and multi-index families still use checked generation;
the single-index planner does not conflate them. A bounded miss remains
incomplete evidence. Focused compiler tests pass, and Scala replays the original
failure seed with all 579 collection tests passing. The final fresh combined
run below also passes with this projection plan.

Kotlin scaffolds set `kotlin.daemon.jvmargs=-Xmx2g`, using the
[documented compiler-daemon heap setting](https://kotlinlang.org/docs/gradle-compilation-and-caches.html).
This accommodates complete generated boundary suites without reducing their
case counts. The native indexed suite executes all 4,335 tests with that setting;
its ten mutation controls also fail at runtime as required. The corresponding
Go indexed suite and all ten mutation controls pass as well.

Native conformance also exposed JVM class-size limits in large handler suites.
Java, Kotlin and Scala share assertion bodies from 64 cases onward, preserving
individual setup, input checks, failure context and discovery. Scala registration
traits share the same suite instance and global ordering queue; the random-order,
parallel and repeated-run harness suite passes all seven mutation controls.
Groovy retains a Java execution body for suites with at least 512 independent
tests as well as deeply nested callbacks. The corrected handler suites compile
in Scala, Java, Kotlin, Groovy and Clojure, each retaining all 8,004 boundary
cases. Java handler-map factories specify `String, Object` explicitly so
Groovy's static checker preserves the same interface types. The final fresh
acceptance graph covers the combined changes and their native controls.

A later native check found that closed record initializers in dynamic handlers
mapped distinct Core binders to one `_unbound` name. The seven affected renderer
call sites now use the existing unique Core-to-native name mapping. A new
heterogeneous record initializer retains `count = 3` and `factor = 2.5` as
independent values. The old JavaScript emitter passes 36 cases and fails this
new case; the corrected emitter passes it. Typed-model evaluation remains
separate from native implementation conformance.

The scalar conformance generator now emits canonical phrase names, `definition:`
sections, explicit quantifier endings and a unit ending after all generated laws.
All 57 independent scalar vectors remain unchanged. Recorded native stubs were
reviewed against the canonical `Integer` result; compatible native big-integer
implementations remain, with explicit exact wrappers where Rust and Haskell
require them. The native scalar suites and their mutation controls are checked
for all 17 targets.

Mutation expectations now distinguish selected compile-time law refutations
from native failures. The changed even-number definition must be refuted at
`n = 3`, and the changed UTF-8 byte-count clause at `n = 0`, with diagnostic
`refuted` and the original law name. Native resource and reusable-law controls
retain their required failure context with current test names and quoted phrase
names. No verification layer or intrinsic definition check is disabled by these
fixture corrections.

Large Haskell suites now share boundary setup and assertions while retaining
independent registrations, checked inputs, fresh symbol contexts and per-case
handler/resource execution. Literal factories receive the case's symbol context.
The handler suite shrinks from 63,454,955 to 2,924,151 source bytes; all 8,004
boundary names and their order remain unchanged. The native suite passes all
8,012 tests, and both handler mutation controls fail natively.

BEAM generation retains the selected property layer in its execution plan.
Explicit harness strategies supply requested observations alongside complete
finite cases when property testing is selected; deterministic cases never count
as random observations. An unused fallback strategy is not invoked for an
already exhaustive law without observations or targeting.
Exhaustive-only selection and empty domains do not request random trials.
For a known-failing law, these strategy trials precede deterministic checks so
an expected logical failure cannot conceal broken coverage or an invalid
strategy. Three compiler selection regressions and the native targeted-search,
repetition and known-failure suites pass across Erlang, Elixir and Gleam.
The final combined run also passes all six installed BEAM harness CLI checks,
including both integer profiles.

BEAM native codecs and failure fixtures construct alternatives with one explicit
record payload. The Erlang recursive-chain binding specifies native argument
positions independently of canonical record ordering, preserving its existing
adapter representation. Native failure controls accept the current framework
test identities while retaining required failure causes.

Later indexed conformance found that Java's index-guided draws used an entry
point that refuses schemas with constructor contracts. Java now routes guided
draws through the same checked result and bounded rejection mechanism as its
ordinary draws; Rust likewise retains checked results for guided generation.
Dependent index expressions are evaluated once before borrowing Rust's context
for validation. Native regressions check that shrinking preserves constructor
restrictions and that predicate evaluation errors reach the property rather
than becoming rejected candidates. These repairs preserve the schema's guards,
the generator's index equations and the declared input domains. The Groovy
collection adapter also uses the canonical `Integer` result signature shared
with Java while retaining exact big-integer counts. All four affected indexed
suites pass their positive tests and all ten mutation controls in both profiles;
the Groovy collection suite passes its positive tests and all five controls.

### Final 0.26.0 technical acceptance — 20 October 2026

The fresh combined run executes the code at
`2444621f02c1c6ecdcf27846870730b11530b1ee`, now on local `main`.
All **2,593 checks pass**, with zero failures or interrupted checks. The run
uses `--fresh --jobs 8`, including refreshed native acceptance suites; it does
not substitute earlier component receipts for current execution. All 6,462
tracked input files and modes remain unchanged throughout the run. Before this
documentation-only update, all main input bytes and modes matched that frozen
checkout. This update records the result without changing the validated
compiler or package payload.

| Gate | Executed result |
| --- | --- |
| Compiler and intrinsic guarantees | 2,253 examples, zero failures. Definition validation, refinements, GADT facts, checked recursion and deliberately deferred runtime contracts remain independent of optional law verification. |
| Targets and public interfaces | The complete 17-target graph passes, including its configured 32-bit and compact profiles, native controls, editor consumers, API schema 5, configuration version 2 and profile `1.0-rc.2`. |
| SDK | The unfiltered suite reports 337 tests: 333 passed, zero failed, four declared opt-in skips. All four skipped native layout/failure checks are separately executed on the same compiler: four passed, zero failed or skipped. |
| Native/WASM parity | Passes on the final compiler and its native build. |
| Chapter 6 | Both 64-bit and compact 32-bit WASM/Python profiles pass all 32,768 A-addresses, 1,792 C-instructions and 13 stateful programs, including repeated-invocation isolation and all six mutation controls. Each exercises 23 laws through 66 examples, 16 properties, 453 boundaries and ten replay hooks. |
| Source and formatting | Both active Chapter 6 sources are byte-identical and use the current named endings. Formatting is idempotent and preserves the nontrivia token stream; the 23 laws, 65 table rows, one named example, 25 definitions, six mappings, seven ADTs and two refinements remain. |
| Documentation and tooling | Published documentation, stable-code rejection examples, Canon, editor checks, boundaries, version checks and all 121 generated files pass. |
| Installed package | The CLI/API smoke test, complete example export, structural target checks and Rust scaffold/test/regeneration flow pass. All 197 packed regular files and modes match the frozen source inputs. |
| Release preconditions | The complete read-only `make release-check` passes on clean local `main`. No tag or publication is created. |

The validated WASM is 69,542,732 bytes, SHA-256
`d2b1e801de144f41badc4688b51b54112a0b3a050c33c1f959832c6a843d7264`.
The installed-test archive has SHA-256
`94b6651a65d9b28957be48557211ce9d150131dfe3f4b4d6dadd66e752f9f62b`.
Both Chapter 6 entry points have SHA-256
`3784ed8431ffa4a1937e0d6f5f206747f30f60c9ae78c44b433fd1133c5a57b1`.

Local execution evidence is retained under `.artifacts/blocks-026/`:
`ci-final-14-receipt.json`, the before/after input snapshots, the immutable
2,593-log archive and index, `package-14-frozen-input-comparison.json`,
`chapter6-final-ci14-oracles.json` and the four current SDK opt-in results.
Earlier failures and superseded runs retain their own identities and logs;
they are not relabelled as successful final runs.

The human readership exercise remains explicitly user-deferred. The larger
pre-final-1.0 portfolio, all-17-language Chapter 6 implementation programme,
advanced verification and external Linguist recognition remain open. This
technical minor-version acceptance does not imply final 1.0 acceptance or an
RC designation.

## Historical 0.25.0 completion checklist — 19 October 2026

Validated project migration writes and the first canonical Chapter 6 pass shipped at `98c5cf79`. The complete current-minor implementation is accepted on `891f8bb1`, with its execution scope and retained limits recorded below. Earlier increments retain their own source identities and evidence.

- [x] Verify scoped collection-provider discovery and ordered-set migration, including complete source correspondence, all 17 configured target emissions, native/WASM parity and regression checks. Opaque dependency fields retain conservative discovery.
- [x] Account for all six migration acceptance boundaries with supported-path and actual refusal tests. Unsupported abstract/indexed/existential forms, unbounded generic populations and changed opaque hooks remain explicit limits; missing correspondence still blocks writes. The final full-run gate also passes.
- [x] Complete the schema-5/configuration-2/profile cutover for ordinary public interfaces, with older source and interfaces entering through migration. Ordinary requests require schema 5 and the canonical profile; configuration requires version 2. Archived source uses explicit migration entry points. Installed consumers and all 34 native-interface profiles pass.
- [x] Finish Chapter 6's second authoring pass and audit the required language, demonstration, editor and documentation coverage against this contract. The authored inventory, both-profile instruction oracles, published snippets, stable-code rejection controls, editor/SDK checks and full target graph pass.
- [x] Deliver authored expected compile-rejection examples checked by stable diagnostic codes. Independently checked `reject=<code>` documentation fixtures, exact diagnostic matching and editable rejection views are implemented and verified below.
- [x] Run the final compiler, target, generation, boundary, editor, documentation, parity and complete read-only release checks on the final implementation; record failures and limits. The fresh 2,593-step graph passes, with all tracked inputs unchanged throughout execution. Earlier failures and interrupted runs remain separate historical receipts.

The human readability exercise remains user-deferred. Completing all named endings belongs to the immediately following minor. The larger demonstration portfolio, advanced verification and external Linguist acceptance remain pre-final-1.0 requirements. None of these statuses authorizes an RC designation or a tag.

The dated implementation receipts below preserve historical statuses. The
final receipt supersedes their pending execution gates without relabelling old
runs. The product-storage increment still supersedes the `Nat` preservation
limit recorded at `9b76bd54`. The current checklist and explicit deferrals above
are authoritative for this minor; the larger pre-final-1.0 programme stays open.

### Final 0.25.0 authoring acceptance — 19 October 2026

The complete production `lawspec-dev ci --fresh --jobs 6` graph passes on
`891f8bb17c6bff6a2861c508771a91ea6845a306`: **2,593 steps, zero failures,
110 registered manifests, all 17 targets**. The supervisor exits zero and
independently confirms that all **6,529 tracked inputs** stayed unchanged.
Every terminal step log is hashed and archived. The graph includes 2,421
native-conformance steps, five explicitly expected native-architecture
refusals and 167 other gates; an expected refusal is not native execution.

| Gate | Actual current-run result |
|---|---|
| Compiler and automatic guarantees | 2,252 tests pass, with zero failures or pending tests. Mandatory definition checking, refinements, GADT facts, checked recursion and deferred runtime postconditions remain outside optional law-layer selection. |
| Public SDK | 513 tests pass; four declared Rust/Clojure/Haskell native opt-ins execute separately, each with one pass and zero skips. The current suite includes actual Z3 invocation, compiler-backed UTF-16 LSP diagnostics, formatting, migration writes, explanations and catalog export. |
| Installed package | Actual pack/install/smoke succeeds. All 206 regular archive files match frozen package inputs or their declared root prepack sources. Canonical initialization defaults to no law layers; native smoke explicitly selects its checks. |
| Installed native interfaces | All 34 profiles pass: 17 targets at normal 64-bit and compact 32-bit settings. Each checks native execution, a failing fee mutation, selective invalidation/replay and preserved application files. |
| Native model-layer selection | All 34 profiles pass with independently selected actor laws and model checks, wrong-reference rejection, stale/failure/repaired evidence, honest zero-selected-check reporting and shared evidence in all four views. Native search completeness remains `not-established`; JavaScript additionally checks interruption and flaky replay. |
| Native/WASM parity | 4,777 complete JSON responses match: 4,427 accepted and 350 rejected; generation accounts for 4,301 accepted and 340 rejected responses. Required nonempty codec generation covers all 17 targets, both widths and both layouts, with canonical package generation also checked. |
| Documentation and editor | 120 pages, 119 compiled snippets, resolved links, shared TextMate grammar and actual LSP/SDK consumer checks pass. Fourteen independent documentation controls cover three authored stable-code rejection fixtures. No human comprehension result or visual editor inspection is inferred. |
| Business conformance | Refund/order checks pass all 34 target profiles and reject 308 mutants: 272 specification and 36 native-adapter mutations. These are scoped implementation-conformance results. |
| Chapter 6 | Both normal 64-bit and compact 32-bit Python/native oracle runs check all 32,768 A-addresses, 1,792 C-combinations, 13 stateful programs, independent repeated invocations and six meaningful mutants per profile. The inventory remains 23 laws, 65 table rows, one named example, 25 authored definitions, seven ADTs and two refinements, plus six checked mappings. The original `chap06.lawspec` bytes remain unchanged. |

The fresh Swift harness passes in 16.6 seconds. Its correct adapter passes;
discount, rounding, cover and outside controls fail natively; declares,
interfering and unshared are explicitly expected generation refusals. The
repaired discount mutant reports `EquationFailed`, actual false and expected
true, at `Order(0, 0)` with seed `6219572487513710363`, without an overflow
trap. Separate original-seed/zero-seed repair replays retain their own
both-profile provenance. The earlier failed full run remains archived.

The package tarball SHA-256 is
`38602a07fb2eefc4ac3778e417b73906e4000edc5b4925aa379a7887b271d731`.
The native compiler is
`0a8e436f8fb9d8149468124755aecba24d4b6df42e6336483d3cf57842378fdd`;
the 73,195,567-byte WASM is
`79d6019410f0fdc5412b88973a16dc2ccf409bc9474a581a49f8ec0920ad32f4`.
Receipts, complete logs, package inspection and requirement/source audits are
under `.artifacts/minor-final-swift-mutant-acceptance/`. Earlier portable hash,
solver-precedent and migration receipts keep their original execution
identities; unchanged source correspondence and the new whole-graph results
are recorded separately.

The final coverage audit checks the 34-row contract inventory, actual test
registration, critical assertion bodies, complete current execution and
requirement-specific receipts. The 32 current-minor rows have completed
execution coverage. The six migration boundaries retain their documented
supported paths and conservative write refusals. Optional reachability
warnings remain explicitly incomplete. Proof execution uses external Z3 via
typed SMT-LIB tasks; no independent proof kernel or in-process Z3 binding is
claimed. Generation, native conformance, bounded evidence and universal
proof remain distinct.

Read-only `make release-check` passes on clean main: version 0.25.0 agrees
and all 146 generated files match. An independent registry probe receives
HTTP 200 for the package, finds no 0.25.0 entry, and receives HTTP 404 for
that exact version. Local and remote `v0.25.0` tags are absent. This review-only
closeout preserves the execution candidate's compiler, runtime, package and
test inputs; it does not relabel the full run as a different source execution.
No tag or publication is performed.

**Retained gates:** human readability remains user-deferred; banning every
bare `end` belongs to the immediately following minor. Chapter 6
implementations/verification in all 17 languages, Projects 7–8 and 10–11 in
the seven selected languages, the testable Jack Snake and complete Jack OS
API, the selected library demonstrations, broader solver/conflict/temporal
verification and upstream Linguist recognition all remain **pre-final-1.0**.
Completing this minor does not authorize an RC designation or final 1.0.

### Swift harness discount mutant — 18 October 2026

The fresh full acceptance run on `6801c9ec` found a real failure in
`swift-harness`. Correct adapters passed, but the discount mutant added one
to an `Int32` total. The generated maximum boundary caused a native overflow
trap before the required discount-law diagnostic. The acceptance harness
correctly rejected that result; it was not a completed law counterexample.

The mutant now returns one for a zero total and the total otherwise. It stays
within `Int32` and violates the discount law on the deterministic zero-total
boundary. Compiler semantics, generators, native adapters and the strict
diagnostic requirement are unchanged.

The original seed, `10144252326957008458`, reproduces the old failure with
acceptance caching disabled. A separate native Swift probe confirms signal 5
for the original maximum-input addition. The repaired full harness passes at
64-bit normal and 32-bit compact profiles, with both the original seed and
seed zero. Correct adapters pass and all seven negative controls are rejected
in each invocation; the discount mutant reports `EquationFailed` with actual
false and expected true, without a native process trap. Receipts are under
`.artifacts/swift-harness-mutation/` in the isolated repair worktree.

These are scoped repair results. The failed run's receipts are preserved;
fresh combined acceptance remains required. Version 0.25.0 remains an
unpublished minor, without an RC designation, tag or publication.

### Short-circuit proof branch repair — 18 October 2026

The final acceptance run exposed exponential work in definition-contract result
analysis for the existing built-in Clock suite. A left-associated conjunction
of twenty temporal checks enumerated both outcomes again after an earlier
prefix had already returned literal `false`. Those continuation paths cannot
execute. Disjunction had the corresponding literal-`true` case.

Result analysis now applies the same conservative Boolean-literal test already
used for condition paths. It retains both paths for an unknown condition and
selects the reachable arm for a literal conditional. Strict body auditing,
callee preconditions, branch-local guarantees, termination, refinement checks
and deferred runtime postconditions remain in place. This is a correction to
the existing checker, with no additional solver or proof-checking backend.
The precedent is Why3's documented [lazy Boolean evaluation and evaluation
order](https://why3.org/doc/syntaxref.html#evaluation-order) and SPARK's separate
[contract truth and runtime-safety obligations](https://docs.adacore.com/spark2014-docs/html/ug/en/source/subprogram_contracts.html).

The isolated `d38cc177` regression generates the unchanged twenty-check fixture
through the real migration API in 6.6 seconds. All six production
`beam-builtin-context` native profiles pass with acceptance caches disabled:
Elixir, Erlang and Gleam at 64-bit readable and 32-bit compact output, including
stub/public-adapter rejection checks. Additional regressions preserve both
reachable Boolean outcomes, their scoped facts, invalid-contract rejection and
selected postcondition-arm definedness. The first conditional-representation
experiment did not fix the regression and has been removed. The original
full-run receipts remain attached to their own immutable snapshot; the full
compiler suite and combined final-snapshot acceptance are still required.

The superseded `e3d77b95` run preserves 2,367 passed steps, six interrupted
built-in-context steps and 220 steps not executed. Its inputs stayed unchanged.
It was stopped only after the concrete repair passed the original regression,
scoped semantic checks and all six affected native profiles. Interruption does
not count as a completed verification result. The combined native/WASM package
build succeeds; full acceptance of the combined candidate remains open.

### Minor-version preparation — 18 October 2026

Version **0.25.0** is prepared for the authoring milestone, without an RC
designation, tag or publication. Package/Cabal/WASM/Rust versions and the CLI
agree. The registry preflight reports no 0.25.0 version; this is a read-only
check, not a publication. The technical language profile remains `1.0-rc.1`,
API schema remains 5, configuration remains 2, and migration still starts from
0.24. Historical 0.24 documentation links remain on their actual released tag.

Both native and WASM package builds pass with the new version. The native
compiler is SHA-256
`7341f05eb33084d33d534a55ce0a0eab7ba527c1553f7d1d11012c78c6b99216`;
the 72,964,848-byte WASM is SHA-256
`f6ffdf78293954693165577903400b5150a1cb9a0d20e9f8e6625687e98272f6`.
Version checks, all 137 generated-file checks, source/artifact fingerprint
recording and documentation checks for 120 pages/118 compiled snippets pass.
These preflights do not substitute for final regression or native execution.

The public-documentation audit found stale inline function syntax, obsolete
source number names and setup instructions that assumed law verification was
selected by default. The guides now use canonical function/Integer/Whole/Nat
forms and the unpublished checkout, and explicitly select property/examples
when teaching test execution. Native type names such as Rust's BigInt remain
native names. The collections reference previously combined an Eq-based
canonical introduction with a long ordered-Set historical reference. It now
consistently names SortedSet for keyed/sorted behavior and native ordered-set
representations, and distinguishes Set's Eq requirements, storage order and
IEEE behavior. Historical source remains available through the released
0.24 documentation and this review's labeled history.

Release instructions now cover all 17 targets, agree on the prepared version,
and run release preconditions after the version is bumped and committed.
Fresh final CI, installed consumers, native target checks, package inspection
and the complete release check remain open. The user deferred readability;
all-named closers remain the following minor, and pre-final-1.0 gates remain
unchanged. No final acceptance or tag is claimed.

The preceding formatter-block snapshot's catalog export has also completed:
one test passes in **6,356,647.629583 ms** (total **6,356,818.63325 ms**), with
zero failures or skips. Independent auditing confirms all **273 frozen package
files** retain their recorded hashes. This closes that frozen snapshot's run,
not the current 0.25.0 package gate.

### Final validation progress and Canon reconciliation — 18 October 2026

The initial fresh all-17-target CI run uses the immutable `20f90b30` candidate.
Its completed actual compiler suite passes in 1,004.1 seconds. Stack suppresses the
successful suite's individual results; a separate dry-run inventory lists
2,223 tests and is not counted as test execution. The installed-package smoke
check passes in 1,853.1 seconds, including all bundled exports, all 17 structural
generation targets at both widths/layouts, and native Rust scaffold execution.
Its archive matches the independently inspected 202-file package, SHA-256
`19a3fa4d4e6915b859c3c4c2ec6c16a5e06d5e53d3bd5ec6b0eba2d819c0dd70`.
Release preconditions also pass; they do not replace the complete CI gate.

Both fresh Chapter 6 oracle profiles pass: 64-bit readable and 32-bit compact.
Each exercises all 32,768 A addresses, 1,792 C combinations, 13 stateful programs,
independent repeated invocations and six meaningful mutants. Each runs 545
generated checks. The authored inventory remains 23 laws, 65 table rows, one
named example, 25 definitions, seven ADTs and two refinements. Separate canonical
native/WASM parity matches 303 complete responses, including 221 accepted
generation requests across all 17 targets and both widths/layouts. These are
Python native-conformance and compiler/generation results; Chapter 6 native
implementations in the other languages remain pre-final-1.0 work.

The CI `canon` step exited zero because Canon was unavailable and explicitly
skipped checking. It is not counted as a Canon pass. A real Canon 0.2.2 run
found six stale pending entries, two incorrect `REQ-harness` links and a parser
failure at a list-comprehension boundary. The cleanup removes only those six
pending entries, corrects the links to `REQ-harness-units`, and parenthesizes the
existing case expression without changing its body. No human verdict is
introduced, changed or removed. A fresh stable whole-project Canon check passes
with 15,131 informational findings under the existing pre-1.0 exemptions and
zero non-informational findings. The exemptions do not discharge human vetting.
The cleanup passes both compiler builds, 25 focused WASM migration transport
tests, all 137 generated-file checks, the 236-module boundary check, version and
source/artifact integrity checks, documentation for 120 pages/118 compiled
snippets, and all 14 rejection-example controls. Complete old-native,
rebuilt-native and rebuilt-WASM responses match for 78 requests, including 68
accepted generation profiles across all 17 targets, both widths and layouts,
and positive/changed-body migration transport. Every complete response and its
stored hash is independently audited; nothing is stripped from comparisons.
An initial comparison harness incorrectly selected law layers on migration
requests; the API correctly rejected them, and the corrected full run passes.

The rebuilt native compiler is SHA-256
`78ea3167c695d36144d22259ba53658d88f641a95c2a9b971ee88d9891d9d025`;
the 72,964,880-byte WASM is SHA-256
`b450073873d2fc588e2a666fecbfc5839c7fb6cf48e509e01d97cc9cdca66158`.
The independently inspected 202-file archive is SHA-256
`2969487f4fd596b8c3c38359b505b2ab07b0c7b615af3c325b168b72859570e1`.
Only its WASM and build-fingerprint manifest differ from the preceding inspected
package. Its full installed-package and complete CI gates remain open.

The committed cleanup supersedes the initial candidate for final acceptance;
its unfinished CI will be stopped deliberately and the entire fresh gate run
on the cleanup with nine workers. Completed initial-candidate receipts remain
scoped to `20f90b30`; partial or interrupted steps are not passes. Evidence is
under `.artifacts/canon-reconciliation/`
in its isolated worktree and `.artifacts/minor-release-preparation/` in the
preceding candidate worktree.

The initial candidate is deliberately stopped after 183 completed steps;
its interrupted parity/SDK steps are not completed passes. The standalone
cleanup compiler run and package smoke are also superseded by their required
steps in the complete committed-candidate CI. The first replacement attempt
cannot acquire the environment lock: three orphaned .NET MSBuild servers
inherited its descriptor from the initial run. That attempt executes no gates.
Only those three verified orphan lock holders are terminated. The CI runner now
closes unrelated descriptors when creating a step, preserving its explicit
standard-input/output/error pipes. A behavioral probe compiles the actual
runner function with an export-only test shim: the original child inherits the
held lock as descriptor 3 and fails; the corrected child inherits none and
passes. The development executable rebuild passes. This change affects only
the CI runner; the language compiler, WASM, SDK and package bytes stay unchanged.
The complete nine-worker fresh CI remains required after committing this fix.

The earlier frozen scenario-formatter snapshot's full SDK run has finished:
506 tests, 502 passes, zero failures/cancellations, four explicit native
environment skips, in 6,541,329.638083 ms. The export test takes
6,540,849.464625 ms. This is the earlier 0.24 snapshot's result, not the final
0.25 package result. The skipped checks cover Rust/Clojure mapped failures and
Rust/Haskell native layouts; they do not count as native-conformance passes.

Final acceptance remains open. Readability stays user-deferred, all-named
endings belong to the following minor, and the larger portfolio, advanced
verification and upstream Linguist gates remain pre-final-1.0. Version 0.25.0
remains an unpublished minor without an RC designation or tag.

### Native suite registration coverage — 18 October 2026

The final coverage audit found that `minor-typed-mappings` had earlier native
receipts but was absent from the automated CI matrix. It now runs on all 17
targets at 64-bit readable and 32-bit compact output, adding 34 checks. The
inventory also found the older `beam-status` suite absent; its known-failure,
skip, strategy and coverage regressions now run on Erlang, Elixir and Gleam at
both profiles, adding six checks. All 107 acceptance suite manifests now have
registered native targets. The default CI graph contains 2,491 steps.

An executable extraction of the actual old/new CI plans verifies that removing
only these 40 added entries reproduces every existing target command,
environment and order exactly. All 5,847 compared compiler, runtime, SDK,
template, acceptance, fixture, example and package-source files match the
immutable `04c4eb22` candidate. The development executable builds; compiler and
package bytes are unchanged. Initial direct-build probes omitted the precise
Vector package exposure; the corrected build uses the installed package ID.

Separate current-artifact native/WASM parity passes 303 complete responses,
including 221 accepted generation requests and the typed-mapping fixture on
all 17 targets at both widths/layouts. The 72 intentional rejections are counted
separately. This is compiler/generation parity; native execution remains the
pending supplement's responsibility.

The current fresh 2,451-step run continues on `04c4eb22`. A separate native
supplement uses the existing acceptance harness with cache refresh, waits for
that run's environment lock, and requires its successful completion first.
Acceptance requires both that complete result and all 40 added native results;
the additional checks remain pending. Evidence is under
`.artifacts/ci-mapping-coverage/` in its isolated worktree. This registration
change does not alter law verification, definition checking or language
semantics. Readability stays deferred, all-named endings belong to the following
minor, and the larger pre-final-1.0 gates remain open. No tag or publication is
authorized by these checks.

### Installed authoring commands and current CLI documentation — 18 October 2026

The current 202-file archive, SHA-256
`2969487f4fd596b8c3c38359b505b2ab07b0c7b615af3c325b168b72859570e1`,
passes its fresh installed-package CI check in 1,738.8 seconds. Its CLI/API,
bundled exports, all-17-target structural generation, native JavaScript tests
and native Rust scaffold/adapter tests execute successfully. Independent archive
inspection confirms that its artifacts match the current sources and package.

A separate installation of that exact archive passes the four authoring
commands outside the checkout. Migration's default report preserves source and
configuration; validated writing produces configuration 2, the explicit profile
and the six selections preserving legacy behavior. This source-only project
does not establish target/native conformance or law truth through migration.
Formatting rejects the deliberately unformatted file under `--check`, then
formats idempotently while preserving its complete typed migration snapshot,
Unicode comment and literal marker. All four explanation JSON views retain the
same typed assertion. The actual installed LSP handles split UTF-8 stdio frames,
advertises UTF-16 positions, returns outlines and formats unsaved text without
changing the file. Existing compiler/editor tests cover position conversion.

The initial explanation probe assumed an ordinary name for a migrated phrase
law; the compiler's returned name selects it correctly. The exact documented
shell-quoted selector also passes installed `explain` and `evidence` commands.
The CLI reference and CI guide now use canonical selectors, describe all four
views and their JSON records, select native checks explicitly, distinguish
planned/unverified from completed evidence, and use `lawspec test` to record
native results. They remove a stale example that called planned checks
`PROPERTY TESTED`. Evidence is under `.artifacts/ci-mapping-coverage/` and
`.artifacts/cli-authoring-docs/` in their respective isolated worktrees.

The full CI continues. It has exposed obsolete replay-source grammar and a
missing language profile in the Rust layout consumer; those consumer repairs
remain required. The 40 added native checks also remain pending. Neither this
installed-interface result nor release preconditions close final acceptance.
Readability remains user-deferred, all-named endings belong to the following
minor, and pre-final-1.0 gates stay open. No tag or publication is implied.

### Canonical integration consumers — implementation under verification

The immutable `04c4eb22` fresh run exposed 26 failures in five integration
consumers: Rust custom layout, JavaScript/BEAM multi-project replay, and BEAM
crypto, models and harnesses at both profiles. These helpers still submitted
archived syntax to ordinary canonical entry points, omitted the explicit
profile, or inherited the new empty verification selection. The run continues
to collect the complete result; failed consumers are not counted as passes.

Rust's archived layout fixture now enters through `migrationBaseline` with
generation explicitly requested. Replay authors canonical laws and explicitly
selects property/examples checks. The three BEAM consumers use checked canonical
fixtures and explicitly preserve their six prior law layers. The harness fixture
manifest accounts for every source in the original nine suite manifests.
Canonical model adapters and pop mutants use the compiler-resolved structural
record payload, including its field order. Legacy acceptance sources and adapters
remain available through their existing explicit legacy path.

The 23 new fixture files include fifteen specifications, twelve of which retain
their original harness-source identities. These are explicit canonical fixture
ports, not automatic validated project migrations. In particular, the model and
harness migration previews still have unestablished source-template or domain
correspondence; their writers remain blocked. Fixture adoption does not remove
those migration limits or establish native implementation conformance.

All eighteen complete BEAM generation responses agree between native and WASM
compilers: three consumers, three targets and both profiles. Their expected
slots remain eighteen model checks, nineteen crypto checks, and thirty-nine
harness checks plus eight benchmarks. Three complete typed formatting snapshots
are preserved and formatting is idempotent. All three canonical pop-mutant
anchors match their adapter exactly once. Another ten complete native/WASM
responses agree for Rust's explicit migration baseline and replay's four targets
at both profiles. An initial private Rust assertion incorrectly counted nested
examples as separate law slots; the corrected audit retains four slots.

Real Rust Cargo execution passes with custom source/test roots, doctor checks,
literal path preservation and regeneration ownership checks. The installed
JavaScript replay check passes independent project caches, reports, failing seed
and input retention, repair replay and target removal/readdition. Its first run
exposed a stale assertion conflating a test identity containing `::law::` with
the recorded source law name; both identities now have explicit assertions.
The isolated 64-bit readable Erlang model integration also passes actual native
selection/JUnit, unchanged caching, pop-mutant rejection, failed-seed replay
and cache invalidation. Other BEAM native executions and the complete repaired
CI gate remain pending.

No compiler, runtime, WASM, SDK or package-source bytes change in this increment.
The generated-file, 236-module boundary, artifact-integrity and version checks
pass, along with documentation for 120 pages/118 compiled snippets and the real
Canon check under its existing pre-1.0 exemptions. Evidence is under
`.artifacts/canonical-integration-consumers/` in its
isolated worktree. The complete 2,491-step graph, including the forty newly
registered checks, remains required as a fresh final-candidate run under the
repository's release workflow. The ordinary CI cache remains available for
development, but does not replace that final fresh gate. Final acceptance is
still open. Readability remains
user-deferred, all-named endings remain the following minor, and no tag,
publication or release-candidate designation is claimed.

### Explicit native harness generation profile — 18 October 2026

Actual Erlang execution exposed a further fixture assumption: canonical range
analysis can enumerate the 1,001-value integer domains used by sampling/search
tests. With the default exhaustive limit, those tests reached exhaustive native
checks and then correctly failed their sampling-only coverage requirements with
zero generated observations. The consumer now explicitly sets 100 generated
cases and an exhaustive limit of 256, retaining the existing attempt/shrink
limits. Five sampling/search laws must have sampled plans, while the Boolean
repetition law must retain a finite plan. No coverage assertion or negative
native check was removed, and compiler/runtime behavior is unchanged.

The corrected eighteen complete native/WASM BEAM responses agree at both
profiles, with unchanged test/benchmark slot counts and preserved typed
formatting snapshots. Actual 64-bit readable harness runs pass on Erlang and
Elixir, including all thirty-nine law slots, skip/known-failure handling, flaky
retries, repeated coverage/search, parallel selection, exact benchmark callback
counts, recording failures/updates, resource-owner timeout/cleanup failures,
JUnit and restored reruns. The earlier Erlang failure remains in the receipts.
The isolated 64-bit model runs also pass on all three BEAM targets, including
native discovery, selection, caching, JUnit, pop mutation and seed replay.
Erlang's installed crypto run passes the native C/NIF build, vector/coverage
checks and all three mutants with automatic replay after repair.

Evidence remains under `.artifacts/canonical-integration-consumers/`. Other
profiles and the complete fresh 2,491-step final-candidate run remain required.
The current immutable run is allowed to finish; its completed receipts retain
their original scope. No tag, publication or RC designation is implied.

### Completion audit corrections and Unicode authoring — 18 October 2026

The requirement-by-requirement audit found that the earlier coverage inventory
overstated two implementation claims: pinned full Unicode case folding and the
finished picture/filename examples 48–50. The existing substring operations,
tuple/record machinery and eight nesting demonstrations did not establish those
requirements. They remain part of this minor, rather than being deferred to
the larger pre-final-1.0 portfolio.

The isolated `minor-unicode-filename-authoring` increment now implements
`prelude.caseFold` from the unmodified Unicode 17.0.0 `CaseFolding.txt` C/F
mappings. The pinned SHA-256 is
`ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183`.
The generator checks that digest and all 1,585 entries. S and Turkic T overrides
are excluded; unlisted code points remain unchanged. The Unicode license is
retained in the repository and npm package. This follows the
[upstream full default mapping specification](https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt).

The implementation produces ordinary checked definitions over portable text
slicing, ordering and concatenation. Halving a positive span uses the existing
integer-descent termination check and keeps traversal stack depth logarithmic.
Small balanced lookup functions avoid JVM method-size limits. There is no host
lowercasing, normalization, word segmentation or second
execution/proof engine. The upstream data, source generator, existing compiler
admission and runtime text operations remain the trust boundary. Native and
WASM compilation must independently agree on complete responses before this
increment is accepted.

The decreasing-measure precedent is
[SPARK's subprogram termination variants](https://docs.adacore.com/spark2014-docs/html/ug/en/source/how_to_write_subprogram_contracts.html#subprogram-termination)
and [Lean's well-founded recursive definitions](https://lean-lang.org/doc/reference/latest/Definitions/Recursive-Definitions/).
For the recursive branch, `count > 1` establishes a nonnegative, strictly
smaller `quot count 2`; both calls decrease that same argument. LawSpec reuses
its existing checker for this fact. It introduces no trusted termination
annotation, skipped definition admission or new solver/proof integration.

`prelude.textContains whole fragment` is an ordinary checked function and can
be partially applied. The completed filename policy folds before matching its
three fragments and returns an explicit rejection before checking banner size.
Pictures with prohibited names remain constructible. Dedicated tuple and
anonymous-record dimension examples preserve examples 48 and 49. The new native
suite includes all official mapped code points, unmapped characters, expansions,
supplementary characters, default I, normalization-sensitive text, substring
matching and rejection priority. Three mutants remove folding, check size before
rejection, or reverse orientation. Both target profiles are registered in CI.

The initial List-based traversal passed three focused compiler tests, 116
generated JavaScript tests and 114 Java tests. Python's complete-corpus native
run then exposed a recursion-depth failure (114 tests passed, one failed).
The decreasing-span repair retains the complete corpus; its compiler and native
reruns remain required. Those earlier results are supporting receipts for their
own traversal, not passes for this repair, all 17 targets, universal laws, WASM
parity or the whole minor. Remaining target/mutant, package, formatter, editor,
documentation and release checks remain open. Evidence is under
`.artifacts/unicode-filename/`.

The subsequent decreasing-span implementation passes the native suite at all
seventeen targets in both 64-bit readable and 32-bit compact profiles, including
all three mutants. Sixteen targets use the original increment's actual native
receipts; Gleam's compiler-owned namespace admission is repaired separately at
`e332d9bf` and both Gleam profiles pass. All 38 complete native/WASM responses
match, and every generated file in all 34 target/profile projects matches the
files used by those native executions. No fields are dropped or normalized for
comparison. The rebuilt SDK's two tests pass without skips. The actual
206-file npm archive matches the staged package byte for byte and includes the
Unicode license and three new examples. Installed-package smoke remains
running; this archive audit does not claim that gate passed. The checkpoint is
pushed to main at `e332d9bf`, without a tag. The final WASM for that checkpoint
is 73,117,916 bytes, SHA-256
`aa7d9df1c55cee90f2af8b1e25a356551bf5d000ead37714806709fb0a846174`.
Evidence is under `.artifacts/unicode-target-admission/`. The complete official
mapping corpus is finite oracle coverage, and sampled properties remain
sampled properties; neither result is a proof of every universal law.

The same audit independently reproduced another missing requirement: `Int8`
implicitly widens to `Integer`, but its provably lossless widening to `Int16`
is rejected. The direct narrowing and exact-to-float probes reject correctly.
General bounded exact widening remains required within this minor; no new
narrowing, floating precision loss or nominal unwrapping is authorized.

The six failures in the earlier `ad8bfc33` CI run all completed at the recorded
macOS dark wake after 17 minutes of sleep. Each of the six original checks now
passes unchanged in an isolated rerun. Original failed receipts are retained;
this does not rewrite that run as green. All 26 repaired CLI consumers and the
compiler suite also passed in that fresh baseline run. Its other checks are
still running against immutable `ad8bfc33` sources. Readability stays deferred,
all-named endings remain the following minor, and no RC, tag or final release
acceptance is claimed.

### Exact scalar widening — 18 October 2026

The completion audit's bounded-widening gap is now implemented through the
existing typed conversion proof. Inference admits an implicit exact scalar
conversion only when the complete source domain fits the destination domain
at the selected machine width. Examples include `Int8` to `Int16`, `UInt8`
to `Int16`, and `Decimal` to `Rational`. Narrowing, signedness loss, floating
conversions, nominal unwrapping and whole-product conversion do not enter this
rule. Mandatory definition checking and checked runtime bridges remain active.

The precedent is [SPARK's proof of program integrity](https://learn.adacore.com/courses/intro-to-spark/chapters/03_Proof_Of_Program_Integrity.html),
which treats range violations as verification obligations. Here the existing
`Core.Total.safeConversionTypes` domain-containment rule discharges the simple
whole-domain obligation; the compiler does not introduce another solver or
claim SPARK certificates. That rule, elaboration and native exact-number
representations remain the trust boundary.

Eight focused compiler tests pass across both machine widths. They include
complete checking of all 256 `UInt8` inputs, all seventeen target emitters,
unsafe conversion refusals, nominal/product boundaries and division by zero
with no optional law layers selected. The six-law, nineteen-row native suite
checks signed extrema, unsigned values above the signed source maximum,
`2^53 + 1`, `2^64 - 1`, and exact decimal fractions. Three mutants change a
value, discard high bits, or require an unsafe implicit conversion. Native
execution passed JavaScript, Java, Python, TypeScript, Rust and Go at both
profiles, including all three mutants, before each profile stopped at F#.
That failure exposes the portable F# checked-argument bridge validating an
unconverted integer/decimal representation against Decimal/Rational. The
failed receipts remain authoritative; the implementation needs a repair.
Both rebuilt WASM SDK tests pass, covering admission/refusal, all seventeen
emitters and actual typed formatting snapshots. All 141 generated files,
237 boundary modules, integrity, and 120 documentation pages with 119 compiled
snippets pass. Complete response parity, the native repair and remaining target
execution, packaging and final combined regression checks remain open. Evidence
is under `.artifacts/exact-widening/`; this is not final minor acceptance.

### Numeric bridges and documentary prelude aliases — 18 October 2026

The isolated `minor-numeric-reference-boundaries` repair converts a differing
exact numeric representation through .NET's existing `Scalar.convert` before
schema validation. Core already restricts a differing checked-argument bridge
to exact numeric types; identical types retain ordinary validation. The repair
does not weaken ranges, nominal boundaries or mandatory admission. It addresses
the actual F# Decimal/Rational failures above and remains subject to native
execution, including C# consumers of the same portable bridge.

The audit also reproduced unresolved documentary links to existing public
prelude function aliases. Executable and documentary resolution now share the
same provider table for collection, matcher, text and time definitions. Links
retain the original declaration identity and source span, obey package
visibility, and search local and explicitly imported names before falling back
to the prelude. Primitive operations without a source definition do not gain
invented function targets. Wrong-kind and unresolved references remain errors;
references do not discharge obligations.

Compiler and public SDK regressions cover alias-only references, qualified and
unqualified forms, local/import shadowing, original target identities and
no-selected-checks evidence. A new identity test initially caught `setOf`
linking the legacy ordered constructor instead of `eqSetOf`; the repair applies
the same existing `canonicalCollectionValues` map as import exports. All
15 documentary compiler tests, eight exact-widening compiler tests and three
targeted WASM SDK tests now pass. Both WASM builds have captured terminal-zero
receipts and unchanged source hashes; the second build includes the identity
repair. All 141 generated outputs, 237 boundary modules, integrity, and 120
documentation pages with 119 compiled snippets pass. F# and C# each pass both
native profiles and all three mutants. Swift then exposes the same unconverted
Decimal/Rational representation failure. That failure is retained and remains
unrepaired in this increment; the remaining native targets run independently
so one failure cannot hide another. This is not final acceptance. The Unicode fixture
law title now states its actual idempotence proposition. Its full official
mapping table is retained, but previous old-title native receipts do not stand
in for a current harness run. Evidence is under
`.artifacts/numeric-reference-boundaries/`. Final combined acceptance remains
open; no RC designation, tag or publication is claimed.

### Remaining portable numeric conversions and package export — 18 October 2026

The independent remaining-target run passes Clojure, Haskell, Kotlin, Groovy
and Scala at both profiles, including all three mutants. Erlang, Elixir and
Gleam reproduce the Decimal/Rational representation failures already seen in
Swift. Their runtime validators deliberately require a matching representation;
the missing operation is in the emitted checked numeric bridge.

The isolated `minor-portable-numeric-conversions` increment applies the same
existing scalar conversion before validation in Swift and the shared BEAM
emitter. Identical types still take their original validation path. Core's
numeric admission rules, nominal boundaries and mandatory contracts do not
change. Native and WASM builds pass, as do eight focused compiler tests and
three targeted public WASM regressions. Swift, Erlang, Elixir and Gleam each
pass both native profiles and all three widening mutants. The complete
seventeen-target matrix and the rebuilt Unicode SDK corpus are still running;
these scoped results do not close them. All 141 generated outputs, 237 boundary
modules, integrity, and 120 documentation pages with 119 compiled snippets pass.
The 73,111,245-byte WASM is SHA-256
`c22ba5d19dcad25667b7e4a41e9333886cc6be698554f6b5b9e6f118fc2a3a5f`.
The previous sources and failed receipts remain unchanged.

The complete widening matrix subsequently passes all seventeen targets at
64-bit readable and 32-bit compact profiles, including all three mutants.
All 42 complete native/WASM responses match: widening check/format/all-target
generation at both widths, plus documentary-reference checking and formatting.
Every generated file in all 34 native target/profile projects matches the
current native and WASM generation byte for byte. Effective Canon 0.2.2 passes
with the existing pre-1.0 exemptions; no human vetting is claimed. These results
close the scoped widening/reference repair checks, not the pending Unicode
SDK corpus, installed smoke, remaining baseline repairs or final combined gate.

The installed Unicode checkpoint's smoke run terminates while exporting the
bundled examples at the existing thirty-minute guard. Earlier installed CLI,
generated-code and native starter checks completed, but the smoke gate did not.
Its wrapper discarded the underlying error code and signal. The development
smoke script now records each command, duration and original error cause.
Only the expanded example export receives a one-hour budget; all exports and
assertions remain required. The actual 206-file archive audit is separate
evidence and is not a smoke pass. The generated script passes Node syntax
checking. The new installed-package rerun has passed setup, checking,
explanation, doctor, generation, native starter tests and generation checking;
it is now exporting the bundled examples. A complete smoke pass remains
required.

Evidence is under `.artifacts/portable-numeric-conversions/` and the earlier
frozen worktrees. Final combined compiler, target, SDK, parity, editor,
documentation and release checks remain open. Readability stays deferred,
all-named endings remain the following minor, and no RC designation, tag or
publication is claimed.

The still-running immutable `ad8bfc33` baseline also exposes additional
acceptance failures. The `packages` suite supplies canonical package sources
without a canonical profile, routing them through legacy parsing; the shared
parse error is at `shop-domain/src/domain.lawspec:11`. Its manifest, native
adapters/stubs and mutants need reconciliation and actual target checks.
Kotlin and Scala built-in properties generate unsigned eight-byte values for a
positive `Int64` restriction, admitting values above `2^63 - 1` before schema
validation. Their bounded generators need correction and range/shrinking
checks; this is not an intrinsic compiler check to disable. F#'s harness passes
its correct implementation and initial mutants, then MSBuild loses child nodes
during the `outside` mutant. That build failure cannot count as an expected
strategy diagnostic and requires an unchanged isolated rerun. The six earlier
sleep failures retain their separate passing reruns. None of these newly
observed failures is rewritten as a pass or removed from final acceptance.

### Bounded native generators and canonical package acceptance — 18 October 2026

The `minor-bounded-package-consumers` increment corrects Kotlin/Scala generation
for finite integer restrictions. The previous implementation chose only a byte
width and signedness, losing the actual endpoints. For a nonempty interval
`[lo, hi]`, the repair masks an unsigned draw to the next power-of-two interval,
rejects offsets outside `hi - lo + 1`, and adds `lo`. Rejection accepts at least
half the masked offsets. The existing native `map`/`filter` operations retain
and validate shrink trees. Full machine ranges retain their original signed or
unsigned generator, including signed shrinking toward zero.

This uses the repository's existing Kotest and ScalaCheck-backed adapters,
not another generator or execution engine. The pinned
[Kotest 5.9.1 BigInt implementation](https://github.com/kotest/kotest/blob/v5.9.1/kotest-property/src/jvmMain/kotlin/io/kotest/property/arbitrary/bigint.kt)
offers Int-sized ranges or bit counts, rather than full BigInteger intervals;
its bit-count form does not retain the existing byte shrink tree. The repair
composes the existing byte arbitraries with the documented
[generator operations](https://kotest.io/docs/5.9.x/proptest/generator-operations.html).
Scala continues to draw through its existing
[ScalaCheck seed/generator integration](https://github.com/typelevel/scalacheck/blob/v1.20.0/core/shared/src/main/scala/org/scalacheck/Gen.scala).
ScalaCheck provides `Choose[BigInteger]`; replacing the existing tree generator
with a value-only draw would require a separate shrink adapter. This repair
keeps the existing tree pipeline on both frameworks.
The range-checking precedent remains
[SPARK's proof of program integrity](https://learn.adacore.com/courses/intro-to-spark/chapters/03_Proof_Of_Program_Integrity.html).
The code generator, framework adapters and runtime scalar validation remain
trusted; these changes do not add solver integration or independently checked
proof certificates, and do not weaken mandatory definition validation.

Native regressions render the actual compiler generators into 26 cases across
both machine widths. Each checks 200 seeds, exact replay, type/range validity,
and up to 96 shrink nodes per sample, including narrow negative intervals,
large unsigned values, distant exact integers, singletons and default signed
shrinking to zero. Both Kotlin and Scala pass at both output profiles, with
all three specification mutants rejected. An initial adapter-directory failure
stopped before compilation and is retained. The first 24-case pilot passed;
the added full-signed compatibility cases then caught shrinking toward the
minimum integer instead of zero. That regression was repaired and the current
26-case runs pass. This is sampled execution coverage, not exhaustive proof of
the generators or universal laws.

The six-law bounded-generation suite is registered for all seventeen targets at
both profiles. A public WASM regression passes typed semantic correspondence,
formatting idempotence, all seventeen emitters at both widths, honest no-layer
evidence and mandatory division-by-zero rejection. Native and WASM builds,
all 144 generated files, 237 boundary modules and integrity pass. The completed
native matrix and four Kotlin/Scala pilots establish all seventeen targets at
both profiles, with all three mutants rejected. Kotlin/Scala builtins also pass
at both profiles, covering the original out-of-range generation failures.

The package suite now declares the canonical profile and explicitly selects
the six law layers preserving its previous behavior. A full seventeen-target
generation preflight finds no diagnostics or recorded-stub changes. Current
native package runs pass on all seventeen targets at both profiles, including
all six adapter mutations and each applicable stub-rejection check. The
original package implementations are retained; no signature mismatch check is
skipped. Together with the bounded-generator and builtins checks, the broad
matrix completes 68 independent native runs; four Kotlin/Scala generator pilots
are recorded separately. Input hashes are unchanged throughout those runs.

All 76 complete native/WASM responses agree for the bounded-generator and
package fixtures at both widths, including all seventeen emitters. The 68
emitted projects match every generated-file byte used by the native tests.
User-owned package adapter files are compared separately with the original
implementations exercised by those tests, rather than with empty generated
stubs. The final public WASM regression checks exactly six unverified law
slots when no layers are selected and the stable `total` rejection for an
undefined definition. Documentation passes 120 pages and 119 compiled
snippets. Canon passes with its declared registry exemptions; this is not a
claim of human review. The full compiler regression subsequently passes
2,237 tests with zero failures in 1,161.8611 seconds. That result belongs to
this checkpoint, before the later contextual boundary-hint repair.
Evidence is under `.artifacts/bounded-package-consumers/`, including
`native-wide-state.json`, `native-pilot-final-state.json`,
`generator-tree-evidence.json` and `parity-state.json`. Final combined acceptance
and current installed-package checks remain open.

The F# harness subsequently passes an isolated unchanged rerun of its correct
implementation and all seven mutants, including `outside`. All compiler and
harness sources match `ad8bfc33`; the copied resolved CI executable is byte
identical and predates the original failure. The original CI rebuilt its native
executables after the initial frozen-image capture, so the rerun records that
actual CI image separately. The prior MSBuild child-node failure did not repeat;
its missing temporary failure files prevent a stronger claim about the cause.
The failed receipt remains retained. This closes the isolated follow-up, not
the original failed whole-run result. Evidence is under
`.artifacts/fsharp-harness-recheck/` in the unchanged preflight worktree. Final
combined acceptance remains open. No RC designation, tag or publication is
claimed.

### Contextual boundary hints — 18 October 2026

The continuing older broad run found a Python failure in the compact
`minor-refined-primitive-inputs` suite. Hypothesis reported 50 rejected examples
and only seven accepted examples, with replay seed
`25223908019183950680600183627505699360`. The narrowed integer generator was
correct, but its supplemental type-boundary witnesses still included the
minimum integer, minus one, zero and the maximum integer. Those values bypassed
the narrowed range until the enclosing law restriction rejected them. Earlier
input values could likewise be unsuitable hints for a dependent later input.

The isolated `minor-refined-boundary-hints` repair filters contextual hints
through the source-ordered restrictions in their actual lexical prefix before
mixing them with native generation. The prefix is reconstructed when the
framework shrinks earlier inputs. Final restriction checks remain, and no
health check is suppressed. Constant primitive hints outside an established
integer range are also omitted from the non-contextual portable path.
This follows Hypothesis's documented
[dependent draws and shrinking](https://hypothesis.readthedocs.io/en/latest/reference/strategies.html)
and retains the existing typed predicate renderer and checked runtime, rather
than introducing another evaluator or proof mechanism.

A native Python regression observes the hint lists passed by the actual emitted
property functions. It checks both narrow ranges, strict dependent ordering and
retention of the valid `Int8` boundary 127. The original implementation fails
with the recorded seed and seeds zero, one and two. The suite now contains a
third law for that retained boundary; its existing two assertion mutants remain.
A controlled counterexample also exercises Hypothesis's actual shrinking while
the observation checks restrictions in changed prefixes. An initial local
virtual-environment setup failure is recorded separately from the subsequent
actual native failures.

Both repair builds pass. All seventeen native targets pass the three-law suite
at both profiles and reject both assertion mutants. Python passes all nine
native tests at each profile, including the four replay seeds and the deliberate
shrinking regression, using Python 3.13.15 and Hypothesis 6.135.26. Six additional
Python/JavaScript/TypeScript package runs pass their adapters, mutations and
applicable stub checks. The combined focused matrix completes all 40 runs with
unchanged inputs.

All 42 complete native/WASM responses agree, including both-width typed
formatting correspondence, idempotence and all seventeen emitters. Every
emitted file byte matches the 34 actual native-tested projects. The public SDK
passes all eleven selected bounded-generation and real-Z3 proof regressions
with no failures or skips. Documentation passes 120 pages and 119 compiled
snippets; all 144 generated files, 237 boundary modules, source/artifact
integrity and version consistency pass. The 73,154,006-byte WASM is SHA-256
`6e0d8be4e259a29a12293b4762786905aa3f4a7a4ab24e7b81968c6d27a32528`.
These are scoped execution results, not universal proofs or final combined
acceptance. Evidence is under `.artifacts/refined-boundary-hints/` in the
isolated worktree, including `native-state.json`, `parity-response-state.json`
and `parity-native-file-evidence.json`.

The queued 2,593-step run of `87f880c9` was deliberately superseded before
executing any steps because it contains this reproduced bug. Its actual
termination and unchanged inputs are recorded; it was not restarted because of
silence or an observation timeout. The older broad run remains unchanged and
its failed results remain failed. A complete fresh run on the repaired candidate
is still required.

Chapter 6 also passes fresh Python oracle execution at both profiles with the
preceding pushed `87f880c9` compiler: all 32,768 A-instruction addresses, 1,792
C-instruction combinations, thirteen stateful programs, independent repeated
invocations and six mutants per profile. The required 23-law, 65-row, one-example,
25-definition, seven-ADT and two-refinement authored inventory, plus six mappings,
and both protected source hashes are unchanged. This does not establish all
seventeen Chapter 6 implementations. The new hint repair still requires its
own final combined run.

The preceding `8f258e65` package smoke has now completed successfully. It
exports all bundled examples in 3,357.075 seconds, exercises the installed
structural API across seventeen targets at both widths and layouts, and passes
installed JavaScript and Rust scaffold tests, doctor and regeneration checks.
All 206 archive files match that checkpoint's package tree. This is supporting
evidence for that archive, not installed acceptance of the subsequent generator
or boundary-hint repairs. Final combined acceptance remains open; readability
stays user-deferred and all named endings remain the following minor. No RC
designation, tag or publication is claimed.

### Final documentation reconciliation — 18 October 2026

The optional case-warning increment is pushed on `main` at `e3d77b95`. Its
focused compiler, public-interface, editor, complete-response parity, generation,
boundary, integrity and configured canonical-format checks pass. An independent
inspection of the current packed archive matches all 206 files to the candidate
and passes six actual packaged-CLI checks across both machine widths: defaults,
opt-in warning delivery, unchanged law evidence and mandatory admission errors.
This does not replace the full installed catalog export or complete CI graph.

The fresh 2,593-step acceptance run is executing on that immutable main snapshot.
This documentation follow-up corrects the catalog export's command limit to one
hour, records the warning controls in the changelog, and names their permanent
regressions in the completion inventory. Compiler and target implementation bytes
are unchanged. Final integration, applicable documentation/package checks and
release preconditions remain open. No tag, publication or RC designation is
authorized by this record.

### Optional case warnings — implementation under verification, 18 October 2026

The completion audit found that the authoring contract's optional unreachable
branch and unnecessary fallback diagnostics were missing. The separate
`codex/minor-match-advisories` worktree adds opt-in `warnMatches` API output,
`lawspec check --warn-matches`, and the VS Code `lawspec.warnMatches` setting.
Warnings use `case-unreachable` and `case-unnecessary-fallback`, retain original
source spans, and stay separate from mandatory errors and law evidence. Defaults
remain off; no verification layer is selected by enabling these warnings.

The implementation consumes the existing ordered pattern matrix's retained-row
identities. It adds no solver or independent proof mechanism. Its structural
analysis is incomplete, especially where further constructor or refinement facts
only become available after typing. An empty warning list does not establish
that every branch is reachable. Guards do not establish exhaustive coverage.

This follows [SPARK's explicit warning-completeness boundary](https://docs.adacore.com/spark2014-docs/html/ug/en/source/how_to_write_subprogram_contracts.html#verifying-contract-consistency)
and [Lean's configurable authoring warnings](https://lean-lang.org/doc/reference/latest/Linters-and-Code-Quality/Linters-and-Warnings/).
[Lean's match compiler](https://github.com/leanprover/lean4/blob/master/src/Lean/Meta/Match/Match.lean)
also tracks used alternatives during match compilation; LawSpec reuses its own
existing matrix rather than introducing a second coverage implementation.

The extended focused compiler run passes 21 tests, including warning
selection at both machine widths, complete generated-result preservation across
all 17 targets, guards, nested original spans, and unchanged mandatory admission
errors, plus recursive-constructor, record and tuple shadowing. Seven editor
tests and a strict published TypeScript declaration consumer also pass. All 84
complete native responses match the pushed `1af46d54` baseline; opt-in warnings
change only the two documented warning fields. All 84 complete WASM responses
match the new native compiler, including all 17 emitters at both widths.
Documentation checks pass 120 pages and 119 compiled snippets.

An earlier attempt was stopped because its test-registration script had
failed; its log and supersession reason are preserved. The initial SDK run
passes actual compiler/API, LSP and TypeScript checks; its
CLI case rejects a Node WASI experimental notice because it incorrectly assumed
empty stderr. The repaired test permits that host notice while still checking
LawSpec warning delivery and clean JSON output. The rerun passes all four public
interface tests with no skips, including the CLI. Generation, boundary, integrity
and version checks pass. The first canonical-format attempt skipped its absent
checkout. Subsequent checks exposed absent HEAD entries and duplicate canonical
vetting of the new generated editor test. Its authoritative template carries the
mock-method comments; the generated output now follows the existing
`DEC-generated-files-not-checked` policy, like the generated grammar test.
No human sign-off is fabricated. The repaired canonical-format check and final
combined acceptance remain open. Evidence is under
`.artifacts/match-advisories/` in that worktree.
No RC designation, tag or publication is implied.


### Completed compiler and public-consumer gates — 18 October 2026

These receipts belong to the pushed `e3d77b95` implementation snapshot. They
supersede earlier pending statuses for these particular gates, while preserving
the earlier attempts and their recorded failures or interruptions as history.
The complete fresh CI run and acceptance of the subsequent documentation
integration remain open at this checkpoint.

The full compiler suite passes **2,249 tests with zero failures**. The complete
SDK command records **517 tests: 513 passes, four declared native-environment
skips, zero failures and zero cancellations**. All four skipped cases execute
as the exact same test cases in their dedicated Rust, Clojure or Haskell CI
gates, each with one pass and zero skips. The SDK run includes actual external
Z3 execution from rebuilt-WASM tasks, checked migration writes, formatting,
explanation views, public CLI example export, TypeScript consumers and actual
LSP warning transport with UTF-16 positions. This is regression evidence, not
verification of every user law or an independently checked solver certificate.

The production native/WASM parity command compares **4,777 complete responses**:
**4,427 accepted and 350 matching rejections**. It enters the archived 0.24
corpus through the explicit migration interface and separately checks the
canonical orders package. Every backend must produce accepted, nonempty codec
generation at both widths and both layouts; canonical package generation also
runs on all 17 targets. Rejected responses remain counted separately. Compiler
response and emission parity do not replace execution of generated projects.

The installed native-binding integration matrix passes **all 34 profiles across
17 targets and both machine widths**. Its public CLI and normal native build
tools execute the generated tests, reject a wrong-fee implementation through a
generated law, rerun affected laws after adapter changes, avoid caching failures
as passes, and preserve application files during regeneration. The separate
installed-package smoke gate also passes, including complete catalog export,
structural consumers and the Rust quickstart.

Both current Chapter 6 oracle profiles pass **32,768 A-instruction addresses**,
**1,792 C-instruction combinations**, 13 stateful programs and six meaningful
mutants per profile, including independent repeated invocations. The protected
authored inventory and original-source hashes remain unchanged. The refund and
order demonstration also passes all 34 native target/width profiles. Other
native suites and the complete release checks remain separate acceptance gates.

The per-command logs, hashes, scoped receipts and requirement-to-gate map are
preserved under `.artifacts/minor-final-match-advisories-acceptance/`. They keep
planned checks separate from completed evidence. Readability remains explicitly
user-deferred, all-named endings remain the following minor, and the larger
pre-final-1.0 programme remains unchanged. No RC designation, tag or publication
is claimed.

### Requirement coverage audit — 18 October 2026

This inventory checks the approved implementation contract against current
sources. Source inspection does not replace final execution gates. The named
tests are executable coverage; their current full-run results must be recorded
before closing the completion checklist. Earlier dated receipts establish
results for their own compiler and package snapshots.

| Contract requirement | Current implementation and acceptance coverage | Outstanding acceptance |
|---|---|---|
| Mandatory definition checking independently of law layers | `Core/DefinitionContracts`, `Core/Totality`; `TotalSpec`, `DefinitionContractProofSpec`, `GadtSpec`, canonical no-layer rejection tests | Final compiler and native runtime-contract gates |
| Pure functions, effectful procedures and abilities; polymorphism, capabilities, wrappers, indexed families and checked recursion | Canonical frontend and existing typed Core; `AbilitiesSpec`, `DefinitionSchemeSpec`, `SourceGadtIndicesSpec`, `SourceGadtRefinementsSpec`, record/payload suites | Final regression and target gates; no unchecked function category |
| Declarations, annotations, sections, metadata and current-minor closers | Canonical parser, `CanonicalSpec`, published `docs/reference/language/syntax.md` | Final parser/docs checks; every named ending is explicitly the following minor |
| Phrase spelling/escapes, qualified prefix/infix equivalence, precedence and native-name collisions | Canonical lexer/resolver; `CanonicalSpec`, `SourceSyntaxSpec`, `TargetNamesSpec` | Final target emission; collisions still require explicit bindings |
| Integer/Whole/Nat domains, bounded migration, zero-inclusive lengths/indices, exact literals and widening | Existing scalar/type admission and migration cover the domains and contextual literals; exact scalar widening uses the existing whole-domain containment check, with compiler tests, native runs on all 17 targets/both profiles and complete native/WASM comparisons | Final combined regression; narrowing, float precision loss and nominal unwrapping remain rejected |
| Nominal records, explicit construction, closed anonymous products and typed alternatives | `Core/RecordIdentity`, source record elaboration; `SourceRecordCanonicalSpec`, `SourceRecordPayloadSpec`, `SourceRecordInferenceSpec`, `PayloadSpec` | Final compiler/native payload suites; unsupported dependent source forms remain diagnosed |
| BLAKE3 identity, field-order independence, alias/bound-name normalization, collision interning and separate nominal dependency invalidation | Portable `Blake3`, canonical descriptors; official-vector checks in `CanonicalSpec`, `RecordIdentitySpec`, `RecordNormalizeSpec`, recorded GoForge comparison | Final record parity; unrelated SHA caches remain separate |
| Single-evaluation ordered cases, scoped it, guards, recursive/record patterns, wildcards and exhaustiveness | Canonical case elaboration; `CanonicalMatcherSpec`, `CanonicalPredicateFactsSpec`, `MatchWarningSpec`, recursive-record examples and SDK/CLI/LSP warning regressions | Final compiler/target/editor gates; guards do not establish coverage, and optional structural warnings do not establish complete reachability |
| Nested quantifiers/negation, left-to-right restrictions, normative wording, contextual articles and typed equality | Authoritative Core propositions; `CanonicalSpec`, `QuantifierDomainSpec`, `WitnessSpec`, contextual-article SDK checks | Final logical, reusable-law, Eq and IEEE regressions |
| Prelude lookup after locals/imports, ambiguity and capture avoidance | Shared resolution/substitution; `PreludeResolutionSpec`, canonical qualified-name and reusable-law tests | Final compiler/consumer gates |
| Eq-only Set/membership, first-occurrence order, SortedSet migration, collection any and explicit map selections | `Core/EqSet`, existing collection operations; `EqSetSpec`, `EqSetOperationsSpec`, `CanonicalCollectionsSpec`, SDK set/membership/migration suites | Final native collection suites; iteration itself needs no Eq |
| Explicit substrings and pinned full Unicode default case folding without normalization | The completion audit exposed missing folding support, now implemented as ordinary checked definitions from pinned Unicode 17 C/F data; native runs on all 17 targets/both profiles, corpus SDK checks and complete native/WASM comparisons pass | Final combined regression and installed-package gate; no normalization or host case-fold dependency |
| Checked mappings, finite coverage/fallback, Maybe partial lookup, preimages and uniqueness-gated inverse | Mapping elaboration to ordinary definitions; `MappingSpec`, typed-mapping fixture, Chapter 6 mappings | Final mapping/native suites; external-oracle agreement stays separate |
| Repeating named examples, expectation-first tables, multiple expectations, typed/recorded inputs and independent failures | Canonical table elaboration; starter, native-evidence and authoring suites | Final consumer/native execution |
| Authored expected compile rejection with stable diagnostic codes | Independent `reject=<code>` documentation fences, three negative fixtures, fourteen documentation controls and editable rejection views | Verified at `4a6f672a`; rerun final docs/consumer gates |
| Documentary typed references, selectors/groups, unresolved errors and finite cycles | Resolved reference metadata; canonical reference tests, documentary-review example, unsaved-source LSP tests | Final consumers/docs/editor; references never discharge obligations |
| Optional verification layers and honest no-selected-checks reporting | Compiler/API/config selection; `SelectionAdmissionSpec`, `ModelLayerSelectionSpec`, SDK evidence/model-layer suites | Final public-consumer and target gates |
| Checked harness witnesses/lexical paths, complete or bounded searches and dependent shrinking | `Witness`, `HarnessWitness`, existing checked evaluator/search; `WitnessSpec`, `SearchSpec`, `QuantifierDomainSpec` | Final existential/native suites; failed candidates and bounded misses remain inconclusive |
| Distinguish proof, particular witnesses, complete finite results, bounded findings, unsupported search and nonexistence | Typed evidence and scoped execution receipts; `DomainEvidenceSpec`, SDK evidence/native-evidence suites | Final evidence/consumer gates; sampled universals never become universal proofs |
| Use established proof infrastructure with an explicit trust boundary | Typed SMT-LIB tasks and actual external Z3 execution; `SmtSpec`, SDK `smt-proof` tests, recorded SPARK/Why3/Lean/Idris/Rocq precedents | Final real-solver checks; no independent proof checker or in-process Z3 binding is claimed |
| Preserve workflow/temporal/scenario/actor/model semantics, snapshots, history, fairness and model/native distinction | Existing checked models/native adapters; `StatefulModelSpec`, `ScenarioSpec`, `TemporalSpec`, native-evidence suites | Final native model/temporal gates; advanced analyses remain pre-final-1.0 |
| Two-space/80-column formatting, idempotence, comments/literals and chosen wording | `SourceText`; canonical/SDK typed snapshots, handler/block fixtures, scenario/multiline fixes and parser-identified record separators | Current final compiler/release checks stay open; source-sensitive cache/remote identities can rekey |
| Read-only migration, checked project writes, constructors/native bindings, comments/origins and rollback | Explicit migration APIs/writer; `MigrationSnapshotSpec`, `MigrationPayloadSpec`, SDK migration-write/package/native-binding suites | Six support/refusal boundaries below; final current-package run pending |
| Developer/business/formal/evidence views and JSON from the same obligations | Shared typed presentation and `explain` CLI; SDK authoring/explanation/TypeScript tests | Final CLI/consumer tests; no second proposition interpretation |
| Diagnostics, seeds, shrinking, source spans, expected/actual and search completeness | Structured compiler/evidence/execution results; API, witness, replay and native-evidence tests | Final consumers/native gates, including interrupted runs |
| LSP stdio, diagnostics, formatting, symbols, hover, navigation/references and UTF-16 | Compiler-backed `lsp.mjs`, VS Code extension/grammar; unsaved-source/documentary/witness LSP tests | Final editor/SDK gates; unavailable visual browser inspection is not claimed |
| Schema 5, configuration 2, explicit profile, migration-only older input and preserved legacy law selections | Canonical admission and migration configuration; `CanonicalInterfaceSpec`, SDK canonical-interface/environment/migration-write tests | Final installed public consumers/release checks |
| Shared website/editor TextMate highlighting and Linguist preparation | Exact shared grammar, locked TextMate/Oniguruma, corpus parity, `linguist-eligibility.md` | Upstream usage/import/acceptance/deployment remain external pre-final-1.0 dependencies |
| Codecs/reusable inverse, existence/absence, authorization, refunds/conflicts and stateful orders | Published `examples/rc1` and permanent native acceptance suites | Final all-17-target run; existing receipts describe each suite's native scope |
| Examples 48–50 and eight three-layer record/alternative combinations | Eight nesting files and tuple/record machinery are present. The audit exposed missing completed filename demonstrations; examples 48–50 now include tuple/record/filename authoring, rejection priority and native outcomes/mutants on all 17 targets at both profiles | Final combined nesting, documentation and installed-example gates |
| Chapter 6 semantic migration, authored inventory, complete instruction oracles and invocation independence | Canonical assembler, frozen original, checked mappings and `tools/chapter6-oracles.mjs`; fresh both-profile oracle receipts | Preserve inventory/hashes; complete implementations in other languages remain pre-final-1.0 |
| Final compiler, target, generation, boundary, docs, editor, parity and release checks | CI graph, package smoke, locked runtimes and release preconditions | Open: final package rebuilding and fresh final-commit execution; 0.25.0 is in preparation |
| Three-reader comprehension exercise | Ten questions and threshold retained here | Explicitly user-deferred; no reader results claimed |
| Larger demonstration portfolio and advanced verification | Original pre-final-1.0 gates retained below | Open pre-final-1.0; completing this minor does not authorize final 1.0 |

Migration acceptance establishes documented supported paths and checks refusals
for the remaining limits; it does not claim every generic or opaque
transformation is available. The detailed six-case inventory below remains
authoritative. Actual writer tests cover reordered-index population refusal,
unsupported generic GADT admission, unestablished generic populations,
polymorphic-only missing target artifacts, stale package changes and changed
opaque codecs/factories. They check that original source, configuration and
application bytes survive refusal. Positive tests separately cover finite
populations, concrete indexed/existential factories, complete dependency source
transport and admitted native layouts on all configured targets. The current
192 migration/interface/existential consumers pass in the run recorded below.
The separate complete iteration release gate remains open.

### Parser-identified record-type separators — implementation under verification

The formatter now omits optional record-type field commas. The existing parser
records their exact authored spans in its source inventory; the formatter uses
those roles rather than recognizing another record grammar. Record values,
patterns, tuple types/values, text and comments keep their commas. Inserted
prelude qualifiers do not replace authored coordinates. The ordinary format API
captures the existing syntax inventory, applies the edit, and recompiles the
complete formatted project with mandatory definition validation still enabled.

All **106 native canonical authoring tests** pass on the first fixture. The
corrected public fixture passes **68 target/width/layout generations**, including
an imported nominal type, complete typed snapshot correspondence, idempotence,
tabs and a preserved Unicode comment. The initial fixture used a Unicode field
label accepted by the source language but rejected by existing native emitters;
it now uses the portable domain label `caption`. This corrects the acceptance
fixture, not native naming policy. Its focused SDK check passes in
22,707.7755 ms. An earlier compiler run was deliberately stopped before updating
the compiled fixture assertions. The restarted compiler run now passes
**2,223 tests with zero failures** in 607.4778 seconds.

The selected SDK run records **219 tests: 218 passes, one initial fixture
failure, no skips**, in 363,046.918125 ms. All **192 migration, canonical-interface
and existential-migration consumers pass**. The remaining 26 authoring consumers
also pass; the corrected separator case passes separately as recorded above.
This is combined evidence, not an uninterrupted final-source SDK pass. Actual
writer refusals account for all six migration boundaries without promoting
unsupported generic or opaque transformations into supported capabilities.

Complete native/WASM parity agrees on **436 full responses**, including
**408 accepted generation requests** across all 17 targets, both widths and
layouts, and four legacy migration-baseline responses. All 434 preceding
responses match exactly; only the two record-separator format responses differ.
Before/after typed snapshots agree for the scenario, literal and record/import
fixtures. Every response pair and its hash passes an independent audit. The
existing 124 source-sensitive remote-hash differences between unformatted and
formatted scenario/literal programs remain explicitly checked; no new remote
identity policy is introduced.

The native compiler is SHA-256
`5ce523bd6ad204a3718f86b86d6006200ed5ba7e57de5012d7861c6358f28e2b`;
the 72,964,880-byte WASM is SHA-256
`a2211c565e578e30c31c9df60dd29b6da4c7ba75348af388eadf3ae40a36ce04`.
All 137 generated files, 236 compiler boundaries, six editor checks, integrity
and documentation for 120 pages with 118 compiled snippets pass. Chapter 6's
original and canonical hashes remain intact; its entire native format response
matches the preceding verified checkpoint. Evidence is retained under
`.artifacts/record-type-format-separators/` in the isolated worktree.

That compiler result belongs to the frozen 0.24.0 formatter checkpoint. The
current-package full catalog export, fresh installed consumer/native target
gates, minor-version preparation and complete release check remain open. No RC
designation, tag or final 1.0 acceptance is implied.

### Scenario command boundaries and multiline literals — implementation under verification

Valid scenarios with a long command argument previously failed after formatting:
the formatter moved the argument off the invocation's physical line. Scenario
command boundaries now survive binding, parallel delivery and recovery, while
surrounding functions can wrap. A separate regression exposed multiline literals
whose closing line also closes a function: the literal's whitespace remains
exact, and trailing block tokens now update the scope before the next function.

All **105 canonical authoring tests pass**. Complete native/WASM parity agrees
on **288 responses**, including **272 accepted target generations** across all
17 targets, both widths and layouts. Four complete before/after typed snapshots
match and formatting is idempotent. An independent receipt/hash audit verifies
all complete responses. The preceding compiler agrees on 280 responses; eight
formatting responses contain the intended scenario or literal-layout changes.
No response fields are removed from these comparisons.

Comparing unformatted and formatted generated programs found existing
source-sensitive remote-definition hashes. Across 124 changed generated-file
pairs, only those SHA3-256 identities change; dispatch names, descriptors,
executable definitions and every other artifact byte match. These full pairs
are retained. Formatting is not claimed to preserve remote/cache identities.
The first SDK assertion incorrectly required identical hashes; a subsequent
test-helper regex omitted some target paths and then had an escaping error.
Those failed/interrupted validation attempts remain separate from corrected
results. The compiler implementation did not change during those test repairs.

The current native compiler is SHA-256
`360263687a3948c8a999cc922233eda5149ed482fae9017b2c80cd47fad61061`;
the 72,941,140-byte WASM is SHA-256
`50ae53e251c2e26e46ccacae339150207691fda14cfc03af93aa859297248715`.
All 137 generated outputs, 236 compiler boundaries, six editor tests, version
agreement, artifact/source integrity and documentation for 120 pages with
118 compiled snippets pass. The full compiler now passes **2,222 tests with
zero failures** in 838.7431 seconds. The current SDK catalog run remains in
progress and is not claimed complete here. A separate native audit verifies
both original Chapter 6 hashes and its canonical authored hash, and confirms
that the canonical assembler's formatted bytes remain unchanged. The first
audit invocation exceeded Node's default subprocess output buffer; the
corrected complete-response audit passes without that buffer limit.

The broader requirement audit above also verifies an outstanding mechanical
formatter requirement: optional commas remain in formatted multiline record
types. A valid Picture type compiles and formats, retaining its field comma.
The complete request and responses are retained in
`.artifacts/scenario-format-boundaries/record-separators-probe.json` in the
isolated worktree. The next formatter increment must omit these type separators
while retaining commas in record values/patterns and nested tuple syntax.
This is an explicit remaining requirement, not a completed coverage gate.

### Shared editor and website highlighting — 18 October 2026

The website now interprets the exact editor grammar with the same pinned
Microsoft TextMate 9.2.0 and Oniguruma 2.0.1 packages. The duplicated legacy
highlight.js LawSpec rules are removed. A presentation adapter maps TextMate
scopes to the site's existing theme classes; it does not define another lexer.
Phrase names close at their delimiter, computation keywords and canonical types
receive their editor scopes, and Eq capability scopes remain distinct from
primitive type scopes. Generated native code retains highlight.js.

The builder copies the shared grammar template, verified tokenizer bundles,
Oniguruma WASM and required licenses/notices. New vendor URLs contain the locked
versions so immutable caching cannot retain a different package revision at the
same URL. Package versions and integrity values must match the editor lock.
When highlighting cannot load, escaped source and compiler interaction remain
available. No fallback grammar is substituted.

Six SDK checks pass, including all three existing rejection-example checks.
Scope parity uses the actual browser UMD bundles and compares every token with
the editor across **144 source files, 12,370 lines and 107,851 tokens**. Complete
source spelling survives rendering, including Unicode, escapes and CRLF. All
**137 generated outputs**, 236 compiler boundaries, six editor checks, version
consistency and artifact integrity pass. The site builds 120 pages with 118
checked snippets. Independent asset auditing verifies three identical grammar
copies, all **360 script references**, and exact tokenizer/WASM/license bytes.

DOM interaction tests use the emitted scripts, their browser-context vendor
bundles and actual compiler WASM. Normal highlighting and missing-runtime,
missing-grammar and missing-WASM cases preserve source and compiler checks.
Rejection editing and pending-result invalidation still work. This is DOM
verification; the previously recorded browser-plugin initialization limit
remains, and no visual browser inspection is claimed. Evidence is under
`.artifacts/site-grammar-parity/` in the site-grammar-parity worktree. Compiler
library sources and native/WASM compiler bytes remain unchanged from the
formatter checkpoint; no new law or native-conformance evidence is claimed.

The wider formatter audit found a concrete remaining failure: a valid scenario
command with a long Text argument passes ordinary checking, but wrapping moves
its argument onto a new line and the formatted source fails parsing. Scenario
arguments retain the existing line-scoped grammar. The complete check/format
reproducer is `scenario-line-boundary-probe.json` in the same evidence directory.
Preserving those boundaries is required before the authoring coverage gate can
close. The current-package catalog exports and final release checks remain
open. Readability stays deferred, named endings belong to the following minor,
and no RC designation or tag is implied.

### Checked compiler-rejection examples — 18 October 2026

Documentation authors can write `lawspec reject=<diagnostic-code>` fences,
including standalone source fixtures. The ordinary compiler checks each fixture
independently with no optional law layers selected. Exactly one diagnostic must
have the named code; accidental acceptance, a different code or extra diagnostics
fail the documentation check. Malformed or duplicate attributes, fragments and
requests for native implementations or execution are rejected. This introduces
no LawSpec declaration, unchecked computation category or compiler-check bypass.

The published examples cover a zero denominator, an incompatible function result
and an out-of-range address refinement. Corrected counterparts compile. All
three use the same unit name while retaining independent source contexts. The
precedent is [Lean's `#guard_msgs` diagnostic assertions](https://lean-lang.org/doc/reference/latest/Interacting-with-Lean/);
LawSpec checks its existing compiler's stable codes rather than message wording.
A matched compiler rejection establishes compiler behavior, not law verification
or native conformance.

An editable rejection view shows the expected code and actual diagnostic with its
source location. A repaired source reports unexpected acceptance. Wrong codes,
reset/copy operations and edits during a pending check are covered. Each view owns
an independent source model and offers compilation controls. Native execution
controls are absent because the fixture deliberately fails compilation.

All **14 actual documentation-checker controls** pass, including incorrect-code,
unexpected-success, malformed-option and cross-fixture symbol-isolation cases.
The rebuilt site contains 120 pages and **118 checked snippets**. Three SDK tests
pass, covering every target entry point at both widths with no law layers.
Native/WASM parity agrees on **132 complete responses**: 126 rejections and six
accepted repairs. Independent payload and receipt-hash auditing passes. All 136
generated outputs, 236 compiler boundaries, six editor checks, version consistency
and artifact integrity pass.

The emitted component also passes DOM interaction tests using its real browser
WASM shim. These cover matching, source context, repair, wrong codes, reset,
copy, independent same-key fixtures and invalidation of pending results. The
browser plugin failed during initialization because its process-module import
was unavailable. No visual browser inspection is claimed. The test harness uses
pinned LinkeDOM 0.18.13 in the private artifact directory; it adds no product
runtime dependency.

Compiler library sources and both compiler artifacts remain byte-identical to
the formatter checkpoint (`e16b1d77...` native and `f37cadd9...` WASM). The package
manifest changes only its three fixture entries and corresponding packaging
fingerprint. Existing mandatory validation and deferred runtime enforcement
remain unchanged. Initial build/test assumptions and their corrected runs are
retained under `.artifacts/rejection-examples/` in the rejection-examples worktree.
The 14-control tool is registered in the normal CI plan.

The continuing coverage audit confirms a separate site-highlighting defect:
the web highlighter uses legacy rules, leaves canonical computation/type words
unclassified and consumes a phrase name through its function body as a string.
The emitted HTML reproducer is `highlight-audit.json` in the same evidence
directory. The canonical editor TextMate grammar already handles these forms;
web highlighting must be brought into correspondence before the wider authoring
coverage gate closes. Frozen catalog exports and final iteration release checks
also remain open. Readability remains deferred, all named endings belong to the
following minor, and no RC designation or tag is implied.

### Formatter block coverage and migration refusal boundaries — implementation under verification

The source formatter now retains the enclosing levels of workflows, protocols,
scenarios, models, actors, supervisors, resources, wrappers, refinements and
harnesses. Nested workflow `all` groups, scenario `par` branches and recovery,
resource operation bodies, strategies, benchmarks and implicit `for law` groups
have explicit layout coverage. A top-level `handle` type declaration no longer
opens an expression block. This retains the current closing grammar; completing
all named endings remains the following minor's task.

Scenario and benchmark labels retain their existing paired-backtick syntax.
Their words cannot open or close blocks, and long labels remain indivisible.
Lexical context survives header line breaks and comments, and wrapping retains
the original token boundaries. Canonical infix backticks remain unpaired. The
regressions exposed missing scenario handling, an empty-token comment-line
failure and invalid initial model-fixture assumptions; corrected runs are
recorded separately from those failures.

All **103 canonical authoring tests** pass. The three new SDK checks pass,
including full typed snapshot correspondence at both machine widths and actual
writer refusals. A polymorphic-only project's symbolic agreement cannot replace
accepted target generation. Changed opaque codecs and generator factories
cannot authorize writing: sources, configuration and existing application bytes
remain intact. Public migration documentation now lists the six supported/refused
boundaries and corrects stale statements about separately migrating dependency
sources. Admitted dependency sources are transformed with the project; stale or
unestablished package inputs still block writing.

Native/WASM parity passes **296 complete responses**, including **272 accepted
generation profiles** across all 17 targets, both widths and both layouts.
Independent receipt and complete-response auditing confirms **288 unchanged
preceding responses**. All eight differences are formatting responses: six
retain every other response field, while the two long-label cases repair a
previous formatting parse error. All generated bytes in those generation
profiles are unchanged. Native formatting also preserves six complete typed
migration snapshots and is idempotent. This is generation correspondence, not
a new native execution or law-proof claim.

The native compiler is SHA-256
`e16b1d77b5fa66dbf718da181c4ae3daf41c27eddf087a4b6f3956ada9c85fbf`.
The 72,937,446-byte WASM is SHA-256
`f37cadd99786f1598577c4185309b25d37b55edc2356b8d4849c87ee3ba6c4ca`.
All 134 generated outputs, 236 compiler boundary checks, six editor checks and
documentation for 120 pages with 115 compiled snippets pass. Chapter 6's
`UserSymbol` refinement body now receives two-space indentation; complete typed
snapshots before and after agree and the new formatting is idempotent. The
original Chapter 6 and frozen legacy fixture retain their recorded bytes.
Complete generated Python files are byte-identical before and after that
indentation change at both profiles. Twelve source-sensitive dependency keys
change per profile; every other test-manifest field matches. Complete response
pairs retain those changes. The first comparison's assertion that the keys were
identical failed; the corrected audit explicitly accounts for each changed key.
The complete typed snapshots also match the preceding checkpoint's snapshot.
The full compiler regression passes **2,220 tests with zero failures** in
865.4078 seconds. The SDK regression records 492 passes, one stale Chapter 6
formatting-baseline failure and four explicit opt-in skips out of 497 tests.
That case had captured the earlier source before its indentation refresh;
the corrected current-source case passes separately in 77.6152 seconds. This
records the combined scope rather than an uninterrupted final-source SDK run.

Fresh independent Chapter 6 oracles now pass at both profiles. Each executes
545 generated checks covering 23 laws, 66 examples, 16 properties, 453 boundaries
and ten replay hooks. Independent oracles cover all 32,768 A-instruction addresses,
1,792 C-instruction combinations and 13 stateful programs, including repeated
invocation independence. Each profile rejects six implementation/specification
mutants. Receipt auditing verifies the current authored-source hash
`569c7f3baf90ad3093bebc4ea32552c51dd1529a2a5777d26b007cf1a8b848d1`,
the original-source and frozen-fixture hashes, and the pinned native compiler.
The frozen catalog export and final iteration release checks remain open.

Evidence is under `.artifacts/formatter-block-coverage/` in the isolated
formatter-block-coverage worktree. This checkpoint does not complete the wider
coverage audit or final iteration release check. Readability stays user-deferred;
no RC designation or tag is implied.

### Business policies, native conformance and stateful orders — implementation under verification

The coverage audit identified missing canonical refund, conflicting-requirement
and order-history demonstrations. The new positive suite contains eight laws
and 40 independent table cases across the checked refund policy, an application
conformance specification and a stateful order processor. Refunds use exact,
zero-inclusive `Whole` amounts, with explicit zero/excess/review priority and a
case beyond binary floating-point's exact integer range. The conformance law
compares an application's adapter with the checked policy and repeats the ten
published outcomes independently. All 17 targets have application-owned native
implementations and a valid-but-wrong native decision mutation.

The order processor uses an explicit `OrderStore` ability and an owned in-memory
handler. Twelve rows cover every single-step state/action combination; eight
histories check sequencing, cancellation and shipping. A separate law invokes
independent orders to expose handler-state leakage. This is finite sequential
execution with fresh state, without a concurrency, durability, fairness or
complete-history claim. The conflicting-requirement source admits both valid
total candidate functions with no law checks selected. Complete finite law
checking refutes each candidate against its violated requirement with code
`refuted`; it does not claim general joint conflict analysis.

The new `business-refunds-orders` suite passes native execution on all 17
targets at 64-bit readable and 32-bit compact output, rejecting nine mutations
per profile: **306 native rejections**. The receipts combine 32 passing batch
profiles and two corrected Clojure runs. The initial Clojure implementation
incorrectly expected Java records at a boundary documented to provide maps;
the corrected implementation uses Clojure data. Earlier Python/Go failures
were acceptance-oracle label assumptions: a different applicable policy law
reported the mutation first. The expectations now accept the actual relevant
violated obligations. Failed runs remain separate evidence. An independent
audit anchors every retained positive and negative log. Separate Java positive
report runs each contain 76 actual completed tests with no failures, errors or
skips; Maven's quiet successful stdout is empty.

Three rebuilt-WASM consumers pass: authored obligations/outcomes and formatting
correspondence at both widths, 68 accepted generation profiles across all 17
targets and layouts, and both conflicting-policy refutations. All **84 focused
complete native/WASM responses** agree. Independently checked receipts retain
82 identical preceding-compiler responses; two format responses differ only in
their explicitly checked source text. Every compared generated byte and other
response field remains unchanged. No fields are omitted from the comparisons.

The example exposed missing formatter depth for abilities, stateful handler
operations, conditional initializers and handled expressions. That correction
passes both new indentation/semantic regressions and all **99 canonical
authoring tests**. Token spelling, idempotence and typed migration snapshots
remain checked. The wider construct-coverage audit remains part of final
acceptance. All 134 generated outputs, 236 module boundaries, strict TypeScript
consumers, six editor checks and documentation for 120 pages with 115 compiled
snippets pass. The current native compiler is SHA-256
`751eaa6998327df83b094917220ffaa1c5a938f86742efa66f5f1468a3bf6dbd`;
the 72,896,999-byte WASM is SHA-256
`75847a36fcda51e8c26e92a27c69635120d691c8dbfe0ce653e147f6fd888836`.

The full compiler passes **2,216 tests with zero failures** in 987.3351 seconds.
The SDK run records 489 passes, one failure and four explicit opt-in skips out
of 494 tests. The failure exposed a checked-in Chapter 6 formatting baseline
that no longer matched the corrected formatter. The canonical source has been
reformatted; its complete typed migration snapshots remain identical, its
formatting is idempotent and the failed SDK case now passes separately. The
original Chapter 6 and frozen legacy fixture retain their original bytes. The
independent Chapter 6 oracle rerun now passes at both profiles.

The first oracle attempt also exposed a stale consumer of native-report
freshness: it supplied the time after execution and therefore discarded the
completed JUnit cases. The runner now supplies its launch time. Other model
runner consumers use the same start-time convention; the 46 report/evidence
contract tests pass. The corrected oracle run remains separate from that
failed attempt. Its 64-bit readable and 32-bit compact profiles each pass 545 actual generated checks,
including all 66 authored examples and all 23 laws. Independent oracles cover
32,768 A instructions, 1,792 C combinations and 13 stateful programs with
repeated-invocation independence. Six meaningful implementation/specification
mutants are rejected at each profile. Both runs preserve the recorded inventory
of 23 laws, 65 table rows, one named example, 25 definitions, seven ADTs and
two refinements, alongside six authored mappings.

The wide refund case was then strengthened to compare 9,007,199,254,740,992
captured units with 9,007,199,254,740,993 requested units: converting these to
binary floating-point collapses their distinction. All 34 native positive
profiles pass again with that final table data. Separate isolated JavaScript
runs reject an additional precision-loss implementation mutation at both
profiles, alongside their existing nine mutations. The final three business
SDK consumers and 84 complete parity comparisons also pass again. Independent
payload and receipt auditing confirms all 84 native/WASM responses, 82 unchanged
preceding responses, the two formatting-only deltas, 68 accepted generation
profiles, all 342 frozen native logs and both full Chapter 6 oracle receipts.

The frozen business-demonstration catalog export has now completed: its full
all-target export, independent generated-file comparison, adapter preservation,
idempotence and path-protection test passes in **6,062,101.346875 ms** (total
**6,062,265.196625 ms**), with zero failures or skips. Independent auditing
verifies that all **273 frozen package files** retain their recorded hashes
after completion. This closes that snapshot's export run, not the final
current-package release gate.
The audit also rechecks the original Chapter 6 and legacy-fixture hashes; its
receipt is `final-checkpoint-audit.json` under the same evidence directory. These
receipts are combined evidence across the stated changes, not one uninterrupted
SDK/native run after every correction. Evidence is under
`.artifacts/business-demonstrations/` in the isolated business-demonstrations
worktree. The current sources and their native examples are scheduled together
in both CI profiles. This increment adds no solver, proof checker or unchecked
definition category. It does not complete migration/coverage auditing or the
full iteration release check. Readability remains user-deferred, all-named
endings belong to the following minor, and the pre-final-1.0 portfolio remains
required. No RC designation or tag is implied.

### Scoped native execution evidence — implementation under verification

Native manifests now link execution slots to the existing typed model,
consistency, restart, scenario and supervision obligations. Session safety facts
retain their separate compiler evidence. A restart completion requires a declared
restart command. Ordinary law coverage records the selected finite inputs or
examples and retains nested quantifier search from the original typed law,
before execution planning lowers it into Boolean terms.

The CLI journals pending attempts before launching native tests and invalidates
older cached passes for those checks. Completion requires actual matching runner
results and current compiler, profile, specification, configuration, bindings,
attested wiring, recordings, generated files, native sources and toolchain
inputs. All requested target/project scopes participate. Stale, skipped,
undiscovered, interrupted and failed-setup observations cannot establish a
successful run. A failed combined native method leaves its individual logical
checks incomplete. Current retry and adequacy metadata remain available.

The four explanation views share these observations. Completed native conformance
is separate from a formal proof and from search completeness. Sampled model
execution does not prove every history or a universal existence claim. Existing
proofs and mandatory definition validation retain their classifications. A
model-only selection leaves ordinary laws unverified; an examples-only selection
without authored examples emits no law tests. Native seeds beyond JavaScript's
safe integer range retain their exact decimal tokens; framework seed limits
remain independent.

The primary precedents are [Why3's obsolete and detached proof attempts](https://why3.org/doc/manpages.html)
and [SPARK's investigation of unproved checks](https://docs.adacore.com/spark2014-docs/html/ug/en/source/how_to_investigate_unproved_checks.html).
Compiler identity links, fingerprinting and native report readers are trusted
reporting components. This increment adds no solver execution or independent
proof certificate. Haskell preparation uses [Stack's `config build-files`](https://docs.haskellstack.org/en/latest/commands/config_command/)
before execution fingerprints are computed; evidence reads remain read-only.
JUnit parsing retains failures and skips, rejects stale reports and ignores
testcase-like text in comments and CDATA.

Verification is in progress in the isolated native-model-evidence worktree,
under `.artifacts/native-model-evidence/`. Eleven focused compiler checks and
46 execution/evidence unit checks pass. The final full compiler run passes
**2,214 tests with zero failures** in 933.3846 seconds, including the added
restart-attribution regression. The SDK rerun passes **486 of 490 tests**, with
zero failures and four explicit opt-in skips, in 823,442.546 milliseconds.
Rust and Haskell layout checks and the five-test native-failure suite separately
pass without skips. The final retry/adequacy reader additions also pass the
46-test focused suite, strict TypeScript checks and both JavaScript lifecycle
profiles; this is combined evidence rather than one uninterrupted SDK run after
every reader refinement. The completed broader replay passes **1,455 complete
native/WASM responses**: all 1,285 preceding requests plus 170 new examples-only,
restart-attribution and scoped-quantifier requests. Independent receipt-hash and
complete-response auditing passes. Of the preceding responses, 469 are identical;
816 change only the explicitly checked native test coverage/obligation metadata
and model-only ordinary-law classifications. Every compared generated byte and
other field is unchanged. No fields or fingerprints are removed. The frozen
267-file catalog export now passes its complete adapter-preservation,
idempotence and path checks across all 17 target exports: one test passes in
6,782,270.434 milliseconds. Independent auditing confirms all 267 frozen input
hashes remain unchanged. This receipt covers that native-model-evidence package
snapshot, independently of later compiler changes. The independently audited native
lifecycle receipts cover all 17 targets at 64-bit readable and 32-bit compact
output: ordinary actor laws, six typed model obligations through five native
slots, actual mutant failures, stale observations, repaired runs, no selected
checks and four-view agreement. The 68 complete execution-snapshot and current
compiler plans are identical, including every generated byte and manifest field.
The compact batch initially failed its newly added JavaScript test-harness
assertions; separate corrected runs pass. This is coverage across recorded runs,
not an uninterrupted 34-pass batch.
Actual JavaScript interruption, setup-failure, repair and damaged-seed flows
pass at 64-bit readable and 32-bit compact output. The expanded retry-metadata
view check also passes at both profiles using explicit result-file fixtures.
That fixture checks metadata consumption rather than claiming an actual flaky
native execution. Early test-harness assumptions about compact flags and
the scope of unaffected supervision observations were corrected; their failed
runs remain recorded. These results do not complete the minor iteration, its
migration/coverage audit or the full release check. Readability remains
user-deferred, all-named endings belong to the following minor, and no RC
designation or tag is authorized.

### Resolved typed mappings — 17 October 2026

Mapping row checks now use resolved names, expanded aliases, actual machine
widths and ordinary typed constants. The existing Core evaluator and complete
finite-domain engine check key restrictions, Eq reflexivity, duplicate keys
and coverage. Record and collection keys no longer have the earlier blanket
parser rejection. Explicit fallbacks admit unbounded key domains; unsupported
or incomplete coverage cannot authorize a mapping without one.

Complete mappings group output values by typed Eq to derive preimages in
source row order. An inverse remains available only for unique, reflexive
outputs. A second ordinary compilation resolves exactly those helper names
and reconstructs grouped literal results with their precise key refinements.
Provisional helpers never leave compilation. Native binding identities and
ordinary definition contracts remain mandatory; law selection cannot disable
these checks. Bodyless definitions and restrictions beyond existing admission
or complete-domain analysis retain their existing limits.

The precedents are [Why3's finite maps and their explicit executable equality
parameter](https://why3.gitlabpages.inria.fr/why3/stdlib/fmap.html) and
[Mathlib's complete finite enumeration](https://github.com/leanprover-community/mathlib4/blob/master/Mathlib/Data/Fintype/Defs.lean).
LawSpec retains IEEE Eq semantics rather than importing mathematical
reflexivity for NaN. The compiler translation, existing evaluator and cover
generator remain trusted. This adds no solver binding or independent proof
certificate.

All 22 focused mapping regressions pass, including complete UInt8 coverage,
nominal boundaries, refined keys, aliases, imported facades, phrase names,
signed zeros and NaN rejection. The full compiler passes **2,200 tests**. The
SDK suite excluding the archived-catalog export passes **470 of 474 tests**,
with no failures and four explicit opt-in skips. Separate Rust/Haskell layout
checks and all five native-failure checks pass, covering those skips.

The delivery mapping suite passes all 17 targets at 64-bit readable and 32-bit
compact output: **34 target/profile passes and 68 mutant rejections**. Its Java
run exposed finite generation-tree exhaustion. The shared Java/Groovy property
emitter now uses independent one-case JetCheck sessions with a seeded stream,
retaining its growing budget, native shrinking and replay data. This follows
[JetCheck's generator-tree deduplication and replay implementation](https://github.com/JetBrains/jetCheck/blob/master/src/main/java/org/jetbrains/jetCheck/Iteration.java).
The original failing seed passes and the nominal-label mutant produces a
shrunk `PropertyFalsified`, not a generator failure. Go equality emission now
uses a blank identifier for a payload-free alternative's unused asserted value.
These native checks establish bounded conformance, not universal law proofs.

Native/WASM parity agrees on **999 complete responses**. Of the 924 preceding
responses, 746 are identical and 178 retain complete audited deltas. Changes in
the preceding non-mapping suite are limited to named source/interface
fingerprints from the source-definition Binary extension and exact seed-stream
additions in Java/Groovy tests. Chapter 6 changes only its six mapping bodies,
twelve derived helpers, dependent test cache keys and their emitted/serialized
implementations. Its types, laws, obligations, contracts and other response
fields remain unchanged. No response fields were omitted from parity.

All four Chapter 6 oracle runs pass with native/WASM compilers at both profiles.
Each independently exercises 32,768 A addresses, 1,792 C combinations and 13
stateful programs, rejects all six mutants, preserves repeated invocation
independence and validates project migration. Its authored inventory remains
23 laws, 65 expectation rows, one named example, 25 definitions including six
mappings, seven ADTs and two refinements. This is Python native conformance;
the larger all-17-language Chapter 6 implementation gate remains pre-final-1.0.

All 129 generated files, 233 module boundaries, six editor tests, version checks
and documentation for 119 pages and 115 snippets pass. The actual quickstart
also passes local package installation, explicit zero-check reporting, the
current starter law selector, doctor, generation and native tests after
selecting property/examples. Documentation now distinguishes the unreleased
checkout from tagged 0.24.0 and lists all 17 targets. The public migration
reference no longer describes completed GADT/existential transport as unavailable.

Evidence is under `.artifacts/typed-mappings/`, including
`native-acceptance-receipts.json`, `chapter6-oracle-receipts.json`,
`parity/receipts.json`, `parity/audited-deltas.json` and
`quickstart-receipt.json`. Earlier failed and superseded exploratory runs remain
separate. The complete catalog export passes its frozen typed-mapping package
snapshot: all bundled exports, independent generated-file comparisons, adapter
preservation, edited-test protection and path checks pass in 5,673,649.2 ms.
That snapshot predates the package README and changelog additions; its 263 code
and product files match the final typed-mapping package exactly. This is the
`ba9ceeb1` compiler/package receipt, separate from later compiler increments.
The remaining migration/coverage audit and final iteration
release gate remain open. Readability stays deferred, all-named endings belong
to the following minor, and this checkpoint authorizes no RC designation or tag.

### Independent native model-layer selection — 17 October 2026

The testing plan now records model execution selection separately from complete
typed units. Derived test views omit unselected machines and supervision checks;
reference definitions, mandatory validation, actor, supervisor and session APIs
remain available. Every backend uses this selection, including native-binding
regeneration paths. Eleven backends that previously emitted unregistered model
tests now register their actual native slots alongside the six existing targets.

Optional manifest metadata identifies exact model slots and native scope. Some
frameworks combine sequential, parallel and scenario checks in one method; a
successful native completion covers the included checks together. A failed or
undiscovered method establishes no successful completion. Python node selection,
ScalaTest exact names, Clojure exact vars and Hspec full paths avoid applying
ordinary law-prefix selection to model slots. Distinct logical groups with
colliding generated slots are rejected rather than sharing evidence.

Seven focused compiler checks pass, including all-target source/API preservation
at both widths and layouts, mandatory reference-definition rejection, model-only
manifests and selected native-name collision rejection. Actual public CLI/native
flows pass on all 17 targets at 64-bit readable and 32-bit compact output. Each
runs ordinary actor laws with model checks disabled, executes all five model
checks with that layer selected, rejects an incorrect checked reference
transition and reports zero execution with no selected checks. The compact
negative runs additionally require a completed native failure in JUnit output.
The canonical fixture uses the existing independent actor implementations.

Full compiler regression passes **2,210 tests** with zero failures. The rebuilt
WASM SDK suite excluding archived catalog export passes **474 of 478 tests**,
with zero failures and four explicit opt-in skips. Separate Rust and Haskell
layout checks and the five-test native-failure suite cover those opt-ins with no
skips. An additional binding-consumer regression passes on all 17 targets at
32-bit readable and 64-bit compact output. It retains every public source and
ordinary law slot while independently selecting model checks; cache keys
explicitly change with the verification selection.

All **68 complete native/WASM binding responses** match, and independent
full-response, source, slot and receipt-hash auditing passes. The WASM is
72,855,249 bytes, SHA-256
`a6a7116f9f299dee6834e2f4feacc17aba1d691661f7a9ecf1c84c900d5480d8`.
All 34 execution-command checks, a strict typed manifest consumer, 131 generated
outputs, 236 module boundaries, six editor checks and documentation for 119 pages
and 115 compiled snippets pass. The completed broader replay passes **1,285
complete native/WASM responses**, including all 1,081 preceding requests and 204
new selections across all 17 targets, both widths and layouts. Independent full
response and receipt-hash auditing passes. Exactly 1,027 preceding responses are
identical. The 54 intentional deltas contain only the Clojure runner's exact
updated bytes in 48 artifact responses and its independently recomputed content
and manifest digests in six migration-generation receipts. No response fields
were removed. The corrected installed package smoke passes: installed API law
expansion, structural APIs across all 17 targets, widths and layouts, and Rust
scaffolding, doctor, adapters, execution and regeneration. The frozen
current-package catalog export passes its complete adapter-preservation,
edited-test protection and path checks in 7,143,784.925 milliseconds. All 266
frozen package file hashes remain unchanged after execution. This is the frozen
model-layer-selection package; later package snapshots retain their own runs.
The final iteration gate is not claimed.
Evidence is under
`.artifacts/model-layer-selection/` and `.artifacts/model-layer-integration/`
in the isolated model-layer-selection worktree. An older manifest assertion
assumed every entry was a law test family; it now distinguishes exact model slots
and retains source-name checks for both. Initial missing-generation and dependency
preparation failures remain recorded separately.

The standard release-tool audit also found stale interface consumers. Package
smoke still requested schema 3, and the standard parity script sent archived
syntax through canonical entry points, permitting matching request rejections
to stand in for generation coverage. Both now use explicit migration entry
points for archived source and canonical requests for canonical source. Parity
requires accepted codec generation on every target, width and layout, checks
actual out-of-range rejections and loads all versions of the canonical package
example's dependencies. Earlier custom, anchored full-response parity receipts
remain separate evidence; the defective standard script does not establish
accepted generation coverage. Corrected public-tool runs are recorded separately
from their initial fixture/profile failures. The corrected tool passes **297
complete legacy-mode responses** (227 accepted, 70 rejected) and **303 complete
canonical-mode responses** (231 accepted, 72 rejected). Each run includes 221
accepted generations and 68 expected generation rejections, with required codec
output on all 17 targets, both widths and layouts, plus the complete canonical
package dependency graph. The wider evidence-view audit remains open: persisted
native model completions must be reconciled with aggregate typed model
obligations without turning sampled checks into proofs. No release designation
or tag is authorized by this checkpoint.

### Reordered shared-index body correspondence — 17 October 2026

The comparison can now justify an index measure changing which equal-indexed
sibling it reads after record regrouping. A temporary Boolean definition compares
the two branch results under the constructor's checked invariants. Its result
contract must be proved by the existing ordinary definition validator. Only pure
structural storage reads in self-measure calls may differ; dispatch, arithmetic,
interfaces and other calls remain identical. Other changed callees cannot be
hidden by this rule. Both originals retain mandatory admission and termination,
and the rewritten comparison copy is validated again. The helper is never emitted.

The precedents are [Why3's pure lemma-functions and cloning obligations](https://why3.gitlabpages.inria.fr/why3/syntaxref.html)
and [Lean's structural and well-founded recursion](https://lean-lang.org/doc/reference/latest/Definitions/Recursive-Definitions/).
LawSpec uses its existing contract prover and constructor invariants, with target
termination supplying the well-founded recursion boundary for the equal branch
equations. This remains a trusted compiler transformation. It adds no solver
binding, evaluator, proof-kernel integration or independent certificate.

The focused compiler suite passes **35 cases**, including both widths, two
independent indices, arithmetic mutation rejection and an independent
counterexample: without a sibling equality invariant, the two reads return
heights one and two on the same unbalanced tree. The migration SDK case accepts
all **17 configured target emissions at both widths**, matches executable,
definition-template and law-template bodies, and confirms the separate refusal
to write when the generated `Tree@index` refinement law lacks uniform input
population evidence. Body correspondence does not establish a legal tree for
every natural index. That unbounded population requirement remains open; it is
not replaced by finite samples or by this body proof.

The optional `indexMeasureBodies` receipt records affected definition identities,
before/after body digests and the proof basis. Public types and documentation
describe that comparison-only scope. Full compiler regression passes **2,203
tests** with zero failures. The SDK suite excluding archived catalog export
passes **471 of 475 tests**, with zero failures and four explicit opt-in skips.
Those four checks also pass in separate Rust, Haskell and native-failure runs;
the five-test failure suite includes Rust and Clojure execution with no skips.
All 129 generated files, 234 module boundaries, six editor tests, version
consistency, artifact integrity and documentation checks for 119 pages and 115
snippets pass.

All **eight focused complete native/WASM responses** agree for reordered
single-index and two-index bodies and changed-equation rejection at both widths.
The new WASM artifact is 72,749,372 bytes, SHA-256
`46fe8c746f8466d16ca27aa64992e44113df55220cd9cb009bb489a0cacba3be`.
The completed full replay passes **1,081 complete native/WASM responses**.
All **999 preceding responses are identical**, with no fields or fingerprints
removed. The 82 additional responses cover both-width body-equivalence and
changed-equation cases plus complete project-report compiler requests across all
17 targets. Both project reports match executable, definition-template and
law-template bodies, accept every configured emission, and retain the independent
uniform-population write blocker. Independent receipt-hash and full-response
auditing passes. Final iteration checks are not claimed here. Evidence is under
`.artifacts/migration-acceptance/` in its isolated worktree. Initial test-harness
and API-layout failures, corrected runs and exploratory proof attempts remain
recorded separately.

The migration acceptance inventory now distinguishes these concrete cases:

| Case | Established behavior | Remaining limit or required work |
|---|---|---|
| Reordered index measures | Checked branch-body correspondence, both widths and independent indices | Unbounded generated-refinement populations remain a separate write blocker |
| Grouped indexed, GADT and existential payloads | Concrete checked transport and witness factories | Abstract branch admission and field-only existential matching retain their source limits |
| Unused polymorphic definitions | Complete symbolic body and requirement comparison | Projects with no accepted nonempty target artifacts still cannot write |
| Generic input populations | Parameter-independent witnesses and complete finite parameter populations | Unbounded constructive witnesses and abstract function/resource-dependent populations remain unestablished |
| Dependency changes | Anchored complete package/source comparison; actual changed dependencies and stale package inputs block writes | No arbitrary dependency-equivalence claim |
| Opaque native hooks | Explicit checked layouts and original assumptions for unchanged representations | Changed opaque codecs and generator factories require independent implementation correspondence |

The 77 passing native consumers cover
[body and domain transport](templates/npm/test/migration-transport-domains.test.mjs),
[package changes](templates/npm/test/migration-packages.test.mjs),
[opaque native bindings](templates/npm/test/migration-native-bindings.test.mjs)
and [actual project writes and refusals](templates/npm/test/migration-write.test.mjs).
This inventory does not claim the remaining positive capabilities implemented.
At this checkpoint the broader coverage audit identified selective native model
generation as unfinished: `planTestingWith` rejected these units when the model
layer was unselected. The independent-selection increment above supersedes that
source limitation; its remaining verification gates are recorded separately.

The preceding typed-mapping catalog export has passed on its frozen package
snapshot, as recorded above; that is not a catalog run on this later compiler.
Readability remains deferred, all named endings belong to the following
minor, and no RC designation or tag is implied. The completion checklist remains
open.

### Grouped GADT and existential payloads — 17 October 2026

This migration increment compares grouped GADT payloads and complete
concrete eliminator bodies through canonical records. Constructor equations,
existential metadata, labels, refinements and rebuilt structural descriptors
remain checked. Existential factories retain the bindings inferred from actual
constructor arguments while packing their record payload. The existing
structural parameter matcher supplies candidates only: full normalized type
equality and ordinary Core validation must still admit every conversion.
Nominal identities are never opened by this matcher.

The native regression exposed runtime Text witness fields being rechecked as
logical constructor arguments. Public emission now validates logical definition
bodies and contracts before representation lowering. Internal emission paths
retain a checked logical projection of those materialized constructors: every
trailing witness must exactly match the type inferred from the logical fields.
The original materialized contracts remain available for runtime enforcement.
Forged witnesses and already lowered plans supplied as logical public inputs
are rejected. No definition category becomes unchecked.

Go and Haskell's native profile traversal now follows known fields through
records containing open constructor-local witnesses. Their public root types
remain closed, and actual value validation still requires the witness. Separate
native regressions retain architecture-mismatch rejection for a known IntSize
field alongside the hidden carrier; skipping an entire open record would lose
that check.

The precedents are [Idris 2's dependent pairs](https://idris2.readthedocs.io/en/latest/tutorial/typesfuns.html#dependent-pairs)
for explicit witness scope and [Lean's elaboration, kernel checking and compilation pipeline](https://lean-lang.org/doc/reference/latest/Elaboration-and-Compilation/)
for checking logical terms before runtime lowering. LawSpec reuses its existing
constructor instantiation, record normalization, typed admission and native
codecs. These compiler transformations remain trusted; no Lean certificate,
new solver binding or independently checked proof backend is introduced.

Focused checks pass 37 migration cases and 17 structural-payload cases.
Native checks pass across all 17 targets at 64-bit readable and 32-bit compact
output: 34 target/profile passes and 68 deliberate carrier-mutation rejections.
Go and Haskell's separate known-machine-field cases pass at the host width and
reject the mismatched profile. Native and WASM SDK checks each pass all
three new tests, including six validated all-target project writes across both
widths and refusal to write unsupported generic GADT eliminators. Native checks
are bounded implementation conformance, not proofs of universal laws.

The full compiler suite passes **2,178 tests**. The SDK suite excluding the
separately running archived-catalog export passes **470 of 474 tests**, with
zero failures and four explicit opt-in skips. Separate Rust and Haskell layout
checks and all five native-failure SDK checks pass, covering those four skips,
including Rust and Clojure execution. All 129 generated files, 233 module
boundaries, six editor tests, version consistency, artifact integrity and
documentation checks for 119 pages and 114 snippets pass.

Native/WASM parity agrees on **852 complete responses**. Of the 778 preceding
responses, 698 are identical. Independent auditing limits the 80 changed
responses to the exact Go/Haskell runtime source changes and their corresponding
artifact manifests; other generated bytes and response fields are unchanged.
The 74 additional checks cover both-width migration cases and all 17 target
generations at both widths and layouts. Three new 32-bit probes retain a saved
64-bit exploratory response for context; those profile differences are not
prior-compiler regressions. Compiler hashes are checked around the complete
replay and the final developer-tool build.

Evidence is under `.artifacts/gadt-payload-transport/` in the payload-transport
worktree, including `native-acceptance-receipts.json`, `parity/receipts.json`
and `parity/audited-deltas.json`. Initial source/native failures and superseded
or interrupted runs remain recorded separately. An additional replay of
Chapter 6's **72 published-authoring responses** also passes: 64 responses are
identical and eight differ only in the independently audited Go/Haskell runtime
sources. All 68 generations across the 17 targets, both widths and layouts are
accepted. These two replays cover **924 complete native/WASM comparisons**;
Chapter 6's source inventory and original-source digest remain unchanged.

The complete catalog export remains in progress. It reads a frozen package copy
so later work cannot change its inputs. That pending check and the final
iteration release check are not claimed complete by this checkpoint.

Generic GADT symbolic roots remain unestablished when an abstract branch cannot
be admitted. Pure source matching of field-only existentials remains an existing
limitation in both source profiles. A project with only unused polymorphic
definitions can compare symbolically but still lacks accepted nonempty target
generation; the project writer conservatively refuses that case. The positive
generic-factory project therefore includes a real concrete caller. None of
these limits is hidden by a matching payload shape. Reordered shared-index
measure bodies, broader uniform populations, dependency changes and opaque
hooks remain separate migration acceptance items. The minor completion
checklist stays open; readability remains deferred, all-named endings belong
to the following minor, and no tag or RC designation is implied.

### Chapter 6 authoring — 17 October 2026

The published specification now uses six checked mappings for computation,
destination and jump spellings and bits. Its source and reference functions use
phrase names, every law has a domain description, and `AssemblyRuns` names its
first, second and repeated-first output fields. The adapter remains
`assemble :: Text -> List Text`. Explanations of physical output and the
independent structured reference live in the accompanying README.

The inventory remains **23 laws, 65 expectation-table rows, one named example,
25 authored definitions, seven ADTs and two refinements**. Six of those 25
definitions are mappings; their inverse/preimage helpers are additional lowered
definitions. The 88 mapping rows are separate from the 65 expectation rows.
The source passes ordinary admission and idempotent formatting. No compiler,
solver, evaluator or trust boundary changed for this authoring pass.

The oracle runner first validates and writes the original semantic migration,
preserving its source separately. It then adopts the published authoring pass
and records its different source hash explicitly. It does not claim unchanged
complete-source fingerprints for the manually improved authoring. The original
Chapter 6 source and its fixture retain SHA-256
`07d8116b847aa80e044ad3ea2cbc8317bc949a0c4fe07b560e513d6fa0bfaf06`.

Four independent runs pass: native and WASM compilation at 64-bit readable and
32-bit compact output. Each exercises all 23 laws through **16 property tests,
453 boundary checks and 66 examples**, with ten replay hooks recorded separately.
Each compares **32,768 A addresses, 1,792 C combinations and thirteen stateful
programs** with independent oracles and rejects all six mutants, including the
changed checked computation table. Repeated calls remain independent, and the
symbol-table-leak mutant is rejected. These are finite codec and Python native
conformance receipts, not proofs of the unbounded laws or implementations in the
other sixteen languages.

Native/WASM parity agrees on **72 complete responses**, including **68 generation
requests across all 17 targets, both machine widths and both output layouts**.
Repeated checking after those generations returns the same complete response.
Documentation checks pass for 119 pages and 114 snippets; all 128 generated files, 233 module
boundaries, artifact integrity and version consistency pass. The compiler bytes
are unchanged from the typed-failure checkpoint, whose 2,171-test compiler and
SDK/native receipts remain the implementation baseline. Evidence is under
`.artifacts/chapter6-authoring/` in the Chapter 6 authoring worktree.

The remaining coverage audit, migration acceptance cases and complete iteration
release check remain open. Human readability remains user-deferred, complete
named endings belong to the following minor, and the larger Chapter 6 portfolio
across all 17 languages remains pre-final-1.0. Version 0.24.0 has no RC designation
or tag.

### Symbolic helper types in typed-failure migration — 17 October 2026

The typed-failure documentation example now has complete symbolic law-template
correspondence. Its source capture retains an inference variable in the result
annotation added for `prelude.attempt`. Comparison previously turned that local
variable into a rigid declaration parameter before ordinary inference could
identify the result as `Int32`. Only declared parameter, capability and resource
type variables now acquire that rigidity; already rigid lexical carriers retain
their law-specific scope. Local helper inference variables remain flexible until
the existing checker resolves them. Complete typed terms, metadata, population
policies and transported-copy validation still participate in correspondence.

The precedent is the distinction between bound parameters and elaboration
metavariables in [Lean's expression implementation](https://github.com/leanprover/lean4/blob/master/src/Lean/Expr.lean)
and its [elaboration/checking boundary](https://lean-lang.org/doc/reference/latest/Elaboration-and-Compilation/),
alongside [Why3's polymorphic type expressions](https://why3.gitlabpages.inria.fr/why3/syntaxref.html#type-expressions).
LawSpec reuses its existing inference and validation, which remain trusted;
this adds no solver integration, external proof checker or proof certificate.

All **33 focused payload/migration compiler regressions pass**, including both
machine widths, changed-message rejection and existing symbolic generic/Eq
checks. The real project writer migrates the complete typed-failure fixture,
including its two laws and named example, with all **17 target configurations**
in separate native- and WASM-backed runs. Both runs retain unestablished native
conformance and law verification. The tests preserve no-selected-checks reporting
and mandatory definition checks after writing. Documentation checks pass for
119 pages and 114 snippets; six editor checks, all 128 generated outputs,
233 module boundaries, version consistency and artifact integrity pass.

The final compiler regression passes **2,171 tests with zero failures** in
790.1617 seconds. The SDK run excluding the separately running archived export
passes **467 of 471 tests**, with zero failures and four opt-in native checks
skipped, in 698.3088 seconds. Those four checks then pass explicitly: Rust and
Haskell layouts each pass, and the five-test native-message suite includes
passing Rust and Clojure execution with no skips. This is coverage across runs,
not one uninterrupted skip-free SDK run.

Native/WASM parity agrees on **778 complete responses**, including 68 generation
requests across all 17 targets, both widths and both layouts. All 704 preceding
responses were replayed; only the two expected typed-failure migration
comparisons change. Their complete before/after pairs retain the newly matching
law-template and source-unit evidence. Every compared generated artifact is
unchanged. The replay resumed after its added generation probe omitted matching
destination settings; the rejected request remains recorded, and the corrected
requests pass. Frozen compiler hashes are checked around the completed replay.

Logs and the complete before/after reproducer are under
`.artifacts/attempt-template-types/` in the attempt-template worktree. The first
new compiler test accidentally left its destination at the default machine
width; its corrected two-sided requests pass. The superseded failed focused
receipt and interrupted full run are retained separately. The earlier archive
jobs remain active in their frozen worktrees; this receipt does not claim their
completion or the complete iteration release check.

This supersedes the historical symbolic `attempt` blocker below. Reordered
shared-index measure bodies and grouped GADT/existential payload transport remain
open. Uniform populations beyond the existing finite and parameter-independent
cases remain limited; changed dependencies and opaque native hooks still cannot
authorize writes without correspondence. Fresh grouped GADT and existential
probes admit both sources but reach the explicit unsupported transport guard.
Chapter 6's second authoring pass and the final iteration gates remain required.
The original Chapter 6 bytes are unchanged. Readability remains user-deferred,
all-named endings remain the following minor, and version 0.24.0 carries no RC
designation or tag.

### Indexed payload migration increment — 17 October 2026

Grouped natural-index payloads now have a checked field-to-record-path correspondence. It preserves the full index path, the final index selector, constructor equations and definedness guards. The candidate product's shared-index equalities must follow from the original constructor guards; field types, refinements and the complete structural descriptor are independently rebuilt from the original checked source. Equality-class normalization retains every required index read. Changed equations, missing equalities, exchanged selectors and stronger product restrictions remain unestablished.

The transported comparison copy still passes ordinary definition validation. Comparison can replace a pure projection of already evaluated structural storage with a direct read; capture, inconsistent annotations and dependent uses prevent that reduction. Existing effect-order and once-only tests remain passing. This extends compiler-trusted representation correspondence, following explicit equivalence and inverse-layout reasoning in [Lean's `Equiv`](https://github.com/leanprover-community/mathlib4/blob/master/Mathlib/Logic/Equiv/Defs.lean) and the definition-preservation boundary of [Why3 module cloning](https://why3.org/doc/syntaxref.html#module-cloning). It produces no Lean proof certificate or new solver integration.

Validation passes 2,057 compiler tests, 167 native migration-consumer tests, 198 WASM-backed consumer tests, all 122 generated-file checks, 232 module-boundary checks, six editor tests, version and artifact-integrity checks, and documentation checks for 119 pages and 114 compiled snippets. Native/WASM parity agrees on 1,844 complete responses and six migration reports, including 1,352 accepted generation requests across all 17 targets, both machine widths and both layouts. All compared generated bytes agree with the frozen `0da8cc42` compiler. The ten intentionally changed migration-comparison responses are retained as complete before/after pairs; every other compared response is unchanged. This generation evidence does not establish native implementation conformance. The original Chapter 6 source retains its recorded SHA-256 digest.

This increment does not complete indexed migration acceptance. Reordered shared-index measures still need justified body correspondence; grouped GADT/existential transport remains open. At that checkpoint, symbolic law-template admission rejected the abstract index value parameter represented by a call inside a refinement predicate. Uniform input-population evidence, complete source-template correspondence and native representations remain independent gates. A matching concrete payload transport alone does not authorize project writes. The completion checklist above remains open.

### Formal values in law templates — 17 October 2026

The typed law now retains formal value binders separately from sampled inputs, before those inputs in lexical scope. This removes the zero-argument-adapter encoding of abstract index values without weakening refinement or definition admission. Own restrictions, left-to-right dependencies, named expectations and source metadata remain. Function parameters retain their existing abstract symbols; no function implementation or witness is invented. Native test planning rejects uninstantiated formal values. The existing SMT translation quantifies them before canonical universal inputs and retains its nonempty-policy limitation.

The precedent is [Lean's section variables and declaration parameters](https://lean-lang.org/doc/reference/latest/Namespaces-and-Sections/#section-variables) and [Why3's bound logical variables](https://why3.org/doc/syntaxref.html#terms-and-formulas). This is typed compiler translation, not a new solver integration or an independently checked proof certificate. All ordinary definitions retain their mandatory validation.

Population evidence carries the formal parameter count. A verified input witness independent of the formal values has an explicit `parameter-independent` uniformity marker; SDK acceptance requires both that marker and the matching parameter scope. This does not claim existence of parameter values or truth of the law. At this checkpoint, parameter-dependent populations remained unsupported pending complete parameter analysis or constructive uniform witnesses. No single sampled parameter is substituted for that obligation. The remaining indexed, existential, migration, interface and final acceptance gates above stay open.

Validation passes 2,064 compiler tests, including 21 input-domain and 30 payload-shape tests; 170 native migration-consumer tests; and 201 WASM-backed consumer tests. All 122 generated-file checks, 232 module-boundary checks, six editor tests, strict TypeScript consumer checks, version and artifact-integrity checks pass. Documentation retains 119 checked pages and 114 compiled snippets. Native/WASM parity agrees on 1,922 complete responses and six migration reports, including 1,420 accepted generation requests across all 17 targets, both widths and both layouts. All compared generated files agree byte for byte with the frozen `033a71c1` compiler. The 970 changed complete response pairs retain the expected typed-Core fingerprints, formal scope and domain-evidence changes; their payload and before/after hashes are independently audited. This is generation correspondence, not a new native-conformance run. Evidence is under `.artifacts/minor-law-formal-values/` in the migration-transport worktree. The shipped WASM is 72,122,640 bytes, SHA-256 `dda8af7e65102583d9c3e79d2f2166364b5b9cd2a5d3471d0d9e75e9415c8cd5`. Chapter 6 retains its recorded bytes and digest. This remains a minor-version checkpoint without a tag; the iteration checklist stays open.

### Complete finite parameter populations — 17 October 2026

Parameter-dependent input populations now reuse the existing complete logical covers, closed evaluator and ordinary value/refinement checker. Formal binders are visited left to right in their actual earlier-value environment, with every restriction rechecked. A positive result retains a separate input witness for every admissible finite parameter tuple. A complete empty formal domain is explicitly vacuous; an admissible formal tuple with a complete empty input domain is a population counterexample, not a refutation of the law. Evaluation failures, unbounded or unsupported covers and the combined candidate limit retain inconclusive or unsupported results. No law body is evaluated.

Source-template domain copies use the same checked formal binding translation as full law-template transport. Additional source argument-admissibility checks, resource dependencies and abstract-function-dependent populations remain unsupported. The SDK requires matching scope, complete finite evidence and dependency anchors before accepting a population-policy change. Matching empty formal domains may establish vacuous population correspondence without claiming parameter inhabitance. The complete source, native binding and behavior gates remain independent.

The precedent is [Mathlib's `Fintype` complete finite enumeration and decidable universal/existential quantifiers](https://github.com/leanprover-community/mathlib4/blob/master/Mathlib/Data/Fintype/Defs.lean), together with the bound-variable semantics already recorded above. LawSpec reuses its existing machinery; the cover generator, evaluator and typed admission boundary remain trusted. This adds no solver integration, independent proof checker or Lean certificate. Constructive uniform evidence over unbounded parameters, the remaining indexed/existential migration cases, interface cutover and final acceptance checks remain open.

Validation passes 2,071 compiler tests, including 28 input-domain and 14 source-domain tests; 173 native migration-consumer tests; and 204 WASM-backed consumer tests. All 122 generated-file checks, 232 module-boundary checks, six editor tests, strict TypeScript consumer checks, version and artifact-integrity checks pass. Documentation retains 119 checked pages and 114 compiled snippets. Native/WASM parity covers 1,958 complete responses and six migration reports, including 1,420 accepted generation requests across all 17 targets, both widths and both layouts. All compared generated files agree byte for byte with the frozen `8a8149eb` compiler. The four changed responses in the preceding 1,922-response suite are retained as complete migration-comparison pairs. The 36 new finite-population responses retain complete prior/current pairs separately. The combined parity script completed all preceding assertions before a malformed legacy `=` restriction in its new section failed; the corrected entire 36-response section passes independently, with unchanged compiler artifacts. The final full compiler run passes after updating the superseded unsupported-domain expectation. This evidence establishes generation correspondence, not a new native-conformance run. Evidence is under `.artifacts/minor-finite-parameter-domains/` in the migration-transport worktree. The shipped WASM is 72,175,021 bytes, SHA-256 `d6bb22aae751fe2c997dd61f30b6e7613b9f35729cb6db86000fa6649e7b76ec`. Chapter 6 retains its recorded bytes and digest. This remains a minor-version checkpoint without a tag; the iteration checklist stays open.

### Canonical native payments and phrase-law execution — verified checkpoint

The exported payments example now uses canonical records, explicit alternative payloads, named function/case endings and phrase laws, with its three requirements and seven named examples retained. Its 17 project configurations use version 2, the explicit language profile and the six verification layers preserving the previous checks. The 15 native type-binding targets have checked binding proposals for the payload-field name change. C# and Clojure explicitly adopt the canonical generated model data; automatic migration continues to reject their changed generated public representation rather than claiming ABI compatibility. The legacy catalog specification remains available pending the wider catalog cutover.

Installed-project validation exposed an authoring-interface defect in JavaScript/TypeScript execution evidence: the installed Node JUnit reporter double-escapes quotes, so canonical phrase-law names could not match their execution reports. LawSpec now consumes [Node's structured reporter stream](https://nodejs.org/api/test.html#custom-reporters), preserving exact names and keeping literal XML entities distinct from quotes. An invocation nonce, format version, row count and final seal reject stale or interrupted reports. Skipped/todo cases do not count as passes; failures remain failures. JUnit export is projected from those exact events. The native runner remains trusted execution infrastructure, not an independently checked proof or exhaustive law verification. Node test contexts are isolated when a native run is launched inside another Node test run.

The native integration harness uses returned law identities when checking invalidation and replay; Scala's offline invocation explicitly enables its required power mode. Distribution integrity now checks every canonical example's staged npm copy. All 17 installed CLI/native flows passed at 64-bit readable output, including wrong-fee mutation, selective invalidation, failure replay and ownership. All 142 complete native/WASM responses matched: normal generation and migration generation cover every target at both machine widths and both layouts. The full SDK catalog passed 443 checks with three opt-in native layout checks skipped; those Rust, Go and Haskell checks then passed separately at both widths and layouts. The focused 31 execution-command checks, 44 native-binding compiler checks, one C# check, 232 boundary checks, six editor checks, 119 documentation pages with 114 snippets, generated files, version and integrity checks passed. Compiler sources and native/WASM compiler bytes remain unchanged from the preceding checkpoint; the integrity manifest changes only its extra-source-file packaging fingerprint. Chapter 6 remains unchanged. Execution conformance does not establish a model proof. This advances public-consumer migration; the schema/profile cutoff, remaining catalog and documentation consumers, Chapter 6 second pass and full iteration acceptance remain open. No release-candidate designation or tag is implied.

### Public API and environment evidence — implementation underway

The isolated public-interface cutover requires schema 5 and an explicit technical language profile on ordinary API calls; no selected law layers is the default. Configuration version 1 remains migration input. Ordinary CLI commands, project formatting and the language server direct old projects to migration. Frozen 0.24 regression fixtures and the archived specifications catalog use the explicit migration entry rather than permissive canonical parsing. Canonical exported native payments use ordinary requests.

Planned environment wiring is represented separately as `plannedEnvironment`, `plannedEnvironmentRun`, `plannedAgainst` and dependency `plannedObligations`. These do not claim execution or change the law status. The CLI shows planned, unverified, incomplete and unsupported obligations; it reports historical passing native runs with their timestamps and seeds separately from the current plan. A passing record may link its own attestation, without attaching another law's unexecuted plan to that historical run. Node's native execution receipt remains trusted runner evidence, not a proof certificate.

This cutover is not yet shipped or accepted. Its focused checks include 105 SDK regressions, six compiler boundary checks, 44 native binding request checks, 12 API contract checks, seven environment checks and eight complete native/WASM comparisons. Remaining package, historical CLI, documentation/playground and public-consumer migrations, full regression/parity runs and distribution fingerprints must pass before this isolated change reaches main. The verified payments checkpoint above has been pushed separately. The iteration remains a minor version; readability remains user-deferred, all-named endings remain the following minor, and pre-final-1.0 gates remain open.

### Public-interface verification and documentation audit — in progress

The first full compiler run for the interface cutover passed 2,077 examples.
The SDK run excluding the separately scheduled archived-catalog export passed
453 tests, skipped two opt-in native layouts, and failed one overstrict test
assertion: a restored constant law may be either proved or exhaustively checked.
That assertion is corrected; these numbers precede the later proof changes and
are not final acceptance of the current tree.

Package migration now previews and validates declared dependency sources as well
as project sources. Atomic writing observes package manifests and complete source
inventories, rejects stale edits and newly added sources, and confines dependency
writes to the explicitly observed source paths. A finite package fixture passes
correspondence and writing; the manually adopted canonical orders demonstration
retains conservative refusals for unestablished generic reusable-law populations.
The package parity run matched 70 complete native/WASM responses, including 68
generation requests across every target, width and layout. This is generation
correspondence, not execution of those generated projects.

The documentation audit found additional canonical-language gaps rather than
hiding complete examples as fragments. Canonical case predicates now retain
their constructor facts for definition admission; strict and relaxed range
predicates and an independently zero denominator are regression cases. Canonical
constructor matchers reuse the existing ordered pattern matrix, including nested
records, tuples and wildcards. Fourteen focused matcher tests pass at both widths.
Migration now records positional matcher spans for payload rewriting. The complete
matcher documentation example has an admitted canonical preview and validated
migration correspondence. Indexed payload proof views and documentary typed
failures remain under investigation. The indexed concatenation reproducer exposes
a generic measure using a different structural payload identity from its concrete
input. The unsuccessful proof-view and continuation changes were removed; no
projection identity was equated without typed correspondence and no result
contract or recursive-descent check was weakened.
All seven lesson targets (JavaScript, Java, Python, TypeScript, F#, C# and Swift)
now pass their correct adapters and reject their stub and eight mutants: 56
mutants and seven stubs in total. The first offline F# invocation lacked restored
NuGet imports in its fresh project. The acceptance harness now restores from the
local global-package cache, disables network auditing for that offline restore,
and then runs the selected Microsoft test platform; F# and C# both pass after
that correction. Scala's offline invocation also enables its required power mode.

The rebuilt WASM matches 142 complete native responses: 72 matcher responses and
70 package responses, including 136 generation requests across all 17 targets,
both widths and both layouts. Saved response hashes are independently audited.
All 125 generated files, 232 boundary modules, six editor checks, version and
artifact-integrity checks pass. The editor's first invocation lacked its local
dependency link; the six checks pass with the existing locked dependency cache.
The full compiler rerun completed 2,097 examples with zero failures and 16
solver-dependent pending cases. After installing Z3 5.1.0, all 22 native SMT
checks pass, covering those 16 pending cases. The SDK run excluding the archived
catalog export completed 457 tests: 449 passed, zero failed and eight skipped.
All eight skips subsequently pass in targeted reruns: the two native Rust/Haskell
layout checks at both widths and layouts, and six real-solver checks in the
ten-test SMT SDK suite. These counts retain the original run's limits and the
separate rerun receipts rather than rewriting its reported totals.

The documentation rerun still rejects the indexed-family and typed-failure
pages; the remaining fragment and prose migration, archived export and complete
release checks remain open. These are checkpoint results, not milestone
acceptance. This isolated work has not been pushed to main or tagged.

Proof precedent: [SPARK quantified expressions](https://docs.adacore.com/R/docs/gnat-25.1/spark2014/html/spark2014_ug/en/source/specification_features.html#quantified-expressions)
separate definedness obligations from quantified truth;
[Lean's quantifiers](https://lean-lang.org/doc/reference/latest/Basic-Propositions/Quantifiers/)
distinguish universal functions from existential witness/proof pairs, and its
[empty type](https://lean-lang.org/doc/reference/latest/Basic-Types/The-Empty-Type/)
shows why a generic parameter does not establish inhabitance. Generic-population
refusals remain conservative. [Lean's reduction rules](https://lean-lang.org/doc/reference/latest/The-Type-System/)
and [Why3's typed pattern matching](https://why3.org/doc/syntaxref.html#conditionals-let-bindings-and-pattern-matching)
provide the constructor-reduction and shared-desugaring precedents for the proof
view investigation. LawSpec still uses its existing typed proof projection and
arithmetic checker. No new Z3 binding, Why3 backend, Lean integration or independent
proof certificate is claimed. Strict definedness and termination admission remain
mandatory, and proof simplification must not erase those audits.

### Failure messages in explicit record payloads — current increment

Canonical `message contains` now reads a `Text` field named `message` from an
alternative's anonymous or named record payload, including generic records
instantiated with `Text`. Existing direct message fields remain supported.
Other text payloads and numeric fields named `message` do not acquire this role.
The expression lowers to ordinary typed matches, projections and substring
checking. It introduces no unchecked definition category or solver mechanism.

Migration preserves a legacy message label in an explicit record even when it
is the alternative's only field. The existing product transport now handles
one-field grouping as well as multi-field grouping. It still rebuilds and
compares the complete descriptor, labels, field types, restrictions and index
relationships, and validates the transported Core. Pure renaming remains a
separate case. Native binding proposals retain the original native argument
position and field name through the new `value.message` path. Changed labels,
additional fields and stronger restrictions do not establish correspondence.

The finite message fixture passes complete source correspondence at both
widths, including construction, projection, update, pattern matching and
independent expected outcomes. The larger typed-failure documentation example
now admits canonical source and runs correctly. Its automatic project migration
remains blocked by symbolic law-template `attempt` type correspondence; matching
concrete Core alone does not authorize writing. The documentation adoption was
manual, not a claim of validated automatic migration.

Checks pass 26 canonical matcher examples, 32 payload-shape examples, 36
legacy law-primitive examples and 44 native-binding request examples.
The focused WASM SDK run passes all 41 tests
without skips. A real JavaScript run passes eight checks, rejects a changed
model message and passes after restoration; this scenario is retained as an
SDK regression using the acceptance dependencies. All 106 complete native/WASM
responses match, including 68 generation requests and 34 binding proposals
across all 17 targets and both widths. Generation also covers both layouts.
These are generation/binding results, not native execution on all 17 targets.
All 126 generated files, boundary, editor, version and integrity checks pass.
The previous full regression receipts apply to checkpoint `5ae3db6`; the full
compiler/SDK and release runs still need repeating on the final implementation.

The documentation check now rejects only the indexed-family page. Automatic
native exception mapping into a record payload remains unavailable; adapters
can raise the runtime's `Fail` with an explicitly constructed record. The
published reference states this limit. The indexed proof correspondence,
symbolic `attempt` correspondence, automatic exception mapping, documentation
fragments, archived export and remaining minor acceptance checklist stay open.
No main push, milestone completion or tag is implied by this increment.

### Typed product projections in indexed definitions — 17 October 2026

Canonical indexed-vector concatenation now passes mandatory definition admission
with an explicit record payload. The source-template and closed-Core audits
retain a product's checked type through pattern-binder freshening. A generic
product projection can use a concrete instance only after the existing rigid
actual-type matcher and structural-record instantiator rebuild the complete
same descriptor, including refinements and dependent relationships. Links are
directed, are not transitive, and do not equate nominal types. Digest equality
alone, matching field arity, and an unrelated stronger record do not establish
this relation.

The existing proof normalization also keeps a single-constructor conversion's
consumer in its branch and reduces projections of known constructed products.
It freshens binders before moving the continuation and retains the independent
strict definedness walk. Recursive descent follows stored fields; arbitrary
call results do not inherit their arguments' descent. The mechanism follows
typed record projections in [Why3's language reference](https://why3.org/doc/syntaxref.html#type-declarations)
and constructor elimination in [Lean's inductive types](https://lean-lang.org/doc/reference/latest/The-Type-System/Inductive-Types/).
The LawSpec type matcher, descriptor builder, capture-avoiding substitution and
existing proof projection remain compiler-trusted. This adds no Why3 backend,
Z3 binding, independent proof checker or unchecked definition category. The
existing SMT integration still invokes an external solver through SMT-LIB.

The full compiler run passes **2,128 tests with zero failures**. Regression
coverage checks 49 independently computed vector-concatenation outcomes at each
machine width, dropped heads, wrong tails, a strict zero divisor,
non-decreasing recursion, continuation capture, non-transitive generic links,
nominal boundaries, stronger record restrictions and IEEE non-reflexivity.
The indexed-family reference and both fragments were manually adopted and
checked in context. Documentation passes 119 pages and 114 compiled snippets;
126 generated outputs, 233 module boundaries, six editor checks, version and
artifact integrity pass. Whole-source automatic migration correspondence is
still unestablished; this manual adoption does not authorize migration writes.

A further preservation regression remains explicit: the same canonical
concatenation using `Nat` elements fails its recursive-call precondition,
although the legacy positional version using an equivalent positive unbounded
integer refinement admits. Ordinary `Bool`, `Integer`, `Whole`, `Int8` and
`Float64` element versions admit. Refinement-payload provenance through product
projections needs completing; it must not be repaired by discarding refinements
or borrowing a stronger generic record contract. Reproducers and full response
receipts are retained under `.artifacts/minor-public-interface-cutover/`.

All 80 complete indexed native/WASM responses agree, including 68 generation
requests across all 17 targets, both machine widths and both output layouts.
The ten negative checks retain mandatory-admission failures, including the
known positive-refinement regression. The broad SDK run passes 458 tests with zero failures and two environment
skips; the Rust and Haskell native-layout checks then pass explicitly without
skips, covering all 460 SDK tests. The typed-failure parity rerun adds 106
complete matching responses on these same compiler artifacts, bringing this
checkpoint to 186 audited response pairs. The archived export run is still
in progress. Native execution across all 17 targets is not
claimed for this increment. Automatic exception-to-record mapping, symbolic
`attempt` migration correspondence, the remaining documentation fragments,
Chapter 6's second authoring pass and the full minor acceptance checklist remain
open. Readability is user-deferred, all-named endings belong to the following
minor, and this remains version 0.24.0 without an RC designation or tag.

### Refinement payloads through product storage — 17 October 2026

The preceding checkpoint's positive-element regression is repaired in the
isolated refinement increment. Indexed concatenation, a stored positive head,
and recursive conversion to a list now pass ordinary mandatory admission.
The proof view eliminates an already assumed payload predicate through the
existing shared parameter recipe, including nested record and list fields.
The recipe retains which type parameter owns each payload; a positive first
parameter does not strengthen a second parameter with the same erased scalar
type, a fixed field or an unrelated argument. List facts concern hypothetical
members of the same stored list and do not assert that an empty list is
inhabited.

Checked product-instance comparison now follows nested structural type
instantiation before rebuilding and comparing the complete descriptor. It
uses the existing rigid actual-type matcher, substitution and record builder.
Only structural products can be opened; nominal identities stay opaque,
repeated parameters retain one substitution, and actual variables remain
rigid. Nested constraints remain in the descriptor. If a changed nested field
type would require normalizing a stored predicate expression, this comparison
still reports no link rather than removing that predicate. Completing those
cases remains an explicit limit.

Single-result normalization keeps a product conversion's consumer inside its
typed domain and fresh constructor scope. Pure Boolean projections use the
same stored-field identity as numeric projections; known constructed fields
reduce to their checked contents. Short-circuit proof paths retain their
applicable payload facts. Hypothetical member and branch bodies are visited
only after their binders are fresh and their premises are in scope. Strict
argument, unused-field, definedness, recursion and deferred-postcondition
checks remain separate and mandatory.

The precedent remains typed projection and constructor elimination in
[Why3](https://why3.org/doc/syntaxref.html#type-declarations) and
[Lean](https://lean-lang.org/doc/reference/latest/The-Type-System/Inductive-Types/).
This extends compiler-trusted type instantiation and obligation translation;
it introduces no new solver, Why3 backend, Z3 binding or independently checked
proof certificate. Optional law verification remains a separate selection.

Focused verification passes 50 canonical predicate-fact examples and 37
record-identity examples, including Boolean, bounded positive, nested and list
refinements, unrelated arguments, parameter positions, nominal boundaries,
stronger nested restrictions, zero divisors, bad recursion, capture and IEEE
behavior. The independent concatenation oracle covers all 49 pairs of vectors
of length at most two over two element values, at both machine widths, for
both ordinary and positive elements.

The new SDK regression has passed through the native compiler API: 49 ground
outcome obligations are completely evaluated at each width, a changed
expectation is refuted, and checked definitions generate across all 17 targets,
both widths and both layouts. Actual JavaScript execution passes all 49 ground
checks, fails the changed expectation and passes after restoration. These
ground checks do not establish a universal law over arbitrary vectors.
The full compiler run passes **2,159 tests with zero failures**. The broad SDK
run passes 462 tests with zero failures and two environment skips; both Rust
and Haskell native-layout checks then pass explicitly without skips. A new
wrapper-proof regression was added afterward and passes independently,
covering all 465 SDK tests overall rather than claiming one uninterrupted
465-test run. The rebuilt-WASM refinement suite also passes all four tests.
All 127 generated outputs, 233 module boundaries, six editor tests,
119 documentation pages with 114 compiled snippets, version and artifact
integrity checks pass. Chapter 6 retains its recorded digest.

All 272 complete parity responses agree between native and WASM compilation,
including 68 new generation requests across all 17 targets, widths and layouts.
Of the 186 preceding responses, 184 are identical; the two former `Nat`
admission errors now accept. Another 22 paired responses audit proof selection
and boundary counterexamples. Every saved parity payload hash is checked.
A complete 65-source JavaScript catalog comparison retains all 232 emitted
files and all other response fields. Only the evidence for the law asserting
`UnitQuantity`'s 1–1,000 bounds strengthens from planned tests to a static proof.
That proof follows the admitted wrapper constraints. Tightening either law
bound or weakening the constructor's lower bound does not acquire a proof;
explicit valid boundary values refute the corresponding ground obligations.
Selecting no law layers reports not verified. Selecting examples alone reports
planned execution, not completed verification. The model proof does not
establish native implementation conformance. Actual execution of the new
concatenation example is established in JavaScript; all-target generation is
not an all-target native execution claim.

Evidence is retained under `.artifacts/refined-products/`. The preceding
archived-export run is still in progress against its frozen `9b76bd54`
snapshot. The minor acceptance checklist and remaining migration, automatic
exception mapping, documentation and Chapter 6 authoring work stay open;
no RC designation, completion or tag is implied.

### Canonical reference fragments and equality guidance — 17 October 2026

The reference and how-to pages now use canonical function/procedure headers,
explicit record payloads, phrase names, quantifier endings, named conditional
endings and section colons in the 19 fences flagged by the legacy-syntax
audit. Three header sketches with omitted bodies are explicitly plain text.
Generic law imports use `law` selectors, and template applications use
`apply law`. A recorded-value example is shown as a section of a law with the
corresponding input, rather than as an apparent unit-level example.
Description literal contents and recording names remain intact.

The equality guidance now distinguishes value and proposition contexts,
retains `Eq` and IEEE behavior, and explains that `must be` adds no stronger
modality. The precedence table matches the parser's named-infix, comparison,
matcher, equality and worded-logic layers. Explanations use `Integer`, `Whole`
and `Nat` consistently; zero-inclusive indices remain whole-number indices.
The explicitly labeled historical grammar and ordered-collection material
remain history.

Validation passes 18 complete contexts for the affected fragments and the
field-only existential spelling. The deliberately false positive-output law
still yields 129 `refuted` diagnostics under exhaustive checking. The
published documentation check passes 119 pages and 114 complete snippets,
with links resolving. The selected legacy-marker audit reports no remaining
matches in LawSpec fences, including four-backtick description examples.
This is manual documentation adoption and contextual compilation, not a
certificate permitting project migration writes or a claim that native
adapters have been verified.

Native compiler and WASM bytes, version 0.24.0, distribution fingerprints and
Chapter 6's original digest are unchanged from `585631dd`. That checkpoint's
full compiler and SDK results remain the regression baseline; no new full
regression run is claimed for these documentation edits. The archived export
continues independently against `9b76bd54`. Remaining migration, native
exception mapping, Chapter 6 authoring and full minor acceptance remain open.
Human readability remains user-deferred; all-named endings belong to the
following minor. No RC designation or tag is authorized.

### Native exception messages and checked input ranges — 17 October 2026

Automatic native exception mappings now construct an explicitly typed message
payload through single-field products, including anonymous records, nominal
records and concrete generic applications. Payload-free alternatives and the
existing direct Text form retain their behavior. The construction plan stores
resolved constructor identities and applied types; the existing type registry
checks each field, and record normalization retargets the entire plan. Every
target uses its ordinary construction and boundary validation. No unchecked
function category, alternative evaluator or new proof backend is introduced.

Finite nested applications such as `Message (Message Text)` descend through
proper type arguments. Repeated or growing recursive field applications are
rejected. A mapping cannot invent additional fields or select a payload
alternative. Indexed, existential and handle payloads remain unsupported by
this automatic message construction. An explicit adapter remains available.
The message is obtained once, and a refinement can reject it.

Clojure now uses the JVM binary class names from the Java data-name planner,
including single-constructor products and nested sum variants. It no longer
reconstructs a class name from a source tag. Its runtime constructs the checked
product chain before the existing failure codec validates the value. Rust now
validates a mapped dynamic failure against the full schema before exposing it
as the declared failure. A native Rust probe also executes a message refinement
that calls a checked LawSpec function.

The native matrix exposed a separate generation defect: schema-checked
construction could discard the constant integer intervals already present in
a law's input plan. The fix reuses `LawSpec.Bounds.inputRange` and the existing
bounded primitive generators in Python, JavaScript, TypeScript, Java, Groovy,
Clojure, Go, Kotlin, Scala and Haskell. Each input supplies its own primitive
fallback; a record field of the same primitive type retains its own
restriction. Explicit native factories, schema validation and the complete
dependent predicates remain in place. This changes sampling, not the law or
its proof obligations. Increasing discard limits is not the fix.

Two permanent acceptance suites cover native exception records and independent
and dependent input intervals. All 17 targets pass both CI profiles (64-bit
readable and 32-bit compact): **68 successful suite runs**, each rejecting its
two mutants (**136 rejected mutants**). The interval suite includes separate
positive and negative Int64 inputs, a negative Int64 record field, and a
relationship between two inputs. The native exception suite retains distinct
native and specification handlers. These are sampled native execution results,
not universal proofs or complete finite evidence.

The focused compiler suite passes **19 tests**. All 17 targets, both widths and
both layouts also participate in complete native/WASM response comparisons,
including deep generic message construction and rejected recursive shapes.
The original Chapter 6 source retains SHA-256
`07d8116b847aa80e044ad3ea2cbc8317bc949a0c4fe07b560e513d6fa0bfaf06`.
Artifacts are under `.artifacts/checked-input-ranges/` in the
`lawspec-minor-checked-input-ranges` worktree. Earlier failed generation runs
remain under `.artifacts/native-message-products/` in the preceding worktree;
those failures are not passing evidence.

The full compiler run passes **2,170 tests with zero failures** (783.7 seconds).
The broad SDK run passes **466 of 470 tests**, with zero failures and four
explicit environment selections skipped. Those four selected tests also pass
when run in their required environments: the existing Rust and Haskell native
layout tests and the new Rust and Clojure message tests. The separate five-test
message run has no failures or skips; this is coverage across runs, not a
claim of one uninterrupted skip-free SDK run.

Complete native/WASM parity agrees on **704 responses** (628 regression and
fixture responses plus 76 deep-message responses). All 486 preceding responses
are retained in full. The 32 changed generations differ only in generated
file fields, and only for the seven targets served by the additional scoped
primitive fallbacks; typed obligations and other response fields are unchanged.
The 128 generated files, 233-module compiler/backend boundary, six editor
tests, version consistency, artifact integrity and documentation checks for
119 pages/114 compiled snippets pass. The staged WASM artifact has SHA-256
`82c4ce63d38157ebfd54ebf2942d594086747bb25694e9cab84581d2ec14beab`;
the native core has SHA-256
`872d00ac94b0657110778b46e86942bf405dbb65887da06bfe20b0500b578c95`.
Both unsigned pointer conversions are verified in the generated WASM glue.

The current archive/export run remains in progress against these frozen
sources. The earlier archive/export baseline at
`9b76bd54` passed its complete all-target export, adapter preservation and
edited-file protection check (5,934.8 seconds). That is an earlier compiler
receipt, not a claim that the current archive run has completed. Symbolic
law-template `attempt` correspondence and the other migration acceptance gates
remain open; executable mappings do not certify that transport. The human
readability exercise remains deferred, complete named endings remain in the
following minor, and this increment authorizes no RC designation or tag.

## Latest approved milestone direction — 15 October 2026

The user supplied a `tensorflow.ctc` specification and required every `end` to identify the block it closes. The current parser does not yet meet that requirement: functions, procedures, types, cases, conditionals and mappings have named closers, while laws, sections, quantifiers, tables and several other constructs still accept bare `end`.

The milestone immediately following the minor authoring version currently being prepared must complete **named endings for every end-delimited block**. A bare `end` must be an error in normal source parsing. This supersedes the earlier decision to retain plain endings for laws, sections and quantifiers; that earlier syntax remains the current-minor compatibility baseline, not the next milestone's target. A numerical version for the following milestone is not assigned here.

Acceptance requires:

- Inventory every end-delimited grammar production, including laws; definition, description, rationale and references sections; universal, existential, negated-existential and `given` scopes; examples and expectation tables; abilities, handlers, resources, workflows, models, actors, protocols, scenarios, harnesses, benchmarks and their nested blocks. Preserve existing named function/procedure/type/case/if/mapping closers. No block may silently retain a bare ending.
- Specify the matching closing label for every production, including alternate quantifier wording and nested forms. `end law` and `end definition` follow the same explicit-closing principle as `end function`; the complete grammar must settle every remaining spelling together.
- Reject missing labels, mismatched labels and bare `end`, with source spans that identify both the opener and the offending closer. Scalar metadata and other constructs that do not open a block acquire no artificial closing block.
- Update parser, authoritative grammar, formatter, migration, editor grammar/services, examples, documentation and native/WASM consumers together. Legacy bare-ended source enters through explicit migration; it must not remain permissive normal syntax in the following milestone.
- Migrate the supplied CTC example and the authoring corpus while preserving typed obligations, evaluation order, mandatory definition checks, examples and evidence. Exercise nested blocks and every closing form, and verify formatter idempotence and all supported targets/interfaces.

The current-parser audit accepts a law/section/quantifier sample with three bare endings, rejects `end definition` / `end law`, accepts `end function`, and rejects a bare function ending. This is evidence that the next-milestone change is needed, not a claim that it has been implemented. All other acceptance and pre-final-1.0 requirements below remain in scope. Historical references to RC1 name the earlier plan, not the current minor version.

The parser inventory for that work includes the following block families. This records current behavior; it does not select the unresolved future quantifier or operation-clause labels.

| Block family | Current canonical closer | Following-milestone coverage |
| --- | --- | --- |
| Function, procedure, named record or alternative type, first-matching case, conditional, mapping | `end function`, `end procedure`, `end type`, `end case`, `end if`, `end mapping` | Preserve and test matching labels. |
| Law; definition, description, rationale and references sections | Bare `end` for each block | Label both outer declarations and every section. |
| Universal, existential and normative/negative existential quantifiers; `given` | Bare `end` for each scope | Settle labels for all alternate wordings and test nesting. |
| Refinement, wrapper | Bare `end` | Include type-related declarations outside `type`. |
| Workflow; its concurrent `all` group | Bare `end` for each block | Include the inner group before `combine`. |
| Protocol, model, actor, supervisor | Bare `end` | Include all stateful declaration families. |
| Scenario; `par`; a receive operation's `or else` recovery block | Bare `end` for each block | Include parallel branches and recovery nesting. |
| Ability, handler set (`handlers`), handler; written handler operation body | Bare `end` for each block | Distinguish outer handlers from nested operation bodies. |
| `handle ... with ...` expression | Bare `end` | Include expression-level effect scopes. |
| Resource; acquire, release and optional reset bodies | Bare `end` for each block | Label all resource lifecycle bodies. |
| Named example, expectation table | Bare `end` | Preserve independent expectations and row failures. |
| Harness, strategy, benchmark | Bare `end` | Include implementation-plane blocks and standalone harness files. |

Legacy `definition`, `match` and `references are` forms also need explicit migration correspondence. By contrast, a unit header, scalar law metadata, ability `laws` introducer, harness `for law` settings group, handler `operation by function` clause and ordinary let expression have no separate end-delimited block in the current grammar. This inventory does not add closers to them. The implementation must repeat the audit against the final grammar so new or transformed productions cannot escape the no-bare-`end` gate.

## Implementation baseline and decisions

Language profile: `1.0-rc.1`. API schema: **5**. Configuration version: **2**.

The user-approved RC1 implementation plan is the source of intent. These mechanical defaults are now adopted explicitly, without claiming they were approved in the earlier example discussion.

- `function` declares pure computation; `procedure` declares effects. `ability` remains distinct from capabilities. Declarations use `is`, sections use `:`, and functions, procedures, types, cases and conditionals have named closers. **Historical/current-minor compatibility syntax:** laws, sections and quantifiers close with plain `end`. The following milestone replaces every bare ending as required above.
- Every ordinary law has one authoritative `definition:`. Description, rationale and references are optional singleton sections. Examples and expectation-first tables repeat. Scalar metadata has one value before sections. Formatting preserves section order and chosen valid annotations/equality wording/infix notation.
- Phrase names begin with `"|` and end with `|`, without a closing quote. Infix names begin with a backtick, with optional pipe delimiters. One function namespace serves prefix/infix and qualified calls. Phrase bodies are case-sensitive, allow escaped pipes/backslashes, and reject emptiness, edge whitespace and line breaks. Namespace dots outside delimiters qualify; internal dots are part of a name. Native word splitting is deterministic and public collisions require explicit binding overrides.
- `Integer` is exact/unbounded, `Whole` (also `"|whole number|`) includes zero, and `Nat` (also `"|natural number|`) is positive. Migrate `BigUInt` and zero-inclusive `Natural` to `Whole`, preserving bounded nonzero refinements. Lengths and indices include zero.
- Named records use braces, are nominal, and construct as `Picture record{...}`. Anonymous records are closed structural products. No width subtyping or nominal unwrapping. Annotated type fields may have commas; canonical multiline types omit commas. Values/patterns use comma-separated `field = value`. An alternative has zero or one explicitly typed payload; a bare name is payload-free, even if a type has that name.
- Positional products use tuple types, values and recursive patterns together. Two or more components form a closed structural product; `()` retains Unit and one parenthesized item is grouping. Arity and nesting remain distinct, and tuples do not unwrap nominal `Pair` or records. Components evaluate once from left to right. The shared structural descriptor uses unspellable position labels; the wire view exposes their explicit position order so explanations and native fields do not guess it. This is an explicit implementation default, not a claim of earlier approval of a tuple representation. Canonical function/procedure parameter patterns use the existing match and mandatory irrefutability checks; destructured names scope into own restrictions, subsequent parameters, result contracts and bodies. Verification evidence and the remaining regression gates for this increment are recorded below.
- Anonymous record identity uses a 256-bit BLAKE3 digest of a versioned, field-label-sorted descriptor containing resolved types, refinements and dependent relationships. Normalize aliases and bound names; preserve nominal references, compare interned descriptors, and keep dependency fingerprints separate. Source evaluation order is independent. Native/WASM share a portable implementation checked against official vectors and GoForge; existing SHA-256 caches remain.
- `first matching case of value:` evaluates once and tries ordered branches. Guards continue on failure; nested cases scope their own `it`. Constructor/tuple/record/literal patterns may omit `it matches`; ambiguous whole bindings require it. Partial record patterns reject duplicate/unknown fields and repeated binders. `#any` and `_` are wildcards. `otherwise` is unique and last; guards alone do not prove coverage. Preserve GADT and dependent facts and recursive/destructuring patterns.
- Quantifiers own an explicit closing block and bind left to right; binders are visible in their own restrictions. The current-minor plain `end` spelling is superseded for the following milestone by the named-ending requirement above. Universal restrictions are antecedents; existential restrictions are required witness conditions. `there must exist` is existence; `there does not exist`/`there must not exist` negate existence. `given ... when C then P` means universal `C implies P`; `given ... then P` means universal P. `must` preserves a proposition; `must not` negates it. Text order establishes no priority or conjunction.
- `must be`, `is`, `=`, `must =`, and leading `must` express the same typed equality in laws. `must be` is preferred wording only. Value equality is Boolean; proposition equality is an obligation. Preserve Eq, IEEE equality and Boolean refinements. Legacy `==` migration uses typed context.
- Preserve symbolic precedence. Named infix is nonassociative immediately above comparisons; comparisons/equality/membership precede worded `not`, `and`, `or`, and right-associative `implies`. No user fixities or infix sections. Contextual a/an/the/is do not reserve ordinary variables or change resolution. Line breaks never imply sequencing or conjunction.
- `#S{...}` is primitive set notation. `Set` construction and membership require Eq for elements, without requiring ordering; duplicate detection retains first-occurrence order and IEEE caveats. Existing ordered sets migrate to `SortedSet`; maps retain Keyed. Generalize `any` to finite collections, with explicit map keys/values/entries; iteration needs no Eq. Text substrings stay explicit; pin full default Unicode case folding consistently without implicit normalization or boundaries. Contextual binary/hex literals and proven lossless widening never narrow, lose float precision, or unwrap nominal values. Prelude resolution follows locals and explicit imports and diagnoses ambiguity.
- Checked mappings contain typed constant rows, reject duplicate/non-reflexive keys, require complete finite coverage or `otherwise`, and expose partial lookup as Maybe. Generate ordinary checked lookup functions, finite preimages, and Maybe inverse only with unique outputs. Derived agreement does not replace external oracles.
- Expectation-first tables retain multiple expectations, typed inputs, recorded values, independent row failures and stable-code compile-rejection examples. Documentary references use `ref law qualifiedName` with section/named selectors or `ref function qualifiedName`, with `#S{...}` groups and phrase-named external entries. Resolve targets; cycles do not recursively expand or discharge obligations.
- Harness `witness expression for binder` uses qualified lexical binder paths and enclosing scope. Strategy search and witnesses never change the proposition. Evidence distinguishes proofs of existence/nonexistence, particular-input witnesses, complete finite verification/refutation, bounded discoveries, and incomplete/unsupported searches. A bounded miss or failed candidate cannot prove nonexistence. Model evidence states snapshots/history/fairness/completeness separately from native conformance.
- CLI: `fmt [paths...] [--check]`, read-only-by-default `migrate --from 0.24 [--write]`, `explain [unit::law] --view developer|business|formal|evidence [--json]`, `lsp --stdio`. Formatter is idempotent, preserves trivia/literals, uses two spaces and an 80-column target. Migration writes only after validated project-wide semantic/behavior correspondence including constructors and native bindings.
- `verification.layers` defaults to `[]`; choices are proof, exhaustive, property, examples, runtime, model, analysis. Harnesses still control execution. Intrinsic definition contracts and runtime enforcement are outside this switch. Migration explicitly preserves prior selections. Planned checks are separate from completed evidence; no selections must report no selected checks, never verification success.

### RC1 acceptance and remaining pre-final-1.0 requirements

All 17 backends, native/WASM, API/manifests/bindings, formatting/migration, editor and docs must pass compiler, target, generation, boundary, parity and complete release checks. Chapter 6 retains 23 laws, 65 table rows, one named example, 25 definitions, seven ADTs and two refinements. Independent oracles exercise 32,768 A addresses and 1,792 C combinations with meaningful mutants and independent repeated invocations. Examples 48–50 and all eight three-layer record/alternative combinations cover construction, recursive matching and expected results.

Readability gate: three business/product readers each answer at least eight of ten outcome/interpretation questions correctly; all distinguish incomplete witness search from proof of nonexistence. Record comprehension separately from preference. The user deferred this human readability gate during implementation on 14 October 2026; no reader results are claimed.

The larger portfolio remains **pre-final-1.0**, never post-1.0: Chapter 6 implementations/verification in all 17 languages; Projects 7–8 and 10–11 in Java, Python, TypeScript, F#, Rust, Elixir and Clojure; Project 9's testable Jack Snake; Project 12's complete public Jack OS API; the selected library demonstrations; agreed solver, conflict/completeness and advanced temporal work. GitHub Linguist recognition requires upstream acceptance/deployment and remains an external dependency; `.gitattributes` cannot install a grammar. The eligibility report was checked against upstream on 15 October 2026: repeated `.lawspec` files require 2,000 recent indexed non-fork files with independent adoption; local examples and tokenizer tests do not satisfy that usage gate or the upstream grammar compiler check.

### Implementation ledger

Baseline refreshed on 14 October 2026: HEAD and origin/main both `eff6d7af21d9606c254f626409c4b28d936af588`. The original review and Chapter 6 sources are preserved under `.artifacts/rc1/baseline/` with SHA-256 inventory. RC1 completion requires recorded evidence for every gate; the historical examples below are not assertions that a feature is implemented.

### Current implementation and evidence (not an RC1 acceptance claim)

Implemented foundations:

- Strict canonical parsing is selected by schema 5 and explicit `1.0-rc.1`; the existing frontend, inference, typed Core and automatic definition-contract audits are reused. Functions declare purity; procedures retain effect inference. Named closers, annotations, case-sensitive phrase names, qualified prefix/infix calls, normative typed equality, explicit universal/given scopes, singleton sections and expectation-first tables are covered.
- Canonical `apply law` reuses the existing typed expansion, with declared argument order, capabilities, specialization and recursion checks. The prelude's phrase names resolve after local/imported laws, and explicit `prelude.` selection remains available. Canonical imports and re-exports use `law name`; phrase names retain internal dots and backticks. Table inputs are selected after expansion, so reused requirements keep their checked examples.
- Optional scalar `id` and `owner` metadata precedes law sections, accepts one text or documentary identifier value, and has no separate closing `end`. Entries are singletons; formatting preserves their source order. These words remain ordinary identifiers elsewhere. Typed Core/API retain metadata separately from declaration identity and unit ownership; every explanation view preserves the same proposition and evidence. Documentary identifiers need no import resolution and metadata never discharges an obligation.
- Schema-5 `nativeBindings.names` supplies explicit public function names by resolved declaration identity, including checked definitions. Overrides preserve types, bodies, contracts and call identities; they create no native bridge on their own. Target naming/keyword rules still apply, and collisions after overrides remain errors. Malformed names, duplicate overrides, unknown identities and use through a legacy API schema are rejected.
- Scoped existential and nested universal propositions, proposition negation, normative negative-existence wording and existential `a`/`an` binders reach typed Core with distinct binder identities. Own and dependent restrictions scope left to right, including imported functions shadowed by later binders. Complete enumerable domains lower to ordinary checked typed terms for the shared evaluator and all targets, preserving the original proposition in explanations and the API. Missing finite coverage and exceeded expansion limits remain incomplete; an undefined candidate reports `verification-incomplete`, never a refutation of existence. Effectful searches report their missing snapshot semantics.
- Explicit conjunction, disjunction, negation and right-associative implication compose scoped propositions and reusable requirements. Sibling binders remain local, leading universal inputs stop at shadowing, and vacuous clauses cannot suppress sibling obligations. Logical short circuiting can decide a proposition without searching an irrelevant unbounded branch. Imported names and effect handlers follow lexical scope; an effectful sibling executes outside the search, while repeated effects within search retain the snapshot-semantics limit. Legacy/canonical expansion caches include the language profile.
- Canonical outer universal domains may be empty. Complete domain enumeration, empty algebraic types and closed false restrictions can establish emptiness without evaluating unreachable bodies or inventing witnesses. Selected proof/exhaustive verification explicitly reports zero evaluated cases; property testing alone reports incomplete. Examples still require valid inputs. Typed Core/API preserve universal versus legacy nonempty-domain semantics, and legacy execution still rejects empty test domains. Zero-binder laws execute their single case once. Emitter cache keys include the full execution plan so switching verification layers cannot reuse earlier test selection.
- Polymorphic named nominal record declarations, explicit construction with evaluation order preserved, projections, typed single-payload alternatives, recursive constructor/record and Boolean first-match cases, guard fall-through and scoped `it` are implemented. Refined field projection now transfers admitted constructor guarantees through the shared proof engine. Intrinsic termination, definedness and contract checks remain.
- Recursive field projections now preserve strict descent from an original function input; projections of rebuilt values and call results do not. Polymorphic record-field lets share the value occurrence's type, preserving the payload context of `Nothing` and similar constructors. Canonical named type closers no longer hide following generic declarations during header discovery. Go products with cyclic inline layout use sealed interfaces and one variant, with matching names and codecs; slice recursion, phantom arguments and finite nesting retain structs.
- `Whole`/`Nat` and their phrase aliases lower to the existing exact representations and positive refinements. Binary/hex literals retain exact contextual typing. Enum/Boolean finite mappings and mappings with fallbacks generate checked definitions; complete mappings derive finite preimages and eligible Maybe inverses. Duplicate/non-reflexive keys are rejected after primitive contextual conversion.
- Configuration version 2 and explicit law layers default to none. No selections report `not-verified`; native test plans report `planned`. Completed compiler proofs/exhaustive evaluations remain evidence. Generation keys include layer selection. Unsupported exhaustive/model generation reports limits instead of silently dropping runtime model semantics or claiming a success.
- Lossless lexical tokens, stable nested-block formatting targeting 80 columns with comment/literal preservation, `fmt --check`, four typed explanation views, stdio LSP diagnostics/formatting/outlines/function navigation, UTF-16 positions, a VS Code client and shared grammar are implemented. Fresh CLI projects use the canonical profile and empty law layers.
- Migration supplies a read-only typed inventory, constructor/native-binding changes and a configuration proposal preserving prior law layers. `--write` now obtains fresh correspondence evidence and applies admitted project transformations under the existing compiler and native-binding assumptions. All source, domain, binding and configured-target gates must pass; unsupported or unestablished transformations remain blocked. Filesystem inputs and the complete declared source inventory are rechecked before committing. Earlier disabled-writer statuses in the dated ledger below describe the preceding checkpoints.
- Portable BLAKE3-256 matches all 35 official boundary vectors and GoForge. Typed Core structural-record identity, interning and direct anonymous source types/values now work through checked definitions, specialization and literal examples. Nominal payload source contexts and the other acceptance gates remain incomplete. Existing SHA-256 caches remain unchanged.

Recorded checks so far: the original 0.24 suite passed 1,290 tests; a subsequent full compiler run passed 1,318 tests, and an earlier focused RC1 run passed 46 tests (the preceding compiled focused run passed 40). Existing editor tests and three authoring/transport tests passed. All 67 generated outputs match their templates, and the WASM/API/compiler source fingerprints match. Core/emitter boundaries passed for 214 modules. Legacy check/expand native/WASM parity passed 67 fixtures at both machine widths. Schema-5 native/WASM parity passed 44 checks, including check/expand/format and generation of all eight nesting examples through every target at both machine widths; the CLI sample remains valid after formatting and a second formatting check makes no changes. Full generation parity passed 4,556 fixture/target/width/layout combinations, the complete npm suite passed 148 tests, and documentation checks passed 118 pages and 114 compiled snippets. The eight canonical delivery/document/file examples passed 20 compiler-evaluated outcome laws and native execution through every one of the 17 targets. Additional native/WASM exhaustive checks agree on contextual numeric equality and IEEE signed-zero guard fall-through at both machine widths. Five native/WASM boundary checks agree on polymorphic records, record/alternative construction, the empty-pattern limit, the ordered-set limit and single-line infix declaration discovery. Polymorphic record construction/projection also generates through all 17 targets. Kotlin and Groovy used the pinned Gradle 9.3.0 distribution with its official checksum verified. The reproducible `rc1-nesting` acceptance suite passes its Java native run and rejects all eight filename-loss mutants during exhaustive generation checking; CI schedules the suite for all targets in normal and 32-bit compact profiles. Read-only Chapter 6 migration inventory retains 23 laws, 25 definitions and seven ADTs; a requested write fails with `migration-incomplete` and leaves its source unchanged. `make release-check` stops at the dirty-worktree prerequisite, so release readiness is not established. Tests of all 17 emitters establish emission support for the exercised functions, not implementation conformance of the full demonstration portfolio.

The subsequent reusable-law change passes 65 focused canonical/import regression tests, including the legacy facade and package cases. Its bit-codec acceptance suite runs on all 17 native targets; all reject both a lost-decoding mutant and a reversed-encoding mutant. The latter preserves round-trip agreement and fails the independent expected encodings at native execution, illustrating why derived agreement is insufficient. Native/WASM parity agrees on 51 additional checks covering codec evidence, all 17 emitters at both widths, formatting idempotence, malformed reuse, and phrase-law imports/re-exports. The new canonical examples are included in the npm package and `rc1-codec` is scheduled beside the nesting suite in both CI profiles. These checks establish the small codec demonstration, not the outstanding Chapter 6 portfolio or existential requirements.

Explicit public-name overrides subsequently pass native execution on all 17 targets with two colliding source spellings and distinct behavior; every target also rejects a lost-negation mutant. Native/WASM responses agree on 77 additional checks, including both machine widths, all target collision errors, unchanged typed law evidence and invalid, duplicate or unknown overrides. The combined canonical, legacy import/package and native-binding boundary suite passes 111 tests; the two focused override tests also pass after the duplicate-override assertion was added. Generated outputs, source/artifact fingerprints, compiler/emitter boundaries, six editor tests and all documentation checks pass after this change. The `rc1-native-names` acceptance suite is scheduled in both CI profiles.

Scoped search subsequently passes a 119-test combined canonical/import/binding run and a full `test/Main.hs` run of 1,352 tests. Final imported-binder-scope and undefined-candidate corrections pass focused tests, 14 legacy import/package regressions, and native/WASM parity; generic specialization inside existential scopes is also covered. The complete authorization-snapshot demonstration has five laws and six independent expected rows. All 17 native targets pass it, rejecting all three mutants on every target (51 rejections). Native/WASM parity agrees on 124 checks covering both quantifier orders, negation, empty nested domains, incomplete/unselected searches, failed candidate evaluation, generic specialization, imported scopes, formatting, all 17 targets at both widths and compact output. Four authoring/transport tests pass, as do generated-file integrity, compiler/emitter boundaries, six editor tests, and documentation checks. Java/Scala initially exposed invalid logical-binder names; the shared naming correction is covered by the passing native suite. `rc1-existence` is scheduled in both CI profiles. This establishes finite snapshot evidence, not constructive or bounded unbounded-domain search or state/history completeness.

Proposition composition subsequently passes 157 combined canonical/import/ability regressions, plus focused identical-surface-tree cache and repeated-effect checks. The composed authorization requirements and a handler-scope fixture have 11 executable laws. All 17 native targets pass and reject both mutants (34 rejections); `rc1-composition` is scheduled in both CI profiles. Native/WASM parity agrees on 92 checks covering scoped conjunction/disjunction/implication, lexical shadowing, vacuity, short circuiting, cross-profile cache reuse, imports, handler preservation, formatting and all targets at both widths/layouts. Five authoring/transport tests, all 67 generated outputs, WASM/API/source integrity, boundaries for 215 modules, six editor tests, and documentation checks for 118 pages and 114 snippets pass. These results cover complete finite composed propositions; constructive/bounded search and outer empty-input domains remain open.

Empty outer universals subsequently pass 73 focused canonical regressions on the final source. The empty-domain demonstration has four laws; all 17 native targets pass and reject both finite-domain mutants (34 rejections). Native/WASM parity agrees on 102 checks, including both machine widths/layouts, all targets, explicit zero-case evidence, preserved scoped assertions, property-only limits, legacy semantics and repeated switches between exhaustive and property layers. A complete compiler run passes 1,362 tests. The subsequent layer-switch checks exposed an emitter cache key that omitted finite cases and generators; the full-plan key correction and zero-binder property execution are covered by the final 73-test focused run and parity. All 67 generated outputs, WASM/API/source integrity, boundaries for 215 modules, six editor tests and documentation checks pass. The complete npm regression run subsequently passes all 150 tests. `rc1-empty-domains` is scheduled in both CI profiles. The directly recursive Go product gap at this milestone is resolved by the recursive-record work below.

The recursive-record change passes 282 combined canonical, structural, source-data, specialization and definition-contract regressions, plus the strengthened negative checks requiring a termination diagnostic. Its four-law demonstration passes native execution on all 17 targets, rejecting both traversal mutants everywhere (34 rejections). Native/WASM parity agrees on 86 checks covering both annotations, generic headers, polymorphic payload context, genuine field descent, rejected rebuilt/returned arguments, formatting and all targets at both widths/layouts. A separate Go compile check verifies slice recursion, phantom arguments and finite nested products. Generated outputs, source/artifact integrity, 215-module boundaries, six editor tests and documentation checks pass. `rc1-recursive-records` is scheduled in both CI profiles. This resolves the directly recursive Go product gap exposed by the earlier empty-domain exercise. Example export now validates output paths before compilation while retaining validation before writes; invalid parent traversal and symbolic-link destinations reject in approximately 30 ms in the recorded local check. The complete 150-test npm run started at the preceding milestone also passes; a fresh 20-test API, scalar, refinement, structural and authoring consumer run passes after the recursive-record rebuild.

Scalar metadata subsequently passes its parser, scope, formatting and non-discharge regressions. Its two-law review demonstration passes native execution on all 17 targets and rejects both outcome mutants everywhere (34 rejections). Native/WASM parity agrees on 100 checks, including both widths/layouts, every target, declaration/proposition preservation, contextual binders, metadata order, malformed-source rejection and unselected verification. The rebuilt API and authoring consumers pass 21 tests, including six explanation/transport tests. Shared highlighting recognizes metadata keys contextually and retains function/binder highlighting for ordinary `id` and `owner` names. Generated outputs, WASM/API/source integrity, 215-module boundaries, six editor tests and documentation checks pass. `rc1-metadata` is scheduled in both CI profiles. The complete compiler run for this source revision passes all 1,371 tests with zero failures.

Typed documentary references now have parsed and resolved representations separate from executable imports and law application. `ref law` accepts whole-law, known section and `references.` phrase selectors; `ref function` selects a checked source definition. Named external entries use `phraseName: text`; quoted unnamed citations remain typed external links. `#S{...}` groups complete links, or targets after `ref law`/`ref function`. Selector punctuation and named-entry syntax are explicit mechanical defaults for this implementation. Known optional fields may be empty; named selectors must resolve to an actual entry. Resolution retains declaration identity and both declaration/use spans, handles local/import/alias/facade/full-unit paths and prelude law phrases, enforces package visibility, and rejects ambiguity, missing targets and wrong kinds. Package-version selection applies to full-unit links through a separate resolution policy, preserving original reference text and use spans. Documentary cycles introduce no executable dependency and no proof evidence. Schema 5 exposes structured links; transitional schemas 3/4 retain string citations. Explanation and editor consumers read the same resolved links. The final reference regressions pass 87 canonical tests. The two-law documentary review demonstration passes all 17 native targets and rejects all three mutants everywhere (51 rejections); after the package-policy correction, identical generated projects reuse those native results. Native/WASM parity agrees on 148 checks, covering both widths/layouts and every target, complete/grouped/selected links, facade identities, full-unit package-version selection with original use spans, rejected private-version access, prelude law phrases, unchanged propositions/evidence, malformed targets, legacy citation arrays and intrinsic termination. The rebuilt consumers pass 24 tests, including the actual WASM-backed language-server check on unsaved Unicode phrase names. All 67 generated outputs, source/artifact integrity, 215-module boundaries, six editor tests and documentation checks pass. `rc1-references` is scheduled in both CI profiles. The complete compiler regression run for the final package-policy source passes all 1,381 tests with zero failures. Explanations present legacy prelude names in canonical phrase syntax while retaining their original declaration identities.

Constructive harness witnesses now use `witness expression for binderPath` inside selected law blocks. Paths resolve against expanded lexical scopes, include leading universal binders, accept optional `definition.` and unique short names, and use `branch1`, `branch2`, etc. for conjunction siblings. These path labels are explicit mechanical defaults, not requirement priority. Import resolution waits for lexical scope, including binders introduced by reusable laws. Candidate expressions are typed, monomorphized as needed and restricted to pure checked call chains. The law's authoritative proposition is retained. Shared execution uses three outcomes through ordinary typed terms: a failed candidate is incomplete, negation preserves incompleteness, and complete finite fallback remains available. Sufficient constructive goals go through the existing contract prover; negative existence needs complete finite coverage in this implementation. Native undecided searches report `quantifier-search-incomplete`. Configured expressions are exposed as harness metadata and labelled as strategy choices in explanation views. Concrete witness-value traces and broader search remain open. The 21 focused witness regressions and the complete compiler run pass: 1,402 tests, zero failures. The six-law demonstration passes native execution on all 17 targets in both normal and 32-bit compact profiles, rejecting all three mutants on every target/profile (102 rejections). Native/WASM parity agrees on 126 checks, including preserved propositions, symbolic constructive proof, incomplete misses and negation, finite fallback, IEEE behavior, warm-cache strategy changes, selected layers, formatting and generation across all targets at both widths/layouts. A focused evaluator regression also confirms each visited candidate is evaluated once. The rebuilt API/editor consumers pass 26 tests, including an actual WASM-backed language-server check of unsaved witness settings and navigation. All 67 generated outputs, source/artifact integrity, boundaries for 215 modules, six editor tests and documentation checks for 118 pages and 114 compiled snippets pass on the final source. `rc1-witnesses` is scheduled in both CI profiles.

Complete finite search now recognizes integer domains established by mandatory conjunctive restrictions, including strict/reversed comparisons, equality, exact affine arithmetic, intrinsic finite-width bounds and positive/zero-inclusive refinements. Exact signed integer intervals with equal variable coefficients at both endpoints admit complete symbolic covers depending on enclosing binders. Leading universal inputs are enumerated in lexical order with each restriction rechecked against the actual prefix; scoped quantifiers share the same typed cover. Other predicates remain authoritative, and disjunctions, nonlinear bounds, rational/IEEE intervals and oversized covers do not supply false completeness evidence. The original proposition and mandatory definition validation are unchanged. All 13 focused regressions pass, including 75 independent translated-range oracle cases, endpoint refutation, budget limits, dependent tuples and all 17 emitters. Existing canonical and constructive-witness regressions pass 87 and 21 tests respectively. The six-law settlement demonstration passes native execution on all 17 targets in normal and 32-bit compact profiles, rejecting all three mutants everywhere (102 rejections). Formatting the source retains identical generated projects and reuses those native results; the CLI formatting check is clean. Native/WASM parity agrees on 128 checks covering both widths/layouts and every target. An additional independent 150-law scalar oracle agrees on native and WASM at both widths, including signed/unsigned/positive clamping, reversed affine comparisons, negative offsets and additional filters. Eight CLI explanation checks preserve the authoritative obligations, distinguish unselected laws from verified results, and retain zero-case evidence. The rebuilt API/editor consumer run passes 33 tests. All 67 generated outputs, source/artifact integrity, 216-module boundaries, six editor tests and documentation checks for 118 pages and 114 snippets pass. `rc1-integer-domains` is scheduled in both CI profiles. The complete compiler regression run passes all 1,415 tests with zero failures (814.8 seconds). The full npm regression run for this integer-range revision subsequently passed all 156 tests with zero failures (approximately 30 minutes); its log is `.artifacts/rc1/integer-domain-npm-full-tests.log`. This milestone implements exact finite covers; bounded/default unbounded-domain sampling remains open.

Bounded scoped search now resolves existing harness strategies against expanded lexical binder paths. Root strategies retain their framework behavior; scoped strategies use deterministic finite choices, weighted cycles, diagonal dependent binds, checked filters and named refinements. Default pools include safe restriction hints, nearby exact integers, signed literal values, type boundaries and small integers. Generic checked functions used only by strategies or their refinements are specialized, and the dependency graph includes those expressions. A finite strategy list is never treated as a complete type domain. Three-valued execution preserves incompleteness through negation, can refute a universal from a real counterexample, and rechecks restrictions with the actual enclosing inputs during outer shrinking. The search lowers to ordinary typed lets and conditionals with single evaluation and a linear decision tree; no unchecked definition category or second candidate-expression evaluator was added. Constructive certificates use the shared contract prover with increasing candidate prefixes. Schema 5 and explanation consumers distinguish configured searches from completed evidence. These deterministic scheduling choices are explicit implementation defaults. All 22 focused tests pass, including the nine-law demonstration through all 17 emitters, hundred-candidate size/depth bounds, generic/refinement roots, single evaluation and original harness diagnostic locations. The initial and refreshed complete compiler runs both pass all 1,437 tests with zero failures; the refreshed run takes 932.7 seconds and includes the final navigation and Go backend corrections. All 35 rebuilt API/editor consumer tests pass, including actual WASM-backed diagnostics and function navigation in unsaved scoped strategies. Typed draw trees retain expression origins for both root and scoped strategies. Generated outputs, source/artifact integrity, 217-module boundaries, six editor tests and documentation checks pass. Native execution exposed Python expression-depth limits and Go closure-inlining growth; balanced decision trees, readable failure labels and a synchronous non-inlined Go expression helper address them. Go passes its normal compiler settings and all four search mutants; recursive-record, GADT and flow Go regression suites also pass with their mutants. Groovy parser probes identify heap exhaustion at Gradle's default 512 MiB compiler worker limit; the generated build now gives that worker a 2 GiB maximum. Native execution of the nine-law demonstration passes all 17 targets in both normal and 32-bit compact profiles, rejecting all four mutants on every target/profile (136 rejections). Groovy, Clojure and Swift results are recorded in separate continuation logs after the first fourteen targets. The refreshed generation, integrity, 217-module boundary, six editor and documentation checks pass after the Groovy scaffold correction, as do ten distribution/scaffold regressions. Final native/WASM parity agrees on 130 checks, including every target at both widths/layouts, configured versus completed evidence, bounded misses and negation, universal counterexamples, dependent/generic strategies, complete finite fallback, IEEE behavior, positive budget validation, source spans and warm dependency changes. The full npm regression run for this scoped-search revision passes all 158 tests with zero failures (approximately 32 minutes). No RC1 acceptance result is claimed.

Contextual `the` now resolves inside canonical restrictions against the actual lexical scope and explicit imports. The current, earlier and enclosing binders, record projections, function/infix arguments, alternative payloads, `given ... when` guards and harness filters retain their typed meaning. Later or sibling binders remain inaccessible. Real functions and variables named `the` retain ordinary application; `a` and `an` remain ordinary names elsewhere, and refinement purity checks still apply. The operand keeps its own original source span and formatting retains the authored article. All 18 focused regressions and 87 canonical regressions pass. Worded and plain restrictions emit identical checked programs through all 17 targets at both machine widths. The authorization snapshot demonstration now uses this wording; all 17 native targets pass in normal and 32-bit compact profiles and reject all three mutants everywhere (102 rejections), reusing prior native results where generated projects are identical. Six shared-grammar tests pass, including contextual articles and ordinary names. All 68 target/width/layout combinations preserve every generated project file between worded and plain authorization requirements. Native/WASM parity agrees on 178 checks, and an independent 64-law oracle covering all sixteen binary Boolean functions in four argument-wording forms agrees at both widths. The rebuilt WASM passes all fourteen authoring/transport consumer tests in a separate local package, including the new source-span, explanation, formatting and unselected-evidence check, plus 21 API/scalar/refinement/structural consumers. The final compiler run passes all 1,455 tests with zero failures (869.3 seconds). After the full scoped-search npm run finishes, the package is staged and its compiler/glue/API bytes match the independently checked package. All fifteen staged authoring and TypeScript-interface tests pass. All 67 generated outputs and WASM/API/source fingerprints match; 217-module boundaries, six editor tests and documentation checks for 118 pages and 114 snippets pass. These are implementation increments; no RC1 acceptance is claimed.

The structural-record Core foundation now computes a full BLAKE3-256 identity from versioned array descriptors of label-sorted typed fields and their restrictions. It normalizes bound names, exact scalar representations and type-parameter permutations, retains opaque nominal references, and separates dependency fingerprints from type identity. Registry interning recomputes descriptors and compares stored bytes. Every source occurrence retains mandatory constructor admission checks before sharing. Construction uses ordinary typed lets to evaluate supplied fields once in their source order. Twenty-two focused regressions pass, including nominal boundaries, forged metadata, collision rejection, duplicate-occurrence definedness, persisted/public metadata, dependent field identities, source-order evaluation and valid distinct native temporaries. Five direct Core record laws pass native execution on all 17 targets in normal and 32-bit compact profiles; each profile rejects a wrong-count mutant (34 rejections). Native/WASM agrees on 24 complete descriptors, digests, parameter permutations, dependency lists and fingerprints, including exact-number invariance and IEEE distinctions. The rebuilt package also agrees on the existing 178 API parity checks; TypeScript consumer checks, all 67 generated outputs, source/artifact integrity, 219-module boundaries, six editor tests and documentation checks for 118 pages and 114 snippets pass. This is an internal Core increment: anonymous record authoring syntax and frontend inference remain pending. The full compiler regression passes 1,476 tests with zero failures (850.8 seconds); the additional temporary-name regression also passes in the 22-test focused suite. The full npm regression passes all 159 tests with zero failures and no skipped checks (1,811.5 seconds). These results validate this Core increment; anonymous source authoring and the other RC1 gates remain incomplete. No release acceptance is claimed.

On 15 October 2026, structural normalization now runs before Core admission and planning. Generic and directly written concrete products share their resolved identities through nested products, nominal payloads, function signatures, contracts, constructors, projections, updates and patterns. Quantifiers, scoped witnesses, strategies, resources, example bindings, effects, handler state, sessions and mailboxes retain their corresponding typed references. Closed data-only lets remain valid literal fixtures without admitting arithmetic, calls or free references. Every distinct source ordering of a shared refined constructor is audited in the complete constructor environment before interning; valid duplicates are accepted and unsafe orderings still fail for undefined division. Exact numeric projections from known constructors now establish their field relations without skipping checks of unselected fields or treating IEEE equality as exact reflexivity.

The compiler passes all 1,498 tests with zero failures (814.5 seconds), including 12 normalization, 27 identity and 53 definition-contract regressions. A ten-law direct Core interoperability program passes on all 17 native targets in normal and 32-bit compact profiles and rejects a wrong-count mutant everywhere (34 rejections). It exercises checked calls, nested products, nominal payloads, patterns, updates, refined duplicate declarations, NaN and signed-zero equality. Native/WASM agrees on the complete normalized programs, all ten outcomes and 1,692 generated-file fingerprints across 68 target/width/layout combinations. The existing 178 API parity checks, 36 package authoring/type/scalar/refinement/structural consumers, all 67 generated outputs, source/artifact integrity, 220-module boundaries, six editor checks and documentation checks for 118 pages and 114 snippets also pass. These checks validate this Core integration, not anonymous record source syntax or RC1 acceptance.

The source type model now represents structural record fields with separate public labels and lexical binders. Field order and intrinsic restrictions survive erasing enclosing refinements, alias expansion, imports and cache serialization. Capture-avoiding substitution preserves own-field, earlier-field and nested scopes without renaming public labels. Value and type substitutions traverse expression annotations together, preventing dependencies from being replaced twice or captured by an expression binder. Twenty-two focused regressions pass. Native/WASM agrees on five complete type/dependency snapshots, identical binary cache bytes and round-trips, and 452 independent arithmetic-oracle outcomes. The rebuilt package passes 36 targeted consumers and 178 native/WASM API checks; another 178 comparisons against the preceding main compiler preserve generated behavior across all targets and machine/layout profiles. All 67 generated outputs, source/artifact integrity, 220-module boundaries, six editor checks and the 118-page/114-snippet documentation checks pass. The full compiler regression passes all 1,520 tests with zero failures (798.4 seconds). This is source-model groundwork: anonymous record parsing, inference and contextual Core lowering remain required and are not exposed by this increment.

Source-expression inference now handles closed record literals, contextual field types, exact label sets, nested products, field access and updates, polymorphic uses, intrinsic restrictions and field-order equivalence without nominal or width conversions. The explicit Core collector builds descriptors from typed fields and restrictions, retains declaration occurrences until mandatory admission, collects products introduced inside restriction expressions, and uses ordinary strict lets for source evaluation order. The older expression-only entry point audits each duplicate occurrence before discarding a registered descriptor. Restriction typing keeps enclosing parameters rigid so inference cannot erase a dependency by specializing it. Generated structural constructors stay outside the ordinary source constructor namespace. Capability checking uses the same contextual type/declaration lowering, including Eq records whose fields do not support Keyed. Type-variable discovery and occurs checks include predicate annotations. Definition admission still rejects violated positive/dependent restrictions and undefined unselected fields. A known constructor behind strict source lets now supplies its field facts to a match/update only after the complete selected expression has passed its strict audit; NaN does not become reflexive.

The 66 focused source-record checks and seven new strict-value proof regressions pass. The full compiler regression passes all 1,571 tests with zero failures (800.3 seconds). A ten-law source-expression fixture passes native execution on all 17 targets in normal and 32-bit compact profiles and rejects a wrong-count mutant everywhere (34 rejections). It covers a checked record function, nested construction and projection, field-order equality, dependent updates, positive fields, opaque nominal fields, empty records, NaN and signed zero. Two additional native laws exercise records constructed inside refinement metadata, native input validation and positive construction through strict projections; they also pass all 17 targets in both profiles and reject their mutant everywhere (another 34 rejections). Native/WASM agrees on complete checked programs, all ten outcomes and 1,740 generated-file fingerprints across 68 target/width/layout combinations. The final native/WASM probes also agree on generic parameter preservation/rejection, declarations introduced by predicates, registered-order rejection and positive projection checks. Every closed program and generated-file fingerprint remains identical to the bytes tested natively. The existing 178 API parity checks, another 178 comparisons against the preceding main compiler, 36 targeted package consumers, all 67 generated outputs, source/artifact integrity, 220-module boundaries, six editor checks and the 118-page/114-snippet documentation checks pass. These results validate source-expression inference and the explicit collector. Canonical anonymous record parsing, whole-unit collection, structural context across nominal payloads, complete source specialization/traversals and authoring-pattern integration remain required; this increment does not expose completed anonymous record syntax or claim RC1 acceptance.

Implementation and law elaboration now use an explicit structural-declaration collector. Signatures, definition arguments and bodies, contracts, ability instances/operations/failures/resources, handler state, protocol payloads and mailboxes retain their record declarations. The compiler's definition-admission program and final frontend program consume those declarations. Formal equality, leading/nested law quantifiers, example expectations and law-resource lifecycle expressions share collection too. Lookup catalogues may intern descriptors, while the separate admission stream retains every source occurrence. Cached law elaboration stores its declarations alongside its proposition; old single-result APIs reject undeclared products and audit duplicate occurrences before dropping them. Empty additions preserve existing registry/cache identities.

Seventeen new regressions bring the focused source-record checks to 83, with zero failures. A four-law fixture now traverses the public frontend, including checked record calls, literal arguments, nested field-order equality and empty products. Native execution initially exposed an F# hoisting bug: independent equality operands reused temporary names, allowing the later operand to shadow values needed by the earlier one. The shared .NET printer now makes lexical bindings distinct before hoisting for both languages; C# already required this. After the fix, this fixture passes all 17 native targets in both profiles and rejects 34 mutants. The 16 unaffected targets retain byte-identical generated projects. The earlier ten-law source fixture is also rerun on F# and C# because C# includes generated F# model code. Both .NET targets additionally pass the canonical authorization-snapshot example at both profiles and reject four inverted-law mutants. Native/WASM agrees on all four new outcomes and 1,596 generated-file fingerprints across 68 combinations; the previous ten-law fixture agrees on its complete Core, ten outcomes and 1,740 fingerprints, with affected .NET model code checked natively. These are implementation-plane and law-collection results. Canonical anonymous source parsing, nominal payload source contexts, harness/strategy collection, structural literal examples, specialization/traversals and authoring patterns remain open. The full compiler regression passes all 1,588 tests with zero failures (814.3 seconds). The final rebuilt package passes 178 native/WASM API comparisons and 36 targeted consumer tests with no skipped tests. Another 178 comparisons to the preceding main compiler preserve API data and generated output, allowing only generated F# binder suffixes to differ. All 67 generated outputs, compiler/artifact integrity, 220-module boundaries, six editor tests and documentation checks for 118 pages and 114 compiled snippets pass. The full npm catalog was not rerun for this increment. No RC1 acceptance is claimed.

The remaining frontend harness planes now share structural-declaration collection: constructive witnesses, root and scoped strategies, named/weighted/filtered/dependent draws, coverage/classification/labels/targets, benchmarks and their production ability references. Each selected item's diagnostics retain its source span. The final program retains every occurrence for ordinary constructor admission. Harness expressions still reject native/effectful computations, including computations hidden in unselected record fields; benchmarks retain their existing native/ability behavior. Generator typing now follows the same innermost-first lexical bindings as name resolution, so a bound record shadows a function of the same name and nested binds do not capture an outer value. An explicit `any` type is lowered and checked independently rather than comparing possibly failing type-lowering results.

Thirteen additional regressions bring the source-record checks to 96; all pass, as do 85 tests selected by the harness filter, 22 bounded-search tests and 16 Kotlin-specific checks. A four-law harness fixture and a record-only benchmark traverse the public frontend and testing planner. The fixture passes all 17 native targets in normal and 32-bit compact profiles and rejects 34 wrong-result mutants. Native execution exposed a Kotlin naming bug: a generated unit class named `Unit` masked Kotlin's built-in return type in harness callbacks. Callback types and native binding Unit values/returns now use `kotlin.Unit`. Kotlin passes both profiles after the fix; the other 16 native projects remain byte-identical. Native/WASM agrees on the complete typed harnesses, six sampled root/scoped outcomes, evidence and 1,348 generated-file fingerprints across 68 combinations. The unbounded observation law correctly remains incomplete under exhaustive-only verification; the three scoped existence requirements are completely checked with their configured witnesses/strategies. A bounded record miss remains inconclusive under both positive and negative existence, and unselected laws remain unverified. The final package passes 178 native/WASM API comparisons, another 178 exact comparisons against the preceding main compiler and 36 targeted consumers with no skipped tests. Compiler/artifact integrity, all 67 generated outputs, 220-module boundaries, six editor tests and the 118-page/114-snippet documentation checks pass. The full compiler regression passes all 1,601 tests with zero failures (802.7 seconds). The complete npm catalog was not rerun for this increment. These are typed source-model and frontend results; anonymous record authoring syntax, structural literal examples, nominal source contexts, complete source traversals/specialization and patterns still require implementation. No RC1 acceptance is claimed.

Canonical direct anonymous record authoring now reaches the same checked pipeline. The parser accepts structural field types, bare and nested values, empty products, adjacent projections and record-valued table literals. Type fields retain optional commas; values require them. Ordinary functions named `record` and calls with bare record arguments still resolve normally. Structural types propagate through checked template admission, generic specialization, imports, effect traversals and concrete example validation. Field sets remain closed and nominal boundaries remain explicit; intrinsic positive-field and definedness checks still run with no law layers selected. Public example views resolve the lexical data bindings used to preserve construction order, retaining the existing wire value shape. Formatting now carries the preceding token across line wrapping so the second word of `of type` cannot open a spurious type declaration.

Thirteen focused canonical-record tests and all 107 tests selected by the canonical-authoring filter pass. The five-law canonical-source fixture, including three record-valued table rows, passes all 17 native targets at normal and 32-bit compact profiles and rejects a wrong-count mutant in every profile (34 rejections). Native/WASM agrees on the complete checked program, seven sampled property outcomes, three table outcomes and 1,656 generated-file fingerprints across 68 target/width/layout combinations. The published structural-record example and implemented grammar document the available syntax and the remaining source-constructor and field-function limits. The complete compiler run passes all 1,614 tests with zero failures (820.9 seconds); the subsequent formatter-only correction passes the final 107-test canonical suite. The final rebuilt package passes 38 targeted consumers with no skipped tests, 78 actual canonical-source API comparisons, the existing 178 native/WASM API comparisons and another 178 exact comparisons against the preceding main compiler. All 67 generated outputs, source/artifact integrity, 220-module boundaries, six editor tests and documentation checks for 118 pages and 114 snippets pass. The complete npm catalog was not rerun for this increment. These are direct anonymous source authoring results; nominal payload contexts, full patterns and the other RC1 requirements remain open. No RC1 acceptance or tag is implied.

Nominal declarations now retain explicit source constructor contexts for anonymous fields and structural GADT equations. Inference, elaboration, template admission, capabilities, specialization and the public frontend share that context. Internal nominal headers are completed before mandatory constructor validation. Generic product storage and concrete structural results are reconciled through ordinary checked Core matches/constructions, without changing nominal identities or adding an execution mechanism. Contextual construction supplies exact field types to nested literals. Data-only representation matches in table inputs are evaluated by the existing Core evaluator for public serialization; unrestricted computations remain excluded. Formatting avoids splitting compound block endings and annotation keywords during wrapping.

The eight nesting examples now use inline anonymous record payloads, retaining their 20 independent outcomes. A new eight-law record-payload example includes four table rows, generic products with distinct fields, nested positive dimensions and alternative matching. Its permanent acceptance suite independently mutates dimension selection, download labels and generic field selection, and is scheduled in both target profiles. The full compiler regression passes all 1,624 tests with zero failures (940.2 seconds). Focused payload, normalization and canonical-authoring suites pass 9, 13 and 107 tests respectively. The permanent payload suite passes all 17 native targets in both profiles with 102 mutant rejections. The revised anonymous nesting suite passes every target/profile too, including 272 host mutant rejections. Native/WASM agrees on the complete checked payload program, ten sampled law outcomes, four table outcomes and 1,828 generated-file fingerprints across 68 combinations. The public payload source passes 78 native/WASM API comparisons; the existing 178 API comparisons and another 178 exact comparisons against the preceding main compiler pass. All 17 authoring consumer tests pass after correcting a test that had placed a mandatory-definition probe inside an unselected law. The initial complete npm catalog run finished with 161 of 162 tests passing and no skips (1,851.2 seconds); its sole failure was that superseded test assertion. The complete corrected authoring file passed 17 tests afterward. No uninterrupted complete-catalog pass is claimed for that run. The rebuilt main native package, all 67 generated outputs, source/artifact integrity, 221-module boundaries, six editor tests and 118-page/114-snippet documentation checks pass. At that milestone, separate probes exposed three generic cases. The next increment addresses projections through generic nominal storage in field refinements; generic structural GADT equations and container payloads remain implementation requirements. The user requested and received the current implementation on main before tagging. No RC1 acceptance or tag is claimed.

Generic nominal projections in intrinsic structural field refinements now use completed source contexts consistently during declaration, template and fixture admission. Every occurrence is normalized and checked before descriptor interning. Source template proofs obtain structural storage conversions from the same ordinary checked Core views as executable definitions. The existing proof normalizer can resolve a uniquely matching known constructor branch; it still audits every strict prefix and unused field before using the result. Runtime schema generation lowers executable field-access views separately from canonical descriptor metadata. Named-record literals in tables now resolve fields by label, preserving nominal identity and rejecting missing, extra or repeated labels.

The new parcel-measurements example has three laws and four table rows. It passes native execution on all 17 targets in both profiles, rejecting 34 wrong-weight mutants. Its permanent acceptance suite additionally mutates the sample parcel, weight result and recipient result independently: all 17 targets pass both profiles and reject all 102 mutants. Independent schema mutations trigger field-refinement failures across all 17 targets at both profiles (34 mutations). Rust includes an explicit native schema boundary check accepting one gram and rejecting zero; compiler-proved Rust table literals need not repeat that boundary validation. A separate named-record table fixture passes all 17 native targets at both profiles and rejects 34 wrong-label mutants.

The complete compiler regression passes 1,632 tests with zero failures (919.5 seconds), followed by the final 14-test payload suite exercising generation through all 17 targets. Native/WASM agrees on the complete refined Core, five sampled law outcomes, four table outcomes and 1,532 generated-file fingerprints across 68 combinations. The preceding eight-law payload program remains exactly unchanged, including all 1,828 generated-file fingerprints. The public parcel source passes 78 native/WASM API comparisons; the existing 178 comparisons and another 178 exact comparisons against the preceding main compiler also pass. All 18 authoring consumers pass, including mandatory invalid-construction/table rejection with no law layers and honest incomplete results over unbounded domains. The fresh complete npm catalog passes all 163 tests with zero failures or skips (1,909.0 seconds). The rebuilt main native package also passes. All 67 generated outputs, source/artifact integrity, 221-module boundaries, six editor tests and the 118-page/114-snippet documentation checks pass. No RC1 acceptance or release tag is claimed.

Explanation domains now use checked structural field metadata instead of anonymous record digest names. Developer, business and formal views show generic and nested products, field labels and intrinsic restrictions while retaining nominal names and distinguishing same-spelled qualified types. Generated storage views are hidden only when their typed branches copy every structural field in order. Unhandled expression forms retain checked text; no evaluator or proof rule is added. Developer output also includes input domains and explicit input restrictions. All views retain the original typed inputs, assertion and evidence. The positive-weight domain recompiles to the same identity and canonical descriptor. Twenty-five focused authoring, explanation and TypeScript-consumer checks pass, including dependent restrictions, IEEE comparisons, literal contents, preservation of user computations and unselected evidence. The package includes the new internal renderer. All 69 generated outputs, source/artifact integrity, 221-module boundaries and documentation checks for 118 pages and 114 snippets pass. The compiler and WASM are unchanged; their previously recorded regression results remain the baseline, and no new full compiler or npm-catalog run is claimed. At that milestone, record-valued assertion text still needed presentation work; the checked-term increment below addresses it. No RC1 acceptance or tag is claimed.

The generated TypeScript expression union now includes every node shape already emitted by the public serializer: record projections and updates, conditionals, lets, effect operations, both failure and explicit-handler forms, and call-count observations with nullable argument filters. This corrects the declarations without changing the wire format or compiler execution. The exhaustive consumer compiles without casts, rejects malformed handlers/binders/indices, and traverses 810 actual expressions spanning 15 node kinds from the canonical parcel example and explicit legacy-schema ability/failure fixtures. Both handler forms and both call-filter forms occur in those results; typed fixtures additionally check update-child traversal. Both TypeScript checks pass without skips. The development tool builds, all 69 generated outputs match, compiler/artifact integrity and 221-module boundaries pass, and all 118 documentation pages and 114 snippets pass. Only the declaration-file artifact fingerprint changes; compiler sources, WASM, glue and executable API bytes remain unchanged. No new full compiler, target-matrix or npm-catalog run is claimed for this declaration correction.

Checked-term explanation views now render structural values by field label and other constructors as labeled terms, including the nested parcel requirement. These constructor/case/handler terms are presentation notation, not new authoring syntax. Names resolve from checked identities, with qualification for collisions and shadowing. Primitive names and field order are generated from the existing Core registry, rather than maintained as another type checker. Independent strict field bindings may reconstruct a value in their original evaluation order only when every binding supplies exactly one constructor field. Dependencies, repeated uses and unused computations remain explicit. Single-constructor projections retain the complete subject, including unselected computations. Let/case/callback names avoid capture, conversions retain their mode, and branches, handlers and call filters remain visible. Missing metadata or an unhandled node retains the entire original checked expression, so opaque child text cannot be captured by renamed binders.

All 38 focused authoring, explanation and TypeScript checks pass with no skips. Effect abilities use their checked source names, qualifying collisions and preserving unresolved type-argument keys verbatim. A structural assertion recompiles to the same type and complete finite outcome with its original source field order. Canonical primitive examples display nested records through List, Maybe and Either; a law containing division by zero retains both computations and remains not-verified when no law layers are selected. Explicit legacy-schema ability/failure examples retain actual operation, handler and call-filter terms, with unchanged typed assertions and evidence in all four views. The CLI shows the readable parcel constructor term and retains not-verified evidence. Package checks include all presentation modules and the generated primitive names. The development tool builds; all 72 generated outputs, compiler/artifact integrity, 221-module boundaries and documentation checks for 118 pages and 114 snippets pass. Compiler sources, WASM, glue, executable API and declaration bytes remain unchanged, so no new full compiler, native target-matrix or npm-catalog run is claimed. This is another authoring-view increment, not RC1 acceptance or a release tag.

Historical internal-set source checkpoint: an equality-based set implementation adds the reserved internal Core representation, membership-based equality, order-preserving storage validation and duplicate rejection using language equality. Sets containing NaN remain non-reflexive; signed zeros compare equal. Capability derivation requires Eq for stored elements and refuses Keyed for sets and enclosing stored types. Definitions involving this representation remain on the existing checked value path rather than using native product equality. Matching support is being added to each target runtime family. Canonical Set syntax remains explicitly unavailable, and legacy ordered Set behavior is preserved pending the SortedSet migration.

Checkpoint validation passes 12 new Core tests and the existing canonical Set implementation-limit test, JavaScript and Python schema smoke checks, all 38 existing Rust runtime tests, Java runtime/schema compilation, BEAM scalar/schema compilation, the .NET runtime build and Swift runtime type checking. All 72 generated files match and Core/emitter boundaries pass. These checks do not establish end-to-end conformance of the new representation across all 17 targets. The npm compiler/WASM artifacts have not yet been rebuilt for this source checkpoint; source/artifact integrity, the full compiler regression, native parity, source operations, literal notation, migration and collection-generation completeness remain pending. This checkpoint is published for review at the user's request; no RC1 acceptance or release tag is claimed.

Historical rebuilt-foundation checkpoint: the set-foundation follow-up rebuilds the native compiler and npm WASM artifact. Its permanent internal fixture has 13 laws, each covering both Boolean inputs. Generated native tests pass through all 17 targets in both the normal and compact 32-bit profiles. Four specification mutants are refuted by complete finite Core evaluation during generation in each profile; these are compiler refutations, not native mutation results. The existing ordered-collection suite also passes all 17 native targets and rejects its five implementation mutants per target. Native/WASM agrees on 204 fixture/target/width/layout generation combinations, plus check/expand and package comparisons. The full compiler regression passes 1,645 tests with zero failures (969.3 seconds); all 73 generated files, source/artifact integrity, 222-module boundaries, six editor tests and documentation checks for 118 pages and 114 snippets pass. A permanent WASM consumer test checks all 13 internal laws and their four refuting mutants at both widths. The fresh complete npm catalog now passes all 183 tests with zero failures or skips (2,918.0 seconds), including independent repeated full-catalog example exports. Both native set-foundation profiles are scheduled in CI. Canonical Set authoring remains unavailable pending frontend, operation, binding and migration integration; no RC1 acceptance or release tag is claimed.

Canonical set authoring now resolves `Set` to the equality-based representation and `SortedSet` to the existing ordered representation, including qualified imports, re-exports and prelude operations. Construction and membership require Eq for elements; iteration does not. Ordinary checked source definitions implement construction, membership, insertion, removal, union, intersection and difference. `#S{...}` supports expressions, empty and nested sets, records, alternatives, tables and examples. Contextual literal checking preserves computed-value types, refinements and nominal boundaries. Constant collection inputs are materialized through the existing checked definition evaluator before final Core validation. Public metadata distinguishes Set from SortedSet, private constructors and storage fields remain hidden, and user paths cannot select a legacy grammar or replace compiler-owned unit identities. Table labels retain set notation.

The canonical authoring suite passes 120 tests; the final collections suite passes 28 tests, including explicit generic Eq requirements, incomplete unbounded-domain coverage and checked exact arguments beside literal collection arguments. Six finite laws and eleven literal examples pass native execution on every one of the 17 targets at both normal and compact-32 profiles. Three independent expectation mutations fail natively on each target/profile, for 102 native mutant rejections. Both public suites and the checked internal operation suite are scheduled in CI. The actual rebuilt WASM passes source/artifact integrity. Native/WASM agrees on 234 complete API comparisons, including 204 fixture/target/width/layout generations and complete combined legacy-catalog checks and JavaScript generation at both widths.

The first full compiler run finished with 1,661 tests and nine failures, all caused by the combined legacy catalog exposing a contextual-argument regression; the corresponding npm run finished with 186 passes and one failure, with no skips. The corrected argument path retains the existing checked exact conversion rather than unifying a computed argument's natural type with the declared parameter. Its focused collections suite passes, as do all ten catalog/test-manifest checks, including eight backends and a custom test directory. A second actual WASM rebuild includes that correction. The corrected full compiler regression passes all 1,662 tests with zero failures (1,005.1 seconds). The corrected full npm regression passes all 187 tests with zero failures or skips (1,968.6 seconds), including independent repeated full-catalog exports. That run started before the two final view checks were added; those pass in the separately recorded focused suites. No uninterrupted 189-test current-catalog run is claimed.

Developer explanations again include checked concrete example inputs and every expectation. All views retain the same examples, assertion and evidence. Displayed domains use canonical Set/SortedSet metadata and preserve qualification when user types share a name. The 24 focused authoring/set consumers pass, followed by the final five set-consumer checks covering qualified same-named types and all 20 expression-presentation/TypeScript checks. All 75 generated outputs, source/artifact integrity, 222-module boundaries, six editor tests and documentation checks for 118 pages/114 snippets pass. The installed-package smoke workflow selects optional checks explicitly and uses the canonical starter's law and adapter names. Its installed CLI/API run passes, including the bundled-example export, structural generation on all 17 targets at both widths/layouts, and Rust scaffold, doctor, adapter execution and regeneration. The final display-qualification correction is covered separately by the focused presentation tests. The main native build, generated outputs, integrity and module boundaries also pass. No completion of still-running checks, RC1 acceptance or tag is claimed. Complete set-input generation, dependent shrinking, native adapter coverage, generalized collection membership, set-term presentation and validated project migration remain requirements.


Finite set checking now enumerates every duplicate-free stored sequence over a complete finite element domain, preserving observable iteration order and equal-but-differently-stored inner values. Boolean sets have five inputs; nested Boolean sets have 114. Empty, Unit and Maybe Bool element domains have one, two and sixteen set inputs respectively. The enumeration budget bounds traversal before factorial materialization. A non-reflexive element admits arbitrarily many unequal repetitions, so the checker retains incomplete coverage rather than claiming a finite set domain. Dependent input restrictions continue to filter the complete tuple domain through checked evaluation.

Native generators and their shrink paths retain the first language-equal occurrence without ordering or hashing. Complete element and dependent input checks remain in force; supplied native factories are validated without repairing their values. JVM generators retain a small-budget branch beside the full-budget branch: otherwise increasingly long raw Boolean lists almost always deduplicate to two-member sets and can miss unequal-size pairs. A complete singleton property input runs once, retaining planned evidence rather than gaining exhaustive or proof status. Empty alternative types now emit correctly for TypeScript, Haskell, Rust and .NET; .NET empty codecs reject values in both directions, and their generated carrier has no public constructor. Mandatory definition checks and contract enforcement remain unchanged.

The new permanent finite-domain suite contains eight laws and five explicit iteration rows. Its three specification mutants independently remove a stored order or assert incorrect cardinalities; complete Core checking refutes them during generation. The native-generation suite reuses those laws and adds Float64 and Symbol insertion/membership plus four explicit IEEE/identity examples. Its dependent-size and large-IEEE-set mutants must fail in native property execution, exercising dependent shrinking and generated sets larger than the fixed boundary samples. Both suites are registered for all 17 targets in the normal and compact 32-bit CI profiles. The collection reference now states the Eq requirement per operation: membership always requires element equality; iteration, size and emptiness do not.

Checkpoint validation: the 23-test Eq-only filter and 31-test collections filter pass. The rebuilt WASM passes both new finite-domain consumer tests at both widths, including honest unselected/planned evidence, insufficient-budget diagnostics and independent refuting mutants. All 76 generated files, source/artifact integrity, 222-module boundaries, six editor checks and documentation checks for 118 pages/114 snippets pass. The final finite-domain suite passes all 17 native targets in both normal and compact 32-bit profiles, rejecting 102 specification mutants by complete Core evaluation during generation. The property suite also passes all 17 native targets in both profiles and rejects 68 mutants in native property execution. These are distinct evidence stages. Native/WASM agrees on 158 complete API responses, including 136 target/width/layout generations, optional-layer evidence, idempotent formatting and insufficient-limit diagnostics. The rebuilt main native package, generated outputs, integrity and boundaries pass. The full compiler regression passes 1,669 tests with zero failures (1,085.3 seconds). That run began before the final JVM sampling-only runtime correction; the corrected generators are covered by the complete native matrix and final native/WASM parity above. The full npm regression passes all 191 tests with zero failures or skips (2,072.0 seconds), including independent repeated bundled-example exports. It began before the final Kotlin nullability-only runtime correction; that correction is covered separately by the final native and parity checks. No RC1 acceptance or release tag is claimed. This is an implementation checkpoint, not RC1 acceptance or a release tag.


Canonical membership now accepts List, Set, SortedSet, Queue, Stack, Deque and Bytes, with Eq required for elements. `prelude.member value members`, `value in members`, `value is in members` and `value must be in members` share the same typed meaning. Membership is nonassociative and retains precise keyword boundaries. Maps select keys, values or entries explicitly; sized containers use their existing checked item-list operations. Text substring matching remains separate.

`prelude.any predicate members` uses the existing checked, scoped element iteration and requires no extra Eq capability. Predicate definitions retain their own requirements. Membership evaluates both arguments once in source order; partially applied predicates evaluate their captured arguments once before iteration, even for empty collections. Captured literals and literal collections retain context through partial application, composition and explicit function annotations, while computed values retain their own types and nominal identities. Generated callback slots remain monomorphic and capture-avoiding. Private callback names and nested membership temporaries now receive valid, distinct native names. All intrinsic definition checks and runtime enforcement remain mandatory with no selected law layers.

The new source fixture has twenty laws and six independent table rows, including checked definitions, nested membership, ordinary variable names, floating contexts, IEEE equality, explicit maps and sized operations. Three expectation-only mutants must compile and fail in native execution; they do not change the authoritative laws. Both profiles are registered in CI. Ordinary logical negation without a quantifier now lowers into the native execution plan through the existing Boolean lowering, retaining the original typed proposition and evidence. This corrects the earlier emission rejection without changing search completeness or treating a bounded miss as nonexistence.

Checkpoint validation: the final collections filter passes 37 tests, including composed and annotated predicate contexts and mandatory strict-argument rejection with no optional checks. The preceding canonical filter passes 130 tests and the target/interface filter passes 78, including the private-name regression. The final twenty-law fixture passes all 17 native targets in both normal and compact 32-bit profiles and rejects 102 expectation-only mutants during native execution. The preceding seventeen-law run is retained as separate history; the final matrix also covers the added checked-definition, nested-membership and ordinary-name cases. Twenty final WASM authoring/presentation consumers pass. The preceding full compiler snapshot passes 1,675 tests with zero failures (1,045.0 seconds); a fresh full run covers the later scope and callback-context fixes. The actual final WASM is rebuilt and source/artifact integrity matches. All 77 generated files, 222-module boundaries and documentation checks for 118 pages/114 snippets pass. Native/WASM agrees on 78 complete API responses, including 68 target/width/layout generations, checked optional-layer evidence and idempotent formatting. All six editor checks pass. The subsequent full compiler regression passes all 1,676 tests with zero failures (984.7 seconds), covering the final scope and callback-context changes. The full npm regression passes all 194 tests with zero failures or skips (1,907.8 seconds), including independent repeated full-catalog exports. No RC1 acceptance or release tag is claimed.


Authored function identities now survive imports, re-exports and specialization independently of executable names. Schema 5 declarations expose optional `source: {unit, name, canonicalName?}` metadata; known compiler-owned collection operations carry their authoritative prelude name. Explanation views use that identity to display original names, qualify collisions, preserve escaped phrase spelling, and show complete list literals, checked set construction and membership. Validated concrete set inputs use `#S{...}`. Unknown list tails, dependent or unused strict bindings, conversions and arbitrary raw set-storage expressions remain explicit. The views retain the original typed assertions, inputs and evidence; mathematical constructor/case/iteration presentation is not universally authoring syntax.

A compiler-looking user function name exposed an older termination-identity heuristic that stripped generated name prefixes and suffixes. Specialization now records its actual template identity, and the mandatory totality audit uses that explicit identity. A recursive cycle of specialized instances must share a single decreasing parameter across its bodies and checks. Different definitions do not become the same definition because their names resemble compiler output. Deferred nonlinear postconditions retain runtime enforcement.

Checkpoint validation: 39 collection checks, 96 contract-filter checks, 65 refined-definition proof checks (including both new identity/cycle regressions), and 20 GADT checks pass. The actual rebuilt WASM passes all 27 focused expression, membership and TypeScript consumers with no skips, including facade specialization, escaped phrase collisions, misleading user filenames/names and recompilation of displayed set membership with the same finite outcome. The twenty-law membership fixture passes all 17 native targets in both normal and compact 32-bit profiles, rejecting 102 expectation-only mutants during native execution. All 77 generated outputs, source/artifact integrity, 222-module boundaries, six editor checks and documentation checks for 118 pages/114 snippets pass. New Core metadata changes dependent definition/test cache fingerprints. The full compiler regression now passes all 1,680 tests with zero failures (1,019.5 seconds). The subsequent full npm regression passes all 204 tests with zero failures or skips (2,065.0 seconds), including independent repeated full-catalog exports. The subsequent broader native/WASM run agrees on all 366 complete responses, including 340 generations across membership, structural-record, GADT and indexed-family fixtures, all 17 targets, both widths and both layouts. Correspondence with the preceding compiler also passes all 366 responses after excluding only additive declaration source metadata, dependent test-cache keys and declaration-fingerprint literals inside generated remote registries; executable bodies, contracts, structural descriptors and the remaining generated files compare exactly. No RC1 acceptance or release tag is claimed.

Canonical public prelude operations now resolve unqualified after lexical bindings, local declarations and explicit imports. Prefix and named-infix calls use the same resolution path; an ambiguous explicit import stays an error, and a local type mismatch does not trigger fallback. The public operation catalogue reuses the compiler's helper, collection, matcher, duration and railway tables; internal execution helpers remain inaccessible. Dependency discovery uses lossless tokens without changing source text or reading helper words inside comments, strings or phrase bodies. Operation demand loads a provider independently of same-spelled local/imported types; namespace-only imports preserve those nominal identities when all provider type names are shadowed. Canonical railway elaboration follows name resolution and does not optimize user `Left`/`Right` constructors as Either values. Legacy grammar and mandatory definition checks remain in place.

Checkpoint validation: all 24 focused prelude checks pass, including Eq-only membership requirements, iteration without Eq, strict captures on empty collections, numeric bounds, local/imported/lexical precedence, reserved qualified `prelude.then`, and nominal provider-type boundaries. The eight-law fixture with two table rows and six independent expectations passes every one of the 17 native targets in normal and compact 32-bit profiles, rejecting 102 expectation-only mutants during native execution. The actual rebuilt WASM, with both unsigned JSFFI address conversions explicitly checked, passes all 36 focused prelude, membership, expression and TypeScript consumers with no failures or skips. All 78 generated files, source/artifact integrity, 222-module boundaries, six editor checks and documentation checks for 118 pages/114 snippets pass. The subsequent full compiler regression passes all 1,704 tests with zero failures (1,143.8 seconds). Complete native/WASM parity agrees on 78 responses, including 68 generations across all 17 targets, both widths and both layouts, unselected-law evidence and repeated idempotent formatting. The subsequent full npm regression for this prelude increment passes all 207 tests with zero failures or skips (1,986.6 seconds), including independent repeated full-catalog exports. The pre-fix runs deliberately stopped after discovering a provider-discovery defect, and the intermediate WASM runs stopped after correcting the build step's missed pointer conversions, are not complete validation evidence. No release-candidate designation, acceptance or tag is claimed.

The migration report now includes a computation-edit preview driven by the legacy compiler's checked declaration and expression spans. Effect rows select function versus procedure. Conditional endings use actual branch spans, including nested parenthesized forms. Equality edits use typed equality nodes and source-bearing operand descendants when lowering gives a constructor or intrinsic call a generated origin; multiple ambiguous operator candidates are not guessed. Ordinary strings beginning with the reserved phrase-name prefix receive value-preserving escapes, including immediately following digits. Lossless tokens retain comments and literal spelling elsewhere, and edits record original UTF-16 ranges and retained-source segments with parser-column conversion for Unicode and tabs.

Ten focused checks pass, including actual legacy/canonical recompilation at both widths with identical checked function bodies and contracts, explicit/inferred effects, Boolean/IEEE/refinement equality, lowered operands, comments, literal values, overlap rejection and the real CLI's read-only report and write rejection. The preserved Chapter 6 source produces identical native/WASM reports at both widths: 23 laws, 25 definitions, seven ADTs, 66 examples (65 table rows and the named example) and 85 preview edits comprising 75 computation-header/closer edits, six typed equalities and four conditional closers. The original source SHA-256 remains unchanged. This is a partial edit preview, not a completed Chapter 6 migration or a verified replacement specification; law/type/payload/table transformations, complete frontend source inventory (including uninstantiated generic functions and reusable laws omitted by the concrete Core baseline), complete semantic/generated-behavior correspondence and validated writing remain required. All 80 generated files, compiler/artifact integrity, 222-module boundaries and documentation checks for 118 pages/114 snippets pass; the package dry-run includes the planner and its CLI coordinator. No compiler, WASM or runtime change is made by this preview increment, so the recorded 1,704-test compiler regression remains its compiler baseline. The subsequent full npm regression passes all 217 tests with zero failures or skips (1,833.4 seconds), including the new migration checks and independent repeated full-catalog exports.

The explicit schema-5 `migrationBaseline` entry now returns version-1 parser-owned source syntax after the existing compiler validations succeed. It requires `from: "0.24"` and reports that source grammar separately from the current technical language profile. Its cache is isolated from normal canonical parsing. The inventory is collected before domain elaboration, reusable-law expansion and specialization, retaining unused generic computations and reusable laws, declarations, sections, parameters, type/index parameter kinds, constructor fields, patterns, expression and operator ranges, examples, tables, harness settings and actual closers. Parser lookahead and failed alternatives cannot retain speculative records. Public spans use the existing start/end shape and Unicode/tab column convention. Existing ability inference supplies checked effect rows for source definitions, including pure empty rows; no new typed representation or execution mechanism is introduced.

The migration report includes this inventory beside the concrete Core baseline. Its computation preview now covers unused generic definitions and inferred effectful procedures, parser-owned conditionals and equality tokens even when no Core instance exists. Fourteen focused compiler regressions and seventeen actual rebuilt-WASM/TypeScript consumers pass, including explicit entry/schema checks, normal-cache isolation, mandatory rejection of invalid unused definitions, unselected-law evidence, standalone line-scoped harnesses, wire spans, and concrete specialization of a migrated generic body. All 81 generated files, source/artifact integrity, 222-module boundaries, six editor checks and documentation checks for 118 pages/114 snippets pass. Complete compiler, npm and cross-target native/WASM plus preceding-compiler correspondence results for this increment are recorded below. Full law/type/payload/table transformations, project-wide correspondence, native-binding changes and validated writing remain required. Current grammar still accepts its existing bare law/section/quantifier endings; named endings for every block remain the immediately following minor milestone. No release-candidate designation or tag is claimed.

The checked source-inventory compiler increment now passes the complete compiler regression: **1,718 tests, zero failures** (1,082.9 seconds). Its complete parity run passes 130 native/WASM responses, including 68 generation responses across all 17 targets, both machine widths and both layouts; 104 complete normal responses also match the preceding compiler, and 16 complete migration reports match. No fields or cache fingerprints are dropped in those comparisons. Its full npm regression also passes all **222 tests**, with zero failures or skips (2,006.6 seconds).

The next migration increment extends the read-only preview to quoted law/example names, law import/export markers, explicit reusable-law applications, section delimiters, universal scopes, expectation-first tables, legacy case selection and payload-free alternatives. Relocated expectations retain comments, literal values and original-coordinate segments. An existing `it` reference in a legacy case branch requires an explicit rename to avoid capture by canonical scoped `it`. The report separately exposes canonical compilation acceptance/rejection and explicitly lists the legacy nonempty versus canonical universal input-domain policy change; recompilation alone is not claimed to establish correspondence for empty or dependent domains. Twenty-three focused rebuilt-WASM consumers pass, including finite selected-law checks and a meaningful function mutant rejected at both machine widths. All 84 generated files, compiler/artifact integrity, 222-module boundaries and documentation checks for 118 pages/114 snippets pass. Complete native/WASM comparison passes 108 responses (68 generation responses across all 17 targets, both widths and both layouts), eight complete migration reports and 34 native/WASM mutant-rejection comparisons. The preserved Chapter 6 source yields 640 preview edits at each width while retaining the baseline inventory of 23 laws, 25 definitions, seven ADTs and 66 examples (65 table rows plus the named example); canonical compilation correctly reports the unfinished payload conversion. This is still a partial preview, not a migrated Chapter 6 specification or a validated project writer. The full npm regression for this increment finishes with 228 passes, zero failures and two TypeScript checks skipped because the isolated worktree lacked its toolchain path (1,952.2 seconds). Both skipped checks subsequently pass with the installed TypeScript compiler selected explicitly, covering all 230 tests without code changes; the visitor traverses 810 emitted expressions across 15 node kinds. These are the full-run and supplemental results, not a claim that the original run had no skips. No new compiler, WASM or runtime code is introduced beyond the source-inventory compiler baseline.

Local nominal records and alternative payloads now have a checked-source migration preview: declarations, constructions, table literals and case patterns change together. Nominal record field identities are preserved; alternatives with several fields use an explicit record payload and still require native-binding correspondence. Thirty-five focused consumers pass, including unused generic records and all eight three-layer record/alternative combinations at both machine widths with independent Boolean outcomes and meaningful mutants. Complete native/WASM comparison passes 864 responses: 544 generation responses across all 17 targets, both widths, both layouts and all eight nesting combinations; 16 complete migration reports; and 272 mutant-rejection comparisons. The full npm run reports 240 passes, zero failures and two TypeScript toolchain-path skips (1,972.9 seconds); the two skipped checks subsequently pass with the installed compiler selected explicitly. These separate results cover all 242 tests. All 86 generated files, integrity, 222-module boundaries and documentation checks for 118 pages/114 snippets pass. This generation/checked-law evidence does not claim that the corresponding application implementations ran in all 17 languages.

The source inventory now includes declaration/import namespace bindings from the compiler's existing checked resolver. Type and constructor targets retain nominal identities through aliases, facade re-exports and same-spelled local declarations; value and law targets follow the resolver's portable naming convention. The table is not a map of lexical variables or a second resolver. Migration uses it to rewrite qualified and re-exported record constructions, literals and patterns. Eighteen focused compiler checks and 38 rebuilt-WASM/TypeScript consumers pass. The complete compiler regression passes **1,722 tests**, zero failures (1,082.2 seconds), and the complete npm regression passes **243 tests**, zero failures or skips (1,999.8 seconds), with the TypeScript path selected explicitly. Complete parity passes 208 native/WASM responses, including 136 generation responses over all 17 targets, both widths and layouts, 178 complete preceding-compiler normal responses, and 20 complete migration reports. No fields or cache fingerprints are omitted. An initial extra generation fixture used Rust's reserved unit name `use`; the corrected portable `consumer` unit passes the complete run.

A full Chapter 6 preview exposed a missing source-inventory case: a constructor operand within a comparison retained its atom but not the complete application span. The parser now captures the actual application production before operator precedence combines operands, without adding executable location wrappers or changing existing expression origins. The planner uses those complete spans. Nineteen focused compiler checks and 40 rebuilt-WASM/TypeScript consumers pass, including both equality contexts, parenthesized calls, list arguments and a versioned, byte-preserved Chapter 6 baseline. At both machine widths Chapter 6 now produces 736 planned edits with no planning diagnostics while retaining 23 laws, 25 definitions, seven ADTs and 66 examples (65 rows plus the named example). Its canonical compilation correctly stops at the unfinished legacy numeric-name conversion; this is not a completed specification migration. The original Chapter 6 source SHA-256 remains `07d8116b847aa80e044ad3ea2cbc8317bc949a0c4fe07b560e513d6fa0bfaf06`. The strengthened parity run passes 208 complete responses, 136 generation responses, 178 preceding-compiler normal responses and 20 migration reports, and explicitly requires successful preview planning for every fixture, including Chapter 6. All 86 generated files, integrity, 222-module boundaries and documentation checks for 118 pages/114 snippets pass. The full compiler regression passes all 1,723 tests with zero failures (1,010.6 seconds), and the full npm regression passes all 245 tests with zero failures and no skips (1,877.7 seconds), with the installed TypeScript compiler selected explicitly. The complete logs remain `.artifacts/minor-migration-applications/compiler-full.log` and `.artifacts/minor-migration-applications/npm-full.log`. Complete numeric/Set migration, source-template and generated-behavior correspondence, native bindings and validated atomic writing remain required. Named endings for every block remain the following minor milestone; no release-candidate designation, acceptance or tag is claimed.


The ordered-collection and unsigned-name preview now uses free-reference spans and original declaration identities from the existing checked resolver. Lexically bound names are excluded by that resolver's own traversal; facade exports retain their declaring unit. Parsed import/export item and alias roles let the preview update lists and qualified uses together. Actual legacy Set types and their seven ordered helpers become SortedSet names; unrelated same-spelled user declarations remain unchanged. Primitive BigUInt becomes Whole with its original bounds and native representation. A user refinement named BigUInt remains intact and its canonical spelling conflict is reported, rather than silently changing its domain. General Natural/positive-number and BigInt/native-binding migration remain open. A canonical parser correction separates a let's own `in` delimiter from membership in delimited initializer expressions and the binding body, including nested lets. Twenty-two focused source-inventory checks, 26 canonical-collection checks and 89 canonical-authoring checks pass. All 52 focused rebuilt-WASM/TypeScript consumers pass with no skips; the strengthened six-test collection suite also passes. All 88 generated files, compiler/artifact fingerprints, 222-module boundaries and documentation checks for 118 pages/114 snippets pass. The preserved Chapter 6 preview now has 756 edits and passes canonical compilation with mandatory definition checks at both machine widths. Its original bytes and inventory of 23 laws, 65 table rows, one named example, 25 definitions, seven ADTs and two refinements are preserved. No optional law checks are selected by this preview compilation. The complete compiler regression passes all 1,729 tests with zero failures (243.7 seconds). Complete native/WASM comparison passes 358 responses, including 272 generation responses across all 17 targets, both widths and both layouts, plus 22 whole migration reports. A further 252 complete normal responses agree exactly with the preceding compiler (native source `f785f095`), without removing fields or cache fingerprints. The complete npm regression passes all 251 tests with zero failures and no skips (1,929.5 seconds), with the TypeScript compiler selected explicitly. Evidence remains in `.artifacts/minor-migration-numbers/` in its frozen worktree. Canonical acceptance does not establish migration correspondence: source-template meanings, nonempty/universal domains, generated behavior, native bindings, independent oracles and validated atomic writing remain gates. Named endings for every block remain the following minor milestone; this is not a release candidate or an accepted release.


Chapter 6 now has a repeatable Python native-conformance gate and independent codec vectors. The vectors come from the course's separately maintained decoder, pinned to `nand2tetris/web-ide` revision `52611ad9bc2a30d329293b0cf58be672d672ac96` with checked source digests; regeneration reproduces all 1,792 canonical C-instructions and the digest of all 32,768 A-instructions. They are not derived from the LawSpec computation/destination/jump functions. The Python assembler implements the valid-program text-to-physical-lines contract and the `.asm`/`.hack` file interface. At both 64-bit readable/native-compiler and 32-bit compact/rebuilt-WASM profiles, seed 6061 passes 545 generated native checks: 66 examples, 16 property tests, 453 boundaries and 10 replay hooks. Every one of the 23 laws has an executed property, boundary or example; replay hooks alone do not establish that. Each profile separately checks every A address and C combination against both the native assembler and emitted checked codec functions, plus 13 stateful programs and two exact file-interface checks. Independent repeated calls expose symbol-table leakage. Five native mutants and one checked-specification computation-table mutant are rejected in each profile, for 12 rejections. The latter passes mandatory definition validation with no selected law checks before the external oracle refutes its encoding. The actual source, candidate, compiler, seed and generation settings are recorded in each run's evidence. All 90 generated files, artifact fingerprints, 222-module boundaries and documentation checks for 118 pages/114 snippets pass; the CI addition type-checks and schedules both Python profiles. The archive inventory now includes the collection-migration fixture, and the actual WASM package was rebuilt and fingerprinted without changing frontend, Core or emitter logic. The rebuilt package's complete native/WASM parity run passes 358 responses, including 272 generations across every target/width/layout, 22 complete migration reports and 252 exact complete normal-response comparisons with the preceding compiler. The prior collection increment's full npm regression also finishes with 251 passes, zero failures and no skips; this is its frozen 0ac9fd11 run, not a separate full npm run for the rebuilt oracle package. The complete logs and evidence remain under `.artifacts/minor-chap06-oracles/` and `.artifacts/chapter6-oracles/` in the frozen oracle worktree. These results establish finite codec coverage and Python conformance for executed programs, not a proof of unbounded program laws or project-wide migration correspondence. The remaining 16 Chapter 6 implementations, both migration passes, native bindings, source-template/domain correspondence, validated writing, readability results and all other pre-final-1.0 gates remain in scope. No release-candidate designation, acceptance or tag is claimed.

Migration now exposes versioned fingerprints derived from the complete authoritative checked concrete Core, rather than comparing only its smaller documentary JSON view. Nominal constructor predicates, GADT equations, deferred runtime postconditions, definition policies and model metadata remain in the projection. Source origins and coordinates are excluded; lexical binders, approved law-name delimiter changes and two strict once-only selector/record-construction let forms are normalized conservatively. Literal values, nominal identities, initializer order and actual domain policies are retained. The report separately compares the full program, the definition plane and a clearly labeled projection excluding law-domain policy; per-definition, contract and data-type fingerprints identify changed, added and removed comparison identities. Equal fingerprints cover only that projection. Uninstantiated source templates, native bindings and generated behavior remain unestablished, so overall correspondence remains `not-established` and writing remains disabled. Chapter 6's accepted preview exposes eight changed definitions, changed Predefined and Line payload shapes, an added structural product and all 23 nonempty-to-universal domain changes; none is silently erased or accepted as equivalent.

Fifteen new native comparison/API regressions pass, and the complete compiler regression passes all 1,744 tests with zero failures (237.5 seconds). Sixteen rebuilt-WASM migration consumers pass, including matching computations, actual body mutants, nominal predicates, GADT equations, domain-policy separation, Chapter 6 shape differences, malformed metadata and mandatory unsafe-definition rejection with law layers unselected. The published TypeScript visitor compiles with the snapshot union and rejects malformed switches and unavailable-snapshot claims. All 92 generated outputs, compiler/artifact fingerprints, 222-module boundaries and documentation checks for 118 pages/114 snippets pass. The completed parity and npm results for this concrete-Core increment are recorded below. Evidence remains under `.artifacts/minor-migration-correspondence/` in its worktree. A fresh parser audit confirms plain law/section/quantifier endings are still accepted and named law/section endings are rejected: completing all named endings remains the immediately following minor milestone. No release-candidate designation, migration acceptance or tag is claimed.

The preceding concrete-Core snapshot increment also completes native/WASM parity: 436 complete responses, including 340 generation responses across all 17 targets, both machine widths and both layouts, plus 22 whole migration reports. Another 252 ordinary responses match the preceding native compiler exactly, without removing fields or cache fingerprints. Its full npm catalog subsequently passes all 261 tests with zero failures and no skips (1,914.9 seconds), with the TypeScript compiler selected explicitly. This is the frozen 372a76c1 concrete-Core run, distinct from the template-capture catalog below.

Checked source-template capture now retains the actual pre-specialization source units, typed definition bodies and contracts used by mandatory admission, expanded reusable laws, data declarations and resolved constructor context. Unused generic bodies, capability requirements and reusable-law assertions no longer disappear when concrete specialization omits them. The existing inference and audit share a bounded typed-template cache; there is no additional type checker or execution engine. The source comparison preserves literal values, refinements, parameter relationships, effects and nonempty effect annotations. It excludes comments and coordinates, reconciles explicit versus inferred empty effect rows only for checked pure definitions, and normalizes only a uniquely recognized law-name prefix in generated expansion traces, preserving argument text. All other source-shape differences remain conservative correspondence blockers. Actual domain policies, including unused prelude laws, remain distinct from the projection that explicitly excludes them. Template, concrete Core, native binding and generated-behavior correspondence are separate; writing remains disabled.

Eleven new template regressions, the existing 15 Core comparison checks and all 22 source-inventory checks pass. The complete compiler regression passes 1,755 tests with zero failures (264.9 seconds). All 22 focused rebuilt-WASM migration consumers pass with no skips, including unused-body, capability and reusable-law mutants whose concrete Core is unchanged. Complete native/WASM parity passes 450 responses, including 340 generations across every target/width/layout, 22 whole migration reports and 252 exact preceding-compiler ordinary responses. Four additional full-response comparisons cover all 33 scalar families at both widths, including unbounded integers and a NaN payload. The published TypeScript visitor compiles with the optional template snapshot union. All 92 generated files, artifact/source fingerprints, 222-module boundaries and documentation checks for 118 pages/114 snippets pass. The complete npm catalog subsequently passes all 267 tests with zero failures and no skips (1,903.6 seconds), with the TypeScript compiler selected explicitly. This is the frozen adf72d11 template-capture run, distinct from later compiler increments. Evidence remains under `.artifacts/minor-migration-templates/` in its worktree. Project-wide template equivalence for the remaining shape changes, law-domain correspondence, native bindings, generated behavior and validated atomic writing remain open. Named endings for every block remain the following minor milestone; no release-candidate designation, acceptance or tag is claimed.

Concrete input-domain evidence now runs separately from a law's body and selected verification layers. Examples contribute only their checked inputs; complete finite products, ordinary boundary candidates and restriction hints reuse the existing closed evaluator and value/refinement checker. Each tuple is checked in lexical order, including self and dependent restrictions. A verified tuple establishes inhabitance, never the law. Complete finite rejection without evaluation errors can establish an empty input domain. Bounded misses remain incomplete, unsupported generation is identified, and candidate errors cannot establish emptiness. Opaque handles through nominal fields and existential witness pools are excluded from complete covers. Snapshots carry lossless input witnesses, limits, notes and an explicit assertion that no law body was evaluated. Population-policy changes are matched only with verified witnesses on both sides and equal fingerprints of the transitive domain dependencies, including nominal constructor predicates and deferred runtime postconditions; unrelated definitions are excluded. The ordinary example value serializer is reused. Both comparison modules are now covered explicitly by the Core/frontend boundary check.

Sixteen new native domain regressions pass, alongside 15 Core comparison, 11 template-capture and 22 source-inventory checks. The complete compiler regression passes all 1,771 tests with zero failures (230.0 seconds). All 27 focused rebuilt-WASM migration consumers pass without skips. Complete native/WASM parity passes 460 responses, including 340 generations across all 17 targets, both widths and both layouts, 22 whole migration reports and 252 exact ordinary responses against the preceding compiler. Four additional full-response scalar-catalog comparisons cover all 33 scalar families at both widths, including unbounded integers and a NaN payload. The TypeScript consumer, all 92 generated files, compiler/artifact fingerprints, 224-module boundaries and documentation checks for 118 pages/114 snippets pass. Chapter 6 has verified input tuples for all 23 concrete domains on both sides; 17 population-policy changes have matching dependencies, while six remain unestablished because they reach changed payload shapes. This does not prove any of its laws. The complete npm catalog subsequently passes all 272 tests with zero failures and no skips (1,845.6 seconds), with the TypeScript compiler selected explicitly. This is the frozen 1f44e6eb domain-evidence run, distinct from later compiler increments. Evidence remains under `.artifacts/minor-migration-domains/` in its worktree. Source-template policy correspondence, remaining payload/template equivalence, native bindings, generated behavior and validated writing remain required. All other authoring, demonstration, readability and pre-final-1.0 gates remain in scope; all-named closers remain the following minor milestone. No release-candidate designation, acceptance or tag is claimed.

Constructor payload shapes now have a paired compiler entry, `migrationComparison`. Its original 0.24 input and required canonical `migrated` input independently resolve sources, packages and native bindings at the same machine width, pass ordinary mandatory validation, and select no optional law checks. Migration-only capture now retains every source constructor field through the existing resolution logic, including unused generic fields; ordinary inference keeps its established sparse structural context. A single payload preserves its exact type and checked restrictions under explicit field-ID renaming. A grouped payload derives its descriptor through ordinary source-record elaboration, compares the complete stored descriptor and declaration, instantiates its fields and restrictions, and records the original-to-canonical field permutation. Nominal identity, field labels, parameter relationships, restrictions, constructor metadata and GADT equations cannot disappear. Existing nominal records retain their fields directly; changed indexed/existential payloads remain explicitly unsupported. Unexplained added or removed types remain visible.

Sixteen new native regressions pass, and the complete compiler regression passes all 1,787 tests with zero failures (217.8 seconds). All 41 focused rebuilt-WASM consumers pass without skips, including both machine widths, shape mutants, independent input validation, native request rejection, the actual read-only report, and all eight three-layer record/alternative combinations with their checked Boolean outcomes. The TypeScript consumer, all 93 generated files, compiler/artifact fingerprints, 224-module boundaries and documentation checks for 118 pages/114 snippets pass. Four additional full-response scalar-catalog comparisons cover all 33 families at both widths, including unbounded integers and a NaN payload. Chapter 6's `Line` and `Predefined` payload shapes match the preserved source; the `Compute` record's full descriptor and three-field mapping are retained. This is shape correspondence only: executable construction/matching/projection/update transport, transitive dependency behavior, source-template policies, native bindings, generated behavior and validated project writing remain open. The paired report retains overall `not-established`, `validated: false`, and no law-verification claim. Complete native/WASM parity passes 478 responses, including 340 generation responses across all 17 targets, both widths and both layouts, 22 whole migration reports, and 252 exact ordinary responses against the preceding compiler (1f44e6eb). The paired method itself agrees across both runtimes for accepted shapes, shape mutants and invalid requests. The complete npm catalog subsequently passes all 277 tests with zero failures and no skips (1,905.0 seconds), with the TypeScript compiler selected explicitly. This is the frozen d168c66f payload-shape run, distinct from later compiler increments. Evidence remains under `.artifacts/minor-migration-payload-transport/` in its worktree. All other authoring, readability, demonstration and pre-final-1.0 gates remain in scope. All-named closers remain the following minor milestone; no release-candidate designation, acceptance or tag is claimed.

Certified payload shapes now drive a comparison-only Core transport. The shared complete-Core traversal has a raw mode preserving existing identities, origins and annotations, with explicit expression, declaration and type hooks. Construction wraps old fields in the checked record representation while evaluating each argument once in original order. Matches introduce a payload binder and checked field projections in original binding order. Projections follow the new payload; updates retain replacement-before-subject evaluation. Ordinary record normalization handles generic storage and concrete record identities, and mandatory Core validation audits the entire resulting copy. Full snapshots compare definitions, contracts, laws and model/harness metadata; type catalogs may align by checked identity, without reordering fields or predicates. Strict identity lets and unused projections of already checked structural values have narrow comparison reductions that retain dependent type uses and inconsistent annotations. Original programs and emitters are unchanged by the transport.

Representation observers remain explicit limits. A changed key order, recording, concurrency group or parameter-predicate visitation cannot match solely because its operation node is unchanged. The type traversal also checks intrinsic sorted-set and keyed-map key invariants when no comparison expression occurs; changed map values with unchanged keys can still match. Observer analysis is conservative, including in constructor predicates before certified headers replace them. Independent tests demonstrate a reversed key comparison and a changed traversal outcome from false to deferred-postcondition failure. Existing evaluator hooks confirm strict, once-only effects before and after transport and comparison normalization. External adapters and handlers must respect the value transport; native conformance and unused source-template behavior remain separate. The enclosing migration report stays `not-established` and `validated: false`; matching obligations does not prove them.

The parser now lets a local alternative constructor shadow the implicit prelude's same-named record header, including `Pair`. Canonical recorded-value laws elaborate through all five valid equality wordings with the existing recording-key rules and quantified-recording restriction. The published result types expose actual verification selection and the invariant that intrinsic definition checks remain enabled. Twenty-one new native transport regressions pass. The final complete compiler regression passes all 1,808 tests with zero failures (211.3 seconds), including the intrinsic ordered-container correction. The TypeScript consumer, all 94 generated outputs, compiler/artifact fingerprints, 225-module boundaries and documentation checks for 118 pages/114 snippets pass. Four final full-response scalar-catalog comparisons cover all 33 families at both widths, including unbounded integers and a NaN payload. A native Chapter 6 run matches every concrete definition, contract, datatype and law-body fingerprint after transport; all changed population policies remain separately visible. All 50 final focused WASM/TypeScript consumers pass without skips. Final native/WASM parity passes 578 complete responses, including 408 generations across all 17 targets, both widths and both layouts, 22 whole migration reports and 252 exact ordinary responses against the preceding d168c66f compiler. Chapter 6 definition and law-body matching is asserted at both widths. The new intrinsic-key rejection and unchanged-key/value transport also agree across runtimes. An earlier npm run was deliberately stopped before the intrinsic-key correction, and no completed result is claimed for it. The final complete npm catalog subsequently passes all 284 tests with zero failures and no skips (1,981.4 seconds). This is the frozen 6a88140d corrected transport run, distinct from later increments. Evidence remains under `.artifacts/minor-migration-core-transport/` in its worktree. Project-wide source-template/policy correspondence, observer-preserving transformations, native bindings, generated behavior and validated writing remain open, alongside all other authoring and pre-final-1.0 gates. All-named closers remain the following minor milestone; no release-candidate designation, acceptance or tag is claimed.

Concrete input-domain correspondence now uses the same mandatory-validated payload transport copy. The compiler independently obtains input witnesses on that copy and the canonical program, without evaluating law bodies or reinterpreting old serialized values. `sourceBeforeDigest` binds the transport to the original admitted Core, and the target fingerprint must match the actual canonical snapshot. The report checks snapshot versions, machine widths, validation flags, policy identities, transitive domain fingerprints and witness binder identities before using this evidence. It preserves independently established direct facts when transport evidence is unavailable. Transformed witness tuples explicitly name their `transported-before-and-canonical-after` representation. Changed transitive predicates, complete empty domains, bounded misses, unsupported searches and stale anchors cannot clear a changed policy. A deliberately false law retains input evidence while its body and overall migration remain unestablished. Chapter 6 now establishes all 23 concrete population-policy correspondences at both machine widths: 17 directly and six after certified payload transport. This does not establish the laws or unused reusable-law schemes, external/native behavior, or complete project migration; the writer remains `validated: false`.

Five additional native transport regressions pass; the complete compiler regression passes all 1,813 tests with zero failures (239.3 seconds). All 42 focused rebuilt-WASM and strict TypeScript consumers pass with zero failures and no skips (108.3 seconds). All 95 generated outputs, compiler/artifact fingerprints, 225-module boundaries and documentation checks for 118 pages/114 snippets pass. Four complete scalar-catalog native/WASM responses agree across all 33 families and both widths, including an IEEE NaN payload. Complete native/WASM parity passes 578 responses, including 408 generations across all 17 targets, both widths and both layouts, plus 22 whole migration reports. Another 252 complete ordinary responses match the preceding 6a88140d compiler exactly, without removing fields or cache fingerprints. Both Chapter 6 reports assert all 23 matched concrete input domains and retain the six transformed witness representations. The complete npm catalog subsequently passes all 291 tests with zero failures and no skips (1,940.7 seconds). This is the frozen 7ebbe750 input-domain transport run, distinct from later increments. Evidence remains under `.artifacts/minor-migration-transport-domains/` in its frozen worktree. All remaining authoring, migration, deferred readability and pre-final-1.0 gates remain in scope. All named closers remain the immediately following minor milestone; no release-candidate designation, acceptance or tag is claimed.

Typed bare empty record patterns now reach the existing checked frontend and Core. `record{}` retains its selected record type and lowers to an ordinary match, rather than erasing the constraint as a wildcard. Empty and populated structural products, named records, generic fields and nested payloads work without an Eq requirement. Guards remain ordered and do not establish exhaustive coverage; a missing structural-record fallback now reports a non-exhaustive match. Strict field initialization and once-only selection are measured through the existing evaluator's operation hooks. Scalar, collection, multi-constructor and unconstrained generic inputs still reject. At that increment the reproduced unreachable-row validation gap remained open; the subsequent shape-admission change below addresses it.

Native execution exposed and corrected generated binder identities ending in digits, Go's discarded-product subject becoming unused, and private JVM variant classes colliding with their enclosing type. The JVM implementation now uses the existing case-naming rule. Private F# type abbreviations disambiguate type/constructor names and standard-library arities in typed code and codecs; they preserve public native types and their parameter constraints. Seven finite laws and 16 table rows execute through all 17 targets at 64-bit readable and 32-bit compact profiles, for 34 native projects; both source mutants are refuted during generation in every project, for 68 rejections. All 34 generated projects match the final compiler exactly. Four further native collection-suite runs cover the changed F#/C# codecs at both widths. The new suite is scheduled in the local CI matrix for every target and both profiles.

Seven added native regressions pass in the 20-test focused record suite. The final complete compiler regression passes all 1,820 tests with zero failures (219.3 seconds); all 41 final rebuilt-WASM/TypeScript consumers pass with no skips (98.7 seconds). All 96 generated outputs, compiler/artifact fingerprints, 225-module boundaries, six editor tests and documentation checks for 118 pages/114 compiled snippets pass. Complete native/WASM parity passes 664 responses, including 476 generations across all 17 targets, both widths and layouts, plus 22 complete migration reports. Against 7ebbe750, 244 complete ordinary responses match exactly; eight F#/C# generation responses differ only in explicitly audited private codec abbreviations. No response fields or cache fingerprints are dropped, and these eight are not counted as byte-identical. Four further full-response scalar-catalog comparisons agree across all 33 families and both widths, including a NaN payload. The complete npm catalog subsequently passes all 295 tests with zero failures and no skips (1,924.7 seconds), against the frozen 675962ef artifacts. Evidence remains under `.artifacts/minor-empty-record-patterns/` in its worktree. Source-template migration, remaining pattern diagnostics, native binding migration, validated writing, the deferred reader gate and the larger pre-final-1.0 programme remain required. All named endings remain the immediately following minor milestone; no release-candidate designation, release acceptance or tag is claimed.

The canonical parser now retains an independent shape-admission expression for each refutable authored pattern before ordered specialization discards unreachable rows. The existing inference engine checks those expressions in their own constructor and GADT scopes, then erases them before runtime Core is built. The checks reuse the already selected value and copy no branch bodies or guards. Hidden invalid empty-record types, unknown nested fields, wrong-parent constructors and mismatched literals now reject in unused functions, procedures and laws. Generic field patterns still need no Eq capability; existing GADT accessibility rules, exhaustiveness, failed guards and mandatory definition contracts remain. Operation-hook regressions retain once-only field evaluation in source order. Admission of all unreachable guards and branch bodies remains open.

Five added native regressions pass in the 25-test focused record suite. The complete compiler regression passes all 1,825 tests with zero failures (224.8 seconds). All 57 focused rebuilt-WASM/TypeScript consumer tests pass with no skips, including the corrected test of the formatter's existing rejection of semantically invalid source. All 97 generated outputs, compiler/artifact fingerprints, 225-module boundaries, six editor tests and documentation checks for 118 pages/114 snippets pass. Complete native/WASM parity passes 708 responses, including 476 generations across all 17 targets, both widths and layouts, and 22 complete migration reports. Another 320 complete ordinary responses match 675962ef exactly, including the record fixture's generated files; no fields or cache fingerprints are removed. This reuses the preceding native fixture execution evidence through exact output correspondence; it is not a new implementation-conformance campaign. Four further complete scalar-catalog comparisons agree across all 33 families and both widths, including a NaN payload. The complete npm catalog subsequently passes all 298 tests with zero failures and no skips (1,872.9 seconds), against the frozen 23e2866d artifacts. Evidence remains under `.artifacts/minor-pattern-validation/` in its worktree. All remaining authoring, migration, deferred readability and pre-final-1.0 gates remain required. Every block's named ending remains the immediately following minor milestone; no release-candidate designation, acceptance or tag is claimed.

Canonical tuple types, values, literal examples and recursive patterns now share the existing structural-product and checked-match representations. Two or more components retain exact arity and nesting; Unit, grouping and nominal boundaries remain distinct. Reserved position labels sort in source-position order even beyond nine components, and explicit optional API position metadata drives tuple explanations without guessing labels. Components evaluate once in source order. Irrefutable function/procedure parameter patterns retain their names in own restrictions, subsequent arguments, result contracts and bodies. Ordinary uppercase parameter bindings still shadow prelude conversions; a parenthesized payload-free constructor selects a constructor pattern. Generic phrase specializations use deterministic native word splitting, and normalization collisions require a declaration-specific native-name override rather than silently publishing allocator suffixes.

The new `minor-positional-products` demonstration has seven laws and five independent table rows. Its eleven independent Boolean inputs retain all 2,048 finite cases. Native execution passes all seventeen targets in both the 64-bit readable and 32-bit compact profiles, for 34 native projects. Both specification mutants are refuted during generation in every project (68 rejections); these are source-specification mutants, not native implementation mutants. All 34 generated projects match the final compiler exactly. Large JVM suites share assertion bodies while retaining input checking, symbol contexts, handlers and resource brackets. Scala registration and BEAM list construction use bounded helpers; large Groovy specifications compile statically; Swift builds bounded array portions before its unchanged indexed loop. These changes retain all cases, names and ordering. Groovy reports 2,067 tests with no skips in each profile.

Eighteen focused native regressions pass, including measured once-only component evaluation, dependent restrictions, positive components, mandatory definedness and exhaustiveness, recursive matching, positional comparison and generic native-name collisions. The complete compiler regression passes all 1,843 tests with zero failures (350.1 seconds). Seventy complete native/WASM collision-and-override responses agree across all 17 targets and both widths; four full scalar-catalog comparisons agree across all 33 families and both widths, including a NaN payload. Generated-file, compiler/artifact integrity, 226-module boundaries, six editor tests and documentation checks for 118 pages/114 snippets pass. The rebuilt WASM artifact is 69,094,343 bytes, SHA-256 `022fe0fd5e92858386264ddf79ce963045ae741277920c8eb8cd7c05a0137412`. All seven new rebuilt-WASM consumer tests pass with zero failures and no skips (620.2 seconds), covering all targets, widths and layouts, mandatory rejection, formatting, tuple explanations and explicit name overrides. Complete native/WASM parity subsequently passes 806 responses, including 544 generations across all 17 targets, both widths and layouts, plus 22 complete migration reports. Another 320 complete ordinary responses match 23e2866d exactly, with no response fields or cache fingerprints discarded. The complete npm catalog passes all 305 tests with zero failures and no skips (2,105.3 seconds). These results use the frozen a6d3fe08 compiler and artifacts, including the subsequent documentation-only evidence update. Earlier partial regression runs stopped for the confirmed Swift/Groovy emitter corrections are not passing evidence. Evidence remains under `.artifacts/minor-positional-products/` in its worktree. This is a reviewable minor-authoring checkpoint, not milestone acceptance; all remaining migration, readability and pre-final-1.0 gates remain required. Every block's named ending remains the immediately following minor milestone. No release-candidate designation or tag is claimed.

Canonical first-matching cases now retain typing obligations for guards and bodies that ordered specialization discards completely, including an unnecessary `otherwise`. The parser tracks which authored bodies survive, removes its temporary row markers, and retains only the discarded bodies for independent checking against the case's result type. Live rows keep the actual ordered matcher's dependent facts. The existing inference engine checks the retained rows in their own constructor, record, tuple and GADT scopes; an unspellable source-only local supplies the known result type outside that row's pattern. No runtime value or unchecked function is introduced. Existing GADT accessibility rules still exclude impossible constructors. Names, Boolean guards, result types, contextual scalar bounds and capability requirements remain mandatory even without selected law-verification layers. Discarded computations never run, and ordinary exhaustiveness, definedness, termination and deferred-postcondition enforcement continue on the executable definition.

Four previously accepted invalid programs now produce definition diagnostics for an unknown body name, mismatched result, non-Boolean guard or unknown fallback. Fourteen focused native tests pass at both machine widths, including constructor-local GADT equations, inaccessible constructors, nested scopes, exact UInt8 literals and generic Eq requirements. Operation hooks observe only the selected subject and live body, in order; unreachable zero division and recursion remain outside the executable contract while their reachable counterparts still reject. The 25-test record and 18-test tuple regressions pass. The complete compiler regression passes all 1,857 tests with zero failures (280.6 seconds). The `minor-branch-admission` demonstration has four laws and four independent table rows and passes all 17 native targets in 64-bit readable and 32-bit compact profiles. Both invalid-row specification mutants are rejected during mandatory definition admission in every project (68 generation rejections); these are not native implementation mutants. All 34 new generated projects and all 34 preceding positional-product projects match this compiler exactly, preserving the earlier native execution evidence.

All three added rebuilt-WASM consumer tests pass with zero failures and no skips (26.3 seconds), covering every target, both widths/layouts, check/expand rejection without optional law layers, unselected evidence, formatting, all four explanation views and absence of admission locals in public results. Seventy full native/WASM name-collision/override responses and four full scalar-catalog comparisons also agree. All 100 generated outputs, compiler/artifact fingerprints, 226-module boundaries, six editor tests and documentation checks for 118 pages/114 compiled snippets pass. The rebuilt WASM artifact is 69,120,790 bytes, SHA-256 `9548ce13ed18d81a2d2da03bb88577c9c1cb5c58078aa81f65fc494d07c28eee`. The complete npm catalog subsequently passes all 308 tests with zero failures and no skips (2,009.3 seconds). Complete native/WASM parity passes 924 responses, including 612 generations across all 17 targets, both widths and layouts, and 22 whole migration reports. Another 472 complete ordinary responses match the preceding a6d3fe08 compiler exactly; no response fields or cache fingerprints are dropped. These results use the frozen cd087240 compiler and artifacts. Evidence remains under `.artifacts/minor-branch-admission/` in its worktree. Precise row diagnostics and optional unreachable-branch reports remain open; the migration writer remains unvalidated. All other authoring, deferred readability and pre-final-1.0 gates remain required. Every block's named ending remains the immediately following minor milestone, and no release-candidate designation or tag is claimed.

### Uniform input-domain evidence for checked source templates — 16 October 2026

Migration snapshots now retain separate input-domain evidence for every admitted expanded source law, including reusable laws omitted from executable Core. Concrete laws reuse their actual checked domain rows after matching owner, law identity and input names. Other laws use a domain-only analysis copy with assertions, examples, resources and harness execution removed; the original source capture remains unchanged. The ordinary specializer, frontend, mandatory validators and checked evaluator analyze that copy using the complete captured constructor context, including unused polymorphic fields. No law function parameter is sampled and no law body is evaluated. Domains depending on a law parameter or resource remain unsupported; generic generation retains its existing unsupported limits. Complete finite emptiness, bounded misses and populated tuples keep their distinct evidence states.

Each template-domain snapshot is anchored to all four complete source-template digests, its version and machine width. The migration comparator requires those anchors, matching domain dependencies and verified uniform input witnesses before clearing a changed population policy. The full policy-erased expanded template must also match before its laws correspond. Empty domains, incomplete search, stale or transplanted evidence and changed source bodies or definitions cannot clear that gate. Individual concrete or fixed reusable laws can now establish domain correspondence while unused generic prelude laws remain visible blockers. Native binding migration, generated behavior, broader source-template transport and validated writing remain separate requirements; the writer remains unvalidated.

Fourteen added native regressions pass in the 25-test source-template suite, including parameter shadowing, dependent restrictions, unused polymorphic and intrinsically restricted constructor fields, bounded misses and unevaluated false or undefined bodies. The final frozen complete compiler regression passes all 1,871 tests with zero failures (277.2 seconds). Forty-eight native responses across both widths, legacy capture, canonical check and expansion differ from cd087240 only by the declared optional source-template domain field; all preceding response fields and fingerprints agree. Five focused rebuilt-WASM checks pass with zero failures and no skips (2.0 seconds), including both widths, malformed or transplanted anchors and actual uniform, generic, parameter-dependent, empty and incomplete domains. An earlier combined consumer run passed 34 checks and exposed a hardcoded 64-bit width in the new test helper; all five checks using the corrected helper were rerun successfully. This is not a claim that that earlier combined run passed. Published TypeScript, all 100 generated outputs, compiler/artifact fingerprints, 226-module boundaries, six editor tests and documentation checks for 118 pages/114 compiled snippets pass. The actual rebuilt WASM artifact is 69,212,336 bytes, SHA-256 `85f8e41bb52b4066a4f0ad8b0e6ce88d438e8877486c5ad1b4a49a00d72ed97f`; both unsigned pointer conversions were positively verified. The complete npm catalog subsequently passes all 313 tests with zero failures and no skips (2,006.3 seconds). Complete native/WASM parity passes 972 responses, including 612 generations across all 17 targets, both widths and layouts, and 22 whole migration reports. Another 472 complete ordinary responses match cd087240 exactly, with no response fields or cache fingerprints dropped. For 180 migration-snapshot responses, removing only the declared optional source-template input-domain extension produces the preceding compiler response exactly; these are extension checks, separate from the byte-identical ordinary responses. These results use the frozen 3c8422a9 compiler and artifacts. Evidence is under `.artifacts/minor-template-domains/` in its worktree. This is a minor-authoring checkpoint, not milestone acceptance; all remaining migration, deferred readability and pre-final-1.0 gates remain required. Named endings for every block remain the immediately following minor milestone. No release-candidate designation or tag is claimed.

### Constructor indices determine generic payloads — 16 October 2026

Constructor equations now constrain the same fresh indices in payloads and results. Construction realizes those equations before contextual argument checking. Matching ties payload indices to the actual scrutinee under its branch-local givens, then restores the outer scope. Generic definitions can destructure a payload declared as `a` when that constructor fixes `a` to a structural record. Determined existentials shared by multiple indices remain related. Concrete structural indices use the existing closed-record comparison, including label order independence and complete stored restrictions. Existing inaccessible-branch, existential-witness, capability, definedness, refinement and termination checks remain mandatory. This introduces no new function category or verification switch.

The indexed-reading demonstration has four laws and ten independent table rows. Native integration exposed generation errors in fixed-index fields and codecs that source emission alone missed. Generated native sum cases now apply fixed equations to their fields; public product parameters remain available. Java/Kotlin codecs bridge the refined fields through existing checked schema codecs, Kotlin/Scala product decoding keeps the product's complete parameter list, Python bases use forward references for later data types, TypeScript fixed cases no longer reference an undeclared parameter, Go uses fixed field codecs where its variant removes an index parameter, and Haskell derives display with the needed directly determined payload constraint. Native display does not add a source `Eq` capability. The demonstration's fixture was retained through these corrections.

Twelve new focused native regressions pass (5.0 seconds), alongside the 18-test GADT and 14-test structural-payload suites. The final frozen complete compiler regression passes all 1,883 tests with zero failures (267.7 seconds). All 17 native targets pass in 64-bit readable and 32-bit compact profiles. Both specification mutants are rejected during mandatory generation in all 34 projects (68 rejections); these are not native implementation mutants. All 34 final projects match this compiler's generated files exactly. Java reports 526 tests with no failures, errors or skips in each profile. Three rebuilt-WASM consumer tests pass with zero failures and no skips (41.9 seconds), covering every target, width and layout, mandatory rejection without optional law layers, unselected evidence, formatting and all four explanation views. Seventy complete native/WASM name-collision/override responses and four full scalar-catalog responses also agree, including all 33 scalar families at both widths and an IEEE NaN payload. All 101 generated outputs, compiler/artifact fingerprints, 226-module boundaries, six editor tests and documentation checks for 118 pages/114 compiled snippets pass. The actual rebuilt WASM artifact is 69,249,731 bytes, SHA-256 `b3a79e1f19dd6c227521618d2c1204d02680568b817dd50a1e91e2592689fe22`; both unsigned pointer conversions were positively verified. Earlier native failures led to the recorded generator corrections and are not passing evidence. The subsequently completed npm catalog passes all 316 tests with zero failures and no skips (1,981.3 seconds). Complete native/WASM parity agrees on 1,050 responses, including 680 generations across all 17 targets, both widths and layouts, and 22 whole migration reports. Another 472 complete ordinary responses match the preceding 3c8422a9 compiler exactly, with no response fields or cache fingerprints dropped. These results use the frozen 0e745026 compiler and artifacts. Evidence is under `.artifacts/minor-structural-families/` in its worktree.

This does not complete recursive-container representation conversion. A generic alternative carrying `List record{...}` still requires checked reconstruction between parameterized and canonical record storage, although plain lists of anonymous records already work. Refinement inside structural GADT index arguments and the other source-integration, migration, diagnostics and demonstration gates remain open. The writer remains unvalidated. All remaining authoring, deferred readability and pre-final-1.0 requirements remain in scope. Named endings for every block remain the immediately following minor milestone; no release-candidate designation, milestone acceptance or tag is claimed.

### Checked structural records inside recursive containers — 16 October 2026

Generic nominal payloads now carry structural records inside List, Maybe, nested lists and user-defined recursive containers. Representation changes use ordinary exhaustive Core matches and recursive definitions, admitted by the existing independent typing, termination, definedness and constructor-contract checks. Source-template proof admission uses those same definitions and the shared definition-to-proof projection. Nominal identities, closed field sets, stored restrictions and evaluation order remain authoritative; opaque storage and infinitely expanding specializations receive no unchecked conversion. Closed table literals are reconstructed from data syntax without executing functions or dropping unused computations. Repeated normalization regenerates and compares helper bodies before removing representation calls; altered helpers are rejected.

The seven-law batched-readings fixture contains five independent table rows. Five laws have complete Boolean domains; the two requirements over unbounded lists retain planned examples under exhaustive-only checking. Native execution selects property tests and examples, and exhaustive-only native generation correctly reports incomplete coverage. Explanations use an explicit compiler marker and matching full signature to hide representation calls in presentation while retaining the typed assertion. Names alone do not authorize hiding a call. Public TypeScript declarations include that optional marker.

Native execution exposed a Go dependency omission: a helper used directly by a law was absent from its package. Go now includes calls from law inputs, bodies, examples, resources, contracts, harness callbacks and benchmarks in its checked-definition closure. Consumer rejection tests also exposed repeated nominal declarations in standalone source-proof catalogs. Identical nominal declarations are now coalesced, disagreements are rejected, and structural occurrences retain their admission checks. A concrete checked-let regression distinguishes the actual division-by-zero rejection from a catalog error.

All 14 focused native regressions pass (4.5 seconds). The final frozen complete compiler regression passes all 1,897 tests with zero failures (350.0 seconds). All 17 native targets pass in 64-bit readable and 32-bit compact profiles, with 34 mandatory field-label rejections and 34 natively executed wrong-result mutant rejections. All 34 projects match the final compiler's generated files. Separate successful Java reruns report 36 tests with zero failures, errors or skips in each profile; those XML reports supersede the expected failing mutant reports. Four final rebuilt-WASM consumer tests pass with zero failures and no skips (82.3 seconds), including all target/width/layout combinations, mandatory rejection with no selected law layers, formatting, planned versus completed evidence, four explanation views, and marker/signature controls. Four full scalar-catalog comparisons and 70 complete name-collision/override responses agree between native and WASM. All 102 generated files and compiler/artifact fingerprints agree. The 227-module boundary check, six editor tests and documentation checks for 118 pages/114 compiled snippets pass. Evidence is recorded under `.artifacts/minor-container-record-views/`; the subsequently completed npm catalog passes all 320 tests with zero failures and no skips (2,116.8 seconds). The subsequently completed broad native/WASM parity run agrees on 1,128 complete responses, including 748 generations across all 17 targets, both widths/layouts and 22 whole migration reports. Another 550 ordinary responses match the preceding 0e745026 compiler exactly; no response fields or cache fingerprints were dropped. The actual rebuilt WASM artifact is 69,572,796 bytes, SHA-256 `aeeb74f9a9e8bc4c2c28187146bb046930175f5c4b83046e8c4110f283cf3a0d`; both unsigned pointer conversions were positively verified. Earlier exhaustive-only, Go and consumer failures are not passing evidence; the interim broad parity run was stopped after the Go failure and is being rerun against the final artifacts.

This closes the demonstrated generic container cases, not the broader authoring or migration gates. Refinement inside structural GADT index arguments, checked function expansion in anonymous restrictions, remaining model/actor integration, validated migration writing, deferred readability and the larger pre-final-1.0 programme remain required. Named endings for every block remain the immediately following minor milestone. No release-candidate designation, milestone acceptance or tag is claimed.

### Stored restrictions in structural GADT indices — 16 October 2026

Refined structural indices already determined the payload's type at construction and matching. Exact division exposed a separate missing-assumption path: the nonzero-denominator check queried existing linear constraints directly instead of using the common entailment path that supplies admitted field domains and constructor predicates. It now uses that shared path, including dependent sibling restrictions such as `upper > lower`. A zero-inclusive restriction remains insufficient. The denominator and its strict construction/call inputs still receive their independent definedness and admission checks. No new proof algorithm or Z3 integration is introduced.

The positive-readings demonstration has five checked definitions, two indexed alternatives, five laws and twelve independent table rows. It covers generic payload projection and record patterns, ordinary refined records, nested Nat fields and dependent intervals. All five laws have complete finite input domains in the API; those law restrictions do not limit the definitions' admitted inputs. Native execution selects property tests and examples so its wrong-reciprocal mutant reaches native execution. Weakening the stored positive restriction to include zero is rejected during mandatory generation.

All 14 focused native regressions pass (17.9 seconds), and the complete compiler regression passes all 1,911 tests with zero failures (373.5 seconds). All 17 native targets pass in 64-bit readable and 32-bit compact profiles, with 34 mandatory zero-inclusive rejections and 34 natively executed wrong-reciprocal rejections. All 34 projects match the compiler's generated files exactly. Separate positive Java reruns report 21 tests with zero failures, errors or skips in each profile. All 103 generated outputs and source/artifact fingerprints agree; the 227-module boundary check, six editor tests and documentation checks for 118 pages/114 compiled snippets pass. Four complete scalar-catalog responses and 70 complete naming-collision/override responses agree between native and WASM. The actual rebuilt WASM artifact is 69,576,288 bytes, SHA-256 `b84596b16a5d5c65cf4551ffb4d3dc82d436fd587815ce3f930dbb0ae21bf99a`; both unsigned pointer conversions were positively verified. Three new rebuilt-WASM consumer tests pass with zero failures and no skips (375.0 seconds), covering 68 target/width/layout generations, 24 mandatory check/expand rejections without law layers, idempotent formatting, all four explanation views and unselected evidence. Focused native/WASM parity agrees on all 102 complete refined-index responses, including 68 generations and 24 mandatory rejection responses across both widths; no fields were omitted. The subsequently completed broad native/WASM parity run agrees on 1,230 complete responses, including the 102 focused responses, 816 generations across all 17 targets/both widths/layouts and 22 whole migration reports. Another 628 ordinary responses match the preceding 6dca3703 compiler exactly, with no response fields or cache fingerprints dropped. The complete npm catalog passes all 323 tests with zero failures and no skips (2,120.0 seconds). These results use the frozen e32ffca5 compiler and artifacts. Evidence is under `.artifacts/minor-refined-gadt-indices/` in its worktree. Initial exhaustive-only native harness attempts refuted the source mutant during generation; those attempts are excluded from the native mutant evidence. An initial editor run lacked installed dependencies and is superseded by the successful six-test run.

This closes the demonstrated refined fixed-payload index cases and their missing denominator facts. Broader indexed-container and model/actor integration, checked function expansion inside anonymous restrictions, validated migration writing, deferred readability and the larger pre-final-1.0 programme remain required. Named endings for every block remain the immediately following minor milestone. No release-candidate designation, milestone acceptance or tag is claimed.

### Proof engineering research priority — 16 October 2026

The user requires proof work to prioritize SPARK/Ada, Lean 4, Idris 2, Rocq and relevant established systems. Before extending custom proof machinery, consult primary documentation and implementation sources, identify the applicable precedent, and record the reuse or adaptation decision and trust boundary. This working instruction is also recorded in `AGENTS.md`.

Historical implementation status before the Z3 host checkpoint below (retained as the research baseline):

The current arithmetic path is homegrown: `Core.Totality` calls `Core.RefinementProof`, whose bounded linear implication checker uses Fourier–Motzkin elimination. No Z3 binding or SMT-LIB solver invocation is wired into that path. The previously recorded direct Z3/SMT-LIB integration remains unfinished; the current `proof` layer must not be described as a Z3 backend.

[SPARK's architecture](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/appendix/quality_assurance.html) retains language analysis and translation in GNAT2Why and delegates prover tasks through Why3 to external engines. [Why3's VC generator](https://why3.org/doc/vcgen.html) supplies the relevant model for preconditions, stored invariants, construction obligations and termination. [Why3's prover interface](https://why3.org/doc/manpages.html) also preserves resource-limit outcomes, replayable sessions and counterexample validation. These are precedents for LawSpec's integration, not claims that those components have been adopted.

[Lean 4's elaboration/kernel boundary](https://lean-lang.org/doc/reference/latest/Elaboration-and-Compilation/), [Idris 2's dependent proofs and totality](https://idris2.readthedocs.io/en/latest/tutorial/theorems.html), and [Rocq's core language](https://rocq-prover.org/doc/v9.0/refman/language/core/index.html) are additional starting points for proof terms, recursive definitions and trust. Their language policies are not copied wholesale: LawSpec's automatic definition checks remain mandatory, and its empty-domain, IEEE equality and effect semantics remain authoritative.

The next solver work must make typed obligations and their assumptions explicit, use an established prover backend, bind results to the exact task and prover configuration, and retain unknown/timeout/unsupported outcomes. Native and WASM host integration must share that contract. Optional law proof selection cannot switch off intrinsic definition obligations. A candidate model involving abstract native functions needs concrete validation before it becomes implementation-refutation evidence. The recorded direct SMT-LIB route and a Why3 integration should be assessed against these requirements before expanding the internal prover.

Implementation-source review uses AdaCore/why3 commit `e8a19d2c821959079c8e24510bc607dd25a276fd`. Its [driver interface](https://github.com/AdaCore/why3/blob/e8a19d2c821959079c8e24510bc607dd25a276fd/src/driver/driver.mli) separates task preparation, printing and execution. Its [prover-call interface](https://github.com/AdaCore/why3/blob/e8a19d2c821959079c8e24510bc607dd25a276fd/src/driver/call_provers.mli) retains resource limits, process status, raw output, timing and models alongside distinct solver outcomes. The [SPARK Z3 driver](https://github.com/AdaCore/why3/blob/e8a19d2c821959079c8e24510bc607dd25a276fd/drivers/z3_gnatprove_ce.drv) selects established SMT arithmetic, bit-vector and floating-point encodings and transformations. The shared [SMT-LIB driver](https://github.com/AdaCore/why3/blob/e8a19d2c821959079c8e24510bc607dd25a276fd/drivers/smt-libv2.gen) accepts `unsat` as validity but does not automatically promote `sat` to a concrete counterexample. This supports keeping solver models distinct from validated LawSpec execution failures.

Retain the agreed direct SMT-LIB/Z3 route: a pure typed task producer shared by native and WASM, with explicit host solver execution. This follows Why3's separation without adding an OCaml/WhyML runtime boundary or developing another search engine. LawSpec-specific work belongs in sound translation of its checked types, restrictions, operations and source identities. The solver protocol, actual Z3 execution, task/prover/configuration binding, result handling and counterexample validation still require implementation; the present source study does not supply them. A later Why3 adapter can consume the same obligation boundary if its theory coverage or prover portfolio warrants it.

The old linear representation is a rational relaxation with some integral comparisons; it is not a substitute for typed integer, rational, decimal and IEEE tasks. Do not infer SMT sorts after erasing those distinctions. Preserve construction checks separately from assumptions about admitted inputs, do not assert unsupported native functions as concrete implementations, and keep empty refined domains legal. SMT `unsat` evidence trusts the selected solver and translation; it is distinct from a Lean/Rocq kernel-checked proof certificate.

An isolated Z3 5.3.1.0 study in `.artifacts/minor-refined-gadt-indices/` checks six manually encoded queries: positive and dependent field restrictions, a missing restriction with a zero-valued model, nonlinear integer reasoning, and IEEE NaN equality. The study demonstrates backend behavior only. It is not a compiler integration or proof of a LawSpec source law. The missing-assumption correction recorded above is verified separately; no new solver implementation is claimed.

### Field predicate expansion audit — 16 October 2026

Historical investigation checkpoint, published at `a5e9e2e0`; the implementation and its verified limits are recorded immediately below.

The next authoring increment exposed defects in the existing nominal-field source inliner. An ignored argument could lose its declared type or refinement precondition, and generated argument names could capture user locals. The working repair independently checks original calls using ordinary definition admission, uses the shared capture-avoiding substitution and retains strict argument order. It also extends expansion to anonymous record positions. Those changes remain under investigation in the isolated `minor-record-predicate-functions` worktree and have not been published as a completed feature.

A further numeric-context regression is confirmed in the published e32ffca5 compiler: a predicate declared with a Float64 argument computes `0.1 + 0.2 = 0.3` as false, while its untyped expansion in a field restriction infers an exact decimal argument and admits a constructor that the authored predicate forbids. The existing green regression counts above do not cover or resolve this counterexample. The source and complete API responses are under `.artifacts/minor-record-predicate-functions/numeric-context*` in that worktree. Preserving call-site argument/result types and generic instantiation is a required repair before this increment can be accepted.

The applicable precedent is [Why3's typed inliner at the reviewed revision](https://github.com/AdaCore/why3/blob/e8a19d2c821959079c8e24510bc607dd25a276fd/src/transform/inlining.ml): it matches argument and result types before typed substitution, retains origins and restricts nonrecursive expansion. [Lean 4's definition reduction](https://lean-lang.org/doc/reference/latest/Definitions/Definitions/) likewise concerns typed definitions. LawSpec's repair must use its existing inference and independent admission machinery to preserve those distinctions. A stronger solver cannot repair a predicate that was mistranslated before reaching the proof boundary. Z3 integration remains separate and unfinished.

### Checked predicate calls in record fields — 16 October 2026

This increment repairs the nominal-field expansion defects recorded in the preceding audit and admits the demonstrated nonrecursive checked predicates in anonymous record positions. The existing inference engine determines each argument carrier, result carrier and generic instantiation before shared capture-avoiding substitution. Strict lets retain evaluation order. Typing-only nominal headers retain source shapes; full completed declarations and original calls still pass independent mandatory admission. Transient admission templates do not enter public declarations, generated code or migration snapshots. Cache entries include the original calls and their dependencies, so changing an ignored argument's signature cannot reuse admission of an identical expanded body.

The repair follows the reviewed Why3 typed-inlining precedent; it does not add another proof engine. An ordinary definition may retain existing deferred runtime postconditions. Expansion currently rejects dependencies with such deferred enforcement rather than erasing it. Tests distinguish Float64 `0.1 + 0.2` from exact decimal arithmetic, including nested generic calls and concrete GADT-selected carriers. Source locations no longer count toward the specialization type-size budget; type and predicate structure and the existing instance limit remain counted. Java, JavaScript/TypeScript, Go and Haskell schema callbacks now allocate distinct strict-let locals.

The six-law, fourteen-row checked-readings demonstration covers positive fields, dependent sibling restrictions, refined structural GADT indices, ordinary and nested records, and contextual floating arguments. Its permanent native suite selects property tests and examples, with a wrong-reciprocal native mutant and mandatory argument-type and precondition mutants. Complete finite checking is verified separately. All 33 focused regressions pass, including long source paths, hygiene, definedness, scope, capabilities, runtime-contract preservation and checked schema local allocation. Four independent before/after source probes confirm the previously accepted wrong type, missing precondition and IEEE-context mismatch are rejected, and the previously captured valid expression is accepted.

The complete compiler regression passes **1,944 tests with zero failures** (559.7 seconds). All 17 native targets pass in the 64-bit readable and 32-bit compact profiles, with 34 wrong-result native mutant rejections and 68 mandatory type/precondition mutant rejections. All 34 generated native projects compare exactly after testing. The final positive Java reports each contain 26 tests with no failures, errors or skips. The actual rebuilt WASM compiler is 69,746,091 bytes (SHA-256 `c7e53451b6f530719d2948c11ba743051d24c2b4f65a04b13300e9dcebbdf2aa`); both unsigned-pointer conversions are positively checked. All 104 generated outputs, source/artifact integrity, 227-module boundaries, six editor tests, and documentation checks for 118 pages and 114 snippets pass. Four complete scalar-catalog responses and 70 complete collision/override responses agree between native and WASM. Chapter 6 retains its recorded SHA-256 and baseline inventory. The three focused rebuilt-WASM consumer tests pass with zero failures or skips (552.4 seconds), covering 68 target/width/layout generation combinations, 48 mandatory negative responses, formatting idempotence, all four explanation views and accurate unselected-law evidence. The complete package regression subsequently passes all **326 tests with zero failures and no skips** (2,211.7 seconds). Focused native/WASM parity also passes all **126 complete responses**, including 68 generation responses and 48 mandatory rejection responses across both widths; no response fields were omitted. The completed broader run agrees on **1,230 full native/WASM responses**, including 816 generation responses and 22 complete migration reports, and matches 700 complete ordinary responses exactly against the preceding `e32ffca5` compiler. No response fields or cache fingerprints were dropped from those comparisons. Evidence and logs are under `.artifacts/minor-record-predicate-functions/` in the isolated worktree.

This is a minor-version checkpoint, not an RC or release acceptance. Recursive/deep or unresolved expansion, stored polymorphic GADT matches needing local Core equality evidence, and complete remaining model/actor source integration stay explicit requirements. The generic GADT limitation is tested as rejection; concrete GADT calls are tested separately. The project migration writer remains unvalidated, human readability evidence remains deferred by the user, and all larger pre-final-1.0 gates remain in scope. No tag is created.

Required work still open:

- Broader stochastic candidate generation, shrinking individual existential witnesses, concrete witness-value traces, and complete variable-width or opaque integer covers made finite only by refinements. Complete constant and fixed-width dependent integer covers now work. Constructive expressions and qualified harness paths now work. Nested and outer finite/empty logical domains now have scoped evidence. Effectful witness searches still require explicit snapshot semantics.
- Remaining generic source-constructor work includes broader indexed-container integration. The demonstrated refined fixed-payload index cases now retain their admitted field restrictions, including dependent sibling relationships, as recorded above. The demonstrated List, Maybe, nested-list and user-defined recursive-container payloads now use checked reconstruction as recorded above. Fixed structural result indices now determine their generic payload fields as recorded above. Generic projection refinements now pass the all-target matrix above. The demonstrated checked field-predicate calls and type/precondition/hygiene/numeric-context repairs are implemented and verified as recorded above. Recursive/deep or unresolved predicate expansion, stored polymorphic GADT matches requiring local Core equality evidence, and complete remaining model/actor source integration still require work. Recursive tuple patterns and irrefutable parameter patterns now reach the checked representation, with verification recorded above. Direct anonymous source types, values, generic product projections/returns and literal examples now pass the checks above. Typed bare empty record patterns now reach the checked matcher and native execution as recorded in this review. Independent admission now checks patterns, guards and bodies hidden by preceding rows while preserving established GADT accessibility rules. Precise row diagnostics and optional unreachable-branch reporting remain required. All eight domain-layer examples now use actual inline anonymous payloads.
- Complete Set/SortedSet migration and native adapter coverage; broader set domains made finite only by refinements and remaining dependent-generation coverage; remaining direct sized-container iteration, pinned full Unicode case folding and exact-widening additions. Canonical source names and checked set operations are now implemented as recorded above.
- Complete finite mapping domains beyond the implemented enums/Booleans, explicit partial lookup, and target/interface coverage of every added feature.
- Source formatting now handles nested cases/mappings and wraps at trivia toward 80 columns; a full authoring corpus and complete language-service navigation remain gates. Schemas 3/4 and configuration 1 remain available during transition; rejecting them from normal canonical interfaces is an unfinished release boundary.
- Expected compile-rejection examples with stable diagnostic codes and the full failure/witness/assumption diagnostic contract.
- The validated project-wide migration engine, both Chapter 6 passes, all specified demonstrations and independent Chapter 6 oracles/mutants, then complete target/docs/parity/release acceptance.

The human readability gate is **deferred by the user**. The larger demonstrations, advanced analyses and GitHub Linguist recognition remain pre-final-1.0 requirements. No RC1 or final-1.0 acceptance or release is claimed.

### Typed obligations and actual Z3 execution — 16 October 2026

Selected law proofs now have a real Z3 execution path. The pure compiler's schema-5 `proofTasks` method translates admitted typed Core into SMT-LIB; `lawspec prove` and the Node package's `lawspec/proof` host execute the configured Z3 binary. The native and WASM compilers share the task producer. This is the previously agreed direct SMT-LIB route, not adoption of Why3 itself and not another arithmetic search engine. The pinned Why3 driver/prover-call study above supplies the separation and outcome precedent.

Task preparation is distinct from completed proof evidence and has a separate compiler-cache namespace. It removes only optional law proof execution from its preparation stages. Mandatory definition validation and deferred runtime contract enforcement remain independent of selected law layers. Ordinary checks retain their existing internal linear checker; this increment does not replace it with Z3. Selecting no proof layer prepares no solver tasks and invokes no solver. The CLI says so explicitly.

The first encoding supports Boolean and integral quantifiers, unsigned and machine-profile bounds, exact arithmetic and rational-valued computations, ordered logical definedness, strict lets, lossless conversions, and nonrecursive pure checked definitions. Calls retain argument preconditions and deferred runtime result checks, including checks on unused arguments. Shared SMT lets prevent repeated checked calls from duplicating argument terms exponentially. Quotient and remainder encode LawSpec's truncation toward zero rather than assuming SMT integer division has the same semantics. Translation has explicit expression and output budgets.

Rational quantification remains unsupported: replacing rational witnesses with SMT Reals could admit irrational witnesses. IEEE and Decimal arithmetic, structural and nominal data quantification, recursive induction, effects, resources and native implementations also remain unsupported in this encoding. Unsupported operations do not become uninterpreted assumptions. Definedness participates in positive and negative certificates; an undefined candidate does not count as a false candidate when proving nonexistence.

The host records the exact task and checked-program hashes, machine width, solver executable hash and version, arguments, configuration, execution fingerprint, timing, exit status and raw output. Only a successful completed `unsat` response upgrades the corresponding law. This trusts the typed translation and selected Z3 executable; it is not a Lean/Rocq kernel-checked proof certificate. `sat` retains an unvalidated model and does not claim a source counterexample. Unknown, timeout, resource-limit, memory exhaustion, unavailable, unsupported, changed-binary and protocol-failure outcomes remain incomplete. Explanations can consume the same typed law and returned obligation evidence. Native implementation conformance remains separate.

The four-law arithmetic demonstration has seven independent table rows and retains its full finite witness domains. Actual native execution exposed JVM host limits that emission-only checks had missed. Kotlin and Scala strict lets now use the existing non-inline JVM runtime helper. For large Groovy execution bodies, generated Java retains the checked expressions and harness while independent Spock features retain discovery, names, skip/order metadata and failure reporting. This avoids Groovy parser heap exhaustion without reducing the quantified domains, changing search completeness or introducing a second executor. Both JVM profiles and the target mutants are exercised. The broader Scala collection regression also exposed a lexical boundary: typed callback names ending in an underscore require whitespace before the colon. The shared typed-lambda emitter retains that separation, and the collection, async, ability, existential and field-predicate suites exercise the correction.

The final frozen complete compiler regression passes all 1,968 tests with zero failures (537.9 seconds). All 17 native targets pass the four-law/seven-row arithmetic demonstration in 64-bit readable and 32-bit compact profiles. Each of the 34 projects rejects the mandatory denominator-precondition mutant and the natively executed wrong-square mutant (68 rejections), and all 34 projects match the final compiler exactly. Successful Java reports contain 18 tests with no failures, errors or skips in each profile. Five additional native suites covering collections, async execution, abilities, existence and checked field predicates pass for each of Kotlin, Scala and Groovy; the corrected Scala suites use the isolated Scala worktree. Ten final rebuilt-WASM/Z3 host consumers pass with zero failures and no skips (6.0 seconds), including real solver execution at both widths, CLI behavior, task/prover bindings, limits, failures and the public TypeScript subpath. All 107 generated files, compiler/artifact fingerprints, 228-module boundaries and six editor tests pass. Final documentation checks pass 119 pages and 114 compiled snippets, including the reconciled public API reference. Chapter 6 remains unchanged (SHA-256 `07d8116b847aa80e044ad3ea2cbc8317bc949a0c4fe07b560e513d6fa0bfaf06`). The actual final WASM artifact is 69,962,710 bytes, SHA-256 `8659cef57b6a2117293a8f5d468249f1792ae46d2ea480361e3299046161278d`; both unsigned pointer conversions were positively verified.

The subsequently completed full npm catalog passes all 336 tests with zero failures and no skips (2,358.4 seconds), against the frozen `917aed91` implementation and its published final WASM artifact. The broader complete native/WASM response-parity run subsequently passes 1,230 complete responses, including 816 generations across all 17 targets, both widths and layouts, and 22 whole migration reports. Another 592 complete ordinary responses match the preceding compiler exactly; intentional Kotlin/Scala/Groovy generation changes are compared against WASM in full and covered by the separate native conformance runs. No response fields or fingerprints are omitted. The separate focused arithmetic run established 288 complete task/check/expand comparisons at both widths, including all task fingerprints, before the generation-performance investigation below; that stopped run remains partial evidence. Earlier package/parity attempts were intentionally stopped after the separate Scala collection regression exposed the callback lexical issue, and are excluded from final acceptance. Evidence and active session tracking are under `.artifacts/minor-smt-obligations/` in its worktree; the source implementation is committed at `917aed91`.

This is a minor-authoring checkpoint, not milestone acceptance or a release candidate. General SMT theory coverage, recursive/inductive proofs, concrete validation of solver models, broader conflict/completeness and temporal work remain pre-final-1.0 requirements. The other remaining authoring, migration, demonstration and deferred readability gates remain required; the migration writer remains unvalidated. Named endings for every block remain the immediately following minor milestone. No tag is authorized.

### Finite-search generation performance audit — 16 October 2026

**Initial investigation, superseded by the completed integration below.**

The pending arithmetic parity comparison exposed a generation-cost issue while preserving its complete Int8 witness domains. Sampling the frozen WASM process identifies GHC string-equality routines. The Python expression emitter scans its complete binder list for both free-name detection and each local lookup; these repeated scans are quadratic for large lowered search terms. An isolated indexed replacement preserves traversal order, first-assigned names for repeated binder identities, allocator gaps and free-name capture avoidance. Its two hygiene tests pass. The full 11 MB Python-generation response agrees with native compilation and returns from the rebuilt WASM compiler in 5.9 seconds; both original controlled runs were still active after many minutes. This is performance evidence for the isolated replacement, not publication or complete regression evidence for that patch.

A separate native compact JavaScript sample maps its hot functions to `Code.Doc`. Compact hanging expressions currently perform line-fit lookahead despite having already selected flat optional breaks. An isolated bypass agrees with the previous renderer on all 27,000 generated document/layout comparisons, including mandatory newlines, tabs, literals, nesting and readable layouts. A 1,000-level probe produces identical 20,005-character output, reducing measured native CPU time from 0.310 seconds to 0.000542 seconds. Its integration, native/WASM complete-response comparisons and full regressions remain pending. Neither investigation changes a law, candidate domain, completeness claim or intrinsic definition check. The source implementation and broader verification gates remain open.

### Integrated generation performance fixes — 16 October 2026

Python expression emission now indexes bound identities and occupied free names with the existing `containers` Map and Set implementations. The original traversal, first assignment of repeated binder identities, allocator gaps, free-name capture avoidance and generated spelling are preserved. Compact hanging expressions skip line-fit lookahead after optional breaks have already been fixed to spaces; readable layout and mandatory indentation retain their existing behavior. Neither correction changes propositions, candidate domains, evaluation order, verification selection or mandatory definition admission.

The final coherent compiler passes all 1,971 tests with zero failures (438.2 seconds), including both new Python hygiene cases and all 53 layout checks. The renderer also agrees with its preceding implementation on 27,000 standalone document/layout comparisons. A permanent isolated-process WASM regression checks all four Python width/layout combinations with the unchanged arithmetic fixture, its four laws and seven rows, and all 256 Int8 candidates in compact output. Its deadline terminates the child compiler if generation regresses; it does not shrink the source domain or claim that generation verifies the laws.

Complete final native/WASM and preceding-native correspondence passes 410 responses and 92 generations, covering arithmetic on all 17 backends at both widths and layouts, plus Python record predicates, collections, nested records, GADTs, refinements and positional products. All 98 proof-task responses and ready-task fingerprints agree. No source locations, fingerprints, evidence fields or artifacts are removed before comparison. Earlier partial stopped arithmetic controls remain excluded from completed evidence; this final comparison covers their cases and completes generation. The separately completed published-code broad run remains the 1,230-response, 816-generation, 22-migration-report result recorded above.

Sixteen Python native project profiles passed, with 60 mutant rejections. Their generated files are rechecked against the final combined compiler and match exactly. The arithmetic outputs also match the published builds used for the earlier 34 positive native projects and 68 mandatory/native mutant rejections. This is reuse through exact generated-file correspondence, not a claim that all those native builds were rerun after the renderer correction. The final installed npm archive separately passes CLI/API smoke checks, JavaScript and Rust scaffold execution and regeneration, and all 68 structural target/width/layout combinations.

The full final npm catalog passes all 337 tests with zero failures and no skips (2130.7 seconds), using the configured real Z3 executable. Task generation remains distinct from solver execution and trusted solver evidence. All 108 generated files, compiler/artifact integrity, 228-module boundaries, six editor tests, version consistency and documentation checks for 119 pages/114 compiled snippets pass. The final WASM artifact is 69,992,470 bytes, SHA-256 `613280ad875b617f90fa8611fb0283a806d0bebfafa1bda0607ac0bb213b0b0c`. Chapter 6 remains byte-identical at SHA-256 `07d8116b847aa80e044ad3ea2cbc8317bc949a0c4fe07b560e513d6fa0bfaf06`.

In the complete-response comparison, one 32-bit compact Python arithmetic request falls from 8.9 to 2.3 seconds, and the corresponding JavaScript request from 117.6 to 1.3 seconds. These are measured fixture results, not universal performance guarantees. Evidence is under `.artifacts/minor-python-binding-index/` in its worktree. This finishes the two performance corrections in the current iteration; it does not establish overall authoring-milestone acceptance. The migration writer remains unvalidated, the schema-5-only normal-interface gate remains open, human readability results remain deferred, and the larger pre-final-1.0 programme remains required. Remaining named block endings stay in the immediately following minor milestone. Version 0.24.0 and the technical profile remain unchanged; no RC designation or tag is claimed.

### Source profiles and checked Core migration correspondence — 16 October 2026

Migration capture no longer changes compiler-provided dependency templates to the calling project's profile. Parsing and import resolution already identify the versioned sources' own profiles; expansion, its memo key and each captured input-population policy now use the same decision. This removes the blanket prelude blocker even for a monomorphic project with no laws, while retaining every dependency template and its unsupported generic-domain evidence. A canonical caller applying a versioned prelude law still has universal semantics, including an empty concrete input type. Authored generic, parameter-dependent, empty and incomplete changed domains remain explicit limits; no uniform inhabitant is assumed.

The host now composes existing correspondence facts. The policy-erased body digest covers the complete checked Core, including contracts, nominal metadata, models and harnesses. Matching that digest and independently establishing input-domain correspondence can establish concrete Core correspondence. For changed payload representations, the compiler's validated comparison copy must be anchored to the actual original and destination programs, machine width and snapshot version. Its definition, body and complete-program fingerprint-pair claims must agree with the nested snapshots before its body facts are used. Missing or inconsistent claims cannot promote changed bodies. The report retains raw definition/type differences and labels the transport basis explicitly. Domain facts alone cannot establish a changed body, and a Core match does not establish law truth, source-template equivalence, native bindings or generated behavior.

This uses the existing typed projection, checked payload transport, mandatory validator, input-domain evaluator and SHA-256 snapshots. The separation of typed transformations, tasks and prover calls is illustrated by the primary [Why3 API documentation](https://why3.org/doc/api.html#operations-on-terms-and-formulas-transformations); the trust boundary here remains the existing compiler-owned transformations and fingerprint scheme. Solver evidence continues through the separately recorded Z3 host. No kernel-checked certificate is claimed for migration correspondence.

The read-only report now lists blockers from incomplete components. Completed Core or population-policy stages are not listed as pending; source-template domain changes still appear even when an unused reusable law has no concrete property. Native bindings, generated behavior and the unimplemented project writer remain explicit blockers. Chapter 6 now establishes transported concrete Core correspondence and all 23 concrete input domains at both widths, retaining its raw shape differences and separate source-template limitation. Its report remains `validated: false`, with no files written.

The native source-template suite passes all 28 tests (1.4 seconds). The complete compiler run has 1,974 examples, zero failures and 16 initially pending solver checks because its invocation omitted the configured solver path. A subsequent real-Z3 run passes all 22 SMT tests with zero failures or pending tests (17.2 seconds), completing those 16 checks on the unchanged compiled sources. The final selected migration/proof-host catalog passes all 102 tests with zero failures or skips (223.6 seconds), including real Z3 and TypeScript consumers. Five focused comparison tests, 16 coordinator tests and the three new WASM profile regressions also pass. Earlier selected-consumer attempts expecting the superseded blanket prelude or raw-Core blocker are excluded; the corrected checks retain and strengthen false-body, changed-predicate, empty/incomplete-domain and stale/malformed-certificate rejection.

Complete native/WASM comparison passes 234 responses and 204 generations across all 17 targets, both widths and layouts, including canonical prelude providers and empty-domain applications. Another 228 complete ordinary responses match `b57b9810` exactly. Eight complete final-host migration reports agree across native and WASM, including Chapter 6 at both widths. No response fields or fingerprints are omitted. The source-template snapshot policy changes are intentional and compared in full across runtimes. There is no new full npm-catalog or native execution-matrix claim for this correction; the prior 337-test and native-conformance baselines remain recorded separately, with ordinary generated output correspondence checked here.

All 109 generated files, compiler/artifact integrity, 228-module boundaries and version consistency pass. Documentation checks retain 119 pages and 114 compiled snippets. The rebuilt WASM artifact is 69,993,815 bytes, SHA-256 `c44944a8ff76b7d7fe64759d10329a8bcb71afc789211190365400e499f304b1`; both unsigned pointer conversions are checked. Chapter 6 remains byte-identical at SHA-256 `07d8116b847aa80e044ad3ea2cbc8317bc949a0c4fe07b560e513d6fa0bfaf06`. Evidence is under `.artifacts/minor-migration-project/` in its worktree. This advances the migration engine; validated writing, changed-payload source-template transport, native binding and generated-behavior correspondence, normal-interface schema rejection and all other authoring, deferred-readability and pre-final-1.0 gates remain open. Named endings for every remaining block stay in the immediately following minor milestone. No version bump, release-candidate designation or tag is claimed.

### Symbolic checked definition migration — 16 October 2026

The migration comparison now lowers the complete pre-specialization definition plane through the ordinary frontend, including unused generic bodies and their transitive dependencies. Generic type variables remain symbolic; no chosen type, sampled input or arbitrary implementation stands in for a scheme. The compiler-owned payload plan transports a comparison copy, which still passes independent Core and mandatory definition-contract validation. Known bodies are never omitted or replaced by opaque declarations to obtain correspondence. Original programs and captured source templates remain unchanged.

Source interfaces, capability requirements and source/template identities have a separate fingerprint because executable Core does not store every source requirement. Both actual source-unit definitions and the audited template catalogue contribute, with duplicate or inconsistent definition identities rejected. Only the duplicate body field is replaced in this nonexecuting interface view; complete typed bodies and contracts remain covered by the independently validated Core comparison. All four complete source-template digests, snapshot version and machine width anchor the result. The host checks the matching interface pair and every complete Core fingerprint pair before using it, and upgrades only the definition-template component. Declaration metadata, reusable laws and their population policies, native bindings and generated behavior remain separate gates.

This extends the existing typed Core and payload transport rather than introducing another evaluator or proof engine. The primary [Why3 API tutorial](https://why3.org/doc/api.html#building-terms) provides the precedent for retaining typed symbolic terms and keeping transformation, task generation and external proof execution distinct. LawSpec's trust boundary remains its existing elaborator, validator, certified comparison transformations and fingerprints; no kernel-checked migration proof is claimed. Generic equality or numeric schemes that this Core path cannot represent return explicit comparison limits while retaining ordinary source admission. An initial probe also confirmed that a case and a direct projection can have different normalized Core shapes. This remains an explicit unestablished-comparison regression, not a refutation of their equivalence; the intended case and projection migrations are tested separately.

The final full compiler regression passes **1,979 tests with zero failures and no pending checks** (374.0 seconds), with the real Z3 executable configured. The final selected migration/proof consumer suite passes **108 tests with zero failures or skips** (242.2 seconds). It covers symbolic generic payloads at both widths, unused-body and transitive-helper mutants, changed capability requirements, unsupported equality, ordinary mandatory rejection, and stale, malformed, incomplete or cross-width evidence. Twelve complete symbolic migration responses agree between native and WASM. The broader comparison passes 234 complete native/WASM responses, including 204 generations on all 17 targets at both widths and layouts; 228 complete ordinary responses also match `c1735445` exactly. Eight complete migration reports agree across native and WASM, including Chapter 6 at both widths. No response fields are omitted. There is no new full npm-catalog or native execution-matrix claim; their preceding completed baselines remain recorded above, with ordinary generated output correspondence checked here.

All 110 generated files, source/artifact integrity, 228-module boundaries, six editor tests and version consistency pass. Documentation checks retain 119 pages and 114 compiled snippets. The final WASM artifact is 70,100,585 bytes, SHA-256 `abdd1bcc2bc07724988a9383ce8833819d4f1548387ba68c649bae24024b8923`; both unsigned pointer conversions are checked. Chapter 6 retains its recorded bytes and inventory. Evidence is under `.artifacts/minor-migration-template-transport/` in its worktree. Initial runs with an unsupported KeyMap helper or missing isolated-worktree editor dependencies are excluded; both were corrected before the completed checks above.

This closes symbolic definition-template comparison for the represented schemes. Complete source-unit and reusable-law transport, the validated project writer, native-binding and generated-behavior correspondence, the normal-interface schema boundary, remaining authoring/demonstration gates, deferred human readability evidence and all larger pre-final-1.0 requirements remain open. No overall acceptance is claimed. Version 0.24.0 and the technical profile remain unchanged; complete named block endings stay in the immediately following minor milestone. No RC designation or tag is created.

### Symbolic law and source-unit correspondence; typed field migration — 16 October 2026

This continuation supersedes the preceding checkpoint's unsupported generic-equality result and open source-unit/law comparison. Capability evidence is lexical typing information: an admitted `Eq` scheme permits equality operations, `Keyed` also permits equality, and neither supplies a generator or an equality-reflexivity axiom. Ordinary executable Core starts with no assumptions. Independent mandatory validation audits every definition and contract under its own scope, checks called schemes' requirements, and includes scope maps in audit-cache identities. Evidence cannot leak into another definition or a later strict check.

Complete source comparison reuses ordinary scheme instantiation at fresh rigid carriers. Every generic definition has an independently checked root, including unused bodies, explicit contracts, effects and policies. Actual calls produce instances through the same instantiator; no sample type or replacement implementation stands in for a known definition. Reusable laws keep fresh abstract parameter declarations and separate, rigid type variables. Their bodies, nested logical scopes, restrictions, examples and execution metadata pass ordinary elaboration and Core validation. Abstract parameter declarations are comparison inputs, not implementations or population witnesses. Ordinary executable specialization continues to reject these symbolic carriers.

Compiler-owned certificates retain all four source-template anchors. Complete definition and law terms are covered by validated Core transport; the source-unit metadata comparison retains the other declarations, effects, harnesses, models, documentary data and policies. Duplicate term fields are removed only from comparison copies whose corresponding compiler-owned certificates are checked. Input-domain evidence is computed independently on the transported typed programs. Incomplete or unsupported domains remain unresolved; matching source obligations never establishes their truth or native implementation conformance.

The migration baseline now reports source field occurrences from the existing checked typed expressions and exact parser suffix spans. These facts cover unused generic definitions as well as authored laws and map each access/update to its resolved constructor and original field position. The source planner rewrites single payload labels to `value`, inserts the grouped record path, and uses an accessible checked constructor when rebuilding an updated grouped payload. Consecutive updates and nested imported payloads preserve replacement-before-base evaluation and evaluate the base once. Missing or inconsistent occurrence coverage blocks the preview rather than guessing a field's type from its spelling. Source comments and retained source segments stay attached to the original document.

The comparison normalizer now recognizes total single-constructor projection patterns, unary constructor projections, and exact ordered structural-storage view round trips. It retains selected evaluation, sibling-field evaluation, effectful initializers and dependent binder uses. Projection movement cannot export a branch-local dependent type. These are narrow compiler-owned simplifications of already admitted Core, not arbitrary algebraic equivalence. The precedent is Why3's [documented computation transformations](https://why3.org/doc/technical.html#compute-in-goal), which include pattern matching and record-field reduction; LawSpec uses its own existing Core traversal and validator rather than claiming an integrated Why3 backend or a kernel-checked certificate. [Why3's API](https://why3.org/doc/api.html) also supplies the separation between typed task preparation and prover execution. The distinction between equality support and additional equality laws follows [Lean's Boolean equality classes](https://lean-lang.org/doc/reference/latest/Type-Classes/Basic-Classes/); no IEEE reflexivity assumption is added.

The focused native field campaign passes all three end-to-end tests, including both machine widths, unused generic projections, repeated updates, nested imports and an independently checked changed-field mutant. The normalizer's 18-test native suite also passes, including unary effect retention, refusal to discard sibling evaluation and refusal to treat a non-product case as a product. The final frozen compiler run passes **1,993 tests with zero failures and no pending checks** (381.2 seconds), with the real Z3 executable configured. The selected migration/proof consumer suite passes **116 tests with zero failures or skips** (339.7 seconds). The final published TypeScript consumer separately passes both tests, exercising the new source-field and symbolic-certificate declarations against actual WASM responses in addition to the existing exhaustive expression visitor.

Complete native/WASM comparison passes 234 ordinary/snapshot responses and 204 generations on all 17 targets at both widths and layouts. Another 228 complete ordinary responses match `2bd5f2c1` exactly. Twelve complete symbolic-definition comparisons agree across runtimes. Eight complete migration reports agree, including Chapter 6 at both widths; its source declarations, definition templates, reusable-law bodies and input-domain policies now match. A further field campaign compares 16 complete baseline/canonical responses and eight complete reports across both widths, covering unused generic updates, imported nested payloads, nominal field preservation, Unicode and tab positions. No response fields are omitted. There is no new full npm-catalog or native target-execution claim; the preceding completed baselines remain recorded separately, with generated-output correspondence checked here.

All 111 generated files, source/artifact integrity, 229-module boundaries, version consistency and six editor tests pass. Documentation checks retain 119 pages and 114 compiled snippets. The rebuilt WASM artifact is 70,471,089 bytes, SHA-256 `78c17226927dbc70dfdf7488bdc1dfe02084ff148531fe8a4843b729e34084a4`; both unsigned pointer conversions are checked. Chapter 6 remains byte-identical at its recorded SHA-256 and retains its full inventory. The final SDK/declaration and documentation changes leave the verified native and WASM binaries byte-identical. Evidence is under `.artifacts/minor-migration-symbolic-scopes/` in the existing migration-transport worktree.

Native constructor/field/representation bindings, target behavior correspondence and validated project-wide writing remain open. The normal-interface schema boundary and all remaining authoring, demonstration and final-release gates remain required. The human readability exercise remains deferred by the user. Version 0.24.0 and the technical profile are unchanged; all-named block endings remain the immediately following minor milestone. No RC designation, tag or overall acceptance is claimed.

### Checked native binding proposals — 16 October 2026

The migration report now checks the actual native request for every configured target instead of merely echoing the configuration. Its source baseline is compiled independently; binding-specific requests use the explicit schema-5 `migrationBindings` method, with `from: 0.24`, canonical destination sources and no selected law layers. Mandatory source and definition validation still runs on both programs. Direct API-supplied bindings no longer accidentally enter the binding-blind schema-3 baseline. They are checked as separate input requests and cannot overwrite target settings or become implicit project defaults. Invalid target bindings remain target-specific diagnostics and prevent project-wide binding correspondence.

The compiler reuses the existing payload plan and native resolver to produce concrete destination requests. A single alternative payload changes its logical field label to `value` while preserving the application's native field, constructor, type and function references. Named-record mappings retain their fields. Normalization follows the resolver's declaration order; arbitrary configuration entry order cannot change native positional arguments. Metadata serialization retains type mappings, codec pairs, generator factories and stub choices, functions/methods/constructors, public-name overrides, Rust crate, Go imports, ordered Erlang headers, handlers, failures and network paths. The public TypeScript request/result types cover these fields.

Each proposal anchors the actual input binding object, machine width, requested target, complete Core program fingerprints and all four source-template digests on each side. It records original and proposed configuration fingerprints, validation status and ordinary binding evidence. The host recomputes the proposed-object digest with Node's SHA-256 implementation and checks anchors and evidence classifications before accepting correspondence. Compiler-native request equality is configuration evidence; it is not native execution or law verification. The shared public obligation presenter retains runtime-enforcement and assumed statuses, including the assumptions for codecs, factories and native functions.

The precedent is SPARK's [explicit treatment of imported subprogram contracts](https://docs.adacore.com/spark2014-docs/html/ug/en/source/how_to_write_subprogram_contracts.html#writing-contracts-on-imported-subprograms): caller/interface checks do not verify imported bodies. This increment reuses LawSpec's current resolver, mandatory validator and evidence model. It adds no alternative execution engine, solver or unchecked function category. Native conformance and target generation remain explicitly unestablished.

Grouped payloads remain an identified implementation requirement. Their proposal records every original native field, its original constructor argument index and its destination payload path. It cannot silently replace several native arguments with one record. Codecs receiving changed logical data and factories over changed generated types need independent correspondence; their destination configuration can pass validation while overall correspondence remains unknown. Neither condition is a refutation of the external implementation. Accepted single-field proposals appear explicitly in the proposed target configuration; unsupported targets retain their original configuration. Read-only CLI previews leave the sources, configuration and application roots untouched, and writing stays disabled while project-wide gates remain unresolved.

The final compiler regression passes **1,996 tests with zero failures and no pending checks** (380.2 seconds), with the real Z3 executable configured. The broad migration/proof/native-binding/TypeScript consumer run passes **146 tests with zero failures or skips** (357.3 seconds). A subsequent host-only input-scope correction keeps one-off API bindings separate from actual target configurations, including explicit null/empty bindings; all **13 final focused tests** pass (16.5 seconds), including the TypeScript consumer and read-only CLI. The compiler and WASM binaries remain byte-identical after that host correction. The broad 146-test run predates this final host-only correction; it is not presented as a new 147-test full run.

Complete native/WASM parity passes 234 ordinary/snapshot responses and 204 generations across all 17 targets, both widths and layouts. Another 228 complete ordinary responses match `10bed215` exactly. Twelve complete symbolic-definition responses, eight complete source-migration reports including Chapter 6 at both widths, and 16 field-baseline/canonical responses plus eight field reports also agree. The final binding campaign compares 40 complete responses, covering every target at both widths, Unicode field names and accepted-but-unresolved codec/factory configurations; six complete bound-project reports also agree, including one-off API scope isolation. No response fields are omitted. This is portable binding-plan and generated-output correspondence, not a new full npm-catalog or native execution-matrix claim.

All 113 generated files, source/artifact integrity, 229-module boundaries, six editor tests and version consistency pass. Documentation checks retain 119 pages and 114 compiled snippets. The rebuilt WASM artifact is 70,700,094 bytes, SHA-256 `d9006f30690658d80c78f5647c49157ff7c9b2fe0bb1385e850e03f4b0a5910d`; both unsigned pointer conversions are checked. Chapter 6 remains byte-identical at the recorded SHA-256 and retains its full inventory. Evidence is under `.artifacts/minor-migration-native-bindings/` in the migration-transport worktree. General grouped native layouts, opaque conversion correspondence, generated/native behavior validation and the validated project writer remain open, alongside the previously recorded interface, authoring, demonstration and final-release gates. The user-deferred readability exercise remains deferred. Version 0.24.0 and the technical profile are unchanged. The immediately following minor milestone still owns all-named block endings. No release-candidate designation or tag is created.

### Checked structural native layouts — 16 October 2026

Grouped constructor bindings now carry explicit `field`, structural `path` and native `argument` positions. The existing resolver checks full coverage, native-name uniqueness, nonoverlapping paths and contiguous argument indices independently of configuration array order. Paths may open anonymous records only; nominal children retain their typed conversions. Structural type parameters are substituted before leaf conversion. Indexed and existential constructor layouts remain explicitly unsupported. Flat bindings retain their existing declaration-order normalization and wire representation.

The migration proposal derives grouped layouts from the admitted original constructor order and the checked payload plan. They preserve native constructor references and native field names while identifying the new record paths. Configuration proposals can now match for grouped payloads across all 17 target names and both widths. This is configuration correspondence: target generation, external native conformance and law truth remain separate evidence, and the project writer stays disabled.

Python, JavaScript and TypeScript generated bridges now execute these layouts. They convert each native leaf in explicit argument order, pack or unpack the anonymous records and use ordinary recursive schema validation for both the records and their enclosing constructor. Scalar bounds, nested refinements and generic field types remain enforced. No additional evaluator, proof engine or unchecked definition category is introduced; external functions and custom hooks retain their existing assumptions. JavaScript native-schema copies also retain constructor refinement and witness metadata. Other target emitters reject nested layouts explicitly, including their existing broader type-binding limitations. Completing those emitters remains part of the all-target migration requirement; this checkpoint does not reduce that scope.

The complete native compiler regression passes **1,997 tests with zero failures and no pending checks** (373.9 seconds), with the real Z3 executable configured. The broad migration/proof/native-binding/TypeScript suite passes **152 tests with zero failures or skips** (354.8 seconds). Independent native binding checks also pass 68 tests. A final test-only tool lookup adjustment uses the established Python executable override and reports unavailable Python/TypeScript environments as skipped tests; all 18 final focused checks pass with both tools configured, without skips (16.6 seconds). The compiler and WASM binaries remain unchanged after that adjustment. Generated nested generic bridges execute on all three implemented targets, at both machine widths and both layouts, with explicit expected field values, native access order and rejected invalid values. Installed payment examples for Python, JavaScript and TypeScript pass their ordinary native tests, detect the wrong-fee mutant, retain incremental law selection and preserve application files during regeneration. This is three installed target runs at 64 bits in readable mode; it is not a new full native execution matrix.

Complete native/WASM parity passes **174 responses**, including **80 accepted generations**, plus both complete grouped-project reports. Ordinary requests cover every target, both widths and both layouts; 72 complete preceding-compiler responses agree after replacing only the intended schema implementation contents in generated artifacts. All other response fields and artifact metadata match. Grouped proposals cover all 17 target names and both widths; implemented emitters generate both layouts while unfinished emitters report diagnostics. These checks do not promote native execution or project migration evidence.

All 114 generated files, source/artifact integrity, 229-module boundaries and version consistency pass. Documentation retains 119 pages and 114 compiled snippets. The WASM artifact is 70,757,566 bytes, SHA-256 `85886a1ef5ffb8f2e6dcc11c346d950dfee4fe670f9cda68707f4a77aca755f1`; both unsigned pointer conversions are retained. Chapter 6 remains byte-identical at the recorded SHA-256. Evidence is under `.artifacts/minor-native-record-layouts/` in the migration-transport worktree. Remaining native emitters, opaque conversion correspondence, complete generated/native behavior, validated writing, interface strictness and the other authoring, demonstration and pre-final-1.0 gates remain open. Readability evidence remains deferred by the user. Version 0.24.0 and the technical profile are unchanged; all-named block endings remain the immediately following minor milestone. No release-candidate designation or tag is created.

### Shared JVM and Rust native packing — 16 October 2026

Native layout resolution now retains one checked packing tree alongside the existing explicit field paths. Its leaves contain instantiated Core binders and native argument indices; each interior record retains its actual Core constructor identity and applied field type. JVM and Rust emitters derive numerical projections and target construction from that same tree. Nominal fields stay leaves, complete coverage and nonoverlap remain mandatory, and indexed/existential layouts remain explicit unsupported cases. This metadata belongs to the existing checked binding plan; it is not a separate logical representation or evaluator.

Java, Kotlin, Scala and Groovy's Java bridge now execute grouped layouts through their existing codecs. They decode native leaves into locals in native argument order, then construct canonical records through the ordinary schema. Reverse conversion projects through the same tree and invokes the existing leaf codecs. Generic fields, scalar bounds, nested predicates, native getter order and invalid native results are exercised in compiled application fixtures. Groovy's fixture exercises its generated Java bridge with an application-owned Java type; it does not claim a separate Groovy representation mechanism.

Rust builds typed record moves and constructions from that tree. Canonical record boxing and the native constructor's boxing are calculated separately, so introducing a structural record does not silently remove a recursive native Box or add one to the native API. Leaf conversions run in explicit native argument order. Direct adapter arguments and results reaching nested layout types now pass the existing schema validator at the selected machine width, with contextual failures; this includes transitive occurrences. Independent Rust execution checks reject an invalid input before the native implementation is called and reject an invalid native result. Recursive chain conversion retains both its branch and its native recursive Box. External native bodies remain assumed, and matching a configuration still establishes neither native conformance nor law truth.

The target CI plan includes a native layout stage after each applicable toolchain bootstrap. An explicitly selected target must execute its fixture; it cannot turn a missing required tool into a skipped result. The ordinary core-only npm run can report unavailable toolchains and an unprepared Rust acceptance environment honestly. Configured verification uses `LAWSPEC_NATIVE_LAYOUT_TARGET=all`. The exact Rust target-stage command has also passed one selected test with no skipped checks, confirming that its name filter actually selects and executes the fixture.

Complete native/WASM parity passes 240 full responses, including 168 accepted generations, plus two complete grouped-project reports. All 17 targets, both machine widths and both layouts are covered. The 172 exact preceding-compiler comparisons include 136 ordinary generation responses, existing native-bound payment configurations for every target and 34 grouped binding proposals; no fields or generated implementation contents are omitted or normalized. New grouped generation is accepted for Python, JavaScript, TypeScript, Java, Kotlin, Scala, Groovy and Rust, while remaining emitters retain explicit diagnostics. Configuration-only correspondence remains distinct from generated behavior and native execution.

The complete compiler regression passes **1998 tests with zero failures and no pending checks** (388.5 seconds), with the real Z3 executable configured. The broad migration/proof/API/native-binding run passes **157 tests with zero failures or skips** (366.3 seconds), with all native layout target fixtures explicitly required. An earlier focused native binding run passes 69 tests. Twenty new compiled fixture executions cover Java, Kotlin, Scala, Groovy's Java bridge and Rust at both widths and both layouts; the existing dynamic bridge fixtures are also rerun in the broad suite. These results cover the described layouts and boundary cases, not the full all-target native release matrix.

All 115 generated files, source/artifact integrity, 229-module boundaries, version consistency and documentation checks pass. Documentation retains 119 pages and 114 compiled snippets. The rebuilt WASM is 70,928,121 bytes, SHA-256 `da43a435057dc637cff7f7ab2e694a1b69429f5a3fbbc84a026d67f6f9d91106`; both unsigned pointer conversions are checked. Chapter 6 remains byte-identical at its recorded SHA-256. Evidence is under `.artifacts/minor-static-native-layouts/` in the migration-transport worktree. Go, Haskell, BEAM, .NET and Swift layout emission, opaque conversion correspondence, complete generated/native behavior, the validated project writer and the previously recorded interface, authoring, demonstration and pre-final-1.0 gates remain open. Clojure and C# retain their existing broader type-binding limits. The user-deferred readability exercise remains deferred. Version 0.24.0 and the technical profile are unchanged. Complete named block endings remain the immediately following minor milestone. No release-candidate designation, milestone acceptance or tag is claimed.

### Go and Haskell packing with recursive canonical fields — 16 October 2026

Go and Haskell now emit the checked structural native layouts, bringing implementation coverage to ten targets. Go uses ordered native-leaf locals, the shared packing tree, numerical projection paths and its existing schema construction and validation. Haskell keeps the existing codec entry points as compatible wrappers and adds a layout-aware entry for admitted binding plans. It constructs and destructures the actual structural constructor identities; ordinary `codecWith` validation remains before decoding and after encoding. Neither path adds a type checker, evaluator, unchecked function category or independent proof mechanism. Indexed and existential native layouts remain explicitly unsupported.

The recursive fixtures exposed a concrete representation error in Go and the JVM bridges: an unmapped generated record's concrete nominal field was assigned a mapped native child. A Java compilation probe independently reproduces the mismatch, and the corrected probe compiles. Go, Java, Kotlin, Scala and Groovy's Java bridge now keep those concrete canonical fields in the canonical representation; generic parameters retain their supplied directional codecs. Haskell already applied the canonical rule to unmapped concrete fields. Delegation is confined to requests with native type mappings, preserving the previous generated implementation for function-only requests, including Clojure. This does not unwrap nominal values or change a native body on the user's behalf.

Native fixtures cover nested generic products, deliberately different native field orders, recursive chains, round trips, invalid input and invalid native output. Go observes that an invalid input never reaches the native implementation. Haskell uses a distinguishable native failure to check that input validation happens first, without requiring equality or display capabilities on its native packet type. JVM fixtures now exercise the recursive chain as well as the generic packet. Existing Rust recursive-box and checked-boundary coverage remains selected. The Go and Haskell target CI stages run the same fixtures after their toolchain bootstrap, and both exact selected-stage commands pass one test with no skips. Haskell compilation reads the prepared snapshot package database, including the existing runtime's network dependency.

Complete native/WASM parity passes 240 full responses, including 176 accepted generations, plus two complete grouped-project reports. All 17 targets, both machine widths and both layouts are covered. Another 172 complete responses agree with `b029d03f` without normalizing or omitting any fields: 136 ordinary generations, including native-bound payments for every target, 34 grouped binding proposals and two ordinary checks. The separate compatibility preflight also compares all 68 bound-payment generation responses. New grouped generation is accepted for Python, JavaScript, TypeScript, Java, Kotlin, Scala, Groovy, Rust, Go and Haskell. Other emitters retain explicit diagnostics. These comparisons keep configuration correspondence, generated behavior, native execution and law verification distinct.

The final complete compiler regression passes **1998 tests with zero failures and no pending checks** (389.0 seconds), with the real Z3 executable configured. The final broad migration/proof/API/native-binding run passes **159 tests with zero failures or skips** (368.7 seconds), with all native layout fixtures explicitly required. Its seven static target fixtures execute 28 compiled width/layout combinations; the earlier dynamic bridge fixtures are also selected. These are final-build results, distinct from preliminary runs interrupted for the compatibility correction. They do not establish the full all-target native release matrix.

All 115 generated files, source/artifact integrity, 229-module boundaries, version consistency and documentation checks pass. Documentation retains 119 pages and 114 compiled snippets. The shipped WASM is 71,013,093 bytes, SHA-256 `e9eb9a16729007811906b618e55277993696003b0c8a2a3bcb0ef85e89e178aa`; both unsigned pointer conversions remain checked. Chapter 6 remains byte-identical at its recorded SHA-256. Evidence is under `.artifacts/minor-go-haskell-native-layouts/` in the migration-transport worktree. BEAM, .NET and Swift layout emission, opaque conversion correspondence, complete generated/native behavior, the validated project writer and the previously recorded interface, authoring, demonstration and pre-final-1.0 gates remain open. Clojure and C# retain their existing broader type-binding limits. Readability evidence remains deferred by the user. Version 0.24.0 and the technical profile are unchanged. Complete named block endings remain the immediately following minor milestone. No release-candidate designation, milestone acceptance or tag is claimed.

### F# and Swift packing with checked native boundaries — 16 October 2026

F# and Swift now emit the checked structural native layouts, bringing implementation coverage to twelve targets. F# folds the resolver's packing tree into nested portable patterns and values. Swift derives guarded projections from that tree, checking each structural constructor tag and field count before indexing, and uses the shared fold to pack values. Leaf conversions execute in explicit native argument order. Both emitters retain native aliases in their shared data families; generic native aliases now apply their type parameters, and Swift bound codecs receive the corresponding generic child codecs. No structural type resolver, evaluator or proof mechanism was added.

The entry emitters use the existing schema validator before native calls when an input type reaches an admitted layout, following type arguments and the checked declaration graph with cycle protection. Existing adapter result validation remains. Older entry-emission functions remain compatible wrappers, and no-layout generation preserves preceding responses. Mandatory definition checking and runtime enforcement remain independent of optional law verification. Indexed and existential native layouts remain explicitly unsupported.

Native fixtures compile and execute generic variants, generic native records, nested products with deliberately different native field order, recursive chains and round trips. Invalid nested-refinement inputs encounter schema rejection before a distinguishable native failure can run; invalid native results are also rejected. F# native types explicitly disable equality and comparison, and Swift native types supply no equality implementation. Conversion imposes no extra native equality or display requirement. All four machine-width/layout combinations pass for each new target. The F# and Swift target CI stages select these fixtures after their toolchain bootstrap. The public native-binding reference and symbol guide now document these targets and their boundary behavior.

The final compiler run passes all **1,998 tests with zero failures**, using the real Z3 executable, in 383.3128 seconds. The final migration, API, native-binding and solver regression run passes **161 tests with zero failures or skips** in 381,938.417292 milliseconds. It includes all nine compiled static-target fixtures, each exercising 32/64-bit and readable/compact profiles. The separate selected F# and Swift native-compiler runs also pass. This evidence distinguishes schema rejection, native execution and optional law verification; it is not a claim that configuration matching verifies a native implementation.

Complete native/WASM parity passes **240 full responses**, including **184 accepted generations**, plus two complete grouped-project reports. All 17 targets, both machine widths and both layouts are covered. Another **172 complete responses** agree with `07861a4b` without normalizing or omitting fields: 136 ordinary generations, including native-bound payments for every target, 34 grouped binding proposals and two ordinary checks. The separate compatibility preflight compares all 68 bound-payment responses. New grouped generation is accepted on Python, JavaScript, TypeScript, Java, Kotlin, Scala, Groovy, Rust, Go, Haskell, F# and Swift; unfinished emitters keep explicit diagnostics.

All 115 generated files, source/artifact integrity, 229-module boundaries, version consistency and documentation checks pass. Documentation retains 119 pages and 114 compiled snippets. The shipped WASM is 71,094,843 bytes, SHA-256 `d3b92c950ebc8f03f60b428ea6332f46ea0ad771b019a7dddaf2f3cf8474bd21`; both unsigned pointer conversions remain checked. Chapter 6 remains byte-identical at SHA-256 `07d8116b847aa80e044ad3ea2cbc8317bc949a0c4fe07b560e513d6fa0bfaf06`. Evidence is under `.artifacts/minor-dotnet-swift-native-layouts/` in the migration-transport worktree.

BEAM's three layout emitters, opaque conversion correspondence, complete generated/native behavior and the validated project writer remain open; C# and Clojure retain their broader native-type-binding limits. The previously recorded interface, authoring, demonstration and pre-final-1.0 gates remain required. Matching configurations and generated plans do not establish native conformance, and migration still reports `validated: false` with writing disabled. Readability evidence remains deferred by the user. Complete named block endings remain the immediately following minor milestone. Version 0.24.0 and the technical profile are unchanged. No release-candidate designation, milestone acceptance or tag is claimed.

### BEAM native packing across Erlang, Elixir and Gleam — 16 October 2026

Erlang, Elixir and Gleam now emit nested native layouts, bringing support to fifteen targets. The emitter serializes the resolver's packing tree and scoped leaf types into the existing shared schema. Generic instantiation substitutes leaf types; conversion runs leaves in native argument order and packs records in canonical order. Existing logical validation surrounds encoding and decoding. Erlang records use their supplied headers, Elixir uses structs, and Gleam retains compiler-derived constructor positions, including deliberately reordered fields. No emitter reconstructs structural types, and no evaluator, solver or proof mechanism was added. Layout metadata is audited for scope, tags, arities and complete argument positions; malformed non-map shapes retain the existing diagnostic.

Native fixtures cover generic variants, native records, recursive chains, round trips, wrong constructors and scalar ranges, invalid input rejected before a distinguishable native failure, and invalid native results. Every new target passes all four width/layout profiles. Shared runtime tests additionally cover nested generic substitution, observable conversion order, malformed layouts and opaque child-codec crossings. The full BEAM runtime conformance script passes **532 tests**, including the new schema cases and its independent vectors/interoperability checks. Its vector generation uses the fixed built development executable rather than rebuilding a compiler during regression runs.

The final compiler suite passes **1,998 tests with zero failures** in 388.1165 seconds using the real Z3 executable. The final migration/API/native/solver regression run passes **164 tests with zero failures or skips** in 394,436.831334 milliseconds, including all twelve static native-layout fixtures. Native/WASM parity agrees on **240 complete responses**, including **196 accepted generations**, plus two complete grouped-project reports. All 17 targets, both widths and both layouts are exercised. Against `cbf01001`, 148 responses are identical; 24 BEAM responses differ only in the explicitly updated shared schema runtime file. The comparison checks the complete expected response, verifies the old runtime against the preceding commit and the new runtime against the actual source, and rejects every other difference. The separate 68-response payment preflight likewise has 56 exact matches and twelve runtime-only updates. No fields are discarded or normalized.

All 115 generated files, source/artifact integrity, 229-module boundaries, version consistency and documentation checks pass. Documentation retains 119 pages and 114 compiled snippets. The shipped WASM is 71,103,518 bytes, SHA-256 `2d526d210932cfe353c2629c305c4eed7fc06657e7a74c8dbc9dd611d9b28345`; both unsigned pointer conversions are checked. Chapter 6 retains its recorded bytes and SHA-256. Final evidence is under `.artifacts/minor-beam-native-layouts/`; preliminary logs explicitly distinguish the corrected malformed-shape diagnostic and Elixir test-launcher fix from final results.

C# and Clojure retain their pre-existing native-type-binding restrictions; ordinary source generation and supported function bindings remain covered. Indexed and existential native layouts remain unsupported. Opaque conversion correspondence, complete generated/native behavior correspondence, the validated migration writer and all previously recorded interface, authoring, demonstration and pre-final-1.0 gates remain open. Conversion tests do not discharge laws or establish project-wide migration. Readability remains user-deferred; complete named block endings remain the following minor milestone. Version 0.24.0 and the technical profile are unchanged. No release-candidate designation, milestone acceptance or tag is claimed.

### Checked migration generation and scoped artifact receipts — 16 October 2026

The new schema-5 `migrationGeneration` method runs the existing harness planner and target emitter on both admitted source versions, retaining the destination binding proposal as typed data. Targets, widths, output directories, layouts and generation limits must agree. Ordinary intrinsic definition validation remains mandatory; optional law checks are not executed. The generated legacy harness plans remain plans. Each side independently records acceptance, rejection diagnostics or unavailable adaptation, with complete SHA-256 artifact manifests including ownership, placement and adapter-reference digests. Exact source/dependency digests retain paths and text alongside the existing Core, source-template and binding anchors.

The coordinator now exposes `generationPreview` and `correspondence.targetGeneration`, checks manifests and scope options, and reports zero target configurations as `not-requested`. API-level directories remain scoped to that input and never become configured-target defaults. Incomplete opaque-codec adaptation cannot become accepted destination emission. Native implementation conformance and law verification remain explicitly unestablished by this receipt; migration still returns `validated: false` and writes nothing. This follows the boundaries in [SPARK's proof/test integration guidance](https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/usage_scenarios.html#between-proof-and-unit-testing) and [Lean's checking/compilation pipeline](https://lean-lang.org/doc/reference/latest/Elaboration-and-Compilation/), consulted before implementation. No new solver, evaluator or proof checker was added.

The final compiler suite passes **1,998 tests with zero failures** in 384.2022 seconds using the real Z3 executable. The final migration/API/native/solver regression suite passes **175 tests with zero failures or skips** in 318,886.301417 milliseconds. Eleven new generation regressions cover every target, independent legacy/canonical artifact comparisons, both widths/layouts, grouped bindings on fifteen targets, C#/Clojure's existing restrictions, exact-input and manifest guards, separate side failures, opaque-codec limits and mixed API/configuration scopes. The focused generation/profile run passes fourteen tests. Six editor tests pass. Preliminary logs retain the stale blocker-text assertion and the API-directory scope correction; final logs cover the corrected coordinator.

Native/WASM parity agrees on **318 complete responses**, including **196 accepted ordinary generations** and **68 accepted migration-generation receipts** across every target and both widths/layouts. It also compares four complete reports, including both API/configuration directory scopes. All **172 complete preceding responses** match `a8085d8e` without normalization or omitted fields; the separate 68-response native-payment preflight also matches. All 117 generated files, source/artifact integrity, 230-module boundaries, version consistency and documentation checks pass. Documentation retains 119 pages and 114 compiled snippets. The shipped WASM is 71,177,918 bytes, SHA-256 `9a2f062f7be46c8cf1ba6ad987634e7cf56c9793f0238e718d0a06fb0e996621`; unsigned pointer conversions remain checked. Chapter 6 remains byte-identical. Evidence is under `.artifacts/minor-migration-generation/` in the migration-transport worktree.

Native boundary/behavior correspondence, the validated project writer and all previously recorded authoring, interface, demonstration and pre-final-1.0 gates remain open. Emitter acceptance does not close those gates. Readability remains user-deferred, complete named block endings remain the immediately following minor, and version 0.24.0 and the technical profile are unchanged. No release-candidate designation, milestone acceptance or tag is claimed.

### Resolved native migration interfaces — 16 October 2026

`migrationGeneration.nativeBoundary` now compares compiler-resolved native interfaces independently of emission acceptance. Version 1 of `resolved-native-contract-v1` records native constructor identities, styles, ordered leaf types, codecs, calls and async/effect interfaces, handler operations, and generated data layouts exposed by unbound adapters. Rust's existing boxing helper supplies its native field decisions. Bound parameters normalize by position; nominal identities remain references. Runtime-erased value indices and logical predicates remain the responsibility of the separate complete Core/source-template correspondence gates. No additional evaluator, typechecker or prover is introduced.

Grouping a payload now preserves the original resolver's explicit native argument positions and nested paths, rather than reconstructing argument order from source declaration order. Native exception mappings retain their original first-match order instead of being sorted by native class name. Typed request normalization and its documentary serializer are shared by the existing binding proposal and the new boundary comparison. The coordinator checks the complete generation receipt, contract digests, destination configuration and unchanged assumptions before reporting `correspondence.nativeBoundary`. A changed unbound adapter layout can remain unestablished even when configuration correspondence matches and both emitters accept. Zero configured targets report `not-requested`.

A matched interface is conditional on the existing emitters and unchanged native implementations under their original binding assumptions. It does not prove native bodies, codecs or generators correct, establish law truth, close complete generated/native behavior correspondence, or enable migration writing. This follows [SPARK's imported-subprogram contract boundary](https://docs.adacore.com/spark2014-docs/html/ug/en/source/how_to_write_subprogram_contracts.html#writing-contracts-on-imported-subprograms), consulted before implementation: an external contract assumption is retained until its body is independently verified. Native conformance and law verification remain explicitly unestablished by the receipt.

The compiler suite passes **1,998 tests with zero failures** in 382.1553 seconds using real Z3. The broad migration/API/native/solver run passes **183 tests with zero failures or skips** in 333,615.841917 milliseconds, including all twelve static native-layout fixtures. Two further permanent checks were then added without changing the compiler or runtime: compiled Java migration across both widths/layouts and handler/async/effect interface changes. The final focused suites pass **21 native tests** and **24 WASM tests**, with no failures or skips. Python, JavaScript and Java execute both old and migrated bridges with distinct Boolean/integer fields and explicit native argument positions. The broad 183-test run precedes those final two test additions; no uninterrupted 185-test broad run is claimed.

Native/WASM parity agrees on **402 complete responses**, including ordinary generation, grouped native boundaries, existing explicit native positions, unchanged and changed unbound layouts, changed call types and ordered failures. All 17 targets, both widths and layouts are exercised. All **172 complete preceding responses** match `6611b879` exactly; a separate **68-response** native-payment preflight also matches. Four complete migration reports agree. Six editor tests, all 118 generated outputs, source/artifact integrity, 232-module boundaries, version consistency and documentation checks pass; documentation retains 119 pages and 114 compiled snippets. The shipped WASM is 71,332,060 bytes, SHA-256 `f03b63a5ad9d776c2291039dbad59511f01b064a2a8ad457016fa19458f4757f`. Both unsigned pointer conversions remain checked. Chapter 6 remains byte-identical. Evidence is under `.artifacts/minor-migration-native-boundaries/` in the migration-transport worktree.

Complete generated/native behavior correspondence, validated project-wide writing, the schema-5-only normal public-interface gate, and all other recorded authoring, demonstration and pre-final-1.0 acceptance requirements remain open. Readability remains user-deferred; complete named endings remain the immediately following minor. Version 0.24.0 and the technical profile are unchanged. No release-candidate designation, milestone completion or tag is claimed.

### Validated project writes and published Chapter 6 migration — 16 October 2026

The project coordinator now combines complete checked Core, source templates, domain policies, native binding proposals, emitter receipts and resolved native interfaces. A passing report has `validated: true` and `validation.status: validated-under-existing-assumptions`; configured generated behavior is `matched-under-existing-assumptions`. It retains the compiler's existing validation/transport/emitter trust and original assumptions about unchanged native implementations. Native conformance and law verification remain unestablished by migration. With no configured targets, generation, native boundaries and generated behavior remain explicitly `not-requested`; the coordinator may validate source-only migration without claiming target checks ran. This is modular reasoning under the [SPARK imported-subprogram contract boundary](https://docs.adacore.com/spark2014-docs/html/ug/en/source/how_to_write_subprogram_contracts.html#writing-contracts-on-imported-subprograms), not a new solver, evaluator or proof checker.

`migrate --from 0.24` remains read-only. `--write` obtains fresh evidence and writes only admitted source/configuration replacements, including explicit native-binding changes and prior law-layer selections. It checks the complete source inventory, original bytes, configuration settings, configured target scopes and package inputs; one-off API bindings cannot silently replace persisted bindings. Native application code and existing generated artifacts are preserved. Replacements are staged with their permissions, originals retained for ordinary-error rollback, and configuration committed last. Concurrent edits abort or retain recovery paths rather than being overwritten. Process/OS crashes are not an atomic multi-file filesystem transaction. These limits and recovery behavior are documented. Shared source discovery also exposed a formatter path bug: explicit paths with a configuration in another directory were resolved against that directory for writing. A read-only reproduction confirmed the wrong path; the corrected formatter uses the working directory, and a regression protects an unrelated sibling file.

[The published canonical Chapter 6 specification](examples/chap06/assembler.lawspec) completes its first semantic migration pass. It retains **23 authored laws, 65 table rows, one named example, 25 authored functions, seven ADTs and two refinements**. Compiler-generated field helpers are additional lowered definitions, not authored functions. Formatting is idempotent, and complete Core plus source-template fingerprints match the actual validated migrated copy. The original Chapter 6 bytes remain unchanged. Both native and WASM compilers execute actual project migration, followed by the independent Python oracle suite, in 64-bit readable and 32-bit compact profiles. Each passes all **32,768 A-instruction addresses, 1,792 C-instruction combinations, thirteen stateful programs, independent repeated invocations, 66 generated examples and all six mutants**. These executions establish their recorded finite/Python conformance scope, not unbounded-law proofs or the remaining sixteen native implementations. Further Chapter 6 authoring improvements remain required.

The native migration regression passes **150 tests** and the broad WASM/API/native/solver/files/authoring run passes **268 tests**, with zero failures or skips. Those runs precede the final configuration guards and published-example test; the final focused suites pass **16 native tests** and **21 WASM/files tests**, and the final authoring suite passes **20 tests**, all without failures or skips. No uninterrupted full-catalog run after those additions is claimed. Native/WASM parity agrees on **402 complete responses**, including four complete reports; all **172 selected preceding responses** match `d59637f0` exactly. Compiler sources, the native executable and WASM bytes are unchanged from that checkpoint, whose 1,998-test compiler run remains the baseline rather than a new compiler-test result. Evidence is under `.artifacts/minor-migration-writer/` in the migration-transport worktree.

This enables admitted project writes without declaring all migration or authoring acceptance complete. Indexed/existential payload transport, changed opaque hooks, unestablished generic populations and captured dependency-catalogue changes retain their limits. In particular, the imported ordered-collection fixture still exposes additional canonical library declarations and remains blocked by full Core/source-template checks despite matching its exercised runtime outcomes; those checks were not weakened. The schema-5-only public-interface cutover, remaining migration/authoring demonstrations and full acceptance checks remain required. The larger portfolio, advanced verification and Linguist dependency remain pre-final-1.0. Readability remains user-deferred, and complete named endings remain the immediately following minor. Version 0.24.0 and the technical profile are unchanged. No RC designation, milestone completion or tag is claimed.

### Scoped collection-provider demand — 17 October 2026

A bound parameter named `values` previously triggered discovery of the prelude map operation, adding unused `KeyVal` declarations to canonical source captures and blocking ordered-set migration. Discovery now refines its conservative catalogue using the existing scope-aware import resolver. It preserves authored generic declarations, actual re-exports and documentary targets, shared helpers, bounded arithmetic, ordering and pairs introduced by subsequent elaboration. Fields outside the resolver's dependency traversal retain conservative discovery. Mandatory definition checks still run over the resulting complete program.

The precedent is [Why3's dependency-based removal of unused symbols](https://why3.org/doc/technical.html#cmdoption-arg-remove_unused). LawSpec uses its existing resolver and versioned source-block ownership; proof infrastructure and the compiler trust boundary are unchanged. Complete Core and source-template comparisons remain strict. The ordered-set fixture now validates and writes with all 17 target configurations. That regression also exposed a Haskell emitter lookup of map `Entry` while matching a set; it now requests that constructor only for maps.

The final native compiler regression passes **2,003 tests**, native migration passes **155 tests**, and the WASM migration/API/authoring suite passes **177 tests**, all with zero failures or skips. Native/WASM parity agrees on **682 complete API responses plus six complete project reports**, covering all 17 targets, both widths and both layouts; **172 selected preceding responses** match `98c5cf79` exactly. Generated files (120), module boundaries (232), documentation (119 pages and 114 snippets), editor tests (six), version and artifact integrity checks pass. Evidence is under `.artifacts/minor-collection-provider-demand/` in the migration-transport worktree. These are compiler, emission and migration checks; they do not establish a new native implementation conformance matrix.

The ordered-collection blocker described in the preceding checkpoint is resolved. Remaining migration limits, public-interface cutover, Chapter 6 authoring and final acceptance remain on the checklist above. The original Chapter 6 bytes, version 0.24.0 and technical language profile are preserved. No milestone completion, RC designation or tag is claimed.

### Explicit migration baseline and artifact inspection — 17 October 2026

The migration coordinator now obtains its legacy declarations, selected-law evidence, source inventory and semantic snapshots in one schema-5 `migrationBaseline` request with `from: '0.24'`. It retains the prior law-layer selections and no longer calls ordinary legacy `check`. A regression rejects any ordinary legacy request from the coordinator and compares its snapshot with an independently requested baseline without selected law checks. Mandatory definition admission remains independent of those selections. Baseline evidence uses the explicit-selection statuses, preserving the distinction between planned checks and completed evidence.

`migrationBaseline` optionally accepts `includeGeneration: true` and a target for read-only inspection of the original artifacts. It uses the existing emitters and legacy harness plan, including the matching test manifest. `baselineGeneration` explicitly reports generation with execution `not-run`, unestablished native conformance and no law verification established by generation. Other methods reject this flag, and malformed or undefined programs still fail. The SDK types, documentation and migration execution fixtures use this explicit interface. This adds no unchecked function category or alternate execution engine.

The final compiler regression passes **2,005 tests**, native migration passes **156 tests**, and the final WASM migration/API/authoring suite passes **178 tests**, with zero failures or skips. Native/WASM parity agrees on **886 complete API responses plus six complete project reports**, including **204 explicit baseline previews**, all 17 targets, both widths and both layouts. The **172 selected preceding responses** match `ae5e2a71` exactly. A separate 204-case comparison against that compiler matches complete generated files, test/benchmark manifests and the checked program views across three legacy fixtures, every target, width and layout. Generated files (120), module boundaries (232), documentation (119 pages and 114 snippets), editor tests (six), version and artifact-integrity checks pass. Evidence is under `.artifacts/minor-explicit-migration-baseline/` in the migration-transport worktree.

The consumer audit distinguishes templates from exported projects: the seventeen payment configurations acquire their law files during export. A preliminary audit of complete exported projects validates fifteen; C# and Clojure retain explicit blockers for changed generated representations exposed through native functions without corresponding type bindings. The package example also reveals a source-origin bug: version resolution lengthens an import target, and its saved `Band` span is then applied to the shorter original line. These remain concrete migration/cutover work, alongside the other checklist items. Ordinary older-schema compatibility is still present; no interface-cutover completion is claimed. Chapter 6's original bytes, version 0.24.0 and the technical profile remain unchanged. No tag or RC designation is created.

### Original positions through package version resolution — 17 October 2026

Package preparation now uses the existing header grammar to locate unit, import and harness names, inserting version qualifiers and required implicit aliases without rebuilding lines. A portable origin map relates prepared offsets to original locations, including tabs, Unicode, CRLF and EOF. Parsing uses it for syntax nodes, declarations, law locations, references, header predicates and diagnostics. Version selection, visibility and nominal identities retain their existing rules. Compiler definition checks and optional law-layer selection remain unchanged.

This fixes the orders package's out-of-bounds `Band` position and its shifted quoted-law imports. The source preview now completes; canonical admission still rejects an unchanged legacy dependency. That remaining dependency-language work is explicit, and an unadmitted preview still cannot authorize writing. Additional regressions verify declarations on the same line as a qualified unit header, implicit/explicit aliases, separate harness targets, parser and intrinsic-check errors, retained source segments and actual multiline literal values through the evaluator.

The final compiler run passes **2,010 tests**, native migration passes **157 tests**, and the WASM migration/API/authoring suite passes **179 tests**, all without failures or skips. Native/WASM parity agrees on **1,034 complete API responses plus six project reports**, including **148 package checks** across legacy/canonical input, aliases, formatting, all 17 emitters, both widths and both layouts. All **172 selected preceding responses** match `04cb786d` exactly. Generated files (121), module boundaries (232), documentation (119 pages and 114 snippets), six editor tests, version and artifact integrity checks pass. Evidence is under `.artifacts/minor-package-source-origins/` in the migration-transport worktree. Emission and source-provenance checks do not establish a new native conformance matrix.

The source-position blocker from the preceding checkpoint is resolved. Dependency migration, the affected generated native representations, ordinary interface cutover, Chapter 6 authoring and final acceptance remain open. The original Chapter 6 bytes, version 0.24.0 and technical profile are preserved. No milestone completion, RC designation or tag is claimed.

### Code-point source coordinates for migration and editors — 17 October 2026

The public parser now uses the same code-point coordinates for original and compiler-qualified source. Previously, unqualified source inherited the parser library's display-width columns while qualified source used the original-position map. Emoji, fullwidth letters and combining marks could therefore produce inconsistent spans; a migration literal range could include an `end` token or extend past its source line. All source-bearing parser contexts now share the original-position machinery, including constructor-header discovery and separate harness files. Tabs retain eight-column stops, CRLF and literal bytes remain intact, and parse diagnostics use original coordinates rather than misleading display columns.

The new JavaScript regression reproduces an incorrectly selected literal on the preceding compiler, then checks every returned inventory range against the original UTF-16 string and the editor position conversion. It also validates the complete no-target migration and every retained source segment. The focused syntax suite passes 29 tests, the full compiler passes 2,012 tests, native migration passes 158 tests, and the WASM migration/API/authoring/source-inventory run passes 183 tests, all without failures or skips. Generated outputs (121), module boundaries (232), documentation (119 pages and 114 snippets), six editor tests and version checks also pass. Native/WASM parity agrees on 1,106 complete API responses plus six project reports, including 72 additional Unicode responses across both widths, both layouts and all 17 emitters. All 172 selected preceding responses match `2943db52` exactly. This checks source provenance and emission, not a new native implementation-conformance matrix.

A fresh catalog audit now produces migration previews for all 65 bundled source files, whose legacy baseline contains 539 checked laws. Canonical admission next rejects a stateful ability-handler header; an independent minimal example accepts the same handler without state and accepts both forms through legacy migration. This is a separate canonical grammar blocker, not validated catalog migration. Consumer migration, dependency-language handling, the affected native representations, ordinary interface cutover, Chapter 6's second authoring pass and final acceptance remain open. The current version remains 0.24.0; no RC designation or tag is implied.

### Canonical handlers, expressions and numeric previews — 17 October 2026

The catalog audit exposed canonical paths that had dropped existing language behavior. Stateful handler headers now distinguish their declaration `is` from worded equality using the actual operation-clause grammar, including delegated clauses. Initializers retain conditionals, Boolean wording and nested `let` scopes. Canonical computations share the existing state-update, explicit sequencing and performance-budget machinery. Budgets work in laws, named examples and tables with the existing imported clock ability. No new executor or unchecked definition category is introduced.

Canonical equality now binds above conjunction, rather than incorrectly consuming `b && c` as the right operand of `a = b && c = d`. Worded negation and symbolic/worded logical operators retain their required order. Proposition operators still compose with explicit nested quantifiers. Delimited value expressions restore their own equality and membership scopes, while table/example expected-value separators and `let` initializer boundaries remain distinct. The regression suite retains the preceding parser-profile/cache and nested-let checks. Collection models recognize `SortedSet`, select its existing checked ordered-set references, and keep canonical `Set` on equality-based references; all 17 emitters are exercised.

Migration now proposes checked primitive `BigInt` → `Integer` and implicit zero-inclusive `Natural` → `Whole` spellings, alongside `BigUInt` → `Whole`. Index kinds retain zero; bounded nonzero refinements retain their base and limits. Payload-free parameterized/indexed declarations receive canonical headers and closers while preserving equations. Typed previews are not certificates: numeric Core/template/domain differences, ambiguous legacy refinements and missing native representation correspondence still block writing. The planner does not rename documentary text or assume a same-spelled user refinement has the builtin meaning.

The JVM and Go emitters now lower compound handler initializers through their existing checked statement paths. Initial state is evaluated once per handler construction. Native ability boundaries also preserve sole, mixed and absent unit arguments: Swift restores parameters omitted from its public protocols; F# and C# distinguish native method arity from named parameters in checked module functions; Go converts logical units to the concrete native values its ability interfaces require. Argument computations still run before the operation. These fixes preserve the existing executor and mandatory admission checks.

The twelve-law, eighteen-row stateful initializer suite passes every target at 64-bit readable and 32-bit compact profiles. All 34 profile results are established, including 22 reused results whose complete generated projects and acceptance inputs match. Three source mutants are rejected during generation in each profile (102 rejections); another two generate successfully and fail native expectations (68 rejections). The runtime logs identify the affected laws and actual/expected values. Explicit handler scopes remain planned in compiler-only evidence; finite input types alone do not become completed law verification. Both profiles are registered in the repository CI.

The new SDK test exhaustively checks remembered Boolean state and equality precedence at both widths, rejects four independent mutations per width, and checks formatting idempotence. The final compiler passes 2,021 tests with zero failures (430.4 seconds). Native migration passes 161 tests and the rebuilt WASM passes 187 selected migration, source, API and authoring consumers, with no failures or skips. All 121 generated outputs, the 232-module boundary, version 0.24.0, six editor tests and documentation for 119 pages/114 snippets pass. The complete native/WASM parity run agrees on 1,466 full responses and six migration reports, including 1,012 accepted generations across all 17 targets, both widths and both layouts. It includes 360 authoring responses, 72 Unicode responses, 148 package checks, 204 baseline previews and 68 generation receipts. Another 244 complete responses agree exactly with the preceding `2a449c17` WASM without omitting or normalizing fields. Source/artifact integrity matches the rebuilt package. The full npm catalog and complete release gate are not claimed for this checkpoint. The syntax reference now leads with canonical forms and labels the retained 0.24 grammar as migration history.

This advances the 65-file catalog preview to the indexed payload family in `examples/specs/flow_stack.lawspec`; it does not complete catalog migration or publish those previews as migrated examples. Payload-bearing indexed/GADT transformation remains open. A separate stateful example has matched checked Core but unmatched source-template declaration fingerprints. A field-by-field audit localizes that mismatch to phrase-name delimiters in the law-name keys of `lawHandlers` and `lawAssignments`; its writer remains blocked until those links are normalized and checked without discarding handler choices. Native numeric representation bindings, dependency migration, public consumer/configuration cutover, Chapter 6's second authoring pass and final acceptance remain required. The current version is still 0.24.0, not an RC; no tag is authorized.

### Handler-law links and checked single-payload migration — 17 October 2026

Migration comparison now normalizes the law-name keys of handler selections, resolved handler assignments and per-law harness plans alongside their declarations. Structured `for law` harness targets receive the same name mapping. Handler choices, settings, ordering and literal labels remain in the comparison. Changing a selected handler or a repeat setting still prevents correspondence. Both widths pass configured generation and interface comparison for all 17 targets, and a stateful project with a single-law harness passes validated writing and canonical reload. Law evidence remains unverified when no law layers are selected.

The source edit facts now include compiler-owned constructor classification. The planner no longer infers an ordinary nominal record solely because its constructor has the same name as its type: indexed equations and existential scope distinguish the alternative cases. Source editing and payload certification share the same classification helper. Missing classification blocks a same-named record preview. The schema-5 TypeScript response describes these additional facts.

A single payload formal may be renamed to `value` when its exact type, complete constructor metadata, equations, existential scope and predicates are preserved. The existing copier follows the formal's identity and validates the transported program; no new executor, solver or unchecked function category is introduced. GADT and existential previews now use explicit alternative payload syntax instead of accidentally becoming nominal records. Grouping multiple indexed or existential fields remains unsupported by the transport, and canonical natural-index elaboration cannot yet follow a measure through an anonymous record payload. The updated 65-file/539-law catalog preview reaches that typed `Stack.Push` limitation rather than the preceding legacy-declaration syntax error; those examples have not been overwritten or declared migrated.

A direct single-field natural-index example separately reaches matched payload shapes and validated executable transport. Its full source migration still fails because symbolic lowering of generated refinement laws treats a measure call in a refinement as an adapter call, and the generated `refinement Chain@index` and `refinement Natural` population policies change from nonempty to universal. The writer remains blocked: neither a valid payload copy nor a bounded witness can silently discharge those requirements. The next indexed work must retain field paths, index equations, dependent restrictions, measure totality and runtime enforcement. The primary Lean parameter/index reference and Idris dependent-record examples, and their application and limits, are linked in the migration reference. The previously recorded SPARK/Why3 proof-engineering direction remains in force.

Verification passes 2,024 compiler tests (407.1 seconds), all 167 native migration tests, and all 193 selected rebuilt-WASM consumers without failures or skips. The focused source-template and payload suites pass 30 and 25 tests. Native/WASM agrees on the complete 1,466-response parity suite and six reports, including 1,012 accepted generations across every target/width/layout and 244 exact complete comparisons with the preceding `fe98b961` WASM. The new migration cases additionally agree on 36 complete responses and ten reports at both widths. All 122 generated outputs, the 232-module boundary, six editor tests, version 0.24.0 and documentation for 119 pages/114 snippets pass. The full npm catalog, final release gate and remaining migration, consumer cutover and Chapter 6 authoring requirements remain open. This is a minor-version implementation checkpoint, not an RC designation or tag.

### Checked index paths through structural products — 17 October 2026

Core index terms now distinguish a direct field/index reference (`f0.1`) from an explicit structural projection (`p0/1/2.0`). The latter starts at constructor field 0, traverses structural record fields 1 and 2, then reads index 0 of the selected family. Registry admission resolves the actual record constructor identities and leaf family, rejects empty, negative and out-of-bounds paths, and refuses nominal unwrapping. Existing direct references retain their meaning. Record positions follow canonical labels while strict source evaluation order remains independent.

The reference interpreter and all nine shared native schemas enforce nested sibling-index and arithmetic guards. Their conformance entry points pass for all 17 configured targets at both machine widths, including observable secondary indices and rejection of mismatched siblings and undefined natural arithmetic. JVM and web checks also reject malformed field metadata. The .NET checks compile private runtime copies so F# and C# can run concurrently. These checks are registered in repository CI. Checked Core probes additionally admit and emit a nested-path program across all 17 targets and both widths; this emission probe is separate from the native runtime conformance fixtures.

The definition checker builds typed projections for index guards. Pure calls on checked projections retain their equalities through constructed products and the selected match branch. This normalization is used only after strict definedness auditing: all fields still execute, wrong sibling indices remain rejected, and recursive calls still require structural descent. The focused proof checks cover valid and invalid construction, branch-local facts, smaller recursive arguments and rejection of unchanged recursive arguments. This extends existing checked measures and the existing proof projection; it does not add an executor, solver integration or unchecked function category.

The final compiler run passes **2,029 tests with zero failures** (401.1 seconds), native migration passes **167 tests**, and the rebuilt WASM migration/API/authoring/explanation suite passes **196 tests**, without failures or skips. Native/WASM parity agrees on **1,466 complete responses plus six reports**, including **1,012 accepted generations** across all targets, widths and layouts. Another **40 complete preceding non-generation responses** match `dd6adb0b` exactly; preceding generated runtime bytes intentionally differ. The focused migration cases agree on **36 complete responses and ten reports**, retaining the indexed-source rejection and unestablished direct-index correspondence. No response fields were omitted or normalized. Evidence is under `.artifacts/minor-index-paths/` in the migration-transport worktree.

Source grouping remains unavailable. Erasing `record{left :: Tree m right :: Tree m}` into two unrestricted tree fields would lose a dependent relationship from the structural identity. The frontend and migration writer continue to reject the grouped natural-index preview until descriptors, type-owned constraints, substitutions, populations and checked measures preserve that relationship. The direct index generator does not consume nested paths; ordinary generation and shrinking retain their checked filters and existing limits. This does not turn bounded search into complete verification. Direct single-field indexed law transport and its changed population policies remain separate blockers.

Catalog and dependency migration, ordinary schema/configuration/profile cutover, Chapter 6's second authoring pass, the remaining language and demonstration coverage, and final release acceptance remain required. Human readability stays user-deferred; all-named endings belong to the following minor. The version remains 0.24.0, with no RC designation or tag.

### Intrinsic indexed record relationships — 17 October 2026

The preceding index-path checkpoint deliberately kept source grouping unavailable. Source elaboration now retains locally shared natural indices through structural record payloads rather than erasing them into independent children. A constrained record uses a versioned `lawspec.record.v2` BLAKE3 descriptor with normalized guards over canonical field labels and typed projection paths. Unconstrained records keep their existing v1 descriptors and identities. Guard normalization preserves natural-arithmetic definedness. Interning, registry admission, substitution and concrete rebuilding retain the constraints; malformed or erased metadata is rejected.

The product owns its guards independently of any enclosing family. Core value validation, finite enumeration, ordinary generation/shrinking and all native schemas enforce them. Schema-5 structural metadata exposes optional `indexGuards`. A checked function must establish intrinsic guards using unambiguous checked measures before constructing the product. Matching/projection supplies admitted constraints; a smaller recursive call supplies its result contract only after the existing descent audit. Canonical cases retain the lexical `it` binding, and strict product sequences carry evaluated call facts into the enclosing constructor check. Short-circuit branches contribute only the facts they executed. Their propagation follows the truth required on the selected path and leaves ordinary predicates symbolic, avoiding the discarded-path expansion exposed by the existing temporal deadline demonstration. Unproved constructions, incomplete cases, unchanged recursive arguments and undefined strict prefixes remain errors. There is no unchecked function category.

The proof design follows [SPARK's dynamic-predicate obligations](https://docs.adacore.com/spark2014-docs/html/ug/en/source/type_contracts.html), [Why3 verification conditions and record invariants](https://why3.org/doc/vcgen.html), [Lean subtypes](https://lean-lang.org/doc/reference/latest/Basic-Types/Subtypes/) and the previously recorded Idris dependent-record precedent. Immutable LawSpec products require whole-value constraints throughout their use. This extends the existing typed obligation projection and arithmetic checker; it does not implement a new solver backend or independent proof-kernel integration. The obligation generator remains part of the trusted compiler.

Adding a second Core structural-metadata variant changes its internal Binary serialization. Ordinary v1 record descriptors and BLAKE3 identities remain stable, while affected complete Core/template SHA-256 fingerprints change. Verification retains whole preceding/current response pairs and identifies those digest fields explicitly; it does not strip them to assert cross-version equality.

Source tests cover recursive stacks and balanced trees, dependent results, implicit shared record inputs, checked conditional construction, identity normalization, rejected dropping/mismatched children and complete finite constrained domains. Repeated indices in one direct family field (`Matrix n n`) remain distinct selectors joined by an intrinsic equality, including beneath a nested product; valid construction passes and off-diagonal construction remains a definition error with law checks unselected. Native conformance directly validates guard-only products, independently of a wrapper, for all 17 targets at both widths. The final compiler run passes **2,048 tests with zero failures** (415.9 seconds), native migration passes **167 tests**, and rebuilt-WASM migration/API/authoring/explanation consumers pass **198 tests**, without failures or skips. Complete native/WASM parity agrees on **1,766 responses and six reports**, including **1,284 accepted generations** across all 17 targets, both widths and both layouts. All **1,614 complete preceding responses**, including generated bytes, match the frozen pre-repeated-index-fix compiler exactly; the new case's intentional changes are retained as complete before/after pairs. The earlier `4c45d637` comparison separately retains 34 complete response pairs whose structural Core/template digest fields changed with the Binary representation; no response fields were stripped. Evidence is under `.artifacts/minor-record-index-guards/` in the migration-transport worktree. All 122 generated files, the 232-module compiler/backend boundary, six editor tests, documentation for 119 pages/114 snippets, version consistency and package integrity checks pass.

Grouped indexed/existential migration transport, direct indexed law population correspondence, scalar-dependent record indices, enclosing-value dependencies in record inputs/results and non-variable record-field index patterns remain explicit open work. They cannot be cleared by source admission alone. Catalog/dependency migration, canonical interface cutover, Chapter 6's second authoring pass and full milestone acceptance remain required. Human readability remains user-deferred, all-named endings belong to the following minor, and version 0.24.0 has no RC designation or tag.

## Historical review discussion

The following sections preserve earlier examples and alternatives for review. Any wording marked open/proposed below is historical where the authoritative RC1 decisions above resolve it. In particular, optional totality, ambiguous Natural naming, unlabeled canonical closers and permissive schema compatibility are superseded.

## Contents

1. How to use this draft
2. What business readers have already told us
3. Adoption without requiring every guarantee
4. A short reader vocabulary
5. Worked examples for business review
6. Records and alternatives under active discussion
7. Questions to take to business readers
8. Decision ledger
9. Draft grammar and semantic translations
10. Existing implementation inventory
11. Existential verification and evidence
12. Formatting editors and presentation
13. Required demonstration portfolio
14. Implementation phases and release criteria
15. Complete remaining design agenda
16. Eight combinations of three nested layers
17. Review worksheet and suggested answers
18. Repository sources and glossary

---

## 1 How to use this draft

### Status labels

| Label | Meaning |
| --- | --- |
| Approved | A direction or example accepted in the working discussion. It remains open to a deliberate revision based on new feedback. |
| Recorded planning direction | An earlier planning choice to carry forward and check when the complete plan is consolidated. |
| Preferred proposal | A recommendation awaiting approval. |
| Alternative | A plausible choice retained for comparison. |
| Unresolved | A decision or precise behavior still needs discussion. |
| Superseded | An earlier choice replaced by a later instruction. Retained where its history explains the current choice. |
| Existing implementation | Behavior found in the current repository, distinct from the proposed language. |

An approval of an example establishes the features it actually demonstrates. It does not approve every possible extension, inference rule, or migration behavior.

### A suggested review session

Start with Sections 2 through 7. Use familiar examples about pictures, group sizes, and books before introducing payment terminology. Use the nesting examples in Section 16 when readers are ready to discuss structured data.

Give readers an example before explaining it. Ask them to predict two or three outcomes and say why. Record their original interpretation before teaching the intended one. Afterwards, compare alternative wording.

Ask separately:

1. What does the specification mean?
2. What does it leave unspecified?
3. Which spelling is easier to read?
4. What would convince you that the implementation follows it?

Confidence, preference, correctness, and time to understand are different observations. Record them separately. A reader can prefer a spelling while misunderstanding it.

Keep ordinary examples clear without source-code comments. Descriptions, rationale, and domain definitions can supply necessary context. Avoid making an explanatory comment compensate for an unclear language construct.

### Printing

This is one self-contained Markdown file. Open it in a Markdown preview and print the rendered document. Code blocks contain no color-dependent meaning. Tables, headings, and review spaces remain understandable in black and white.

For a shorter meeting, print Sections 1 through 7 and the examples from Section 16 you intend to discuss. The rest preserves the technical detail and remaining work.

Reviewer: ______________________________________________

Role or domain experience: ______________________________

Date: __________________________________________________

## 2 What business readers have already told us

The feedback concerns both unfamiliar programming notation and unfamiliar financial vocabulary.

| Feedback | Implication for this review |
| --- | --- |
| “BigUInt” looked like “big unit.” | Representation names do not explain domain meaning. Test Natural and meaningful domain types, and state units explicitly. |
| “Case” first suggested upper case, lower case, or case sensitivity. | Test the explicit phrase “first matching case of” through actual outcome prediction. |
| Repeated “end” resembled nested brackets but did not identify what closed. | Named closers such as “end case” and “end function” have been accepted for the constructs demonstrated. |
| “The period makes it a triple end.” | Locate the exact punctuation that caused confusion. Do not assume the reader meant a namespace dot, a sentence period, or a terminator. |
| “I don’t know what :: means.” | The worded annotation “of type” is now an accepted alternative. |
| Financial examples made the reader feel inexperienced with money. | Separate language comprehension from knowledge of capture, authorization, settlement, and refunds. |

The language should not require knowledge of payment processing to demonstrate tuples or matching. A picture’s dimensions are a more familiar starting point.

The existing concern about periods remains unresolved. There is no proposed statement-ending period in these examples. A dot in a unit name separates namespaces; a dot in a field access selects a field; ordinary prose may contain sentence punctuation.

## 3 Adoption without requiring every guarantee

**Approved direction:** users can adopt layers independently and gain additional guarantees as they choose them. Using LawSpec must not require complete agreement with the strongest formal model.

| A team chooses | What it obtains | What it has not established merely by choosing it |
| --- | --- | --- |
| Typed declarations and readable requirements | Resolved names, checked types, useful specification and documentation | A proof that native implementations satisfy every law |
| Explicit examples and tables | Checks of those named cases | Correctness for every possible input |
| Property-based tests | Generated cases, boundaries, shrinking, and reproducible failures | An exhaustive result over an unbounded domain |
| Finite exhaustive checking | Every value in a clearly defined finite domain is checked | Correctness outside that domain |
| Runtime contracts | Checks at actual execution boundaries | Correctness of every execution that has not happened |
| Static proof or solver analysis | A proposition established within stated assumptions and supported reasoning | Unstated assumptions, native implementation correctness, or an external policy oracle |
| Stateful or temporal analysis | Guarantees for an explicitly defined model, trace, or runtime observation | Automatic conformance of an arbitrary distributed implementation to that model |

These are independently selectable layers, not a mandatory ladder. A team may want runtime contracts and examples before attempting theorem proving.

Type errors and an invalid value for an explicitly chosen type remain errors. Optional verification does not silently turn an invalid address into a valid one.

### Mandatory definition validation

Automatic exhaustiveness, termination, definedness, refinement, and definition-contract validation remain intrinsic compiler checks. Existing runtime enforcement of deliberately deferred postconditions remains. No unchecked function category or `checked` modifier is introduced. Progressive adoption selects verification of laws only.

The earlier proposal to make totality depend on a modifier or checking profile is **superseded history**. Purity and totality remain distinct properties; both pure functions and effectful procedures retain their existing intrinsic validation.

An unselected layer should be reported as not verified, rather than as failed or proved. A selected, required analysis that cannot complete should report its actual incomplete result. Scoped exemptions must carry a reason.

## 4 A short reader vocabulary

| Word | Meaning in this draft |
| --- | --- |
| Function | A pure computation. The same inputs determine its result without performing an ability operation. |
| Procedure | A computation that uses an effectful ability, such as writing an audit entry. |
| Ability | An interface to effectful computation. A handler supplies what its operations actually do. |
| Law | A required behavioral relationship. Business requirements and mathematical properties share this declaration. |
| Record | Named fields that belong together in one value. |
| Tuple | A group of values distinguished by position, such as width followed by height. |
| Alternative or discriminated union | A value chooses one named alternative, which may carry data. The chosen name identifies the alternative. |
| Pattern | A structured way to recognize an alternative and extract the data needed from it. |
| Refinement | An additional condition on values of an existing type. |
| Witness | A concrete value that satisfies an existence requirement. |
| Natural | An exact whole number at least zero, without a fixed maximum. |
| Evidence | What a particular check, proof, test, or execution actually established. |

“Must” expresses an obligation. It is not an instruction that executes the refund, creates a record, or repairs a failed state.

## 5 Worked examples for business review

### 5.1 A pure function and a law

**Approved direction.**

~~~text
unit example.arithmetic

function "|double the value| (value of type BigInt) -> BigInt is
  value + value
end function

law "|doubling is multiplication by two| is
  definition:
    for all (value of type BigInt) =>
      "|double the value| value = 2 * value
    end
  end
end
~~~

The function supplies a computation. The law says what must hold for every integer.

The quantifier now has its own closing end. This is a later approved revision to the original proposal, which had requested no extra quantifier end. The section and law also close. Exact future use of labels on section and quantifier closers is still a formatting question.

The unusual identifier spelling is literal: the name begins with a double quote and pipe and finishes with a pipe. It has no closing double quote. Ordinary identifiers such as doubleValue remain equally valid.

### 5.2 Ordinary names and checked tables

**Approved direction.** Expectations precede the table, which supplies their bindings.

~~~text
unit example.arithmetic

function doubleValue (value of type BigInt) -> BigInt is
  value + value
end function

law "|doubling agrees with these examples| is
  definition:
    for all (value of type BigInt) =>
      doubleValue value = 2 * value
    end
  end

  expect doubleValue value = expected
  in table (value, expected):
    row -1, -2
    row 0, 0
    row 1, 2
  end
end
~~~

The formal proposition and the three table cases remain different sources of evidence. Three examples do not prove the universal law.

Multiple expectations may share one table. Each row checks all expectations independently and participates in the enclosing law’s normal case checking.

~~~text
expect doubleValue value = expected
expect value + value = expected
in table (value, expected):
  row -1, -2
  row 0, 0
  row 1, 2
end
~~~

### 5.3 An effectful procedure

**Approved distinction.** Abilities mean effectful computation.

~~~text
unit example.audit

ability AuditLog is
  append of type Text -> ()
end

procedure "|record an audit message| (message of type Text)
  uses AuditLog
is
  append message
end
~~~

This procedure writes through AuditLog. A pure function cannot perform that operation. A type capability such as Eq, which permits equality, is a different concept from an effectful ability.

The empty result is (). Omitting a procedure’s result arrow is accepted for this result. A named “end procedure” closer is a candidate for consistent extension; the earlier approved procedure example used plain end.

### 5.4 A familiar choice based on a number

**Approved direction.**

~~~text
unit example.groups

function "|group size| (people of type Natural) -> Text is
  first matching case of people:
    when it >= 10 then
      "large"

    when it >= 5 then
      "medium"

    otherwise "small"
  end case
end function
~~~

Here it means the value of people. Twelve gives “large,” seven gives “medium,” and three gives “small.” The first matching branch supplies the result.

The selected value is evaluated once. Nested selections introduce their own it. The precise escape or naming convention for referring to an outer it remains to be finalized.

### 5.5 Tuples and picture orientation

**Approved example direction.** Destructure the tuple once in the parameter.

~~~text
unit example.pictures

type Orientation is one of
  | Landscape
  | Portrait
  | Square
end type

function "|picture orientation|
  ((width, height) of type (Natural, Natural)) -> Orientation
is
  first matching case of compare width height:
    when Greater then Landscape
    when Less then Portrait
    when Equal then Square
  end case
end function

expect "|picture orientation| (1200, 800) = Landscape
expect "|picture orientation| (800, 1200) = Portrait
expect "|picture orientation| (1000, 1000) = Square
~~~

The tuple positions mean width and height. “When it matches Greater” is also an accepted explicit spelling. It matches may be omitted for recognizable constructor and structured patterns.

Parameter patterns must match every value of their declared input type. Choosing among genuinely different alternatives belongs in an exhaustive case expression.

The current library already has compare and the alternatives Less, Equal, and Greater. Compare uses the existing Keyed comparison semantics; this example uses Natural, where that order is ordinary numeric order.

### 5.6 Named and anonymous records

**Approved latest record direction.**

~~~text
unit example.pictures

type Picture is a record
  fileName of type Text
  dimensions of type record{
    width of type Natural,
    height of type Natural
  }
end type
~~~

Picture is a named record. Its dimensions are an anonymous record. A tuple remains an alternative for dimensions:

~~~text
dimensions of type (Natural, Natural)
~~~

Named fields describe which number is which without relying on position. A tuple is shorter when the order is familiar and stable.

The latest instruction replaces anonymous “record: … end record” with record{…}. Named type declarations retain end type.

Commas inside record braces are a preferred punctuation proposal shown consistently in this draft. Whether they are required, optional, or replaced by another unambiguous separator is still open. Line breaks must not silently change the type or expression.

Named records remain distinct types. Anonymous records are identified by their field names and types. Closed field sets, field-order independence for type identity, and the absence of implicit width subtyping are the recorded preference; precise construction and inference rules still need completion.

### 5.7 A function stating a policy and a law requiring conformance

**Approved overall direction.** Use function cases for priority and laws for required conformance. The record-based presentation below combines the latest record direction with that example.

~~~text
unit example.refunds

type RefundRequest is a record
  amountInCents of type Natural
  needsReview of type Bool
end type

type RefundDecision is one of
  | Approved
  | "|Rejected for exceeding captured funds|
  | "|Pending review|
end type

function "|refund policy|
  (capturedCents of type Natural)
  (request of type RefundRequest) -> RefundDecision
is
  first matching case of request:
    when it.amountInCents > capturedCents then
      "|Rejected for exceeding captured funds|

    when it.needsReview then
      "|Pending review|

    otherwise Approved
  end case
end function

refund of type Natural -> RefundRequest -> RefundDecision

law "|refunds follow the stated policy| is
  definition:
    given
      (capturedCents of type Natural)
      (request of type RefundRequest)
    then
      refund capturedCents request
        must be "|refund policy| capturedCents request
  end

  description:
    "Reject requests above captured funds first.
     For remaining requests, require review when flagged.
     Approve the remaining requests."
  end
end
~~~

For this example only, captured funds are money already collected, and amountInCents expresses a chosen unit. This is an illustrative policy rather than a claim about an actual payment provider’s rules.

For 100 captured cents:

| Requested cents | Review flag | Required outcome |
| --- | --- | --- |
| 120 | true | Rejected for exceeding captured funds |
| 120 | false | Rejected for exceeding captured funds |
| 80 | true | Pending review |
| 80 | false | Approved |

The law does not introduce a second policy engine. Its proposition requires the implementation’s result to equal the pure policy function’s result.

Separate applicable requirements all constrain behavior; their textual order does not establish priority. Within one operation-contract or applicability group, requirements concern the same captured result. Independently written adapter invocations remain independent observations.

### 5.8 What must means

These accepted forms express the same equality obligation:

This small comparison uses the independent simplified signature refund of type Natural -> Natural -> RefundDecision. The second input is an amount, unlike the RefundRequest record used in Section 5.7.

~~~text
must refund capturedAmount 0 = Approved
~~~

~~~text
refund capturedAmount 0 must = Approved
~~~

~~~text
refund capturedAmount 0 must be Approved
~~~

They require a result. They do not execute an extra refund, establish textual rule priority, or describe an unspecified alternative outcome.

Ordinary prohibition has logical negation semantics:

~~~text
must not approveTransfer account request
~~~

It requires the proposition “approveTransfer account request” to be false. It does not imply a particular error constructor unless the law states one.

### 5.9 Membership and primitive sets

**Approved direction.**

~~~text
refund capturedAmount 0
  must be in #S{Approved, "|Pending review|}
~~~

~~~text
refund capturedAmount 0
  must not be in #S{"|Rejected for exceeding captured funds|}
~~~

The #S{…} notation is primitive set syntax. Membership ultimately extends to collections of elements supporting Eq. It must not silently demand a stronger ordering capability everywhere.

In, not in, and the worded is in spelling have been discussed and accepted in the relevant contexts. The complete operator inventory and exact precedence still need consolidation.

### 5.10 Existence within an explicit collection

**Approved logical and business wording; domain integration still needs a complete demonstration.**

~~~text
law "|every captured payment has an authorization| is
  definition:
    given
      (payment of type CapturedPayment)
      (authorizations of type List Authorization)
    then
      there must exist an
        (authorization of type Authorization
          where the authorization is in authorizations)
      such that
        authorization `|authorizes| payment
      end
  end
end
~~~

The relation authorizes is an ordinary typed function, also callable in prefix form. The a or an article is optional and contextual before a binder. It does not globally reserve the variable name a.

Names such as sideA, sideB, and sideC may make a Pythagorean example easier to read, but the article feature does not force every mathematical variable a to be renamed.

This law requires an authorization in the supplied collection. Constructing an unrelated authorization-shaped value does not satisfy that membership restriction.

The domain of the example matters. Taken over every arbitrary payment and every arbitrary list, this law is false, including when the list is empty. The finished demonstration must tie inputs to an actual observed capture or to reachable states of the authorization model. We must not assume the desired authorization invariant merely to prove it.

### 5.11 Negative existence over a defined history

**Approved wording direction.**

~~~text
law "|revoked credentials have no active sessions| is
  definition:
    given
      (credential of type RevokedCredential)
      (sessions of type List ActiveSession)
    then
      there must not exist a
        (session of type ActiveSession
          where the session is in
            sessionsAfterRevocation credential sessions)
      such that
        session `|is authenticated by| credential
      end
  end
end
~~~

The optional connective is before a named infix function remains an approved language direction. The name inside its delimiters is still exact. Optional surrounding words do not rename “authenticated by” into “is authenticated by.”

For a function whose declared name is authenticated by, the optional connective gives these two spellings:

~~~text
session `|authenticated by| credential

session is `|authenticated by| credential
~~~

The example above instead uses the separately chosen literal function name is authenticated by, with the preferred call spelling:

~~~text
session `|is authenticated by| credential
~~~

The finished model must define active, revocation time, sessionsAfterRevocation, the authentication relation, and the completeness of the observed state or history.

An inspected snapshot can establish absence in that snapshot. It cannot, by itself, establish that no session will ever appear in an unobserved future.

### 5.12 Formal quantifiers and their order

**Approved distinction.**

~~~text
for all (x of type X) =>
  there exists (y of type Y) such that
    x `|relates to| y
  end
end
~~~

~~~text
there exists (y of type Y) such that
  for all (x of type X) =>
    x `|relates to| y
  end
end
~~~

The first allows a different y for each x. The second requires one y that works for every x.

Formal negative existence is available as:

~~~text
there does not exist (session of type ActiveSession) such that
  session `|is authenticated by| credential
end
~~~

It denotes the negation of an existential proposition, as does an explicitly parenthesized not around that proposition.

### 5.13 A value that must fail to compile

**Approved example direction.** Invalid inputs can be checked as expected compiler failures.

For an Address refinement ranging from 0 through 32767:

~~~text
expect "|is zero| (-1)
  fails to compile with "argument-outside-type"

expect "|is zero| 32768
  fails to compile with "argument-outside-type"
~~~

The helper’s declared input must actually be Address. These are expected failures of typing or refinement acceptance, not runtime examples returning false. Final fixture syntax must ensure the compiler can record an expected rejection without rejecting the entire documentation suite.

### 5.14 References within the specification

**Approved feature direction:** supporting references can refer to another law, function or definition, description, rationale, individual reference, or a set of such targets.

For example, a refund requirement may cite the formal definition of the refund policy and the rationale of a separate authorization law. A reader should be able to follow both links and see precisely which material was referenced.

The final concrete selector spelling and stable identities must be recorded before implementation. This snapshot does not manufacture a selector syntax from an absent example transcript.

References document provenance and relationships. Citing another law does not automatically prove it or import its assumptions.

### 5.15 Example 50 and prohibited filenames

**Approved:** a prohibited filename returns an explicit rejection result. It does not make constructing Picture invalid.

The intended text behavior follows the supplied Haskell example: Unicode case folding followed by substring detection of any of three listed fragments.

~~~text
function containsProfanity (input of type Text) -> Bool is
  let normalized = caseFold input in
    let badWords = ["shit", "piss", "fuck"] in
      any (contains normalized) badWords
end function
~~~

The current contains matcher takes the haystack first. Therefore contains normalized is intended to be a predicate on each prohibited fragment.

**Supporting library work:** caseFold and any have not been found as public functions in the current prelude. Partial application of contains must be supported through an ordinary typed function rather than relying on the current special handling of saturated matcher calls.

The final example should reject a prohibited filename before applying banner dimension eligibility, then return the normal size result for other filenames. It should test uppercase fragments, clean names, and a small picture with a prohibited name to show priority.

**Still open:** the exact Picture construction and union payload notation used by the finished example. The user approved its rejection behavior, not a final unshown program.

Case folding must have one defined Unicode behavior across targets. Lowercasing is not automatically an equivalent implementation. Word boundaries, normalization, and a more sophisticated moderation policy are separate choices; none are silently added to this substring example.

## 6 Records and alternatives under active discussion

### 6.1 The latest record spelling

**Approved:** anonymous types, values, and patterns use record{…}. The earlier worded anonymous block with end record is superseded.

Named record declaration:

~~~text
type EmailDetails is a record
  recipient of type Text
  document of type Document
end type
~~~

Anonymous record type:

~~~text
record{
  recipient of type Text,
  document of type Document
}
~~~

Anonymous record value:

~~~text
record{
  recipient: "alex@example.com",
  document: document
}
~~~

Record pattern:

~~~text
record{
  recipient: address
}
~~~

The value and pattern contexts determine whether address is being read as an expression or introduced as a binding. The type context determines that of type supplies a field annotation.

These examples use commas as the current punctuation proposal. Named record construction, an optional type prefix, contextual typing, and whether a record value can construct a nominal record all remain explicit questions.

### 6.2 Why the earlier Email alternative was confusing

Earlier candidate:

~~~text
type Delivery is one of
  | Email
      recipient of type Text
      document of type Document
  | Download document of type Document
end type
~~~

This makes Email a constructor of Delivery with two fields. It does not create a separately named type Email. A person reading it as a reference to an existing Email record would have a different interpretation.

The current implementation follows the constructor-and-fields approach. The redesign should make the relationship visible enough for business readers.

### 6.3 Preferred proposal with an explicit payload type

**Preferred proposal, awaiting approval.**

~~~text
type EmailDetails is a record
  recipient of type Text
  document of type Document
end type

type Delivery is one of
  | Email of type EmailDetails
  | Download of type record{
    document of type Document
  }
end type
~~~

Email is the alternative’s name. EmailDetails is the type of its payload. Download carries an anonymous record.

If the existing record type is named Email, one explicit spelling is:

~~~text
type Delivery is one of
  | ByEmail of type Email
  | ForDownload of type DownloadDetails
end type
~~~

An inline payload can express the same fields without introducing a reusable named type:

~~~text
type Delivery is one of
  | Email of type record{
    recipient of type Text,
    document of type Document
  }
  | Download of type record{
    document of type Document
  }
end type
~~~

A named nominal record and an anonymous structural record do not automatically become interchangeable merely because their fields look alike.

The explicit-payload proposal changes the constructor from taking two separate fields to carrying one record. Migration, generated schemas, constructor calls, patterns, capabilities, and dependent field relationships must account for that change. Successful parsing alone does not establish compatibility.

### 6.4 Alternative listing existing types directly

**Alternative requested for exploration.**

~~~text
type Delivery is one of
  | Email
  | Download
end type
~~~

This could mean “either an existing Email value or an existing Download value.” It is attractive when those types are already well named.

However, bare alternatives already express cases with no payload:

~~~text
type RefundDecision is one of
  | Approved
  | PendingReview
end type
~~~

We must decide how the grammar distinguishes a referenced type from a newly declared data-free alternative. A later type declaration must not silently change an existing alternative’s meaning.

Possible solutions to compare:

1. Require an explicit tag and payload annotation, as in the preferred proposal.
2. Introduce an explicit existing-type member marker and derive its alternative identity.
3. Distinguish a union of existing types from a declaration of named alternatives.
4. Permit bare type members only under a tightly specified, stable rule with diagnostics for ambiguity.

If two alternatives carry the same type or records with identical fields, explicit alternative identities still matter. Pattern matching must not guess the chosen case from field shape.

### 6.5 Matching the preferred proposal

**Proposal for review.**

~~~text
function "|delivery description|
  (delivery of type Delivery) -> Text
is
  first matching case of delivery:
    when Email (record{ recipient: address }) then
      "Email to " ++ address

    when Download #any then
      "Available for download"
  end case
end function
~~~

First select the union alternative. Then read the fields of its payload.

The pattern ignores unspecified record fields. Unknown or duplicate field names should produce diagnostics. A record pattern is checked against the type expected at that position; it does not erase nominal distinctions.

Whole-value bindings, field puns such as record{recipient}, aliases for nested patterns, and shorthand for matching a known record type are further options. The examples should not accidentally make all of them mandatory.

### 6.6 How to count three nested layers

The eight combinations in Section 16 originally counted delivery, document, and file as three layers. Their union alternatives declared fields directly.

An explicit record payload introduces an additional record node in the type structure. We should distinguish three domain layers from exactly three successive record-or-union nodes. Both are useful, but they are different counting rules.

The appendix preserves the eight earlier combinations with the latest record braces. It labels the union field spelling as an earlier candidate. It does not silently claim that the still-unapproved payload proposal has been settled.

## 7 Questions to take to business readers

These are discussion prompts, not a requirement to answer every question in one meeting.

### 7.1 Understanding a requirement

1. Explain the doubling law in your own words. Does its table establish the same thing as “for all”?
2. In the group-size example, what does it refer to?
3. Do “first matching case of” and “otherwise” make the choice and priority understandable?
4. Which closing words help you find where a function, choice, or requirement finishes?
5. Is must be clearer than a plain equals sign for a requirement? Does either look like an instruction to execute?
6. Where would you put an explanation you need: a type name, field name, description, rationale, or reference?

### 7.2 Names and type descriptions

7. Compare value of type Natural with value :: Natural. Which can you explain without help?
8. Does Natural communicate a whole number at least zero? What wording would make its boundary clear?
9. Does AmountInCents explain more than BigUInt? What unit or rounding question does it raise?
10. Do names with spaces improve comprehension enough to justify the visible quote-and-pipe marker?
11. Do ordinary identifiers such as capturedCents remain comfortable beside spaced names?
12. What did you believe each punctuation mark meant before it was explained?

### 7.3 Records tuples and alternatives

13. Can you tell whether a value contains all the fields or chooses one alternative?
14. Is a picture’s dimensions clearer as a tuple or a record with width and height?
15. Compare the three union presentations in Section 6. Which makes Email’s role clearest?
16. Should the union name its alternatives, list existing types, or visibly do both?
17. What do you expect when two alternatives carry identical-looking records?
18. Can you trace one selected path through three layers without reading unrelated fields?
19. Does record{…} help you see structure, or does the punctuation remain an obstacle?
20. At what depth would you prefer giving an intermediate concept its own name?

### 7.4 Policies exceptions and incomplete requirements

21. For a request above captured funds that also needs review, which outcome wins, and why?
22. Can you distinguish an ordered policy function from several laws that all apply?
23. Should an incomplete requirement be acceptable when deliberately scoped?
24. How should the tool show conflicting requirements without claiming a conflict it has not established?
25. What would you expect must not approve to say about the actual error result?
26. Does “in this set” clearly communicate several permitted outcomes?

### 7.5 Existence time and evidence

27. Does “there must exist an authorization” mean a record in the actual system, a value we could construct, or an item in a named list?
28. Which state, history, time, and identity define that authorization?
29. What would “not found after a limited search” establish?
30. What evidence would establish that no matching session exists?
31. What does eventually mean operationally? Is there a deadline or fairness assumption?
32. Which evidence labels would you trust enough to release a change, and for what scope?
33. What would make it clear that a proof of a model is not automatically a proof of the native implementation?

### 7.6 Adoption and communication

34. What is the smallest useful LawSpec document your team would adopt?
35. Which guarantees would you add next, and which should remain optional?
36. What should a business view show by default? What should remain available on demand?
37. Could you identify the required behavior without understanding every type or verification detail?
38. What counterexample would help you explain a failure to another person?
39. Which information would you need to approve a policy change?
40. What should be preserved when a requirement is renamed, versioned, or superseded?

Space for immediate reactions:

____________________________________________________________________

____________________________________________________________________

____________________________________________________________________

## 8 Decision ledger

This ledger distinguishes the latest instructions from the original proposal. A later explicit correction takes precedence over an earlier preference.

### 8.1 Language identity and adoption

| ID | Status | Direction |
| --- | --- | --- |
| D01 | Approved | Readability should resemble Elixir, Pascal, Ruby, and Ada while retaining ML-family, refinement, and dependent-type power. |
| D02 | Approved | Progressive adoption is central. Stronger verification layers are opt-in rather than a prerequisite for use. |
| D03 | Approved | All authoring forms elaborate into one authoritative typed semantic representation. |
| D04 | Approved | Every agreed feature and supporting tool belongs before 1.0. Major scope must not quietly move after 1.0. |
| D05 | Approved | Business comprehension is an acceptance criterion, tested with actual readers. |
| D06 | Approved | Develop the authoring experience through concrete examples and explicit feedback. |

### 8.2 Declarations names and documentation

| ID | Status | Direction |
| --- | --- | --- |
| D07 | Approved | Declarations use is; named sections use a colon. |
| D08 | Approved | Keep definition: as the authoritative proposition section. |
| D09 | Approved | Description, rationale, example, table, and references use the consistent section convention, subject to the later expect-first table form. |
| D10 | Approved | Scalar metadata such as id and owner uses one colon and one value, without an independent end. |
| D11 | Approved | Use law for mathematical and business requirements. Do not add canonical rule and decision declaration categories. |
| D12 | Approved | Function means pure computation; procedure means effectful computation using abilities. |
| D13 | Approved | An ability means an effectful computation interface. It is not merely a generic type capability. |
| D14 | Approved | Spaced names have one consistent form across declarations and prefix invocation, with the corresponding infix marker form. |
| D15 | Approved | Ordinary programming identifiers remain valid. Spaced names are an option, not a requirement. |
| D16 | Approved | Of type is an accepted worded equivalent of :: in type annotation positions. |
| D17 | Approved | Function examples use -> for the result. Procedures returning () can omit the result arrow. |
| D18 | Approved | Internal references can identify formal and explanatory material and sets of such targets. |
| D19 | Approved | Meaning should be clear without explanatory comments inside examples. |

### 8.3 Logical and business expressions

| ID | Status | Direction |
| --- | --- | --- |
| D20 | Approved | Universal syntax is for all … =>, without do. Later examples add a quantifier-closing end. |
| D21 | Approved | Existential syntax is there exists … such that, without do, with a scoped body. |
| D22 | Approved | Business syntax is there must exist … such that, with optional a or an before a binder. |
| D23 | Approved | There does not exist and there must not exist denote negative existence in their respective contexts. |
| D24 | Approved | Quantifier order, dependent binder scope, and restriction semantics must survive every transformation. |
| D25 | Approved | Given, when, and then business clauses live inside definition:. |
| D26 | Approved | Must, must =, and must be forms state obligations and share formal semantics. |
| D27 | Approved | Must not is precise logical negation, without an unspecified alternative outcome. |
| D28 | Approved | Must be in and must not be in are supported directions. |
| D29 | Approved | #S{…} is primitive set notation. Membership extends to appropriate Eq collections. |
| D30 | Approved | Where x is in xs is an accepted worded membership form. The bound-name phrase “the x” is optional in the discussed refinement context. |
| D31 | Approved | Named infix invocation is ordinary function application, available throughout the language. |
| D32 | Approved | The optional connective is before a named infix application remains available. Function names themselves remain exact. |
| D33 | Recorded planning direction | Use type-directed canonical = while preserving Boolean equality semantics and Eq requirements during migration from ==. |
| D34 | Recorded planning direction | Logical grouping is not, then and, then or, then right-associative implies. Named infix chains require parentheses rather than adopting arbitrary fixities. |

### 8.4 Data and matching

| ID | Status | Direction |
| --- | --- | --- |
| D35 | Approved | Named records use type Name is a record … end type. |
| D36 | Approved latest correction | Anonymous records use record{…} for types, values, and patterns. |
| D37 | Superseded | Anonymous record: … end record was briefly preferred, then explicitly replaced by record{…}. |
| D38 | Approved | Alternative types use type Name is one of. Their exact payload declaration grammar remains unresolved. |
| D39 | Approved | Tuples, records, and alternatives should compose recursively. |
| D40 | Approved | First matching case of value: makes ordered selection explicit. |
| D41 | Approved | Case-local it refers to the selected value. Explicit it matches can be omitted for recognizable patterns. |
| D42 | Approved | Otherwise is the last fallback, without when or then. Else remains the conditional alternative. |
| D43 | Approved | #any is readable wildcard syntax; _ remains equivalent shorthand. |
| D44 | Approved | Parameter patterns can destructure an irrefutable input once. Do not require artificial repeated tuple matches. |
| D45 | Approved | Preserve refined environments, GADT branch refinement, exhaustiveness, termination, and structural recursion guarantees when selected. |
| D46 | Approved | Named closers have been accepted for function, type, case, and if. Extension to other constructs remains to be specified. |
| D47 | Approved | Policy priority belongs in pure function cases; laws require conformance to those policy functions. |
| D48 | Preferred proposal | Union alternatives can explicitly carry an existing named type or an inline anonymous record using of type. |
| D49 | Unresolved | Whether an alternative can list an existing type directly, and how that differs from a payload-free case. |
| D50 | Preferred proposal | Anonymous records are closed structural products with field-name/type identity; named records remain nominal. Finish the exact subtyping and construction rules. |

### 8.5 Examples tooling and delivery

| ID | Status | Direction |
| --- | --- | --- |
| D51 | Approved | Expectation-first in table is the canonical table direction. Multiple expectations may share one table. |
| D52 | Approved | Examples can assert expected compiler rejection for invalid typed inputs. |
| D53 | Approved | Two-space indentation, spaces rather than tabs, fixed continuation indentation, and a target width of 80 columns. |
| D54 | Approved | The formatter preserves semantics, comments, literal values, infix style, and approved worded forms. |
| D55 | Approved | Provide developer, business, formal, and evidence presentations of the same authoritative obligation. |
| D56 | Approved | Improve counterexamples, generator explanations, witnesses, completeness reporting, and source links. |
| D57 | Approved | Update VS Code support and establish genuine GitHub syntax highlighting. |
| D58 | Approved | The chat examples can remain uncolored. GitHub and editor support are separate deliverables. |
| D59 | Approved | Example 48 remains a historical tuple-based picture example. Example 49 explores anonymous record dimensions. |
| D60 | Approved | Example 50 returns an explicit rejection for a prohibited filename rather than making Picture unconstructible. |

### 8.6 Earlier planning directions to preserve

The following belong in the complete implementation plan. They are not newly invented requirements of this export.

- Use a source-preserving concrete syntax layer and the existing semantic architecture, rather than building another business rule engine.
- Use general checked finite mappings rather than an unrelated encoding-only execution mechanism.
- Keep external-oracle tests independent from a table and the functions derived from it.
- Use exact, proven-lossless widening; introduce no implicit narrowing, precision loss, or target-dependent overflow.
- Support binary and hexadecimal literals with sound contextual typing.
- Resolve unqualified prelude names deterministically after local and explicit import resolution, with clear conflict diagnostics.
- Use an immediate, deliberate canonical syntax transition with a separate legacy parser/migrator rather than an indefinite permissive mixture.
- Keep explicit examples, tests, harness controls, and documentation distinct from a law’s proposition.
- Reuse existing temporal, workflow, scenario, actor, session, and model machinery.
- Keep effective dates, ownership, versions, approval information, and supersession documentary unless a semantic relationship is stated explicitly.
- Preserve typed source identities, public contract manifests, schema compatibility checks, and stable evidence provenance.

### 8.7 Superseded directions that must not reappear accidentally

| Earlier direction | Current direction |
| --- | --- |
| Separate top-level rule and decision declarations | Laws express requirements; functions express computations and prioritized policies; procedures express effects. |
| Universal quantifiers have no independent end | Later approved examples explicitly close the quantifier. |
| Anonymous worded records with end record | Anonymous record{…}. |
| Legacy law names using paired backticks | Unified name markers, with explicit migration rules. |
| A compulsory “it matches” prefix for every constructor | Optional when the pattern form is recognizable. |
| A newly introduced count variable inside an unexplained when | Case-local it or an explicitly introduced structural binding. |
| Table-first authoring as the canonical form | Expectations first, followed by in table. |
| Comments explaining that textual policy order wins | The first matching case phrase states that behavior directly. |

## 9 Draft grammar and semantic translations

### 9.1 Naming forms

The approved naming direction uses these literal source forms:

~~~text
function "|double the value| (value of type BigInt) -> BigInt is
  value + value
end function

"|double the value| 4
~~~

~~~text
authorization `|authorizes| payment
~~~

The ordinary-name infix form uses the same prefix marker direction:

~~~text
authorization `authorizes payment
~~~

Qualified examples from the naming discussion:

~~~text
payments."|authorizes payment| authorization payment

authorization `payments.|authorizes payment| payment

"|payment services|."|authorizes payment| authorization payment
~~~

A dot outside a delimited name qualifies it. A dot inside its body is part of the name. The complete lexer must define delimiter escapes, malformed names, keyword conflicts, qualified infix names, and legacy paired-backtick migration.

There is one resolved function namespace. Prefix and infix invocation do not declare different functions.

### 9.2 Partial grammar sketch

This sketch records the current direction. “Pending” is an intentional design boundary, not an invitation for an implementer to choose silently.

~~~text
source =
  unit_declaration imports declaration*

declaration =
  function | procedure | signature | law
  | named_record | alternatives
  | refinement | wrapper | indexed_family
  | ability | handler | workflow | actor | model | scenario
  | checked_mapping

function =
  "function" name parameter* "->" type
  requirements? "is" expression "end" "function"

procedure =
  "procedure" name parameter* result? effects?
  "is" procedure_body procedure_close

type_annotation = "of" "type" | "::"

parameter =
  "(" irrefutable_pattern type_annotation type restriction? ")"

law =
  "law" name parameters? requirements? "is"
    law_member*
  "end"

law_member =
  definition_section | scalar_metadata | documentation_section
  | named_example | expectation_table | reference_section

definition_section =
  "definition" ":" obligation "end"

universal =
  "for" "all" binder+
  "=>" proposition "end"

existential =
  "there" "exists" binder+
  "such" "that" proposition "end"

negative_existential =
  "there" "does" "not" "exist" binder+
  "such" "that" proposition "end"

business_existential =
  "there" "must" "exist" article? binder+
  "such" "that" proposition "end"

business_negative_existential =
  "there" "must" "not" "exist" article? binder+
  "such" "that" proposition "end"

business_obligation =
  "given" binder+
  ("when" proposition)?
  "then" normative_proposition

named_record =
  "type" type_name parameters? "is" "a" "record"
    named_field*
  "end" "type"

anonymous_record_type =
  "record" "{" typed_fields "}"

anonymous_record_value =
  "record" "{" value_fields "}"

record_pattern =
  "record" "{" pattern_fields "}"

alternatives =
  "type" type_name parameters? "is" "one" "of"
    alternative+
  "end" "type"

alternative =
  pending_explicit_payload_or_existing_type_member_or_legacy_fields

case_expression =
  "first" "matching" "case" "of" expression ":"
    branch+
    otherwise_branch?
  "end" "case"

branch =
  "when" condition_or_pattern guard? "then" expression

otherwise_branch =
  "otherwise" expression

expectation_table =
  expectation+
  "in" "table" "(" columns ")" ":"
    row+
  "end"
~~~

Exactly one definition section is required for an ordinary law. Supporting sections can be displayed in author order. Multiplicity, fixed header placement, and scalar-versus-block parsing must be completed in the formal grammar.

The grammar must distinguish expressions and patterns without letting a bare unbound name after when silently introduce an unexpected whole-value binder. It must handle quoted and qualified constructor names without relying only on capitalization.

### 9.3 Translation rules

| Surface form | Authoritative meaning |
| --- | --- |
| a followed by the infix marker and f followed by b | Ordinary application f a b, with the same resolution, types, capabilities, and refinements |
| for all binders => P | Nested universal binders in source order |
| there exists binders such that P | Nested existential binders in source order |
| there does not exist binders such that P | Negation of the corresponding existential proposition |
| there must exist binders such that P | The same existential proposition in a normative law context |
| there must not exist binders such that P | Negation of that existential proposition |
| given binders when C then must P | Universally quantified C implies P |
| given binders then must P | Universally quantified P |
| result must = expected or result must be expected | Typed equality of result and expected |
| result must be in collection | Typed membership proposition |
| result must not be in collection | Negation of that membership proposition |
| must not P | Proposition-level negation of P |
| first matching case | Evaluate the selected expression once, test branches in order, and choose the first successful pattern and guard |
| otherwise | Fallback after all preceding branches fail |

Bindings introduced earlier are visible in later binder types and restrictions and in the body. A binder is visible in its own restriction after its base type is established.

For a universal binder restricted by R, R is an antecedent. For an existential binder restricted by R, R is a required part of the witness condition:

~~~text
for all (x of type T where R x) => P x end
  means: for every x in T, R x implies P x

there exists (x of type T where R x) such that P x end
  means: there is an x in T for which R x and P x
~~~

Multiple dependent restrictions must preserve left-to-right scope. Formatting or line breaks must not move one across a quantifier.

### 9.4 Equality and logical scope

The earlier planning preference is one canonical, type-directed = while preserving the existing distinction between a Boolean equality expression and an equality obligation in the semantic representation.

Migration from == must preserve the Boolean context rather than replace characters blindly. Refinement predicates still require Bool. Equality capabilities apply at the actual compared type. Capability checking must continue through nested containers, records, generic functions, and laws.

IEEE equality is not ordinary mathematical reflexivity for NaN. Equality and portable ordering are separate operations; the current Keyed restrictions exclude IEEE floats. The new Eq collection direction must explicitly handle NaN and signed zero. Neither a solver nor a collection implementation may silently substitute ordering for equality.

Logical precedence is not, then and, then or, then right-associative implies. The complete table must place arithmetic, comparison, equality, membership, ordinary application, and named infix application precisely. Ordinary application binds tightly; named infix binds more tightly than logical conjunction and implication. Unparenthesized named-infix chains are rejected under the recorded nonassociative direction.

No infix sections or user-defined fixity system have been approved.

Adjacent lines do not imply conjunction or sequencing. Logical conjunction uses and. Do must not be introduced into quantifiers, pure propositions, refinements, case selection, or declarative business obligations. Any genuinely sequential effect syntax needs its own agreed meaning. Existing local let … in expressions remain distinct from top-level declarations.

### 9.5 Pattern and guard semantics

A successful pattern introduces its variables only in its branch. A guard sees those variables. If the guard is false, matching continues with the next branch. The fallback introduces no wildcard variable.

The accepted guarded layout direction is:

~~~text
when RefundRequest amount #any
  if amount > capturedAmount then
    RejectedExceedsCaptured
~~~

That illustration uses the earlier multi-field constructor form. A one-record payload changes the corresponding pattern and needs an explicit migration.

Record patterns can omit fields. Literal patterns require appropriate typed equality. Repeated bindings, whole-pattern aliases, duplicate fields, overlapping branches, unnecessary fallbacks, and unreachable branches need precise diagnostics.

Exhaustiveness must account for guards, refinements, and GADT indices. A guarded constructor branch does not cover every value of that constructor. An otherwise branch preserves totality but may warrant an optional diagnostic when it hides future constructor additions.

### 9.6 Metadata references and identity

An id field supplies a stable business identity; it does not change the proposition. Owner, rationale, references, effective dates, approval information, and supersession are documentary unless an explicit temporal or applicability relation gives them semantics.

References need typed target identities for laws, checked functions, formal sections, descriptions, rationales, and named or grouped references. Renaming source text must not silently redirect a reference.

Preserve source spans, author-written names, source-to-generated origins, declaration identities, table row identities, expanded reusable-law origins, and evidence links.

## 10 Existing implementation inventory

### 10.1 Snapshot

The inspected checkout is version 0.24.0 at:

~~~text
eff6d7af21d9606c254f626409c4b28d936af588
~~~

At preparation time, a read-only remote query reported the same commit for origin/main. No pull was needed to obtain newer content. The only pre-existing untracked working file was chap06.lawspec; it is user material and is not modified by this export.

The Chapter 6 file contains 703 lines, 23 laws, 25 checked definitions, 7 data types, 2 refinements, 6 tables with 65 rows, and 1 named example. The earlier count of 66 checked cases combines the 65 rows and the named example.

### 10.2 Capabilities already present

| Area | Existing implementation | Redesign implication |
| --- | --- | --- |
| Parsing | Megaparsec parser, legacy keywords and block syntax, lexical whitespace and comments | Extend the real parser and introduce source-preserving syntax support; do not create an independent business parser with weaker semantics. |
| Surface representation | Model types for expressions, typed declarations, constructor fields, laws, examples, and refinements | Reuse and extend this layer where appropriate. |
| Typed semantics | Resolved typed Core, constructors, matches, field operations, and independent validation | All new syntax must reach this boundary. |
| Type elaboration | Generic functions and laws, capabilities, refinements, native contracts, indexed and GADT elaboration | Syntax changes must preserve specialization and obligations. |
| Checked definitions | Exhaustiveness, structural and bounded recursion, definedness, branch facts, refined results | Preserve automatic definition validation for functions and procedures. |
| Law expansion | Reusable law application and substitution | Preserve polymorphism, requirements, capture avoidance, identities, and explanation. |
| Quantified testing | Input generation, boundary cases, refinements, shrinking, finite-domain planning | Add existential strategies without misclassifying searches. |
| Data | Nominal single-constructor products and multi-constructor sums | Named record syntax can lower to existing products. Structural anonymous records and tuples require additional elaboration. |
| Pattern matching | Ordinary match branches use a constructor tag and a flat list of bound names | Nested binding patterns, guards, and the new first-match grammar need real elaboration work. |
| Pattern tests | A separate constructor-pattern matcher already recursively checks nested constructor structure | Useful existing machinery, but not a complete recursive binding-pattern system. |
| Fields | Typed projection and update for known single-constructor data, lowered appropriately for targets | Preserve field refinements and avoid duplicating record semantics. |
| Effects | Abilities, handlers, failures, native adapter effect declarations | Separate pure functions and effectful procedures on the surface while retaining existing contracts. |
| Concurrency | Actors, supervision, sessions, scenarios, workflows, models, temporal contracts | Reuse these semantic engines for business temporal requirements. |
| Evidence | Proof, finite checking, property tests, runtime contracts, measurement, assumptions, harness statuses, environment attestations | Extend provenance and incomplete-result reporting rather than replacing evidence with a binary pass/fail. |
| Code generation | Seventeen target languages and native runtime representations | Every relevant target and schema consumer needs regression coverage. |
| Formatting | Deterministic native generated-code formatting | This is distinct from the proposed canonical LawSpec source formatter. |
| VS Code | TextMate grammar and grammar tests | Upgrade lexical support, then connect compiler diagnostics, navigation, and formatting where supported. |
| GitHub | .gitattributes currently maps LawSpec to Haskell as a fallback | Genuine LawSpec highlighting needs a Linguist-compatible grammar and upstream recognition. |

The ordinary law proposition path currently includes universal binders, equality, Boolean holds, implication with an expression premise, conjunction, and reusable-law invocation. General scoped mixed quantifiers, existential witnesses, and proposition-level negation need extensions.

Current source whitespace processing discards comments and does not supply the lossless representation needed by a canonical formatter. Source trivia preservation is a substantive addition.

### 10.3 Existing type power that must remain

Preserve aliases, refinements, nominal wrappers, constructor constraints, recursive data, indexed families, GADTs, dependent arrows, generic laws, higher-order functions, capabilities, effects, and native contract boundaries.

The current indexed-family design elaborates natural-number indices into erased data, checked measures, and refinements. It must not be replaced by an incompatible new index engine for the sake of prettier syntax.

A baseline indexed example, shown in existing syntax, is:

~~~text
type Vec (n :: Natural) (a :: Type) is
  | VNil where n = 0
  | VCons head :: a tail :: Vec m a where n = m + 1
end
~~~

A GADT constructor can constrain type parameters with where. Matching refines those parameters within the branch. Constructor-local existential type witnesses are a different feature from logical existential propositions.

The current implementation has limitations on matching field-only existential packages and a bounded specialization policy for some recursive GADT definitions. The redesign must inventory and preserve these actual limits or explicitly approve changes; it must not claim unrestricted dependent theorem proving already exists.

### 10.4 Architecture for the redesign

~~~text
Readable source with comments and spans
                 |
                 v
Lossless concrete syntax and surface declarations
                 |
                 v
Resolution desugaring and typed elaboration
                 |
                 v
Authoritative typed Core and validation
                 |
       +---------+---------+----------------+
       |         |         |                |
       v         v         v                v
   Proofs     Testing   Runtime checks   Code generation
       |         |         |                |
       +---------+---------+----------------+
                 |
                 v
Documentation explanations and actual evidence
~~~

Use the existing surface AST and typed Core where they are sufficient. Add a concrete syntax/trivia layer for formatting and source preservation. Do not proliferate parallel semantic ASTs unnecessarily.

Record payload changes may alter constructor arity and schema shape. Anonymous structural products need deterministic identities, nominal boundaries, field mappings, and source origins. Preserve source evaluation order even when a canonical field order is used for type identity.

Evaluating a case’s selected value once does not authorize global deduplication or memoization of independently written native calls. Chapter 6’s repeated-invocation checks must still observe each actual invocation.

Every downstream consumer must handle scoped propositions and products: validation, law expansion, finite enumeration, generators, shrinkers, solver translation, CLI, WebAssembly, API codecs, manifests, and all emitters.

## 11 Existential verification and evidence

### 11.1 Different outcomes that must remain distinguishable

| Outcome | What can be reported |
| --- | --- |
| A checked function constructs a value and its condition is established | A concrete verified witness for the stated input and assumptions |
| A symbolic proof establishes existence for every required input | A proved quantified proposition within the supported proof system |
| Every value of a finite witness domain is searched for one fixed input | A complete existence or nonexistence result for that input and domain |
| Every universal input and witness domain is checked finitely | An exhaustive result for the complete finite proposition |
| A witness is found during bounded testing | A witness for the particular tested input; the universal statement remains property tested |
| A bounded search finds no witness | Inconclusive search, not nonexistence |
| A solver proves no witness under the stated assumptions | Nonexistence within those assumptions and the solver’s supported semantics |
| A solver times out or does not support a construct | Inconclusive or unsupported; never a fabricated proof |

A witness for one generated universal input is not a proof for every universal input.

### 11.2 Constructive witnesses

Reuse ordinary checked functions to supply witnesses. Keep their execution and their proof obligations separate.

A function of type Int32 -> Text may construct an encoding. The separate obligation says that decoding that text recovers the input. Merely returning Text proves neither correctness of the decoder nor the universal round-trip law.

A witness strategy belongs in the testing or proof configuration, not in a hidden alternative meaning for the source proposition. Strategies may be constructive, finite exhaustive, solver-assisted, or bounded.

Dependent witnesses must be generated after the universal values and earlier witnesses they depend on. Shrinking one input requires revalidating or reconstructing dependent witnesses. An invalid shrunk witness is not a counterexample.

### 11.3 Finite domains and empty domains

Exhaustiveness must concern the actual observable domain and its declared bounds, not a convenient quotient formed by Eq or a sampling limit.

Mathematically, a universal proposition over an empty domain is true and an existential over an empty domain is false. Evidence must separately report vacuity and test adequacy. This differs from the current generator policy that rejects or fails empty and unreachable test domains; migration must preserve honest reporting while distinguishing logic from successful test coverage.

Selected tests that discard every generated candidate do not establish useful confidence. Report attempts, accepted cases, discarded cases, boundaries, and the reason for inadequate coverage.

### 11.4 Solver direction

The recorded implementation direction is direct SMT-LIB integration with Z3, explicit assumptions, supported-fragment checks, and provenance. The exact trust and reproducibility contract belongs in the final plan.

Cover exact integers and the agreed numeric families, including rational, decimal, and IEEE semantics, rather than silently replacing them with mathematical real arithmetic. Unsupported higher-order or effectful reasoning reports its limitation.

A satisfying assignment involving uninterpreted native functions is not automatically a real counterexample. Replay against supported concrete semantics or report its assumptions and limits.

The CLI, native API, and WebAssembly host-solver path must agree on protocol and evidence classification. A proof backend is an opt-in layer.

Earlier working defaults were 100 generated cases, 10,000 generation attempts, 1,000 shrink steps, a finite exhaustive limit of 4,096, and a solver budget of 10 seconds. These are configurable planning defaults, not claims that every current command already uses this exact combined profile.

### 11.5 Evidence vocabulary

Preserve proved, exhaustively checked, property tested, runtime checked, measured, assumed or external, known failing, flaky, and skipped distinctions. Keep the existing default-handler provenance where relevant. Add explicit incomplete, unsupported, and not-verified reporting where the redesign requires them.

Evidence is not a single ordered confidence score. A runtime check of a production boundary and a proof about a reference model establish different things.

For each relevant result, expose:

- The source obligation and stable identity.
- Types, refinements, assumptions, and quantifier order.
- Concrete universal inputs and witnesses.
- Whether each domain and search was complete.
- Strategy, limits, seeds, attempts, boundaries, discards, and shrinking.
- Proof backend, supported semantics, and trust assumptions.
- Target language, tool versions, configuration, and code or contract digests.
- Runtime environment and whether dependencies were real or stand-ins.
- The relationship between a reference model and the native adapter under test.

Existing environment attestations record whether tests reached real dependencies or stand-ins. Preserve that information without silently upgrading an evidence status.

### 11.6 Negative existence and temporal claims

To establish no matching authorization or session in a finite collection, the collection must be the complete domain being claimed. A database query with an unexamined page limit is not exhaustive merely because it returned no rows.

For histories, define identity, observation time, causal order, revocation boundaries, retention, and completeness. Open histories may remain pending. A completeness watermark or a bounded observation interval must be explicit.

Preserve existing polling and deadline rounding, including ceiling-based conversions where the current semantics use them, unless an explicit change is approved. Define equality at the deadline, clock granularity, and observation intervals.

An eventuality needs a trace or model semantics and any fairness assumptions. A deadline needs a clock model and boundary rules. Temporal business wording must lower into the current temporal and stateful machinery.

Model checking and implementation conformance remain separate obligations. A proven state machine does not prove that a native payment service follows it.

## 12 Formatting editors and presentation

### 12.1 Canonical source formatter

The CLI provides `lawspec fmt` and `lawspec fmt --check`. Formatting parses
input and output without compiling by default; `--compile` opts into compiler
checks before and after formatting. Mandatory definition validation remains
independent of optional law verification. Syntax-only formatting makes no typed
or verification claim and does not require dependency packages to resolve.
SDK and editor formatting retain their checked default for compatibility.

The owner's 2026-10-22 layout direction uses Haskell-like two-space indentation,
an 80-column target, and separate brace lines for record types, including short
records. Fields occupy separate lines two spaces inside their braces; nested
records add two spaces per level. Independent recoverable parse failures are
reported together across source files, without admitting recovered terms or
writing any file. This applies generally to grammar failures, including repeated
bad constructors, malformed types, expressions, sections and block closers.
Quoted tokens remain opaque while finding resumption points; severe structural
damage can limit recovery. The formatter preserves literal contents,
comments and supported annotation wording. Parser-owned record-type separators
may be omitted; record-value, tuple and pattern separators retain their roles.

Requirements:

- Idempotence and semantic preservation.
- Preserved comments, literal values, literal spellings where meaningful, and source identities.
- Two-space indentation with spaces, a target width of 80 columns, and predictable continuation layout.
- Declaration is, section colons, and the accepted named block closers.
- Correct quantifier scope, such that, and quantifier closing boundaries.
- Preserved named infix style rather than routine conversion to prefix calls.
- Consistent record braces, tuple layout, table alignment, and guarded branches.
- Preservation of intentionally chosen of type or :: forms under the recorded style-preserving direction.
- A deliberate migration path for legacy syntax, distinct from accidental semantic rewriting.

The source formatter uses the authoritative parser inventory in the native and WASM builds. Source and generated-code formatting are documented separately.

### 12.2 Four presentations of one specification

| View | Intended emphasis |
| --- | --- |
| Developer | Signatures, laws, examples, reference models, contracts, and counterexamples |
| Business | Applicability, required behavior, rationale, ownership, references, and the relevant evidence |
| Formal | Resolved types, quantifier order, refinements, expanded reusable laws, assumptions, and obligations |
| Evidence | What was selected, what actually ran, how it concluded, completeness, witnesses, and limitations |

Business prose must be generated from or faithfully linked to the typed obligation. It must not become an independent source of truth.

A business display for authorization could say:

~~~text
PAY-AUTH-001
Captured payments must have authorizations.

Applies to
  Captured payments in the defined payment state.

Required
  A corresponding authorization must be present.

Rationale
  Captured funds must be traceable to authorization.

Evidence
  Verification record with the checked domain and assumptions.
~~~

The display must retain enough links to inspect exactly what “corresponding,” “present,” and “payment state” mean.

### 12.3 Better failures

~~~text
LAW
  Repeated variables retain their allocation.

COUNTEREXAMPLE
  @foo
  @foo

EXPECTED
  0000000000010000
  0000000000010000

ACTUAL
  0000000000010000
  0000000000010001

VIOLATION
  The same symbol received two different RAM addresses.
~~~

For an unsuccessful existential search:

~~~text
OBLIGATION
  Every captured payment has an authorization.

INPUT
  Payment P123

WITNESS SEARCH
  No matching authorization was found within the search budget.

EVIDENCE
  Inconclusive.
  The search was not exhaustive.
~~~

Include source spans, shrunk inputs, witnesses, seeds, budgets, assumptions, and environmental provenance when available. A failed example, a refuted law, an incomplete witness search, and a compiler rejection need distinct explanations.

### 12.4 VS Code and language services

Update syntax highlighting, grammar tests, outlines, diagnostics, formatting integration, hover/type information, references, and semantic navigation where supported.

Prefer compiler-backed resolution and diagnostics to a second implementation of type rules in the editor. Preserve source origins after desugaring. Account for editor coordinate conventions, including UTF-16 positions.

The current TextMate grammar is not sufficient to provide all of these services.

### 12.5 GitHub highlighting

The repository currently contains:

~~~text
*.lawspec linguist-language=Haskell
~~~

That is a fallback, not native LawSpec highlighting.

The intended work is a shared, appropriately licensed TextMate grammar, representative samples and tests, and a contribution to GitHub Linguist when its eligibility requirements can be met. Upstream recognition, extension usage requirements, and deployment timing are external dependencies that must be checked rather than promised.

Keep highlighting meaningfully consistent between VS Code and GitHub. Avoid presenting another language’s grammar as a complete match for LawSpec. No change to the chat application’s renderer is implied by this repository work.

The upstream contribution policy is at:

https://github.com/github-linguist/linguist/blob/main/CONTRIBUTING.md

## 13 Required demonstration portfolio

### 13.1 Chapter 6 assembly source to Hack binary

Migrate the actual chap06.lawspec, retaining all meaningful behavioral obligations.

The baseline includes:

- ADTs for computation, destination, jump, predefined symbols, source lines, layout, and repeated runs.
- Address and user-symbol refinements.
- Checked textual and binary encodings.
- Recursive reference models, label scanning, variable allocation, and symbol resolution.
- Universal laws, 6 data tables, and a named example.
- Decimal interpretation of leading zeroes, whitespace and comment invariants, line endings, labels, and case sensitivity.
- Independent repeated invocations, so symbol tables and allocation counters cannot leak between calls.
- External-oracle checks against published Hack encodings, not merely agreement between two functions derived from one table.

The recorded plan tests all 32,768 A-instruction addresses and 1,792 combinations of C-instruction fields. Use independent oracles and meaningful mutants.

First establish mechanical semantic equivalence. Then improve readability using accepted mappings and conveniences. Do not silently lose a law while shortening the example.

Chapter 6’s assembly-source-to-binary program is to be implemented and verified in all 17 supported languages:

Java, Python, JavaScript, TypeScript, Go, Haskell, Kotlin, Rust, Erlang, Elixir, Gleam, F#, C#, Scala, Groovy, Clojure, and Swift.

### 13.2 Remaining Nand2Tetris software projects

The selected seven featured languages are:

**Java, Python, TypeScript, F#, Rust, Elixir, and Clojure.**

Use all seven for the VM translator in Projects 7–8 and the Jack syntax analysis/compiler work in Projects 10–11. The user explicitly expanded the original request for three languages to all seven.

The broader recorded portfolio covers the software projects from 6 through 12. Hardware Projects 1–5 are outside this particular scope.

Project 9 is a Jack Snake demonstration: a 32 by 15 playfield below a status area, initial length 3, injected input/time/randomness, reversal restrictions, food, growth, collision, score, pause, restart, quit, and headless tests.

Project 12 covers the full public Jack OS API. Verification must not pass merely by silently falling back to missing native or built-in OS implementations.

Language coverage beyond the explicitly selected VM/compiler seven must be transcribed into the final portfolio matrix rather than inferred from an example.

### 13.3 Codec and reusable laws

Provide both a direct round-trip law and an application of the existing inverse-law abstraction.

~~~text
unit example.codec

encode of type Int32 -> Text
decode of type Text -> Int32

law "|encoding round trips| is
  definition:
    for all (value of type Int32) =>
      decode (encode value) = value
    end
  end
end
~~~

Preserve parameter order in reusable-law application. In the existing prelude, left inverse is declared with the outer inverse function first and the inner function second; do not assume order from English argument names.

The recorded new application direction is apply law followed by the resolved law and its declared-order arguments. Capture-avoiding substitution, specialization, capability requirements, expanded obligations, and evidence must be preserved.

### 13.4 Existence and business authorization

Provide:

1. An encoding witness built by a checked function and verified against decoding.
2. A complete authorization domain with payments, authorization identities, explicit state, and a meaningful matching relation.
3. A witness strategy constrained to the actual state or observed collection.
4. A false case with no authorization.
5. A bounded unsuccessful search reported as inconclusive.
6. A complete finite-domain refutation or proof where applicable.

For captured payments, define the operation or reachable state that makes a payment captured. Do not “prove” authorization by filtering inputs with the authorization requirement itself.

### 13.5 Revocation and histories

Define credentials, sessions, authentication, revocation, active status, time boundaries, state/history completeness, and the actual domain searched.

Demonstrate both a complete snapshot nonexistence result and an incomplete or open-history observation. Preserve the distinction between an invariant, a bounded history property, and an unbounded future requirement.

### 13.6 Policy classification and conflicts

Demonstrate ordinary function cases with otherwise, guarded priority, complete typed results, and a law requiring conformance.

Also demonstrate:

- Two simultaneously applicable requirements with compatible results.
- A proven contradiction for a concrete input, such as a zero-boundary refund receiving mutually exclusive required results.
- A suspected overlap that the selected analysis cannot resolve.
- A partial law that is valid within its stated scope.
- Opt-in completeness analysis showing an uncovered input without treating the partial law itself as refuted.

The earlier decision-table requirements survive as function classification, law applicability, and optional analysis. Removing the top-level decision declaration must not silently remove their substance.

### 13.7 Stateful order workflow

~~~text
Received -> Validated -> Authorized -> Captured -> Fulfilled
~~~

Include invalid transitions, failures, allowed cancellation paths, temporal obligations, and implementation conformance. Reuse the current stateful model and workflow machinery.

State which transitions require authorization, which errors leave state unchanged, and which guarantees need fairness or deadlines. A model proof and a native integration test require distinct evidence.

### 13.8 Advanced type regressions

Exercise indexed vectors, GADT index refinement, dependent refinements, generic reusable laws, checked recursion, higher-order functions, capabilities, and effectful procedures.

Keep existentially packaged data separate from existential propositions. Include the actual existing implementation limits in regression expectations.

### 13.9 Existing library demonstrations

Earlier planning also selected public-API specification and documentation exercises for these pinned library versions:

| Library | Recorded version | Recorded license |
| --- | --- | --- |
| fast-json-patch | 3.1.1 | MIT |
| cachetools | 7.2.1 | MIT |
| shopspring/decimal | 1.5.0 | MIT |
| NimbleOptions | 1.1.1 | Apache-2.0 |
| semver | 1.0.28 | MIT or Apache-2.0 |

These are historical planning pins, not a claim about today’s latest release or a completed license audit. Revalidate the pinned source and license before implementation or distribution.

Cover the full selected public API with documentation and independently selectable guarantees. Do not require every library user to adopt the strongest verification profile.

### 13.10 Before and after a Chapter 6 law

Legacy excerpt:

~~~text
law `A instructions encode every fifteen bit address` is
  definition is
    `for all` (address :: Address) .
      assemble ("@" ++ prelude.textOf address) = [binary16 (prelude.BigUInt (address))]
  end
  table (address, expected) is
    row 0, ["0000000000000000"]
    row 1, ["0000000000000001"]
    row 32767, ["0111111111111111"]
    expect assemble ("@" ++ prelude.textOf address) = expected
  end
end
~~~

The legacy law returns a list of output lines and explicitly widens the address to BigUInt. A faithful migration retains the singleton-list result and the Address restriction. Removing the explicit conversion relies on the agreed proven-lossless widening behavior.

Preferred presentation of the complete law structure, using helpers supplied by the full migrated specification:

~~~text
law "|A instructions encode every fifteen bit address| is
  definition:
    for all (address of type Address) =>
      assemble ("@" ++ textOf address) = [binary16 address]
    end
  end

  description:
    "Every A-instruction encodes its address as a
     sixteen-bit binary word."
  end

  rationale:
    "The Hack architecture reserves fifteen bits for
     the address and uses a leading zero bit."
  end

  example "|eight is decimal despite leading zeroes|:
    address = 8
    expect assemble "@0008" = ["0000000000001000"]
  end

  expect assemble ("@" ++ textOf address) = expected
  in table (address, expected):
    row 0, ["0000000000000000"]
    row 1, ["0000000000000001"]
    row 32767, ["0111111111111111"]
  end

  references:
    "Nand2Tetris Chapter 6"
    "Hack machine-language specification"
  end
end
~~~

This example separates formal meaning, explanation, rationale, a named example, a checked table, and references. It incorporates the later quantifier end, name markers, worded annotations, and expectation-first table direction.

## 14 Implementation phases and release criteria

### 14.1 Phase A language design

Complete the inventory, resolve the genuinely open choices, record approved decisions, and produce the complete canonical grammar and semantic translations.

Required design outputs:

- Existing grammar and capability inventory.
- Proposed canonical grammar.
- Before-and-after examples.
- Approved, unresolved, and superseded decision ledger.
- Syntax-to-semantics rules, including scopes and source origins.
- Parser and elaborator plan.
- Compatibility and migration plan.
- Formatter design.
- Business-rule authoring design using laws.
- Existential verification and evidence design.
- Testing matrix.
- Dependency-ordered pre-1.0 phases.
- Acceptance criteria, including real-reader comprehension.

Implementation of the language begins only after the complete design is discussed and approved. This review-file export is documentation work.

### 14.2 Phase B canonical grammar and typed elaboration

Implement the accepted name forms, annotations, declaration/section conventions, law authoring, scoped quantifiers, named infix calls, record and tuple syntax, explicit alternative payload rules, first-match cases, guards, wildcard forms, and diagnostics.

Preserve spans, nominal identities, refinements, GADT facts, capabilities, automatic totality guarantees, reusable-law expansion, and ordinary application semantics.

### 14.3 Phase C existential verification

Add authoritative scoped propositions, negation, dependent witnesses, constructive strategies, finite exhaustive checking, bounded search, solver integration, witness shrinking, and accurate incomplete-result reporting.

Support mixed quantifier order rather than flattening every binder into one list of generated inputs.

### 14.4 Phase D business obligations and model integration

Implement given/when/then and must forms inside laws, membership and existence obligations, documentary metadata, classification via functions, conformance laws, overlap/conflict/completeness analysis, temporal integration, and traceability.

Avoid a second runtime rule interpreter or a second temporal engine.

### 14.5 Phase E ergonomic features

Implement the agreed general finite mappings, encoding derivations, numeric literals, exact widening, membership collection semantics, and import/prelude resolution.

Current preference is a general checked finite mapping abstraction, not a separate encoding-specific execution mechanism.

A mapping must specify:

- Typed domain and columns.
- Coverage, duplicates, and optional uniqueness.
- Bit widths and numeric bounds.
- Derived lookups and partial Maybe results.
- Valid inverses or preimages when uniqueness does not hold.
- Deliberate handling of combined column values.
- Integration with checked definitions.

Deriving two functions from one table establishes consistency with that table, not agreement with an external architecture standard.

### 14.6 Phase F tooling

Deliver the source formatter, migration diagnostics, the four presentation views, counterexamples, generator and witness explanations, documentation generation, editor integration, and the GitHub grammar contribution work.

Use stable typed identities, source links, reproducible evidence, and actual-run provenance across CLI, native API, and WebAssembly.

### 14.7 Phase G migration and release

Migrate real specifications, validate semantic correspondence, run every relevant target suite, test published documentation, evaluate comprehension, close the approved scope, and freeze the canonical grammar.

The earlier compatibility direction is a canonical breaking transition with a separate legacy parser and migrator. Exact command names, version boundary, and failure behavior still need final specification.

Do not leave a permissive parser that silently assigns different meanings based on whichever legacy or new branch happens to succeed.

### 14.8 API and schema migration

Earlier planning recorded a schema-5 boundary, migration from schemas 3 and 4, and a version-2 checking configuration that can explicitly select no verification layers. Confirm these concrete version choices against every current consumer before implementing them.

Under that direction, normal canonical requests accept schema 5; versions 3 and 4 use the explicit migration path rather than silent compatibility. An empty layers selection is the intended no-optional-verification baseline. Final wire fields and diagnostics must be specified together with their consumers.

Keep CLI, native bindings, generated adapters, JavaScript APIs, WebAssembly, evidence codecs, public contract manifests, and generated schemas synchronized.

Changing constructor payloads to records requires a stated correspondence between old and new values, not merely ignoring differences in a comparison of syntax trees.

### 14.9 Testing matrix

| Area | Required checks |
| --- | --- |
| Lexing | Colon versus ::, name markers, multiword keyword boundaries, comments, strings, record braces, and qualified names |
| Parsing | Every canonical section, scalar metadata, quantifier closers, nested quantifiers, guards, otherwise placement, tuple/record recursion, and selected legacy errors |
| Typed semantics | Prefix/infix equivalence, business/formal lowering, equality contexts, dependent scopes, refinements, nominal identities, capabilities, and GADT branch facts |
| Law expansion | Generic specialization, alpha-renaming, capture avoidance, declared parameter order, spans, assumptions, and evidence |
| Examples | Standalone checks, multiple table expectations, independent row failures, typed inputs, recorded values, negative compiler fixtures, and stable identities |
| Existence | Constructed witnesses, finite complete domains, bounded misses, refutations, nested dependent witnesses, shrinking, and negative existence |
| Solver | Supported arithmetic semantics, assumptions, unknown/timeouts, unsupported effects and higher-order terms, and concrete replay where required |
| Adoption | Each verification layer independently selected; no-layer baseline; selected required incomplete result; reasoned exemptions |
| Patterns | Tuple and record nesting, constructor payloads, ignored fields, bindings, guards, reachability, exhaustiveness, and optional diagnostics |
| Mapping | Coverage, duplicates, uniqueness, partial lookup, inverse validity, bounds, and independent external oracle tests |
| Models | Valid/invalid transitions, reachable-state invariants, native conformance, history completeness, deadlines, fairness, and open traces |
| Code generation | All relevant behavior across all 17 targets and supported native representations |
| Formatter | Idempotence, comments, literal values, semantic preservation, name style, infix style, scopes, and canonical migration output |
| Editor | Grammar samples, diagnostics, source positions, outlines, hover, navigation, references, and formatting |
| Documentation | Published executable examples parse and typecheck after implementation, and run where applicable |
| Readability | Outcome predictions, scope comprehension, missing-case recognition, evidence interpretation, and preference tested separately |

For syntax-only migration, compare typed declarations, scopes, refinements, expanded laws, obligations, test plans, adapter dependencies, evidence classification, and generated behavior. For approved representation changes, compare through an explicit typed migration correspondence.

### 14.10 Acceptance gates

- The canonical grammar is decision complete and its public examples are validated.
- Business readers can explain required behavior, applicability, priority, and evidence with measured comprehension.
- Declarations and sections follow the agreed convention.
- Function, procedure, ability, record, tuple, and alternative roles are distinguishable.
- Mixed quantifiers preserve scope and order.
- Existential results distinguish complete evidence from incomplete searches.
- Prefix and infix invocation elaborate identically.
- Pattern matching preserves typing and automatic totality guarantees.
- Business obligations share the typed semantic system.
- Progressive adoption works without mandatory maximal proof.
- General mappings and numeric/collection improvements satisfy the agreed semantics.
- Formatting and editor support preserve source meaning.
- Migration preserves obligations and explicitly handles representation changes.
- Every relevant target suite and demonstration passes.
- Documentation, evidence views, counterexamples, and domain explanations are complete.
- External highlighting dependencies are explicitly resolved or brought back for an approved release decision.
- No agreed feature is silently moved beyond 1.0.

The exact numerical readability thresholds should be agreed before using the study results to claim success.

## 15 Complete remaining design agenda

This section preserves all 62 original agenda items and then adds the questions introduced by the later example review. “Closure” means finish the grammar or implementation contract without reopening the accepted direction merely for aesthetic debate.

### 15.1 Original agenda A sections and declarations

| Question | Current position and remaining closure |
| --- | --- |
| Q01 Exact colon-section grammar | Approved convention; finish unambiguous delimiters and section boundaries. |
| Q02 Whether all metadata uses sections | Multiline documentation uses sections; simple scalar metadata uses one value. Finish the full inventory. |
| Q03 Scalars versus blocks | Approved distinction; specify allowed value shapes and how the parser rejects ambiguity. |
| Q04 Definition inside business requirements | Retained; business requirements now use law rather than a separate rule declaration. |
| Q05 Given and when clauses or sections | Approved clauses inside definition:, with then introducing the normative obligation. |
| Q06 Ordering and multiplicity | Exactly one authoritative definition; specify duplicate-section errors and legal metadata placement. |
| Q07 Legacy section migration | Recorded breaking transition with a separate migrator; finish release boundary, diagnostics, and semantic checks. |

### 15.2 Original agenda B logical expressions

| Question | Current position and remaining closure |
| --- | --- |
| Q08 Proposition versus Boolean equality | Recorded type-directed = preference; preserve semantic distinctions, capabilities, and == migration. |
| Q09 Universal scope | Approved quantifier scope with later explicit end; finish grammar and negative cases. |
| Q10 Existential scope | Approved such that and dependent scoped binders; preserve mixed order. |
| Q11 Negation | Approved not and negative existence forms; finish proposition grouping and Boolean interaction. |
| Q12 Conjunction and implication precedence | Recorded logical order; consolidate the complete operator table. |
| Q13 Dependent binders | Left-to-right visibility; finish index and refinement interactions. |
| Q14 Quantified refinements | Universals restrict by implication; existentials require the restriction conjunctively. |

### 15.3 Original agenda C infix functions

| Question | Current position and remaining closure |
| --- | --- |
| Q15 Precedence | Application binds tightly and named infix precedes logical operators; record the complete arithmetic/comparison interaction. |
| Q16 Associativity | Recorded nonassociative chains require parentheses. |
| Q17 Qualified names | Same resolution as prefix calls; complete exact name-token and error rules. |
| Q18 Partial application | Ordinary partial application remains; infix sections are not approved. |
| Q19 Symbolic operators | Retain documented semantics; finish exact mixed-expression examples. |
| Q20 Formatting | Preserve infix authoring style and source meaning. |
| Q21 Legacy backticks | Migrate legacy law names and paired forms into the unified marker convention explicitly. |

### 15.4 Original agenda D pattern matching

| Question | Current position and remaining closure |
| --- | --- |
| Q22 Case grammar | First matching case of expression: … end case is the current accepted direction. |
| Q23 Guards | Accepted guarded branches; finish scope, evaluation, layout, and interaction with conditional expressions. |
| Q24 Exhaustiveness | Preserve guarantees when selected; account for guards and refinements. |
| Q25 Nested patterns | Recursive direction accepted; record payload changes and all binding forms still need a final grammar. |
| Q26 GADT refinement | Preserve actual indexed branch environments and existing package limitations. |
| Q27 Unnecessary fallback diagnostics | Optional diagnostic direction; define scope and severity without making it an adoption barrier. |

### 15.5 Original agenda E existential verification

| Question | Current position and remaining closure |
| --- | --- |
| Q28 Constructive witnesses | Reuse checked functions; prove or check their witness conditions separately. |
| Q29 Witness-generating definitions | Avoid another execution mechanism; specify strategy configuration and dependencies. |
| Q30 Solver integration | Recorded Z3/SMT-LIB direction; finish protocol, supported semantics, assumptions, trust, and replay. |
| Q31 Finite domains | Define completeness precisely over actual values and bounds. |
| Q32 Bounded search | A miss is inconclusive; finish budgets, reporting, and exit behavior for selected checks. |
| Q33 Negative existence | Approved language direction; complete state/history domains and evidence. |
| Q34 Evidence classification | Preserve existing distinctions and add explicit incomplete/not-selected outcomes. |
| Q35 Existential types | Keep packaged data distinct from propositions; preserve and document current witness restrictions. |

### 15.6 Original agenda F business requirements

| Question | Current position and remaining closure |
| --- | --- |
| Q36 Rule grammar | Superseded as a separate declaration; all required behavior uses law. |
| Q37 Given semantics | Universal inputs in definition:. |
| Q38 When applicability | Antecedent restricting when the obligation applies. |
| Q39 Must and must not | Approved obligation and negation semantics; finish legal expression positions. |
| Q40 Existential obligations | Same existential proposition as the formal form, under law inputs and applicability. |
| Q41 State/history domains | High-priority open business meaning: actual collection, reachability, identity, and completeness. |
| Q42 Decision-table semantics | Ordered classification via functions plus conformance laws; simultaneous law applicability remains conjunctive. |
| Q43 Conflict/completeness | Opt-in, with proved findings distinct from heuristic or unresolved analysis. |
| Q44 Temporal integration | Reuse current machinery; define clocks, fairness, open traces, deadlines, and native conformance. |
| Q45 Metadata | Documentary by default; finish field types, versions, dates, supersession, and lifecycle. |
| Q46 Traceability | Stable identities and links across source, expansion, tests, native calls, and evidence. |

### 15.7 Original agenda G ergonomics and tooling

| Question | Current position and remaining closure |
| --- | --- |
| Q47 Declarative encodings | Recorded preference for general checked mappings; retain the original encoding proposal for comparison. |
| Q48 General finite mappings | Finish declaration spelling, coverage, duplicates, uniqueness, derivations, and partial/inverse APIs. |
| Q49 Numeric conversions | Only proven-lossless exact widening; specify capability and nominal-boundary behavior. |
| Q50 Membership | Primitive #S and Eq collection direction; resolve the current Keyed representation conflict and floating equality. |
| Q51 Imports/prelude | Deterministic fallback and explicit conflict diagnostics; finalize lookup priority. |
| Q52 Formatter | Lossless source representation, canonical layout, semantic preservation, and migration policy. |
| Q53 Explanation views | Developer, business, formal, evidence; finish CLI/API interfaces without changing meaning. |
| Q54 Counterexamples | Obligation-specific expected/actual violations with origins and reproducibility. |
| Q55 Generator diagnostics | Domains, accepted/discarded cases, boundaries, witnesses, limits, and incompleteness. |
| Q56 Editor support | Shared grammar, compiler services where supported, and genuine GitHub highlighting with external dependencies. |

### 15.8 Original agenda H delivery

| Question | Current position and remaining closure |
| --- | --- |
| Q57 Compatibility policy | Recorded canonical break and separate legacy path; finalize the exact boundary. |
| Q58 Migration tools | Typed transformation and explicit failures, not regular-expression replacement alone. |
| Q59 Equivalence tests | Compare semantic obligations and behavior, using a correspondence for representation changes. |
| Q60 Dependencies | Design before coding; typed front end before downstream consumers; complete all approved pre-1.0 scope. |
| Q61 Readability evaluation | Actual readers and outcome prediction; agree objective success thresholds. |
| Q62 Release gates | Complete agreed scope, demonstrations, all targets, docs, tooling, and an explicit resolution of external blockers. |

### 15.9 Additional questions from the example review

| Question | Why it matters and what remains open |
| --- | --- |
| N01 Alternative tag versus payload type | Decide between explicit of type payloads, direct existing-type members, and retaining constructor fields. |
| N02 Bare existing types versus data-free cases | An existing declaration or forward reference must not silently change what a bare alternative means. |
| N03 Named record construction | Decide how a value is constructed, whether the type name prefixes record{…}, and how nominal boundaries are enforced. |
| N04 Constructor and type name collisions | An Email record type and an Email union alternative need a coherent namespace and invocation policy. |
| N05 Anonymous record separators | Decide commas, optional trailing commas, empty records, and multiline layout without newline-sensitive meaning. |
| N06 Record field identity | Finalize closed structural identity, field order, duplicate/unknown fields, and whether any subtyping is permitted. |
| N07 Record patterns | Decide explicit labels, puns, omitted fields, repeated bindings, whole-pattern aliases, and literal field patterns. |
| N08 Nested it | Define shadowing, outer references, and interactions with ordinary identifiers and existing generator it. |
| N09 Purity versus totality | Resolved for RC1: functions are pure, procedures use effects; intrinsic definition checks remain automatic. Only law verification layers are optional. |
| N10 No-verification behavior | Decide exactly which semantic refutations are optional analysis and which intrinsic declaration errors remain mandatory. |
| N11 Name escapes | Define pipes, delimiters, Unicode, qualified spaced segments, malformed markers, and migration diagnostics. |
| N12 Type wording and domain units | Test Natural, bounded numbers, exact values, money units, and of type with business readers. |
| N13 Pattern versus condition after when | Define bare constructors, Bool literals, bound Bool names, function calls, and when it matches without accidental binding. |
| N14 Parameter patterns | Finalize irrefutability, nested record/tuple syntax, aliases, and diagnostic wording. |
| N15 Explicit payload representation | Moving multiple constructor fields into a record changes arity, schemas, native APIs, and dependent-field scope. |
| N16 Exact nesting count | Distinguish three domain layers from three structural type nodes when union payloads are records. |
| N17 Eq sets | Decide how primitive sets interact with Keyed storage, Eq-only elements, NaN, signed zero, and deterministic iteration. |
| N18 Optional the and is | Define their precise contextual grammar and disambiguation from ordinary functions or identifiers with those names. |
| N19 Named closers | Decide whether and how procedure, law, ability, sections, refinements, and quantifiers receive labels. |
| N20 Prohibited filenames | Finish the rejection example, full Unicode caseFold semantics, any, partial contains, tests, and priority. |
| N21 Domain completeness | Define what “all authorizations” or “sessions after revocation” actually observes, including paging and retention. |
| N22 Native naming | Define predictable ThisCase, thisCase, and this_case mappings, Unicode/acronyms, collisions, and public API stability. |
| N23 Effect annotations | Clarify uses inference versus explicit declaration, ability selection, pure calls, failure effects, and handler boundaries. |
| N24 Reader punctuation feedback | Recover the exact example and mark that caused the “period” comment before changing punctuation. |
| N25 Example numbering | Preserve known examples such as 48, 49, and 50; use stable review IDs for reconstructed examples rather than inventing an exact historical transcript. |
| N26 External highlighting gate | Check upstream eligibility and deployment timing, and make any release consequence an explicit decision. |

### 15.10 Options retained for ergonomics

The original specialized encoding proposal was:

~~~text
encoding Comp is
  CZero represents "0" as 0b0101010
  COne represents "1" as 0b0111111
  CMinusOne represents "-1" as 0b0111010
end
~~~

This remains a comparison example rather than the accepted canonical declaration. The recorded preference is general checked finite mappings, which can cover this use without a separate execution mechanism.

Other alternatives to keep visible:

- Named record dimensions versus a tuple in a picture.
- Of type versus ::, with a style-preserving formatter.
- Ordinary identifiers versus spaced names.
- #any versus _.
- Explicit it matches versus a recognizable short pattern.
- A constructive witness versus finite or bounded search of the same proposition.
- A policy function with prioritized cases versus multiple simultaneously applicable obligations.
- Explicit named record payloads versus inline anonymous payloads.
- Existing-type union members versus explicit tag/payload declarations.
- Concise examples versus full checked tables; do not add another table syntax merely to save punctuation.
- Current refinement spelling versus a friendlier binder-and-where block, without changing its semantics.
- Selected static checking versus runtime contracts where the actual guarantee permits that choice.

For imports, the preferred direction is unqualified textOf when deterministic resolution finds the prelude function unambiguously. Explicit prelude.textOf remains available.

For numeric literals, 0b0101010 and 0x2A are the desired forms, contextually typed without silent narrowing or floating-point conversion.

For widening, binary16 address should not need an unnecessary conversion if the source range is proved representable. A nominal identifier wrapper is not automatically interchangeable with its underlying number.

For collections, the current Set and KeyVal key representation requires Keyed; IEEE floats and Symbols are not currently Keyed. The requested Eq-based membership and primitive set direction therefore requires a deliberate design. In particular, a NaN is not equal to itself under IEEE equality, so ordinary set-law assumptions cannot be asserted without choosing the precise policy.

The final grammar must state each choice. A future implementer should not infer approval merely because one option was easier to code.




## 16 Eight combinations of three nested layers

**Earlier union-field candidate, updated to the latest record braces.** Canonical executable counterparts now live in `examples/rc1/nesting/`; these historical snippets preserve the earlier comparison set. The user subsequently questioned the union-field declaration style; it is under review rather than a final canonical choice. Section 16.10 illustrates the explicit-payload proposal for comparison.

Each block is an independent unit. Read its three letters from outside inward: delivery, document, file. R means a record and U means a union. Primitive fields do not count as another structured layer.

At a record layer, the model represents the particular kind directly: EmailDelivery, Invoice, or PdfFile. At a union layer, it additionally represents Download, Letter, or PlainText. Consequently the eight models permit different values; they are not eight semantically interchangeable spellings.

The function returns the filename of a PDF invoice delivered by email. Present contains a qualifying filename. Absent means a different alternative was selected. A record pattern selects fields by name; a union constructor pattern selects the tag and matches its positional fields in this earlier candidate.

| Example | Delivery | Document | File |
| --- | --- | --- | --- |
| 1 RRR | Record | Record | Record |
| 2 RRU | Record | Record | Union |
| 3 RUR | Record | Union | Record |
| 4 RUU | Record | Union | Union |
| 5 URR | Union | Record | Record |
| 6 URU | Union | Record | Union |
| 7 UUR | Union | Union | Record |
| 8 UUU | Union | Union | Union |

### 16.1 RRR

Every input already represents an emailed PDF invoice. The record pattern is exhaustive, so no fallback is necessary.

~~~text
unit example.delivery.rrr

type PdfFile is a record
  fileName of type Text
  byteCount of type Natural
end type

type Invoice is a record
  number of type Text
  file of type PdfFile
end type

type EmailDelivery is a record
  recipient of type Text
  document of type Invoice
end type

function "|email invoice PDF file name|
  (delivery of type EmailDelivery) -> Maybe Text
is
  first matching case of delivery:
    when record{
      document: record{
        file: record{
          fileName: name
        }
      }
    } then
      Present name
  end case
end function
~~~

### 16.2 RRU

The file may instead be PlainText. That alternative reaches Absent.

~~~text
unit example.delivery.rru

type File is one of
  | Pdf
      fileName of type Text
      byteCount of type Natural
  | PlainText fileName of type Text
end type

type Invoice is a record
  number of type Text
  file of type File
end type

type EmailDelivery is a record
  recipient of type Text
  document of type Invoice
end type

function "|email invoice PDF file name|
  (delivery of type EmailDelivery) -> Maybe Text
is
  first matching case of delivery:
    when record{
      document: record{
        file: Pdf name #any
      }
    } then
      Present name

    otherwise Absent
  end case
end function
~~~

### 16.3 RUR

The document may instead be a Letter. The selected invoice contains a PdfFile record.

~~~text
unit example.delivery.rur

type PdfFile is a record
  fileName of type Text
  byteCount of type Natural
end type

type Document is one of
  | Invoice
      number of type Text
      file of type PdfFile
  | Letter file of type PdfFile
end type

type EmailDelivery is a record
  recipient of type Text
  document of type Document
end type

function "|email invoice PDF file name|
  (delivery of type EmailDelivery) -> Maybe Text
is
  first matching case of delivery:
    when record{
      document: Invoice #any (record{
        fileName: name
      })
    } then
      Present name

    otherwise Absent
  end case
end function
~~~

### 16.4 RUU

Both document kind and file format are choices. The pattern accepts Invoice containing Pdf.

~~~text
unit example.delivery.ruu

type File is one of
  | Pdf
      fileName of type Text
      byteCount of type Natural
  | PlainText fileName of type Text
end type

type Document is one of
  | Invoice
      number of type Text
      file of type File
  | Letter file of type File
end type

type EmailDelivery is a record
  recipient of type Text
  document of type Document
end type

function "|email invoice PDF file name|
  (delivery of type EmailDelivery) -> Maybe Text
is
  first matching case of delivery:
    when record{
      document: Invoice #any (Pdf name #any)
    } then
      Present name

    otherwise Absent
  end case
end function
~~~

### 16.5 URR

The outer choice distinguishes Email from Download. Both inner structures are records.

~~~text
unit example.delivery.urr

type PdfFile is a record
  fileName of type Text
  byteCount of type Natural
end type

type Invoice is a record
  number of type Text
  file of type PdfFile
end type

type Delivery is one of
  | Email
      recipient of type Text
      document of type Invoice
  | Download document of type Invoice
end type

function "|email invoice PDF file name|
  (delivery of type Delivery) -> Maybe Text
is
  first matching case of delivery:
    when Email #any (record{
      file: record{
        fileName: name
      }
    }) then
      Present name

    otherwise Absent
  end case
end function
~~~

### 16.6 URU

The outer and inner choices are independent. The middle invoice remains a record.

~~~text
unit example.delivery.uru

type File is one of
  | Pdf
      fileName of type Text
      byteCount of type Natural
  | PlainText fileName of type Text
end type

type Invoice is a record
  number of type Text
  file of type File
end type

type Delivery is one of
  | Email
      recipient of type Text
      document of type Invoice
  | Download document of type Invoice
end type

function "|email invoice PDF file name|
  (delivery of type Delivery) -> Maybe Text
is
  first matching case of delivery:
    when Email #any (record{
      file: Pdf name #any
    }) then
      Present name

    otherwise Absent
  end case
end function
~~~

### 16.7 UUR

Email must contain Invoice. The PDF filename is then read from a record.

~~~text
unit example.delivery.uur

type PdfFile is a record
  fileName of type Text
  byteCount of type Natural
end type

type Document is one of
  | Invoice
      number of type Text
      file of type PdfFile
  | Letter file of type PdfFile
end type

type Delivery is one of
  | Email
      recipient of type Text
      document of type Document
  | Download document of type Document
end type

function "|email invoice PDF file name|
  (delivery of type Delivery) -> Maybe Text
is
  first matching case of delivery:
    when Email #any (Invoice #any (record{
      fileName: name
    })) then
      Present name

    otherwise Absent
  end case
end function
~~~

### 16.8 UUU

All three choices are explicit. Only Email containing Invoice containing Pdf matches the first branch.

~~~text
unit example.delivery.uuu

type File is one of
  | Pdf
      fileName of type Text
      byteCount of type Natural
  | PlainText fileName of type Text
end type

type Document is one of
  | Invoice
      number of type Text
      file of type File
  | Letter file of type File
end type

type Delivery is one of
  | Email
      recipient of type Text
      document of type Document
  | Download document of type Document
end type

function "|email invoice PDF file name|
  (delivery of type Delivery) -> Maybe Text
is
  first matching case of delivery:
    when Email #any (Invoice #any (Pdf name #any)) then
      Present name

    otherwise Absent
  end case
end function
~~~

### 16.9 Values and results for UUU

These values use the earlier positional-field constructor candidate from Example 8.

~~~text
expect "|email invoice PDF file name|
  (Email "alex@example.com"
    (Invoice "INV-42"
      (Pdf "invoice.pdf" 24000)))
  = Present "invoice.pdf"

expect "|email invoice PDF file name|
  (Download
    (Invoice "INV-42"
      (Pdf "invoice.pdf" 24000)))
  = Absent

expect "|email invoice PDF file name|
  (Email "alex@example.com"
    (Letter (Pdf "letter.pdf" 12000)))
  = Absent

expect "|email invoice PDF file name|
  (Email "alex@example.com"
    (Invoice "INV-42"
      (PlainText "invoice.txt")))
  = Absent
~~~

The three ignored values in the successful deep pattern are the recipient, invoice number, and PDF byte count. The filename is the bound value.

### 16.10 UUU with explicit named record payloads

**Preferred proposal, awaiting approval.** This is the proposed alternative to implicit constructor fields. It has three domain layers and additional explicit payload-record nodes.

~~~text
unit example.delivery.explicitPayloads

type PdfDetails is a record
  fileName of type Text
  byteCount of type Natural
end type

type File is one of
  | Pdf of type PdfDetails
  | PlainText of type Text
end type

type InvoiceDetails is a record
  number of type Text
  file of type File
end type

type Document is one of
  | Invoice of type InvoiceDetails
  | Letter of type File
end type

type EmailDetails is a record
  recipient of type Text
  document of type Document
end type

type Delivery is one of
  | Email of type EmailDetails
  | Download of type Document
end type

function "|email invoice PDF file name|
  (delivery of type Delivery) -> Maybe Text
is
  first matching case of delivery:
    when Email (record{
      document: Invoice (record{
        file: Pdf (record{
          fileName: name
        })
      })
    }) then
      Present name

    otherwise Absent
  end case
end function
~~~

Compare the two deep patterns by asking a reader to trace the data and name the ignored fields. The labeled version is longer, but it avoids remembering the positions of recipient, invoice number, and byte count. Measure the trade-off rather than assuming either version is friendlier.

## 17 Review worksheet and suggested answers

### 17.1 Record the first reading

Example or question ID: ______________________________________________

What I think it requires:

____________________________________________________________________

____________________________________________________________________

An input and the outcome I expect:

____________________________________________________________________

Something it appears to permit:

____________________________________________________________________

Something it appears to forbid:

____________________________________________________________________

Something it does not tell me:

____________________________________________________________________

A word or symbol I could not explain:

____________________________________________________________________

Confidence before discussion: low / medium / high

Confidence after discussion: low / medium / high

Time or number of rereads before an answer: ___________________________

### 17.2 Compare alternative spellings

| Topic | First choice | Second choice | What the reader understood |
| --- | --- | --- | --- |
| Annotation | of type | :: | |
| Names | Ordinary identifier | Spaced delimited name | |
| Dimensions | Tuple | Named record fields | |
| Alternative payload | Explicit tag and type | Existing type member | |
| Payload definition | Existing named record | Inline record{…} | |
| Pattern | it matches | Short recognizable pattern | |
| Ignored data | #any | _ | |
| Requirement | must be | Plain equality | |
| Evidence | Technical status | Worded explanation with exact scope | |

Do not use an option’s position in this table as a suggestion that it is preferred. Present choices in different orders across sessions if practical.

### 17.3 Outcome questions

1. In the group example, what happens for 0, 5, 9, 10, and 12?
2. What is the orientation of dimensions (800, 1200)?
3. With 100 captured cents, what happens to a request for 120 cents that also needs review?
4. With 100 captured cents, what happens to a request for 80 cents that needs review?
5. Does a filename rejected for prohibited text also need to be a valid banner size?
6. In the UUU example, does a downloadable PDF invoice produce a filename?
7. In that example, which values does #any ignore?
8. If a search tries 100 possible authorizations and finds none, what can be concluded?
9. If a complete finite authorization collection contains no matching item, what has been established?
10. If a policy’s state machine is proved correct, what remains to check about its native implementation?
11. Does an owner or effective field change which inputs a law applies to?
12. Does a function that constructs a Text witness prove that decoding it is correct?
13. Can an optional proof layer allow -1 to be accepted as an explicitly refined nonnegative Address?
14. Does referencing another law prove either law?
15. If a named record and an anonymous record have identical fields, are they automatically the same type?

### 17.4 Suggested answers for the facilitator

1. Small, medium, medium, large, large. Read the first applicable branch.
2. Portrait: height exceeds width.
3. Reject for exceeding captured funds; that condition comes first in the policy function.
4. Pending review.
5. The agreed priority is to return the filename rejection before the normal size result.
6. No. The query specifically selects Email containing Invoice containing Pdf.
7. Recipient, invoice number, and PDF byte count in the earlier flat-constructor candidate.
8. No matching witness was found among the attempts. Nonexistence has not been established.
9. No matching witness exists in that complete finite collection for the stated input. This says nothing about another collection or an unobserved future.
10. Conformance to the model, integration, assumptions, environmental behavior, and any unmodeled effects.
11. Not by itself. Metadata is documentary unless applicability explicitly refers to it.
12. No. The condition relating the witness to decoding is a separate obligation.
13. No. The declared type boundary remains meaningful even when optional verification layers are not selected.
14. No. A reference is a link and provenance relationship.
15. No. The recorded preference preserves nominal identity for a named record.

### 17.5 Capture domain assumptions

Domain word: ________________________________________________________

The reader’s definition:

____________________________________________________________________

The specification’s intended definition:

____________________________________________________________________

Examples that reveal a difference:

____________________________________________________________________

Use this for words such as active, captured, authorized, eventual, complete, matching, valid, and accepted. A shared word does not guarantee shared meaning.

### 17.6 Consolidate feedback

| Observation | Syntax issue | Domain issue | Missing requirement | Evidence issue | Proposed follow-up |
| --- | --- | --- | --- | --- | --- |
| | | | | | |
| | | | | | |
| | | | | | |
| | | | | | |

Mark each resulting change as accepted, rejected with reason, or still open. Update the decision ledger instead of leaving conflicting “approved” statements in different places.

## 18 Repository sources and glossary

### 18.1 Source locations for technical review

The following paths identify the inspected implementation and its current documentation. They are not substitutes for the proposed language grammar.

| Source | Purpose |
| --- | --- |
| src/LawSpec/Parser.hs | Current parser and legacy syntax |
| src/LawSpec/Model.hs | Surface expressions, declarations, laws, examples, and patterns |
| src/LawSpec/Core.hs | Authoritative typed declarations, expressions, identities, and origins |
| src/LawSpec/Core/Types.hs | Type registry, constructors, capabilities, index compatibility, and positivity |
| src/LawSpec/Prelude.hs | Existing reusable-law definitions and parameter order |
| docs/reference/language/syntax.md | Published legacy grammar summary |
| docs/reference/language/types-and-data.md | Products, sums, fields, equality, and generation |
| docs/reference/language/definitions.md | Current checked definitions, totality, and contracts |
| docs/reference/refinements.md | Refinement and dependent contract behavior |
| docs/reference/language/indexed-families.md | Natural indices and their elaboration |
| docs/reference/language/gadts.md | GADT branch refinement and packaged existential limitations |
| docs/reference/language/abilities.md | Effectful operations, handlers, contracts, and failure behavior |
| docs/reference/language/collections.md | Current Keyed collections, ordering, and operations |
| docs/reference/language/evidence-and-discharge.md | Evidence statuses and environmental attestations |
| docs/reference/formatting.md | Current generated-code formatting |
| docs/reference/cli.md | Existing command interfaces to inspect before adding new commands |
| docs/reference/language/ | Workflows, models, scenarios, actors, temporal behavior, and related features |
| editors/vscode/ | Current syntax grammar and grammar tests |
| templates/editors/vscode/ | Generated/editor source templates to inspect before editing outputs |
| canonical_decisions.yaml | Established implementation decisions |
| chap06.lawspec | The user-supplied Chapter 6 specification to preserve and migrate |
| .gitattributes | GitHub’s current Haskell fallback |

### 18.2 Glossary for a mixed review group

| Term | Meaning |
| --- | --- |
| AST | A structured representation of parsed source. It need not preserve every comment or space. |
| Concrete syntax or CST | A source-oriented representation that can preserve spelling, punctuation, comments, and formatting. |
| Core | The authoritative typed semantic representation consumed by verification and generation. |
| Elaboration | Resolving friendly syntax and inferred information into explicit typed meaning. |
| Desugaring | Translating an authoring convenience into a smaller underlying construct with the same meaning. |
| Nominal type | A type whose declared identity matters, beyond the fields it happens to contain. |
| Structural type | A type identified by its structure, such as field names and field types. |
| Product | Data containing its components together, such as a record or tuple. |
| Sum | Data selecting one alternative, usually with a constructor identity or tag. |
| Discriminant or tag | The identity saying which alternative was chosen. |
| Constructor | A way to build a value of a particular data alternative. |
| Capability | A type-level requirement for an operation, such as equality. Distinct from an effectful ability. |
| Eq | The equality capability. Actual scalar equality rules still apply. |
| Keyed | The current capability for deterministic portable ordering used by sets and map keys. |
| Refinement | A type plus a predicate restricting its values. |
| Wrapper | A distinct nominal type around another value, possibly with a constraint. |
| Indexed family | A family of types related to an index, such as a vector’s length. |
| GADT | An alternative type whose constructors can constrain type parameters, refining them during matching. |
| Totality | Returning or producing the explicitly modeled outcome for every valid input, without an unguarded undefined operation or unestablished termination. |
| Purity | Computing without effectful ability operations; separate from totality. |
| Adapter | Native implementation supplied outside the checked LawSpec definition system. |
| Harness | Configuration controlling how a law is checked, without changing its proposition. |
| Witness | A value satisfying an existential condition. |
| Vacuity | A proposition holding because its applicability domain contains no relevant input. |
| Completeness | Having covered the entire stated domain, not merely the search budget. |
| Model checking | Analysis of states or traces of a defined model. |
| Conformance | An implementation satisfying the model or contract it claims to follow. |
| SMT solver | A reasoning tool for supported logical and arithmetic theories. |
| Oracle | An independent source of expected behavior, such as published machine-language encodings. |
| Provenance | Where a requirement, assumption, generated node, test result, or evidence claim came from. |

### 18.3 Handoff after this review

Collect business feedback and update the open questions. Then consolidate the approved grammar, exact semantics, migration correspondence, public interfaces, implementation dependencies, and acceptance tests into a decision-complete plan.

The initiative remains unfinished until that review and approval happen. The next engineering step is not to silently choose the unresolved alternatives.
