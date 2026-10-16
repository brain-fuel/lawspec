// Migration starts from the typed legacy baseline. A report is not permission
// to write an unvalidated transformation or silently alter native payload APIs.
import {planLegacyComputationEdits} from './migration-source.mjs';

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
    change: constructor.fields.length > 1 ? 'group fields into one explicit tuple or record payload' : 'declare an explicit typed payload and reconcile its native field binding',
  })));
  let sourcePreview;
  try {
    sourcePreview = {scope:'checked computation declarations, conditional closers, typed equality and reserved literal prefixes',
      sources:planLegacyComputationEdits(input.sources,baseline,syntax.sourceSyntax),diagnostics:[]};
  } catch (error) {
    sourcePreview = {scope:'checked computation declarations, conditional closers, typed equality and reserved literal prefixes',sources:[],
      diagnostics:[{code:'migration-source',message:error.message,at:null}]};
  }
  return {
    from: '0.24', to: '1.0-rc.1', validated: false, diagnostics: [],
    proposedConfiguration: { ...config, version: 2, languageProfile: '1.0-rc.1', verification: { layers: [...legacyLawLayers] } },
    baseline: { declarations, definitions, laws, types, obligations: baseline.evidence, sourceSyntax:syntax.sourceSyntax },
    sourcePreview,
    constructorChanges: payloads,
    nativeBindings: config.targets.map(target => ({ target: target.language, bindings: target.nativeBindings ?? null })),
    blockers: ['Source and native binding transformations have not yet passed project-wide semantic and generated-behavior correspondence checks.',
      ...sourcePreview.diagnostics.map(diagnostic => 'Source preview unavailable: ' + diagnostic.message)],
    filesWritten: [],
  };
}
