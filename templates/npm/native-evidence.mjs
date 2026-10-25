import {readFile} from 'node:fs/promises';
import {isDeepStrictEqual} from 'node:util';
import path from 'node:path';
import {doctor} from './doctor.mjs';
import {planWrites} from './files.mjs';
import {projectKey} from './failure-database.mjs';
import {lawKeys,presentationDigest,environmentDigest,recordedDigest,projectDigest,invocations} from './test-command.mjs';

// Native execution observations are scoped to actual completed test slots.
// They never establish a universal model proof or a witness-search completeness claim.
export const obligationTargets = entry => entry.obligations ?? [{declaration:entry.law,stage:'law'}];

export function nativeSeed(value){
  const text=String(value),number=Number(text);
  if(!/^[0-9]+$/.test(text))throw new Error('A native seed must be a whole number');
  if(typeof value==='number'&&!Number.isSafeInteger(value))
    throw new Error('The recorded numeric seed lost precision; rerun with an explicit exact seed');
  return Number.isSafeInteger(number)?number:text;
}

export function recordNativeAttempts(run, tests, {keys,seed,ok,profile,output,allEntries=run.laws,at=new Date().toISOString()}) {
  return Object.fromEntries((run.laws??[]).map(entry=>{
    const matched=tests.filter(test=>(run.matches?.(test)??[]).includes(entry));
    const model=(entry.obligations?.length??0)>0;
    const complete=matched.length>0&&matched.every(test=>test.status==='passed')&&(ok||model);
    const outcome=matched.some(test=>test.status==='failed')?'failed':
      matched.some(test=>test.status==='incomplete')?'incomplete':
      entry.skip?'skipped':complete?(entry.knownDiscrepancy?'known-discrepancy':'passed'):
      matched.length&&matched.every(test=>test.status==='skipped')?'skipped':'incomplete';
    return [entry.law,{key:keys.get(entry.law),planKey:entry.key,seed:nativeSeed(seed),at,outcome,
      profile,coverage:entry.coverage??{kind:'sampled',scopedQuantifiers:true},check:{id:entry.law,unit:entry.unit,file:entry.file,name:entry.name,label:entry.label,
        ...(entry.scope?{scope:entry.scope}:{}),obligations:obligationTargets(entry),
        nativeGroup:(allEntries??[]).filter(other=>other.file===entry.file&&other.name===entry.name&&other.scope===entry.scope)
          .map(other=>other.law)},
      // A passed combined method covers all its logical model aliases. A failed
      // combined method completes none successfully, even if another method passed.
      tests:matched,invocation:{ok,command:run.command,
        ...(!ok&&['failed','incomplete'].includes(outcome)&&output&&
          !matched.some(test=>test.status==='failed'&&(test.failure||test.reason||test.message))?{output}: {})},
      verification:'native-execution',searchCompleteness:'not-established'}];
  }));
}

// A law an attestation touches is keyed by how its dependencies were wired:
// endpoint, kind, and a stand-in's product, version and conformance. What the
// run observed (reached, history digests, completion) and the identities
// reported beside it are not inputs, so they change no key.
export function attestedKeys(result) {
  const wiring=d=>[d.dependency,d.endpoint,d.kind,
    ...(d.implementation?[[d.implementation.kind,d.implementation.product,d.implementation.version,
      d.implementation.commit??null,d.implementation.digest??null]]:[]),
    ...(d.standIn?[d.standIn.identity,d.standIn.version,d.standIn.conformance]:[])];
  return new Map((result.evidence??[]).filter(item=>item.against||item.plannedAgainst)
    .map(item=>[item.declaration,JSON.stringify([
      item.environment??item.plannedEnvironment,(item.against??item.plannedAgainst).map(wiring)])]));
}

const subject = (entry,item) => obligationTargets(entry).some(target=>
  target.declaration===item.declaration&&target.stage===item.stage);
const runtimeStages=new Set(['law','model','linearizable','sequentially consistent','causally consistent',
  'eventually consistent','restart','scenario','supervision']);

