import assert from 'node:assert/strict';
import {test} from 'node:test';
import {existsSync} from 'node:fs';
import {mkdtemp,mkdir,readFile,writeFile,symlink,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {createCompiler} from '../api.mjs';

const dependencies=new URL('../../.integration/javascript/node_modules',import.meta.url).pathname;
const source=`unit guide.failures

type PaymentError is one of
  | Declined of type record{message :: Text}
  | Blocked
  | TooLarge of type Int32
end type
procedure charge (cents :: Int32) -> Int32 fails with PaymentError is
  if cents > 100000 then raise (TooLarge 100000) else
    if cents < 0 then raise (Declined record{message = "a negative amount"}) else cents end if
  end if
end procedure
law tooLarge is
  definition: for all (cents :: Int32 where cents > 100000) => charge cents fails with TooLarge _ end for all end definition
end law
law declined is
  definition: for all (cents :: Int32 where cents < 0) =>
    charge cents fails with Declined record{message = _} message contains "negative"
  end for all end definition
  example minusOne:
    cents = -1
    expect charge cents fails with Declined _
    expect not (charge cents fails with Blocked)
  end example
end law

end unit
`;

test('generated typed failure messages execute real properties and examples and reject a changed native message',
  {skip:!existsSync(path.join(dependencies,'fast-check'))&&'requires the JavaScript acceptance dependencies'},async()=>{
    const compiler=await createCompiler(),result=await compiler.planGeneration({schemaVersion:5,languageProfile:'1.0-rc.2',
      verification:{layers:['property','examples']},target:'javascript',sources:[{path:'failures.lawspec',content:source}]});
    assert.deepEqual(result.diagnostics,[]);
    const root=await mkdtemp(path.join(tmpdir(),'lawspec-failure-messages-'));
    try{
      for(const file of result.files){const destination=path.join(root,file.path);await mkdir(path.dirname(destination),{recursive:true});await writeFile(destination,file.content);}
      await writeFile(path.join(root,'package.json'),JSON.stringify({type:'module'}));
      await symlink(dependencies,path.join(root,'node_modules'),'dir');
      const env={...process.env,LAWSPEC_SEED:'42'};delete env.NODE_TEST_CONTEXT;
      const run=()=>spawnSync(process.execPath,['--test','test/guide_failures.lawspec.test.mjs'],{cwd:root,env,encoding:'utf8'});
      const correct=run();assert.equal(correct.status,0,correct.stdout+correct.stderr);
      assert.match(correct.stdout,/declined property/);
      assert.match(correct.stdout,/example: minusOne/);
      const needle="'a negative amount'",models=result.files.filter(file=>file.path.startsWith('src/')&&file.content.includes(needle));
      assert.equal(models.length,1,'one checked model owns the failure message');
      const model=path.join(root,models[0].path),original=await readFile(model,'utf8');
      assert.equal(original.split(needle).length,2);
      await writeFile(model,original.replace(needle,"'unrelated'"));
      const wrong=run();assert.notEqual(wrong.status,0);
      assert.match(wrong.stdout,/declined property/);
      await writeFile(model,original);
      const restored=run();assert.equal(restored.status,0,restored.stdout+restored.stderr);
    }finally{await rm(root,{recursive:true,force:true});}
  });
