// Generated from templates/npm/test/native-record-layouts.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp, mkdir, writeFile, rm} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createCompiler} from '../api.mjs';
import {programTargets as targets} from '../templates.mjs';

const compiler = await createCompiler();
const localPython = new URL(
  '../../.integration/python/.venv/bin/python',
  import.meta.url,
).pathname;
const localPrologPython = new URL(
  '../../.integration/prolog/.venv/bin/python',
  import.meta.url,
).pathname;
const prologPython =
  process.env.LAWSPEC_PYTHON_EXECUTABLE ??
  (existsSync(localPrologPython) ? localPrologPython : null);
const localTsc = new URL(
  '../../.integration/typescript/node_modules/.bin/tsc',
  import.meta.url,
).pathname;
const python =
  process.env.LAWSPEC_PYTHON_EXECUTABLE ??
  (existsSync(localPython) ? localPython : null);
const tsc = process.env.LAWSPEC_TSC ?? (existsSync(localTsc) ? localTsc : null);
const options = {
  schemaVersion: 5,
  languageProfile: '1.0-rc.2',
  verification: {layers: []},
};
const source = `unit layouts

type Packet (a :: Type) is one of
  Packed of type record{
    last of type a
    first of type record{count :: (n :: UInt8 where n > 0) flag :: Bool}
  }
end type
copy :: Packet UInt8 -> Packet UInt8

end unit
`;
const nativeBindings = {
  types: [
    {
      type: 'layouts::type::Packet',
      native: ['application', 'Packet'],
      constructors: [
        {
          constructor: 'Packed',
          native: ['application', 'Packed'],
          style: 'variant',
          fields: [
            {
              field: 'value',
              path: ['first', 'count'],
              argument: 2,
              native: 'quantity',
            },
            {field: 'value', path: ['last'], argument: 0, native: 'tail'},
            {
              field: 'value',
              path: ['first', 'flag'],
              argument: 1,
              native: 'enabled',
            },
          ],
        },
      ],
    },
  ],
  functions: [{declaration: 'layouts::copy', native: ['application', 'copy']}],
};
const request = target => ({
  ...options,
  target,
  sources: [{path: 'layouts.lawspec', content: source}],
  nativeBindings,
});
const run = (command, args, options = {}) =>
{
  const result = spawnSync(command, args, {encoding: 'utf8', ...options});
  assert.equal(result.status, 0, result.stdout + '\n' + result.stderr);
  return result.stdout;
};

test('nested native layouts require complete structural coverage and explicit argument positions', async () =>
{
  const checked = await compiler.check(request('python'));
  assert.deepEqual(checked.diagnostics, []);
  const fields = nativeBindings.types[0].constructors[0].fields;
  for (const changed of [
    fields.slice(1),
    [...fields, fields[0]],
    fields.map(item => ({...item, argument: 0})),
    fields.map(item => ({...item, argument: item.argument + 1})),
    fields.map(item => ({...item, path: ['absent']})),
    fields.map(item =>
    {
      const {argument, ...rest} = item;
      return rest;
    }),
    [{field: 'value', native: 'whole'}, ...fields],
  ])
  {
    const input = request('python');
    input.nativeBindings = structuredClone(nativeBindings);
    input.nativeBindings.types[0].constructors[0].fields = changed;
    const rejected = await compiler.check(input);
    assert.ok(rejected.diagnostics.length, JSON.stringify(changed));
  }
});

test('unfinished target emitters reject nested native layouts explicitly', async () =>
{
  for (const target of targets.filter(
    target =>
      ![
        'python',
        'javascript',
        'typescript',
        'java',
        'kotlin',
        'scala',
        'rust',
        'groovy',
        'go',
        'haskell',
        'fsharp',
        'swift',
        'erlang',
        'elixir',
        'gleam',
        'prolog',
      ].includes(target),
  ))
  {
    const result = await compiler.planGeneration(request(target));
    assert.ok(
      result.diagnostics.length,
      target + ' silently accepted an unsupported layout',
    );
    assert.ok(
      result.diagnostics.some(item =>
        /nested native field layout|Clojure binds.*not types/.test(
          item.message,
        ),
      ),
      JSON.stringify(result.diagnostics),
    );
  }
});

