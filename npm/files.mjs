import {
  readFile,
  mkdir,
  writeFile,
  rename,
  unlink,
  lstat,
  realpath,
  link,
} from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
export const digest = (text) =>
  crypto.createHash("sha256").update(text).digest("hex");
export async function readOptional(file) {
  try {
    return await readFile(file, "utf8");
  } catch (e) {
    if (e.code === "ENOENT") return null;
    throw e;
  }
}
export async function safePath(root, relative) {
  if (
    typeof relative !== "string" ||
    !relative ||
    path.isAbsolute(relative) ||
    relative.split(/[\\/]/).some((p) => p === ".." || p === ".")
  )
    throw new Error(`Unsafe output path: ${relative}`);
  const resolved = path.resolve(root, relative);
  if (!resolved.startsWith(path.resolve(root) + path.sep))
    throw new Error(`Output escapes project: ${relative}`);
  const realRoot = await realpath(root);
  let cursor = root;
  for (const part of relative.split("/")) {
    cursor = path.join(cursor, part);
    try {
      const stat = await lstat(cursor);
      if (stat.isSymbolicLink())
        throw new Error(`Refusing symbolic-link output: ${relative}`);
      const real = await realpath(cursor);
      if (real !== realRoot && !real.startsWith(realRoot + path.sep))
        throw new Error(`Output escapes project: ${relative}`);
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
    }
  }
  return resolved;
}
export async function atomicWrite(file, content, exclusive = false) {
  await mkdir(path.dirname(file), { recursive: true });
  const tmp = `${file}.lawspec-${crypto.randomUUID()}.tmp`;
  try {
    await writeFile(tmp, content, { flag: "wx" });
    if (exclusive) await link(tmp, file);
    else await rename(tmp, file);
  } finally {
    try {
      await unlink(tmp);
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
    }
  }
}
export async function planWrites(root, artifacts) {
  const manifestPath = await safePath(root, ".lawspec/generated.json");
  const previousText = await readOptional(manifestPath);
  const previous =
    previousText === null
      ? { version: 1, files: {} }
      : JSON.parse(previousText);
  if (
    previous.version !== 1 ||
    !previous.files ||
    typeof previous.files !== "object"
  )
    throw new Error("Invalid ownership manifest");
  const seen = new Set();
  const changes = [];
  const preserved = [];
  const adapterUpdates = [];
  const adapterHashes = {};
  const next = {};
  for (const artifact of artifacts) {
    if (seen.has(artifact.path))
      throw new Error(`Duplicate output: ${artifact.path}`);
    seen.add(artifact.path);
    const file = await safePath(root, artifact.path);
    const old = await readOptional(file);
    if (artifact.ownership === "user") {
      adapterHashes[artifact.path] = digest(artifact.content);
      if (
        old !== null &&
        previous.adapters?.[artifact.path] !== adapterHashes[artifact.path]
      )
        adapterUpdates.push({
          path: artifact.path,
          requiredAdapter: artifact.content,
        });
      if (old === null)
        changes.push({
          action: "create",
          file,
          relative: artifact.path,
          content: artifact.content,
          expected: null,
        });
      else preserved.push(artifact.path);
      continue;
    }
    if (artifact.ownership !== "generated")
      throw new Error("Unknown artifact ownership");
    const recorded = previous.files[artifact.path];
    if (old !== null && (!recorded || digest(old) !== recorded))
      throw new Error(
        `Refusing to overwrite unowned or edited generated file: ${artifact.path}`,
      );
    next[artifact.path] = digest(artifact.content);
    if (old !== artifact.content)
      changes.push({
        action: old === null ? "create" : "update",
        file,
        relative: artifact.path,
        content: artifact.content,
        expected: old,
      });
  }
  for (const [relative, hash] of Object.entries(previous.files)) {
    if (seen.has(relative)) continue;
    const file = await safePath(root, relative);
    const old = await readOptional(file);
    if (old === null) continue;
    if (digest(old) !== hash)
      throw new Error(`Refusing to remove edited generated file: ${relative}`);
    changes.push({ action: "remove", file, relative, expected: old });
  }
  const manifest =
    JSON.stringify(
      { version: 1, files: next, adapters: adapterHashes },
      null,
      2,
    ) + "\n";
  if (manifest !== previousText)
    changes.push({
      action: previousText === null ? "create" : "update",
      file: manifestPath,
      relative: ".lawspec/generated.json",
      content: manifest,
      expected: previousText,
    });
  return { root, changes, preserved, adapterUpdates };
}
export async function applyWrites(plans) {
  // Recheck every file before the first mutation, including concurrent edits since planning.
  for (const plan of plans)
    for (const change of plan.changes) {
      await safePath(plan.root, change.relative);
      if ((await readOptional(change.file)) !== change.expected)
        throw new Error(`File changed during generation: ${change.relative}`);
    }
  for (const plan of plans)
    for (const change of plan.changes) {
      if (change.action === "remove") await unlink(change.file);
      else
        await atomicWrite(
          change.file,
          change.content,
          change.action === "create",
        );
    }
}
