-- | Named text formats: `v matches format email`, `v matches format
-- rfc822Address` and `v matches format uuid`. A format is a list of checks,
-- each a regex of the portable dialect (LawSpec.Regex) or a length, so every
-- target's matcher checks it, generation draws matching texts from it, and
-- no target needs a mail or regex library.
--
-- `email` is what most forms mean by an email address: one mailbox,
-- local@domain, in ASCII. The local part is a dot-atom or one quoted string
-- of at most 64 characters; the domain is two or more labels of letters,
-- digits and inner hyphens, or an IPv4 address in brackets; the whole is at
-- most 254 characters. No display name, route, group, comment or white
-- space. Its reference is Email::Valid 1.204 with fqdn on and the network
-- checks off: `email` accepts nothing that module refuses, and refuses
-- what the module accepts only for the listed reasons (emailDeviations).
--
-- `rfc822Address` is the address grammar of RFC 822, section 6.1, as Paul
-- Warren's Perl module Mail::RFC822::Address 0.3 decides it: the format
-- accepts exactly the texts that module's valid() accepts. valid() first
-- replaces comments, which nest and so are not regular, with a space
-- (rfc822Uncommented), then matches its regex (rfc822Pattern). The regex is
-- built from the grammar's parts and so is this one, under the same names.
--
-- Three things differ in how the regex is written, none in what it accepts:
--
--   * The module ends an atom with `(?:lwsp+|\Z|(?=[\["specials]))`. The
--     portable dialect has no lookahead, and needs none: an atom is a maximal
--     run wherever the grammar lets two atoms meet (in a phrase), so an atom
--     is its characters and any white space after them.
--   * Perl's `$` also matches before a final line feed, so the module accepts
--     an address followed by one. The pattern says so with a last `\n?`.
--   * Perl's `\s` (after a group's comma and semicolon) is Unicode white
--     space on a character string. The dialect's `\s` is ASCII, so the class
--     is written out.
--
-- Both equivalences are tested, not proved, on recorded verdicts of the two
-- modules (test/fixtures/formats). ref:DEC-email-format
module LawSpec.Formats
  ( formatNames, formatChecks, formatDescription, formatAccepts, FormatCheck(..)
  , emailPattern, emailLocalPattern, emailMaxLength, emailDeviations
  , rfc822Pattern, rfc822Uncommented, rfc822RegexAccepts, uuidPattern
  ) where

import LawSpec.Regex (parseRegex, regexMatches)

-- | The formats `matches format` may name.
formatNames :: [String]
formatNames = ["email", "rfc822Address", "uuid"]

-- | One check of a format. A text is in the format when every check holds.
data FormatCheck
  -- | The whole text matches the regex.
  = Matches String
  -- | The text without its RFC 822 comments matches the regex.
  | UncommentedMatches String
  -- | The text has at most so many characters.
  | AtMost Integer
  deriving (Eq, Show)

-- | A format's checks.
formatChecks :: String -> Maybe [FormatCheck]
formatChecks name = lookup name
  [ ("email", [Matches emailPattern, Matches emailLocalPattern, AtMost emailMaxLength])
  , ("rfc822Address", [UncommentedMatches rfc822Pattern])
  , ("uuid", [Matches uuidPattern]) ]

-- | What a format accepts, for messages and documentation.
formatDescription :: String -> String
formatDescription name = case name of
  "email" -> "an email address"
  "rfc822Address" -> "an RFC 822 address"
  "uuid" -> "a UUID in its 8-4-4-4-12 hexadecimal form"
  _ -> name

-- | Whether a text is in a format: the reference the recorded vectors check.
formatAccepts :: String -> String -> Bool
formatAccepts name text = case formatChecks name of
  Nothing -> False
  Just checks -> all holds checks
  where
    holds check = case check of
      Matches pattern -> matches pattern text
      UncommentedMatches pattern -> matches pattern (rfc822Uncommented text)
      AtMost limit -> toInteger (length text) <= limit
    matches pattern subject = either (const False) (`regexMatches` map fromEnum subject) (parseRegex pattern)

