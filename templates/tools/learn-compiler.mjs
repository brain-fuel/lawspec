// Write npm/core.wasm.gz, the compiler lawspec learn serves, unless it is
// already there and current. learn.mjs gzipped npm/core.wasm itself on the
// first request, with Node's zlib at level 9; the application core has no
// compressor that gives those bytes, so the same gzipSync output is written
// here, once per core, and the core serves the file. It is current when it
// is no older than core.wasm and its trailer records core.wasm's length;
// the core checks the same. tools/wasm.sh and tools/learn-build.mjs run this.
// The bytes are the running Node's zlib output, which differs between Node
// builds (ghc-wasm-meta's Node 26.8.2 and Homebrew's 26.8.1 differ), so it
// must run under the Node that runs the legacy CLI for the two to serve the
// same bytes; tools/wasm.sh runs it under the Node it found first.
// ref:DEC-haskell-application-port
import {readFileSync, statSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {gzipSync} from 'node:zlib';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = path.join(root, 'npm/core.wasm');
const target = path.join(root, 'npm/core.wasm.gz');

function current()
{
  try
  {
    const original = statSync(source);
    const archive = statSync(target);
    if (archive.mtimeMs < original.mtimeMs || archive.size < 18)
    {
      return false;
    }
    const bytes = readFileSync(target);
    return bytes.readUInt32LE(bytes.length - 4) === original.size % 2 ** 32;
  }
  catch
  {
    return false;
  }
}

if (current())
{
  console.log('npm/core.wasm.gz is current.');
}
else
{
  writeFileSync(target, gzipSync(readFileSync(source), {level: 9}));
  console.log('Wrote npm/core.wasm.gz.');
}
