---
name: lawspec-project
description: Start, adopt, or change a LawSpec project from an interview, design document, or existing codebase, linking Canon decisions to executable behavior and evidence. Use for explicit feature additions, changes, and removals as well as project discovery.
---

# LawSpec project workflow

Use Canon for decision rationale and links to affected units, LawSpec for behavior,
code and tests for implementation, and Git for authorship and history. Do not
create a feature registry or duplicate a decision's rationale across files.
The repository's `LAWSPEC-PRE-1.0-REVIEW.md`, when present, is authoritative.

The [coding course](https://goforge.dev/lawspec/learn/) is also served by
`lawspec learn`. Its source projects are under `learn/exercises/`, with narrative under
`learn/lessons/`; `learn/curriculum.json` is generated from them in a compiler
checkout. Use `lawspec-learn` for tutoring, hints and requested lesson
solutions. This project skill remains for discovery and feature work. The opening Wlaschin stories and their application exercises are an F#-first
teaching preview; later lessons, capstones and the complete API collection await
owner review. Browser F# executes through Fable
and the JavaScript harness; it is separate from native .NET evidence.

## Starting and discovery

Choose the entry mode from the user's materials; combine modes when useful.

- **Interview:** establish actors, desired outcomes, representative examples,
  boundaries, rejection/failure outcomes, and unresolved choices. Ask only
  questions whose answers materially affect behavior; continue independent work.
- **Design document:** extract stated requirements with source locations. Keep
  contradictions and missing decisions as product questions. Do not resolve an
  ambiguity by silently turning one interpretation into a requirement.
- **Existing codebase:** discovery is read-only to application code, tests,
  dependencies, generated code, and build configuration. Inspect public APIs,
  types, tests, data and error paths. Cite observed behavior with file/symbol/test
  locations. Label inferred requirements separately. Existing tests do not prove
  product intent, and observed quirks need not become requirements. Do not run
  generators that rewrite the application during discovery.

Produce reviewable LawSpec drafts plus a concise discovery note distinguishing
observations, explicit requirements, assumptions and open product questions.
Keep temporary drafts outside configured source paths until ready for checking.
Each question should show the affected behavior and alternatives; do not store
another feature catalog. Record an approved decision once in Canon and link the
LawSpec units it affects. Do not claim human approval from generated text.

`lawspec project init --project <directory>` creates target-free LawSpec metadata
and uses the pinned Rice's Tax setup. Use `project adopt` for existing projects;
it preserves application files and existing metadata. Default Canon ingestion is
Folio; select additional supported profiles with `--languages folio,javascript`
when appropriate. Review existing configuration conflicts instead of replacing it.
`lawspec init --target <language>` adds a target only when implementation work is
in scope. Do not choose an application language just to start a specification.

## Explicit feature work

For an authorized addition, change or removal, coordinate these artifacts:

1. Identify the relevant existing Canon decisions and affected LawSpec units,
   public types, implementation and tests. State any unresolved product choice.
2. Add a Canon decision for newly settled intent, or a new decision superseding
   the old one for changed intent. Use Canon's existing ledger format and
   `ref:DEC-...` links from affected specs, code and tests. Never delete decision
   history. A removal records the withdrawal and preserves prior decisions;
   remove obsolete executable behavior and its obsolete tests as appropriate.
3. Update types and specs to express the agreed behavior, then implementation
   and tests. Use ADRs only for distinct architecture decisions costly to reverse;
   link them from Canon instead of copying their rationale into both places.
4. Run `lawspec project status`, then `lawspec project validate`. Inspect Canon
   review and definition-check outcomes separately from configured verification
   evidence. Run focused application tests and negative controls appropriate to
   the change. Report pending human review truthfully; never manufacture vetting.

## Modeling and evidence

Choose existing concepts: round trips, invariants, idempotence, reference models,
structural properties and generator coverage. Try maliciously compliant
implementations to assess property strength. Do not add Wlaschin-inspired grammar
aliases or a `Fin` primitive.

Generate a linear model's command arguments from its current abstract reference
state and measured indices; recompute after transitions, and revalidate the
suffix after shrinking. Never let the system under test select its own test
inputs. A proven-empty domain disables a command; bounded generation failure is
incomplete. Shared models remain unindexed; OTP gen_statem integration is outside
this workflow.

Mandatory definition validation is independent of optional law verification.
Use only the layers selected in `lawspec.edn`. Distinguish obligation generation,
solver execution, and proof checking. Sampled testing is sample evidence; finite
exhaustive checks are scoped to their model and domain; solver results name their
trust boundary. Preserve not-verified, unknown, unsupported, incomplete, pending,
and known-discrepancy outcomes. Do not present a research prototype as an
integrated backend. MCP is read-only check/list/explain; decisions are ordinary
reviewable file edits, with no feature CRUD or decision-writing MCP tools.
