module TotalSpec (spec) where

import Test.Hspec
import Data.Either (isLeft, isRight)
import LawSpec.Core
import LawSpec.Core.Total
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Frontend (compileCore)
import LawSpec.Common (Source(..), Artifact(..), defaultGeneration, ownership)
import Data.List (isInfixOf)
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

spec :: Spec
spec = describe "checked Core total definitions" $ do
  it "executes arithmetic justified by a matched field's primitive domain" $ do
    let source = Source "fields.lawspec" $ unlines
          ["unit fields"
          ,"definition first (xs :: List Int8) :: Rational is match xs with | Nil -> 0 | Cons head tail -> 1 / (head + 129) end end"
          ,"law `nonnegative` is definition is `for all` (xs :: List Int8) . first xs >= 0 end end"]
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
            mapM_ (\n -> invoke (Id "fields::first") [singleton n]
              `shouldBe` Right (V.ScalarValue (SRational 1 (n + 129)))) [-128..127]
        mapM_ (\target -> (planTesting program >>= emitPlan target) `shouldSatisfy` isRight) targets) [32,64]
  it "executes guarded narrowing for every Int8 value under both profiles" $ do
    let source = Source "narrow.lawspec" $ unlines
          ["unit narrow"
          ,"definition next (x :: Int8) :: Bool is x < 127 && prelude.Int8 (x + 1) > x end"
          ,"law `range` is definition is `for all` (x :: Int8) . next x = (x < 127) end end"]
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
          ["unit affine"
          ,"definition reciprocal (x :: Int8) :: Bool is x >= 0 && 1 / (x + 1) > 0 end"
          ,"law `sign` is definition is `for all` (x :: Int8) . reciprocal x = (x >= 0) end end"]
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
          ["unit total"
          ,"definition size (xs :: List Int8) :: BigInt is"
          ,"  match xs with | Nil -> 0 | Cons head tail -> 1 + size tail end"
          ,"end"
          ,"law `length` is definition is `for all` (xs :: List Int8) . size xs = prelude.length xs end end"]
    mapM_ (\bits -> case compileCore bits defaultGeneration [source] >>= prepareDefinitions of
      Left ds -> expectationFailure (show ds)
      Right invoke -> do
        let nil = V.DataValue list (Id "List::Nil") []
            values = foldr (\n tailValue -> V.DataValue list (Id "List::Cons")
              [V.ScalarValue (SInteger "Int8" n), tailValue]) nil [1,2,3]
        invoke (Id "total::size") [values] `shouldBe` Right (V.ScalarValue (SInteger "BigInt" 3))
        invoke (Id "total::size") [nil] `shouldBe` Right (V.ScalarValue (SInteger "BigInt" 0))
        invoke (Id "total::size") [] `shouldSatisfy` isLeft
        invoke (Id "total::size") [V.ScalarValue (SBool True)] `shouldSatisfy` isLeft
        invoke (Id "adapter") [] `shouldSatisfy` isLeft) [32,64]
  it "checks unused source definitions, including recursion and partial bodies" $ do
    let check body = compileCore 64 defaultGeneration [Source "total.lawspec" ("unit total\n" ++ body)]
    mapM_ (\body -> check body `shouldSatisfy` isLeft)
      ["definition bad (xs :: List Int8) :: BigInt is bad xs end"
      ,"definition bad (xs :: List Int8) :: BigInt is match xs with | Nil -> 0 end end"
      ,"definition bad (x :: BigInt) :: Rational is 1 / x end"
      ,"definition bad (x :: Int8) (x :: Int8) :: Int8 is x end"
      ,"adapter :: Int8 -> Int8\ndefinition bad (x :: Int8) :: Int8 is adapter x end"
      ,"definition f (x :: Int8) :: Int8 is g x end\ndefinition g (x :: Int8) :: Int8 is f x end"
      ,"definition bad (x :: Int8) :: Bool is x end"
      ,"definition bad (x :: Int8 where x >= 0) :: Rational is 1 / x end"]
  it "qualifies custom constructors and evaluates forward definition calls" $ do
    let source = Source "tree.lawspec" $ unlines
          ["unit tree"
          ,"type Tree is Leaf value :: Int8 | Branch children :: List Tree end"
          ,"definition root (t :: Tree) :: Int8 is get t end"
          ,"definition get (t :: Tree) :: Int8 is match t with | Leaf x -> x | Branch xs -> 0 end end"]
    case compileCore 64 defaultGeneration [source] >>= prepareDefinitions of
      Left ds -> expectationFailure (show ds)
      Right invoke -> invoke (Id "tree::root")
        [V.DataValue (Constructor "tree::type::Tree" []) (Id "tree::type::Tree::Leaf")
          [V.ScalarValue (SInteger "Int8" 127)]] `shouldBe` Right (V.ScalarValue (SInteger "Int8" 127))
  it "preserves lexical parameter shadowing over function names" $ do
    let source = Source "shadow.lawspec" $ unlines
          ["unit shadow", "x :: Bool -> Bool", "definition identity (x :: Int8) :: Int8 is x end"]
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
    let source = Source "total.lawspec" "unit total\ndefinition identity (x :: Int8) :: Int8 is x end"
    case compileCore 64 defaultGeneration [source] >>= planTesting of
      Left ds -> expectationFailure (show ds)
      Right plan -> mapM_ (\target -> case emitPlan target plan of
        Left ds -> expectationFailure (target ++ ": " ++ show ds)
        Right files -> concatMap artifactContent [f | f <- files, ownership f == "user"]
          `shouldNotSatisfy` isInfixOf "identity") targets
  it "emits Rust definitions as generated source with typed native entry points" $ do
    let source = Source "total.lawspec" "unit total\ndefinition identity (x :: Int8) :: Int8 is x end"
    case compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "rust" of
      Left ds -> expectationFailure (show ds)
      Right files -> do
        let sourceFiles = [file | file <- files, artifactPath file == "src/lawspec_definitions.rs"]
        length sourceFiles `shouldBe` 1
        map ownership sourceFiles `shouldBe` ["generated"]
        map artifactPlacement sourceFiles `shouldBe` ["source"]
        concatMap artifactContent sourceFiles `shouldSatisfy` isInfixOf "pub fn identity(ctx: &mut ls::Context, value0: i8) -> ls::Result<i8>"
        concatMap artifactContent [f | f <- files, ownership f == "user"]
          `shouldNotSatisfy` isInfixOf "pub fn identity"
  it "emits Java definitions with native entry points and checked support" $ do
    let source = Source "total.lawspec" "unit total\ndefinition identity (x :: Int8) :: Int8 is x end"
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
    let total = Source "total.lawspec" "unit example.total\ndefinition identity (x :: Int8) :: Int8 is x end"
    mapM_ (\unit -> (compileCore 64 defaultGeneration
        [total,Source "collision.lawspec" ("unit " ++ unit ++ "\necho :: Bool -> Bool")]
        >>= planTesting >>= emitPlan "java") `shouldSatisfy` isLeft)
      ["lawspec.runtime.law_spec_definition_bodies","lawspec.definitions.example.total"]
  it "emits Kotlin definitions with native generics and shared JVM bodies" $ do
    let source = Source "total.lawspec" "unit total\ndefinition identity (x :: Optional (Nullable Int8)) :: Optional (Nullable Int8) is x end"
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
    let total = Source "total.lawspec" "unit example.total\ndefinition identity (x :: Int8) :: Int8 is x end"
    mapM_ (\unit -> (compileCore 64 defaultGeneration
        [total,Source "collision.lawspec" ("unit " ++ unit ++ "\necho :: Bool -> Bool")]
        >>= planTesting >>= emitPlan "kotlin") `shouldSatisfy` isLeft)
      ["lawspec.runtime.law_spec_definition_bodies","lawspec.definitions.example.total"]
  it "emits Python definitions as typed generated source without adapter stubs" $ do
    let source = Source "total.lawspec" "unit total\ndefinition identity (x :: List Int8) :: List Int8 is x end"
    case compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "python" of
      Left ds -> expectationFailure (show ds)
      Right files -> do
        let native = [f | f <- files, artifactPath f == "src/lawspec_definitions/total.py"]
            bodies = [f | f <- files, artifactPath f == "src/lawspec_definition_bodies.py"]
        length native `shouldBe` 1
        length bodies `shouldBe` 1
        map ownership (native ++ bodies) `shouldBe` ["generated","generated"]
        map artifactPlacement (native ++ bodies) `shouldBe` ["source","source"]
        concatMap artifactContent native `shouldSatisfy` isInfixOf "value_0: _builtins.list[_builtins.int]"
        concatMap artifactContent [f | f <- files, ownership f == "user"]
          `shouldNotSatisfy` isInfixOf "def identity"
  it "rejects Python definition support and module/package name collisions" $ do
    let total = Source "total.lawspec" "unit example.total\ndefinition identity (x :: Int8) :: Int8 is x end"
    mapM_ (\unit -> (compileCore 64 defaultGeneration
        [total,Source "collision.lawspec" ("unit " ++ unit ++ "\necho :: Bool -> Bool")]
        >>= planTesting >>= emitPlan "python") `shouldSatisfy` isLeft)
      ["lawspec_definitions", "lawspec_definition_bodies", "example", "example.total.child"]
    mapM_ (\name -> (compileCore 64 defaultGeneration [Source "collision.lawspec"
        ("unit total\ndefinition " ++ name ++ " (x :: Int8) :: Int8 is x end")]
        >>= planTesting >>= emitPlan "python") `shouldSatisfy` isLeft) ["_definitions", "_lawspec_schema"]
  it "emits JS/TS definitions as generated source with native typed TypeScript APIs" $ do
    let source = Source "total.lawspec" "unit total\ndefinition identity (x :: List Int8) :: List Int8 is x end"
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
          concatMap artifactContent native `shouldSatisfy` isInfixOf "value0: Array<number>"
          concatMap artifactContent (native ++ bodies) `shouldNotSatisfy` isInfixOf "@ts-nocheck"
        else pure ()) [("javascript","mjs"),("typescript","ts")]
  it "rejects JS/TS definition support collisions and shadowed globals" $ do
    let total = Source "total.lawspec" "unit example.total\ndefinition identity (x :: Int8) :: Int8 is x end"
    mapM_ (\target -> do
      mapM_ (\unit -> (compileCore 64 defaultGeneration
          [total,Source "collision.lawspec" ("unit " ++ unit ++ "\necho :: Bool -> Bool")]
          >>= planTesting >>= emitPlan target) `shouldSatisfy` isLeft)
        ["lawspec_definitions.example.total", "lawspec_definition_bodies"]
      mapM_ (\name -> (compileCore 64 defaultGeneration [Source "collision.lawspec"
          ("unit total\ndefinition " ++ name ++ " (x :: Int8) :: Int8 is x end")]
          >>= planTesting >>= emitPlan target) `shouldSatisfy` isLeft) ["globalThis", "eval", "arguments"])
      ["javascript","typescript"]
  it "emits Go native definition methods without colliding with data type names" $ do
    let source = Source "total.lawspec" $ unlines
          ["unit total", "type Identity is Identity value :: Int8 end"
          ,"definition identity (x :: Identity) :: Identity is x end"]
    case compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "go" of
      Left ds -> expectationFailure (show ds)
      Right files -> do
        let native = [f | f <- files, artifactPath f == "total/lawspec_definitions.go"]
        length native `shouldBe` 1
        map ownership native `shouldBe` ["generated"]
        map artifactPlacement native `shouldBe` ["source"]
        concatMap artifactContent native `shouldSatisfy` isInfixOf "func (lawSpecDefinitions) Identity"
        concatMap artifactContent native `shouldSatisfy` isInfixOf "value0 Identity"
        concatMap artifactContent [f | f <- files, ownership f == "user"]
          `shouldNotSatisfy` isInfixOf "func Identity"
  it "does not emit Go definition source into an unused empty unit" $ do
    let sources = [Source "empty.lawspec" "unit empty", Source "total.lawspec"
          "unit total\ndefinition identity (x :: Int8) :: Int8 is x end"]
    case compileCore 64 defaultGeneration sources >>= planTesting >>= emitPlan "go" of
      Left ds -> expectationFailure (show ds)
      Right files -> map artifactPath files `shouldNotSatisfy` elem "empty/lawspec_definitions.go"
  it "emits Haskell native definitions with a scoped Symbol context" $ do
    let source = Source "total.lawspec" $ unlines
          ["unit total", "definition identity (x :: Int8) :: Int8 is x end"
          ,"definition schema (x :: Bool) :: Bool is x end"
          ,"definition bits (x :: Bool) :: Bool is x end"]
    case compileCore 64 defaultGeneration [source] >>= planTesting >>= emitPlan "haskell" of
      Left ds -> expectationFailure (show ds)
      Right files -> do
        let native = [f | f <- files, artifactPath f == "src/LawSpecDefinitions/Total.hs"]
        length native `shouldBe` 1
        map ownership native `shouldBe` ["generated"]
        map artifactPlacement native `shouldBe` ["source"]
        concatMap artifactContent native `shouldSatisfy` isInfixOf "LS.SymbolContext"
        concatMap artifactContent native `shouldSatisfy` isInfixOf "P.Either P.String (I.Int8)"
        concatMap artifactContent native `shouldSatisfy` isInfixOf "_lawspecSchema"
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