// Display archived observations in the current vocabulary; retain their raw
// attempts and use those original values for freshness and completion checks.
const observationOutcome=outcome=>outcome==='known-discrepancy'?'known-discrepancy':outcome;

// Only observations with matching current compiler/configuration/source/native
// inputs are eligible for completed evidence. A stored timestamp alone is not.
export async function readNativeObservations({compiler,input,selected,roots,configRoot,build,evidence,attestation}) {
  const records=await Promise.all(selected.map(async(target,index)=>{
    const root=roots[index],file=path.join(configRoot,'.lawspec/results',`${target.language}-${projectKey(root)}.json`);
    const record=JSON.parse(await readFile(file,'utf8').catch(error=>{
      if(error.code==='ENOENT')return '{}';throw error;
    }));
    return {target,root,attempts:record.attempts??{},runs:record.laws??{},presentation:record.presentation,attestations:record.attestations??{}};
  }));
  if(!records.some(record=>Object.keys(record.attempts).length))return [];
  const observations=[];
  for(const {target,root,attempts,runs,presentation,attestations}of records){
    const plans=new Map(),contexts=new Map();
    // An attempt is keyed by the wiring of the attestation it ran under: the
    // one named now, or else the one lawspec test stored for its run.
    const wiredBy=attempt=>attestation??(attempt?.environment?attestations[attempt.environment]:undefined);
    const slot=(minify,wired)=>`${minify}\0${wired?.run?.id??''}`;
    async function plan(minify,wired=attestation){
      const key=slot(minify,wired);
      if(!plans.has(key))plans.set(key,await compiler.planGeneration({...input,target:target.language,
        sourceDir:target.sourceDir,testDir:target.testDir,nativeBindings:target.nativeBindings,minify,
        ...(wired?{attestation:wired}:{})}));
      return plans.get(key);
    }
    const modes=[...new Set(Object.values(attempts).map(attempt=>attempt.profile?.minify)
      .filter(mode=>typeof mode==='boolean'))];
    if(!modes.length)modes.push(false);
    const base=await plan(modes[0]);
    if(base.diagnostics.length){
      observations.push({target:target.language,root,freshness:'unavailable',outcome:'incomplete',
        obligations:evidence.filter(item=>runtimeStages.has(item.stage)).map(({declaration,stage})=>({declaration,stage})),
        reason:'Native generation is unavailable: '+base.diagnostics.map(diagnostic=>diagnostic.message).join('; ')});
      continue;
    }
    const expected=new Map(base.tests.map(entry=>[entry.law,entry]));
    async function context(minify,wired){
      const key=slot(minify,wired);
      if(contexts.has(key))return contexts.get(key);
      const generated=await plan(minify,wired);
      let result;
      if(generated.diagnostics.length)result={reason:'Native generation is unavailable for the recorded layout'};
      else {
        const pending=await planWrites(root,generated.files);
        if(pending.changes.length)result={stale:true,reason:'Generated files differ from the recorded/current plan'};
        else {
          const report=await doctor(target,root,generated.files);
          if(!report.ok)result={reason:'The current native environment could not be checked: '+report.message};
          else {
            const environment=await environmentDigest(root,report,target.language);
            if(presentation!==presentationDigest(generated.files,environment)){
              result={reason:'Current generated presentation has not passed native validation; run lawspec test'};
              contexts.set(key,result);return result;
            }
            const owned=new Set(generated.files.filter(file=>file.ownership==='generated').map(file=>file.path));
            const keys=lawKeys({build,target,machineBits:input.machineBits,minify,tests:generated.tests,files:generated.files,
              environment,recorded:await recordedDigest(path.join(configRoot,'recorded')),
              project:await projectDigest(root,owned,target.language),attested:attestedKeys(generated)});
            result={generated,keys};
          }
        }
      }
      contexts.set(key,result);return result;
    }
    for(const [id,baseline]of expected){
      let attempt=attempts[id],reuse;
      if(!attempt)for(const original of Object.values(attempts)){
        // Only a single ordinary-law observation can be re-associated here.
        // Combined model methods keep their exact group identities.
        if(original.outcome!=='passed'||original.check?.nativeGroup?.length!==1||
          !isDeepStrictEqual(original.check.obligations,[{declaration:original.check.id,stage:'law'}])||
          !isDeepStrictEqual(obligationTargets(baseline),[{declaration:id,stage:'law'}]))continue;
        let candidate=await context(original.profile?.minify??false,wiredBy(original));
        if(candidate.reason&&candidate.stale)candidate=await context(!original.profile?.minify,wiredBy(original));
        if(!candidate.reason&&candidate.keys.get(id)===original.key&&baseline.key===original.planKey){
          attempt=original;reuse={check:original.check.id,key:original.key,at:original.at};break;
        }
      }
      const row={target:target.language,root,check:{id,obligations:obligationTargets(baseline)},
        outcome:observationOutcome(attempt?.outcome??'not-run'),coverage:baseline.coverage,attempt};
      if(!attempt){observations.push({...row,freshness:'not-run',reason:'No completed native observation was recorded'});continue;}
      const profile=attempt.profile??{};
      if(profile.target!==target.language||profile.root!==root||profile.machineBits!==input.machineBits||profile.build!==build||
        typeof profile.minify!=='boolean'){
        observations.push({...row,freshness:'stale',reason:'Compiler, target or machine profile differs'});continue;
      }
      let current=await context(profile.minify,wiredBy(attempt));
      // Layout belongs to the artifact, not to the meaning of its old run.
      // Accept the other canonical layout only when it exactly matches disk.
      if(current.reason&&current.stale)current=await context(!profile.minify,wiredBy(attempt));
      if(current.reason){observations.push({...row,freshness:current.stale?'stale':'unavailable',reason:current.reason});continue;}
      const entry=current.generated.tests.find(entry=>entry.law===id);
      if(!entry||attempt.key!==current.keys.get(id)||attempt.planKey!==entry.key||
        (!reuse&&!isDeepStrictEqual(attempt.check?.obligations,obligationTargets(entry)))||
        !isDeepStrictEqual(attempt.coverage,entry.coverage)){
        observations.push({...row,freshness:'stale',reason:'Specification, selection, bindings, native source or toolchain inputs differ'});continue;
      }
      const observedEntry=reuse?{...entry,...attempt.check,law:attempt.check.id,key:attempt.planKey}:entry;
      const invocation=invocations(target,[observedEntry],{root}).find(run=>run.laws?.includes(observedEntry));
      const observedKeys=reuse?new Map([[observedEntry.law,attempt.key]]):current.keys;
      const validSeed=(typeof attempt.seed==='number'&&Number.isSafeInteger(attempt.seed)&&attempt.seed>=0)||
        (typeof attempt.seed==='string'&&/^[0-9]+$/.test(attempt.seed));
      const recomputed=validSeed&&Number.isFinite(Date.parse(attempt.at))&&invocation&&Array.isArray(attempt.tests)&&recordNativeAttempts(invocation,attempt.tests,
        {keys:observedKeys,seed:attempt.seed,ok:attempt.invocation?.ok===true,profile,at:attempt.at,
          allEntries:reuse?[observedEntry]:current.generated.tests})[observedEntry.law];
      if(!recomputed||recomputed.outcome!==attempt.outcome||
        !isDeepStrictEqual(recomputed.check.nativeGroup,attempt.check?.nativeGroup)){
        observations.push({...row,freshness:'unavailable',reason:'The stored observation does not establish the current native completion'});continue;
      }
      const run=runs[id];
      observations.push({...row,freshness:'matching-inputs',...(reuse?{reused:reuse}:{}),
        ...(attempt.outcome==='passed'&&run?.key===attempt.key&&(run.flaky||run.adequacy)?
          {harness:{...(run.flaky?{flaky:true}:{}),...(run.adequacy?{adequacy:run.adequacy}:{})}}:{}),
        reason:reuse?'Original native completion reused for the current semantic law; no fresh invocation is claimed':attempt.outcome==='passed'?'Recorded native completion matches the current inputs':'Recorded native attempt matches the current inputs'});
    }
    for(const [id,attempt]of Object.entries(attempts))if(!expected.has(id)&&Array.isArray(attempt.check?.obligations))
      observations.push({target:target.language,root,check:attempt.check,attempt,outcome:observationOutcome(attempt.outcome),
        coverage:attempt.coverage,freshness:'not-selected',reason:'This native check is not selected by the current configuration'});
  }
  return observations;
}

