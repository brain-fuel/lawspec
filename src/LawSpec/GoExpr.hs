-- | Go expression documents for checked Core, shared by definitions and properties.
module LawSpec.GoExpr
  ( renderExpression, renderExpressionWithContext, scalarLiteral, textLiteral, call, array, quoted, runeLiteral
  , declare, identifiers, generatedHeader, goHeaderDoc, condition, keyed, funcLiteral, parenthesised
  ) where

import LawSpec.Core
import qualified LawSpec.GoTypeRefs as Native
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import LawSpec.Code.Literal (literalFor, printable)
import LawSpec.SourceLink (goGeneratedMarker)
import Data.Char (chr, isAlphaNum)
import Data.List (find)
import Numeric (showHex)

-- | Strings are Go string literals, escaped by Go's table
-- (LawSpec.Code.Literal), so no generated literal can end early or change
-- meaning. ref:DEC-native-string-literals
quoted :: String -> D.Doc
quoted = D.text . literalFor "go"

-- | The first lines of every generated Go file: the marker Go's tools
-- recognise generated files by, then the specification it comes from.
generatedHeader :: Maybe FilePath -> D.Doc
generatedHeader source = D.text ("// " ++ goGeneratedMarker) <>
  maybe mempty (\path -> D.hardline <> D.text ("// Source: " ++ path)) source

-- | The marker and the blank line before a generated file's package clause.
goHeaderDoc :: D.Doc
goHeaderDoc = generatedHeader Nothing <> D.hardline <> D.hardline

-- | A character as a Go rune literal: printable characters as they are,
-- Go's escapes otherwise.
runeLiteral :: Char -> String
runeLiteral c = "'" ++ escaped ++ "'"
  where
    escaped = case c of
      '\\' -> "\\\\"
      '\'' -> "\\'"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      _ | printable c -> [c]
        | fromEnum c < 0x10000 -> "\\u" ++ hex 4 (fromEnum c)
        | otherwise -> "\\U" ++ hex 8 (fromEnum c)
    hex n v = let digits = showHex v "" in replicate (n - length digits) '0' ++ digits

-- | Text as Go writes it. Text holds Unicode scalar values only, so every
-- value is a valid Go string literal.
textLiteral :: [Int] -> D.Doc
textLiteral units = call "lsText" [quoted (map chr units)]

-- | Locals, each followed by the statements that may read it. Go refuses a
-- local nothing reads, so one that is unread is marked used with _ = name;
-- a pure one (droppable) is left out instead.
declare :: [(String, D.Doc, Bool)] -> [D.Doc] -> [D.Doc]
declare [] rest = rest
declare ((name, value, droppable) : others) rest
  | name `elem` identifiers (D.render D.Compact (D.joinWith D.hardline later)) = defined : later
  | droppable = later
  | otherwise = defined : D.text ("_ = " ++ name) : later
  where
    later = declare others rest
    defined = D.text (name ++ " := ") <> value

-- | Whether an expression is already wrapped in one pair of parentheses:
-- gofmt prints ((x)) as (x).
parenthesised :: D.Doc -> Bool
parenthesised doc = let rendered = D.render D.Compact doc in '\n' `notElem` rendered && wholly rendered
  where
    wholly ('(' : rest) = closes (0 :: Int) rest
    wholly _ = False
    closes depth text' = case text' of
      [] -> False
      '"' : more -> closes depth (skip '"' more)
      '\'' : more -> closes depth (skip '\'' more)
      '(' : more -> closes (depth + 1) more
      ")" | depth == 0 -> True
      ')' : more | depth == 0 -> False
                 | otherwise -> closes (depth - 1) more
      _ : more -> closes depth more
    skip q text' = case text' of
      [] -> []
      '\\' : _ : more -> skip q more
      c : more | c == q -> more
               | otherwise -> skip q more

