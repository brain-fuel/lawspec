// Generated from templates/npm/test/prove-cli.mjs by lawspec-dev generate. Do not edit.
// lawspec prove --json through the package's CLI, for tests written against
// the proveWithZ3(compiler, request, options) the legacy CLI exported: the
// request's sources become a project of their own (lawspec.edn with its
// verification layers and machine bits) and the options become the CLI's
// solver flags. The CLI prints what proveWithZ3 returned. A request field
// the CLI cannot express (a forged modelResults) is refused, never ignored;
// the compiler argument is unused, since the CLI runs the package's own.
import {spawnSync} from 'node:child_process';
import {mkdtemp, mkdir, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {configEDN} from './manifest-fixtures.mjs';

const cli = fileURLToPath(new URL('../bin/lawspec.mjs', import.meta.url));
const requestFields = new Set([
  'schemaVersion',
  'languageProfile',
  'verification',
  'machineBits',
  'sources',
  'cacheDirectory',
]);
const flags = [
  ['binary', '--solver'],
  ['timeoutMs', '--proof-timeout'],
  ['memoryMb', '--proof-memory'],
  ['resourceLimit', '--proof-rlimit'],
  ['seed', '--proof-seed'],
];

export async function proveWithZ3(_compiler, request, options = {}, root)
{
  for (const field of Object.keys(request))
    if (!requestFields.has(field))
      throw new Error(`lawspec prove takes no ${field} from its caller`);
  if (request.schemaVersion !== undefined && request.schemaVersion !== 5)
    throw new Error('lawspec prove reads lawspec.edn, the current schema');
  const project =
    root ?? (await mkdtemp(path.join(tmpdir(), 'lawspec-prove-')));
  try
  {
    await mkdir(path.join(project, 'laws'), {recursive: true});
    for (const source of request.sources)
      await writeFile(path.join(project, 'laws', source.path), source.content);
    await writeFile(
      path.join(project, 'lawspec.edn'),
      configEDN({
        manifestVersion: 1,
        languageProfile: request.languageProfile ?? '1.0-rc.2',
        sources: ['laws'],
        targets: [],
        verification: {layers: request.verification?.layers ?? []},
        ...(request.machineBits ? {machineBits: request.machineBits} : {}),
        ...(request.cacheDirectory
          ? {cacheDirectory: request.cacheDirectory}
          : {}),
      }),
    );
    const argv = [cli, 'prove', '--json'];
    for (const [option, flag] of flags)
      if (options[option] !== undefined)
        argv.push(flag, String(options[option]));
    const run = spawnSync(process.execPath, argv, {
      cwd: project,
      encoding: 'utf8',
      env: {...process.env, NODE_NO_WARNINGS: '1'},
      maxBuffer: 256 * 1024 * 1024,
    });
    if (!run.stdout.trim())
      throw new Error(
        `lawspec prove printed nothing (exit ${run.status}): ${run.stderr}`,
      );
    return JSON.parse(run.stdout);
  }
  finally
  {
    if (!root) await rm(project, {recursive: true, force: true});
  }
}
