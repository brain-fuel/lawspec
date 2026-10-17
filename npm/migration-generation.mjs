// Generated from templates/npm/migration-generation.mjs by lawspec-dev generate. Do not edit.
// Generation is an independent migration gate. A compiler's accepted emission
// receipt never means that a target compiler or an external implementation ran.
import {bindingDigest,checkBindingProposal} from './migration-bindings.mjs';

const pending=reason=>({status:'not-established',reason});
const digest=value=>typeof value==='string'&&/^[0-9a-f]{64}$/.test(value);
const sourceInputs=input=>Object.fromEntries(['sources','packages','package','dependencies']
  .filter(key=>input[key]!==undefined).map(key=>[key,input[key]]));
const safePath=value=>typeof value==='string'&&value.length>0&&!/[\\\0]/.test(value)&&
  value.split('/').every(part=>part&&part!=='.'&&part!=='..')&&!/^[A-Za-z]:/.test(value);
const acceptedSide=side=>side?.status==='accepted'&&Array.isArray(side.diagnostics)&&side.diagnostics.length===0&&
  Array.isArray(side.files)&&side.files.length>0&&side.files.every(file=>file&&safePath(file.path)&&
    ['user','generated'].includes(file.ownership)&&['source','test'].includes(file.placement)&&
    Object.keys(file).every(key=>['path','ownership','placement','contentDigest','adapterReferenceDigest'].includes(key))&&
    digest(file.contentDigest)&&(file.adapterReferenceDigest===undefined||digest(file.adapterReferenceDigest)))&&
  new Set(side.files.map(file=>file.path)).size===side.files.length&&digest(side.artifactDigest)&&
  bindingDigest(side.files)===side.artifactDigest;

export function checkGenerationReceipt(before,after,request,bindingProposal,evidence){
  if(!request?.migrated||!request.generation||!evidence?.generation)
    return pending('A complete generation request and receipt are required.');
  const proposal=evidence?.bindingProposal;
  const binding=checkBindingProposal(before,after,request.nativeBindings,request.target,proposal);
  if(binding.status!=='matched'||bindingDigest(proposal)!==bindingDigest(bindingProposal))
    return pending('Generation does not carry the matching checked binding proposal.');
  if(evidence?.version!==1||evidence.algorithm!=='sha256'||evidence.target!==request.target||
    evidence.machineBits!==(request.machineBits??64)||evidence.sourceDir!==(request.sourceDir??null)||
    evidence.testDir!==(request.testDir??null)||evidence.minify!==(request.minify??false)||
    bindingDigest(evidence.generation)!==bindingDigest(request.generation)||evidence.planning!=='legacy-harnesses'||
    evidence.sourceInputs?.before!==bindingDigest(sourceInputs(request))||
    evidence.sourceInputs?.after!==bindingDigest(sourceInputs(request.migrated))||
    evidence.nativeConformance!=='not-established'||evidence.lawVerification!=='not-established-by-generation')
    return pending('Generation receipt does not match these exact sources, dependencies, target, width, layout and limits.');
  if(evidence.status!=='accepted'||!acceptedSide(evidence.before)||!acceptedSide(evidence.after)){
    const failures=['before','after'].flatMap(side=>evidence[side]?.diagnostics?.map(item=>`${side}: ${item.code}: ${item.message}`)??[]);
    return pending(failures.join(' ')||evidence.after?.reason||'Complete target generation was not accepted on both inputs.');
  }
  return {status:'accepted',basis:'compiler-emission-of-both-checked-programs',
    scope:'legacy harness plans and complete artifact manifests; target compilation and native behavior remain separate'};
}

const boundaryAssumptions=['existing compiler emitters',
  'unchanged native implementations under their original binding assumptions'];
