# Executable stories for teaching review

The previous preview failed owner review because the narrative and the code
could describe different steps. This revision makes the source project the
boundary of each story step. Teaching review remains open; automated execution
checks establish coherence, not teaching quality or the existing 1.0 readership
and external adoption gates. ref:DEC-learn-executable-story

Run `node npm/bin/lawspec.mjs learn --port 8384` and open the printed loopback
URL. No project manifest is needed. The active course version is `preview-4`;
old IndexedDB entries remain preserved under their original version. An old
preview URL starts at the new addition story on its first refresh. Current
exports contain current-version drafts and the adapted examples' license.

## Quantified-claim formatting correction

The seats example exposed a source-formatter defect: the quantified header used
the arithmetic body's line width, leaving `* 4 end for all` on a continuation
line. The formatter now uses parser-owned header, body and closing boundaries.
It gives each claim its own indented line, rejoins short arithmetic bodies and
breaks long headers between complete binders. Nested universal, existential and
`given` claims follow the same structure; comments and literal text remain
intact. ref:DEC-lawspec-quantifier-layout

The native compiler and actual browser WASM were rebuilt with `tools/wasm.sh`.
The rebuilt formatter checked all 66 authored LawSpec files, changed 28 and
confirmed that a second formatting pass leaves all 66 unchanged. Generated
browser and tutor projects use those formatted sources. Existing `preview-4`
drafts keep their identities and kept cases; Run checks formats a saved draft
before executing it, without requiring a reset.

Focused validation passes: 131 canonical-authoring checks, 15 SDK formatting and
source checks, 24 complete native/WASM formatting comparisons across 32/64-bit
and syntax/checked modes, 120 lesson checks and four packaging checks. Actual
Run formatting passes in Chromium, Firefox and WebKit, including structured
quantifier layout, idempotence, visible/saved/executed snapshot equality,
cancellation, timeout, syntax/storage failures and packaged GET requests only.
Generated-file and compiler-fingerprint checks pass. The local preview and
static artifact have identical packaged bytes. Logs are under
`.artifacts/quantifier-format/`; browser receipts are in
`.artifacts/learn-preview/formatting.json`. These focused checks do not replace
the open teaching review or claim a complete integration-matrix run.
The cached full native compiler suite also passes all 2,817 tests, recorded in
`compiler.log`; the full external integration matrix was not rerun.

## First-time learner review

This refinement keeps `preview-4` progress identities. It reviews the opening,
all six stories, code naming, typing, run scopes, results, errors, replay,
regressions, source replacement and progress recovery from a first encounter
with property-based testing. ref:DEC-learn-english-names
ref:DEC-learn-novice-results

| Learner obstacle | Change | Evidence to inspect |
| --- | --- | --- |
| Camel-case labels obscure what a claim means. | Laws use English sentences; the ordering helper is `"\|is in ascending order\|`. Short implementation/input names remain. | Actual parser/formatter, all story executions and generated native names. |
| The unfamiliar phrase delimiter resembles an unfinished string. | Teach `"\|` through `\|`, without a closing quote; Monaco no longer adds a stray quote when typing a phrase. | Real keyboard entry, parsing and execution in three browser engines. |
| “Property”, “counterexample” and “shrinking” arrive before their meaning. | Define each before first use, alongside the current runnable example; explain a law as a named claim. | Addition and threshold first-use narrative; tutor source. |
| One sampled property sounds like one tested input. | Report actual `numRuns` as generated trials, separately from named properties and accepted smaller failing cases. | A real one-property, 100-trial run. |
| Runner IDs and raw failure data obscure the useful observation. | Display English claims using compiler metadata, show actual concrete calls/answers, and retain native IDs/errors in diagnostics. | The actual call `add 2 2` returns 0 and its named claim fails. |
| An intended red check feels like failing the course. | Qualify expected teaching failures only when the supplied project actually produced its checked observation. | Expected failures stay failed; edited projects and unexpected outcomes get separate explanations. |
| A full JSON trace overwhelms the first failure. | Show the actual final failing input first; disclose the recorded shrink trace and coverage counts separately. | Real input 80, seed/path replay and observed calls. |
| A naming refresh could overwrite existing work. | Refresh an unchanged Laws/Harness pair together; preserve edited pairs, implementations, milestones and kept cases. | Seed an old supplied draft and an edited draft, then compile and run both after loading. |
| Reset or loading a solution can replace a useful experiment. | Offer one immediate Undo reset / solution in the open step; loading a solution opens its implementation. | Recover a kept law byte for byte, execute it, and undo a solution replacement. |

