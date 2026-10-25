import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {artifactKey} from '../../tools/ci-artifact-key.mjs';

test('CI artifact keys isolate unrelated fixtures and bind the archive, compiler and execution context',async()=>{
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-artifact-key-'));
  try {
    const sdk=path.join(root,'npm');
    await mkdir(path.join(sdk,'bin'),{recursive:true});
    await mkdir(path.join(sdk,'test'));
    await mkdir(path.join(root,'test/fixtures/beam'),{recursive:true});
    await writeFile(path.join(root,'README.md'),'the public readme\n');
    await writeFile(path.join(root,'CHANGELOG.md'),'the public changes\n');
    await writeFile(path.join(sdk,'api.mjs'),'export const checked = true;\n');
    await writeFile(path.join(sdk,'core.wasm'),Buffer.from([0,97,115,109]));
    await writeFile(path.join(sdk,'package.json'),JSON.stringify({name:'lawspec-key-fixture',version:'0.0.1',
      files:['*.mjs','core.wasm','README.md','CHANGELOG.md'],scripts:{prepack:
        'node -e "for(const f of [\'README.md\',\'CHANGELOG.md\'])require(\'node:fs\').copyFileSync(\'../\'+f,f)"'}}));
    const native=path.join(root,'native-core');await writeFile(native,'native compiler one');
    const options={root,nativeCompiler:native,probe:async command=>command.join(' ')+': pinned version'};
    const smoke=await artifactKey('package-smoke',options),parity=await artifactKey('parity',options);
    await writeFile(path.join(root,'test/fixtures/beam/schedule.exs'),'a new scheduling fixture\n');
    await writeFile(path.join(sdk,'test/assertions.mjs'),'new unshipped assertions\n');
    assert.deepEqual(await artifactKey('package-smoke',options),smoke);
    assert.deepEqual(await artifactKey('parity',options),parity);
    await writeFile(path.join(root,'README.md'),'the revised public readme\n');
    assert.notEqual((await artifactKey('package-smoke',options)).archive,smoke.archive);
    assert.deepEqual(await artifactKey('parity',options),parity);
    const beforeSource=await artifactKey('package-smoke',options);
    await writeFile(path.join(sdk,'api.mjs'),'export const checked = false;\n');
    assert.notEqual((await artifactKey('package-smoke',options)).archive,beforeSource.archive);
    assert.notDeepEqual(await artifactKey('parity',options),parity);
    const beforeWasm=await artifactKey('parity',options);
    await writeFile(path.join(sdk,'core.wasm'),Buffer.from([0,97,115,109,1]));
    assert.notDeepEqual(await artifactKey('parity',options),beforeWasm);
    const beforeNative=await artifactKey('parity',options);
    await writeFile(native,'native compiler two');
    assert.notDeepEqual(await artifactKey('parity',options),beforeNative);
    const beforeFlags=await artifactKey('package-smoke',options);
    const flags={...options,environment:{...process.env,RUSTFLAGS:'--cfg lawspec_cache_probe'}};
    assert.equal((await artifactKey('package-smoke',flags)).archive,beforeFlags.archive);
    assert.notDeepEqual(await artifactKey('package-smoke',flags),beforeFlags);
    const manifestPath=path.join(sdk,'package.json');
    const manifest=JSON.parse(await readFile(manifestPath,'utf8'));
    manifest.dependencies={'lawspec-key-dependency':'1.0.0'};
    await writeFile(manifestPath,JSON.stringify(manifest));
    const dependency=path.join(sdk,'node_modules/lawspec-key-dependency');
    await mkdir(dependency,{recursive:true});
    await writeFile(path.join(dependency,'package.json'),JSON.stringify({name:'lawspec-key-dependency',version:'1.0.0',main:'index.js'}));
    await writeFile(path.join(dependency,'index.js'),'module.exports = 1;');
    const beforeDependency=await artifactKey('package-smoke',options);
    await writeFile(path.join(dependency,'index.js'),'module.exports = 2;');
    const afterDependency=await artifactKey('package-smoke',options);
    assert.equal(afterDependency.archive,beforeDependency.archive);
    assert.notEqual(afterDependency.context,beforeDependency.context);
    await assert.rejects(artifactKey('package-smoke',{...options,probe:async()=>{throw new Error('tool unavailable');}}),/tool unavailable/);
    assert.equal(await readFile(path.join(root,'test/fixtures/beam/schedule.exs'),'utf8'),'a new scheduling fixture\n');
  } finally {await rm(root,{recursive:true,force:true});}
});
