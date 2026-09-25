module CoreSpec (spec) where
import Test.Hspec
import LawSpec.Common
import LawSpec.Scalar
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Eval as E
import qualified LawSpec.Core.Validate as V
import LawSpec.Frontend
import LawSpec.Testing (planTesting)
import qualified LawSpec.Model as S
import Data.Either (isLeft)
import qualified Data.Map.Strict as M

spec :: Spec
spec = describe "typed core boundary" $ do
  it "elaborates all bundled programs at both machine widths and independently validates them" $ do
    mapM_ (\name -> do
      source <- readFile ("examples/specs/" ++ name ++ ".lawspec")
      mapM_ (\bits -> case compileCore bits defaultGeneration [Source name source] of
        Left ds -> expectationFailure (name ++ "/" ++ show bits ++ ": " ++ show ds)
        Right core -> V.validateProgram core `shouldBe` Right ()) [32,64])
      ["algebra","currying","atoi_codec","boolean_flags","canonical_url","equivalent","mixed_inputs","parse_port","refinements","scalar_adapters","scalar_catalog","scalars","slug"]
  it "checks general type and value argument kinds without a unary application encoding" $ do
    let registry = [("Vector",C.KindArrow C.ValueKind (C.KindArrow C.TypeKind C.TypeKind)),("Int32",C.TypeKind)]
    V.kindOf registry (C.Constructor "Vector" [C.IndexArgument (C.Natural 3),C.TypeArgument (C.scalarType "Int32")]) `shouldBe` Right C.TypeKind
    V.kindOf registry (C.Constructor "Vector" [C.TypeArgument (C.scalarType "Int32"),C.IndexArgument (C.Natural 3)]) `shouldSatisfy` isLeft
  it "rejects corrupt arithmetic evidence independently of inference" $ do
    let origin = C.GeneratedFrom (C.Id "test")
        lit = C.Expr (C.scalarType "Int8") (C.Constant (SInteger "Int8" 127)) origin
        bad = C.Expr (C.scalarType "Int8") (C.Binary C.Add (C.Numeric (C.scalarType "Int8")) lit lit) origin
    V.validateExpression 64 M.empty M.empty bad `shouldSatisfy` isLeft
  it "short circuits partial exact arithmetic" $ do
    let s = Source "core" "unit core\nlaw `short circuit` is definition is `for all` (x :: Bool) . false && 1 / 0 == 0 = false end end"
    case compileCore 64 defaultGeneration [s] of
      Left ds -> expectationFailure (show ds)
      Right c -> mapM_ (\p -> E.evaluateProposition 64 (\_ _ -> Left "unexpected adapter") [] (C.propertyBody p) `shouldBe` Right True) (concatMap C.unitProperties (C.programUnits c))
  it "executes scalar example expectations without reconstructing surface expressions" $ do
    source <- readFile "examples/specs/scalars.lawspec"
    case compileCore 64 defaultGeneration [Source "scalars" source] of
      Left ds -> expectationFailure (show ds)
      Right c -> mapM_ (\p -> mapM_ (\example -> do
        case mapM (\(i,e) -> (,) i <$> E.evaluatePure 64 [] e) (C.exampleBindings example) of
          Left err -> expectationFailure err
          Right bindings -> mapM_ (\expect -> E.evaluateProposition 64 (\_ _ -> Left "unexpected adapter") bindings expect `shouldBe` Right True) (C.exampleExpectations example)) (C.propertyExamples p)) (concatMap C.unitProperties (C.programUnits c))

  it "keeps checked conversions explicit and rejects overflow before adapter invocation" $ do
    let source = S.Apply (S.Var "narrow") (S.Binary "+" (S.Var "x") (S.Number 1))
        env = [("narrow",S.Arrow (S.Named "Int8") (S.Named "Int8")),("x",S.Named "Int8")]
    case elaborateExpression 64 (C.Id "bridge") C.Id env source of
      Right e@C.Expr{C.expressionNode=C.ExternalCall _ [arg]} -> do
        case C.expressionNode arg of
          C.Convert C.CheckedArgument target _ -> target `shouldBe` C.scalarType "Int8"
          _ -> expectationFailure "missing checked argument conversion"
        E.evaluate 64 (\_ _ -> Right (SInteger "Int8" 0)) [(C.Id "x",SInteger "Int8" 127)] e `shouldSatisfy` isLeft
      other -> expectationFailure (show other)
  it "preserves property and binder identities when unrelated laws are inserted" $ do
    let header = "unit stable\nf :: Int8 -> Int8\n"
        law n = "law `" ++ n ++ "` is definition is `for all` (x :: Int8) . f x = x end end\n"
        target c = [(C.propertyId p,map (C.binderId . C.quantifiedBinder) (C.propertyInputs p)) | u <- C.programUnits c,p <- C.unitProperties u,C.propertyName p == "target"]
    fmap target (compileCore 64 defaultGeneration [Source "stable" (header ++ law "target")])
      `shouldBe` fmap target (compileCore 64 defaultGeneration [Source "stable" (header ++ law "unrelated" ++ law "target")])
  it "separates language checking from uninhabited-domain execution planning" $ do
    let source = Source "empty" "unit empty\nlaw `empty` is definition is `for all` (x :: Bool where false) . x = x end end"
    case compileCore 64 defaultGeneration [source] of
      Left ds -> expectationFailure (show ds)
      Right core -> planTesting core `shouldSatisfy` isLeft

  it "preserves explicitly constructed float precision and exact literal comparison" $ do
    let expressions = ["float32Bits(\"3f800000\") = float64Bits(\"3ff0000000000001\")", "1 = 0.1"]
    mapM_ (\body -> case compileCore 64 defaultGeneration [Source "precision" ("unit precision\nlaw `different` is definition is `for all` (marker :: Unit) . " ++ body ++ " end end")] of
      Left ds -> expectationFailure (show ds)
      Right c -> mapM_ (\p -> E.evaluateProposition 64 (\_ _ -> Left "unexpected adapter") [] (C.propertyBody p) `shouldBe` Right False) (concatMap C.unitProperties (C.programUnits c))) expressions

  it "retains parsed expression and declaration ranges through elaboration" $ do
    let source = Source "ranges.lawspec" "unit ranges\nf :: Int8 -> Integer\nlaw `range` is definition is `for all` (x :: Int8) . f x = x + 1 end end"
    case compileCore 64 defaultGeneration [source] of
      Left ds -> expectationFailure (show ds)
      Right c -> do
        let u = head (C.programUnits c)
        case C.declarationOrigin (head (C.unitDeclarations u)) of
          C.SourceSpan (Span begin end) -> do
            begin `shouldBe` Location "ranges.lawspec" 2 1
            line end `shouldSatisfy` (>= 2)
          other -> expectationFailure (show other)
        case C.propertyBody (head (C.unitProperties u)) of
          C.Equation _ call addition -> do
            mapM_ (\e -> case C.expressionOrigin e of
              C.SourceSpan (Span begin end) -> do
                file begin `shouldBe` "ranges.lawspec"
                line begin `shouldBe` 3
                (line end,column end) `shouldSatisfy` (> (line begin,column begin))
              other -> expectationFailure (show other)) [call,addition]
            case C.expressionNode addition of
              C.Binary C.Add _ _ one -> C.expressionOrigin one `shouldSatisfy` (\o -> case o of C.SourceSpan _ -> True; _ -> False)
              other -> expectationFailure (show other)
          other -> expectationFailure (show other)

  it "requires checked to observe an evaluated result" $ do
    let source = Source "checked" "unit checked\nf :: Int8 -> Integer\nlaw `bad` is definition is `for all` (x :: Int8) . prelude.checked f end end"
    compileCore 64 defaultGeneration [source] `shouldSatisfy` isLeft

  it "rejects generator bounds that speculate a partial expression" $ do
    let source = Source "bound" "unit bound\nlaw `bound` is definition is `for all` (x :: Int8 where x > 0) . x = x end end"
    case compileCore 64 defaultGeneration [source] of
      Left ds -> expectationFailure (show ds)
      Right c -> do
        let origin = C.GeneratedFrom (C.Id "bound")
            zero = C.Expr (C.scalarType "Integer") (C.Constant (SInteger "Integer" 0)) origin
            partial = C.Expr (C.scalarType "Rational") (C.Binary C.Divide (C.Numeric (C.scalarType "Rational")) zero zero) origin
            changeProperty p = p{C.propertyInputs=[q{C.quantifiedBounds=[(C.Greater,partial)]} | q <- C.propertyInputs p]}
            corrupt = c{C.programUnits=[u{C.unitProperties=map changeProperty (C.unitProperties u)} | u <- C.programUnits c]}
        V.validateProgram corrupt `shouldSatisfy` isLeft

  it "keeps quoted law names from impersonating binder identity segments" $ do
    let source = Source "identities" "unit identities\nlaw `name::input::oops%` is definition is `for all` (x :: Int8) . x = x end end"
    case compileCore 64 defaultGeneration [source] of
      Left ds -> expectationFailure (show ds)
      Right c -> case C.programUnits c of
        [C.Unit{C.unitProperties=[p]}] -> do
          C.idText (C.propertyId p) `shouldBe` "identities::law::name%3A%3Ainput%3A%3Aoops%25"
          map (C.idText . C.binderId . C.quantifiedBinder) (C.propertyInputs p) `shouldBe` ["identities::law::name%3A%3Ainput%3A%3Aoops%25::input::0"]
        other -> expectationFailure (show other)