-- | The module's regex alone, without the comment pass: the first of the
-- two verdicts recorded for Mail::RFC822::Address.
rfc822RegexAccepts :: String -> Bool
rfc822RegexAccepts text = either (const False) (`regexMatches` map fromEnum text) (parseRegex rfc822Pattern)

-- | A UUID as RFC 9562, section 4, writes it: 32 hexadecimal digits in groups
-- of 8, 4, 4, 4 and 12. Either case is accepted, as the RFC requires of a
-- reader; the version and variant digits are not constrained.
uuidPattern :: String
uuidPattern = hex 8 ++ "-" ++ hex 4 ++ "-" ++ hex 4 ++ "-" ++ hex 4 ++ "-" ++ hex 12
  where hex n = "[0-9a-fA-F]{" ++ show (n :: Int) ++ "}"

-- | The shape of an `email`: a dot-atom or a quoted string, an at sign, and
-- a domain name of two or more labels or an IPv4 address in brackets.
emailPattern :: String
emailPattern = group (dotAtom ++ "|" ++ quoted) ++ "@" ++ group (name ++ "|" ++ address)
  where
    group body = "(?:" ++ body ++ ")"
    -- RFC 822's atom characters among printable ASCII: all but the
    -- specials and the space. RFC 5322 calls the same set atext.
    atext = "[A-Za-z0-9!#$%&'*+/=?^_`{|}~\\-]"
    dotAtom = atext ++ "+" ++ group ("\\." ++ atext ++ "+") ++ "*"
    -- Printable ASCII but the quotation mark and the backslash, or a
    -- backslash and any printable ASCII character.
    quoted = "\"" ++ group ("[ !#-Z^-~\\[\\]]|\\\\[ -~]") ++ "*\""
    label = "[A-Za-z0-9]" ++ group "[A-Za-z0-9\\-]*[A-Za-z0-9]" ++ "?"
    name = label ++ group ("\\." ++ label) ++ "+"
    octet = group "25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9]"
    address = "\\[" ++ octet ++ group ("\\." ++ octet) ++ "{3}\\]"

-- | The local part's limit, RFC 5321's 64: at most 64 characters before
-- the last at sign. It is a second regex because the shape cannot count.
emailLocalPattern :: String
emailLocalPattern = "[\\s\\S]{1,64}@[^@]*"

-- | RFC 5321's limit on a forward path, less its angle brackets.
emailMaxLength :: Integer
emailMaxLength = 254

-- | Why `email` refuses a text that Email::Valid accepts: every reason that
-- applies, by name. The recorded vectors hold one for each such text, and
-- the documentation lists them. Email::Valid finds an address inside a
-- larger text and checks that; `email` asks whether the text is one.
emailDeviations :: String -> [String]
emailDeviations text =
  [ reason | (reason, applies) <-
    [ ("comment", any (`elem` ("()" :: String)) bare)
    , ("angle-address", any (`elem` ("<>" :: String)) bare)
    , ("white-space", any (`elem` (" \t\r\n" :: String)) bare)
    , ("control-character", any (\c -> c < ' ' || c == '\DEL') text)
    , ("loose-ip-literal", '[' `elem` bare)
    , ("quoted-word-among-atoms", '"' `elem` text && not (wholeQuoted local)) ]
  , applies ]
  where
    -- The text outside its quoted strings.
    bare = outside False text
    outside quoted rest = case rest of
      [] -> []
      '\\' : _ : more | quoted -> outside quoted more
      '"' : more -> outside (not quoted) more
      c : more -> if quoted then outside quoted more else c : outside quoted more
    local = reverse (drop 1 (dropWhile (/= '@') (reverse text)))
    wholeQuoted part = case part of
      '"' : rest@(_ : _) -> last rest == '"' && closed (init rest)
      _ -> False
    -- No quotation mark inside but an escaped one.
    closed inner = case inner of
      [] -> True
      '\\' : _ : more -> closed more
      '"' : _ -> False
      _ : more -> closed more

