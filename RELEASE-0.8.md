# LawSpec 0.8.0

Rust support and a shared typed compiler boundary are the focus of this release.
The compiler remains implemented in Haskell and ships as prebuilt WebAssembly.

## Changes

- Rust 2024, with Rust 1.85 as the minimum toolchain, Cargo scaffolding, Proptest
  generation/shrinking, the complete scalar catalog, refinements, and contracts.
- An independent numeric Rust runtime with owned native bridges, exact arithmetic,
  checked conversions, direct IEEE rounding, raw text, Symbol identity, and
  distinct nested absence states. Proptest support is emitted separately.
- A typed core and proposition tree shared by all eight emitters. Resolved IDs,
  parsed source ranges, contextual literals, arithmetic evidence, and conversions
  survive elaboration. Emitters no longer import source syntax or inference.
- An independent core validator and evaluator. Testing plans distinguish semantic
  validity from execution feasibility and preserve dependent refinement domains.
- API schema v3 with explicit wire views and unchanged lossless scalar encodings.
  Explicit schema-v2 requests receive a migration diagnostic.
- Rust module wiring, custom layouts, Cargo preflight, adapter preservation,
  generation manifests, bundled examples, and installed-package coverage.
- Exact algebra and numeric currying examples. Logical `Integer` replaces their
  former modular Int32 contracts. Examples cover Int32 overflow, large products,
  Int32-minimum negation, and values beyond machine/safe-number bounds; deliberately
  wrapping adapters are rejected on every target.

See [Rust](RUST.md), [the language reference](LANGUAGE.md),
[primitives](PRIMITIVES.md), [refinements](REFINEMENTS.md), and
[API migration](API-MIGRATION.md).

## Compatibility and scope

Java 25+, Python 3.13+, and Node 22+ baselines remain unchanged. Existing LawSpec
source remains compatible. API clients must migrate to schema v3. All nonempty
plans emit scalar runtime source; existing Haskell projects need direct `text`
and `bytestring` dependencies in the component compiling that source. Build
files and implementation adapters remain user-owned.

Machine-sized domains use an explicit 32/64-bit profile. Native machine-sized
bindings reject an architecture mismatch. Rust adapters take owned values;
borrowing/lifetimes do not become LawSpec language constructs.

Collections, algebraic Maybe/Either, user-defined sums/products, total definitions,
GADTs, and general dependent types remain subsequent steps. Nullable/Optional
retain their existing interoperability semantics.

## Verification

The release gates include compiler/core tests, API/CLI and preservation tests,
native/WASM parity at both machine profiles, all eight native integration suites,
shared arithmetic conformance vectors, and deliberately incorrect adapters.
The packed npm archive is installed into fresh JavaScript and Rust projects and
used to generate, execute, and regenerate tests.

CI additionally exercises Rust 1.85 and stable in debug/release modes on real
32-bit and 64-bit Linux targets, plus architecture mismatch diagnostics. Publishing
requires successful CI for the exact release commit and verification that the
registry archive matches the tested package.
