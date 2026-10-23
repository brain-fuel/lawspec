-- | F# laid out as Fantomas lays it out with its default settings, so that
-- generated F# is a fixed point of the formatter. LawSpec prints the code
-- itself; Fantomas only checks it, in acceptance. The rules are Fantomas
-- 8's: a 120-column line, a value binding on one line while name = value
-- takes up to 80 columns, a function's body on its declaration's line while
-- it is under 40, lists up to 80, records up to 40 and conditionals up to 60
-- columns on one line, closing brackets left out of a line's measure, and a
-- blank line around each statement or member that spans lines.
-- ref:DEC-readable-output-default ref:fantomas
module LawSpec.DotNet.Layout
  ( F(..), Stmt(..), Lines
  , pageWidth, columns, pad, opening, closing, separated, separatedBy, linesDoc
  , flat, expr, item, block, binding, function, matchLines, methodLike, needsParens, atom
  , exprW, itemW, blockW, bindingW, functionW, breakLast, dottedLines
  ) where

import qualified LawSpec.Code.Doc as D
import Data.List (intercalate)

-- | An F# expression, as far as its layout goes.
data F
  -- | Text that never breaks: a name, a literal, an expression written out.
  = A String
  -- | A function applied to arguments: f a b.
  | App String [F]
  -- | A method or constructor applied to a tuple: Value.Data(a, b).
  | Method String [F]
  | List [F]
  | Tuple [F]
  -- | A record expression: { A = a; B = b }.
  | Record [(String, F)]
  -- | fun with its parameters' text, and its body.
  | Fun String F
  -- | match e with | pattern -> body.
  | Match F [(String, F)]
  | Cond F F F
  -- | Statements, then a result.
  | Block [Stmt] F
  -- | An infix operator between operands: a |> f.
  | Infix String F F
  -- | An expression in parentheses of its own.
  | Paren F
  -- | A prefix operator: -x.
  | Prefix String F
  -- | An expression with its type: (x : T).
  | Annotated F String
  deriving (Eq, Show)

-- | A let binding, a local function (its declaration, parameters, result
-- type and body) or an expression evaluated for its effect.
data Stmt = LetS String F | DefS String [String] (Maybe String) F | DoS F deriving (Eq, Show)

-- | Lines of code. In an expression's lines the first continues the current
-- line and the rest carry their own indentation; a block's lines all do.
type Lines = [String]

pageWidth :: Int
pageWidth = 120

-- | A line's width as Fantomas counts it: in text elements, so a character
-- and the marks that combine with it, an emoji sequence joined by ZWJ or a
-- pair of regional indicators count once. Character widths come from
-- LawSpec's pinned Unicode tables, never the host's.
columns :: String -> Int
columns = go False
  where
    go _ [] = 0
    go joined (c : rest)
      | c == '\x200D' = go True rest
      | joined = go False rest
      | fromEnum c >= 0x300 && D.displayWidth [c] == 0 = go False rest
      | regional c, d : more <- rest, regional d = 1 + go False more
      | otherwise = 1 + go False rest
    regional c = c >= '\x1F1E6' && c <= '\x1F1FF'

pad :: Int -> String -> String
pad i s = replicate i ' ' ++ s

-- | Text after an expression's last line (a closing bracket).
closing :: String -> Lines -> Lines
closing s [] = [s]
closing s ls = init ls ++ [last ls ++ s]

-- | Text before an expression's first line.
opening :: String -> Lines -> Lines
opening s [] = [s]
opening s (l : ls) = (s ++ l) : ls

-- | Statements or members joined, with a blank line around each that spans
-- lines.
separated :: [Lines] -> Lines
separated (a : rest@(b : _)) = a ++ ["" | length a > 1 || length b > 1] ++ separated rest
separated [a] = a
separated [] = []

-- | Groups of lines joined by a separator.
separatedBy :: Lines -> [Lines] -> Lines
separatedBy = intercalate

-- | A block's lines as a document, relative to the block's indentation.
linesDoc :: Int -> Lines -> D.Doc
linesDoc base ls = D.joinWith D.hardline [D.text (drop base l) | l <- ls]

-- | Whether F# calls a function as a method: its name's last part is
-- capitalised, and Fantomas writes it next to a parenthesised argument.
methodLike :: String -> Bool
methodLike f = case reverse (takeWhile (/= '.') (reverse f)) of
  c : _ -> c >= 'A' && c <= 'Z'
  [] -> False

