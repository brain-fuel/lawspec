# Publishing LawSpec

Release from `main` using Git over the existing SSH remote. Do not use the GitHub
CLI. npm stores the immutable package version separately from dist-tags:
publishing version 0.15.0 with `--tag latest` preserves `lawspec@0.15.0` and moves
`lawspec@latest` to that version. Never try to overwrite an existing npm version.

## Prepare and verify

Keep `package.yaml`, the generated `lawspec.cabal`,
`wasm/lawspec-wasm.cabal`, `npm/package.json`, the CLI version and the Rust
conformance package version in sync. Update the release notes and current
installation examples. Preserve historical release notes.

```sh
stack --no-terminal test
bash tools/wasm.sh
node --test npm/test/*.test.mjs
stack --no-terminal run lawspec-dev -- integrity
stack --no-terminal run lawspec-dev -- boundaries
node tools/package-smoke.mjs
mkdir -p .artifacts/0.15.0
npm pack ./npm --pack-destination .artifacts/0.15.0
```

Check the native integration results for all eight targets. The installed native
binding runner is `node tools/native-example-integration.mjs <target>`; run it
for both default output and `LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1`.

## Commit, tag and push

Inspect `git status` and confirm `git branch --show-current` reports `main`.
Review the diff, then record the release and push the branch and annotated tag
together. Do not force-push or move an existing release tag.

```sh
git add -A
git commit -m "Release LawSpec 0.15.0: evidence and discharge"
git tag -a v0.15.0 -m "LawSpec 0.15.0"
git push --atomic origin main v0.15.0
```

Run `stack run lawspec-dev -- ci` before publishing; every step must pass. Resolve
failures on `main` and verify that the release tag identifies the exact commit
being published.

## Publish the tested archive

```sh
npm publish .artifacts/0.15.0/lawspec-0.15.0.tgz --access public --tag latest --registry https://registry.npmjs.org --browser false
npm view lawspec@0.15.0 version dist.integrity --registry https://registry.npmjs.org
npm view lawspec dist-tags --registry https://registry.npmjs.org
```

If npm requests authentication, complete its browser approval in Brave using the
URL printed by npm, then resume the publish command. Never put authentication
tokens or one-time codes in the repository. A failed request does not establish
publication; verify the exact version and `latest` tag in the registry.
