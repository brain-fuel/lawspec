# Use 32-bit and compact profiles

LawSpec has two independent output settings: the machine profile, which changes
what machine-sized integers mean, and the formatting mode, which changes how
generated code is laid out.

## Select a 32-bit machine profile

`IntSize`, `UIntSize` and `UIntPtr` are 64-bit by default. To specify a 32-bit
platform, set `machineBits` in `lawspec.json`:

```json
{"version": 1, "sources": ["laws"], "machineBits": 32, "targets": [{"language": "go", "root": "."}]}
```

Or pass it for a single command:

```sh
npx lawspec generate --machine-bits 32
```

`--machine-bits` overrides the configuration file. `init --machine-bits 32`
writes the setting into a new configuration. The compiler API accepts
`machineBits: 32 | 64`.

The profile sets the bounds of machine-sized types for literals, examples,
generators, boundary cases and native bridges. It is independent of the
computer that runs the compiler. Fixed-width types such as `Int32` and `UInt64`
behave the same in both profiles.

Go, Haskell and Rust map machine-sized types to native machine-sized integers.
Their generated bridges check that the executing architecture matches the
profile, and report an architecture mismatch otherwise. The check covers the
whole type, including fields of data variants that the current value does not
use. Other targets represent machine-sized values portably and enforce the
profile's range.

See [portable semantics and machine profiles](../explanation/portable-semantics-and-machine-profiles.md)
for the reasoning.

## Generate compact output

Generated code is readable by default. `--minify` selects compact output:

```sh
npx lawspec generate --minify
npx lawspec examples --minify
npx lawspec init --target kotlin --minify
```

- For `generate` and `examples`, it compacts runtime sources, declarations,
  definitions, adapter stubs and tests.
- For `init`, it compacts newly created build scaffolds and the configuration
  JSON.

The compiler API accepts `minify: true` on generation requests.

The mode applies to one invocation. It is not saved in `lawspec.json`, so
`generate` without `--minify` returns to readable output. Compact output keeps
the newlines, indentation and token separators each language requires, and
preserves comments and literal contents.

Switching modes does not touch your adapters. The ownership manifest compares
adapters against the compiler's canonical readable scaffold, so a formatting
change never produces a false adapter-update report. See
[formatting](../reference/formatting.md) for each target's readable layout.
