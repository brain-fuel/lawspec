// Repository formatting: owner Allman override, then Google, then language defaults.
// ref:DEC-google-style-allman
import {readFile, writeFile, readdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {createRequire} from 'node:module';
const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(
  here,
  path.basename(path.dirname(here)) === 'templates' ? '../..' : '..',
);
const {formatWeb} = await import(
  pathToFileURL(path.join(root, 'learn/browser/web-format.mjs')).href
);
const require = createRequire(path.join(root, 'learn/package.json'));
const prettier = require('prettier');
const braceStyle = require('prettier-plugin-brace-style');

const style = JSON.parse(
  await readFile(path.join(root, '.prettierrc.json'), 'utf8'),
);
async function formatContent(file, source)
{
  if (/\.[cm]?[jt]s$/.test(file))
  {
    return formatWeb(source, file, {prettier, plugins: [braceStyle], style});
  }
  if (file.endsWith('.css'))
  {
    const formatted = await prettier.format(source, {
      ...style,
      parser: 'css',
      plugins: [braceStyle],
    });
    return formatted;
  }
  if (file.endsWith('.html'))
  {
    return prettier.format(source, {
      ...style,
      parser: 'html',
      plugins: [braceStyle],
    });
  }
  return source;
}
const args = process.argv.slice(2);
if (args[0] === '--render')
{
  let input = '';
  for await (const chunk of process.stdin)
  {
    input += chunk;
  }
  const formatted = [];
  for (const [file, source] of JSON.parse(input))
  {
    formatted.push([file, await formatContent(file, source)]);
  }
  process.stdout.write(JSON.stringify(formatted));
}
else
{
  const check = args.includes('--check');
  const paths = args.filter(value => !value.startsWith('--'));
  if (!paths.length)
  {
    throw new Error('Usage: code-style.mjs [--check] <source paths...>');
  }
  const files = [];
  async function walk(directory)
  {
    for (const entry of await readdir(directory, {withFileTypes: true}))
    {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory())
      {
        if (
          !['node_modules', 'vendor', 'archive', 'bin', 'obj'].includes(
            entry.name,
          )
        )
        {
          await walk(file);
        }
      }
      else if (/\.[cm]?[jt]s$|\.(css|html)$/.test(file))
      {
        files.push(file);
      }
    }
  }
  for (const file of paths)
  {
    const full = path.resolve(root, file);
    try
    {
      await walk(full);
    }
    catch (error)
    {
      if (error.code !== 'ENOTDIR')
      {
        throw error;
      }
      files.push(full);
    }
  }
  const changed = [];
  for (const file of files.sort())
  {
    const source = await readFile(file, 'utf8');
    // Named template holes are tokens, never JavaScript expressions. Protect
    // their spelling while parsing the surrounding real source with formatters.
    const holes = [];
    const protectedSource = source.replace(
      /\/\*@\s*([\w-]+)\s*@\*\/|@@[^@\n]+@@/g,
      original =>
      {
        const token =
          'LAWSPEC_TEMPLATE_HOLE_' +
          String(holes.length).padStart(8, '0') +
          '_';
        holes.push([token, original]);
        return token;
      },
    );
    let formatted = await formatContent(file, protectedSource);
    for (const [token, original] of holes)
    {
      formatted = formatted.replaceAll(token, original);
    }
    if (formatted !== source)
    {
      changed.push(path.relative(root, file));
      if (!check)
      {
        await writeFile(file, formatted);
      }
    }
  }
  if (changed.length)
  {
    console.log(
      (check ? 'Needs formatting:\n' : 'Formatted:\n') + changed.join('\n'),
    );
  }
  if (check && changed.length)
  {
    process.exitCode = 1;
  }
}