`learn/archive/preview-4-before-english-names.json` is the compatibility snapshot.
Generated `previousProjects` are not active lesson examples. A changed Laws or
Harness file prevents pair replacement, so old short names remain valid in
learner-edited projects. The existing strategy grammar requires lowercase bare
names; the course keeps `numbers` and `lists` rather than adding grammar aliases.
External implementation names remain aligned with the existing typed browser
boundary. No compiler or runtime assertion semantics changed.

Generation checks observe these actual names, separately from native execution:

| Target | Generated claim identifier | Generated typed helper |
| --- | --- | --- |
| JavaScript | English label in the native test name | `isInAscendingOrder` |
| F# | `lawSortingOrdersValuesAndKeepsEveryOccurrence` | `isInAscendingOrder` |
| Python | `test_sorting_orders_values_and_keeps_every_occurrence` | `is_in_ascending_order` |
| Rust | `law_sorting_orders_values_and_keeps_every_occurrence` | `is_in_ascending_order` |

The focused lesson suite passes 120 checks. The focused first-use browser path
passes in Chromium, Firefox and WebKit, including typed English names, actual
calls, trial counts, preserved drafts and replacement undo. Receipts are in
`.artifacts/learn-preview/novice.json`; logs and native-generation observations
are in `.artifacts/novice-review/`. The full browser integration run also passes in all three engines and is
recorded separately in `browsers-full.log`. These checks establish execution coherence;
new-learner teaching review and the existing completion gates remain open.

## Executable story revision

The opening follows Wlaschin's addition, sorting and smaller-than-80 examples.
Only then do the existing seating, library and temperature-summary exercises apply the ideas.
`learn/archive/preview-1.json`, `preview-2.json` and `preview-3.json` preserve the earlier courses
as history; none is the active authoring source.

`learn/course.json` selects the sequence. `learn/lessons/*.json` owns the original
narrative, focused file, project path and required observations for each step.
Actual `.fs`, `.ts`, `.js` and `.lawspec` files under
`learn/exercises/` are the code authority. Project overlays explicitly inherit
unchanged files. `learn/build-course.mjs` resolves each complete project and
records the exact source path of every file. Repository generation creates
`learn/curriculum.json` and packages those bytes for the browser and tutor.
There is no separately authored code copy in a prose block.

Each selected step loads its own source snapshot or saved draft and pairs the discussed source excerpt with its companion implementation or
test in the editor. The prose snippet reads that file from the current draft.
Edits immediately update the snippet, invalidate previous results and label the
project as edited. The supplied-scene observation is qualified accordingly.
Reset restores that step, including its seed. Changing steps preserves separate
drafts rather than carrying a previous step's function into new prose. Loading
a complete solution moves to the final challenge and its matching checks.

Every supplied step declares which checks run and the observations that must
result. The scene acceptance suite compiles and executes all 28 steps in F#,
TypeScript and JavaScript, verifies required named failures and actual shrinking,
and checks source provenance. No compilation error counts as an intended test
failure. Browser checks also traverse the story in sequence and compare the
visible prose, actual editor contents, rendered snippet and execution result.
A supplied-scene observation never changes an individual check's actual status.

## LawSpec-only tests

Every learner-written check is now LawSpec. `Tests.lawspec` owns the implementation
signature, checked helper definitions, named concrete examples and quantified
properties. `Harness.lawspec` owns strategies and their law/input bindings. Each
project has just those two files and one implementation in F#, TypeScript or
JavaScript. The compiler generates the assertions; the browser contains no
parallel handwritten property or example suite. ref:DEC-learn-tests-in-lawspec

