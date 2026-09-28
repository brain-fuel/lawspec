# JavaScript and TypeScript backends

LawSpec emits ES modules. JavaScript uses `.mjs`; TypeScript uses `.ts` with `.js`
import paths for NodeNext compilation. Generated data and numeric support belong
in source directories and do not depend on fast-check. Generated properties use
fast-check's native generators and shrinkers.

## Native structural values

`List a` uses `Array<A>`. `Maybe a` and `Either a b` use named classes and, in
TypeScript, generic unions from `lawspec_data`. User products and sums likewise
have named native variant classes. TypeScript retains payload types and nominal
variant identity, including recursive fields and phantom parameters.

`Nullable a` and `Optional a` use tagged `data.Presence<A>` values, preserving
nested states separately from algebraic `Maybe`. Runtime checks enforce the
presence kind and payload domain. Scalar and structural presence values both use
the schema bridge when crossing native adapter boundaries.

Checked conversions copy containers, reject sparse arrays and invalid fields,
validate numeric ranges and machine profiles, and preserve raw text and bytes.
LawSpec equality follows the schema: NaN differs from itself, signed zeros compare
equal, and Symbols compare by identity. Ordinary JavaScript object equality is
not a replacement for structural LawSpec equality.

## Total definitions

Checked definitions produce reusable source functions:

```lawspec
unit example.total

definition increment (x :: Int8) :: BigInt is x + 1 end
```

```javascript
import {increment} from './lawspec_definitions/example/total.mjs';

const symbols = new Map();
const result = increment(symbols, 127); // 128n
```

The TypeScript entry point has `symbols: Map<string, symbol>`, `value0: number`,
and a `bigint` result. Native signatures preserve lists, products, sums, and
nested presence payloads. Runtime validation also rejects invalid number ranges,
fractional primitive inputs, and malformed values from JavaScript callers.
Failures identify the resolved definition.

The first argument shares Symbol fixture identity across calls within an example.
Equal descriptions in separate contexts do not create equal Symbols. Exact
integers use bigint; exact Decimal and Rational operations use the scalar runtime
without passing through Number arithmetic.

Public modules live under `lawspec_definitions/`, grouped by unit. Checked logical
bodies live in `lawspec_definition_bodies`. Both are generated-owned source.
Properties call the implementations directly; a definition never becomes an
adapter stub. Ordinary adapters remain user-owned. Support-module collisions and
bindings that shadow generated global access are rejected before output.

Definitions and properties share typed Core expression rendering. Match inputs
are evaluated once, only the selected branch runs, and Boolean guards
short-circuit. Totality validation checks structural descent and potentially
failing operations. Generic definitions specialize to concrete uses. Refined signatures become
checked contracts, and refinement predicates may call checked definitions.

## Formatting and verification

Definition output uses two-space blocks, four-space continuations, single-quoted
strings, and an 80-column layout. String tokens preserve escaped and raw payloads
in readable and compact modes. Compact mode removes optional document breaks.
The public `--minify` path covers runtime, declaration, definition, adapter, and
test artifacts. `tools/web-formatting-integration.mjs` checks the full bundled
corpus for formatting rules and readable/compact syntax-tree equivalence. It
records Prettier differences separately: Prettier's continuation layout is not
the Google four-space continuation rule used here.

`tools/web-definitions-integration.mjs` checks both targets and machine profiles,
strict TypeScript entry points and rejected assignments, source-only execution,
recursive properties, incorrect adapters, compact output, custom directories,
and regeneration protection. The implementation modules pass strict TypeScript
without `any` or `@ts-nocheck`. Existing schema and numeric runtime TypeScript
files still use `@ts-nocheck`; their public data declarations and definition
entry points are checked separately.

## Runtime source formatting

The checked-in JavaScript scalar runtime, schema runtime, and fast-check helpers
use two-space indentation, single quotes, and an 80-column target, formatted with
Prettier 3.6.2. `node tools/format-web-runtimes.mjs` checks these sources;
`--write` formats them. Set `LAWSPEC_PRETTIER` to the formatter's `index.mjs` when
it is not in `.artifacts/formatter-deps/prettier/`. This development tool never
runs in generated projects or during compiler requests.

Run `python3 tools/embed-runtimes.py` after runtime edits, then use `--check` to
verify that native/WASM source embedding is current. Both JavaScript and
TypeScript receive the reviewed runtime source, with the existing typed-schema
constructor annotation and module-extension adjustments for TypeScript.


Internal checked Core definition contracts now run at native and logical entry
points. Emission proves the obligations first; argument validation precedes
ordered preconditions, and result validation precedes postconditions. Contract
binders map explicitly to body inputs and the checked result. Refined source
signatures now produce these contracts through template proof and specialization.

`tools/portable-definition-contract-integration.mjs` exercises Python, JavaScript
and strict TypeScript with both machine profiles and layouts, without property
frameworks. It also verifies that deliberately corrupted results are rejected.
The fixture in `test/DefinitionContractFixture.hs` is shared with the JVM checks.


## Generated source style checks

JavaScript and TypeScript emitters use two-space blocks and four-space
continuations. The latter follows the [Google JavaScript line-wrapping guide](https://google.github.io/styleguide/jsguide.html#s4.5-line-wrapping).
Binary operators remain on the preceding line when an expression wraps.
Generated adapter error messages and tagged scalar values use the shared
single-quoted JavaScript literal renderer.

`tools/web-formatting-integration.mjs` independently parses both output modes
with TypeScript, compares their syntax trees and literal contents, and checks
quote choice, binary-operator breaks, continuation and statement-block indentation,
the 80-column limit, tabs, and trailing
whitespace. Module imports/re-exports and indivisible source excerpts on their
own comment line are explicit column exceptions. Ordinary prose and code remain
subject to the limit. Long scalar string values use escaped concatenated chunks;
property names remain single tokens. It runs
both machine profiles for the bundled examples and total-definition fixture.
Set `LAWSPEC_CORE` to the native compiler; optional `LAWSPEC_TYPESCRIPT` and
`LAWSPEC_PRETTIER` paths select the cached development tools. Prettier must be
version 3.6.2. Positional arguments select specification files.

Prettier differences are saved for inspection, not treated as an exact Google
style oracle: its continuation indentation differs from Google's. These checks
are partial style evidence. Additional indentation cases (such as switch bodies
and type declarations) and Kotlin formatter acceptance remain tracked in the 0.9 plan; passing this script alone does not
establish complete style conformance.

The development-only runtime formatter (`tools/format-web-runtimes.mjs`) applies
Prettier layout and then syntax-tree-directed continuation indentation. It verifies
that JavaScript tokens remain unchanged, retains relative callback block indentation,
and rejects adjustments inside multiline template literals. It is idempotent and
checks the resulting 80-column limit. Reviewed runtime source is embedded at build
time; generated projects never download or invoke these development tools.
