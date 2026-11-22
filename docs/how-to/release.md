---
id: lawspec.how-to.release
kind: how-to
title: Release LawSpec
---
# Releasing LawSpec

A release moves one version of the npm package `lawspec` from `main` to the npm
registry and attaches the same archive to the GitHub release. Every step runs
on your machine; there is no hosted CI.

## Rules

- Release from `main`, pushing over the existing SSH remote. Do not use the
  GitHub CLI.
- Never put an npm token, one-time code or other credential in the repository.
- npm versions are immutable: never try to overwrite or unpublish one. Never
  move an existing tag or force-push `main`.
- Roadmap milestones are minor releases (0.x.0). Everything else, such as
  tooling, documentation and fixes, is a patch release (0.x.y). The milestones
  are listed in [the roadmap](../explanation/roadmap.md).

## 1. Check the preconditions

```sh
git switch main && git pull --ff-only
git status --short
```

Start from a clean `main`. Run `release-check` after preparing and committing
the new version; the current released version already has a tag and registry
entry, so it cannot pass those new-version preconditions.

## 2. Bump the version

```sh
make bump VERSION=0.36.3
```

`lawspec-dev bump` sets the version in `package.yaml` (Stack writes
`lawspec.cabal` from it), `wasm/lawspec-wasm.cabal`, the Rust conformance crate
(`runtime/rust/Cargo.toml`, `Cargo.lock`) and `canon.yaml`, updates install
instructions that name the version (`lawspec@x.y.z`) in the README and docs,
then regenerates `npm/package.json` and the CLI's `--version`.

`CHANGELOG.md` follows Keep a Changelog ref:keep-a-changelog.
Rename its `## [Unreleased]` section to `## [x.y.z] - YYYY-MM-DD`, keeping the
`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` and `Security` groups: what
changed for users, and anything that needs their action. Start a new, empty
`## [Unreleased]` above it, and add the version's comparison link at the bottom.

`canon.yaml`'s version is the project version canon checks against: an open
decision or an exemption whose `revisit` version the release reaches fails
`make canon` until it is settled. Vet what is pending first, on Rice's Tax's
review page, and settle each exemption the release reaches: see
[Vet the canonical material](vet.md); `make audit` says what is left.

## 3. Build the package

