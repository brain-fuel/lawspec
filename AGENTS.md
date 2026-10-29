# Proof engineering

For proof, verification, dependent typing, totality and related design work,
prioritize studying SPARK/Ada (including Why3), Lean 4, Idris 2, Rocq and
relevant established systems before designing custom machinery.

- Read primary documentation and implementation sources for the relevant
  mechanism. Record the precedent and how it maps to LawSpec's semantics.
- Prefer established libraries, solvers, proof infrastructure and techniques.
  Explain any necessary bespoke implementation and its trust boundary.
- Distinguish obligation generation, solver execution and proof checking.
  Identify what is actually integrated; a research prototype is not an
  implemented compiler backend.
- Preserve mandatory definition validation independently of optional law
  verification. Preserve explicit unknown, unsupported and incomplete results.

The authoritative language and milestone contract remains
`LAWSPEC-PRE-1.0-REVIEW.md`.

# Code style

The owner's explicit Allman-brace preference takes precedence over every external
style guide where the established formatter supports that layout. Where it
cannot support Allman, keep the standard layout rather than adding a custom
formatter. Go retains the same-line braces required by its grammar. Follow Google's
current language guide for the remaining choices; use the language's official
or established guide where Google has none. This includes generated code,
compiler and runtime sources, Learn, MCP, examples, scaffolds and templates.
Read `docs/reference/formatting.md` for tools, target mappings and documented
syntax/ABI boundaries. Do not equate passing a formatter with complete style
conformance. Preserve semantics, public bindings and honest evidence statuses.
Update authoritative sources and regenerate their outputs; leave third-party
and explicitly minified build artifacts in their upstream format.
