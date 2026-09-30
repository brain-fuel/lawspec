// Generated from templates/npm/test/api-types.test.mjs by lawspec-dev generate. Do not edit.
// The published TypeScript declarations admit an exhaustive visitor over the
// expression types (test/fixtures/payload_api.ts). Skipped without tsc.
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '../..');
const local = path.join(root, '.integration/typescript/node_modules/.bin/tsc');
const tsc = process.env.LAWSPEC_TSC ?? (existsSync(local) ? local : null);

test('published expression types pass exhaustive TypeScript visitor checks', {skip: tsc === null && 'tsc is not installed'}, () => {
  execFileSync(tsc, [
    '--noEmit', '--strict', '--target', 'ES2022', '--module', 'NodeNext',
    '--moduleResolution', 'NodeNext', 'test/fixtures/payload_api.ts',
  ], {cwd: root, stdio: 'pipe'});
});