First build the four platforms' Canon bundles, pack them and record their
digests ([Build the native executables](build-native.md#pack-canon-for-npm-and-record-the-digests)),
because the core compiles the digests in.

```sh
make wasm
make generate-check integrity
```

`make wasm` builds the native compiler, writes the generated files, compiles
the WASM core with `wasm32-wasi-ghc`, stages the shipped files into `npm/`,
and records their fingerprints in `npm/build.json`.

Git keeps no build output: everything in `npm/` except `npm/build.json` and
`npm/package-lock.json`, `tools/*.mjs` and the other generated files are
written by `make generate` (which `make wasm` and every task that reads them
run first), and `git add -A` never stages them. The package ships them all,
including the skill references in `npm/references/`. It also ships the WASM
cores (`npm/core.wasm` and `npm/host-core.wasm`, from `make wasm`), the host
component (`npm/host-component/`, from `make component SDK_DIST=<SDK
tarballs>`) and the lesson assets (`npm/learn/vendor/`). A worktree holds
whatever it last built of them, and a new worktree holds none, so build them
in the worktree you release from, before `make wasm`: its last step records
the host component's fingerprints and stops if the directory is missing.
Build, verify and pack in that one worktree.

## 4. Commit the candidate and verify

```sh
git add -A
git commit -m "Prepare LawSpec 0.36.3"
make ci-fresh
make smoke-release
make docs-check
make release-check
```

Canon reads versioned sources from `HEAD`, so commit the candidate before
running CI. If a check requires changes, commit those changes and rerun CI.

`make ci-fresh` ignores recorded results, so every step runs against the
release commit. Steps run in parallel, half the processors at a time; pass
`--jobs N` (or set `LAWSPEC_CI_JOBS`) to change that, and `--jobs 1` to run
them one at a time, for example to time a single step on an idle machine.

`make smoke-release` (`node tools/package-smoke.mjs --examples`) repeats the
package smoke test with the export of every bundled example from the
installed archive. The export runs single-threaded for the better part of an
hour, under a one-hour limit, so the `package-smoke` step of the complete
check leaves it out; a release must run it. Run it on an otherwise idle
machine: a loaded one can push the export past its limit.

Every CI step must pass: compiler and npm tests, native/WASM parity, the
package smoke test, the editor grammar, artifact validators, and program-target
acceptance suites in both machine profiles. Logs are in `.artifacts/ci/`.

`release-check` then requires a clean `main`, matching versions, current
generated files, no existing tag for the prepared version, and no published npm version
with that number. Passing these checks does not create a tag or publish.

## 5. Pack and inspect

```sh
make package
tar -tzf .artifacts/0.36.3/lawspec-0.36.3.tgz
```

`make package` first runs `make integrity`, which refuses a staged core or
host component that differs from what `npm/build.json` records (`Stale build
artifact/source: ...`), and builds the lesson assets again, which
`npm/build.json` does not record. `release-check` runs the same integrity
check. Neither can tell that an ignored output is stale if you record it
again without rebuilding it, so do not run `lawspec-dev integrity --record`
by hand.

The archive holds the CLI and library code, `core.wasm` and its JavaScript glue,
`README.md`, `CHANGELOG.md`, `LICENSE`, the starter specification and
`examples/`. `README.md` and `CHANGELOG.md` live only at the repository root:
the package's `prepack` script copies them into `npm/`, where git ignores them.
The smoke tests in step 4 already installed and exercised a
packed copy.

Pack the host-effect core for the Go host:

```sh
tools/package-core.sh
```

It packs `npm/host-core.wasm` as `@goforgedev/core` into
`.artifacts/core-npm/goforgedev-core-0.36.3.tgz`, after checking that
`hosts/go/internal/core/pin.go` records that core's SHA-256 for this version
(`make wasm` writes the pin). The Go module carries no core: on first use it
downloads this package and refuses any other bytes, so the commit the
`hosts/go/v0.36.3` tag names needs nothing added.

## 6. Tag and push

```sh
git tag -a v0.36.3 -m "LawSpec 0.36.3"
git push --atomic origin main v0.36.3
```

Push the branch and the annotated tag together, so the tag always names a
commit that is on `main`.

## 7. Publish

```sh
npm publish .artifacts/0.36.3/lawspec-0.36.3.tgz --access public --tag latest --registry https://registry.npmjs.org
```

Publish the core package for the Go host the same way, before anyone installs
the Go module's release:

```sh
npm publish .artifacts/core-npm/goforgedev-core-0.36.3.tgz --access public --registry https://registry.npmjs.org
```

Publish the archive you inspected, not the directory. npm asks for approval in
the browser; complete it there. If npm reports that you are not logged in, run
`npm login --registry https://registry.npmjs.org` first.

The platform packages the archive names as optional dependencies go first,
exactly as packed and recorded, from the same worktree:

```sh
for f in .artifacts/canon-npm/goforgedev-canon-*-0.36.3.tgz component/vendor/goforgedev-compiler-*-0.36.3-*.tgz; do
  npm publish "$f" --access public --registry https://registry.npmjs.org
done
```

Once `@goforgedev/core` is on npm, tag the Go module (the commit `v0.36.3`
names) and push the tag:

```sh
git tag -a hosts/go/v0.36.3 -m "LawSpec Go host 0.36.3" v0.36.3
git push origin hosts/go/v0.36.3
```

### Maven Central

GoForge's assayxport publishes the Maven packages
([Install from Maven](install-maven.md#publish-a-release-owner)). It checks
that the checkout is exactly the tag and clean, so stage from a worktree of
the tag, giving it the platform binaries and the Learn site and cores the npm
archive shipped:

```sh
git worktree add --detach ../maven-0.36.3 v0.36.3
cd ../maven-0.36.3
tar -xzf ../<release worktree>/.artifacts/0.36.3/lawspec-0.36.3.tgz -C npm --strip-components 1 \
  package/core.wasm package/core.wasm.gz package/core_jsffi.js package/learn
for p in darwin-arm64 darwin-x64 linux-arm64 linux-x64; do
  hosts/jvm/stage-native.sh --platform $p --binary <its lawspec-native> --canon <its Canon bundle>
done
hosts/jvm/stage-native.sh --check-all
mvn -f hosts/jvm -Prelease,all-platforms -Drevision=0.36.3 -DskipTests \
  package deploy:deploy \
  -DaltDeploymentRepository=staging::file:$PWD/hosts/jvm/target/central-staging
(cd hosts/jvm/gradle-plugin && gradle -Pversion=0.36.3 \
  -PlawspecRepository=$PWD/../target/central-staging \
  publishAllPublicationsToCentralStagingRepository)
git status --short     # must print nothing
ax publish --maven-settings-path ~/para/projects/goforge/maven_settings.xml
```

The Gradle build adds the Gradle plugin and its plugin marker to the same
staging directory ([Install the Gradle plugin](install-gradle.md#publish-a-release-owner)),
so one bundle publishes everything. `ax publish` waits until Central reports
the deployment published.

## 8. Verify the registry

```sh
npm view lawspec@0.36.3 version dist.integrity
npm view lawspec dist-tags
shasum -a 512 .artifacts/0.36.3/lawspec-0.36.3.tgz | awk '{print $1}' | xxd -r -p | base64
```

`dist.integrity` must be `sha512-` followed by the local archive's digest, and
`latest` must name the new version.

## 9. Attach the archive to the GitHub release

Registry mirrors can lag behind npm, so each release also offers the archive
for download. Use the GitHub website, not the GitHub CLI:

1. Open <https://github.com/brain-fuel/lawspec/releases/new?tag=v0.36.3>. The
   tag pushed in step 6 is selected.
2. Set the title to `LawSpec 0.36.3` and paste the version's `CHANGELOG.md`
   section as the description.
3. Drag `.artifacts/0.36.3/lawspec-0.36.3.tgz` into the box for attaching
   binaries. Attach the archive you published in step 7, not a new pack.
4. Publish the release, then download the attached file and check that
   `shasum -a 512` prints the digest of the local archive.

[Install from a release tarball](install-and-init.md#install-from-a-release-tarball)
tells users how to install it.

## 10. Publish the documentation (optional)

```sh
make docs-deploy
```

This builds the site and deploys it to Cloudflare Pages with Wrangler; see
[the contributing guide](contribute.md).

## If something goes wrong

- A failed or interrupted `npm publish` may still have published. Check
  `npm view lawspec@x.y.z` before trying again.
- If a published version is broken, deprecate it with
  `npm deprecate lawspec@x.y.z "<reason>; use x.y.(z+1)"` and release the next
  patch. Do not unpublish.
- If the push was rejected, do not force it. Rebase onto `origin/main`, delete
  the local tag (`git tag -d vx.y.z`), and start again from step 4.
