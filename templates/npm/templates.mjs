// Project scaffolds, test commands and setup advice for each target. The data
// is LawSpec.Scaffold's, so the npm CLI and the compiler cannot disagree.
export const targets = /*@ targets @*/;
export const programTargets = /*@ program-targets @*/;
export const artifactTargets = /*@ artifact-targets @*/;
export const targetLabels = /*@ target-labels @*/;

export const presentationChecks = /*@ presentation-checks @*/;

export const commands = /*@ commands @*/;

export const setup = /*@ setup @*/;

// The commands lawspec init runs to fetch a new project's dependencies, and
// the settings it adds to a JSON build file the project already has.
export const prepareCommands = /*@ prepare-commands @*/;

export const requirements = /*@ requirements @*/;

// Each target's build files in the readable and the compact (minified) layout.
const scaffolds = /*@ scaffolds @*/;

export function templates(target, { minify = false } = {}) {
  if (typeof minify !== "boolean") throw new Error("minify must be a boolean");
  if (!targets.includes(target)) throw new Error(`Unknown target: ${target}`);
  return { ...scaffolds[target][minify ? "compact" : "readable"] };
}
