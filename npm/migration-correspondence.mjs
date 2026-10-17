// Generated from templates/npm/migration-correspondence.mjs by lawspec-dev generate. Do not edit.
// These fingerprints cover the compiler's complete typed Core, not the
// smaller documentary JSON views. They establish no unrun law verification.
const digest=/^[0-9a-f]{64}$/;
const components=[['programDigest','program'],['definitionPlaneDigest','definitionPlane'],['lawBodiesDigest','lawBodies']];
const parts=['definitions','contracts','dataTypes'];
const templateComponents=[['declarationsDigest','declarations'],['definitionTemplatesDigest','definitions'],
  ['lawTemplatesDigest','laws'],['lawBodiesDigest','lawBodies']];

function rowsValid(rows,policies=false) {
  return Array.isArray(rows)&&rows.every(item=>item&&typeof item.comparisonId==='string'&&
    (policies?['nonempty','universal'].includes(item.policy)&&
      (item.formalParameterCount===undefined||Number.isSafeInteger(item.formalParameterCount)&&item.formalParameterCount>=0):
      typeof item.digest==='string'&&digest.test(item.digest)))&&
    new Set(rows.map(item=>item.comparisonId)).size===rows.length;
}

function differences(before,after,names) {
  return Object.fromEntries(names.map(name=>{
    const original=new Map(before[name].map(item=>[item.comparisonId,item.digest]));
    const migrated=new Map(after[name].map(item=>[item.comparisonId,item.digest]));
    return [name,{added:[...migrated.keys()].filter(id=>!original.has(id)),
      removed:[...original.keys()].filter(id=>!migrated.has(id)),
      changed:[...original.keys()].filter(id=>migrated.has(id)&&original.get(id)!==migrated.get(id))}];
  }));
}

function checkedDefinitionTemplates(before,after,evidence,machineBits) {
  if(evidence?.status!=='matched'||evidence.version!==1||evidence.algorithm!=='sha256'||
    evidence.machineBits!==machineBits||evidence.originalsUnchanged!==true||
    !templateComponents.every(([field])=>evidence.before?.[field]===before[field]&&evidence.after?.[field]===after[field])) return false;
  const headers=evidence.interfaces,core=evidence.typedCore;
  if(headers?.status!=='matched'||typeof headers.before!=='string'||!digest.test(headers.before)||headers.before!==headers.after||
    core?.status!=='matched'||core.version!==1||core.algorithm!=='sha256'||core.machineBits!==machineBits||
    core.copyValidated!==true||core.originalsUnchanged!==true||
    typeof core.sourceBeforeDigest!=='string'||!digest.test(core.sourceBeforeDigest)||
    !available(core.before)||!available(core.after)||core.before.machineBits!==machineBits||core.after.machineBits!==machineBits||
    core.before.domainPolicies.length!==0||core.after.domainPolicies.length!==0) return false;
  return components.every(([field,name])=>core[name]?.status==='matched'&&
    core[name].before===core.before[field]&&core[name].after===core.after[field]&&core[name].before===core[name].after);
}

function anchoredTemplates(before,after,evidence,machineBits) {
  return evidence?.status==='matched'&&evidence.version===1&&evidence.algorithm==='sha256'&&
    evidence.machineBits===machineBits&&evidence.originalsUnchanged===true&&
    templateComponents.every(([field])=>evidence.before?.[field]===before[field]&&evidence.after?.[field]===after[field]);
}

function matchingPair(pair) {
  return pair?.status==='matched'&&typeof pair.before==='string'&&digest.test(pair.before)&&pair.before===pair.after;
}

function templateCoreIdentity(id) {
  const split=id.indexOf('::law::');
  return split<0?id:id.slice(0,split+7)+id.slice(split+7).replace(/[:%]/g,char=>char===':'?'%3A':'%25');
}

function checkedLawTemplates(before,after,evidence,machineBits) {
  if(!anchoredTemplates(before,after,evidence,machineBits)||!matchingPair(evidence.metadata)||
    evidence.lawBodiesEvaluated!==false) return false;
  const core=evidence.typedCore;
  if(core?.status!=='matched'||core.version!==1||core.algorithm!=='sha256'||core.machineBits!==machineBits||
    core.copyValidated!==true||core.originalsUnchanged!==true||typeof core.sourceBeforeDigest!=='string'||!digest.test(core.sourceBeforeDigest)||
    !available(core.before)||!available(core.after)||core.before.machineBits!==machineBits||core.after.machineBits!==machineBits) return false;
  for(const [source,snapshot] of [[before,core.before],[after,core.after]]) {
    if(JSON.stringify(source.domainPolicies.map(row=>({...row,comparisonId:templateCoreIdentity(row.comparisonId)})))!==
      JSON.stringify(snapshot.domainPolicies)) return false;
  }
  return components.every(([field,name])=>{
    const claim=core[name],old=core.before[field],made=core.after[field];
    return claim?.before===old&&claim?.after===made&&claim.status===(old===made?'matched':'not-established')&&
      (name==='program'||old===made);
  });
}

