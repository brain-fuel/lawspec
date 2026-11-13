---
id: lawspec.explanation.ownership-and-regeneration
kind: explanation
title: Ownership and regeneration
---
# Ownership and regeneration

A code generator that shares a directory with people has to answer one question
reliably: whose file is this? LawSpec answers it explicitly for every file, and
refuses to guess. ref:DEC-adapter-ownership

## Three kinds of file

**Adapters are yours.** `generate` creates an adapter stub once per unit. From
then on the file belongs to you: implement it, or make it delegate to existing
application code. Regeneration never rewrites it. If the specification changes
the adapter's required signature, `generate` prints the new stub shape and you
apply it yourself.

**Generated files are LawSpec's.** Tests, runtime support, data types, schemas,
codecs, checked definitions and native-binding bridges are generated. Each
target root records them in `.lawspec/generated.json`, with a hash of each
file's content.

**Build files and application code are yours.** `init` creates build files only
in an empty project, and never edits existing ones. Application models, codec
hooks and generator factories are never touched. Optional generator scaffolds
are created once and then belong to you.

## How the manifest protects you

Because the manifest records exactly what LawSpec wrote, generation can tell
three situations apart:

- A generated file whose content still matches its hash can be updated or, if
  obsolete, deleted.
- A generated file whose content has changed has been edited. LawSpec refuses
  to overwrite or delete it.
- A file the manifest does not list is not LawSpec's, even if its content
  happens to match what LawSpec would write. LawSpec refuses to overwrite it.

Commit the manifest with the generated files. Without it, every existing file
looks unowned.

Generation is all-or-nothing. It plans every write for every target, checks
them all, and only then writes. Writes go through temporary files and atomic
replacement. If a file changes between planning and writing, generation aborts
before writing anything. Output paths cannot leave the target root or pass
through symbolic links.

## Placement is not ownership

Every artifact has an ownership (generated or user) and, separately, a
placement (source or test). Runtime support is generated source; adapters are
user source; property-testing helpers are generated test code; generator
factories are user test code. `sourceDir` and `testDir` move files by
placement, without changing who owns them.

## Generated directories

Moving by placement keeps generated files and yours in one tree. That suits a
repository that commits generated code. Many builds do the opposite: generated
source is written under the build directory, registered as an extra source
root, and never committed. Pointing `sourceDir` at such a directory would put
your adapters where cleaning the build deletes them.

A Java target can therefore also move files by ownership. With
`generatedSourceDir` and `generatedTestDir` set, each generated file goes to
the generated directory of its placement, and each file you own stays in
`sourceDir` or `testDir`:

| File | Ownership | Placement | Directory |
| --- | --- | --- | --- |
| Runtime, data types, codecs, checked definitions | generated | source | `generatedSourceDir` |
| Adapters | user | source | `sourceDir` |
| Tests, property-testing helpers, a harness's JUnit configuration | generated | test | `generatedTestDir` |
| Generator factories | user | test | `testDir` |

The compiler decides each path; the CLI only writes them. Java finds classes
by package, so a generated class compiles the same from either root, and the
files are byte for byte the ones the default layout has.

The generated directories can be deleted at any time. `lawspec generate` writes
them again with the same bytes: the compiler is deterministic, and
`.lawspec/generated.json` holds each file's hash. A missing generated file is
simply created. This holds whether or not you commit the manifest. Committed,
it records what the generated tree must contain; absent, there is nothing on
disk for it to protect. The protections above are unchanged for files that do
exist: an edited generated file is still refused.

Two consequences follow from not committing generated files. A clean checkout
does not compile until `lawspec generate` has run, so run it before the build
in CI. And `lawspec generate --check`, which fails when generation would change
anything, fails in a clean checkout because every generated file is missing;
it checks committed generated code, and there is none.

A [native-binding bridge](#native-bindings) is generated, so it goes to
`generatedSourceDir` too, under the adapter's class name. An adapter left in
`sourceDir` from before the bindings then declares the same class, and `javac`
reports the duplicate: move its code into the application and delete it.

Only the Java target has generated directories. Other targets keep one tree:
several of them resolve generated modules by relative path, so separating the
files needs more than a move.

## Formatting and adapter updates

Your adapter will never match the compiler's stub byte for byte: you have
implemented it. So LawSpec compares interfaces, not implementations. For every
adapter it keeps a canonical readable reference of the stub, and reports an
update only when that reference changes. Switching between readable and
compact output therefore never produces a false update report. ref:DEC-adapter-ownership

The reference names parameters by position (`value0`, `value1`), whatever the
stub you were given called them. A parameter's name is yours to choose in an
adapter, so naming one in the spec, or renaming it, reports no update; a
changed type, order or result does. ref:DEC-generated-parameter-names

## Native bindings

Erlang, Elixir and Gleam emit native function bindings in a separate generated
`lawspec_native_bindings.erl` module. Existing user adapters remain yours.
Removing the bindings removes the unedited bridge and creates any missing
adapter stubs; existing adapters need to implement the specification's types.
An edited generated bridge is protected from removal.

The other targets use the unit's adapter file as the generated bridge. Your
adapter is at exactly the path the bridge needs.
ref:DEC-native-bindings-typed-identity

LawSpec will not overwrite it, even if it is still the untouched stub. Move the
implementation into your application module, move the old adapter out of the
way, and regenerate. Do not edit the manifest to make your code look
generated.

Removing bindings works the other way round. LawSpec keeps the former bridge as
a user-owned file, rather than silently replacing it with a stub, and reports
the adapter signature you now need. Generated binding helpers that are no longer
needed can be removed.

For targets supporting custom source and test roots, changing the layout
relocates generated files. Application files stay where they are until you move
them. Gleam requires its native `src`, `test` and `test-support` layout.

## Example exports

`lawspec examples --example payments` writes whole projects in which every file
is yours. It keeps its own manifest, `.lawspec/example.json`, separate from the
compiler's `.lawspec/generated.json`. Exporting again preserves your edits and
reports changed bundled files for review, without disturbing generated code.