-- | Whether an argument needs parentheses.
needsParens :: F -> Bool
needsParens e = case e of
  A s -> any (== ' ') s && not (wrapped s)
  App _ _ -> True
  Method _ _ -> True
  Fun _ _ -> True
  Match _ _ -> True
  Cond {} -> True
  Block _ _ -> True
  Infix {} -> True
  Prefix {} -> True
  _ -> False
  where
    wrapped s = case (s, reverse s) of
      ('(' : _, ')' : _) -> balanced s
      ('[' : _, ']' : _) -> balanced s
      ('"' : _, '"' : _) -> '"' `notElem` init (drop 1 s)
      _ -> False
    balanced s = go (0 :: Int) (zip [1 :: Int ..] s)
      where
        go _ [] = True
        go depth ((k, c) : rest)
          | c `elem` ("([{" :: String) = go (depth + 1) rest
          | c `elem` (")]}" :: String) = let d = depth - 1 in (d > 0 || k == length s) && go d rest
          | otherwise = go depth rest

-- | An expression on one line, when it has no statements and Fantomas's
-- widths allow it.
flat :: F -> Maybe String
flat e = case e of
  A s -> Just s
  App f [] -> Just (f ++ (if methodLike f then "()" else " ()"))
  App f [a] | needsParens a || parenthesised a, methodLike f -> (f ++) <$> atom a
  App f args -> unwords . (f :) <$> mapM atom args
  Method f args -> (\as -> f ++ "(" ++ intercalate ", " as ++ ")") <$> mapM flat args
  List [] -> Just "[]"
  List xs -> do
    items <- mapM flat xs
    within 80 ("[ " ++ intercalate "; " items ++ " ]")
  Tuple xs -> (\as -> "(" ++ intercalate ", " as ++ ")") <$> mapM flat xs
  Record [] -> Just "{}"
  Record fields -> do
    fs <- mapM (\(n, v) -> ((n ++ " = ") ++) <$> flat v) fields
    within 40 ("{ " ++ intercalate "; " fs ++ " }")
  Fun ps b -> (\body -> "fun " ++ ps ++ " -> " ++ body) <$> flat b
  Cond c a b -> do
    s <- (\c' a' b' -> "if " ++ c' ++ " then " ++ a' ++ " else " ++ b') <$> flat c <*> flat a <*> flat b
    within 60 s
  -- Fantomas keeps an infix expression on one line up to 80 columns.
  Infix o a b -> (\x y -> x ++ " " ++ o ++ " " ++ y) <$> flat a <*> flat b >>= within 80
  Block [] r -> flat r
  Paren x -> (\y -> "(" ++ y ++ ")") <$> flat x
  Prefix o x -> (o ++) <$> atom x
  Annotated x t -> (\y -> "(" ++ y ++ ": " ++ t ++ ")") <$> flat x
  _ -> Nothing
  where within n s = if columns s <= n then Just s else Nothing

-- | Whether an argument is written in parentheses of its own: unit, a
-- tuple, a parenthesised expression.
parenthesised :: F -> Bool
parenthesised a = case a of
  A "()" -> True
  Tuple _ -> True
  Paren _ -> True
  Annotated _ _ -> True
  A s -> enclosed s
  _ -> False
  where
    -- Text whose first parenthesis closes at its end.
    enclosed s = case s of
      '(' : _ -> go (0 :: Int) (zip [1 :: Int ..] s)
      _ -> False
      where
        go _ [] = False
        go depth ((k, c) : rest)
          | c == '(' = go (depth + 1) rest
          | c == ')' = if depth == 1 then k == length s else go (depth - 1) rest
          | c == '"' = go depth (drop 1 (dropWhile ((/= '"') . snd) rest))
          | otherwise = go depth rest

-- | An argument on one line, parenthesised when it must be.
atom :: F -> Maybe String
atom a = (\s -> if needsParens a then "(" ++ s ++ ")" else s) <$> flat a

-- | An expression starting at column c of a line indented i: on one line
-- when it fits, else broken as Fantomas breaks it.
exprW :: Int -> Int -> Int -> F -> Lines
exprW w i c e = case flat e of
  Just s | c + columns s - closer <= w || unbreakable -> [s]
  _ -> brokenW w i c e
  where
    -- A parenthesis that closes a tuple or a parenthesised expression is
    -- left out of the measure; a call's is not.
    closer = case e of
      Tuple (_ : _) -> 1
      Paren _ -> 1
      _ -> 0
    unbreakable = case e of
      A _ -> True
      App _ [] -> True
      Method _ [] -> True
      List [] -> True
      Record [] -> True
      _ -> False

