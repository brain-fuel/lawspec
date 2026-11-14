// Acceptance-format mutations run only in disposable project copies.
// ref:DEC-s1j-shared-failures
import {readManifest} from './component.mjs';
import {
  cp,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  writeFile,
} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';

export function parseMutant(content)
{
  const lines = content.split(/\r?\n/);
  const expectations = [],
    forbidden = [],
    edits = [];
  let at = 0,
    rejection = null,
    outputUnchecked = null,
    file;
  while (at < lines.length && !lines[at].startsWith('@@ '))
  {
    const line = lines[at++];
    if (/^ *$/.test(line)) continue;
    if (['rejected-at: compile', 'rejected-at: generation'].includes(line))
      rejection = line.slice(13);
    else if (line.startsWith('expect: ')) expectations.push([line.slice(8)]);
    else if (line.startsWith('expect-any: '))
      expectations.push(line.slice(12).split(' | '));
    else if (line.startsWith('forbid: ')) forbidden.push(line.slice(8));
    else if (line.startsWith('output-unchecked-on: '))
    {
      // The mutant must still fail on these targets; only its output is not
      // held to the expectations there, for the stated reason.
      const [targets, ...reason] = line.slice(21).split('|');
      outputUnchecked = {
        targets: targets.split(' ').filter(Boolean),
        reason: reason.join('|').trim(),
      };
      if (!outputUnchecked.targets.length || !outputUnchecked.reason)
        throw new Error('output-unchecked-on needs targets, then | and a reason');
    }
    else throw new Error(`unexpected header line: ${line}`);
  }
  while (at < lines.length)
  {
    const line = lines[at++];
    if (/^ *$/.test(line)) continue;
    if (line.startsWith('@@ '))
    {
      file = line.slice(3);
      continue;
    }
    if (line !== '<<<<<<<' || !file)
      throw new Error(`unexpected line: ${line}`);
    const search = [],
      replacement = [];
    while (at < lines.length && lines[at] !== '=======')
      search.push(lines[at++]);
    if (at++ >= lines.length) throw new Error('missing =======');
    while (at < lines.length && lines[at] !== '>>>>>>>')
      replacement.push(lines[at++]);
    if (at++ >= lines.length) throw new Error('missing >>>>>>>');
    edits.push({
      file,
      search: search.join('\n'),
      replacement: replacement.join('\n'),
    });
  }
  if (!edits.length) throw new Error('mutation has no edits');
  return {expectations, forbidden, edits, rejection, outputUnchecked};
}

export async function applyMutant(root, mutant)
{
  root = await realpath(root);
  for (const {file, search, replacement} of mutant.edits)
  {
    const target = path.resolve(root, file);
    const relative = path.relative(root, target);
    if (!relative || relative.startsWith('..') || path.isAbsolute(relative))
      throw new Error(`edit leaves project: ${file}`);
    const actual = await realpath(target);
    if (actual !== target)
      throw new Error(`mutation edits through a symbolic link: ${file}`);
    const text = await readFile(target, 'utf8');
    if (search === '*') await writeFile(target, replacement);
    else
    {
      const index = text.indexOf(search);
      if (
        !search ||
        index < 0 ||
        text.indexOf(search, index + search.length) >= 0
      )
        throw new Error(`edit must match exactly once: ${file}`);
      await writeFile(
        target,
        text.slice(0, index) + replacement + text.slice(index + search.length),
      );
    }
  }
}

async function discover(root, paths)
{
  const files = [];
  async function visit(file, explicit = false)
  {
    const info = await lstat(file);
    if (info.isSymbolicLink())
      throw new Error(`symbolic mutation path: ${file}`);
    if (info.isDirectory())
      for (const name of (await readdir(file)).sort())
        await visit(path.join(file, name));
    else if (file.endsWith('.mutant')) files.push(file);
    else if (explicit) throw new Error(`expected a .mutant file: ${file}`);
  }
  for (const name of paths.length ? paths : ['mutants'])
    await visit(path.resolve(root, name), true);
  return [...new Set(files)].sort();
}

