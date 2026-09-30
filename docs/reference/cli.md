# CLI

```text
lawspec init --target <language> [--project <directory>] [--machine-bits <32|64>] [--minify] [--config <path>]
lawspec check [--target <language>] [--machine-bits <32|64>] [--json] [--config <path>]
lawspec evidence [<unit> | <unit>::<declaration>] [--target <language>] [--machine-bits <32|64>] [--json] [--config <path>]
lawspec explain [<unit>::<law>] [--machine-bits <32|64>] [--json] [--config <path>]
lawspec doctor [--target <language>] [--json] [--config <path>]
lawspec generate [--target <language>] [--dry-run | --check] [--minify] [--machine-bits <32|64>] [--json] [--config <path>]
lawspec package [--project <package directory>] [--machine-bits <32|64>] [--json]
lawspec examples [--example payments] [--target <language>] [--output <directory>] [--machine-bits <32|64>] [--minify] [--json]
lawspec --version
lawspec help
```

Run the locally installed CLI with `npx lawspec`. `<language>` is one of `java`,
`python`, `javascript`, `typescript`, `go`, `haskell`, `kotlin` or `rust`.

## Common options

| Option | Meaning |
| --- | --- |
| `--config <path>` | The project configuration file. Default: `./lawspec.json`. Relative paths in it resolve from its directory. |
| `--target <language>` | Select configured targets of this language. Without it, commands use every configured target. |
| `--machine-bits <32\|64>` | Override the configuration's machine profile for this command. |
| `--json` | Print machine-readable output. Errors are printed as `{"diagnostics": [...]}`. |
| `--minify` | Compact output. Accepted only by `init`, `generate` and `examples`. |

Options that take a value require one. Unknown options, and positional
arguments where none are expected, are errors. The command exits with status 1
on any error.

## `init`

Creates or extends a project configuration.

- `--target <language>` (required): the target to add.
- `--project <directory>`: the target's root, relative to the configuration
  file. Default: the configuration file's directory.
- `--machine-bits <32|64>`: write `machineBits` into the configuration.
- `--minify`: write compact scaffolds and configuration JSON.

When there is no configuration file, `init` creates `lawspec.json` with
`sources: ["laws"]` and a starter specification `laws/atoi_codec.lawspec`. It
fails if the starter already exists. When the file exists, it adds the target.
A target of the same language with the same root is an error.

If the target root has no build files (such as `pom.xml`, `pyproject.toml`,
`package.json`, `go.mod`, `stack.yaml`, `package.yaml`, a `.cabal` file,
`Cargo.toml` or Gradle files), `init` creates the target's scaffold. Otherwise
it leaves the build alone. Either way it prints the target's setup instructions.
It never overwrites a file.

## `check`

Parses, resolves, type-checks and expands every law, without target tools.
Prints the number of laws and the count of obligations with each
[evidence status](language/evidence-and-discharge.md). Validates the native
bindings of the selected targets. `--json` prints the compiler's full result.

## `evidence`

Lists every obligation with its stage, identity, claim and reason, grouped by
status from `PROVED` to `ASSUMED / EXTERNAL`.

- `<unit>` limits the list to one unit.
- `<unit>::<declaration>` limits it to one obligation, such as
  `example.atoi_codec::itoa and then atoi yields a` or `example.atoi_codec::itoa`.
  No match is an error.
- Binding, codec, generator and native-function obligations of the selected
  targets are included and labelled with their target.
- `--json` prints the `ObligationEvidence` records.

## `explain`

Prints each law's expansion trace, its final property, and each example's input
bindings and expected results. It does not run adapters.

- `<unit>::<law>` selects one law, named without backticks. No match is an
  error. Without it, every law is explained.
- `--json` prints the expanded law records with their expansions.

## `doctor`

Inspects each selected target's environment and prints `ready`, or a message
and setup instructions. Exits with status 1 if any target is not ready. See
[Diagnose your environment with doctor](../how-to/run-doctor.md).

## `generate`

Plans every selected target's files, runs the `doctor` checks, validates every
write against the ownership manifest, and then writes. Prints, per target, the
number of changes, the number of preserved adapters, any required adapter
signatures, and the command that runs the tests.

- `--dry-run`: print the planned changes; write nothing.
- `--check`: write nothing, and exit with status 1 if any file would change.
- `--minify`: compact generated code.

`--dry-run` and `--check` cannot be combined. If any target fails its checks,
nothing is written for any target.

## `package`

Checks a package directory on its own and prints its name, version, units, laws,
data types and dependencies.

- `--project <directory>`: the package directory, containing
  `lawspec-package.json`. Default: the current directory.

The package's own `dependencies` and `packages` fields are used to resolve its
dependencies. See [configuration](configuration.md#lawspec-packagejson).

## `examples`

Exports the bundled examples. Needs no configuration and no target tools.

- Without `--example`, compiles every bundled specification and writes its
  generated tests and adapter stubs to `<output>/<language>/`. Default output:
  `example_artifacts`.
- `--example payments` exports the runnable native-binding project for each
  target to `<output>/<language>/`. Default output: `native_payments`.
- `--target <language>` selects one target; default, all eight.
- `--output <directory>` must be relative, without parent traversal or symbolic
  links.

`examples` accepts only `--example`, `--target`, `--output`, `--machine-bits`,
`--json` and `--minify`. See
[Generate example artifacts](../how-to/generate-example-artifacts.md).

## Exit status

`0` on success. `1` when a command fails, `doctor` finds a target that is not
ready, or `generate --check` finds changes.