-- | RFC 822's `address`, in the portable dialect. The names are the
-- grammar's. Control characters stand for themselves in the pattern: the
-- dialect has escapes only for \n \t \r \f \v.
rfc822Pattern :: String
rfc822Pattern = many lwsp ++ group (mailbox ++ "|" ++ groupAddress) ++ "\\n?"
  where
    group body = "(?:" ++ body ++ ")"
    many body = body ++ "*"
    optional body = body ++ "?"
    -- Linear white space: a space or tab, which a CRLF may precede (folding).
    lwsp = group (optional (group "\\r\\n") ++ "[ \\t]")
    anyCharacter = "[\\s\\S]"
    -- Not a special, a space or a control. The module writes the controls
    -- as \000-\031, which Perl reads in octal: U+0000 to U+0019.
    atomCharacter = "[^()<>@,;:\\\\\".\\[\\] " ++ ['\0'] ++ "-" ++ ['\x19'] ++ "]"
    atom = atomCharacter ++ "+" ++ many lwsp
    domainLiteral = "\\[" ++ many (group ("[^\\[\\]\\r\\\\]|\\\\" ++ anyCharacter)) ++ "\\]" ++ many lwsp
    quotedString = "\"" ++ many (group ("[^\"\\r\\\\]|\\\\" ++ anyCharacter ++ "|" ++ lwsp)) ++ "\"" ++ many lwsp
    word = group (atom ++ "|" ++ quotedString)
    localPart = word ++ many (group ("\\." ++ many lwsp ++ word))
    subDomain = group (atom ++ "|" ++ domainLiteral)
    domain = subDomain ++ many (group ("\\." ++ many lwsp ++ subDomain))
    addrSpec = localPart ++ "@" ++ many lwsp ++ domain
    phrase = many word
    route = group ("@" ++ domain ++ many (group (",@" ++ many lwsp ++ domain)) ++ ":" ++ many lwsp)
    routeAddr = "<" ++ many lwsp ++ optional route ++ addrSpec ++ ">" ++ many lwsp
    mailbox = group (addrSpec ++ "|" ++ phrase ++ routeAddr)
    -- Perl's \s on a character string.
    whiteSpace = "[\\t-\\r " ++ map toEnum [0x85, 0xA0, 0x1680] ++ [toEnum 0x2000] ++ "-" ++ [toEnum 0x200A] ++
      map toEnum [0x2028, 0x2029, 0x202F, 0x205F, 0x3000] ++ "]"
    groupAddress = phrase ++ ":" ++ many lwsp ++
      optional (group (mailbox ++ many (group ("," ++ many whiteSpace ++ mailbox)))) ++ ";" ++ many whiteSpace

-- | The module's strip_comments: while the text has a comment with no comment
-- inside it, after a prefix whose quoted strings are closed, replace the
-- first such comment by one space. A backslash quotes the next character.
-- Perl's regex takes the longest such prefix first, and the order matters: a
-- comment may hold a quotation mark, which changes what later counts as
-- quoted. So the candidates are tried from the end of the text.
rfc822Uncommented :: String -> String
rfc822Uncommented text = maybe text rfc822Uncommented (replaceOne text)
  where
    replaceOne source = case [ before ++ " " ++ after
                             | (index, True) <- reverse (zip [0 :: Int ..] (outside source))
                             , let (before, from) = splitAt index source
                             , Just after <- [comment from] ] of
      first : _ -> Just first
      [] -> Nothing
    -- For each position, whether a prefix ending there is well quoted: it is
    -- (?:[^"\\]|\\.)*(?:"(?:[^"\\]|\\.)*"(?:[^"\\]|\\.)*)*, an even number of
    -- unescaped quotation marks and no backslash left without a character.
    outside source = go False source
      where
        go quoted rest = not quoted : case rest of
          [] -> []
          '\\' : _ : more -> False : go quoted more
          '\\' : [] -> []
          '"' : more -> go (not quoted) more
          _ : more -> go quoted more
    -- \((?:[^()\\]|\\.)*\) at the start of the text, and what follows it.
    comment source = case source of
      '(' : rest -> inside rest
      _ -> Nothing
      where
        inside rest = case rest of
          ')' : after -> Just after
          '(' : _ -> Nothing
          '\\' : _ : more -> inside more
          '\\' : [] -> Nothing
          _ : more -> inside more
          [] -> Nothing
