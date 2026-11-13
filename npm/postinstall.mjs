// Generated from templates/npm/postinstall.mjs by lawspec-dev generate. Do not edit.
// Prepares the optional native component runtime after installation. The CLI
// compiles with the WebAssembly core and never needs that runtime, so a
// missing part is at most a note and never a failed installation. A runtime
// that is present and fails its own preparation still fails.
import {existsSync} from 'node:fs';
import {createRequire} from 'node:module';
const install = new URL('./host-component/install.mjs', import.meta.url);
function resolved(require, request)
{
  try
  {
    return require.resolve(request);
  }
  catch (error)
  {
    if (error.code !== 'MODULE_NOT_FOUND')
    {
      throw error;
    }
    return undefined;
  }
}
// Why the runtime cannot be prepared here, or undefined when it can.
function unavailable()
{
  const kit = resolved(
    createRequire(import.meta.url),
    'wasm-platform-kit/package.json',
  );
  if (!kit)
  {
    return 'wasm-platform-kit is not installed';
  }
  const platform = `${process.platform}-${process.arch}`;
  if (
    !resolved(
      createRequire(kit),
      `wasm-platform-kit-${platform}/bin/host-sdk-runtime`,
    )
  )
  {
    return `wasm-platform-kit has no installed package for ${platform}`;
  }
  if (
    process.platform === 'linux' &&
    !process.report.getReport().header.glibcVersionRuntime
  )
  {
    return 'wasm-platform-kit needs glibc on Linux';
  }
  return undefined;
}
// A git checkout has no host-component directory: nothing to prepare.
if (existsSync(install))
{
  const reason = unavailable();
  if (reason)
  {
    console.log(
      `lawspec: the optional native component runtime is unavailable (${reason}). The CLI does not need it.`,
    );
  }
  else
  {
    await import(install.href);
  }
}
