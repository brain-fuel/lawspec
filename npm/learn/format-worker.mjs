// Formatting is trusted tooling; it never executes learner source.
// ref:DEC-learn-format-before-run ref:DEC-google-style-allman
import * as prettier from './vendor/prettier/standalone.mjs';
import * as babel from './vendor/prettier/babel.mjs';
import * as estree from './vendor/prettier/estree.mjs';
import * as typescript from './vendor/prettier/typescript.mjs';
import braceStyle from './vendor/prettier/brace-style.mjs';
import {formatWeb} from './web-format.mjs';
let core;
let fantomas;
const style = fetch(new URL('./style-options.json', import.meta.url)).then(
  response =>
  {
    if (!response.ok)
    {
      throw new Error('Missing packaged style options');
    }
    return response.json();
  },
);
async function formatFSharp(source)
{
  fantomas ??= new Promise((resolve, reject) =>
  {
    const worker = new Worker(
      new URL('./fantomas-worker.mjs', import.meta.url),
      {type: 'module'},
    );
    const ready = ({data}) =>
    {
      if (data.ready)
      {
        worker.removeEventListener('message', ready);
        worker.removeEventListener('error', failed);
        resolve(worker);
      }
    };
    const failed = event => reject(new Error(event.message));
    worker.addEventListener('message', ready);
    worker.addEventListener('error', failed, {once: true});
  });
  const worker = await fantomas;
  return new Promise((resolve, reject) =>
  {
    const clean = () =>
    {
      worker.removeEventListener('message', received);
      worker.removeEventListener('error', failed);
    };
    const received = ({data}) =>
    {
      clean();
      data.error ? reject(new Error(data.error)) : resolve(data.source);
    };
    const failed = event =>
    {
      clean();
      reject(new Error(event.message));
    };
    worker.addEventListener('message', received);
    worker.addEventListener('error', failed);
    worker.postMessage({id: 1, source});
  });
}
self.onmessage = async ({data}) =>
{
  const files = {...data.files};
  const diagnostics = [];
  try
  {
    postMessage({
      id: data.id,
      progress: 'Formatting LawSpec files on this device…',
    });
    core ??= import('./lawspec-core.mjs').then(({createCompiler}) =>
      createCompiler(),
    );
    const sources = Object.entries(files)
      .filter(([path]) => path.endsWith('.lawspec'))
      .map(([path, content]) => ({path, content}));
    const lawspec = await (
      await core
    ).format({
      languageProfile: '1.0-rc.2',
      compile: false,
      sources,
    });
    diagnostics.push(...(lawspec.diagnostics ?? []));
    if (lawspec.formattedSources)
    {
      for (const source of lawspec.formattedSources)
      {
        files[source.path] = source.content;
      }
    }
    for (const [path, content] of Object.entries(files))
    {
      if (path.endsWith('.lawspec'))
      {
        continue;
      }
      try
      {
        postMessage({
          id: data.id,
          progress: 'Formatting ' + path + ' on this device…',
        });
        if (path.endsWith('.fs'))
        {
          files[path] = await formatFSharp(content);
        }
        else if (/\.[cm]?[jt]s$/.test(path))
        {
          files[path] = await formatWeb(content, path, {
            prettier,
            plugins: [babel, estree, typescript, braceStyle],
            style: await style,
          });
        }
        else
        {
          throw new Error('Unsupported lesson source: ' + path);
        }
      }
      catch (error)
      {
        diagnostics.push({
          code: 'LEARN_FORMAT_SYNTAX',
          severity: 'error',
          message: String(error.message ?? error),
          at: {
            file: path,
            line: error.loc?.start?.line ?? 1,
            column: (error.loc?.start?.column ?? 0) + 1,
          },
        });
      }
    }
    postMessage({
      id: data.id,
      result: diagnostics.length ? {diagnostics} : {files, diagnostics},
    });
  }
  catch (error)
  {
    postMessage({id: data.id, error: String(error.message ?? error)});
  }
};
