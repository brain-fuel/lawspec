// Filesystem acceptance for adopting and regenerating native bindings.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile, writeFile, mkdir, rename, mkdtemp, rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createCompiler} from '../api.mjs';
import {planWrites, applyWrites} from '../files.mjs';

const compiler = await createCompiler();
const fixture = new URL('../../test/fixtures/native-payments/', import.meta.url);
const sources = [{path:'payments.lawspec',content:await readFile(
  new URL('../examples/specs/payments.lawspec',import.meta.url),'utf8')}];
const configurations = [
  ['rust','bindings.json',['lawspec_generators','prices'],'support/lawspec_generators.rs'],
  ['python','bindings-python.json',['lawspec_generators','prices'],'lawspec_generators.py'],
  ['javascript','bindings-web.json',['lawspec_generators','prices'],'lawspec_generators.mjs'],
  ['typescript','bindings-web.json',['lawspec_generators','prices'],'lawspec_generators.ts'],
  ['java','bindings-java.json',['domain','PaymentGenerators','prices'],'domain/PaymentGenerators.java'],
  ['kotlin','bindings-kotlin.json',['domain','PaymentGenerators','prices'],'domain/PaymentGenerators.kt'],
  ['go','bindings-go.json',['NativePrices'],'example/payments/native_generators_test.go'],
  ['haskell','bindings-haskell.json',['PaymentGenerators','prices'],'PaymentGenerators.hs'],
];

