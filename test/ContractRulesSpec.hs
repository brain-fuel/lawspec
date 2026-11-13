-- | Record rules, validators and masking (LawSpec.ContractRules).
module ContractRulesSpec (test_recordRulesBecomeCheckedValidators) where

import Data.List (isInfixOf, sort)
import Test.Hspec
import LawSpec.Compile
import LawSpec.ContractRules
import LawSpec.Model hiding (Expectation)

check :: [String] -> Either [Diagnostic] ([Unit], [Expanded])
check body = compile [Source "source.lawspec" (unlines (["unit probe.rules", ""] ++ body ++ ["end unit"]))]

-- | The unit the test wrote, among the built-in units compiled with it.
probe :: [Unit] -> Unit
probe units = head ([unit | unit <- units, unitName unit == "probe.rules"] ++ error "the probe unit is missing")

refused :: [String] -> String -> Expectation
refused body expected = case check body of
  Left diagnostics -> concatMap message diagnostics `shouldSatisfy` isInfixOf expected
  Right _ -> expectationFailure ("expected a diagnostic saying: " ++ expected)

account :: [String]
account =
  [ "function validName (name :: Text) -> Bool is name matches regex \"[A-Z][a-z]{0,9}\""
  , "end function"
  , "type Account is a record{"
  , "  name :: (v :: Text where validName v),"
  , "  email :: (v :: Text where v matches format email),"
  , "  age :: (v :: Int32 where 18 <= v && v <= 120),"
  , "  plan :: (v :: Text where v in [\"free\", \"pro\"]),"
  , "  code :: (v :: Text where v matches regex \"[A-Z]{2}[0-9]{2,8}\" as shape && prelude.length v <= 6),"
  , "  vatId :: Text}"
  , "  rule vatForPro is plan != \"pro\" || vatId != \"\""
  , "end type" ]

vatExample :: [String]
vatExample =
  [ "function ann (u :: Unit) -> AccountDraft is"
  , "  AccountDraft record{name = \"Ann\", email = \"ann@example.org\", age = 30, plan = \"pro\", code = \"GB12\", vatId = \"GB1\"}"
  , "end function"
  , "law \"|a professional plan needs a VAT id| is"
  , "  definition :"
  , "    validateAccount (ann () with vatId = \"\") fails with vatForPro"
  , "  end definition"
  , "end law" ]

card :: [String] -> [String]
card masks =
  [ "type Card is a record{"
  , "  number :: (v :: Text where v matches regex \"[0-9]{13,19}\"),"
  , "  pin :: Int32}"
  , "end type"
  , "masking Card is" ] ++ masks ++ ["end masking"]

