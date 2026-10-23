// Generated from templates/tools/bootstrap-integration.mjs by lawspec-dev generate. Do not edit.
// Initializes isolated reference projects; dependency installation is explicit developer tooling.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { access, readFile, writeFile, mkdir, copyFile } from "node:fs/promises";
import path from "node:path";
import { programTargets as targets, templates } from "../npm/templates.mjs";
const exec = promisify(execFile);
const repo = path.resolve(import.meta.dirname, "..");
async function run(cmd, args, cwd, environment = {}) {
  console.log(`${path.basename(cwd)}: ${cmd} ${args.join(" ")}`);
  try {
    return await exec(cmd, args, {
      cwd,
      env: { ...process.env, ...environment },
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
  // An existing project may predate a scaffold file; restore any that are
  // missing without touching files already present.
  for (const [file, content] of Object.entries(templates(target))) {
    const destination = path.join(root, file);
    if (!(await access(destination).then(() => true, () => false))) {
      await mkdir(path.dirname(destination), { recursive: true });
      await writeFile(destination, content);
    }
  }
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
      // The environment serves every suite, including those that import
      // lawspec.crypto or lawspec.network, so it declares the lock's packages,
      // which a project scaffolded without crypto leaves out; npm ci would
      // otherwise skip them.
      const declared = JSON.parse(await readFile(lock, "utf8")).packages[""];
      const manifestPath = path.join(root, "package.json");
      const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
      for (const field of ["dependencies", "devDependencies"])
        if (declared[field]) manifest[field] = { ...manifest[field], ...declared[field] };
      await writeFile(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
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
  } else if (target === "python" || target === "prolog") {
    if (target === "prolog") await run("swipl", ["--version"], root);
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
        path.join(repo, "test/locks", target === "prolog" ? "prolog.txt" : "python.txt"),
        "-e",
        ".[test]",
        // For the suites that import lawspec.crypto or lawspec.network.
        "cryptography",
        // Acceptance checks generated Python with ruff format (pinned in the lock).
        ...(target === "python" ? ["ruff"] : []),
      ],
      root,
    );
  } else if (target === "rust") {
    await run("cargo", ["fetch"], root);
    // Acceptance checks generated Rust with the pinned toolchain's rustfmt
    // (acceptance/Toolchain.hs).
    await run("rustup", ["component", "add", "--toolchain", "1.97.1", "rustfmt"], root);
  }
  else if (target === "java")
    await run("mvn", ["-B", "-q", "test-compile"], root);
  else if (target === "go")
    // circl by version: a project scaffolded without crypto does not require it,
    // but the suites that import lawspec.crypto or lawspec.network do.
    await run("go", ["mod", "download", "pgregory.net/rapid", "github.com/cloudflare/circl@v1.6.5"], root);
  else if (target === "haskell") {
    await mkdir(path.join(root, "src"), { recursive: true });
    await run(
      "stack",
      ["--no-terminal", "build", "--test", "--no-run-tests"],
      root,
    );
  } else if (target === "clojure") {
    await run("clojure", ["-P", "-M:test"], root);
  } else if (target === "kotlin" || target === "groovy") {
    config.targets[0].gradle =
      process.env.LAWSPEC_GRADLE || config.targets[0].gradle || "gradle";
    await run(
      config.targets[0].gradle,
      ["--no-daemon", "--console=plain", "testClasses"],
      root,
    );
  } else if (target === "scala") {
    config.targets[0].scala = process.env.LAWSPEC_SCALA || config.targets[0].scala || "scala";
    // Fetches Scala, ScalaCheck and ScalaTest, and starts the build server.
    await run(config.targets[0].scala, ["compile", "--test", "."], root);
  } else if (["erlang", "elixir", "gleam"].includes(target)) {
    const lockName = {erlang: "rebar.lock", elixir: "mix.lock", gleam: "manifest.toml"}[target];
    await copyFile(path.join(repo, "test/locks", target, lockName), path.join(root, lockName));
    await mkdir(path.join(root, "src"), {recursive: true});
    if (target === "erlang") await run("rebar3", ["as", "test", "compile"], root);
    if (target === "elixir") {
      await run("mix", ["deps.get"], root);
      await run("mix", ["compile"], root, {MIX_ENV: "test"});
    }
    if (target === "gleam") await run("gleam", ["build"], root);
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
