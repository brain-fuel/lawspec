-- | Execution lowering shares a finite candidate body without changing the
-- checked claim, typed Core or the completeness of its domain.
-- ref:DEC-planned-generation ref:DEC-evidence-statuses
module FiniteSearchLoopSpec (test_finiteSearchHasOneCheckedBody) where

import Data.List (isInfixOf)
import qualified LawSpec.Backend as Backend
import qualified LawSpec.Core as C
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Common (artifactContent, artifactPath)
import LawSpec.CoreEmit (emitPlan)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Testing
import Test.Hspec
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)

test_finiteSearchHasOneCheckedBody :: Spec
test_finiteSearchHasOneCheckedBody = describe "finite search execution loops" $ do
  it "keeps a complete Int8 search small, typed and separate from its source claim" $ do
    let text = unlines
          [ "unit finite.search"
          , "law \"|a byte can be selected| is"
          , "  definition: for all (flag :: Bool) =>"
          , "    there exists (candidate :: Int8) such that candidate = 123 end exists"
          , "  end for all end definition"
          , "end law"
          , "end unit" ]
    case compileCore 64 defaultGeneration [Source "finite-search.lawspec" text] of
      Left errors -> expectationFailure (show errors)
      Right program -> case planTesting program of
        Left errors -> expectationFailure (show errors)
        Right plan -> do
          let properties = concatMap plannedProperties (plannedUnits plan)
              nodes = concatMap (concatMap descend . C.propertyExpressions . plannedProperty) properties
              loops = [() | C.Expr _ (C.SearchElements {}) _ <- nodes]
          length loops `shouldBe` 1
          length nodes `shouldSatisfy` (< 100)
          validateProgram (program { C.programUnits = map plannedUnit (plannedUnits plan) }) `shouldBe` Right ()
          [description | p <- properties, let description = Backend.prettyExpanded p,
            "there exists" `isInfixOf` description] `shouldSatisfy` (not . null)
          map Backend.prettyExpanded properties `shouldSatisfy` all (not . isInfixOf "searchElements")
  it "awaits a finite search inside asynchronous JavaScript bindings" $ do
    let text = unlines
          [ "unit finite.asynchronous"
          , "async unused :: Int8 -> Bool"
          , "law \"|a byte can be selected| is"
          , "  definition: for all (flag :: Bool) =>"
          , "    there exists (candidate :: Int8) such that unused candidate = flag end exists"
          , "  end for all end definition"
          , "end law"
          , "end unit" ]
    case compileCore 64 defaultGeneration [Source "finite-async.lawspec" text] >>= planTesting >>= emitPlan "javascript" of
      Left errors -> expectationFailure (show errors)
      Right files -> do
        let checks = [artifactContent file | file <- files,
                      "test" `isInfixOf` artifactPath file, "searchElementsAsync" `isInfixOf` artifactContent file]
        checks `shouldSatisfy` (not . null)
        mapM_ (\source -> do
          (code, _, err) <- readProcessWithExitCode "node" ["--input-type=module", "--check"] source
          (code, err) `shouldBe` (ExitSuccess, "")) checks
  where
    descend expression = expression : concatMap descend (C.children expression)
