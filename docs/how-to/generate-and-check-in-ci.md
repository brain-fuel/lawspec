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

`check` parses, resolves and type-checks the project, expands its laws and runs
mandatory definition validation. It needs no target build tools. New projects
select no optional law checks: their laws remain `not-verified` even when
intrinsic definition checks pass.

Choose the checks you want in the project's version-2 `lawspec.edn`. For
generated property tests and authored examples, set:

```json
{
  "verification": {
    "layers": ["property", "examples"]
  }
}
```

This plans those native checks; running them supplies execution evidence.
Other layers, such as `proof` and `exhaustive`, can be selected independently.
Selected compiler checks report established counterexamples with code
`refuted`. When a target has native bindings, `check` validates them too.
Add `--json` for the full compiler result. Optional layer selection never
disables definition checks or deferred definition-contract enforcement.

## Inspect a law

```sh
npx lawspec explain example.codec::codec --view developer
npx lawspec explain example.codec::codec --view business --json
```

`explain` presents the same typed requirement in developer, business, formal
or evidence form. It includes examples and available evidence without running
your adapters. Without a selector it explains every law. Use the exact
`<owner>::<name>` returned by `check --json`; preserve canonical phrase-name
delimiters and quote the entire selector for the shell. The
[CLI reference](../reference/cli.md#explain) gives a phrase-name example.

## List the evidence

```sh
npx lawspec evidence
npx lawspec evidence example.codec
npx lawspec evidence example.codec::codec
```

`evidence` groups obligations by status and gives the reason for each result.
`PLANNED` means a check is configured; `NOT VERIFIED` records an unverified
obligation. Completed native results appear after `lawspec test` records the
run. Property-test evidence describes those tested cases rather than a
universal proof. An incomplete witness search does not prove nonexistence.

Filter by a unit or by `unit::declaration`. With native bindings, binding,
codec, generator and native-function obligations are listed with their target. See
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

- your `.lawspec` sources and `lawspec.edn`;
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
npx lawspec test --target python --fresh
npx lawspec evidence example.codec::codec
```

`generate --check` catches a specification change that someone forgot to
regenerate. `test` runs the selected native checks and records their scoped
results; `--fresh` reruns them. Keep the verification-layer selections in
`lawspec.edn` under version control so the job runs the intended checks.
Use `--json` on `check`, `doctor`, `generate`, `explain` and `evidence` for
machine-readable output.
