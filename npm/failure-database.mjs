// Generated from templates/npm/failure-database.mjs by lawspec-dev generate. Do not edit.
// Failed seeds and framework counterexamples belong to one project root.
import {createHash} from 'node:crypto';
import {cp, mkdir, mkdtemp, readFile, rename, rm, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {readOptional} from './files.mjs';

export const projectKey = root => createHash('sha256').update(path.resolve(root)).digest('hex').slice(0, 12);

function parseDatabase(text) {
  const database = JSON.parse(text);
  if (!database || typeof database !== 'object' || Array.isArray(database))
    throw new Error('The failure database must contain a map of law identities to failures');
  return database;
}

export async function failureDatabase(configRoot, language, root) {
  const legacy = path.join(configRoot, '.lawspec/failures', language);
  const directory = path.join(legacy, projectKey(root));
  const file = path.join(directory, 'laws.json');
  const current = await readOptional(file);
  if (current !== null) return {directory, file, database: parseDatabase(current)};

  // Old databases identify only the language. Preserve them and copy their
  // failures once into each project's initial state so no counterexample is
  // lost. Subsequent passes and failures change only that project's copy.
  const database = parseDatabase((await readOptional(path.join(legacy, 'laws.json'))) ?? '{}');
  await mkdir(legacy, {recursive: true});
  const temporary = await mkdtemp(path.join(legacy, '.migrate-'));
  try {
    for (const name of ['inputs', 'hypothesis', 'proptest-regressions.txt']) {
      try { await cp(path.join(legacy, name), path.join(temporary, name), {recursive: true}); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    await writeFile(path.join(temporary, 'laws.json'), JSON.stringify(database, null, 2) + '\n');
    try { await rename(temporary, directory); }
    catch (error) {
      // Another invocation may have initialized the same project while this
      // one copied the legacy data. Its complete database takes precedence.
      if (!['EEXIST', 'ENOTEMPTY'].includes(error.code) || await readOptional(file) === null) throw error;
    }
  } finally {
    await rm(temporary, {recursive: true, force: true});
  }
  return {directory, file, database: parseDatabase(await readFile(file, 'utf8'))};
}
