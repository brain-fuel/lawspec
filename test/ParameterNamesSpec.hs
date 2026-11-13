-- | The names generated code gives an adapter's parameters.
module ParameterNamesSpec (test_generatedParametersTakeTheirSignaturesNames) where

import Control.Monad (forM_)
import Data.Aeson (Value(..), object, (.=), decode, encode)
import qualified Data.Aeson.KeyMap as K
import Data.Foldable (toList)
import Data.Char (isAlphaNum, toLower)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import LawSpec.Targets (programTargets)
import Data.Maybe (isJust)
import qualified Data.Text as T
import Test.Hspec
import qualified LawSpec.Api as API
import LawSpec.Builtins (defaultedUnits)
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.CoreEmit (emitPlanWithOptions)
import LawSpec.Dependencies (Identity(..), Ref(..), dependencyGraph, nodeIdentity)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Naming
import LawSpec.Testing (planTesting)
import LawSpec.Search (lawDescriptors)
import qualified LawSpec.Core.Smt as Smt

int32, text, order, orderLine :: C.Type
int32 = C.scalarType "Int32"
text = C.scalarType "Text"
order = C.Constructor "example.shop::type::Order" []
orderLine = C.Constructor "example.shop::type::OrderLine" []

listOf, maybeOf :: C.Type -> C.Type
listOf t = C.Constructor "List" [C.TypeArgument t]
maybeOf t = C.Constructor "Maybe" [C.TypeArgument t]

declared :: [Maybe String] -> C.ParameterNames
declared = C.DeclaredParameters

-- | One unit with an adapter that names its parameters and one that does
-- not, or the same unit with neither named.
adapters :: Bool -> String
adapters named = unlines
  [ "unit example.named"
  , ""
  , if named then "add :: (a :: Int32) -> (b :: Int32) -> Int32" else "add :: Int32 -> Int32 -> Int32"
  , "plus :: Int32 -> Int32 -> Int32"
  , ""
  , "law \"|add commutes| is"
  , "  definition : for all (x :: Int32) (y :: Int32) => add x y = add y x end for all end definition"
  , "end law"
  , ""
  , "law \"|plus commutes| is"
  , "  definition : for all (x :: Int32) (y :: Int32) => plus x y = plus y x end for all end definition"
  , "end law"
  , "end unit" ]

program :: Bool -> C.Program
program named = either (error . show) id (compileCore 64 defaultGeneration [Source "named.lawspec" (adapters named)])

-- | A unit that imports every built-in unit with abilities.
builtins :: C.Program
builtins = either (error . show) id (compileCore 64 defaultGeneration
  [Source "everything.lawspec" (unlines (["unit example.everything", ""] ++ ["import " ++ unit | unit <- defaultedUnits] ++ ["end unit"]))])

-- | The built-in abilities' operations whose signature leaves a parameter
-- unnamed.
unnamedBuiltinOperations :: [String]
unnamedBuiltinOperations =
  [ C.abilityName a ++ "." ++ operation
  | u <- C.programUnits builtins, a <- C.unitAbilities u, "lawspec." `isPrefixOf` C.idText (C.abilityOwner a)
  , (operation, t) <- C.abilityOperations a
  , let arity = length (fst (C.functionType t))
  , case C.operationParameters a operation of
      C.DeclaredParameters names -> length names /= arity || not (all isJust names)
      C.PositionalParameters -> True ]

-- | Everything a target generates for the built-in units.
builtinOutput :: String -> String
builtinOutput target = case planTesting builtins >>= emitPlanWithOptions False target Nothing Nothing of
  Left problems -> error (target ++ ": " ++ show problems)
  Right files -> concatMap artifactContent files

-- | The positional identifiers generated code may still write, each with
-- its reason (DEC-generated-parameter-names). Anything else fails the guard.
allowedPositional :: String -> String -> String -> Bool
allowedPositional target path found = or
  -- Rust binds a call's arguments, and a constructor's fields where the
  -- constructor is not a declared one, to temporaries in evaluation order
  -- before the call borrows the context. The expression renderer knows the
  -- callee only by its native name.
  [ target == "rust" && any (`isPrefixOf` name) ["argument_", "field_"]
  -- A generated Haskell test evaluates a native call's arguments in a let
  -- before the call. Haskell's let is recursive, so a declared name there
  -- could capture the law's own variable of that name.
  , target == "haskell" && "Spec.hs" `isSuffixOf` path && "argument" `isPrefixOf` name ]
  where name = takeWhile (/= ' ') found

