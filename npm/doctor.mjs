import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  readFile,
  readdir,
  access,
  mkdtemp,
  rm,
  writeFile,
} from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { setup } from "./templates.mjs";
const exec = promisify(execFile);
const profiles = JSON.parse(
  await readFile(new URL("./compatibility.json", import.meta.url), "utf8"),
).targets;
function versionParts(v) {
  return String(v).replace(/^v/, "").split(".").map(Number);
}
function compare(a, b) {
  const x = versionParts(a),
    y = versionParts(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] || 0) - (y[i] || 0);
    if (d) return Math.sign(d);
  }
  return 0;
}
export function supported(target, dependency, version) {
  const range = profiles[target]?.[dependency];
  return (
    !!range &&
    /^v?\d+(?:\.\d+)*$/.test(String(version)) &&
    compare(version, range[0]) >= 0 &&
    compare(version, range[1]) < 0
  );
}
export async function run(command, args, cwd, extra = {}) {
  const result = await exec(command, args, {
    cwd,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
    timeout: 120000,
    ...extra,
  });
  return result.stdout.replace(/\x1b\[[0-9;]*m/g, "");
}
const major = (version) =>
  Number(String(version).replace(/^v/, "").split(".")[0]);
function requireThat(condition, message) {
  if (!condition) throw new Error(message);
}
async function installed(req, name) {
  let dir = path.dirname(req.resolve(name));
  for (;;) {
    try {
      const pkg = JSON.parse(
        await readFile(path.join(dir, "package.json"), "utf8"),
      );
      if (pkg.name === name) return pkg.version;
    } catch {}
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error(`Cannot resolve installed ${name}`);
    dir = parent;
  }
}
export async function doctor(target, root) {
  const name = target.language;
  const defaults =
    name === "java"
      ? ["src/main/java", "src/test/java"]
      : name === "kotlin"
        ? ["src/main/kotlin", "src/test/kotlin"]
        : ["src", name === "python" ? "tests" : "test"];
  const sourceDir = target.sourceDir ?? defaults[0];
  const testDir = target.testDir ?? defaults[1];
  try {
    requireThat(major(process.versions.node) >= 22, "Node 22+ is required");
    const versions = {};
    if (["javascript", "typescript"].includes(name)) {
      const pkg = JSON.parse(
        await readFile(path.join(root, "package.json"), "utf8"),
      );
      requireThat(
        pkg.type === "module",
        "package.json must specify type=module",
      );
      const req = createRequire(path.join(root, "package.json"));
      versions["fast-check"] = await installed(req, "fast-check");
      requireThat(
        /^4\./.test(versions["fast-check"]),
        "fast-check 4.x is required",
      );
      if (name === "typescript") {
        versions.typescript = await installed(req, "typescript");
        requireThat(
          /^5\.9\./.test(versions.typescript),
          "TypeScript 5.9.x is required",
        );
        const ts = req("typescript");
        const configPath = path.join(root, "tsconfig.json");
        const read = ts.readConfigFile(configPath, ts.sys.readFile);
        requireThat(!read.error, "Cannot read tsconfig.json");
        const config = ts.parseJsonConfigFileContent(read.config, ts.sys, root);
        requireThat(
          config.errors.every((e) => e.code === 18003),
          "Invalid TypeScript configuration",
        );
        requireThat(
          config.options.module === ts.ModuleKind.NodeNext &&
            config.options.outDir === path.join(root, "dist") &&
            config.options.rootDir === root,
          "TypeScript requires module=NodeNext, rootDir=., outDir=dist",
        );
        requireThat(
          !config.options.noEmit &&
            config.options.target >= ts.ScriptTarget.ES2022,
          "TypeScript requires emission and target ES2022+",
        );
        requireThat(
          config.raw.include?.includes(`${sourceDir}/**/*.ts`) &&
            config.raw.include?.includes(`${testDir}/**/*.ts`),
          "TypeScript must include the configured source and test directories",
        );
        requireThat(
          !config.raw.exclude ||
            config.raw.exclude.every((p) =>
              ["node_modules", "dist"].includes(p),
            ),
          "Custom TypeScript exclusions cannot be verified",
        );
        versions["@types/node"] = JSON.parse(
          await readFile(req.resolve("@types/node/package.json"), "utf8"),
        ).version;
        requireThat(
          major(versions["@types/node"]) >= 22,
          "@types/node 22+ is required",
        );
      }
    } else if (name === "python") {
      const script = `import sys,json,importlib.metadata as m,tomllib,pathlib\np=tomllib.loads(pathlib.Path('pyproject.toml').read_text())\nprint(json.dumps({'python':'.'.join(map(str,sys.version_info[:3])),'pytest':m.version('pytest'),'hypothesis':m.version('hypothesis'),'config':p.get('tool',{}).get('pytest',{}).get('ini_options',{})}))`;
      Object.assign(
        versions,
        JSON.parse(await run(target.python || "python3", ["-c", script], root)),
      );
      requireThat(
        major(versions.python) === 3 &&
          Number(versions.python.split(".")[1]) >= 13,
        "Python 3.13+ is required",
      );
      requireThat(
        /^8\.4\./.test(versions.pytest) && /^6\./.test(versions.hypothesis),
        "pytest 8.4.x and Hypothesis 6.x are required",
      );
      requireThat(
        versions.config.pythonpath?.includes(sourceDir) &&
          versions.config.testpaths?.includes(testDir),
        "pytest must include the configured source and test directories",
      );
      requireThat(
        !versions.config.addopts &&
          !versions.config.python_files &&
          !versions.config.python_functions,
        "Custom pytest selection options cannot be verified",
      );
      requireThat(
        !process.env.PYTEST_ADDOPTS,
        "Clear PYTEST_ADDOPTS before compatibility checks",
      );
      delete versions.config;
    } else if (name === "go") {
      versions.go = (await run("go", ["version"], root)).match(
        /go(\d+\.\d+(?:\.\d+)?)/,
      )?.[1];
      requireThat(
        versions.go && Number(versions.go.split(".")[1]) >= 22,
        "Go 1.22+ is required",
      );
      const data = JSON.parse(
        await run(
          "go",
          ["list", "-mod=readonly", "-m", "-json", "pgregory.net/rapid"],
          root,
          { env: { ...process.env, GOTOOLCHAIN: "local", GOFLAGS: "" } },
        ),
      );
      requireThat(
        !data.Replace && data.Version === "v1.2.0",
        "Rapid v1.2.0 without local replacement is required",
      );
      await run("go", ["list", "-mod=readonly", "pgregory.net/rapid"], root, {
        env: { ...process.env, GOTOOLCHAIN: "local", GOFLAGS: "" },
      });
      versions.rapid = data.Version;
    } else if (name === "haskell") {
      const compiler = (
        await run(
          "stack",
          [
            "--no-terminal",
            "--no-install-ghc",
            "--with-hpack",
            fileURLToPath(new URL("./read-only-hpack.mjs", import.meta.url)),
            "--lock-file",
            "read-only",
            "path",
            "--compiler-exe",
          ],
          root,
        )
      ).trim();
      await access(compiler);
      versions.ghc = (await run(compiler, ["--numeric-version"], root)).trim();
      const deps = JSON.parse(
        await run(
          "stack",
          [
            "--no-terminal",
            "--with-hpack",
            fileURLToPath(new URL("./read-only-hpack.mjs", import.meta.url)),
            "--lock-file",
            "read-only",
            "ls",
            "dependencies",
            "json",
            "--test",
            "--global-hints",
          ],
          root,
        ),
      );
      for (const dep of deps) versions[dep.name] = dep.version;
      for (const dep of [
        "hspec",
        "hedgehog",
        "hspec-hedgehog",
        "hspec-discover",
      ])
        requireThat(versions[dep], `Stack test plan is missing ${dep}`);
      requireThat(
        /^2\.11\./.test(versions.hspec) &&
          /^1\./.test(versions.hedgehog) &&
          /^0\.3\./.test(versions["hspec-hedgehog"]),
        "Unsupported Hspec/Hedgehog combination; use lts-24.58",
      );
      const entry = await readFile(path.join(root, testDir, "Spec.hs"), "utf8");
      requireThat(
        entry.includes("hspec-discover"),
        "test/Spec.hs must use hspec-discover",
      );
      const cabals = (await readdir(root)).filter((f) => f.endsWith(".cabal"));
      requireThat(
        cabals.length === 1,
        "The Stack profile requires one package per target root",
      );
      const cabal = await readFile(path.join(root, cabals[0]), "utf8");
      const suites = cabal
        .split(/^test-suite\s+/m)
        .slice(1)
        .map((s) => s.split(/\n(?=\S)/)[0]);
      requireThat(
        suites.some(
          (s) =>
            ["hspec", "hedgehog", "hspec-hedgehog"].every((dep) =>
              new RegExp(`(?:^|[\\s,])${dep}(?=[\\s,<>=]|$)`).test(s),
            ) &&
            s.includes(testDir) &&
            s.includes("Spec.hs"),
        ),
        "A test suite must directly depend on Hspec/Hedgehog and discover the configured test directory",
      );
    } else if (name === "java") {
      const cmd = target.maven || "mvn";
      const version = await run(cmd, ["-version"], root);
      versions.java = version.match(/Java version:\s*([\d.]+)/)?.[1];
      requireThat(major(versions.java) >= 25, "Maven must run on Java 25+");
      const pom = await run(cmd, ["help:effective-pom"], root);
      const plugins = [...pom.matchAll(/<plugin>([\s\S]*?)<\/plugin>/g)].map(
        (m) => m[1],
      );
      const compiler =
        plugins
          .filter((p) =>
            p.includes("<artifactId>maven-compiler-plugin</artifactId>"),
          )
          .at(-1) || "";
      requireThat(
        /<version>3\.(?:14|15)\./.test(compiler),
        "Maven compiler plugin 3.14.x or 3.15.x is required",
      );
      requireThat(
        !/<(?:jdkToolchain|executable|jvm)>/.test(pom),
        "Custom JVM/toolchain overrides cannot be verified by the v0.1 Maven profile",
      );
      requireThat(
        !/<(?:release|testRelease)>((?!25<)[^<]+)<\//.test(compiler),
        "All effective compiler releases must be 25",
      );
      requireThat(
        /<(?:maven\.compiler\.release|release)>25<\//.test(pom),
        "The effective Maven compiler release must be 25",
      );
      requireThat(
        pom.includes(
          `<sourceDirectory>${path.join(root, sourceDir)}</sourceDirectory>`,
        ) &&
          pom.includes(
            `<testSourceDirectory>${path.join(root, testDir)}</testSourceDirectory>`,
          ),
        "Maven source directories must match the configured LawSpec layout",
      );
      const tree = await run(
        cmd,
        ["dependency:tree", "-Dscope=test", "-DoutputType=text"],
        root,
      );
      for (const [key, pattern] of Object.entries({
        jetCheck: /org\.jetbrains:jetCheck:jar:(0\.3\.0):test/,
        "junit-jupiter":
          /org\.junit\.jupiter:junit-jupiter(?:-api)?:jar:(5\.14\.\d+):test/,
      })) {
        versions[key] = tree.match(pattern)?.[1];
        requireThat(versions[key], `Missing compatible resolved ${key}`);
      }
      requireThat(
        /<artifactId>maven-surefire-plugin<\/artifactId>\s*<version>3\.5\./.test(
          pom,
        ),
        "Surefire 3.5.x is required",
      );
      requireThat(
        !/<skipTests>true<\/skipTests>|<maven.test.skip>true<\/maven.test.skip>/.test(
          pom,
        ),
        "Maven test execution is disabled",
      );
      const surefire =
        plugins
          .filter((p) =>
            p.includes("<artifactId>maven-surefire-plugin</artifactId>"),
          )
          .at(-1) || "";
      requireThat(
        !/<(?:includes|excludes|groups|excludedGroups)>|<(?:skip|testFailureIgnore)>true</.test(
          surefire,
        ),
        "Custom Surefire filtering or ignored failures cannot be verified",
      );
      requireThat(
        /org\.junit\.jupiter:junit-jupiter-engine:jar:5\.14\.\d+:test/.test(
          tree,
        ),
        "The JUnit Jupiter test engine must be on the test classpath",
      );
    } else if (name === "kotlin") {
      const command =
        target.gradle ||
        (await access(path.join(root, "gradlew")).then(
          () => path.join(root, "gradlew"),
          () => "gradle",
        ));
      const tmp = await mkdtemp(path.join(os.tmpdir(), "lawspec-gradle-"));
      try {
        const report = path.join(tmp, "report.json");
        const init = path.join(tmp, "inspect.gradle");
        await writeFile(
          init,
          `import groovy.json.JsonOutput\ngradle.projectsEvaluated {\n def p = gradle.rootProject\n p.tasks.register('lawspecEnvironmentReport') { doLast {\n def k = p.tasks.findByName('compileTestKotlin')\n def j = p.tasks.findByName('test')\n def plugin = p.plugins.findPlugin('org.jetbrains.kotlin.jvm')\n def kv = plugin.class.classLoader.loadClass('org.jetbrains.kotlin.gradle.plugin.KotlinPluginWrapperKt').getMethod('getKotlinPluginVersion', org.gradle.api.Project).invoke(null, p)\n def deps = p.configurations.testRuntimeClasspath.resolvedConfiguration.resolvedArtifacts.collect { [name: it.moduleVersion.id.group + ':' + it.name, version: it.moduleVersion.id.version] }\n new File(System.getenv('LAWSPEC_REPORT')).text = JsonOutput.toJson([kotlin: kv, gradle: gradle.gradleVersion, java: System.getProperty('java.version'), target: k?.compilerOptions?.jvmTarget?.get()?.target, testJava: j?.javaLauncher?.get()?.metadata?.languageVersion?.asInt(), runner: j?.options?.class?.name, enabled: j.enabled, includes: j.filter.includePatterns, excludes: j.filter.excludePatterns, sourceDirs: p.sourceSets.main.allSource.srcDirs.collect { it.canonicalPath }, testDirs: p.sourceSets.test.allSource.srcDirs.collect { it.canonicalPath }, dependencies: deps])\n } }\n}\n`,
        );
        await run(
          command,
          [
            "--no-daemon",
            "--console=plain",
            "-I",
            init,
            "lawspecEnvironmentReport",
          ],
          root,
          { env: { ...process.env, LAWSPEC_REPORT: report } },
        );
        const data = JSON.parse(await readFile(report, "utf8"));
        requireThat(
          /^9\.[1-3]\./.test(data.gradle) &&
            major(data.java) >= 25 &&
            Number(data.target) >= 25 &&
            data.testJava >= 25,
          "Kotlin requires Gradle 9.1–9.3 and Java/JVM target/test runtime 25+",
        );
        requireThat(
          data.runner?.includes("JUnitPlatform") &&
            data.enabled &&
            !data.includes.length &&
            !data.excludes.length,
          "Gradle test must enable unfiltered JUnit Platform execution",
        );
        requireThat(
          data.sourceDirs.includes(path.join(root, sourceDir)) &&
            data.testDirs.includes(path.join(root, testDir)),
          "Gradle source sets must include the configured LawSpec directories",
        );
        for (const dep of [
          "io.kotest:kotest-property-jvm",
          "io.kotest:kotest-runner-junit5-jvm",
          "io.kotest:kotest-assertions-core-jvm",
        ])
          requireThat(
            data.dependencies.some(
              (d) => d.name === dep && d.version === "5.9.1",
            ),
            `Missing ${dep}:5.9.1`,
          );
        Object.assign(versions, data);
        requireThat(
          data.kotlin,
          "Cannot determine the Kotlin Gradle plugin version",
        );
      } finally {
        await rm(tmp, { recursive: true, force: true });
      }
    } else throw new Error(`Unsupported target ${name}`);
    for (const dependency of Object.keys(profiles[name] || {}))
      requireThat(
        supported(name, dependency, versions[dependency]),
        `${dependency} ${versions[dependency] || "(unknown)"} is outside the verified ${name} profile [${profiles[name][dependency].join(", ")})`,
      );
    return { target: name, ok: true, versions };
  } catch (error) {
    return {
      target: name,
      ok: false,
      message: String(error.message).slice(0, 4000),
      instructions: setup[name],
    };
  }
}
