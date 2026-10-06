---
id: lawspec.how-to.generate-and-check-in-ci
kind: how-to
title: Generate tests and check them in CI
---
# Generate tests and check them in CI

This guide covers the everyday loop: check the specification, inspect laws and
evidence, generate tests, and keep generated files up to date in continuous
integration. Every command and option is listed in the
[CLI reference](../reference/cli.md).

## Check the specification

```sh
npx lawspec check
```

`check` parses, resolves, type-checks and expands every law. It needs no target
build tools. It prints the number of laws and a summary of how the obligations
are discharged:

```text
Checked 1 law(s). Evidence: 0 proved, 0 exhaustively checked, 1 property tested, 0 runtime checked, 2 assumed / external.
```

A law over checked definitions that the compiler can refute on a finite domain
fails here with code `refuted`. When a target has native bindings, `check`
validates them too. Add `--json` for the full compiler result.

## Inspect a law

```sh
npx lawspec explain 'example.atoi_codec::itoa and then atoi yields a'
```

`explain` prints each step of the law's expansion, the final property, and the
inputs and expected results of each example. It does not run your adapters.
Without an argument it explains every law. The argument is
`<unit>::<law name>`, without backticks.

## List the evidence

```sh
npx lawspec evidence
npx lawspec evidence example.atoi_codec
npx lawspec evidence 'example.atoi_codec::itoa and then atoi yields a'
```

`evidence` lists every obligation, grouped by status from `PROVED` to
`ASSUMED / EXTERNAL`, with its claim and the reason for its status. For the
starter project:

```text
PROPERTY TESTED (1)
  law example.atoi_codec::itoa and then atoi yields a: (atoi (itoa (x)) == x)
    the generated tests check 100 generated cases, 4 boundary cases and 2 examples; relies on example.atoi_codec::atoi, example.atoi_codec::itoa

ASSUMED / EXTERNAL (2)
  adapter example.atoi_codec::itoa
    native implementation taken on trust; called by 1 law(s)
  adapter example.atoi_codec::atoi
    native implementation taken on trust; called by 1 law(s)
```

Filter by a
unit or by `unit::declaration`. With native bindings, binding, codec, generator
and native-function obligations are listed with their target. See
[evidence and discharge](../reference/language/evidence-and-discharge.md).

## Generate

```sh
npx lawspec generate
```

`generate` does three things, in order:

1. It plans every file for every selected target.
2. It runs the same environment checks as `doctor`, and validates every output
   against the ownership manifest.
3. Only if everything passes, it writes the files.

It fails before writing anything if a target is incompatible or an output would
overwrite a file LawSpec does not own. At the end it prints the command that
runs each target's tests, and the required signature of any adapter whose
contract changed.

Use `--target <language>` to generate for one configured target only.

### Preview changes

```sh
npx lawspec generate --dry-run
```

`--dry-run` prints the planned file operations and writes nothing.

### Fail when generated files are stale

```sh
npx lawspec generate --check
```

`--check` plans generation and exits with status 1 if any generated file needs
to be created, updated or deleted. It writes nothing. `--dry-run` and `--check`
cannot be combined.

## Commit the right files

Commit:

- your `.lawspec` sources and `lawspec.json`;
- the generated tests and runtime sources;
- `.lawspec/generated.json`, the ownership manifest in each target root;
- your adapters.

The manifest records a hash of every generated file. Without it, LawSpec
cannot tell a file it generated from one you wrote, and it refuses to
overwrite either. See [ownership and regeneration](../explanation/ownership-and-regeneration.md).

## A CI job

A CI job for one target needs Node 22+, the target's toolchain and its test
dependencies. Then:

```sh
npm ci
npx lawspec check
npx lawspec doctor --target python
npx lawspec generate --check --target python
python -m pytest
```

`generate --check` catches a specification change that someone forgot to
regenerate. The native test command then runs the committed tests. Use `--json`
on `check`, `doctor` and `generate` for machine-readable output.
