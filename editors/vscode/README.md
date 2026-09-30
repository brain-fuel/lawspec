# LawSpec syntax highlighting

A standalone TextMate grammar for LawSpec (`source.lawspec`), with VS Code
language registration for `.lawspec` files. This extension contains no executable
extension code and needs no language server or compiler installation.

It highlights:

- Laws, examples, declarations, refinements, constraints, and match expressions.
- The quantifier `` `for all` `` and backtick-quoted law names and invocations.
- Primitive and container types, constructors, and prelude helpers.
- Exact numeric literals, scalar constructors, absence values, and operators.
- Strings, Haskell-style character escapes, and `--` comments.

Scopes use standard TextMate categories so the active editor theme chooses the
colors. Unicode identifiers are supported. Highlighting is lexical; it does not
validate types or distinguish every user-defined constructor from a type name.
Use `lawspec check` for compiler diagnostics.

## Try it in VS Code

From the repository root, launch an extension development window:

```sh
code --extensionDevelopmentPath="$PWD/editors/vscode" examples/specs/scalars.lawspec
```

The status bar should show **LawSpec**. Use **Developer: Inspect Editor Tokens
and Scopes** to inspect `source.lawspec` and the individual token scopes.

To build an installable extension using Microsoft's packaging tool:

```sh
cd editors/vscode
npx @vscode/vsce package --no-dependencies
code --install-extension lawspec-language-0.1.0.vsix
```

This is a local extension, not a published Marketplace listing. Its version is
independent of the compiler release. The npm CLI package is unchanged.

## Reuse the grammar

[`syntaxes/lawspec.tmLanguage.json`](syntaxes/lawspec.tmLanguage.json) is the
canonical grammar, licensed under MIT. Other TextMate-compatible editors and
highlighting services can register it under `source.lawspec` with the `lawspec`
language identifier and `.lawspec` extension. No VS Code APIs are required.

## Verify changes

```sh
cd editors/vscode
npm install --ignore-scripts
npm test
```

Tests use VS Code's actual TextMate tokenizer and Oniguruma engine. They check
token scopes, keyword boundaries, Unicode identifiers, escapes, recovery from
unfinished law names, editor registration, and tokenization of the repository's
examples and parser fixtures. `lawspec-dev ci` runs them alongside the compiler tests.

## GitHub highlighting

GitHub does not load grammars from individual repositories. Its Linguist
registry must include LawSpec before `.lawspec` files or `lawspec` Markdown
fences receive this grammar on GitHub. The root `.gitattributes` therefore keeps
the existing Haskell fallback for now; this does not highlight LawSpec keywords.

An upstream contribution needs a `LawSpec` language entry with extension
`.lawspec`, scope `source.lawspec`, this grammar, licensed representative samples,
and evidence of independent usage. See
[Linguist's contribution requirements](https://github.com/github-linguist/linguist/blob/main/CONTRIBUTING.md).
Its adoption criteria include widespread usage; having a grammar alone does
not qualify a new language. No upstream submission or acceptance is implied by
this extension.

Once upstream support is released and deployed to GitHub, remove the Haskell
override from `.gitattributes` so native LawSpec detection can take effect.
