// Generated from templates/tools/rejection-examples.mjs by lawspec-dev generate. Do not edit.
// Exercise the real documentation checker, including failing authoring cases.
import assert from 'node:assert/strict';
import {mkdir, mkdtemp, readFile, writeFile, copyFile} from 'node:fs/promises';
import {spawnSync, execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const binary =
  process.env.LAWSPEC_DEV ??
  path.join(
    execFileSync('stack', ['path', '--local-install-root'], {
      cwd: root,
      encoding: 'utf8',
    }).trim(),
    'bin/lawspec-dev',
  );
const artifacts = path.join(root, '.artifacts/rejection-examples');
await mkdir(artifacts, {recursive: true});
const directory = await mkdtemp(path.join(artifacts, 'docs-'));
for (const folder of ['docs', 'templates/site', 'test/fixtures'])
  await mkdir(path.join(directory, folder), {recursive: true});
await copyFile(
  path.join(root, 'package.yaml'),
  path.join(directory, 'package.yaml'),
);
await copyFile(
  path.join(root, 'templates/site/page.html'),
  path.join(directory, 'templates/site/page.html'),
);
await copyFile(
  path.join(root, 'docs/vendor.lock.json'),
  path.join(directory, 'docs/vendor.lock.json'),
);
for (const file of ['canonical_refs.yaml', 'canonical_decisions.yaml'])
  await writeFile(path.join(directory, file), '');
await writeFile(
  path.join(directory, 'README.md'),
  '# Documentation fixture checks\n',
);
await writeFile(
  path.join(directory, 'docs/nav.json'),
  JSON.stringify([{path: 'index.md'}]),
);
for (const name of ['denominator', 'result-type', 'address'])
{
  const file = 'test/fixtures/canonical-rejection-' + name + '.lawspec';
  await copyFile(path.join(root, file), path.join(directory, file));
}
const denominator = await readFile(
  path.join(directory, 'test/fixtures/canonical-rejection-denominator.lawspec'),
  'utf8',
);
const fence = (attributes, body = '') =>
  '```lawspec ' + attributes + '\n' + body + '\n```\n';
const included =
  'include=test/fixtures/canonical-rejection-denominator.lawspec';
const front =
  '---\nid: fixture.rejections\nkind: index\ntitle: Rejection fixtures\n---\n# Rejection fixtures\n\n';
const cases = [
  {name: 'expected-total', body: fence('reject=total ' + included), pass: true},
  {
    name: 'all-independent-fixtures',
    body: [
      ['denominator', 'total'],
      ['result-type', 'definition'],
      ['address', 'total'],
    ]
      .map(([name, code]) =>
        fence(
          'reject=' +
            code +
            ' include=test/fixtures/canonical-rejection-' +
            name +
            '.lawspec',
        ),
      )
      .join('\n'),
    pass: true,
  },
  {
    name: 'accepted-repair',
    body: fence('', denominator.replace('value 0', 'value 1')),
    pass: true,
  },
  {
    name: 'wrong-code',
    body: fence('reject=parse ' + included),
    pass: false,
    reason: /expected exactly one compiler rejection with code parse/,
  },
  {
    name: 'unexpected-acceptance',
    body: fence('reject=total', denominator.replace('value 0', 'value 1')),
    pass: false,
    reason: /received \[\]/,
  },
  {
    name: 'ordinary-rejection',
    body: fence(included),
    pass: false,
    reason: /snippet does not compile/,
  },
  ...['reject', 'reject=', 'reject=total reject=definition'].map(
    (attributes, index) => ({
      name: 'malformed-' + index,
      body: fence(attributes, denominator),
      pass: false,
      reason: /exactly one nonempty reject=/,
    }),
  ),
  ...[
    'fragment',
    'implementations=application',
    'run=application',
    'view=implementation',
  ].map((attribute, index) => ({
    name: 'incompatible-' + index,
    body: fence('reject=total ' + attribute, denominator),
    pass: false,
    reason: /reject fixtures cannot be/,
  })),
  {
    name: 'isolated-fences',
    body:
      fence(
        '',
        `unit isolation

function privateValue (value :: Bool) -> Bool is value end function

end unit
`,
      ) +
      fence(
        'reject=definition',
        `unit isolation

function second (value :: Bool) -> Bool is privateValue value end function

end unit
`,
      ),
    pass: true,
  },
];
const receipts = [];
for (const fixture of cases)
{
  const source = front + fixture.body;
  await writeFile(path.join(directory, 'docs/index.md'), source);
  const result = spawnSync(binary, ['docs', '--check'], {
    cwd: directory,
    encoding: 'utf8',
    maxBuffer: 16e6,
  });
  assert.equal(result.error, undefined, String(result.error));
  assert.equal(result.signal, null);
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  await writeFile(path.join(directory, fixture.name + '.md'), source);
  await writeFile(path.join(directory, fixture.name + '.log'), output);
  if (fixture.pass)
    assert.equal(result.status, 0, fixture.name + ': ' + output);
  else
  {
    assert.ok(result.status > 0, fixture.name + ' unexpectedly passed');
    assert.match(output, fixture.reason);
  }
  receipts.push({
    name: fixture.name,
    expected: fixture.pass ? 'accepted' : 'rejected',
    status: result.status,
    sourceSha256: createHash('sha256').update(source).digest('hex'),
    outputSha256: createHash('sha256').update(output).digest('hex'),
  });
}
await writeFile(
  path.join(directory, 'receipts.json'),
  JSON.stringify({checks: receipts.length, receipts}, null, 2) + '\n',
);
console.log(
  JSON.stringify({status: 'passed', checks: receipts.length, directory}),
);
