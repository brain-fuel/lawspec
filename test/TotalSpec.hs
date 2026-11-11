-- | Execution of checked total definitions in Core.
module TotalSpec (test_checkedDefinitionsExecuteTotallyInCore) where

import Test.Hspec
import Data.Either (isLeft, isRight)
import LawSpec.Core
import LawSpec.Core.Total
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Frontend (compileCore)
import Control.Exception (evaluate)
import LawSpec.Common (Source(..), Artifact(..), Diagnostic(..), defaultGeneration, ownership)
import System.Timeout (timeout)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import LawSpec.Core.SizeChange (Verdict(..), sizeChange)
import qualified LawSpec.Core.Value as V
import LawSpec.Core.Validate (operationEvidence, validateProgram)
import LawSpec.CoreEmit (emitPlan, targets)
import LawSpec.Testing (planTesting)
import LawSpec.Scalar (Scalar(..), floatScalar)

origin :: Origin
origin = GeneratedFrom (Id "total-test")
int, integer, boolean, list :: Type
int = scalarType "Int8"
integer = scalarType "Integer"
boolean = scalarType "Bool"
list = Constructor "List" [TypeArgument int]

expression :: Type -> Node -> Expr
expression ty node = Expr ty node origin
local :: String -> Type -> Expr
local name ty = expression ty (Local (Id name))
number :: Type -> Integer -> Expr
number ty@(Constructor name []) n = expression ty (Constant (SInteger name n))
number _ _ = error "numeric test fixture"
binder :: String -> Type -> Binder
binder name ty = Binder (Id name) name ty
call :: String -> [Expr] -> Expr
call name arguments = expression integer (ExternalCall (Id name) arguments)
operation :: BinaryOp -> Expr -> Expr -> Expr
operation op left right =
  let evidence = either error id (operationEvidence op (expressionType left) (expressionType right))
      ty = if isComparison op then boolean else case evidence of Numeric t -> t; Structural t -> t
  in expression ty (Binary op evidence left right)
matchList :: Expr -> Expr -> String -> String -> Expr -> Expr
matchList value nil headName tailName cons = expression (expressionType nil) (Match value
  [MatchCase (Id "List::Nil") [] nil,
   MatchCase (Id "List::Cons") [binder headName int, binder tailName list] cons])
cons :: Expr -> Expr
cons tailValue = expression list (Construct (Id "List::Cons") [number int 0, tailValue])
definition :: String -> [(String, Type)] -> Expr -> Definition
definition name parameters body = Definition
  (Declaration (Id name) name (foldr Arrow (expressionType body) (map snd parameters)) origin)
  [binder name ty | (name,ty) <- parameters] body
lengthDef :: Expr -> Definition
lengthDef recursive = definition "length" [("xs",list)]
  (matchList (local "xs" list) (number integer 0) "head" "tail"
    (operation Add (number integer 1) recursive))

