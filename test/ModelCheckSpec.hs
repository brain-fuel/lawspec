-- | Laws about a model's runs (law n in model m ... every run holds P),
-- checked over the model's reference by the in-house explicit-state search
-- (LawSpec.Core.ModelCheck), with weak and strong fairness.
module ModelCheckSpec (test_modelChecking) where

import Data.Aeson (Value(..), object, (.=), decode, encode)
import qualified Data.Aeson.KeyMap as K
import Data.Foldable (toList)
import Data.List (isInfixOf, isSuffixOf)
import qualified Data.Text as T
import Test.Hspec
import qualified LawSpec.Api as API

check :: String -> Maybe Value
check source = decode (API.dispatch (encode (object
  [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("check" :: String)
  , "verification" .= object ["layers" .= ["exhaustive" :: String]]
  , "sources" .= [object ["path" .= ("model.lawspec" :: String), "content" .= source]] ])))

-- | A law's row: its status and reason.
row :: String -> Maybe Value -> Maybe (String, String)
row law response = case response of
  Just (Object r) | Just (Array rows) <- K.lookup "evidence" r ->
    case [ (T.unpack s, T.unpack why) | Object o <- toList rows, K.lookup "stage" o == Just (String "law")
         , Just (String d) <- [K.lookup "declaration" o], ("::law::\"|" ++ law ++ "|") `isSuffixOf` T.unpack d
         , Just (String s) <- [K.lookup "status" o], Just (String why) <- [K.lookup "reason" o] ] of
      found : _ -> Just found
      [] -> Nothing
  _ -> Nothing

diagnostics :: Maybe Value -> [String]
diagnostics response = case response of
  Just (Object r) | Just (Array ds) <- K.lookup "diagnostics" r -> [T.unpack m | Object d <- toList ds, Just (String m) <- [K.lookup "message" d]]
  _ -> []

-- | A three-state model: flip moves 0 and 1 back and forth, and go is
-- enabled only at 1 and leads to 2.
toggle :: String -> String
toggle law = unlines
  [ "unit portfolio.toggle\n"
  , "type Box is a record{ id :: Int32 } end type"
  , "newBox :: Unit -> Box"
  , "flip :: Box -> Unit"
  , "go :: Box -> Unit"
  , "function flipped (s :: Int8 where s >= 0 && s <= 1) -> Int8 is 1 - s end function"
  , "function done (s :: Int8) -> Int8 is 2 end function"
  , "function canFlip (s :: Int8) -> Bool is s < 2 end function"
  , "function isOne (s :: Int8) -> Bool is s = 1 end function"
  , "function isTwo (s :: Int8) -> Bool is s = 2 end function"
  , "model box :: shared Box by Int8 is"
  , "  start newBox ~ 0"
  , "  flip ~ flipped when canFlip"
  , "  go ~ done when isOne"
  , "end model\n"
  , law
  , "end unit" ]

test_modelChecking :: Spec
test_modelChecking = describe "model checking" $ do
  describe "portfolio 13.7, the order workflow" $ do
    response <- runIO (check <$> readFile "test/fixtures/order-workflow.lawspec")
    it "proves invariants and orderings over every reachable state" $ do
      row "nothing ships unpaid" response `shouldBe` Just ("proved", "every run holds it: all 6 states explored")
      fmap fst (row "cancelled orders stay cancelled" response) `shouldBe` Just "proved"
      fmap fst (row "paid orders are never cancelled" response) `shouldBe` Just "proved"
    it "proves a liveness claim under weak fairness, and refutes it without, with the run" $ do
      row "validated orders finish, given fair authorization" response
        `shouldBe` Just ("proved", "every run holds it under fairness for authorize: all 6 states explored")
      row "validated orders finish" response `shouldBe` Just ("refuted", "a run breaks it: validate, decline, (decline)")
      diagnostics response `shouldSatisfy` any (isInfixOf "a run breaks it")
    it "shows a run that holds a some-run law" $
      row "an order can be fulfilled" response `shouldSatisfy` maybe False (\(s, why) -> s == "proved" && "validate, authorize, capture, fulfil" `isInfixOf` why)
  it "refutes a mutant that ships before payment, with the invalid steps" $ do
    source <- readFile "test/fixtures/order-workflow.lawspec"
    let mutant = replace "  fulfil ~ toFulfilled when isCaptured" "  fulfil ~ toFulfilled when isAuthorized" source
    row "nothing ships unpaid" (check mutant) `shouldBe` Just ("refuted", "a run breaks it: validate, authorize, fulfil, then stays")
  it "needs strong fairness when a command is enabled only again and again" $ do
    let law fairness = "law \"|it ends| in model box" ++ fairness ++ " is\n  definition: every run holds eventually isTwo end definition\nend law\n"
    fmap fst (row "it ends" (check (toggle (law "")))) `shouldBe` Just "refuted"
    fmap fst (row "it ends" (check (toggle (law " assuming fairness for go")))) `shouldBe` Just "refuted"
    row "it ends" (check (toggle (law " assuming strong fairness for go"))) `shouldBe` Just ("proved", "every run holds it under strong fairness for go: all 3 states explored")
  it "refutes a some-run law no run holds, after exploring every state" $
    row "it never ends" (check (toggle "law \"|it never ends| in model box is\n  definition: some run holds always (isOne and not isOne) end definition\nend law\n"))
      `shouldBe` Just ("refuted", "no run holds it: all 3 states explored")
  it "names an unknown model, command or predicate" $ do
    diagnostics (check (toggle "law \"|x| in model nothing is\n  definition: every run holds always isOne end definition\nend law\n"))
      `shouldSatisfy` any (isInfixOf "the unit has no model nothing")
    diagnostics (check (toggle "law \"|x| in model box assuming fairness for jump is\n  definition: every run holds always isOne end definition\nend law\n"))
      `shouldSatisfy` any (isInfixOf "the model has no command jump")
    diagnostics (check (toggle "law \"|x| in model box is\n  definition: every run holds always isThree end definition\nend law\n"))
      `shouldSatisfy` any (isInfixOf "no property or predicate isThree")
  where
    replace old new text = case breakOn old text of
      Just (before, after) -> before ++ new ++ drop (length old) after
      Nothing -> text
    breakOn needle haystack = go "" haystack
      where go acc rest | needle `isPrefixOfS` rest = Just (reverse acc, rest)
                        | otherwise = case rest of c : more -> go (c : acc) more; [] -> Nothing
            isPrefixOfS a b = take (length a) b == a
