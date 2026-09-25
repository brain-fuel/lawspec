// Generated from LawSpec.Gen. Do not edit.
import { loadCore } from './launcher.mjs';
export async function createCompiler() {
  const call = await loadCore();
  return { check: (input) => call({ schemaVersion: 3, ...input, method: 'check' }), expand: (input) => call({ schemaVersion: 3, ...input, method: 'expand' }), planGeneration: (input) => call({ schemaVersion: 3, ...input, method: 'planGeneration' }) };
}
