-- | Structural identities are semantic and portable, while constructor
-- admission and source evaluation order remain mandatory checked behavior.
-- ref:DEC-readable-notation ref:DEC-typed-core-boundary
module RecordIdentitySpec (test_recordIdentitiesPreserveSemantics) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.Char (isAlphaNum)
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import Data.Binary (decode,encode)
import qualified Data.ByteString.Lazy as BL
import Data.Either (isLeft, isRight)
import Data.IORef
import Data.List (permutations)
import qualified Data.Map.Strict as M
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec
import LawSpec.Core
import LawSpec.Core.RecordIdentity
import LawSpec.Core.Types
import LawSpec.Core.Value
import LawSpec.Core.Eval (evaluateValue)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Total (constructorProofContracts)
import LawSpec.CoreEmit (emitPlan, targets)
import LawSpec.Backend (localName)
import LawSpec.Common (defaultGeneration)
import LawSpec.Public (programView)
import qualified LawSpec.Testing as Testing
import RecordIdentityFixtures (recordSmokeProgram)
import LawSpec.Scalar

origin :: Origin
origin = GeneratedFrom (Id "records")
integerType, boolean :: Type
integerType = scalarType "Integer"
boolean = scalarType "Bool"
value :: Integer -> Expr
value n = Expr integerType (Constant (SInteger "Integer" n)) origin
local :: Binder -> Expr
local b = Expr (binderType b) (Local (binderId b)) origin
comparison :: BinaryOp -> Expr -> Expr -> Expr
comparison operation a b = Expr boolean (Binary operation (Numeric (expressionType a)) a b) origin
field :: String -> Type -> RecordField
field name ty = RecordField (Binder (Id ("field::" ++ name)) name ty) []
described :: [Id] -> [RecordField] -> RecordDescription
described parameters fields = either error id (describeRecord parameters fields)
descriptor :: [RecordField] -> RecordDescriptor
descriptor = recordDescriptor . described []
record :: [RecordField] -> DataDeclaration
record fields = fst (either error id (makeRecordDeclaration [] fields origin))

