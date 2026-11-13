-- | The recorded vectors of the `rfc822Address` and `email` formats
-- (LawSpec.Formats): texts with the verdicts of Mail::RFC822::Address 0.3
-- and of Email::Valid 1.204 on them. The modules are the oracles and are not
-- part of this repository; this command needs Perl and a copy of each, and
-- nothing else in the build does.
--
--   lawspec-dev email-vectors <Address.pm>
--       rewrite test/fixtures/formats/email-vectors.tsv
--   lawspec-dev email-vectors --check <Address.pm> [corpus files...]
--       compare LawSpec's verdicts with the module's, on a larger set of
--       inputs than is recorded and on every quoted string and line of the
--       corpus files
--       (for example the test files of Email::Valid and Email::Address,
--       which are not copied here)
--   lawspec-dev email-vectors --email-valid <Email::Valid's lib directory>
--       rewrite test/fixtures/formats/email-valid-vectors.tsv: Email::Valid's
--       verdict on each text and, where `email` refuses what it accepts, why
--       (needs Mail::Address installed; the network is never used)
--
-- The inputs are LawSpec's own: addresses written from RFC 822's grammar,
-- texts the format's regex generates, single edits of both, and every text
-- of up to three characters over one character from each class the grammar
-- tells apart. ref:DEC-email-format
module EmailVectors (emailVectorsCommand, vectorInputs, encodeInput) where

import Control.Monad (forM_, unless, when)
import Data.Char (isSpace)
import qualified Data.Set as S
import Data.List (intercalate)
import LawSpec.Formats (emailDeviations, emailPattern, formatAccepts, rfc822Pattern, rfc822RegexAccepts)
import LawSpec.Regex (parseRegex, regexSamples)
import Numeric (showHex)
import System.Exit (die, exitFailure)
import System.Process (readProcess)

fixture :: FilePath
fixture = "test/fixtures/formats/email-vectors.tsv"

emailVectorsCommand :: [String] -> IO ()
emailVectorsCommand arguments = case arguments of
  [modulePath] -> do
    verdicts <- oracle modulePath vectorInputs
    writeFile fixture (unlines (header ++ [encodeInput input ++ "\t" ++ bit regex ++ "\t" ++ bit valid | (input, regex, valid) <- verdicts]))
    putStrLn ("recorded " ++ show (length verdicts) ++ " vectors in " ++ fixture)
    compareWith verdicts
  ["--email-valid", library] -> do
    let inputs = distinct (mailboxes ++ vectorInputs)
    output <- readProcess "perl" ["tools/email-valid-oracle.pl", library] (unlines (map encodeInput inputs))
    let answered = [ (input, verdict == "1") | (input, row) <- zip inputs (lines output), [_, verdict] <- [splitTabs row], verdict `elem` ["0", "1"] ]
        row (input, accepted) = (input, accepted, if accepted && not (formatAccepts "email" input) then emailDeviations input else [])
        rows = map row answered
        wider = [input | (input, False) <- answered, formatAccepts "email" input]
        unexplained = [input | (input, True, []) <- rows, not (formatAccepts "email" input)]
    when (length (lines output) /= length inputs) (die "the oracle answered a different number of lines than it was asked")
    forM_ (take 40 wider) (\input -> putStrLn ("email accepts what Email::Valid refuses: " ++ show input))
    forM_ (take 40 unexplained) (\input -> putStrLn ("email refuses what Email::Valid accepts, for no listed reason: " ++ show input))
    unless (null wider && null unexplained) exitFailure
    -- Every text is compared here. The file keeps each text the module
    -- accepts, and one in twelve of those both refuse.
    let kept = [row | (index, row@(_, accepted, _)) <- zip [0 :: Int ..] rows, accepted || index `mod` 12 == 0]
    writeFile emailValidFixture (unlines (emailValidHeader ++
      [encodeInput input ++ "\t" ++ bit accepted ++ "\t" ++ (if null reasons then "-" else intercalate "," reasons) | (input, accepted, reasons) <- kept]))
    putStrLn ("compared " ++ show (length rows) ++ " texts and recorded " ++ show (length kept) ++ " vectors in " ++ emailValidFixture ++ "; " ++
      show (length [() | (_, True, _ : _) <- rows]) ++ " are listed deviations, " ++
      show (length [() | (input, True, []) <- rows, formatAccepts "email" input]) ++ " are accepted by both")
  "--check" : modulePath : corpora -> do
    extra <- concat <$> mapM (fmap corpusTexts . readFile) corpora
    verdicts <- oracle modulePath (distinct (checkedInputs ++ extra))
    putStrLn ("compared " ++ show (length verdicts) ++ " texts with the module")
    compareWith verdicts
  _ -> die "usage: lawspec-dev email-vectors [--check] <path to Mail::RFC822::Address's Address.pm> [corpus files...] | --email-valid <path to Email::Valid's lib directory>"
  where
    bit verdict = if verdict then "1" else "0"
    header =
      [ "# Verdicts of Mail::RFC822::Address 0.3 (Paul Warren, 2001-2002) on LawSpec's own inputs."
      , "# Columns: the text as hexadecimal code points; the module's regex alone; the module's valid()."
      , "# Written by `lawspec-dev email-vectors <Address.pm>`; see dev/EmailVectors.hs. Do not edit." ]
    emailValidHeader =
      [ "# Verdicts of Email::Valid 1.204 (fqdn, allow_ip and localpart on; mxcheck, tldcheck, fudge and local_rules off) on LawSpec's own inputs."
      , "# Columns: the text as hexadecimal code points; the module's verdict; why LawSpec's `email` refuses a text the module accepts, or -."
      , "# Every text the module accepts is here, and one in twelve of the texts it and LawSpec both refuse."
      , "# Written by `lawspec-dev email-vectors --email-valid <lib>`; see dev/EmailVectors.hs. Do not edit." ]

