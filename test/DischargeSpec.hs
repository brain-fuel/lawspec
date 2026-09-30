module DischargeSpec (spec) where

import Data.Aeson (Value(..), decode, encode, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.List (isInfixOf)
import qualified Data.Vector as V
import Test.Hspec
import LawSpec.Api (dispatch)
import LawSpec.Common
import qualified LawSpec.Core as C
import LawSpec.Core.Evidence
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Frontend (compileCore)

evidenceFor :: String -> Either [Diagnostic] [Obligation]
evidenceFor body = compileCore 64 defaultGeneration [Source "d.lawspec" ("unit d\n" ++ body)] >>= dischargeEvidence

lawStatus :: String -> String -> Either String (Status, String)
lawStatus name body = case evidenceFor body of
  Left diagnostics -> Left (concatMap message diagnostics)
  Right obligations -> case [(obligationStatus o, obligationReason o) | o <- obligations,
      obligationStage o == "law", C.idText (obligationDeclaration o) == "d::law::" ++ name] of
    [found] -> Right found
    _ -> Left ("no law " ++ name)

law :: String -> String -> String
law name claim = "law `" ++ name ++ "` is definition is " ++ claim ++ " end end\n"

twice :: String
twice = "definition twice (x :: Int32) :: BigInt is x + x end\n"

spec :: Spec
spec = describe "evidence and discharge" $ do
  it "proves linear laws over definitions, unfolding unrefined callees" $ do
    fmap fst (lawStatus "doubling" (twice ++ law "doubling" "`for all` (x :: Int32) . twice x = x * 2")) `shouldBe` Right Proved
    fmap fst (lawStatus "guarded" (twice ++ law "guarded" "`for all` (x :: Int32) . x > 0 implies twice x > x")) `shouldBe` Right Proved
    fmap fst (lawStatus "refined" (law "refined" "`for all` (x :: Int32 where x > 0) . x + x > x")) `shouldBe` Right Proved

  it "never proves a false law" $
    fmap fst (lawStatus "wrong" (twice ++ law "wrong" "`for all` (x :: Int32) . twice x = x")) `shouldBe` Right PropertyTested

  it "keeps callee preconditions as obligations instead of unfolding" $
    fmap fst (lawStatus "half" ("definition half (x :: Int32 where x > 0) :: Int32 is x end\n" ++
      law "half" "`for all` (x :: Int32 where x > 1) . half x > 0")) `shouldBe` Right PropertyTested

  it "checks finite laws over definitions in the compiler and refutes false ones" $ do
    let inc = "definition inc (x :: Int8) :: BigInt is x + 1 end\n"
    fmap fst (lawStatus "bounded" (inc ++ law "bounded" "`for all` (x :: Int8) . inc x <= 128")) `shouldBe` Right Proved
    -- Not linear, so not proved; every Int8 is evaluated instead.
    lawStatus "square" (inc ++ law "square" "`for all` (x :: Int8) . inc x * inc x >= 0")
      `shouldSatisfy` either (const False) (\(status, reason) -> status == ExhaustivelyChecked &&
        "the compiler evaluated all 256 inputs" `isInfixOf` reason)
    case lawStatus "positive" (inc ++ law "positive" "`for all` (x :: Int8) . inc x > 0") of
      Left failure -> failure `shouldSatisfy` isInfixOf "law positive is false for x = -128"
      Right found -> expectationFailure ("expected a refutation, got " ++ show found)

  it "checks finite laws over adapters in the generated tests" $ do
    let flip' = "flipFlag :: Bool -> Bool\n"
    lawStatus "twice" (flip' ++ law "twice" "`for all` (b :: Bool) . flipFlag (flipFlag b) = b")
      `shouldSatisfy` either (const False) (\(status, reason) -> status == ExhaustivelyChecked &&
        "the generated tests check all 2 inputs" `isInfixOf` reason && "relies on d::flipFlag" `isInfixOf` reason)
    lawStatus "one" ("finish :: Int32 -> Bool\n" ++ law "one" "finish 1 = true")
      `shouldSatisfy` either (const False) (\(status, reason) -> status == ExhaustivelyChecked && "its only case" `isInfixOf` reason)

  it "property-tests infinite laws over adapters" $
    lawStatus "idempotent" ("f :: Int32 -> Int32\n" ++ law "idempotent" "`for all` (x :: Int32) . f (f x) = f x")
      `shouldSatisfy` either (const False) (\(status, reason) -> status == PropertyTested &&
        "100 generated cases" `isInfixOf` reason)

  it "reports adapters as assumed, noting those no law calls" $ do
    let Right obligations = evidenceFor ("f :: Int32 -> Int32\nunused :: Int8 -> Int8\n" ++
          law "idempotent" "`for all` (x :: Int32) . f (f x) = f x")
        adapters = [(C.idText (obligationDeclaration o), obligationStatus o, obligationReason o) | o <- obligations, obligationStage o == "adapter"]
    adapters `shouldBe`
      [ ("d::f", Assumed, "native implementation taken on trust; called by 1 law(s)")
      , ("d::unused", Assumed, "native implementation taken on trust; no law calls it") ]

  it "reports contract and construction obligations as before" $ do
    let Right obligations = evidenceFor ("type Box is Box value :: (v :: Int32 where v > 0) end\n" ++
          "positive :: (x :: Int32 where x > 0) -> (y :: Int32 where y > 0)\n" ++
          law "p" "`for all` (x :: Int32 where x > 0) . positive x > 0")
        stages = [(obligationStage o, obligationStatus o) | o <- obligations, obligationStage o /= "law"]
    stages `shouldSatisfy` elem ("construction", RuntimeChecked)
    stages `shouldSatisfy` elem ("precondition", RuntimeChecked)
    stages `shouldSatisfy` elem ("postcondition", RuntimeChecked)

  it "reports native bindings through the API" $ do
    payments <- readFile "examples/specs/payments.lawspec"
    bindings <- maybe Null id . decode <$> BL.readFile "test/fixtures/native-payments/bindings.json"
    let response = maybe Null id $ decode $ dispatch $ encode $ object
          [ "method" .= ("check" :: String), "schemaVersion" .= (4 :: Int)
          , "sources" .= [object ["path" .= ("payments.lawspec" :: String), "content" .= payments]]
          , "nativeBindings" .= (bindings :: Value) ]
        stages = case response of
          Object o | Just (Array items) <- KM.lookup "evidence" o ->
            [(stage, status) | Object item <- V.toList items, Just (String stage) <- [KM.lookup "stage" item],
              Just (String status) <- [KM.lookup "status" item]]
          _ -> []
    show response `shouldNotSatisfy` isInfixOf "\"code\""
    stages `shouldSatisfy` elem ("binding", "runtime-checked")
    stages `shouldSatisfy` elem ("native-function", "assumed")