test(
  'Prolog native variants preserve nested generic argument order and reject invalid native results',
  {
    skip:
      prologPython === null && 'Prolog acceptance environment is not installed',
  },
  async () =>
  {
    for (const machineBits of [32, 64])
      for (const minify of [false, true])
      {
        const result = await compiler.planGeneration({
          ...request('prolog'),
          machineBits,
          minify,
        });
        assert.deepEqual(result.diagnostics, []);
        const root = await mkdtemp(
          path.join(os.tmpdir(), 'lawspec-prolog-layout-'),
        );
        try
        {
          for (const file of result.files.filter(
            file => file.placement === 'source',
          ))
          {
            const destination = path.join(root, file.path);
            await mkdir(path.dirname(destination), {recursive: true});
            await writeFile(destination, file.content);
          }
          await writeFile(
            path.join(root, 'src/application.pl'),
            `:- module(application,[copy/2,observed/1,bad/1]).
:- dynamic observed/1,bad/1.
copy(Value,Result) :-
    Value = 'application.Packed'(Tail,Enabled,Quantity),
    retractall(observed(_)), assertz(observed([Tail,Enabled,Quantity])),
    ( bad(zero) -> Result = 'application.Packed'(7,true,0)
    ; bad(range) -> Result = 'application.Packed'(256,true,3)
    ; bad(boolean) -> Result = 'application.Packed'(7,1,3)
    ; Result = Value
    ).
`,
          );
          await writeFile(
            path.join(root, 'check.py'),
            `import lawspec_data as data
from lawspec_schema import Named
import lawspec_prolog as bridge
from layouts import copy
schema=data.make_schema()
ty=Named('layouts::type::Packet',(Named('UInt8'),))
packet=schema.constructors(ty)[0]
record_type=packet.fields[0].type
record=schema.constructors(record_type)[0]
assert [field.name for field in record.fields]==['first','last']
inner_type=record.fields[0].type
inner=schema.constructors(inner_type)[0]
assert [field.name for field in inner.fields]==['count','flag']
fields=schema.construct(inner_type,inner.tag,[3,True])
wrapped=schema.construct(record_type,record.tag,[fields,7])
logical=schema.construct(ty,packet.tag,[wrapped])
native=schema.to_native(ty,logical)
assert schema.equal(ty,schema.from_native(ty,copy(native)),logical)
assert bridge.janus.query_once('application:observed(Values)')['Values']==[7,'true',3]
for mode in ['zero','range','boolean']:
    bridge.janus.query_once('retractall(application:bad(_)),assertz(application:bad(Mode))',{'Mode':mode})
    try: copy(native)
    except (ValueError,TypeError,OverflowError): pass
    else: raise AssertionError('invalid native result admitted: '+mode)
print('Prolog native nested layout execution passed')
`,
          );
          run(prologPython, ['-B', 'check.py'], {
            cwd: root,
            env: {...process.env, PYTHONPATH: path.join(root, 'src')},
          });
        }
        finally
        {
          await rm(root, {recursive: true, force: true});
        }
      }
  },
);