emailValidFixture :: FilePath
emailValidFixture = "test/fixtures/formats/email-valid-vectors.tsv"

-- | LawSpec's verdicts beside the module's; any difference fails.
compareWith :: [(String, Bool, Bool)] -> IO ()
compareWith verdicts = do
  let differences = [ (input, what, expected)
                    | (input, regex, valid) <- verdicts
                    , (what, ours, expected) <- [ ("the regex alone", rfc822RegexAccepts input, regex)
                                                , ("rfc822Address", formatAccepts "rfc822Address" input, valid) ]
                    , ours /= expected ]
  forM_ (take 40 differences) $ \(input, what, expected) ->
    putStrLn ("differs for " ++ what ++ ": the module says " ++ show expected ++ " for " ++ show input)
  unless (null differences) $ do
    putStrLn (show (length differences) ++ " differences")
    exitFailure
  putStrLn "LawSpec agrees with the module on every text, with and without the comment pass"

-- | The module's two verdicts on each text it answered for. Its regexes
-- backtrack; a text it does not decide within the oracle's time limit is
-- left out, and counted.
oracle :: FilePath -> [String] -> IO [(String, Bool, Bool)]
oracle modulePath inputs = do
  output <- readProcess "perl" ["tools/email-oracle.pl", modulePath] (unlines (map encodeInput inputs))
  let rows = lines output
  when (length rows /= length inputs) (die "the oracle answered a different number of lines than it was asked")
  let answered = [ (input, regex == "1", valid == "1")
                 | (input, row) <- zip inputs rows
                 , [_, regex, valid] <- [splitTabs row]
                 , all (`elem` ["0", "1"]) [regex, valid] ]
  when (length answered /= length inputs)
    (putStrLn (show (length inputs - length answered) ++ " texts left out: the module did not decide them in time"))
  pure answered

splitTabs :: String -> [String]
splitTabs text = case break (== '\t') text of
  (cell, _ : rest) -> cell : splitTabs rest
  (cell, []) -> [cell]

-- | A text as hexadecimal code points separated by spaces.
encodeInput :: String -> String
encodeInput = unwords . map (\c -> showHex (fromEnum c) "")

-- | The quoted strings and the lines of a corpus file: candidates only, since
-- the module gives the verdict on each.
corpusTexts :: String -> [String]
corpusTexts text = filter usable (distinct (concatMap spellings (map trim (lines text) ++ quoted '\'' text ++ quoted '"' text)))
  where
    -- Email::Address's corpus writes the at sign as a placeholder.
    spellings candidate = distinct [candidate, replace "-- ATAT --" "@" candidate]
    replace old new source@(first : rest)
      | take (length old) source == old = new ++ replace old new (drop (length old) source)
      | otherwise = first : replace old new rest
    replace _ _ [] = []
    usable candidate = not (null candidate) && length candidate <= 200
    trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace
    quoted mark source = case dropWhile (/= mark) source of
      _ : rest -> let (inside, after) = break (\c -> c == mark || c == '\n') rest
                  in inside : quoted mark (drop 1 after)
      [] -> []

