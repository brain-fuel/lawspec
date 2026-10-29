/** @file Validate the explicit browser host used by generated LawSpec harness code. ref:REQ-learn-tests-in-lawspec */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {harnessHostModules} from '../browser/harness-host.mjs';
import {bundle} from '../browser/bundle.mjs';
import {services, compile, execute, course} from './helpers.mjs';
test('generated harness reports stay in memory and overlapping contexts fail explicitly', async () =>
{
  const modules = {
    ...harnessHostModules(),
    'test/lawspec_harness.mjs': `export {mkdirSync,writeFileSync} from 'node:fs';export {AsyncLocalStorage} from 'node:async_hooks';`,
    'entry.mjs': `import {mkdirSync,writeFileSync,AsyncLocalStorage} from './test/lawspec_harness.mjs';
(async()=>{mkdirSync('/browser-stats');writeFileSync('/browser-stats/test.json','{"cases":100}');let forbidden=false,overlap=false;try{writeFileSync('/outside/source','{}');}catch(error){forbidden=error.code==='LEARN_UNSUPPORTED_HOST';}
const context=new AsyncLocalStorage();let release;const running=context.run('first',async()=>{await new Promise(resolve=>release=resolve);return context.getStore();});try{context.run('second',()=>{});}catch(error){overlap=error.code==='LEARN_UNSUPPORTED_HOST';}release();const value=await running;postMessage({result:{reports:globalThis.__harnessReports,forbidden,overlap,value,cleared:context.getStore()===undefined}});})();`,
  };
  const result = await execute(
    await bundle(services.esbuild, modules, 'entry.mjs', services.readAsset),
  );
  assert.deepEqual(result, {
    reports: [{cases: 100}],
    forbidden: true,
    overlap: true,
    value: 'first',
    cleared: true,
  });
});
test('native LawSpec adequacy writes actual generated-case statistics through the browser reference host', async () =>
{
  const files = {
    'Solution.js': 'export const seats=rows=>rows*4;',
    'Tests.lawspec':
      'unit host.stats\nseats :: Int32 -> Int32\nlaw rule is definition: for all (rows :: Int32 where rows >= 0 and rows <= 40) => seats rows = rows * 4 end for all end definition end law\nend unit\n',
    'Harness.lawspec':
      'harness host.stats.testing for host.stats is\nstrategy rows :: (n :: Int32 where n >= 0 and n <= 40) is any end strategy\nfor law rule\nuse rows for rows\ncover 100% "nonnegative" when rows >= 0\nend for law\nend harness\n',
  };
  const plan = await compile(course.lessons[0], 'javascript', files, 'sample');
  assert.ok(plan.code, JSON.stringify(plan.diagnostics));
  const result = await execute(plan.code);
  assert.equal(result.ok, true, JSON.stringify(result));
  assert.ok(
    result.harnessReports.some(row =>
      JSON.stringify(row).includes('nonnegative'),
    ),
  );
  assert.ok(
    result.harnessReports.some(row => JSON.stringify(row).includes('100')),
  );
});
test('a LawSpec strategy outside the law domain is a visible harness failure and does not run the implementation', async () =>
{
  const files = {
    'Solution.js':
      'export function seats(){throw new Error("implementation should not run");}',
    'Tests.lawspec':
      'unit host.invalid\nseats :: Int32 -> Int32\nlaw rule is definition: for all (n :: Int32 where n >= 0) => seats n = n end for all end definition end law\nend unit\n',
    'Harness.lawspec':
      'harness host.invalid.testing for host.invalid is\nstrategy bad :: Int32 is one of -1 end strategy\nfor law rule\nuse bad for n\nend for law\nend harness\n',
  };
  const plan = await compile(course.lessons[0], 'javascript', files, 'sample');
  assert.ok(plan.code, JSON.stringify(plan.diagnostics));
  const result = await execute(plan.code);
  assert.equal(result.ok, false);
  assert.match(result.sampled.error, /outside the input/);
  assert.ok(result.sampled.observations.every(row => row.calls.length === 0));
});
