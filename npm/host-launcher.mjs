// Generated from templates/npm/host-launcher.mjs by lawspec-dev generate. Do not edit.
// Component transport for the existing compiler API. No automatic legacy fallback.
// ref:DEC-host-sdk-independent-consumer
import {mkdir} from 'node:fs/promises';
import {preludeQuery, preludeResponse} from './host-codecs.mjs';
import {createHash} from 'node:crypto';
import path from 'node:path';
export async function loadCore(options = {})
{
  const compilation = options.compilation ?? 'precompiled';
  if (compilation !== 'precompiled')
    throw new Error(
      'Runtime compilation is unavailable; run WASM_PLATFORM_KIT_BUILD_FROM_SOURCE=1 npm rebuild lawspec',
    );
  let createApplication;
  try
  {
    ({createApplication} = await import('./host-component/node.mjs'));
  }
  catch (cause)
  {
    if (
      cause.code !== 'ERR_MODULE_NOT_FOUND' ||
      !cause.message.includes("'wasm-platform-kit'")
    )
      throw cause;
    const error = new Error(
      'The component runtime requires the separately installed wasm-platform-kit package.',
      {cause},
    );
    error.code = 'unsupported';
    throw error;
  }
  let activeRoot, host, namespace;
  let queue = Promise.resolve();
  const run = async input =>
  {
    const validCache = typeof input.cacheDirectory === 'string';
    let root =
      validCache && input.cacheDirectory
        ? path.resolve(input.cacheDirectory)
        : undefined;
    if (root)
      try
      {
        await mkdir(root, {recursive: true});
      }
      catch
      {
        root = undefined;
      }
    if (!host || root !== activeRoot)
    {
      host?.close();
      host = undefined;
      host = await createApplication({
        keepAlive: false,
        compilation,
        limits: {
          memory: 1024 * 1024 * 1024,
          bytes: 64 * 1024 * 1024,
          timeout: 120000,
          fuel: 100000000000,
        },
        grants: root
          ? {'compiler-cache': {kind: 'files', root, read: true, write: true}}
          : {},
      });
      activeRoot = root;
      const {
        artifact,
        runtime,
        provider,
        policy,
        nativeArtifact,
        configuration,
        target,
      } = host.identity;
      namespace = createHash('sha256')
        .update(
          JSON.stringify({
            artifact,
            runtime,
            provider,
            policy,
            nativeArtifact,
            configuration,
            target,
            compilation,
          }),
        )
        .digest('hex');
    }
    const request = {
      ...input,
      ...(validCache ? {cacheDirectory: root ? namespace : undefined} : {}),
    };
    try
    {
      if (request.method === 'prelude')
        return preludeResponse(await host.prelude(preludeQuery(request)));
      return JSON.parse(await host.dispatch(JSON.stringify(request)));
    }
    catch (error)
    {
      host.close();
      host = undefined;
      throw error;
    }
  };
  return input =>
  {
    const result = queue.then(() => run(input));
    queue = result.then(
      () =>
      {},
      () =>
      {},
    );
    return result;
  };
}