-- | Every recorded input, in a fixed order: one edit in six, and the short
-- texts of three characters over half of the classes. `--check` compares
-- all of `checkedInputs`, which takes a few minutes of Perl.
vectorInputs :: [String]
vectorInputs = distinct (written ++ generated ++ everySixth (concatMap singleEdits written) ++ short 2 representatives ++ short 3 (take 12 representatives))
  where everySixth texts = [text | (index, text) <- zip [0 :: Int ..] texts, index `mod` 6 == 0]

-- | The recorded inputs and the rest: every edit, and every text of up to
-- three characters over all the classes.
checkedInputs :: [String]
checkedInputs = distinct (vectorInputs ++ concatMap singleEdits (written ++ take 40 generated) ++ short 3 representatives)

-- | Texts the format's regex generates. Long ones are where the module's own
-- regex stops answering.
generated :: [String]
generated = filter ((<= 48) . length) (either (const []) (regexSamples 400) (parseRegex rfc822Pattern))

-- | Inputs for the `email` format: texts its regex generates, their single
-- edits, and texts written around each of its rules and of Email::Valid's.
mailboxes :: [String]
mailboxes = distinct (plain ++ samples ++ concatMap singleEdits (plain ++ take 60 samples) ++ concatMap mailboxEdits (take 12 plain))
  where
    samples = filter ((<= 80) . length) (either (const []) (regexSamples 300) (parseRegex emailPattern))
    long n = replicate n 'a'
    plain =
      [ "ann@example.org", "ann.lee@example.org", "ann@example", "ann@example.co.uk", "ANN@EXAMPLE.ORG", "0@a.b", "ann@1.2"
      , "a!#$%&'*+/=?^_`{|}~-b@example.org", "ann..lee@example.org", ".ann@example.org", "ann.@example.org"
      , "ann@example..org", "ann@.example.org", "ann@example.org.", "ann@-a.org", "ann@a-.org", "ann@a-b.org", "ann@a--b.org"
      , "ann@ex_ample.org", "ann@ex ample.org", "ann@xn--bcher-kva.example", "\228nn@example.org", "ann@ex\228mple.org"
      , "\"Ann Lee\"@example.org", "\"\"@example.org", "\"a@b\"@example.org", "\"a\\\"b\"@example.org", "\"a\\\\b\"@example.org"
      , "\"a\\ b\"@example.org", "\"a\SOHb\"@example.org", "\"a\nb\"@example.org", "\"a\tb\"@example.org", "\"a\DELb\"@example.org"
      , "\"a\\\SOHb\"@example.org", "\"a\".b@example.org", "a.\"b\"@example.org", "\"a\".\"b\"@example.org", "\"a\"b@example.org", "a\"b\"@example.org"
      , "ann@[10.0.0.1]", "ann@[255.255.255.255]", "ann@[256.1.1.1]", "ann@[999.1.1.1]", "ann@[10.0.0.1x]", "ann@[10.0.0]"
      , "ann@[10.0.0.01]", "ann@[010.0.0.1]", "ann@[0.0.0.0]", "ann@[IPv6:::1]", "ann@[1.2.3.4].example.org", "ann@x.[1.2.3.4]", "ann@[1.2.3.4"
      , "ann@10.0.0.1", "a\DELb@example.org", "a\USb@example.org", "ann@exa\DELmple.org"
      , "Ann Lee <ann@example.org>", "<ann@example.org>", "ann@example.org (Ann)", "(Ann) ann@example.org", "ann(x)@example.org"
      , "ann @ example.org", " ann@example.org", "ann@example.org ", "ann@example.org\n", "ann@example.org\r\n", "ann@example.org\n\n"
      , "team: ann@example.org;", "ann@example.org, bob@example.org", "ann@example.org;", "ann@@example.org", "ann", "", "@", "@example.org", "ann@"
      , long 64 ++ "@example.org", long 65 ++ "@example.org", long 32 ++ "." ++ long 31 ++ "@example.org", long 32 ++ "." ++ long 32 ++ "@example.org"
      , "\"" ++ long 62 ++ "\"@example.org", "\"" ++ long 63 ++ "\"@example.org"
      , "a@" ++ long 248 ++ ".org", "a@" ++ long 249 ++ ".org", long 64 ++ "@" ++ long 185 ++ ".org", long 64 ++ "@" ++ long 186 ++ ".org"
      , "a@" ++ long 63 ++ ".org", "a@" ++ long 64 ++ ".org", "a@" ++ intercalate "." (replicate 120 "b"), "a@" ++ intercalate "." (replicate 127 "b") ]
    -- The characters that separate the two formats, put at each position.
    mailboxEdits text = [before ++ [c] ++ rest | index <- [0 .. length text], let (before, rest) = splitAt index text, c <- "-_\DEL\SOH\t\n)]>" :: String]

