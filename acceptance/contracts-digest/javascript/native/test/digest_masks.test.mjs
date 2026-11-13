// A digest needs no key: a specification's digest, the runtime's and a
// record's native rendering are one text.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import * as data from '../src/lawspec_data.mjs';
import * as definitions from '../src/lawspec_definitions/example/digest.mjs';
import * as ls from '../src/lawspec_runtime.mjs';

const texts = [
  '',
  'abc',
  'GB82WEST12345698765432',
  'a\u00e9\u20ac\u{1F600}'.repeat(300),
  'x'.repeat(5121),
];
// BLAKE3 of no bytes and of "abc", as b3sum prints them; the first is the
// first of the official test vectors (test/fixtures/blake3-official).
const published = [
  ['', 'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262'],
  ['abc', '6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85'],
];
const iban = 'GB82WEST12345698765432';

test('maskDigest in a specification is the runtime maskDigest', () =>
{
  for (const text of texts)
  {
    const shown = definitions.fingerprint(new Map(), text);
    assert.equal(shown, ls.maskDigest(text));
    assert.equal(shown, ls.maskDigestBlake3(text));
    const scoped = definitions.fingerprintIn(new Map(), 'orders', text);
    assert.equal(scoped, ls.maskDigestIn('orders', text));
    assert.equal(scoped, ls.maskDigestBlake3In('orders', text));
    assert.notEqual(scoped, shown);
  }
  for (const [text, hash] of published)
    assert.equal(definitions.fingerprint(new Map(), text), 'digest:' + hash);
});

test('the default digest is the BLAKE3 one', () =>
{
  assert.equal(ls.maskDigest, ls.maskDigestBlake3);
  assert.equal(ls.maskDigestIn, ls.maskDigestBlake3In);
});

test('a record shows its digests natively, with no key set', () =>
{
  const account = new data.Account('ann', iban, iban);
  const shown = definitions.maskedAccount(new Map(), account);
  assert.equal(shown, String(account));
  assert.equal(
    shown,
    'Account{owner=ann' +
      ', iban=digest:bef19ccbcf87f759cb18235af8a4d031a4cd89369514a9300e348803fe129d02' +
      ', reference=digest:c88e885494a2d3f82a49e3efbda8ab5dad1560ac499caa380ba9db31abb5a727}',
  );
  assert.ok(!`${account}`.includes(iban));
  assert.ok(account.toUnmaskedString().includes(iban));
});

test('a field has its own context', () =>
{
  const account = new data.Account('ann', iban, iban);
  const shown = String(account);
  assert.ok(
    shown.includes(ls.maskDigestIn('example.digest.Account.iban', iban)),
  );
  assert.ok(
    shown.includes(ls.maskDigestIn('example.digest.Account.reference', iban)),
  );
  assert.ok(!shown.includes(ls.maskDigest(iban)));
});

test('a half of a surrogate pair is hashed as U+FFFD', () =>
{
  for (const lone of ['\ud800', '\udc00', 'a\ud83d'])
  {
    const replaced = lone.replace(/[\ud800-\udfff]/g, '\ufffd');
    assert.equal(ls.maskDigest(lone), ls.maskDigest(replaced));
    assert.equal(
      ls.maskDigestIn('orders', lone),
      ls.maskDigestIn('orders', replaced),
    );
  }
});

test('a failure shows a digest field as its digest', () =>
{
  data.makeSchema();
  const tag = 'example.digest::type::Account::Account';
  const value = new ls.DataValue(tag, ['ann', iban, iban]);
  for (const printed of [ls.shown(value), String(ls.concealed(value).fields)])
  {
    assert.ok(!printed.includes(iban), printed);
    assert.ok(
      printed.includes(ls.maskDigestIn('example.digest.Account.iban', iban)),
      printed,
    );
  }
});