-- | The specs the positional-name guard emits on every target.
guardCorpus :: [String]
guardCorpus = words "abilities contracts builtins actors models records data_types workflows sessions currying collections crypto failures resources"

-- | Identifiers that number a stem by position (value0, input_1, Argument2,
-- codec3, field0) in a text, in order of appearance.
positionalIdentifiers :: String -> [String]
positionalIdentifiers = filter positional . identifiers
  where
    identifiers text = case dropWhile (not . word) text of
      [] -> []
      rest -> let (token, more) = span word rest in token : identifiers more
    word c = isAlphaNum c || c == '_'
    positional token = any (numbered (map toLower token)) ["value", "input", "argument", "field", "codec", "arg"]
    numbered token stem = case splitAt (length stem) token of
      -- A positional series starts at 0 or 1; a clash is numbered from 2
      -- (value_2, state2) and is no position.
      (start, digits) | start == stem -> dropWhile (== '_') digits `elem` ["0", "1"]
      _ -> False

-- | What a target generates for a spec of the corpus, without the runtime's
-- hand-written sources: each file's path and its positional identifiers.
positionalIn :: String -> String -> IO [(String, [String])]
positionalIn target spec = do
  source <- readFile ("examples/specs/" ++ spec ++ ".lawspec")
  pure $ case compileCore 64 defaultGeneration [Source (spec ++ ".lawspec") source] >>= planTesting >>= emitPlanWithOptions False target Nothing Nothing of
    Left _ -> []
    Right files -> [ (artifactPath f, [name ++ " in `" ++ take 110 (dropWhile (== ' ') line) ++ "`" | (name, line) <- found])
                   | f <- files
                   , let found = firsts [(name, line) | line <- lines (artifactContent f), name <- positionalIdentifiers line]
                   , not (null found) ]
  where firsts pairs = [(name, line) | name <- sort (nub (map fst pairs)), line <- take 1 [l | (n, l) <- pairs, n == name]]

-- | An ability whose operation takes and gives refined values, so every
-- handler owes a generated law about it; the law's quantifier takes the
-- parameter's name.
refinedOperation :: String -> C.Program
refinedOperation parameter = either (error . show) id (compileCore 64 defaultGeneration [Source "meter.lawspec" (unlines
  [ "unit example.meter"
  , ""
  , "ability Meter is scale :: (" ++ parameter ++ " :: Int32 where " ++ parameter ++ " >= 0) -> (r :: Int32 where r >= 0) end ability"
  , "handler fixedMeter for Meter is operation scale k is 7 end operation end handler"
  , "end unit" ])])

-- | The generated laws of refinedOperation: the names of their inputs, and
-- everything a receipt, a cache or the failure database knows them by.
refinedLawIdentities :: C.Program -> ([String], [(String, String, [String])], [(String, String, String, String)])
refinedLawIdentities p =
  ( [C.binderName (C.quantifiedBinder q) | l <- laws, q <- C.propertyInputs l]
  , [(C.idText (C.propertyId l), C.propertyName l, maybe [] id (lawDescriptors 64 (C.programDataDeclarations p) l)) | l <- laws]
  , [ (C.idText (Smt.taskLaw t), Smt.taskProgram t, Smt.taskFingerprint t, either id id (Smt.taskQuery t))
    | t <- either (error . show) id (Smt.proofTasks p), C.idText (Smt.taskLaw t) `elem` map (C.idText . C.propertyId) laws ] )
  where laws = [l | u <- C.programUnits p, l <- C.unitProperties u, "gives what its type says" `isInfixOf` C.propertyName l]

-- | The user-owned stubs of a target, and their canonical references.
stubs :: Bool -> String -> (String, String)
stubs named target = case planTesting (program named) >>= emitPlanWithOptions False target Nothing Nothing of
  Left problems -> error (target ++ ": " ++ show problems)
  Right files -> ( concat [artifactContent f | f <- files, ownership f == "user"]
                 , concat [reference | f <- files, ownership f == "user", Just reference <- [adapterReference f]] )

