import {createApplication} from './assets/node.mjs';
import {formatResponse} from './assets/public-codecs.mjs';

/** Loads the real Haskell formatter and preserves the existing formatting result shape. */
export async function createFormatter(options = {})
{
  const host = await createApplication(options);
  const format = async (input, controls) =>
  {
    const response = await host.format(
      {sources: input.sources, compile: input.compile},
      controls,
    );
    return formatResponse(response);
  };
  return Object.freeze({
    identity: host.identity,
    format,
    async formatFiles(provider, paths, {write, compile, signal} = {})
    {
      const response = await host.formatFiles(
        {provider, paths, write, compile},
        {signal},
      );
      return formatResponse(response);
    },
    close: host.close,
    revoke: host.revoke,
  });
}
