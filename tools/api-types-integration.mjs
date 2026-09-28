import {execFileSync} from 'node:child_process';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
execFileSync(process.env.LAWSPEC_TSC ?? 'tsc', [
  '--noEmit', '--strict', '--target', 'ES2022', '--module', 'NodeNext',
  '--moduleResolution', 'NodeNext', 'test/fixtures/payload_api.ts',
], {cwd: root, stdio: 'inherit'});
console.log('Published expression types pass exhaustive TypeScript visitor checks');
