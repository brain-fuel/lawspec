# 0.9.0 release acceptance

Scope is the structural-data, total-definition, and formatting work described in
the first sections of `PLAN-0.9.md`. Python follows PEP 8. GADTs and general
dependent types remain outside this release. Publishing is separate.

Implementation and release acceptance are complete as of 2026-09-27. No
publication, tag, or Git push is claimed by this report.

## Language and runtime evidence

The compiler suite passes 478 examples (`.artifacts/haskell-scalar-tests.log`).
Its source checks cover kinds/arity, contextual literals, polymorphic
specialization, products/sums, exhaustive matching, structural termination,
definedness, refinement proofs, finite domains, boundaries, and rejected
programs. See `SourceDataSpec`, `StructuralSpec`, `GenericDefinitionSpec`,
`TotalSpec`, `DefinitionContractProofSpec`, `PayloadSpec`, and `PayloadProofSpec`.
`DocumentSpec` checks required layout, literal payloads, and token separation.

All eight targets have executable native-data, definition, constructor-contract,
and payload integration harnesses under `tools/`. These cover typed native
wrappers, recursive generation, native shrinking, wrong tags/fields, nested
absence, Symbol identity, guarded evaluation, custom layouts, and edited-adapter
preservation. Evidence includes `.artifacts/*-definitions-integration.log`,
`*-source-definition-contract-integration.log`, `*-field-properties.log`, and
`*-payload-emission.log`. Harness scope and framework-specific limits are
documented in each target guide and `REFINEMENTS.md`.

The public recursive-refinement example executes on all eight targets at both
widths/layouts (32 configurations): `.artifacts/recursive-refinements-*.log`.
The final Haskell layout additionally passes the four recursive configurations,
scalar examples and all 57 independent exact-arithmetic vectors, four faulty
scalar adapters in each layout, six payload mutants, and four constructor
mutants (`.artifacts/haskell-scalar-*.log`). A GHC parsed-AST comparison confirms
that manual scalar-runtime formatting preserves the pre-format program.
The versioned Rust runtime passes 22 tests (`release-09-rust-runtime.log`).

## Formatting and distribution evidence

| Output | Current full-corpus result | Evidence in `.artifacts/` |
| --- | --- | --- |
| Java | 250 artifacts match Google Java Format | `java-formatting-current.log` |
| Python | 238 artifacts pass PEP 8 and AST parity | `python-style-report.json` (empty) |
| JavaScript/TypeScript | 524 artifacts pass Google-layout rule checks and AST parity | `web-formatting-current.log` |
| Go | 338 artifacts match gofmt | `go-formatting-current.log` |
| Haskell | 460 artifacts pass 80-column checks and GHC AST parity | `haskell-scalar-formatting.log` |
| Kotlin | 366 artifacts pass compiler parsing, style rules, and AST parity | `kotlin-formatting-current.log` |
| Rust | 278 artifacts match rustfmt | `rust-formatting-current.log` |

All eight scaffold targets pass readable/compact initialization, configuration,
nested placement, machine profiles, and preservation of user-owned build files
(`scaffold-formatting-current.log`). Independent message fixtures check Unicode,
escapes, large integers, and diagnostic text in both layouts.

Native/WASM parity passes the recursive example and two diagnostic fixtures at
both widths/layouts on all targets (96 generation comparisons), using the final
0.9 build (`release-09-parity.log`). The broader bundled-corpus run passes all
800 generation comparisons and check/expand comparisons for 25 fixtures at both
widths (`release-09-parity-full.log`).
Build fingerprints, embedded runtimes, exhaustive API TypeScript visitors, and
the 61-module compiler/emitter boundary checks pass.

The pre-version-bump npm suite passed all 40 tests. The candidate archive installed
JavaScript and Rust projects, executed their generated tests, checked regeneration,
and used the installed structural API on all eight targets/widths/layouts
(`package-candidate-current.log`). The final 0.9 archive also passes the same
installed checks (`release-09-package.log`). Its 53 packaged files match `npm/`
byte-for-byte. The final 0.9 npm suite also passes all 40 tests
(`release-09-npm-tests.log`).

## Release artifacts

Package metadata, CLI version, Cabal packages, and the runtime conformance crate
are 0.9.0. Native and WASM builds are rebuilt. Bundled references and examples
match their source copies. `RELEASE-0.9.md` is included in the npm manifest and
build-copy step. The verified final archive is
`.artifacts/package-smoke/lawspec-0.9.0.tgz`, with SHA-256
`7fb4f02a9837a21712dec3e4924775db2103e12c954fe6811efd395760caa90e`.
All suites and installation checks above completed successfully.
