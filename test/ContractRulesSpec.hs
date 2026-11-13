-- | Record rules, validators and masking (LawSpec.ContractRules).
module ContractRulesSpec (test_recordRulesBecomeCheckedValidators) where

import Data.Aeson (Value(..), decode, encode, object, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Control.Monad (forM_)
import Data.Foldable (toList)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, sort)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Test.Hspec
import LawSpec.Api (dispatch)
import qualified LawSpec.Backend as Backend
import LawSpec.Blake3 (blake3, blake3DeriveKey, blake3Keyed, hexOf)
import LawSpec.Compile
import LawSpec.ContractRules
import qualified LawSpec.Core as C
import LawSpec.Core.Semantics (helperValue)
import LawSpec.Core.Types (makeRegistry)
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Scalar as V
import LawSpec.Data (elaborateDataDeclarations)
import qualified LawSpec.MaskAdvice as MaskAdvice
import LawSpec.Model hiding (Expectation)
import qualified LawSpec.Model as M
import LawSpec.PreludeNames (sequencePreludeHelpers)
import LawSpec.Regex (parseRegex, regexMatches, regexSamples)
import LawSpec.Scaffold (scaffoldFiles)
import LawSpec.Targets (programTargets)
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

-- | The advice findings of a check, each as its rule and message.
advised :: [String] -> [String]
advised body = case decode (dispatch (encode (object
    [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("check" :: String)
    , "sources" .= [object ["path" .= ("probe.lawspec" :: String), "content" .= unlines (["unit probe.rules", ""] ++ body ++ ["end unit"])]] ]))) of
  Just (Object response) | Just (Object advice) <- KM.lookup "advice" response, Just (Array findings) <- KM.lookup "findings" advice ->
    [ text (KM.lookup "rule" row) ++ ": " ++ text (KM.lookup "message" row) | Object row <- toList findings ]
  _ -> ["no advice"]
  where
    text value = case value of
      Just (String content) -> T.unpack content
      _ -> ""

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