All source files undergo mandatory definition validation before execution. The
existing JavaScript target emits the tests and its unchanged testing harness.
The typed implementation bridge calls the learner's actual compiled function.
The observer records those calls and fast-check's actual runs, failures and shrink
steps; it does not compute replacement assertions. Explicit strategies expose
law-input counterexamples. Other generator representations are labelled as such
and cannot be saved as misleading input regressions. Replay selects the exact
failing test with its seed/path. Saving a regression inserts a concrete law into
`Tests.lawspec`, which is checked and run like every other assertion.

Integer strategies use the law's stated bounds. The list stories construct empty,
one-, two- and three-item lists from bounded integer strategies. Those are finite
teaching domains, not evidence for arbitrary list lengths. The unchanged native
harness also generates concrete and boundary checks. Sample-only mode omits those
checks so learners can inspect the sampling story; a full run can reveal a false
claim earlier. Neither outcome is suppressed to fit the narrative.

The harness's browser reference host supports its statistics writes in memory
under `/browser-stats` and sequential asynchronous context scopes. Reports remain
visible in diagnostics. Native filesystem operations and overlapping contexts
fail explicitly. Only the generated harness may import those host modules;
learner code receives no filesystem or network capability. This host is not a
general Node implementation or evidence for native operating-system behavior.
Platform isolation, compiler and UI tests remain ordinary development tests.

## Harness explanation

The opening story introduces Laws, Solution and Harness before using a
generated property. The first quantified addition step explains strategies and
the two input bindings; sorting explains constructive list choices; threshold
contrasts a strategy's range with the claim's larger domain. Essential teaching
is in the visible narrative rather than only a syntax disclosure.
ref:DEC-learn-harness-explanation

Selecting Harness exposes a compact "Harness explained" disclosure below its
editor. `learn/course.json` owns the shared explanation and each authored scene
owns its concrete `harnessNotes`, generated into both browser and tutor material.
The walkthrough identifies itself as describing the supplied source; edited
source remains authoritative. It distinguishes this configuration from the
generated runner and explains example/sample/all modes, seed/path replay and
browser/native evidence. No second code listing or handwritten test suite is
introduced.

The focused harness browser check passes in Chromium, Firefox and WebKit. It
follows the introductory narrative, switches source/language tabs, and changes
the actual threshold strategy from 0–79 to 0–200: the same law and implementation
then fail with counterexample 80. It checks the expanded explanation with editor
and Run accessible at desktop, phone and short-window sizes. Receipts are in
`.artifacts/learn-preview/harness.json`; rerun with
`LAWSPEC_LEARN_HARNESS_ONLY=1 node learn/test/browser.mjs`.

## Lesson decisions to review

Owner feedback rejected the ticket exercise's unstated premise. Preview-4
reworks the visible stories across all six lessons with Winston's Star and
replaces it with the distinct-temperature summary described below.
ref:DEC-learn-winston-story-revision

