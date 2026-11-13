// A masked record's native renderings: what is masked, and what is not.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import util from 'node:util';
import * as data from '../src/lawspec_data.mjs';
import * as definitions from '../src/lawspec_definitions/example/masking.mjs';

const card = new data.Card(
  'Ann Lee',
  '4111111111111111',
  'ann@example.org',
  900,
  1234,
);
const masked =
  'Card{holder=***, number=***1111, contact=a***@example.org, limit=900, pin=***}';

function nothingRaw(text)
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
