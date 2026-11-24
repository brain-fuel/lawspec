import {test} from 'node:test';
import assert from 'node:assert/strict';
import {corePath, nativePath} from '../core-path.mjs';
import {createEffects} from '../host.mjs';

// The same cases as hosts/go/internal/effects/winpath_test.go.
test('corePath maps Windows paths to the core form', () =>
{
  const cases = [
    ['C:\\Users\\me\\project', '/C:/Users/me/project'],
    ['c:\\Users', '/C:/Users'],
    ['C:/Users/me', '/C:/Users/me'],
    ['C:\\', '/C:/'],
    ['C:', '/C:/'],
    ['\\\\server\\share\\dir', '//server/share/dir'],
    ['\\\\?\\C:\\long', '/C:/long'],
  ];
  for (const [native, core] of cases)
  {
    assert.equal(corePath('win32', native), core, native);
  }
});

test('nativePath maps the core form and Windows spellings to native paths', () =>
{
  const cases = {
    '/C:/Users/me': 'C:/Users/me',
    '/c:/': 'C:/',
    '/C:': 'C:/',
    'C:\\a\\b': 'C:/a/b',
    'C:/a': 'C:/a',
    '//server/s/d': '//server/s/d',
    '\\\\?\\C:\\long': 'C:/long',
    'relative/x': 'relative/x',
  };
  for (const [given, native] of Object.entries(cases))
  {
    assert.equal(nativePath('win32', given), native, given);
  }
});

test('paths are untouched off Windows', () =>
{
  for (const platform of ['linux', 'darwin', 'freebsd'])
  {
    for (const file of ['/a/b', '/C:/x', 'C:\\x'])
    {
      assert.equal(corePath(platform, file), file);
      assert.equal(nativePath(platform, file), file);
    }
  }
});

test('the core form round-trips', () =>
{
  for (const native of ['C:/Users/me', 'D:/', '//server/share/dir'])
  {
    assert.equal(nativePath('win32', corePath('win32', native)), native);
  }
  for (const core of ['/C:/Users/me', '/D:/', '//server/share/dir', '/a/b'])
  {
    assert.equal(corePath('win32', nativePath('win32', core)), core);
  }
});

const policy = {
  read: ['/C:/work'],
  write: ['/C:/work'],
  programs: ['/C:/tools/git.exe'],
  network: false,
  listen: false,
};

// A host that believes it is on Windows, over a fake file system: the
// request path is converted to native before the file system sees it, and a
// path in a response is converted back.
test('a win32 host converts the paths of requests and responses', async () =>
{
  const seen = [];
  const effects = createEffects({
    platform: 'win32',
    files: {
      realpath: async file =>
      {
        seen.push(['realpath', file]);
        return file.replace('link', 'target');
      },
      readFile: async file =>
      {
        seen.push(['readFile', file]);
        return Buffer.from('hi');
      },
      readdir: async file =>
      {
        seen.push(['readdir', file]);
        return [];
      },
    },
  });
  try
  {
    const read = await effects.perform({
      abi: 2,
      op: 'read',
      path: '/C:/work/a.txt',
      policy,
    });
    assert.equal(read.ok.data, Buffer.from('hi').toString('base64'));
    assert.deepEqual(
      seen.filter(([op]) => op === 'readFile'),
      [['readFile', 'C:/work/a.txt']],
    );
    const real = await effects.perform({
      abi: 2,
      op: 'realpath',
      path: '/C:/work/link',
      policy,
    });
    assert.deepEqual(real.ok, {path: '/C:/work/target'});
    const outside = await effects.perform({
      abi: 2,
      op: 'read',
      path: '/C:/other/a.txt',
      policy,
    });
    assert.equal(outside.error.kind, 'denied');
    const native = await effects.perform({
      abi: 2,
      op: 'read',
      path: 'C:\\work\\a.txt',
      policy,
    });
    assert.equal(native.error.kind, 'invalid');
  }
  finally
  {
    effects.close();
  }
});
