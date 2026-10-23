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
  App f [a] | needsParens a, methodLike f -> (f ++) <$> atom a
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
  Infix o a b -> (\x y -> x ++ " " ++ o ++ " " ++ y) <$> flat a <*> flat b
  Block [] r -> flat r
  Paren x -> (\y -> "(" ++ y ++ ")") <$> flat x
  Prefix o x -> (o ++) <$> atom x
  Annotated x t -> (\y -> "(" ++ y ++ " : " ++ t ++ ")") <$> flat x
  _ -> Nothing
  where within n s = if columns s <= n then Just s else Nothing

-- | An argument on one line, parenthesised when it must be.
atom :: F -> Maybe String
atom a = (\s -> if needsParens a then "(" ++ s ++ ")" else s) <$> flat a

-- | An expression starting at column c of a line indented i: on one line
-- when it fits, else broken as Fantomas breaks it.
expr :: Int -> Int -> F -> Lines
expr i c e = case flat e of
  Just s | c + columns s <= pageWidth || unbreakable -> [s]
  _ -> broken i c e
  where
    unbreakable = case e of
      A _ -> True
      App _ [] -> True
      Method _ [] -> True
      List [] -> True
      Record [] -> True
      _ -> False

-- | An expression on lines of its own, from indentation j.
item :: Int -> F -> Lines
item j x = opening (pad j "") (expr j j x)

broken :: Int -> Int -> F -> Lines
broken i c e = case e of
  App f args -> application f args
  Method f args -> commaList (f ++ "(") ")" args
  List xs -> ["["] ++ concatMap (item (i + 4)) xs ++ [pad i "]"]
  Tuple xs ->
    let items = map (expr (c + 1) (c + 1)) xs
        joined = concat [if k == length items then ls else closing "," ls | (k, ls) <- zip [1 :: Int ..] items]
    in closing ")" (opening "(" (take 1 joined ++ [pad (c + 1) l | l <- drop 1 joined]))
  Record fields -> ["{"] ++ concat [field (i + 4) n v | (n, v) <- fields] ++ [pad i "}"]
  Fun ps b -> ("fun " ++ ps ++ " ->") : body (i + 4) b
  Match subject cases -> matchLines i subject cases
  Cond cond a b -> conditional i cond a b
  Block ss r -> case block i ss r of
    first : more -> drop i first : more
    [] -> []
  -- A chain of an operator: its first operand, then each other on a line
  -- of its own, led by the operator.
  Infix o _ _ ->
    let operands = chain o e
    in expr i c (head operands) ++ concat [opening (pad i (o ++ " ")) (expr i (i + length o + 1) x) | x <- drop 1 operands]
  A s -> [s]
  Paren x -> closing ")" (opening "(" (expr i (c + 1) x))
  Prefix o x -> opening o (expr i (c + length o) x)
  Annotated x t -> opening "(" (expr i (c + 1) x) ++ [pad i (": " ++ t ++ ")")]
  where
    commaList open close args =
      let items = map (item (i + 4)) args
      in [open] ++ concat [if k == length items then ls else closing "," ls | (k, ls) <- zip [1 :: Int ..] items] ++ [pad i close]
    -- f a b: with a function last kept on the first line (a callback), with
    -- one parenthesised argument opened on the first line, or with each
    -- argument on a line of its own.
    application f args
      | not (null args), Fun ps b <- last args, Just fronts <- mapM atom (init args)
      , let open = unwords (f : fronts ++ ["(fun " ++ ps ++ " ->"])
      , c + columns open <= pageWidth = closing ")" (open : body (i + 4) b)
      | [a] <- args, needsParens a, not (isLambda a) =
          [f ++ (if methodLike f then "(" else " (")] ++ item (i + 4) (unwrap a) ++ [pad i ")"]
      | otherwise = f : concatMap (argument (i + 4)) args
    argument j a
      | needsParens a = closing ")" (opening (pad j "(") (expr j (j + 1) (unwrap a)))
      | otherwise = item j a
    isLambda a = case a of Fun _ _ -> True; _ -> False
    unwrap a = a

