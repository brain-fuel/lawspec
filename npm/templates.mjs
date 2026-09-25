export const targets = [
  "java",
  "python",
  "javascript",
  "typescript",
  "go",
  "haskell",
  "kotlin",
];
export const commands = {
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
const json = (value) => JSON.stringify(value, null, 2) + "\n";
export function templates(target) {
  if (!targets.includes(target)) throw new Error(`Unknown target: ${target}`);
  const commonPackage = {
    name: "lawspec-example",
    version: "0.1.0",
    private: true,
    type: "module",
  };
  switch (target) {
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
        "pom.xml": `<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion><groupId>example</groupId><artifactId>lawspec-example</artifactId><version>0.1.0</version>
  <properties><maven.compiler.release>25</maven.compiler.release><project.build.sourceEncoding>UTF-8</project.build.sourceEncoding></properties>
  <dependencies>
    <dependency><groupId>org.jetbrains</groupId><artifactId>jetCheck</artifactId><version>0.3.0</version><scope>test</scope></dependency>
    <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId><version>5.14.0</version><scope>test</scope></dependency>
  </dependencies>
  <build><plugins>
    <plugin><groupId>org.apache.maven.plugins</groupId><artifactId>maven-compiler-plugin</artifactId><version>3.14.1</version></plugin>
    <plugin><groupId>org.apache.maven.plugins</groupId><artifactId>maven-surefire-plugin</artifactId><version>3.5.4</version></plugin>
  </plugins></build>
</project>\n`,
      };
    case "go":
      return {
        "go.mod":
          "module example.com/lawspec-example\n\ngo 1.22\n\nrequire pgregory.net/rapid v1.2.0\n",
      };
    case "haskell":
      return {
        "stack.yaml": "snapshot: lts-24.58\npackages: [.]\n",
        "package.yaml": `name: lawspec-example\nversion: 0.1.0\ndependencies: [base, text, bytestring]\nlibrary:\n  source-dirs: src\ntests:\n  laws:\n    main: Spec.hs\n    source-dirs: test\n    dependencies: [lawspec-example, hspec, hedgehog, hspec-hedgehog]\n    build-tools: [hspec-discover]\n`,
        "test/Spec.hs": "{-# OPTIONS_GHC -F -pgmF hspec-discover #-}\n",
      };
    case "kotlin":
      return {
        "settings.gradle.kts": 'rootProject.name = "lawspec-example"\n',
        "build.gradle.kts": `plugins { kotlin("jvm") version "2.3.21" }\nrepositories { mavenCentral() }\nkotlin { jvmToolchain(25) }\ndependencies {\n  testImplementation("io.kotest:kotest-runner-junit5:5.9.1")\n  testImplementation("io.kotest:kotest-assertions-core:5.9.1")\n  testImplementation("io.kotest:kotest-property:5.9.1")\n}\ntasks.test { useJUnitPlatform() }\n`,
      };
  }
}
