// Compile dependencies before LawSpec generates the runtime imported by the app.
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {cp, mkdir, mkdtemp, readFile, readdir, rm} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const exec = promisify(execFile);
const root = path.dirname(fileURLToPath(import.meta.url));
await mkdir(path.join(root, '.lawspec'), {recursive: true});
const temporary = await mkdtemp(path.join(root, '.lawspec/dependencies-'));
try {
  // Use the project's actual dependency requirements and lock file, with empty
  // application roots. Application code remains in place throughout setup.
  await mkdir(path.join(temporary, 'src'), {recursive: true});
  await mkdir(path.join(temporary, 'test-support/src'), {recursive: true});
  for (const file of ['gleam.toml', 'test-support/gleam.toml'])
    await cp(path.join(root, file), path.join(temporary, file));
  try { await cp(path.join(root, 'manifest.toml'), path.join(temporary, 'manifest.toml')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  // Reuse downloaded packages when available, including fully offline setups.
  try { await cp(path.join(root, 'build/packages'), path.join(temporary, 'build/packages'), {recursive: true}); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }

  const {stdout, stderr} = await exec('gleam', ['build'], {cwd: temporary,
    timeout: 300000, maxBuffer: 8 * 1024 * 1024});
  process.stdout.write(stdout);
  process.stderr.write(stderr);
  const information = path.join(temporary, 'package.json');
  await exec('gleam', ['export', 'package-information', '--out', information], {cwd: temporary});
  const application = JSON.parse(await readFile(information, 'utf8'))['gleam.toml'].name;

  await mkdir(path.join(root, 'build/dev/erlang'), {recursive: true});
  await cp(path.join(temporary, 'build/packages'), path.join(root, 'build/packages'), {recursive: true});
  for (const entry of await readdir(path.join(temporary, 'build/dev/erlang'), {withFileTypes: true})) {
    if (!entry.isDirectory() || [application, 'lawspec_test_support'].includes(entry.name)) continue;
    await cp(path.join(temporary, 'build/dev/erlang', entry.name),
      path.join(root, 'build/dev/erlang', entry.name), {recursive: true});
  }
  await cp(path.join(temporary, 'manifest.toml'), path.join(root, 'manifest.toml'));
  console.log('Dependencies compiled. Run lawspec generate, then gleam test.');
} catch (error) {
  process.stderr.write(error.stdout ?? '');
  process.stderr.write(error.stderr ?? '');
  throw error;
} finally {
  await rm(temporary, {recursive: true, force: true});
}