-- | Every text of up to n of the characters.
short :: Int -> String -> [String]
short n characters = concat [sequence (replicate size characters) | size <- [0 .. n]]

-- | The texts in their first order, each once.
distinct :: [String] -> [String]
distinct = go S.empty
  where
    go _ [] = []
    go seen (text : rest)
      | text `S.member` seen = go seen rest
      | otherwise = text : go (S.insert text seen) rest

-- | One character from each class the grammar tells apart.
representatives :: String
representatives = "a \t\r\n\"\\()<>@,;:.[]" ++ map toEnum [0, 0x19, 0x1A, 0x7F, 0xA0, 0xE9, 0x2028, 0x1F600]

-- | A text with one character removed, or one character put in its place or
-- before it, at each position. Long texts are edited at their first
-- positions only.
singleEdits :: String -> [String]
singleEdits text = concat
  [ [before ++ after | _ : after <- [rest]] ++
    [before ++ [c] ++ rest | c <- inserted] ++
    [before ++ [c] ++ after | _ : after <- [rest], c <- inserted]
  | index <- [0 .. min 12 (length text)]
  , let (before, rest) = splitAt index text ]
  where inserted = " \r\"\\(<@,:.[" :: String

-- | Addresses and near misses written from RFC 822's grammar: each production
-- of section 6.1 (address, mailbox, group, route-addr, route, addr-spec,
-- local-part, domain, sub-domain) and of section 3.3 (atom, quoted-string,
-- domain-literal, linear white space, comment) has texts that use it and
-- texts that break it.
written :: [String]
written =
  -- addr-spec: local-part "@" domain
  [ "user@example.org", "user@example", "u@e", "user@", "@example.org", "user", "", "@"
  , "user@@example.org", "user@example@org", "first.last@example.org", "first..last@example.org"
  , ".first@example.org", "first.@example.org", "user@example..org", "user@.example.org", "user@example.org."
  , "user name@example.org", "user@exam ple.org", "user @example.org", "user@ example.org", " user@example.org"
  , "user@example.org ", "user@example.org\n", "user@example.org\n\n", "\nuser@example.org", "user@example.org\r\n"
  , "user@example.org\r\n ", "user\r\n @example.org", "user\r\n@example.org", "user\t@example.org", "user\n@example.org"
  -- atom: any character but specials, space and controls
  , "a+b@example.org", "a!#$%&'*+-/=?^_`{|}~b@example.org", "a,b@example.org", "a;b@example.org", "a:b@example.org"
  , "a<b@example.org", "a>b@example.org", "a[b@example.org", "a]b@example.org", "a\\b@example.org", "a\"b@example.org"
  , "a(b@example.org", "a)b@example.org", "caf\233@example.org", "user@caf\233.example", "\955@\955.example"
  , "a\0b@example.org", "a\x19\&b@example.org", "a\x1A\&b@example.org", "a\x1F\&b@example.org", "a\x7F\&b@example.org"
  , "a\x80\&b@example.org", "a\xA0\&b@example.org", "a\x2028\&b@example.org", "user@exa\x1A\&mple.org"
  -- quoted-string
  , "\"user\"@example.org", "\"user name\"@example.org", "\"\"@example.org", "\"a\\\"b\"@example.org", "\"a\\\\b\"@example.org"
  , "\"a\"b\"@example.org", "\"user@example.org", "user\"@example.org", "\"a\rb\"@example.org", "\"a\\\rb\"@example.org"
  , "\"a\nb\"@example.org", "\"a\r\n b\"@example.org", "\"a\r\nb\"@example.org", "\"a(b)c\"@example.org", "\"a@b\"@example.org"
  , "\"first\".\"last\"@example.org", "\"first\"last@example.org", "first\"last\"@example.org", "\"a\\\nb\"@example.org"
  , "\"a\" .b@example.org", "\"a\". b@example.org", "\"a\\\"@example.org", "\"<>,;:.[]\"@example.org"
  -- domain-literal
  , "user@[127.0.0.1]", "user@[]", "user@[a[b]", "user@[a]b]", "user@[a\\]b]", "user@[a\\[b]", "user@[a\rb]", "user@[a\\\rb]"
  , "user@[a\nb]", "user@[127.0.0.1].example", "user@example.[127.0.0.1]", "user@[127.0.0.1", "user@127.0.0.1]"
  , "user@[a b]", "user@[a] ", "user@[a]\n", "user@[a][b]", "\"127.0.0.1\"@[127.0.0.1]", "user@[\"]", "user@[a\\"
  -- mailbox: phrase route-addr
  , "Ann <ann@example.org>", "Ann<ann@example.org>", "<ann@example.org>", "Ann Lee <ann@example.org>"
  , "\"Ann Lee\" <ann@example.org>", "\"Lee, Ann\" <ann@example.org>", "Lee, Ann <ann@example.org>", "Ann. Lee <ann@example.org>"
  , "Ann <ann@example.org", "Ann ann@example.org>", "Ann <ann@example.org>>", "Ann <<ann@example.org>>", "Ann <ann>"
  , "Ann <>", "Ann < ann@example.org >", "Ann <ann@example.org> ", "Ann <ann@example.org>\n", "Ann <ann@example.org> Lee"
  , "Ann\"Lee\"<ann@example.org>", "Ann\r\n Lee <ann@example.org>", "Ann\r\nLee <ann@example.org>", "Ann <ann@example.org>,"
  , "Ann@Lee <ann@example.org>", "Ann [Lee] <ann@example.org>"
  -- route
  , "Ann <@a:ann@example.org>", "Ann <@a,@b,@c:ann@example.org>", "<@a.example,@b.example:ann@example.org>"
  , "Ann <@a,b:ann@example.org>", "Ann <@a,@b ann@example.org>", "Ann <@:ann@example.org>", "Ann <@a:>", "Ann <@a,@ b:ann@example.org>"
  , "Ann <@a ,@b:ann@example.org>", "Ann <@a: ann@example.org>", "Ann <@[10.0.0.1]:ann@example.org>", "@a:ann@example.org"
  -- group: phrase ":" [#mailbox] ";"
  , "team:;", "team: ;", "team:ann@example.org;", "team: ann@example.org, bob@example.org;", "team:ann@example.org,bob@example.org;"
  , "team: Ann <ann@example.org>, Bob <bob@example.org>;", "team:ann@example.org", "team ann@example.org;", ":;", ":ann@example.org;"
  , "team:;\n", "team:; ", "team:;\t\n ", "team:;x", "team:ann@example.org,;", "team:,ann@example.org;", "team:ann@example.org;;"
  , "team:ann@example.org,\n bob@example.org;", "team:ann@example.org,\xA0\&bob@example.org;", "team:ann@example.org,\x2028\&bob@example.org;"
  , "team:ann@example.org,\x3000\&bob@example.org;", "team:ann@example.org,\x200B\&bob@example.org;", "team:;\x85", "team:;\x1680"
  , "team:;\x180E", "team:;\xB", "team:;\xC", "the team:ann@example.org;", "\"the team\":ann@example.org;", "a:b:;", "team:inner:;;"
  -- more than one address is a list, not an address
  , "ann@example.org, bob@example.org", "ann@example.org,bob@example.org", "ann@example.org;", "ann@example.org bob@example.org"
  -- comments
  , "ann(comment)@example.org", "ann@example.org (Ann Lee)", "(Ann Lee) ann@example.org", "ann@(comment)example.org"
  , "ann@example.org (a (nested) comment)", "ann@example.org (unclosed", "ann@example.org unopened)", "ann@example.org (a \\) b)"
  , "ann@example.org (a \\( b)", "\"(not a comment)\"@example.org", "\"a\" (c \" d) \"(e)\"@example.org", "ann@example.org ()"
  , "()", "(only a comment)", "ann@example.org (a \" b)", "Ann (Lee) <ann@example.org>", "ann(a)(b)@example.org", "ann@example.org (a\nb)"
  , "team:(empty);", "ann@example.org (\\", "\"a\\\"(b)\"@example.org", "(a)\"(b)\"(c)@example.org", "ann.(c)lee@example.org"
  ]
