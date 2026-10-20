-- | Environment attestations in the compiler API's evidence.
module AttestationSpec (test_attestationReportsWhereTestsRanWithoutChangingEvidence) where

import Control.Monad (forM_)
import Data.Aeson (Value(..), decode, encode, object, toJSON, (.=))
import Data.String (fromString)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Vector as V
import Test.Hspec
import LawSpec.Api (dispatch)

spec :: String
spec = unlines
  [ "unit shop.orders"
   ++ "\n", ""
  , "type Receipt is a record{cents :: Int32} end type\n"
  , "ability Gateway is"
  , "  capture :: Int32 -> Receipt"
  , "laws"
  , "  law receiptAmount is"
  , "    definition: for all (cents :: Int32) => capture cents = Receipt record{cents = cents} end for all end definition"
  , "  end law"
  , "\nend laws"
  , "end ability"
  , "handler fakeGateway for Gateway is"
  , "   operation capture cents is Receipt record{cents = cents} end operation"
  , "end handler"
  , "normalize :: Int32 -> Int32"
  , "function twice (x :: Int32) -> Integer is x + x end function\n"
  , "procedure checkout (cents :: Int32) -> Bool uses Gateway is"
  , "  first matching case of capture cents: when Receipt record{cents = paid} then paid = cents end case"
  , "end procedure"
  , "law checkoutCharges is"
  , "  definition: for all (cents :: Int32) => checkout cents = true end for all end definition"
  , "end law"
  , "law normalizing is"
  , "  definition: for all (x :: Int32) => normalize (normalize x) = normalize x end for all end definition"
  , "end law"
  , "law doubling is"
  , "  definition: for all (x :: Int32) => twice x = x * 2 end for all end definition"
  , "end law"
  , "\nend unit" ]

dependency :: String -> String -> [(K.Key, Value)] -> Value
dependency name kind extra = object (["name" .= name, "endpoint" .= ("localhost:9092" :: String), "reached" .= True, "kind" .= kind] ++
  [(k, v) | (k, v) <- extra])

standIn :: String -> Value
standIn level = object ["product" .= ("acme/gateway" :: String), "version" .= ("0.1.0" :: String), "conformance" .= level]

attestation :: [Value] -> Value
attestation dependencies = object
  [ "format" .= ("environment-attestation" :: String), "version" .= (1 :: Int), "environment" .= ("staging" :: String)
  , "run" .= object ["id" .= ("run-1" :: String), "started_at" .= ("2026-10-09T19:30:31.6Z" :: String)
                    , "recorded_at" .= ("2026-10-09T21:30:33+02:00" :: String)]
  , "unknownField" .= True
  , "dependencies" .= dependencies ]

check :: Maybe Value -> Value
check attested = checkWith attested []

-- | A check with the outcomes lawspec test recorded in the attestation's run.
checkWith :: Maybe Value -> [(String, String)] -> Value
checkWith attested outcomes = fromMaybe Null $ decode $ dispatch $ encode $ object $
  [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String),
    "verification" .= object ["layers" .= (["proof", "exhaustive", "property"] :: [String])],
    "method" .= ("check" :: String), "sources" .= [object ["path" .= ("a.lawspec" :: String), "content" .= spec]] ] ++
  [ "attestation" .= a | Just a <- [attested] ] ++
  [ "attestedOutcomes" .= object [K.fromString law .= outcome | (law, outcome) <- outcomes] | not (null outcomes) ]

-- | An attestation with fields added at the top level.
withFields :: [(K.Key, Value)] -> Value -> Value
withFields extra (Object o) = Object (foldr (\(k, v) -> KM.insert k v) o extra)
withFields _ v = v

digestOf :: Char -> String
digestOf c = "sha256:" ++ replicate 64 c

field :: String -> Value -> Maybe Value
field name (Object o) = KM.lookup (K.fromString name) o
field _ _ = Nothing

