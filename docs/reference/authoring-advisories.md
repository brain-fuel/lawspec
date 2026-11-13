---
id: lawspec.reference.authoring-advisories
kind: reference
title: Authoring discovery and advisories
---
# Authoring discovery and advisories

`lawspec prelude [query]` searches the installed compiler's public operation
registry and reusable law source without reading a project manifest.
`lawspec inspect --target <target> [--json]` validates the current project and
returns its actual generation plan, resolved declaration identities, allocated
names, native bindings, ownership and canonical adapter source. Constructor
layout and native signatures remain authoritative in the returned source and
schema. Bound references remain structured arrays; their target syntax is authoritative
in the emitted source. A null allocated name does not invent a class
for structural or term-based targets. Inspection also returns digests of the compiler’s readable and compact generated
artifacts, so supported formatting choices do not trigger ownership warnings.
Neither command writes application files. Project dependencies must already be
available locally or in a verified, unpacked cache; discovery never repairs
cache markers, unpacks packages or writes lockfiles. Run `lawspec fetch` separately
when a required package is unavailable.
ref:DEC-authoring-advisories

`lawspec advise [--target <target>] [--json] [--strict]` reports review candidates
and the status of selected checks. Ordinary `check` and `generate` report advice
by default; `--no-advice` disables it for that invocation. Advisory warnings do
not change semantic diagnostics, law evidence or ordinary command success.
`--strict` fails for unresolved findings **or incomplete selected checks**.
Without a configured native target, advice explicitly covers compiler rules
only. Supplying a target selects native analysis too.

## Bounded checks

Compiler rules inspect resolved, typed Core. Generic helpers are checked at their
instantiated Core definitions and reported under their authored identity; a
definition template without an executable Core instance is explicitly incomplete.
Initial helper patterns are
recursive List length and membership. Initial law patterns are unrestricted
unary idempotence and left inverse equations, and the two
[guard rules](#guards). Existing template applications
retain their trace and do not trigger the expanded-equation suggestion. A helper
with different recursion, bounds or domain meaning is outside these shapes;
absence of a finding does not establish optimal authoring or equivalent meaning.

Native checks use bundled, hash-pinned upstream Tree-sitter/WASM grammars for
every `programTargets` entry, including Prolog and the host languages used by
composite targets. Files in unrelated native languages are explicitly classified
as not applicable to the selected target. Parsing is syntax analysis; it is not native compilation or
proof. Supported declaration shapes include classes, records, unions, aliases,
functions and Prolog dictionary schemas. Rules report copied generated files,
matching generated declaration shapes (including renamed declarations), shared
model names, adapters referring to competing local models, and potential manual
conversion boundaries. Similar shapes and names are review candidates.

The source scan excludes dependencies, build products, hidden directories and
vendored code. Symlinks require an explicit source selection. Files larger than
2 MiB, trees exceeding 100,000 nodes, parser errors, missing parser assets,
unsupported preprocessing/macros, and unresolved imports produce explicit
incomplete or unsupported checks. Imports outside the supplied/generated source
inventory require review; the analyzer is not a language server or whole-program
type checker. TSX and literate Haskell sources are discovered but explicitly unsupported by
the bundled grammar selection. Runtime support copy detection compares whole-file bytes; a
partially rewritten support implementation may fall outside that check.
Artifact targets classify native analysis as `not-applicable`.

The parser engine and grammars are packaged for offline use. Versions, source
archives, digests and build commands are recorded in `npm/native-parsers/lock.json`;
each grammar has its upstream license. Tree-sitter owns parsing; LawSpec owns the
bounded extraction and comparison rules. No new obligation generator, solver
executor, proof checker or custom language parser is introduced.

## Guards

Two compiler rules report laws whose claim sits behind a guard that generated
cases cannot be expected to satisfy. Such a law passes without testing its
claim, and `lawspec test` reports it as `vacuous`; see
[guards and reach](refinements.md#guards-and-reach). ref:DEC-vacuous-outcome

| Rule | Reports | Suggests |
| --- | --- | --- |
| `vacuous-guard` | A `matches regex` or literal-list (`x in [...]`) guard on a directly quantified input | The refined quantifier, written out: `(name :: Text where name matches regex "[A-Za-z]{2,40}")` in place of the guard |
| `adapter-guard` | A guard that calls an adapter on a quantified input | A harness strategy that builds values the guard accepts, and `use` of it for that input |

The compiler already reads a `vacuous-guard` guard to direct generation, so
the law usually reaches its claim; the refinement is suggested because it also
governs examples, boundary cases and shrinking, and makes the domain explicit.
An `adapter-guard` cannot be helped by the compiler: it cannot see which
values native code accepts. `lawspec test` prints the same message under a
law it reports vacuous. Both rules are structural: a guard written another way
(a comparison chain, a helper around the regex on a field) is outside them,
and no finding does not mean a guard is reached.

## Migration and explicit exceptions

Prefer migration to generated models. If an application must retain its model,
use checked native bindings or supported codecs, preserving public semantics.
An intentionally independent reference model or teaching declaration can carry
a scoped exception in `lawspec.edn`. Add this entry to its root map:

```edn fragment
:authoring-exceptions [
  {:declaration "src/reference.mjs::Point"
   :rule "native-model"
   :reason "Independent reference model used to cross-check the generated model"}
]
```

Compiler findings use resolved LawSpec declaration identities. Native findings
use the reported relative path and declaration name. The rule and declaration
must match; a nonempty reason is required. Exceptions retain the finding with
`status: excepted`; they do not change binding validity or verification evidence.
Advice never rewrites types, bindings, adapters, public interfaces or generated
files. Re-run native tests after an independently reviewed migration.

## SDK and MCP

The SDK exposes `compiler.prelude({query})`, `compiler.inspect(request)` and
`compiler.advise({...request, nativeSources, exceptions})`. Native sources are
explicit `{path, content}` values; omitting them for a selected program target
is incomplete. `advice.ok` is false for unresolved findings or incomplete checks;
SDK callers choose how to enforce it. Compiler `check` and `planGeneration`
return compiler-side advice; the CLI additionally reads selected native sources.
Use `advice: false` to omit compiler advice. Semantic diagnostics and evidence
remain separate response fields.

MCP exposes read-only `lawspec_prelude`, `lawspec_inspect` and `lawspec_advise`.
The server can start before project initialization; only project-dependent tools
require a manifest. The same SDK/core implementations supply these views.
