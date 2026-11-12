---
id: lawspec.reference.host-sdk
kind: reference
title: Independent host SDK integration
---

# Independent host SDK integration

## Release status

**Released with 0.32.0 under the owner's 9 November 2026 decision; rebuilt for
0.33.0.** The goal "ship trusted precompiled native artifacts for Node, with an
option to build from source" ships with these platform statements.
ref:DEC-component-release-acceptance

- **macOS ARM64:** native installation and execution recorded for 0.33.0 by the
  local `component-native-acceptance` step.
- **Linux ARM64:** for 0.33.0, the acceptance bundle passed under Node 22, 24
  and 26 (Debian 12, glibc 2.36) in an ARM64 Linux VM on Apple silicon.
- **Linux x64:** for 0.33.0, the same bundle passed under Node 22, 24 and 26
  (Debian 12, glibc 2.36) under x64 emulation in that VM. This is functional
  evidence, not native performance. Native Linux x64 hardware is not recorded.
- **macOS x64: unverified.** The package is cross-built; this Mac cannot launch
  x64 executables and has no Rosetta installation, so no execution is recorded.
  The owner accepted shipping it with this note, to be corrected later.

To close the remaining rows, run the prepared acceptance bundle on an Intel Mac
and on native Linux x64 under Node 22, 24 and 26, preserving complete results
and host OS/CPU details. Hosted CI remains disabled under `DEC-local-ci-only`;
execution limits must not be relaxed to turn an emulation failure into acceptance.
See [the component build instructions](../../component/README.md) to reproduce a
bundle from pinned archives.

ARM64 and emulated results are not native x64 evidence. Human review of the
remaining Canon material is still pending, and the full application-port
cutover remains incomplete: the component runtime is opt-in. Update this status
when new execution evidence changes it. ref:DEC-node-precompiled-components

