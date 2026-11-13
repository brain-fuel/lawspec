-- | A target's build options at the JSON boundary: generated directories
-- place files by ownership, and a release refuses what it cannot compile.
module TargetOptionsSpec (test_generatedDirectoriesPlaceFilesByOwnership, test_javaReleaseRefusesWhatItCannotCompile) where

import Control.Monad (forM_)
import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (isInfixOf, isPrefixOf, sort)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Vector as V
import LawSpec.ActorRuntime (defaultActorSettings)
import LawSpec.Api (dispatch)
import LawSpec.Manifest.Decode (admitEDNManifest)
import LawSpec.Scaffold (generatedRootsAdvice, scaffoldFilesForRelease)
import Test.Hspec

call :: [(K.Key, Value)] -> Value
call fields =
  fromMaybe
    (error "invalid API response")
    ( decode
        ( dispatch
            ( encode
                ( object
                    ( [ "schemaVersion" .= (5 :: Int),
                        "languageProfile" .= ("1.0-rc.2" :: String),
                        "method" .= ("planGeneration" :: String),
                        "verification" .= object ["layers" .= (["property", "examples"] :: [String])]
                      ]
                        ++ fields
                    )
                )
            )
        )
    )

field :: String -> Value -> Value
field name (Object o) = fromMaybe Null (KM.lookup (K.fromString name) o)
field _ _ = Null

text :: Value -> String
text (String s) = T.unpack s
text _ = ""

list :: Value -> [Value]
list (Array a) = V.toList a
list _ = []

-- | Each file's path, ownership and content.
files :: Value -> [(String, String, String)]
files result = [(text (field "path" f), text (field "ownership" f), text (field "content" f)) | f <- list (field "files" result)]

messages :: Value -> [(String, String)]
messages result = [(text (field "code" d), text (field "message" d)) | d <- list (field "diagnostics" result)]

source :: String -> String -> Value
source path body = object ["path" .= path, "content" .= body]

plain :: Value
plain =
  source "successor.lawspec" $
    unlines
      [ "unit example.successor",
        "",
        "successor :: Int8 -> Integer",
        "law promotes is",
        " definition: for all (x :: Int8) => successor x = x + 1 end for all end definition",
        " example maximum: x = 127 expect successor x = 128 end example",
        "end law",
        "",
        "end unit"
      ]

crypto :: Value
crypto =
  source "digest.lawspec" $
    unlines
      [ "unit example.digest",
        "",
        "import lawspec.crypto (SigningKeyPair)",
        "",
        "successor :: Int8 -> Integer",
        "law promotes is",
        " definition: for all (x :: Int8) => successor x = x + 1 end for all end definition",
        "end law",
        "",
        "end unit"
      ]

java :: [(K.Key, Value)] -> Value
java options = call (["target" .= ("java" :: String), "sources" .= [plain]] ++ options)

generatedDirectories :: [(K.Key, Value)]
generatedDirectories =
  [ "generatedSourceDir" .= ("target/generated-sources/lawspec" :: String),
    "generatedTestDir" .= ("target/generated-test-sources/lawspec" :: String)
  ]

