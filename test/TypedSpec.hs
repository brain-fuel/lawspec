-- | Typed native definitions: which definitions run typed, how copies share a
-- body, and what the Rust, Go, JVM and BEAM emitters make of them.
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
import LawSpec.Typed.Beam (BeamTyped(..), emitBeamTyped)
import qualified LawSpec.BeamAbilities as BeamAbilities
import qualified LawSpec.Code.Doc as D
import LawSpec.RustDefinitions (emitRustDefinitions)
import LawSpec.Common (Artifact(..))
import qualified LawSpec.AbilityEmit.Rust as RustAbilities
import qualified LawSpec.AbilityEmit.Go as GoAbilities
import qualified LawSpec.AbilityEmit.Java as JavaAbilities
import qualified LawSpec.AbilityEmit.Kotlin as KotlinAbilities
import qualified LawSpec.AbilityEmit.Python as PythonAbilities
import qualified LawSpec.AbilityEmit.Web as WebAbilities
import qualified LawSpec.AbilityEmit.Haskell as HaskellAbilities
import LawSpec.RustData (emitRustData)
import LawSpec.HaskellDefinitions (emitHaskellDefinitions)

ledger :: String
ledger = unlines
  [ "unit example.ledger"
   ++ "\n", ""
  , ""
  , "type Account is a record{  owner :: Text balance :: Int64} end type\n"
  , ""
  , "function credit (name :: Text) (amount :: Int64) (book :: KeyVal Text Account) -> KeyVal Text Account is"
  , "  first matching case of prelude.lookup name book :"
  , "  when Absent then prelude.put name (Account record{ owner = name , balance = amount}) book"
  , "  when Present a then book"
  , "  end case"
  , "end function"
  , ""
  , "function total (xs :: List Int64) (acc :: Integer) -> Integer is"
  , "  first matching case of xs :"
  , "  when Nil then acc"
  , "  when Cons h t then total t (acc + h)"
  , "  end case"
  , "end function"
  , ""
  , "function half (x :: Float64) -> Float64 is x / 2.0 end function\n"
  , ""
  , "function current (b :: Maybe (KeyVal Text Account)) -> KeyVal Text Account is"
  , "  first matching case of b : when Absent then prelude.keyValOf [] when Present k then k end case"
  , "end function"
  , ""
  , "ability Bank is"
  , "  deposit :: Text -> Int64 -> Int64"
  , "end ability"
  , ""
  , "handler books for Bank with state book :: Maybe (KeyVal Text Account) start Absent is"
  , "   operation deposit name amount is ~book := Present (credit name amount (current book)); amount end operation"
  , "end handler"
  , "\nend unit" ]

