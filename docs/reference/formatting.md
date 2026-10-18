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
| Python | PEP 8: four-space indentation, 79-column code, 72-column comments and docstrings, two blank lines between top-level definitions |
| JavaScript, TypeScript | Two-space blocks, four-space continuations (Google JavaScript line wrapping), single-quoted strings, 80 columns, binary operators at the end of a wrapped line |
| Go | `gofmt` |
| Haskell | 80 columns, spaces for indentation |
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
