// Migration starts from the typed legacy baseline. A report is not permission
// to write an unvalidated transformation or silently alter native payload APIs.
import {planLegacySourceEdits} from './migration-laws.mjs';
import {compareMigrationSnapshots} from './migration-correspondence.mjs';

export const legacyLawLayers = ['proof', 'exhaustive', 'property', 'examples', 'runtime', 'model'];
export async function migrationReport(compiler, config, input) {
  const baseline = await compiler.check({ ...input, schemaVersion: 3 });
  if (baseline.diagnostics?.length) return { from: '0.24', to: '1.0-rc.1', validated: false, diagnostics: baseline.diagnostics };
  const syntax = await compiler.migrationBaseline({...input,schemaVersion:5,languageProfile:'1.0-rc.1',from:'0.24',verification:{layers:[]}});
  if (syntax.diagnostics?.length) return {from:'0.24',to:'1.0-rc.1',validated:false,diagnostics:syntax.diagnostics};
  if (!Array.isArray(syntax.sourceSyntax)) throw new Error('The compiler did not return the checked source syntax inventory');
  const files = new Set(input.sources.map(s => s.path));
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
    sourcePreview = {scope:'checked computations, nominal records and alternative payloads, ordered collection names, unsigned integers, cases, laws, explicit universal scopes and expectation-first tables',
      sources:planLegacySourceEdits(input.sources,baseline,syntax.sourceSyntax),diagnostics:[]};
  } catch (error) {
    sourcePreview = {scope:'checked computations, nominal records and alternative payloads, ordered collection names, unsigned integers, cases, laws, explicit universal scopes and expectation-first tables',sources:[],
      diagnostics:[{code:'migration-source',message:error.message,at:null}]};
  }
  if (!sourcePreview.diagnostics.length) {
    const checked = await compiler.check({...input,schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]},migrationSnapshot:true,
      sources:sourcePreview.sources.map(({path,content})=>({path,content}))});
    sourcePreview.canonicalCheck = {status:checked.diagnostics.length?'rejected':'accepted',diagnostics:checked.diagnostics,
      intrinsicDefinitionChecks:checked.verification?.intrinsicDefinitionChecks===true,
      lawVerification:'no-selected-checks',coreSnapshot:checked.migrationSemantics??{status:'unavailable',reason:'The compiler did not return a Core migration snapshot.'}};
  } else sourcePreview.canonicalCheck = {status:'unavailable',diagnostics:sourcePreview.diagnostics};
  let payloadComparison={status:'unavailable',reason:'The canonical preview or compiler-side payload comparison is unavailable.'};
  if(sourcePreview.canonicalCheck.status==='accepted'&&typeof compiler.migrationComparison==='function') {
    const compared=await compiler.migrationComparison({...input,schemaVersion:5,languageProfile:'1.0-rc.1',from:'0.24',verification:{layers:[]},
      migrated:{...input,schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]},
        sources:sourcePreview.sources.map(({path,content})=>({path,content}))}});
    payloadComparison=compared.migrationComparison??{status:'unavailable',
      reason:'The compiler did not admit both inputs for payload comparison.',diagnostics:compared.diagnostics};
  }
  const correspondence={...compareMigrationSnapshots(syntax.migrationSemantics,sourcePreview.canonicalCheck?.coreSnapshot,payloadComparison.executableTransport),
    payloads:payloadComparison};
  const pending=[
    ['program','Complete checked Core correspondence has not been established.'],
    ['definitionPlane','Checked definition and contract correspondence has not been established.'],
    ['lawBodies','Complete policy-erased Core correspondence has not been established.'],
    ['sourceTemplates','Complete checked source-template correspondence has not been established.'],
    ['nativeBindings','Native constructor, field and representation bindings require project-wide correspondence.'],
    ['generatedBehavior','Generated plans and native behavior require target validation.'],
  ];
  const domainPending=correspondence.domainPolicies.status!=='matched'||
    correspondence.sourceTemplates.domainPolicies?.status==='not-established';
  return {
    from: '0.24', to: '1.0-rc.1', validated: false, diagnostics: [],
    proposedConfiguration: { ...config, version: 2, languageProfile: '1.0-rc.1', verification: { layers: [...legacyLawLayers] } },
    baseline: { declarations, definitions, laws, types, obligations: baseline.evidence, sourceSyntax:syntax.sourceSyntax,
      coreSnapshot:syntax.migrationSemantics??{status:'unavailable',reason:'The compiler did not return a Core migration snapshot.'} },
    sourcePreview,
    correspondence,
    domainPolicyChanges: laws.map(law => ({law:law.id,from:law.inputDomain,to:'universal',
      requirement:'Preserve domain correspondence, including empty and dependent domains, when validating this migration.'})),
    constructorChanges: payloads,
    nativeBindings: config.targets.map(target => ({ target: target.language, bindings: target.nativeBindings ?? null })),
    blockers: [...pending.filter(([name])=>correspondence[name].status!=='matched').map(([,reason])=>reason),
      ...(domainPending ? ['Legacy nonempty input-domain handling and canonical universal quantification require explicit correspondence checks; no empty-domain equivalence is assumed.'] : []),
      ...(sourcePreview.canonicalCheck.status==='rejected' ? ['The partial preview does not yet pass canonical compilation; inspect sourcePreview.canonicalCheck.diagnostics.'] : []),
      ...sourcePreview.diagnostics.map(diagnostic => 'Source preview unavailable: ' + diagnostic.message),
      'Validated project-wide writing has not been implemented.'],
    filesWritten: [],
  };
}
