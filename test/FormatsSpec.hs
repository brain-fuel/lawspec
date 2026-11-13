-- | Named text formats: `email`, `rfc822Address` and `uuid` (LawSpec.Formats).
module FormatsSpec (test_formatsAreTheRecordedGrammars) where

import Control.Monad (forM_, unless)
import Data.Char (chr)
import Data.Either (isRight)
import Numeric (readHex)
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Process (readProcess)
import Test.Hspec
import LawSpec.Formats
import LawSpec.Regex (parseRegex, regexMatchesText, regexSamples)

-- | One recorded vector: the text, the module's regex alone, the module's valid().
type Vector = (String, Bool, Bool)

readVectors :: IO [Vector]
readVectors = do
  content <- readFile "test/fixtures/formats/email-vectors.tsv"
  pure [vector | line <- lines content, take 1 line /= "#", Just vector <- [parseVector line]]

parseVector :: String -> Maybe Vector
parseVector line = case cells line of
  [text, regex, valid] | all (`elem` ["0", "1"]) [regex, valid] -> Just (decode text, regex == "1", valid == "1")
  _ -> Nothing
  where
    cells source = case break (== '\t') source of
      (cell, _ : rest) -> cell : cells rest
      (cell, []) -> [cell]
    decode = map (chr . fst . head . readHex) . words

-- | One recorded verdict of Email::Valid: the text, the verdict, and why
-- `email` refuses the text when the module accepts it.
readEmailValid :: IO [(String, Bool, [String])]
readEmailValid = do
  content <- readFile "test/fixtures/formats/email-valid-vectors.tsv"
  pure [ (decodeText text, verdict == "1", if reasons == "-" then [] else splitOn ',' reasons)
       | line <- lines content, take 1 line /= "#", [text, verdict, reasons] <- [splitOn '\t' line] ]
  where
    decodeText = map (chr . fst . head . readHex) . words

splitOn :: Char -> String -> [String]
splitOn separator source = case break (== separator) source of
  (cell, _ : rest) -> cell : splitOn separator rest
  (cell, []) -> [cell]

rfc822 :: String -> Bool
rfc822 = formatAccepts "rfc822Address"

email :: String -> Bool
email = formatAccepts "email"