-- | Builds that never commit generated source need LawSpec's files apart
-- from the user's, so that cleaning the build cannot delete an adapter and
-- generating again restores exactly what was cleaned.
-- ref:DEC-adapter-ownership
test_generatedDirectoriesPlaceFilesByOwnership :: Spec
test_generatedDirectoriesPlaceFilesByOwnership = describe "generated directories" $ do
  it "move every generated Java file and leave every user-owned file in the source tree" $ do
    let result = java generatedDirectories
    messages result `shouldBe` []
    files result `shouldNotBe` []
    forM_ (files result) $ \(path, owner, _) ->
      if owner == "user"
        then path `shouldSatisfy` \p -> any (`isPrefixOf` p) ["src/main/java/", "src/test/java/"]
        else path `shouldSatisfy` \p -> any (`isPrefixOf` p) ["target/generated-sources/lawspec/", "target/generated-test-sources/lawspec/"]
    [owner | (_, owner, _) <- files result] `shouldSatisfy` elem "user"
    [path | (path, _, _) <- files result] `shouldSatisfy` elem "target/generated-sources/lawspec/lawspec/runtime/LawSpecRuntime.java"

  it "change paths only, so a generated tree is reproduced byte for byte" $ do
    let relocate path = foldr move path [("src/main/java/", "target/generated-sources/lawspec/"), ("src/test/java/", "target/generated-test-sources/lawspec/")]
        move (from, to) path = if from `isPrefixOf` path then to ++ drop (length from) path else path
        expected = sort [(if owner == "generated" then relocate path else path, owner, body) | (path, owner, body) <- files (java [])]
    sort (files (java generatedDirectories)) `shouldBe` expected
    encode (java generatedDirectories) `shouldBe` encode (java generatedDirectories)

  it "list the generated tests where they are written" $ do
    let result = java generatedDirectories
        tests = [text (field "file" entry) | entry <- list (field "tests" result)]
    tests `shouldNotBe` []
    forM_ tests (`shouldSatisfy` isPrefixOf "target/generated-test-sources/lawspec/")
    forM_ tests (`shouldSatisfy` (`elem` [path | (path, _, _) <- files result]))

  it "keep the custom source directories for user-owned files" $ do
    let result = java (generatedDirectories ++ ["sourceDir" .= ("app/main" :: String), "testDir" .= ("app/checks" :: String)])
    messages result `shouldBe` []
    forM_ [path | (path, "user", _) <- files result] (`shouldSatisfy` \p -> any (`isPrefixOf` p) ["app/main/", "app/checks/"])
    [path | (path, "generated", _) <- files result, "app/" `isPrefixOf` path] `shouldBe` []

  it "move a harness's JUnit configuration beside the generated tests" $ do
    let result = call (["target" .= ("java" :: String), "sources" .= [parallelUnit, harness]] ++ generatedDirectories)
        moved = [path | (path, _, _) <- files result]
    messages result `shouldBe` []
    moved `shouldSatisfy` elem "target/generated-test-sources/lawspec/junit-platform.properties"
    [path | path <- moved, "src/test/resources/" `isPrefixOf` path] `shouldBe` []

  it "refuse a directory that is unsafe, shared or nested, and any target but Java" $ do
    let refused options = map fst (messages (java options))
    refused ["generatedSourceDir" .= ("../outside" :: String)] `shouldBe` ["layout"]
    refused ["generatedSourceDir" .= (7 :: Int)] `shouldBe` ["layout"]
    refused ["generatedSourceDir" .= ("src/main/java" :: String)] `shouldBe` ["layout"]
    refused ["generatedSourceDir" .= ("src/main/java/generated" :: String)] `shouldBe` ["layout"]
    refused ["generatedSourceDir" .= ("target/generated" :: String), "generatedTestDir" .= ("target/generated" :: String)] `shouldBe` ["layout"]
    let python = call (["target" .= ("python" :: String), "sources" .= [plain]] ++ generatedDirectories)
    map fst (messages python) `shouldBe` ["layout"]
    snd (head (messages python)) `shouldSatisfy` isInfixOf "java target only"

  it "are admitted, with the release, on a target in lawspec.edn" $ do
    let manifest target =
          "{:manifest-version 1 :component {:name \"shop\" :version \"1.0.0\"} :language-profile \"1.0-rc.2\" :sources [\"laws\"] :targets [{:language :java :root \"laws\" "
            ++ target
            ++ "}]}"
    fmap snd (admitEDNManifest (manifest ":release 21 :generated-source-dir \"target/generated-sources/lawspec\" :generated-test-dir \"target/generated-test-sources/lawspec\""))
      `shouldBe` Right []
    fmap snd (admitEDNManifest (manifest ":generated-dir \"target\""))
      `shouldBe` Right ["targets[0]: unknown field generatedDir"]

  it "render the Maven executions and Gradle source sets that register the directories" $ do
    let advice = generatedRootsAdvice (Just "target/generated-sources/lawspec") (Just "target/generated-test-sources/lawspec")
    forM_
      [ "<artifactId>build-helper-maven-plugin</artifactId>",
        "<goal>add-source</goal>",
        "<source>${project.basedir}/target/generated-sources/lawspec</source>",
        "<goal>add-test-source</goal>",
        "<source>${project.basedir}/target/generated-test-sources/lawspec</source>",
        "<goal>add-test-resource</goal>",
        "main { java.srcDir(\"target/generated-sources/lawspec\") }",
        "java.srcDir(\"target/generated-test-sources/lawspec\")"
      ]
      (\part -> advice `shouldSatisfy` isInfixOf part)
    generatedRootsAdvice (Just "generated") Nothing `shouldNotSatisfy` isInfixOf "add-test-source"
    generatedRootsAdvice Nothing Nothing `shouldBe` ""
  where
    parallelUnit =
      source "parallel.lawspec" $
        unlines
          [ "unit example.parallel",
            "",
            "successor :: Int8 -> Integer",
            "law promotes is",
            " definition: for all (x :: Int8) => successor x = x + 1 end for all end definition",
            "end law",
            "",
            "end unit"
          ]
    harness =
      source "parallel_testing.lawspec" $
        unlines
          [ "harness example.parallel.testing for example.parallel is",
            "  parallel",
            "end harness"
          ]