for (const [target, fixtureName, factory, generatorFile] of configurations) {
  test(`${target}: migration, edits, regeneration and layouts preserve application ownership`, async () => {
    const nativeBindings = JSON.parse(await readFile(new URL(fixtureName,fixture),'utf8'));
    nativeBindings.generators = [{type:'example.payments::type::Money',factory}];
    const directory = await mkdtemp(path.join(os.tmpdir(),`lawspec-${target}-ownership-`));
    const sourceDir = 'library/native';
    const testDir = target === 'go' ? sourceDir : 'checks/native';
    const base = {sources,target,sourceDir,testDir,machineBits:32,minify:false};
    async function generate(options) {
      const result = await compiler.planGeneration(options);
      assert.deepEqual(result.diagnostics,[]);
      return result.files;
    }
    async function put(relative,content) {
      const file=path.join(directory,relative);
      await mkdir(path.dirname(file),{recursive:true});
      await writeFile(file,content);
    }
    const get=relative=>readFile(path.join(directory,relative),'utf8');
    try {
      const unbound = await generate(base);
      const bound = await generate({...base,nativeBindings});
      const adapterPaths = unbound.filter(file=>file.ownership==='user' &&
        bound.some(next=>next.path===file.path && next.ownership==='generated')).map(file=>file.path);
      assert.ok(adapterPaths.length>0,'must exercise an actual adapter ownership transition');
      const applicationGenerator = path.posix.join(testDir,generatorFile);
      const applicationSource = path.posix.join(sourceDir,'application-owned.txt');
      await put(applicationGenerator,'application generator implementation\n');
      await put(applicationSource,'application model implementation\n');
      await applyWrites([await planWrites(directory,unbound)]);
      const manifestBefore = await get('.lawspec/generated.json');
      await assert.rejects(planWrites(directory,bound),/Refusing to overwrite unowned or edited/);
      assert.equal(await get('.lawspec/generated.json'),manifestBefore);
      // Explicit migration: move user adapters aside before creating owned bridges.
      for(const relative of adapterPaths) {
        const saved=path.join(directory,'saved-adapters',relative);
        await mkdir(path.dirname(saved),{recursive:true});
        await rename(path.join(directory,relative),saved);
      }
      await applyWrites([await planWrites(directory,bound)]);
      const manifest=JSON.parse(await get('.lawspec/generated.json'));
      for(const relative of adapterPaths) assert.ok(manifest.files[relative]);
      assert.ok(!manifest.files[applicationGenerator]);
      assert.ok(bound.some(file=>file.placement==='test' && (target==='rust'
        ? file.content.includes('mod lawspec_generators;') : /native.*generators/i.test(file.path))));
      assert.ok(bound.filter(file=>file.placement==='source').every(file=>file.path.startsWith(sourceDir+'/')));
      assert.ok(bound.filter(file=>file.placement==='test').every(file=>file.path.startsWith(testDir+'/')));
      assert.deepEqual((await planWrites(directory,bound)).changes,[]);
      const support=bound.find(file=>file.ownership==='generated' && file.placement==='source');
      await put(support.path,support.content+'edited bridge/runtime\n');
      await assert.rejects(planWrites(directory,bound),/Refusing to overwrite unowned or edited/);
      await put(support.path,support.content);
      const changed=await generate({...base,nativeBindings,machineBits:64,minify:true});
      const pending=await planWrites(directory,changed);
      const update=pending.changes.find(change=>change.action==='update' && change.relative!=='.lawspec/generated.json');
      assert.ok(update,'profile/format switch must change a generated artifact');
      await put(update.relative,update.expected+'concurrent edit\n');
      const beforeRace=await get('.lawspec/generated.json');
      await assert.rejects(applyWrites([pending]),/File changed during generation/);
      assert.equal(await get('.lawspec/generated.json'),beforeRace);
      await put(update.relative,update.expected);
      await applyWrites([pending]);
      assert.deepEqual((await planWrites(directory,changed)).changes,[]);
      const movedSource='relocated/library';
      const movedTest=target==='go'?movedSource:'relocated/checks';
      const moved=await generate({...base,nativeBindings,machineBits:64,minify:true,sourceDir:movedSource,testDir:movedTest});
      const stale=changed.find(file=>file.ownership==='generated' && file.placement==='source');
      await put(stale.path,stale.content+'edited old location\n');
      await assert.rejects(planWrites(directory,moved),/Refusing to remove edited generated file/);
      await put(stale.path,stale.content);
      await applyWrites([await planWrites(directory,moved)]);
      await assert.rejects(get(stale.path),{code:'ENOENT'});
      assert.equal(await get(applicationGenerator),'application generator implementation\n');
      assert.equal(await get(applicationSource),'application model implementation\n');
      for(const relative of adapterPaths) assert.equal(await get(path.posix.join('saved-adapters',relative)),
        unbound.find(file=>file.path===relative).content);
      const ordinary=await generate({...base,sourceDir:movedSource,testDir:movedTest,machineBits:64,minify:true});
      const release=await planWrites(directory,ordinary);
      const reverting=ordinary.filter(file=>file.ownership==='user' && moved.some(old=>old.path===file.path && old.ownership==='generated'));
      assert.ok(reverting.length>0);
      for(const file of reverting) {
        assert.ok(release.preserved.includes(file.path));
        assert.ok(release.adapterUpdates.some(update=>update.path===file.path));
      }
      await applyWrites([release]);
      for(const file of reverting) assert.equal(await get(file.path),moved.find(old=>old.path===file.path).content);
    } finally {
      await rm(directory,{recursive:true,force:true});
    }
  });
}

