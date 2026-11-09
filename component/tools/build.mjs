// Generated from templates/component/tools/build.mjs by lawspec-dev generate. Do not edit.
// Application build: consumes installed SDK packages, never their source checkout.
// ref:DEC-host-sdk-independent-consumer
import {
  generateBindings,
  packageComponent,
  runHaskell,
  supportDirectory,
  witDirectory,
} from 'wasm-platform-kit-build';
import {mkdir, readFile, writeFile, copyFile, readdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pilot = path.join(root, 'pilot');
const generated = path.join(root, 'generated');
await mkdir(path.join(pilot, 'wit/deps/host'), {recursive: true});
await copyFile(
  path.join(witDirectory(), 'host.wit'),
  path.join(pilot, 'wit/deps/host/host.wit'),
);
await generateBindings({
  wit: path.join(pilot, 'wit'),
  world: 'pilot',
  out: generated,
});
const symbols = JSON.parse(
  await readFile(path.join(generated, 'linker.json'), 'utf8'),
);
await writeFile(
  path.join(pilot, 'cabal.project.local'),
  `packages: ${JSON.stringify(supportDirectory())}\npackage host-sdk-pilot\n  ghc-options: -optl-Wl,${symbols.map(name => '--export=' + name).join(',')},--allow-undefined\n`,
);
const options = {cwd: pilot, stdio: 'inherit'};
runHaskell(
  'wasm32-wasi-cabal',
  ['build', '--builddir=../dist-newstyle', 'host-sdk-pilot'],
  options,
);
const core = runHaskell(
  'wasm32-wasi-cabal',
  ['list-bin', '--builddir=../dist-newstyle', 'host-sdk-pilot'],
  {cwd: pilot, encoding: 'utf8'},
).trim();
await packageComponent({
  core,
  wit: path.join(pilot, 'wit'),
  world: 'pilot',
  generated,
  directory: path.join(root, 'assets'),
  interfaceName: 'lawspec:format-pilot/application@0.1.0',
  requirements: [{provider: 'compiler-cache', kind: 'files'}],
});
await copyFile(
  path.join(root, '../npm/host-codecs.mjs'),
  path.join(root, 'assets/public-codecs.mjs'),
);
const stage = path.join(root, '../npm/host-component');
await mkdir(stage, {recursive: true});
await mkdir(path.join(stage, 'runtime'), {recursive: true});
for (const name of [
  'component.wasm',
  'manifest.json',
  'node.mjs',
  'node-registration.mjs',
  'install.mjs',
  '.npmignore',
  'native-artifacts.json',
  ...(await readdir(path.join(root, 'assets'))).filter(name =>
    name.endsWith('.cwasm'),
  ),
  'node.d.mts',
  'runtime/client.mjs',
  'runtime/policy.mjs',
])
  await copyFile(path.join(root, 'assets', name), path.join(stage, name));
console.log('Built the LawSpec component using installed SDK artifacts.');