-- | An existing build on the earlier LTS can hold the Java target only if
-- its generated code compiles there, and a unit that cannot must say so at
-- generation rather than fail in javac. ref:DEC-adapter-ownership
test_javaReleaseRefusesWhatItCannotCompile :: Spec
test_javaReleaseRefusesWhatItCannotCompile = describe "Java release" $ do
  it "generates the same files at release 21 as at the default" $ do
    messages (java ["release" .= (21 :: Int)]) `shouldBe` []
    files (java ["release" .= (21 :: Int)]) `shouldBe` files (java [])
    files (java ["release" .= (25 :: Int)]) `shouldBe` files (java [])

  it "names the unit and the release it needs when a program uses newer JDK APIs" $ do
    let refused = messages (call ["target" .= ("java" :: String), "sources" .= [crypto], "release" .= (21 :: Int)])
    map fst refused `shouldBe` ["release"]
    forM_ ["unit lawspec.crypto", "Java release 24 or later", "release 21"] (\part -> snd (head refused) `shouldSatisfy` isInfixOf part)
    messages (call ["target" .= ("java" :: String), "sources" .= [crypto], "release" .= (25 :: Int)]) `shouldBe` []
    messages (call ["target" .= ("java" :: String), "sources" .= [crypto]]) `shouldBe` []

  it "refuses an unsupported release, a release that is not a number, and a release on another target" $ do
    map fst (messages (java ["release" .= (17 :: Int)])) `shouldBe` ["release"]
    map fst (messages (java ["release" .= (24 :: Int)])) `shouldBe` ["release"]
    map fst (messages (java ["release" .= ("21" :: String)])) `shouldBe` ["release"]
    map fst (messages (call ["target" .= ("kotlin" :: String), "sources" .= [plain], "release" .= (21 :: Int)])) `shouldBe` ["release"]

  it "scaffolds a build at the chosen release and refuses another" $ do
    let pom release = fmap (concatMap snd) (scaffoldFilesForRelease release defaultActorSettings False False "java")
    pom 21 `shouldSatisfy` either (const False) (isInfixOf "<maven.compiler.release>21</maven.compiler.release>")
    pom 25 `shouldSatisfy` either (const False) (isInfixOf "<maven.compiler.release>25</maven.compiler.release>")
    pom 17 `shouldSatisfy` either (isInfixOf "17") (const False)
