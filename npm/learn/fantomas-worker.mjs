// Keep the .NET runtime in its own worker and initialize it before accepting work.
// This worker formats source; learner F# execution remains Fable/JavaScript.
// ref:DEC-learn-format-before-run
import {dotnet} from './vendor/fantomas/dotnet.js';
const runtime = await dotnet.create();
const exports = await runtime.getAssemblyExports(
  runtime.getConfig().mainAssemblyName,
);
const formatter = exports.LawSpec.Learn.Formatter;
self.addEventListener('message', async ({data}) =>
{
  try
  {
    postMessage({
      id: data.id,
      source: await formatter.FormatFSharp(data.source),
    });
  }
  catch (error)
  {
    postMessage({id: data.id, error: String(error.message ?? error)});
  }
});

postMessage({ready: true});
