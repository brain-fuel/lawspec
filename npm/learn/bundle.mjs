// Resolve virtual modules through esbuild's parser, including cycles and re-exports.
/** Link virtual lesson files with esbuild, keeping parsing and module resolution separate from learner execution. ref:DEC-learn-course-preview */
export async function bundle(esbuild, modules, entry, readLibrary)
{
  const normalize = path =>
  {
    const parts = [];
    for (const part of path.split('/'))
    {
      if (part === '..')
      {
        if (!parts.length)
        {
          throw new Error('Module escapes workspace');
        }
        parts.pop();
      }
      else if (part && part !== '.')
      {
        parts.push(part);
      }
    }
    return parts.join('/');
  };
  const result = await esbuild.build({
    entryPoints: [entry],
    bundle: true,
    write: false,
    format: 'iife',
    platform: 'browser',
    target: 'es2022',
    logLevel: 'silent',
    plugins: [
      {
        name: 'lesson-files',
        setup(build)
        {
          build.onResolve({filter: /.*/}, args =>
          {
            const special = {
              'node:test': 'node-test.mjs',
              'node:assert/strict': 'assert.mjs',
              'fast-check': 'fast-check.mjs',
            };
            let name = special[args.path] ?? args.path;
            if (name.startsWith('.'))
            {
              name = normalize(
                args.importer.split('/').slice(0, -1).join('/') + '/' + name,
              );
            }
            if (
              ['node:fs', 'node:path', 'node:async_hooks'].includes(name) &&
              args.importer !== 'test/lawspec_harness.mjs'
            )
            {
              throw new Error(
                'Unsupported native import outside the generated harness: ' +
                  name,
              );
            }
            if (Object.hasOwn(modules, name))
            {
              return {path: name, namespace: 'lesson'};
            }
            if (name.startsWith('fable-library/'))
            {
              return {path: name.slice(14), namespace: 'fable'};
            }
            if (args.namespace === 'fable' && args.path.startsWith('.'))
            {
              return {
                path: normalize(
                  args.importer.split('/').slice(0, -1).join('/') +
                    '/' +
                    args.path,
                ),
                namespace: 'fable',
              };
            }
            if (name === 'fast-check-original')
            {
              return {path: 'fast-check.mjs', namespace: 'vendor'};
            }
            if (
              [
                'node:http',
                'node:net',
                'browser:unsupported-secure-network',
              ].includes(name)
            )
            {
              return {path: name, namespace: 'unsupported'};
            }
            throw new Error('Unsupported import: ' + args.path);
          });
          build.onLoad({filter: /.*/, namespace: 'lesson'}, args => ({
            contents: modules[args.path],
            loader: args.path.endsWith('.ts') ? 'ts' : 'js',
          }));
          build.onLoad({filter: /.*/, namespace: 'fable'}, async args => ({
            contents: await readLibrary('fable-library/' + args.path),
            loader: 'js',
          }));
          build.onLoad({filter: /.*/, namespace: 'vendor'}, async args => ({
            contents: await readLibrary(args.path),
            loader: 'js',
          }));
          build.onLoad({filter: /.*/, namespace: 'unsupported'}, args => ({
            contents: `throw new Error(${JSON.stringify('unsupported: ' + args.path + ' is unavailable in browser lessons')});`,
            loader: 'js',
          }));
        },
      },
    ],
  });
  return result.outputFiles[0].text;
}
