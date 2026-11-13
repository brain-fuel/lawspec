// Makes an initialised project usable without further manual steps: adds the
// settings an existing JSON build file lacks, creates the Python environment
// a Python project installs into and fetches dependencies with the target's
// own build tool. What to add and which commands to run are LawSpec.Scaffold's
// data; this module only reads, writes and runs.

import {access, readdir} from 'node:fs/promises';
import path from 'node:path';
import {prepareCommands, requirements, templates} from './templates.mjs';
import {atomicWrite, readOptional, safePath} from './files.mjs';
import {describeSpawnError, execTool, spawnTool} from './spawn.mjs';
const windows = process.platform === 'win32';

// Directories that hold installed or generated files, not the project's own.
const skipped = ['node_modules', 'dist', 'build', 'target', 'coverage'];

// The first CommonJS-by-default source in the project, if it has one. Such a
// file changes meaning when package.json's type becomes module.
async function firstScript(root, folder = '')
{
  const entries = await readdir(path.join(root, folder), {withFileTypes: true});
  for (const entry of entries)
  {
    const relative = path.join(folder, entry.name);
    if (entry.isDirectory())
    {
      if (entry.name.startsWith('.') || skipped.includes(entry.name)) continue;
      const found = await firstScript(root, relative);
      if (found) return found;
    }
    else if (/\.(?:js|jsx|ts|tsx)$/.test(entry.name)) return relative;
  }
  return null;
}

// Adds each required setting the file lacks and reports what it changed. A
// setting the project already has is kept, and lawspec doctor judges it; the
// one exception is npm init's default type=commonjs, which is replaced when no
// source file depends on it.
async function applyEntries(language, root, file, entries, document)
{
  const changed = [];
  for (const {path: keys, value} of entries)
  {
    let holder = document;
    for (const key of keys.slice(0, -1))
    {
      holder[key] ??= {};
      if (typeof holder[key] !== 'object' || Array.isArray(holder[key]))
        throw new Error(`${file}: ${key} must be an object`);
      holder = holder[key];
    }
    const leaf = keys.at(-1);
    const label = keys.join('.');
    if (keys[0] === 'devDependencies' && document.dependencies?.[leaf])
      continue;
    if (holder[leaf] === undefined)
    {
      holder[leaf] = value;
      changed.push(label);
    }
    else if (label === 'type' && holder[leaf] === 'commonjs')
    {
      const script = await firstScript(root);
      if (script)
        throw new Error(
          `${file} sets type=commonjs and ${script} depends on it. LawSpec's ${language} target needs type=module: convert the project to ES modules, or give the target its own directory with --project <directory>.`,
        );
      holder[leaf] = value;
      changed.push(label);
    }
  }
  return changed;
}

// Returns the files created from the scaffold and the settings added to
// existing files, for init's summary.
export async function applyRequirements(language, root, {minify = false} = {})
{
  const created = [];
  const updated = [];
  const scaffold = templates(language, {minify});
  for (const [file, entries] of Object.entries(requirements[language] ?? {}))
  {
    const target = await safePath(root, file);
    const text = await readOptional(target);
    if (text === null)
    {
      await atomicWrite(target, scaffold[file], true);
      created.push(file);
      continue;
    }
    if (entries.length === 0) continue;
    let document;
    try
    {
      document = JSON.parse(text);
    }
    catch
    {
      throw new Error(`${file} is not valid JSON, so lawspec init cannot update it`);
    }
    if (document === null || typeof document !== 'object' || Array.isArray(document))
      throw new Error(`${file} must hold a JSON object`);
    const changed = await applyEntries(language, root, file, entries, document);
    if (changed.length === 0) continue;
    const indent = text.match(/^([ \t]+)"/m)?.[1] ?? (text.includes('\n') ? '  ' : '');
    await atomicWrite(
      target,
      JSON.stringify(document, null, indent) + (text.endsWith('\n') ? '\n' : ''),
    );
    updated.push(`${file} (${changed.join(', ')})`);
  }
  return {created, updated};
}

// Runs a build tool, passing its output through to standard error so that
// standard output stays init's own.
function runTool(command, args, cwd, environment)
{
  return new Promise((resolve, reject) =>
  {
    const settings = {
      cwd,
      env: {...process.env, ...environment},
      stdio: ['ignore', 'pipe', 'pipe'],
    };
    const child = spawnTool(command, args, settings);
    child.stdout.pipe(process.stderr, {end: false});
    child.stderr.pipe(process.stderr, {end: false});
    const shown = [command, ...args].join(' ');
    child.on('error', error =>
    {
      const described = describeSpawnError(error, command, settings);
      reject(
        described === error
          ? new Error(`${shown}: ${error.message}`)
          : described,
      );
    });
    child.on('close', code =>
      code === 0 ? resolve() : reject(new Error(`${shown} exited with ${code}`)),
    );
  });
}

// The first interpreter on PATH that is new enough for the Python targets.
async function findPython()
{
  for (const candidate of ['python3', 'python3.14', 'python3.13', 'python'])
  {
    const recent = await execTool(candidate, [
      '-c',
      'import sys; print(sys.version_info[:2] >= (3, 13))',
    ]).then(
      result => result.stdout.trim() === 'True',
      () => false,
    );
    if (recent) return candidate;
  }
  throw new Error('Python 3.13 or later was not found on PATH');
}

// A project without a chosen interpreter gets its own virtual environment, so
// that installing its test dependencies never changes a system Python.
async function projectPython(root)
{
  const relative = windows
    ? path.join('.venv', 'Scripts', 'python.exe')
    : path.join('.venv', 'bin', 'python');
  const present = await access(path.join(root, relative)).then(
    () => true,
    () => false,
  );
  if (!present) await runTool(await findPython(), ['-m', 'venv', '.venv'], root, {});
  return relative;
}

// The manifest fields that name a target's own build tool.
const overrides = {
  mvn: 'maven',
  gradle: 'gradle',
  cargo: 'cargo',
  scala: 'scala',
  clojure: 'clojure',
  swift: 'swift',
};

// The Gradle command for a target: the manifest's gradle field, else the
// project's own wrapper, else gradle on PATH. init, generate and test share
// this choice.
export async function gradleFor(target, root)
{
  if (target.gradle) return target.gradle;
  const wrapper = path.join(root, windows ? 'gradlew.bat' : 'gradlew');
  return access(wrapper).then(
    () => wrapper,
    () => 'gradle',
  );
}

export async function toolFor(command, target, root)
{
  if (command === 'gradle') return gradleFor(target, root);
  return target[overrides[command]] || command;
}

// Fetches the project's dependencies. For a Python target that init is adding
// and that names no interpreter, returns the environment created for it, for
// init to record in the manifest. A target the manifest already declares keeps
// the interpreter the manifest implies, so its text is not rewritten.
export async function prepareProject(target, root, {added = false} = {})
{
  const commands = prepareCommands[target.language] ?? [];
  const usesPython = commands.some(step => step.command === '{python}');
  const python =
    usesPython && added && !target.python ? await projectPython(root) : undefined;
  for (const step of commands)
  {
    const command =
      step.command === '{python}'
        ? (target.python ?? python ?? 'python3')
        : await toolFor(step.command, target, root);
    await runTool(command, step.args, root, step.environment);
  }
  return python === undefined ? {} : {python};
}
