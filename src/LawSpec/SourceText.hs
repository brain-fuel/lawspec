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
    indent text = snd (mapAccumL formatLine (0 :: Int,[],[],Nothing,[]) (zip offsets original))
      where
        original = lines text
        offsets = scanl (\n line -> n + length line + 1) 0 original
        protected = [(tokenOffset t,tokenOffset t + length (tokenText t)) | t <- sourceTokens text,
          tokenKind t `elem` [LiteralToken,PhraseToken], '\n' `elem` tokenText t]
        formatLine state@(depth,cases,braces,previous,handlers) (offset,line)
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
                  declarationType = take 1 tokens == ["type"] && (depth == 0 || maybe True (/= "of") previous)
                  handlerStart = take 1 tokens == ["handler"]
                  operation = take 1 handlers == [depth] && "is" `elem` tokens &&
                    take 1 tokens `notElem` [["handler"],["start"],["end"]]
                  opened = opens declarationType tokens + if operation then 1 else 0
                  ends = length (filter (== "end") tokens)
                  recordType = declarationType && "record" `elem` tokens
                  (braceDelta,braces') = braceChanges recordType braces tokens
                  nextDepth = max 0 ((if branch then base + 1 else if caseEnd then base - 1 else depth) + opened -
                    (if caseEnd then max 0 (ends - 1) else ends) + braceDelta)
                  cases' = (if contains ["first","matching","case","of"] tokens then (nextDepth :) else id)
                    (if caseEnd then drop 1 cases else cases)
                  handlers' = [level | level <- (if handlerStart && nextDepth > depth then nextDepth:handlers else handlers),
                    level <= nextDepth]
              in ((nextDepth,cases',braces',case reverse tokens of first:_ -> Just first; [] -> previous,handlers'),replicate (indentation * 2) ' ' ++ trimOutsideLiteral content)
    -- Wrapping may put the second word of "of type" at a line's start.
    -- That annotation continues the existing declaration, rather than opening
    -- a new type block and indenting every following declaration.
    opens declarationType tokens =
      (if declarationType || take 1 tokens `elem` [["function"],["procedure"],["law"],["example"],["mapping"],
        ["ability"],["handler"],["handlers"]] then 1 else 0) +
      length [() | (a,b) <- zip tokens (drop 1 tokens), a `elem` ["definition","description","rationale","references"], b == ":"] +
      length [() | (a,b) <- zip tokens (drop 1 tokens), (a,b) `elem` [("for","all"),("given","(")]] +
      length [() | rest <- suffixes tokens, any (`isPrefixOf` rest)
        [["there","exists"],["there","must","exist"],["there","must","not","exist"],["there","does","not","exist"]]] +
      (if contains ["first","matching","case","of"] tokens then 1 else 0) +
      length [() | (previous,word) <- zip ("":tokens) tokens,word == "handle" || word == "if" && previous /= "end"] +
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
          tokenOffset t > indentation, tokenOffset t <= 80,canSplit t] of
          [] -> [line]
          split:_ -> take split line : wrap (replicate indentation ' ' ++ dropWhile isSpace (drop split line))
      where
        tokens = sourceTokens line
        indentation = length (takeWhile isSpace line)
        -- Keep grammatical phrases together when wrapping. In particular,
        -- splitting "end function" would turn its second word into a false
        -- declaration opener on the next formatting pass.
        canSplit trivia = case
          (reverse [tokenText t | t<-tokens,tokenKind t/=TriviaToken,tokenOffset t<tokenOffset trivia],
            [tokenText t | t<-tokens,tokenKind t/=TriviaToken,tokenOffset t>tokenOffset trivia]) of
          (left:_,right:_) -> (left,right) `notElem` protectedPairs
          _ -> True
        protectedPairs = [("end",construct) | construct<-["function","procedure","type","case","if","mapping"]] ++
          [("of","type"),("one","of"),("first","matching"),("matching","case"),("case","of"),
           ("for","all"),("there","exists"),("there","must"),("there","does"),("must","exist"),
           ("must","not"),("does","not"),("not","exist"),("such","that"),("must","be"),
           ("given","("),("in","table")] ++
          [(section,":") | section<-["definition","description","rationale","references"]]
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
