# LawSpec 0.9.0

This release adds structural data and checked total definitions across Java,
Python, JavaScript, TypeScript, Go, Haskell, Kotlin, and Rust.

## Language

- `List a` supports nested contextual literals, structural equality, exact
  length, deterministic boundaries, and native framework generation/shrinking.
- Algebraic `Maybe a` and `Either a b` provide `Nothing`/`Just` and `Left`/`Right`.
  They remain distinct from interoperability `Nullable` and `Optional` values.
- Named parameterized products and sums have constructors and ordered fields.
  Generated native types and typed adapters preserve their structure.
- Total definitions support exhaustive matching and checked structural recursion.
  The compiler rejects partial matches and recursion it cannot establish as
  terminating. Generic definitions specialize to their concrete uses.
- Refined definition signatures become executable native contracts. Scoped
  payload predicates preserve type-parameter roles through recursive and mutual
  data declarations, including predicates that depend on preceding inputs.

Existing scalar semantics remain intact: exact arithmetic does not wrap,
conversions to bounded adapter parameters are checked, floating equality follows
IEEE rules, and Symbol equality uses identity.

## Generated output

Readable code is the default for runtimes, declarations, definitions, adapters,
tests, and scaffolds. Explicit `--minify` selects compact output for `init`,
`generate`, and `examples`; the compiler API accepts `minify: true`.

Output follows Google language-specific guidance where applicable, PEP 8 for
Python, standard Go and Rust formatting, and an 80-column Haskell layout.
Formatting is deterministic in both native and WASM compilation and requires
no formatter download. Compact output preserves required layout, literal
contents, and semantics. Changing formatting mode does not overwrite edited
adapters or create false adapter-signature updates.

## API and compatibility

API schema 3 adds named data declarations, structural values, checked definitions,
construction/matching expressions, and scoped payload predicates. Existing scalar
wire encodings are unchanged. Exhaustive expression visitors must handle the
new variants; see [API migration](API-MIGRATION.md).

Java 25+, Python 3.13+, Node 22+, and Rust 1.85+ baselines remain unchanged.
Machine-width profiles, custom source/test directories, generation manifests,
and user ownership of adapters/build files remain supported. Framework-specific
strategies stay separate from reusable runtime source.

GADTs, indexed families, and general dependent types remain future work. See
[the language reference](LANGUAGE.md) and the target guides for native type
representations and framework-specific refinement/shrinking limits.

## Examples and release acceptance

Bundled examples cover reverse involution, sorting idempotence/sortedness/length/
permutation, nested presence, products/sums, exhaustive matches, total functions,
and recursive payload refinements. Release acceptance includes compiler and
native/WASM checks, native execution on all eight targets, deliberately incorrect
adapters, independent formatting/syntax checks, regeneration protection, and
installation of the packed npm artifact. Publication is a separate step.
