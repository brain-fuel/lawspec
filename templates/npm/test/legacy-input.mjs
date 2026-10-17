// Frozen 0.24 fixtures exercise the explicit migration boundary. Ordinary
// authoring tests call the canonical API directly with its required profile.
const legacyLayers=['proof','exhaustive','property','examples','runtime','model'];
export const canonicalRequest={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
export function legacyCheck(compiler,input){
  return compiler.migrationBaseline({...canonicalRequest,verification:{layers:legacyLayers},
    ...input,from:'0.24'});
}
export function legacyGeneration(compiler,input){
  return legacyCheck(compiler,{...input,includeGeneration:true});
}
