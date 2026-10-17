// Migration starts from the typed legacy baseline. A report is not permission
// to write an unvalidated transformation or silently alter native payload APIs.
import {planLegacySourceEdits} from './migration-laws.mjs';
import {compareMigrationSnapshots} from './migration-correspondence.mjs';
import {planNativeBindings} from './migration-bindings.mjs';
import {planMigrationGeneration} from './migration-generation.mjs';

export const legacyLawLayers = ['proof', 'exhaustive', 'property', 'examples', 'runtime', 'model'];
export async function migrationReport(compiler, config, input) {
  if(config?.version!==1||!Array.isArray(config.targets))return {from:'0.24',to:'1.0-rc.1',validated:false,
    diagnostics:[{code:'migration-configuration',message:'Migration requires a version 1 configuration with a targets array.',at:null}]};
  const {nativeBindings:inputBindings,...sourceInput}=input;
  const legacyInput={...sourceInput,schemaVersion:5,languageProfile:'1.0-rc.1',from:'0.24'};
  const baseline = await compiler.migrationBaseline({...legacyInput,verification:{layers:[...legacyLawLayers]}});
  if (baseline.diagnostics?.length) return { from: '0.24', to: '1.0-rc.1', validated: false, diagnostics: baseline.diagnostics };
  if (!Array.isArray(baseline.sourceSyntax)) throw new Error('The compiler did not return the checked source syntax inventory');
  const packageInputs = input.packages ?? [];
  const allSources = [...input.sources, ...packageInputs.flatMap(pkg => pkg.sources)];
  const files = new Set(allSources.map(source => source.path));
  const owned = origin => origin?.kind === 'source' && files.has(origin.span.start.file);
  const declarations = baseline.units.flatMap(unit => unit.declarations.filter(d => owned(d.origin)).map(d => ({ unit: unit.id, ...d })));
  const definitions = baseline.definitions.filter(d => declarations.some(declaration => declaration.id === d.id));
  const laws = baseline.laws.filter(law => files.has(law.location.file));
  const types = baseline.dataTypes.filter(d => owned(d.origin));
  const payloads = types.flatMap(type => type.constructors.filter(c => c.fields.length).map(constructor => ({
    type: type.id, constructor: constructor.id, fields: constructor.fields,
    change: type.constructors.length===1 && constructor.name===type.name
      ? 'declare explicit nominal record syntax and preserve its constructor field binding'
      : constructor.fields.length > 1 ? 'group fields into one explicit record payload and reconcile its native field binding' : 'declare an explicit typed payload and reconcile its native field binding',
  })));
  let sourcePreview;
  try {
    if(files.size !== allSources.length) throw new Error('Project and package source paths must be unique.');
    const edited = planLegacySourceEdits(allSources,baseline,baseline.sourceSyntax,baseline.sourceFields);
    const edits = new Map(edited.map(source => [source.path,source]));
    sourcePreview = {scope:'checked computations, nominal records and alternative payloads, ordered collection names, unsigned integers, cases, laws, explicit universal scopes and expectation-first tables',
      sources:input.sources.map(source => edits.get(source.path)),
      packages:packageInputs.map(pkg => ({...pkg,sources:pkg.sources.map(source => edits.get(source.path))})),diagnostics:[]};
  } catch (error) {
    sourcePreview = {scope:'checked computations, nominal records and alternative payloads, ordered collection names, unsigned integers, cases, laws, explicit universal scopes and expectation-first tables',sources:[],
      diagnostics:[{code:'migration-source',message:error.message,at:null}]};
  }
  const migratedSources=sourcePreview.sources.map(({path,content})=>({path,content}));
  const migratedPackages=(sourcePreview.packages??[]).map(pkg=>({...pkg,
    sources:pkg.sources.map(({path,content})=>({path,content}))}));
  const migratedContext=packageInputs.length?{packages:migratedPackages}:{};
  if (!sourcePreview.diagnostics.length) {
    const checked = await compiler.check({...sourceInput,...migratedContext,schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]},migrationSnapshot:true,
      sources:migratedSources});
    sourcePreview.canonicalCheck = {status:checked.diagnostics.length?'rejected':'accepted',diagnostics:checked.diagnostics,
      intrinsicDefinitionChecks:checked.verification?.intrinsicDefinitionChecks===true,
      lawVerification:'no-selected-checks',coreSnapshot:checked.migrationSemantics??{status:'unavailable',reason:'The compiler did not return a Core migration snapshot.'}};
  } else sourcePreview.canonicalCheck = {status:'unavailable',diagnostics:sourcePreview.diagnostics};
  let payloadComparison={status:'unavailable',reason:'The canonical preview or compiler-side payload comparison is unavailable.'};
  if(sourcePreview.canonicalCheck.status==='accepted'&&typeof compiler.migrationComparison==='function') {
    const compared=await compiler.migrationComparison({...sourceInput,schemaVersion:5,languageProfile:'1.0-rc.1',from:'0.24',verification:{layers:[]},
      migrated:{...sourceInput,...migratedContext,schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]},
        sources:migratedSources}});
    payloadComparison=compared.migrationComparison??{status:'unavailable',
      reason:'The compiler did not admit both inputs for payload comparison.',diagnostics:compared.diagnostics};
  }
  const correspondence={...compareMigrationSnapshots(baseline.migrationSemantics,sourcePreview.canonicalCheck?.coreSnapshot,
    payloadComparison.executableTransport,payloadComparison.definitionTemplates,payloadComparison.lawTemplates,payloadComparison.sourceUnits),
    payloads:payloadComparison};
  const bindingPreview=sourcePreview.canonicalCheck.status==='accepted' ?
    await planNativeBindings(compiler,config,input,migratedSources,
      baseline.migrationSemantics,sourcePreview.canonicalCheck.coreSnapshot,migratedContext) :
    {status:'not-established',scope:'explicit native binding configuration',
      configurationCount:config.targets.length+(input.nativeBindings!==undefined?1:0),targets:[],
      proposedTargets:config.targets,reason:'Native binding planning requires an admitted canonical source preview.'};
  correspondence.nativeBindings={status:bindingPreview.status,scope:bindingPreview.scope,
    configurationCount:bindingPreview.configurationCount};
  const generationPreview=await planMigrationGeneration(compiler,config,{...input,generation:baseline.generation},
    migratedSources,baseline.migrationSemantics,
    sourcePreview.canonicalCheck.coreSnapshot,bindingPreview,migratedContext);
  correspondence.targetGeneration={status:generationPreview.status,scope:generationPreview.scope,
    configurationCount:generationPreview.configurationCount};
  correspondence.nativeBoundary=generationPreview.nativeBoundary;
  const pending=[
    ['program','Complete checked Core correspondence has not been established.'],
    ['definitionPlane','Checked definition and contract correspondence has not been established.'],
    ['lawBodies','Complete policy-erased Core correspondence has not been established.'],
    ['sourceTemplates','Complete checked source-template correspondence has not been established.'],
    ['nativeBindings','Native constructor, field and representation bindings require project-wide correspondence.'],
  ];
  const domainPending=correspondence.domainPolicies.status!=='matched'||
    correspondence.sourceTemplates.domainPolicies?.status!=='matched';
  const sourceMatched=sourcePreview.canonicalCheck.status==='accepted'&&
    sourcePreview.canonicalCheck.intrinsicDefinitionChecks===true&&sourcePreview.diagnostics.length===0&&
    !domainPending&&pending.every(([name])=>correspondence[name].status==='matched');
  const count=generationPreview.configurationCount;
  const targetsMatched=count===0 ? generationPreview.status==='not-requested'&&
    generationPreview.nativeBoundary.status==='not-requested'&&generationPreview.targets.length===0 :
    generationPreview.status==='accepted'&&generationPreview.nativeBoundary.status==='matched'&&
    generationPreview.targets.length===count&&generationPreview.targets.every(row=>row.status==='accepted'&&
      row.nativeBoundary.status==='matched');
  const validated=sourceMatched&&targetsMatched&&bindingPreview.configurationCount===count;
  const assumptions=['existing compiler validation, transport and target emitters',
    'unchanged native implementations under their original binding assumptions'];
  correspondence.generatedBehavior={status:count===0?'not-requested':validated?
    'matched-under-existing-assumptions':'not-established',
    scope:'preservation of checked source semantics and configured native interfaces; no native execution',
    assumptions,nativeExecution:'not-performed',nativeConformance:'not-established',
    lawVerification:'not-established-by-migration'};
  correspondence.status=validated?'matched-under-existing-assumptions':'not-established';
  correspondence.scope='complete checked source migration and configured target interfaces';
  return {
    from: '0.24', to: '1.0-rc.1', validated, diagnostics: [],
    validation:{status:validated?'validated-under-existing-assumptions':'not-established',
      scope:'all supplied project sources, configuration and configured targets',assumptions,
      nativeConformance:'not-established',lawVerification:'not-established-by-migration'},
    proposedConfiguration: { ...config, targets:bindingPreview.proposedTargets, version: 2, languageProfile: '1.0-rc.1', verification: { layers: [...legacyLawLayers] } },
    baseline: { declarations, definitions, laws, types, obligations: baseline.evidence, sourceSyntax:baseline.sourceSyntax,sourceFields:baseline.sourceFields,
      coreSnapshot:baseline.migrationSemantics??{status:'unavailable',reason:'The compiler did not return a Core migration snapshot.'} },
    sourcePreview,
    correspondence,
    domainPolicyChanges: laws.map(law => ({law:law.id,from:law.inputDomain,to:'universal',
      requirement:'Preserve domain correspondence, including empty and dependent domains, when validating this migration.'})),
    constructorChanges: payloads,
    nativeBindings: config.targets.map(target => ({ target: target.language, bindings: target.nativeBindings ?? null })),
    bindingPreview,
    generationPreview,
    blockers: [...pending.filter(([name])=>correspondence[name].status!=='matched').map(([,reason])=>reason),
      ...bindingPreview.targets.filter(target=>target.status!=='matched').map(target=>'Native bindings for '+(target.target||'input')+': '+target.reason),
      ...generationPreview.targets.filter(target=>target.status!=='accepted').map(target=>'Target generation for '+(target.target||'input')+': '+target.reason),
      ...generationPreview.targets.filter(target=>target.status==='accepted'&&target.nativeBoundary.status!=='matched')
        .map(target=>'Native boundary for '+(target.target||'input')+': '+target.nativeBoundary.reason),
      ...(domainPending ? ['Legacy nonempty input-domain handling and canonical universal quantification require explicit correspondence checks; no empty-domain equivalence is assumed.'] : []),
      ...(sourcePreview.canonicalCheck.status==='rejected' ? ['The partial preview does not yet pass canonical compilation; inspect sourcePreview.canonicalCheck.diagnostics.'] : []),
      ...sourcePreview.diagnostics.map(diagnostic => 'Source preview unavailable: ' + diagnostic.message),
      ...(!sourcePreview.canonicalCheck.intrinsicDefinitionChecks?['Mandatory definition validation was not established.']:[])],
    filesWritten: [],
  };
}