test_recordIdentitiesPreserveSemantics :: Spec
test_recordIdentitiesPreserveSemantics = describe "closed structural record identities" $ do
  it "uses versioned array descriptors and a full 256-bit digest" $ do
    let d = descriptor [field "amount" integerType]
        arrays (A.Object _) = False
        arrays (A.Array values) = all arrays values
        arrays _ = True
    length (descriptorDigest d) `shouldBe` 64
    case A.eitherDecode (BL.fromStrict (descriptorBytes d)) of
      Right json -> arrays json `shouldBe` True
      Left message -> expectationFailure message
  it "keeps every field permutation identical without sorting the supplied values" $ do
    let fields = [field "z" integerType,field "b" boolean,field "c" (scalarType "Text"),field "a" integerType]
    map descriptor (permutations fields) `shouldBe` replicate 24 (descriptor fields)
    map (binderName . recordFieldBinder) fields `shouldBe` ["z","b","c","a"]
  it "distinguishes labels, resolved types, refinements and field relationships" $ do
    let x = field "x" integerType
        y = field "y" integerType
        condition op a b = [comparison op (local (recordFieldBinder a)) (local (recordFieldBinder b))]
        refined op a b = a{recordFieldPredicates=condition op a b}
        variants = [[x],[field "other" integerType],[field "x" (scalarType "Int64")],
          [refined Greater x y,y],[refined Greater y x,x],[refined Less x y,y]]
    let digests = map (descriptorDigest . descriptor) variants
    length (M.fromList (zip digests (repeat ()))) `shouldBe` length variants
  it "does not move a restriction to another field merely because its free variables agree" $ do
    let x = field "x" integerType; y = field "y" integerType
        predicate = comparison Greater (local (recordFieldBinder x)) (value 0)
    descriptor [x{recordFieldPredicates=[predicate]},y] `shouldNotBe`
      descriptor [x,y{recordFieldPredicates=[predicate]}]
  it "normalizes parameter spelling and returns each use site's parameter permutation" $ do
    let a=Id "a"; b=Id "b"; alpha=Id "alpha"; beta=Id "beta"
        first = described [a,b] [field "y" (TypeVariable b),field "x" (TypeVariable a)]
        second = described [beta,alpha] [field "x" (TypeVariable alpha),field "y" (TypeVariable beta)]
        repeated = described [a,b] [field "x" (TypeVariable a),field "y" (TypeVariable a)]
    recordDescriptor first `shouldBe` recordDescriptor second
    recordParameters first `shouldBe` [a,b]
    recordParameters second `shouldBe` [alpha,beta]
    recordDescriptor repeated `shouldNotBe` recordDescriptor first
    described [a,Id "unused"] [field "x" (TypeVariable a)] `shouldBe`
      described [a] [field "x" (TypeVariable a)]
  it "rejects duplicate labels, reused field identities and unbound values or types" $ do
    let x = field "x" integerType
        y = (field "y" integerType){recordFieldBinder=(recordFieldBinder x){binderName="y"}}
    forM_ [[x,x],[x,y],[field "x" (TypeVariable (Id "free"))],
      [x{recordFieldPredicates=[Expr boolean (Local (Id "free")) origin]}]] $ \fields ->
      describeRecord [] fields `shouldSatisfy` isLeft
  it "ignores source origins and alpha renames nested expression binders" $ do
    let x = field "x" integerType
        predicate name = let b=Binder (Id name) name integerType
          in Expr boolean (Let b (local (recordFieldBinder x)) (comparison Equal (local b) (local (recordFieldBinder x)))) (GeneratedFrom (Id name))
    descriptor [x{recordFieldPredicates=[predicate "first"]}] `shouldBe`
      descriptor [x{recordFieldPredicates=[predicate "renamed"]}]
  it "keeps sibling existential type binders local while preserving constructor identity" $ do
    let package = field "package" (scalarType "Package")
        predicate suffix = let a=Id ("a"++suffix); b=Binder (Id ("value"++suffix)) "value" (TypeVariable a)
          in Expr boolean (Match (local (recordFieldBinder package))
            [MatchCase (Id "Package::Packed") [b]
              (Expr boolean (Binary Equal (Structural (TypeVariable a)) (local b) (local b)) origin)]) origin
    descriptor [package{recordFieldPredicates=[predicate "1"]}] `shouldBe`
      descriptor [package{recordFieldPredicates=[predicate "2"]}]
  it "normalizes exact scalar representations without flattening IEEE distinctions" $ do
    let scalar s = let ty=scalarType (scalarName s); e=Expr ty (Constant s) origin
          in descriptor [(field "value" integerType){recordFieldPredicates=[Expr boolean (Binary Equal (Numeric ty) e e) origin]}]
    scalar (SDecimal 100 (-2)) `shouldBe` scalar (SDecimal 1 0)
    scalar (SDecimal 0 (10^12)) `shouldBe` scalar (SDecimal 0 0)
    scalar (SRational (-2) (-4)) `shouldBe` scalar (SRational 1 2)
    scalar (SFloat "Float64" "7FF8000000000001") `shouldBe` scalar (SFloat "Float64" "7ff8000000000001")
    scalar (SFloat "Float64" "0000000000000000") `shouldNotBe` scalar (SFloat "Float64" "8000000000000000")
    scalar (SFloat "Float64" "7ff8000000000001") `shouldNotBe` scalar (SFloat "Float64" "7ff8000000000002")
  it "excludes conversion blame metadata while retaining the resolved target type" $ do
    let d conversion = let ty=scalarType "Int64"; e=Expr ty (Convert conversion ty (value 1)) origin
          in descriptor [(field "x" integerType){recordFieldPredicates=[comparison Equal e e]}]
    d Explicit `shouldBe` d CheckedArgument
  it "keeps nominal references opaque and dependency fingerprints separate" $ do
    let d = descriptor [field "money" (scalarType "shop::type::Money")]
    descriptorDependencies d `shouldBe` [Id "shop::type::Money"]
    dependencyFingerprint (const (Just "before")) d `shouldNotBe` dependencyFingerprint (const (Just "after")) d
    dependencyFingerprint (const Nothing) d `shouldSatisfy` isLeft
    descriptor [field "money" (scalarType "shop::type::OtherMoney")] `shouldNotBe` d
  it "normalizes dependent field identities while retaining their relationships" $ do
    let fields suffix selected =
          let size=(field "size" integerType){recordFieldBinder=Binder (Id ("size"++suffix)) "size" integerType}
              other=(field "other" integerType){recordFieldBinder=Binder (Id ("other"++suffix)) "other" integerType}
              vector=field "values" (Constructor "Vec" [IndexArgument (IndexVariable (Id (selected++suffix))),TypeArgument integerType])
          in [size,vector,other]
    descriptor (fields "one" "size") `shouldBe` descriptor (reverse (fields "two" "size"))
    descriptor (fields "one" "size") `shouldNotBe` descriptor (fields "one" "other")
  it "compares stored descriptors even when an injected digest index collides" $ do
    let a=descriptor [field "x" integerType]; b=descriptor [field "y" integerType]
        (_,pool)=either error id (internRecordWith (const "collision") a emptyInterner)
    internRecordWith (const "collision") a pool `shouldSatisfy` isRight
    internRecordWith (const "collision") b pool `shouldSatisfy` isLeft
  it "constructs empty products and canonical declarations without phantom parameters" $ do
    let (declaration,parameters)=either error id (makeRecordDeclaration [Id "unused"] [] origin)
    parameters `shouldBe` []
    validateRecordDeclaration declaration `shouldBe` Right ()
    fmap (length . filter ((== dataId declaration) . dataId) . registryDeclarations) (makeRegistry [declaration,declaration]) `shouldBe` Right 1
  it "validates stored descriptors and rejects forged hashes, names and restriction indexes" $ do
    let declaration=record [field "x" integerType]
        Just metadata=dataStructural declaration
        bad=[declaration{dataId=Id "forged"},declaration{dataName="forged"},
          declaration{dataStructural=Just metadata{structuralDescriptor="forged"}},
          declaration{dataStructural=Just metadata{structuralPredicates=[("x",[0])]}},
          declaration{dataParameters=[Id "unused"]}]
    forM_ bad $ \d -> fmap (const ()) (makeRegistry [d]) `shouldSatisfy` isLeft
  it "never interns a nominal type with an identical-looking structural product" $ do
    let anonymous=record [field "x" integerType]
        nominal=(DataDeclaration (Id "shop::type::Named") "Named" []
          [DataConstructor (Id "shop::type::Named::Named") "Named" [Binder (Id "namedx") "x" integerType] [] origin [] []] origin Nothing)
    matchType [] M.empty (scalarType (idText (dataId anonymous))) (scalarType (idText (dataId nominal))) `shouldBe` Nothing
    fmap (const ()) (makeRegistry [anonymous,nominal]) `shouldBe` Right ()
    fmap (const ()) (makeRegistry [nominal,nominal]) `shouldSatisfy` isLeft
  it "preserves structural metadata in persisted Core and its public typed view" $ do
    let program=recordSmokeProgram 64
        restored=decode (encode program) :: Program
    restored `shouldBe` program
    case programView defaultGeneration [] [] [] [] restored of
      A.Object object -> case KM.lookup "dataTypes" object of
        Just (A.Array declarations) -> forM_ declarations $ \declaration -> case declaration of
          A.Object entry -> case KM.lookup "structure" entry of
            Just (A.Object structure) -> do
              KM.lookup "kind" structure `shouldBe` Just (A.String "record")
              KM.member "digest" structure `shouldBe` True
              KM.member "descriptor" structure `shouldBe` True
              KM.member "fields" structure `shouldBe` True
            _ -> expectationFailure "the public type lost its structural identity"
          _ -> expectationFailure "invalid public type declaration"
        _ -> expectationFailure "missing public data declarations"
      _ -> expectationFailure "invalid public program view"
  it "retains mandatory constructor definedness audits for every duplicate occurrence" $ do
    let x=field "x" integerType; y=field "y" integerType
        nonzero=comparison NotEqual (local (recordFieldBinder x)) (value 0)
        divided=Expr integerType (Binary Quotient (Numeric integerType) (value 1) (local (recordFieldBinder x))) origin
        positive=comparison Greater divided (value 0)
        good=record [x{recordFieldPredicates=[nonzero]},y{recordFieldPredicates=[positive]}]
        bad=record [y{recordFieldPredicates=[positive]},x{recordFieldPredicates=[nonzero]}]
    dataId good `shouldBe` dataId bad
    constructorProofContracts 64 [good] `shouldSatisfy` isRight
    forM_ [[good,bad],[bad,good]] $ \declarations ->
      validateProgram (Program 64 declarations []) `shouldSatisfy` isLeft
  it "evaluates supplied fields once in source order before canonical construction" $ do
    let declaration=record [field "a" integerType,field "z" integerType]
        call name=Expr integerType (ExternalCall (Id name) []) origin
        expression=either error id (constructRecord (Id "literal") declaration [] [("z",call "first"),("a",call "second")] origin)
        registry=either error id (makeRegistry [declaration])
    calls <- newIORef ([] :: [String])
    let invoke identity _=unsafePerformIO $ do
          modifyIORef' calls (++ [idText identity])
          pure (Right (ScalarValue (SInteger "Integer" (if idText identity=="first" then 1 else 2))))
    actual <- evaluate (evaluateValue registry 64 invoke [] expression)
    fmap (\value -> case value of DataValue _ _ xs -> xs; _ -> []) actual `shouldBe`
      Right [ScalarValue (SInteger "Integer" 2),ScalarValue (SInteger "Integer" 1)]
    readIORef calls `shouldReturn` ["first","second"]
  it "rejects width subtyping, duplicate fields and mismatched contextual field types" $ do
    let declaration=record [field "x" integerType]
    forM_ [[("x",value 1),("extra",value 2)],[],[("x",value 1),("x",value 2)],
      [("x",Expr boolean (Constant (SBool True)) origin)]] $ \values ->
      constructRecord (Id "literal") declaration [] values origin `shouldSatisfy` isLeft
  it "keeps separate record temporaries distinct and valid in generated expressions" $ do
    let declaration=record [field "x" integerType]
        temporary prefix=case either error id (constructRecord (Id prefix) declaration [] [("x",value 1)] origin) of
          Expr _ (Let binder _ _) _ -> localName (binderId binder)
          _ -> error "record construction lost its single-evaluation binding"
        names=map temporary ["first literal","nested.literal","other::literal"]
    length (M.fromList (zip names (repeat ()))) `shouldBe` length names
    forM_ names $ \name -> do
      take 1 name `shouldBe` "_"
      all (\character -> isAlphaNum character || character=='_') name `shouldBe` True
  it "admits structural products, generic instances, nested projections and empty records through every target" $
    forM_ [32,64] $ \bits -> case Testing.planTesting (recordSmokeProgram bits) of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right plan -> do
        length (Testing.planDataDeclarations plan) `shouldBe` 4
        forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
