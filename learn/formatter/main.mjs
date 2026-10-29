// This entry point is used only by build-time formatter probes.
import {dotnet} from './_framework/dotnet.js';
const runtime = await dotnet.create();
const exports = await runtime.getAssemblyExports(
  runtime.getConfig().mainAssemblyName,
);
globalThis.lawspecFormatter = exports.LawSpec.Learn.Formatter;
