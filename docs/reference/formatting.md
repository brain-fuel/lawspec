---
id: lawspec.reference.formatting
kind: reference
title: Formatting
---
# Formatting

Generated code is readable by default and follows each language's usual style.
Formatting is built into the compiler: it is deterministic, identical in the
native and WebAssembly builds, and never downloads or runs an external
formatter.

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
| Java | Google Java Format |
| Kotlin | Google Android Kotlin style guide: four-space blocks and wrapped arguments, 100-column lines, ASCII-sorted imports. Java support files use Google Java Format. |
| Python | `ruff format` with its default settings (88 columns), checked byte for byte by acceptance |
| JavaScript, TypeScript | Two-space blocks, four-space continuations (Google JavaScript line wrapping), single-quoted strings, 80 columns, binary operators at the end of a wrapped line |
| Go | `gofmt` |
| Haskell | `ormolu` (0.9.0.0), near 80 columns, checked byte for byte by acceptance |
| Rust | `rustfmt` |

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
