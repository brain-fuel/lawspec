// Generated from templates/npm/templates.mjs by lawspec-dev generate. Do not edit.
// Project scaffolds, test commands and setup advice for each target. The data
// is LawSpec.Scaffold's, so the npm CLI and the compiler cannot disagree.
export const targets = [
                         "java",
                         "python",
                         "javascript",
                         "typescript",
                         "go",
                         "haskell",
                         "kotlin",
                         "rust"
                       ];

export const commands = {
                          "java": "mvn test",
                          "python": "python -m pytest",
                          "javascript": "node --test test/*.test.mjs",
                          "typescript": "npm exec -- tsc -p tsconfig.json && node --test dist/test/*.test.js",
                          "go": "go test ./...",
                          "haskell": "stack test",
                          "kotlin": "gradle test",
                          "rust": "cargo test"
                        };

export const setup = {
                       "java": "Use JDK 25+, Maven, JetCheck 0.3.0, JUnit Jupiter 5.14.x, compiler plugin 3.14.1+, Surefire 3.5.x, and maven.compiler.release=25; a program that imports lawspec.crypto or lawspec.network also needs Bouncy Castle bcprov-jdk18on 1.86. Run mvn test-compile.",
                       "python": "Use Python 3.13+. Install pytest 8.4.x and Hypothesis 6.x into the selected environment, and, for a program that imports lawspec.crypto or lawspec.network, cryptography 50: python -m pip install -e \".[test]\". Configure pytest pythonpath=[\"src\"] and testpaths=[\"tests\"]. Set the target python field to the interpreter path if needed.",
                       "javascript": "Use Node 22+, package.json type=module, npm install --save-dev fast-check@4.10.2, and for a program that imports lawspec.crypto or lawspec.network npm install @noble/post-quantum@0.7.1.",
                       "typescript": "Use Node 22+, package.json type=module, npm install --save-dev fast-check@4.10.2 typescript@5.9.3 @types/node@22.20.4 (and npm install @noble/post-quantum@0.7.1 for a program that imports lawspec.crypto or lawspec.network). Configure tsconfig.json with module=NodeNext, target=ES2022, rootDir=., outDir=dist, include=[\"src/**/*.ts\",\"test/**/*.ts\"].",
                       "go": "Use Go 1.25+ and go get pgregory.net/rapid@v1.2.0 (and github.com/cloudflare/circl@v1.6.5 for a program that imports lawspec.crypto or lawspec.network), then go mod download.",
                       "haskell": "Use Stack with lts-24.58, directory and time as dependencies (and, for a program that imports lawspec.crypto or lawspec.network, extra-deps crypton-1.1.5, ram-0.22.1, mlkem-0.2.3.0 and mldsa-0.1.1.0 as dependencies too), and test dependencies hspec, hedgehog, hspec-hedgehog, hspec-discover, and a test/Spec.hs using hspec-discover. Run stack build --test --no-run-tests.",
                       "kotlin": "Use JDK 25, Gradle 9.3.0, Kotlin plugin 2.3.21, JVM target 25, Kotest 5.9.1 (runner, assertions, property), and useJUnitPlatform(); a program that imports lawspec.crypto or lawspec.network also needs Bouncy Castle bcprov-jdk18on 1.86. Run gradle testClasses.",
                       "rust": "Use Rust 1.85+ with edition 2024, Proptest 1.11.0, num-bigint 0.4.8, num-rational 0.4.2, num-complex 0.4.6 and num-traits 0.2.19; a program that imports lawspec.crypto or lawspec.network also needs sha3 0.12.0, shake 0.1.0, ml-kem 0.3.2, ml-dsa 0.1.1, slh-dsa 0.2.0-rc.5, aes-gcm 0.11.1 and getrandom 0.4.3. Run cargo test."
                     };

