-- | Typed native definitions: which definitions run typed, how copies share a
-- body, and what the Rust, Go and JVM emitters make of them.
module TypedSpec (test_typedDefinitionsRunNativeWithTheirMeaning) where

import Data.List (isInfixOf)
import qualified Data.Map.Strict as M
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Typed.Plan (TypedPlan(..), typedPlan, sharedDefinitions, isTypedHandler)
import LawSpec.Typed.Rust (RustTyped(..), emitRustTyped)
import LawSpec.Typed.Go (GoTyped(..), emitGoTyped)
import LawSpec.Typed.Jvm (JvmTyped(..), JvmStyle(..), emitJvmTyped)
import qualified LawSpec.Code.Doc as D

ledger :: String
ledger = unlines
  [ "unit example.ledger"
  , ""
  , "type Account is Account owner :: Text balance :: Int64 end"
  , ""
  , "definition credit (name :: Text) (amount :: Int64) (book :: KeyVal Text Account) :: KeyVal Text Account is"
  , "  match prelude.lookup name book with"
  , "  | Nothing -> prelude.put name (Account name amount) book"
  , "  | Just a -> book"
  , "  end"
  , "end"
  , ""
  , "definition total (xs :: List Int64) (acc :: Integer) :: Integer is"
  , "  match xs with"
  , "  | Nil -> acc"
  , "  | Cons h t -> total t (acc + h)"
  , "  end"
  , "end"
  , ""
  , "definition half (x :: Float64) :: Float64 is x / 2.0 end"
  , ""
  , "definition current (b :: Maybe (KeyVal Text Account)) :: KeyVal Text Account is"
  , "  match b with | Nothing -> prelude.keyValOf [] | Just k -> k end"
  , "end"
  , ""
  , "ability Bank is"
  , "  deposit :: Text -> Int64 -> Int64"
  , "end"
  , ""
  , "handler books for Bank with state book :: Maybe (KeyVal Text Account) start Nothing is"
  , "  deposit name amount is ~book := Just (credit name amount (current book)); amount end"
  , "end" ]

consumer :: String
consumer = unlines
  [ "unit example.consumer"
  , ""
  , "import example.ledger as ledger"
  , ""
  , "definition twice (name :: Text) (book :: KeyVal Text ledger.Account) :: KeyVal Text ledger.Account is"
  , "  ledger.credit name 1 (ledger.credit name 1 book)"
  , "end" ]

program :: Either String C.Program
program = either (Left . show) Right
  (compileCore 64 defaultGeneration [Source "ledger.lawspec" ledger, Source "consumer.lawspec" consumer])

named :: C.Program -> String -> [C.Id]
named p name = [ C.declarationId (C.definitionDeclaration d) | u <- C.programUnits p, d <- C.unitDefinitions u
               , C.declarationName (C.definitionDeclaration d) == name ]

withProgram :: (C.Program -> Expectation) -> Expectation
withProgram check = either expectationFailure check program

-- | A reference model must be fast enough to serve as a runtime, so its
-- definitions and handlers run typed where their values have a typed form,
-- and stay dynamic, unchanged, where they do not. ref:DEC-typed-native-definitions
test_typedDefinitionsRunNativeWithTheirMeaning :: Spec
test_typedDefinitionsRunNativeWithTheirMeaning = describe "typed definitions" $ do
  it "types definitions over text, bounded integers, Integer, lists, KeyVal and data" $ withProgram $ \p -> do
    let plan = typedPlan (C.programDataDeclarations p) (C.programUnits p)
    all (`M.member` typedDefinitions plan) (named p "credit" ++ named p "total") `shouldBe` True
  it "keeps a definition over Float64 dynamic" $ withProgram $ \p -> do
    let plan = typedPlan (C.programDataDeclarations p) (C.programUnits p)
    any (`M.member` typedDefinitions plan) (named p "half") `shouldBe` False
  it "types a stateful handler whose state and clauses are typed" $ withProgram $ \p -> do
    let plan = typedPlan (C.programDataDeclarations p) (C.programUnits p)
    -- The handler, and the importing unit's copy of it.
    let handlers = [isTypedHandler plan h | u <- C.programUnits p, h <- C.unitHandlers u]
    (not (null handlers) && and handlers) `shouldBe` True
  it "shares one body between a definition and an import's copy of it" $ withProgram $ \p -> do
    let shared = sharedDefinitions (C.programUnits p)
        originals = named p "credit"
        copies = [ C.declarationId (C.definitionDeclaration d) | u <- C.programUnits p, d <- C.unitDefinitions u
                 , "Credit" `isInfixOf` C.declarationName (C.definitionDeclaration d) ]
    not (null copies) `shouldBe` True
    [M.lookup c shared | c <- copies] `shouldBe` map (const (Just (head originals))) copies
  it "emits Rust whose maps are persistent and whose self tail calls loop" $ withProgram $ \p ->
    case emitRustTyped (C.programDataDeclarations p) (C.programUnits p) of
      Left e -> expectationFailure e
      Right typed -> do
        let source = D.render D.Compact (rustTypedModule typed)
        source `shouldSatisfy` isInfixOf "ls::fast::Map<ls::fast::Text, Account>"
        source `shouldSatisfy` isInfixOf "loop"
        source `shouldSatisfy` isInfixOf ".insert("
  it "emits Go and Java for the same definitions" $ withProgram $ \p -> do
    let declarations = C.programDataDeclarations p
        units = C.programUnits p
    case emitGoTyped declarations units of
      Left e -> expectationFailure e
      Right typed -> case goTypedSource typed "ledger" (named p "credit" ++ named p "total") [] of
        Left e -> expectationFailure e
        Right source -> do
          source `shouldSatisfy` isInfixOf "lsfPut("
          source `shouldSatisfy` isInfixOf "for {"
    case emitJvmTyped JavaStyle declarations units of
      Left e -> expectationFailure e
      Right typed -> do
        jvmTypedSource typed `shouldSatisfy` isInfixOf "public static final class Account"
        jvmTypedSource typed `shouldSatisfy` isInfixOf "while (true)"