function compareTemplates(before,after,machineBits,definitionEvidence,lawEvidence,unitEvidence) {
  const available=value=>[32,64].includes(machineBits)&&value?.status==='available'&&value.version===1&&value.algorithm==='sha256'&&
    value.machineBits===machineBits&&templateComponents.every(([name])=>typeof value[name]==='string'&&digest.test(value[name]))&&
    ['units','definitions','laws'].every(name=>rowsValid(value[name]))&&rowsValid(value.domainPolicies,true);
  if(!available(before)||!available(after)) return {status:'not-established',
    reason:'Matching-version checked source-template snapshots at the program machine width were not available.'};
  const checks=Object.fromEntries(templateComponents.map(([field,name])=>[name,
    before[field]===after[field]?{status:'matched',basis:'matching-checked-source-template-fingerprints'}:
      {status:'not-established',reason:'The checked source-template '+name+' fingerprints differ.'}]));
  const definitionsMatched=checkedDefinitionTemplates(before,after,definitionEvidence,machineBits);
  const lawsMatched=checkedLawTemplates(before,after,lawEvidence,machineBits);
  if(checks.definitions.status!=='matched'&&definitionsMatched) {
    checks.definitions={status:'matched',basis:'matching-complete-symbolic-definition-Core-and-source-interfaces-after-validated-payload-transport'};
  }
  if(checks.lawBodies.status!=='matched'&&lawsMatched) checks.lawBodies={status:'matched',
    basis:'matching-complete-symbolic-law-Core-and-source-metadata-after-validated-payload-transport'};
  if(checks.declarations.status!=='matched'&&definitionsMatched&&lawsMatched&&
    anchoredTemplates(before,after,unitEvidence,machineBits)&&matchingPair(unitEvidence.metadata)&&
    unitEvidence.definitions==='matched'&&unitEvidence.laws==='matched'&&unitEvidence.payloadShapes==='matched') {
    checks.declarations={status:'matched',basis:'matching-complete-source-unit-metadata-and-certified-symbolic-terms-and-payloads'};
  }
  // Domain evidence belongs to the complete source capture that produced it.
  // A concrete-Core witness, stale capture, or one chosen law parameter is
  // insufficient for a reusable template's uniform input population.
  const anchored=value=>{
    const evidence=value.inputDomains;
    return {...value,inputDomains:templateComponents.every(([field])=>evidence?.sourceTemplates?.[field]===value[field])?
      evidence:undefined};
  };
  let policies=compareDomainPolicies(anchored(before),anchored(after));
  // The compiler's symbolic comparison copy retains the original inputs;
  // abstract parameter declarations are never witnesses. Reuse only complete
  // transported input evidence anchored to the checked law-template copy.
  if(policies.status!=='matched'&&lawsMatched) {
    const transported=compareDomainPolicies(lawEvidence.typedCore.before,lawEvidence.typedCore.after);
    const candidates=new Map((transported.domains??[]).map(row=>[row.comparisonId,row]));
    const domains=policies.domains.map(row=>{
      const candidate=candidates.get(templateCoreIdentity(row.comparisonId));
      return row.status==='matched'||candidate?.status!=='matched'?row:{...candidate,comparisonId:row.comparisonId,
        basis:'matching-transported-template-domain-dependencies-and-verified-input-witnesses',
        valueRepresentation:'transported-before-and-canonical-after'};
    });
    const matched=before.domainPolicies.length===after.domainPolicies.length&&domains.every(row=>row.status==='matched');
    policies={...policies,status:matched?'matched':'not-established',domains,
      ...(matched?{basis:'verified-input-domain-correspondence',reason:undefined}:{})};
  }
  if(checks.laws.status!=='matched'&&checks.lawBodies.status==='matched'&&policies.status==='matched') {
    checks.laws={status:'matched',basis:'matching-policy-erased-source-templates-and-verified-input-domains'};
  }
  return {status:policies.status==='matched'&&Object.values(checks).every(check=>check.status==='matched')?'matched':'not-established',
    scope:'pre-specialization checked source templates',...checks,
    lawBodies:{...checks.lawBodies,includesDomainPolicy:false},
    domainPolicies:policies,
    differences:differences(before,after,['units','definitions','laws'])};
}

