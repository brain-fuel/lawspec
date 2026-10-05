module NativeBindingSpec (spec) where

import Test.Hspec
import Data.Either (isLeft)
import Data.List (isInfixOf)
import qualified LawSpec.HaskellData as Haskell
import qualified LawSpec.Code.Doc as Doc
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Frontend (compileCore)
import LawSpec.NativeBinding

source :: String
source = unlines
  [ "unit domain"
  , "type Currency is USD | EUR end"
  , "type Money is Money amount :: Decimal currency :: Currency end"
  , "type Box (a :: Type) is Box value :: a end"
  ]

ref :: String -> NativeRef
ref name = NativeRef ["app",name]

money :: TypeBinding
money = TypeBinding (C.Id "domain::type::Money") (ref "Price")
  [ConstructorBinding "Money" (ref "Price") RecordConstructor
    [FieldBinding "currency" "unit", FieldBinding "amount" "major"]] Nothing Nothing

resolve :: Bindings -> Either String ResolvedBindings
resolve bindings = case compileCore 64 defaultGeneration [Source "native" source] of
  Left diagnostics -> Left (show diagnostics)
  Right program -> resolveBindings (C.programDataDeclarations program) bindings

spec :: Spec
spec = describe "native binding resolution" $ do
  it "renders Haskell native codecs with named fields in both directions" $ do
    case compileCore 64 defaultGeneration [Source "native" source] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let declarations = C.programDataDeclarations program
        -- Constructor IDs come from Core, never reconstructed from native names.
        let moneyDeclaration = head [d | d <- declarations, C.dataName d == "Money"]
            constructorId = C.constructorId (head (C.dataConstructors moneyDeclaration))
            mapped fields = Haskell.emitHaskellCodecsWithRepresentations
              (Doc.Pretty 100) declarations "LawSpecNativeCodecs" ["Domain"]
              [(C.dataId moneyDeclaration, "Domain.Price")]
              [(constructorId, ("Domain.Price", fields))]
        case mapped ["Domain.major", "Domain.unit"] of
          Left message -> expectationFailure message
          Right output -> do
            output `shouldSatisfy` isInfixOf "Codec.Codec Domain.Price"
            output `shouldSatisfy` isInfixOf "Domain.major = value0"
            output `shouldSatisfy` isInfixOf "Domain.unit = field1"
            output `shouldSatisfy` isInfixOf "import qualified Domain"
        mapped ["Domain.major"] `shouldSatisfy` isLeft
  it "resolves codec hooks in place of constructor mappings" $ do
    let hook = CodecBinding (ref "decodePrice") (ref "encodePrice")
        binding = money {boundConstructors = [], boundCodec = Just hook}
    case resolve (Bindings [binding] []) of
      Left message -> expectationFailure message
      Right bound -> do
        map resolvedCodec (resolvedTypes bound) `shouldBe` [Just hook]
        map resolvedConstructors (resolvedTypes bound) `shouldBe` [[]]
    resolve (Bindings [money {boundCodec = Just hook}] []) `shouldSatisfy` isLeft
    resolve (Bindings [binding {boundCodec = Just (hook {codecToNative = NativeRef []})}] []) `shouldSatisfy` isLeft
  it "preserves the no-binding default" $
    resolve emptyBindings `shouldBe` Right (ResolvedBindings [] [])
  it "resolves fields in declaration order, regardless of config order" $
    case resolve (Bindings [money] []) of
      Left message -> expectationFailure message
      Right bound -> do
        let mapped = head (resolvedTypes bound)
            fields = resolvedFields (head (resolvedConstructors mapped))
        C.dataId (resolvedDeclaration mapped) `shouldBe` C.Id "domain::type::Money"
        map (C.binderName . fst) fields `shouldBe` ["amount","currency"]
        map snd fields `shouldBe` ["major","unit"]
  it "resolves generic generator factories with argument arities" $
    case resolve (Bindings []
      [GeneratorBinding (C.Id "domain::type::Box") (ref "boxes") False,
       GeneratorBinding (C.Id "Either") (ref "choices") False,
       GeneratorBinding (C.Id "Decimal") (ref "amounts") False]) of
      Left message -> expectationFailure message
      Right bound -> map generatorParameterCount (resolvedGenerators bound) `shouldBe` [1,2,0]
  it "rejects unknown type identities, including ambiguous short names" $ do
    resolve (Bindings [money {boundType = C.Id "Money"}] []) `shouldSatisfy` isLeft
    resolve (Bindings [] [GeneratorBinding (C.Id "Missing") (ref "values") False]) `shouldSatisfy` isLeft
  it "retains generator scaffold requests and rejects shared scaffold identities" $ do
    let generator = GeneratorBinding (C.Id "domain::type::Box") (ref "boxes") True
    case resolve (Bindings [] [generator]) of
      Left message -> expectationFailure message
      Right bound -> do
        map resolvedGeneratorStub (resolvedGenerators bound) `shouldBe` [True]
        map generatorParameterCount (resolvedGenerators bound) `shouldBe` [1]
    resolve (Bindings [] [generator, generator {generatorType = C.Id "List", generatorStub = False}])
      `shouldSatisfy` isLeft
  it "rejects duplicate bindings and ambiguous native type identities" $ do
    resolve (Bindings [money,money] []) `shouldSatisfy` isLeft
    resolve (Bindings [money,money {boundType=C.Id "domain::type::Currency"}] []) `shouldSatisfy` isLeft
    let gen = GeneratorBinding (C.Id "Decimal") (ref "amounts") False
    resolve (Bindings [] [gen,gen]) `shouldSatisfy` isLeft
  it "requires complete constructor and field mappings" $ do
    resolve (Bindings [money {boundConstructors=[]}] []) `shouldSatisfy` isLeft
    let constructor = head (boundConstructors money)
        invalid fields = resolve (Bindings [money {boundConstructors=[constructor {boundFields=fields}]}] [])
    invalid [FieldBinding "amount" "major"] `shouldSatisfy` isLeft
    invalid [FieldBinding "amount" "major",FieldBinding "unknown" "unit"] `shouldSatisfy` isLeft
    invalid [FieldBinding "amount" "major",FieldBinding "currency" "major"] `shouldSatisfy` isLeft
    invalid [FieldBinding "amount" "major",FieldBinding "amount" "unit"] `shouldSatisfy` isLeft
  it "rejects record encodings of sums and payloads on unit constructors" $ do
    let currency = TypeBinding (C.Id "domain::type::Currency") (ref "Code")
          [ConstructorBinding "USD" (ref "Dollars") RecordConstructor [],
           ConstructorBinding "EUR" (ref "Euros") UnitConstructor []] Nothing Nothing
    resolve (Bindings [currency] []) `shouldSatisfy` isLeft
    let constructor = head (boundConstructors money)
    resolve (Bindings [money {boundConstructors=[constructor {constructorStyle=UnitConstructor}]}] []) `shouldSatisfy` isLeft
  it "rejects target code fragments and empty reference parts" $
    mapM_ (\name -> resolve (Bindings [money {nativeType=NativeRef [name]}] []) `shouldSatisfy` isLeft)
      ["", "app.Price", "Price<T>", "Price; panic!()", "../Price", "_"]
  it "finds machine-sized fields through recursive declarations and type arguments" $ do
    let recursive = unlines
          [ "unit machine"
          , "type Chain (a :: Type) is Stop | More value :: a tail :: Maybe (Chain a) end"
          , "type Native is Done | Next tail :: Maybe Native width :: UIntPtr end"
          ]
        chain ty = C.Constructor "machine::type::Chain" [C.TypeArgument (C.scalarType ty)]
    case compileCore 64 defaultGeneration [Source "machine" recursive] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        let uses = usesMachineRepresentation (C.programDataDeclarations program)
        uses (chain "Int8") `shouldBe` False
        uses (chain "IntSize") `shouldBe` True
        uses (C.Constructor "machine::type::Native" []) `shouldBe` True
