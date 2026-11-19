// lawspec lsp --stdio through the package's CLI, for tests written against
// the serveLanguage(input, output, compiler) the legacy CLI exported: input
// becomes the server's standard input and its standard output is copied to
// output. The server runs the package's compiler in the LawSpec core, so
// the compiler argument (createCompiler's, the same compiler) is unused;
// tests that handed the legacy server a stub compiler were removed.
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const cli = fileURLToPath(new URL('../bin/lawspec.mjs', import.meta.url));

export function serveLanguage(input, output, _compiler)
{
  return new Promise((resolve, reject) =>
  {
    const child = spawn(process.execPath, [cli, 'lsp', '--stdio'], {
      env: {...process.env, NODE_NO_WARNINGS: '1'},
      stdio: ['pipe', 'pipe', 'inherit'],
    });
    child.on('error', reject);
    child.stdout.on('data', chunk => output.write(chunk));
    // The legacy server finished when its input ended; the exit status
    // (1 without an exit notification) is the protocol's, not the test's.
    child.on('close', () =>
    {
      output.end();
      resolve();
    });
    input.pipe(child.stdin);
  });
}
