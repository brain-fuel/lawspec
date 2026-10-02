# Install LawSpec and create a project

## Requirements

- Node 22 or later.
- The build tools of the target language you choose. See
  [compatibility](../reference/compatibility.md) for the supported versions.

You do not need a Haskell toolchain. The reference platforms are macOS and Linux.

## Install from npm

Install [LawSpec from npm](https://www.npmjs.com/package/lawspec) as a
development dependency, and run the local CLI with `npx`:

```sh
npm install --save-dev lawspec@0.17.3
npx lawspec --version
```

## Start in a new, empty directory

In an empty directory, run `init` before you install local dependencies, so that
LawSpec can create `package.json` and its test script:

```sh
mkdir lawspec-example
cd lawspec-example
npm exec --package=lawspec@0.17.3 -- lawspec init --target javascript
npm install --save-dev lawspec@0.17.3
npx lawspec check
npx lawspec explain 'example.atoi_codec::itoa and then atoi yields a'
npx lawspec doctor
npx lawspec generate
```

`init` writes:

- `lawspec.json`, the [project configuration](../reference/configuration.md);
- `laws/atoi_codec.lawspec`, a starter specification with two functions,
  `itoa` and `atoi`, and a round-trip law with examples;
- the target's build files, when the directory has none.

Replace `javascript` with `java`, `python`, `typescript`, `go`, `haskell`,
`kotlin` or `rust` to choose another target. Each [target guide](targets/index.md)
lists the build setup `init` creates and the toolchain it expects.

## Implement the adapters

`generate` writes the tests and, the first time, one adapter file per unit. The
adapters are yours. The starter adapters throw until you implement them. For
JavaScript, implement `src/example/atoi_codec.mjs`:

```javascript
export function itoa(value) { return String(value); }
export function atoi(value) { return Number(value); }
```

Then run the tests:

```sh
npm test
```

The generated tests include the examples from the specification, signed 32-bit
boundary cases, and randomized properties that use the target framework's
shrinking and failure reporting.

## Add LawSpec to an existing project

Install LawSpec first, then run `init` in the project:

```sh
npm install --save-dev lawspec@0.17.3
npx lawspec init --target javascript
```

`init` preserves existing build files. Instead of editing them, it prints the
dependency and test-runner changes you need to make. Apply them before you
generate. [Configure an existing project](configure-an-existing-project.md)
covers the details.

## Editor support

LawSpec has a [syntax-highlighting grammar and VS Code extension](../../editors/vscode/README.md)
for keywords, types, refinements, literals and law names.

## Next steps

- [Generate tests and check them in CI](generate-and-check-in-ci.md)
- [Diagnose your environment with doctor](run-doctor.md)
- [Language syntax](../reference/language/syntax.md)
