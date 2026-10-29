import {packageLearn} from '../npm/learn.mjs';
import path from 'node:path';
const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== '--out')
{
  throw new Error('Usage: node tools/learn-site.mjs --out <static-directory>');
}
const destination = path.resolve(args[1]);
await packageLearn(destination);
console.log(`Packaged Learn at ${destination}`);
