-- | Formatting consumes the authoritative parser's block inventory. Tokens
-- retain literal and comment spelling; typed Core remains the only semantics.
module LawSpec.SourceText (module LawSpec.SourceTokens,
  formatSource, formatSources, formatSourcesUsing, formatSourceWithSyntax, utf16Position) where
import LawSpec.SourceTokens
import LawSpec.Common
import LawSpec.SourceSyntax (SyntaxNode(..), SourceSyntax(..))
import LawSpec.Compile (parseSourceSyntax)
import LawSpec.Blocks
import Data.Char (isSpace, ord)
import Data.List (mapAccumL)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

-- | Format only after the authoritative grammar accepts every source.
-- Syntax errors leave direct callers' source untouched; API callers receive
-- diagnostics. Semantic validation belongs to the checked compiler path.
formatSource :: Source -> Source
formatSource source = case formatSources [source] of
  Right [formatted] -> formatted
  _ -> source

formatSources :: [Source] -> Either [Diagnostic] [Source]
formatSources = formatSourcesUsing parseSourceSyntax

-- Package-aware callers can supply header discovery with original coordinates.
formatSourcesUsing :: ([Source] -> Either [Diagnostic] [SourceSyntax])
  -> [Source] -> Either [Diagnostic] [Source]
formatSourcesUsing parseSyntax sources = do
  inventory <- parseSyntax sources
  let formatted = [formatSourceWithSyntax
        (concat [syntaxNodes item | item <- inventory, syntaxPath item == path source]) source
        | source <- sources]
  _ <- parseSyntax formatted
  pure formatted

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
    recordDeclarations = [(offset (spanStart (syntaxSpan node)),offset (spanEnd (syntaxSpan node))) |
      node <- nodes,syntaxKind node == "record-declaration"]
    inRecordDeclaration index = any (\(begin,end) -> begin <= index && index < end) recordDeclarations
    recordBoundary node = syntaxKind node `elem`
      ["record-type-opener","record-type-field","record-type-closer"] ||
      (syntaxKind node == "closer" && syntaxName node == Just "type" &&
        inRecordDeclaration (offset (spanStart (syntaxSpan node))))
    nodeRange node = (offset (spanStart (syntaxSpan node)),offset (spanEnd (syntaxSpan node)))
    quantifierKinds = ["for all","exists","given"]
    quantifierKind node = case syntaxKind node of
      "quantifier.forall" -> Just "for all"
      "quantifier.exists" -> Just "exists"
      "quantifier.given" -> Just "given"
      _ -> Nothing
    -- ref:DEC-lawspec-quantifier-layout
    quantifierBoundary node = syntaxKind node == "quantifier-body" ||
      (syntaxKind node == "block-opener" && syntaxName node `elem` map Just quantifierKinds) ||
      (syntaxKind node == "closer" && syntaxName node `elem`
        map Just (quantifierKinds ++ ["definition","law","unit"]))
    originalLexed = sourceTokens original
    overlaps (begin,end) token = tokenOffset token < end &&
      begin < tokenOffset token + length (tokenText token)
    hasComment range = any (\token -> tokenKind token == CommentToken && overlaps range token) originalLexed
    -- Join only parser-owned flat bodies. Nested blocks, line-scoped syntax,
    -- comments and multiline literals retain their authored line boundaries.
    flatBody range@(begin,end) = not (hasComment range) &&
      not (any (\node -> let at = offset (spanStart (syntaxSpan node)) in
        begin <= at && at < end && syntaxKind node `elem` ["block-opener","line-expression"]) nodes) &&
      not (any (\token -> overlaps range token && tokenKind token `elem` [LiteralToken,PhraseToken] &&
        '\n' `elem` tokenText token) originalLexed)
    flatBodies = [range | node <- nodes,syntaxKind node == "quantifier-body",
      let range = nodeRange node,flatBody range]
    -- Long headers break between complete binders, never in a short range
    -- constraint. The separator gets its own aligned line in this layout.
    headers = [(begin,finish,separator) | node <- nodes,syntaxKind node == "quantifier-separator",
      let (separator,finish) = nodeRange node,
      let owners = [start | owner <- nodes,quantifierKind owner == syntaxName node,
            let (start,end) = nodeRange owner,start < separator && separator < end],
      not (null owners),let begin = maximum owners,
      not (hasComment (begin,finish)),
      not (any (\child -> let at = offset (spanStart (syntaxSpan child)) in
        syntaxKind child == "block-opener" && begin < at && at < separator) nodes)]
    headerDepth begin = length [kind | kind <- foldl step []
        [value | (index,value) <- Map.toAscList events,
          index < Map.findWithDefault 0 begin indices],kind /= UnitBlock]
      where step stack (True,kind) = kind:stack
            step stack (False,_) = drop 1 stack
    headerText (begin,finish,_) = restoreSource [token{tokenText = if tokenKind token == TriviaToken then " " else tokenText token} |
      token <- originalLexed,begin <= tokenOffset token && tokenOffset token < finish]
    longHeaders = [header | header@(begin,_,_) <- headers,
      2 * headerDepth begin + length (headerText header) > 80]
    headerBinders = [nodeRange node | (begin,_,separator) <- longHeaders,
      node <- nodes,syntaxKind node == "parameter",let range@(start,end) = nodeRange node,
      begin < start && end <= separator,
      not (any (\outer -> syntaxKind outer == "parameter" && nodeRange outer /= range &&
        let (a,b) = nodeRange outer in begin < a && a <= start && end <= b && b <= separator) nodes)]
    flatRanges = flatBodies ++ [(begin,finish) | (begin,finish,_) <- headers]
    flattened = Set.fromList [tokenOffset token + index | token <- originalLexed,
      tokenKind token == TriviaToken,
      (tokenOffset token + length (tokenText token)) `Set.notMember` lineBreaks,
      any (\(begin,end) -> begin <= tokenOffset token && tokenOffset token < end) flatRanges,
      (index,character) <- zip [0..] (tokenText token),character `elem` ['\n','\r']]
    lineBreaks = Set.fromList ([offset (spanStart (syntaxSpan node)) | node <- nodes,
      recordBoundary node || quantifierBoundary node] ++ map fst headerBinders ++
      [separator | (_,_,separator) <- longHeaders])
    -- Break only at parser-owned token boundaries, never inside trivia or
    -- literals. Existing line comments stay attached to their original line.
    rewritten = concat [
      (if index `Set.member` lineBreaks && any (not . isSpace)
        (takeWhile (/='\n') (reverse (take index original))) then "\n" else "") ++
      (if (index `Set.member` separators && character == ',') || index `Set.member` flattened
        then " " else [character]) |
      (index,character) <- zip [0..] original]
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
      syntaxKind node `elem` ["block-opener","closer"],
      not (syntaxName node == Just "type" &&
        inRecordDeclaration (offset (spanStart (syntaxSpan node)))),
      Just item <- [event node]]
    -- Removed commas no longer occupy a token ordinal. Rebase once, before
    -- formatting; later passes preserve the significant token sequence.
    removed = [index | (index,token) <- zip [0..] originalTokens,
      tokenOffset token `Set.member` separators]
    rebased = Map.fromList [(index-length (filter (<index) removed),value)
      | (index,value) <- Map.toList events]
    headerSeparators = Set.fromList [index-length (filter (<index) removed) |
      (_,_,separator) <- longHeaders,Just index <- [Map.lookup separator indices]]
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
    expressionRanges = Map.fromListWith max
      [(index-length (filter (<index) removed), finish-length (filter (<finish) removed)) |
        node <- nodes, take 11 (syntaxKind node) == "expression." ||
          syntaxKind node `elem` ["expectation","table-expectation","table-row"],
        Just index <- [Map.lookup (offset (spanStart (syntaxSpan node))) indices],
        let finish = maybe (length originalTokens) snd
              (Map.lookupGE (offset (spanEnd (syntaxSpan node))) indices)]
    stabilize count text
      | count >= (8 :: Int) = text
      | otherwise = let next = layout text in
          if next == text then next else stabilize (count+1) next
    layout text = unlines (concat (snd (mapAccumL render ([],[],Map.empty,False) numbered)))
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
        render (stack,braces,anchors,afterEquals) (start,value,local) =
          let first = case local of entry:_ -> Just entry; [] -> Nothing
              word = maybe "" (tokenText . snd) first
              closing = first >>= \(index,_) -> case Map.lookup index rebased of
                Just (False,kind) -> Just kind
                _ -> Nothing
              virtual = length [() | (CaseBlock,True) <- stack]
              branch = word `elem` ["when","otherwise"] && any ((==CaseBlock) . fst) stack
              branchVirtual = if branch && any (== (CaseBlock,True)) (take 1 stack) then 1 else 0
              blockDepth = length [() | (kind,_) <- stack,kind /= UnitBlock]
              tableHeader = case stack of
                (TableBlock,_):_ -> word == "expect" ||
                  take 2 (map (tokenText . snd) local) == ["in","table"]
                _ -> False
              structuralDepth = blockDepth + virtual - branchVirtual -
                (if tableHeader then 1 else 0) - case closing of
                Just CaseBlock -> 1 + if take 1 stack == [(CaseBlock,True)] then 1 else 0
                Just UnitBlock -> 0
                Just _ -> 1
                Nothing | word == "else" && any ((==IfBlock) . fst) stack -> 1
                        | word == "with" && any ((==ParBlock) . fst) stack -> 1
                        | otherwise -> 0
              -- Delimiters remember the indentation of their opening line.
              -- Nested keyword blocks still add their own levels; a record
              -- on a continued line keeps its fields and closer aligned.
              baseDepth = case (word,braces) of
                ("}",(opening,atDepth):_) -> opening + structuralDepth-atDepth
                _ -> maximum (structuralDepth :
                  [opening+1+structuralDepth-atDepth | (opening,atDepth) <- braces])
              -- Continued expressions get one additional level, even outside
              -- delimiters. Token ordinals keep this stable after wrapping.
              -- A surrounding expression cannot indent a nested block's
              -- branches or closers; their own parsed structure owns layout.
              active = case first of
                Just (index,_) -> Map.filterWithKey (\begin (finish,anchor) ->
                  begin < index && index < finish && anchor >= baseDepth) anchors
                Nothing -> Map.empty
              continuation = closing == Nothing && not branch &&
                word `notElem` ["else","with","expect","in","row", ")", "]", "}"] &&
                not (any (\(index,_) -> case Map.lookup index rebased of
                  Just (True,_) -> True
                  _ -> False) local)
              depth | maybe False (\(index,_) -> index `Set.member` headerSeparators) first = baseDepth-1
                    | continuation && (afterEquals || not (Map.null active)) =
                        1 + maximum (baseDepth : map snd (Map.elems active))
                    | otherwise = baseDepth
              branchStack = if branch then markBranch stack else stack
              final = foldl apply branchStack local
              literalLine = any (\(a,b) -> a < start && start < b) protected
              opensLiteral = any (\(a,b) -> start <= a && a <= start+length value && start+length value < b) protected
              content = (if opensLiteral then id else trim) (dropWhile isSpace (restoreSource [if tokenKind token == TriviaToken
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
              finalStructuralDepth = length [() | (kind,_) <- final,kind /= UnitBlock] +
                length [() | (CaseBlock,True) <- final]
              finalBraces = foldl (\current (_,token) -> case tokenText token of
                "{" -> (depth+max 0 (length current-length braces),finalStructuralDepth):current
                "}" -> drop 1 current
                _ -> current) braces local
              retained = case first of
                Just (index,_) -> Map.filter ((>index) . fst) anchors
                Nothing -> anchors
              newAnchors = foldl (\current (index,_) -> case Map.lookup index expressionRanges of
                Just finish -> Map.insert index (finish,depth +
                  if Just index /= fmap fst first && (branch ||
                    word `elem` ["function","procedure","operation","let","strategy"])
                    then 1 else 0) current
                Nothing -> current) retained local
              nextEquals = case reverse local of
                (_,token):_ -> tokenText token == "="
                [] -> afterEquals
          in ((final,finalBraces,newAnchors,nextEquals),output)
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
                         rest = replicate (indentation+2) ' ' ++ drop consumed value
                     in take split value : wrap rest
      where
        indentation = length (takeWhile isSpace value)
        lexed = sourceTokens value
        candidates = [tokenOffset token | (index,token) <- zip [0..] lexed,
          tokenKind token == TriviaToken, tokenOffset token > indentation,
          tokenOffset token <= 80, safeBoundary index]
        safeBoundary index = case
          (reverse [token | token <- take index lexed,tokenKind token /= TriviaToken],
           [token | token <- drop (index+1) lexed,tokenKind token /= TriviaToken]) of
          (left:_,right:_) -> (tokenText left,tokenText right) `notElem` protectedPairs &&
            not (tokenText left `elem` ["law","function","procedure"] && tokenKind right == PhraseToken) &&
            not (tokenKind left == PhraseToken && tokenText right == "is")
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
