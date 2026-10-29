import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {lstat, mkdir, readFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {initialize} from 'ricestax/setup.mjs';
import {createCompiler} from './api.mjs';
import {readManifest, writeManifest, dependencyRanges} from './component.mjs';
import {resolveDependencies} from './component-packages.mjs';
import {atomicWrite, collectSources, safePath} from './files.mjs';
// Rice's Tax owns Canon setup and grammars; its exact npm version is pinned.
export const canonSetupVersion = '0.3.2';
const rice = fileURLToPath(import.meta.resolve('ricestax/bin/ricestax.mjs'));
const cli = fileURLToPath(new URL('./bin/lawspec.mjs', import.meta.url));
async function exists(file)
{
  try
  {
    await lstat(file);
    return true;
  }
  catch (error)
  {
    if (error.code === 'ENOENT')
    {
      return false;
    }
    throw error;
  }
}
function run(root, file, args, node = true)
{
  const result = spawnSync(
    node ? process.execPath : file,
    node ? [file, ...args] : args,
    {cwd: root, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024},
  );
  let data;
  try
  {
    data = JSON.parse(result.stdout);
  }
  catch
  {
    /* Canon emits text. */
  }
  return {
    status:
      result.error || result.signal
        ? 'incomplete'
        : result.status === 0
          ? 'passed'
          : result.status === 2
            ? 'incomplete'
            : 'failed',
    exitCode: result.status,
    ...(data === undefined ? {output: result.stdout ?? ''} : {result: data}),
    ...(result.stderr || result.error
      ? {detail: result.error?.message ?? result.stderr}
      : {}),
  };
}
async function inspectCanon(root, validate)
{
  if (!(await exists(path.join(root, 'canon.yaml'))))
  {
    return {
      status: 'incomplete',
      detail: 'No canon.yaml; run lawspec project adopt',
    };
  }
  const config = await readFile(path.join(root, 'canon.yaml'), 'utf8');
  const expected =
    config.match(/^canon:\s*["']?([\d.x]+)/m)?.[1] ??
    config.match(/"canon"\s*:\s*"([\d.x]+)"/)?.[1];
  const binary = process.env.CANON;
  const version = binary
    ? run(root, binary, ['version'], false)
    : run(root, rice, ['canon', 'version']);
  const actual = version.output?.match(/canon\s+(\d+\.\d+\.\d+)/)?.[1];
  if (
    version.status !== 'passed' ||
    !actual ||
    (expected &&
      expected.split('.').slice(0, 2).join('.') !==
        actual.split('.').slice(0, 2).join('.'))
  )
  {
    return {
      status: 'incomplete',
      expectedVersion: expected,
      actualVersion: actual,
      detail:
        'Canon version unavailable or incompatible. Set CANON to the matching native executable; existing metadata is preserved.',
    };
  }
  const args = [validate ? 'check' : 'decisions'];
  return {
    ...(binary
      ? run(root, binary, args, false)
      : run(root, rice, ['canon', ...args])),
    version: actual,
  };
}
export async function setupProject(
  root,
  {adopt = false, languages = ['folio']} = {},
)
{
  root = path.resolve(root);
  // Complete preflight before invoking the upstream initializer or writing files.
  for (const old of ['lawspec.json', 'lawspec-package.json'])
  {
    if (await exists(path.join(root, old)))
    {
      throw new Error(`${old} is no longer supported; use lawspec.edn`);
    }
  }
  const hasManifest = await exists(path.join(root, 'lawspec.edn'));
  const hasCanon = await exists(path.join(root, 'canon.yaml'));
  if (!adopt && (hasManifest || hasCanon))
  {
    throw new Error(
      'Project metadata already exists; use lawspec project adopt',
    );
  }
  if (hasManifest)
  {
    await readManifest(path.join(root, 'lawspec.edn'));
  }
  if (!hasCanon && (await exists(path.join(root, '.ricestax'))))
  {
    throw new Error(
      '.ricestax exists without canon.yaml; review the incomplete Canon setup',
    );
  }
  const manifest = {
    manifestVersion: 1,
    component: {
      name: path.basename(root).replace(/[^A-Za-z0-9_.-]/g, '-'),
      version: '0.1.0',
    },
    languageProfile: '1.0-rc.2',
    verification: {layers: []},
    sources: ['laws'],
    targets: [],
  };
  // A tiny empty unit makes mandatory validation available before choosing a target.
  const starter = !hasManifest && !(await exists(path.join(root, 'laws')));
  await mkdir(root, {recursive: true});
  if (!hasCanon)
  {
    await initialize(root, languages);
    // Upstream setup does not create a decision ledger. Never replace an existing one.
    for (const name of [
      'canonical_decisions.yaml',
      'canonical_refs.yaml',
      'canonical_exemptions.yaml',
    ])
    {
      if (!(await exists(path.join(root, name))))
      {
        await atomicWrite(await safePath(root, name), '{}\n', true);
      }
    }
  }
  if (!hasManifest)
  {
    if (starter)
    {
      await atomicWrite(
        await safePath(root, 'laws/project.lawspec'),
        'unit project\nend unit\n',
        true,
      );
    }
    await atomicWrite(
      await safePath(root, 'lawspec.edn'),
      writeManifest(manifest),
      true,
    );
  }
  return {
    root,
    manifest: hasManifest ? 'preserved' : 'created',
    canon: hasCanon ? 'preserved' : 'created',
    canonSetup: `ricestax@${canonSetupVersion}`,
    applicationFilesChanged: false,
  };
}
export async function inspectProject(
  root,
  {validate = false, configFile = path.join(root, 'lawspec.edn')} = {},
)
{
  root = path.resolve(root);
  configFile = path.resolve(configFile);
  const canon = await inspectCanon(root, validate).catch(error => ({
    status: 'incomplete',
    detail: error.message,
  }));
  const report = {root, canon};
  try
  {
    const manifest = await readManifest(configFile);
    const compiler = await createCompiler();
    const dependencies = await resolveDependencies(configFile, manifest, {
      writeLock: false,
    });
    const input = {
      sources: await collectSources(root, manifest.sources),
      languageProfile: manifest.languageProfile,
      machineBits: manifest.machineBits ?? 64,
      packages: dependencies.packages,
      dependencies: dependencyRanges(manifest),
      ...(manifest.package ? {package: manifest.package} : {}),
      projectVersion: manifest.component?.version ?? manifest.package?.version,
      now: new Date().toISOString(),
    };
    const checked = await compiler.check({
      ...input,
      verification: {layers: []},
    });
    report.definitions = {
      status: checked.diagnostics?.length ? 'failed' : 'passed',
      diagnostics: checked.diagnostics ?? [],
    };
    report.verification = {
      layers: manifest.verification?.layers ?? [],
      status: 'not-verified',
      evidence: checked.evidence,
    };
    if (validate && report.definitions.status === 'passed')
    {
      const selected = await compiler.check({
        ...input,
        verification: manifest.verification ?? {layers: []},
      });
      report.verification = {
        layers: manifest.verification?.layers ?? [],
        status: selected.diagnostics?.length
          ? 'failed'
          : manifest.verification?.layers?.length
            ? 'completed'
            : 'not-verified',
        selection: selected.verification,
        diagnostics: selected.diagnostics ?? [],
        evidence: selected.evidence,
      };
      if (report.verification.layers.includes('proof'))
      {
        report.proof = run(root, cli, [
          'prove',
          '--config',
          configFile,
          '--json',
        ]);
        // Solver discharge settles the previously generated obligations. Keep
        // its original rows, rather than reporting the pre-solver incompleteness.
        if (Array.isArray(report.proof.result?.evidence))
        {
          report.verification.evidence = report.proof.result.evidence;
        }
      }
      if (
        report.verification.layers.some(layer =>
          ['property', 'examples', 'exhaustive', 'model'].includes(layer),
        )
      )
      {
        report.native = manifest.targets?.length
          ? run(root, cli, ['test', '--config', configFile, '--json'])
          : {
              status: 'incomplete',
              detail: 'Selected execution layers have no application target',
            };
      }
    }
  }
  catch (error)
  {
    if (!report.definitions)
    {
      report.definitions = {
        status: 'incomplete',
        detail: error.message,
        diagnostics: error.diagnostics ?? [],
      };
    }
    else
    {
      report.verification = {
        ...report.verification,
        status: 'incomplete',
        detail: error.message,
      };
    }
  }
  return report;
}
export function projectExitCode(report)
{
  if (
    [
      report.canon,
      report.definitions,
      report.verification,
      report.proof,
      report.native,
    ].some(row => row?.status === 'failed')
  )
  {
    return 1;
  }
  const evidence = report.verification?.evidence;
  const rows =
    evidence?.obligations ?? (Array.isArray(evidence) ? evidence : []);
  if (rows.some(row => row.status === 'refuted'))
  {
    return 1;
  }
  if (
    [
      report.canon,
      report.definitions,
      report.verification,
      report.proof,
      report.native,
    ].some(row => row?.status === 'incomplete') ||
    rows.some(row =>
      ['unknown', 'unsupported', 'incomplete', 'pending'].includes(row.status),
    )
  )
  {
    return 2;
  }
  return 0;
}
