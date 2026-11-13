-- | Named text formats: `email` and `uuid` (LawSpec.Formats).
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

-- | `email` is RFC 822's address as Mail::RFC822::Address 0.3 accepts it; the
-- module's verdicts are recorded, so no test needs Perl. ref:DEC-email-format
test_formatsAreTheRecordedGrammars :: Spec
test_formatsAreTheRecordedGrammars = describe "named text formats" $ do
  it "are regexes of the portable dialect" $
    forM_ formatNames $ \name -> (parseRegex =<< maybe (Left "no pattern") Right (formatPattern name)) `shouldSatisfy` isRight
  it "name nothing else" $
    formatPattern "mailbox" `shouldBe` Nothing
  it "email agrees with the module's regex on every recorded text" $ do
    vectors <- readVectors
    length vectors `shouldSatisfy` (> 10000)
    [text | (text, regex, _) <- vectors, emailAccepts RefuseComments text /= regex] `shouldBe` []
  it "email after the comment pass agrees with the module's valid() on every recorded text" $ do
    vectors <- readVectors
    [text | (text, _, valid) <- vectors, emailAccepts StripComments text /= valid] `shouldBe` []
  it "the recorded texts tell the two policies apart" $ do
    vectors <- readVectors
    length [() | (_, False, True) <- vectors] `shouldSatisfy` (> 100)
    [text | (text, True, False) <- vectors] `shouldBe` []
  it "email refuses a comment, which the format does not strip" $ do
    emailCommentPolicy `shouldBe` RefuseComments
    emailAccepts emailCommentPolicy "ann@example.org (Ann Lee)" `shouldBe` False
    emailAccepts StripComments "ann@example.org (Ann Lee)" `shouldBe` True
    emailAccepts emailCommentPolicy "\"(not a comment)\"@example.org" `shouldBe` True
  it "email accepts every form of RFC 822's address, and one final line feed" $
    forM_ [ "ann@example.org", "ann@example", "\"Ann Lee\"@example.org", "ann@[10.0.0.1]", "Ann Lee <ann@example.org>"
          , "Ann <@a.example,@b.example:ann@example.org>", "team: ann@example.org, Bob <bob@example.org>;", "team:;"
          , "ann@example.org\n" ] $ \text ->
      (text, emailAccepts RefuseComments text) `shouldBe` (text, True)
  it "email refuses what is not one address" $
    forM_ [ "", "ann", "@example.org", "ann@", "ann@@example.org", "ann..lee@example.org", "ann@example..org"
          , "ann@example.org, bob@example.org", "ann lee@example.org", "ann@example.org\n\n", "a\0b@example.org" ] $ \text ->
      (text, emailAccepts RefuseComments text) `shouldBe` (text, False)
  it "the comment pass replaces innermost comments first, from the end, outside quoted strings" $ do
    stripComments "a(b)c" `shouldBe` "a c"
    stripComments "a(b(c)d)e" `shouldBe` "a e"
    stripComments "\"(a)\"(b)" `shouldBe` "\"(a)\" "
    stripComments "a(b\\)c)d" `shouldBe` "a d"
    stripComments "a(b" `shouldBe` "a(b"
    stripComments "(a\"b) \"(c)\"" `shouldBe` "  \" \""
  it "every text the email pattern generates is an address" $ do
    let samples = either (const []) (regexSamples 200) (parseRegex emailPattern)
    length samples `shouldSatisfy` (> 100)
    [text | text <- samples, not (emailAccepts RefuseComments text)] `shouldBe` []
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
  where
    showHexDigits n = let digits = "0123456789abcdef"
                          go 0 acc = acc
                          go m acc = go (m `div` 16) (digits !! (m `mod` 16) : acc)
                      in if n == 0 then "0" else go n ""