for (const [target, sourceRoot, generator] of [
  ['erlang', 'src', 'payment_generators.erl'],
  ['elixir', 'lib', 'support/payment_generators.ex'],
  ['gleam', 'src', 'payment_generators.gleam'],
]) {
  test(`${target}: adopting and removing native bindings preserves application files`, async () => {
    const example = new URL(`../examples/native-payments/${target}/`, import.meta.url);
    const nativeBindings = JSON.parse(await readFile(new URL('lawspec.json', example), 'utf8')).targets[0].nativeBindings;
    const directory = await mkdtemp(path.join(os.tmpdir(), `lawspec-${target}-ownership-`));
    const sourceDir = target === 'gleam' ? 'src' : 'library/native';
    const testDir = target === 'gleam' ? 'test' : 'checks/native';
    const base = {sources, target, sourceDir, testDir, machineBits: 32, minify: false};
    const get = relative => readFile(path.join(directory, relative), 'utf8');
    async function put(relative, content) {
      const file = path.join(directory, relative);
      await mkdir(path.dirname(file), {recursive: true});
      await writeFile(file, content);
    }
    async function generate(options) {
      const result = await compiler.planGeneration(options);
      assert.deepEqual(result.diagnostics, []);
      return result.files;
    }
    try {
      const ordinary = await generate(base);
      const bound = await generate({...base, nativeBindings});
      const extension = {erlang: 'erl', elixir: 'ex', gleam: 'gleam'}[target];
      const application = new Map([
        [`${sourceDir}/payments_domain.${extension}`, await readFile(new URL(`${sourceRoot}/payments_domain.${extension}`, example), 'utf8')],
        [`${testDir}/${generator}`, await readFile(new URL(`test/${generator}`, example), 'utf8')],
      ]);
      if (target === 'erlang')
        application.set('include/payments_domain.hrl', await readFile(new URL('include/payments_domain.hrl', example), 'utf8'));
      for (const [relative, content] of application) await put(relative, content);
      await applyWrites([await planWrites(directory, ordinary)]);
      for (const adapter of ordinary.filter(file => file.ownership === 'user')) {
        const content = adapter.content + '\n' + (target === 'erlang' ? '%' : target === 'elixir' ? '#' : '//') + ' application implementation\n';
        application.set(adapter.path, content);
        await put(adapter.path, content);
      }
      const bridge = bound.find(file => file.path.endsWith('/lawspec_native_bindings.erl'));
      assert.ok(bridge, 'Bindings must emit a real native bridge');
      const before = await get('.lawspec/generated.json');
      await put(bridge.path, 'application-owned module at the prospective bridge path\n');
      await assert.rejects(planWrites(directory, bound), /Refusing to overwrite unowned or edited/);
      assert.equal(await get('.lawspec/generated.json'), before);
      await rm(path.join(directory, bridge.path));
      await applyWrites([await planWrites(directory, bound)]);
      const owned = JSON.parse(await get('.lawspec/generated.json')).files;
      assert.ok(owned[bridge.path]);
      for (const [relative, content] of application) {
        assert.equal(await get(relative), content);
        assert.ok(!owned[relative], `${relative} must remain application-owned`);
      }
      assert.deepEqual((await planWrites(directory, bound)).changes, []);
      const changed = await generate({...base, nativeBindings, machineBits: 64, minify: true});
      const pending = await planWrites(directory, changed);
      const update = pending.changes.find(change => change.action === 'update' && change.relative !== '.lawspec/generated.json');
      assert.ok(update);
      await put(update.relative, update.expected + '\nconcurrent application edit\n');
      const beforeRace = await get('.lawspec/generated.json');
      await assert.rejects(applyWrites([pending]), /File changed during generation/);
      assert.equal(await get('.lawspec/generated.json'), beforeRace);
      await put(update.relative, update.expected);
      await applyWrites([pending]);
      const unbound = await generate({...base, machineBits: 64, minify: true});
      const currentBridge = changed.find(file => file.path === bridge.path);
      await put(bridge.path, currentBridge.content + '\n% edited bridge\n');
      await assert.rejects(planWrites(directory, unbound), /Refusing to remove edited generated file/);
      await put(bridge.path, currentBridge.content);
      await applyWrites([await planWrites(directory, unbound)]);
      await assert.rejects(get(bridge.path), {code: 'ENOENT'});
      assert.deepEqual((await planWrites(directory, unbound)).changes, []);
      for (const [relative, content] of application) assert.equal(await get(relative), content);
    } finally {
      await rm(directory, {recursive: true, force: true});
    }
  });
}
