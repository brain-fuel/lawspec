---
id: lawspec.how-to.release
kind: how-to
title: Release LawSpec
---
# Releasing LawSpec

A release moves one version of the npm package `lawspec` from `main` to the npm
registry. Every step runs on your machine; there is no hosted CI.

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
make release-check
```

`release-check` requires a clean `main`, every versioned file in agreement,
generated files up to date, no existing tag for the version, and no published
npm version with that number.

## 2. Bump the version

```sh
make bump VERSION=0.15.1
```

`lawspec-dev bump` sets the version in `package.yaml`, `lawspec.cabal`,
`wasm/lawspec-wasm.cabal`, the Rust conformance crate
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
`make canon` until it is settled.

## 3. Build the package

```sh
make wasm
make generate-check integrity
```

`make wasm` regenerates sources, builds the native compiler, compiles the WASM
core with `wasm32-wasi-ghc`, stages the shipped files into `npm/`, and records
their fingerprints in `npm/build.json`.

## 4. Commit the candidate and verify

```sh
git add -A
git commit -m "Release LawSpec 0.22.0"
make ci-fresh
make docs-check
```

Canon reads versioned sources from `HEAD`, so commit the candidate before
running CI. If a check requires changes, commit those changes and rerun CI.

`make ci-fresh` ignores recorded results, so every step runs against the
release commit.

Every CI step must pass: compiler and npm tests, native/WASM parity, the
package smoke test, the editor grammar, and every acceptance suite for all
eleven targets in both machine profiles. Logs are in `.artifacts/ci/`.

## 5. Pack and inspect

```sh
make package
tar -tzf .artifacts/0.22.0/lawspec-0.22.0.tgz
```

The archive holds the CLI and library code, `core.wasm` and its JavaScript glue,
`README.md`, `CHANGELOG.md`, `LICENSE`, the starter specification and
`examples/`. `README.md` and `CHANGELOG.md` live only at the repository root:
the package's `prepack` script copies them into `npm/`, where git ignores them.
The smoke test in `make ci` already installed and exercised a
packed copy.

## 6. Tag and push

```sh
git tag -a v0.22.0 -m "LawSpec 0.22.0"
git push --atomic origin main v0.22.0
```

Push the branch and the annotated tag together, so the tag always names a
commit that is on `main`.

## 7. Publish

```sh
npm publish .artifacts/0.22.0/lawspec-0.22.0.tgz --access public --tag latest --registry https://registry.npmjs.org
```

Publish the archive you inspected, not the directory. npm asks for approval in
the browser; complete it there. If npm reports that you are not logged in, run
`npm login --registry https://registry.npmjs.org` first.

## 8. Verify the registry

```sh
npm view lawspec@0.22.0 version dist.integrity
npm view lawspec dist-tags
shasum -a 512 .artifacts/0.22.0/lawspec-0.22.0.tgz | awk '{print $1}' | xxd -r -p | base64
```

`dist.integrity` must be `sha512-` followed by the local archive's digest, and
`latest` must name the new version.

## 9. Publish the documentation (optional)

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
