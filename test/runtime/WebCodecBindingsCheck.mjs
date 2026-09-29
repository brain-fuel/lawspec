import assert from 'node:assert/strict';
import test from 'node:test';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const load = name => import(pathToFileURL(path.join(process.env.LAWSPEC_DATA_DIR,
  `${name}.${process.env.LAWSPEC_DATA_EXTENSION ?? 'mjs'}`)).href);
const [bridge, schema, ls, domain, hooks] = await Promise.all([
  load('lawspec_native'), load('lawspec_schema'), load('lawspec_runtime'),
  load('codec_domain'), load('codec_hooks'),
]);
const parcel = 'native.codecs::type::Parcel';
const tag = parcel+'::Parcel';

test('generic hooks preserve native children and Symbol identity', () => {
  const symbol = Symbol('same');
  const reference = new schema.Named(parcel,[new schema.Named(parcel,[new schema.Named('Symbol')])]);
  const value = new ls.DataValue(tag,[new ls.DataValue(tag,[symbol])]);
  const native = bridge.native.toNative(reference,value);
  assert.ok(native.unpack() instanceof domain.Parcel);
  assert.equal(native.unpack().unpack(),symbol);
  assert.ok(bridge.canonical.equal(reference,value,bridge.native.fromNative(reference,native)));
});
test('checked child converters reject invalid payloads', () => {
  const reference = new schema.Named(parcel,[new schema.Named('Int8')]);
  assert.throws(() => bridge.native.fromNative(reference,new domain.Parcel(128n)),/Parcel fromNative/);
  const wrong = bridge.canonical.withNativeBindings(new Map(),new Map([
    [parcel,{native:domain.Parcel,toNative:()=>({}),fromNative:hooks.from_parcel}],
  ]));
  assert.throws(() => wrong.toNative(reference,new ls.DataValue(tag,[1n])),/wrong native type/);
});
test('hooks compose with direct native mappings', () => {
  class Direct { constructor({value}) { this.value=value; } }
  const positive='native.codecs::type::Positive';
  const native=bridge.canonical.withNativeBindings(new Map([
    [positive+'::Positive',{native:Direct,fields:['value']}],
  ]),new Map([[parcel,{native:domain.Parcel,toNative:hooks.to_parcel,fromNative:hooks.from_parcel}]]));
  const reference=new schema.Named(parcel,[new schema.Named(positive)]);
  const value=new ls.DataValue(tag,[new ls.DataValue(positive+'::Positive',[7n])]);
  const app=native.toNative(reference,value);
  assert.ok(app.unpack() instanceof Direct);
  assert.ok(bridge.canonical.equal(reference,value,native.fromNative(reference,app)));
});
test('hook registrations reject conflicts and snapshot configuration', () => {
  const hook={native:domain.Parcel,toNative:hooks.to_parcel,fromNative:hooks.from_parcel};
  const registry=new Map([[parcel,hook]]);
  const native=bridge.canonical.withNativeBindings(new Map(),registry);
  hook.toNative=()=>{ throw new Error('mutated configuration'); };
  registry.clear();
  const reference=new schema.Named(parcel,[new schema.Named('Int8')]);
  assert.equal(native.toNative(reference,new ls.DataValue(tag,[1])).unpack(),1);
  assert.throws(()=>bridge.canonical.withNativeBindings(new Map(),new Map([
    ['unknown',hook],
  ])),/unknown or empty/);
  assert.throws(()=>bridge.canonical.withNativeBindings(new Map(),new Map([
    [parcel,{...hook,toNative:null}],
  ])),/invalid native codec/);
  assert.throws(()=>bridge.canonical.withNativeBindings(new Map([
    [tag,{native:domain.Parcel,fields:['item']}],
  ]),new Map([[parcel,hook]])),/conflicts/);
});
