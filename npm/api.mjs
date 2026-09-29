// Generated from LawSpec.Gen. Do not edit.
import {loadCore} from './launcher.mjs';

export async function createCompiler() {
  const call = await loadCore();
  return {
    check: (input) =>
        call(
            {
              schemaVersion: input.nativeBindings === undefined ? 3 : 4,
              ...input,
              method: 'check',
            }
        ),
    expand: (input) =>
        call(
            {
              schemaVersion: input.nativeBindings === undefined ? 3 : 4,
              ...input,
              method: 'expand',
            }
        ),
    planGeneration: (input) =>
        call(
            {
              schemaVersion: input.nativeBindings === undefined ? 3 : 4,
              ...input,
              method: 'planGeneration',
            }
        ),
  };
}