-- | The compiler evaluates checked definitions itself, so every operation that
-- could fail must be justified by a proved domain, in both machine profiles
-- and without IEEE shortcuts. ref:DEC-total-definitions
-- ref:REQ-total-definitions
test_checkedDefinitionsExecuteTotallyInCore :: Spec
test_checkedDefinitionsExecuteTotallyInCore = describe "checked Core total definitions" $ do
  it "executes arithmetic justified by a matched field's primitive domain" $ do
    let source = Source "fields.lawspec" $ unlines
          [ "unit fields"
           ++ "\n", ""
          , "function first (xs :: List Int8) -> Rational is first matching case of xs : when Nil then 0 when Cons head tail then 1 / (head + 129) end case end function\n"
          , "law \"|nonnegative| is definition : for all (xs :: List Int8) => first xs >= 0 end for all end definition end law"
          , "\nend unit" ]
        list = Constructor "List" [TypeArgument int]
        nil = V.DataValue list (Id "List::Nil") []
        singleton n = V.DataValue list (Id "List::Cons") [V.ScalarValue (SInteger "Int8" n),nil]
    mapM_ (\bits -> case compileCore bits defaultGeneration [source] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        case prepareDefinitions program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right invoke -> do
            invoke (Id "fields::first") [nil] `shouldBe` Right (V.ScalarValue (SRational 0 1))
            -- The admitted interpreter skips repeated borrowing checks only
            -- after the public boundary rejects malformed native values.
            invoke (Id "fields::first") [singleton 128] `shouldSatisfy` isLeft
            invoke (Id "fields::first") [V.DataValue list (Id "List::Cons") [nil,nil]] `shouldSatisfy` isLeft
            mapM_ (\n -> invoke (Id "fields::first") [singleton n]
              `shouldBe` Right (V.ScalarValue (SRational 1 (n + 129)))) [-128..127]
        mapM_ (\target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight) targets) [32,64]
  it "executes guarded narrowing for every Int8 value under both profiles" $ do
    let source = Source "narrow.lawspec" $ unlines
          [ "unit narrow"
           ++ "\n", ""
          , "function next (x :: Int8) -> Bool is x < 127 && prelude.Int8 (x + 1) > x end function\n"
          , "law \"|range| is definition : for all (x :: Int8) => next x = (x < 127) end for all end definition end law"
          , "\nend unit" ]
    mapM_ (\bits -> case compileCore bits defaultGeneration [source] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        case prepareDefinitions program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right invoke -> mapM_ (\n -> invoke (Id "narrow::next") [V.ScalarValue (SInteger "Int8" n)]
            `shouldBe` Right (V.ScalarValue (SBool (n < 127)))) [-128..127]
        mapM_ (\target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight) targets) [32,64]
  it "uses exact implications for affine denominators without assuming IEEE identities" $ do
    let source = Source "affine.lawspec" $ unlines
          [ "unit affine"
           ++ "\n", ""
          , "function reciprocal (x :: Int8) -> Bool is x >= 0 && 1 / (x + 1) > 0 end function\n"
          , "law \"|sign| is definition : for all (x :: Int8) => reciprocal x = (x >= 0) end for all end definition end law"
          , "\nend unit" ]
    mapM_ (\bits -> case compileCore bits defaultGeneration [source] of
      Left diagnostics -> expectationFailure (show diagnostics)
      Right program -> do
        case prepareDefinitions program of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right invoke -> mapM_ (\n -> invoke (Id "affine::reciprocal") [V.ScalarValue (SInteger "Int8" n)]
            `shouldBe` Right (V.ScalarValue (SBool (n >= 0)))) [-128..127]
        mapM_ (\target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight) targets) [32,64]
  it "does not discharge an exact zero denominator using contradictory-looking IEEE facts" $ do
    let floating = scalarType "Float64"
        input = local "x" floating
        nanGuard = operation NotEqual input input
        infinityGuard = operation NotEqual (operation Subtract input input)
          (expression floating (Constant (floatScalar "Float64" 0)))
        division = operation Divide (number int 1) (number int 0)
        body guard = expression boolean (ShortCircuit And guard (operation Equal division division))
    mapM_ (\guard -> validateDefinitions 64 [] [definition "unsafe" [("x",floating)] (body guard)]
      `shouldSatisfy` isLeft) [nanGuard,infinityGuard]
  it "parses, checks, and evaluates source list recursion in both machine profiles" $ do
    let source = Source "total.lawspec" $ unlines
          [ "unit total"
           ++ "\n", ""
          , "function size (xs :: List Int8) -> Integer is"
          , "  first matching case of xs : when Nil then 0 when Cons head tail then 1 + size tail end case"
          , "end function"
          , "law \"|length| is definition : for all (xs :: List Int8) => size xs = prelude.length xs end for all end definition end law"
          , "\nend unit" ]
    mapM_ (\bits -> case compileCore bits defaultGeneration [source] >>= prepareDefinitions of
      Left ds -> expectationFailure (show ds)
      Right invoke -> do
        let nil = V.DataValue list (Id "List::Nil") []
            values = foldr (\n tailValue -> V.DataValue list (Id "List::Cons")
              [V.ScalarValue (SInteger "Int8" n), tailValue]) nil [1,2,3]
        invoke (Id "total::size") [values] `shouldBe` Right (V.ScalarValue (SInteger "Integer" 3))
        invoke (Id "total::size") [nil] `shouldBe` Right (V.ScalarValue (SInteger "Integer" 0))
        invoke (Id "total::size") [] `shouldSatisfy` isLeft
        invoke (Id "total::size") [V.ScalarValue (SBool True)] `shouldSatisfy` isLeft
        invoke (Id "adapter") [] `shouldSatisfy` isLeft) [32,64]
  it "checks unused source definitions, including recursion and partial bodies" $ do
    let check body = compileCore 64 defaultGeneration [Source "total.lawspec" ("unit total\n\n" ++ body ++ "\nend unit\n")]
    mapM_ (\body -> check body `shouldSatisfy` isLeft)
      ["function bad (xs :: List Int8) -> Integer is bad xs end function\n"
      ,"function bad (xs :: List Int8) -> Integer is first matching case of xs : when Nil then 0 end case end function\n"
      ,"function bad (x :: Integer) -> Rational is 1 / x end function\n"
      ,"function bad (x :: Int8) (x :: Int8) -> Int8 is x end function"
      ,"adapter :: Int8 -> Int8\nfunction bad (x :: Int8) -> Int8 is adapter x end function\n"
      ,"function f (x :: Int8) -> Int8 is g x end function\nfunction g (x :: Int8) -> Int8 is f x end function\n"
      ,"function bad (x :: Int8) -> Bool is x end function\n"
      ,"function bad (x :: Int8 where x >= 0) -> Rational is 1 / x end function\n"]
  it "qualifies custom constructors and evaluates forward definition calls" $ do
    let source = Source "tree.lawspec" $ unlines
          [ "unit tree"
           ++ "\n", ""
          , "type Tree is one of Leaf  of type Int8 | Branch  of type List Tree end type\n"
          , "function root (t :: Tree) -> Int8 is get t end function\n"
          , "function get (t :: Tree) -> Int8 is first matching case of t : when Leaf x then x when Branch xs then 0 end case end function\n"
          , "\nend unit" ]
    case compileCore 64 defaultGeneration [source] >>= prepareDefinitions of
      Left ds -> expectationFailure (show ds)
      Right invoke -> invoke (Id "tree::root")
        [V.DataValue (Constructor "tree::type::Tree" []) (Id "tree::type::Tree::Leaf")
          [V.ScalarValue (SInteger "Int8" 127)]] `shouldBe` Right (V.ScalarValue (SInteger "Int8" 127))
  it "preserves lexical parameter shadowing over function names" $ do
    let source = Source "shadow.lawspec" $ unlines
          [ "unit shadow"
           ++ "\n", ""
          , "x :: Bool -> Bool"
          , "function identity (x :: Int8) -> Int8 is x end function\n"
          , "\nend unit" ]
    case compileCore 64 defaultGeneration [source] >>= prepareDefinitions of
      Left ds -> expectationFailure (show ds)
      Right invoke -> invoke (Id "shadow::identity") [V.ScalarValue (SInteger "Int8" 42)]
        `shouldBe` Right (V.ScalarValue (SInteger "Int8" 42))
  it "audits total bodies and ownership at the program validation boundary" $ do
    let bad = definition "bad" [("xs",list)] (call "bad" [local "xs" list])
        good = lengthDef (call "length" [local "tail" list])
        program d declarations = Program 64 [] [Unit (Id "unit") declarations [] [] [d] []]
    validateProgram (program bad [definitionDeclaration bad]) `shouldSatisfy` isLeft
    validateProgram (program good []) `shouldSatisfy` isLeft
    validateProgram (program good [definitionDeclaration good]) `shouldBe` Right ()
  it "does not silently replace checked definitions with adapter stubs" $ do
    let source = Source "total.lawspec" "unit total\n\nfunction identity (x :: Int8) -> Int8 is x end function\nend unit\n"
    case compileCore 64 defaultGeneration [source] >>= planTesting of
      Left ds -> expectationFailure (show ds)
      Right plan -> mapM_ (\target -> case emitPlan target plan of
        Left ds -> expectationFailure (target ++ ": " ++ show ds)
        Right files -> concatMap artifactContent [f | f <- files, ownership f == "user"]
          `shouldNotSatisfy` isInfixOf "identity") targets
  it "emits Rust definitions as generated source with typed native entry points" $ do
    let source = Source "total.lawspec" "unit total\n\nfunction identity (x :: Int8) -> Int8 is x end function\nend unit\n"
    case compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "rust" of
      Left ds -> expectationFailure (show ds)
      Right files -> do
        let sourceFiles = [file | file <- files, artifactPath file == "src/lawspec_definitions.rs"]
        length sourceFiles `shouldBe` 1
        map ownership sourceFiles `shouldBe` ["generated"]
        map artifactPlacement sourceFiles `shouldBe` ["source"]
        concatMap artifactContent sourceFiles `shouldSatisfy` isInfixOf "pub fn identity(_ctx: &mut ls::Context, x: i8) -> ls::Result<i8>"
        concatMap artifactContent [f | f <- files, ownership f == "user"]
          `shouldNotSatisfy` isInfixOf "pub fn identity"
  it "emits Java definitions with native entry points and checked support" $ do
    let source = Source "total.lawspec" "unit total\n\nfunction identity (x :: Int8) -> Int8 is x end function\nend unit\n"
    case compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "java" of
      Left ds -> expectationFailure (show ds)
      Right files -> do
        let native = [f | f <- files, artifactPath f == "src/main/java/lawspec/definitions/Total.java"]
            bodies = [f | f <- files, artifactPath f == "src/main/java/lawspec/runtime/LawSpecDefinitionBodies.java"]
        length native `shouldBe` 1
        length bodies `shouldBe` 1
        map ownership (native ++ bodies) `shouldBe` ["generated","generated"]
        map artifactPlacement (native ++ bodies) `shouldBe` ["source","source"]
        concatMap artifactContent native `shouldSatisfy` isInfixOf "java.lang.Byte identity"
        concatMap artifactContent [f | f <- files, ownership f == "user"]
          `shouldNotSatisfy` isInfixOf " identity("
  it "rejects Java adapter collisions with generated definition classes" $ do
    let total = Source "total.lawspec" "unit example.total\n\nfunction identity (x :: Int8) -> Int8 is x end function\nend unit\n"
    mapM_ (\unit -> (compileCore 64 defaultGeneration
        [total,Source "collision.lawspec" ("unit " ++ unit ++ "\necho :: Bool -> Bool\nend unit\n")]
        >>= planTesting >>= emitPlan "java") `shouldSatisfy` isLeft)
      ["lawspec.runtime.law_spec_definition_bodies","lawspec.definitions.example.total"]
  it "emits Kotlin definitions with native generics and shared JVM bodies" $ do
    let source = Source "total.lawspec" "unit total\n\nfunction identity (x :: Optional (Nullable Int8)) -> Optional (Nullable Int8) is x end function\nend unit\n"
    case compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "kotlin" of
      Left ds -> expectationFailure (show ds)
      Right files -> do
        let native = [f | f <- files, artifactPath f == "src/main/kotlin/lawspec/definitions/Total.kt"]
            bodies = [f | f <- files, artifactPath f == "src/main/java/lawspec/runtime/LawSpecDefinitionBodies.java"]
        length native `shouldBe` 1
        length bodies `shouldBe` 1
        map ownership (native ++ bodies) `shouldBe` ["generated","generated"]
        map artifactPlacement (native ++ bodies) `shouldBe` ["source","source"]
        concatMap artifactContent native `shouldSatisfy` isInfixOf "lawspec.runtime.LawSpecKotlin.Optional<"
        concatMap artifactContent native `shouldSatisfy` isInfixOf "lawspec.runtime.LawSpecKotlin.Nullable<kotlin.Byte>"
        concatMap artifactContent [f | f <- files, ownership f == "user"]
          `shouldNotSatisfy` isInfixOf "fun identity"
  it "rejects Kotlin adapter collisions with JVM bodies and native definition objects" $ do
    let total = Source "total.lawspec" "unit example.total\n\nfunction identity (x :: Int8) -> Int8 is x end function\nend unit\n"
    mapM_ (\unit -> (compileCore 64 defaultGeneration
        [total,Source "collision.lawspec" ("unit " ++ unit ++ "\necho :: Bool -> Bool\nend unit\n")]
        >>= planTesting >>= emitPlan "kotlin") `shouldSatisfy` isLeft)
      ["lawspec.runtime.law_spec_definition_bodies","lawspec.definitions.example.total"]
  it "emits Python definitions as typed generated source without adapter stubs" $ do
    let source = Source "total.lawspec" "unit total\n\nfunction identity (x :: List Int8) -> List Int8 is x end function\nend unit\n"
    case compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "python" of
      Left ds -> expectationFailure (show ds)
      Right files -> do
        let native = [f | f <- files, artifactPath f == "src/lawspec_definitions/total.py"]
            bodies = [f | f <- files, artifactPath f == "src/lawspec_definition_bodies.py"]
        length native `shouldBe` 1
        length bodies `shouldBe` 1
        map ownership (native ++ bodies) `shouldBe` ["generated","generated"]
        map artifactPlacement (native ++ bodies) `shouldBe` ["source","source"]
        concatMap artifactContent native `shouldSatisfy` isInfixOf "x: _builtins.list[_builtins.int]"
        concatMap artifactContent [f | f <- files, ownership f == "user"]
          `shouldNotSatisfy` isInfixOf "def identity"
  it "rejects Python definition support and module/package name collisions" $ do
    let total = Source "total.lawspec" "unit example.total\n\nfunction identity (x :: Int8) -> Int8 is x end function\nend unit\n"
    mapM_ (\unit -> (compileCore 64 defaultGeneration
        [total,Source "collision.lawspec" ("unit " ++ unit ++ "\necho :: Bool -> Bool\nend unit\n")]
        >>= planTesting >>= emitPlan "python") `shouldSatisfy` isLeft)
      ["lawspec_definitions", "lawspec_definition_bodies"]
    -- A unit named like another unit's package is the package's __init__.py.
    mapM_ (\(unit, path) -> (map artifactPath <$> (compileCore 64 defaultGeneration
        [total,Source "collision.lawspec" ("unit " ++ unit ++ "\necho :: Bool -> Bool\nend unit\n")]
        >>= planTesting >>= emitPlan "python")) `shouldSatisfy` either (const False) (elem path))
      [("example", "src/example/__init__.py"), ("example.total.child", "src/example/total/__init__.py")]
    mapM_ (\name -> (compileCore 64 defaultGeneration [Source "collision.lawspec"
        ("unit total\nfunction " ++ name ++ " (x :: Int8) -> Int8 is x end function\nend unit")]
        >>= planTesting >>= emitPlan "python") `shouldSatisfy`
          either (isInfixOf "reserved target identifier" . show) (const False)) ["ls", "schema"]
  it "emits JS/TS definitions as generated source with native typed TypeScript APIs" $ do
    let source = Source "total.lawspec" "unit total\n\nfunction identity (x :: List Int8) -> List Int8 is x end function\nend unit\n"
    mapM_ (\(target,extension) -> case compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan target of
      Left ds -> expectationFailure (show ds)
      Right files -> do
        let native = [f | f <- files, artifactPath f == "src/lawspec_definitions/total." ++ extension]
            bodies = [f | f <- files, artifactPath f == "src/lawspec_definition_bodies." ++ extension]
        length native `shouldBe` 1
        length bodies `shouldBe` 1
        map ownership (native ++ bodies) `shouldBe` ["generated","generated"]
        map artifactPlacement (native ++ bodies) `shouldBe` ["source","source"]
        concatMap artifactContent native `shouldSatisfy` isInfixOf "export function identity"
        concatMap artifactContent [f | f <- files, ownership f == "user"]
          `shouldNotSatisfy` isInfixOf "function identity"
        if target == "typescript" then do
          concatMap artifactContent native `shouldSatisfy` isInfixOf "x: Array<number>"
          concatMap artifactContent (native ++ bodies) `shouldNotSatisfy` isInfixOf "@ts-nocheck"
        else pure ()) [("javascript","mjs"),("typescript","ts")]
  it "rejects JS/TS definition support collisions and shadowed globals" $ do
    let total = Source "total.lawspec" "unit example.total\n\nfunction identity (x :: Int8) -> Int8 is x end function\nend unit\n"
    mapM_ (\target -> do
      mapM_ (\unit -> (compileCore 64 defaultGeneration
          [total,Source "collision.lawspec" ("unit " ++ unit ++ "\necho :: Bool -> Bool\nend unit\n")]
          >>= planTesting >>= emitPlan target) `shouldSatisfy` isLeft)
        ["lawspec_definitions.example.total", "lawspec_definition_bodies"]
      mapM_ (\name -> (compileCore 64 defaultGeneration [Source "collision.lawspec"
          ("unit total\nfunction " ++ name ++ " (x :: Int8) -> Int8 is x end function\nend unit")]
          >>= planTesting >>= emitPlan target) `shouldSatisfy` isLeft) ["globalThis", "eval", "arguments"])
      ["javascript","typescript"]
  it "emits Go native definition methods without colliding with data type names" $ do
    let source = Source "total.lawspec" $ unlines
          [ "unit total"
           ++ "\n", ""
          , "type Identity is a record{  value :: Int8} end type\n"
          , "function identity (x :: Identity) -> Identity is x end function\n"
          , "\nend unit" ]
    case compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "go" of
      Left ds -> expectationFailure (show ds)
      Right files -> do
        let native = [f | f <- files, artifactPath f == "total/lawspec_definitions.go"]
        length native `shouldBe` 1
        map ownership native `shouldBe` ["generated"]
        map artifactPlacement native `shouldBe` ["source"]
        concatMap artifactContent native `shouldSatisfy` isInfixOf "func (lawSpecDefinitions) Identity"
        concatMap artifactContent native `shouldSatisfy` isInfixOf "x Identity"
        concatMap artifactContent [f | f <- files, ownership f == "user"]
          `shouldNotSatisfy` isInfixOf "func Identity"
  it "does not emit Go definition source into an unused empty unit" $ do
    let sources = [Source "empty.lawspec" "unit empty\nend unit\n", Source "total.lawspec"
          "unit total\n\nfunction identity (x :: Int8) -> Int8 is x end function\nend unit\n"]
    case compileCore 64 defaultGeneration sources >>= planTesting >>= emitPlan "go" of
      Left ds -> expectationFailure (show ds)
      Right files -> map artifactPath files `shouldNotSatisfy` elem "empty/lawspec_definitions.go"
  it "emits Haskell native definitions with a scoped Symbol context" $ do
    let source = Source "total.lawspec" $ unlines
          [ "unit total"
           ++ "\n", ""
          , "function identity (x :: Int8) -> Int8 is x end function\n"
          , "function schema (x :: Bool) -> Bool is x end function\n"
          , "function bits (x :: Bool) -> Bool is x end function\n"
          , "\nend unit" ]
    case compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "haskell" of
      Left ds -> expectationFailure (show ds)
      Right files -> do
        let native = [f | f <- files, artifactPath f == "src/LawSpecDefinitions/Total.hs"]
        length native `shouldBe` 1
        map ownership native `shouldBe` ["generated"]
        map artifactPlacement native `shouldBe` ["source"]
        concatMap artifactContent native `shouldSatisfy` isInfixOf "LS.SymbolContext"
        concatMap artifactContent native `shouldSatisfy` isInfixOf "P.Either P.String I.Int8"
        concatMap artifactContent native `shouldSatisfy` isInfixOf "schema = P.either P.error P.id DataSchema.schema"
  it "accepts list-tail recursion and arbitrary definition order" $ do
    let size = lengthDef (call "length" [local "tail" list])
        caller = definition "size" [("value",list)] (call "length" [local "value" list])
    validateDefinitions 64 [] [caller,size] `shouldSatisfy` isRight
  it "accepts transitive strict subterms" $ do
    let inner = matchList (local "tail" list) (number integer 0) "head2" "tail2"
          (call "length" [local "tail2" list])
    validateDefinitions 64 [] [lengthDef inner] `shouldSatisfy` isRight
  it "allows a growing accumulator when one parameter always decreases" $ do
    let body = matchList (local "xs" list) (number integer 0) "head" "tail"
          (call "append" [local "tail" list, cons (local "acc" list)])
    validateDefinitions 64 [] [definition "append" [("xs",list),("acc",list)] body]
      `shouldSatisfy` isRight
  it "rejects unchanged, reconstructed, and nested nondecreasing calls" $ do
    let bad = [call "length" [local "xs" list], call "length" [cons (local "tail" list)],
          operation Add (number integer 1) (call "length" [local "xs" list])]
    mapM_ (\body -> validateDefinitions 64 [] [lengthDef body] `shouldSatisfy` isLeft) bad
  it "rejects alternately shrinking and rebuilding different parameters" $ do
    let onEmpty = matchList (local "ys" list) (number integer 0) "headY" "tailY"
          (call "loop" [cons (local "xs" list), local "tailY" list])
        body = matchList (local "xs" list) onEmpty "headX" "tailX"
          (call "loop" [local "tailX" list, cons (local "ys" list)])
    validateDefinitions 64 [] [definition "loop" [("xs",list),("ys",list)] body]
      `shouldSatisfy` isLeft
  -- S1.j report 14. ref:DEC-size-change-termination
  describe "size-change termination" $ do
    let checked name body = compileCore 64 defaultGeneration [Source (name ++ ".lawspec") (unlines (("unit recursion." ++ name) : body ++ ["end unit"]))]
        admits name body = either (map message) (const []) (checked name body) `shouldBe` []
        refuses name body expected = case checked name body of
          Left diagnostics -> concatMap message diagnostics `shouldSatisfy` isInfixOf expected
          Right _ -> expectationFailure (name ++ " was admitted")
        relation = Map.fromList
    it "closes call relations and requires a kept, strictly smaller measure on each loop" $ do
      sizeChange 64 [("f", "f", relation [((0, 0), True)])] `shouldBe` Terminates
      sizeChange 64 [("f", "f", relation [((0, 0), False)])] `shouldBe` Loops "f" ["f"]
      -- A swap decreases one of two measures in turn: no single call keeps a
      -- measure, the loop of two calls does.
      sizeChange 64 [("f", "f", relation [((0, 1), False), ((1, 0), True)])] `shouldBe` Terminates
      -- Lexicographic: the first is smaller, or the first is kept and the second smaller.
      sizeChange 64 [("f", "f", relation [((0, 0), True)]), ("f", "f", relation [((0, 0), False), ((1, 1), True)])] `shouldBe` Terminates
      -- One call shrinks the first and loses the second; the other the reverse.
      sizeChange 64 [("f", "f", relation [((0, 0), True)]), ("f", "f", relation [((1, 1), True)])] `shouldBe` Loops "f" ["f", "f"]
      sizeChange 64 [("f", "g", relation [((0, 0), False)]), ("g", "f", relation [((0, 0), True)])] `shouldBe` Terminates
      sizeChange 64 [("f", "g", relation [((0, 0), False)]), ("g", "f", relation [((0, 0), False)])] `shouldBe` Loops "f" ["g", "f"]
      -- A call out of the group is no loop.
      sizeChange 64 [("f", "g", Map.empty)] `shouldBe` (Terminates :: Verdict String)
    it "reports an analysis that passes its limit as incomplete, not as a loop" $
      sizeChange 2 [("f", "f", relation [((i, j), True)]) | i <- [0 .. 3 :: Int], j <- [0 .. 3], i /= j] `shouldBe` Exhausted
    it "admits two definitions that count down through each other" $
      admits "parity"
        [ "function isEven (n :: Whole) -> Bool is if n <= 0 then true else isOdd (n - 1) end if end function"
        , "function isOdd (n :: Whole) -> Bool is if n <= 0 then false else isEven (n - 1) end if end function" ]
    it "admits a record and its list of children traversed by two definitions" $
      admits "items"
        [ "type Item is a record{label :: Text, children :: List Item} end type"
        , "function itemLine (item :: Item) -> Integer is 1 + itemLines item.children end function"
        , "function itemLines (items :: List Item) -> Integer is"
        , "  first matching case of items: when Nil then 0 when Cons head tail then itemLine head + itemLines tail end case"
        , "end function" ]
    it "admits a lexicographic order, nested calls and arguments that change places" $ do
      admits "ackermann"
        [ "function ack (m :: Whole) (n :: Whole) -> Whole is"
        , "  if m <= 0 then n + 1 else if n <= 0 then ack (m - 1) 1 else ack (m - 1) (ack m (n - 1)) end if end if"
        , "end function" ]
      admits "swap"
        [ "function swap (xs :: List Bool) (ys :: List Bool) -> Integer is"
        , "  first matching case of xs: when Nil then 0 when Cons head tail then 1 + swap ys tail end case"
        , "end function" ]
      admits "grid"
        [ "function cells (rows :: List Bool) (columns :: List Bool) (width :: List Bool) -> Integer is"
        , "  first matching case of columns:"
        , "    when Cons head tail then 1 + cells rows tail width"
        , "    when Nil then first matching case of rows: when Nil then 0 when Cons head tail then cells tail width width end case"
        , "  end case"
        , "end function" ]
    it "admits a counter rising to a limit through a second definition" $
      admits "fill"
        [ "function fill (index :: Integer) (limit :: Integer) -> Integer is"
        , "  if index >= limit then 0 else 1 + rest (index + 1) limit end if"
        , "end function"
        , "function rest (index :: Integer) (limit :: Integer) -> Integer is"
        , "  if index >= limit then 0 else fill index limit end if"
        , "end function" ]
    it "refuses a cycle that makes nothing smaller and names it" $ do
      refuses "ping"
        [ "function ping (n :: Whole) -> Bool is pong n end function"
        , "function pong (n :: Whole) -> Bool is ping n end function" ]
        "recursion could not be shown to end: no argument is kept and made strictly smaller around the call cycle ping -> pong -> ping"
      refuses "seesaw"
        [ "function up (n :: Whole) -> Bool is if n <= 0 then true else down (n - 1) end if end function"
        , "function down (n :: Whole) -> Bool is up (n + 1) end function" ]
        "recursion could not be shown to end"
    it "refuses alternating descent on two arguments that each call undoes" $
      refuses "undo"
        [ "function loop (xs :: List Bool) (ys :: List Bool) -> Integer is"
        , "  first matching case of xs:"
        , "    when Nil then first matching case of ys: when Nil then 0 when Cons head tail then loop [true] tail end case"
        , "    when Cons head tail then loop tail [true]"
        , "  end case"
        , "end function" ]
        "recursion could not be shown to end"
    describe "a stated decreases measure" $ do
      let narrowing clause =
            [ "function narrowing (low :: Integer) (high :: Integer) -> Integer"
            , clause
            , "is"
            , "  if low >= high then 0"
            , "  else if prelude.rem low 2 = 0 then 1 + narrowing (low + 1) high"
            , "  else 1 + narrowing low (high - 1) end if end if"
            , "end function" ]
      it "admits recursion whose stated measure is proved to shrink and stay at least 0" $
        admits "narrowing" (narrowing "decreases high - low")
      it "refuses the same recursion without the measure" $
        refuses "unstated" (narrowing "") "no integer argument moves strictly toward a bound"
      it "checks the measure instead of trusting it" $ do
        refuses "wrong" (narrowing "decreases low") "the decreases measure was not proved to get smaller"
        -- Smaller on every call, but never shown to stay at least 0.
        refuses "unbounded"
          [ "function sink (n :: Integer) -> Integer decreases n is sink (n - 1) end function" ]
          "the decreases measure was not proved to get smaller and stay at least 0"
      it "compares measures across a cycle of definitions" $ do
        let pair second =
              [ "function left (low :: Integer) (high :: Integer) -> Integer decreases high - low is"
              , "  if low >= high then 0 else right (low + 1) high end if"
              , "end function"
              , "function right (low :: Integer) (high :: Integer) -> Integer decreases high - low is"
              , "  if low >= high then 0 else " ++ second ++ " end if"
              , "end function" ]
        admits "pair" (pair "left low (high - 1)")
        refuses "widening" (pair "left low (high + 1)") "the measure right states was not proved to decrease at its call of left"
      it "reads several measures in order of importance" $
        admits "ordered"
          [ "function settle (debt :: Integer) (step :: Integer) (spare :: Integer) -> Integer decreases debt, step is"
          , "  if debt <= 0 || step <= 0 then 0"
          , "  else if step > 1 then settle debt (step - 1) (spare + 1)"
          , "  else settle (debt - 1) (debt + spare * spare + 5) spare end if end if"
          , "end function" ]
      it "leaves no trace of the measure in generated code" $
        case checked "emitted" (narrowing "decreases high - low") >>= planTesting >>= emitPlan "python" of
          Left diagnostics -> expectationFailure (show diagnostics)
          Right files -> concatMap artifactContent files `shouldNotSatisfy` isInfixOf "ecreases"
      it "allows only a function to state a measure, and keeps decreases usable as a name" $ do
        admits "named" ["function plain (decreases :: Integer) -> Integer is decreases + 1 end function"]
        checked "procedure" ["procedure run (n :: Integer) -> Integer decreases n is n end procedure"] `shouldSatisfy` isLeft
  -- S1.j report 17. ref:DEC-s1j-shared-failures
  describe "shared strict bindings" $ do
    let chain count step = unlines $
          ["unit total.chain", "function render (x :: Integer) -> Integer is",
           "let v0 = (if x > 0 then x else 0 end if) in"] ++
          ["let v" ++ show index ++ " = " ++ step ("v" ++ show (index - 1 :: Int)) ++ " in" | index <- [1 .. count - 1]] ++
          ["v" ++ show (count - 1), unwords (replicate count "end let"), "end function", "end unit"]
        admitted text = isRight (compileCore 64 defaultGeneration [Source "chain.lawspec" text])
        within text = timeout 60000000 (evaluate (admitted text))
        boxed result = unlines
          [ "unit total.boxed"
          , "refinement Count is (n :: Integer where n >= 0) end refinement"
          , "type Box is a record{n :: Count} end type"
          , "function box (x :: Integer) -> Box is"
          , "let v = (if x > 0 then x else 0 end if) in Box record{n = " ++ result ++ "} end let"
          , "end function", "end unit" ]
    it "admits a deep chain of conditionals that each use the last twice" $
      within (chain 24 (\v -> "(if " ++ v ++ " > 1 then " ++ v ++ " - 1 else " ++ v ++ " + " ++ v ++ " end if)"))
        `shouldReturn` Just True
    it "admits a deep chain of matches that each use the last twice" $
      within (chain 24 (\v -> "(first matching case of [" ++ v ++ "]: when Nil then " ++ v ++ " when Cons head tail then head + " ++ v ++ " end case)"))
        `shouldReturn` Just True
    it "admits a deep chain of sums that each use the last twice" $
      within (chain 40 (\v -> v ++ " + " ++ v)) `shouldReturn` Just True
    it "still proves a refinement from what a shared binding equals on each branch" $ do
      admitted (boxed "v + v") `shouldBe` True
      admitted (boxed "v + v - 1") `shouldBe` False
    it "reports every rejected definition, not only the first" $ do
      let text = unlines
            [ "unit total.many"
            , "function first (x :: Integer) -> Integer is first x end function"
            , "function second (x :: Integer) -> Integer is second x end function"
            , "end unit" ]
      case compileCore 64 defaultGeneration [Source "many.lawspec" text] of
        Right _ -> expectationFailure "nonterminating definitions were admitted"
        Left problems -> do
          filter (isInfixOf "first:" . message) problems `shouldSatisfy` (not . null)
          filter (isInfixOf "second:" . message) problems `shouldSatisfy` (not . null)
  it "audits callees and rejects mutual recursion" $ do
    let f = definition "f" [("xs",list)] (call "g" [local "xs" list])
        g = definition "g" [("xs",list)] (call "f" [local "xs" list])
    validateDefinitions 64 [] [f] `shouldSatisfy` isLeft
    validateDefinitions 64 [] [f,g] `shouldSatisfy` isLeft
  it "checks argument signatures, scopes, and exhaustive matches" $ do
    let good = lengthDef (call "length" [local "tail" list])
        missing = good { definitionBody = expression integer
          (Match (local "xs" list) [MatchCase (Id "List::Nil") [] (number integer 0)]) }
        unbound = good { definitionBody = local "missing" integer }
        signature = good { definitionArguments = [binder "xs" integer] }
    mapM_ (\body -> validateDefinitions 64 [] [body] `shouldSatisfy` isLeft)
      [missing,unbound,signature]
  it "allows guarded exact division and quotient with branch-local facts" $ do
    let y = local "y" int
        zero = number int 0
        quotient = operation Quotient (number int 1) y
        result = operation Equal quotient (number integer 0)
        nonzero = operation NotEqual y zero
        isZero = operation Equal y zero
        guarded op guard = definition "safe" [("y",int)]
          (expression boolean (ShortCircuit op guard result))
    validateDefinitions 64 [] [guarded And nonzero] `shouldSatisfy` isRight
    validateDefinitions 64 [] [guarded Or isZero] `shouldSatisfy` isRight
    validateDefinitions 64 [] [guarded And isZero] `shouldSatisfy` isLeft
    validateDefinitions 64 [] [guarded Or nonzero] `shouldSatisfy` isLeft
    validateDefinitions 64 [] [definition "unsafe" [("y",int)] quotient]
      `shouldSatisfy` isLeft
  it "does not evaluate the right side of a constant short circuit" $ do
    let bad = operation Equal (operation Divide (number int 1) (number int 0))
          (expression (scalarType "Rational") (Constant (SRational 0 1)))
        body = expression boolean (ShortCircuit And (expression boolean (Constant (SBool False))) bad)
    validateDefinitions 64 [] [definition "unreachable" [] body] `shouldSatisfy` isRight
  it "validates malformed Core constants even in skipped proof branches" $ do
    let invalid = expression (scalarType "Rational") (Constant (SRational 1 0))
        result = operation Equal invalid invalid
        body = expression boolean (ShortCircuit And (expression boolean (Constant (SBool False))) result)
    validateDefinitions 64 [] [definition "invalid" [] body] `shouldSatisfy` isLeft
  it "keeps IEEE division total, including a zero denominator" $ do
    let floating n = expression (scalarType "Float64") (Constant (floatScalar "Float64" n))
    validateDefinitions 64 [] [definition "infinity" [] (operation Divide (floating 1) (floating 0))]
      `shouldSatisfy` isRight
  it "requires presence before extracting a nullable payload" $ do
    let ty = Constructor "Nullable" [TypeArgument int]
        value = local "x" ty
        payload = expression int (Helper PresentValue [value])
        guard = expression boolean (Helper IsPresent [value])
        condition = operation Equal payload (number int 0)
    validateDefinitions 64 [] [definition "safe" [("x",ty)]
      (expression boolean (ShortCircuit And guard condition))] `shouldSatisfy` isRight
    validateDefinitions 64 [] [definition "unsafe" [("x",ty)] payload] `shouldSatisfy` isLeft
  it "accepts safe promotions and constant conversions, rejecting unchecked narrowing" $ do
    let convert ty value = expression ty (Convert CheckedArgument ty value)
    validateDefinitions 64 [] [definition "promote" [("x",int)] (convert integer (local "x" int))]
      `shouldSatisfy` isRight
    validateDefinitions 64 [] [definition "literal" [] (convert int (number integer 127))]
      `shouldSatisfy` isRight
    validateDefinitions 64 [] [definition "narrow" [("x",integer)] (convert int (local "x" integer))]
      `shouldSatisfy` isLeft
  it "does not accept duplicate declarations or invalid machine profiles" $ do
    let size = lengthDef (call "length" [local "tail" list])
    validateDefinitions 64 [] [size,size] `shouldSatisfy` isLeft
    validateDefinitions 16 [] [size] `shouldSatisfy` isLeft
