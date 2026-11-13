-- | Named text formats: `v matches format email` and `v matches format uuid`. Each
-- format is a regex of the portable dialect (LawSpec.Regex), so every
-- target's matcher checks it, generation draws matching texts from it, and
-- no target needs a mail or regex library.
--
-- `email` is the address grammar of RFC 822, section 6.1, as Paul Warren's
-- Perl module Mail::RFC822::Address 0.3 writes it: the format accepts exactly
-- the texts that module's regex accepts (`$s =~ m/^$rfc822re$/so`), which is
-- an RFC 822 `address`: a mailbox with or without a display phrase and a
-- route, or a group. The module's regex is built from the grammar's parts and
-- so is this one, under the same names.
--
-- Three things differ in how it is written, none in what it accepts:
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
-- The module's `valid` function first replaces comments, which nest and so
-- are not regular, with a space; `stripComments` is that pass. The format
-- does not run it: a text with a comment outside a quoted string is not an
-- `email`. `emailAccepts` gives the verdict under either policy, and the
-- recorded vectors (test/fixtures/formats/email-vectors.tsv) hold both.
--
-- The equivalence is tested, not proved: against the module on every string
-- of up to five characters over 24 class representatives and of up to seven
-- over 15, and on the recorded vectors. ref:DEC-email-format
module LawSpec.Formats
  ( formatNames, formatPattern, formatDescription
  , emailPattern, uuidPattern
  , CommentPolicy(..), emailCommentPolicy, emailAccepts, stripComments
  ) where

import LawSpec.Regex (Regex, parseRegex, regexMatches)

-- | The formats `matches format` may name.
formatNames :: [String]
formatNames = ["email", "uuid"]

-- | A format's regex in the portable dialect.
formatPattern :: String -> Maybe String
formatPattern name = lookup name [("email", emailPattern), ("uuid", uuidPattern)]

-- | What a format accepts, for messages and documentation.
formatDescription :: String -> String
formatDescription name = case name of
  "email" -> "an RFC 822 address"
  "uuid" -> "a UUID in its 8-4-4-4-12 hexadecimal form"
  _ -> name

-- | A UUID as RFC 9562, section 4, writes it: 32 hexadecimal digits in groups
-- of 8, 4, 4, 4 and 12. Either case is accepted, as the RFC requires of a
-- reader; the version and variant digits are not constrained.
uuidPattern :: String
uuidPattern = hex 8 ++ "-" ++ hex 4 ++ "-" ++ hex 4 ++ "-" ++ hex 4 ++ "-" ++ hex 12
  where hex n = "[0-9a-fA-F]{" ++ show (n :: Int) ++ "}"

-- | RFC 822's `address`, in the portable dialect. The names are the
-- grammar's. Control characters stand for themselves in the pattern: the
-- dialect has escapes only for \n \t \r \f \v.
emailPattern :: String
emailPattern = many lwsp ++ group (mailbox ++ "|" ++ groupAddress) ++ "\\n?"
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

-- | What `email` does with a comment, RFC 822's parenthesized text.
data CommentPolicy
  -- | The module's regex alone: a comment outside a quoted string is refused.
  = RefuseComments
  -- | The module's `valid`: comments are replaced by a space first.
  | StripComments
  deriving (Eq, Show)

-- | The policy the `email` format has. Only RefuseComments is a regex, and so
-- only it is what the targets check; see the module comment.
emailCommentPolicy :: CommentPolicy
emailCommentPolicy = RefuseComments

-- | Whether a text is an address under a policy: the reference the recorded
-- vectors check, for both of the module's verdicts.
emailAccepts :: CommentPolicy -> String -> Bool
emailAccepts policy text = case emailRegex of
  Left _ -> False
  Right regex -> regexMatches regex (map fromEnum (case policy of
    RefuseComments -> text
    StripComments -> stripComments text))

-- | The pattern, parsed once.
emailRegex :: Either String Regex
emailRegex = parseRegex emailPattern

-- | The module's strip_comments: while the text has a comment with no comment
-- inside it, after a prefix whose quoted strings are closed, replace the
-- first such comment by one space. A backslash quotes the next character.
-- Perl's regex takes the longest such prefix first, and the order matters: a
-- comment may hold a quotation mark, which changes what later counts as
-- quoted. So the candidates are tried from the end of the text.
stripComments :: String -> String
stripComments text = maybe text stripComments (replaceOne text)
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