-- | What each target's stub writes for add's declared names and plus's
-- type-derived ones.
expected :: [(String, String, String)]
expected =
  [ ("java", "add(int a, int b)", "plus(int int32_1, int int32_2)")
  , ("groovy", "add(int a, int b)", "plus(int int32_1, int int32_2)")
  , ("clojure", "[a b]", "[int32-1 int32-2]")
  , ("kotlin", "fun add(a: kotlin.Int, b: kotlin.Int)", "fun plus(int32_1: kotlin.Int, int32_2: kotlin.Int)")
  , ("scala", "def add(a: scala.Int, b: scala.Int)", "def plus(int32_1: scala.Int, int32_2: scala.Int)")
  , ("python", "def add(a: int, b: int)", "def plus(int32_1: int, int32_2: int)")
  , ("javascript", "function add(a, b)", "function plus(int32_1, int32_2)")
  , ("typescript", "function add(a: number, b: number)", "function plus(int32_1: number, int32_2: number)")
  , ("go", "func Add(a int32, b int32)", "func Plus(int32_1 int32, int32_2 int32)")
  , ("rust", "pub fn add(a: i32, b: i32)", "pub fn plus(int32_1: i32, int32_2: i32)")
  , ("haskell", "add _a _b =", "plus _int32_1 _int32_2 =")
  , ("fsharp", "let add (a: int) (b: int)", "let plus (int32_1: int) (int32_2: int)")
  , ("csharp", "Add(int a, int b)", "Plus(int int32_1, int int32_2)")
  , ("swift", "func add(_ a: Int32, _ b: Int32)", "func plus(_ int32_1: Int32, _ int32_2: Int32)")
  , ("erlang", "add(_A, _B)", "plus(_Int32_1, _Int32_2)")
  , ("elixir", "def add(_a, _b)", "def plus(_int32_1, _int32_2)")
  , ("gleam", "pub fn add(_a: Int, _b: Int)", "pub fn plus(_int32_1: Int, _int32_2: Int)")
  , ("prolog", "ls_add(_A, _B, _)", "ls_plus(_Int32_1, _Int32_2, _)") ]

-- | The completeness row of a claims block, from the API.
completeness :: String -> Maybe String
completeness signature = case decode (API.dispatch (encode (object
    [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("check" :: String)
    , "verification" .= object ["layers" .= ["exhaustive" :: String]]
    , "sources" .= [object ["path" .= ("orders.lawspec" :: String), "content" .= source]] ]))) of
  Just (Object response) | Just (Array rows) <- K.lookup "evidence" response ->
    case [T.unpack why | Object row <- toList rows, K.lookup "stage" row == Just (String "completeness"), Just (String why) <- [K.lookup "reason" row]] of
      why : _ -> Just why
      [] -> Nothing
  _ -> Nothing
  where
    source = unlines
      [ "unit claims.orders\n"
      , "type State is one of | Pending | Shipped | Cancelled end type\n"
      , signature ++ "\n"
      , "law \"|pending orders ship| is"
      , "  definition: for all (state :: State) => state = Pending implies next state = Shipped end for all end definition"
      , "end law\n"
      , "law \"|shipped orders stay| is"
      , "  definition: for all (state :: State) => state = Shipped implies next state = Shipped end for all end definition"
      , "end law\n"
      , "laws for next are"
      , "end laws\n"
      , "end unit" ]

