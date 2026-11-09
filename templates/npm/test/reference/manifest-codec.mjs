import {toEDNString} from 'edn-data';
import {EDNListParser} from 'edn-data/dist/parse.js';
// Frozen codec reference from a91b22f0. Test-only; never import from application code.
// ref:DEC-haskell-application-port
const camel = key =>
  key.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
const kebab = key =>
  key.replace(/[A-Z]/g, letter => '-' + letter.toLowerCase());
const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
const fail = (message, file) =>
{
  const error = new Error(`${file ? file + ': ' : ''}${message}`);
  error.diagnostics = [
    {
      code: 'manifest',
      message,
      ...(file ? {at: {file, line: 1, column: 1}} : {}),
    },
  ];
  throw error;
};

export function parseManifest(text, file)
{
  let values, parser;
  try
  {
    parser = new EDNListParser();
    values = parser.next('(' + text + '\n)\n');
  }
  catch (error)
  {
    fail(`Invalid EDN: ${error.message}`, file);
  }
  if (!parser.isDone() || values.length !== 1 || !Array.isArray(values[0]?.map))
    fail('Expected exactly one complete EDN map', file);
  function convert(value)
  {
    if (
      value === null ||
      typeof value === 'string' ||
      typeof value === 'boolean'
    )
      return value;
    if (typeof value === 'number' && Number.isSafeInteger(value)) return value;
    if (Array.isArray(value)) return value.map(convert);
    if (value && typeof value === 'object' && own(value, 'key'))
      return value.key;
    if (value && typeof value === 'object' && own(value, 'map'))
    {
      const entries = [],
        seen = new Set();
      for (const [key, entry] of value.map)
      {
        if (typeof key !== 'string' && !(key && typeof key.key === 'string'))
          fail('Manifest map keys must be strings or keywords', file);
        const name = typeof key === 'string' ? key : camel(key.key);
        if (seen.has(name)) fail(`Duplicate manifest key: ${name}`, file);
        seen.add(name);
        entries.push([name, convert(entry)]);
      }
      return Object.fromEntries(entries);
    }
    fail(
      'Unsupported manifest EDN value; use maps, vectors, keywords, strings, integers, booleans or nil',
      file,
    );
  }
  return convert(values[0]);
}

export function writeManifest(value, options = {})
{
  if (options?.compact !== undefined && typeof options.compact !== 'boolean')
    throw new TypeError('compact must be a boolean');
  const identifiers = new Set(['language', 'layers']);
  function convert(value, parent)
  {
    if (Array.isArray(value)) return value.map(entry => convert(entry, parent));
    if (value && typeof value === 'object')
      return {
        map: Object.entries(value)
          .filter(([, entry]) => entry !== undefined)
          .map(([key, entry]) => [
            /^[a-z][A-Za-z0-9]*$/.test(key) ? {key: kebab(key)} : key,
            convert(entry, key),
          ]),
      };
    return typeof value === 'string' && identifiers.has(parent)
      ? {key: value}
      : value;
  }
  function layout(value, depth)
  {
    const indent = '  '.repeat(depth),
      child = indent + '  ';
    if (value && !Array.isArray(value) && value.map)
      return (
        '{\n' +
        value.map
          .map(
            ([key, entry]) =>
              child + toEDNString(key) + ' ' + layout(entry, depth + 1),
          )
          .join('\n') +
        '\n' +
        indent +
        '}'
      );
    if (
      Array.isArray(value) &&
      value.some(entry => entry && typeof entry === 'object')
    )
      return (
        '[\n' +
        value.map(entry => child + layout(entry, depth + 1)).join('\n') +
        '\n' +
        indent +
        ']'
      );
    return toEDNString(value);
  }
  const converted = convert(value);
  return (
    (options?.compact === true
      ? toEDNString(converted)
      : layout(converted, 0)) + '\n'
  );
}
