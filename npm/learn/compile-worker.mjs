import {packagedReader} from './assets.mjs';
import {browserRuntime} from './browser-runtime.mjs';
import * as esbuild from './vendor/esbuild.mjs';
import ts from './vendor/typescript.mjs';
import './vendor/fable.js';
import {createFsharp} from './fsharp.mjs';
import {compileProject} from './compiler.mjs';
import {checkTypes} from './typescript.mjs';
let initialized, fs, core, libs;
let assetReader;
const readAsset = async path =>
{
  assetReader ??= fetch(new URL('./vendor/manifest.json', import.meta.url))
    .then(response =>
    {
      if (!response.ok)
      {
        throw new Error('Missing packaged manifest');
      }
      return response.json();
    })
    .then(manifest =>
      packagedReader(manifest, async name =>
      {
        const response = await fetch(
          new URL(
            name === 'assert.mjs' ? name : 'vendor/' + name,
            import.meta.url,
          ),
        );
        if (!response.ok)
        {
          throw new Error('Missing packaged asset: ' + name);
        }
        return response.text();
      }),
    );
  return (await assetReader)(path);
};
async function fsharp(files)
{
  fs ??= (async () =>
  {
    const names = await (
      await fetch(new URL('./vendor/assemblies.json', import.meta.url))
    ).json();
    const assemblies = Object.fromEntries(
      await Promise.all(
        names.map(async name =>
        {
          const response = await fetch(
            new URL('./vendor/metadata/' + name, import.meta.url),
          );
          if (!response.ok)
          {
            throw new Error('Missing F# metadata: ' + name);
          }
          return [name, new Uint8Array(await response.arrayBuffer())];
        }),
      ),
    );
    return createFsharp(globalThis.__FABLE_STANDALONE__, assemblies);
  })();
  return (await fs)(files);
}
async function typescript(files)
{
  libs ??= fetch(
    new URL('./vendor/typescript-libs.json', import.meta.url),
  ).then(response => response.json());
  return checkTypes(ts, files, await libs);
}
self.onmessage = async ({data}) =>
{
  try
  {
    initialized ??= esbuild.initialize({
      wasmURL: new URL('./vendor/esbuild.wasm', import.meta.url).href,
      worker: false,
    });
    await initialized;
    const result = await compileProject(data, {
      esbuild,
      readAsset,
      fsharp,
      typescript,
      browserRuntime: source => browserRuntime(ts, source),
      lawspec: async () =>
      {
        core ??= import('./lawspec-core.mjs').then(({createCompiler}) =>
          createCompiler(),
        );
        return core;
      },
    });
    postMessage({id: data.id, result});
  }
  catch (error)
  {
    postMessage({
      id: data.id,
      error: String(error?.message ?? error),
      diagnostics: error.errors,
    });
  }
};
