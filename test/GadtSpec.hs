-- | GADTs: local type refinement, inaccessible constructors, existentials and witnesses.
module GadtSpec (test_gadtMatchesRefineTypesLocally) where

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
  , "type Pair (a :: Type) (b :: Type) is Pair first :: a second :: b end"
  , "type Expr (a :: Type) is"
  , "  | Number value :: BigInt where a = BigInt"
  , "  | Truth value :: Bool where a = Bool"
  , "  | Same left :: Expr BigInt right :: Expr BigInt where a = Bool"
  , "  | Both first :: Expr b second :: Expr c where a = Pair b c"
  , "end"
  , "type Shown is"
  , "  | Shown value :: b"
  , "end"
  ]

-- | The declarations above, then the given lines.
program :: [String] -> Either [Diagnostic] C.Program
program extra = compileCore 64 defaultGeneration [Source "gadt.lawspec" (expressions ++ unlines extra)]

rejects :: String -> [String] -> Expectation
rejects fragment extra = case program extra of
  Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf fragment
  Right _ -> expectationFailure ("expected rejection mentioning " ++ show fragment)

eval :: [String]
eval =
  [ "definition eval (e :: Expr a) :: a is"
  , "  match e with"
  , "  | Number v -> v"
  , "  | Truth b -> b"
  , "  | Same l r -> eval l == eval r"
  , "  | Both l r -> Pair (eval l) (eval r)"
  , "  end"
  , "end"
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
        ["type Fixed (a :: Type) is | Fixed value :: a values :: List a where a = Bytes end"])
      let declarations = C.programDataDeclarations compiled
      text <- either fail pure (Haskell.emitHaskellData layout declarations)
      codec <- either fail pure (Haskell.emitHaskellCodecs layout declarations)
      text `shouldSatisfy` isInfixOf "fixedValue :: B.ByteString"
      text `shouldSatisfy` isInfixOf "fixedValues :: [B.ByteString]"
      codec `shouldSatisfy` isInfixOf "EmptyCase, GADTs, ScopedTypeVariables"
      codec `shouldSatisfy` isInfixOf "Codec.decode (Codec.bytesCodec schema bits) value0"
      codec `shouldSatisfy` isInfixOf "Codec.encode (Codec.bytesCodec schema bits) value0")
      [D.Pretty 80, D.Compact]
    it "keeps a fixed parameter in the Go product and codec" $ do
      compiled <- either (fail . show) pure (program
        ["type Fixed (a :: Type) is | Fixed value :: a where a = Bytes end"])
      let declarations = C.programDataDeclarations compiled
      text <- either fail pure (Go.emitGoData (D.Pretty 80) "example" declarations)
      codec <- either fail pure (Go.emitGoCodecs (D.Pretty 80) "example" declarations)
      text `shouldSatisfy` isInfixOf "type Fixed[T0 any] struct"
      codec `shouldSatisfy` isInfixOf "Fixed[T0]{"
    it "keeps a fixed parameter in the TypeScript product class" $ do
      compiled <- either (fail . show) pure (program
        ["type Fixed (a :: Type) is | Fixed value :: a where a = Bytes end"])
      artifacts <- either fail pure (Web.emitWebData True (D.Pretty 80) (C.programDataDeclarations compiled))
      let text = concatMap artifactContent artifacts
      text `shouldSatisfy` isInfixOf "export class Fixed<T0>"
      text `shouldSatisfy` isInfixOf "readonly value: T0;"
    it "keeps a fixed parameter in the Python product class" $ do
      compiled <- either (fail . show) pure (program
        ["type Fixed (a :: Type) is | Fixed value :: a where a = Bytes end"])
      artifacts <- either fail pure (Python.emitPythonData (D.Pretty 80) (C.programDataDeclarations compiled))
      let text = concatMap artifactContent artifacts
      text `shouldSatisfy` isInfixOf "class Fixed[_T0]:"
      text `shouldSatisfy` isInfixOf "value: _T0"
    mapM_ (\layout -> it ("keeps a fixed parameter in Kotlin products and codecs in " ++ show layout) $ do
      compiled <- either (fail . show) pure (program
        ["type Fixed (a :: Type) is | Fixed value :: a values :: List a where a = Bytes end"])
      artifacts <- either fail pure (Kotlin.emitKotlinData layout (C.programDataDeclarations compiled))
      let text = concatMap artifactContent artifacts
      text `shouldSatisfy` isInfixOf "data class Fixed<T0>"
      text `shouldSatisfy` isInfixOf "val value: T0"
      text `shouldSatisfy` isInfixOf "val values: kotlin.collections.List<T0>"
      text `shouldSatisfy` isInfixOf "Codec<lawspec.data.Fixed<T0>>")
      [D.Pretty 80, D.Compact]
  describe "local type refinement" $ do
    it "refines a rigid type variable in each branch" $
      program (eval ++ ["law `two` is definition is `for all` (x :: BigInt) . eval (Number 2) = 2 end end"])
        `shouldSatisfy` isRight
    it "rejects a branch result at the wrong refined type" $
      program
        [ "definition bad (e :: Expr a) :: a is"
        , "  match e with | Number v -> true | Truth b -> b | Same l r -> true | Both l r -> Pair 1 true end"
        , "end"
        ] `shouldSatisfy` isLeft
    it "accepts polymorphic recursion at other instances" $
      -- Same calls eval at Expr BigInt from inside Expr Bool.
      program (eval ++ ["law `same` is definition is `for all` (x :: BigInt) . eval (Same (Number x) (Number x)) = true end end"])
        `shouldSatisfy` isRight
  describe "inaccessible constructors" $ do
    it "needs no branch for a constructor that cannot build the type" $
      program
        [ "definition truth (e :: Expr Bool) :: Bool is"
        , "  match e with | Truth b -> b | Same l r -> true end"
        , "end"
        ] `shouldSatisfy` isRight
    it "rejects constructing a value at a type its constructor cannot build" $
      program ["law `bad` is definition is `for all` (x :: BigInt) . (Number x == Number x) = true end end",
               "f :: Expr Bool -> Bool",
               "law `worse` is definition is `for all` (x :: BigInt) . f (Number x) = true end end"]
        `shouldSatisfy` isLeft
    it "keeps only compatible constructors at an instantiated type" $ do
      let Right compiled = program []
          Right registry = makeRegistry (C.programDataDeclarations compiled)
          expr = C.dataId (declaration compiled "Expr")
          at ty = map C.constructorName <$> compatibleConstructors registry (C.Constructor (C.idText expr) [C.TypeArgument ty])
      at (C.Constructor "Bool" []) `shouldBe` Right ["Truth", "Same"]
      at (C.Constructor "BigInt" []) `shouldBe` Right ["Number"]
  describe "existentials" $ do
    it "determines existentials from the refined type" $ do
      let Right compiled = program []
          both = [c | c <- C.dataConstructors (declaration compiled "Expr"), C.constructorName c == "Both"]
      map (length . C.constructorExistentials) both `shouldBe` [2]
      map (freeExistentials (declaration compiled "Expr")) both `shouldBe` [[]]
    it "rejects matching a field-only existential in a definition" $
      rejects "only in adapters"
        [ "definition unbox (s :: Shown) :: Bool is"
        , "  match s with | Shown v -> true end"
        , "end"
        ]
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
      rejects "cannot be named witness" ["type Boxed is | Boxed value :: b witness :: Bool end"]
