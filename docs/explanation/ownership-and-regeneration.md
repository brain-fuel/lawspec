# Ownership and regeneration

A code generator that shares a directory with people has to answer one question
reliably: whose file is this? LawSpec answers it explicitly for every file, and
refuses to guess.

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

## Formatting and adapter updates

Your adapter will never match the compiler's stub byte for byte: you have
implemented it. So LawSpec compares interfaces, not implementations. For every
adapter it keeps a canonical readable reference of the stub, and reports an
update only when that reference changes. Switching between readable and
compact output therefore never produces a false update report.

## Native bindings

Binding an adapter to an existing function turns its file into a generated
bridge. This is where ownership matters most: your adapter is at exactly the
path the bridge needs.

LawSpec will not overwrite it, even if it is still the untouched stub. Move the
implementation into your application module, move the old adapter out of the
way, and regenerate. Do not edit the manifest to make your code look
generated.

Removing bindings works the other way round. LawSpec keeps the former bridge as
a user-owned file, rather than silently replacing it with a stub, and reports
the adapter signature you now need. Generated binding helpers that are no longer
needed can be removed.

Changing the layout relocates generated files. Application files stay where
they are until you move them.

## Example exports

`lawspec examples --example payments` writes whole projects in which every file
is yours. It keeps its own manifest, `.lawspec/example.json`, separate from the
compiler's `.lawspec/generated.json`. Exporting again preserves your edits and
reports changed bundled files for review, without disturbing generated code.
