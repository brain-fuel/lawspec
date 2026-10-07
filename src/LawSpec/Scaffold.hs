-- | Build-file scaffolds for generated projects. These render known project
-- structure only; they never reformat user source. The readable layout is the
-- default, and minify selects the compact form, as for generated code.
module LawSpec.Scaffold
  ( scaffoldTargets, testCommand, setupAdvice, scaffoldFiles, scaffoldFilesWith
  ) where

import Data.List (intercalate)

-- | The order users see the targets in everywhere: the CLI, the generated npm
-- facts and the docs read this one list. ref:DEC-generated-javascript
scaffoldTargets :: [String]
scaffoldTargets = ["java", "python", "javascript", "typescript", "go", "haskell", "kotlin", "rust"]

-- | Each target's tests run with its own build tool, so a generated project is
-- tested the way its developers already test. ref:DEC-native-property-frameworks
testCommand :: String -> Maybe String
testCommand target = lookup target
  [ ("rust", "cargo test")
  , ("java", "mvn test")
  , ("python", "python -m pytest")
  , ("javascript", "node --test test/*.test.mjs")
  , ("typescript", "npm exec -- tsc -p tsconfig.json && node --test dist/test/*.test.js")
  , ("go", "go test ./...")
  , ("haskell", "stack test")
  , ("kotlin", "gradle test") ]

-- | The pinned toolchain each target is verified against, stated once so doctor,
-- the CLI and the docs give the same advice.
setupAdvice :: String -> Maybe String
setupAdvice target = lookup target
  [ ("rust", "Use Rust 1.85+ with edition 2024, Proptest 1.11.0, num-bigint 0.4.8, num-rational 0.4.2, num-complex 0.4.6 and num-traits 0.2.19; a program that imports lawspec.crypto, lawspec.network or lawspec.randomness also needs sha3 0.12.0, shake 0.1.0, ml-kem 0.3.2, ml-dsa 0.1.1, slh-dsa 0.2.0-rc.5, aes-gcm 0.11.1 and getrandom 0.4.3. Run cargo test.")
  , ("java", "Use JDK 25+, Maven, JetCheck 0.3.0, JUnit Jupiter 5.14.x, compiler plugin 3.14.1+, Surefire 3.5.x, and maven.compiler.release=25; a program that imports lawspec.crypto or lawspec.network also needs Bouncy Castle bcprov-jdk18on 1.86. Run mvn test-compile.")
  , ("python", "Use Python 3.13+. Install pytest 8.4.x and Hypothesis 6.x into the selected environment, and, for a program that imports lawspec.crypto or lawspec.network, cryptography 50: python -m pip install -e \".[test]\". Configure pytest pythonpath=[\"src\"] and testpaths=[\"tests\"]. Set the target python field to the interpreter path if needed.")
  , ("javascript", "Use Node 22+, package.json type=module, npm install --save-dev fast-check@4.10.2, and for a program that imports lawspec.crypto or lawspec.network npm install @noble/post-quantum@0.7.1.")
  , ("typescript", "Use Node 22+, package.json type=module, npm install --save-dev fast-check@4.10.2 typescript@5.9.3 @types/node@22.20.4 (and npm install @noble/post-quantum@0.7.1 for a program that imports lawspec.crypto or lawspec.network). Configure tsconfig.json with module=NodeNext, target=ES2022, rootDir=., outDir=dist, include=[\"src/**/*.ts\",\"test/**/*.ts\"].")
  , ("go", "Use Go 1.25+ and go get pgregory.net/rapid@v1.2.0 (and github.com/cloudflare/circl@v1.6.5 for a program that imports lawspec.crypto or lawspec.network), then go mod download.")
  , ("haskell", "Use Stack with lts-24.58, directory and time as dependencies (and, for a program that imports lawspec.crypto, lawspec.network or lawspec.randomness, extra-deps crypton-1.1.5, ram-0.22.1, mlkem-0.2.3.0 and mldsa-0.1.1.0 as dependencies too), and test dependencies hspec, hedgehog, hspec-hedgehog, hspec-discover, and a test/Spec.hs using hspec-discover. Run stack build --test --no-run-tests.")
  , ("kotlin", "Use JDK 25, Gradle 9.3.0, Kotlin plugin 2.3.21, JVM target 25, Kotest 5.9.1 (runner, assertions, property), and useJUnitPlatform(); a program that imports lawspec.crypto or lawspec.network also needs Bouncy Castle bcprov-jdk18on 1.86. Run gradle testClasses.") ]

