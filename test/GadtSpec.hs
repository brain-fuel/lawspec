-- | GADTs: local type refinement, inaccessible constructors, existentials and witnesses.
module GadtSpec (test_gadtMatchesRefineTypesLocally) where

import FixtureSource (extendUnit)
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import LawSpec.Core.Types (makeRegistry, compatibleConstructors, freeExistentials)
import LawSpec.Core.Value (Value(..), witnessFields, witnessKey)
import LawSpec.Common
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..))
import LawSpec.Scalar (textScalar, Scalar(..))
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.WebData as Web
import qualified LawSpec.PythonData as Python
import qualified LawSpec.GoData as Go
import qualified LawSpec.HaskellData as Haskell
import qualified LawSpec.KotlinData as Kotlin

expressions :: String
expressions = unlines
  [ "unit example.gadt"
   ++ "\n", ""
  , "type Pair (a :: Type) (b :: Type) is a record{  first :: a second :: b} end type\n"
  , "type Expr (a :: Type) is one of"
  , "  | Number  of type Integer where a = Integer"
  , "  | Truth  of type Bool where a = Bool"
  , "  | Same of type record{ left :: Expr Integer right :: Expr Integer} where a = Bool"
  , "  | Both of type record{ first :: Expr b second :: Expr c} where a = Pair b c"
  , "end type"
  , "type Shown is a record{"
  , "    value :: b}"
  , "end type"
  , "\nend unit" ]

-- | The declarations above, then the given lines.
program :: [String] -> Either [Diagnostic] C.Program
program extra = compileCore 64 defaultGeneration [Source "gadt.lawspec" (extendUnit expressions $ unlines extra)]

rejects :: String -> [String] -> Expectation
rejects fragment extra = case program extra of
  Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf fragment
  Right _ -> expectationFailure ("expected rejection mentioning " ++ show fragment)

eval :: [String]
eval =
  [ "function eval (e :: Expr a) -> a is"
  , "  first matching case of e:"
  , "    when Number v then v"
  , "    when Truth b then b"
  , "    when Same record{left = l, right = r} then eval l = eval r"
  , "    when Both record{first = l, second = r} then Pair record{first = eval l, second = eval r}"
  , "  end case"
  , "end function"
  ]

declaration :: C.Program -> String -> C.DataDeclaration
declaration compiled name = case [d | d <- C.programDataDeclarations compiled, C.dataName d == name] of
  d : _ -> d
  [] -> error ("no declaration " ++ name)