function available(snapshot) {
  return snapshot?.status==='available'&&snapshot.version===1&&snapshot.algorithm==='sha256'&&
    [32,64].includes(snapshot.machineBits)&&components.every(([field])=>typeof snapshot[field]==='string'&&digest.test(snapshot[field]))&&
    parts.every(name=>rowsValid(snapshot[name]))&&rowsValid(snapshot.domainPolicies,true);
}

function compareDomainPolicies(before,after) {
  const original=before.domainPolicies,migrated=after.domainPolicies;
  const unchanged=JSON.stringify(original)===JSON.stringify(migrated);
  if(unchanged) return {status:'matched',before:original,after:migrated,basis:'unchanged-domain-policies'};
  const valid=sample=>sample?.status==='available'&&sample.version===1&&sample.algorithm==='sha256'&&
    sample.machineBits===before.machineBits&&sample.lawBodiesEvaluated===false&&Array.isArray(sample.domains)&&
    sample.domains.every(row=>row&&typeof row.comparisonId==='string'&&typeof row.domainDigest==='string'&&digest.test(row.domainDigest)&&
      ['inhabited','empty','incomplete','unsupported'].includes(row.status))&&
    new Set(sample.domains.map(row=>row.comparisonId)).size===sample.domains.length;
  const evidenceAvailable=valid(before.inputDomains)&&valid(after.inputDomains);
  const oldDomains=new Map(evidenceAvailable?before.inputDomains.domains.map(row=>[row.comparisonId,row]):[]);
  const newDomains=new Map(evidenceAvailable?after.inputDomains.domains.map(row=>[row.comparisonId,row]):[]);
  const validWitness=(row,policy)=>row?.status==='inhabited'&&Number.isSafeInteger(row.inputCount)&&row.inputCount>=0&&
    (row.formalParameterCount??0)===(policy.formalParameterCount??0)&&
    (!(policy.formalParameterCount>0)||row.uniformity==='parameter-independent')&&
    Array.isArray(row.witness)&&row.witness.length===row.inputCount&&
    row.witness.every(binding=>binding&&typeof binding.binder==='string'&&binding.value&&typeof binding.value==='object')&&
    new Set(row.witness.map(binding=>binding.binder)).size===row.witness.length;
  const rows=original.map(row=>{
    const next=migrated.find(item=>item.comparisonId===row.comparisonId);
    if(!next) return {comparisonId:row.comparisonId,status:'not-established',reason:'The migrated input domain is missing.'};
    if(row.policy===next.policy) return {comparisonId:row.comparisonId,status:'matched',basis:'unchanged-domain-policy'};
    const old=oldDomains.get(row.comparisonId),changed=newDomains.get(row.comparisonId);
    if(validWitness(old,row)&&validWitness(changed,next)&&old.domainDigest===changed.domainDigest&&
      old.inputCount===changed.inputCount&&
      JSON.stringify(old.witness.map(binding=>binding.binder))===JSON.stringify(changed.witness.map(binding=>binding.binder))) return {
      comparisonId:row.comparisonId,status:'matched',basis:'matching-domain-dependencies-and-verified-input-witnesses',
      before:old.witness,after:changed.witness};
    return {comparisonId:row.comparisonId,status:'not-established',reason:
      'The changed population policy needs matching domain dependencies and verified input witnesses; empty or incomplete searches do not justify it.'};
  });
  const matched=original.length===migrated.length&&rows.every(row=>row.status==='matched');
  return {status:matched?'matched':'not-established',basis:matched?'verified-input-domain-correspondence':undefined,
    ...(matched?{}:{reason:'Nonempty and universal domains differ. Establish inhabitance, including dependent and empty domains, before accepting this change.'}),
    before:original,after:migrated,domains:rows,lawVerification:'not-established-by-domain-evidence'};
}

function anchoredTransport(before,after,transport) {
  if(!transport) return false;
  // Bind the comparison copy to both actual admitted programs. A shape match,
  // a body match, or an unanchored witness is not an input-domain certificate.
  return ['matched','not-established'].includes(transport.status)&&transport.version===1&&transport.algorithm==='sha256'&&
    transport.machineBits===before.machineBits&&transport.copyValidated===true&&transport.originalsUnchanged===true&&
    transport.sourceBeforeDigest===before.programDigest&&available(transport.before)&&available(transport.after)&&
    transport.before.machineBits===before.machineBits&&transport.after.machineBits===after.machineBits&&
    transport.after.programDigest===after.programDigest&&
    JSON.stringify(transport.before.domainPolicies)===JSON.stringify(before.domainPolicies)&&
    JSON.stringify(transport.after.domainPolicies)===JSON.stringify(after.domainPolicies);
}