-- | Files in the order the project is written, for a program that uses no
-- crypto library (lawspec init's).
scaffoldFiles :: Bool -> String -> Either String [(FilePath, String)]
scaffoldFiles = scaffoldFilesWith False

-- With crypto: the libraries of lawspec.crypto's default handlers and of
-- lawspec.network's secure transport, only for programs that import them.
scaffoldFilesWith :: Bool -> Bool -> String -> Either String [(FilePath, String)]
scaffoldFilesWith crypto minify target = case target of
  "rust" -> Right
    [ ("src/lib.rs", "// Application library. LawSpec maintains the included module declarations.\ninclude!(\"lawspec_modules.rs\");\n")
    , ("Cargo.toml", unlines $
        [ "[package]", "name = \"lawspec-example\"", "version = \"0.1.0\"", "edition = \"2024\""
        , "rust-version = \"1.85\"", "publish = false", ""
        , "[dependencies]", "num-bigint = \"=0.4.8\"", "num-rational = \"=0.4.2\""
        , "num-complex = \"=0.4.6\"", "num-traits = \"=0.2.19\"" ] ++
        (if crypto then
        [ "# lawspec.crypto's default handlers and lawspec.network"
        , "sha3 = \"=0.12.0\"", "shake = \"=0.1.0\"", "ml-kem = \"=0.3.2\""
        , "ml-dsa = { version = \"=0.1.1\", default-features = false, features = [\"alloc\"] }"
        , "slh-dsa = \"=0.2.0-rc.5\"", "aes-gcm = \"=0.11.1\"", "getrandom = \"=0.4.3\"" ] else []) ++
        [ "", "[dev-dependencies]", "proptest = \"=1.11.0\"" ]) ]
  "javascript" -> Right
    [ ("package.json", json (Obj (commonPackage ++
        [ ("scripts", Obj [("test", Str "node --test test/*.test.mjs")]) ] ++ noble ++
        [ ("devDependencies", Obj [("fast-check", Str "4.10.2")]) ]))) ]
  "typescript" -> Right
    [ ("package.json", json (Obj (commonPackage ++
        [ ("scripts", Obj [("test", Str "npm exec -- tsc -p tsconfig.json && node --test dist/test/*.test.js")]) ] ++ noble ++
        [ ("devDependencies", Obj [("fast-check", Str "4.10.2"), ("typescript", Str "5.9.3"), ("@types/node", Str "22.20.4")]) ])))
    , ("tsconfig.json", json (Obj
        [ ("compilerOptions", Obj
            [ ("target", Str "ES2022"), ("module", Str "NodeNext"), ("rootDir", Str "."), ("outDir", Str "dist")
            , ("strict", Bool True), ("esModuleInterop", Bool True), ("skipLibCheck", Bool True) ])
        , ("include", Arr [Str "src/**/*.ts", Str "test/**/*.ts"]) ])) ]
  "python" -> Right
    [ ("pyproject.toml", unlines
        [ "[build-system]", "requires = [\"setuptools==80.9.0\"]", "build-backend = \"setuptools.build_meta\"", ""
        , "[project]", "name = \"lawspec-example\"", "version = \"0.1.0\"", "requires-python = \">=3.13\""
        , if crypto then "dependencies = [\"cryptography==50.0.2\"]" else "dependencies = []", ""
        , "[project.optional-dependencies]", "test = [\"pytest==8.4.2\", \"hypothesis==6.135.26\"]", ""
        , "[tool.setuptools.packages.find]", "where = [\"src\"]", ""
        , "[tool.pytest.ini_options]", "pythonpath = [\"src\"]", "testpaths = [\"tests\"]" ]) ]
  "java" -> Right [("pom.xml", renderXml minify 0 (mavenProject crypto) ++ "\n")]
  "go" -> Right [("go.mod", unlines $
    [ "module example.com/lawspec-example", "", "go 1.25.0", ""
    ] ++ (if crypto then
    [ "require (", "\tgithub.com/cloudflare/circl v1.6.5", "\tpgregory.net/rapid v1.2.0", ")", ""
    , "require (", "\tgolang.org/x/crypto v0.54.0 // indirect", "\tgolang.org/x/sys v0.47.0 // indirect", ")" ]
    else [ "require pgregory.net/rapid v1.2.0" ]))]
  "haskell" -> Right
    [ ("stack.yaml", "snapshot: lts-24.58\npackages: [.]\n" ++
        (if crypto then "# lawspec.crypto's default handlers and lawspec.network\nextra-deps: [crypton-1.1.5, ram-0.22.1, mlkem-0.2.3.0, mldsa-0.1.1.0]\n" else ""))
    , ("package.yaml", unlines
        [ "name: lawspec-example", "version: 0.1.0", "dependencies: [base, text, bytestring, containers, network, directory, time" ++
            (if crypto then ", crypton, mlkem, mldsa, ram]" else "]")
        , "library:", "  source-dirs: src", "tests:", "  laws:", "    main: Spec.hs", "    source-dirs: test"
        , "    dependencies: [lawspec-example, hspec, hedgehog, hspec-hedgehog, containers, mtl]"
        , "    ghc-options: [-threaded, -rtsopts, \"-with-rtsopts=-N\"]"
        , "    build-tools: [hspec-discover]" ])
    , ("test/Spec.hs", "{-# OPTIONS_GHC -F -pgmF hspec-discover #-}\n") ]
  "kotlin" -> Right
    [ ("settings.gradle.kts", "rootProject.name = \"lawspec-example\"\n")
    , ("build.gradle.kts", intercalate (if minify then "\n" else "\n\n")
        [ kotlinBlock "plugins" ["kotlin(\"jvm\") version \"2.3.21\""]
        , kotlinBlock "repositories" ["mavenCentral()"]
        , kotlinBlock "kotlin" ["jvmToolchain(25)"]
        , kotlinBlock "dependencies"
            ([ "implementation(\"org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.0\")" ] ++
             [ "implementation(\"org.bouncycastle:bcprov-jdk18on:1.86\")" | crypto ] ++
             [ "testImplementation(\"io.kotest:kotest-runner-junit5:5.9.1\")"
             , "testImplementation(\"io.kotest:kotest-assertions-core:5.9.1\")"
             , "testImplementation(\"io.kotest:kotest-property:5.9.1\")" ])
        , kotlinBlock "tasks.test" ["useJUnitPlatform()"] ] ++ "\n") ]
  _ -> Left ("Unknown target: " ++ target)
  where
    noble = [("dependencies", Obj [("@noble/post-quantum", Str "0.7.1")]) | crypto]
    commonPackage = [("name", Str "lawspec-example"), ("version", Str "0.1.0"), ("private", Bool True), ("type", Str "module")]
    kotlinBlock name statements
      | minify = name ++ " { " ++ intercalate "; " statements ++ " }"
      | otherwise = name ++ " {\n" ++ intercalate "\n" (map ("    " ++) statements) ++ "\n}"
    json value = renderJson minify 0 value ++ "\n"

-- | The JSON subset these files need, laid out as JSON.stringify(value, null, 2)
-- (or without indentation when minified), keeping field order.
data Json = Str String | Bool Bool | Arr [Json] | Obj [(String, Json)]

renderJson :: Bool -> Int -> Json -> String
renderJson minify depth value = case value of
  Str s -> quote s
  Bool b -> if b then "true" else "false"
  Arr items -> container "[" "]" (map (renderJson minify (depth + 1)) items)
  Obj fields -> container "{" "}"
    [quote key ++ (if minify then ":" else ": ") ++ renderJson minify (depth + 1) v | (key, v) <- fields]
  where
    container open close [] = open ++ close
    container open close items
      | minify = open ++ intercalate "," items ++ close
      | otherwise = open ++ "\n" ++ intercalate ",\n" (map (indent (depth + 1) ++) items) ++
          "\n" ++ indent depth ++ close
    indent n = replicate (2 * n) ' '
    quote s = "\"" ++ concatMap escape s ++ "\""
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape c = [c]

data Xml = Element String [(String, String)] (Either String [Xml])

mavenProject :: Bool -> Xml
mavenProject crypto = Element "project"
  [ ("xmlns", "http://maven.apache.org/POM/4.0.0")
  , ("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance")
  , ("xsi:schemaLocation", "http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd") ]
  (Right (fields [("modelVersion", "4.0.0"), ("groupId", "example"), ("artifactId", "lawspec-example"), ("version", "0.1.0")] ++
    [ node "properties" (fields [("maven.compiler.release", "25"), ("project.build.sourceEncoding", "UTF-8")])
    , node "dependencies"
        ([ compileDependency "org.bouncycastle" "bcprov-jdk18on" "1.86" | crypto ] ++
        [ dependency "org.jetbrains" "jetCheck" "0.3.0"
        , dependency "org.junit.jupiter" "junit-jupiter" "5.14.0" ])
    , node "build" [node "plugins"
        [ plugin "maven-compiler-plugin" "3.14.1"
        , plugin "maven-surefire-plugin" "3.5.4" ]] ]))
  where
    node name children = Element name [] (Right children)
    fields = map (\(name, text) -> Element name [] (Left text))
    dependency group artifact version =
      node "dependency" (fields [("groupId", group), ("artifactId", artifact), ("version", version), ("scope", "test")])
    -- Bouncy Castle: lawspec.crypto's SHAKE256 and SLH-DSA.
    compileDependency group artifact version =
      node "dependency" (fields [("groupId", group), ("artifactId", artifact), ("version", version)])
    plugin artifact version =
      node "plugin" (fields [("groupId", "org.apache.maven.plugins"), ("artifactId", artifact), ("version", version)])

renderXml :: Bool -> Int -> Xml -> String
renderXml minify depth (Element name attributes body) =
  let indent = if minify then "" else replicate (2 * depth) ' '
      rendered = [key ++ "=\"" ++ escape v ++ "\"" | (key, v) <- attributes]
      open = "<" ++ name ++ (if null rendered then ""
        else if minify then " " ++ unwords rendered
        else "\n" ++ intercalate "\n" (map ((indent ++ "  ") ++) rendered)) ++ ">"
  in case body of
    Left text -> indent ++ open ++ escape text ++ "</" ++ name ++ ">"
    Right children ->
      let inner = map (renderXml minify (depth + 1)) children
      in if minify then open ++ concat inner ++ "</" ++ name ++ ">"
         else indent ++ open ++ "\n" ++ intercalate "\n" inner ++ "\n" ++ indent ++ "</" ++ name ++ ">"
  where
    escape = concatMap (\c -> case c of
      '&' -> "&amp;"; '"' -> "&quot;"; '<' -> "&lt;"; '>' -> "&gt;"; _ -> [c])
