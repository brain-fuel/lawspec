-- | Historical large-output fixtures must stay compact on every executable
-- target, and neither minification nor a long line may bypass the guard.
-- ref:DEC-planned-generation ref:DEC-tests-cite-requirements
module GeneratedTestSizeSpec (test_generatedTestsStayProportionalToTheirSpecification) where

import Control.Monad (forM_)
import Data.Aeson (Value(..), decode, encode, object, (.=))
import qualified Data.ByteString.Lazy as B
import qualified Data.Aeson.KeyMap as K
import qualified Data.Vector as V
import qualified Data.Text as T
import LawSpec.Api (dispatch)
import LawSpec.Common (Artifact(..), Source(..))
import LawSpec.Targets (programTargets)
import LawSpec.Testing.Size
import Test.Hspec

test_generatedTestsStayProportionalToTheirSpecification :: Spec
test_generatedTestsStayProportionalToTheirSpecification = describe "compact generated test budgets" $ do
  forM_ [(["examples/specs/handler_bindings.lawspec"], programTargets),
         (["test/fixtures/canonical-smt-arithmetic.lawspec"], programTargets),
         (["examples/specs/total_functions.lawspec", "examples/specs/refined_definitions.lawspec",
           "examples/specs/data_types.lawspec"], ["kotlin"])] $ \(files, targets) ->
    forM_ targets $ \target -> it (target ++ " keeps " ++ unwords files ++ " within its source-size budget") $ do
      sources <- mapM (\file -> Source file <$> readFile file) files
      let request = object ["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
            "method" .= ("planGeneration" :: String), "target" .= target,
            "verification" .= object ["layers" .= (["proof","exhaustive","property","examples","runtime","model"] :: [String])],
            "sources" .= [object ["path" .= path source, "content" .= content source] | source <- sources]]
      checkBudget sources request
  forM_ ["java", "kotlin", "groovy", "clojure"] $ \target ->
    it (target ++ " shares native-failure scaffolding within the source-size budget") $ do
      let file = "test/fixtures/canonical-native-failure-products.lawspec"
      source <- Source file <$> readFile file
      bindingBytes <- B.readFile ("acceptance/minor-native-failure-products/" ++ target ++ "/bindings.json")
      let bindings = maybe Null id (decode bindingBytes)
      bindings `shouldNotBe` Null
      let request = object ["schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
            "method" .= ("planGeneration" :: String), "target" .= target,
            "verification" .= object ["layers" .= (["property", "examples", "runtime"] :: [String])],
            "nativeBindings" .= bindings,
            "sources" .= [object ["path" .= path source, "content" .= content source]]]
      checkBudget [source] request
  it "rejects expanded scaffolding even when compacted to a single line" $ do
    let budget = testSizeBudget [Source "small.lawspec" "unit small end unit"] 1
        repeated = concat (replicate 20000 "check_case();")
    checkTestSize budget (Artifact "tests/Expanded" repeated "generated" "test") `shouldSatisfy` isFailure
    checkTestSize budget (Artifact "tests/Expanded" (unlines (replicate 20000 "check_case();")) "generated" "test")
      `shouldSatisfy` isFailure
  where
    checkBudget sources request = case decode (dispatch (encode request)) of
      Just (Object result) -> do
        K.lookup "diagnostics" result `shouldBe` Just (Array V.empty)
        let list name = case K.lookup name result of Just (Array values) -> V.toList values; _ -> []
            artifacts = [Artifact (field "path" value) (field "content" value)
              (field "ownership" value) (field "placement" value) | Object value <- list "files"]
            budget = testSizeBudget sources (length (list "tests"))
        artifacts `shouldSatisfy` (not . null)
        mapM_ (\artifact -> checkTestSize budget artifact `shouldBe` Right ()) artifacts
      other -> expectationFailure (show (other :: Maybe Value))
    field key value = case K.lookup key value of
      Just (String text) -> T.unpack text
      _ -> error ("missing generated artifact field: " ++ show key)
    isFailure (Left _) = True
    isFailure _ = False