const jsApplication = `export const order=[];
export class Packed {
  constructor({tail,enabled,quantity}) {this.tail=tail;this.enabled=enabled;this.quantity=quantity;}
}
export const copy=value=>{order.push([value.tail,value.enabled,value.quantity]);return value;};`;
const jsCheck = `import assert from 'node:assert/strict';
import {native} from './src/lawspec_native.js';
import {Named} from './src/lawspec_schema.js';
import {Packed,order} from './src/application.js';
import {copy} from './src/layouts.js';
const type=new Named('layouts::type::Packet',[new Named('UInt8')]);
const input=new Packed({tail:7,enabled:true,quantity:3});
const logical=native.fromNative(type,input);
assert.deepEqual(logical.fields[0].fields[0].fields,[3,true]);
assert.equal(logical.fields[0].fields[1],7);
assert.deepEqual(native.toNative(type,logical),input);
assert.throws(()=>native.fromNative(type,new Packed({tail:7,enabled:true,quantity:0})),/refinement/);
assert.throws(()=>native.fromNative(type,new Packed({tail:256,enabled:true,quantity:3})));
assert.throws(()=>native.fromNative(type,new Packed({tail:7,enabled:1,quantity:3})));
const getters=[];
const observed=Object.create(Packed.prototype);
for(const [name,value] of [['tail',7],['enabled',true],['quantity',3]])
  Object.defineProperty(observed,name,{get(){getters.push(name);return value;}});
native.fromNative(type,observed);
assert.deepEqual(getters,['tail','enabled','quantity']);
const canonical=await import('./src/lawspec_native.js');
const canonicalValue=canonical.canonical.toNative(type,logical);
const returned=copy(canonicalValue);
assert.deepEqual(canonical.canonical.fromNative(type,returned),logical);
assert.deepEqual(order,[[7,true,3]]);
console.log('native layout execution passed');`;
const pyApplication = `order=[]
class Packed:
    def __init__(self, *, tail, enabled, quantity):
        self.tail,self.enabled,self.quantity=tail,enabled,quantity

def copy(value):
    order.append((value.tail,value.enabled,value.quantity))
    return value
`;
const pyCheck = `from lawspec_native import _native, _canonical
from lawspec_schema import Named
from application import Packed, order
from layouts import copy
type_=Named('layouts::type::Packet',(Named('UInt8'),))
input_=Packed(tail=7,enabled=True,quantity=3)
logical=_native.from_native(type_,input_)
assert logical.fields[0].fields[0].fields == (3,True)
assert logical.fields[0].fields[1] == 7
restored=_native.to_native(type_,logical)
assert (restored.tail,restored.enabled,restored.quantity)==(7,True,3)
for invalid in [Packed(tail=7,enabled=True,quantity=0),Packed(tail=256,enabled=True,quantity=3),Packed(tail=7,enabled=1,quantity=3)]:
    try: _native.from_native(type_,invalid)
    except (ValueError,TypeError,OverflowError): pass
    else: raise AssertionError('invalid native value admitted')
result=copy(_canonical.to_native(type_,logical))
assert _canonical.equal(type_,_canonical.from_native(type_,result),logical)
assert order==[(7,True,3)]
print('native layout execution passed')
`;

for (const target of ['python', 'javascript', 'typescript'])
{
  const unavailable =
    target === 'python' && python === null
      ? 'Python 3.13 integration environment is not installed'
      : target === 'typescript' && tsc === null
        ? 'TypeScript integration environment is not installed'
        : false;
  test(
    `${target} generated bridges pack nested generic records and enforce refinements`,
    {skip: unavailable},
    async () =>
    {
      for (const machineBits of [32, 64])
        for (const minify of [false, true])
        {
          const result = await compiler.planGeneration({
            ...request(target),
            machineBits,
            minify,
          });
          assert.deepEqual(
            result.diagnostics,
            [],
            JSON.stringify(result.diagnostics),
          );
          const root = await mkdtemp(
            path.join(os.tmpdir(), 'lawspec-native-layout-'),
          );
          try
          {
            for (const file of result.files.filter(
              file => file.placement === 'source',
            ))
            {
              const destination = path.join(root, file.path);
              await mkdir(path.dirname(destination), {recursive: true});
              await writeFile(destination, file.content);
            }
            if (target === 'python')
            {
              await writeFile(
                path.join(root, 'src/application.py'),
                pyApplication,
              );
              await writeFile(path.join(root, 'check.py'), pyCheck);
              run(python, ['check.py'], {
                cwd: root,
                env: {...process.env, PYTHONPATH: path.join(root, 'src')},
              });
            }
            else
            {
              const ts = target === 'typescript',
                extension = ts ? 'ts' : 'mjs';
              await writeFile(
                path.join(root, `src/application.${extension}`),
                (ts ? '// @ts-nocheck\n' : '') + jsApplication,
              );
              await writeFile(path.join(root, 'package.json'), '{}');
              if (ts)
              {
                run(
                  tsc,
                  [
                    '--target',
                    'ES2022',
                    '--module',
                    'ES2022',
                    '--skipLibCheck',
                    '--outDir',
                    'out',
                    ...result.files
                      .filter(
                        file =>
                          file.placement === 'source' &&
                          file.path.endsWith('.ts'),
                      )
                      .map(file => file.path),
                    'src/application.ts',
                  ],
                  {cwd: root},
                );
                // tsc places source files directly under out; keep their relative imports together.
                await writeFile(
                  path.join(root, 'out/check.mjs'),
                  jsCheck.replaceAll('./src/', './'),
                );
                run(process.execPath, ['out/check.mjs'], {cwd: root});
              }
              else
              {
                await writeFile(
                  path.join(root, 'check.mjs'),
                  jsCheck.replaceAll(".js'", ".mjs'"),
                );
                run(process.execPath, ['check.mjs'], {cwd: root});
              }
            }
          }
          finally
          {
            await rm(root, {recursive: true, force: true});
          }
        }
    },
  );
}
