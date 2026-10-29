// Generated from templates/npm/learn.mjs by lawspec-dev generate. Do not edit.
import {createServer} from 'node:http';
import {readFile, realpath, stat, cp, mkdir, copyFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {gzipSync} from 'node:zlib';

let compressed;
async function packagedAssets()
{
  try
  {
    await readFile(new URL('./learn/vendor/manifest.json', import.meta.url));
    await readFile(new URL('./learn/sandbox-frame.html', import.meta.url));
  }
  catch
  {
    throw new Error(
      'Learn assets are missing. In a compiler checkout run npm ci --prefix learn, make generate, and npm run build --prefix learn.',
    );
  }
}
async function compilerBytes()
{
  return (compressed ??= gzipSync(
    await readFile(fileURLToPath(new URL('./core.wasm', import.meta.url))),
    {level: 9},
  ));
}

export async function packageLearn(destination)
{
  await packagedAssets();
  await mkdir(destination, {recursive: true});
  await cp(fileURLToPath(new URL('./learn/', import.meta.url)), destination, {
    recursive: true,
  });
  await copyFile(
    fileURLToPath(new URL('./core_jsffi.js', import.meta.url)),
    path.join(destination, 'core_jsffi.js'),
  );
  const {writeFile} = await import('node:fs/promises');
  await writeFile(
    path.join(destination, 'core.wasm.gz'),
    await compilerBytes(),
  );
}

export async function serveLearn(port = '8384', {quiet = false} = {})
{
  await packagedAssets();
  if (!/^\d+$/.test(String(port)) || Number(port) < 0 || Number(port) > 65535)
    throw new Error(
      '--port must be an integer from 1 to 65535 (0 selects an available port)',
    );
  const root = await realpath(
    fileURLToPath(new URL('./learn/', import.meta.url)),
  );
  const types = {
    '.html': 'text/html; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.wasm': 'application/wasm',
    '.woff2': 'font/woff2',
  };
  const server = createServer(async (request, response) =>
  {
    try
    {
      if (!['GET', 'HEAD'].includes(request.method))
      {
        response.writeHead(405);
        response.end();
        return;
      }
      const pathname = decodeURIComponent(
        new URL(request.url, 'http://localhost').pathname,
      );
      if (pathname === '/core.wasm.gz')
      {
        response.writeHead(200, {
          'Content-Type': 'application/gzip',
          'Cache-Control': 'no-cache',
        });
        response.end(
          request.method === 'HEAD' ? undefined : await compilerBytes(),
        );
        return;
      }
      const compilerAsset = pathname === '/core_jsffi.js';
      const file = await realpath(
        compilerAsset
          ? fileURLToPath(new URL('.' + pathname, import.meta.url))
          : path.join(root, pathname === '/' ? 'index.html' : pathname),
      );
      if (
        (!compilerAsset && !file.startsWith(root + path.sep)) ||
        !(await stat(file)).isFile()
      )
        throw new Error('not found');
      response.writeHead(200, {
        'Content-Type': types[path.extname(file)] ?? 'application/octet-stream',
        'X-Content-Type-Options': 'nosniff',
        'Cache-Control': 'no-cache',
      });
      response.end(
        request.method === 'HEAD' ? undefined : await readFile(file),
      );
    }
    catch
    {
      response.writeHead(404);
      response.end('Not found');
    }
  });
  await new Promise((resolve, reject) =>
  {
    server.once('error', reject);
    server.listen(Number(port), '127.0.0.1', resolve);
  });
  if (!quiet)
    console.log(`Learn LawSpec: http://127.0.0.1:${server.address().port}/`);
  return server;
}
