-- | Rust expressions laid out as rustfmt lays them out with its default
-- configuration (style edition 2024). Emitters build the expression's
-- structure; this module chooses where it breaks, with rustfmt's widths:
-- 100 columns, 60 for a call's arguments, an array's items and a method
-- chain on one line, 18 for a struct literal's fields and 50 for a one-line
-- if-else. Nothing here reads generated text back. ref:DEC-readable-output-default
module LawSpec.RustLayout
  ( Expr(..), Stmt(..), Arm(..)
  , expr, stmt, stmts, block, flat, oneLine, function
  , atom, call, method, try', prefix, infixOp, cast, paren, struct, closure, macroCall, vecOf, letIn
  , precedence
  ) where

import Data.List (intercalate)
import Data.Maybe (isJust, isNothing)
import qualified LawSpec.Code.Doc as D

data Expr
  = Atom String
    -- A laid-out document (a string literal, a schema reference): it is
    -- one line when its compact text is.
  | Laid D.Doc
  | Call Expr [Expr]
    -- name!, its delimiters and its arguments: vec![..], format!(..).
  | Macro String String String [Expr]
  | Method Expr String [Expr]
  | Field Expr String
  | Try Expr
  | Prefix String Expr
    -- Precedence (higher binds tighter), operator, operands.
  | Infix Int String Expr Expr
  | Cast Expr String
  | Paren Expr
  | Block [Stmt] (Maybe Expr)
  | If Expr Expr (Maybe Expr)
  | Match Expr [Arm]
    -- The closure's head (|x| or || -> T) and body.
  | Closure String Expr
  | Struct String [(String, Expr)]
  | Return (Maybe Expr)

data Arm = Arm String (Maybe Expr) Expr | ArmOf Expr (Maybe Expr) Expr

-- A let, a binding with its own head (a const), an expression with its semicolon, an expression statement that
-- ends in a block (if, match, for), or a laid-out item.
data Stmt = Let String Expr | Let' String Expr | Semi Expr | Do Expr | Item D.Doc

atom :: String -> Expr
atom = Atom

call :: String -> [Expr] -> Expr
call name = Call (Atom name)

-- | A method call; a receiver that is an operation is parenthesised.
method :: Expr -> String -> [Expr] -> Expr
method r = Method (operand r)

try' :: Expr -> Expr
try' = Try . operand

prefix :: String -> Expr -> Expr
prefix op = Prefix op . operand

cast :: Expr -> String -> Expr
cast e = Cast (case e of
  Infix {} -> Paren e
  Closure {} -> Paren e
  _ -> e)

-- | An expression as a postfix or prefix operator's operand.
operand :: Expr -> Expr
operand e = case e of
  Infix {} -> Paren e
  Cast {} -> Paren e
  Prefix {} -> Paren e
  Closure {} -> Paren e
  Return {} -> Paren e
  _ -> e

paren :: Expr -> Expr
paren = Paren

struct :: String -> [(String, Expr)] -> Expr
struct = Struct

closure :: String -> Expr -> Expr
closure = Closure

macroCall :: String -> [Expr] -> Expr
macroCall name = Macro (name ++ "!") "(" ")"

vecOf :: [Expr] -> Expr
vecOf = Macro "vec!" "[" "]"

letIn :: [Stmt] -> Expr -> Expr
letIn [] e = e
letIn ss e = Block ss (Just e)

-- | Rust's operator precedence, for the operators generated code uses.
precedence :: String -> Int
precedence op = case op of
  "||" -> 3
  "&&" -> 4
  _ | op `elem` ["==", "!=", "<", "<=", ">", ">="] -> 5
  "|" -> 6
  "^" -> 7
  "&" -> 8
  _ | op `elem` ["<<", ">>"] -> 9
  _ | op `elem` ["+", "-"] -> 10
  _ | op `elem` ["*", "/", "%"] -> 11
  _ -> 12

