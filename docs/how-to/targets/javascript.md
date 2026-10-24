---
id: lawspec.how-to.targets.javascript
kind: how-to
title: Set up JavaScript
---
# Set up JavaScript

## Requirements

- Node 22 or later.
- `package.json` with `"type": "module"`.
- fast-check 4.x as a development dependency. Tests run with `node:test`.

## Create the project

Use the development checkout for the unpublished 0.25.0 authoring profile:

```sh
git clone https://github.com/brain-fuel/lawspec.git lawspec
mkdir lawspec-javascript && cd lawspec-javascript
node ../lawspec/npm/bin/lawspec.mjs init --target javascript
npm install --save-dev ../lawspec/npm
npx lawspec doctor
```

New projects select no law checks. In `lawspec.json`, set
`verification.layers` to `["property", "examples"]`, then run
`npx lawspec generate`. Implement the generated adapter stubs and run `npm test`.
Intrinsic definition checking always runs.

In a directory without build files, `init` creates a `package.json` with
`"type": "module"`, fast-check 4.10.2 and the test script
`node --test test/*.test.mjs`. In an existing project, add them yourself:

```sh
npm install --save-dev fast-check@4.10.2
```

## Layout

LawSpec emits ES modules with the `.mjs` extension.

| Files | Directory |
| --- | --- |
| Adapters (yours) | `src`, one module per unit, for example `src/example/atoi_codec.mjs` |
| Runtime, data and schema modules | `src` |
| Checked definitions: `lawspec_definitions/`, `lawspec_definition_bodies.mjs` | `src` |
| Tests and fast-check helpers | `test` |

The runtime and data modules do not depend on fast-check.

## Native representations

| LawSpec | JavaScript |
| --- | --- |
| `Int8`…`Int32`, `UInt8`…`UInt32` | `number` |
| Wider and arbitrary integers | `bigint` |
| `Integer` result | `bigint`, or a safe integral `number` |
| `Float32`, `Float64`, `CodePoint`, `CodeUnit16` | `number` |
| `Bool`, `Text`, `Char` | `boolean`, `string`, `string` |
| `Bytes` | `Uint8Array` |
| `Symbol` | `symbol` |
| `Decimal`, `Rational`, complex, raw text | Runtime support classes |
| `Duration` | The generated `Duration` class; its `value` is a `bigint` of microseconds |
| `List a` | `Array` |
| Products | A frozen class named after the type, from `lawspec_data` |
| `Maybe a`, `Either a b` and sums | Named variant classes from `lawspec_data` |
| `Nullable a`, `Optional a` | Tagged `data.Presence` values |
| `Unit` | A `void` return |

`Nullable` and `Optional` keep nested absence states distinct from each other
and from algebraic `Maybe`.

Checked conversions copy containers, reject sparse arrays and invalid fields,
check numeric ranges and the machine profile, reject fractional integer inputs,
and preserve raw text and bytes. LawSpec equality follows the schema, not
JavaScript object equality.

## Checked definitions

```lawspec
unit example.total

function increment (x :: Int8) -> Integer is x + 1 end function
end unit
```

```javascript
import {increment} from './lawspec_definitions/example/total.mjs';

const symbols = new Map();
const result = increment(symbols, 127); // 128n
```

The first argument is the Symbol context: calls sharing a map share fixture
identities. Exact integers use `bigint`, and Decimal and Rational arithmetic
never passes through `Number`. Failures name the definition.

## Generation and shrinking

Tests use fast-check's native arbitraries and shrinkers. Input guards use
fast-check preconditions, which keep its skip and shrink behavior. Whole-value
retries are bounded by `maxAttempts`; an exhausted search fails.

## Formatting

Output is what Prettier writes with its default settings: two-space
indentation, 80 columns, double quotes unless single quotes need fewer
escapes, semicolons and trailing commas. LawSpec lays it out itself, so
generation needs no formatter, and LawSpec's own acceptance checks every
generated project with `prettier --check`. `--minify` allows long lines. See
[formatting](../../reference/formatting.md).

## Names

Generated code uses the specification's names. Locals keep their source
names; a checked definition's body is a function named after it
(`_definitions.feeModel`), with `_2` only when two would share a name, and
a typed helper is named after its kind and type (`fromPairInt64Int64`). An
anonymous record is a class named from where it is used: the payload of a
`Declined` case is `DeclinedDetails`. Each test, definition and class has a
comment linking it to its source line, text is written as string literals,
and the assertions are the runtime's (`ls.check`), so a test module holds
only its laws.
