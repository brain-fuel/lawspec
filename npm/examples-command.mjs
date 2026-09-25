import { readFile, readdir, mkdir } from "node:fs/promises";
import path from "node:path";
import { createCompiler } from "./api.mjs";
import { targets } from "./templates.mjs";
import { safePath, planWrites, applyWrites } from "./files.mjs";

export async function generateExamples(options) {
  const selected = options.target ? [options.target] : targets;
  if (selected.some((t) => !targets.includes(t)))
    throw new Error(`Unknown target: ${options.target}`);
  const directory = new URL("./examples/specs/", import.meta.url);
  const sources = await Promise.all(
    (await readdir(directory))
      .filter((n) => n.endsWith(".lawspec"))
      .sort()
      .map(async (name) => ({
        path: name,
        content: await readFile(new URL(name, directory), "utf8"),
      })),
  );
  const compiler = await createCompiler();
  const artifacts = [];
  for (const target of selected) {
    const result = await compiler.planGeneration({ sources, target, machineBits: options.machineBits ?? 64 });
    if (result.diagnostics.length)
      throw Object.assign(new Error("Bundled examples failed to compile"), {
        diagnostics: result.diagnostics,
      });
    artifacts.push(result.files);
  }
  const root = await safePath(
    process.cwd(),
    options.output || "example_artifacts",
  );
  await mkdir(root, { recursive: true });
  const plans = [];
  for (let i = 0; i < selected.length; i++) {
    const targetRoot = await safePath(root, selected[i]);
    await mkdir(targetRoot, { recursive: true });
    plans.push(await planWrites(targetRoot, artifacts[i]));
  }
  await applyWrites(plans);
  return plans.map((plan, i) => ({
    target: selected[i],
    directory: plan.root,
    files: artifacts[i].map((f) => ({ path: f.path, ownership: f.ownership })),
    changes: plan.changes.length,
    preservedAdapters: plan.preserved,
    adapterUpdates: plan.adapterUpdates,
  }));
}
