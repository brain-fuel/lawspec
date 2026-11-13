// A masked record's native renderings: what is masked, and what is not.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import util from 'node:util';
import * as data from '../src/lawspec_data.js';
import * as definitions from '../src/lawspec_definitions/example/masking.js';
import * as ls from '../src/lawspec_runtime.js';

const card = new data.Card(
  'Ann Lee',
  '4111111111111111',
  'ann@example.org',
  900,
  1234,
);
const masked =
  'Card{holder=***, number=***1111, contact=a***@example.org, limit=900, pin=***}';

function nothingRaw(text: string): void
{
  for (const raw of ['Ann Lee', '4111111111111111', 'ann@example.org', '1234'])
    assert.ok(!text.includes(raw), `shows ${raw}: ${text}`);
}

test('toString is the checked masked rendering', () =>
{
  assert.equal(String(card), masked);
  assert.equal(definitions.maskedCard(new Map(), card), String(card));
  nothingRaw(`card: ${card}`);
  nothingRaw('card: ' + card);
});

test('console.log and util.inspect show the masked rendering', () =>
{
  assert.equal(util.inspect(card), masked);
  nothingRaw(util.inspect({order: 7, card}));
  nothingRaw(util.format('%s %o %O', card, card, [card]));
});

test('the unmasked rendering is explicit', () =>
{
  assert.ok(card.toUnmaskedString().includes('4111111111111111'));
});

test('JSON.stringify is the wire form and is not masked', () =>
{
  assert.equal(JSON.parse(JSON.stringify(card)).number, '4111111111111111');
});

// Keyed BLAKE3-256 under the key below, from test/fixtures/blake3-keyed-text.json:
// the digests LawSpec's Haskell port computes. They tie this runtime to it.
const letters: [number, string][] = [
  [0, '92b2b75604ed3c761f9d6f62392c8a9227ad0ea3f09573e783f1498a4ed60d26'],
  [1, '36a6d4db841fe91831fe6d0fe35623a3a47269dd94d84ac68cb8ba7cd26ba3a2'],
  [64, '81873b794210dfd69cc8d2124ae9606f741743c60ef56d1eacd7a2a98d4d5807'],
  [65, 'a3e4916d04ae832e039226fcae19845b35de0289e59dceb7d51a6994d806d3e2'],
  [1024, '1e585da86aa6772d1792955fed46e2fe7362f5564b64612c88602b964538986a'],
  [1025, '09fbf44f6e68576dd4082a72cc176a2865513031c6200df32eebdf77894b2b8f'],
  [2048, 'e3deeb5a2004cc135d0c60d694a06d746a6ffbcc5009e31368d3e2af360f985a'],
  [2049, 'b4467e073bfa567e4a337b8b8a04da641184522ae5bb753584244a1f37696c4c'],
  [3073, '5795c366f3dd3d823ee2b8bf21724bdd1a0fe378a8616dba2b011c46715125f2'],
  [5121, '269647e2dd34dd8055e7f39620b006c91d516b658203d5404583575c1e0c545e'],
  [8193, '67af3328f4c7f02f0d20e2921dd61513170f6151748e2989b3dd4f775c099236'],
];
const mixed: [number, string][] = [
  [1, '7bdcc4c951f17b858dd3098096a6bfc4618d2e712012ea8deda5db2b40207365'],
  [300, 'a4d2df6b99760f8ac8e166f46ab4427e8e987aeef49768283c5061cfceb9372d'],
];

test('a hashed field needs a key, and shows the keyed BLAKE3 digest', () =>
{
  const session = new data.Session('ann', 'tok-12345678');
  assert.throws(() => String(session), /no key is set/);
  assert.throws(() => ls.setMaskHashKey(new Uint8Array(31)), /32 bytes/);
  ls.setMaskHashKey(
    new TextEncoder().encode('whats the Elvish word for friend'),
  );
  for (const [count, hash] of letters)
  {
    const text = 'abcdefghijklmnopqrstuvwxyz'.repeat(400).slice(0, count);
    assert.equal(ls.maskHash(text), 'hash:' + hash);
  }
  for (const [count, hash] of mixed)
    assert.equal(
      ls.maskHash('a\u00e9\u20ac\u{1F600}'.repeat(count)),
      'hash:' + hash,
    );
  const shown = String(session);
  assert.equal(
    shown,
    `Session{user=ann, token=${ls.maskHash('tok-12345678')}}`,
  );
  assert.match(shown, /token=hash:[0-9a-f]{64}}$/);
  assert.ok(!shown.includes('tok-12345678'));
  assert.equal(util.inspect(session), shown);
  assert.equal(
    definitions.maskedSession(new Map(), session),
    'Session{user=ann, token=***}',
  );
  assert.ok(session.toUnmaskedString().includes('tok-12345678'));
});
