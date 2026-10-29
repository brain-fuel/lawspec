---
id: lawspec.reference.formatting
kind: reference
title: Formatting
---
# Formatting

The owner's Allman-brace preference takes precedence. Then follow Google's
language guide, and use established language conventions where Google has no
guide. Keep the standard formatter's layout when it cannot support Allman; Go's
brace placement is required by its grammar. These rules cover compiler output,
runtime copies, scaffolds, Learn and MCP/project tooling and their source templates.
ref:DEC-google-style-allman

Compiler target printing remains pure and deterministic: native and WebAssembly
builds print the same bytes without downloading or invoking a formatter. The
repository build and learning workspace use pinned local formatters. A formatter
check establishes layout conformance, not compliance with every API-design rule
in a style guide. Explicit compact output remains available.

## LawSpec source

`lawspec fmt [paths...]` parses source and formats it with two-space block and
continuation indentation and an 80-column target. It accepts unfinished typing
and imports. `--compile` additionally checks definitions before and after
formatting; mandatory definition validation remains part of that compiler check.
`--check` reports files that need formatting in either mode without writing.
Independent syntax errors are reported together across the input files, with
locations for each occurrence. Recovery resumes at grammar boundaries such as
fields, collection items, table rows, law sections and declarations. Damaged
quoting or missing delimiters can limit how much of the remaining input can be
parsed reliably. Syntax errors prevent every write. Recovery never supplies an
accepted program or verification evidence.
The CLI and editor share the compiler's parsed block and expression inventory, including
continuation indentation for nested applications and expectations.

Formatting preserves comments, literal values, phrase spelling, section order
and the author's valid annotation, equality and infix wording. Long literals and
declaration names can exceed the column target. A phrase declaration keeps its
name together with its declaration keyword and `is`. Repeated formatting leaves
the same result.

Quantified claims put the header, indented body and matching closer on separate
lines. A short arithmetic body stays together rather than wrapping against the
header's width:

```lawspec
law "|every row contributes four seats| is
  definition:
    for all (rows :: Int32 where rows >= 0 and rows <= 40) =>
      seats rows = rows * 4
    end for all
  end definition
end law
```

The same layout applies to existential claims and `given` scopes, including
nested claims. Long headers break between complete input binders, with their
separator aligned beneath the opening keyword. Comments and multiline literal
contents retain their authored boundaries. ref:DEC-lawspec-quantifier-layout

Record types use separate brace lines, one field per line, and no field commas,
including short records. Nested records add two spaces per level. Record values,
patterns and tuples retain their separators. For example:

```lawspec
unit formatting.records
type TimePoint is a record
{
  year :: Int32
  month :: Maybe Int32
  day :: Maybe Int32
}
end type
type OtherThing is a record
{
  year :: Int32
}
end type
end unit
```

The SDK's `format` operation and editor formatting retain checked formatting by
default; SDK callers can select `compile: false` to format syntax alone.

## Source highlighting

The documentation site and editor use the same TextMate grammar and pinned
TextMate/Oniguruma tokenizer versions. Phrase names, Unicode identifiers,
keywords and types therefore receive the same scopes. The website maps those
scopes to its existing colors; highlighting preserves the source text.

The site hosts the grammar and tokenizer assets locally, including their
licenses. Vendor URLs include their locked versions. If highlighting assets
cannot load, the source remains readable and compiler checks remain available.
Generated native code uses highlight.js.

## Readable output

| Target | Layout |
| --- | --- |
| Java | Google Java's two-space blocks, four-space continuations and 100 columns, with Allman braces; Checkstyle checks the owner profile. `node tools/java-style.mjs <complete Java files...>` uses pinned Eclipse JDT 3.47.0/JFace Text 3.31.100 and `test/locks/java-eclipse.xml`. The profile starts from Google's archived Eclipse configuration and adds owner overrides and current record settings. |
| C# | Google's two-space blocks and 100 columns, with Allman braces; `.editorconfig` configures `dotnet format`. |
| Kotlin | Google's Android Kotlin guide: four-space blocks, 100 columns and sorted imports; pinned ktfmt's Kotlin layout. |
| Swift | Google's Swift guide and pinned swift-format: two spaces, 100 columns; the formatter's standard brace layout. |
| Python | Google Python's 80-column limit and four-space blocks; pinned `ruff format --isolated --line-length 80`. |
| JavaScript, TypeScript | Google's gts Prettier settings: 80 columns, two spaces, single quotes, no bracket spacing, unparenthesized single arrow parameters and trailing commas; Prettier **3.9.10** with **prettier-plugin-brace-style 0.10.4**, `braceStyle: allman`. |
| Rust | Google's Rust guide plus the owner's Allman override; `rustfmt.toml` pins 100 columns, module-level import grouping, lower-case hex and brace placement. Formatting alone uses **nightly-2026-10-22** because these rustfmt options require nightly. Generated Rust and its compilation/MSRV gates remain stable. |
| Go | Google Go guidance and pinned `gofmt` (Go 1.26.5); grammatical same-line braces. |
| Haskell | Google Haskell guidance and pinned `ormolu` (0.9.0.0), conventionally near 80 columns. |
| F# | Pinned Fantomas **8.1.0**; four-space blocks and its standard F# layout. |
| Other languages | Their existing pinned formatters and language conventions; no invented Google profile. |

