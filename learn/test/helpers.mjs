import {packagedReader} from '../browser/assets.mjs';
import {browserRuntime} from '../browser/browser-runtime.mjs';
import {readFile, readdir} from 'node:fs/promises';
import {Worker} from 'node:worker_threads';
import * as esbuild from 'esbuild';
import ts from 'typescript';
import {createFsharp} from '../browser/fsharp.mjs';
import {checkTypes} from '../browser/typescript.mjs';
import {createCompiler} from '../../npm/api.mjs';
import {compileProject} from '../browser/compiler.mjs';
/** Share the authoritative exercise projects with execution checks. ref:REQ-learn-local-execution */
export const course = JSON.parse(
  await readFile(new URL('../curriculum.json', import.meta.url)),
);
/** Reuse the standalone Fable checker between focused cases. ref:REQ-learn-local-execution */
let fs;
/** Reuse the WASM compiler without changing its verification selection. ref:REQ-learn-local-execution */
let core;
/** Compile actual F# projects against pinned metadata for the focused suite. ref:REQ-learn-local-execution */
async function fsharp(files)
{
  fs ??= (async () =>
  {
    await import('@fable-org/fable-standalone');
    const dir = new URL(
      '../node_modules/@fable-org/fable-metadata/lib/',
      import.meta.url,
    );
    const names = (await readdir(dir))
      .filter(name => name.endsWith('.dll'))
      .sort();
    const assemblies = Object.fromEntries(
      await Promise.all(
        names.map(async name => [
          name,
          new Uint8Array(await readFile(new URL(name, dir))),
        ]),
      ),
    );
    return createFsharp(globalThis.__FABLE_STANDALONE__, assemblies);
  })();
  return (await fs)(files);
}
/** Keep test services equivalent to the browser compilation worker. ref:REQ-learn-local-execution */
export const services = {
  /** Use esbuild's actual module resolver instead of rewriting imports. ref:REQ-learn-local-execution */
  esbuild,
  /** Exercise Fable's type checker and printer on the authored project. ref:REQ-learn-local-execution */
  fsharp,
  /** Apply the same explicit browser network-loader boundary. ref:REQ-learn-local-execution */
  browserRuntime: source => browserRuntime(ts, source),
  /** Retain mandatory admission in the actual WASM compiler. ref:REQ-learn-local-execution */
  lawspec: async () => (core ??= await createCompiler()),
  /** Restrict library reads to packaged assets before touching the filesystem. ref:REQ-learn-local-execution */
  readAsset: packagedReader(
    JSON.parse(
      await readFile(
        new URL('../../npm/learn/vendor/manifest.json', import.meta.url),
      ),
    ),
    async name =>
      readFile(
        new URL(
          name === 'assert.mjs'
            ? '../../npm/learn/assert.mjs'
            : '../../npm/learn/vendor/' + name,
          import.meta.url,
        ),
        'utf8',
      ),
  ),
  /** Check TypeScript semantics against the same libraries shipped to the browser. ref:REQ-learn-local-execution */
  typescript: async files =>
  {
    const libraries = JSON.parse(
      await readFile(
        new URL('../../npm/learn/vendor/typescript-libs.json', import.meta.url),
      ),
    );
    return checkTypes(ts, files, libraries);
  },
};
/** Compile a selected lesson and explicit overrides without replacing its real harness. ref:REQ-learn-local-execution */
export async function compile(
  lesson,
  language = 'fsharp',
  overrides = {},
  mode = 'all',
  path = '',
  replayTest = null,
)
{
  return compileProject(
    {
      lesson,
      language,
      files: {...lesson.projects[language], ...overrides},
      mode,
      seed: 424242,
      path,
      replayTest,
    },
    services,
  );
}
/** Run bundles in a disposable worker so timeouts and errors cannot appear as passing evidence. ref:REQ-learn-local-execution */
export function execute(code, timeout = 30000)
{
  return new Promise((resolve, reject) =>
  {
    const worker = new Worker(
      `const {parentPort,workerData}=require('node:worker_threads');const vm=require('node:vm');
const context=vm.createContext({setTimeout,clearTimeout,TextEncoder,TextDecoder,URL,crypto:globalThis.crypto,performance,console,postMessage:value=>parentPort.postMessage(value)});
try{vm.runInContext(workerData,context,{timeout:20000});}catch(error){parentPort.postMessage({error:error.stack});}`,
      {eval: true, execArgv: [], workerData: code},
    );
    const timer = setTimeout(() =>
    {
      worker.terminate();
      reject(new Error('Execution timed out'));
    }, timeout);
    worker.once('message', data =>
    {
      clearTimeout(timer);
      worker.terminate();
      data.error ? reject(new Error(data.error)) : resolve(data.result);
    });
    worker.once('error', error =>
    {
      clearTimeout(timer);
      worker.terminate();
      reject(error);
    });
  });
}
