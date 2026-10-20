// Generated from templates/npm/test/artifact-targets.test.mjs by lawspec-dev generate. Do not edit.
// Artifact generation has its own acceptance contract: checked definitions and
// explicit incomplete configuration, with no native law execution claims.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createCompiler} from '../api.mjs';
import {targets, programTargets, artifactTargets, templates} from '../templates.mjs';

const exec = promisify(execFile);
const compiler = await createCompiler();
const content = `unit configuration
type Settings is a record{port :: UInt16 enabled :: Bool} end type
function settings (u :: Unit) -> Settings is Settings record{port = 8080, enabled = true} end function
end unit`;
const request = (target, text = content) => ({schemaVersion:5, languageProfile:'1.0-rc.2',
  verification:{layers:[]}, target, sources:[{path:'configuration.lawspec',content:text}]});

test('program and artifact inventories are distinct and cover public targets', () => {
  assert.deepEqual(targets,[...programTargets,...artifactTargets]);
  assert.equal(new Set(targets).size,targets.length);
  for(const target of artifactTargets) assert.deepEqual(templates(target),{});
});

test('artifact API emits checked configuration without tests, on both machine profiles and layouts', async () => {
  for(const target of artifactTargets) for(const machineBits of [32,64]) for(const minify of [false,true]) {
    const result = await compiler.planGeneration({...request(target),machineBits,minify});
    assert.deepEqual(result.diagnostics,[],target);
    assert.deepEqual(result.tests,[],target);
    assert.deepEqual(result.benchmarks,[],target);
    assert.ok(result.files.length > 0,target);
    if(target === 'yaml') {
      const config = JSON.parse(result.files.find(file => file.path === 'configuration.yaml').content);
      assert.deepEqual(config['configuration::settings'],{port:8080,enabled:true});
    }
  }
});

test('missing values remain explicit and do not emit a complete YAML document', async () => {
  const result = await compiler.planGeneration(request('yaml','unit incomplete\nsetting :: Unit -> UInt16\nend unit'));
  assert.deepEqual(result.diagnostics,[]);
  assert.ok(!result.files.some(file => file.path === 'configuration.yaml'));
  const receipt = JSON.parse(result.files.find(file => file.path === 'lawspec-artifacts.json').content);
  assert.equal(receipt.configurationComplete,false);
  assert.deepEqual(receipt.missingValues,['incomplete::setting']);
  assert.equal(receipt.lawsExecuted,false);
  const types = await compiler.planGeneration(request('hcl',
    'unit types\ntype Settings is a record{port :: UInt16} end type\nend unit'));
  assert.deepEqual(types.diagnostics,[]);
  const manifest = JSON.parse(types.files.find(file => file.path === 'lawspec-artifacts.json').content);
  assert.equal(manifest.configurationComplete,false);
  assert.deepEqual(manifest.missingTypeValues,manifest.typeVariables.map(variable => variable.name));
  assert.match(manifest.types[manifest.typeVariables[0].schema],/types::type::Settings/u);
});

test('configuration serialization preserves UTF-8 and astral code points', async () => {
  const value = '日本語 é 😀';
  const source = `unit text\nfunction value (u :: Unit) -> Text is "${value}" end function\nend unit`;
  for(const target of ['yaml','hcl']) {
    const result = await compiler.planGeneration(request(target,source));
    assert.deepEqual(result.diagnostics,[]);
    const filename = target === 'yaml' ? 'configuration.yaml' : 'configuration.tfvars.json';
    assert.deepEqual(Object.values(JSON.parse(result.files.find(file => file.path === filename).content)),[value]);
  }
});

test('artifact layout and native binding requests are never silently ignored', async () => {
  for(const target of artifactTargets) {
    for(const nativeBindings of [{network:{identity:'identity.key'}},
      {names:[{declaration:'configuration::settings',name:'renamed'}]}]) {
      const result = await compiler.planGeneration({...request(target),nativeBindings});
      assert.ok(result.diagnostics.some(d => d.code === 'native-binding'),target);
    }
    for(const layout of [{testDir:'tests'},{sourceDir:'../escape'}]) {
      const result = await compiler.planGeneration({...request(target),...layout});
      assert.ok(result.diagnostics.some(d => d.code === 'target-unsupported'),target);
    }
  }
});

test('artifact targets preserve mandatory definition validation with no optional verification', async () => {
  for(const target of artifactTargets) {
    const result = await compiler.planGeneration(request(target,
      'unit invalid\nfunction bad (u :: Unit) -> UInt8 is 300 end function\nend unit'));
    assert.ok(result.diagnostics.length > 0,target);
    assert.deepEqual(result.files ?? [],[],target);
  }
});

test('HCL rejects numeric and textual representations that would silently lose information', async () => {
  for(const content of ['unit exact\nvalue :: Unit -> Integer\nend unit',
    'unit exact\nfunction value (u :: Unit) -> Text is "e\u0301" end function\nend unit',
    'unit exact\nfunction value (u :: Unit) -> Text is "\u{1fae9}" end function\nend unit']) {
    const result = await compiler.planGeneration(request('hcl',content));
    assert.ok(result.diagnostics.some(d => d.code === 'target-unsupported'));
  }
});

for(const target of artifactTargets) test(`${target}: CLI initialization, doctor and generation use the public interface`, async t => {
  const root = await mkdtemp(path.join(os.tmpdir(),'lawspec-artifact-cli-'));
  t.after(() => rm(root,{recursive:true,force:true}));
  const cli = path.resolve(import.meta.dirname,'../bin/lawspec.mjs');
  const run = args => exec(process.execPath,[cli,...args],{cwd:root,maxBuffer:8*1024*1024});
  await run(['init','--target',target]);
  assert.match((await run(['doctor'])).stdout,/generation ready/u);
  const generated = JSON.parse((await run(['generate','--json'])).stdout);
  assert.equal(generated[0].test,null);
  assert.doesNotMatch((await run(['generate','--check'])).stdout,/undefined/u);
  const config = JSON.parse(await readFile(path.join(root,'lawspec.json'),'utf8'));
  assert.equal(config.targets[0].language,target);
  const expected = {hcl:'variables.tf',yaml:'configuration.yaml',antlr4:'LawSpecData.g4',make:'Makefile'}[target];
  assert.ok((await readFile(path.join(root,expected),'utf8')).length > 0);
  await assert.rejects(run(['test','--target',target]),error => /cannot execute application laws/u.test(error.stderr));
  await assert.rejects(run(['examples','--target',target]),error => /examples exports program targets/u.test(error.stderr));
});
