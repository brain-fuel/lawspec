-- | The manifest of generated tests per law.
module TestManifestSpec (test_testManifestNamesEveryLawsTestOnEachTarget) where

import Control.Monad (forM_)
import Data.Aeson (Value(..), decode, encode, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (isInfixOf, isSuffixOf, sort)
import qualified Data.Text as T
import qualified Data.Vector as V
import System.Directory (listDirectory)
import Test.Hspec
import LawSpec.Code.ECMAScript (javascriptLiteral)
import LawSpec.Api (dispatch)
import LawSpec.Targets (programTargets)

-- | Every bundled example, planned for each target in one program.
planned :: String -> Maybe String -> IO (KM.KeyMap Value)
planned target testDir = do
  names <- sort . filter (".lawspec" `isSuffixOf`) <$> listDirectory "examples/specs"
  sources <- mapM (\name -> (\content -> object ["path" .= name, "content" .= content]) <$> readFile ("examples/specs/" ++ name)) names
  let request = object (["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
        "method" .= ("planGeneration" :: String),
        "verification" .= object ["layers" .= (["proof","exhaustive","property","examples","runtime","model"] :: [String])],
        "target" .= target, "sources" .= sources] ++
        ["testDir" .= d | Just d <- [testDir]])
  case decode (dispatch (encode request)) of
    Just (Object response) -> pure response
    _ -> fail "no response"

field :: String -> KM.KeyMap Value -> Value
field name = maybe Null id . KM.lookup (K.fromString name)

text :: Value -> String
text (String s) = T.unpack s
text _ = ""


-- | How each target names the tests of law n.
-- A law's tests are named after its label (LawSpec.TestNames); the manifest
-- carries that name.
named :: String -> String -> String
named target name = case target of
  "python" -> "def " ++ name ++ "__"
  "prolog" -> "test(" ++ name ++ ")"
  "go" -> "func " ++ name ++ "_"
  "rust" -> "fn " ++ name ++ "()"
  "haskell" -> "\"" ++ name ++ "_"
  "kotlin" -> "\"" ++ name ++ "_"
  _ -> name ++ "_"

-- Exact model slots do not have an ordinary law's test-kind suffix.
modelNamed :: String -> String -> String
modelNamed target name = case target of
  "python" -> "def " ++ name ++ "("
  "prolog" -> "test(" ++ name ++ ")"
  "go" -> "func " ++ name ++ "("
  "rust" -> "fn " ++ name ++ "()"
  "haskell" -> "\"" ++ name ++ "\""
  "kotlin" -> "\"" ++ name ++ "\""
  _ -> name ++ "("

unsplit :: String -> String
unsplit text = case text of
  '"' : rest | (sep : after) <- dropWhile blank rest, sep `elem` (",+" :: String), '"' : more <- dropWhile blank after -> unsplit more
  c : rest -> c : unsplit rest
  [] -> []
  where blank c = c `elem` (" \n" :: String)

-- | lawspec test runs only the laws whose results may have changed, which needs
-- a manifest that names each law's tests on each target, wherever the tests
-- live. ref:DEC-incremental-compilation ref:REQ-test-manifest
test_testManifestNamesEveryLawsTestOnEachTarget :: Spec
test_testManifestNamesEveryLawsTestOnEachTarget = describe "the test manifest" $ do
  it "retains complete empty-domain Core evidence without planning a nonexistent native test" $ do
    let source = unlines ["unit emptyManifest",
          "law vacuous is definition: for all (x :: Integer) (y :: Integer where y > x and y < x + 1) => false end for all end definition end law",
          "law ordinary is definition: for all (x :: Integer) => x must be x end for all end definition end law",
          "end unit"]
    forM_ programTargets $ \target -> do
      let request=object ["schemaVersion" .= (5::Int), "languageProfile" .= ("1.0-rc.2"::String),
            "method" .= ("planGeneration"::String), "target" .= target,
            "verification" .= object ["layers" .= (["proof","exhaustive","property","examples"]::[String])],
            "sources" .= [object ["path" .= ("empty.lawspec"::String),"content" .= source]]]
      case decode (dispatch (encode request)) of
        Just (Object response) -> do
          field "diagnostics" response `shouldBe` Array mempty
          let Array tests=field "tests" response
              Array evidence=field "evidence" response
              Array laws=field "laws" response
              status=[field "status" item | Object item<-V.toList evidence,
                field "declaration" item==String "emptyManifest::law::vacuous",field "stage" item==String "law"]
          V.length laws `shouldBe` 2
          [field "law" entry | Object entry<-V.toList tests] `shouldBe` [String "emptyManifest::law::ordinary"]
          length status `shouldBe` 1
          head status `shouldSatisfy` (`elem` [String "proved",String "exhaustively-checked"])
        other -> expectationFailure (show (other :: Maybe Value))
  forM_ ["python", "prolog", "javascript", "typescript", "go", "java", "kotlin", "rust", "haskell"] $ \target ->
    it ("names each law's generated test file and tests in " ++ target) $ do
      response <- planned target Nothing
      let Array files = field "files" response
          contents = [ (text (field "path" f), text (field "content" f)) | Object f <- V.toList files ]
          Array tests = field "tests" response
      V.length tests `shouldSatisfy` (> 100)
      forM_ [ t | Object t <- V.toList tests ] $ \t -> do
        let file = text (field "file" t)
            name = text (field "name" t)
        case lookup file contents of
          Nothing -> expectationFailure (target ++ ": no generated test file " ++ file)
          Just content
            | target `elem` ["javascript", "typescript"] ->
                -- Labels are inside native string literals there.
                content `shouldSatisfy` isInfixOf (init (drop 1 (javascriptLiteral (text (field "label" t)))))
            -- Haskell and Kotlin split long string literals into pieces.
            | otherwise -> unsplit content `shouldSatisfy` isInfixOf
                (if field "kind" t == String "model" then modelNamed target name else named target name)
  it "follows a custom test directory" $ do
    response <- planned "python" (Just "checks")
    let Array files = field "files" response
        paths = [ text (field "path" f) | Object f <- V.toList files ]
        Array tests = field "tests" response
    forM_ [ t | Object t <- V.toList tests ] $ \t -> do
      let file = text (field "file" t)
      take 7 file `shouldBe` "checks/"
      paths `shouldSatisfy` elem file
