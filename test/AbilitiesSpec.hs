module AbilitiesSpec (spec) where

import Control.Monad (forM_)
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Core.Evidence (Obligation(..), Status(..))
import LawSpec.CoreEmit (emitPlan, emitPlanWithNativeOptions)
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.NativeBinding (NativeRef(..))
import LawSpec.NativeRequest
import LawSpec.Testing (planTesting)

program :: String -> Either [Diagnostic] C.Program
program source = compileCore 64 defaultGeneration [Source "payments.lawspec" source]

failsWith :: String -> Either [Diagnostic] a -> Bool
failsWith needle = either (any ((needle `isInfixOf`) . message)) (const False)

gateway :: String
gateway = unlines
  [ "unit example.payments"
  , "type Payment is | Approved cents :: Int32 | Declined end"
  , "type Receipt is Receipt cents :: Int32 end"
  , "ability Gateway is"
  , "  authorize :: Int32 -> Payment"
  , "  capture :: Int32 -> Receipt"
  , "laws"
  , "  law `a receipt is for the amount` is"
  , "    definition is `for all` (cents :: Int32) . capture cents = Receipt cents end"
  , "  end"
  , "end"
  , "handler fakeGateway for Gateway is"
  , "  authorize cents is Approved cents end"
  , "  capture cents is Receipt cents end"
  , "end" ]

with :: [String] -> String
with rest = gateway ++ unlines rest

checkout :: String
checkout = unlines
  [ "definition checkout (cents :: Int32) :: Bool is"
  , "  match authorize cents with"
  , "  | Approved amount -> (match capture amount with | Receipt paid -> paid == cents end)"
  , "  | Declined -> false"
  , "  end"
  , "end" ]

-- The ability row Core gives a declaration.
row :: String -> C.Program -> Maybe [String]
row name compiled = lookup name
  [(C.declarationName d, map C.abilityKey (C.declarationUses d)) | u <- C.programUnits compiled, d <- C.unitDeclarations u]

-- The user-owned files a target scaffolds.
stub :: String -> String -> Either [Diagnostic] String
stub target source = do
  files <- program source >>= planTesting >>= emitPlan target
  pure (concat [artifactContent f | f <- files, ownership f == "user"])

generated :: String -> String -> Either [Diagnostic] String
generated target source = do
  files <- program source >>= planTesting >>= emitPlan target
  pure (concatMap artifactContent files)

fileOf :: String -> FilePath -> String -> Either [Diagnostic] String
fileOf target path source = do
  files <- program source >>= planTesting >>= emitPlan target
  pure (concat [artifactContent f | f <- files, artifactPath f == path])