function execute(root, args, timeout)
{
  return new Promise(resolve =>
  {
    const child = spawn(
      process.execPath,
      [
        fileURLToPath(new URL('./bin/lawspec.mjs', import.meta.url)),
        'test',
        '--fresh',
        '--json',
        ...args,
      ],
      {
        cwd: root,
        detached: process.platform !== 'win32',
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
    let stdout = '',
      stderr = '',
      timedOut = false;
    const timer = setTimeout(() =>
    {
      timedOut = true;
      if (process.platform !== 'win32')
      {
        try
        {
          process.kill(-child.pid, 'SIGKILL');
        }
        catch
        {}
      }
      else child.kill('SIGKILL');
    }, timeout);
    child.stdout.on('data', chunk =>
    {
      stdout += chunk;
    });
    child.stderr.on('data', chunk =>
    {
      stderr += chunk;
    });
    child.on('error', error =>
    {
      clearTimeout(timer);
      resolve({code: null, error: error.message, output: stderr});
    });
    child.on('close', code =>
    {
      clearTimeout(timer);
      let report;
      try
      {
        report = JSON.parse(stdout);
      }
      catch
      {}
      resolve({code, timedOut, report, output: stdout + stderr});
    });
  });
}

export function classifyMutation(run, mutant, target)
{
  const failedLaws = [
    ...new Set(
      (Array.isArray(run.report) ? run.report : []).flatMap(
        row => row.failedLaws ?? [],
      ),
    ),
  ].sort();
  if (run.timedOut) return {status: 'timed-out', failedLaws};
  if (run.error) return {status: 'errored', failedLaws, reason: run.error};
  if (
    run.report?.diagnostics?.some(row =>
      ['unsupported', 'target-unsupported'].includes(row.code),
    )
  )
    return {status: 'unsupported', failedLaws};
  if (run.code === 0) return {status: 'surviving', failedLaws};
  if (!failedLaws.length)
    return {
      status: Array.isArray(run.report)
        ? 'errored'
        : run.report?.diagnostics?.length
          ? 'invalid'
          : 'errored',
      failedLaws,
      reason: 'No individually identified executed failing law',
      diagnostics: run.report?.diagnostics,
    };
  if (mutant.outputUnchecked?.targets.includes(target))
    return {
      status: 'killed',
      failedLaws,
      outputUnchecked: mutant.outputUnchecked.reason,
    };
  if (
    !mutant.expectations.every(alternatives =>
      alternatives.some(text => run.output.includes(text)),
    ) ||
    mutant.forbidden.some(text => run.output.includes(text))
  )
    return {
      status: 'errored',
      failedLaws,
      reason: 'Failure did not meet the mutation expectations',
    };
  return {status: 'killed', failedLaws};
}

export async function mutateProject({
  root,
  paths = [],
  target,
  timeout = 120000,
  config = 'lawspec.edn',
  run = execute,
})
{
  root = await realpath(root);
  if (!Number.isSafeInteger(timeout) || timeout <= 0)
    throw new Error('mutation timeout must be a positive integer');
  const configRelative = path.relative(root, path.resolve(root, config));
  if (configRelative.startsWith('..') || path.isAbsolute(configRelative))
    throw new Error('mutation configuration must be inside the project');
  const manifest = await readManifest(path.resolve(root, configRelative));
  for (const source of manifest.sources ?? [])
    if (path.isAbsolute(source) || source.split(/[\\/]/).includes('..'))
      throw new Error(
        'mutation sources must be relative paths inside the project',
      );
  for (const target of manifest.targets ?? [])
  {
    const relative = path.relative(
      root,
      path.resolve(root, target.root ?? '.'),
    );
    if (relative.startsWith('..') || path.isAbsolute(relative))
      throw new Error('mutation targets must be inside the project');
  }
  // Do not let generation or the native runner follow a link back into the
  // original workspace. Internal dependency links are copied by value.
  async function checkLinks(directory)
  {
    for (const name of await readdir(directory))
    {
      if (
        name === '.git' ||
        (path.basename(directory) === '.lawspec' &&
          ['cache', 'results'].includes(name))
      )
        continue;
      const file = path.join(directory, name),
        info = await lstat(file);
      if (info.isSymbolicLink())
      {
        const relative = path.relative(root, await realpath(file));
        if (relative.startsWith('..') || path.isAbsolute(relative))
          throw new Error(
            `external symbolic link in mutation project: ${file}`,
          );
      }
      else if (info.isDirectory()) await checkLinks(file);
    }
  }
  await checkLinks(root);
  const files = await discover(root, paths);
  if (!files.length) throw new Error('no .mutant files found');
  const directory = await mkdtemp(path.join(os.tmpdir(), 'lawspec-mutate-'));
  const copy = path.join(directory, 'project');
  const args = [
    '--config',
    configRelative,
    ...(target ? ['--target', target] : []),
  ];
  // The compiler cache is content-addressed, so every run shares one: a
  // mutant that edits no specification compiles nothing again, and one that
  // does misses only what its edit reaches. Native results are never shared.
  const cache = path.join(directory, 'compiler-cache');
  const copiedCache = path.join(copy, '.lawspec', 'cache');
  await cp(path.join(root, '.lawspec', 'cache'), cache, {
    recursive: true,
  }).catch(error =>
  {
    if (error.code !== 'ENOENT') throw error;
  });
  async function reset()
  {
    await rename(copiedCache, cache).catch(error =>
    {
      if (error.code !== 'ENOENT') throw error;
    });
    await rm(copy, {recursive: true, force: true});
    await cp(root, copy, {
      recursive: true,
      dereference: true,
      filter: source =>
        path.basename(source) !== '.git' &&
        !(
          path.basename(path.dirname(source)) === '.lawspec' &&
          ['cache', 'results'].includes(path.basename(source))
        ),
    });
    await mkdir(path.dirname(copiedCache), {recursive: true});
    await rename(cache, copiedCache).catch(error =>
    {
      if (error.code !== 'ENOENT') throw error;
    });
  }
  // The generated files a mutant edits, which its test run must not replace.
  async function editedGenerated(mutant)
  {
    const owned = new Set();
    for (const entry of manifest.targets ?? [])
    {
      const targetRoot = path.resolve(copy, entry.root ?? '.');
      let recorded;
      try
      {
        recorded = JSON.parse(
          await readFile(
            path.join(targetRoot, '.lawspec', 'generated.json'),
            'utf8',
          ),
        );
      }
      catch (error)
      {
        if (error.code !== 'ENOENT') throw error;
        continue;
      }
      for (const name of Object.keys(recorded.files ?? {}))
        owned.add(path.resolve(targetRoot, name));
    }
    return mutant.edits
      .map(edit => path.resolve(copy, edit.file))
      .filter(file => owned.has(file))
      .map(file => path.relative(copy, file));
  }
  try
  {
    await reset();
    const baseline = await run(copy, args, timeout);
    if (
      baseline.code !== 0 ||
      !Array.isArray(baseline.report) ||
      !baseline.report.some(row => row.ok && row.ran?.length)
    )
      return {
        ok: false,
        baseline: {
          status: baseline.timedOut ? 'timed-out' : 'failed',
          report: baseline.report,
        },
        mutations: [],
        killMatrix: {},
        uniqueKills: {},
      };
    const mutations = [];
    for (const file of files)
    {
      const name = path.relative(root, file);
      let phase = 'invalid';
      try
      {
        const mutant = parseMutant(await readFile(file, 'utf8'));
        await reset();
        const generated = await editedGenerated(mutant);
        await applyMutant(copy, mutant);
        phase = 'errored';
        const result = await run(
          copy,
          generated.length
            ? [...args, '--mutated-generated', generated.join(',')]
            : args,
          timeout,
        );
        mutations.push({name, ...classifyMutation(result, mutant, target)});
      }
      catch (error)
      {
        mutations.push({
          name,
          status: phase,
          failedLaws: [],
          reason: error.message,
        });
      }
    }
    const killMatrix = {},
      uniqueKills = {};
    for (const mutant of mutations.filter(row => row.status === 'killed'))
      for (const law of mutant.failedLaws)
      {
        (killMatrix[law] ??= []).push(mutant.name);
        if (mutant.failedLaws.length === 1)
          (uniqueKills[law] ??= []).push(mutant.name);
      }
    return {
      ok: mutations.every(row => row.status === 'killed'),
      baseline: {status: 'passed'},
      mutations,
      killMatrix,
      uniqueKills,
    };
  }
  finally
  {
    await rm(directory, {recursive: true, force: true});
  }
}
