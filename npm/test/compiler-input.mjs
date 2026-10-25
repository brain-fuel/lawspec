// Generated from templates/npm/test/compiler-input.mjs by lawspec-dev generate. Do not edit.
// Public compiler requests used by the conformance corpus. Every fixture uses
// the current grammar; law layers are selected explicitly by each helper.
export const canonicalRequest = {schemaVersion: 5, languageProfile: '1.0-rc.2', verification: {layers: []}};
const layers = ['proof', 'exhaustive', 'property', 'examples', 'runtime', 'model'];
export function checkInput(compiler, input) {
  return compiler.check({...canonicalRequest, verification: {layers}, ...input});
}
export function generateInput(compiler, input) {
  return compiler.planGeneration({...canonicalRequest, verification: {layers}, ...input});
}

// Display comparisons may ignore the phrase delimiters while identity and
// source-syntax tests continue to assert the complete resolved spelling.
export function nameText(name) {
  return name.replace(/\|((?:\\[|\\]|[^|\\])*)\|/gu,
    (_, body) => body.replace(/\\([|\\])/gu, '$1'));
}

// Append authored declarations inside an already complete unit fixture.
export function extendUnit(source, declarations) {
  if (!/\bend unit\s*$/u.test(source)) throw new Error('Expected a complete unit fixture');
  return source.replace(/\bend unit\s*$/u, '') + '\n' + declarations + '\nend unit\n';
}

// Compare actual public typed results while allowing formatting to move source
// origins. All selected fields must be present, so an absent API field cannot
// silently turn a correspondence check into undefined === undefined.
export function semanticFacts(result) {
  const fields = ['units', 'dataTypes', 'definitions', 'laws', 'contracts', 'refinements'];
  for (const field of fields) {
    if (!Array.isArray(result[field])) throw new Error(`Missing typed result field: ${field}`);
  }
  // Local identities may include a source-derived freshness digest. Compare
  // their binding structure consistently, retaining public declaration IDs.
  const locals=new Map();
  const bind=binder=>{if(binder?.id && !locals.has(binder.id))locals.set(binder.id,`$local${locals.size}`);};
  const discover=value=>{
    if(Array.isArray(value))return value.forEach(discover);
    if(!value || typeof value!=='object')return;
    if(['let','allElements'].includes(value.kind))bind(value.binder);
    if(value.kind==='allPayloads')for(const predicate of value.predicates)bind(predicate.binder);
    if(value.kind==='match')for(const branch of value.cases)for(const binder of branch.binders)bind(binder);
    Object.values(value).forEach(discover);
  };
  const facts=Object.fromEntries(fields.map(field=>[field,result[field]]));
  discover(facts);
  const withoutOrigins=value=>{
    if(Array.isArray(value))return value.map(withoutOrigins);
    if(value && typeof value==='object')return Object.fromEntries(
      Object.entries(value).filter(([key])=>!['origin','location','span','at'].includes(key))
        .map(([key,item])=>[key,key==='id' && locals.has(item)?locals.get(item):withoutOrigins(item)]));
    return value;
  };
  return withoutOrigins(facts);
}

// The compiler's explanations of every law in a request, or of one law. The
// human text is exactly every section's lines, in order.
export async function explanations(compiler, input, view, law) {
  const result = await compiler.explain({...input, ...(view ? {view} : {}), ...(law ? {law} : {})});
  if (result.diagnostics.length) throw new Error(JSON.stringify(result.diagnostics));
  return result.explanations;
}
export const explanationText = explanation => explanation.sections.flatMap(section => section.lines).join('\n');
export const explanationViews = ['eng', 'math', 'dev'];
