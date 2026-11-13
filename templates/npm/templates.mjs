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

// The Java releases generated code compiles at (lawspec.edn's :release), and
// the Java build file at each release other than the default.
export const javaReleases = /*@ java-releases @*/;
export const defaultJavaRelease = /*@ java-default-release @*/;
const javaReleaseScaffolds = /*@ java-release-scaffolds @*/;

export function templates(target, { minify = false, release } = {}) {
  if (typeof minify !== "boolean") throw new Error("minify must be a boolean");
  if (!targets.includes(target)) throw new Error(`Unknown target: ${target}`);
  const layout = minify ? "compact" : "readable";
  if (release === undefined || (target === "java" && release === defaultJavaRelease))
    return { ...scaffolds[target][layout] };
  if (target !== "java") throw new Error("release is supported by the java target only");
  if (!javaReleases.includes(release))
    throw new Error(`release ${release} is not supported for java; choose ${javaReleases.join(" or ")}`);
  return { ...javaReleaseScaffolds[release][layout] };
}

// What a Java build needs so that it compiles a target's generated
// directories. The text is LawSpec.Scaffold's; only the names are filled in.
const generatedRoots = /*@ generated-roots-advice @*/;

export function generatedRootsAdvice(target) {
  const source = target.generatedSourceDir, test = target.generatedTestDir;
  if (source === undefined && test === undefined) return "";
  return generatedRoots[source === undefined ? "test" : test === undefined ? "source" : "both"]
    .replaceAll(/*@ generated-source-hole @*/, source)
    .replaceAll(/*@ generated-test-hole @*/, test);
}
