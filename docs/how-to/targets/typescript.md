# Set up TypeScript

## Requirements

- Node 22 or later.
- `package.json` with `"type": "module"`.
- Development dependencies: fast-check 4.x, TypeScript 5.9.x and `@types/node`
  22.x.
- A `tsconfig.json` with `module` NodeNext, `target` ES2022 or later,
  `rootDir` `.`, `outDir` `dist`, emission enabled, and `include` covering the
  source and test directories.

## Create the project

```sh
npm exec --package=lawspec@0.15.1 -- lawspec init --target typescript
npm install --save-dev lawspec@0.15.1
npx lawspec doctor
npx lawspec generate
npm test
```

In a directory without build files, `init` creates:

- `package.json` with fast-check 4.10.2, TypeScript 5.9.3, `@types/node`
  22.20.4 and the test script
  `npm exec -- tsc -p tsconfig.json && node --test dist/test/*.test.js`;
- `tsconfig.json` with `target` ES2022, `module` NodeNext, `rootDir` `.`,
  `outDir` `dist`, `strict`, and
  `include: ["src/**/*.ts", "test/**/*.ts"]`.

In an existing project:

```sh
npm install --save-dev fast-check@4.10.2 typescript@5.9.3 @types/node@22.20.4
```

`doctor` rejects `exclude` entries other than `node_modules` and `dist`,
because it cannot verify that the generated files are still compiled.

## Layout

LawSpec emits `.ts` modules with `.js` import paths for NodeNext compilation.
The layout matches [JavaScript](javascript.md#layout): adapters and generated
runtime, data and definitions in `src`, tests in `test`.

## Native representations

The representations are those of [JavaScript](javascript.md#native-representations),
with types:

- `Maybe a`, `Either a b` and your products and sums are generic unions of named
  variant classes. They keep payload types and nominal variant identity,
  including recursive fields and phantom parameters.
- `Nullable a` and `Optional a` are `data.Presence<A>`.
- An abstract `Integer` result has type `number | bigint`; `Integer` arguments
  are `bigint`.

## Checked definitions

Definition entry points are strictly typed. For
`definition increment (x :: Int8) :: BigInt is x + 1 end`, the entry point
takes `symbols: Map<string, symbol>` and `value0: number`, and returns
`bigint`. Runtime validation still rejects out-of-range and fractional numbers
from untyped callers.

The definition modules pass strict TypeScript without `any` or
`@ts-nocheck`. The generated schema and numeric runtime files use
`@ts-nocheck`; their public declarations are checked separately.

## Generation and formatting

As [JavaScript](javascript.md#generation-and-shrinking).