-- | A signature's parameter names reach generated code on every target,
-- and never an adapter's identity or its canonical reference.
-- ref:DEC-generated-parameter-names
test_generatedParametersTakeTheirSignaturesNames :: Spec
test_generatedParametersTakeTheirSignaturesNames = describe "generated parameter names" $ do
  describe "the shared naming function" $ do
    it "keeps a declared name and numbers unnamed parameters by their type, from 1" $
      parameterWords (declared [Just "a", Nothing]) [int32, int32, int32, text]
        `shouldBe` [DeclaredName "a", TypeDerivedName ["int32"] 1, TypeDerivedName ["int32"] 2, TypeDerivedName ["text"] 1]
    it "numbers a sole unnamed parameter of its type too" $
      parameterNames "python" [] "value" C.unnamedParameters [int32] `shouldBe` ["int32_1"]
    it "names a compound type by its head" $ do
      parameterNames "python" [] "value" C.unnamedParameters [listOf text, maybeOf order, order, listOf int32]
        `shouldBe` ["list_1", "maybe_1", "order_1", "list_2"]
      typeHeadWords (C.scalarType "UInt32") `shouldBe` ["uint32"]
      typeHeadWords (C.scalarType "BigUInt") `shouldBe` ["whole"]
      typeHeadWords (C.Arrow int32 int32) `shouldBe` ["function"]
      typeHeadWords (C.TypeVariable (C.Id "f::a")) `shouldBe` ["value"]
      typeHeadWords (C.Constructor "lawspec::structural::0123456789abcdef" []) `shouldBe` ["record"]
    it "cases a type-derived name as the target cases a value, and joins its number as the casing joins a word" $ do
      parameterNames "python" [] "value" C.unnamedParameters [orderLine, text, int32] `shouldBe` ["order_line_1", "text_1", "int32_1"]
      parameterNames "clojure" [] "value" C.unnamedParameters [orderLine, text, int32] `shouldBe` ["order-line-1", "text-1", "int32-1"]
      -- camelCase has no separator; an underscore only keeps two numbers apart.
      parameterNames "java" [] "value" C.unnamedParameters [orderLine, text, int32] `shouldBe` ["orderLine1", "text1", "int32_1"]
      parameterNamesWith Pascal id [] "value" C.unnamedParameters [orderLine, text, int32] `shouldBe` ["OrderLine1", "Text1", "Int32_1"]
    it "cases a declared name as the target cases a value" $ do
      parameterNames "java" [] "value" (declared [Just "order_id"]) [text] `shouldBe` ["orderId"]
      parameterNames "python" [] "value" (declared [Just "orderId"]) [text] `shouldBe` ["order_id"]
      parameterNames "clojure" [] "value" (declared [Just "orderId"]) [text] `shouldBe` ["order-id"]
      parameterNamesWith Pascal id [] "value" (declared [Just "order_id"]) [text] `shouldBe` ["OrderId"]
    it "escapes a reserved word the target's own way" $ do
      parameterNames "java" [] "value" (declared [Just "class"]) [text] `shouldBe` ["class_"]
      parameterNames "python" [] "value" (declared [Just "lambda"]) [text] `shouldBe` ["lambda_"]
      parameterNames "python" [] "value" (declared [Just "list"]) [text] `shouldBe` ["list_"]
      parameterNames "rust" [] "value" (declared [Just "type"]) [text] `shouldBe` ["r#type"]
      parameterNames "kotlin" [] "value" (declared [Just "object"]) [text] `shouldBe` ["object_"]
      parameterNames "go" [] "value" (declared [Just "class"]) [text] `shouldBe` ["class"]
    it "keeps names clear of each other and of the names taken, in order" $ do
      parameterNames "java" [] "value" (declared [Just "order_id", Just "orderId"]) [text, text] `shouldBe` ["orderId", "orderId2"]
      parameterNames "python" [] "value" (declared [Just "int32_1", Nothing]) [text, int32] `shouldBe` ["int32_1", "int32_1_2"]
      parameterNames "java" ["gateway"] "value" (declared [Just "gateway"]) [text] `shouldBe` ["gateway2"]
      parameterNames "python" ["gateway"] "value" (declared [Just "gateway"]) [text] `shouldBe` ["gateway_2"]
      parameterNames "clojure" [] "value" (declared [Just "order_id", Just "orderId"]) [text, text] `shouldBe` ["order-id", "order-id-2"]
    it "ignores a name with no usable words" $
      parameterNames "java" [] "value" (declared [Just "\955"]) [text] `shouldBe` ["text1"]
    it "writes the reference spelling by position, whatever is taken" $ do
      parameterNames "java" ["value0"] "value" C.PositionalParameters [int32, text] `shouldBe` ["value0", "value1"]
      take 2 (positionalNames "argument") `shouldBe` ["argument0", "argument1"]
    it "shows names as the spec writes them in text about a law" $
      sourceParameterNames (declared [Just "orderId", Nothing]) [text, int32] `shouldBe` ["orderId", "int32_1"]
    it "names a handler parameter after its ability" $ do
      let ref name = C.AbilityRef (C.Id ("example.shop::ability::" ++ name)) []
      handlerParameterNames "java" [] [ref "Clock", ref "AuditLog"] `shouldBe` ["clock", "auditLog"]
      handlerParameterNames "python" ["clock"] [ref "Clock", ref "AuditLog"] `shouldBe` ["clock_2", "audit_log"]
  describe "the built-in abilities" $ do
    it "name every parameter in their signatures" $
      unnamedBuiltinOperations `shouldBe` []
    forM_
      [ ("java", ["void sleep(java.time.Duration duration)", "void writeBytes(java.lang.String path, byte[] contents)"])
      , ("python", ["def sleep(self, duration: ", "def logMessage(self, level: "])
      , ("typescript", ["sleep(duration: data.Duration): void", "constructor(verifyingKey: VerifyingKey, signingKey: SigningKey)"])
      , ("go", ["Sleep(duration "])
      , ("rust", ["fn sleep(&self, duration: "])
      , ("kotlin", ["fun sleep(duration: "])
      , ("scala", ["def sleep(duration: "]) ] $ \(target, signatures) ->
      it ("give " ++ target ++ " interfaces those names, and no positional one") $ do
        let output = builtinOutput target
        forM_ signatures $ \signature -> output `shouldSatisfy` isInfixOf signature
        output `shouldNotSatisfy` isInfixOf "value0"
  describe "positional names in generated code" $
    forM_ programTargets $ \target -> it (target ++ " writes none outside the allowlist") $ do
      found <- concat <$> mapM (\spec -> map ((,) spec) <$> positionalIn target spec) guardCorpus
      let offending = [ spec ++ " " ++ path ++ ": " ++ name | (spec, (path, names)) <- found, name <- names
                      , not (allowedPositional target path name) ]
      offending `shouldBe` []
  describe "a generated law's quantifier names" $
    it "change no law identity, proof task or receipt binding" $ do
      let (namesN, lawsN, tasksN) = refinedLawIdentities (refinedOperation "n")
          (namesM, lawsM, tasksM) = refinedLawIdentities (refinedOperation "amount")
      namesN `shouldSatisfy` elem "n"
      namesM `shouldSatisfy` elem "amount"
      lawsN `shouldNotBe` []
      tasksN `shouldNotBe` []
      lawsM `shouldBe` lawsN
      tasksM `shouldBe` tasksN
  describe "a signature's names in Core" $ do
    it "are kept on the adapter's declaration, without its result's" $ do
      let named = [(C.declarationName d, C.declarationParameters d) | u <- C.programUnits (program True), d <- C.unitDeclarations u]
      lookup "add" named `shouldBe` Just (declared [Just "a", Just "b"])
      lookup "plus" named `shouldBe` Just (declared [Nothing, Nothing])
    it "never change an adapter's or a law's semantic hash" $ do
      let identities p = let graph = dependencyGraph (C.programDataDeclarations p) (C.programUnits p) in
            [ (C.declarationName d, fmap semanticHash (nodeIdentity graph (DeclarationNode (C.declarationId d))))
            | u <- C.programUnits p, d <- C.unitDeclarations u ]
      identities (program True) `shouldBe` identities (program False)
      map snd (identities (program True)) `shouldSatisfy` all (/= Nothing)
  describe "every target's adapter stub" $
    forM_ expected $ \(target, named, derived) -> it target $ do
      let (content, reference) = stubs True target
      content `shouldSatisfy` isInfixOf named
      content `shouldSatisfy` isInfixOf derived
      -- The reference is the positional stub, the same whether or not the
      -- signature names its parameters.
      reference `shouldBe` snd (stubs False target)
      reference `shouldNotSatisfy` isInfixOf named
      reference `shouldNotSatisfy` isInfixOf derived
  it "writes a Java reference with the positional names of earlier releases" $
    snd (stubs True "java") `shouldSatisfy` isInfixOf "add(int value0, int value1)"
  describe "text about an adapter's laws" $ do
    it "shows an input by its declared name" $
      completeness "next :: (current :: State) -> State" `shouldSatisfy` maybe False ("not covered: current = Cancelled" `isInfixOf`)
    it "shows an unnamed input by its type-derived name" $
      completeness "next :: State -> State" `shouldSatisfy` maybe False ("not covered: state_1 = Cancelled" `isInfixOf`)
