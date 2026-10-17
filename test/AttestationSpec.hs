-- | Environment attestations in the compiler API's evidence.
module AttestationSpec (test_attestationReportsWhereTestsRanWithoutChangingEvidence) where

import Data.Aeson (Value(..), decode, encode, object, (.=))
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
  , "type Receipt is a record{cents :: Int32} end type"
  , "ability Gateway is"
  , "  capture :: Int32 -> Receipt"
  , "laws"
  , "  law receiptAmount is"
  , "    definition: for all (cents :: Int32) => capture cents = Receipt record{cents = cents} end end"
  , "  end"
  , "end"
  , "handler fakeGateway for Gateway is"
  , "  capture cents is Receipt record{cents = cents} end"
  , "end"
  , "normalize :: Int32 -> Int32"
  , "function twice (x :: Int32) -> Integer is x + x end function"
  , "procedure checkout (cents :: Int32) -> Bool uses Gateway is"
  , "  first matching case of capture cents: when Receipt record{cents = paid} then paid = cents end case"
  , "end procedure"
  , "law checkoutCharges is"
  , "  definition: for all (cents :: Int32) => checkout cents = true end end"
  , "end"
  , "law normalizing is"
  , "  definition: for all (x :: Int32) => normalize (normalize x) = normalize x end end"
  , "end"
  , "law doubling is"
  , "  definition: for all (x :: Int32) => twice x = x * 2 end end"
  , "end" ]

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
check attested = fromMaybe Null $ decode $ dispatch $ encode $ object $
  [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.1" :: String),
    "verification" .= object ["layers" .= (["proof", "exhaustive", "property"] :: [String])],
    "method" .= ("check" :: String), "sources" .= [object ["path" .= ("a.lawspec" :: String), "content" .= spec]] ] ++
  [ "attestation" .= a | Just a <- [attested] ]

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
    let strip (Object o) = Object (foldr (KM.delete . K.fromString) o ["environment", "environmentRun", "against", "plannedEnvironment", "plannedEnvironmentRun", "plannedAgainst"])
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
  where
    arrayOf (Array xs) = Just (V.toList xs)
    arrayOf _ = Nothing
    firstOf (x : _) = Just x
    firstOf [] = Nothing
