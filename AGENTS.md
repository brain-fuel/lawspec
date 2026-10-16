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
