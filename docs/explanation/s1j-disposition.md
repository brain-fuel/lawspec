---
id: lawspec.review.s1j
kind: explanation
title: S1.j disposition
---
# S1.j disposition

This increment addresses the shared compiler, generation and tooling failures in
DEC-s1j-shared-failures and DEC-s1j-evaluation-budget. It preserves the host-SDK
work already present in this checkout. Original projects that were not supplied
remain awaiting confirmation; passing reduced regressions does not close them.
The teaching review and human/external release gates in
[the milestone contract](../../LAWSPEC-PRE-1.0-REVIEW.md) remain in force.

| Report | Change and regression family | Remaining confirmation |
| --- | --- | --- |
| 1 | Central Rapid range `>=1.2.0 <1.4.0`, scaffold 1.3.0; unsupported releases and local replacements rejected. Both released baselines execute the checked-strategy fixture. | Original dependency setup. |
| 2 | Intermediate `any` uses checked generation of its requested type, including nested binding, frequency and filtering; unrelated refinements do not require contracts for a plain Go schema. | Original constrained domain and shrink/replay artifact. |
| 3 | Imported collection operations retain their canonical prelude provider; import/re-export and shadowing regressions. | Original package graph. |
| 4 | Fresh-process cold/warm, damaged and disabled caches agree on macOS ARM64 under Node 22.23.4 and Node 24.21.0, including evaluation settings. Linux ARM64 passes all five cache checks under Node 22.23.4 and 24.22.2; emulated Linux x64 passes under Node 22.23.3 and 24.21.0. | Native x64 hardware, macOS x64 and the unavailable WSL2 project. The reported warm-cache segfault was later reproduced under x64 emulation with a 73-law specification; see the cache crash section. |
| 5 | Empty substitution avoids repeated record expansion; flat construction measured through 64 fields. | Original wide record and workload. |
| 6 | Nested construction retains one strict proof prefix; admitted definition evaluation avoids repeatedly validating borrowed subvalues. Recursion is metered and measured separately. | Original recursive model; larger-model roadmap remains open. |
| 7 | Witness search explores every root constructor independently at increasing depth and uses canonical constructor order; constrained, impossible and recursive domain regressions retain exhaustion. | Original witness domain. |
| 8 | Configured Go factories and typed local bridges propagate into consuming packages; transitive provider/middle/consumer fixture uses a native record codec. | Original host integration. |
| 9 | Reserved syntax/type names documented from compiler lists; `Entry` is shadowable. | No new syntax aliases. |
| 10 | `prelude.all` supports the iterable domains of `any`, short-circuits, returns true on empty inputs and evaluates captures once. | Original use site. |
| 11 | `FileSystem.createDirectories` added to default handlers; nested parents and repeated creation covered by the resource fixture. | Custom handler migration and platform filesystem failures. |
| 12 | Public `mutate` command executes a passing baseline and independent temporary copies, reports actual failing laws, classifications, kill matrix and unique kills. | Project-specific mutants establish observed adequacy only. |
| 13 | Total-definition adapter-call errors explain abilities and effectful procedures. | Original call site. |
| 14 | Mutual recursion remains unsupported; checked parity restructuring example and an established-techniques roadmap added. | Separate future feature; not an implemented recursion checker. |
| 15 | Go package-local interfaces, transitive ability dependencies, sparse unit runtime materialization and handler wrapper migration documented and exercised. | Original workaround wrappers and package layout. |

## Measurement and trust boundaries

[Raw measurements](s1j-benchmarks.jsonl) come from `tools/bench-s1j.py` on macOS
26.4 ARM64 using the native compiler, with isolated processes. Wall/CPU time and
peak RSS include admission and process startup. Logical steps are the minimum
successful optional-evaluation allowance, found by binary search; admission is
never charged to that allowance. These are observations, not portable performance
guarantees. Parallel build load can affect elapsed times.

Flat widths and nested depths 4, 8, 16, 32 and 64 all admit successfully. Recursive
list depths 4 through 64, at 1, 8 and 32 inputs, all report exhaustive evaluation.
At depth 64 and 32 inputs this probe uses 166,304 logical steps. Construction of
literal recursive values still validates constructor boundaries and can exhibit
quadratic work; this is recorded for the larger-model roadmap rather than hidden
by raising a limit.

