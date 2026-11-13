-- | The names lawspec init gives a project's build files: where the name
-- comes from, how each target writes it, and what is refused.
-- ref:DEC-scaffold-project-name
module ProjectNameSpec (test_projectNames) where

import Control.Monad (forM_)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.List (isInfixOf, isPrefixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import LawSpec.ActorRuntime (defaultActorSettings)
import LawSpec.Api (dispatch)
import LawSpec.ProjectName
import LawSpec.Scaffold (scaffoldFiles, scaffoldFilesForRelease, scaffoldTargets)
import LawSpec.TargetOptions (defaultJavaRelease)
import Test.Hspec

-- | A target's build files for a name, as path and content.
files :: String -> Maybe String -> String -> [(FilePath, String)]
files target group name =
  either error id $ do
    names <- projectNames target group name
    scaffoldFilesForRelease names defaultJavaRelease defaultActorSettings False False target

content :: String -> Maybe String -> String -> String
content target group name = concatMap snd (files target group name)

package, atom, typeName :: String -> String -> Either String String
package target = fmap projectPackage . projectNames target Nothing
atom target = fmap projectAtom . projectNames target Nothing
typeName target = fmap projectType . projectNames target Nothing

request :: [(Key, Value)] -> Value
request fields =
  fromMaybe (error "invalid response") $
    decode (dispatch (encode (object (["schemaVersion" .= (5 :: Int), "method" .= ("scaffold" :: String)] ++ fields))))

at :: [Key] -> Value -> Value
at [] value = value
at (key : rest) (Object fields) = maybe Null (at rest) (KM.lookup key fields)
at _ _ = Null

test_projectNames :: Spec
test_projectNames = describe "project names" $ do
  describe "one name in each target's build files" $ do
    let written target = content target Nothing "Billing Service"
    it "is kebab-case for npm, Cargo, pyproject, Stack, Maven and Gradle" $ do
      forM_ ["javascript", "typescript"] $ \target ->
        written target `shouldSatisfy` ("\"name\": \"billing-service\"" `isInfixOf`)
      written "rust" `shouldSatisfy` ("name = \"billing-service\"" `isInfixOf`)
      forM_ ["python", "prolog"] $ \target ->
        written target `shouldSatisfy` ("[project]\nname = \"billing-service\"" `isInfixOf`)
      written "haskell" `shouldSatisfy` ("name: billing-service\n" `isInfixOf`)
      written "haskell" `shouldSatisfy` ("dependencies: [billing-service, hspec" `isInfixOf`)
      written "java" `shouldSatisfy` ("<artifactId>billing-service</artifactId>" `isInfixOf`)
      written "kotlin" `shouldSatisfy` ("rootProject.name = \"billing-service\"" `isInfixOf`)
      written "groovy" `shouldSatisfy` ("rootProject.name = 'billing-service'" `isInfixOf`)
    it "is snake_case for the BEAM applications and the Gleam package" $ do
      map fst (files "erlang" Nothing "Billing Service") `shouldContain` ["src/billing_service.app.src"]
      written "erlang" `shouldSatisfy` ("{application, billing_service, [" `isInfixOf`)
      written "elixir" `shouldSatisfy` ("app: :billing_service," `isInfixOf`)
      written "elixir" `shouldSatisfy` ("defmodule BillingService.MixProject do" `isInfixOf`)
      written "gleam" `shouldSatisfy` ("name = \"billing_service\"" `isInfixOf`)
      map fst (files "gleam" Nothing "Billing Service") `shouldContain` ["test/billing_service_test.gleam"]
    it "is PascalCase for .NET and Swift" $ do
      map fst (files "fsharp" Nothing "billing-service")
        `shouldBe` ["global.json", "BillingService.slnx", "src/BillingService.fsproj", "tests/BillingService.Tests.fsproj"]
      content "csharp" Nothing "billing-service" `shouldSatisfy` ("<RootNamespace>BillingService</RootNamespace>" `isInfixOf`)
      content "csharp" Nothing "billing-service" `shouldSatisfy` ("../src/BillingService.csproj" `isInfixOf`)
      content "swift" Nothing "billing-service" `shouldSatisfy` ("name: \"BillingService\"," `isInfixOf`)
    it "is the last element of the Go module path" $
      written "go" `shouldSatisfy` ("module example.com/billing-service\n" `isPrefixOf`)
    it "leaves no example name in any target's files" $
      forM_ scaffoldTargets $ \target -> do
        written target `shouldNotSatisfy` ("lawspec-example" `isInfixOf`)
        written target `shouldNotSatisfy` ("lawspec_example" `isInfixOf`)
        concatMap fst (files target Nothing "Billing Service") `shouldNotSatisfy` ("Example" `isInfixOf`)
    it "keeps the example project's files as they were" $ do
      let exampleFiles target = either error (concatMap snd) (scaffoldFiles False target)
      exampleFiles "rust" `shouldSatisfy` ("name = \"lawspec-example\"" `isInfixOf`)
      exampleFiles "java" `shouldSatisfy` ("<groupId>example</groupId>" `isInfixOf`)
      exampleFiles "go" `shouldSatisfy` ("module example.com/lawspec-example\n" `isPrefixOf`)
      exampleFiles "elixir" `shouldSatisfy` ("defmodule LawSpecExample.MixProject do" `isInfixOf`)
      exampleFiles "swift" `shouldSatisfy` ("name: \"Example\"," `isInfixOf`)
      exampleFiles "kotlin" `shouldNotSatisfy` ("group =" `isInfixOf`)

  describe "awkward names" $ do
    it "reads spaces, dots, underscores and capitals as word boundaries" $
      forM_ ["billing service", "billing.service", "billing_service", "BillingService", "BILLING-SERVICE", "  billing  service  "] $ \name -> do
        package "rust" name `shouldBe` Right "billing-service"
        atom "elixir" name `shouldBe` Right "billing_service"
        typeName "csharp" name `shouldBe` Right "BillingService"
    it "splits an acronym from the word after it" $
      package "javascript" "HTTPServer v2" `shouldBe` Right "http-server-v2"
    it "puts project before a leading digit where a name must begin with a letter" $ do
      package "rust" "2048" `shouldBe` Right "project-2048"
      atom "erlang" "2048" `shouldBe` Right "project_2048"
      atom "gleam" "3d_viewer" `shouldBe` Right "project_3d_viewer"
      typeName "fsharp" "2048" `shouldBe` Right "Project2048"
      typeName "swift" "2048" `shouldBe` Right "Project2048"
      -- npm, PyPI, Maven and Gradle accept a digit first.
      forM_ ["javascript", "python", "java", "kotlin"] $ \target ->
        package target "2048" `shouldBe` Right "2048"
      fmap projectGroup (projectNames "java" Nothing "2048") `shouldBe` Right "project_2048"
      fmap projectGoModule (projectNames "go" Nothing "2048") `shouldBe` Right "example.com/2048"
    it "gives every part of a Cabal package name a letter" $ do
      package "haskell" "app-2" `shouldBe` Right "app2"
      package "haskell" "2048" `shouldBe` Right "project2048"
      package "haskell" "route-66-maps" `shouldBe` Right "route66-maps"
    it "puts project after a name the target reserves" $ do
      package "rust" "test" `shouldBe` Right "test-project"
      package "rust" "match" `shouldBe` Right "match-project"
      package "rust" "CON" `shouldBe` Right "con-project"
      package "javascript" "lawspec" `shouldBe` Right "lawspec-project"
      package "typescript" "fast-check" `shouldBe` Right "fast-check-project"
      package "python" "pytest" `shouldBe` Right "pytest-project"
      package "haskell" "containers" `shouldBe` Right "containers-project"
      atom "erlang" "end" `shouldBe` Right "end_project"
      atom "elixir" "stream-data" `shouldBe` Right "stream_data_project"
      atom "gleam" "gleam_tools" `shouldBe` Right "project_gleam_tools"
      atom "gleam" "gleam" `shouldBe` Right "project_gleam"
      typeName "csharp" "lawspec" `shouldBe` Right "LawspecProject"
      typeName "fsharp" "System" `shouldBe` Right "SystemProject"
      fmap projectGroup (projectNames "java" Nothing "class") `shouldBe` Right "class_project"
      -- A word reserved on one target is an ordinary name on another.
      package "python" "match" `shouldBe` Right "match"
      package "java" "class" `shouldBe` Right "class"
    it "drops characters outside ASCII letters and digits" $ do
      package "rust" "caf\233 r\233sum\233" `shouldBe` Right "caf-r-sum"
      package "rust" "billing\8212service!" `shouldBe` Right "billing-service"
    it "refuses a name with nothing to write" $
      forM_ ["", "   ", "---", "\26085\26412\35486", "\1085\1072\1091\1082\1072"] $ \name ->
        projectNames "rust" Nothing name `shouldBe` Left "has no ASCII letter or digit to make a build name from"
    it "refuses a name longer than the limit and accepts one at it" $ do
      package "javascript" (replicate nameLimit 'a') `shouldBe` Right (replicate nameLimit 'a')
      projectNames "javascript" Nothing (replicate (nameLimit + 1) 'a') `shouldSatisfy` isLeft
      -- The added word counts.
      projectNames "rust" Nothing ('1' : replicate (nameLimit - 1) 'a') `shouldSatisfy` isLeft
      projectNames "python" Nothing (unwords (replicate 20 "long")) `shouldSatisfy` either ("is too long: it is 99 characters" `isPrefixOf`) (const False)

  describe "the group" $ do
    it "defaults to the name as a Java package segment" $ do
      content "java" Nothing "Billing Service" `shouldSatisfy` ("<groupId>billing_service</groupId>" `isInfixOf`)
      content "kotlin" Nothing "Billing Service" `shouldNotSatisfy` ("group =" `isInfixOf`)
    it "is written as given" $ do
      content "java" (Just "com.acme.billing") "ledger" `shouldSatisfy` ("<groupId>com.acme.billing</groupId>\n  <artifactId>ledger</artifactId>" `isInfixOf`)
      content "kotlin" (Just "com.acme") "ledger" `shouldSatisfy` ("\n\ngroup = \"com.acme\"\n\n" `isInfixOf`)
      content "groovy" (Just "com.acme") "ledger" `shouldSatisfy` ("\n\ngroup = 'com.acme'\n\n" `isInfixOf`)
      content "go" (Just "github.com/acme") "Ledger API" `shouldSatisfy` ("module github.com/acme/ledger-api\n" `isPrefixOf`)
    it "is checked, never re-spelled" $ do
      forM_ ["com.acme-corp", "com.2fa", "com.class.app", "com..acme", "", "com.acme."] $ \group ->
        projectNames "java" (Just group) "ledger" `shouldSatisfy` either (\problem -> "--group" `isPrefixOf` problem && "is not a Java package name" `isInfixOf` problem) (const False)
      forM_ ["acme", "github.com//acme", "github.com/acme corp", ".com/acme"] $ \group ->
        projectNames "go" (Just group) "ledger" `shouldSatisfy` either ("is not the start of a Go module path" `isInfixOf`) (const False)
    it "is refused where the build has none" $
      forM_ ["python", "rust", "javascript", "fsharp", "scala", "yaml"] $ \target ->
        fmap projectSummary (resolveProject target Nothing (Just "com.acme") [] Nothing "ledger")
          `shouldBe` Left ("--group applies to the java, kotlin, groovy and go targets; a " ++ target ++ " build file has no group")

  describe "an existing build file's name" $ do
    let named file text = buildFileName [(file, text)]
    it "is read from each build tool's file" $ do
      named "package.json" "{\"author\": {\"name\": \"A\"}, \"name\": \"@acme/billing-api\"}" `shouldBe` Just ("package.json", "billing-api")
      named "Cargo.toml" "[workspace]\nname = \"no\"\n\n[package]\nname = \"ledger\"\nversion = \"1.0.0\"\n" `shouldBe` Just ("Cargo.toml", "ledger")
      named "pyproject.toml" "[build-system]\nrequires = []\n[project]\n  name = 'ledger-py'\n" `shouldBe` Just ("pyproject.toml", "ledger-py")
      named "gleam.toml" "name = \"shop\"\nversion = \"1.0.0\"\n[dependencies]\nname = \"no\"\n" `shouldBe` Just ("gleam.toml", "shop")
      named "pom.xml" "<?xml version=\"1.0\"?>\n<!-- <artifactId>no</artifactId> -->\n<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n  <parent>\n    <artifactId>parent</artifactId>\n  </parent>\n  <artifactId> orders </artifactId>\n  <dependencies><dependency><artifactId>dep</artifactId></dependency></dependencies>\n</project>\n"
        `shouldBe` Just ("pom.xml", "orders")
      named "settings.gradle.kts" "pluginManagement {}\nrootProject.name = \"shop\"\n" `shouldBe` Just ("settings.gradle.kts", "shop")
      named "settings.gradle" "rootProject.name = 'shop'\n" `shouldBe` Just ("settings.gradle", "shop")
      named "go.mod" "module github.com/acme/ledger/v2 // the ledger\n\ngo 1.25.0\n" `shouldBe` Just ("go.mod", "ledger")
      named "mix.exs" "defmodule Shop.MixProject do\n  def project do\n    [app: :shop_web, version: \"1.0.0\"]\n  end\nend\n" `shouldBe` Just ("mix.exs", "shop_web")
      named "package.yaml" "name: shop\nversion: 0.1.0\n" `shouldBe` Just ("package.yaml", "shop")
      named "shop.cabal" "cabal-version: 2.2\nName:    shop-core\n" `shouldBe` Just ("shop.cabal", "shop-core")
      named "Billing.Api.slnx" "<Solution />\n" `shouldBe` Just ("Billing.Api.slnx", "Billing.Api")
      named "Package.swift" "import PackageDescription\nlet package = Package(\n  name: \"Shop\",\n  targets: [.target(name: \"App\")])\n" `shouldBe` Just ("Package.swift", "Shop")
    it "is absent when the file names nothing" $ do
      named "package.json" "{\"private\": true}" `shouldBe` Nothing
      named "package.json" "not json" `shouldBe` Nothing
      named "pom.xml" "<project><modelVersion>4.0.0</modelVersion></project>" `shouldBe` Nothing
      named "rebar.config" "{erl_opts, [debug_info]}.\n" `shouldBe` Nothing
      named "Cargo.toml" "[workspace]\nmembers = []\n" `shouldBe` Nothing
    it "does not depend on the order the files were read in" $ do
      let found = [("pom.xml", "<project><artifactId>orders</artifactId></project>"), ("package.json", "{\"name\": \"web\"}")]
      buildFileName found `shouldBe` Just ("package.json", "web")
      buildFileName (reverse found) `shouldBe` Just ("package.json", "web")

  describe "where the name comes from" $ do
    let build = [("package.json", "{\"name\": \"from-build\"}")]
        resolved option existing manifest = fmap (\project -> (projectSource project, projectPackage (projectBuildNames project))) (resolveProject "rust" option Nothing existing manifest "From Directory")
    it "is --name, then a build file, then the manifest, then the directory" $ do
      resolved (Just "from option") build (Just "from-manifest") `shouldBe` Right (FromOption, "from-option")
      resolved Nothing build (Just "from-manifest") `shouldBe` Right (FromBuildFile "package.json", "from-build")
      resolved Nothing [] (Just "from-manifest") `shouldBe` Right (FromManifest, "from-manifest")
      resolved Nothing [] Nothing `shouldBe` Right (FromDirectory, "from-directory")
    it "says what was named and from where" $ do
      fmap projectSummary (resolveProject "java" Nothing Nothing [] Nothing "Billing Service") `shouldBe` Right (Just "Project name: billing_service:billing-service (from the directory name).")
      fmap projectSummary (resolveProject "fsharp" (Just "ledger") Nothing [] Nothing "x") `shouldBe` Right (Just "Project name: Ledger (from --name).")
      fmap projectSummary (resolveProject "go" Nothing (Just "github.com/acme") build Nothing "x") `shouldBe` Right (Just "Project name: github.com/acme/from-build (from package.json).")
    it "names the manifest's component as given when the manifest admits it" $ do
      fmap projectComponent (resolveProject "rust" Nothing Nothing [] Nothing "Billing.Service_2") `shouldBe` Right "Billing.Service_2"
      fmap projectComponent (resolveProject "rust" Nothing Nothing [] Nothing "Billing Service") `shouldBe` Right "billing-service"
    it "says which name failed and how to give another" $ do
      fmap projectSummary (resolveProject "rust" Nothing Nothing [] Nothing "\26085\26412\35486")
        `shouldBe` Left "the directory name \"\\26085\\26412\\35486\" has no ASCII letter or digit to make a build name from; give the project's name with --name"
      fmap projectSummary (resolveProject "rust" (Just "!!") Nothing [] Nothing "fine")
        `shouldBe` Left "--name \"!!\" has no ASCII letter or digit to make a build name from"
    it "needs no build name where the build files carry none" $ do
      fmap projectSummary (resolveProject "yaml" Nothing Nothing [] Nothing "\26085\26412\35486") `shouldBe` Right Nothing
      fmap projectComponent (resolveProject "scala" Nothing Nothing [] Nothing "\26085\26412\35486") `shouldBe` Right "\26085\26412\35486"
      fmap projectComponent (resolveProject "clojure" Nothing Nothing [] Nothing "!!") `shouldSatisfy` isLeft

  describe "the scaffold request" $ do
    it "returns the named files and what was named" $ do
      let response = request ["target" .= ("rust" :: String), "directory" .= ("My App" :: String)]
      at ["diagnostics"] response `shouldBe` toJSON ([] :: [Value])
      at ["project"] response
        `shouldBe` object ["name" .= ("My App" :: String), "component" .= ("my-app" :: String), "summary" .= ("Project name: my-app (from the directory name)." :: String), "source" .= ("directory" :: String)]
      case at ["files"] response of
        Array entries -> do
          map (at ["path"]) (toList entries) `shouldBe` [String "src/lib.rs", String "Cargo.toml"]
          [text | entry <- toList entries, String text <- [at ["content"] entry]]
            `shouldSatisfy` any (T.isInfixOf "name = \"my-app\"")
        other -> expectationFailure (show other)
    it "prefers the option to a build file and the manifest" $ do
      let response =
            request
              [ "target" .= ("typescript" :: String),
                "directory" .= ("work" :: String),
                "name" .= ("Ledger" :: String),
                "manifestName" .= ("component" :: String),
                "buildFiles" .= [object ["path" .= ("pom.xml" :: String), "content" .= ("<project><artifactId>orders</artifactId></project>" :: String)]]
              ]
      at ["project", "source"] response `shouldBe` String "option"
      at ["project", "summary"] response `shouldBe` String "Project name: ledger (from --name)."
      at ["project", "source"] (request ["target" .= ("typescript" :: String), "directory" .= ("work" :: String), "buildFiles" .= [object ["path" .= ("pom.xml" :: String), "content" .= ("<project><artifactId>orders</artifactId></project>" :: String)]]])
        `shouldBe` String "build-file"
    it "reports a name it cannot use as a diagnostic" $ do
      let response = request ["target" .= ("rust" :: String), "directory" .= ("---" :: String)]
      at ["diagnostics"] response
        `shouldBe` toJSON [object ["code" .= ("scaffold" :: String), "message" .= ("the directory name \"---\" has no ASCII letter or digit to make a build name from; give the project's name with --name" :: String), "at" .= Null]]
      at ["files"] response `shouldBe` Null
    it "reports an unsupported Java release" $
      at ["diagnostics"] (request ["target" .= ("java" :: String), "directory" .= ("app" :: String), "release" .= (17 :: Int)])
        `shouldBe` toJSON [object ["code" .= ("scaffold" :: String), "message" .= ("Java release 17 is not supported; choose 21 or 25" :: String), "at" .= Null]]