function compareTransportedDomains(before,after,transport,direct) {
  if(direct.status==='matched'||!anchoredTransport(before,after,transport)) return direct;
  const compared=compareDomainPolicies(transport.before,transport.after);
  const candidates=new Map((compared.domains??[]).map(row=>[row.comparisonId,row]));
  const domains=direct.domains.map(row=>{
    if(row.status==='matched') return row;
    const candidate=candidates.get(row.comparisonId);
    return candidate?.status==='matched'?{...candidate,
      basis:'matching-transported-domain-dependencies-and-verified-input-witnesses',
      valueRepresentation:'transported-before-and-canonical-after'}:row;
  });
  const matched=before.domainPolicies.length===after.domainPolicies.length&&domains.every(row=>row.status==='matched');
  return {...direct,status:matched?'matched':'not-established',domains,
    ...(matched?{basis:'verified-input-domain-correspondence',reason:undefined}:{}),
    transport:{status:'available',sourceBeforeDigest:transport.sourceBeforeDigest,
      copyValidated:true,originalsUnchanged:true}};
}

// A domain certificate alone cannot justify a body transformation. Require
// the compiler's complete validated-copy fingerprints and their pair claims,
// anchored to both admitted programs. The comparison copy is never executed.
function checkedTransportBodies(before,after,transport) {
  if(!anchoredTransport(before,after,transport)||transport.status!=='matched') return false;
  const pair=(name,field,equal)=>{
    const claim=transport[name],old=transport.before[field],made=transport.after[field];
    return claim?.before===old&&claim?.after===made&&
      claim.status===(old===made?'matched':'not-established')&&(!equal||old===made);
  };
  return pair('program','programDigest',false)&&pair('definitionPlane','definitionPlaneDigest',true)&&
    pair('lawBodies','lawBodiesDigest',true);
}

export function compareMigrationSnapshots(before,after,transport,definitionEvidence,lawEvidence,unitEvidence) {
  const incomplete=reason=>({status:'not-established',reason});
  const unproved={
    sourceTemplates:compareTemplates(before?.sourceTemplates,after?.sourceTemplates,
      before?.machineBits===after?.machineBits?before?.machineBits:undefined,definitionEvidence,lawEvidence,unitEvidence),
    nativeBindings:incomplete('Native constructor, field and representation bindings require project-wide correspondence.'),
    generatedBehavior:incomplete('Generated plans and native behavior require their own target validation.'),
  };
  if(!available(before)||!available(after)||before.machineBits!==after.machineBits) {
    const reason='The compiler did not return matching-version Core migration snapshots at one machine width.';
    return {status:'not-established',scope:'checked concrete Core',
      ...Object.fromEntries(components.map(([,component])=>[component,incomplete(reason)])),
      domainPolicies:incomplete(reason),...unproved};
  }
  const checks=Object.fromEntries(components.map(([field,component])=>[component,
    before[field]===after[field]?{status:'matched',basis:'matching-full-Core-fingerprints'}:incomplete('The normalized '+component+' fingerprints differ; correspondence has not been established.')]));
  const domainPolicies=compareTransportedDomains(before,after,transport,compareDomainPolicies(before,after));
  const transported=checkedTransportBodies(before,after,transport);
  if(transported) for(const component of ['definitionPlane','lawBodies']) {
    if(checks[component].status!=='matched') checks[component]={status:'matched',
      basis:'matching-complete-Core-fingerprints-after-validated-payload-transport'};
  }
  // lawBodiesDigest covers the entire normalized Core, with only root input
  // population policies erased. Equal bodies plus verified policy equivalence
  // establish Core correspondence; they do not establish any law's truth.
  if(checks.program.status!=='matched'&&checks.definitionPlane.status==='matched'&&
      checks.lawBodies.status==='matched'&&domainPolicies.status==='matched') {
    checks.program={status:'matched',basis:transported?
      'matching-complete-Core-after-validated-payload-transport-and-input-domain-correspondence':
      'matching-policy-erased-complete-Core-and-verified-input-domains'};
  }
  return {status:'not-established',scope:'checked concrete Core',...checks,
    differences:differences(before,after,parts),
    lawBodies:{...checks.lawBodies,includesDomainPolicy:false},
    domainPolicies,...unproved};
}
