-- | Evidence and discharge of laws. ref:DEC-s1j-evaluation-budget
module DischargeSpec (test_lawsAreDischargedWithHonestEvidence) where

import Data.Aeson (Value(..), decode, encode, toJSON, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Vector as V
import Test.Hspec
import LawSpec.Api (dispatch)
import LawSpec.Common
import qualified LawSpec.Core as C
import LawSpec.Core.Evidence
import LawSpec.Discharge (dischargeEvidence, dischargeEvidenceWith)
import qualified LawSpec.Core.Verification as Verification
import Data.Either (isLeft)
import LawSpec.Frontend (compileCore)

evidenceFor :: String -> Either [Diagnostic] [Obligation]
evidenceFor body = compileCore 64 defaultGeneration [Source "d.lawspec" ("unit d\n\n" ++ body ++ "\nend unit\n")] >>= dischargeEvidence

lawStatus :: String -> String -> Either String (Status, String)
lawStatus name body = case evidenceFor body of
  Left diagnostics -> Left (concatMap message diagnostics)
  Right obligations -> case [(obligationStatus o, obligationReason o) | o <- obligations,
      obligationStage o == "law", C.idText (obligationDeclaration o) == "d::law::|" ++ name ++ "|"] of
    [found] -> Right found
    _ -> Left ("no law " ++ name)

law :: String -> String -> String
law name claim = "law \"|" ++ name ++ "| is definition: " ++ claim ++ " end definition end law\n"

twice :: String
twice = "function twice (x :: Int32) -> Integer is x + x end function\n"

-- | Evidence tells a user what was proved and what was only tested, so a false
-- law must never be proved and every adapter the compiler cannot see into must
-- be reported as assumed. ref:DEC-evidence-statuses ref:REQ-honest-evidence
test_lawsAreDischargedWithHonestEvidence :: Spec
test_lawsAreDischargedWithHonestEvidence = describe "evidence and discharge" $ do
  it "meters optional evaluation and validates explicit law identities" $ do
    let text = "unit d\nfunction twice (x :: Int8) -> Integer is x + x end function\n" ++
          law "square" "for all (x :: Int8) => twice x * twice x >= 0 end for all" ++ "end unit"
        config layers steps deferred = Verification.VerificationEvaluation layers (Verification.Evaluation steps deferred)
        statuses = fmap (map obligationStatus . filter ((== "law") . obligationStage))
    case compileCore 64 defaultGeneration [Source "budget.lawspec" text] of
      Left problems -> expectationFailure (show problems)
      Right program -> do
        statuses (dischargeEvidenceWith (config [Verification.Exhaustive] 1 []) program) `shouldBe` Right [Planned]
        statuses (dischargeEvidenceWith (config [Verification.Exhaustive] 1000000 []) program) `shouldBe` Right [ExhaustivelyChecked]
        statuses (dischargeEvidenceWith (config [Verification.Proof] 1000000 ["d::|square|"]) program) `shouldBe` Right [Incomplete]
        statuses (dischargeEvidenceWith (config [Verification.Exhaustive] 1000000 ["d::|square|"]) program) `shouldBe` Right [Planned]
        dischargeEvidenceWith (config [] 1 ["d::absent"]) program `shouldSatisfy` isLeft
  it "never lets optional evaluation settings bypass invalid definitions" $ do
    let response = dispatch (encode (object ["schemaVersion" .= (5::Int), "method" .= ("check"::String),
          "languageProfile" .= ("1.0-rc.2"::String),
          "verification" .= object ["layers" .= ([]::[String]), "evaluation" .= object ["maxSteps" .= (1::Int), "deferLaws" .= (["bad::later"]::[String])]],
          "sources" .= [Source "bad.lawspec" "unit bad\nfunction invalid (x :: Integer) -> Rational is x / 0 end function\nend unit"]]))
    show response `shouldSatisfy` isInfixOf "total"
  it "defers caught failures through every reachable procedure" $ do
    source <- readFile "test/fixtures/effectful-attempt.lawspec"
    let (before,after) = break (isPrefixOf "law queued") (lines source)
        helper = "procedure recordAccepted (event :: Int32) -> Bool uses Sink is prelude.isRight (prelude.attempt (record event)) end procedure"
        wrapper = "procedure enqueue (event :: Int32) -> Bool uses Sink is recordAccepted event end procedure"
        variants = [("prelude.isRight (prelude.attempt (record 1))",[]),
                    ("recordAccepted 1",[helper]),("enqueue 1",[helper,wrapper])]
        run (claim,definitions) = do
          let changed = unlines (before ++ definitions ++ take 1 after ++
                [" definition: " ++ claim ++ " implies pending >= 1 end definition", "end law", "end unit"])
              response = decode (dispatch (encode (object ["method" .= ("check" :: String),
                "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
                "verification" .= object ["layers" .= (["exhaustive","property"] :: [String])],
                "sources" .= [Source "effects.lawspec" changed]]))) :: Maybe Value
          case response of
            Just (Object result) -> do
              KM.lookup "diagnostics" result `shouldBe` Just (toJSON ([] :: [Value]))
              let statuses = [status | Just (Array rows) <- [KM.lookup "evidence" result], Object row <- V.toList rows,
                    KM.lookup "declaration" row == Just (String "evaluation.sink::law::queued"), Just status <- [KM.lookup "status" row]]
              statuses `shouldBe` [String "planned"]
            _ -> expectationFailure "missing compiler response"
    mapM_ run variants
  it "retains exhaustive execution through stateless spec-handler procedures" $ do
    let source = unlines ["unit fixed", "ability Seats is", "count :: Unit -> Int32", "end ability",
          "handler four for Seats is operation count unused is 4 end operation end handler",
          "procedure readSeats (unused :: Unit) -> Int32 uses Seats is count () end procedure",
          "law selected using four is definition: readSeats () = 4 end definition end law", "end unit"]
        response = decode (dispatch (encode (object ["method" .= ("check" :: String),
          "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
          "verification" .= object ["layers" .= (["exhaustive"] :: [String])],
          "sources" .= [Source "stateless.lawspec" source]]))) :: Maybe Value
    case response of
      Just (Object result) -> do
        KM.lookup "diagnostics" result `shouldBe` Just (toJSON ([] :: [Value]))
        let statuses = [status | Just (Array rows) <- [KM.lookup "evidence" result], Object row <- V.toList rows,
              KM.lookup "declaration" row == Just (String "fixed::law::selected"), Just status <- [KM.lookup "status" row]]
        statuses `shouldBe` [String "exhaustively-checked"]
      _ -> expectationFailure "missing compiler response"
  it "proves linear laws over definitions, unfolding unrefined callees" $ do
    fmap fst (lawStatus "doubling" (twice ++ law "doubling" "for all (x :: Int32) => twice x = x * 2 end for all")) `shouldBe` Right Proved
    fmap fst (lawStatus "guarded" (twice ++ law "guarded" "for all (x :: Int32) => x > 0 implies twice x > x end for all")) `shouldBe` Right Proved
    fmap fst (lawStatus "refined" (law "refined" "for all (x :: Int32 where x > 0) => x + x > x end for all")) `shouldBe` Right Proved

  it "never proves a false law" $
    fmap fst (lawStatus "wrong" (twice ++ law "wrong" "for all (x :: Int32) => twice x = x end for all")) `shouldBe` Right PropertyTested

  it "keeps callee preconditions as obligations instead of unfolding" $
    fmap fst (lawStatus "half" ("function half (x :: Int32 where x > 0) -> Int32 is x end function\n" ++
      law "half" "for all (x :: Int32 where x > 1) => half x > 0 end for all")) `shouldBe` Right PropertyTested

  it "checks finite laws over definitions in the compiler and refutes false ones" $ do
    let inc = "function inc (x :: Int8) -> Integer is x + 1 end function\n"
    fmap fst (lawStatus "bounded" (inc ++ law "bounded" "for all (x :: Int8) => inc x <= 128 end for all")) `shouldBe` Right Proved
    -- Not linear, so not proved; every Int8 is evaluated instead.
    lawStatus "square" (inc ++ law "square" "for all (x :: Int8) => inc x * inc x >= 0 end for all")
      `shouldSatisfy` either (const False) (\(status, reason) -> status == ExhaustivelyChecked &&
        "the compiler evaluated all 256 inputs" `isInfixOf` reason)
    case lawStatus "positive" (inc ++ law "positive" "for all (x :: Int8) => inc x > 0 end for all") of
      Left failure -> failure `shouldSatisfy` isInfixOf "law |positive| is false for x = -128"
      Right found -> expectationFailure ("expected a refutation, got " ++ show found)

  it "checks finite laws over adapters in the generated tests" $ do
    let flip' = "flipFlag :: Bool -> Bool\n"
    lawStatus "twice" (flip' ++ law "twice" "for all (b :: Bool) => flipFlag (flipFlag b) = b end for all")
      `shouldSatisfy` either (const False) (\(status, reason) -> status == ExhaustivelyChecked &&
        "the generated tests check all 2 inputs" `isInfixOf` reason && "relies on d::flipFlag" `isInfixOf` reason)
    lawStatus "one" ("finish :: Int32 -> Bool\n" ++ law "one" "finish 1 = true")
      `shouldSatisfy` either (const False) (\(status, reason) -> status == ExhaustivelyChecked && "its only case" `isInfixOf` reason)

  it "property-tests infinite laws over adapters" $
    lawStatus "idempotent" ("f :: Int32 -> Int32\n" ++ law "idempotent" "for all (x :: Int32) => f (f x) = f x end for all")
      `shouldSatisfy` either (const False) (\(status, reason) -> status == PropertyTested &&
        "100 generated cases" `isInfixOf` reason)

  it "reports adapters as assumed, noting those no law calls" $ do
    let Right obligations = evidenceFor ("f :: Int32 -> Int32\nunused :: Int8 -> Int8\n" ++
          law "idempotent" "for all (x :: Int32) => f (f x) = f x end for all")
        adapters = [(C.idText (obligationDeclaration o), obligationStatus o, obligationReason o) | o <- obligations, obligationStage o == "adapter"]
    adapters `shouldBe`
      [ ("d::f", Assumed, "native implementation taken on trust; called by 1 law(s)")
      , ("d::unused", Assumed, "native implementation taken on trust; no law calls it") ]

  it "reports contract and construction obligations as before" $ do
    let Right obligations = evidenceFor ("type Box is a record{  value :: (v :: Int32 where v > 0)} end type\n" ++
          "positive :: (x :: Int32 where x > 0) -> (y :: Int32 where y > 0)\n" ++
          law "p" "for all (x :: Int32 where x > 0) => positive x > 0 end for all")
        stages = [(obligationStage o, obligationStatus o) | o <- obligations, obligationStage o /= "law"]
    stages `shouldSatisfy` elem ("construction", RuntimeChecked)
    stages `shouldSatisfy` elem ("precondition", RuntimeChecked)
    stages `shouldSatisfy` elem ("postcondition", RuntimeChecked)

  it "reports native bindings through the API" $ do
    payments <- readFile "examples/specs/payments.lawspec"
    bindings <- maybe Null id . decode <$> BL.readFile "test/fixtures/native-payments/bindings.json"
    let response = maybe Null id $ decode $ dispatch $ encode $ object
          [ "method" .= ("check" :: String), "schemaVersion" .= (5 :: Int)
          , "languageProfile" .= ("1.0-rc.2" :: String)
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
