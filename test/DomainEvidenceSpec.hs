{-# LANGUAGE OverloadedStrings #-}
module DomainEvidenceSpec (test_domainEvidence) where

import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Core.DomainEvidence
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Smt (proofTasks,taskQuery)
import LawSpec.Core.Migration (normalizedProgram)
import LawSpec.Testing (planTesting)
import LawSpec.Core.Value
import qualified LawSpec.Core.Expression as Expression
import LawSpec.MigrationDomains (domainSnapshot)
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Vector as V
import LawSpec.Frontend (compileCoreCanonical,elaborateWithFormalValues,sourcePropertyId)
import qualified LawSpec.Compile as Compile
import LawSpec.MigrationTemplates (SourceTemplates(..))
import LawSpec.MigrationScopes (sourceContext)
import qualified Data.Map.Strict as M
import LawSpec.Common
import LawSpec.Scalar (Scalar(..))
import LawSpec.Model (Source(..))
import Data.Either (isLeft)

checked settings body = either (fail . show) pure
  (compileCoreCanonical 64 settings [Source "domain.lawspec" ("unit domain\n" ++ body)])
evidence settings text = checked settings text >>= evaluateDomain
evaluateDomain program = do
  registry <- either fail pure (makeRegistry (C.programDataDeclarations program))
  invoke <- either (fail . show) pure (prepareDefinitions program)
  let definitions=[definition | unit<-C.programUnits program,definition<-C.unitDefinitions unit]
      properties=[property | unit<-C.programUnits program,C.unitId unit==C.Id "domain",property<-C.unitProperties unit]
  case properties of
    [property] -> pure (inputDomainEvidence registry 64 invoke definitions property)
    _ -> fail "expected one domain property"
law text="law requirement is definition: " ++ text ++ " end end"
inhabited result = case domainStatus result of VerifiedInputTuple _ -> True; _ -> False
inconclusive result = case domainStatus result of InconclusiveDomain _ -> True; UnsupportedInputDomain _ -> True; _ -> False
domainDigest program = do
  snapshot <- either fail pure (domainSnapshot True [] program)
  case snapshot of
    A.Object fields | Just (A.Array domains) <- KM.lookup "domains" fields -> case V.toList domains of
      [A.Object domain] -> maybe (fail "missing domain digest") pure (KM.lookup "domainDigest" domain)
      _ -> fail "expected one domain fingerprint"
    _ -> fail "missing domain snapshot"

formalPrefix count program=program{C.programUnits=[unit{C.unitProperties=
  [property{C.propertyParameters=take count (C.propertyInputs property),
    C.propertyInputs=drop count (C.propertyInputs property)} | property<-C.unitProperties unit]} | unit<-C.programUnits program]}

test_domainEvidence = describe "checked input-domain evidence" $ do
  it "keeps formal and ordinary elaboration contexts separate after cache warming" $ do
    let text=Source "domain.lawspec" ("unit domain\n"++law "for all (choice :: Bool) (value :: Bool) => value = choice end")
    (units,laws,_,captured)<-either (fail.show) pure
      (Compile.compileWithMigrationCapture True (\_ name->name) (\_ _->Nothing) 64 defaultGeneration [text])
    templates<-maybe (fail "missing source templates") pure captured
    let elaborate counts=elaborateWithFormalValues counts M.empty True (sourceContext templates)
          (templateDataDeclarations templates) 64 units laws
        formal=M.singleton (sourcePropertyId "domain" "requirement") 1
        counts program=[length (C.propertyParameters property) | unit<-C.programUnits program,
          C.unitId unit==C.Id "domain",property<-C.unitProperties unit]
    first<-either (fail.show) pure (elaborate formal)
    ordinary<-either (fail.show) pure (elaborate M.empty)
    again<-either (fail.show) pure (elaborate formal)
    counts first `shouldBe` [1]
    counts ordinary `shouldBe` [0]
    counts again `shouldBe` [1]
    elaborate (M.singleton (C.Id "missing") 1) `shouldSatisfy` isLeft
    elaborate (M.map (const 3) formal) `shouldSatisfy` isLeft
  it "keeps formal values in lexical scope without sampling them as law inputs" $ do
    original<-checked defaultGeneration (law "for all (choice :: Bool) (value :: Bool where value = choice) => value = choice end")
    let program=formalPrefix 1 original
        unbound=program{C.programUnits=[unit{C.unitProperties=[property{C.propertyParameters=[]} |
          property<-C.unitProperties unit]} | unit<-C.programUnits program]}
    validateProgram program `shouldBe` Right ()
    validateProgram unbound `shouldSatisfy` isLeft
    normalized<-either fail pure (normalizedProgram True False [] program)
    validateProgram normalized `shouldBe` Right ()
    planTesting program `shouldSatisfy` isLeft
    -- Canonical universal semantics are the same nested logical binders in
    -- the existing SMT translation; the input-population scopes stay distinct.
    before<-either (fail.show) pure (proofTasks original)
    after<-either (fail.show) pure (proofTasks program)
    map taskQuery after `shouldBe` map taskQuery before
    dependent<-checked defaultGeneration (law "for all (choice :: Bool) (other :: Bool where other = choice) (value :: Bool) => other = choice end")
    let ordered=formalPrefix 2 dependent
        reversed=ordered{C.programUnits=[unit{C.unitProperties=[property{C.propertyParameters=reverse (C.propertyParameters property)} |
          property<-C.unitProperties unit]} | unit<-C.programUnits ordered]}
    validateProgram ordered `shouldBe` Right ()
    validateProgram reversed `shouldSatisfy` isLeft
  it "establishes an input witness independent of all admissible formal values" $ do
    original<-checked defaultGeneration (law "for all (choice :: Bool) (value :: Bool) => false end")
    let program=formalPrefix 1 original
    result<-evaluateDomain program
    domainStatus result `shouldBe` VerifiedInputTuple [ScalarValue (SBool False)]
    snapshot<-either fail pure (domainSnapshot True [] program)
    case snapshot of
      A.Object fields | Just (A.Array rows)<-KM.lookup "domains" fields,
        [A.Object row]<-V.toList rows -> do
          KM.lookup "inputCount" row `shouldBe` Just (A.Number 1)
          KM.lookup "formalParameterCount" row `shouldBe` Just (A.Number 1)
          KM.lookup "uniformity" row `shouldBe` Just (A.String "parameter-independent")
      _->expectationFailure "missing formal input-domain evidence"
  it "does not turn one bounded parameter choice into uniform population evidence" $ do
    original<-checked defaultGeneration (law "for all (minimum :: Integer) (value :: Bool where minimum != 0) => true end")
    result<-evaluateDomain (formalPrefix 1 original)
    domainStatus result `shouldSatisfy` (\status -> case status of UnsupportedInputDomain _->True;_->False)
    domainSearch result `shouldBe` "unsupported-uniform-input-search"
    domainCandidateChecks result `shouldBe` 0
  it "retains the formal parameter's own restriction in input-domain fingerprints" $ do
    first<-checked defaultGeneration (law "for all (minimum :: Integer where minimum >= 0) (value :: Bool) => true end")
    changed<-checked defaultGeneration (law "for all (minimum :: Integer where minimum >= 1) (value :: Bool) => true end")
    a<-domainDigest (formalPrefix 1 first)
    b<-domainDigest (formalPrefix 1 changed)
    a `shouldNotBe` b
  it "checks every finite formal tuple and records its dependent input witness without evaluating the law" $ do
    original<-checked defaultGeneration (law "for all (choice :: Bool) (value :: Bool where value = choice) => false end")
    result<-evaluateDomain (formalPrefix 1 original)
    let boolean=ScalarValue . SBool
    domainStatus result `shouldBe` VerifiedFiniteParameterInputs
      [([boolean False],[boolean False]),([boolean True],[boolean True])]
    domainSearch result `shouldBe` "complete-finite-parameter-input-domains"
    domainCandidateChecks result `shouldBe` 6
    snapshot<-either fail pure (domainSnapshot True [] (formalPrefix 1 original))
    case snapshot of
      A.Object fields | Just (A.Array rows)<-KM.lookup "domains" fields,
        [A.Object row]<-V.toList rows -> do
          KM.lookup "status" row `shouldBe` Just (A.String "uniformly-inhabited")
          KM.lookup "complete" row `shouldBe` Just (A.Bool True)
          KM.lookup "uniformity" row `shouldBe` Just (A.String "complete-finite-parameters")
      _->expectationFailure "missing finite parameter-domain evidence"
  it "distinguishes an admissible formal counterexample from a refuted law" $ do
    original<-checked defaultGeneration (law "for all (choice :: Bool) (value :: Bool where choice and value) => true end")
    result<-evaluateDomain (formalPrefix 1 original)
    domainStatus result `shouldBe` CompleteEmptyInputForParameter [ScalarValue (SBool False)]
  it "filters formal restrictions and keeps dependent formal scopes left to right" $ do
    original<-checked defaultGeneration (law "for all (choice :: Bool where choice) (other :: Bool where other = choice) (value :: Bool where value = other) => false end")
    result<-evaluateDomain (formalPrefix 2 original)
    let yes=ScalarValue (SBool True)
    domainStatus result `shouldBe` VerifiedFiniteParameterInputs [([yes,yes],[yes])]
  it "keeps complete empty parameter domains distinct from inhabited populations" $ do
    original<-checked defaultGeneration (law "for all (choice :: Bool where false) (value :: Bool where value = choice) => false end")
    result<-evaluateDomain (formalPrefix 1 original)
    domainStatus result `shouldBe` CompleteEmptyParameterDomain
    domainCandidateChecks result `shouldBe` 2
  it "closes exact earlier values before deriving a complete unsigned input cover" $ do
    original<-checked defaultGeneration (law "for all (choice :: Whole where choice <= 1) (value :: Whole where value = choice) => false end")
    result<-evaluateDomain (formalPrefix 1 original)
    let whole=ScalarValue . SInteger "BigUInt"
    domainStatus result `shouldBe` VerifiedFiniteParameterInputs [([whole 0],[whole 0]),([whole 1],[whole 1])]
  it "reports an exhausted combined finite budget without asserting uniformity or absence" $ do
    original<-checked defaultGeneration{exhaustiveLimit=3}
      (law "for all (choice :: Bool) (value :: Bool where value = choice) => false end")
    result<-evaluateDomain (formalPrefix 1 original)
    domainStatus result `shouldSatisfy` (\status->case status of InconclusiveDomain _->True;_->False)
    domainCandidateChecks result `shouldBe` 3
  it "does not turn a failing dependent restriction evaluation into a parameter counterexample" $ do
    original<-checked defaultGeneration
      (law "for all (choice :: Bool) (value :: Bool where value = choice and (1 / 0 :: Integer) = 0) => true end")
    result<-evaluateDomain (formalPrefix 1 original)
    domainStatus result `shouldSatisfy` (\status->case status of InconclusiveDomain _->True;_->False)
    domainNotes result `shouldSatisfy` (not.null)
  it "establishes a populated domain without executing a false law body" $ do
    result <- evidence defaultGeneration (law "for all (value :: Bool) => false end")
    domainStatus result `shouldBe` VerifiedInputTuple [ScalarValue (SBool False)]
  it "never evaluates an undefined law body while checking its inputs" $ do
    result <- evidence defaultGeneration (law "for all (value :: Bool) => (1 / 0 :: Integer) = 0 end")
    result `shouldSatisfy` inhabited
  it "checks a no-input law's one empty input tuple independently of its body" $ do
    result <- evidence defaultGeneration (law "false")
    domainStatus result `shouldBe` VerifiedInputTuple []
  it "distinguishes a complete finite empty domain from a bounded miss" $ do
    empty <- evidence defaultGeneration (law "for all (value :: Bool where false) => true end")
    domainStatus empty `shouldBe` CompleteEmptyDomain
    domainCandidateChecks empty `shouldBe` 2
    missed <- evidence defaultGeneration (law "for all (value :: Integer where value * value = 1040400) => true end")
    missed `shouldSatisfy` inconclusive
    domainSearch missed `shouldBe` "bounded-input-search"
  it "checks self and earlier-binder restrictions in a complete finite product" $ do
    result <- evidence defaultGeneration (law "for all (left :: Bool) (right :: Bool where right != left) => false end")
    domainStatus result `shouldBe` VerifiedInputTuple [ScalarValue (SBool False),ScalarValue (SBool True)]
    domainCandidateChecks result `shouldBe` 2
  it "rechecks dependent restrictions during bounded prefix search" $ do
    result <- evidence defaultGeneration{exhaustiveLimit=1}
      (law "for all (left :: Bool where left) (right :: Integer where right = (if left then 2 else 3 end if)) => false end")
    domainStatus result `shouldBe` VerifiedInputTuple [ScalarValue (SBool True),ScalarValue (SInteger "Integer" 2)]
    domainSearch result `shouldBe` "bounded-input-search"
  it "uses ordinary checked functions in input restrictions" $ do
    result <- evidence defaultGeneration ("function allowed (value :: Bool) -> Bool is value end function\n" ++
      law "for all (value :: Bool where allowed value) => false end")
    domainStatus result `shouldBe` VerifiedInputTuple [ScalarValue (SBool True)]
  it "keeps native adapter restrictions outside the admitted evaluator" $ do
    program <- checked defaultGeneration ("native :: Bool -> Bool\n" ++ law "for all (value :: Bool) => true end")
    let propertyChanged property=property{C.propertyInputs=[q{C.quantifiedPredicates=[
          C.Expr (C.scalarType "Bool") (C.ExternalCall (C.Id "domain::native")
            [C.Expr (C.scalarType "Bool") (C.Local (C.binderId (C.quantifiedBinder q))) origin]) origin]} | q<-C.propertyInputs property]}
        origin=C.GeneratedFrom (C.Id "candidate")
        modified=program{C.programUnits=[unit{C.unitProperties=map propertyChanged (C.unitProperties unit)} | unit<-C.programUnits program]}
    isLeft (prepareDefinitions modified) `shouldBe` True
  it "does not interpret undefined restriction evaluations as emptiness" $ do
    program <- checked defaultGeneration (law "for all (value :: Bool) => true end")
    division <- either fail pure (Expression.operationEvidence C.Divide (C.scalarType "Integer") (C.scalarType "Integer"))
    let origin=C.GeneratedFrom (C.Id "candidate")
        integer n=C.Expr (C.scalarType "Integer") (C.Constant (SInteger "Integer" n)) origin
        resultType=case division of C.Numeric ty -> ty; C.Structural ty -> ty
        undefinedValue=C.Expr resultType (C.Binary C.Divide division (integer 1) (integer 0)) origin
    comparison <- either fail pure (Expression.operationEvidence C.Equal resultType resultType)
    let
        predicate=C.Expr (C.scalarType "Bool")
          (C.Binary C.Equal comparison undefinedValue undefinedValue) origin
        modified=program{C.programUnits=[unit{C.unitProperties=
          [property{C.propertyInputs=[q{C.quantifiedPredicates=[predicate]} | q<-C.propertyInputs property]} |
            property<-C.unitProperties unit]} | unit<-C.programUnits program]}
    result <- evaluateDomain modified
    result `shouldSatisfy` inconclusive
    domainSearch result `shouldBe` "complete-finite-input-domain"
    domainNotes result `shouldSatisfy` (not . null)
  it "keeps IEEE non-reflexive witnesses rather than using host equality" $ do
    result <- evidence defaultGeneration (law "for all (value :: Float64 where value != value) => false end")
    result `shouldSatisfy` inhabited
  it "does not treat a native handle or a nominal field containing one as an empty domain" $ do
    mapM_ (\body -> do
      result <- evidence defaultGeneration body
      result `shouldSatisfy` inconclusive)
      ["handle Connection\n" ++ law "for all (connection :: Connection) => true end",
       "handle Connection\ntype Envelope is a record{connection :: Connection} end type\n" ++
          law "for all (envelope :: Envelope) => true end"]
  it "does not treat existential witness pools as complete type covers" $ do
    result <- evidence defaultGeneration ("type Hidden is one of | Wrap of type a end type\n" ++
      law "for all (hidden :: Hidden where false) => true end")
    result `shouldSatisfy` inconclusive
  it "checks nested intrinsic field restrictions before recording a witness" $ do
    result <- evidence defaultGeneration ("type Positive is a record{value :: (n :: UInt8 where n > 0)} end type\n" ++
      law "for all (positive :: Positive) => false end")
    case domainStatus result of
      VerifiedInputTuple [DataValue _ _ [ScalarValue (SInteger "UInt8" value)]] -> value `shouldSatisfy` (>0)
      other -> expectationFailure (show other)
  it "retains nominal predicate changes behind an unchanged domain type name" $ do
    before <- checked defaultGeneration ("type Positive is a record{value :: (n :: UInt8 where n > 0)} end type\n" ++
      law "for all (positive :: Positive) => true end")
    after <- checked defaultGeneration ("type Positive is a record{value :: (n :: UInt8 where n > 1)} end type\n" ++
      law "for all (positive :: Positive) => true end")
    old <- domainDigest before
    new <- domainDigest after
    old `shouldNotBe` new
  it "ignores unrelated function edits while retaining actual domain dependencies" $ do
    let source body="function allowed (value :: Bool) -> Bool is value end function\n" ++
          "function unrelated (value :: Bool) -> Bool is " ++ body ++ " end function\n" ++
          law "for all (value :: Bool where allowed value) => true end"
    before <- checked defaultGeneration (source "value")
    after <- checked defaultGeneration (source "not value")
    domainDigest before >>= \old -> domainDigest after >>= \new -> old `shouldBe` new
  it "retains transitive calls used by deferred runtime postconditions" $ do
    let source body="function allowed (value :: Bool) -> Bool is value end function\n" ++
          "function gate (value :: Bool) -> Bool is " ++ body ++ " end function\n" ++
          law "for all (value :: Bool where allowed value) => true end"
        withRuntime program=program{C.programUnits=[unit{C.unitContracts=C.unitContracts unit++[contract]} | unit<-C.programUnits program,C.unitId unit==C.Id "domain"]}
        origin=C.GeneratedFrom (C.Id "runtime-domain")
        argument=C.Binder (C.Id "runtime-argument") "value" (C.scalarType "Bool")
        result=C.Binder (C.Id "runtime-result") "result" (C.scalarType "Bool")
        call=C.Expr (C.scalarType "Bool") (C.ExternalCall (C.Id "domain::gate")
          [C.Expr (C.scalarType "Bool") (C.Local (C.binderId result)) origin]) origin
        condition=C.Expr (C.scalarType "Bool") (C.ShortCircuit C.Or call
          (C.Expr (C.scalarType "Bool") (C.Unary C.Not call) origin)) origin
        contract=C.Contract (C.Id "domain::allowed") [argument] result [] [] [condition]
    before <- withRuntime <$> checked defaultGeneration (source "true")
    after <- withRuntime <$> checked defaultGeneration (source "not value")
    evaluateDomain before >>= (\result -> result `shouldSatisfy` inhabited)
    evaluateDomain after >>= (\result -> result `shouldSatisfy` inhabited)
    domainDigest before >>= \old -> domainDigest after >>= \new -> old `shouldNotBe` new
