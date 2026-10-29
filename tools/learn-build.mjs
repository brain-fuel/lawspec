// Generated from templates/tools/learn-build.mjs by lawspec-dev generate. Do not edit.
// Package pinned runtime dependencies locally. No CDN or source-upload service.
// ref:DEC-learn-course-preview
import {
  readFile,
  writeFile,
  cp,
  mkdir,
  readdir,
  rm,
  mkdtemp,
  rename,
} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(path.join(root, 'learn/package.json'));
const {build} = require('esbuild');
const liveOutput = path.join(root, 'npm/learn/vendor');
await mkdir(path.dirname(liveOutput), {recursive: true});
const output = await mkdtemp(
  path.join(path.dirname(liveOutput), '.vendor-build-'),
);
try
{
  const modulePath = name => path.join(root, 'learn/node_modules', name);
  await cp(
    modulePath('@fable-org/fable-standalone/dist/bundle.min.js'),
    path.join(output, 'fable.js'),
  );
  await cp(
    modulePath('@fable-org/fable-library-js'),
    path.join(output, 'fable-library'),
    {recursive: true},
  );
  await cp(
    modulePath('@fable-org/fable-metadata/lib'),
    path.join(output, 'metadata'),
    {recursive: true},
  );
  const assemblies = (await readdir(path.join(output, 'metadata')))
    .filter(name => name.endsWith('.dll'))
    .sort();
  await writeFile(
    path.join(output, 'assemblies.json'),
    JSON.stringify(assemblies),
  );
  await cp(
    modulePath('esbuild-wasm/esbuild.wasm'),
    path.join(output, 'esbuild.wasm'),
  );
  // Fantomas runs locally on .NET WebAssembly; no formatting service receives code.
  execFileSync(
    'dotnet',
    [
      'publish',
      path.join(root, 'learn/formatter/LawSpec.Learn.Formatter.csproj'),
      '-c',
      'Release',
      '--nologo',
      '-p:RestoreLockedMode=true',
    ],
    {stdio: 'pipe', cwd: path.join(root, 'learn/formatter')},
  );
  await cp(
    path.join(
      root,
      'learn/formatter/bin/Release/net10.0/publish/wwwroot/_framework',
    ),
    path.join(output, 'fantomas'),
    {
      recursive: true,
      filter: file =>
        !file.endsWith('.gz') &&
        !file.endsWith('.br') &&
        !file.endsWith('.pdb'),
    },
  );
  await mkdir(path.join(output, 'prettier'), {recursive: true});
  await build({
    entryPoints: [modulePath('prettier-plugin-brace-style/dist/index.js')],
    bundle: true,
    format: 'esm',
    platform: 'browser',
    outfile: path.join(output, 'prettier/brace-style.mjs'),
    minify: true,
    plugins: [
      {
        name: 'prettier-browser',
        setup(builder)
        {
          builder.onResolve({filter: /^prettier$/}, () => ({
            path: path.join(root, 'learn/formatting/prettier-browser.mjs'),
          }));
        },
      },
    ],
  });

  await cp(
    modulePath('prettier/standalone.mjs'),
    path.join(output, 'prettier/standalone.mjs'),
  );
  for (const name of ['babel', 'estree', 'typescript'])
  {
    await cp(
      modulePath('prettier/plugins/' + name + '.mjs'),
      path.join(output, 'prettier/' + name + '.mjs'),
    );
  }
  const libraries = {};
  for (const name of (await readdir(modulePath('typescript/lib'))).sort())
  {
    if (name.startsWith('lib.') && name.endsWith('.d.ts'))
    {
      libraries[name] = await readFile(
        modulePath('typescript/lib/' + name),
        'utf8',
      );
    }
  }
  await writeFile(
    path.join(output, 'typescript-libs.json'),
    JSON.stringify(libraries),
  );
  await build({
    entryPoints: [modulePath('esbuild-wasm/esm/browser.js')],
    bundle: true,
    format: 'esm',
    platform: 'browser',
    outfile: path.join(output, 'esbuild.mjs'),
  });
  for (const [entry, name] of [
    ['typescript', 'typescript'],
    ['fast-check', 'fast-check'],
  ])
  {
    await build({
      stdin: {
        contents: `import value from ${JSON.stringify(entry)};export default value;export * from ${JSON.stringify(entry)};`,
        resolveDir: path.join(root, 'learn'),
      },
      bundle: true,
      format: 'esm',
      platform: 'browser',
      outfile: path.join(output, name + '.mjs'),
      minify: true,
    });
  }
  const grammar = JSON.parse(
    await readFile(
      path.join(root, 'editors/vscode/syntaxes/lawspec.tmLanguage.json'),
      'utf8',
    ),
  );
  const patterns = grammar.patterns
    .filter(row => row.match && /^(keyword|support\.type)/.test(row.name ?? ''))
    .map(row => [
      row.match,
      row.name.startsWith('support') ? 'type' : 'keyword',
    ]);
  // Captured declaration patterns also carry keywords; include their word groups.
  for (const row of grammar.patterns)
  {
    if (
      row.match &&
      Object.values(row.captures ?? {}).some(value =>
        value.name.startsWith('keyword'),
      )
    )
    {
      patterns.push([row.match, 'keyword']);
    }
  }
  await build({
    define: {__LAWSPEC_RULES__: JSON.stringify(patterns)},
    entryPoints: [path.join(root, 'learn/browser/editor.mjs')],
    bundle: true,
    format: 'esm',
    platform: 'browser',
    outfile: path.join(output, 'editor.mjs'),
    loader: {'.ttf': 'file'},
    minify: true,
  });
  await build({
    entryPoints: [modulePath('monaco-editor/esm/vs/editor/editor.worker.js')],
    bundle: true,
    format: 'iife',
    platform: 'browser',
    outfile: path.join(output, 'editor-worker.js'),
    minify: true,
  });
  // Requested typefaces are packaged assets, including their open-font licenses.
  await mkdir(path.join(output, 'fonts'), {recursive: true});
  for (const [name, weights] of [
    ['overpass', [600, 700]],
    ['atkinson-hyperlegible', [400, 700]],
    ['atkinson-hyperlegible-mono', [400]],
  ])
  {
    for (const weight of weights)
    {
      const file = `${name}-latin-${weight}-normal.woff2`;
      await cp(
        modulePath(`@fontsource/${name}/files/${file}`),
        path.join(output, 'fonts', file),
      );
    }
  }
  const packages = [
    '@fontsource/overpass',
    '@fontsource/atkinson-hyperlegible',
    '@fontsource/atkinson-hyperlegible-mono',
    '@fable-org/fable-standalone',
    '@fable-org/fable-metadata',
    '@fable-org/fable-library-js',
    'typescript',
    'fast-check',
    'monaco-editor',
    'esbuild-wasm',
    'prettier',
    'prettier-plugin-brace-style',
    'zod',
  ];
  const versions = {};
  for (const name of packages)
  {
    const pkg = JSON.parse(
      await readFile(modulePath(name + '/package.json'), 'utf8'),
    );
    versions[name] = pkg.version;
    const license = (await readdir(modulePath(name)))
      .sort()
      .find(file => /^licen[sc]e(\.|$)/i.test(file));
    if (license)
    {
      await cp(
        modulePath(name + '/' + license),
        path.join(output, name.replaceAll('/', '-') + '-LICENSE.txt'),
      );
    }
  }
  await cp(
    path.join(root, 'learn/formatter/licenses'),
    path.join(output, 'formatter-licenses'),
    {recursive: true},
  );
  versions['Fantomas.Core'] = '8.1.0';
  versions['Microsoft.NETCore.App.Runtime.Mono.browser-wasm'] = '10.0.12';
  const manifest = {versions, fable: '5.21.0', assets: {}};
  async function inventory(directory, prefix = '')
  {
    for (const item of (await readdir(directory, {withFileTypes: true})).sort(
      (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0),
    ))
    {
      const name = prefix + item.name;
      if (item.isDirectory())
      {
        await inventory(path.join(directory, item.name), name + '/');
      }
      else
      {
        const bytes = await readFile(path.join(directory, item.name));
        manifest.assets[name] = {
          bytes: bytes.length,
          sha256: createHash('sha256').update(bytes).digest('hex'),
        };
      }
    }
  }
  await inventory(output);
  await writeFile(
    path.join(output, 'manifest.json'),
    JSON.stringify(manifest, null, 2) + '\n',
  );
  // Prepare the complete tree before replacing individual assets atomically. A
  // live lesson must never lose its libraries during a local rebuild.
  await mkdir(liveOutput, {recursive: true});
  const previous = [];
  async function existing(directory, prefix = '')
  {
    for (const item of await readdir(directory, {withFileTypes: true}))
    {
      const name = prefix + item.name;
      if (item.isDirectory())
      {
        await existing(path.join(directory, item.name), name + '/');
      }
      else
      {
        previous.push(name);
      }
    }
  }
  await existing(liveOutput);
  for (const name of [...Object.keys(manifest.assets), 'manifest.json'])
  {
    const destination = path.join(liveOutput, name);
    await mkdir(path.dirname(destination), {recursive: true});
    await rename(path.join(output, name), destination);
  }
  for (const name of previous)
  {
    if (name !== 'manifest.json' && !Object.hasOwn(manifest.assets, name))
    {
      await rm(path.join(liveOutput, name), {force: true});
    }
  }
  console.log(
    `Packaged ${Object.keys(manifest.assets).length} local assets (${Object.values(manifest.assets).reduce((n, row) => n + row.bytes, 0)} bytes).`,
  );
  // The distributed tutor uses the same curriculum, never a separately authored
  // lesson transcript. The directory is a portable versioned Codex plugin.
  const plugin = path.join(root, 'plugins/lawspec');
  await mkdir(path.join(plugin, '.codex-plugin'), {recursive: true});
  await cp(
    path.join(root, 'learn/plugin.json'),
    path.join(plugin, '.codex-plugin/plugin.json'),
  );
  await mkdir(path.join(root, 'learn/skills/lawspec-learn/references'), {
    recursive: true,
  });
  await cp(
    path.join(root, 'learn/curriculum.json'),
    path.join(root, 'learn/skills/lawspec-learn/references/curriculum.json'),
  );
  await cp(
    path.join(root, 'learn/skills/lawspec-learn'),
    path.join(root, '.agents/skills/lawspec-learn'),
    {recursive: true},
  );
  await mkdir(path.join(root, '.agents/skills/lawspec-learn/references'), {
    recursive: true,
  });
  await cp(
    path.join(root, 'learn/curriculum.json'),
    path.join(root, '.agents/skills/lawspec-learn/references/curriculum.json'),
  );
  for (const skill of ['lawspec-learn'])
  {
    await cp(
      path.join(root, '.agents/skills', skill),
      path.join(plugin, 'skills', skill),
      {recursive: true},
    );
  }
  // A separate opaque document avoids inheriting the application's CSP. Only
  // this exact bootstrap and blob worker code may execute in the sandbox.
  const {frameMain} = await import('../learn/browser/sandbox.mjs');
  const bootstrap = `(${frameMain.toString()})()`;
  const hash = createHash('sha256').update(bootstrap).digest('base64');
  await writeFile(
    path.join(root, 'npm/learn/sandbox-frame.html'),
    `<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; connect-src 'none'; script-src 'sha256-${hash}' blob:; worker-src blob:"><title>Isolated execution</title><script>${bootstrap}</script>`,
  );
}
finally
{
  await rm(output, {force: true, recursive: true});
}