spec :: Spec
spec = describe "abilities" $ do
  describe "names" $
    it "rejects, on Java and Kotlin, an ability or handler named like the class holding its unit's abilities" $ do
      let clashing = unlines ["unit example.gateway", "ability Gateway is", "  ping :: Int32 -> Int32", "end"]
          handlerClash = unlines (["unit example.payments"] ++ drop 1 (lines gateway) ++ ["handler payments for Gateway is", "  authorize cents is Declined end", "  capture cents is Receipt cents end", "end"])
      forM_ ["java", "kotlin"] $ \target -> do
        generated target clashing `shouldSatisfy` failsWith "is the name of the class holding the unit's abilities (Gateway)"
        generated target handlerClash `shouldSatisfy` failsWith "the handler payments"
      generated "python" clashing `shouldSatisfy` isRight
  describe "rows" $ do
    it "infers a definition's row from the operations it performs" $ do
      let Right compiled = program (with [checkout])
      row "checkout" compiled `shouldBe` Just ["example.payments::ability::Gateway"]
    it "infers rows through calls" $ do
      let Right compiled = program (with [checkout, "definition twice (cents :: Int32) :: Bool is checkout cents end"])
      row "twice" compiled `shouldBe` Just ["example.payments::ability::Gateway"]
    it "keeps a declared adapter row, in its order" $ do
      let Right compiled = program (with ["ability Clock is now :: Int64 end", "charge :: Int32 -> Bool uses Gateway, Clock"])
      row "charge" compiled `shouldBe` Just ["example.payments::ability::Gateway", "example.payments::ability::Clock"]
    it "leaves a pure definition's row empty" $ do
      let Right compiled = program (with ["definition double (n :: Int32 where n >= 0 && n <= 100) :: Int32 is n + n end"])
      row "double" compiled `shouldBe` Just []
    it "turns operation calls into Perform" $ do
      let Right compiled = program (with [checkout])
          performs e = case C.expressionNode e of
            C.Perform op args -> C.operationName op : concatMap performs args
            _ -> concatMap performs (C.children e)
      concat [performs (C.definitionBody d) | u <- C.programUnits compiled, d <- C.unitDefinitions u,
        C.declarationName (C.definitionDeclaration d) == "checkout"] `shouldBe` ["authorize", "capture"]
  describe "errors" $ do
    it "rejects an unknown ability" $
      program (with ["charge :: Int32 -> Bool uses Clock"]) `shouldSatisfy` failsWith "there is no ability called Clock"
    it "rejects a definition whose uses list misses an ability it uses" $
      program (with ["ability Clock is now :: Int64 end",
        "definition stamped (cents :: Int32) :: Int64 uses Gateway is now end"])
        `shouldSatisfy` failsWith "stamped uses Clock (through now), but its uses list does not say so"
    it "rejects a raise without fails with" $
      program (with ["type Problem is | Refused end",
        "definition refuse (cents :: Int32) :: Int32 is raise Refused end"])
        `shouldSatisfy` failsWith "refuse raises a failure, so its signature must say what it fails with"
    it "rejects a raise of another failure type" $
      program (with ["type Problem is | Refused end",
        "definition refuse (cents :: Int32) :: Int32 fails with Problem is raise \"no\" end"])
        `shouldSatisfy` failsWith "it raises a failure of type Text"
    it "rejects a handler that misses an operation" $
      program (with ["handler halfGateway for Gateway is authorize cents is Declined end end"])
        `shouldSatisfy` failsWith "the handler halfGateway for Gateway has no clause for capture"
    it "rejects a clause for an operation the ability lacks" $
      program (with ["handler oddGateway for Gateway is",
        "  authorize cents is Declined end", "  capture cents is Receipt cents end", "  refund cents is Declined end", "end"])
        `shouldSatisfy` failsWith "Gateway has no operation called refund"
    it "rejects a clause with the wrong number of values" $
      program (with ["handler wideGateway for Gateway is",
        "  authorize cents more is Declined end", "  capture cents is Receipt cents end", "end"])
        `shouldSatisfy` failsWith "the clause for authorize in wideGateway takes 1 value(s)"
    it "rejects calls of without a recording" $
      program (with [checkout, "law `counted` is definition is `for all` (cents :: Int32) . checkout cents = (calls of capture >= 0) end end"])
        `shouldSatisfy` failsWith "so it needs a recording handler"
    it "rejects a handler for an ability the law does not use" $
      program (with ["law `pure` using fakeGateway is definition is `for all` (n :: Bool) . n = n end end"])
        `shouldSatisfy` failsWith "names a handler for Gateway, but nothing it calls uses Gateway"
    it "rejects a handler that breaks an ability law over a finite domain at compile time" $
      (program (unlines
        [ "unit example.toggle"
        , "ability Toggle is"
        , "  flip :: Bool -> Bool"
        , "laws"
        , "  law `flipping twice is identity` is"
        , "    definition is `for all` (b :: Bool) . flip (flip b) = b end"
        , "  end"
        , "end"
        , "handler stuck for Toggle is flip b is true end end" ]) >>= dischargeEvidence)
        `shouldSatisfy` failsWith "flipping twice is identity [stuck] is false"
  describe "laws and handlers" $ do
    it "runs a law without using under each lawful handler" $ do
      let Right compiled = program (with [checkout, "law `checkout works` is definition is `for all` (cents :: Int32) . checkout cents = true end end"])
          names = [C.propertyName p | u <- C.programUnits compiled, p <- C.unitProperties u]
      names `shouldSatisfy` (\ns -> "checkout works [native]" `elem` ns && "checkout works [fakeGateway]" `elem` ns)
    it "makes one law per ability law and handler" $ do
      let Right compiled = program gateway
          names = [C.propertyName p | u <- C.programUnits compiled, p <- C.unitProperties u]
      names `shouldBe` ["Gateway: a receipt is for the amount [native]", "Gateway: a receipt is for the amount [fakeGateway]"]
    it "proves an ability law for a spec handler, and leaves the native one to the tests" $ do
      let Right obligations = program (unlines
            [ "unit example.meter"
            , "ability Meter is"
            , "  reading :: Bool -> Int32"
            , "laws"
            , "  law `a reading is small` is definition is `for all` (b :: Bool) . reading b <= 100 end end"
            , "end"
            , "handler fixedMeter for Meter is reading b is 7 end end" ]) >>= dischargeEvidence
          status name = [obligationStatus o | o <- obligations, obligationStage o == "law", name `isInfixOf` C.idText (obligationDeclaration o)]
      status "[fixedMeter]" `shouldBe` [Proved]
      status "[native]" `shouldBe` [ExhaustivelyChecked]
    it "records the handlers each law runs under" $ do
      let Right compiled = program (with [checkout,
            "law `once` using recording Gateway is definition is `for all` (cents :: Int32) . (if checkout cents then calls of capture == 1 else true) = true end end"])
          handlers = [(C.propertyName p, map snd (C.propertyHandlers p)) | u <- C.programUnits compiled, p <- C.unitProperties u]
      lookup "once [recording fakeGateway]" handlers `shouldBe`
        Just [C.RecordingHandler (C.SpecHandler (C.Id "example.payments::handler::fakeGateway"))]
    it "gives a stateful handler's clauses the state and Pair result state" $
      program (with ["handler countingGateway for Gateway with state count :: List Int32 start [] is",
        "  authorize cents is Approved cents end", "  capture cents is ~count := Cons cents count; Receipt cents end", "end"])
        `shouldSatisfy` isRight
  describe "native interfaces" $ do
    let source = with [checkout, "charge :: Int32 -> Bool uses Gateway"]
    forM_ [ ("python", "class GatewayHandler"), ("javascript", "export class GatewayHandler")
          , ("typescript", "implements abilities.Gateway"), ("java", "class GatewayHandler implements lawspec.abilities.example.Payments.Gateway")
          , ("kotlin", "class GatewayHandler : lawspec.abilities.example.Payments.Gateway"), ("go", "func NewGatewayHandler() Gateway")
          , ("haskell", "gatewayHandler :: P.IO Abilities.Gateway"), ("rust", "impl crate::lawspec_abilities::example_payments::Gateway for GatewayHandler") ] $ \(target, expected) ->
      it ("scaffolds the production handler on " ++ target) $ stub target source `shouldSatisfy` either (const False) (isInfixOf expected)
    forM_ [ ("python", "gateway: \"lawspec_abilities.example.payments.Gateway\""), ("javascript", "export function charge(gateway"), ("go", "func Charge(gateway Gateway")
          , ("java", "charge(lawspec.abilities.example.Payments.Gateway gateway"), ("rust", "gateway: &dyn crate::lawspec_abilities::example_payments::Gateway")
          , ("haskell", "charge :: Abilities.Gateway -> I.Int32 -> P.IO P.Bool") ] $ \(target, expected) ->
      it ("gives a native adapter its handlers first on " ++ target) $ stub target source `shouldSatisfy` either (const False) (isInfixOf expected)
    forM_ [ ("python", "src/lawspec_definitions/example/payments.py", "ls.install_handlers")
          , ("javascript", "src/lawspec_definitions/example/payments.mjs", "ls.installHandlers")
          , ("go", "example/payments/lawspec_definitions.go", "lsInstallHandlers(symbols")
          , ("java", "src/main/java/lawspec/definitions/example/Payments.java", "LawSpecRuntime.installHandlers(")
          , ("kotlin", "src/main/kotlin/lawspec/definitions/example/Payments.kt", "LawSpecRuntime.installHandlers(")
          , ("haskell", "src/LawSpecDefinitions/Example/Payments.hs", "(LS.installHandlers")
          , ("rust", "src/lawspec_definitions.rs", "ctx.install_handlers") ] $ \(target, path, expected) ->
      it ("gives a definition's native function its handlers on " ++ target) $
        fileOf target path source `shouldSatisfy` either (const False) (isInfixOf expected)
    it "generates a Protocol, spec handler and recording for Python" $
      generated "python" source `shouldSatisfy` either (const False)
        (\text -> all (`isInfixOf` text) ["class Gateway(_typing.Protocol)", "class FakeGateway", "class GatewayRecording"])
  describe "handler bindings" $ do
    it "binds a production handler by ability" $ do
      let Right compiled = program gateway
          request = emptyNativeRequest { requestHandlers = [HandlerBinding "example.payments::Gateway" (NativeRef ["payments", "StripeGateway"])] }
      fmap bindingHandlers (resolveNativeRequest compiled request) `shouldBe`
        Right [(C.Id "example.payments::ability::Gateway", NativeRef ["payments", "StripeGateway"])]
    it "rejects a binding for an unknown ability" $ do
      let Right compiled = program gateway
          request = emptyNativeRequest { requestHandlers = [HandlerBinding "example.payments::Clock" (NativeRef ["clock", "Real"])] }
      resolveNativeRequest compiled request `shouldSatisfy` isLeft
    it "makes a bound production handler in the Python tests" $ do
      let Right compiled = program gateway
          request = emptyNativeRequest { requestHandlers = [HandlerBinding "example.payments::Gateway" (NativeRef ["payments", "StripeGateway"])] }
          Right bindings = resolveNativeRequest compiled request
          files = planTesting compiled >>= emitPlanWithNativeOptions False "python" Nothing Nothing bindings
      fmap (concatMap artifactContent) files `shouldSatisfy` either (const False) (isInfixOf "native_handler")
  describe "across units" $ do
    let owner = unlines
          [ "unit example.ledger"
          , "ability Log is note :: Text -> Unit end"
          , "handler quietLog for Log is note message is unitValue end end"
          , "definition logged (n :: Int32) :: Int32 is note \"logged\"; n end" ]
        user = unlines
          [ "unit example.desk"
          , "import example.ledger as ledger"
          , "definition twice (n :: Int32) :: Int32 is ledger.logged n end"
          , "definition shout (n :: Int32) :: Int32 is note \"shout\"; n end" ]
        compiled = compileCore 64 defaultGeneration [Source "ledger.lawspec" owner, Source "desk.lawspec" user]
    it "keeps an imported ability's owner" $
      fmap (row "shout") compiled `shouldBe` Right (Just ["example.ledger::ability::Log"])
    it "lets an imported definition use an ability" $
      fmap (row "twice") compiled `shouldBe` Right (Just ["example.ledger::ability::Log"])
    it "copies an imported spec handler into the importer" $
      fmap (\p -> [C.handlerName h | u <- C.programUnits p, C.idText (C.unitId u) == "example.desk", h <- C.unitHandlers u]) compiled
        `shouldBe` Right ["quietLog"]
  describe "sequencing and scoped handlers" $ do
    it "sequences a Unit operation with ;" $ do
      let Right compiled = program (with ["ability Log is note :: Text -> Unit end",
            "definition noisy (cents :: Int32) :: Bool is note \"paying\"; let ok = authorize cents in note \"paid\"; true end"])
      row "noisy" compiled `shouldBe` Just ["example.payments::ability::Gateway", "example.payments::ability::Log"]
    it "handles an ability inside a definition, which then does not use it" $ do
      let Right compiled = program (with [checkout, "definition trial (cents :: Int32) :: Bool is handle checkout cents with fakeGateway end end"])
          scoped e = case C.expressionNode e of
            C.Handle (C.WithHandler ability (C.SpecHandler h)) _ -> [(C.abilityKey ability, C.idText h)]
            _ -> concatMap scoped (C.children e)
      row "trial" compiled `shouldBe` Just []
      concat [scoped (C.definitionBody d) | u <- C.programUnits compiled, d <- C.unitDefinitions u,
        C.declarationName (C.definitionDeclaration d) == "trial"]
        `shouldBe` [("example.payments::ability::Gateway", "example.payments::handler::fakeGateway")]
    it "lets a handler's clauses use another ability, which its laws then need" $ do
      let Right compiled = program (with ["ability Log is note :: Text -> Unit end",
            "handler notingGateway for Gateway is authorize cents is note \"a\"; Approved cents end capture cents is Receipt cents end end"])
      [map (C.abilityKey . fst) (C.propertyHandlers p) | u <- C.programUnits compiled, p <- C.unitProperties u,
        "[notingGateway]" `isInfixOf` C.propertyName p]
        `shouldBe` [["example.payments::ability::Gateway", "example.payments::ability::Log"]]
    it "rejects a clause that uses its own ability" $
      program (with ["handler loopGateway for Gateway is authorize cents is capture cents; Approved cents end capture cents is Receipt cents end end"])
        `shouldSatisfy` failsWith "uses Gateway, the ability its handler handles"
  describe "parameterized abilities" $ do
    let store = with [ "ability Store (a :: Type) is load :: a  save :: a -> Unit end"
                     , "definition keepCount (n :: Int32) :: Int32 uses Store Int32 is save n; load end"
                     , "definition keepName (s :: Text) :: Text uses Store Text is save s; load end" ]
    it "uses one ability at several types in a unit" $ do
      let Right compiled = program store
      (row "keepCount" compiled, row "keepName" compiled) `shouldBe`
        (Just ["example.payments::ability::Store(Int32)"], Just ["example.payments::ability::Store(Text)"])
    it "asks which type when a definition leaves its uses out" $
      program (store ++ "definition guess (n :: Int32) :: Int32 is save n; load end\n")
        `shouldSatisfy` failsWith "say which with `uses Store T`"
  describe "refined operations" $
    it "makes every handler owe an operation's refined result" $ do
      let Right compiled = program (with ["ability Meter is reading :: (r :: Int32 where r >= 0) end",
            "handler fixedMeter for Meter is reading is 7 end end"])
      [C.propertyName p | u <- C.programUnits compiled, p <- C.unitProperties u, "Meter: reading gives what its type says" `isInfixOf` C.propertyName p]
        `shouldBe` ["Meter: reading gives what its type says [native]", "Meter: reading gives what its type says [fixedMeter]"]
  describe "spec handlers with state" $ do
    let counter law = unlines
          [ "unit example.counter"
          , "ability Counter is bump :: Unit -> Int32 end"
          , "handler counting for Counter with state n :: Int32 start 0 is"
          , "  bump u is ~n := (if n < 5 then n + 1 else n); n end"
          , "end"
          , law ]
    it "checks a law over a finite domain at compile time" $
      (program (counter "law `two bumps` using counting is definition is (bump unitValue; bump unitValue) = 2 end end") >>= dischargeEvidence)
        `shouldSatisfy` isRight
    it "refutes a false law at compile time" $
      (program (counter "law `three bumps` using counting is definition is (bump unitValue; bump unitValue) = 3 end end") >>= dischargeEvidence)
        `shouldSatisfy` failsWith "law three bumps is false"
  describe "native failures" $ do
    let source = with ["type Problem is | Refused | Odd reason :: Text end", "charge :: Int32 -> Bool uses Gateway fails with Problem"]
    it "maps a native exception to a failure constructor" $ do
      let Right compiled = program source
          request = emptyNativeRequest { requestFailures =
            [FailureMapping (NativeRef ["payments", "Declined"]) "example.payments::Problem::Refused",
             FailureMapping (NativeRef ["payments", "Weird"]) "example.payments::Problem::Odd"] }
      fmap (map (\b -> (C.idText (C.failureConstructor b), C.failureMessage b)) . bindingFailures) (resolveNativeRequest compiled request)
        `shouldBe` Right [("example.payments::type::Problem::Refused", False), ("example.payments::type::Problem::Odd", True)]
    it "rejects a mapping to an unknown constructor" $ do
      let Right compiled = program source
          request = emptyNativeRequest { requestFailures = [FailureMapping (NativeRef ["payments", "Declined"]) "example.payments::Problem::Lost"] }
      resolveNativeRequest compiled request `shouldSatisfy` isLeft
    forM_ [ ("python", "ls.native_failures("), ("javascript", "ls.nativeFailures("), ("go", "lsNativeFailures(")
          , ("java", "LawSpecRuntime.nativeFailures("), ("kotlin", "LawSpecRuntime.nativeFailures("), ("haskell", "LS.nativeFailures")
          , ("rust", "ls::native_failures::<") ] $ \(target, expected) ->
      it ("catches a native adapter's Fail on " ++ target) $
        generated target (source ++ "law `charges` is definition is `for all` (c :: Int32) . prelude.attempt (charge c) = prelude.attempt (charge c) end end\n")
          `shouldSatisfy` either (const False) (isInfixOf expected)
