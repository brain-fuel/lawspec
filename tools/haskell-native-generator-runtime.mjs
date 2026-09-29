import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const ghc = process.env.LAWSPEC_GHC;
const packageDb = process.env.LAWSPEC_GHC_PACKAGE_DB;
assert.ok(ghc && packageDb, 'Set LAWSPEC_GHC and LAWSPEC_GHC_PACKAGE_DB');
const directory = path.join(root, '.artifacts/haskell-native-generator-runtime');
await mkdir(directory, {recursive: true});
for (const name of ['LawSpecRuntime.hs', 'LawSpecSchema.hs', 'LawSpecCodecs.hs', 'LawSpecDataStrategies.hs']) {
  await writeFile(path.join(directory, name), await readFile(path.join(root, 'runtime', name)));
}
await writeFile(path.join(directory, 'Main.hs'), await readFile(path.join(root, 'test/runtime/HaskellNativeGeneratorsCheck.hs')));
execFileSync(ghc, ['--make', 'Main.hs', '-O0', '-i.', '-package-db', packageDb,
  '-outputdir', 'build', '-o', 'check'], {cwd: directory, stdio: 'inherit'});
execFileSync(path.join(directory, 'check'), [], {cwd: directory, stdio: 'inherit', timeout: 30000});
