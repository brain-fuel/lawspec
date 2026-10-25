-- | Execution lowering shares a finite candidate body without changing the
-- checked claim, typed Core or the completeness of its domain.
-- ref:DEC-planned-generation ref:DEC-evidence-statuses
module FiniteSearchLoopSpec (test_finiteSearchHasOneCheckedBody) where

import Data.List (isInfixOf)
import Control.Monad (forM_)
import qualified LawSpec.Backend as Backend
import qualified LawSpec.Core as C
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Quantification (lowerSearchProof, lowerSearchPropositionCandidates)
import LawSpec.Core.Search (Candidate(..))
import LawSpec.Core.Eval (evaluate)
import LawSpec.Scalar (Scalar(..))
import LawSpec.Common (artifactContent, artifactPath, Quantification(..))
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
  it "shares the finite proof predicate and agrees with an independent finite oracle" $ do
    let origin = C.GeneratedFrom (C.Id "proof-loop")
        byte = C.scalarType "Int8"
        bool = C.scalarType "Bool"
        binder = C.Binder (C.Id "candidate") "candidate" byte
        local = C.Expr byte (C.Local (C.binderId binder)) origin
        number n = C.Expr byte (C.Constant (SInteger "Int8" n)) origin
        predicate = C.Expr bool (C.ExternalCall (C.Id "observe") [local]) origin
        equation = C.Equation (C.Structural bool) predicate (C.Expr bool (C.Constant (SBool True)) origin)
        domain _ = Right (Just (map number [-128..127]))
        adapter _ [SInteger _ n] = Right (SBool (n == 127))
        adapter _ _ = Left "unexpected oracle arguments"
    forM_ [ForEvery,ForSome] $ \kind -> do
      let quantified = C.Quantified kind (C.Quantifier binder [] []) equation
          lowered = lowerSearchProof domain (\_ _ -> Right []) 4096 100 (C.Id "proof-loop") [] quantified
      case lowered of
        Right (C.Equation _ claim _) -> do
          let expected = (if kind == ForEvery then all else any) (== (127 :: Integer)) [-128..127]
              nodes = descend claim
          evaluate 64 adapter [] claim `shouldBe` Right (SBool expected)
          length [() | C.Expr _ (C.ExternalCall identity _) _ <- nodes, identity == C.Id "observe"] `shouldBe` 1
          length nodes `shouldSatisfy` (< 800)
        other -> expectationFailure (show other)
  it "does not force rejected or unvisited constructive proof candidates" $ do
    let origin = C.GeneratedFrom (C.Id "guarded-proof")
        byte = C.scalarType "Int8"
        bool = C.scalarType "Bool"
        binder = C.Binder (C.Id "candidate") "candidate" byte
        local = C.Expr byte (C.Local (C.binderId binder)) origin
        number n = C.Expr byte (C.Constant (SInteger "Int8" n)) origin
        poison = C.Expr byte (C.ExternalCall (C.Id "must-not-run") []) origin
        rejected = CandidateGuard (C.Expr bool (C.Constant (SBool False)) origin) (Candidate poison)
        body = C.Quantified ForSome (C.Quantifier binder [] []) (C.Equation (C.Numeric byte) local (number 127))
        lowered = lowerSearchProof (\_ -> Right Nothing)
          (\_ _ -> Right [rejected,Candidate (number 127),Candidate poison]) 4096 3 (C.Id "guarded-proof") [] body
    case lowered of
      Right (C.Equation _ claim _) -> evaluate 64 (\_ _ -> Left "forced a rejected or unvisited candidate") [] claim
        `shouldBe` Right (SBool True)
      other -> expectationFailure (show other)
  it "retains outer bindings in dependent finite proof domains" $ do
    let origin = C.GeneratedFrom (C.Id "dependent-proof")
        integer = C.scalarType "Integer"
        x = C.Binder (C.Id "x") "x" integer
        y = C.Binder (C.Id "y") "y" integer
        local binder = C.Expr integer (C.Local (C.binderId binder)) origin
        number n = C.Expr integer (C.Constant (SInteger "Integer" n)) origin
        domain q = Right (Just (if C.binderId (C.quantifiedBinder q) == C.binderId x
          then map number [0,1] else [local x]))
        body = C.Quantified ForEvery (C.Quantifier x [] [])
          (C.Quantified ForSome (C.Quantifier y [] []) (C.Equation (C.Numeric integer) (local x) (local y)))
    case lowerSearchProof domain (\_ _ -> Right []) 4096 3 (C.Id "dependent-proof") [] body of
      Right (C.Equation _ claim _) -> evaluate 64 (\_ _ -> Left "unexpected adapter") [] claim
        `shouldBe` Right (SBool True)
      other -> expectationFailure (show other)
  it "shares optional selection envelopes while retaining lazy candidate calls and outcome order" $ do
    let origin = C.GeneratedFrom (C.Id "mixed-selection")
        byte = C.scalarType "Int8"
        bool = C.scalarType "Bool"
        binder = C.Binder (C.Id "candidate") "candidate" byte
        local = C.Expr byte (C.Local (C.binderId binder)) origin
        number n = C.Expr byte (C.Constant (SInteger "Int8" n)) origin
        call name args = C.Expr byte (C.ExternalCall (C.Id name) args) origin
        poison = call "must-not-run" []
        rejected = CandidateGuard (C.Expr bool (C.Constant (SBool False)) origin) (Candidate poison)
        candidates = rejected : [Candidate (call "visit" [number n]) | n <- [0..63]] ++ [Candidate poison]
        domain _ = Right Nothing
        search _ _ = Right candidates
    forM_ [0,31,63] $ \target -> do
      let proposition = C.Quantified ForSome (C.Quantifier binder [] [])
            (C.Equation (C.Numeric byte) local (number target))
          adapter (C.Id "visit") [SInteger "Int8" n]
            | n <= target = Right (SInteger "Int8" n)
          adapter _ _ = Left "forced a rejected, out-of-order or unvisited candidate"
          lowered = [ lowerSearchProof domain search 4096 66 (C.Id "mixed-selection") [] proposition
                    , lowerSearchPropositionCandidates domain search 4096 66 (C.Id "mixed-selection") [] proposition ]
      forM_ lowered $ \result -> case result of
        Right (C.Equation _ claim _) -> do
          evaluate 64 adapter [] claim `shouldBe` Right (SBool True)
          let envelopes = [() | C.Expr _ (C.Construct (C.Id "Maybe::Present") _) _ <- descend claim]
          length envelopes `shouldSatisfy` (< 12)
        other -> expectationFailure (show other)
  where
    descend expression = expression : concatMap descend (C.children expression)
