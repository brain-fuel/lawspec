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
import Data.List (isInfixOf, permutations)
import qualified Data.Map.Strict as M
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec
import LawSpec.Core
import LawSpec.Core.RecordIdentity
import LawSpec.Core.Types
import qualified LawSpec.Core.Schema as Schema
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
import LawSpec.IndexTerm
import qualified LawSpec.Core.Totality as Totality
import qualified LawSpec.Core.RecordInstances as Instances

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
  it "links complete parametric product instances without transitive or nominal aliases" $ do
    let a=Id "a"; b=Id "b"
        list ty=Constructor "List" [TypeArgument ty]
        make parameters fields=fst (either error id (makeRecordDeclaration parameters fields origin))
        generic=make [a] [field "head" (TypeVariable a),field "tail" (list (TypeVariable a))]
        fixed=make [b] [field "head" (TypeVariable b),field "tail" (list (scalarType "Int8"))]
        instanceOf declaration ty=fst (either error id (instantiateRecordDeclaration declaration [ty] origin))
        integers=instanceOf generic (scalarType "Int8")
        booleans=instanceOf generic boolean
        mixed=instanceOf fixed boolean
        nominal=DataDeclaration (Id "Nominal") "Nominal" []
          [DataConstructor (Id "Nominal::Make") "Make"
            [Binder (Id "Nominal::head") "head" (scalarType "Int8"),Binder (Id "Nominal::tail") "tail" (list (scalarType "Int8"))] [] origin [] []] origin Nothing
        tag declaration=constructorId (head (dataConstructors declaration))
    registry<-either fail pure (makeRegistry [generic,fixed,integers,booleans,mixed,nominal])
    let links=Instances.fromRegistry registry
        projects from to=Instances.projects links (tag from) (tag to)
    projects generic integers `shouldBe` True
    projects generic booleans `shouldBe` True
    projects fixed integers `shouldBe` True
    projects fixed mixed `shouldBe` True
    projects generic mixed `shouldBe` False
    projects generic fixed `shouldBe` False
    projects integers generic `shouldBe` False
    projects generic nominal `shouldBe` False
    projects nominal integers `shouldBe` False
  it "does not link a product instance with an additional field restriction" $ do
    let a=Id "a"; int8=scalarType "Int8"
        generic=fst (either error id (makeRecordDeclaration [a] [field "value" (TypeVariable a)] origin))
        selected=Binder (Id "field::value") "value" int8
        zero=Expr int8 (Constant (SInteger "Int8" 0)) origin
        restricted=record [RecordField selected [comparison Greater (local selected) zero]]
        tag declaration=constructorId (head (dataConstructors declaration))
    registry<-either fail pure (makeRegistry [generic,restricted])
    Instances.projects (Instances.fromRegistry registry) (tag generic) (tag restricted) `shouldBe` False
  it "reads family indices through nested structural records and retains sibling guards" $ do
    let chainType = Constructor "PathChain" []
        chainTag tag = Id ("PathChain::" ++ tag)
        ctor tag fields = DataConstructor (chainTag tag) tag fields [] origin [] []
        chain = (DataDeclaration (Id "PathChain") "PathChain" []
          [ctor "Stop" [],ctor "Next" [Binder (Id "tail") "tail" chainType]] origin Nothing)
          {dataIndex=Just (FamilyIndex ["n"]
            [("PathChain::Stop",ConstructorIndex [IndexConstant 0] []),
             ("PathChain::Next",ConstructorIndex [IndexApply IndexAdd (IndexField 0 0) (IndexConstant 1)] [])])}
        inner = record [field "rest" chainType]
        innerType = Constructor (idText (dataId inner)) []
        outer = record [field "child" innerType,field "sibling" chainType]
        outerType = Constructor (idText (dataId outer)) []
        guard = IndexGuard IndexEqual (IndexPath [0,0,0] 0) (IndexPath [0,1] 0)
        wrapper = (DataDeclaration (Id "PathWrapper") "PathWrapper" []
          [DataConstructor (Id "PathWrapper::Wrap") "Wrap" [Binder (Id "payload") "payload" outerType] [] origin [] []]
          origin Nothing){dataIndex=Just (FamilyIndex ["n"]
            [("PathWrapper::Wrap",ConstructorIndex [IndexPath [0,0,0] 0] [guard])])}
        declarations = [chain,inner,outer,wrapper]
        registry = either error id (makeRegistry declarations)
        stop = DataValue chainType (chainTag "Stop") []
        next = DataValue chainType (chainTag "Next") [stop]
        product declaration values = DataValue (Constructor (idText (dataId declaration)) [])
          (constructorId (head (dataConstructors declaration))) values
        wrapped left right = DataValue (Constructor "PathWrapper" []) (Id "PathWrapper::Wrap")
          [product outer [product inner [left],right]]
        good = wrapped next next
        bad = wrapped next stop
    constructorIndexTexts (ConstructorIndex [IndexPath [0,0,0] 0] [guard])
      `shouldBe` ["p0/0/0.0","== p0/0/0.0 p0/1.0"]
    valueIndex registry good 0 `shouldBe` Just 1
    forM_ [32,64] $ \bits -> do
      validateValue registry bits (valueType good) good `shouldBe` Right good
      validateValue registry bits (valueType bad) bad `shouldSatisfy` isLeft
      case constructorProofContracts bits declarations of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right contracts -> do
          let mappings = [references | contract <- contracts,
                Totality.constructorOwner contract == Id "PathWrapper::Wrap",
                (_,references) <- Totality.constructorIndexGuards contract]
          mappings `shouldBe` [[
            (([0,0,0],0),("nOfPathChain",[(constructorId (head (dataConstructors outer)),0),
              (constructorId (head (dataConstructors inner)),0)])),
            (([0,1],0),("nOfPathChain",[(constructorId (head (dataConstructors outer)),1)]))]]
    let invalid path = wrapper{dataIndex=Just (FamilyIndex ["n"]
          [("PathWrapper::Wrap",ConstructorIndex [IndexPath path 0] [])])}
    forM_ [[],[-1],[0,-1],[0,2],[0,0,1],[0,1,0]] $ \path ->
      isLeft (makeRegistry [chain,inner,outer,invalid path]) `shouldBe` True
    -- The last invalid path attempts to traverse the nominal PathChain.
    indexTermText (IndexField 0 1) `shouldBe` "f0.1"
  describe "intrinsic record index relationships" $ do
    let sizedType=Constructor "Sized" []
        sized=(DataDeclaration (Id "Sized") "Sized" []
          [DataConstructor (Id "Sized::Zero") "Zero" [] [] origin [] [],
           DataConstructor (Id "Sized::One") "One" [] [] origin [] []] origin Nothing)
          {dataIndex=Just (FamilyIndex ["n"] [("Sized::Zero",ConstructorIndex [IndexConstant 0] []),
            ("Sized::One",ConstructorIndex [IndexConstant 1] [])])}
        fields=[field "left" sizedType,field "right" sizedType]
        shared=IndexGuard IndexEqual (IndexField 0 0) (IndexField 1 0)
        make values guards=fst (either error id (makeRecordDeclarationWithIndexGuards [] values guards origin))
        same=make fields [shared]
        ty declaration=Constructor (idText (dataId declaration)) []
        zero=DataValue sizedType (Id "Sized::Zero") []
        one=DataValue sizedType (Id "Sized::One") []
        pair declaration left right=DataValue (ty declaration) (constructorId (head (dataConstructors declaration))) [left,right]
    it "hashes shared indices separately and normalizes field order, direction and singleton paths" $ do
      let reversed=IndexGuard IndexEqual (IndexPath [1] 0) (IndexPath [0] 0)
          equivalent=[make values guards | values<-permutations fields,guards<-[[shared],[reversed],[shared,reversed]]]
      map dataId equivalent `shouldBe` replicate 6 (dataId same)
      dataId same `shouldNotBe` dataId (record fields)
      dataId same `shouldNotBe` dataId (make fields [IndexGuard IndexAtLeast (IndexField 0 0) (IndexField 1 0)])
      dataIndex same `shouldBe` Nothing
      case dataStructural same of
        Just metadata -> do
          structuralIndexGuards metadata `shouldBe` [shared]
          structuralDescriptor metadata `shouldSatisfy` (\text -> "lawspec.record.v2" `isInfixOf` text)
        Nothing -> expectationFailure "missing intrinsic index constraints"
    it "checks the relationship on the product itself and filters complete finite domains" $ do
      let registry=either error id (makeRegistry [sized,same])
          empty=make fields [IndexGuard IndexAtLeast (IndexField 0 0) (IndexConstant 2)]
          emptyRegistry=either error id (makeRegistry [sized,empty])
      forM_ [32,64] $ \bits -> do
        validateValue registry bits (ty same) (pair same one one) `shouldBe` Right (pair same one one)
        validateValue registry bits (ty same) (pair same zero zero) `shouldBe` Right (pair same zero zero)
        validateValue registry bits (ty same) (pair same one zero) `shouldSatisfy` isLeft
        Testing.hasValueContracts registry (ty same) `shouldBe` True
        Testing.finiteValuesWithRegistry registry bits 16 (ty same)
          `shouldBe` Right (Just [pair same zero zero,pair same one one])
        Testing.finiteValuesWithRegistry emptyRegistry bits 16 (ty empty) `shouldBe` Right (Just [])
        case constructorProofContracts bits [sized,same] of
          Right contracts -> length [guard | contract<-contracts,guard<-Totality.constructorIndexGuards contract] `shouldBe` 1
          Left diagnostics -> expectationFailure (show diagnostics)
      case Schema.dataSchemas [sized,same] of
        Right schemas -> [Schema.constructorIndex c | d<-schemas,Schema.typeName d==idText (dataId same),c<-Schema.constructors d]
          `shouldBe` [["== f0 f1"]]
        Left message -> expectationFailure message
    it "retains constraints when generic records are instantiated and rebuilt" $ do
      let a=Id "a"; alpha=Id "alpha"
          generic parameter=makeRecordDeclarationWithIndexGuards [parameter]
            [field "right" (Constructor "Family" [TypeArgument (TypeVariable parameter)]),
             field "left" (Constructor "Family" [TypeArgument (TypeVariable parameter)])] [shared] origin
          first=fst (either error id (generic a)); renamed=fst (either error id (generic alpha))
          (instantiated,_)=either error id (instantiateRecordDeclaration first [integerType] origin)
          direct=make [field "left" (Constructor "Family" [TypeArgument integerType]),
            field "right" (Constructor "Family" [TypeArgument integerType])] [shared]
          rebuilt=fst (either error id (rebuildRecordDeclaration instantiated []
            (map binderType (constructorFields (head (dataConstructors instantiated)))) [] origin))
      dataId first `shouldBe` dataId renamed
      dataId instantiated `shouldBe` dataId direct
      rebuilt `shouldBe` instantiated
      structuralIndexGuards (maybe (error "metadata") id (dataStructural instantiated)) `shouldBe` [shared]
    it "rejects damaged descriptors, missing guards and paths that are not family indices" $ do
      let metadata=maybe (error "metadata") id (dataStructural same)
          changed=same{dataStructural=Just (RecordWithIndexGuards (structuralDescriptor metadata) (structuralPredicates metadata)
            [IndexGuard IndexAtLeast (IndexField 0 0) (IndexField 1 0)])}
          erased=same{dataStructural=Just (StructuralRecord (structuralDescriptor metadata) (structuralPredicates metadata))}
      validateRecordDeclaration changed `shouldSatisfy` isLeft
      validateRecordDeclaration erased `shouldSatisfy` isLeft
      forM_ [IndexField 0 1,IndexPath [0,0] 0] $ \reference ->
        isLeft (makeRegistry [sized,make fields [IndexGuard IndexEqual reference (IndexConstant 0)]]) `shouldBe` True
      isLeft (makeRegistry [make [field "left" integerType,field "right" integerType] [shared]]) `shouldBe` True
      forM_ [IndexPath [] 0,IndexField (-1) 0,IndexField 9 0] $ \reference ->
        describeRecordWithIndexGuards [] fields [IndexGuard IndexEqual reference (IndexConstant 0)] `shouldSatisfy` isLeft
    it "retains natural arithmetic definedness even for reflexive index equalities" $ do
      forM_ [IndexApply IndexSubtract (IndexConstant 0) (IndexConstant 1),
             IndexApply IndexPower (IndexConstant 0) (IndexConstant (-1))] $ \undefined -> do
        let declaration=make [] [IndexGuard IndexEqual undefined undefined]
            resultType=ty declaration
            body=Expr resultType (Construct (constructorId (head (dataConstructors declaration))) []) origin
            function=Definition (Declaration (Id "impossible") "impossible" resultType origin) [] body
            program=Program 64 [declaration] [Unit (Id "indices") [definitionDeclaration function] [] [] [function] []]
            registry=either error id (makeRegistry [declaration])
        validateProgram program `shouldSatisfy` isLeft
        Testing.finiteValuesWithRegistry registry 64 16 resultType `shouldBe` Right (Just [])
        let guards=structuralIndexGuards (maybe (error "metadata") id (dataStructural declaration))
        normalizeRecordIndexGuards guards `shouldBe` guards
        length guards `shouldBe` 2
    it "publishes product-owned guards as typed type metadata" $ do
      case programView defaultGeneration [] [] [] [] (Program 64 [sized,same] []) of
        A.Object object -> case KM.lookup "dataTypes" object of
          Just (A.Array declarations) -> do
            let guards=[value | A.Object declaration<-foldr (:) [] declarations,
                  Just (A.Object structure)<-[KM.lookup "structure" declaration],
                  Just value<-[KM.lookup "indexGuards" structure]]
            guards `shouldBe` [A.toJSON (["== f0 f1"]::[String])]
          _ -> expectationFailure "missing published types"
        _ -> expectationFailure "missing published program"

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
        length (Testing.planDataDeclarations plan) `shouldBe` 5
        forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
  it "gives an instantiated generic record the identity of its concrete fields" $ do
    let a=Id "a"; b=Id "b"
        (generic,_)=either error id (makeRecordDeclaration [a,b]
          [field "value" (TypeVariable a),field "flag" (TypeVariable b)] origin)
        (closed,remaining)=either error id (instantiateRecordDeclaration generic [boolean,integerType] origin)
        concrete=record [field "flag" boolean,field "value" integerType]
    dataId closed `shouldBe` dataId concrete
    remaining `shouldBe` []
    dataParameters closed `shouldBe` []
    validateRecordDeclaration closed `shouldBe` Right ()
  it "returns canonical remaining arguments after partial structural instantiation" $ do
    let a=Id "a"; b=Id "b"; x=Id "caller.x"; z=Id "caller.z"
        listZ=Constructor "List" [TypeArgument (TypeVariable z)]
        (generic,_)=either error id (makeRecordDeclaration [a,b]
          [field "value" (TypeVariable a),field "flag" (TypeVariable b)] origin)
        (partial,remaining)=either error id (instantiateRecordDeclaration generic [listZ,TypeVariable x] origin)
        (direct,_)=either error id (makeRecordDeclaration [x,z]
          [field "value" (TypeVariable x),field "flag" listZ] origin)
    dataId partial `shouldBe` dataId direct
    remaining `shouldBe` [TypeVariable z,TypeVariable x]
  it "retains guarding restrictions in source order when specializing a record" $ do
    let parameter=Id "parameter"
        z=field "z" integerType; a=field "a" (TypeVariable parameter)
        nonzero=comparison NotEqual (local (recordFieldBinder z)) (value 0)
        divided=Expr integerType (Binary Quotient (Numeric integerType) (value 1) (local (recordFieldBinder z))) origin
        positive=comparison Greater divided (value 0)
        (generic,_)=either error id (makeRecordDeclaration [parameter]
          [z{recordFieldPredicates=[nonzero]},a{recordFieldPredicates=[positive]}] origin)
        (closed,_)=either error id (instantiateRecordDeclaration generic [boolean] origin)
    constructorProofContracts 64 [closed] `shouldSatisfy` isRight
  it "specializes the types of restriction evidence and field references together" $ do
    let parameter=Id "parameter"; x=field "x" (TypeVariable parameter)
        reflexive=Expr boolean (Binary Equal (Structural (TypeVariable parameter))
          (local (recordFieldBinder x)) (local (recordFieldBinder x))) origin
        (generic,_)=either error id (makeRecordDeclaration [parameter] [x{recordFieldPredicates=[reflexive]}] origin)
        (closed,_)=either error id (instantiateRecordDeclaration generic [boolean] origin)
        concreteX=field "x" boolean
        concrete=record [concreteX{recordFieldPredicates=[Expr boolean
          (Binary Equal (Structural boolean) (local (recordFieldBinder concreteX)) (local (recordFieldBinder concreteX))) origin]}]
    dataId closed `shouldBe` dataId concrete
    constructorProofContracts 64 [closed] `shouldSatisfy` isRight
  it "selects numeric equality evidence when a generic restriction becomes numeric" $ do
    let parameter=Id "parameter"; x=field "x" (TypeVariable parameter)
        reflexive=Expr boolean (Binary Equal (Structural (TypeVariable parameter))
          (local (recordFieldBinder x)) (local (recordFieldBinder x))) origin
        (generic,_)=either error id (makeRecordDeclaration [parameter] [x{recordFieldPredicates=[reflexive]}] origin)
    forM_ [integerType,scalarType "Float64"] $ \wanted -> do
      let (closed,_)=either error id (instantiateRecordDeclaration generic [wanted] origin)
      constructorProofContracts 64 [closed] `shouldSatisfy` isRight
      case constructorPredicates (head (dataConstructors closed)) of
        [Expr _ (Binary Equal (Numeric actual) _ _) _] -> actual `shouldBe` wanted
        other -> expectationFailure (show other)
