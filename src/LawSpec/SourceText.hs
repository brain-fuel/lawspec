-- | Formatting consumes the authoritative parser's block inventory. Tokens
-- retain literal and comment spelling; typed Core remains the only semantics.
module LawSpec.SourceText (module LawSpec.SourceTokens,
  formatSource, formatSourceWithSyntax, utf16Position) where
import LawSpec.SourceTokens
import LawSpec.Common
import LawSpec.SourceSyntax (SyntaxNode(..), SourceSyntax(..))
import LawSpec.Compile (compileWithSourceSyntax)
import LawSpec.Blocks
import Data.Char (isSpace, ord)
import Data.List (mapAccumL)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

-- | Direct callers use the same checked inventory as CLI and editor formatting.
-- Invalid or incomplete source is left untouched; the compiler owns diagnostics.
formatSource :: Source -> Source
formatSource source = case compileWithSourceSyntax True (\_ name -> name)
    (\_ _ -> Nothing) 64 defaultGeneration [source] of
  Left _ -> source
  Right (_,_,inventory) -> formatSourceWithSyntax
    (concatMap syntaxNodes inventory) source

formatSourceWithSyntax :: [SyntaxNode] -> Source -> Source
formatSourceWithSyntax nodes (Source path original) = Source path (stabilize 0 rewritten)
  where
    positionOffsets = Map.fromList (zip positions [0..])
    positions = scanl advance (1,1) original
    advance (row,col) character = case character of
      '\n' -> (row+1,1)
      '\t' -> (row,col+8-((col-1) `mod` 8))
      _ -> (row,col+1)
    offset location = Map.findWithDefault (length original)
      (line location,column location) positionOffsets
    separators = Set.fromList [offset (spanStart (syntaxSpan node)) | node <- nodes,
      syntaxKind node == "record-type-separator"]
    rewritten = concat [if index `Set.member` separators && character == ','
      then " " else [character] | (index,character) <- zip [0..] original]
    significant text = [token | token <- sourceTokens text,
      tokenKind token `notElem` [TriviaToken,CommentToken]]
    originalTokens = significant original
    indices = Map.fromList [(tokenOffset token,index) | (index,token) <- zip [0..] originalTokens]
    event node = do
      index <- Map.lookup (offset (spanStart (syntaxSpan node))) indices
      label <- syntaxName node
      kind <- blockKind label
      pure (index,(syntaxKind node == "block-opener",kind))
    events = Map.fromList [item | node <- nodes,
      syntaxKind node `elem` ["block-opener","closer"],Just item <- [event node]]
    -- Removed commas no longer occupy a token ordinal. Rebase once, before
    -- formatting; later passes preserve the significant token sequence.
    removed = [index | (index,token) <- zip [0..] originalTokens,
      tokenOffset token `Set.member` separators]
    rebased = Map.fromList [(index-length (filter (<index) removed),value)
      | (index,value) <- Map.toList events]
    -- Layout changes physical offsets on each stabilization pass. Match the
    -- parser's line-scoped expressions by token identity, as for block events.
    lineExpressions = Set.fromList [index-length (filter (<index) removed) |
      node <- nodes,syntaxKind node == "line-expression",
      Just index <- [Map.lookup (offset (spanStart (syntaxSpan node))) indices]]
    quotedNames = Set.fromList [index-length (filter (<index) removed) |
      node <- nodes,syntaxKind node == "quoted-name",
      (index,token) <- zip [0..] originalTokens,
      offset (spanStart (syntaxSpan node)) <= tokenOffset token,
      tokenOffset token < offset (spanEnd (syntaxSpan node))]
    stabilize count text
      | count >= (8 :: Int) = text
      | otherwise = let next = layout text in
          if next == text then next else stabilize (count+1) next
    layout text = unlines (concat (snd (mapAccumL render ([],[]) numbered)))
      where
        allTokens = sourceTokens text
        code = significant text
        numberedTokens = zip [0..] code
        linesWithOffsets = zip (scanl (\n value -> n+length value+1) 0 (lines text)) (lines text)
        numbered = [(start,value,[(index,token) | (index,token) <- numberedTokens,
          start <= tokenOffset token,tokenOffset token < start+length value+1]) |
          (start,value) <- linesWithOffsets]
        protected = [(tokenOffset token,tokenOffset token+length (tokenText token)) |
          token <- allTokens,tokenKind token `elem` [LiteralToken,PhraseToken],
          '\n' `elem` tokenText token]
        render (stack,braces) (start,value,local) =
          let first = case local of entry:_ -> Just entry; [] -> Nothing
              word = maybe "" (tokenText . snd) first
              closing = first >>= \(index,_) -> case Map.lookup index rebased of
                Just (False,kind) -> Just kind
                _ -> Nothing
              virtual = length [() | (CaseBlock,True) <- stack]
              branch = word `elem` ["when","otherwise"] && any ((==CaseBlock) . fst) stack
              branchVirtual = if branch && any (== (CaseBlock,True)) (take 1 stack) then 1 else 0
              blockDepth = length [() | (kind,_) <- stack,kind /= UnitBlock]
              braceDepth = length (filter (== "{") braces) - if word == "}" then 1 else 0
              depth = blockDepth + braceDepth + virtual - branchVirtual - case closing of
                Just CaseBlock -> 1 + if take 1 stack == [(CaseBlock,True)] then 1 else 0
                Just UnitBlock -> 0
                Just _ -> 1
                Nothing | word == "else" && any ((==IfBlock) . fst) stack -> 1
                        | word == "with" && any ((==ParBlock) . fst) stack -> 1
                        | otherwise -> 0
              branchStack = if branch then markBranch stack else stack
              final = foldl apply branchStack local
              literalLine = any (\(a,b) -> a < start && start < b) protected
              content = trim (dropWhile isSpace (restoreSource [if tokenKind token == TriviaToken
                then token{tokenText=" "} else token | token <- sourceTokens value]))
              indented = replicate (2 * max 0 depth) ' ' ++ content
              output | literalLine = [value]
                     | null content = [""]
                     | any (\token -> tokenKind token == CommentToken &&
                         start <= tokenOffset token && tokenOffset token < start+length value+1) allTokens = [indented]
                     | any (\(a,b) -> a < start+length value+1 && start < b) protected = [indented]
                     | any ((==ScenarioBlock) . fst) stack = [indented]
                     | any (\(index,_) -> index `Set.member` lineExpressions || index `Set.member` quotedNames) local = [indented]
                     | otherwise = wrap indented
              finalBraces = foldl (\current (_,token) -> case tokenText token of
                "{" -> (if null current && any (\(index,_) -> Map.lookup index rebased == Just (True,TypeBlock)) local then "" else "{"):current
                "}" -> drop 1 current
                _ -> current) braces local
          in ((final,finalBraces),output)
        apply stack (index,_) = case Map.lookup index rebased of
          Just (True,kind) -> (kind,False):stack
          Just (False,_) -> drop 1 stack
          Nothing -> stack
        markBranch [] = []
        markBranch ((CaseBlock,_):rest) = (CaseBlock,True):rest
        markBranch (item:rest) = item:markBranch rest
    trim value = case reverse (sourceTokens value) of
      token:rest | tokenKind token == TriviaToken -> restoreSource (reverse rest)
      _ -> value
    wrap value
      | length value <= 80 = [value]
      | otherwise = case reverse candidates of
          [] -> [value]
          split:_ -> let consumed = split + length (takeWhile isSpace (drop split value))
                         rest = replicate indentation ' ' ++ drop consumed value
                     in take split value : wrap rest
      where
        indentation = length (takeWhile isSpace value)
        lexed = sourceTokens value
        candidates = [tokenOffset token | (index,token) <- zip [0..] lexed,
          tokenKind token == TriviaToken, tokenOffset token > indentation,
          tokenOffset token <= 80, safeBoundary index]
        safeBoundary index = case
          (reverse [tokenText token | token <- take index lexed,tokenKind token /= TriviaToken],
           [tokenText token | token <- drop (index+1) lexed,tokenKind token /= TriviaToken]) of
          (left:_,right:_) -> (left,right) `notElem` protectedPairs
          _ -> True
        protectedPairs = concatMap (\phrase -> zip phrase (drop 1 phrase))
          (["end":words (blockLabel kind) | kind <- blockKinds] ++
           [["of","type"],["one","of"],["first","matching","case","of"],
            ["for","all"],["there","exists"],["there","must","not","exist"],
            ["there","does","not","exist"],["such","that"],["must","be"],
            ["in","table"],["for","law"],["for","laws"]])

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
