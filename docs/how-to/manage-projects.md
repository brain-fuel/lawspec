---
id: lawspec.how-to.manage-projects
kind: how-to
title: Start, adopt, and change a project
---
# Start, adopt, and change a project

Canon records why a decision was made and links affected units. LawSpec records
behavior; implementation and tests carry code; Git carries authorship and
history. A feature is a coordinated change across those artifacts, with no
separate feature registry ref:DEC-project-workflow.

## Start before choosing a language

```sh
lawspec project init --project my-project
cd my-project
lawspec project status
lawspec project validate
```

This creates `lawspec.edn`, a starter unit under `laws/`, and Canon metadata
through the exact `ricestax@0.3.2` setup package. It does not choose an application
target. That published package embeds Canon 0.1.0; it is separate from the newer
Canon checkout used to review this compiler repository. Its default ingestion
profile is Folio. Use `--languages folio,javascript` to select additional packaged
profiles. No package is installed globally and no human verdict is manufactured.

When implementation work begins, use the existing target scaffold:

```sh
lawspec init --target javascript --project app
```

## Adopt an existing project

```sh
lawspec project adopt --project existing-project
```

Adoption preserves existing LawSpec and Canon metadata and creates missing
metadata only. It never rewrites application code, tests or dependencies. Invalid
manifests, obsolete JSON manifests and incomplete upstream setup destinations
are reported instead of overwritten. An existing `laws/` directory is preserved;
configure `sources` to your existing specs when needed.

For an existing Canon project, validation checks the configured Canon minor
against the executable. Set `CANON` to a compatible native executable when the
bundled Canon is incompatible. It does not run an older Canon against a newer
project silently.

## Discover requirements, then make an explicit change

The repository skill is
[.agents/skills/lawspec-project](https://github.com/brain-fuel/lawspec/tree/main/.agents/skills/lawspec-project).
It supports interviews, design documents and existing code. During discovery,
application files remain read-only. Drafts distinguish observed behavior with
source locations from inferred requirements and open product questions. Existing
tests are evidence of expectations, not automatic product approval.

For additions, link the decided behavior to affected LawSpec units and update
implementation/tests. For changes, create a superseding decision. For removals,
record the withdrawal and retain prior decisions while removing obsolete
executable behavior. Keep rationale in Canon once. Use linked ADRs for distinct
architecture decisions costly to reverse.

## Read the outcomes separately

`project status --json` lists Canon decisions and mandatory definition-check
results separately from unexecuted law evidence. `project validate --json` runs
Canon check, mandatory definition validation and only the layers configured in
`lawspec.edn`. It invokes the existing proof and native test commands when their
layers are selected. A selected execution layer without an application target is
incomplete. Status does not execute laws.

Rows retain their original evidence statuses: `not-verified`, `unsupported`,
`incomplete`, `pending`, refutations and sampled results remain visible. Exit 1
means a definite failure; exit 2 means incomplete or unsupported work; exit 0
with no layers selected means definitions passed, with no law verification
claim. Canon review debt is separate from definition validity.

## Learn by editing code

```sh
lawspec learn
lawspec learn --port 8385
```

Open the printed loopback URL. No manifest is needed. The opening stories adapt Wlaschin’s addition, sorting and smaller-than-80
examples, followed by the existing seating, library and temperature-summary applications.
Every step owns a complete executable project and its checked expected outcome;
choosing a step loads its matching code ref:DEC-learn-executable-story.
Learners edit implementations and LawSpec sources in Monaco. Every example and
property lives in `Tests.lawspec`; generation strategies live in `Harness.lawspec`.
Only `Solution.fs`, `.ts` or `.js` changes implementation language. Both LawSpec
files have syntax highlighting ref:DEC-learn-tests-in-lawspec. Headings use Overpass, text uses Atkinson Hyperlegible,
and code uses Atkinson Hyperlegible Mono, all packaged locally. A single course outline groups Worked examples and Practice, with steps
beneath the active lesson; Previous/Next stays above the reader. Every language has Tests, Solution and Harness
tabs ref:DEC-learn-tests-in-lawspec.
Auto / Light / Dark applies to the entire workspace. Auto follows the system;
explicit choices persist locally ref:DEC-learn-theme.
Previous/Next remains visible above the reader. Desktop keeps story, code and
results in the viewport; compact windows offer Course / Read / Code & results
views that preserve your place ref:DEC-learn-workspace-focus.
F# comes first, with independent TypeScript and
JavaScript drafts. Basic variables, functions and conditionals are assumed;
functional programming and property testing are introduced as they appear.

Language tabs and Run share one editor toolbar; source tabs and save status share
the next row. Test controls contains seeds, replay, saved regressions and alternate
check modes, and opens when an actual failure can be replayed. Load solution sits
beside Reset this step in the reader. About this course contains teaching-preview
status; its Roadmap lists future capstones and material. Unbuilt capstones are not
lesson choices. Existing notebook URLs and stored work remain compatible.

Compilation runs in a worker. F# executes through Fable and typed checked-signature
adapters into the existing JavaScript LawSpec harness with fast-check.
This is browser JavaScript evidence, separate from native .NET/FsCheck. Learner
execution runs in a cancellable worker in an opaque frame with network disabled.
Mandatory definition checks precede execution, including the authored-example
mode. Compiler evidence statuses remain distinct from actual check observations
and learning milestones. Edits invalidate execution results.

Drafts and milestones are saved in IndexedDB by course version, lesson,
application notebook, language and story step. Your progress contains Back up progress and Restore progress. A backup downloads
all saved drafts and milestones for the current course version, across lessons,
steps, languages and saved notebooks, as a portable JSON file with code attribution.
Restore validates the entire file before writing, replaces matching drafts and
preserves other drafts. Theme settings, run seeds and execution results are excluded; rerun
checks after restoring ref:DEC-learn-course-hierarchy. Browser execution makes no automatic AI calls or
source uploads. The optional `lawspec-learn` tutor skill gives progressive hints
and complete solutions when requested; `lawspec-project` remains for discovery
and feature work.

The authoritative code is under `learn/exercises/`, with narrative and
project mappings under `learn/lessons/`. `learn/build-course.mjs` generates
`learn/curriculum.json` and records each source path. Displayed code excerpts
come from the current draft of those same files. Every supplied step compiles
and exhibits its required pass or failure in the scene acceptance suite.
The tutor consumes that generated course too.

The authoritative course is under `learn/`. From a compiler checkout, prepare
its pinned assets and the portable plugin with:

```sh
npm ci --prefix learn
make generate
npm run build --prefix learn
node tools/learn-site.mjs --out .artifacts/learn
```

The CLI and static deployment use this same packaged artifact. Serve `.mjs` and
`.js` as JavaScript and `.wasm` as `application/wasm`. The LawSpec compiler is
transferred as `core.wasm.gz` and decompressed before instantiation; these are the
same compiler bytes. The plugin directory is `plugins/lawspec`, versioned in its
`.codex-plugin/plugin.json`. Its tutor references are generated from the course.

The preview stops at owner teaching review. Review notes are in
`learn/REVIEW.md`. Later lessons, the three distinct capstones and the API example
collection remain deferred. `coverage.json` derives names from compiler
registries, checked built-in declarations, targets and reference headings;
missing checked examples remain visible. Folio is documentary. Deferred targets
are indexed without nonfunctional editor tabs. This preview does not satisfy
the existing 1.0 readership or external adoption gates.