-- | An if statement's condition as gofmt writes it: without parentheses
-- around the whole, unless a composite literal of a named type inside needs
-- them (Go would read its brace as the block's).
condition :: D.Doc -> D.Doc
condition doc
  | '\n' `elem` rendered = doc
  | otherwise = D.text (strip rendered)
  where
    rendered = D.render D.Compact doc
    strip text'
      | Just inner <- wrapped text', not (namedLiteral inner) = strip inner
      | otherwise = text'
    -- (x) whose opening parenthesis closes at the very end.
    wrapped ('(' : rest) | closesAtEnd (0 :: Int) rest = Just (init rest)
    wrapped _ = Nothing
    closesAtEnd depth text'' = case text'' of
      [] -> False
      '"' : more -> closesAtEnd depth (skipQuoted '"' more)
      '\'' : more -> closesAtEnd depth (skipQuoted '\'' more)
      '(' : more -> closesAtEnd (depth + 1) more
      ")" | depth == 0 -> True
      ')' : more | depth == 0 -> False
                 | otherwise -> closesAtEnd (depth - 1) more
      _ : more -> closesAtEnd depth more
    skipQuoted q text'' = case text'' of
      [] -> []
      '\\' : _ : more -> skipQuoted q more
      c : more | c == q -> more
               | otherwise -> skipQuoted q more
    -- A brace right after a name, outside a parenthesised group: Name{...}.
    namedLiteral = go [] ' '
      where
        go _ _ [] = False
        go stack previous text'' = case text'' of
          '"' : more -> go stack '"' (skipQuoted '"' more)
          '\'' : more -> go stack '\'' (skipQuoted '\'' more)
          '(' : more -> go ((isAlphaNum previous || previous `elem` ("_)]" :: String)) : stack) '(' more
          ')' : more -> go (drop 1 stack) ')' more
          '{' : more | (isAlphaNum previous || previous == '_') && and stack -> True
                     | otherwise -> go stack '{' more
          c : more -> go stack c more

-- | A keyed composite literal, Type{ Key: value, ... }, one field a line.
-- gofmt aligns the values of consecutive one-line fields in a column; a
-- field whose value spans lines stands alone. An empty literal is Type{}.
keyed :: String -> [(String, D.Doc)] -> D.Doc
keyed ty [] = D.text (ty ++ "{}")
keyed ty fields = D.text (ty ++ "{") <> D.nest 8 (mconcat (map (D.hardline <>) (concatMap run (groups fields)))) <> D.hardline <> D.text "}"
  where
    oneLine value = '\n' `notElem` D.render D.Compact value
    groups [] = []
    groups xs@((_, v) : _) | oneLine v = let (single, rest) = span (oneLine . snd) xs in single : groups rest
    groups (x : rest) = [x] : groups rest
    run entries = let width = maximum (map (length . fst) entries) in
      [ D.text (key ++ ":" ++ replicate (if length entries > 1 then width - length key + 1 else 1) ' ') <> value <> D.text ","
      | (key, value) <- entries ]

-- | A function literal whose body spans lines, so gofmt keeps it as it is.
funcLiteral :: String -> [D.Doc] -> D.Doc
funcLiteral signature body = D.text ("func" ++ signature ++ " ") <> D.block 8 (D.joinWith D.hardline body)

-- | The identifiers Go code mentions, outside string, rune and raw literals
-- and comments.
identifiers :: String -> [String]
identifiers source = case source of
  [] -> []
  '"' : rest -> identifiers (quotedEnd '"' rest)
  '\'' : rest -> identifiers (quotedEnd '\'' rest)
  '`' : rest -> identifiers (drop 1 (dropWhile (/= '`') rest))
  '/' : '/' : rest -> identifiers (dropWhile (/= '\n') rest)
  c : rest | word c -> let (w, after) = span word (c : rest) in w : identifiers after
           | otherwise -> identifiers rest
  where
    word c = isAlphaNum c || c == '_'
    quotedEnd q text' = case text' of
      [] -> []
      '\\' : _ : more -> quotedEnd q more
      c : more | c == q -> more
               | otherwise -> quotedEnd q more

-- | Arguments wrap when a call is too wide, in the Go style LawSpec follows.
-- ref:DEC-readable-output-default
call :: String -> [D.Doc] -> D.Doc
-- gofmt does not wrap calls to a column limit. Keeping their arguments inline
-- also keeps nested function-literal blocks at the correct lexical indentation.
call name values = D.text (name ++ "(") <> D.joinWith (D.text ", ") values <> D.text ")"

-- | Lists of runtime values are written in one shape: on one line when they
-- fit, otherwise one value a line with a trailing comma, as gofmt keeps them.
array :: [D.Doc] -> D.Doc
array values
  -- A function literal inside keeps the list on its line, so the literal's
  -- block is indented from that line, as gofmt indents it.
  | any multiline values = D.text "[]LawSpecValue{" <> D.joinWith (D.text ", ") values <> D.text "}"
  | otherwise = D.delimitTrailing 8 "[]LawSpecValue{" "}" values
  where multiline value = '\n' `elem` D.render D.Compact value

-- | Literals become runtime values built from their declared type and exact
-- digits, so Go never reads a number at its own precision.
-- ref:DEC-portable-exact-arithmetic
scalarLiteral :: Type -> Scalar -> Either String D.Doc
scalarLiteral ty value = case value of
  SInteger name number -> pure (call "lsInteger" [quoted name,quoted (show number)])
  SBool valueBool -> pure (call "lsBool" [D.text (if valueBool then "true" else "false")])
  SDecimal c e -> pure (call "lsDecimal" [quoted (show c),quoted (show e)])
  SRational n d -> pure (call "lsRational" [quoted (show n),quoted (show d)])
  SFloat name pattern -> pure (call "lsFloating" [quoted name,quoted pattern])
  SComplex name real imaginary -> do
    a <- scalarLiteral (scalarType (scalarName real)) real
    b <- scalarLiteral (scalarType (scalarName imaginary)) imaginary
    pure (call "lsComplex" [quoted name,a,b])
  SCharacter "Char" point | point < 0xD800 || point > 0xDFFF -> pure (call "lsChar" [D.text (runeLiteral (chr point))])
  SCharacter name point -> pure (call "lsCharacter" [quoted name,D.text (show point)])
  SSequence "Text" units -> pure (textLiteral units)
  SSequence name units -> pure (call "lsSequence" [quoted name,
    D.delimitTrailing 8 "[]int{" "}" (map (D.text . show) units)])
  SSymbol identity description -> pure (call "lsSymbol" [quoted identity,quoted description,D.text "symbols"])
  SAbsent name -> pure (call "lsAbsent" [quoted name])
  SPresent name payload -> do
    let inner = case ty of Constructor _ [TypeArgument valueType] -> valueType; _ -> ty
    child <- maybe (pure (D.text "nil")) (fmap (call "lsPointer" . pure) . scalarLiteral inner) payload
    pure (call "lsPresent" [case ty of Constructor _ [_] -> quoted (Native.goDataKey ty); _ -> quoted name,child])

-- | Expressions are rendered from Core, never from source, so the Go tests
-- check the same expansion as every other target.
-- ref:DEC-typed-core-boundary
renderExpression :: [DataDeclaration] -> Int -> String -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpression declarations bits schema = renderExpressionWithContext declarations
  (D.text (show bits)) schema (fmap D.text . Native.goTypeReference)
  (pure . quoted . Native.goDataKey)

-- | Callers whose generated code already holds the machine width and type
-- references in scope pass them in, so the rendering refers to them by name.
renderExpressionWithContext :: [DataDeclaration] -> D.Doc -> String
  -> (Type -> Either String D.Doc) -> (Type -> Either String D.Doc) -> (Id -> String)
  -> (Expr -> [D.Doc] -> Either String D.Doc) -> Expr -> Either String D.Doc
renderExpressionWithContext declarations width schema ref key local external = render
  where
    structural (TypeVariable _) = True
    structural ty = Native.requiresSchema declarations ty
    checked ty value
      | structural ty = do
          reference <- ref ty
          pure (call (schema ++ ".validate") [reference,value,width,D.text "symbols"])
      | otherwise = do
          name <- key ty
          pure (call "lsConvert" [name,value,width])
    render term
      -- An all group's steps run side by side, each on a goroutine.
      | Just (fields,binders,body) <- concurrentGroup term = do
          steps <- mapM render fields
          inner <- render body
          let resultsName = "results"
              bindings = [(local (binderId binder), D.text (resultsName ++ "[" ++ show i ++ "]"), True)
                | (i,binder) <- zip [0::Int ..] binders]
              thunk step = D.text "func() LawSpecValue " <> D.block 8 (D.text "return " <> step)
          pure (D.text "func() LawSpecValue " <> D.block 8 (D.joinWith D.hardline
            ([D.text (resultsName ++ " := ") <> call "lsConcurrently" (map thunk steps)] ++
             declare bindings [D.text "return " <> inner])) <> D.text "()")
    render term = case expressionNode term of
      -- Field nodes are lowered to matches before any backend (lowerFieldNodes).
      Project {} -> Left "a field node reached the backend"
      Update {} -> Left "a record update node reached the backend"
      AllPayloads value predicates -> do
        argument <- render value
        reference <- ref (expressionType value)
        callbacks <- mapM (\(binder,predicate) -> do
          body <- render predicate
          pure (D.text ("func(" ++ local (binderId binder) ++ " LawSpecValue) LawSpecValue ") <>
            D.block 8 (D.text "return " <> body))) predicates
        let functions = D.text "[]func(LawSpecValue) LawSpecValue{" <>
              D.joinWith (D.text ", ") callbacks <> D.text "}"
        pure (call (schema ++ ".allPayloads")
          [reference,argument,functions,width,D.text "symbols"])
      AllElements value binder predicate -> do
        argument <- render value
        body <- render predicate
        pure (call "lsAllElements" [argument,
          D.text ("func(" ++ local (binderId binder) ++ " LawSpecValue) LawSpecValue ") <>
            D.block 8 (D.text "return " <> body)])
      Local identity -> pure (D.text (local identity))
      -- let x = e in body: e runs first, once.
      Let binder value body -> do
        argument <- render value
        inner <- render body
        let name = local (binderId binder)
        pure (call "lsEvaluate" [D.text "func() LawSpecValue " <> D.block 8 (D.joinWith D.hardline
          (declare [(name, argument, False)] [D.text "return " <> inner]))])
      -- Text and characters are always valid as written.
      Constant value@(SSequence "Text" _) | expressionType term == scalarType "Text" -> scalarLiteral (expressionType term) value
      Constant value@(SCharacter "Char" _) | expressionType term == scalarType "Char" -> scalarLiteral (expressionType term) value
      -- So are booleans and unbounded integers.
      Constant value@(SBool _) | expressionType term == scalarType "Bool" -> scalarLiteral (expressionType term) value
      Constant value@(SInteger name _) | name `elem` ["Integer", "BigInt"], expressionType term == scalarType name -> scalarLiteral (expressionType term) value
      Constant value -> scalarLiteral (expressionType term) value >>= checked (expressionType term)
      Construct tag args -> do
        values <- mapM render args
        if structural (expressionType term) then do
          reference <- ref (expressionType term)
          pure (call (schema ++ ".construct") [reference,quoted (idText tag),array values,width,D.text "symbols"])
        else do
          name <- key (expressionType term)
          pure (call "lsConstruct" [name,quoted (idText tag),array values])
      ExternalCall _ args -> mapM render args >>= external term
      -- Ability nodes go to the caller, which knows where handlers are.
      Perform _ args -> mapM render args >>= external term
      Handle _ body -> render body >>= external term . pure
      Calls _ args -> mapM render (maybe [] id args) >>= external term
      Convert mode target value -> do
        argument <- render value
        case mode of
          CheckedArgument -> checked target argument
          Explicit -> do
            name <- key target
            pure (call "lsHelper" [name,array [argument],width])
      If c a b -> do
        condition <- render c
        yes <- render a
        no <- render b
        pure (call "lsEvaluate" [D.text "func() LawSpecValue " <> D.block 8 (D.joinWith D.hardline
          [D.text "if " <> call "lsTruth" [condition] <> D.text " " <> D.block 8 (D.text "return " <> yes),
           D.text "return " <> no])])
      ShortCircuit op a b -> do
        left <- render a
        right <- render b
        pure (call "lsBool" [call "lsTruth" [left] <>
          D.text (if op == And then " && " else " || ") <> call "lsTruth" [right]])
      Unary Not value -> do
        argument <- render value
        pure (call "lsBool" [D.text "!" <> call "lsTruth" [argument]])
      Unary Negate value -> do
        argument <- render value
        pure (call "lsHelper" [quoted "negate",array [argument],width])
      Binary op _ a b -> do
        left <- render a
        right <- render b
        if structural (expressionType a) then do
          reference <- ref (expressionType a)
          pure (call "lsBool" [(if op == NotEqual then D.text "!" else mempty) <>
            call (schema ++ ".equal") [reference,left,right,width,D.text "symbols"]])
        else pure (call "lsBinary" [quoted (binaryName op),left,right])
      Helper Concurrently [value] -> render value
      Helper builtin args -> do
        values <- mapM render args
        pure (call "lsHelper" [quoted (builtinName builtin),array values,width])
      Match scrutinee branches -> do
        -- Values are checked where they are built, decoded or drawn.
        value <- render scrutinee
        -- Each match is a function of its own, so these names never meet
        -- another match's; a source binder never takes them (LawSpec.Naming).
        let matchedName = "matched"
            itemsName = "matchedItems"
            fieldsName = "matchedData"
            bind binder expression = (local (binderId binder), expression, True)
            invoke body = D.text "func() LawSpecValue " <> D.block 8 body <> D.text "()"
        case expressionType scrutinee of
          Constructor "List" _ -> do
            nil <- lookupBranch branches "List::Nil"
            cons <- lookupBranch branches "List::Cons"
            nilBody <- render (caseBody nil)
            consBody <- render (caseBody cons)
            name <- key (expressionType scrutinee)
            bindings <- case caseBinders cons of
              [headBinder,tailBinder] -> pure [bind headBinder (D.text (itemsName ++ "[0]")),
                bind tailBinder (call "lsList" [name,D.text (itemsName ++ "[1:]")])]
              _ -> Left "invalid Go list match binders"
            pure (invoke (D.joinWith D.hardline
              ([D.text (matchedName ++ " := ") <> value,
                D.text (itemsName ++ " := " ++ matchedName ++ ".Data.([]LawSpecValue)"),
                D.text ("if len(" ++ itemsName ++ ") == 0 ") <> D.block 8 (D.text "return " <> nilBody)] ++
               declare bindings [D.text "return " <> consBody])))
          Constructor name _ | name `elem` ["Maybe","Either"] -> do
            let (helper,tags) = if name == "Maybe" then ("lsMatchMaybe",["Maybe::Absent","Maybe::Present"])
                  else ("lsMatchEither",["Either::Left","Either::Right"])
            arms <- mapM (\tag -> lookupBranch branches tag >>= closure) tags
            pure (call helper (value:arms))
          Constructor _ _ -> do
            arms <- mapM (\branch -> do
              body <- render (caseBody branch)
              let bindings = [bind binder (D.text (fieldsName ++ ".fields[" ++ show i ++ "]"))
                    | (i,binder) <- zip [0::Int ..] (caseBinders branch)]
              pure (D.text "case " <> quoted (idText (caseConstructor branch)) <> D.text ":" <>
                D.nest 8 (D.hardline <> D.joinWith D.hardline (declare bindings [D.text "return " <> body])))) branches
            pure (invoke (D.joinWith D.hardline
              [D.text (matchedName ++ " := ") <> value,
               D.text (fieldsName ++ " := " ++ matchedName ++ ".Data.(lawSpecData)"),
               D.text ("switch " ++ fieldsName ++ ".tag {") <> D.hardline <>
                 D.joinWith D.hardline (arms ++ [D.text "default:" <> D.nest 8
                   (D.hardline <> D.text "panic(\"invalid constructor in match\")")]) <>
                 D.hardline <> D.text "}"]))
          _ -> Left "matching requires a Go data type"
    lookupBranch branches tag = maybe (Left "non-exhaustive Go match") Right (find ((== Id tag) . caseConstructor) branches)
    closure branch = do
      body <- render (caseBody branch)
      pure (D.text "func" <> D.delimitTrailing 8 "(" ")"
        [D.text (local (binderId binder) ++ " LawSpecValue") | binder <- caseBinders branch] <>
        D.text " LawSpecValue " <> D.block 8 (D.text "return " <> body))