-- | `rfc822Address` is RFC 822's address as Mail::RFC822::Address 0.3's
-- valid() accepts it, and `email` is one plain mailbox, checked against
-- Email::Valid 1.204. Both modules' verdicts are recorded, so no test needs
-- Perl. ref:DEC-email-format
test_formatsAreTheRecordedGrammars :: Spec
test_formatsAreTheRecordedGrammars = describe "named text formats" $ do
  it "are checks of the portable dialect" $
    forM_ formatNames $ \name -> case formatChecks name of
      Nothing -> expectationFailure (name ++ " has no checks")
      Just checks -> forM_ checks $ \check -> case check of
        Matches pattern -> parseRegex pattern `shouldSatisfy` isRight
        UncommentedMatches pattern -> parseRegex pattern `shouldSatisfy` isRight
        AtMost limit -> limit `shouldSatisfy` (> 0)
  it "are email, rfc822Address and uuid, and nothing else" $ do
    formatNames `shouldBe` ["email", "rfc822Address", "uuid"]
    formatChecks "mailbox" `shouldBe` Nothing
  it "the RFC 822 regex agrees with the module's regex on every recorded text" $ do
    vectors <- readVectors
    length vectors `shouldSatisfy` (> 10000)
    [text | (text, regex, _) <- vectors, rfc822RegexAccepts text /= regex] `shouldBe` []
  it "rfc822Address agrees with the module's valid() on every recorded text" $ do
    vectors <- readVectors
    [text | (text, _, valid) <- vectors, rfc822 text /= valid] `shouldBe` []
  it "the recorded texts tell the regex and valid() apart" $ do
    vectors <- readVectors
    length [() | (_, False, True) <- vectors] `shouldSatisfy` (> 100)
    [text | (text, True, False) <- vectors] `shouldBe` []
  it "rfc822Address accepts a comment and email refuses it" $ do
    rfc822 "ann@example.org (Ann Lee)" `shouldBe` True
    rfc822RegexAccepts "ann@example.org (Ann Lee)" `shouldBe` False
    rfc822 "ann(work)@example.org" `shouldBe` True
    rfc822 "\"(not a comment)\"@example.org" `shouldBe` True
    email "ann@example.org (Ann Lee)" `shouldBe` False
  it "rfc822Address accepts every form of RFC 822's address, and one final line feed" $
    forM_ [ "ann@example.org", "ann@example", "\"Ann Lee\"@example.org", "ann@[10.0.0.1]", "Ann Lee <ann@example.org>"
          , "Ann <@a.example,@b.example:ann@example.org>", "team: ann@example.org, Bob <bob@example.org>;", "team:;"
          , "ann@example.org\n" ] $ \text ->
      (text, rfc822 text) `shouldBe` (text, True)
  it "rfc822Address accepts what the module's way of writing the grammar lets in" $ do
    -- docs/reference/language/matchers.md lists these.
    forM_ [ "ann @ example.org", "\228nn@ex\228mple.org", "a\SUBb@example.org", "a\USb@example.org", "a\DELb@example.org"
          , "team: ann@example.org,\160bob@example.org;\8195" ] $ \text ->
      (text, rfc822 text) `shouldBe` (text, True)
    rfc822 "team: ann@example.org;\n\n\n" `shouldBe` True
    rfc822 "a\EMb@example.org" `shouldBe` False
  it "rfc822Address refuses what is not one address" $
    forM_ [ "", "ann", "@example.org", "ann@", "ann@@example.org", "ann..lee@example.org", "ann@example..org"
          , "ann@example.org, bob@example.org", "ann lee@example.org", "ann@example.org\n\n", "a\0b@example.org" ] $ \text ->
      (text, rfc822 text) `shouldBe` (text, False)
  it "the comment pass replaces innermost comments first, from the end, outside quoted strings" $ do
    rfc822Uncommented "a(b)c" `shouldBe` "a c"
    rfc822Uncommented "a(b(c)d)e" `shouldBe` "a e"
    rfc822Uncommented "\"(a)\"(b)" `shouldBe` "\"(a)\" "
    rfc822Uncommented "a(b\\)c)d" `shouldBe` "a d"
    rfc822Uncommented "a(b" `shouldBe` "a(b"
    rfc822Uncommented "(a\"b) \"(c)\"" `shouldBe` "  \" \""
  it "every text the RFC 822 pattern generates is an rfc822Address" $ do
    let samples = either (const []) (regexSamples 200) (parseRegex rfc822Pattern)
    length samples `shouldSatisfy` (> 100)
    [text | text <- samples, not (rfc822 text)] `shouldBe` []
  it "the two formats differ as the reference says (docs/reference/language/matchers.md)" $ do
    let verdicts text = (text, formatAccepts "email" text, formatAccepts "rfc822Address" text)
    map verdicts
      [ "ann@example.org", "\"Ann Lee\"@example.org", "ann@[10.0.0.1]", "ann@example.org (Ann Lee)", "Ann Lee <ann@example.org>"
      , "Ann <@a.example,@b.example:ann@example.org>", "team: ann@example.org, bob@example.org;", "ann@localhost"
      , "ann @ example.org", "ann@example.org\n", "\228nn@ex\228mple.org", "ann@ex_ample.org", "ann@[999.1.1.1]"
      , "ann..lee@example.org", "ann@example.org, bob@example.org", "ann@example.org (Ann (at work))", "ann@example.org (Ann" ]
      `shouldBe`
      [ ("ann@example.org", True, True), ("\"Ann Lee\"@example.org", True, True), ("ann@[10.0.0.1]", True, True)
      , ("ann@example.org (Ann Lee)", False, True), ("Ann Lee <ann@example.org>", False, True)
      , ("Ann <@a.example,@b.example:ann@example.org>", False, True), ("team: ann@example.org, bob@example.org;", False, True)
      , ("ann@localhost", False, True), ("ann @ example.org", False, True), ("ann@example.org\n", False, True)
      , ("\228nn@ex\228mple.org", False, True), ("ann@ex_ample.org", False, True), ("ann@[999.1.1.1]", False, True)
      , ("ann..lee@example.org", False, False), ("ann@example.org, bob@example.org", False, False)
      , ("ann@example.org (Ann (at work))", False, True), ("ann@example.org (Ann", False, False) ]
    -- The reasons the reference gives for its examples of what Email::Valid takes.
    map emailDeviations ["ann@example.org (Ann Lee)", "Ann Lee <ann@example.org>", "ann @example.org", "\"a\SOHb\"@example.org", "ann@[999.1.1.1]", "ann@[1.2.3.4].example.org", "\"a\".b@example.org"]
      `shouldBe` [["comment", "white-space"], ["angle-address", "white-space"], ["white-space"], ["control-character"], ["loose-ip-literal"], ["loose-ip-literal"], ["quoted-word-among-atoms"]]
  it "email is one plain mailbox" $ do
    forM_ [ "ann@example.org", "ann.lee+tag@mail.example.co.uk", "ANN@EXAMPLE.ORG", "0@a.b", "\"Ann Lee\"@example.org"
          , "\"a@b\"@example.org", "ann@[10.0.0.1]", "a!#$%&'*+/=?^_`{|}~-b@example.org"
          , replicate 64 'a' ++ "@example.org", "a@" ++ replicate 248 'b' ++ ".org" ] $ \text ->
      (text, email text) `shouldBe` (text, True)
    forM_ [ "", "ann", "ann@example", "ann@", "@example.org", "ann@@example.org", "ann..lee@example.org", ".ann@example.org"
          , "ann@-a.org", "ann@a-.org", "ann@ex_ample.org", "ann@example.org.", "\228nn@example.org", "ann@ex\228mple.org"
          , "Ann Lee <ann@example.org>", "<ann@example.org>", "team: ann@example.org;", "ann@example.org, bob@example.org"
          , "ann @example.org", " ann@example.org", "ann@example.org\n", "ann@[256.0.0.1]", "ann@[10.0.0.1x]", "ann@[IPv6:::1]"
          , "\"a\".b@example.org", "a\DELb@example.org", "\"a\SOHb\"@example.org"
          , replicate 65 'a' ++ "@example.org", "a@" ++ replicate 249 'b' ++ ".org" ] $ \text ->
      (text, email text) `shouldBe` (text, False)
  it "every email is an rfc822Address" $ do
    let samples = either (const []) (regexSamples 300) (parseRegex emailPattern)
    length samples `shouldSatisfy` (> 100)
    [text | text <- samples, email text, not (rfc822 text)] `shouldBe` []
    length (filter email samples) `shouldSatisfy` (> 100)
  it "email accepts nothing Email::Valid refuses, on every recorded text" $ do
    vectors <- readEmailValid
    length vectors `shouldSatisfy` (> 10000)
    [text | (text, False, _) <- vectors, email text] `shouldBe` []
  it "email refuses what Email::Valid accepts only for a listed reason" $ do
    vectors <- readEmailValid
    let listed = ["comment", "angle-address", "white-space", "control-character", "loose-ip-literal", "quoted-word-among-atoms"]
    [text | (text, True, []) <- vectors, not (email text)] `shouldBe` []
    [text | (text, True, reasons@(_ : _)) <- vectors, email text || reasons /= emailDeviations text || any (`notElem` listed) reasons] `shouldBe` []
    -- Each reason is recorded, and so is plain agreement.
    forM_ listed $ \reason -> length [() | (_, True, reasons) <- vectors, reason `elem` reasons] `shouldSatisfy` (> 0)
    length [() | (text, True, []) <- vectors, email text] `shouldSatisfy` (> 100)
  it "uuid is 8-4-4-4-12 hexadecimal digits in either case" $ do
    let matches text = regexMatchesText uuidPattern (map fromEnum text)
    matches "123e4567-e89b-12d3-a456-426614174000" `shouldBe` Right True
    matches "123E4567-E89B-12D3-A456-426614174000" `shouldBe` Right True
    matches "123e4567e89b12d3a456426614174000" `shouldBe` Right False
    matches "123e4567-e89b-12d3-a456-42661417400" `shouldBe` Right False
    matches "123e4567-e89b-12d3-a456-42661417400g" `shouldBe` Right False
    matches "{123e4567-e89b-12d3-a456-426614174000}" `shouldBe` Right False
  -- Optional: with Perl and the module at hand, the record is checked against
  -- the oracle itself. LAWSPEC_RFC822_ADDRESS_PM is the path of Address.pm.
  it "the recorded verdicts are the module's own, when LAWSPEC_RFC822_ADDRESS_PM names it" $ do
    modulePath <- lookupEnv "LAWSPEC_RFC822_ADDRESS_PM"
    perl <- findExecutable "perl"
    case (modulePath, perl) of
      (Just path, Just _) -> do
        vectors <- readVectors
        let encode = unwords . map (\c -> showHexDigits (fromEnum c))
        output <- readProcess "perl" ["tools/email-oracle.pl", path] (unlines [encode text | (text, _, _) <- vectors])
        let live = [vector | line <- lines output, Just vector <- [parseVector line]]
        unless (live == vectors) (expectationFailure "the module's verdicts differ from the recorded ones")
      _ -> pendingWith "set LAWSPEC_RFC822_ADDRESS_PM to Mail::RFC822::Address's Address.pm, with perl on the PATH"
  it "the recorded Email::Valid verdicts are the module's own, when LAWSPEC_EMAIL_VALID_LIB names it" $ do
    library <- lookupEnv "LAWSPEC_EMAIL_VALID_LIB"
    perl <- findExecutable "perl"
    case (library, perl) of
      (Just path, Just _) -> do
        vectors <- readEmailValid
        let encode = unwords . map (\c -> showHexDigits (fromEnum c))
        output <- readProcess "perl" ["tools/email-valid-oracle.pl", path] (unlines [encode text | (text, _, _) <- vectors])
        let live = [verdict == "1" | line <- lines output, [_, verdict] <- [splitOn '\t' line]]
        unless (live == [verdict | (_, verdict, _) <- vectors]) (expectationFailure "the module's verdicts differ from the recorded ones")
      _ -> pendingWith "set LAWSPEC_EMAIL_VALID_LIB to Email::Valid's lib directory, with perl and Mail::Address at hand"
  where
    showHexDigits n = let digits = "0123456789abcdef"
                          go 0 acc = acc
                          go m acc = go (m `div` 16) (digits !! (m `mod` 16) : acc)
                      in if n == 0 then "0" else go n ""
