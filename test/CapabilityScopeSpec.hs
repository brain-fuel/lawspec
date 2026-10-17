module CapabilityScopeSpec (test_capabilityScopes) where

import Test.Hspec
import Data.Either (isLeft)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import qualified LawSpec.Core as C
import LawSpec.Core.CapabilityScope
import qualified LawSpec.Core.Types as Types
import LawSpec.Core.Validate (validateProgram,validateProgramWithScopes)
import LawSpec.Scalar (Scalar(..))

variable=C.Id "a"
ty=C.TypeVariable variable
origin=C.GeneratedFrom (C.Id "scope-test")
node t n=C.Expr t n origin
argument n=C.Binder (C.Id n) n ty
declaration n=C.Declaration (C.Id n) n (C.Arrow ty (C.Arrow ty (C.scalarType "Bool"))) origin
equalDefinition n=C.Definition (declaration n) [argument "left",argument "right"]
  (node (C.scalarType "Bool") (C.Binary C.Equal (C.Structural ty)
    (node ty (C.Local (C.Id "left"))) (node ty (C.Local (C.Id "right")))))
program definitions=C.Program 64 [] [C.Unit (C.Id "scope") (map C.definitionDeclaration definitions) [] [] definitions []]
eqCapabilities=Capabilities (Set.singleton variable) Set.empty
contexts owners=M.fromList [(C.Id owner,eqCapabilities) | owner<-owners]

test_capabilityScopes=describe "lexical symbolic Core capabilities" $ do
  it "permits equality without supplying Keyed, generation or a shared registry fact" $ do
    registry<-either fail pure (Types.makeRegistry [])
    let own=Types.assumingCapabilities (Set.singleton variable) Set.empty registry
    Types.equalityRequirements own ty `shouldBe` Right []
    Types.keyedRequirements own ty `shouldBe` Right [variable]
    Types.generationRequirements own ty `shouldBe` Right [variable]
    Types.equalityRequirements registry ty `shouldBe` Right [variable]
  it "lets Keyed supply equality without supplying generation" $ do
    registry<-either fail pure (Types.makeRegistry [])
    let own=Types.assumingCapabilities Set.empty (Set.singleton variable) registry
    Types.equalityRequirements own ty `shouldBe` Right []
    Types.keyedRequirements own ty `shouldBe` Right []
    Types.generationRequirements own ty `shouldBe` Right [variable]
  it "keeps ordinary executable admission strict after a scoped audit warms the caches" $ do
    let value=program [equalDefinition "same"]
    validateProgramWithScopes (contexts ["same"]) value `shouldBe` Right ()
    validateProgram value `shouldSatisfy` isLeft
    validateProgramWithScopes (contexts ["same"]) value `shouldBe` Right ()
  it "does not leak a type-variable capability to another definition" $ do
    let value=program [equalDefinition "same",equalDefinition "other"]
    validateProgramWithScopes (contexts ["same"]) value `shouldSatisfy` isLeft
    validateProgramWithScopes (contexts ["same","other"]) value `shouldBe` Right ()
  it "requires a caller to supply the capability of a generic callee" $ do
    let callee=equalDefinition "same"
        caller=C.Definition (declaration "caller") [argument "left",argument "right"]
          (node (C.scalarType "Bool") (C.ExternalCall (C.Id "same")
            [node ty (C.Local (C.Id "left")),node ty (C.Local (C.Id "right"))]))
        value=program [callee,caller]
    validateProgramWithScopes (contexts ["same"]) value `shouldSatisfy` isLeft
    validateProgramWithScopes (contexts ["same","caller"]) value `shouldBe` Right ()
  it "rejects a stale scope owner and an unrelated variable assumption" $ do
    let value=program [equalDefinition "same"]
    validateProgramWithScopes (contexts ["unknown"]) value `shouldSatisfy` isLeft
    validateProgramWithScopes (M.singleton (C.Id "same") (Capabilities (Set.singleton (C.Id "b")) Set.empty)) value `shouldSatisfy` isLeft
  it "does not acquire equality for function types from an unrelated variable capability" $ do
    registry<-either fail pure (Types.makeRegistry [])
    Types.equalityRequirements (Types.assumingCapabilities (Set.singleton variable) Set.empty registry)
      (C.Arrow ty ty) `shouldSatisfy` isLeft
  it "does not assume reflexivity or bypass result contracts" $ do
    let base=program [equalDefinition "same"]
        result=C.Binder (C.Id "result") "result" (C.scalarType "Bool")
        reflexive=node (C.scalarType "Bool") (C.Binary C.Equal (C.Structural ty)
          (node ty (C.Local (C.Id "left"))) (node ty (C.Local (C.Id "left"))))
        contract=C.Contract (C.Id "same") [argument "left",argument "right"] result [] [reflexive] []
        falseContract=contract{C.contractPostconditions=[node (C.scalarType "Bool") (C.Constant (SBool False))]}
        with value=base{C.programUnits=[unit{C.unitContracts=[value]} | unit<-C.programUnits base]}
    validateProgramWithScopes (contexts ["same"]) (with contract) `shouldSatisfy` isLeft
    validateProgramWithScopes (contexts ["same"]) (with falseContract) `shouldSatisfy` isLeft
