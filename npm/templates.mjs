export const targets = [
  "java",
  "python",
  "javascript",
  "typescript",
  "go",
  "haskell",
  "kotlin",
  "rust",
];
export const commands = {
  rust: "cargo test",
  java: "mvn test",
  python: "python -m pytest",
  javascript: "node --test test/*.test.mjs",
  typescript:
    "npm exec -- tsc -p tsconfig.json && node --test dist/test/*.test.js",
  go: "go test ./...",
  haskell: "stack test",
  kotlin: "gradle test",
};
export const setup = {
  rust: "Use Rust 1.85+ with edition 2024, Proptest 1.11.0, num-bigint 0.4.8, num-rational 0.4.2, num-complex 0.4.6, and num-traits 0.2.19. Run cargo test.",
  java: "Use JDK 25+, Maven, JetCheck 0.3.0, JUnit Jupiter 5.14.x, compiler plugin 3.14.1+, Surefire 3.5.x, and maven.compiler.release=25. Run mvn test-compile.",
  python:
    'Use Python 3.13+. Install pytest 8.4.x and Hypothesis 6.x into the selected environment: python -m pip install -e ".[test]". Configure pytest pythonpath=["src"] and testpaths=["tests"]. Set the target python field to the interpreter path if needed.',
  javascript:
    "Use Node 22+, package.json type=module, and npm install --save-dev fast-check@4.10.2.",
  typescript:
    'Use Node 22+, package.json type=module, and npm install --save-dev fast-check@4.10.2 typescript@5.9.3 @types/node@22.20.4. Configure tsconfig.json with module=NodeNext, target=ES2022, rootDir=., outDir=dist, include=["src/**/*.ts","test/**/*.ts"].',
  go: "Use Go 1.22+ and go get pgregory.net/rapid@v1.2.0, then go mod download.",
  haskell:
    "Use Stack with lts-24.58 and test dependencies hspec, hedgehog, hspec-hedgehog, hspec-discover, and a test/Spec.hs using hspec-discover. Run stack build --test --no-run-tests.",
  kotlin:
    "Use JDK 25, Gradle 9.3.0, Kotlin plugin 2.3.21, JVM target 25, Kotest 5.9.1 (runner, assertions, property), and useJUnitPlatform(). Run gradle testClasses.",
};
// These render known scaffold structure; they never reformat user source.
const element = (name, value, attributes = {}) => ({ name, value, attributes });
const xmlEscape = (text) =>
  String(text)
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
function renderXml(node, minify, depth = 0) {
  const indent = minify ? "" : "  ".repeat(depth);
  const attributes = Object.entries(node.attributes).map(
    ([key, value]) => `${key}="${xmlEscape(value)}"`,
  );
  const open = `<${node.name}${
    attributes.length === 0
      ? ""
      : minify
        ? " " + attributes.join(" ")
        : "\n" + attributes.map((a) => indent + "  " + a).join("\n")
  }>`;
  if (!Array.isArray(node.value)) {
    return `${indent}${open}${xmlEscape(node.value)}</${node.name}>`;
  }
  const children = node.value.map((child) =>
    renderXml(child, minify, depth + 1),
  );
  return minify
    ? `${open}${children.join("")}</${node.name}>`
    : `${indent}${open}\n${children.join("\n")}\n${indent}</${node.name}>`;
}
function mavenProject(minify) {
  const fields = (values) =>
    Object.entries(values).map(([name, value]) => element(name, value));
  const dependency = (groupId, artifactId, version) =>
    element(
      "dependency",
      fields({ groupId, artifactId, version, scope: "test" }),
    );
  const plugin = (artifactId, version) =>
    element(
      "plugin",
      fields({ groupId: "org.apache.maven.plugins", artifactId, version }),
    );
  return (
    renderXml(
      element(
        "project",
        [
          ...fields({
            modelVersion: "4.0.0",
            groupId: "example",
            artifactId: "lawspec-example",
            version: "0.1.0",
          }),
          element(
            "properties",
            fields({
              "maven.compiler.release": "25",
              "project.build.sourceEncoding": "UTF-8",
            }),
          ),
          element("dependencies", [
            dependency("org.jetbrains", "jetCheck", "0.3.0"),
            dependency("org.junit.jupiter", "junit-jupiter", "5.14.0"),
          ]),
          element("build", [
            element("plugins", [
              plugin("maven-compiler-plugin", "3.14.1"),
              plugin("maven-surefire-plugin", "3.5.4"),
            ]),
          ]),
        ],
        {
          xmlns: "http://maven.apache.org/POM/4.0.0",
          "xmlns:xsi": "http://www.w3.org/2001/XMLSchema-instance",
          "xsi:schemaLocation":
            "http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd",
        },
      ),
      minify,
    ) + "\n"
  );
}
export function templates(target, { minify = false } = {}) {
  if (typeof minify !== "boolean") throw new Error("minify must be a boolean");
  const json = (value) =>
    JSON.stringify(value, null, minify ? undefined : 2) + "\n";
  const kotlinBlock = (name, statements) =>
    minify
      ? `${name} { ${statements.join("; ")} }`
      : `${name} {\n${statements.map((line) => "    " + line).join("\n")}\n}`;
  if (!targets.includes(target)) throw new Error(`Unknown target: ${target}`);
  const commonPackage = {
    name: "lawspec-example",
    version: "0.1.0",
    private: true,
    type: "module",
  };
  switch (target) {
    case "rust":
      return {
        "src/lib.rs":
          '// Application library. LawSpec maintains the included module declarations.\ninclude!("lawspec_modules.rs");\n',
        "Cargo.toml": `[package]
name = "lawspec-example"
version = "0.1.0"
edition = "2024"
rust-version = "1.85"
publish = false

[dependencies]
num-bigint = "=0.4.8"
num-rational = "=0.4.2"
num-complex = "=0.4.6"
num-traits = "=0.2.19"

[dev-dependencies]
proptest = "=1.11.0"
`,
      };

    case "javascript":
      return {
        "package.json": json({
          ...commonPackage,
          scripts: { test: commands.javascript },
          devDependencies: { "fast-check": "4.10.2" },
        }),
      };
    case "typescript":
      return {
        "package.json": json({
          ...commonPackage,
          scripts: { test: commands.typescript },
          devDependencies: {
            "fast-check": "4.10.2",
            typescript: "5.9.3",
            "@types/node": "22.20.4",
          },
        }),
        "tsconfig.json": json({
          compilerOptions: {
            target: "ES2022",
            module: "NodeNext",
            rootDir: ".",
            outDir: "dist",
            strict: true,
            esModuleInterop: true,
            skipLibCheck: true,
          },
          include: ["src/**/*.ts", "test/**/*.ts"],
        }),
      };
    case "python":
      return {
        "pyproject.toml": `[build-system]\nrequires = ["setuptools==80.9.0"]\nbuild-backend = "setuptools.build_meta"\n\n[project]\nname = "lawspec-example"\nversion = "0.1.0"\nrequires-python = ">=3.13"\n\n[project.optional-dependencies]\ntest = ["pytest==8.4.2", "hypothesis==6.135.26"]\n\n[tool.setuptools.packages.find]\nwhere = ["src"]\n\n[tool.pytest.ini_options]\npythonpath = ["src"]\ntestpaths = ["tests"]\n`,
      };
    case "java":
      return {
        "pom.xml": mavenProject(minify),
      };
    case "go":
      return {
        "go.mod":
          "module example.com/lawspec-example\n\ngo 1.22\n\nrequire pgregory.net/rapid v1.2.0\n",
      };
    case "haskell":
      return {
        "stack.yaml": "snapshot: lts-24.58\npackages: [.]\n",
        "package.yaml": `name: lawspec-example\nversion: 0.1.0\ndependencies: [base, text, bytestring]\nlibrary:\n  source-dirs: src\ntests:\n  laws:\n    main: Spec.hs\n    source-dirs: test\n    dependencies: [lawspec-example, hspec, hedgehog, hspec-hedgehog, containers, mtl]\n    build-tools: [hspec-discover]\n`,
        "test/Spec.hs": "{-# OPTIONS_GHC -F -pgmF hspec-discover #-}\n",
      };
    case "kotlin":
      return {
        "settings.gradle.kts": 'rootProject.name = "lawspec-example"\n',
        "build.gradle.kts":
          [
            kotlinBlock("plugins", ['kotlin("jvm") version "2.3.21"']),
            kotlinBlock("repositories", ["mavenCentral()"]),
            kotlinBlock("kotlin", ["jvmToolchain(25)"]),
            kotlinBlock("dependencies", [
              'testImplementation("io.kotest:kotest-runner-junit5:5.9.1")',
              'testImplementation("io.kotest:kotest-assertions-core:5.9.1")',
              'testImplementation("io.kotest:kotest-property:5.9.1")',
            ]),
            kotlinBlock("tasks.test", ["useJUnitPlatform()"]),
          ].join(minify ? "\n" : "\n\n") + "\n",
      };
  }
}
