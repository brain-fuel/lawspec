// Generated from LawSpec.Gen. Do not edit.
import { loadCore } from './launcher.mjs';
export async function createCompiler() {
  const call = await loadCore();
  return { check: (input) => call({ ...input, method: 'check' }), expand: (input) => call({ ...input, method: 'expand' }), planGeneration: (input) => call({ ...input, method: 'planGeneration' }) };
}