-- | An expression on lines of its own, from indentation j.
itemW :: Int -> Int -> F -> Lines
itemW w j x = opening (pad j "") (exprW w j j x)

brokenW :: Int -> Int -> Int -> F -> Lines
brokenW w i c e = case e of
  App f args -> application f args
  -- A method given only a function keeps it on its line, as a callback.
  Method f [Fun ps b] | c + columns (f ++ "(fun " ++ ps ++ " ->") <= w -> closing ")" ((f ++ "(fun " ++ ps ++ " ->") : bodyW (w - 1) (i + 4) b)
  Method f args -> commaList (f ++ "(") ")" args
  List xs -> ["["] ++ concatMap (itemW w (i + 4)) xs ++ [pad i "]"]
  -- A tuple too long for its line has an item on each line, aligned after
  -- its opening parenthesis.
  Tuple xs ->
    let items = [ (if k == 1 then id else opening (pad (c + 1) "")) (exprW w (c + 1) (c + 1) x) | (k, x) <- zip [1 :: Int ..] xs ]
        joined = concat [if k == length items then ls else closing "," ls | (k, ls) <- zip [1 :: Int ..] items]
    in closing ")" (opening "(" joined)
  Record fields -> ["{"] ++ concat [fieldW w (i + 4) n v | (n, v) <- fields] ++ [pad i "}"]
  Fun ps b -> ("fun " ++ ps ++ " ->") : bodyW w (i + 4) b
  Match subject cases -> matchLinesW w i subject cases
  Cond cond a b -> conditionalW w i cond a b
  Block ss r -> case blockW w i ss r of
    first : more -> drop i first : more
    [] -> []
  -- A chain of an operator: its first operand, then each other on a line
  -- of its own, led by the operator.
  Infix o _ _ ->
    let operands = chain o e
    in exprW w i c (head operands) ++ concat [opening (pad i (o ++ " ")) (exprW w i (i + length o + 1) x) | x <- drop 1 operands]
  A s -> [s]
  Paren x -> closing ")" (opening "(" (exprW w i (c + 1) x))
  Prefix o x -> opening o (exprW w i (c + length o) x)
  Annotated x t -> opening "(" (exprW w i (c + 1) x) ++ [pad i (": " ++ t ++ ")")]
  where
    commaList open close args =
      let items = map (itemW w (i + 4)) args
      in [open] ++ concat [if k == length items then ls else closing "," ls | (k, ls) <- zip [1 :: Int ..] items] ++ [pad i close]
    -- f a b: with a function last kept on the first line (a callback), with
    -- one parenthesised argument opened on the first line, or with each
    -- argument on a line of its own.
    application f args
      | not (null args), Fun ps b <- last args, Just fronts <- mapM atom (init args)
      , let open = (if null fronts && methodLike f then f ++ "(fun " ++ ps ++ " ->" else unwords (f : fronts ++ ["(fun " ++ ps ++ " ->"]))
      , c + columns open <= w = closing ")" (open : bodyW (w - 1) (i + 4) b)
      | [a] <- args, needsParens a, not (isLambda a) =
          [f ++ (if methodLike f then "(" else " (")] ++ itemW w (i + 4) (unwrap a) ++ [pad i ")"]
      -- A name too long for its line breaks at a dot: as many of its parts
      -- as fit, then the rest.
      | c + columns f > w, (first : rest@(_ : _)) <- dottedLines w c (i + 4) f =
          [first] ++ rest ++ concatMap (argument (i + 4)) args
      | otherwise = f : concatMap (argument (i + 4)) args
    argument j a
      | needsParens a = closing ")" (opening (pad j "(") (exprW (if isLambda a then w - 1 else w) j (j + 1) (unwrap a)))
      | otherwise = itemW w j a
    isLambda a = case a of Fun _ _ -> True; _ -> False
    unwrap a = a

