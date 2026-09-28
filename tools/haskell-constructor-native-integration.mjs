import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const ghc = process.env.LAWSPEC_GHC;
const fixture = process.env.LAWSPEC_HASKELL_DEFINITIONS_FIXTURE;
assert.ok(ghc && fixture, 'Set LAWSPEC_GHC and LAWSPEC_HASKELL_DEFINITIONS_FIXTURE');
const directory = path.join(root, '.artifacts/haskell-constructor-native');
await mkdir(directory, {recursive: true});
const source = (await readFile(path.join(root, 'test/fixtures/python_constructor_fields.lawspec'), 'utf8')) + `
definition missing (x :: Unit) :: Optional (Nullable Int8) is undefined end
definition presentNull (x :: Unit) :: Optional (Nullable Int8) is optional(null) end
definition presentValue (x :: Unit) :: Optional (Nullable Int8) is optional(nullable(7)) end
definition echoList (xs :: List (Maybe Identity)) :: List (Maybe Identity) is xs end
definition echoNested (x :: Optional (Nullable Identity)) :: Optional (Nullable Identity) is x end
definition echoIdentityBucket (x :: Bucket Identity) :: Bucket Identity is x end
type Present (a :: Type) is Present item :: (m :: Maybe a where match m with | Nothing -> false | Just value -> true end) end
definition echoPresent (x :: Present Identity) :: Present Identity is x end
`;
const sourcePath = path.join(directory, 'fields.lawspec');
await writeFile(sourcePath, source);
for (const bits of [32, 64]) {
  execFileSync(fixture, [String(bits), path.join(directory, String(bits)), sourcePath]);
  for (const mode of ['pretty', 'compact']) {
    const project = path.join(directory, String(bits), mode);
    await writeFile(path.join(project, 'Main.hs'),
      await readFile(path.join(root, 'test/runtime/HaskellNativeConstructorCheck.hs')));
    const args = ['--make', 'Main.hs', '-O0', '-i.', '-outputdir', 'build', '-o', 'check'];
    execFileSync(ghc, args, {cwd: project, stdio: 'inherit'});
    execFileSync(path.join(project, 'check'), [String(bits)], {cwd: project, stdio: 'inherit'});
    for (const [name, before, after] of [
      ['LawSpecSchema.hs', 'unless accepted (Left (Rejected', 'unless (accepted || True) (Left (Rejected'],
      ['LawSpecCodecs.hs', 'S.validateWith scope schema typeRef bits value', 'S.validate schema typeRef bits value'],
    ]) {
      const file = path.join(project, name);
      const original = await readFile(file, 'utf8');
      assert.ok(original.includes(before));
      try {
        await writeFile(file, original.replace(before, after));
        execFileSync(ghc, args, {cwd: project, stdio: 'pipe'});
        const failure = spawnSync(path.join(project, 'check'), [String(bits)],
          {cwd: project, encoding: 'utf8'});
        assert.notEqual(failure.status, 0, 'contract mutant must fail execution');
      } finally {
        await writeFile(file, original);
      }
    }
    console.log('Haskell generated constructor predicates passed: ' + bits + ', ' + mode);
  }
}
