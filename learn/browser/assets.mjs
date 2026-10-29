// Untrusted imports may request only known packaged asset names. In particular,
// source text cannot become a query string, URL, or path sent to the asset host.
/** Allow only fixed packaged asset names so an untrusted import cannot submit source text through a URL or filesystem path. ref:DEC-learn-course-preview */
export function packagedReader(manifest, read)
{
  const allowed = new Set([...Object.keys(manifest.assets), 'assert.mjs']);
  return async name =>
  {
    if (!allowed.has(name))
    {
      throw new Error('Unsupported packaged import: ' + name);
    }
    return read(name);
  };
}
