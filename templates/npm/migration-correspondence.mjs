// These fingerprints cover the compiler's complete typed Core, not the
// smaller documentary JSON views. They establish no unrun law verification.
const digest=/^[0-9a-f]{64}$/;
const components=[['programDigest','program'],['definitionPlaneDigest','definitionPlane'],['lawBodiesDigest','lawBodies']];
const parts=['definitions','contracts','dataTypes'];
const templateComponents=[['declarationsDigest','declarations'],['definitionTemplatesDigest','definitions'],
  ['lawTemplatesDigest','laws'],['lawBodiesDigest','lawBodies']];

function rowsValid(rows,policies=false) {
  return Array.isArray(rows)&&rows.every(item=>item&&typeof item.comparisonId==='string'&&
    (policies?['nonempty','universal'].includes(item.policy):typeof item.digest==='string'&&digest.test(item.digest)))&&
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

function compareTemplates(before,after,machineBits) {
  const available=value=>[32,64].includes(machineBits)&&value?.status==='available'&&value.version===1&&value.algorithm==='sha256'&&
    value.machineBits===machineBits&&templateComponents.every(([name])=>typeof value[name]==='string'&&digest.test(value[name]))&&
    ['units','definitions','laws'].every(name=>rowsValid(value[name]))&&rowsValid(value.domainPolicies,true);
  if(!available(before)||!available(after)) return {status:'not-established',
    reason:'Matching-version checked source-template snapshots at the program machine width were not available.'};
  const checks=Object.fromEntries(templateComponents.map(([field,name])=>[name,
    before[field]===after[field]?{status:'matched',basis:'matching-checked-source-template-fingerprints'}:
      {status:'not-established',reason:'The checked source-template '+name+' fingerprints differ.'}]));
  const policiesEqual=JSON.stringify(before.domainPolicies)===JSON.stringify(after.domainPolicies);
  return {status:policiesEqual&&Object.values(checks).every(check=>check.status==='matched')?'matched':'not-established',
    scope:'pre-specialization checked source templates',...checks,
    lawBodies:{...checks.lawBodies,includesDomainPolicy:false},
    domainPolicies:{status:policiesEqual?'matched':'not-established',before:before.domainPolicies,after:after.domainPolicies},
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
  const validWitness=row=>row?.status==='inhabited'&&Number.isSafeInteger(row.inputCount)&&row.inputCount>=0&&
    Array.isArray(row.witness)&&row.witness.length===row.inputCount&&
    row.witness.every(binding=>binding&&typeof binding.binder==='string'&&binding.value&&typeof binding.value==='object')&&
    new Set(row.witness.map(binding=>binding.binder)).size===row.witness.length;
  const rows=original.map(row=>{
    const next=migrated.find(item=>item.comparisonId===row.comparisonId);
    if(!next) return {comparisonId:row.comparisonId,status:'not-established',reason:'The migrated input domain is missing.'};
    if(row.policy===next.policy) return {comparisonId:row.comparisonId,status:'matched',basis:'unchanged-domain-policy'};
    const old=oldDomains.get(row.comparisonId),changed=newDomains.get(row.comparisonId);
    if(validWitness(old)&&validWitness(changed)&&old.domainDigest===changed.domainDigest) return {
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

export function compareMigrationSnapshots(before,after) {
  const incomplete=reason=>({status:'not-established',reason});
  const unproved={
    sourceTemplates:compareTemplates(before?.sourceTemplates,after?.sourceTemplates,
      before?.machineBits===after?.machineBits?before?.machineBits:undefined),
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
  return {status:'not-established',scope:'checked concrete Core',...checks,
    differences:differences(before,after,parts),
    lawBodies:{...checks.lawBodies,includesDomainPolicy:false},
    domainPolicies:compareDomainPolicies(before,after),...unproved};
}
