# LawSpec 1.0 design and business review draft

**Minor authoring implementation contract — revised 15 October 2026**

Repository: brain-fuel/lawspec\
Audience: business readers, product owners, developers, language designers, and verification practitioners.

LawSpec describes what software must do and connects those requirements to implementation, tests, and verification evidence. The intended language combines approachable words and explicit structure with advanced types and formal precision.

The immediate task is to discover whether actual business readers can understand these specifications. Agreement between programmers about attractive syntax is insufficient. Readers should be able to predict outcomes, explain obligations, identify missing requirements, and understand what the evidence establishes.

The latest approved milestone direction below is authoritative. The implementation contract originally called RC1 remains the implementation baseline, subject to the later decisions recorded here. Earlier discussion and superseded alternatives remain history.

**Implementation status:** the repository is at version 0.24.0. The authoring work currently being prepared is a minor-version milestone, **not a release candidate**. No RC version or tag is authorized. The existing technical profile identifier `1.0-rc.1` is retained during implementation; it is not a release designation. The redesigned examples below are language-design examples; they are not claims that the current parser accepts them. Code blocks deliberately use plain text rather than simulated syntax highlighting.

Examples are independent unless a section explicitly connects them. Repeated unit names and simplified signatures are separate presentations, not declarations intended to coexist in one source file.

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
- Migration currently supplies a read-only typed inventory, constructor/native-binding change inventory and explicit configuration proposal preserving prior law checks. It **does not yet transform source**. `--write` reports `migration-incomplete` and writes nothing until project-wide correspondence validation exists.
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

Required work still open:

- Broader stochastic candidate generation, shrinking individual existential witnesses, concrete witness-value traces, and complete variable-width or opaque integer covers made finite only by refinements. Complete constant and fixed-width dependent integer covers now work. Constructive expressions and qualified harness paths now work. Nested and outer finite/empty logical domains now have scoped evidence. Effectful witness searches still require explicit snapshot semantics.
- Remaining generic source-constructor cases include generic structural GADT result equations and structural payloads under containers such as List. Generic projection refinements now pass the all-target matrix above. Checked function expansion in anonymous field restrictions and complete source integration across remaining model/actor paths still require work, as do recursive tuple patterns, typed bare empty record patterns and irrefutable parameter patterns. Direct anonymous source types, values, generic product projections/returns and literal examples now pass the checks above. Bare empty record patterns still report their implementation limit; named record patterns and wildcards remain available. All eight domain-layer examples now use actual inline anonymous payloads.
- Complete unqualified prelude fallback/ambiguity rules; typed documentary references now resolve independently of executable law application. Contextual articles now preserve lexical scope and ordinary names.
- Complete Set/SortedSet migration and native adapter coverage; broader set domains made finite only by refinements and remaining dependent-generation coverage; remaining direct sized-container iteration and unqualified prelude resolution, pinned full Unicode case folding and exact-widening additions. Canonical source names and checked set operations are now implemented as recorded above.
- Complete finite mapping domains beyond the implemented enums/Booleans, explicit partial lookup, and target/interface coverage of every added feature.
- Source formatting now handles nested cases/mappings and wraps at trivia toward 80 columns; a full authoring corpus and complete language-service navigation remain gates. Schemas 3/4 and configuration 1 remain available during transition; rejecting them from normal canonical interfaces is an unfinished release boundary.
- Expected compile-rejection examples with stable diagnostic codes and the full failure/witness/assumption diagnostic contract.
- The validated project-wide migration engine, both Chapter 6 passes, all specified demonstrations and independent Chapter 6 oracles/mutants, then complete target/docs/parity/release acceptance.

The human readability gate is **deferred by the user**. The larger demonstrations, advanced analyses and GitHub Linguist recognition remain pre-final-1.0 requirements. No RC1 or final-1.0 acceptance or release is claimed.

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

The proposed CLI direction is lawspec fmt and lawspec fmt --check, subject to final integration with existing commands.

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

The source formatter is new work. The repository’s existing formatting documentation largely describes generated native code formatting.

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

The function returns the filename of a PDF invoice delivered by email. Just contains a qualifying filename. Nothing means a different alternative was selected. A record pattern selects fields by name; a union constructor pattern selects the tag and matches its positional fields in this earlier candidate.

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
      Just name
  end case
end function
~~~

### 16.2 RRU

The file may instead be PlainText. That alternative reaches Nothing.

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
      Just name

    otherwise Nothing
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
      Just name

    otherwise Nothing
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
      Just name

    otherwise Nothing
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
      Just name

    otherwise Nothing
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
      Just name

    otherwise Nothing
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
      Just name

    otherwise Nothing
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
      Just name

    otherwise Nothing
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
  = Just "invoice.pdf"

expect "|email invoice PDF file name|
  (Download
    (Invoice "INV-42"
      (Pdf "invoice.pdf" 24000)))
  = Nothing

expect "|email invoice PDF file name|
  (Email "alex@example.com"
    (Letter (Pdf "letter.pdf" 12000)))
  = Nothing

expect "|email invoice PDF file name|
  (Email "alex@example.com"
    (Invoice "INV-42"
      (PlainText "invoice.txt")))
  = Nothing
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
      Just name

    otherwise Nothing
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
