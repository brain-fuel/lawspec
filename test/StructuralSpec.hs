module StructuralSpec (spec) where

import Test.Hspec
import Data.Either (isLeft, isRight)
import Control.Monad (forM_)
import Data.List (sortOn, isSuffixOf, isInfixOf)
import qualified Data.Map.Strict as M
import LawSpec.Common
import LawSpec.Core
import LawSpec.Core.Types
import LawSpec.Core.Value
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Eval
import LawSpec.Core.Validate (validateExpressionWithRegistry)
import LawSpec.Frontend (compileCore)
import LawSpec.Scalar
import qualified LawSpec.Testing as T
import qualified LawSpec.Core.Schema as Schema
import qualified LawSpec.JavaData as Java
import qualified LawSpec.RustData as Rust
import qualified LawSpec.PythonData as Python
import qualified LawSpec.WebData as Web
import qualified LawSpec.GoData as Go
import qualified LawSpec.HaskellData as Haskell
import qualified LawSpec.KotlinData as Kotlin
import qualified LawSpec.Code.Doc as Doc

origin :: Origin
origin = GeneratedFrom (Id "structural-tests")
app :: String -> [Type] -> Type
app name = Constructor name . map TypeArgument
ctor :: String -> [Type] -> DataConstructor
ctor name types = DataConstructor (Id name) name
  [Binder (Id (name ++ show i)) ("field" ++ show i) ty | (i,ty) <- zip [0::Int ..] types] [] origin
decl :: String -> [Id] -> [DataConstructor] -> DataDeclaration
decl name parameters constructors = DataDeclaration (Id name) name parameters constructors origin
registry :: [DataDeclaration] -> IO TypeRegistry
registry definitions = either (\e -> expectationFailure e >> fail e) pure (makeRegistry definitions)