-- | The diagnostics of a generation request for one target.
diagnosed :: String -> [String] -> [String]
diagnosed target body = case decode (dispatch (encode (object
    [ "schemaVersion" .= (5 :: Int), "languageProfile" .= ("1.0-rc.2" :: String), "method" .= ("planGeneration" :: String)
    , "target" .= target
    , "verification" .= object ["layers" .= (["property", "examples"] :: [String])]
    , "sources" .= [object ["path" .= ("probe.lawspec" :: String), "content" .= unlines (["unit probe.rules", ""] ++ body ++ ["end unit"])]] ]))) of
  Just (Object response) ->
    [ text (KM.lookup "code" row) ++ ": " ++ text (KM.lookup "message" row) | Just (Array rows) <- [KM.lookup "diagnostics" response], Object row <- toList rows ]
  _ -> ["no response"]
  where
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
    contractNames "Card" `shouldBe` ["CardDraft", "validateCard", "violationsOfCard", "draftOfCard", "maskedCard", "maskedCardDraft", "maskedCardWith", "maskedCardDraftWith"]
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
    record `shouldSatisfy` isInfixOf "\"Card{number=\" + lawspec.runtime.LawSpecMasks.maskLast(4, number)"
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
    file "java" "lawspec/data/Card.java" `shouldSatisfy` isInfixOf "\"Card{number=\" + lawspec.runtime.LawSpecMasks.maskHash(number)"
    file "javascript" "lawspec_data.mjs" `shouldSatisfy` isInfixOf "ls.maskHash(this.number)"
    file "typescript" "lawspec_data.ts" `shouldSatisfy` isInfixOf "ls.maskHash(this.number)"
    file "python" "lawspec_data.py" `shouldSatisfy` isInfixOf "ls.mask_hash(self.number)"
    snd (planned "kotlin" masks) `shouldSatisfy` any (isInfixOf "A field shown as hash is hidden in this target's native rendering")
    -- No generated file holds a key: the application sets one when it starts.
    concatMap snd (fst (planned "java" masks)) `shouldSatisfy` (not . isInfixOf "setMaskHashKey(new byte")
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
    blake3Keyed (B.pack [1, 2, 3]) B.empty `shouldBe` Nothing
    -- Each runtime's own test compares its digests with these rows.
    forM_ [ "acceptance/contracts-masking/java/native/src/test/java/example/MaskedRenderingTest.java"
          , "acceptance/contracts-masking/javascript/native/test/masked_rendering.test.mjs"
          , "acceptance/contracts-masking/typescript/native/test/masked_rendering.test.ts"
          , "acceptance/contracts-masking/python/native/tests/test_masked_rendering.py" ] $ \path -> do
      native <- readFile path
      [hash | (_, hash) <- rows "letters" ++ rows "mixed", not (hash `isInfixOf` native)] `shouldBe` []
  it "name the masks in each target's casing, with maskHash the BLAKE3 one" $ do
    [Backend.maskFunction target algorithm | target <- ["java", "javascript", "python"], algorithm <- [Nothing, Just "blake3"]]
      `shouldBe` ["maskHash", "maskHashBlake3", "maskHash", "maskHashBlake3", "mask_hash", "mask_hash_blake3"]
    let masks = card ["  number shown as hash blake3"]
        file target name = concat [content | (path, content) <- fst (planned target masks), name `isInfixOf` path]
    file "java" "lawspec/data/Card.java" `shouldSatisfy` isInfixOf "lawspec.runtime.LawSpecMasks.maskHashBlake3(number)"
    file "javascript" "lawspec_data.mjs" `shouldSatisfy` isInfixOf "ls.maskHashBlake3(this.number)"
    file "typescript" "lawspec_data.ts" `shouldSatisfy` isInfixOf "ls.maskHashBlake3(this.number)"
    file "python" "lawspec_data.py" `shouldSatisfy` isInfixOf "ls.mask_hash_blake3(self.number)"
    refused (card ["  number shown as hash sha256"]) "sha256 is not a hash this version has; write hash blake3"
    -- Each runtime has every mask under its name, and maskHash is the
    -- BLAKE3 function itself, not a copy of it.
    web <- readFile "runtime/lawspec_runtime.mjs"
    python <- readFile "runtime/lawspec_runtime.py"
    java <- readFile "runtime/LawSpecMasks.java"
    forM_ [ "export function maskStar(", "export function maskLast(", "export function maskEmail(", "export function maskHashBlake3("
          , "export const maskHash = maskHashBlake3;", "export function maskHashBlake3With(", "export const maskHashWith = maskHashBlake3With;" ] $ \name ->
      web `shouldSatisfy` isInfixOf name
    forM_ [ "def mask_star(", "def mask_last(", "def mask_email(", "def mask_hash_blake3(", "\nmask_hash = mask_hash_blake3\n"
          , "def mask_hash_blake3_with(", "\nmask_hash_with = mask_hash_blake3_with\n" ] $ \name ->
      python `shouldSatisfy` isInfixOf name
    forM_ [ "public static String maskStar(Object value)", "public static String maskLast(", "public static String maskEmail("
          , "public static String maskHashBlake3(String value)", "public static String maskHash(String value)"
          , "public static String maskHashBlake3With(byte[] key, String value)", "public static String maskHashWith(byte[] key, String value)" ] $ \name ->
      java `shouldSatisfy` isInfixOf name
    -- In a specification both names are one checked definition, over the
    -- BLAKE3 primitives.
    lookup "maskHash" ruleOperations `shouldBe` Just "rulesMaskHashBlake3"
    lookup "maskHashBlake3" ruleOperations `shouldBe` Just "rulesMaskHashBlake3"
    map fst sequencePreludeHelpers `shouldSatisfy` \names -> all (`elem` names) ["blake3", "blake3Keyed", "blake3DeriveKey"]
  it "agree with BLAKE3's official test vectors in all three modes" $ do
    fixture <- BL.readFile "test/fixtures/blake3-official/test_vectors.json"
    spec <- readFile "acceptance/contracts-digest/official_vectors.lawspec"
    let field name fields = case KM.lookup name fields of
          Just (String value) -> T.unpack value
          _ -> ""
        (key, context, cases) = case decode fixture of
          Just (Object fields) | Just (Array rows) <- KM.lookup "cases" fields ->
            ( T.encodeUtf8 (T.pack (field "key" fields)), T.encodeUtf8 (T.pack (field "context_string" fields))
            , [ (truncate count :: Int, map (take 64 . (`field` row)) ["hash", "keyed_hash", "derive_key"])
              | Object row <- toList rows, Just (A.Number count) <- [KM.lookup "input_len" row] ] )
          _ -> (B.empty, B.empty, [])
        input count = B.pack [fromIntegral (index `mod` 251) | index <- [0 .. count - 1]]
    length cases `shouldBe` 35
    B.length key `shouldBe` 32
    -- The Haskell port, which evaluates a specification's blake3 functions.
    forM_ cases $ \(count, expected) ->
      [hexOf (blake3 (input count)), maybe "" hexOf (blake3Keyed key (input count)), hexOf (blake3DeriveKey context (input count))]
        `shouldBe` expected
    -- The specification every target's runtime runs holds the same values.
    forM_ cases $ \(count, [hash, keyed, derived]) -> do
      spec `shouldSatisfy` isInfixOf ("prelude.hex (prelude.blake3 (pattern " ++ show count ++ ")) = " ++ show hash)
      spec `shouldSatisfy` isInfixOf ("prelude.hex (prelude.blake3Keyed (key ()) (pattern " ++ show count ++ ")) = " ++ show keyed)
      spec `shouldSatisfy` isInfixOf ("prelude.hex (prelude.blake3DeriveKey (context ()) (pattern " ++ show count ++ ")) = " ++ show derived)
    length (filter ("law " `isPrefixOf`) (lines spec)) `shouldBe` 3 * length cases
    spec `shouldSatisfy` isInfixOf ("bytes(" ++ show (B.unpack key) ++ ")") . filter (/= ' ')
  it "show a field as a digest in every rendering, with no key" $ do
    let masks = card ["  number shown as digest"]
        named = card ["  number shown as digest blake3"]
        file target body name = concat [content | (path, content) <- fst (planned target body), name `isInfixOf` path]
        context = "\"probe.rules.Card.number\""
    file "java" masks "lawspec/data/Card.java" `shouldSatisfy` isInfixOf ("lawspec.runtime.LawSpecMasks.maskDigestIn(\n            " ++ context ++ ", number)")
    file "javascript" masks "lawspec_data.mjs" `shouldSatisfy` isInfixOf "ls.maskDigestIn('probe.rules.Card.number', this.number)"
    file "typescript" masks "lawspec_data.ts" `shouldSatisfy` isInfixOf "ls.maskDigestIn('probe.rules.Card.number', this.number)"
    file "python" masks "lawspec_data.py" `shouldSatisfy` isInfixOf ("ls.mask_digest_in(" ++ context ++ ", self.number)")
    file "java" named "lawspec/data/Card.java" `shouldSatisfy` isInfixOf "LawSpecMasks.maskDigestBlake3In("
    file "python" named "lawspec_data.py" `shouldSatisfy` isInfixOf "ls.mask_digest_blake3_in("
    -- A failure shows the digest too: the runtime is told the field's context.
    file "javascript" masks "lawspec_data.mjs" `shouldSatisfy` isInfixOf "ls.digestFields('probe.rules::type::Card::Card', [\n    [0, 'probe.rules.Card.number'],\n  ]);"
    file "python" masks "lawspec_data.py" `shouldSatisfy` isInfixOf ("ls.digest_fields(\n        \"probe.rules::type::Card::Card\",\n        [(0, " ++ context ++ ")],\n    )")
    file "java" masks "LawSpecDataSchema.java" `shouldSatisfy` isInfixOf ("LawSpecRuntime.digestField(\"probe.rules::type::Card::Card\", 0, " ++ context ++ ");")
    -- The checked rendering calls the digest within the field's context.
    case check masks of
      Left diagnostics -> expectationFailure (concatMap message diagnostics)
      Right (units, _) -> do
        let rendering = show [functionBody definition | definition <- functionDefinitions (probe units), functionName definition == "maskedCardDraft"]
        rendering `shouldSatisfy` isInfixOf "Apply (Apply (Var \"lawspecRulesRulesMaskDigestBlake3In\") (StringLit \"probe.rules.Card.number\")) (Var \"number\")"
        [fieldMaskText mask | contract <- recordContracts (probe units), (_, mask) <- contractMasks contract] `shouldBe` ["digest"]
    lookup "maskDigest" ruleOperations `shouldBe` Just "rulesMaskDigestBlake3"
    lookup "maskDigestBlake3" ruleOperations `shouldBe` Just "rulesMaskDigestBlake3"
    lookup "maskDigestIn" ruleOperations `shouldBe` lookup "maskDigestBlake3In" ruleOperations
    refused (card ["  number shown as digest sha256"]) "sha256 is not a digest this version has; write digest blake3"
    refused (card ["  pin shown as digest"]) "pin is not a Text, so it can only be shown as hidden"
    -- Every runtime has the digests under their names.
    web <- readFile "runtime/lawspec_runtime.mjs"
    python <- readFile "runtime/lawspec_runtime.py"
    java <- readFile "runtime/LawSpecMasks.java"
    forM_ [ "export function maskDigestBlake3(", "export function maskDigestBlake3In(", "export const maskDigest = maskDigestBlake3;"
          , "export const maskDigestIn = maskDigestBlake3In;", "export function setMaskHashKey(" ] $ \name -> web `shouldSatisfy` isInfixOf name
    forM_ [ "def mask_digest_blake3(", "def mask_digest_blake3_in(", "\nmask_digest = mask_digest_blake3\n"
          , "\nmask_digest_in = mask_digest_blake3_in\n", "def set_mask_hash_key(" ] $ \name -> python `shouldSatisfy` isInfixOf name
    forM_ [ "public static String maskDigest(String value)", "public static String maskDigestBlake3(String value)"
          , "public static String maskDigestIn(String context, String value)"
          , "public static String maskDigestBlake3In(String context, String value)", "public static void setMaskHashKey(byte[] key)" ] $ \name ->
      java `shouldSatisfy` isInfixOf name
  it "say when a digest field has few enough values to try them all" $ do
    let digest restriction = MaskAdvice.candidateBound (Refined "v" (Named "Text") (Just restriction))
        matching pattern = Apply (Apply (Var "prelude.regexMatches") (StringLit pattern)) (Var "v")
        long op count = Binary op (Apply (Var "prelude.length") (Var "v")) (M.Number count)
    MaskAdvice.enumerableDigestLimit `shouldBe` 2 ^ (64 :: Int)
    digest (matching "[0-9]{4}") `shouldBe` Just 10000
    digest (matching "(yes|no|maybe)") `shouldBe` Just 3
    digest (matching "[0-9]{13,19}") `shouldBe` Just (sum [10 ^ size | size <- [13 .. 19 :: Int]])
    digest (matching "[A-Z0-9]{22}") `shouldBe` Nothing
    digest (matching "[0-9]+") `shouldBe` Nothing
    digest (matching ".{2}") `shouldBe` Just ((0x110000 - 0x800) ^ (2 :: Int))
    digest (Apply (Apply (Var "prelude.member") (Var "v")) (ListLit [StringLit "open", StringLit "closed"])) `shouldBe` Just 2
    digest (Binary "==" (Var "v") (StringLit "fixed")) `shouldBe` Just 1
    digest (long "<=" 3) `shouldSatisfy` maybe False (<= MaskAdvice.enumerableDigestLimit)
    digest (long "<=" 4) `shouldBe` Nothing
    digest (long ">=" 3) `shouldBe` Nothing
    -- The least of the bounds a restriction's parts give.
    digest (Binary "&&" (long "<=" 40) (matching "[a-f]{2}")) `shouldBe` Just 36
    MaskAdvice.candidateBound (Named "Text") `shouldBe` Nothing
    -- The author is told as a warning and as advice; the unit still compiles.
    let small = card ["  number shown as digest"]
        open = [ "type Note is a record{body :: Text, owner :: Text} end type", "masking Note is", "  body shown as digest", "end masking" ]
        told = "Card.number is shown as digest, and its restriction allows at most about 2^63 values"
    snd (planned "java" small) `shouldSatisfy` any (isInfixOf ("enumerable-digest: " ++ told))
    snd (planned "java" small) `shouldSatisfy` any (isInfixOf "Show the field as hash, which is keyed, or as hidden")
    diagnosed "java" small `shouldBe` []
    snd (planned "java" open) `shouldSatisfy` all (not . isInfixOf "enumerable-digest")
    snd (planned "java" (card ["  number shown as hash"])) `shouldSatisfy` all (not . isInfixOf "enumerable-digest")
    advised small `shouldSatisfy` any (isInfixOf ("enumerable-digest: " ++ told))
    advised open `shouldSatisfy` all (not . isInfixOf "enumerable-digest:")
  it "refuse two records whose generated names would meet" $ do
    let record name = [ "type " ++ name ++ " is a record{token :: Text, pin :: Int32} end type", "masking " ++ name ++ " is", "  pin shown as hidden", "end masking" ]
    refused (record "Order" ++ record "OrderWith") "the records Order and OrderWith would both be given the name maskedOrderWith"
    either (concatMap message) (const "") (check (record "Order" ++ record "Within")) `shouldBe` ""
  it "write Go's BLAKE3 file only where a program hashes, over its module" $ do
    let masks = card ["  number shown as digest"]
        plain = ["type Plain is a record{pin :: Int32} end type", "function f (p :: Plain) -> Int32 is p.pin end function"]
        companions body = [content | (path, content) <- fst (planned "go" body), "lawspec_blake3.go" `isSuffixOf` path]
    companions plain `shouldBe` []
    companions masks `shouldSatisfy` (not . null)
    companions masks `shouldSatisfy` all (isInfixOf "import \"goforge.dev/blake3sum/components/blake3\"")
    companions masks `shouldSatisfy` all (not . isInfixOf "RUNTIME_PACKAGE")
    fmap (concatMap snd) (scaffoldFiles False "go") `shouldSatisfy` either (const False) (isInfixOf "goforge.dev/blake3sum v1.0.0")
    -- No other runtime takes a dependency for it.
    forM_ ["rust", "kotlin", "haskell", "swift", "fsharp", "erlang"] $ \target -> diagnosed target masks `shouldBe` []
  it "render a record under a key only where a specification names that rendering" $ do
    let masks = card ["  number shown as hash"]
        keyed = masks ++
          [ "function shownWith (key :: (k :: Bytes where prelude.length k = 32)) (c :: Card) -> Text is maskedCardWith key c end function" ]
        names body = either (const []) (\(units, _) -> map functionName (functionDefinitions (probe units))) (check body)
    names masks `shouldSatisfy` elem "maskedCard"
    names masks `shouldSatisfy` notElem "maskedCardWith"
    names keyed `shouldSatisfy` \found -> all (`elem` found) ["maskedCard", "maskedCardWith", "maskedCardDraftWith"]
    -- A key that nothing says is 32 bytes is refused where it is used.
    refused (masks ++ ["function shownWith (key :: Bytes) (c :: Card) -> Text is maskedCardWith key c end function"])
      "precondition could not be proved: probe.rules::maskedCardWith"
    refused ["function hashed (key :: Bytes) (t :: Text) -> Text is prelude.maskHash key t end function"]
      "precondition could not be proved"
    refused ["function hashed (key :: Bytes) (b :: Bytes) -> Bytes is prelude.blake3Keyed key b end function"]
      "a keyed hash is given a key that is not known to be 32 bytes"
  it "hash in a specification as every runtime does" $ do
    fixture <- BL.readFile "test/fixtures/blake3-keyed-text.json"
    let rows = case decode fixture of
          Just (Object fields) | Just (Array cases) <- KM.lookup "texts" fields ->
            [ ([truncate point | A.Number point <- toList points] :: [Int], T.unpack hash)
            | Object row <- toList cases, Just (Array points) <- [KM.lookup "points" row], Just (String hash) <- [KM.lookup "hash" row] ]
          _ -> []
        key = V.SSequence "Bytes" (map fromEnum "whats the Elvish word for friend")
        hashed points = do
          bytes <- helperValue 64 "utf8" [V.SSequence "Text" points]
          helperValue 64 "blake3Keyed" [key, bytes]
        octets hash = Right (V.SSequence "Bytes" [read ("0x" ++ pair) | pair <- pairs hash])
        pairs digits = case digits of
          a : b : rest -> [a, b] : pairs rest
          _ -> []
    length rows `shouldBe` 2
    forM_ rows $ \(points, hash) -> hashed points `shouldBe` octets hash
    helperValue 64 "blake3Keyed" [V.SSequence "Bytes" [1, 2, 3], V.SSequence "Bytes" [97]] `shouldBe` Left "blake3Keyed: the key is 32 bytes"
    -- Each runtime's own test compares the specification's hash with these.
    forM_ [ "acceptance/contracts-primitives/java/native/src/test/java/example/KeyedMasksTest.java"
          , "acceptance/contracts-primitives/javascript/native/test/keyed_masks.test.mjs"
          , "acceptance/contracts-primitives/typescript/native/test/keyed_masks.test.ts"
          , "acceptance/contracts-primitives/python/native/tests/test_keyed_masks.py" ] $ \path -> do
      native <- readFile path
      [hash | (_, hash) <- rows, not (hash `isInfixOf` native)] `shouldBe` []
  it "refuse the keyed hash and the strict address format on a target without them" $ do
    let strict = ["type Sender is a record{header :: (v :: Text where v matches format rfc822Address)} end type"
                 , "function known (s :: Sender) -> Text is s.header end function" ]
        hashing = ["function hashed (key :: (k :: Bytes where prelude.length k = 32)) (t :: Text) -> Text is prelude.maskHash key t end function"]
        plain = ["type Sender is a record{reply :: (v :: Text where v matches format email)} end type"
                , "function known (s :: Sender) -> Text is s.reply end function", "function star (t :: Text) -> Text is prelude.maskStar t end function" ]
    forM_ Backend.runtimePrimitiveTargets $ \target -> do
      diagnosed target strict `shouldBe` []
      diagnosed target hashing `shouldBe` []
    diagnosed "kotlin" strict `shouldSatisfy` any (isInfixOf "target-unsupported: kotlin: the format rfc822Address")
    forM_ programTargets $ \target -> do
      Backend.blake3Targets `shouldSatisfy` elem target
      diagnosed target hashing `shouldBe` []
    -- `email` and maskStar are plain checked definitions: every target has them.
    forM_ ["kotlin", "rust", "go"] $ \target -> diagnosed target plain `shouldBe` []
  it "give each format one rule, whatever it checks" $
    case check [ "type Sender is a record{"
               , "  reply :: (v :: Text where v matches format email),"
               , "  header :: (v :: Text where v matches format rfc822Address && prelude.length v <= 80),"
               , "  id :: (v :: Text where v matches format uuid)}"
               , "end type"
               , "function sent (d :: SenderDraft) -> Bool is violationsOfSender d = [] end function" ] of
      Left diagnostics -> expectationFailure (concatMap message diagnostics)
      Right (units, _) -> do
        let [contract] = recordContracts (probe units)
        [(contractRuleId rule, contractRuleKind rule) | rule <- contractRules contract] `shouldBe`
          [("reply.email", "email"), ("header.rfc822Address", "rfc822Address"), ("header.maxLength", "maxLength"), ("id.uuid", "uuid")]
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
