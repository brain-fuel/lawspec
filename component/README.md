# LawSpec component integration

> **Blocked — 2026-11-08:** Native artifact shipment is awaiting x64 execution
> acceptance. See the authoritative [blocked status](../docs/reference/host-sdk.md#blocked-status)
> for the missing environments, resumption requirements and prepared bundle.

This directory owns LawSpec's adapter to the independently maintained Wasm Platform Kit.
It is a private development package. The SDK source is in a separate repository;
this package consumes npm tarballs, never sibling source imports.

From the LawSpec root, after `npm run build && npm run pack:local` in that repository:

```sh
node component/tools/install-sdk.mjs ../wasm-platform-kit/dist
npm run build --prefix component
node component/tools/package-native.mjs
npm test --prefix component
```

`install-sdk` checks distribution hashes and records them in `sdk-packages.json`.
`build` uses installed `wasm-platform-kit-build` and the GHC Wasm toolchain to
produce `assets/`, then stages the Node component under `npm/host-component/`.
Build products and local tarballs are ignored; the installed SDK is never changed.
Scripts and JavaScript tests are generated from `templates/component/`.

`package-native` moves application native code into optional
`@lawspec/compiler-<platform>` packages and stages generated registration that
locates the installed package automatically. The main application package keeps
the portable Wasm, without bundling native code for every platform. Local tarballs
and integrity records are written to `component/vendor/` and
`component/native-packages.json`.

To combine trusted builds, supply directories containing `component.cwasm` and
its `registration.json` receipt:

```sh
node component/tools/package-native.mjs /build/linux-arm64 /build/linux-x64 /build/darwin-x64 --require-all
```

Receipts must come from the trusted SDK compiler for this exact component. The
packager checks component, native, target and engine identities before emitting
registration. `--require-all` checks that all four artifacts exist; execution
acceptance on each platform is a separate requirement. The SDK build package's
`precompileNative({component, output, target})` can produce these receipts, with
`target` selected from its exported `nativeTargets` map. Cross-compilation alone
does not validate a platform. Supported targets are macOS and glibc Linux on x64
and ARM64; musl and native Windows are unsupported (use WSL for Windows).

The clean-install test can consume an archive prepared on a different build
host: set `LAWSPEC_TEST_PACKAGE` to a JSON file containing the single receipt
object returned in the `npm pack --json` array, stored beside that tarball. The
test verifies its SHA-512 integrity before installing it. This avoids recompressing
the application under CPU emulation; compiler execution limits are unchanged.

To assemble a portable acceptance bundle from those exact pinned archives, use
the native Haskell bootstrap command from the repository root:

```sh
stack run lawspec-dev -- native-acceptance --package /build/application-package.json --out /build/acceptance-bundle
```

The receipt is the single `npm pack --json` result object, stored beside its
tarball. The builder requires all four native platforms, verifies the copied
archive bytes, rejects path-bearing filenames and symlink archives, and refuses
existing output directories. Failed assembly removes its private staging
directory. The output contains `run.mjs`, the clean-install test and the pinned
archives. Copy the directory to an acceptance host and run `node run.mjs` with
Node 22, 24 and 26. Neither Rust nor Haskell is needed on that host. A successful
bundle build records no platform execution or human approval.

`stack run lawspec-dev -- native-check` runs the builder's negative controls,
packs the current npm application, builds a temporary verified bundle and runs
its clean-install test on this host. It removes the temporary bundle afterward.
The local `lawspec-dev ci` includes this as `component-native-acceptance`, after
integrity and generation checks. It runs uncached and alone because explicit
source compilation still has a substantial peak memory cost. Build and stage
the pinned SDK and all four native application archives before running it;
missing artifacts fail the check. Run it separately on each required native
platform and Node version. No hosted CI is configured.

Use `createCompiler({runtime: 'component'})` from LawSpec's npm API for the SDK
transport. On Node this uses the generated trusted native artifact by default.
`npm install` verifies the prebuilt artifact or compiles the pinned portable
Wasm before execution. Use `WASM_PLATFORM_KIT_BUILD_FROM_SOURCE=1 npm rebuild lawspec`
to force compilation during installation. Commands never compile; the former
`compilation: 'source'` runtime option now fails with repair instructions.
Neither installation path requires Rust or Haskell. The build commands above rebuild the application from Haskell source
and emit fresh native code using the packed SDK compiler. The no-argument API
still uses its existing runtime. The formatter's
explicit entrypoints are `pilot-node.mjs` and `pilot-browser.mjs`; a plain-page
example lives in `examples/`. Serve the full generated browser asset directory.

See [the integration reference](../docs/reference/host-sdk.md) for capability,
cache, deployment and compatibility boundaries. No SDK packages have been published.