spec :: Spec
spec = do
  describe "structural type registry" $ do
    it "checks full container arity and refuses value arguments" $ do
      r <- registry []
      forM_ [app "Either" [scalarType "Bool",scalarType "Int8"],app "List" [scalarType "Text"]] $ \ty -> checkType r ty `shouldBe` Right ()
      forM_ [scalarType "List", app "Either" [scalarType "Bool"], Constructor "List" [IndexArgument (Natural 1)]] $ \ty -> checkType r ty `shouldSatisfy` isLeft
    it "substitutes recursive fields and distinguishes Either branches" $ do
      r <- registry []
      let ty = app "Either" [scalarType "Bool",app "List" [scalarType "Int8"]]
      fmap (map binderType) (constructorFieldsFor r ty (Id "Either::Right")) `shouldBe` Right [app "List" [scalarType "Int8"]]
      constructorFieldsFor r ty (Id "Maybe::Just") `shouldSatisfy` isLeft
      let list = app "List" [scalarType "Text"]
      fmap (map binderType) (constructorFieldsFor r list (Id "List::Cons")) `shouldBe` Right [scalarType "Text",list]
    it "registers mutual recursion before resolving fields" $
      fmap (const ()) (makeRegistry [decl "A" [] [ctor "A::A" [scalarType "B"]],decl "B" [] [ctor "B::B" [app "Maybe" [scalarType "A"]]]]) `shouldSatisfy` isRight
    it "rejects direct and indirect negative recursion" $ do
      fmap (const ()) (makeRegistry [decl "Bad" [] [ctor "Bad::Bad" [Arrow (scalarType "Bad") (scalarType "Bool")]]]) `shouldSatisfy` isLeft
      let a = Id "a"
      fmap (const ()) (makeRegistry [decl "Contra" [a] [ctor "Contra::C" [Arrow (TypeVariable a) (scalarType "Bool")]],decl "Bad" [] [ctor "Bad::Bad" [app "Contra" [scalarType "Bad"]]]]) `shouldSatisfy` isLeft
    it "rejects duplicate identities and unbound parameters" $ do
      let d = decl "Box" [] [ctor "Box::Box" []]
      fmap (const ()) (makeRegistry [d,d]) `shouldSatisfy` isLeft
      fmap (const ()) (makeRegistry [decl "Box" [] [ctor "Box::Box" [TypeVariable (Id "free")]]]) `shouldSatisfy` isLeft
    it "derives Eq only from stored fields, including phantom parameters" $ do
      let a = Id "a"
      r <- registry [decl "Phantom" [a] [ctor "Phantom::P" []],decl "Box" [a] [ctor "Box::B" [TypeVariable a]]]
      equalityRequirements r (app "Phantom" [Arrow (scalarType "Bool") (scalarType "Bool")]) `shouldBe` Right []
      equalityRequirements r (app "Box" [TypeVariable a]) `shouldBe` Right [a]
    it "rejects unbound and indexed runtime type references" $ do
      Schema.typeReference [] (TypeVariable (Id "free")) `shouldSatisfy` isLeft
      Schema.typeReference [] (Constructor "Vector" [IndexArgument (Natural 3)]) `shouldSatisfy` isLeft
    it "preserves native Java generics and resolves filename collisions" $ do
      let a = Id "a"; box = decl "Box" [a] [ctor "BoxValue" [TypeVariable a]]
      Java.javaDataType [box] (app "Box" [scalarType "Int8"]) `shouldBe` Right "lawspec.data.Box<java.lang.Byte>"
      Java.javaDataType [box] (scalarType "Box") `shouldSatisfy` isLeft
      Java.emitJavaData (Doc.Pretty 100) [decl "Foo" [] [],decl "foo" [] []] `shouldSatisfy` isRight
      let left = (decl "Pair" [] []) {dataId = Id "left::type::Pair"}
          right = (decl "Pair" [] []) {dataId = Id "right::type::Pair"}
      Java.javaDataType [left,right] (scalarType "left::type::Pair") `shouldBe` Right "lawspec.data.LeftPair"
      Java.javaDataType [left,right] (scalarType "right::type::Pair") `shouldBe` Right "lawspec.data.RightPair"
  describe "native Python declarations" $ do
    it "retains generic native types under containers" $ do
      let a = Id "a"; box = decl "Box" [a] [ctor "Wrap" [TypeVariable a]]
      Python.pythonDataType [box] (app "List" [app "Box" [scalarType "Int8"]]) `shouldBe`
        Right "_builtins.list[data.Box[_builtins.int]]"
      Python.pythonDataType [box] (scalarType "Box") `shouldSatisfy` isLeft
      Python.pythonDataType [box] (app "Maybe" [app "Box" [scalarType "Bool"]]) `shouldBe`
        Right "_schema.Maybe[data.Box[_builtins.bool]]"
    it "plans type and variant names together and rejects special-method fields" $ do
      let a = decl "Box" [] [ctor "Wrap" []]
          b = decl "BoxWrap" [] []
      Python.emitPythonData (Doc.Pretty 80) [a,b] `shouldSatisfy` isRight
      let bad = decl "Bad" [] [(ctor "BadCtor" [scalarType "Bool"]) {constructorFields = [Binder (Id "x") "__new__" (scalarType "Bool")]}]
      Python.emitPythonData (Doc.Pretty 80) [bad] `shouldSatisfy` isLeft
  describe "native web declarations" $ do
    it "retains generic payloads and nested native container types" $ do
      let box = decl "Box" [Id "a"] [ctor "Box" [TypeVariable (Id "a")]]
      Web.webDataType [box] (app "List" [app "Box" [scalarType "Int8"]]) `shouldBe`
        Right "Array<data.Box<number>>"
      Web.webDataType [box] (scalarType "Box") `shouldSatisfy` isLeft
      Web.webDataType [box] (app "Maybe" [app "Box" [scalarType "Bool"]]) `shouldBe`
        Right "data.Maybe<data.Box<boolean>>"
    it "resolves package-wide collisions and rejects illegal type identifiers" $ do
      Web.emitWebData True (Doc.Pretty 80)
        [decl "Foo" [] [], decl "foo" [] []] `shouldSatisfy` isRight
      Web.emitWebData True (Doc.Pretty 80)
        [decl "never" [] []] `shouldSatisfy` isLeft
  describe "native Go declarations" $ do
    it "preserves native parameterized fields and containers" $ do
      let box = decl "Box" [Id "a"] [ctor "Box" [TypeVariable (Id "a")]]
      Go.goDataType [box] (app "List" [app "Box" [scalarType "Int8"]]) `shouldBe`
        Right "[]Box[int8]"
      Go.goDataType [box] (scalarType "Box") `shouldSatisfy` isLeft
      Go.goDataType [box] (app "Nullable" [app "Optional" [scalarType "Int8"]]) `shouldBe`
        Right "LawSpecNullable[LawSpecOptional[int8]]"
    it "composes typed codecs from resolved structural types" $ do
      let box = decl "Box" [Id "a"] [ctor "Box" [TypeVariable (Id "a")]]
      Go.goCodec [box] (app "Maybe" [app "Box" [scalarType "Int8"]]) `shouldBe`
        Right "lsMaybeCodec(schema, bits, lawSpecBoxCodec(schema, bits, lsScalarCodec[int8](schema, bits, \"Int8\")))"
      Go.goCodec [box] (scalarType "Box") `shouldSatisfy` isLeft
    it "plans names package-wide and rejects capitalized field collisions" $ do
      Go.emitGoData (Doc.PrettyTabs 100) "fixture"
        [decl "Foo" [] [], decl "foo" [] []] `shouldSatisfy` isRight
      let bad = decl "Pair" [] [DataConstructor (Id "PairCtor") "Pair"
            [Binder (Id "first") "field" (scalarType "Bool"),
             Binder (Id "second") "Field" (scalarType "Bool")] [] origin]
      Go.emitGoData (Doc.PrettyTabs 100) "fixture" [bad] `shouldSatisfy` isLeft
      Go.emitGoSchema (Doc.PrettyTabs 100) "type" [] `shouldSatisfy` isLeft
      Go.validateGoBindings [decl "Pair" [] []] ["Pair"] `shouldSatisfy` isLeft
      Go.validateGoBindings [] ["LawSpecJust"] `shouldSatisfy` isLeft
      Go.validateGoBindings [decl "Pair" [] []] ["EchoPair"] `shouldBe` Right ()
  describe "native Kotlin declarations" $ do
    it "keeps recursive payloads and presence type arguments native" $ do
      let box = decl "Box" [Id "a"] [ctor "Box" [TypeVariable (Id "a")]]
      Kotlin.kotlinDataType [box] (app "List" [app "Box" [scalarType "Int8"]]) `shouldBe`
        Right "kotlin.collections.List<lawspec.data.Box<kotlin.Byte>>"
      Kotlin.kotlinDataType [] (app "Nullable" [app "Optional" [scalarType "Unit"]]) `shouldBe`
        Right "lawspec.runtime.LawSpecKotlin.Nullable<lawspec.runtime.LawSpecKotlin.Optional<kotlin.Unit>>"
      Kotlin.kotlinDataType [box] (scalarType "Box") `shouldSatisfy` isLeft
      Kotlin.kotlinDataType [] (scalarType "Unknown") `shouldSatisfy` isLeft
    it "selects checked native Kotlin codecs without erased type arguments" $ do
      Kotlin.kotlinCodec [] (app "Nullable" [app "Optional" [scalarType "Unit"]]) `shouldBe`
        Right "LawSpecKotlinCodecs.nullable(schema, bits, LawSpecKotlinCodecs.optional(schema, bits, LawSpecKotlinCodecs.unit(schema, bits)))"
      Kotlin.kotlinCodec [] (scalarType "CodeUnit16") `shouldBe`
        Right "schema.scalar(\"CodeUnit16\", bits, kotlin.Char::class.javaObjectType)"
      Kotlin.kotlinCodec [] (Arrow (scalarType "Bool") (scalarType "Bool")) `shouldSatisfy` isLeft
    it "qualifies native builtins and rejects invalid Kotlin names" $ do
      Kotlin.kotlinDataType [decl "String" [] []] (scalarType "Text") `shouldBe` Right "kotlin.String"
      Kotlin.emitKotlinData (Doc.Pretty 100) [decl "class" [] []] `shouldSatisfy` isLeft
      Kotlin.emitKotlinData (Doc.Pretty 100) [decl "Foo" [] [], decl "foo" [] []] `shouldSatisfy` isRight
  describe "native Haskell declarations" $ do
    it "distinguishes Text from linked lists and preserves generic payloads" $ do
      let box = decl "Box" [Id "a"] [ctor "Box" [TypeVariable (Id "a")]]
      Haskell.haskellDataType [box] (app "List" [app "Box" [scalarType "Int8"]]) `shouldBe`
        Right "[(Data.Box I.Int8)]"
      Haskell.haskellDataType [] (scalarType "Text") `shouldBe` Right "T.Text"
      Haskell.haskellDataType [] (app "List" [scalarType "Char"]) `shouldBe` Right "[P.Char]"
      Haskell.haskellDataType [box] (scalarType "Box") `shouldSatisfy` isLeft
    it "renders structural schema references from Core types" $ do
      Haskell.haskellTypeReference (app "List" [scalarType "Bool"]) `shouldBe`
        Right "Schema.Named \"List\" [Schema.Named \"Bool\" []]"
      Haskell.haskellTypeReference (TypeVariable (Id "unbound")) `shouldSatisfy` isLeft
    it "selects typed codecs for code units and nested absence" $ do
      Haskell.haskellCodec [] (scalarType "CodeUnit16") `shouldBe`
        Right "Codec.codeUnitCodec schema bits"
      Haskell.haskellCodec [] (app "Nullable" [scalarType "Unit"]) `shouldBe`
        Right "Codec.nullableCodec schema bits (Codec.unitCodec schema bits)"
      Haskell.haskellCodec [] (Arrow (scalarType "Bool") (scalarType "Bool")) `shouldSatisfy` isLeft
    it "plans names across units and rejects colliding record selectors" $ do
      Haskell.emitHaskellData (Doc.Pretty 80)
        [decl "Foo" [] [], decl "foo" [] []] `shouldSatisfy` isRight
      let bad = decl "Pair" [] [DataConstructor (Id "PairCtor") "Pair"
            [Binder (Id "first") "field" (scalarType "Bool"),
             Binder (Id "second") "Field" (scalarType "Bool")] [] origin]
      Haskell.emitHaskellData (Doc.Pretty 80) [bad] `shouldSatisfy` isLeft
  describe "native Rust declarations" $ do
    it "keeps nested custom types native and qualifies standard containers" $ do
      let a = Id "a"; box = decl "Box" [a] [ctor "Wrap" [TypeVariable a]]
      Rust.rustDataType [box] (app "List" [app "Box" [scalarType "Text"]]) `shouldBe`
        Right "std::vec::Vec<crate::lawspec_data::Box<std::string::String>>"
      Rust.rustDataType [box] (scalarType "Box") `shouldSatisfy` isLeft
      Rust.emitRustData (Doc.Pretty 100) [decl "type" [] [ctor "match" [scalarType "Bool"]]] `shouldSatisfy` isRight
      Rust.emitRustData (Doc.Pretty 100) [decl "Self" [] []] `shouldSatisfy` isLeft
    it "plans distinct names for identically named data in different units" $ do
      let left = (decl "Pair" [] []) {dataId = Id "left::type::Pair"}
          right = (decl "Pair" [] []) {dataId = Id "right::type::Pair"}
      Rust.rustDataType [left,right] (scalarType "left::type::Pair") `shouldBe` Right "crate::lawspec_data::LeftPair"
      Rust.rustDataType [left,right] (scalarType "right::type::Pair") `shouldBe` Right "crate::lawspec_data::RightPair"
  describe "structural values and evaluation" $ do
    it "validates nested lists without flattening them" $ do
      r <- registry []
      let inner = listValue (scalarType "Int8") [ScalarValue (SInteger "Int8" 127)]
          ty = app "List" [scalarType "Int8"]
          value = listValue ty [inner,listValue (scalarType "Int8") []]
      validateValue r 64 (app "List" [ty]) value `shouldBe` Right value
      listItems value `shouldBe` Right [inner,listValue (scalarType "Int8") []]
    it "rejects wrong tags, arity, ranges and primitive types" $ do
      r <- registry []
      let ty = app "Maybe" [scalarType "Int8"]
      forM_ [DataValue ty (Id "Either::Left") [],DataValue ty (Id "Maybe::Just") [],DataValue ty (Id "Maybe::Nothing") [ScalarValue (SInteger "Int8" 0)],DataValue ty (Id "Maybe::Just") [ScalarValue (SInteger "Int8" 128)],DataValue ty (Id "Maybe::Just") [ScalarValue (SBool True)]] $ \v -> validateValue r 64 ty v `shouldSatisfy` isLeft
    it "compares every field and constructor identity" $ do
      let ty = scalarType "Pair"
          value a b = DataValue ty (Id "Pair::P") (map (ScalarValue . SBool) [a,b])
      equalValues 64 (value True False) (value True True) `shouldBe` Right False
      equalValues 64 (value True False) (DataValue ty (Id "Other") [ScalarValue (SBool True),ScalarValue (SBool False)]) `shouldBe` Right False
    it "retains IEEE equality and symbol identity under constructors" $ do
      let boxed scalar = DataValue (app "Maybe" [scalarType (scalarName scalar)]) (Id "Maybe::Just") [ScalarValue scalar]
          nan = boxed (SFloat "Float64" "7ff8000000000000")
      equalValues 64 nan nan `shouldBe` Right False
      equalValues 64 (boxed (SFloat "Float64" "0000000000000000")) (boxed (SFloat "Float64" "8000000000000000")) `shouldBe` Right True
      equalValues 64 (boxed (SSymbol "a" "same")) (boxed (SSymbol "b" "same")) `shouldBe` Right False
    it "preserves nested algebraic and interoperability absence" $ do
      r <- registry []
      let inner = app "Maybe" [scalarType "Bool"]; outer = app "Maybe" [inner]
          nothing = DataValue outer (Id "Maybe::Nothing") []
          justNothing = DataValue outer (Id "Maybe::Just") [DataValue inner (Id "Maybe::Nothing") []]
      validateValue r 64 outer justNothing `shouldBe` Right justNothing
      equalValues 64 nothing justNothing `shouldBe` Right False
      let presence = app "Nullable" [app "Optional" [scalarType "Bool"]]
          value = PresenceValue presence (Just (PresenceValue (app "Optional" [scalarType "Bool"]) Nothing))
      validateValue r 64 presence value `shouldBe` Right value
      equalValues 64 (PresenceValue presence Nothing) value `shouldBe` Right False
    it "evaluates only the selected match branch" $ do
      r <- registry []
      let ty = app "Maybe" [scalarType "Bool"]
          value = Expr ty (Construct (Id "Maybe::Nothing") []) origin
          binder = Binder (Id "payload") "payload" (scalarType "Bool")
          result = Expr (scalarType "Bool") (Match value
            [MatchCase (Id "Maybe::Nothing") [] (Expr (scalarType "Bool") (Constant (SBool True)) origin),
             MatchCase (Id "Maybe::Just") [binder] (Expr (scalarType "Bool") (ExternalCall (Id "forbidden") []) origin)]) origin
      evaluateValue r 64 (\_ _ -> Left "unselected effect ran") [] result `shouldBe` Right (ScalarValue (SBool True))
    it "rejects incomplete match coverage before execution" $ do
      r <- registry []
      let ty = app "Maybe" [scalarType "Bool"]
          value = Expr ty (Construct (Id "Maybe::Nothing") []) origin
          result = Expr (scalarType "Bool") (Match value []) origin
      validateExpressionWithRegistry r 64 M.empty M.empty result `shouldSatisfy` isLeft
  describe "scoped List element predicates" $ do
    it "accepts empty lists and checks every populated element" $ do
      r <- registry []
      let bool = scalarType "Bool"
          ty = app "List" [bool]
          binder = Binder (Id "element") "element" bool
          values = Expr ty (Local (Id "values")) origin
          predicate = Expr bool (Local (binderId binder)) origin
          expression = Expr bool (AllElements values binder predicate) origin
          run xs = evaluateValuePure r 64 [(Id "values",listValue bool (map (ScalarValue . SBool) xs))] expression
      validateExpressionWithRegistry r 64 M.empty (M.singleton (Id "values") ty) expression `shouldBe` Right ()
      freeBinders expression `shouldBe` [Id "values"]
      run [] `shouldBe` Right (ScalarValue (SBool True))
      run [True,True] `shouldBe` Right (ScalarValue (SBool True))
      run [True,False] `shouldBe` Right (ScalarValue (SBool False))
    it "short-circuits and adds the failing element index to errors" $ do
      r <- registry []
      let bool = scalarType "Bool"
          ty = app "List" [bool]
          binder = Binder (Id "element") "element" bool
          values = Expr ty (Local (Id "values")) origin
          predicate = Expr bool (ShortCircuit Or
            (Expr bool (Local (binderId binder)) origin)
            (Expr bool (ExternalCall (Id "failure") []) origin)) origin
          expression = Expr bool (AllElements values binder predicate) origin
          run xs = evaluateValue r 64 (\_ _ -> Left "predicate failed")
            [(Id "values",listValue bool (map (ScalarValue . SBool) xs))] expression
          stop = expression {expressionNode = AllElements values binder
            (Expr bool (ShortCircuit And (Expr bool (Local (binderId binder)) origin)
              (Expr bool (ExternalCall (Id "failure") []) origin)) origin)}
      run [] `shouldBe` Right (ScalarValue (SBool True))
      run [True,False] `shouldSatisfy` either
        (\message -> "List element 1:" `isInfixOf` message && "predicate failed" `isSuffixOf` message) (const False)
      evaluateValue r 64 (\_ _ -> Left "must not run")
        [(Id "values",listValue bool [ScalarValue (SBool False),ScalarValue (SBool True)])] stop
        `shouldBe` Right (ScalarValue (SBool False))
    it "rejects non-lists, wrong binder types, non-Bool predicates and captured identities" $ do
      r <- registry []
      let bool = scalarType "Bool"
          ty = app "List" [bool]
          binder = Binder (Id "element") "element" bool
          values = Expr ty (Construct (Id "List::Nil") []) origin
          yes = Expr bool (Constant (SBool True)) origin
          check scope value b predicate = validateExpressionWithRegistry r 64 M.empty scope
            (Expr bool (AllElements value b predicate) origin)
      check M.empty yes binder yes `shouldSatisfy` isLeft
      check M.empty values (binder {binderType = scalarType "Int8"}) yes `shouldSatisfy` isLeft
      check M.empty values binder values `shouldSatisfy` isLeft
      check (M.singleton (binderId binder) bool) values binder yes `shouldSatisfy` isLeft
      check M.empty values binder (Expr bool (Local (Id "escaped")) origin) `shouldSatisfy` isLeft
  describe "structural planning" $ do
    it "filters finite constructor domains and rejects invalid input tuples" $ do
      let bool = scalarType "Bool"
          keep = (ctor "Keep" [bool]){constructorPredicates=
            [Expr bool (Local (Id "Keep0")) origin]}
          ty = app "Truth" []
          good = DataValue ty (Id "Keep") [ScalarValue (SBool True)]
          bad = DataValue ty (Id "Keep") [ScalarValue (SBool False)]
          input = Quantifier (Binder (Id "input") "input" ty) [] []
      r <- registry [decl "Truth" [] [keep]]
      forM_ [32,64] $ \bits -> do
        T.finiteValuesWithRegistry r bits 10 ty `shouldBe` Right (Just [good])
        T.boundariesWithRegistry r bits ty `shouldBe` Right [good]
        T.validTuple r bits [input] [good] `shouldBe` Right True
        T.validTuple r bits [input] [bad] `shouldBe` Right False
        T.validTuple r bits [input] [ScalarValue (SBool True)] `shouldSatisfy` isLeft
    it "retains distinct absence states around an empty refined data domain" $ do
      let bool = scalarType "Bool"
          never = (ctor "Never" [scalarType "Unit"]){constructorPredicates=
            [Expr bool (Constant (SBool False)) origin]}
          empty = app "Empty" []
          product = app "Product" []
          list = app "List" [empty]
          optional = app "Optional" [empty]
          maybe = app "Maybe" [empty]
      r <- registry [decl "Empty" [] [never],
        decl "Product" [] [ctor "Product" [empty,scalarType "BigInt"]]]
      T.finiteValuesWithRegistry r 64 10 empty `shouldBe` Right (Just [])
      T.finiteValuesWithRegistry r 64 10 product `shouldBe` Right (Just [])
      T.finiteValuesWithRegistry r 64 10 list `shouldBe`
        Right (Just [listValue empty []])
      T.finiteValuesWithRegistry r 64 10 optional `shouldBe`
        Right (Just [PresenceValue optional Nothing])
      T.finiteValuesWithRegistry r 64 10 maybe `shouldBe`
        Right (Just [DataValue maybe (Id "Maybe::Nothing") []])
      T.boundariesWithRegistry r 64 empty `shouldBe` Right []
      T.boundariesWithRegistry r 64 list `shouldBe` Right [listValue empty []]
    it "checks dependent finite fields without discarding sum alternatives" $ do
      let bool = scalarType "Bool"
          equal = Expr bool (Binary Equal (Structural bool)
            (Expr bool (Local (Id "Pair0")) origin)
            (Expr bool (Local (Id "Pair1")) origin)) origin
          pair = (ctor "Pair" [bool,bool]){constructorPredicates=[equal]}
          ty = app "Choice" []
          expected = [DataValue ty (Id "Pair") [ScalarValue (SBool x),ScalarValue (SBool x)]
            | x <- [False,True]] ++ [DataValue ty (Id "Other") []]
      r <- registry [decl "Choice" [] [pair,ctor "Other" []]]
      T.finiteValuesWithRegistry r 64 10 ty `shouldBe` Right (Just expected)
      T.finiteValuesWithRegistry r 64 1 ty `shouldBe` Right Nothing
    it "audits malformed predicates before domain enumeration" $ do
      let bad = (ctor "Bad" [scalarType "Bool"]){constructorPredicates=
            [Expr (scalarType "Bool") (Local (Id "unbound")) origin]}
      r <- registry [decl "Bad" [] [bad]]
      T.finiteValuesWithRegistry r 64 10 (app "Bad" []) `shouldSatisfy` isLeft
      T.boundariesWithRegistry r 64 (app "Bad" []) `shouldSatisfy` isLeft
    it "keeps predicate rejection distinct from evaluator faults" $ do
      let ty = app "Box" []
          constructor = (ctor "Box" []){constructorPredicates=
            [Expr (scalarType "Bool") (Constant (SBool True)) origin]}
          candidate = DataValue ty (Id "Box") []
      r <- registry [decl "Box" [] [constructor]]
      checkValueWith (\_ _ -> Right (ScalarValue (SBool False))) r 64 ty candidate
        `shouldBe` Right (RefinementRejected "Box: field refinement failed")
      checkValueWith (\_ _ -> Left "broken evaluator") r 64 ty candidate `shouldSatisfy` isLeft
      checkValueWith (\_ _ -> Right (ScalarValue (SInteger "Int8" 1))) r 64 ty candidate
        `shouldSatisfy` isLeft
    it "follows stored parameters and growing recursion when finding contracts" $ do
      let a = Id "a"
          bool = scalarType "Bool"
          positive = (ctor "Positive" [bool]){constructorPredicates=
            [Expr bool (Local (Id "Positive0")) origin]}
          box = decl "Box" [a] [ctor "Box" [TypeVariable a]]
          phantom = decl "Phantom" [a] [ctor "Phantom" []]
          grow = decl "Grow" [a] [ctor "Stop" [TypeVariable a],
            ctor "More" [app "Grow" [app "Positive" []]]]
      r <- registry [decl "Positive" [] [positive],box,phantom,grow]
      T.hasValueContracts r (app "Box" [app "Box" [app "Positive" []]]) `shouldBe` True
      T.hasValueContracts r (app "Phantom" [app "Positive" []]) `shouldBe` False
      T.hasValueContracts r (app "Grow" [bool]) `shouldBe` True
      T.hasValueContracts r (app "List" [bool]) `shouldBe` False
      T.boundariesWithRegistry r 64 (scalarType "Int8") `shouldBe`
        Right (T.boundaries 64 (scalarType "Int8"))
      case T.boundariesWithRegistry r 64 (app "List" [app "Positive" []]) of
        Left message -> expectationFailure message
        Right values -> do
          values `shouldSatisfy` ((> 1) . length)
          mapM_ (\value -> validateValueWithContracts r 64
            (app "List" [app "Positive" []]) value `shouldBe` Right value) values
    it "finds dependent gaps and sparse Symbol fixtures as boundary witnesses" $ do
      source <- readFile "test/fixtures/constructor_boundaries.lawspec"
      forM_ [32,64] $ \bits -> case compileCore bits defaultGeneration [Source "boundaries" source] of
        Left diagnostics -> expectationFailure (show diagnostics)
        Right program -> do
          r <- registry (programDataDeclarations program)
          case T.planTesting program of
            Left diagnostics -> expectationFailure (show diagnostics)
            Right plan -> forM_ (concatMap T.plannedProperties (T.plannedUnits plan)) $ \property -> do
              T.finiteCases property `shouldBe` Nothing
              T.boundaryCases property `shouldSatisfy` (not . null)
              mapM_ (\values -> T.validTuple r bits
                (propertyInputs (T.plannedProperty property)) values `shouldBe` Right True)
                (T.boundaryCases property)
    it "reports exhausted witness search without claiming an infinite domain empty" $ do
      let ty = app "Impossible" []
          never = (ctor "Impossible" [scalarType "BigInt"]){constructorPredicates=
            [Expr (scalarType "Bool") (Constant (SBool False)) origin]}
      r <- registry [decl "Impossible" [] [never]]
      T.finiteValuesWithRegistry r 64 256 ty `shouldBe` Right Nothing
      T.boundariesWithRegistry r 64 ty `shouldSatisfy`
        either (isInfixOf "exhausted without a witness") (const False)
    it "keeps valid sum branches when a recursive constrained branch has no witness" $ do
      let ty = app "Recursive" []
          never = (ctor "Never" [ty,scalarType "BigInt"]){constructorPredicates=
            [Expr (scalarType "Bool") (Constant (SBool False)) origin]}
          leaf = ctor "Leaf" [scalarType "BigInt"]
      r <- registry [decl "Recursive" [] [never,leaf]]
      case T.boundariesWithRegistry r 64 ty of
        Left message -> expectationFailure message
        Right values -> do
          values `shouldSatisfy` (not . null)
          forM_ values $ \value -> do
            validateValueWithContracts r 64 ty value `shouldBe` Right value
            case value of
              DataValue _ tag _ -> tag `shouldBe` Id "Leaf"
              _ -> expectationFailure "expected a constructor witness"
    it "finds constrained witnesses through long acyclic declaration chains" $ do
      let bool = scalarType "Bool"
          leaf = (ctor "Leaf" [bool]){constructorPredicates=
            [Expr bool (Local (Id "Leaf0")) origin]}
          name index = "Chain" ++ show (index :: Int)
          ty index = app (name index) []
          declarations = decl (name 40) [] [leaf] :
            [decl (name index) [] [ctor (name index) [ty (index+1),scalarType "BigInt"]]
              | index <- [0..39]]
      r <- registry declarations
      case T.boundariesWithRegistry r 64 (ty 0) of
        Left message -> expectationFailure message
        Right values -> do
          values `shouldSatisfy` (not . null)
          mapM_ (\value -> validateValueWithContracts r 64 (ty 0) value
            `shouldBe` Right value) values
    it "enumerates finite Maybe and Either domains without collapsed branches" $ do
      fmap length (T.finiteValues 64 100 (app "Maybe" [app "Maybe" [scalarType "Bool"]])) `shouldBe` Just 4
      fmap length (T.finiteValues 64 100 (app "Either" [scalarType "Bool",scalarType "Unit"])) `shouldBe` Just 3
    it "does not mistake bounded list samples for a finite domain" $
      T.finiteValues 64 100 (app "List" [scalarType "Unit"]) `shouldBe` Nothing
    it "produces valid recursive boundaries at both machine widths" $ do
      let a = Id "a"; tree = decl "Tree" [a] [ctor "Leaf" [TypeVariable a],ctor "Branch" [app "List" [app "Tree" [TypeVariable a]]]]
          ty = app "Tree" [scalarType "IntSize"]
      r <- registry [tree]
      forM_ [32,64] $ \bits -> case T.boundariesWithRegistry r bits ty of
        Left e -> expectationFailure e
        Right values -> do
          values `shouldSatisfy` (not . null)
          mapM_ (\v -> validateValue r bits ty v `shouldBe` Right v) values
    it "executes bundled structural example expectations with the reference evaluator" $
      forM_ ["collections","matching","data_types","finite_data"] $ \name -> do
        content <- readFile ("examples/specs/" ++ name ++ ".lawspec")
        forM_ [32,64] $ \bits -> case compileCore bits defaultGeneration [Source name content] of
          Left ds -> expectationFailure (show ds)
          Right program -> do
            r <- registry (programDataDeclarations program)
            T.planTesting program `shouldSatisfy` isRight
            case prepareDefinitions program of
              Left diagnostics -> expectationFailure (show diagnostics)
              Right invoke -> do
                let identities = [declarationId (definitionDeclaration d) |
                      unit <- programUnits program, d <- unitDefinitions unit]
                    call name values = if name `elem` identities then invoke name values
                      else exampleAdapter name values
                forM_ (concatMap unitProperties (programUnits program)) $ \property ->
                  forM_ (propertyExamples property) $ \example -> do
                    let env = mapM (\(name,expr) -> (,) name <$> evaluateValuePure r bits [] expr) (exampleBindings example)
                    case env of
                      Left e -> expectationFailure e
                      Right bindings -> forM_ (exampleExpectations example) $ \p ->
                        evaluateValueProposition r bits call bindings p `shouldBe` Right True

exampleAdapter :: Id -> [Value] -> Either String Value
exampleAdapter name [value]
  | "::reverse" `isSuffixOf` idText name = listResult reverse value
  | "::sort" `isSuffixOf` idText name = listResult (sortOn integer) value
  | any (`isSuffixOf` idText name) ["::echoMaybe", "::echoEither", "::echoNested"] = Right value
  where integer (ScalarValue (SInteger _ n)) = n
        integer _ = error "sort fixture requires integers"
exampleAdapter name _ = Left ("unknown example adapter: " ++ idText name)

listResult :: ([Value] -> [Value]) -> Value -> Either String Value
listResult operation value@(DataValue (Constructor "List" [TypeArgument element]) _ _) =
  listValue element . operation <$> listItems value
listResult _ _ = Left "expected list fixture"
