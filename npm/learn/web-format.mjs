// Google's gts settings are shared by repository and on-device formatting.
// The pinned brace-style plugin provides the owner's Allman override.
// ref:DEC-google-style-allman
export async function formatWeb(source, path, {prettier, plugins, style})
{
  const parser = /\.[cm]?tsx?$/.test(path) ? 'typescript' : 'babel';
  return prettier.format(source, {...style, parser, plugins});
}
