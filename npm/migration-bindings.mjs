// Generated from templates/npm/migration-bindings.mjs by lawspec-dev generate. Do not edit.
// Native configuration correspondence is independent of external execution.
// The compiler owns payload adaptation and native binding resolution.
import {targets} from './templates.mjs';
import {createHash} from 'node:crypto';

const fingerprints=['programDigest','definitionPlaneDigest','lawBodiesDigest'];
const templates=['declarationsDigest','definitionTemplatesDigest','lawTemplatesDigest','lawBodiesDigest'];
const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'
  ?Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])):value;
const bindingDigest=value=>createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
const digest=value=>typeof value==='string'&&/^[0-9a-f]{64}$/.test(value);
const equal=(a,b)=>{
  if(a===b)return true;
  if(!a||!b||typeof a!=='object'||typeof b!=='object'||Array.isArray(a)!==Array.isArray(b))return false;
  const left=Object.keys(a).sort(),right=Object.keys(b).sort();
  return left.length===right.length&&left.every((key,i)=>key===right[i]&&equal(a[key],b[key]));
};
const pending=reason=>({status:'not-established',reason});
const bindingObligations=rows=>Array.isArray(rows)&&rows.every(row=>row&&typeof row.owner==='string'&&
  typeof row.declaration==='string'&&row.claim===null&&
  (row.stage==='binding' ? row.status==='runtime-checked' :
    ['codec','generator','native-function'].includes(row.stage)&&row.status==='assumed'));


export function checkBindingProposal(before,after,requested,target,evidence) {
  if(evidence?.status==='unavailable'&&typeof evidence.reason==='string')return pending(evidence.reason);
  const unavailable='The compiler did not return a complete binding proposal for these sources, bindings, target and machine width.';
  if(before?.status!=='available'||after?.status!=='available'||before.machineBits!==after.machineBits||
      evidence?.version!==1||evidence.algorithm!=='sha256'||evidence.target!==target||
      evidence.machineBits!==before.machineBits||evidence.originalsUnchanged!==true||
      !equal(evidence.inputBindings,requested??{})||
      !fingerprints.every(field=>digest(before[field])&&digest(after[field])&&
        evidence.before?.[field]===before[field]&&evidence.after?.[field]===after[field])||
      !templates.every(field=>digest(before.sourceTemplates?.[field])&&digest(after.sourceTemplates?.[field])&&
        evidence.sourceTemplates?.before?.[field]===before.sourceTemplates[field]&&
        evidence.sourceTemplates?.after?.[field]===after.sourceTemplates[field])) return pending(unavailable);
  if(evidence.obligations?.status!=='matched'||!bindingObligations(evidence.obligations.before)||
      !equal(evidence.obligations.before,evidence.obligations.after)||
      evidence.status!=='matched'||evidence.beforeValidated!==true||evidence.afterValidated!==true||
      evidence.proposalComplete!==true||evidence.bindings?.status!=='matched'||
      !digest(evidence.originalBindingsDigest)||!digest(evidence.bindings.before)||evidence.bindings.before!==evidence.bindings.after||
      !evidence.proposedNativeBindings||typeof evidence.proposedNativeBindings!=='object'||
      Array.isArray(evidence.proposedNativeBindings)||!Array.isArray(evidence.requirements)||evidence.requirements.length||
      evidence.nativeConformance!=='not-established'||evidence.targetGeneration!=='not-established'||
      evidence.lawVerification!=='not-established-by-binding-correspondence'||
      bindingDigest(evidence.proposedNativeBindings)!==evidence.bindings.after)
    return pending(evidence.requirements?.join(' ')||evidence.reason||'Native binding adaptation remains incomplete.');
  return {status:'matched',basis:'compiler-checked-native-binding-proposal',
    scope:'explicit binding configuration; external behavior and generated APIs remain separate'};
}

export async function planNativeBindings(compiler,config,input,sources,before,after) {
  const scopes=config.targets.map((target,index)=>({target,index,language:target.language,
    bindings:target.nativeBindings}));
  if(input.nativeBindings!==undefined)
    scopes.push({index:null,language:input.target??'',bindings:input.nativeBindings});
  const rows=[];
  for(const scope of scopes) {
    const {language,bindings,index}=scope;
    if(language&&!targets.includes(language)) {
      rows.push({target:language,index,...pending('Unknown migration target: '+language)});continue;
    }
    if(typeof compiler.migrationBindings!=='function') {
      rows.push({target:language,index,...pending('This compiler does not expose checked native binding migration.')});continue;
    }
    const options={...input,schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
    const {nativeBindings:ignored,...canonical}=options;
    const result=await compiler.migrationBindings({...options,from:'0.24',target:language,
      nativeBindings:bindings??{},migrated:{...canonical,sources}});
    const evidence=result.migrationBindings;
    const checked=result.diagnostics?.length ? pending(result.diagnostics.map(item=>item.message).join(' ')) :
      checkBindingProposal(before,after,bindings,language,evidence);
    rows.push({target:language,index,...checked,evidence,
      diagnostics:result.diagnostics??[],...(checked.status==='matched'?{proposedNativeBindings:evidence.proposedNativeBindings}:{})});
  }
  const matched=rows.every(row=>row.status==='matched');
  return {status:matched?'matched':'not-established',
    scope:'every configured explicit native binding request; native execution and generated APIs remain separate',
    configurationCount:rows.length,targets:rows,
    proposedTargets:config.targets.map((target,index)=>{
      const row=rows.find(row=>row.index===index);
      return row?.status==='matched'&&target.nativeBindings!==undefined
        ? {...target,nativeBindings:row.proposedNativeBindings}:{...target};
    })};
}
