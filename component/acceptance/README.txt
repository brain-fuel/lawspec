LawSpec native Node acceptance bundle

Run `node run.mjs` on macOS or glibc Linux, x64 or ARM64, separately with Node
22, 24 and 26. Neither Haskell nor Rust is needed. The runner verifies the local
archive identities, populates npm's dependency cache with package scripts disabled,
then runs the offline clean-install test. Cache population needs registry access
when the dependencies are not already cached. No packages are published.

The test compares all nine public compiler methods against the existing runtime,
then removes the application native artifact, runs npm rebuild with forced
source compilation, removes the compiler executable, and repeats the comparison.
Compilation must finish during installation; commands only load native code. It verifies missing-artifact failure without fallback,
and missing SDK/runtime behavior. The guest execution deadline remains 120 seconds;
installation compilation has a separate 15-minute bound and the test harness
allows setup and multiple bounded calls.

Capture the complete console output and the host OS/CPU description with each run.
Successful emulated execution is functional evidence, not native CPU performance
acceptance. macOS x64 execution and native Linux x64 full-source acceptance are
still outstanding. Human Canon review remains pending.

Historical acceptance before the installation-lifecycle change:
The earlier bundle contained the rebuilt glibc 2.28 Linux helpers. All six Linux
executables passed linked-version inspection. SDK runtime suites passed on
glibc 2.28 ARM64 and emulated x64; this full application test passed on Linux
ARM64 with Node 22, 24 and 26, and on macOS ARM64 with Node 26.