| Story | Vision | Executable steps | News | Contributions |
| --- | --- | --- | --- | --- |
| Addition | Build a calculator that must do more than remember answers. | One example passes; a new example fails; another branch passes both; commutativity rejects the shortcut; multiplication passes commutativity; repeated addition rejects multiplication; zero passes both; identity rejects zero; repair and rerun the unchanged family. | Properties exclude different shortcuts; generated inputs alone do not guarantee a useful requirement. | Addition, named examples, three independently named LawSpec relationships and their scoped browser observations. |
| Sorting | Specify a useful sort without allowing items to disappear. | Empty output passes ordering; preservation rejects it; duplicate-dropping and zero substitutions fail; unchanged unsorted input fails; a correct sort passes both requirements. | Ordering, length and preservation are different requirements. | A sort, adjacent ordering and occurrence preservation without calling another sort. |
| Threshold | Understand a generated failure before debugging an application. | Inputs below 80 pass a false universal claim; widening reaches a failure that shrinks to 80; replay; save the boundary; correct the claim while keeping the classifier unchanged. | The requirement can be wrong. Shrinking explains an observed failure. | A real seed/path/trace, named boundary and corrected requirement that retains the wider generator. |
| Seating application | Estimate four seats per hall row. | Two examples pass; row three fails; the general LawSpec relationship rejects the shortcut; repair and check 0 and 40 rows. | Carry the technique into a useful problem. | Seat function, third-row example, scoped row-count relationship. |
| Library application | Reorder requests while keeping repeated requests. | Ordering alone accepts an empty queue; preservation rejects duplicate loss and substitutions; unchanged unsorted input fails; implement a correct sort. | Equal values can represent separate requests. | Queue function, duplicate-request example, ordering and occurrence preservation. |
| Temperature summary | Report each distinct recorded temperature; freezing and negatives are valid readings. | Positive samples pass; wider data shrinks to [0]; replay and save; remove the zero filter and retain deduplication. | Zero is a measurement, and this summary intentionally combines repeats. | Repaired summary, wider generator, actual [0] failure and executable freezing regression. |

Each story starts with visible, short code, makes a concrete prediction and
requires an actual run. Independent final tasks keep the checks while learners
edit the implementation or challenge the boundary. F# syntax is explained as
it appears; review whether the amount and placement are sufficient for someone
who knows variables, functions and conditionals but no functional programming.

| Story | Salient idea and slogan | Symbol | Earned surprise | Story and contribution |
| --- | --- | --- | --- | --- |
| Calculator | Properties exclude particular shortcuts. Which shortcut can still pass? | A remembered pair versus an unfamiliar pair, on the first step only. | Multiplication and constant zero pass plausible relationships. | Expose each shortcut, retain complementary properties, repair addition and author a negative-input example. |
| Sorting | Order and occurrence counts are separate. Order it. Keep it. | An ordered empty answer loses the inputs. | An empty list passes ordering. | Add preservation, expose duplicate loss and substitution, repair sorting and author a case exercising both obligations. |
| Threshold | Generation depends on reachable inputs. Reach the boundary. Keep the failure. | 79 is below 80; 80 is not. | A false 0–200 claim passes a 0–79 sample. | Widen only the recipe, inspect the real shrink to 80, replay/save, then repair the claim. |
| Seating | The rule must cover unfamiliar halls. Four seats for every row. | One row and three rows have predictable totals. | Familiar halls pass while a new hall gets zero seats. | A new organizer request exposes memorization; repair the rule and author boundary examples. |
| Library | Equal ranks represent separate requests. Same priority, separate requests. | Both rank-1 requests survive reordering. | An ordered result of the right length can have invented priorities. | Define what one integer means, reject lost/replaced ranks, repair the queue sort and author a repeated-priority case. |
| Temperature summary | Zero is valid data. Zero is a reading. | 0 °C is a measurement. | Every positive sample passes while freezing disappears. | Establish the distinct-temperature task, explain the missing-data mistake, widen the recipe, isolate [0], replay/save and repair the implementation. |

The visible opening establishes the useful task, the input/output meaning and
what the learner will be able to do. Steps identify what changed, ask a specific
prediction or trace, then connect the actual result to one idea. The final task
delivers on that promise and asks for an independent example. Symbols occur only
at their relevant first step; actual source and runtime traces carry the later
explanation. No invented shrink sequence is shown.