items :: Value -> [Value]
items response = case field "evidence" response of
  Just (Array xs) -> V.toList xs
  _ -> []

-- The evidence item of a declaration, by a fragment of its name.
item :: String -> Value -> Value
item fragment response = case [i | i <- items response, Just (String d) <- [field "declaration" i], fragment `isInfixOf` show d] of
  found : _ -> found
  [] -> Null

-- | An environment attestation says which laws were tested against stand-ins
-- rather than the real dependencies; it is reporting only, so it adds where
-- the tests ran and never changes a status. ref:DEC-environment-attestation
-- ref:REQ-environment-attestation
test_attestationReportsWhereTestsRanWithoutChangingEvidence :: Spec
test_attestationReportsWhereTestsRanWithoutChangingEvidence = describe "environment attestation" $ do
  let gateway = dependency "shop.orders::Gateway" "stand-in" ["stand_in" .= standIn "3"]
      normalize = dependency "shop.orders::normalize" "real" []
      unmatched = dependency "payments" "real" []
      attested = check (Just (attestation [gateway, normalize, unmatched]))
      plain = check Nothing
  it "plans production-handler dependencies without claiming a completed run" $ do
    field "diagnostics" attested `shouldBe` Just (Array V.empty)
    let law = item "[native]" attested
    field "status" law `shouldBe` Just (String "planned")
    field "environment" law `shouldBe` Nothing
    field "against" law `shouldBe` Nothing
    field "plannedEnvironment" law `shouldBe` Just (String "staging")
    fmap (fmap (field "dependency")) (field "plannedAgainst" law >>= arrayOf) `shouldBe` Just [Just (String "shop.orders::Gateway")]
    (field "plannedAgainst" law >>= arrayOf >>= firstOf >>= field "standIn" >>= field "conformance") `shouldBe` Just (String "3")
    (field "plannedEnvironmentRun" law >>= field "id") `shouldBe` Just (String "run-1")
  it "matches a native adapter a law calls" $
    (field "plannedAgainst" (item "normalizing" attested) >>= arrayOf >>= firstOf >>= field "kind") `shouldBe` Just (String "real")
  it "matches an ability a law reaches through a definition" $
    (field "plannedAgainst" (item "checkout" attested) >>= arrayOf >>= firstOf >>= field "dependency") `shouldBe` Just (String "shop.orders::Gateway")
  it "leaves a law under a spec handler, a proved law and other obligations unchanged" $ do
    field "plannedEnvironment" (item "[fakeGateway]" attested) `shouldBe` Nothing
    field "plannedEnvironment" (item "doubling" attested) `shouldBe` Nothing
    field "environment" (item "shop.orders::normalize\"" attested) `shouldBe` Nothing
  it "changes no status and no other field (the plane rule)" $ do
    let strip (Object o) = Object (foldr (KM.delete . K.fromString) o ["environment", "environmentRun", "against", "environmentProviders", "environmentOutcome", "plannedEnvironment", "plannedEnvironmentRun", "plannedAgainst", "plannedEnvironmentProviders"])
        strip v = v
    map strip (items attested) `shouldBe` items plain
    field "laws" attested `shouldBe` field "laws" plain
  it "reports each dependency with the obligations it touched, none when it matches nothing" $ do
    let deps = fromMaybe [] (field "attestation" attested >>= field "dependencies" >>= arrayOf)
    [ (field "dependency" d, fmap (length . fromMaybe [] . arrayOf) (field "plannedObligations" d)) | d <- deps ] `shouldBe`
      [ (Just (String "shop.orders::Gateway"), Just 2), (Just (String "shop.orders::normalize"), Just 1), (Just (String "payments"), Just 0) ]
    field "attestation" plain `shouldBe` Nothing
  it "rejects an unknown format, an unknown version and a document that breaks the rules" $ do
    let code response = case field "diagnostics" response >>= arrayOf of
          Just (d : _) -> (field "code" d, show (field "message" d))
          _ -> (Nothing, "")
        rejected doc needle = do
          let (c, m) = code (check (Just doc))
          c `shouldBe` Just (String "attestation")
          m `shouldSatisfy` isInfixOf needle
        with key value = case attestation [gateway] of
          Object o -> Object (KM.insert (K.fromString key) value o)
          v -> v
    rejected (with "format" (String "other")) "format must be"
    rejected (with "version" (Number 2)) "version 2 is not known"
    rejected (attestation [dependency "x" "stand-in" []]) "needs stand_in"
    rejected (attestation [dependency "x" "real" ["stand_in" .= standIn "1"]]) "has no stand_in"
    rejected (attestation [normalize, normalize]) "named twice"
    rejected (with "run" (object ["id" .= ("r" :: String), "started_at" .= ("yesterday" :: String), "recorded_at" .= ("2026-10-09T19:30:31Z" :: String)])) "RFC 3339"
    rejected (with "run" (object ["id" .= ("r" :: String), "started_at" .= ("2026-10-09T19:30:31Z" :: String), "recorded_at" .= ("2026-10-09T19:30:30Z" :: String)])) "before run.started_at"
  describe "a completed run" $ do
    let contract = object ["package" .= ("acme/gateway-contract" :: String), "version" .= ("1.0.0" :: String)]
        implemented kind = object ["kind" .= (kind :: String), "product" .= ("acme/gateway" :: String), "version" .= ("0.1.0" :: String)]
        twin = dependency "shop.orders::Gateway" "stand-in"
          [ "stand_in" .= object ["product" .= ("acme/gateway" :: String), "version" .= ("0.1.0" :: String), "conformance" .= ("3" :: String)
                                 , "history_digest" .= digestOf 'a', "stands_in_for" .= contract]
          , "node" .= ("gateway" :: String), "edge" .= ("shop-calls-gateway" :: String), "contract" .= contract
          , "implementation" .= implemented "fixture"
          , "completed" .= object ["reached" .= True, "history_digest" .= digestOf 'b', "history_entries" .= (4 :: Int)] ]
        real = dependency "shop.orders::normalize" "real" ["implementation" .= implemented "real-provider"]
        execution status code = "execution" .= object (["status" .= (status :: String)] ++ ["exit_code" .= c | Just c <- [code :: Maybe Int]] ++
          ["finished_at" .= ("2026-10-09T19:31:00Z" :: String) | status == "completed"])
        identities = [ "architecture" .= object ["document" .= ("shop.calm.json" :: String), "digest" .= digestOf 'c', "topology_digest" .= digestOf 'd']
                     , "application" .= object ["node" .= ("shop" :: String), "contract" .= contract, "implementation" .= implemented "application"] ]
        document status code = withFields (execution status code : identities) (attestation [twin, real])
        native = "shop.orders::law::checkoutCharges [native]"
        recorded = [(native, "passed"), ("shop.orders::law::normalizing", "failed")]
        completed = checkWith (Just (document "completed" (Just 0))) recorded
        law = item "checkoutCharges" completed
    it "links each law whose run id matches to that run, as completed, with its recorded outcome" $ do
      field "diagnostics" completed `shouldBe` Just (Array V.empty)
      field "plannedAgainst" law `shouldBe` Nothing
      field "environment" law `shouldBe` Just (String "staging")
      (field "environmentRun" law >>= field "id") `shouldBe` Just (String "run-1")
      (field "environmentRun" law >>= field "execution" >>= field "status") `shouldBe` Just (String "completed")
      (field "environmentRun" law >>= field "execution" >>= field "exitCode") `shouldBe` Just (Number 0)
      field "environmentOutcome" law `shouldBe` Just (String "passed")
      field "environmentOutcome" (item "normalizing" completed) `shouldBe` Just (String "failed")
      field "status" law `shouldBe` field "status" (item "checkoutCharges" (check Nothing))
    it "leaves a law with no recorded outcome in the run planned" $
      field "plannedEnvironment" (item "receiptAmount [native]" completed) `shouldBe` Just (String "staging")
    it "reports wiring alone, or a run under way, as planned even when outcomes are recorded" $
      forM_ [("wired", Nothing), ("running", Nothing)] $ \(status, code) -> do
        let planned = item "checkoutCharges" (checkWith (Just (document status code)) recorded)
        field "environment" planned `shouldBe` Nothing
        (field "plannedEnvironmentRun" planned >>= field "execution" >>= field "status") `shouldBe` Just (String (fromString status))
    it "identifies what each law ran against: the completed history, and the real provider or a fixture" $ do
      let gatewayOf o = field "against" o >>= arrayOf >>= firstOf
          ran = gatewayOf law >>= field "ranAgainst"
      (ran >>= field "provider") `shouldBe` Just (String "fixture")
      (ran >>= field "historyDigest") `shouldBe` Just (String (fromString (digestOf 'b')))
      (ran >>= field "historyFrom") `shouldBe` Just (String "completed")
      (gatewayOf law >>= field "contract" >>= field "package") `shouldBe` Just (String "acme/gateway-contract")
      (gatewayOf law >>= field "standIn" >>= field "standsInFor" >>= field "version") `shouldBe` Just (String "1.0.0")
      (gatewayOf law >>= field "node") `shouldBe` Just (String "gateway")
      field "environmentProviders" law `shouldBe` Just (toJSON ["fixture" :: String])
      field "environmentProviders" (item "normalizing" completed) `shouldBe` Just (toJSON ["real-provider" :: String])
      let withoutCompleted = item "checkoutCharges" (checkWith (Just (withFields [execution "completed" (Just 0)]
            (attestation [dependency "shop.orders::Gateway" "stand-in" ["stand_in" .= object ["product" .= ("p" :: String), "version" .= ("1" :: String)
              , "conformance" .= ("1" :: String), "history_digest" .= digestOf 'a']]]))) recorded)
      (gatewayOf withoutCompleted >>= field "ranAgainst" >>= field "historyFrom") `shouldBe` Just (String "stand-in")
    it "reports the architecture, application and run identities" $ do
      let view = field "attestation" completed
      (view >>= field "architecture" >>= field "topologyDigest") `shouldBe` Just (String (fromString (digestOf 'd')))
      (view >>= field "application" >>= field "implementation" >>= field "kind") `shouldBe` Just (String "application")
      (view >>= field "run" >>= field "execution" >>= field "status") `shouldBe` Just (String "completed")
      [ (field "dependency" d, fmap (length . fromMaybe [] . arrayOf) (field "obligations" d))
        | d <- fromMaybe [] (view >>= field "dependencies" >>= arrayOf) ] `shouldBe`
        [ (Just (String "shop.orders::Gateway"), Just 1), (Just (String "shop.orders::normalize"), Just 1) ]
    it "rejects an execution that breaks the rules and an implementation that contradicts the kind" $ do
      let rejected doc needle = case field "diagnostics" (check (Just doc)) >>= arrayOf of
            Just (d : _) -> show (field "message" d) `shouldSatisfy` isInfixOf needle
            _ -> expectationFailure "accepted"
      rejected (withFields [execution "completed" Nothing] (attestation [twin])) "needs exit_code"
      rejected (withFields [execution "wired" (Just 1)] (attestation [twin])) "has no exit_code"
      rejected (withFields [execution "finished" Nothing] (attestation [twin])) "is not wired, running or completed"
      rejected (attestation [dependency "x" "real" ["implementation" .= implemented "fixture"]]) "a fixture does not implement it"
  where
    arrayOf (Array xs) = Just (V.toList xs)
    arrayOf _ = Nothing
    firstOf (x : _) = Just x
    firstOf [] = Nothing
