#!/usr/bin/env node
// The lawspec CLI: the Node host of the LawSpec core
// (docs/reference/host-effects.md). Every command runs in the core
// (host-core.wasm); this file only gathers the invocation and the host
// performs the effects the core asks for (host.mjs, worker.mjs). It holds
// no LawSpec logic. ref:DEC-host-effect-abi ref:DEC-haskell-application-port
// ref:DEC-native-canon
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {corePath as corePathOf} from '../core-path.mjs';
import {runCore} from '../host.mjs';

const packageRoot = fileURLToPath(new URL('..', import.meta.url));
const corePath =
  process.env.LAWSPEC_HOST_CORE ?? path.join(packageRoot, 'host-core.wasm');
// The package resources lawspec learn serves: LAWSPEC_RESOURCES, or this
// package.
const resources = corePathOf(
  process.platform,
  path.resolve(process.env.LAWSPEC_RESOURCES || packageRoot),
);
// The Canon lawspec project runs: the bundle LAWSPEC_CANON names, else the
// optional @goforgedev/canon-<platform> package, else, on a platform with no
// native Canon (Windows), the optional ricestax package through this Node.
// The host only finds them; the core decides. Every path reaches the core in
// its form (core-path.mjs).
const packages = createRequire(import.meta.url);
const packageDirectory = name =>
{
  try
  {
    return path.dirname(packages.resolve(`${name}/package.json`));
  }
  catch
  {
    return null;
  }
};
const core = file => corePathOf(process.platform, file);
const bundle = directory => ({
  command: [core(path.join(directory, 'canon'))],
  presets: core(path.join(directory, 'presets')),
});
const canonBundle =
  process.env.LAWSPEC_CANON ||
  packageDirectory(`@goforgedev/canon-${process.platform}-${process.arch}`);
const ricestax = canonBundle ? null : packageDirectory('ricestax');
const canon = canonBundle
  ? bundle(path.resolve(canonBundle))
  : ricestax
    ? {
        command: [
          core(process.execPath),
          core(path.join(ricestax, 'bin/ricestax.mjs')),
          'canon',
        ],
        presets: core(path.join(ricestax, 'presets')),
      }
    : null;
// The core names its compiler cache folder by the module it runs, and keys
// native test results by that module and the host that runs it.
const build = createHash('sha256').update(readFileSync(corePath)).digest('hex');
const outcome = await runCore(corePath, {
  abi: 2,
  argv: process.argv.slice(2),
  cwd: core(process.cwd()),
  build,
  host: {kind: 'node', version: process.version},
  resources,
  ...(canon ? {tools: {canon}} : {}),
});
if (typeof outcome.exit === 'number')
{
  process.exitCode = outcome.exit;
}
else
{
  // No command answers notPorted since the port completed; the outcome
  // stays in ABI 2, and this host has nothing to fall back to.
  process.stderr.write(
    `lawspec: ${outcome.notPorted ?? outcome.error?.message ?? 'no outcome'}\n`,
  );
  process.exitCode = typeof outcome.notPorted === 'string' ? 69 : 1;
}