-- | An infixOp expression, parenthesising an operand only where Rust's
-- precedence needs it.
infixOp :: String -> Expr -> Expr -> Expr
infixOp op a b = Infix p op (wrap (p - 1) a) (wrap p b)
  where
    p = precedence op
    -- Comparisons do not chain in Rust, so a comparison's operand that is
    -- itself a comparison keeps its parentheses.
    -- A cast is parenthesised too, as `x as T < y` would read < as the
    -- start of T's arguments.
    wrap limit e = case e of
      Infix q _ _ _ | q <= limit || (q == 5 && p == 5) -> Paren e
      Cast {} -> Paren e
      Closure {} -> Paren e
      _ -> e

-- | One line of text, or nothing when the expression always takes several.
flat :: Expr -> Maybe String
flat e = case e of
  Atom s -> Just s
  Laid d -> let s = D.render D.Compact d in if '\n' `elem` s then Nothing else Just s
  Call f args -> (++) <$> flat f <*> list "(" ")" args
  Macro name open close args -> (name ++) <$> list open close args
  Method r name args -> (\a b -> a ++ "." ++ name ++ b) <$> flat r <*> list "(" ")" args
  Field r name -> (++ ("." ++ name)) <$> flat r
  Try a -> (++ "?") <$> flat a
  Prefix op a -> (op ++) <$> flat a
  Infix _ op a b -> (\x y -> x ++ " " ++ op ++ " " ++ y) <$> flat a <*> flat b
  Cast a t -> (++ (" as " ++ t)) <$> flat a
  Paren a -> (\x -> "(" ++ x ++ ")") <$> flat a
  Block [] (Just a) -> (\x -> "{ " ++ x ++ " }") <$> flat a
  Block [] Nothing -> Just "{}"
  Block _ _ -> Nothing
  If c a (Just b) | simpleBranch a, simpleBranch b ->
    (\x y z -> "if " ++ x ++ " " ++ y ++ " else " ++ z) <$> flat c <*> flat (asBlock a) <*> flat (asBlock b)
  If {} -> Nothing
  Match {} -> Nothing
  Closure h body -> case body of
    Block [] (Just _) -> Nothing
    Block _ _ -> Nothing
    _ -> ((h ++ " ") ++) <$> flat body
  Struct name [] -> Just name
  Struct name fields -> (\fs -> name ++ " { " ++ intercalate ", " fs ++ " }") <$> mapM field fields
  Return Nothing -> Just "return"
  Return (Just a) -> ("return " ++) <$> flat a
  where
    list open close args = (\xs -> open ++ intercalate ", " xs ++ close) <$> mapM flat args
    field (n, v) = case flat v of
      Just x | x == n -> Just n
      Just x -> Just (n ++ ": " ++ x)
      Nothing -> Nothing

