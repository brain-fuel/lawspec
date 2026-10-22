# LawSpec

**State the law once. Check it everywhere.**

LawSpec is a specification language for the laws your code must obey. It
compiles reusable laws and concrete examples into native property-based tests
and implementation adapters for Java, Python, JavaScript, TypeScript, Go,
Haskell, Kotlin, Rust, C#, F#, Swift, Erlang, Elixir, Gleam, Clojure, Groovy and
Scala. The compiler is written in Haskell and distributed on npm as prebuilt
WebAssembly, with a Node CLI and a typed JavaScript API.

The canonical authoring examples below target 0.25.0, the minor in preparation
on `main`.
Install the development checkout as shown below. For released 0.24.0, use the
[0.24.0 documentation](https://github.com/brain-fuel/lawspec/tree/v0.24.0).

## Features

- **Reusable laws.** A prelude of [round-trip, equivalence and algebraic laws](docs/reference/prelude-algebra.md), and your own generic laws.
- **Examples with expected results** that [pin each law down](docs/reference/language/laws-and-examples.md).
- **Native tests** with each [target's framework, generators and shrinkers](docs/how-to/targets/index.md).
- **A full scalar catalog** with [exact arithmetic](docs/reference/primitives.md) that never wraps.
- **Structural data**: [lists, `Maybe`, `Either`, products and sums](docs/reference/language/types-and-data.md).
- **Refinements and contracts** with [dependent generation](docs/reference/refinements.md) that constructs valid inputs.
- **Automatic definition checks** for [exhaustiveness, termination, definedness and contracts](docs/reference/language/definitions.md), with deliberately deferred postconditions enforced at runtime.
- **Indexed families** such as [length-indexed vectors](docs/reference/language/indexed-families.md), with proved indices.
- **Domain modeling** with [wrappers and workflows](docs/reference/language/domain-modeling.md).
- **Imports and versioned packages** of [shared laws and types](docs/reference/language/imports-and-packages.md).
- **Optional Z3 law proofs** through an [explicit solver host](docs/explanation/smt-proof.md), with task identities, limits and outcomes recorded.
- **Evidence** for every obligation: [proved, exhaustively checked, property tested, runtime checked or assumed](docs/reference/language/evidence-and-discharge.md).
- **Native bindings** to [your existing domain types and generators](docs/how-to/bind-native-types.md).
- **Safe regeneration**: [your adapters and build files stay yours](docs/explanation/ownership-and-regeneration.md).

## Install

Node 22+ and the selected target's build tools are required. No Haskell
toolchain is needed. The reference platforms are macOS and Linux.

The checkout includes the development WASM package. To try it in a **new, empty
directory**, initialize before installing, so that LawSpec can create
`package.json` and its test script:

```sh
git clone https://github.com/brain-fuel/lawspec.git lawspec
mkdir lawspec-example
cd lawspec-example
node ../lawspec/npm/bin/lawspec.mjs init --target javascript
npm install --save-dev ../lawspec/npm
npx lawspec --version
npx lawspec check
npx lawspec explain 'example.codec::codec'
npx lawspec doctor
```

New projects start with `verification.layers: []`: intrinsic definition checks
run, and no law verification is selected. Set `verification.layers` to
`["property", "examples"]` in `lawspec.json`, then run `npx lawspec generate`.
Implement `src/example/codec.mjs`, then run `npm test`:

```javascript
export function itoa(value) { return String(value); }
export function atoi(value) { return Number(value); }
```

In an existing project, install the checkout's `npm` directory first, then run
`npx lawspec init --target javascript`. Existing build files are preserved;
apply the printed setup instructions before generating. See
[Install LawSpec and create a project](docs/how-to/install-and-init.md).

## Example

```lawspec
unit example.atoi_codec

itoa :: Int32 -> Text
atoi :: Text -> Int32

law "|round trip| is
  definition :
    apply law "|left inverse| atoi itoa
  end definition
  description :
    "applying {itoa} and then {atoi} recovers the original integer"
  end description
  example "|negative integers use a minus sign and round-trip unchanged| :
    x = -42
    expect itoa x = "-42"
    expect atoi (itoa x) = -42
  end example
end law
end unit
```

`lawspec explain` shows the final property:

```text
for all (x :: Int32) . atoi (itoa (x)) = x
```

The generated tests check the example, signed 32-bit boundary cases and
randomized inputs against your `itoa` and `atoi`, on whichever targets you
configure.

## Targets

| Target | Build setup | Test libraries | Test command |
| --- | --- | --- | --- |
| `java` | Maven, JDK 25, release 25 | JetCheck 0.3.0, JUnit Jupiter 5.14.x | `mvn test` |
| `python` | Python 3.13 or 3.14, pyproject | pytest 8.4.x, Hypothesis 6.135.26+ (6.x) | `python -m pytest` |
| `javascript` | Node 22+, npm, ESM | fast-check 4.x, node:test | `npm test` |
| `typescript` | Node 22+, npm, TypeScript 5.9.x, ESM | fast-check 4.x, node:test | `npm test` |
| `go` | Go modules, Go 1.22–1.26 | Rapid 1.2.0, testing | `go test ./...` |
| `haskell` | Stack, GHC 9.10, LTS 24.58 | Hspec 2.11, Hedgehog 1.5, hspec-hedgehog 0.3 | `stack test` |
| `kotlin` | JDK/JVM 25, Gradle 9.1–9.3, Kotlin 2.3.21 | Kotest 5.9.1 | `gradle test` |
| `rust` | Rust 1.85+, edition 2024, Cargo | Proptest 1.11.0 | `cargo test` |

See the [target guides](docs/how-to/targets/index.md).

The [Prolog target](docs/reference/prolog.md) uses SWI-Prolog 10+, Janus and
Python 3.13+, with PLUnit slots over pytest and Hypothesis. Its public interfaces
are implemented; the full shared native acceptance matrix remains open.

The [artifact targets](docs/reference/artifact-targets.md) generate HCL
variables and values, YAML configuration and schemas, ANTLR data grammars,
and Make pipelines. These targets emit no application law tests.

## Documentation

The [documentation](docs/index.md) has tutorials, how-to guides, a reference
for the language, CLI, configuration and API, and explanations of the design.
Release history is in the [changelog](CHANGELOG.md). To work on LawSpec itself,
see [contributing](docs/how-to/contribute.md).

Syntax highlighting is available as a [VS Code extension](editors/vscode/README.md).

## License

MIT. See [LICENSE](LICENSE).