The reusable [Wasm Platform Kit](https://github.com/brain-fuel/wasm-platform-kit)
lives in its own Git repository, checked out beside LawSpec as
`../wasm-platform-kit`. LawSpec owns `component/`: its WIT application interface,
Haskell adapter, application assets, formatter wrappers and integration tests.
The SDK has no LawSpec compiler dependency. The split and compatibility choices
are recorded in Canon. ref:DEC-host-sdk-independent-consumer

## Package boundary

The independent repository produces three package families at SDK 0.2.0:

- `wasm-platform-kit`: runtime, capability broker and public declarations.
- `wasm-platform-kit-<platform>`: prebuilt Wasmtime helpers and binding metadata
  tool for macOS/Linux on x64 and ARM64.
- `wasm-platform-kit-build`: direct WIT-to-Haskell generation, packaging and Haskell support.

The runtime package contains no LawSpec implementation, application artifacts,
malicious test fixtures or authoring tools. Runtime consumers need no Haskell or
Rust compiler. Application authors need the documented GHC Wasm toolchain.
Platform execution evidence and outstanding acceptance gaps are recorded below.
The packages are published to npm. `npm/package.json` names the runtime
version, and `npm/package-lock.json` pins its integrity and that of its
platform packages.

Build and pack in the SDK repository, then install those artifacts into LawSpec:

```sh
# In the independent SDK repository:
npm ci
npm run build
npm test
npm run pack:local

# In LawSpec:
node component/tools/install-sdk.mjs ../wasm-platform-kit/dist
npm run build --prefix component
npm test --prefix component
```

The installer verifies tarball integrity, copies immutable tarballs into ignored
`component/vendor/`, and records identities in `component/sdk-packages.json`.
Installed packages are real copies, not links to the SDK source tree. SDK source
changes affect LawSpec only after another build, pack and install. The directory
argument can point to any unpacked local distribution; sibling layout is optional.

Application builds generate bindings, link the Haskell compiler and package the
component using the installed build package. They generate application-owned
Node/browser loaders, declarations, workers and integrity manifests. Packaging
never edits an installed SDK or a shared component registry.

## Compiler API and formatter

The existing Node compiler API supports an explicit component runtime:

```javascript
import {createCompiler} from 'lawspec';

const compiler = await createCompiler({runtime: 'component'});
const result = await compiler.check({
  languageProfile: '1.0-rc.2',
  verification: {layers: []},
  sources: [{path: 'example.lawspec', content: 'unit example\nend unit\n'}],
});
```

All nine existing methods retain their request and response shapes. The adapter
passes the existing versioned JSON protocol through a WIT text export named
`dispatch`; this compatibility codec does not claim that the entire compiler
schema has generated Haskell WIT types. Host operations use the typed capability
contract. The dedicated formatter also has typed WIT request/response records.
Definition validation and evidence classifications remain in the compiler.

`createCompiler()` still selects the existing runtime. CLI, Learn, editor and
other callers have not been switched by default. Selecting `component` never
falls back automatically if its runtime or artifacts are absent. Default cutover
requires the remaining platform and application acceptance work.

An explicit `cacheDirectory` authorizes that directory for compiler memos. The
Node adapter creates a scoped file grant and namespaces entries by artifact,
runtime, provider and policy identities. Changing the directory terminates the
old instance before creating a new one; calls on each compiler are serialized.
The Haskell adapter retains the existing memo encoding and corruption recovery,
using typed file operations with base64 to carry binary entries. The provider
writes entries atomically within its granted directory. Cache I/O remains best
effort. No cache argument grants ambient filesystem access.

`component/pilot-node.mjs` and `component/pilot-browser.mjs` expose the formatter.
For plain-page embedding, serve `component/examples/plain-page.html` and its
referenced assets. The generated browser entrypoint selects the worker and asset
URLs automatically. Deploy the complete generated directory and use its
`deployment.json` header templates. Browser requirements include secure context,
workers, WebCrypto and JSPI; the isolated profile additionally requires COOP/COEP.
Unsupported configurations fail explicitly. Browser file grants use supplied
handles; consent and server authorization remain application responsibilities.

## Trust and acceptance

The SDK generates Haskell records, variants and opaque resources directly from
WIT using upstream `wit-parser`. SDK 0.2.0 adds all signed and unsigned integer
widths, bulk ByteString values, scalar and void exports, indirect argument
layouts and exported resources with constructors, methods and destruction.
Generated JavaScript façades and `.d.mts` declarations expose Promise-returning
operations and opaque resources with explicit disposal. Node preserves 64-bit
integers as bigint; browser workers keep jco resource instances inside the worker.
Both transports validate resource ownership and instance identity. Haskell adds
dynamic borrow scopes and transfer checks; these are runtime checks, not a static
lifetime proof. The reusable SDK still rejects unsupported WIT features. There is no authored C binding layer. GHC foreign
calls, its runtime and libc still underlie the ABI. Unsupported WIT features fail
generation. The generator, canonical codecs and initialization shim are trusted
implementation code, not a proof of ABI safety.

Node runs each instance in a Wasmtime helper with no inherited environment,
application stdio, filesystem preopens or network authority. Browser instances
use host-generated jco glue in workers, with artifact digests pinned by the
application build. Only explicit embedding-owned grants authorize providers;
plugin declarations grant nothing. The SDK owns containment, request/resource
limits, cancellation and failure classification. The application owns its grants,
trusted deployment assets and compiler semantics. ref:DEC-host-sdk-direct-haskell

SDK tests independently exercise Haskell and Rust guests, hostile fixtures,
capability providers, browser engines and clean npm installation. LawSpec tests
compare all compiler methods and formatter behavior against the existing runtime,
exercise real file grants and persistent caches, and embed the Haskell component
in Chromium, Firefox and WebKit. These are scoped execution tests; they do not
establish universal security or prove the implementation from the abstract model.
WebKit file coverage requires a persistent browser profile. File-picker consent
is not automated.

SDK 0.2.0 boundary execution is recorded in `acceptance-0.2.0.json` in the SDK
repository; its earlier `acceptance.json` remains historical. LawSpec's updated
consumer logs are in `.artifacts/host-sdk-port/`; the earlier pilot logs remain in
`.artifacts/host-sdk-extraction/`. Canon review reports unresolved canonical comments and unavailable Git provenance;
human review remains pending. The SDK's
abstract model is definition-checked separately, with optional laws unverified.
The root `lawspec.edn` now selects `laws/`, with no optional law layers selected.
Definition validation passes; the abstract resource admission laws remain
not-verified. Canon status works with the pinned 0.2.3 executable, while full
validation still reports pending review and unavailable provenance for uncommitted
pilot files. No human review has been inferred. SDK publication, other native
platforms, full first-party cutover and Wavelet integration remain subsequent work.

## Application port status

The owner-approved target is the complete Haskell application, using SDK 0.2.0.
The architecture and cutover gates are recorded once in Canon. The decision
named LawSpec 0.32.0; that release shipped without the port, which is now the
next roadmap milestone and has no committed release number.
ref:DEC-haskell-application-port

The separate controller/compiler architecture is settled in
`DEC-application-controller-workers`; it is not yet implemented. Numerical
release limits await a representative baseline and owner selection, as recorded
in `DEC-application-port-performance-baseline`. The earlier 94% reduction is not
a requirement, and existing containment limits remain in force.
ref:DEC-application-controller-workers ref:DEC-application-port-performance-baseline

The port's first checkpoint was developed on `codex/haskell-application-port`
from `a91b22f0`; that branch now includes the 0.32.0 release and its
completed S1J work, and is not yet merged into `main`. Its first candidate service is
`LawSpec.Manifest.EDN`: a Haskell/Megaparsec codec with ordered fields, normalized
keyword keys, duplicate rejection, safe-integer admission, explicit JSON
encoding and readable/compact EDN rendering. Frozen pre-port observations include
820 examples with malformed delimiters, discard forms, Unicode escapes,
JavaScript index-key order and exact output bytes. The native tests compare
against recorded results, while Node replays both the frozen test-only reference
and the current public codec. This is finite compatibility evidence, not a proof
for every input. The candidate is not connected to public SDK entrypoints; the
asynchronous helper and typed WIT manifest-service cutover remain pending.

Manifest admission now has compiler-independent domain records in
`LawSpec.Manifest.Types`, a pure validator in `LawSpec.Service.Manifest`, and
explicit JSON/EDN projections. The existing native JSON adapter uses that
validator; EDN admission calls it without serializing through JSON. Missing,
malformed and present fields remain distinct, and the adapter preserves the
original response manifest. `LawSpec.Version` shares version admission and
selection with compiler package resolution without importing the compiler.
An import-boundary check restricts these services to six local modules.
Frozen pre-extraction results cover 739 JSON requests and 647 direct EDN
admissions; the suite has 1,387 passing checks including syntax/admission failure
separation. It preserves observed version-parser limitations relative to
[SemVer 2.0.0](https://semver.org/), rather than changing admission during the port.
These native services still require typed WIT bindings and component acceptance.

The [EDN specification](https://github.com/edn-format/edn) supplies the external
syntax; [Megaparsec 9.7.0](https://hackage-content.haskell.org/package/megaparsec-9.7.0/docs/Text-Megaparsec.html)
supplies parsing and explicit custom failures. The pinned `edn-data@1.2.2`
implementation is the compatibility reference. Its malformed-input quirks
require an explicit reader-frame layer; a stricter general EDN reader would
change observed behavior. This layer is trusted codec code, invokes no tag
handlers or evaluation, and is unrelated to proof checking. The ordered EDN
representation is limited to an external-format boundary, not a replacement for
typed compiler WIT schemas. See the [fixture record](../../test/fixtures/application-port/README.txt)
for provenance, reproduction and the current scope.

This checkpoint passes the native library/development/CLI/test build, 820 native
codec cases and 1,641 Node reference/public-codec checks on macOS ARM64/Node
26.8.1. All 258 generated files and the existing 267-module compiler boundary
check pass. Root definition validation passes with no optional law layers
selected. The owner subsequently approved the 47 pending component-comment
sign-offs in this conversation. Their digest-bound verdicts are recorded under
`canonical_vetting/comment/component/`, with notes identifying the delegated
approval. Broader deferred review and full-port acceptance remain open. The broad
compiler suite was interrupted and is not claimed as passing. Production component artifacts and installation/platform
acceptance have not been rebuilt or rerun for this candidate.

The SDK boundary now has the resource and integer machinery needed for typed
compiler node tables. Independent Haskell/Rust fixtures exercise bulk reads,
destruction, ownership transfer, retained-borrow rejection, forged and
cross-instance handles, wide integers and generated asynchronous types. These
fixtures do not constitute the full compiler schema migration. Prelude discovery
now uses a typed WIT query and result in the public component runtime, with a
generated compatibility projection preserving the existing JavaScript object
shape and malformed-query diagnostics. The other eight public compiler methods
still use the pilot JSON-string dispatcher.

The standalone typed formatter now calls shared Haskell compilation and
formatting services directly. Compilation failures remain typed diagnostics until
an external codec renders them; mandatory definition validation, package source
coordinates, syntax-only formatting and formatted-output rechecking share the
same implementations as the JSON API. This standalone formatter intentionally
selects no optional law layers. Haskell owns its checked-mode default, file-write
default and language-profile result; generated projections restore optional
diagnostic fields for both Node and browser façades. Each instance retains at most
two pure formatting results, keyed by checked mode and original source paths and
contents. File reads and capability-checked writes remain outside that cache. It is not yet the full public `format` result,
which also includes the program and evidence views. Typed package-version
selection likewise shares its Haskell service with the existing JSON adapter,
including malformed ranges, candidate errors, ordering and duplicate behavior.
The generated package now carries its SDK Node entrypoint, client and declarations
with the component assets; consumers do not locate these files themselves.

Component builds now use `component/dist-newstyle`, independently of the legacy
`wasm/dist-newstyle`. Both use the pinned dependency solution in
`wasm/cabal.project.freeze`; the component no longer keeps a competing freeze file.
Local SDK changes require a build, repack and integrity-checked install before they
can affect LawSpec. Nothing has been published or tagged.

Remaining gates include the remaining compiler WIT schema and typed shared services,
Haskell policy artifacts and expanded platform facilities; CLI/project, proof,
editor/MCP, Learn/documentation and development-tool migrations; async public-helper
cutover; architectural removal of application JavaScript; all native platforms;
and application performance acceptance. Compiler jobs and UI sessions have not
been split. Public default selection and the legacy production runtime remain
until the full gates pass. This is an implemented SDK foundation, not completion
of the application port; the 0.32.0 application package keeps the existing
runtime as its default.

To resume the full port, complete and verify the following work in sequence:

| Work | Required evidence before cutover |
| --- | --- |
| Compiler/component services | Domain-typed interfaces for all nine methods, scoped result tables, manifest/resolution/identity services, schema-5 and malformed-request differential tests. The manifest codec corpus alone does not close this gate. |
| Platform and controller | Complete canonical types and platform facilities, immutable trusted policy artifacts, separate controller/compiler packages, cancellation and resource-ownership tests. |
| CLI and projects | Haskell argument/workflow implementation and parity for offline, locked and read-only operations, archive/path protections, generated ownership, diagnostics and exit status. |
| Proof/native execution | Haskell orchestration and parity for task selection, solver results, replay, coverage, attestations and cache admission; unknown/unsupported/incomplete remain explicit. |
| Editor and protocols | Haskell document/workspace state and MCP behavior; UTF-16, versions, formatting and read-only tests. |
| Learn and documentation | Haskell state/composition/event handling; actual Chromium, Firefox and WebKit application tests for persistence, accessibility, focus and cancellation recovery. |
| Development and distribution | Haskell orchestration, asynchronous helpers and lifecycle APIs, complete controller/compiler receipts, installation failure controls, generated exports and an architectural check over sources, templates and package contents. |
| Performance and release | Representative baseline followed by owner-selected limits; all native macOS/Linux x64/ARM64 and Node 22/24/26 gates; integrate current S1J changes, rerun final artifacts, and retain pending human review. |

Only after those gates pass may defaults change, legacy production code be
removed, and release tags be pushed. Hosted CI remains disabled. Missing native
hosts and owner-selected performance limits are external prerequisites; they do
not prevent continuing the unfinished implementation work.


The earlier formatter-pilot measurement (before the typed service extraction) on macOS ARM64/Node 26.8.1 recorded
three cold starts (median 5.765 seconds), thirty checked-format calls on one tiny
identity-function source (median 432 ms, p95 893 ms), and about 6.18 GiB helper
RSS after the calls. The component is 61,039,258 bytes; browser Wasm/JavaScript
assets total 62,554,406 raw bytes and 12,557,054 bytes when independently gzipped.
These are local observations for the recorded artifact, not a full application
benchmark or a performance pass. The linear-memory budget does not bound the
Wasmtime helper's entire native heap. Startup, interactive cost and helper memory
need work before performance acceptance and default cutover. Exact identities
and samples are in `.artifacts/host-sdk-port/measurements.json`.

After extracting the typed services and adding the bounded result cache, the same
local profile recorded a 5.585-second median cold start. Thirty identical checked
format requests had a 5.99 ms median and 6.69 ms p95, including an 853 ms first
request. Ten requests changing an integer addition had an 838 ms median and
902 ms p95. The cache helps repeated requests; these changing-input costs and
about 6.17 GiB helper RSS remain performance concerns. The component is
61,058,541 bytes. Packaged browser JavaScript/Wasm, including runtime support and
excluding the original component and Node entrypoint, totals 62,609,501 bytes
(12,559,403 bytes with each file gzipped separately). These are narrow local
measurements, not application performance acceptance. Samples, file inventories
and exact execution identity are in
`.artifacts/host-sdk-port/typed-services-measurements.json`; the extraction's
acceptance receipt is `.artifacts/host-sdk-port/typed-services-acceptance.json`.

### Helper memory investigation

The November 5, 2026 investigation attributes the large Node helper RSS to
Wasmtime's eager compilation of the full component and allocator retention after
compilation. The installed helper recompiles the component for each new instance.
On macOS 26.4 ARM64 with 128 GiB RAM, 18 logical CPUs and Node 26.8.1, the
unmodified application entrypoint reached 6.115 GiB RSS before any application
call. One checked format, thirty identical calls and fifty changing-source calls
increased RSS by only 8 MiB altogether. This bounded sample does not establish
the absence of leaks in other workloads.

An isolated copy of the pinned SDK helper measured about 62 MiB RSS immediately
before `Component::new` and 6.10 GiB immediately after it. Instantiation admitted
22.56 MiB of guest linear memory, rising to 25.81 MiB after the first checked
format. The main embedded core module has 411,115 defined functions and a
44,911,663-byte code section. The guest's linear-memory limit does not constrain
compilation, native code mappings or the helper's native allocator.

macOS `vmmap` reported approximately 4.9 GiB of resident `MALLOC_SMALL (empty)`
regions after startup, approximately 2.1 GiB current physical footprint and a
5.9 GiB peak footprint. RSS includes resident pages that the allocator has made
reusable; it must not be read as live Haskell heap or uniquely charged memory.
The high startup footprint remains a real concern even though current footprint
is lower than RSS. The independent small SDK Haskell fixture reached 241 MiB RSS.

The following experiments retained fuel, guest memory limits and empty guest
capability grants. They used temporary harnesses and a separate diagnostic
binary; no production runtime or installed package was changed.

| Experiment                                                              |       Ready RSS | Startup observation |
| ----------------------------------------------------------------------- | --------------: | ------------------: |
| Installed helper, default compilation threads                           |        6.15 GiB |             11.52 s |
| Installed helper, one Rayon compilation thread                          |        6.08 GiB |             56.53 s |
| Installed helper, four Rayon compilation threads                        |        6.11 GiB |             20.60 s |
| Diagnostic helper, locally precompiled component, three fresh processes | 376.5–376.6 MiB |          203–243 ms |

The precompiled experiment used `Component::serialize` followed by
`Component::deserialize_file` in fresh processes with the same engine settings.
All three first-format responses matched the diagnostic compilation baseline's
complete response. Fifty changing-source requests succeeded; RSS ended at
397.8 MiB, with 123.4 MiB physical footprint. Changed-source formatting still
took about a second. Precompilation addresses startup cost and compilation
memory; it does not resolve the remaining interactive compiler cost.

Reducing compilation parallelism did not materially reduce memory. Explicitly
dropping the original Wasm buffer did not reduce RSS. Apple's documented
`malloc_zone_pressure_relief(NULL, 0)` returned zero and did not reduce RSS or
physical footprint in this experiment. Allocator trimming is therefore not a
demonstrated fix. The precompiled file was 382,351,936 bytes (53,176,287 bytes
through the local gzip command), adding a platform-specific packaging/cache cost.
Its construction still incurred the compilation peak.

The investigation identified SDK-managed trusted precompilation or an
authenticated compiled-artifact cache, with compilation outside long-lived
execution helpers, as the strongest measured next step. The implementation below
now provides the precompiled-artifact path; this experiment alone was not a cutover
pass. Wasmtime explicitly requires trusted serialized native code; arbitrary
guest-supplied cache bytes cannot be deserialized safely. A production design
must bind provenance and integrity to the component, runtime/compiler settings
and target compatibility while preserving policy and execution identities.
See the [Wasmtime precompilation documentation](https://docs.wasmtime.dev/examples-pre-compiling-wasm.html)
and [Apple allocator API](https://github.com/apple-oss-distributions/libmalloc/blob/main/include/malloc/malloc.h).

Exact identities, harnesses, samples, phase logs and `vmmap` snapshots are in
`.artifacts/memory-investigation/`. `baseline.mjs` exercises the installed public
entrypoint; `threads.mjs` varies only the experimental helper's Rayon environment.
`probe/src/main.rs` is the diagnostic helper copy, built in release mode with its
recorded lockfile. `probe.mjs` produces the trusted local serialized component;
`fast.mjs` then compares compilation with three fresh-process loads. The latter
uses a warm filesystem cache and retains lightweight phase instrumentation.
Phase runs that invoke `vmmap` inside startup are not startup benchmarks. These
local timings differ from earlier unprofiled measurements and are not acceptance
claims. Linux, other CPU architectures, concurrent instances, large projects and
browser engines remain unmeasured by this investigation.

### Precompiled Node implementation

The SDK emits a native artifact and separate trusted Node registration for
the current build platform, and its packager can combine trusted builds for
macOS/Linux x64 and ARM64. Generated entrypoints select the execution-only
Wasmtime helper by default. Native code is copied with bounded streaming and
SHA-256 verification into a private, unlinked snapshot before loading. This closes
the verification-to-mapping mutation race while keeping large native buffers out
of the helper's heap. Guest manifests cannot supply registration authority.
Missing, corrupt or incompatible native artifacts fail without source fallback.
ref:DEC-node-precompiled-components

`npm install` prepares component execution by verifying a prebuilt platform
artifact or compiling the pinned portable Wasm. To force installation-time
compilation, use `WASM_PLATFORM_KIT_BUILD_FROM_SOURCE=1 npm rebuild lawspec`.
Normal commands never compile native components. The previous
`createCompiler({runtime: 'component', compilation: 'source'})` option now fails
with installation repair instructions. Compilation uses a separate bounded
15-minute installation deadline; guest execution retains its existing limits.
Clean npm consumers need neither Haskell nor Rust. ref:DEC-component-installation-preparation

Component cache namespaces retain native digest, configuration, target and
compilation mode alongside artifact, runtime, provider and policy identities.
The legacy application default remains subject to the full port's cutover gates.

`node component/tools/package-native.mjs` creates optional
`@goforgedev/compiler-<platform>` npm packages. Generated registration locates the
installed platform artifact automatically, so the main LawSpec tarball contains
no native component. Forced installation compilation bypasses prebuilt native package selection.
Additional trusted receipt directories can be supplied to this command;
`--require-all` requires all four target artifacts but does not claim execution
acceptance. See [the component build instructions](../../component/README.md).
Linux uses glibc; musl and native Windows are unsupported, with WSL remaining the
Windows route. ref:DEC-node-native-platform-packages

A subsequent measurement of the immutable-snapshot implementation on macOS ARM64
recorded 317.1 MiB helper RSS at ready and 338.4 MiB after the same formatting
workload, a 94.6% reduction against the original final sample. Startup was 2.35
seconds; macOS reported 65.2 MiB peak physical footprint. These are distinct
metrics: sampled RSS is not a guaranteed peak, and physical footprint is not RSS.
The receipt and snapshots are in `.artifacts/host-sdk-native/native-memory.json`
and adjacent `native-*-vmmap.txt` files. The compilation peak still occurs when
building native artifacts or forcing source preparation during installation. These small local
workloads do not establish full application performance acceptance.

Source and precompiled conformance, corruption rejection and mutation controls
run against the actual SDK helpers. Platform execution acceptance and final
packaging verification remain in progress; cross-compilation alone is
insufficient. The SDK and application packages remain unpublished; human review
is pending.

The distribution audit found that the first Linux helpers required glibc 2.34.
They have been replaced with builds targeting the Node 22/24/26 glibc 2.28
baseline. All six Linux executables pass linked ELF version inspection; packaging
rejects newer requirements and mismatched integrity receipts. On an actual glibc
2.28 ARM64 system, Node 26 passed 29 precompiled runtime tests and 23 source-mode
tests. The same suites passed with Node 24 in glibc 2.28 x64 userspace under
emulation. Clean application installations with the rebuilt archives passed all
nine compiler methods in both modes on Linux ARM64 with Node 22, 24 and 26.
The refreshed portable acceptance bundle also passed on macOS ARM64 with Node 26.
SDK fixture coverage and emulated execution do not establish full native-platform
acceptance.

The earlier runtime source path reached the 120-second SDK deadline under x64
emulation. That path has been removed: preparation now happens at installation
with its own bounded deadline. The revised SDK installation checks pass on
macOS ARM64, Linux ARM64 and emulated Linux x64; full application acceptance
for this lifecycle still needs the platform matrix. Native macOS/Linux x64
execution remains outstanding. Runtime guest limits have not changed.


The revised clean-install test passes on macOS ARM64/Node 26.8.1 and emulated
Linux x64/Node 24.21.0. It installs prebuilt code, compares all nine compiler
methods, forces compilation through `npm rebuild`, removes the compiler
executable, and repeats all comparisons. Missing artifacts fail without a build.
The whole emulated check took approximately 15 minutes; this is functional
execution evidence, not native performance or release certification. The tested
development archive and harness budgets are recorded in
[`component/acceptance/installation.json`](../../component/acceptance/installation.json).
Native x64 execution and the complete platform/Node matrix remain pending.
