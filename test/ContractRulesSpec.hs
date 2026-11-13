-- | Record rules, validators and masking (LawSpec.ContractRules).
module ContractRulesSpec (test_recordRulesBecomeCheckedValidators) where

import Data.Aeson (Value(..), decode, encode, object, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Control.Monad (forM_)
import Data.Foldable (toList)
import Data.List (isInfixOf, isSuffixOf, sort)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Test.Hspec
import LawSpec.Api (dispatch)
import LawSpec.Blake3 (blake3Keyed, hexOf)
import LawSpec.Compile
import LawSpec.ContractRules
import qualified LawSpec.Core as C
import LawSpec.Core.Types (makeRegistry)
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Scalar as V
import LawSpec.Data (elaborateDataDeclarations)
import LawSpec.Model hiding (Expectation)
import LawSpec.Regex (parseRegex, regexMatches, regexSamples)
import LawSpec.Testing (constrainedBoundaries)

check :: [String] -> Either [Diagnostic] ([Unit], [Expanded])
check body = compile [Source "source.lawspec" (unlines (["unit probe.rules", ""] ++ body ++ ["end unit"]))]

-- | The unit the test wrote, among the built-in units compiled with it.
probe :: [Unit] -> Unit
probe units = head ([unit | unit <- units, unitName unit == "probe.rules"] ++ error "the probe unit is missing")

refused :: [String] -> String -> Expectation
refused body expected = case check body of
  Left diagnostics -> concatMap message diagnostics `shouldSatisfy` isInfixOf expected
  Right _ -> expectationFailure ("expected a diagnostic saying: " ++ expected)

-- | The files and warnings of a generation request for one target.
planned :: String -> [String] -> ([(String, String)], [String])
planned target body = case decode (dispatch (encode (object
    [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("planGeneration" :: String)
    , "target" .= target
    , "verification" .= object ["layers" .= (["property", "examples"] :: [String])]
    , "sources" .= [object ["path" .= ("probe.lawspec" :: String), "content" .= unlines (["unit probe.rules", ""] ++ body ++ ["end unit"])]] ]))) of
  Just (Object response) ->
    ( [ (text (look "path" file), text (look "content" file)) | Just (Array files) <- [KM.lookup "files" response], Object file <- toList files ]
    , [ text (look "code" row) ++ ": " ++ text (look "message" row) | Just (Array rows) <- [KM.lookup "warnings" response], Object row <- toList rows ] )
  _ -> ([], ["no response"])
  where
    look name fields = KM.lookup (K.fromString name) fields
    text value = case value of
      Just (String content) -> T.unpack content
      _ -> ""

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
    refused (card ["  pin shown as hash"]) "pin is not a Text, so it can only be shown as hidden"
    refused (card ["  pin shown as last 2"]) "pin is not a Text, so it can only be shown as hidden"
    refused (card ["  number shown as last 0"]) "shows nothing; write hidden"
    refused (card ["  cvv shown as hidden"]) "the record has no field cvv"
    refused (card ["  pin shown as hidden", "  pin shown as hidden"]) "a field is masked twice"
  it "refuse a masking block for a record the unit does not declare" $
    refused ["masking Card is", "  pin shown as hidden", "end masking"] "this unit declares no such record"
  it "mask a Java record's toString and name the unmasked rendering" $ do
    let (files, warnings) = planned "java" (card ["  number shown as last 4", "  pin shown as hidden"])
        record = concat [content | (path, content) <- files, "lawspec/data/Card.java" `isInfixOf` path]
    warnings `shouldBe` []
    record `shouldSatisfy` isInfixOf "public String toString()"
    record `shouldSatisfy` isInfixOf "\"Card{number=\" + lawspec.runtime.LawSpecMasks.last(4, number)"
    record `shouldSatisfy` isInfixOf "+ \", pin=***\""
    record `shouldSatisfy` isInfixOf "public String toUnmaskedString()"
    map fst files `shouldSatisfy` any (isInfixOf "lawspec-logback/lawspec/logging/LawSpecMaskedConverter.java")
    concat [content | (path, content) <- files, "LawSpecDataSchema.java" `isInfixOf` path]
      `shouldSatisfy` isInfixOf "LawSpecRuntime.maskFields(\"probe.rules::type::Card::Card\", 0, 1);"
  it "leave a Java record without a masking block as it was" $ do
    let (files, _) = planned "java" ["type Plain is a record{pin :: Int32} end type", "function f (p :: Plain) -> Int32 is p.pin end function"]
        record = concat [content | (path, content) <- files, "lawspec/data/Plain.java" `isInfixOf` path]
    record `shouldSatisfy` isInfixOf "java.lang.Integer pin) {}"
    map fst files `shouldSatisfy` all (not . isInfixOf "LawSpecMask")
  it "mask the native renderings of JavaScript and Python classes, not their wire form" $ do
    let masks = card ["  number shown as last 4", "  pin shown as hidden"]
        web = concat [content | (path, content) <- fst (planned "javascript" masks), "lawspec_data.mjs" `isInfixOf` path]
        python = concat [content | (path, content) <- fst (planned "python" masks), "lawspec_data.py" `isInfixOf` path]
    web `shouldSatisfy` isInfixOf "ls.maskLast(4, this.number)"
    web `shouldSatisfy` isInfixOf "[Symbol.for('nodejs.util.inspect.custom')]()"
    web `shouldSatisfy` isInfixOf "toUnmaskedString()"
    web `shouldSatisfy` (not . isInfixOf "toJSON")
    web `shouldSatisfy` isInfixOf "ls.maskFields('probe.rules::type::Card::Card', [0, 1]);"
    python `shouldSatisfy` isInfixOf "def __repr__(self)"
    python `shouldSatisfy` isInfixOf "ls.mask_last(4, self.number)"
    python `shouldSatisfy` isInfixOf "def unmasked_repr(self)"
    python `shouldSatisfy` isInfixOf "ls.mask_fields(\"probe.rules::type::Card::Card\", [0, 1])"
  it "show a hashed field as a keyed digest natively and hide it in the checked rendering" $ do
    let masks = card ["  number shown as hash"]
        file target name = concat [content | (path, content) <- fst (planned target masks), name `isInfixOf` path]
    file "java" "lawspec/data/Card.java" `shouldSatisfy` isInfixOf "\"Card{number=\" + lawspec.runtime.LawSpecMasks.hash(number)"
    file "javascript" "lawspec_data.mjs" `shouldSatisfy` isInfixOf "ls.maskHash(this.number)"
    file "typescript" "lawspec_data.ts" `shouldSatisfy` isInfixOf "ls.maskHash(this.number)"
    file "python" "lawspec_data.py" `shouldSatisfy` isInfixOf "ls.mask_hash(self.number)"
    snd (planned "kotlin" masks) `shouldSatisfy` any (isInfixOf "A field shown as hash is hidden on this target")
    -- No generated file holds a key: the application sets one when it starts.
    concatMap snd (fst (planned "java" masks)) `shouldSatisfy` (not . isInfixOf "setHashKey(new byte")
  it "hash with keyed BLAKE3 as the fixture every runtime is tested against records" $ do
    fixture <- BL.readFile "test/fixtures/blake3-keyed-text.json"
    let rows name = case decode fixture of
          Just (Object fields) | Just (Array cases) <- KM.lookup name fields ->
            [ (truncate count :: Int, T.unpack hash)
            | Object row <- toList cases, Just (A.Number count) <- [KM.lookup "count" row], Just (String hash) <- [KM.lookup "hash" row] ]
          _ -> []
        key = T.encodeUtf8 (T.pack "whats the Elvish word for friend")
        keyed text = maybe "" hexOf (blake3Keyed key (T.encodeUtf8 (T.pack text)))
    length (rows "letters") `shouldBe` 11
    [(count, keyed (take count (cycle ['a' .. 'z']))) | (count, _) <- rows "letters"] `shouldBe` rows "letters"
    [(count, keyed (concat (replicate count "a\233\8364\128512"))) | (count, _) <- rows "mixed"] `shouldBe` rows "mixed"
    -- The first two keyed hashes of BLAKE3's published test vectors (key as
    -- above, inputs of no bytes and of the byte 0), written from memory:
    -- this repository holds no copy of the keyed vectors to read them from.
    fmap hexOf (blake3Keyed key B.empty) `shouldBe` Just "92b2b75604ed3c761f9d6f62392c8a9227ad0ea3f09573e783f1498a4ed60d26"
    fmap hexOf (blake3Keyed key (B.pack [0])) `shouldBe` Just "6d7878dfff2f485635d39013278ae14f1454b8c0a3a2d34bc1ab38228a80c95b"
    blake3Keyed (B.pack [1, 2, 3]) B.empty `shouldBe` Nothing
    -- Each runtime's own test compares its digests with these rows.
    forM_ [ "acceptance/contracts-masking/java/native/src/test/java/example/MaskedRenderingTest.java"
          , "acceptance/contracts-masking/javascript/native/test/masked_rendering.test.mjs"
          , "acceptance/contracts-masking/typescript/native/test/masked_rendering.test.ts"
          , "acceptance/contracts-masking/python/native/tests/test_masked_rendering.py" ] $ \path -> do
      native <- readFile path
      [hash | (_, hash) <- rows "letters" ++ rows "mixed", not (hash `isInfixOf` native)] `shouldBe` []
  it "say so on a target whose native rendering is not masked" $ do
    let (files, warnings) = planned "kotlin" (card ["  pin shown as hidden"])
    files `shouldSatisfy` (not . null)
    warnings `shouldSatisfy` any (\warning -> "target-unsupported: kotlin: the masking block of Card" `isInfixOf` warning)
    snd (planned "kotlin" ["type Plain is a record{pin :: Int32} end type", "function f (p :: Plain) -> Int32 is p.pin end function"])
      `shouldBe` []
  it "hide a sentinel no source can write by accident" $
    maskSentinel `shouldBe` "<lawspec-masked-sentinel>"
  it "find boundary records of many restricted fields by settling each field alone" $ do
    -- Few of a field's seeds pass its own pattern, so whole records tried
    -- blindly almost never pass all four: the search keeps, per field, the
    -- seeds that field's restrictions accept before it combines them.
    let body =
          [ "type Parcel is a record{"
          , "  sender :: (v :: Text where v matches regex \"[A-Z]{2}[0-9]{4}\"),"
          , "  receiver :: (v :: Text where v matches regex \"[a-z]{3}-[0-9]{2}\"),"
          , "  depot :: (v :: Text where v matches regex \"D[0-9]{3}\"),"
          , "  weight :: (v :: Int32 where 1 <= v && v <= 30),"
          , "  note :: Text}"
          , "end type" ]
        parcel declarations = head ([name | name <- map (C.idText . C.dataId) declarations, "Parcel" `isSuffixOf` name] ++ ["Parcel"])
        matching pattern value = case (parseRegex pattern, value) of
          (Right regex, V.ScalarValue (V.SSequence _ text)) -> regexMatches regex text
          _ -> False
    case check body of
      Left diagnostics -> expectationFailure (concatMap message diagnostics)
      Right (units, _) -> case elaborateDataDeclarations units of
       Left diagnostics -> expectationFailure (concatMap message diagnostics)
       Right declarations -> case makeRegistry declarations of
        Left text -> expectationFailure text
        Right registry -> case constrainedBoundaries registry 64 (C.Constructor (parcel declarations) []) of
          Left text -> expectationFailure text
          Right values -> do
            length values `shouldSatisfy` (> 1)
            [ value | value@(V.DataValue _ _ [sender, receiver, depot, V.ScalarValue (V.SInteger _ weight), _]) <- values
                    , matching "[A-Z]{2}[0-9]{4}" sender, matching "[a-z]{3}-[0-9]{2}" receiver
                    , matching "D[0-9]{3}" depot, 1 <= weight, weight <= 30 ] `shouldBe` values
  it "sample a repetition inside a repetition briefly, and every sample still matches" $ do
    let samples pattern = either (const []) (regexSamples 200) (parseRegex pattern)
        accepted pattern text = either (const False) (`regexMatches` map fromEnum text) (parseRegex pattern)
    -- An open repetition adds at most six turns; one level in, two; deeper, one.
    maximum (map length (samples "a{2,}")) `shouldBe` 8
    maximum (map length (samples "a{2,3}")) `shouldBe` 3
    maximum (map length (samples "(a{0,}){0,}")) `shouldSatisfy` (<= 12)
    maximum (map length (samples "((a{1,}){1,}){1,}")) `shouldSatisfy` (<= 28)
    forM_ ["a{2,}", "(a{0,}b){0,}", "((a{1,}){1,}c){1,}", "([a-z]+(\\.[a-z]+)*@)+x"] $ \pattern ->
      [text | text <- samples pattern, not (accepted pattern text)] `shouldBe` []
  it "prove a field's length and pattern from a text literal" $ do
    let coded value =
          [ "type Code is a record{code :: (v :: Text where prelude.length v <= 8 && v matches regex \"[A-Z]{2}-[0-9]+\")}"
          , "end type"
          , "function fixed (u :: Unit) -> Code is Code record{code = \"" ++ value ++ "\"}"
          , "end function" ]
    either (concatMap message) (const "") (check (coded "GB-12")) `shouldBe` ""
    refused (coded "GB-1234567") "constructor field refinement could not be proved"
    refused (coded "gb-12") "constructor field refinement could not be proved"