// Each target's build files in the readable and the compact (minified) layout.
const scaffolds = {
                    "java": {
                      "readable": {
                        "pom.xml": "<project\n  xmlns=\"http://maven.apache.org/POM/4.0.0\"\n  xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n  xsi:schemaLocation=\"http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd\">\n  <modelVersion>4.0.0</modelVersion>\n  <groupId>example</groupId>\n  <artifactId>lawspec-example</artifactId>\n  <version>0.1.0</version>\n  <properties>\n    <maven.compiler.release>25</maven.compiler.release>\n    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>\n  </properties>\n  <dependencies>\n    <dependency>\n      <groupId>org.jetbrains</groupId>\n      <artifactId>jetCheck</artifactId>\n      <version>0.3.0</version>\n      <scope>test</scope>\n    </dependency>\n    <dependency>\n      <groupId>org.junit.jupiter</groupId>\n      <artifactId>junit-jupiter</artifactId>\n      <version>5.14.0</version>\n      <scope>test</scope>\n    </dependency>\n  </dependencies>\n  <build>\n    <plugins>\n      <plugin>\n        <groupId>org.apache.maven.plugins</groupId>\n        <artifactId>maven-compiler-plugin</artifactId>\n        <version>3.14.1</version>\n      </plugin>\n      <plugin>\n        <groupId>org.apache.maven.plugins</groupId>\n        <artifactId>maven-surefire-plugin</artifactId>\n        <version>3.5.4</version>\n      </plugin>\n    </plugins>\n  </build>\n</project>\n"
                      },
                      "compact": {
                        "pom.xml": "<project xmlns=\"http://maven.apache.org/POM/4.0.0\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd\"><modelVersion>4.0.0</modelVersion><groupId>example</groupId><artifactId>lawspec-example</artifactId><version>0.1.0</version><properties><maven.compiler.release>25</maven.compiler.release><project.build.sourceEncoding>UTF-8</project.build.sourceEncoding></properties><dependencies><dependency><groupId>org.jetbrains</groupId><artifactId>jetCheck</artifactId><version>0.3.0</version><scope>test</scope></dependency><dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId><version>5.14.0</version><scope>test</scope></dependency></dependencies><build><plugins><plugin><groupId>org.apache.maven.plugins</groupId><artifactId>maven-compiler-plugin</artifactId><version>3.14.1</version></plugin><plugin><groupId>org.apache.maven.plugins</groupId><artifactId>maven-surefire-plugin</artifactId><version>3.5.4</version></plugin></plugins></build></project>\n"
                      }
                    },
                    "python": {
                      "readable": {
                        "pyproject.toml": "[build-system]\nrequires = [\"setuptools==80.9.0\"]\nbuild-backend = \"setuptools.build_meta\"\n\n[project]\nname = \"lawspec-example\"\nversion = \"0.1.0\"\nrequires-python = \">=3.13\"\ndependencies = []\n\n[project.optional-dependencies]\ntest = [\"pytest==8.4.2\", \"hypothesis==6.135.26\"]\n\n[tool.setuptools.packages.find]\nwhere = [\"src\"]\n\n[tool.pytest.ini_options]\npythonpath = [\"src\"]\ntestpaths = [\"tests\"]\n"
                      },
                      "compact": {
                        "pyproject.toml": "[build-system]\nrequires = [\"setuptools==80.9.0\"]\nbuild-backend = \"setuptools.build_meta\"\n\n[project]\nname = \"lawspec-example\"\nversion = \"0.1.0\"\nrequires-python = \">=3.13\"\ndependencies = []\n\n[project.optional-dependencies]\ntest = [\"pytest==8.4.2\", \"hypothesis==6.135.26\"]\n\n[tool.setuptools.packages.find]\nwhere = [\"src\"]\n\n[tool.pytest.ini_options]\npythonpath = [\"src\"]\ntestpaths = [\"tests\"]\n"
                      }
                    },
                    "javascript": {
                      "readable": {
                        "package.json": "{\n  \"name\": \"lawspec-example\",\n  \"version\": \"0.1.0\",\n  \"private\": true,\n  \"type\": \"module\",\n  \"scripts\": {\n    \"test\": \"node --test test/*.test.mjs\"\n  },\n  \"devDependencies\": {\n    \"fast-check\": \"4.10.2\"\n  }\n}\n"
                      },
                      "compact": {
                        "package.json": "{\"name\":\"lawspec-example\",\"version\":\"0.1.0\",\"private\":true,\"type\":\"module\",\"scripts\":{\"test\":\"node --test test/*.test.mjs\"},\"devDependencies\":{\"fast-check\":\"4.10.2\"}}\n"
                      }
                    },
                    "typescript": {
                      "readable": {
                        "package.json": "{\n  \"name\": \"lawspec-example\",\n  \"version\": \"0.1.0\",\n  \"private\": true,\n  \"type\": \"module\",\n  \"scripts\": {\n    \"test\": \"npm exec -- tsc -p tsconfig.json && node --test dist/test/*.test.js\"\n  },\n  \"devDependencies\": {\n    \"fast-check\": \"4.10.2\",\n    \"typescript\": \"5.9.3\",\n    \"@types/node\": \"22.20.4\"\n  }\n}\n",
                        "tsconfig.json": "{\n  \"compilerOptions\": {\n    \"target\": \"ES2022\",\n    \"module\": \"NodeNext\",\n    \"rootDir\": \".\",\n    \"outDir\": \"dist\",\n    \"strict\": true,\n    \"esModuleInterop\": true,\n    \"skipLibCheck\": true\n  },\n  \"include\": [\n    \"src/**/*.ts\",\n    \"test/**/*.ts\"\n  ]\n}\n"
                      },
                      "compact": {
                        "package.json": "{\"name\":\"lawspec-example\",\"version\":\"0.1.0\",\"private\":true,\"type\":\"module\",\"scripts\":{\"test\":\"npm exec -- tsc -p tsconfig.json && node --test dist/test/*.test.js\"},\"devDependencies\":{\"fast-check\":\"4.10.2\",\"typescript\":\"5.9.3\",\"@types/node\":\"22.20.4\"}}\n",
                        "tsconfig.json": "{\"compilerOptions\":{\"target\":\"ES2022\",\"module\":\"NodeNext\",\"rootDir\":\".\",\"outDir\":\"dist\",\"strict\":true,\"esModuleInterop\":true,\"skipLibCheck\":true},\"include\":[\"src/**/*.ts\",\"test/**/*.ts\"]}\n"
                      }
                    },
                    "go": {
                      "readable": {
                        "go.mod": "module example.com/lawspec-example\n\ngo 1.25.0\n\nrequire pgregory.net/rapid v1.2.0\n"
                      },
                      "compact": {
                        "go.mod": "module example.com/lawspec-example\n\ngo 1.25.0\n\nrequire pgregory.net/rapid v1.2.0\n"
                      }
                    },
                    "haskell": {
                      "readable": {
                        "stack.yaml": "snapshot: lts-24.58\npackages: [.]\n",
                        "package.yaml": "name: lawspec-example\nversion: 0.1.0\ndependencies: [base, text, bytestring, containers, network, directory, time]\nlibrary:\n  source-dirs: src\ntests:\n  laws:\n    main: Spec.hs\n    source-dirs: test\n    dependencies: [lawspec-example, hspec, hedgehog, hspec-hedgehog, containers, mtl]\n    build-tools: [hspec-discover]\n",
                        "test/Spec.hs": "{-# OPTIONS_GHC -F -pgmF hspec-discover #-}\n"
                      },
                      "compact": {
                        "stack.yaml": "snapshot: lts-24.58\npackages: [.]\n",
                        "package.yaml": "name: lawspec-example\nversion: 0.1.0\ndependencies: [base, text, bytestring, containers, network, directory, time]\nlibrary:\n  source-dirs: src\ntests:\n  laws:\n    main: Spec.hs\n    source-dirs: test\n    dependencies: [lawspec-example, hspec, hedgehog, hspec-hedgehog, containers, mtl]\n    build-tools: [hspec-discover]\n",
                        "test/Spec.hs": "{-# OPTIONS_GHC -F -pgmF hspec-discover #-}\n"
                      }
                    },
                    "kotlin": {
                      "readable": {
                        "settings.gradle.kts": "rootProject.name = \"lawspec-example\"\n",
                        "build.gradle.kts": "plugins {\n    kotlin(\"jvm\") version \"2.3.21\"\n}\n\nrepositories {\n    mavenCentral()\n}\n\nkotlin {\n    jvmToolchain(25)\n}\n\ndependencies {\n    implementation(\"org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.0\")\n    testImplementation(\"io.kotest:kotest-runner-junit5:5.9.1\")\n    testImplementation(\"io.kotest:kotest-assertions-core:5.9.1\")\n    testImplementation(\"io.kotest:kotest-property:5.9.1\")\n}\n\ntasks.test {\n    useJUnitPlatform()\n}\n"
                      },
                      "compact": {
                        "settings.gradle.kts": "rootProject.name = \"lawspec-example\"\n",
                        "build.gradle.kts": "plugins { kotlin(\"jvm\") version \"2.3.21\" }\nrepositories { mavenCentral() }\nkotlin { jvmToolchain(25) }\ndependencies { implementation(\"org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.0\"); testImplementation(\"io.kotest:kotest-runner-junit5:5.9.1\"); testImplementation(\"io.kotest:kotest-assertions-core:5.9.1\"); testImplementation(\"io.kotest:kotest-property:5.9.1\") }\ntasks.test { useJUnitPlatform() }\n"
                      }
                    },
                    "rust": {
                      "readable": {
                        "src/lib.rs": "// Application library. LawSpec maintains the included module declarations.\ninclude!(\"lawspec_modules.rs\");\n",
                        "Cargo.toml": "[package]\nname = \"lawspec-example\"\nversion = \"0.1.0\"\nedition = \"2024\"\nrust-version = \"1.85\"\npublish = false\n\n[dependencies]\nnum-bigint = \"=0.4.8\"\nnum-rational = \"=0.4.2\"\nnum-complex = \"=0.4.6\"\nnum-traits = \"=0.2.19\"\n\n[dev-dependencies]\nproptest = \"=1.11.0\"\n"
                      },
                      "compact": {
                        "src/lib.rs": "// Application library. LawSpec maintains the included module declarations.\ninclude!(\"lawspec_modules.rs\");\n",
                        "Cargo.toml": "[package]\nname = \"lawspec-example\"\nversion = \"0.1.0\"\nedition = \"2024\"\nrust-version = \"1.85\"\npublish = false\n\n[dependencies]\nnum-bigint = \"=0.4.8\"\nnum-rational = \"=0.4.2\"\nnum-complex = \"=0.4.6\"\nnum-traits = \"=0.2.19\"\n\n[dev-dependencies]\nproptest = \"=1.11.0\"\n"
                      }
                    }
                  };

export function templates(target, { minify = false } = {}) {
  if (typeof minify !== "boolean") throw new Error("minify must be a boolean");
  if (!targets.includes(target)) throw new Error(`Unknown target: ${target}`);
  return { ...scaffolds[target][minify ? "compact" : "readable"] };
}
