-- | Lossless lexical source for authoring tools. Tokens keep their exact text
-- and offsets; the real parser/typed Core remains authoritative for meaning.
module LawSpec.SourceText (Token(..), TokenKind(..), sourceTokens, restoreSource,
  formatSource, utf16Position) where

import Data.Char (isAlphaNum, isSpace, ord)
import Data.List (isPrefixOf, mapAccumL)
import LawSpec.Common

data TokenKind = WordToken | SymbolToken | LiteralToken | PhraseToken | CommentToken | TriviaToken
  deriving (Eq,Show)
data Token = Token { tokenKind :: TokenKind, tokenText :: String, tokenOffset :: Int }
  deriving (Eq,Show)
sourceTokens :: String -> [Token]
sourceTokens = scan 0
  where
    scan _ [] = []
    scan offset input = let (kind,value,rest) = next input
      in Token kind value offset : scan (offset + length value) rest
    next input
      | "--" `isPrefixOf` input = let (a,b) = break (== '\n') input in (CommentToken,a,b)
      | "\"|" `isPrefixOf` input = let (a,b) = delimited '|' (drop 2 input) in (PhraseToken,"\"|" ++ a,b)
      | "`|" `isPrefixOf` input = let (a,b) = delimited '|' (drop 2 input) in (PhraseToken,"`|" ++ a,b)
      | '"':rest <- input = let (a,b) = delimited '"' rest in (LiteralToken,'"':a,b)
      | '`':rest <- input = let (a,b) = span (\c -> isAlphaNum c || c `elem` ("_." :: String)) rest in (PhraseToken,'`':a,b)
      | c:_ <- input, isSpace c = let (a,b) = span isSpace input in (TriviaToken,a,b)
      | c:_ <- input, isAlphaNum c || c == '_' = let (a,b) = span (\c -> isAlphaNum c || c == '_') input in (WordToken,a,b)
      | c:rest <- input = (SymbolToken,[c],rest)
      | otherwise = (TriviaToken,"",[])
    delimited _ [] = ("",[])
    delimited end ('\\':c:rest) = let (a,b) = delimited end rest in ('\\':c:a,b)
    delimited end (c:rest) | c == end = ([c],rest)
                         | otherwise = let (a,b) = delimited end rest in (c:a,b)
restoreSource :: [Token] -> String
restoreSource = concatMap tokenText