-- | The operands of a chain of one infix operator, left to right.
chain :: String -> F -> [F]
chain o e = case e of
  Infix o' a b | o' == o -> chain o a ++ [b]
  _ -> [e]

-- | A lambda's or a branch's body, as a block at an indentation.
body :: Int -> F -> Lines
body j b = case b of
  Block ss r -> block j ss r
  _ -> item j b

-- | A record field: on one line when it fits, else its value under it.
field :: Int -> String -> F -> Lines
field j n v = case flat v of
  Just s | j + columns (n ++ " = " ++ s) <= pageWidth -> [pad j (n ++ " = " ++ s)]
  _ -> pad j (n ++ " =") : body (j + 4) v

-- | if/then/else; an else branch that is only a conditional continues as
-- else if. A condition too long for its line goes between if and then.
conditional :: Int -> F -> F -> F -> Lines
conditional i cond a b = head' ++ body (i + 4) a ++ rest
  where
    head' = case flat cond of
      Just s | i + 3 + columns s + 5 <= pageWidth -> ["if " ++ s ++ " then"]
      _ -> ["if"] ++ item (i + 4) cond ++ [pad i "then"]
    rest = case b of
      Cond c2 a2 b2 -> case conditional i c2 a2 b2 of
        first : more -> pad i ("else " ++ first) : more
        [] -> []
      _ -> pad i "else" : body (i + 4) b

-- | match subject with, then a line for each case: its body on the case's
-- line when it fits, else under it.
matchLines :: Int -> F -> [(String, F)] -> Lines
matchLines i subject cases = header ++ concatMap arm cases
  where
    header = case flat subject of
      Just s | i + columns ("match " ++ s ++ " with") <= pageWidth -> ["match " ++ s ++ " with"]
      _ -> ["match"] ++ item (i + 4) subject ++ [pad i "with"]
    arm (pattern, b) = case b of
      Block (_ : _) _ -> pad i ("| " ++ pattern ++ " ->") : body (i + 4) b
      _ -> case flat b of
        Just s | i + columns ("| " ++ pattern ++ " -> " ++ s) <= pageWidth -> [pad i ("| " ++ pattern ++ " -> " ++ s)]
        _ -> pad i ("| " ++ pattern ++ " ->") : body (i + 4) b

-- | Statements and a result, at an indentation.
block :: Int -> [Stmt] -> F -> Lines
block i ss r = separated (map statement ss ++ [item i r | r /= A ""])
  where
    statement s = case s of
      DoS e -> item i e
      LetS lhs v -> binding i lhs v
      DefS declaration parameters result b -> function i declaration parameters result b

-- | let x = value, or a property member: on one line while name = value
-- takes up to 80 columns, else the value under it.
binding :: Int -> String -> F -> Lines
binding i lhs v = case flat v of
  Just s | columns (named ++ " = " ++ s) <= 80, i + columns (lhs ++ " = " ++ s) <= pageWidth -> [pad i (lhs ++ " = " ++ s)]
  _ -> pad i (lhs ++ " =") : body (i + 4) v
  where
    -- What the binding declares, after let or member: its modifiers
    -- (mutable, private), name and type count.
    named = case words lhs of
      w : ws | w `elem` ["let", "member", "override", "default"] -> unwords ws
      ws -> unwords ws

-- | A function: its declaration with parameters and result type, then its
-- body, on the declaration's line while it is under 40 columns. A
-- declaration too wide for its line has a parameter on each line.
function :: Int -> String -> [String] -> Maybe String -> F -> Lines
function i declaration parameters result b =
  if i + columns header <= pageWidth
    then case flat b of
      Just s | columns s < 40, not (isBlock b), i + columns header + 1 + columns s <= pageWidth -> [pad i (header ++ " " ++ s)]
      _ -> pad i header : body (i + 4) b
    else [pad i declaration] ++ [pad (i + 4) p | p <- parameters] ++ [pad (i + 4) (maybe "=" (\r -> ": " ++ r ++ " =") result)] ++ body (i + 4) b
  where
    header = unwords (declaration : parameters) ++ maybe "" (" : " ++) result ++ " ="
    isBlock x = case x of Block (_ : _) _ -> True; _ -> False