-- | The expression on one line, as rustfmt would write it there: within
-- its width limits (a call's arguments, an array's items and a chain 60
-- columns, a struct literal's fields 18, an if-else 50).
oneLine :: Expr -> Maybe String
oneLine e = case e of
  Atom s -> Just s
  Laid _ -> flat e
  Call f args -> (++) <$> oneLine f <*> list 60 "(" ")" args
  Macro name open close args -> (name ++) <$> list 60 open close args
  Method {} -> chained
  Field {} -> chained
  Try a | isChain a -> chained
        | otherwise -> (++ "?") <$> oneLine a
  Prefix op a -> (op ++) <$> oneLine a
  Infix _ op a b -> (\x y -> x ++ " " ++ op ++ " " ++ y) <$> oneLine a <*> oneLine b
  Cast a t -> (++ (" as " ++ t)) <$> oneLine a
  Paren a -> (\x -> "(" ++ x ++ ")") <$> oneLine a
  If {} -> flat e >>= \t -> if width t <= 50 then Just t else Nothing
  Closure h body -> case body of
    Block _ _ -> Nothing
    _ -> ((h ++ " ") ++) <$> oneLine body
  Struct name fields -> case mapM (\(n, v) -> (\x -> if x == n then n else n ++ ": " ++ x) <$> oneLine v) fields of
    Just texts | width (intercalate ", " texts) <= 18 -> if null texts then Just name else Just (name ++ " { " ++ intercalate ", " texts ++ " }")
    _ -> Nothing
  Return Nothing -> Just "return"
  Return (Just a) -> ("return " ++) <$> oneLine a
  _ -> Nothing
  where
    list limit open close args = case mapM oneLine args of
      Just xs | width (intercalate ", " xs) <= limit -> Just (open ++ intercalate ", " xs ++ close)
      _ -> Nothing
    -- Each link on one line, and the whole chain within 60 columns.
    chained = case (flat e, links) of
      (Just t, Just _) | width t <= 60 -> Just t
      _ -> Nothing
    links = let (root, ls') = unchain e in mapM (either oneLine oneLink) root >> mapM oneLink ls'
    oneLink l = case l of
      LinkCall name args tried -> (\xs -> "." ++ name ++ xs ++ (if tried then "?" else "")) <$> list 60 "(" ")" args
      LinkField name tried -> Just ("." ++ name ++ (if tried then "?" else ""))

simpleBranch :: Expr -> Bool
simpleBranch e = case e of
  Block [] (Just a) -> isJust (flat a)
  Block _ _ -> False
  _ -> isJust (flat e)

asBlock :: Expr -> Expr
asBlock e = case e of
  Block _ _ -> e
  _ -> Block [] (Just e)

width :: String -> Int
width = D.displayWidth

-- | Whether rustfmt may keep the last of a call's arguments' opening on the
-- call's line and break inside it (rustfmt's can_be_overflowed_expr): a
-- block or closure always; a call, macro, struct literal, match or if only
-- when it is the only argument.
overflowable :: Int -> Expr -> Bool
overflowable count e = case e of
  Closure {} -> True
  Block _ _ -> True
  Call {} -> count == 1
  Macro {} -> count == 1
  Method {} -> count == 1
  Struct {} -> count == 1
  Match {} -> count == 1
  If {} -> count == 1
  Try a -> overflowable count a
  Prefix _ a -> overflowable count a
  Cast a _ -> overflowable count a
  _ -> False

-- | Whether an expression holds no block: rustfmt's choice of its line
-- can then be made by laying it out both ways.
shallow :: Expr -> Bool
shallow e = case e of
  Atom _ -> True
  Laid _ -> True
  Call f args -> shallow f && all shallow args
  Macro _ _ _ args -> all shallow args
  Method r _ args -> shallow r && all shallow args
  Field r _ -> shallow r
  Try a -> shallow a
  Prefix _ a -> shallow a
  Infix _ _ a b -> shallow a && shallow b
  Cast a _ -> shallow a
  Paren a -> shallow a
  Closure _ body -> case body of
    Block _ _ -> False
    _ -> shallow body
  Struct _ fields -> all (shallow . snd) fields
  Return a -> maybe True shallow a
  _ -> False

-- | Whether rustfmt keeps an arm's body on the arm's line and breaks it
-- there (rustfmt's can_flatten_block_around_this).
extendable :: Expr -> Bool
extendable e = case e of
  If {} -> False
  Match {} -> True
  Block _ _ -> True
  Closure {} -> True
  Call {} -> True
  Method {} -> True
  Macro {} -> True
  Struct {} -> True
  Try a -> extendable a
  Prefix _ a -> extendable a
  Cast a _ -> extendable a
  _ -> False

-- | The text an expression's first line starts with however it breaks.
opening :: Expr -> String
opening e = case e of
  Call f _ -> maybe "" id (flat f) ++ "("
  Macro name open _ _ -> name ++ open
  Closure h (Block _ _) -> h ++ " {"
  Closure h body -> h ++ " " ++ opening body
  Block _ _ -> "{"
  Match s _ -> "match " ++ maybe "" id (flat s) ++ " {"
  If c _ _ -> "if " ++ maybe "" id (flat c) ++ " {"
  Struct name _ -> name ++ " {"
  Try a -> opening a
  Prefix op a -> op ++ opening a
  Method {} -> let (root, _) = unchain e in concat [maybe "" id (either flat flatLink r) | r <- root]
  Field {} -> let (root, _) = unchain e in concat [maybe "" id (either flat flatLink r) | r <- root]
  _ -> maybe "" id (flat e)

-- | An expression's layout.
expr :: Expr -> D.Doc
expr e = case e of
  Atom s -> D.text s
  Laid d -> d
  Call f args -> expr f <> arguments "(" ")" 60 args
  Macro name open close args -> D.text name <> arguments open close 60 args
  Method {} -> chain e
  Field {} -> chain e
  Try a | isChain a -> chain e
        | otherwise -> expr a <> D.text "?"
  Prefix op a -> D.text op <> expr a
  Infix {} -> infixDoc e
  Cast a t -> expr a <> D.text (" as " ++ t)
  Paren a -> D.text "(" <> expr a <> D.text ")"
  Block ss tailExpr -> blockDoc ss tailExpr
  If c a b -> ifDoc c a b
  Match scrutinee arms -> D.text "match " <> expr scrutinee <> D.text " " <> armsDoc arms
  Closure h body -> D.text (h ++ " ") <> expr body
  Struct name [] -> D.text name
  Struct name fields -> structDoc name fields
  Return Nothing -> D.text "return"
  Return (Just a) -> D.text "return " <> expr a

-- | The first layout that fits on its line, else the last.
oneOf :: [D.Doc] -> D.Doc
oneOf = D.bestFit

-- | A call's or macro's arguments: on one line when they fit there and
-- within the width limit; otherwise the last argument overflows (its
-- opening stays on the call's line) when it cannot fit on a line of its
-- own; otherwise one argument per line.
arguments :: String -> String -> Int -> [Expr] -> D.Doc
arguments open close _ [] = D.text (open ++ close)
arguments open close limit args =
  case (mapM oneLine args, overflowLast) of
    (Just texts, _) | width (intercalate ", " texts) <= limit ->
      oneOf ([D.text (open ++ intercalate ", " texts ++ close)] ++ rest)
    _ -> case rest of
      [only] -> only
      _ -> oneOf rest
  where
    vertical = D.text open <> D.nest 4 (D.hardline <> D.joinWith (D.text "," <> D.hardline) (map expr args) <> D.text ",") <>
      D.hardline <> D.text close
    initial = init args
    lastArg = last args
    overflowLast = overflowable (length args) lastArg && all (isJust . oneLine) initial
    overflowed = D.text open <> mconcat [D.text (t ++ ", ") | Just t <- map oneLine initial] <> expr lastArg <> D.text close
    -- rustfmt overflows the last argument whenever the line up to its
    -- opening fits.
    firstLine = open ++ concat [t ++ ", " | Just t <- map oneLine initial] ++ opening lastArg
    rest
      | overflowLast = [D.prefixChoice firstLine overflowed vertical]
      | otherwise = [vertical]

isChain :: Expr -> Bool
isChain e = case e of
  Method {} -> True
  Field {} -> True
  Try a -> isChain a
  _ -> False

-- | A method chain: on one line within 60 columns; otherwise each link on
-- a line of its own, unless its last call cannot fit on a line of its own:
-- then the chain before it stays on one line and that call's arguments
-- break.
chain :: Expr -> D.Doc
chain e = case oneLine e of
  Just t -> oneOf [D.text t, broken]
  _ -> broken
  where
    (root', links') = unchain e
    rootDoc = mconcat (map (either expr linkDoc) root')
    eachLine = rootDoc <> D.nest 4 (mconcat [D.hardline <> linkDoc l | l <- links'])
    prefixText = concat <$> mapM (either oneLine flatLink) (root' ++ map Right (init links'))
    broken = case links' of
      [] -> rootDoc
      _ -> case (prefixText, last links') of
        (Just p, l@(LinkCall _ _ _)) -> case oneLineLink l of
          Just t -> D.fitsIndented 4 (width t) eachLine (oneOf [D.text p <> linkDoc l, eachLine])
          Nothing -> oneOf [D.text p <> linkDoc l, eachLine]
        _ -> eachLine

data Link = LinkCall String [Expr] Bool | LinkField String Bool

unchain :: Expr -> ([Either Expr Link], [Link])
unchain e = go e []
  where
    go x acc = case x of
      Method r name args -> go r (LinkCall name args False : acc)
      Field r name -> go r (LinkField name False : acc)
      Try (Method r name args) -> go r (LinkCall name args True : acc)
      Try (Field r name) -> go r (LinkField name True : acc)
      _ -> ([Left x], acc)

linkDoc :: Link -> D.Doc
linkDoc l = case l of
  LinkCall name args tried -> D.text ("." ++ name) <> arguments "(" ")" 60 args <> (if tried then D.text "?" else mempty)
  LinkField name tried -> D.text ("." ++ name ++ (if tried then "?" else ""))

-- | A link on one line within its call's width limit.
oneLineLink :: Link -> Maybe String
oneLineLink l = case l of
  LinkCall name args tried -> case mapM oneLine args of
    Just xs | width (intercalate ", " xs) <= 60 -> Just ("." ++ name ++ "(" ++ intercalate ", " xs ++ ")" ++ (if tried then "?" else ""))
    _ -> Nothing
  LinkField name tried -> Just ("." ++ name ++ (if tried then "?" else ""))

flatLink :: Link -> Maybe String
flatLink l = case l of
  LinkCall name args tried -> (\xs -> "." ++ name ++ "(" ++ intercalate ", " xs ++ ")" ++ (if tried then "?" else "")) <$> mapM flat args
  LinkField name tried -> Just ("." ++ name ++ (if tried then "?" else ""))

-- | Operands joined by one operator break before each operator, indented.
infixDoc :: Expr -> D.Doc
infixDoc e = case flat e of
  Just t -> oneOf [D.text t, broken]
  Nothing -> broken
  where
    (first, rest) = operands e
    broken = expr first <> D.nest 4 (mconcat [D.hardline <> D.text (op ++ " ") <> expr x | (op, x) <- rest])
    operands x = case x of
      Infix p op a b -> let (f, r) = sameLevel p a in (f, r ++ [(op, b)])
      _ -> (x, [])
    sameLevel p x = case x of
      Infix q op a b | q == p -> let (f, r) = sameLevel p a in (f, r ++ [(op, b)])
      _ -> (x, [])

blockDoc :: [Stmt] -> Maybe Expr -> D.Doc
blockDoc [] Nothing = D.text "{}"
blockDoc ss tailExpr = D.text "{" <> D.nest 4 (D.hardline <> stmts ss tailExpr) <> D.hardline <> D.text "}"

-- | Statements, then the block's value.
stmts :: [Stmt] -> Maybe Expr -> D.Doc
stmts ss tailExpr = D.joinWith D.hardline (map stmt ss ++ maybe [] (pure . expr) tailExpr)

block :: [Stmt] -> Maybe Expr -> D.Doc
block = blockDoc

-- | A statement. A let's value goes on the next line when it fits there
-- on one line and not after the =.
stmt :: Stmt -> D.Doc
stmt s = case s of
  Item d -> d
  Do e -> expr e
  Semi e -> expr e <> D.text ";"
  Let pat e -> stmt (Let' ("let " ++ pat) e)
  Let' binding e ->
    let head' = D.text (binding ++ " =")
        value = expr e <> D.text ";"
        sameValue = D.text " " <> value
        nextValue = D.nest 4 (D.hardline <> value)
    in if shallow e
      then head' <> D.prefer D.NextLineValue sameValue nextValue sameValue nextValue
      else head' <> sameValue

ifDoc :: Expr -> Expr -> Maybe Expr -> D.Doc
ifDoc c a b = case (flat (If c a b), b) of
  (Just t, Just _) | width t <= 50 -> oneOf [D.text t, broken]
  _ -> broken
  where
    broken = D.text "if " <> expr c <> D.text " " <> expr (asBlock a) <> case b of
      Nothing -> mempty
      Just other@(If {}) -> D.text " else " <> expr other
      Just other -> D.text " else " <> expr (asBlock other)

-- | Struct literal fields: on one line within 18 columns, else one a line.
structDoc :: String -> [(String, Expr)] -> D.Doc
structDoc name fields = case mapM fieldText fields of
  Just texts | width (intercalate ", " texts) <= 18 -> oneOf [D.text (name ++ " { " ++ intercalate ", " texts ++ " }"), vertical]
  _ -> vertical
  where
    fieldText (n, v) = case flat v of
      Just x | x == n -> Just n
      Just x -> Just (n ++ ": " ++ x)
      Nothing -> Nothing
    fieldDoc (n, v) = case flat v of
      Just x | x == n -> D.text n
      _ -> D.text (n ++ ": ") <> expr v
    vertical = D.text (name ++ " {") <> D.nest 4 (D.hardline <> D.joinWith (D.text "," <> D.hardline) (map fieldDoc fields) <> D.text ",") <>
      D.hardline <> D.text "}"

-- | A match's arms. An arm's body is on the arm's line when it fits; a
-- block, or a body that fits on a line of its own, is a block; otherwise
-- it breaks after the arrow's line as it overflows.
armsDoc :: [Arm] -> D.Doc
armsDoc arms = D.text "{" <> D.nest 4 (D.hardline <> D.joinWith D.hardline (map armDoc arms)) <> D.hardline <> D.text "}"

armDoc :: Arm -> D.Doc
armDoc (Arm pat guard body) = armDoc (ArmOf (Atom pat) guard body)
armDoc (ArmOf pat guard body) = case unblocked body of
  Block ss tailExpr -> headDoc <> D.text " " <> blockDoc ss tailExpr
  inner ->
    let blocked = headDoc <> D.text " {" <> D.nest 4 (D.hardline <> expr inner) <> D.hardline <> D.text "}"
        sameLine = headDoc <> D.text " " <> expr inner <> (if endsInBlock inner then mempty else D.text ",")
        extend = extendable inner
    in if shallow inner
      then headDoc <> D.prefer (D.ArmBody extend) (D.text " " <> expr inner <> comma inner) (D.nest 4 (D.hardline <> expr inner))
        (D.text " " <> expr inner <> comma inner) (D.text " {" <> D.nest 4 (D.hardline <> expr inner) <> D.hardline <> D.text "}")
      else if extend then sameLine else blocked
  where
    headDoc = expr pat <> maybe mempty (\g -> D.text " if " <> expr g) guard <> D.text " =>"
    -- A block that only holds a value is that value.
    unblocked b = case b of
      Block [] (Just inner) | not (blockLike inner) -> unblocked inner
      _ -> b
    blockLike x = case x of
      Block _ _ -> True
      _ -> False
    comma x = if endsInBlock x then mempty else D.text ","
    endsInBlock x = case x of
      Match {} -> True
      If _ _ _ -> isNothing (flat x)
      _ -> False

-- | A function: its signature on one line when it fits, else one
-- parameter a line; then its body.
function :: String -> [String] -> String -> D.Doc -> D.Doc
function head' parameters result body =
  D.text head' <> D.delimitTrailing 4 "(" ")" (map D.text parameters) <> D.text (result' ++ " ") <> D.block 4 body
  where result' = if null result then "" else " -> " ++ result