The proof-view optimization retains the complete strict construction prefix and
all constructor obligations; only its known constructor result is substituted
into an enclosing result. It follows the established practice of sharing local
proof computations instead of repeatedly expanding them. Why3's
[VC generation documentation](https://why3.org/doc/vcgen.html) describes the
related exponential-growth problem and sharing techniques. This local compiler
transformation does not constitute a Why3 backend.

Evaluation uses a deterministic per-law counter, following
[Lean's heartbeat precedent](https://lean-lang.org/doc/api/Lean/Util/Heartbeats.html)
with LawSpec-specific expression/value-node accounting. Public definition
arguments and external results remain validated. Only borrowed values inside
an admitted definition avoid redundant recursive validation; constructor
contracts and ordered pre/postconditions still run. The interpreter is trusted;
there is no proof-checking kernel or new solver integration in this change.

For future checked mutual recursion, the roadmap starts with
[Idris 2 totality](https://idris2.readthedocs.io/en/latest/tutorial/typesfuns.html),
[Rocq structural recursion](https://rocq-prover.org/doc/V9.0.0/refman/language/core/inductive.html),
Lean termination checking and SPARK/Why3 obligation generation. Generating an
obligation, executing a solver and checking a proof remain separate claims.

## Warm-cache segfault on Linux x64

A user report (cold `check` passes, later runs exit 139, worse as the
specification grows) reproduces with published 0.31.3 on emulated Linux x64
under Node 22.23.4, using three bundled specifications with 73 laws: of four
`check` runs the second and fourth crashed, and `generate` crashed. Three
core dumps share one stack: the compiler's WASI `path_open` runs as a V8 fast
API call (`node::wasi::WASI::WasiFunction<…PathOpen…>::FastCallback`); uvwasi
allocates, Node reports the allocation through
`AdjustAmountOfExternalAllocatedMemory`, V8 starts a full collection, and root
iteration faults in `InnerPointerToCodeCache::GetCacheEntry` while visiting
the optimized calling frame. The two-law cache fixture above is too small to
optimize that caller, which is why the earlier cache checks passed.

With `--no-turbo-fast-api-calls`, warm checks on the same cache passed, and
four default control runs immediately afterwards all crashed. The compiler
host now sets that V8 flag before it creates WASI. Results are unchanged;
WASI calls take the ordinary call path. With that launcher change applied to
the published 0.31.3 package, eight warm checks passed on the same cache, and
`generate` ended with an ordinary diagnostic about the reproduction project's
missing Python setup instead of a crash; a complete generation on x64 was not
observed. The same specification passed three
warm runs on macOS ARM64 without the flag, and why that platform is spared
is not established. No upstream Node correction has been identified, and
native x64 hardware remains unconfirmed. The component runtime does not use
`node:wasi`.

## Migration

- New Go projects use Rapid 1.3.0; existing stable 1.2.x projects remain accepted.
  Explicit LawSpec case counts override `RAPID_CHECKS`; explicit seeds override
  `RAPID_SEED`. Invalid Rapid environment values can fail during upstream startup.
- Every custom `FileSystem` implementation must implement `createDirectories`.
  `writeBytes` does not create missing parents.
- Go factories imported through `goImports` are forwarded in each consuming
  package with that package's codecs. Remove manually copied `New…Bound` wrappers
  when adopting generated bridges. Handler-only bridges use a generated file
  separate from user adapters; user adapters are preserved.
- `maxSteps` and `deferLaws` affect optional compiler evaluation, not definition
  admission or solver settings. Deferral/exhaustion is planned or incomplete,
  never completed evidence. A deferred law with a provably empty input domain
  is incomplete when no executable test remains; selecting property or
  exhaustive verification alone does not provide a continuation.
- Mutation copies are process isolation, not an operating-system sandbox. Native
  tools can have their ordinary external effects. Invalid edits or compiler
  rejections are not credited as killed laws.

During broad verification, Groovy mutation/restoration checks and a Kotlin
acceptance baseline observed Gradle running stale compiled source. LawSpec now
passes `--no-watch-fs` to Gradle test and benchmark invocations, including the
acceptance harness, refreshing input observations between
runs while retaining incremental compilation. This uses Gradle's
[documented filesystem-watching control](https://docs.gradle.org/current/userguide/file_system_watching.html);
it does not change LawSpec's passing-result cache or skip native checks.
Already stale compiled outputs can require a one-time `gradle clean`; the Kotlin
integration fixture needed that recovery before its full mutation family passed.

## Verification ledger

Focused results: all 18 executable targets pass the checked-strategy and directory-resource fixtures in the default 64-bit profile and the 32-bit compact profile (72 suite/target/profile combinations; Scala uses an isolated Bloop daemon). The transitive Go handler and custom-codec fixture passes both profiles. Go additionally reports a regular-file parent conflict. Rapid 1.2.0 and 1.3.0 pass with explicit LawSpec case limits overriding upstream environment defaults. The public mutation integration covers a kill, a survivor, invalid edits, compile rejection, unexpected failures, timeout and workspace preservation. Its parser accepts all 2,799 acceptance mutants. The five cache checks pass on each of macOS ARM64/Node 22, macOS ARM64/Node 24, Linux ARM64/Node 22 and Linux ARM64/Node 24. Documentation validation compiles 137 snippets and resolves 130 pages. Final native/WASM parity compares 9,366 complete responses across six fixture partitions, including 6,432 accepted generation responses. The partitions cover all 66 bundled specifications, every target and all four profiles; counts include repeated shared probes. [The parity receipt](s1j-parity.json) records fixture coverage and unchanged input hashes.

The checked-strategy fixture also rejects a deliberately false law over valid
refined inputs on all 18 targets in both profiles (36 negative-control runs),
with its correct baseline passing each time.

The final compiler build passes all 2,838 native examples. This includes the
scoped undefined-candidate and premature empty-list witness regressions, and
the deferred empty-domain manifest regression. An earlier stale assertion
expected an unrelated built-in Go interface in a package; it now checks both
packages' actual interface closure and passes in the full suite.

Final review found that a deferred empty-domain law reported planned evidence
despite having no generated test. The continuation check now requires an actual
case or generator. A regression compares the status with the test manifest on
all 18 targets, and the native/WASM parity suite includes the same boundary.
Native, legacy WASM and component artifacts were rebuilt after this correction;
earlier parity and host-SDK installation receipts do not certify the rebuilt bytes.
The rebuilt component passes native clean-install acceptance on macOS ARM64
with Node 26.8.1, including prebuilt installation, forced compilation at install
time, all nine compiler methods and missing-package controls. Its exact
identities are recorded in [the new installation receipt](../../component/acceptance/s1j-final.json).
The corrected empty-domain response also agrees across legacy WASM and component
runtimes. All five cache checks pass again with the final compiler on macOS
ARM64/Node 22.23.4 and 24.21.0, and Linux ARM64/Node 22.23.4 and 24.22.2. The
added empty-domain case retains incomplete evidence across fresh-process cold,
warm and disabled caches. The same final five-check suite passes on emulated
Linux x64/Node 22.23.3 and 24.21.0. This does not close the external platform gates.

The full CI run also exposed an obsolete Rapid doctor version check and Gradle's
retained source observations. The shared-range doctor check and native Go
integration pass after correction; both affected Groovy integrations pass with
filesystem watching disabled. The acceptance harness uses the same option.
Kotlin's integration baseline initially retained an earlier mutant in its
compiled bytecode despite restored source; after cleaning that disposable
project, its baseline and complete mutation family pass. During concurrent host-SDK packaging, several
integration checks observed replaced package files or invalidated evidence
identities. With those artifacts held stable, the affected JavaScript replay,
JavaScript/Python/Kotlin/Swift model checks and Prolog package integration pass.
These reruns do not turn the original failed CI records into passing records.

The completed cached CI milestone contains 2,752 scheduled steps: 2,733 passed,
three were cached and 16 retain non-passing records. Fourteen have passing
corrective reruns; the interrupted parity step has complete passing coverage in
the final fixture partitions. Canon still requires 47 owner sign-offs. The new
74 S1.j suite/target/profile checks and 36 refinement negative controls ran
separately from that launcher's step list. [The CI disposition receipt](s1j-ci.json)
records the original result, follow-up evidence and scope of each correction.
Raw logs and their hashes are retained in `.artifacts/s1j-final-verification/`.

The SDK suite ran 491 tests: 484 passed, five were skipped and two failed.
The five environment-specific tests pass in their separate CI steps: Rust and
Haskell native layouts, Rust dynamic embedding, and Rust/Clojure mapped failures.
The Go budget-execution failure used the earlier Rapid doctor check; the exact
test passes with the corrected shared range. The documentation-manifest failure
exposed a missing outer map around the evaluation EDN example; that example is
corrected and the manifest test passes.

The Linux x64 cache runs also pass all five checks under Node 22.23.3 and
24.21.0, using amd64 containers emulated on the ARM64 Podman VM. This covers the
x64 binaries under emulation, not native x64 hardware or the reported WSL2
environment. Node 22 remains supported on the verified configurations; the
unavailable platform/project combinations remain explicit external checks.

Project status and validation both pass definition admission, with verification explicitly unselected in the project manifest. Canon 0.2.3 status succeeds; its validation gate reports 47 pending owner sign-offs. No sign-off is manufactured. The default PATH Canon is older, so these commands explicitly select the matching built executable.
Platform rows without a recorded execution remain external gates. The existing
host-SDK platform gate is independent and must not be inferred to pass from these
compiler/tooling regressions.