consumer :: String
consumer = unlines
  [ "unit example.consumer"
  , ""
  , "import example.ledger as ledger"
  , ""
  , "function twice (name :: Text) (book :: KeyVal Text ledger.Account) -> KeyVal Text ledger.Account is"
  , "  ledger.credit name 1 (ledger.credit name 1 book)"
  , "end function"
  , ""
  , "end unit" ]

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
  it "emits BEAM code over each language's own data, with KeyVal as a map" $ withProgram $ \p -> do
    let declarations = C.programDataDeclarations p
        units = C.programUnits p
        source target = either error (maybe "" id . beamTypedSource) (emitBeamTyped target [] declarations units)
    source "erlang" `shouldSatisfy` isInfixOf "maps:put("
    source "erlang" `shouldSatisfy` isInfixOf "{account, "
    source "elixir" `shouldSatisfy` isInfixOf "'Elixir.LawSpec.Data.Account'"
    source "gleam" `shouldSatisfy` isInfixOf "{some, "
    -- A self tail call stays a tail call: the call is the body's last expression.
    source "erlang" `shouldSatisfy` isInfixOf "-module(lawspec_typed)."

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
      either expectationFailure (\typed -> beamTypedSource typed `shouldSatisfy` maybe False (isInfixOf "lawspec_beam_effects:raise_failure("))
        (emitBeamTyped "erlang" [] declarations units)
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
      either expectationFailure (\typed -> jvmTypedSource typed `shouldSatisfy` isInfixOf "LawSpecDefinitionBodies.typedPerform") (emitJvmTyped JavaStyle declarations units)
      either expectationFailure (\typed -> beamTypedSource typed `shouldSatisfy` maybe False (isInfixOf "lawspec_beam_effects:perform(")) (emitBeamTyped "erlang" [] declarations units)
  describe "typed names" $ do
    it "stay the same when unrelated definitions are added before them" $ do
      let compile extra = either (\e -> error (show e)) id (compileCore 64 defaultGeneration [Source "ledger.lawspec" (extra ++ ledger)])
          edited = "function unrelated (x :: Int64) -> Int64 is x end function\n\nfunction another (t :: Text) -> Text is t end function\n\n"
          namesOf p = do
            typed <- emitPythonTyped 64 (C.programDataDeclarations p) (C.programUnits p)
            rust <- emitRustTyped (C.programDataDeclarations p) (C.programUnits p)
            beam <- emitBeamTyped "erlang" [] (C.programDataDeclarations p) (C.programUnits p)
            pure [ (pyTypedFunction typed i, (rustTypedFunction rust i, beamTypedFunction beam i)) | i <- named p "credit" ++ named p "total" ]
          withHeader text = case lines text of
            first : rest -> unlines (first : rest)
            [] -> text
      let before = compile ""
          after = either (\e -> error (show e)) id (compileCore 64 defaultGeneration
            [Source "ledger.lawspec" (withHeader (unlines (take 2 (lines ledger)) ++ edited ++ unlines (drop 2 (lines ledger))))])
      namesOf before `shouldBe` namesOf after
      either (const False) (all (\(a, (b, c)) -> a /= Nothing && b /= Nothing && c /= Nothing)) (namesOf before) `shouldBe` True
  describe "generated Rust in a dependent crate" $
    -- (the acceptance suites build every crate and check it has no warnings)
    it "allows no lints wholesale: its generated shapes raise none" $ withProgram $ \p -> do
      let declarations = C.programDataDeclarations p
      case (emitRustDefinitions (D.Pretty 100) 64 declarations (C.programUnits p), emitRustData (D.Pretty 100) declarations) of
        (Right definitions, Right datas) -> do
          definitions `shouldNotSatisfy` isInfixOf "#![allow"
          datas `shouldNotSatisfy` isInfixOf "#![allow"
        (Left e, _) -> expectationFailure e
        (_, Left e) -> expectationFailure e
  describe "embedded handlers" $
    it "give each failing operation a form that returns its failure, and read and replace their state, on every target" $ do
      sources <- mapM (\path -> Source path <$> readFile path) ["examples/specs/composition.lawspec"]
      p <- either (\e -> expectationFailure (show e) >> fail "no program") pure (compileCore 64 defaultGeneration sources)
      let declarations = C.programDataDeclarations p
          units = C.programUnits p
          joined = either (\e -> error e) (concatMap artifactContent)
          expect label source needles = (label, filter (not . (`isInfixOf` source)) needles) `shouldBe` (label, [])
      expect "rust" (either error id (RustAbilities.emit False 64 declarations units)) ["pub fn try_append(", "pub fn state(&self)", "pub fn set_state(", "pub fn typed_state("]
      expect "go" (joined (GoAbilities.emit False 64 declarations units)) [") TryAppend(", ") State() ", ") SetState(", ") TypedState() "]
      expect "java" (joined (JavaAbilities.emit False 64 declarations units)) [" tryAppend(", " state()", "void setState(", " typedState()"]
      expect "kotlin" (joined (KotlinAbilities.emit False 64 declarations units)) ["fun tryAppend(", "fun state(): ", "fun setState(", "fun typedState():"]
      expect "python" (joined (PythonAbilities.emit False 64 declarations units)) ["def try_append(", "def state(self)", "def set_state(self, state)", "def typed_state(self)"]
      expect "typescript" (joined (WebAbilities.emit True False 64 declarations units)) ["tryAppend(", "state()", "setState(state", "typedState()"]
      expect "haskell" (joined (HaskellAbilities.emit False 64 declarations units)) ["tryAppend ::", "storeSnapshot =", "storeRestore ="]
      let beam = either error Just (emitBeamTyped "erlang" [] declarations units)
      expect "erlang" (joined (BeamAbilities.emit "erlang" (D.Pretty 100) 64 beam declarations units False))
        ["_try_append(", "store_state(", "store_set_state(", "store_typed_state(", "lawspec_beam_fast:handler("]
      -- A typed handler's state names LawSpecFast's types where its bodies are.
      let bodies = [artifactContent a | a <- either error id (emitHaskellDefinitions (D.Pretty 100) 64 declarations units), "LawSpecDefinitionBodies" `isInfixOf` artifactPath a]
      expect "haskell bodies" (concat bodies) ["import qualified LawSpecFast as LSF", "MVar.MVar"]