-- | A long dotted name over lines, as Fantomas lays out a chain of
-- navigation: its first part, then each further part on the current line
-- while it fits, else on a new line at the indentation j, in the fewest
-- lines, with the margin narrowed as far as that number of lines allows so
-- the lines are balanced (Fantomas's balanceNavigationRun).
dottedLines :: Int -> Int -> Int -> String -> [String]
dottedLines maxColumn c j name = case splitParts name of
  receiver : parts@(_ : _) ->
    let segments = map ('.' :) parts
        widths = map columns segments
        start = c + columns receiver
        lineCount ps = 1 + length (filter id ps)
        balance from ws' = let fewest = lineCount (fillWith maxColumn from ws')
                               narrowestMargin = head ([m | m <- [0 .. maxColumn], lineCount (fillWith m from ws') <= fewest] ++ [maxColumn])
                           in fillWith narrowestMargin from ws'
        fillWith margin from ws' = snd (foldl (\(column, acc) wd -> if column + wd <= margin then (column + wd, acc ++ [False]) else (j + wd, acc ++ [True])) (from, []) ws')
        placements = case (balance start widths, widths) of
          (True : _, w1 : later) | start + w1 <= maxColumn -> False : balance (start + w1) later
          (ps, _) -> ps
        go current [] = [current]
        go current ((segment, opens) : rest) = if opens then current : go (pad j segment) rest else go (current ++ segment) rest
    in go receiver (zip segments placements)
  _ -> [name]
  where
    splitParts s = case break (== '.') s of
      (a, '.' : more) -> a : splitParts more
      (a, _) -> [a]

-- | A dotted name split at its last dot.
breakLast :: String -> (String, String)
breakLast name = case break (== '.') (reverse name) of
  (member, '.' : owner) -> (reverse owner, '.' : reverse member)
  _ -> ("", name)

-- | The operands of a chain of one infix operator, left to right.
chain :: String -> F -> [F]
chain o e = case e of
  Infix o' a b | o' == o -> chain o a ++ [b]
  _ -> [e]

-- | A lambda's or a branch's body, as a block at an indentation.
bodyW :: Int -> Int -> F -> Lines
bodyW w j b = case b of
  Block ss r -> blockW w j ss r
  _ -> itemW w j b

-- | A record field: on one line when it fits, else its value under it.
fieldW :: Int -> Int -> String -> F -> Lines
fieldW w j n v = case flat v of
  Just s | j + columns (n ++ " = " ++ s) <= w -> [pad j (n ++ " = " ++ s)]
  _ -> pad j (n ++ " =") : bodyW w (j + 4) v

-- | if/then/else; an else branch that is only a conditional continues as
-- else if. A condition too long for its line goes between if and then.
conditionalW :: Int -> Int -> F -> F -> F -> Lines
conditionalW w i cond a b = conditionalChain True w i cond a b

conditionalChain :: Bool -> Int -> Int -> F -> F -> F -> Lines
conditionalChain compact w i cond a b
  -- An else-if chain whose every clause is short has a line per clause.
  | compact, Just ls <- compactChain = ls
  | otherwise = head' ++ bodyW w (i + 4) a ++ rest
  where
    compactChain = do
      let chain = clauses cond a b
          (conditions, final) = (init chain, snd (last chain))
      guardM (length conditions >= 2)
      texts <- mapM (\(c, x) -> (,) <$> (c >>= flat) <*> flat x) conditions
      finalText <- flat final
      let lines' = [(if k == 0 then "if " else "else if ") ++ x ++ " then " ++ y | (k, (x, y)) <- zip [0 :: Int ..] texts] ++ ["else " ++ finalText]
      guardM (all ((<= 60) . columns) lines' && all (\l -> i + columns l <= w) lines')
      pure (take 1 lines' ++ map (pad i) (drop 1 lines'))
    clauses c yes no = case plain no of
      Cond c2 a2 b2 -> (Just c, yes) : clauses c2 a2 b2
      _ -> [(Just c, yes), (Nothing, no)]
    plain x = case x of Block [] y -> plain y; _ -> x
    guardM ok = if ok then Just () else Nothing
    head' = case flat cond of
      Just s | i + 3 + columns s + 5 <= w -> ["if " ++ s ++ " then"]
      _ -> ["if"] ++ itemW w (i + 4) cond ++ [pad i "then"]
    rest = case plain b of
      Cond c2 a2 b2 -> case conditionalChain False w i c2 a2 b2 of
        first : more -> pad i ("else " ++ first) : more
        [] -> []
      _ -> pad i "else" : bodyW w (i + 4) b

-- | match subject with, then a line for each case: its body on the case's
-- line when it fits, else under it.
matchLinesW :: Int -> Int -> F -> [(String, F)] -> Lines
matchLinesW w i subject cases = header ++ concatMap arm cases
  where
    header = case flat subject of
      Just s | i + columns ("match " ++ s ++ " with") <= w -> ["match " ++ s ++ " with"]
      _ -> ["match"] ++ itemW w (i + 4) subject ++ [pad i "with"]
    arm (pattern, b) = case b of
      Block (_ : _) _ -> patternLines pattern ++ bodyW w (i + 4) b
      _ -> case (flat b, patternLines pattern) of
        (Just s, _) | i + columns ("| " ++ pattern ++ " -> " ++ s) <= w -> [pad i ("| " ++ pattern ++ " -> " ++ s)]
        (Just s, ls@(_ : _ : _)) | columns (last ls) + 1 + columns s <= w -> init ls ++ [last ls ++ " " ++ s]
        (_, ls) -> ls ++ bodyW w (i + 4) b
    -- A case's pattern too long for its line breaks after its constructor's
    -- first argument, the rest aligned after the parenthesis.
    patternLines pattern
      | i + columns ("| " ++ pattern ++ " ->") <= w = [pad i ("| " ++ pattern ++ " ->")]
      | (constructor, '(' : arguments) <- break (== '(') pattern, (first, ',' : ' ' : rest) <- topLevel arguments =
          [pad i ("| " ++ constructor ++ "(" ++ first ++ ","), pad (i + 2 + length constructor + 1) (rest ++ " ->")]
      | otherwise = [pad i ("| " ++ pattern ++ " ->")]
    -- Split at the first comma outside brackets and string literals.
    topLevel = go (0 :: Int) False ""
      where
        go _ _ acc [] = (reverse acc, [])
        go depth quoted acc (c : rest)
          | quoted = go depth (c /= '"' || take 1 acc == "\\") (c : acc) rest
          | c == '"' = go depth True (c : acc) rest
          | c `elem` ("([{" :: String) = go (depth + 1) False (c : acc) rest
          | c `elem` (")]}" :: String) = go (depth - 1) False (c : acc) rest
          | c == ',' && depth == 0 = (reverse acc, c : rest)
          | otherwise = go depth False (c : acc) rest

-- | Statements and a result, at an indentation.
blockW :: Int -> Int -> [Stmt] -> F -> Lines
blockW w i ss r = separated (map statement ss ++ [itemW w i r | r /= A ""])
  where
    statement s = case s of
      DoS e -> itemW w i e
      LetS lhs v -> bindingW w i lhs v
      DefS declaration parameters result b -> functionW w i declaration parameters result b

-- | let x = value, or a property member: on one line while name = value
-- takes up to 80 columns, else the value under it.
bindingW :: Int -> Int -> String -> F -> Lines
bindingW w i lhs v = case flat v of
  Just s | columns (named ++ " = " ++ s) <= 80, i + columns (lhs ++ " = " ++ s) <= w -> [pad i (lhs ++ " = " ++ s)]
  _ -> pad i (lhs ++ " =") : bodyW w (i + 4) v
  where
    -- What the binding declares, after let or member: its modifiers
    -- (mutable, private), name and type count.
    named = case words lhs of
      w : ws | w `elem` ["let", "member", "override", "default"] -> unwords ws
      ws -> unwords ws

-- | A function: its declaration with parameters and result type, then its
-- body, on the declaration's line while it is under 40 columns. A
-- declaration too wide for its line has a parameter on each line.
functionW :: Int -> Int -> String -> [String] -> Maybe String -> F -> Lines
functionW w i declaration parameters result b =
  if i + columns header <= w
    then case flat b of
      Just s | columns s < 40, not (isBlock b), i + columns header + 1 + columns s <= w -> [pad i (header ++ " " ++ s)]
      _ -> pad i header : bodyW w (i + 4) b
    else [pad i declaration] ++ [pad (i + 4) p | p <- parameters] ++ [pad (i + 4) (maybe "=" (\r -> ": " ++ r ++ " =") result)] ++ bodyW w (i + 4) b
  where
    header = unwords (declaration : parameters) ++ maybe "" (" : " ++) result ++ " ="
    isBlock x = case x of Block (_ : _) _ -> True; _ -> False

-- | An expression starting at column c of a line indented i, at the page's
-- width. Inside a parenthesised lambda Fantomas lays code out one column
-- narrower for each such lambda.
expr :: Int -> Int -> F -> Lines
expr = exprW pageWidth

-- | An expression on lines of its own, from indentation j.
item :: Int -> F -> Lines
item = itemW pageWidth

-- | Statements and a result, at an indentation.
block :: Int -> [Stmt] -> F -> Lines
block = blockW pageWidth

binding :: Int -> String -> F -> Lines
binding = bindingW pageWidth

function :: Int -> String -> [String] -> Maybe String -> F -> Lines
function = functionW pageWidth

matchLines :: Int -> F -> [(String, F)] -> Lines
matchLines = matchLinesW pageWidth
