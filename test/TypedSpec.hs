-- | Typed native definitions: which definitions run typed, how copies share a
-- body, and what the Rust, Go and JVM emitters make of them.
module TypedSpec (test_typedDefinitionsRunNativeWithTheirMeaning) where

import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as M
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Typed.Plan (TypedPlan(..), typedPlan, typedPlanPerforming, scalarTypes, isContextual, sharedDefinitions, isTypedHandler, typedFallbacks)
import LawSpec.Typed.Python (PythonTyped(..), emitPythonTyped)
import LawSpec.Typed.Web (WebTyped(..), emitWebTyped)
import LawSpec.Typed.Haskell (HaskellTyped(..), emitHaskellTyped)
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
      Right typed -> case goTypedSource typed (\_ _ -> Left "no operation") "ledger" (named p "credit" ++ named p "total") [] of
        Left e -> expectationFailure e
        Right source -> do
          source `shouldSatisfy` isInfixOf "lsfPut("
          source `shouldSatisfy` isInfixOf "for {"
    case emitJvmTyped JavaStyle declarations units of
      Left e -> expectationFailure e
      Right typed -> do
        jvmTypedSource typed `shouldSatisfy` isInfixOf "public static final class Account"
        jvmTypedSource typed `shouldSatisfy` isInfixOf "while (true)"

  describe "typed definitions over failures, sequences and shared handlers" $ do
    let compiled paths = do
          sources <- mapM (\path -> Source path <$> readFile path) paths
          either (\e -> expectationFailure (show e) >> fail "no program") pure (compileCore 64 defaultGeneration sources)
    it "types raise, attempt, the sequence helpers and bounded arithmetic" $ do
      p <- compiled ["examples/specs/sequences.lawspec", "examples/specs/composition.lawspec"]
      let plan = typedPlan (C.programDataDeclarations p) (C.programUnits p)
          -- Bounded arithmetic at the platform-sized types has no typed form.
          platform name = any (`isInfixOf` name) ["IntSize", "UIntSize", "UIntPtr"]
          -- Clients that perform another ability's operations stay dynamic.
          performs why = "it uses " `isPrefixOf` why && not ("Fail" `isInfixOf` why)
      [f | f@(name, why) <- typedFallbacks plan, not (platform name), not (performs why)] `shouldBe` []
    it "types a handler of several abilities with a computed start and failing clauses" $ do
      p <- compiled ["examples/specs/composition.lawspec"]
      let plan = typedPlan (C.programDataDeclarations p) (C.programUnits p)
      [isTypedHandler plan h | u <- C.programUnits p, h <- C.unitHandlers u, C.handlerName h == "store"] `shouldBe` [True]
    it "raises and attempts as the dynamic code does on Rust, Go and the JVM" $ do
      p <- compiled ["examples/specs/composition.lawspec", "examples/specs/sequences.lawspec"]
      let declarations = C.programDataDeclarations p
          units = C.programUnits p
      case emitRustTyped declarations units of
        Left e -> expectationFailure e
        Right typed -> do
          let source = D.render D.Compact (rustTypedModule typed)
          source `shouldSatisfy` isInfixOf "ls::raise_failure("
          source `shouldSatisfy` isInfixOf "ls::fast::octets("
      case emitJvmTyped JavaStyle declarations units of
        Left e -> expectationFailure e
        Right typed -> jvmTypedSource typed `shouldSatisfy` isInfixOf "throw new LawSpecRuntime.Failure("
      case emitGoTyped declarations units of
        Left e -> expectationFailure e
        Right typed -> do
          let ids = [C.declarationId (C.definitionDeclaration d) | u <- units, d <- C.unitDefinitions u]
          case goTypedSource typed (\_ _ -> Right (D.text "lawSpecPerformed()")) "composition" ids [] of
            Left e -> expectationFailure e
            Right source -> source `shouldSatisfy` isInfixOf "panic(&LawSpecFailure{"
    it "types raise and attempt on Python, JavaScript, TypeScript and Haskell" $ do
      p <- compiled ["examples/specs/sequences.lawspec", "examples/specs/composition.lawspec"]
      let declarations = C.programDataDeclarations p
          units = C.programUnits p
      either expectationFailure (\typed -> pyTypedModule typed `shouldSatisfy` isInfixOf "raise ls.Failure(") (emitPythonTyped 64 declarations units)
      either expectationFailure (\typed -> webTypedModule typed `shouldSatisfy` isInfixOf "throw new ls.Failure(") (emitWebTyped False 64 declarations units)
      either expectationFailure (\typed -> webTypedModule typed `shouldSatisfy` isInfixOf "export class") (emitWebTyped True 64 declarations units)
      either expectationFailure (\typed -> hsTypedModule typed `shouldSatisfy` isInfixOf "LSF.raise") (emitHaskellTyped declarations units)
  describe "typed definitions that perform other abilities' operations" $ do
    let compiled paths = do
          sources <- mapM (\path -> Source path <$> readFile path) paths
          either (\e -> expectationFailure (show e) >> fail "no program") pure (compileCore 64 defaultGeneration sources)
    it "type a client of another ability, which takes the handler context" $ do
      p <- compiled ["examples/specs/abilities.lawspec"]
      let plan = typedPlanPerforming scalarTypes (C.programDataDeclarations p) (C.programUnits p)
          pay = [C.declarationId (C.definitionDeclaration d) | u <- C.programUnits p, d <- C.unitDefinitions u, C.declarationName (C.definitionDeclaration d) == "pay"]
      not (null pay) `shouldBe` True
      all (`M.member` typedDefinitions plan) pay `shouldBe` True
      all (isContextual plan) pay `shouldBe` True
    it "stay dynamic where the target's typed code has no context" $ do
      p <- compiled ["examples/specs/abilities.lawspec"]
      let plan = typedPlan (C.programDataDeclarations p) (C.programUnits p)
          pay = [C.declarationId (C.definitionDeclaration d) | u <- C.programUnits p, d <- C.unitDefinitions u, C.declarationName (C.definitionDeclaration d) == "pay"]
      any (`M.member` typedDefinitions plan) pay `shouldBe` False
    it "call the operation's handler in the context on every target" $ do
      p <- compiled ["examples/specs/abilities.lawspec"]
      let declarations = C.programDataDeclarations p
          units = C.programUnits p
      either expectationFailure (\typed -> pyTypedModule typed `shouldSatisfy` isInfixOf "ls.handler(symbols, ") (emitPythonTyped 64 declarations units)
      either expectationFailure (\typed -> webTypedModule typed `shouldSatisfy` isInfixOf "ls.handler(symbols, ") (emitWebTyped True 64 declarations units)
      either expectationFailure (\typed -> hsTypedModule typed `shouldSatisfy` isInfixOf "LS.handlerOf symbols") (emitHaskellTyped declarations units)
      either expectationFailure (\typed -> D.render D.Compact (rustTypedModule typed) `shouldSatisfy` isInfixOf "(&mut *ctx, vec![") (emitRustTyped declarations units)
      either expectationFailure (\typed -> jvmTypedSource typed `shouldSatisfy` isInfixOf "LawSpecDefinitionBodies.typedPerform_") (emitJvmTyped JavaStyle declarations units)