-- | Two-space indentation with literal/comment spelling retained. Line breaks
-- never create obligations. Existing line boundaries, including line-scoped
-- harness settings, remain intact; long indivisible literals are never split.
formatSource :: Source -> Source
formatSource (Source path body) = Source path (stabilize body)
  where
    -- Harness settings are line scoped. Their lines must not be reflowed.
    hasHarness = any (\t -> tokenKind t == WordToken && tokenText t == "harness") (sourceTokens body)
    stabilize text = let next = layout text
      in if next == text then next else stabilize next
    layout text = unlines (concatMap (if any multiline (sourceTokens text) then pure else wrap) (indent text))
    multiline token = tokenKind token `elem` [LiteralToken,PhraseToken] && '\n' `elem` tokenText token
    indent text = snd (mapAccumL formatLine (0 :: Int,[],[]) (zip offsets original))
      where
        original = lines text
        offsets = scanl (\n line -> n + length line + 1) 0 original
        protected = [(tokenOffset t,tokenOffset t + length (tokenText t)) | t <- sourceTokens text,
          tokenKind t `elem` [LiteralToken,PhraseToken], '\n' `elem` tokenText t]
        formatLine state@(depth,cases,braces) (offset,line)
          | any (\(start,end) -> start < offset && offset < end) protected = (state,line)
          | null (dropWhile isSpace line) = (state,"")
          | otherwise =
              let content = dropWhile isSpace line
                  tokens = [tokenText t | t <- sourceTokens content, tokenKind t `elem` [WordToken,SymbolToken]]
                  caseEnd = take 2 tokens == ["end","case"]
                  branch = take 1 tokens `elem` [["when"],["otherwise"]] && not (null cases)
                  base = case cases of current:_ -> current; [] -> depth
                  closing = case tokens of "end":_ -> 1; "}":_ -> 1; "else":_ -> 1; _ -> 0
                  indentation = max 0 (if caseEnd then base - 1 else if branch then base else depth - closing)
                  opened = opens tokens
                  ends = length (filter (== "end") tokens)
                  recordType = take 1 tokens == ["type"] && "record" `elem` tokens
                  (braceDelta,braces') = braceChanges recordType braces tokens
                  nextDepth = max 0 ((if branch then base + 1 else if caseEnd then base - 1 else depth) + opened -
                    (if caseEnd then max 0 (ends - 1) else ends) + braceDelta)
                  cases' = (if contains ["first","matching","case","of"] tokens then (nextDepth :) else id)
                    (if caseEnd then drop 1 cases else cases)
              in ((nextDepth,cases',braces'),replicate (indentation * 2) ' ' ++ trimOutsideLiteral content)
    opens tokens =
      (if take 1 tokens `elem` [["function"],["procedure"],["law"],["type"],["example"],["mapping"]] then 1 else 0) +
      length [() | (a,b) <- zip tokens (drop 1 tokens), a `elem` ["definition","description","rationale","references"], b == ":"] +
      length [() | (a,b) <- zip tokens (drop 1 tokens), (a,b) `elem` [("for","all"),("given","(")]] +
      length [() | rest <- suffixes tokens, any (`isPrefixOf` rest)
        [["there","exists"],["there","must","exist"],["there","must","not","exist"],["there","does","not","exist"]]] +
      (if contains ["first","matching","case","of"] tokens then 1 else 0) +
      (if take 1 tokens == ["if"] then 1 else 0) +
      (if "table" `elem` tokens && ":" `elem` tokens then 1 else 0)
    contains prefix tokens = any (isPrefixOf prefix) (suffixes tokens)
    suffixes [] = [[]]
    suffixes xs@(_:rest) = xs : suffixes rest
    braceChanges recordType initial tokens = go recordType 0 initial tokens
      where
        go _ delta stack [] = (delta,stack)
        go first delta stack ("{":rest) = go False (delta + if first then 0 else 1) (first:stack) rest
        go first delta (named:stack) ("}":rest) = go first (delta - if named then 0 else 1) stack rest
        go first delta [] ("}":rest) = go first delta [] rest
        go first delta stack (_:rest) = go first delta stack rest
    -- Wrap only at existing trivia, keeping phrases, strings and comments
    -- intact. Reindentation then accounts for the braces opened by each line.
    wrap line
      | hasHarness || length line <= 80 || any ((== CommentToken) . tokenKind) tokens = [line]
      | otherwise = case reverse [tokenOffset t | t <- tokens, tokenKind t == TriviaToken,
          tokenOffset t > indentation, tokenOffset t <= 80] of
          [] -> [line]
          split:_ -> take split line : wrap (replicate indentation ' ' ++ dropWhile isSpace (drop split line))
      where
        tokens = sourceTokens line
        indentation = length (takeWhile isSpace line)
    trimOutsideLiteral value = case reverse (sourceTokens value) of
      t:rest | tokenKind t == TriviaToken -> restoreSource (reverse rest)
      _ -> value

-- | Convert the parser's one-based, tab-expanded Unicode columns to zero-based
-- UTF-16 LSP positions. Supplementary characters count as two code units.
utf16Position :: Source -> Location -> (Int,Int)
utf16Position (Source _ body) location = (max 0 (line location - 1),units 1 0 text)
  where
    text = case drop (max 0 (line location - 1)) (lines body) of first:_ -> first; _ -> ""
    units column count _ | column >= LawSpec.Common.column location = count
    units _ count [] = count
    units column count (c:rest) = units (if c == '\t' then column + 8 - ((column - 1) `mod` 8) else column + 1)
      (count + if ord c > 0xffff then 2 else 1) rest
