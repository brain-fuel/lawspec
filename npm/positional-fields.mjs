// Generated from templates/npm/positional-fields.mjs by lawspec-dev generate. Do not edit.
// Positions come from checked compiler metadata, never from guessing labels.
export function positionalFields(declaration) {
  const structure = declaration?.structure, constructors = declaration?.constructors;
  const positions = structure?.positions;
  if (structure?.kind !== 'record' || !Array.isArray(positions) || positions.length < 2
    || constructors?.length !== 1 || new Set(positions).size !== positions.length) return undefined;
  const fields = constructors[0].fields;
  if (fields.length !== positions.length) return undefined;
  const byName = new Map(fields.map(field => [field.name, field]));
  if (byName.size !== positions.length || !positions.every(label => byName.has(label))) return undefined;
  return positions.map(label => byName.get(label));
}