-- | A match on a GADT learns the type index, so each branch must be typed with
-- what it learned and constructors the index rules out must need no branch.
-- ref:DEC-gadts-and-index-arithmetic ref:REQ-gadts
test_gadtMatchesRefineTypesLocally :: Spec
test_gadtMatchesRefineTypesLocally = describe "GADTs" $ do
  describe "native products" $ do
    mapM_ (\layout -> it ("refines Haskell constructor fields and codecs in " ++ show layout) $ do
      compiled <- either (fail . show) pure (program
        [ "type Fixed (a :: Type) is one of | Fixed of type record{ value :: a values :: List a} where a = Bytes end type\n" ])
      let declarations = C.programDataDeclarations compiled
      text <- either fail pure (Haskell.emitHaskellData layout declarations)
      codec <- either fail pure (Haskell.emitHaskellCodecs layout declarations)
      text `shouldSatisfy` isInfixOf "} -> Fixed B.ByteString"
      text `shouldSatisfy` isInfixOf "Value :: a0"
      text `shouldSatisfy` isInfixOf "Values :: [a0]"
      codec `shouldSatisfy` isInfixOf "{-# LANGUAGE GADTs #-}"
      codec `shouldSatisfy` isInfixOf "Codec.bytesCodec schema bits"
      codec `shouldSatisfy` isInfixOf "Codec.encode")
      [D.Pretty 80, D.Compact]
    it "keeps a fixed parameter in the Go product and codec" $ do
      compiled <- either (fail . show) pure (program
        [ "type Fixed (a :: Type) is one of | Fixed  of type a where a = Bytes end type\n" ])
      let declarations = C.programDataDeclarations compiled
      text <- either fail pure (Go.emitGoData (D.Pretty 80) "example" declarations)
      codec <- either fail pure (Go.emitGoCodecs (D.Pretty 80) "example" declarations)
      text `shouldSatisfy` isInfixOf "type Fixed[T0 any] struct"
      codec `shouldSatisfy` isInfixOf "Fixed[T0]{"
    it "keeps a fixed parameter in the TypeScript product class" $ do
      compiled <- either (fail . show) pure (program
        [ "type Fixed (a :: Type) is one of | Fixed  of type a where a = Bytes end type\n" ])
      artifacts <- either fail pure (Web.emitWebData True (D.Pretty 80) (C.programDataDeclarations compiled))
      let text = concatMap artifactContent artifacts
      text `shouldSatisfy` isInfixOf "export class Fixed<T0>"
      text `shouldSatisfy` isInfixOf "readonly value: T0;"
    it "keeps a fixed parameter in the Python product class" $ do
      compiled <- either (fail . show) pure (program
        [ "type Fixed (a :: Type) is one of | Fixed  of type a where a = Bytes end type\n" ])
      artifacts <- either fail pure (Python.emitPythonData (D.Pretty 80) (C.programDataDeclarations compiled))
      let text = concatMap artifactContent artifacts
      text `shouldSatisfy` isInfixOf "class Fixed[_T0]:"
      text `shouldSatisfy` isInfixOf "value: _T0"
    mapM_ (\layout -> it ("keeps a fixed parameter in Kotlin products and codecs in " ++ show layout) $ do
      compiled <- either (fail . show) pure (program
        [ "type Fixed (a :: Type) is one of | Fixed of type record{ value :: a values :: List a} where a = Bytes end type\n" ])
      artifacts <- either fail pure (Kotlin.emitKotlinData layout (C.programDataDeclarations compiled))
      let text = concatMap artifactContent artifacts
      text `shouldSatisfy` isInfixOf "data class Fixed<T0>"
      text `shouldSatisfy` isInfixOf "val value: T0"
      text `shouldSatisfy` isInfixOf "val values: kotlin.collections.List<T0>"
      text `shouldSatisfy` isInfixOf "Codec<lawspec.data.Fixed<T0>>")
      [D.Pretty 80, D.Compact]
  describe "local type refinement" $ do
    it "refines a rigid type variable in each branch" $
      program (eval ++ [ "law \"|two| is definition : for all (x :: Integer) => eval (Number 2) = 2 end for all end definition end law" ])
        `shouldSatisfy` isRight
    it "rejects a branch result at the wrong refined type" $
      program
        [ "function bad (e :: Expr a) -> a is"
        , "first matching case of e : when Number v then true when Truth b then b when Same l r then true when Both record{first = l, second = r} then Pair record{ first = 1 , second = true} end case"
        , "end function"
        ] `shouldSatisfy` isLeft
    it "accepts polymorphic recursion at other instances" $
      -- Same calls eval at Expr BigInt from inside Expr Bool.
      program (eval ++ [ "law \"|same| is definition : for all (x :: Integer) => eval (Same record{left = Number x, right = Number x}) = true end for all end definition end law" ])
        `shouldSatisfy` isRight
  describe "inaccessible constructors" $ do
    it "needs no branch for a constructor that cannot build the type" $
      program
        [ "function truth (e :: Expr Bool) -> Bool is"
        , "first matching case of e : when Truth b then b when Same record{left = l, right = r} then true end case"
        , "end function"
        ] `shouldSatisfy` isRight
    it "rejects constructing a value at a type its constructor cannot build" $
      program ["law \"|bad| is definition : for all (x :: Integer) => (Number x = Number x) = true end for all end definition end law\n",
               "f :: Expr Bool -> Bool",
               "law \"|worse| is definition : for all (x :: Integer) => f (Number x) = true end for all end definition end law\n"]
        `shouldSatisfy` isLeft
    it "keeps only compatible constructors at an instantiated type" $ do
      let Right compiled = program []
          Right registry = makeRegistry (C.programDataDeclarations compiled)
          expr = C.dataId (declaration compiled "Expr")
          at ty = map C.constructorName <$> compatibleConstructors registry (C.Constructor (C.idText expr) [C.TypeArgument ty])
      at (C.Constructor "Bool" []) `shouldBe` Right ["Truth", "Same"]
      at (C.Constructor "Integer" []) `shouldBe` Right ["Number"]
  describe "existentials" $ do
    it "determines existentials from the refined type" $ do
      let Right compiled = program []
          both = [c | c <- C.dataConstructors (declaration compiled "Expr"), C.constructorName c == "Both"]
      map (length . C.constructorExistentials) both `shouldBe` [2]
      map (freeExistentials (declaration compiled "Expr")) both `shouldBe` [[]]
    it "rejects matching a field-only existential in a definition" $
      rejects "only in adapters"
        [ "function unbox (s :: Shown) -> Bool is"
        , "  first matching case of s : when Shown v then true end case"
        , "end function" ]
  describe "type witnesses" $ do
    it "appends a Text witness field to the runtime schema" $ do
      let Right compiled = program []
          Right schemas = S.dataSchemas (C.programDataDeclarations compiled)
          shown = [c | s <- schemas, c <- S.constructors s, "Shown" `isInfixOf` S.constructorTag c]
      map (map S.fieldName . S.fields) shown `shouldBe` [["value", "witness"]]
      map S.constructorWitnesses shown `shouldBe` [[0]]
    it "names a value's witness from its field types" $ do
      let Right compiled = program []
          shown = declaration compiled "Shown"
          tag = C.constructorId (head (C.dataConstructors shown))
          ty = C.Constructor (C.idText (C.dataId shown)) []
      witnessFields (C.programDataDeclarations compiled) ty tag [ScalarValue (SBool True)]
        `shouldBe` [ScalarValue (textScalar "Bool")]
      witnessKey (C.Constructor "Pair" [C.TypeArgument (C.Constructor "Bool" []), C.TypeArgument (C.Constructor "Int32" [])])
        `shouldBe` "(Pair Bool Int32)"
    it "reserves the witness field name" $
      rejects "cannot be named witness" [ "type Boxed is a record{   value :: b witness :: Bool} end type\n" ]
