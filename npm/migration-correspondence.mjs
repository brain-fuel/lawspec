// Generated from templates/npm/migration-correspondence.mjs by lawspec-dev generate. Do not edit.
// These fingerprints cover the compiler's complete typed Core, not the
// smaller documentary JSON views. They establish no unrun law verification.
const digest=/^[0-9a-f]{64}$/;
const components=[['programDigest','program'],['definitionPlaneDigest','definitionPlane'],['lawBodiesDigest','lawBodies']];
const parts=['definitions','contracts','dataTypes'];

function available(snapshot) {
  return snapshot?.status==='available'&&snapshot.version===1&&snapshot.algorithm==='sha256'&&
    [32,64].includes(snapshot.machineBits)&&components.every(([field])=>typeof snapshot[field]==='string'&&digest.test(snapshot[field]))&&
    parts.every(name=>Array.isArray(snapshot[name])&&snapshot[name].every(item=>
      item&&typeof item.comparisonId==='string'&&typeof item.digest==='string'&&digest.test(item.digest))&&
      new Set(snapshot[name].map(item=>item.comparisonId)).size===snapshot[name].length)&&
    Array.isArray(snapshot.domainPolicies)&&snapshot.domainPolicies.every(item=>
      item&&typeof item.comparisonId==='string'&&['nonempty','universal'].includes(item.policy))&&
    new Set(snapshot.domainPolicies.map(item=>item.comparisonId)).size===snapshot.domainPolicies.length;
}

export function compareMigrationSnapshots(before,after) {
  const incomplete=reason=>({status:'not-established',reason});
  const unproved={
    sourceTemplates:incomplete('Uninstantiated definitions and reusable-law templates require separate typed correspondence.'),
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
  const policiesEqual=JSON.stringify(before.domainPolicies)===JSON.stringify(after.domainPolicies);
  const differences=Object.fromEntries(parts.map(name=>{
    const original=new Map(before[name].map(item=>[item.comparisonId,item.digest]));
    const migrated=new Map(after[name].map(item=>[item.comparisonId,item.digest]));
    return [name,{added:[...migrated.keys()].filter(id=>!original.has(id)),
      removed:[...original.keys()].filter(id=>!migrated.has(id)),
      changed:[...original.keys()].filter(id=>migrated.has(id)&&original.get(id)!==migrated.get(id))}];
  }));
  return {status:'not-established',scope:'checked concrete Core',...checks,
    differences,
    lawBodies:{...checks.lawBodies,includesDomainPolicy:false},
    domainPolicies:{...(policiesEqual?{status:'matched'}:incomplete(
      'Nonempty and universal domains differ. Establish inhabitance, including dependent and empty domains, before accepting this change.')),
      before:before.domainPolicies,after:after.domainPolicies},...unproved};
}
