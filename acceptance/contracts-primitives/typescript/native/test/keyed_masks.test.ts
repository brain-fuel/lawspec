// The masks a specification calls are the runtime's own, under the same key.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import * as data from '../src/lawspec_data.js';
import * as definitions from '../src/lawspec_definitions/example/keyed.js';
import * as ls from '../src/lawspec_runtime.js';

const key = new TextEncoder().encode('whats the Elvish word for friend');
const texts = [
  '',
  'abc',
  'tok-12345678',
  'a\u00e9\u20ac\u{1F600}'.repeat(300),
  'x'.repeat(5121),
];
// test/fixtures/blake3-keyed-text.json: the same rows in every runtime.
const recorded: [string, string][] = [
  ['abc', '157f8b4b104070014ab0b3b7aff364f794e010e92b1c976318e892f380b53406'],
  [
    '\ufffd',
    'b08a37ba71c80d97211ca1ecbc0e82e0254499a3004691544ffdb4425702ec8e',
  ],
];

test('maskHash in a specification is the runtime maskHash under the key', () =>
{
  ls.setMaskKey(key);
  for (const text of texts)
  {
    const shown = definitions.fingerprint(new Map(), key, text);
    assert.equal(shown, ls.maskHash(text));
    assert.equal(shown, ls.maskHashBlake3(text));
    assert.equal(shown, ls.maskHashWith(key, text));
    assert.equal(shown, ls.maskHashBlake3With(key, text));
  }
  for (const [text, hash] of recorded)
    assert.equal(definitions.fingerprint(new Map(), key, text), 'hash:' + hash);
});

test('the default hash is the BLAKE3 one', () =>
{
  assert.equal(ls.maskHash, ls.maskHashBlake3);
  assert.equal(ls.maskHashWith, ls.maskHashBlake3With);
});

test('a record rendered with the key is its native rendering', () =>
{
  ls.setMaskKey(key);
  const session = new data.Session('ann', 'tok-12345678', 'c');
  const shown = definitions.maskedSessionWith(new Map(), key, session);
  assert.equal(shown, String(session));
  assert.match(
    shown,
    /^Session\{user=ann, token=hash:[0-9a-f]{64}, device=hash:[0-9a-f]{64}\}$/,
  );
  assert.equal(
    definitions.maskedSession(new Map(), session),
    'Session{user=ann, token=***, device=***}',
  );
});

test('a half of a surrogate pair is hashed as U+FFFD', () =>
{
  for (const lone of ['\ud800', '\udc00', 'a\ud83d'])
    assert.equal(
      ls.maskHashWith(key, lone),
      ls.maskHashWith(key, lone.replace(/[\ud800-\udfff]/g, '\ufffd')),
    );
  assert.equal(ls.maskHashWith(key, '\ud800'), 'hash:' + recorded[1][1]);
});

test('a key that is not 32 bytes is refused', () =>
{
  assert.throws(() => ls.maskHashWith(new Uint8Array(31), 'abc'), /32 bytes/);
  assert.throws(
    () => definitions.fingerprint(new Map(), new Uint8Array(31), 'abc'),
    /precondition/,
  );
});

test('maskStar shows nothing', () =>
{
  assert.equal(ls.maskStar('tok-12345678'), '***');
  assert.equal(ls.maskStar(1234), '***');
});