export function attachNativeEvidence(evidence,observations){
  return evidence.map(item=>{
    const rows=observations.filter(row=>row.check?subject({obligations:row.check.obligations},item):
      row.obligations?.some(target=>target.declaration===item.declaration&&target.stage===item.stage));
    if(!rows.length)return item;
    const current=rows.filter(row=>row.freshness==='matching-inputs');
    const failed=current.filter(row=>row.outcome==='failed');
    const combinedFailure=failed.some(row=>(row.attempt?.check.nativeGroup?.length??0)>1);
    const status=failed.length?(combinedFailure?'incomplete':'failed'):
      current.length===rows.length&&current.every(row=>row.outcome==='passed')?'passed':
      current.length===rows.length&&current.every(row=>row.outcome==='skipped')?'skipped':
      current.length===rows.length&&current.every(row=>row.outcome==='known-discrepancy')?'known-discrepancy':
      current.some(row=>row.outcome==='passed')?'partial':
      current.some(row=>['incomplete','not-run'].includes(row.outcome))?'incomplete':
      rows.every(row=>row.freshness==='not-selected')?'not-selected':
      rows.some(row=>row.freshness==='stale')?'stale':'unavailable';
    const completeFinite=status==='passed'&&rows.every(row=>row.coverage?.kind==='finite-inputs'&&
      row.coverage.scopedQuantifiers===false);
    const nativeEvidence={kind:'native-conformance',status,
      searchCompleteness:completeFinite?'complete-finite-inputs':'not-established',observations:rows};
    const adequacy=current.flatMap(row=>row.harness?.adequacy??[]);
    const enriched={...item,nativeEvidence,...(adequacy.length?{adequacy}:{})};
    if(item.status!=='planned')return enriched;
    const flaky=current.some(row=>row.harness?.flaky);
    if(status==='passed')return {...enriched,plannedEvidence:{status:item.status,reason:item.reason},
      status:flaky?'flaky':completeFinite?'exhaustively-checked':'property-tested',
      reason:`Recorded native checks completed for ${new Set(rows.map(row=>row.target+'\0'+row.root)).size} requested target(s); `+
        (completeFinite?'every finite input was checked.':'this is scoped native execution evidence, not a universal model or search proof.')+
        (flaky?' Its last run failed, then passed on a retry.':'')};
    if(['failed','incomplete'].includes(status))return {...enriched,
      plannedEvidence:{status:item.status,reason:item.reason},status:'incomplete',
      reason:combinedFailure?'A combined native method failed; the specific included logical check is not identified, and no successful conformance result is established.':
        status==='failed'?'A recorded native implementation check failed; no successful conformance result is established.':
          'Native execution did not complete all selected checks; no successful conformance result is established.'};
    return enriched;
  });
}

// Native conformance a law's evidence row carries, for lawspec evidence.
export function nativeEvidenceText(item){
  if(!item.nativeEvidence)return '';
  const summary=item.nativeEvidence;
  return [`Native conformance: ${summary.status}; search completeness: ${summary.searchCompleteness}`,
    ...summary.observations.map(row=>`${row.target} (${row.root}): ${row.outcome}; ${row.freshness}`+
      (row.attempt?`; seed ${row.attempt.seed}; ${row.attempt.at}`:'')+`; ${row.reason}`),
    ...summary.observations.flatMap(row=>(row.attempt?.tests??[]).filter(test=>test.status==='failed')
      .map(test=>`${test.name}: ${test.reason??test.failure??test.message??'native test failed'}`)),
    ...summary.observations.filter(row=>row.attempt?.invocation.output)
      .map(row=>'Native invocation output (scoped to that invocation):\n'+row.attempt.invocation.output)].join('\n');
}