-- | A record's restrictions are its rules: each has a stable id, the
-- validator reports every one a draft breaks, and what is not generated is
-- refused by name. ref:DEC-record-rules ref:DEC-masking
test_recordRulesBecomeCheckedValidators :: Spec
test_recordRulesBecomeCheckedValidators = describe "record rules" $ do
  it "are asked for by naming what they generate" $ do
    contractDemand "law \"|x| is definition: validateAccount d = Right a end definition end law" `shouldBe` ["validateAccount"]
    sort (contractDemand "f (d :: CardDraft) = other.maskedCard (draftOfCard d) <> violationsOfCard d")
      `shouldBe` ["CardDraft", "draftOfCard", "maskedCard", "violationsOfCard"]
    contractDemand "-- validateAccount\nfunction validate (masked :: Text) -> Text is \"draftOfCard\" end function" `shouldBe` []
    contractNames "Card" `shouldBe` ["CardDraft", "validateCard", "violationsOfCard", "draftOfCard", "maskedCard", "maskedCardDraft"]
  it "join the built-in unit only to a program that uses them" $ do
    usesRules "type T is one of | A end type" `shouldBe` False
    usesRules "masking Card is pin shown as hidden end masking" `shouldBe` True
    usesRules "x fails with age.min" `shouldBe` True
    usesRules "function f (u :: Unit) -> Unit fails with Missing is u end function" `shouldBe` False
    usesRules "prelude.violatedRules vs" `shouldBe` True
    programUsesRules ["type Order is a record{id :: Text} end type", "f d = validateOrder d"] `shouldBe` True
    programUsesRules ["type Account is a record{id :: Text} end type", "validateOrder :: Text -> Bool"] `shouldBe` False
    programUsesRules ["type Card is a record{pin :: Int32} end type\nf (d :: CardDraft) = maskedCardDraft d"] `shouldBe` True
  it "have ids from the field and the restriction, a label, or the rule's name" $
    case check (account ++ vatExample) of
      Left diagnostics -> expectationFailure (concatMap message diagnostics)
      Right (units, _) -> do
        let [contract] = recordContracts (probe units)
        contractRecord contract `shouldBe` "Account"
        map contractRuleId (contractRules contract) `shouldBe`
          ["name.validName", "email.email", "age.min", "age.max", "plan.oneOf", "code.shape", "code.maxLength", "vatForPro"]
        [contractRuleField rule | rule <- contractRules contract, contractRuleId rule `elem` ["age.min", "vatForPro"]]
          `shouldBe` [Just "age", Nothing]
  it "generate the draft, the validator and a law for each rule nobody gave an example of" $
    case check (account ++ vatExample) of
      Left diagnostics -> expectationFailure (concatMap message diagnostics)
      Right (units, _) -> do
        let unit = probe units
        map dataTypeName (dataTypes unit) `shouldContain` ["AccountDraft"]
        map fst (functions unit) `shouldSatisfy` \names -> all (`elem` names) ["validateAccount", "violationsOfAccount", "draftOfAccount"]
        map lawName (laws unit) `shouldSatisfy` \names ->
          all (`elem` names) ["Account passes its own validator", "Account reports age.min alone", "Account reports code.shape alone"]
          && "Account reports vatForPro alone" `notElem` names
  it "generate nothing for a record nobody validates" $
    case check account of
      Left diagnostics -> expectationFailure (concatMap message diagnostics)
      Right (units, _) -> do
        map contractGenerated (recordContracts (probe units)) `shouldBe` [False]
        map dataTypeName (dataTypes (probe units)) `shouldBe` ["Account"]
        map lawName (laws (probe units)) `shouldBe` []
  it "refuse a whole-record rule that no example breaks" $
    refused (account ++ ["function f (d :: AccountDraft) -> Bool is violationsOfAccount d = [] end function"])
      "give an example that ends `fails with vatForPro`"
  it "refuse two rules with one id, and say how to name one" $
    refused [ "type T is a record{code :: (v :: Text where v matches regex \"[A-Z]+\" && v matches regex \".{2,4}\")}", "end type"
            , "function f (d :: TDraft) -> Bool is violationsOfT d = [] end function" ]
      "two rules are both code.pattern"
  it "refuse a format that does not exist" $
    refused ["type T is a record{address :: (v :: Text where v matches format mailbox)}", "end type"]
      "there is no format called mailbox"
  it "mask a record's fields in its rendering and add a law for each masked field" $
    case check (card ["  number shown as last 4", "  pin shown as hidden"]) of
      Left diagnostics -> expectationFailure (concatMap message diagnostics)
      Right (units, _) -> do
        let unit = probe units
            [contract] = recordContracts unit
        contractMasks contract `shouldBe` [("number", MaskLast 4), ("pin", MaskHidden)]
        map fst (functions unit) `shouldSatisfy` \names -> all (`elem` names) ["maskedCard", "maskedCardDraft"]
        map lawName (laws unit) `shouldSatisfy` \names -> all (`elem` names) ["Card masks number", "Card hides pin"]
  it "refuse a mask it cannot generate, by name" $ do
    refused (card ["  number shown as hash"]) "`hash` is not generated on any target yet"
    refused (card ["  pin shown as last 2"]) "pin is not a Text, so it can only be shown as hidden"
    refused (card ["  number shown as last 0"]) "shows nothing; write hidden"
    refused (card ["  cvv shown as hidden"]) "the record has no field cvv"
    refused (card ["  pin shown as hidden", "  pin shown as hidden"]) "a field is masked twice"
  it "refuse a masking block for a record the unit does not declare" $
    refused ["masking Card is", "  pin shown as hidden", "end masking"] "this unit declares no such record"
  it "hide a sentinel no source can write by accident" $
    maskSentinel `shouldBe` "<lawspec-masked-sentinel>"
