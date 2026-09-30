# Use the JavaScript API

The `lawspec` package exports an asynchronous, typed compiler API. Use it to
build tools on top of LawSpec: editor integrations, custom generators, or
build-system plugins.

## Plan generation for a target

```javascript
import { createCompiler } from 'lawspec';

const compiler = await createCompiler();
const result = await compiler.planGeneration({
  sources: [{ path: 'codec.lawspec', content: sourceText }],
  target: 'python'
});
if (result.diagnostics.length) console.error(result.diagnostics);
else console.log(result.files);
```

`createCompiler()` loads the WebAssembly compiler and returns an object with
three methods:

| Method | Returns |
| --- | --- |
| `check(request)` | Checked units, data types, definitions, laws, contracts, refinements and evidence. |
| `expand(request)` | The same, plus `expansions`: each law's final property as text. |
| `planGeneration(request)` | The same, plus `files`: every artifact with its path, content, ownership and placement. |

All three return a result with a `diagnostics` array. An empty array means
success. Diagnostics have a `code`, a `message` and a source location `at`, or
`null`.

## What the API does not do

`planGeneration` returns proposed files. It does not inspect the host
environment, check toolchain compatibility, or write anything. The CLI adds
those steps, including the ownership checks that protect edited files. If you
write the files yourself:

- keep each artifact's `placement` (`source` or `test`) separate from its
  `ownership` (`generated` or `user`);
- never overwrite a `user` file that already exists;
- keep a manifest of the hashes of the `generated` files you wrote, and refuse
  to overwrite a generated file whose hash has changed.

## Concurrency

One compiler instance handles repeated and concurrent requests. The JavaScript
shim serializes them.

## Types

TypeScript declarations ship in the package (`index.d.ts`). Requests accept
`machineBits`, `generation`, `nativeBindings`, `dependencies`, `packages` and
`package`; generation requests also accept `sourceDir`, `testDir` and `minify`.
The API selects schema version 4 automatically when `nativeBindings` is
present, and 3 otherwise.

The full wire format, including the lossless scalar encoding, is in the
[API reference](../reference/api.md). Changes between versions are in
[API migration](../explanation/api-migration.md).