The shared web configuration is `.prettierrc.json`. Run
`node tools/code-style.mjs [--check] <paths...>` for first-party web sources;
`lawspec-dev generate --check` also checks the fully rendered repository outputs.
Install build dependencies with `npm ci --prefix learn` first. This uses the
third-party brace-style plugin, without a second competing ESLint formatter.
The browser build supplies Prettier standalone's built-in parsers explicitly,
including the plugin's internal formatting call; it does not fork the plugin.

Primary style sources: [Google's index](https://google.github.io/styleguide/),
[TypeScript](https://google.github.io/styleguide/tsguide.html),
[gts settings](https://github.com/google/gts/blob/main/.prettierrc.json),
[Python](https://google.github.io/styleguide/pyguide.html),
[Rust](https://google.github.io/styleguide/rustguide.html),
[Swift](https://google.github.io/swift/) and
[the brace-style plugin](https://github.com/ony3000/prettier-plugin-brace-style).

### Rust design review

The new Rust guide also governs imports, error handling and APIs. The runtime
uses established `Result` values for ordinary evaluation errors; checked
invariants use pattern matching or `expect` with an explanation. Generated native
conversion imports name their helpers explicitly. Prelude imports and `super::*`
in inline test modules use the guide's stated exceptions. Closed LawSpec domains
retain exhaustive enums: changing their cases requires coordinated changes, as
per the guide's ontology exception. Source-defined names and native ABI remain
stable rather than being renamed by a formatting operation.

There is a material remaining incompatibility: the existing Rust native ability
ABI transports typed `Failure`/`Fail` values through panic payloads, and `attempt`
catches those values. That is semantic control flow, outside Google's narrow
unexpected-panic containment exception. It must not be described as compliant.
Replacing it requires a coordinated fallible ABI change; this style change
preserves the specified failure behavior. Cleanup, search reporting, actor and
harness panic boundaries also need individual classification before a blanket
Rust-guide conformance claim. Their presence is visible in
`runtime/lawspec_runtime.rs` and `runtime/lawspec_harness.rs`.

### Format before running a lesson

Every Run mode first formats the complete project on the device: LawSpec with
its syntax formatter, F# with Fantomas on .NET WebAssembly, JS/TS with the pinned
Prettier/plugin profile above. Dedicated workers keep tooling off the interface
thread. The successful result replaces the visible draft and is saved before
compiling and executing that exact snapshot. Syntax errors prevent partial
rewrites and execution; failed persistence also prevents execution. Cancellation
terminates the workers and each phase has a timeout.

Formatting does not validate a property or establish proof. Mandatory definition
validation and language checking follow it. F# execution still uses Fable and
the JavaScript harness, separately from native .NET/FsCheck evidence. The course
sends no source to a formatting service. See `learn/REVIEW.md#format-before-run`
for the browser checks and measured loading costs.

Generated scaffolds are readable too: `init` expands Maven POMs and Gradle
blocks, and writes indented JSON.

Long string literals are split into escaped chunks where a target's line limit
requires it. Import lines and unbreakable source excerpts in comments may exceed
the limit.

## Compact output

`--minify` on `init`, `generate` and `examples`, or `minify: true` in a
generation request, selects compact output. It keeps every newline,
indentation and separator the language requires, and keeps comments and literal
contents. For Python, compact output keeps Python's significant indentation.

The mode applies to one invocation and is not stored in the project. Switching
modes:

- never rewrites user-owned adapters, because adapters are compared against the
  compiler's canonical readable stub;
- never produces a false adapter-update report;
- regenerates generated files in the new mode.

## Placement

Formatting never changes where files go. Generated runtime support and checked
definitions belong in source directories; framework-specific property helpers
belong in test directories. Both follow `sourceDir` and `testDir`.