This redesign follows Winston’s primary account in [How to Speak, pp. 11–12](https://ocw.mit.edu/courses/15-371-innovation-teams-fall-2024/Unzc731iCUY_transcript.pdf)
and [Make It Clear](https://mitpress.mit.edu/9780262539388/make-it-clear/).
These choices are not a teaching-quality score. Ask a new learner to state the
task before running, predict a call, explain its actual result and distinguish
the library’s repeated requests from the weather summary’s distinct values.
Human teaching review remains open.

## Workspace review feedback

The source tabs read Laws, Solution and Harness. Laws opens `Tests.lawspec`;
the filename and backup identities are preserved. Switching languages keeps the
selected source tab and maps Solution to the corresponding implementation file,
while drafts remain independent. Step changes still open the authored focus.
ref:DEC-learn-source-selection

The primary button is consistently Run checks, with its next-run scope visible
below: Examples + boundaries, Sampled properties or All checks. The caption is
an accessible description; the step still chooses its teaching mode. Busy state
uses progress feedback and aria-busy rather than replacing the button's label.
Alternate runs remain explicitly named under Test controls and temporarily show
their own scope. ref:DEC-learn-run-action

`LAWSPEC_LEARN_TABS_ONLY=1 node learn/test/browser.mjs` checks all three source
selections across F#/TS/JS, edits and revisits each independent draft, checks
keyboard/compact navigation, and verifies the fixed Run label and displayed
scope against actual named-check/property counts in all three browser engines.
The focused source-selection and layout runs pass in Chromium, Firefox and
WebKit, including phone and short-window geometry. The lesson suite passes 120
tests and the packaging suite passes four. Receipts are `tabs.json` and
`layout.json` under `.artifacts/learn-preview/`; logs for this refinement are
`.artifacts/style/tabs-browsers-final.log` and `tabs-layout-verified.log`.

Headings use Overpass, body text uses Atkinson Hyperlegible, and code uses
Atkinson Hyperlegible Mono. Fonts and licenses are packaged locally. Lesson
and step navigation remain visible controls; each language
has Laws, Solution and Harness tabs. Laws opens `Tests.lawspec`; Laws and Harness use LawSpec highlighting. Auto / Light / Dark themes
include Monaco, syntax highlighting, snippets, generated output, diagnostics
and results. Auto follows live system changes; explicit choices persist across
reloads. Theme changes preserve code and execution results. The local
`../ui/refactoring_ui/chapters` guidance informs hierarchy, typography, spacing,
selectable controls and readable color contrast; no associated UI skill exists.

The opening prediction is authored only on its opening step. Other steps use
what their source and actual results demonstrate; the lesson-level Winston
symbol is not automatically stamped across the story. Previous/Next stays above
the scrolling reader, and selecting a new step returns to its heading. Desktop
story, editor, execution controls and results share the viewport; reading or
scrolling one does not move the others off-screen. Compact windows expose
Course / Read / Code & results tabs. Switching views retains each panel's scroll
position, the editor model and the current results. Language changes stay in the
chosen view, and source links open their file directly in Code.

Geometry checks cover a 1440×900 desktop, a 1280×720 laptop, a 390×844 phone-sized
viewport and a short 1366×600 window. They verify visible Run/results/navigation,
independent scrolling, heading reset, view/scroll/model preservation and the
short-window toolbar in Chromium, Firefox and WebKit. Receipts are in
`.artifacts/learn-preview/layout.json`; the screenshots use `*-workspace*.png`.

## Course hierarchy

Kept regression cases are source edits in Laws (`Tests.lawspec`) and are
included in autosaved drafts and progress backups for their original lesson,
step, language and notebook. The backup help says so explicitly. Export requires
a successful save of the current draft; storage failure reports Backup failed
instead of downloading an older stored snapshot. Restoring code does not restore
current execution evidence. ref:DEC-learn-regression-progress

`LAWSPEC_LEARN_PROGRESS_ONLY=1 node learn/test/browser.mjs` exercises a real
generated counterexample, Save regression, reload, backup contents, removal,
restore and fresh execution of the restored law. It also verifies that a failing
storage write prevents a stale backup download. Receipts are in
`.artifacts/learn-preview/progress.json`.
The full regression-progress path and failed-write control pass in Chromium,
Firefox and WebKit; the focused log is
`.artifacts/style/regression-backup-browsers.log`.

Owner direction requested a fresh-context UI pass before applying the five changes.
A separate reviewer received the current files, these requirements and `../ui`,
without the prior conversation. It read the hierarchy, layout, typography and
empty-state guidance and reviewed a rendered baseline before implementation.
There is no `SKILL.md` under `../ui`. Its independent follow-up caught short-window
failure controls and narrow busy-state risks, which are covered by browser checks.
This is a design review of this change, not human teaching approval.
ref:DEC-learn-course-hierarchy

The outline groups the six authored lessons into Worked examples and Practice.
Only the active lesson expands its steps, with a clear current-step state; the
reader has no duplicate step grid. Fixed Previous/Next remains above the story.
Unbuilt capstones are prose in About this course → Roadmap, where future attribution
also lives. Teaching-preview status is inside About this course, not in the header.

Your progress holds secondary Back up progress and Restore progress actions with
scope and overwrite behavior beside them. A JSON backup includes every saved draft
and milestone for `preview-4`, across lessons, steps, implementation languages and
notebooks, plus code attribution. It excludes theme, seed and execution results.
Restore validates before one atomic merge, replacing matching draft keys while
preserving others; rerunning checks supplies current evidence. Existing notebook
IDs, deep links and storage namespaces remain compatible. No course-version bump
or draft migration is needed for this UI change.

The editor has two header rows: language tabs with Run/Cancel, then source tabs
with save status. Full language names appear where space allows; compact TS/JS
labels retain full accessible names and keyboard behavior. File names remain in
tab tooltips and accessible editor context. Test controls contains the seed,
alternate checks and replay/regression tools; actual replayable failures open it.
Execution details are in diagnostics. Load solution is beside Reset in the reader.
The source and results gain space by removing rows, not reducing their fonts.
At 1280×720, measured editor-header height falls from about 198 px to 87 px,
while source height rises from about 167 px to 252 px.

Baseline and revised geometry are recorded in `.artifacts/learn-preview/ui-before.json`
and `*-compact.json`, with settled screenshots at 1440×900, 1280×720, 390×844 and
1366×600. The browser checks exercise the nested outline, keyboard language tabs,
backup/restore, failure controls in a short window and active cancellation at
320×568. Small workspaces retain an internal scrolling fallback and sticky Run
controls when their content cannot fit. This evidence does not approve the
curriculum, deferred capstones or incomplete comprehensive bindings.

## Generated boundaries

The owner requires a comprehensive one-to-one set of deterministically generated
bindings. Missing, ambiguous and unsupported entries must fail completeness;
a complete inventory of deferred entries is not an implemented binding set.
Names, signatures and conversions must derive from authoritative declarations
and target metadata. Check repeated bytes, round trips, invalid values and
corresponding behavior, not just matching names.

The current adapter is still incomplete against that requirement. This preview
supports one implementation declaration, Int32/list inputs, multiple Int32
arguments and Int32/list/Bool results. Its bridge and module wiring derive from
the admitted declaration and actual compiler plan. Unknown signatures fail
explicitly. The addition example requires real two-argument calls; it does not
encode two integers as a fake one-argument lesson function. Repeat-generation
checks cover the emitted bridge, descriptor, Fable output and bundle.

Unchanged native F# harness reuse is not implemented. Pinned Fable probes reject
`Environment.ProcessId`, `Type.GetMethod` and `Random.Shared`; FsCheck's ordinary
DLL still requires Fable-compatible F# sources. Fable documents its
[BCL/reflection limits](https://fable.io/docs/javascript/compatibility.html) and
[library source requirements](https://fable.io/docs/your-fable-project/author-a-fable-library.html).
These obstacles do not establish that a portable F# host is impossible. The
current browser reuses the existing JavaScript harness and runtime; it is
separate from native .NET/FsCheck evidence and does not constitute a new backend.

## Execution and trust boundaries

Pinned components remain Fable Standalone 3.7.2 (Fable 5.21.0), metadata/library
2.2.0, TypeScript 5.9.3, Monaco 0.57.0, esbuild-wasm 0.28.2 and fast-check 4.10.2.
Fable checks the project and generated typed bridge and emits with PrintTargetAst.
TypeScript semantic checking precedes bundling. esbuild resolves virtual modules
through its plugin API. A TypeScript AST transform redirects the optional native
secure-network loader to an explicit unsupported browser module; native socket
imports likewise remain unsupported.

Compilation runs in a worker. Learner execution runs in a cancellable worker
owned by an opaque frame, with network denied by CSP, fixed asset allowlists and
timeouts. No source upload or automatic AI call is made. Asset builds prepare a
complete tree and replace files atomically so rebuilding does not remove live
libraries halfway through compilation.

Mandatory definition admission runs even in authored-example mode. Planned
compiler evidence remains planned; actual named tests and sampled properties
are reported separately. Missing tests, incorrect types, unsupported work,
timeouts, unknown and incomplete outcomes stay visible. Learning milestones
are not proofs. Authored-only steps contain no unused placeholder property.

Drafts are stored by course, lesson, notebook, language and step. Import validates
the entire current-version project before writing; imported milestones do not
carry execution evidence. Local CLI and static deployment consume the identical
packaged assets and compiler bytes. Deferred targets never become editor tabs.

## Attribution and deferred coverage

Scott Wlaschin's [addition article](https://fsharpforfunandprofit.com/posts/property-based-testing/),
[sorting article](https://fsharpforfunandprofit.com/posts/property-based-testing-3/)
and [Understanding FsCheck](https://fsharpforfunandprofit.com/posts/property-based-testing-1/)
are attributed individually in the lessons. Adapted code retains the site's
[MIT code license](https://fsharpforfunandprofit.com/about/license/) in source,
generated curriculum and exported projects. Prose is original. The browser's
uniform bounded generation, seed/path and shrink trace are explicitly distinct
from FsCheck's distribution and article output.

Presentation draws on Winston's [Make It Clear](https://mitpress.mit.edu/9780262539388/make-it-clear/)
and [How to Speak](https://ocw.mit.edu/courses/15-371-innovation-teams-fall-2024/Unzc731iCUY_transcript.pdf).
Future type/failure lessons retain Wlaschin's type-design attribution and
[Against Railway-Oriented Programming](https://fsharpforfunandprofit.com/posts/against-railway-oriented-programming/)
caution. Those lessons and the three distinct capstones await review.

The public inventory is generated from compiler name lists, checked built-in
providers, primitives, target definitions and reference headings. Dedicated API
examples remain deferred, including browser reference handlers and native CI
scenarios. Folio is documentary. Missing coverage stays visible; no complete
API collection or comprehensive binding acceptance is claimed.

## Validation record

The current focused suite passes 120 checks, including every scene in all three
languages, complete and alternative correct implementations, malicious shortcuts,
weak/vacuous properties, incorrect types, missing tests, mandatory admission,
actual generation/shrinking/replay, source provenance and deterministic emission.
Four packaging checks pass, including local/static byte equality, asset hashes,
script/font/WASM MIME types and manifest-free loopback launch.

Browser receipts are written to `.artifacts/learn-preview/browsers.json`,
per-language scene receipts to `story-*.json`, and the logs to
`.artifacts/style/star-lessons-final.log`, `star-browsers-final.log` and
`star-packaging-final.log` for this revision. Browser
checks verify all supplied F# steps, all six solutions in three languages,
source/prose transitions, independent step drafts, themes, replay/regressions,
reload, export/import, cancellation, timeouts, type diagnostics and network denial.
No performance budget is inferred from these measurements.

The portable tutor uses the same generated scene material and reveals complete
solutions on request. The earlier independent tutor trial covered novice hints,
a requested full solution and misleading evidence; the revised tutor explicitly
starts from the current scene's source and observed result. No new independent
behavior trial or human teaching approval is claimed.

The cached integration run for the formatting revision passed all 2,814 compiler
tests and package smoke. It exposed formatting failures and was stopped before
the full 2,751-stage matrix completed. The identified failures were repaired and
checked with the focused reruns below; the full matrix is not claimed green.
That cached run reported 60 pieces of material awaiting human sign-off; no structural errors
were reported and sign-off has not been manufactured.
Root project status/validation also retains its pre-existing missing manifest
and Canon version mismatch. Preserve that setup and unrelated working-tree work.

## Format before run

Every Run mode formats all project files locally before compilation. The editor,
saved draft and compile request contain the same successful formatted snapshot.
LawSpec uses the compiler's syntax formatter; F# uses Fantomas.Core 8.1.0 on
.NET Mono WebAssembly 10.0.12, SDK 10.0.401; JS/TS use Prettier 3.9.10 with
prettier-plugin-brace-style 0.10.4 and the shared Google/gts settings plus Allman.
The third-party plugin's internal Prettier call receives standalone's built-in
parsers through a build-time module facade, without modifying the plugin.
ref:DEC-learn-format-before-run ref:DEC-google-style-allman

The .NET formatter has its own worker and a readiness handshake. Formatting does
not run learner code. Syntax errors leave the whole draft unchanged and stop
execution. Failed storage stops compilation. Cancellation and the two-minute
formatting timeout terminate the formatting worker and its child; the compiler
has its own independently bounded worker. Definition admission and type checks
still run after formatting. F# execution remains Fable/JavaScript.

`LAWSPEC_LEARN_FORMATTING_ONLY=1 node learn/test/browser.mjs` exercises actual
format/save/compile ordering, the executed source shown in Monaco, saved source,
idempotence, Allman, syntax failures, failed storage, cancellation and timeout
in Chromium, Firefox and WebKit. Receipts are written to
`.artifacts/learn-preview/formatting.json`; the full browser suite includes these
checks and its existing execution, replay and isolation checks.

A local warm-asset measurement before adding the negative controls observed
first format/compile/run at 6.8 s Chromium, 2.9 s Firefox and 7.0 s WebKit, and
interface-ready at 143/227/145 ms. This is one machine, not a performance budget
or a cold-network guarantee. The untrimmed local .NET/Fantomas runtime adds about
38 MB to packaged assets and is loaded only for F# formatting. The complete
vendor artifact is about 81.5 MB uncompressed. No source-bearing network requests
were observed: only same-origin packaged GET retrievals. Re-measure before
setting budgets or changing runtime trimming.

Build prerequisite for the local formatter: install .NET SDK 10.0.401 and its
`wasm-tools` workload (`dotnet workload install wasm-tools` from
`learn/formatter/`), then `npm ci --prefix learn`, `lawspec-dev generate` and
`npm run build --prefix learn`. `packages.lock.json` is restored in locked mode;
the runtime and formatter licenses travel with the packaged artifact.

### Verification of this revision

The final lesson suite passes 120 tests. The complete browser suite passes in
Chromium, Firefox and WebKit, including the format-before-run negative controls
and all six stories. All four packaging tests pass. The temperature-summary
contract accepts different output orders and rejects missing zero and retained
duplicates. The local server and static artifact have identical packaged bytes.
That teaching revision left the compiler and runtime unchanged; the subsequent
quantifier correction above updates parser inventory and source formatting.
The earlier formatting baseline includes the following checks. The rebuilt native/WASM
compilers agree on 454 complete responses for the focused collections fixture
and admission probes across 32/64-bit and readable/compact output. Generated-file
and compiler-fingerprint checks pass. Receipts are in `.artifacts/style/`.

The affected SDK regression tests pass (20 tests). Focused formatting and native
execution reruns pass for lessons in Java, C#, Python, JavaScript and TypeScript;
Rust scalar, actors, sessions, abilities, generation and typed mappings; Java
and Clojure crypto; Haskell crypto and orders/refunds; Swift orders/refunds;
Python orders/refunds; and the Prolog bridge. The Rust runtime's 42 tests pass.
These reruns cover the failures found in the interrupted matrix; they do not
establish that every remaining integration stage passes.

Formatting is not complete Google Rust guide conformance. In particular, the
existing typed-failure ABI still uses panic/catch boundaries that need a
coordinated semantic change; see `docs/reference/formatting.md`. This revision
preserves that behavior and its evidence labels. Teaching approval, complete API
coverage, the remaining integration matrix and existing human review debt stay
open.
