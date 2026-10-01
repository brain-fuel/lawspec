# Set up JavaScript

## Requirements

- Node 22 or later.
- `package.json` with `"type": "module"`.
- fast-check 4.x as a development dependency. Tests run with `node:test`.

## Create the project

```sh
npm exec --package=lawspec@0.17.0 -- lawspec init --target javascript
npm install --save-dev lawspec@0.17.0
npx lawspec doctor
npx lawspec generate
npm test
```

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

definition increment (x :: Int8) :: BigInt is x + 1 end
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

Two-space blocks, four-space continuations, single-quoted strings and an
80-column limit. See [formatting](../../reference/formatting.md).