const boundaryKeys=['configuration','types','calls','handlers','unboundAdapters','unmappedData'];
const availableBoundary=side=>side?.status==='available'&&side.contract&&
  typeof side.contract==='object'&&!Array.isArray(side.contract)&&
  Object.keys(side.contract).length===boundaryKeys.length&&
  boundaryKeys.every(key=>key==='configuration'?side.contract[key]&&typeof side.contract[key]==='object'&&
    !Array.isArray(side.contract[key]):Array.isArray(side.contract[key]))&&
  digest(side.digest)&&bindingDigest(side.contract)===side.digest;

export function checkNativeBoundaryReceipt(before,after,request,bindingProposal,evidence){
  const generation=checkGenerationReceipt(before,after,request,bindingProposal,evidence);
  if(generation.status!=='accepted')return pending(generation.reason);
  const boundary=evidence.nativeBoundary;
  if(boundary?.version!==1||boundary.algorithm!=='sha256'||boundary.policy!=='resolved-native-contract-v1'||
    boundary.nativeConformance!=='not-established'||
    boundary.lawVerification!=='not-established-by-boundary-correspondence'||
    bindingDigest(boundary.assumptions??null)!==bindingDigest(boundaryAssumptions)||
    !availableBoundary(boundary.before)||!availableBoundary(boundary.after))
    return pending(boundary?.after?.reason||boundary?.before?.reason||
      'A complete resolved native boundary comparison with its original assumptions is required.');
  const configuration={...bindingProposal.proposedNativeBindings,types:[]};
  if(bindingDigest(boundary.after.contract.configuration)!==bindingDigest(configuration)||
    boundary.status!=='matched'||boundary.before.digest!==boundary.after.digest)
    return pending('Resolved native call contracts or generated adapter layouts differ across the migration.');
  return {status:'matched',basis:'compiler-resolved-native-contract-correspondence',
    scope:boundary.scope,assumptions:[...boundaryAssumptions],
    nativeConformance:'not-established',lawVerification:'not-established-by-boundary-correspondence'};
}

export async function planMigrationGeneration(compiler,config,input,sources,before,after,bindingPreview,migratedContext={}){
  const rows=[];
  for(const binding of bindingPreview.targets){
    const target=binding.index===null?input:config.targets[binding.index];
    if(binding.status!=='matched'||!binding.target||typeof compiler.migrationGeneration!=='function'){
      const unavailable=pending(binding.reason||
        'A concrete target, matching binding proposal and generation-capable compiler are required.');
      rows.push({target:binding.target,index:binding.index,...unavailable,nativeBoundary:{...unavailable}});continue;
    }
    const options={...input,schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]},
      target:binding.target,sourceDir:target.sourceDir,testDir:target.testDir,minify:input.minify===true};
    const request={...options,from:'0.24',nativeBindings:binding.evidence.inputBindings,
      migrated:{...options,...migratedContext,sources,nativeBindings:binding.proposedNativeBindings}};
    const result=await compiler.migrationGeneration(request),evidence=result.migrationGeneration;
    const checked=result.diagnostics?.length?pending(result.diagnostics.map(item=>item.message).join(' ')):
      checkGenerationReceipt(before,after,request,binding.evidence,evidence);
    const nativeBoundary=checked.status==='accepted'?
      checkNativeBoundaryReceipt(before,after,request,binding.evidence,evidence):pending(checked.reason);
    rows.push({target:binding.target,index:binding.index,...checked,nativeBoundary,evidence,diagnostics:result.diagnostics??[]});
  }
  const count=bindingPreview.configurationCount;
  return {status:count===0?'not-requested':rows.length===count&&rows.every(row=>row.status==='accepted')?'accepted':'not-established',
    scope:'every configured target; emitted artifacts, not native execution',configurationCount:count,targets:rows,
    nativeBoundary:{status:count===0?'not-requested':rows.length===count&&rows.every(row=>row.nativeBoundary.status==='matched')?
      'matched':'not-established',configurationCount:count,
      scope:'resolved native call contracts and generated adapter layouts under unchanged native implementation assumptions'}};
}
