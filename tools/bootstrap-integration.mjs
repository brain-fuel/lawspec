// Initializes isolated reference projects; dependency installation is explicit developer tooling.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { access, readFile, writeFile, mkdir, copyFile } from "node:fs/promises";
import path from "node:path";
import { targets } from "../npm/templates.mjs";
const exec = promisify(execFile);
const repo = path.resolve(import.meta.dirname, "..");
async function run(cmd, args, cwd) {
  console.log(`${path.basename(cwd)}: ${cmd} ${args.join(" ")}`);
  try {
    return await exec(cmd, args, {
      cwd,
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024,
      timeout: 300000,
    });
  } catch (e) {
    throw new Error(`${cmd}: ${e.stdout}\n${e.stderr}`);
  }
}
async function setup(target) {
  if (!targets.includes(target)) throw new Error(`Unknown target ${target}`);
  const root = path.join(repo, ".integration", target);
  const configPath = path.join(root, "lawspec.json");
  const exists = await access(configPath).then(
    () => true,
    () => false,
  );
  if (!exists)
    await run(
      process.execPath,
      [
        path.join(repo, "npm/bin/lawspec.mjs"),
        "init",
        "--target",
        target,
        "--config",
        configPath,
      ],
      repo,
    );
  const config = JSON.parse(await readFile(configPath, "utf8"));
  if (["javascript", "typescript"].includes(target)) {
    const lock = path.join(repo, "test/locks", target, "package-lock.json");
    if (
      await access(lock).then(
        () => true,
        () => false,
      )
    ) {
      await copyFile(lock, path.join(root, "package-lock.json"));
      await run(
        "npm",
        ["ci", "--ignore-scripts", "--no-audit", "--no-fund"],
        root,
      );
    } else
      await run(
        "npm",
        ["install", "--ignore-scripts", "--no-audit", "--no-fund"],
        root,
      );
  } else if (target === "python") {
    await mkdir(path.join(root, "src"), { recursive: true });
    await run(
      "uv",
      [
        "venv",
        "--allow-existing",
        "--python",
        process.env.LAWSPEC_PYTHON || "3.13",
        ".venv",
      ],
      root,
    );
    config.targets[0].python = path.join(root, ".venv/bin/python");
    await run(
      "uv",
      [
        "pip",
        "install",
        "--python",
        config.targets[0].python,
        "-c",
        path.join(repo, "test/locks/python.txt"),
        "-e",
        ".[test]",
      ],
      root,
    );
  } else if (target === "rust")
    await run("cargo", ["fetch"], root);
  else if (target === "java")
    await run("mvn", ["-B", "-q", "test-compile"], root);
  else if (target === "go")
    await run("go", ["mod", "download", "pgregory.net/rapid"], root);
  else if (target === "haskell") {
    await mkdir(path.join(root, "src"), { recursive: true });
    await run(
      "stack",
      ["--no-terminal", "build", "--test", "--no-run-tests"],
      root,
    );
  } else if (target === "kotlin") {
    config.targets[0].gradle =
      process.env.LAWSPEC_GRADLE || config.targets[0].gradle || "gradle";
    await run(
      config.targets[0].gradle,
      ["--no-daemon", "--console=plain", "testClasses"],
      root,
    );
  }
  await writeFile(configPath, JSON.stringify(config, null, 2) + "\n");
}
const chosen = process.argv.slice(2);
const results = await Promise.allSettled(
  (chosen.length ? chosen : targets).map(setup),
);
for (const r of results)
  if (r.status === "rejected") {
    console.error(r.reason);
    process.exitCode = 1;
  }
