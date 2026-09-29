# LawSpec 0.10.0

## Existing application models

Native bindings connect LawSpec products and sums to existing application types
on Java, Python, JavaScript, TypeScript, Go, Haskell, Kotlin and Rust. Configure
constructor and field mappings, bind adapter declarations to existing functions,
or supply paired conversion hooks for representations requiring custom code.
Bindings resolve against typed declaration identities; they do not change the
meaning of arithmetic, equality, definitions or refinements.

Checked bridges compose through generic and recursive types and the built-in
containers. They preserve exact numeric values, Symbol identity and distinct
absence states. Invalid native inputs, results, generator samples and shrink
candidates fail with context.

## Native generators

Factories return their framework's generator: JetCheck, Hypothesis, fast-check,
Rapid, Hedgehog, Kotest or Proptest. Generic factories receive child generators.
Composition retains native shrinking. Explicit examples, deterministic boundaries
and finite-domain enumeration still run when the factory's distribution excludes
those values.

A factory can ignore an uninhabited parameter, as in `Phantom Empty`. Requesting a
value from that parameter fails generation; it cannot turn a property into a
vacuous success. Finite inhabited containers such as `List Empty` still enumerate.

Optional `stub: true` generator bindings create user-owned implementation files.
Regeneration preserves edits and reports changed factory signatures for review.

## API and migration

Native binding requests negotiate schema 4. Schema 3 remains supported for
specifications without bindings. Structured native references and strict
configuration validation prevent older compilers from silently ignoring mappings.
Go additionally supports explicit import aliases; Rust binds tests to the
application library's type identities.

Existing adapter files cannot be overwritten by adopting a binding. Move their
implementations into the application module and save the old adapters before
generation. Generated source bridges, test helpers and user-owned application
files retain separate placement and ownership. See the
[migration guide](API-MIGRATION.md#schema-4-native-bindings) and
[ownership instructions](NATIVE-BINDINGS.md#ownership-regeneration-and-migration).

## Runnable payment projects

`lawspec examples --example payments` exports a project for every target; use
`--target rust` or another language to select one. Each project includes an
application model, native generator, configuration, build files and instructions.
The shared specification checks exact fees, currency preservation, sum payloads,
ordered archives, duplicates and absence. Re-exporting preserves application
edits and the separate compiler generation manifest.

Both 32-bit and 64-bit logical machine profiles and readable/compact output are
covered by the acceptance matrices. Java 25+, Python 3.13+ and the other published
toolchain baselines remain unchanged. Python output follows PEP 8.

GADTs, dependent indices and cross-unit packages remain subsequent work.
