-- | Haskell expressions laid out as ormolu lays them out, so generated
-- Haskell is a fixed point of ormolu (DEC-readable-output-default).
--
-- ormolu has no line width: it keeps a construct on one line when it is on
-- one line, and gives a construct written over several lines its one
-- multi-line layout. Each node here is therefore one Wadler group: flat when
-- it fits 80 columns, otherwise in ormolu's multi-line layout, while its
-- children choose for themselves. A do block or a case is always multi-line,
-- and so is everything around it, except where ormolu lets it hang (after
-- $, <-, = and a lambda's arrow).
--
-- Expressions are printed by precedence: an argument is parenthesised only
-- when it is not an atom, and an operator's operand only when it binds more
-- loosely than application.
module LawSpec.Code.Haskell
  ( Expr(..), Stmt(..)
  , var, string, renderString, integer, call, (<+), lambda, operator, dollar, dollarIn
  , expression, statements, declaration, signature, comment, recordDeclaration
  , layout, camelName, uniqueArguments, uniqueValues
  ) where

import qualified LawSpec.Code.Doc as D
import LawSpec.Code.Literal (literalFor)
import LawSpec.Naming (Casing(..), cased, nameWords)

data Expr
  = Var String  -- a name, a qualified name or an operator section such as (P.==)
  | Lit String  -- an atomic literal: a string, a character or a natural number
  | Negative String  -- a negative number, parenthesised as an argument
  | App Expr [Expr]
  | Op String [Expr]  -- one operator between every two operands
  | Lam [String] Expr
  | Do [Stmt]
  | List [Expr]
  | Tuple [Expr]
  | If Expr Expr Expr
  | Case Expr [(String, Expr)]
  | LetIn [(String, Expr)] Expr  -- let lhs = value ... in body
  | Typed Expr String  -- expression :: type
  | Record String [(String, Expr)]  -- Constructor {field = value, ...}
  | Paren Expr  -- parentheses a reader needs, such as around a section
  deriving (Eq, Show)

data Stmt
  = Bind String Expr  -- pattern <- expression
  | Let String Expr  -- let left-hand side = expression
  | Run Expr
  | Comment [String]
  | Blank
  deriving (Eq, Show)

var :: String -> Expr
var = Var

-- | A string as a Haskell literal (LawSpec.Code.Literal's table).
string :: String -> Expr
string = Lit . renderString

renderString :: String -> String
renderString = literalFor "haskell"

integer :: Integer -> Expr
integer n
  | n < 0 = Negative (show n)
  | otherwise = Lit (show n)

-- | A named function applied to arguments.
call :: String -> [Expr] -> Expr
call name [] = Var name
call name args = App (Var name) args

-- | Application to more arguments.
(<+) :: Expr -> [Expr] -> Expr
App f args <+ more = App f (args ++ more)
f <+ [] = f
f <+ more = App f more

lambda :: [String] -> Expr -> Expr
lambda = Lam

-- | Operands joined by one operator; nested chains of the same operator
-- are joined into one.
operator :: String -> [Expr] -> Expr
operator _ [single] = single
operator name operands = Op name (concatMap flatten operands)
  where
    flatten (Op n xs) | n == name && not (isDollar name) = xs
    flatten x = [x]

-- | f $ x, where x is typically a do block or a lambda that hangs.
dollar :: Expr -> Expr -> Expr
dollar f x = Op "$" [f, x]

-- | As dollar, for a module that imports the Prelude qualified (P.$).
dollarIn :: String -> Expr -> Expr -> Expr
dollarIn qualifier f x = Op (qualifier ++ "$") [f, x]

isDollar :: String -> Bool
isDollar name = name == "$" || name == "P.$"

-- | Whether a node is always laid out over several lines.
multi :: Expr -> Bool
multi e = case e of
  Do _ -> True
  Case _ _ -> True
  App f args -> any multi (f : args)
  Op _ xs -> any multi xs
  Lam _ body -> multi body
  List xs -> any multi xs
  Tuple xs -> any multi xs
  If c a b -> any multi [c, a, b]
  LetIn bindings b -> length bindings > 1 || any (multi . snd) bindings || multi b
  Typed x _ -> multi x
  Record _ fields -> any (multi . snd) fields
  Paren x -> multi x
  _ -> False

-- | Whether a node may hang after $, <-, = or ->: it starts on the same
-- line and continues as a block.
hangs :: Expr -> Bool
hangs e = case e of
  Do _ -> True
  Lam _ body -> hangs body
  Op d [f, x] | isDollar d -> not (multi f) && hangs x
  _ -> False

atomic :: Expr -> Bool
atomic e = case e of
  Var _ -> True
  Lit _ -> True
  List _ -> True
  Tuple _ -> True
  Paren _ -> True
  Record _ _ -> True
  _ -> False

-- | One node: a group unless it must break.
node :: Expr -> D.Doc -> D.Doc
node e d = if multi e then d else D.group d

text :: String -> D.Doc
text = D.text

-- | An expression where any expression may stand: a right-hand side, a
-- statement, a list item.
expression :: Expr -> D.Doc
expression e = if groupable e then node e (bare e) else bare e

-- | The nodes that choose between one line and several as a whole.
groupable :: Expr -> Bool
groupable e = case e of
  App _ _ -> True
  Op d [f, x] | isDollar d -> not (hangs x && not (multi f))
  Op _ _ -> True
  Lam _ body -> not (hangs body)
  If {} -> True
  LetIn {} -> True
  Typed {} -> True
  Record {} -> True
  _ -> False

-- | A node's layout; its softlines are flat when its group fits.
bare :: Expr -> D.Doc
bare e = case e of
  Var s -> text s
  Lit s -> text s
  Negative s -> text s
  Paren x -> parenthesised x
  App f args -> function f <> D.nest 2 (mconcat [D.softline <> argument a | a <- args])
  Op d [f, x] | isDollar d -> if hangs x && not (multi f)
    then flat f <> text (" " ++ d ++ " ") <> hanging x
    else operand f <> text (" " ++ d) <> D.nest 2 (D.softline <> expression x)
  Op name (first : rest) -> operand first <> D.nest 2 (mconcat [D.softline <> text (name ++ " ") <> operand x | x <- rest])
  Op _ [] -> mempty
  Lam params body
    | hangs body -> text (lambdaHead params ++ " ") <> hanging body
    | otherwise -> text (lambdaHead params) <> D.nest 2 (D.softline <> expression body)
  Do stmts -> text "do" <> D.nest 2 (D.hardline <> statements stmts)
  List xs -> bracketed "[" "]" xs
  Tuple xs -> bracketed "(" ")" xs
  If c a b -> text "if " <> expression c <> D.nest 2
    (D.softline <> text "then" <> branch a <> D.softline <> text "else" <> branch b)
  -- let x = v\n in body: the bindings past "let ", the body past " in ".
  LetIn bindings body -> text "let " <> D.nest 4 (D.joinWith D.hardline
    [node value (text (lhs ++ " =") <> D.nest 2 (D.softline <> expression value)) | (lhs, value) <- bindings]) <>
    D.nest 1 (D.softline <> text "in " <> D.nest 3 (expression body))
  -- e :: t, the type below its expression when it breaks, which breaks with
  -- it.
  Typed x t -> annotated x <> text " ::" <> D.nest 2 (D.softline <> text t)
  -- Constructor {f = v}, or the fields one per line in braces below it.
  Record con [] -> text (con ++ " {}")
  Record con fields -> text con <> D.nest 2 (D.softline <> text "{" <> D.whenBroken (text " ") <>
    D.nest 2 (D.joinWith (text "," <> D.softline) [field n v | (n, v) <- fields]) <> D.softbreak <> text "}")
  Case scrutinee alternatives -> text "case " <> expression scrutinee <> text " of" <> D.nest 2
    (mconcat [D.hardline <> alternative p body | (p, body) <- alternatives])
  where
    branch x = if hangs x then text " " <> hanging x else node x (D.nest 2 (D.softline <> expression x))
    alternative p body
      | hangs body = text (p ++ " -> ") <> hanging body
      | otherwise = node body (text (p ++ " ->") <> D.nest 2 (D.softline <> expression body))
    field n v
      | hangs v = text (n ++ " = ") <> hanging v
      | otherwise = node v (text (n ++ " =") <> D.nest 2 (D.softline <> expression v))
    annotated x = case x of
      App _ _ -> bare x
      _ | atomic x -> expression x
        | otherwise -> parenthesised x

-- | A node that hangs: its first line continues the line before it.
hanging :: Expr -> D.Doc
hanging = expression

lambdaHead :: [String] -> String
lambdaHead params = "\\" ++ unwords params ++ " ->"

-- | A function in an application: a name, or a parenthesised expression.
function :: Expr -> D.Doc
function f = if atomic f then expression f else parenthesised f

-- | An argument: an atom as it is, anything else parenthesised.
argument :: Expr -> D.Doc
argument a = if atomic a then expression a else parenthesised a

-- | An operator's operand: application binds more tightly than any
-- operator, so only other operators, lambdas and blocks are parenthesised.
operand :: Expr -> D.Doc
operand x = case x of
  App _ _ -> expression x
  Negative _ -> expression x
  _ | atomic x -> expression x
    | otherwise -> parenthesised x

-- | A left operand of $ before a block that hangs: ormolu keeps it on one
-- line however long, and a chain of $ broken anywhere else is laid out
-- with a $ leading each line, so it is never broken.
flat :: Expr -> D.Doc
flat = text . D.render D.Compact . operand

-- | ( x ) over several lines, or (x).
parenthesised :: Expr -> D.Doc
-- The parentheses and what they hold break together.
parenthesised x = case x of
  Negative n -> text ("(" ++ n ++ ")")
  _ -> node x (text "(" <> D.whenBroken (text " ") <> D.nest 2 (bare x) <> D.softbreak <> text ")")

-- | [a, b] or, over several lines, [ a,\n  b\n].
bracketed :: String -> String -> [Expr] -> D.Doc
bracketed open close [] = text (open ++ close)
bracketed open close xs = node (List xs) (text open <> D.whenBroken (text " ") <>
  D.nest 2 (D.joinWith (text "," <> D.softline) (map expression xs)) <> D.softbreak <> text close)

-- | A do block's statements, one per line.
statements :: [Stmt] -> D.Doc
statements = D.joinWith D.hardline . map statement
  where
    statement s = case s of
      Bind p e
        | hangs e -> text (p ++ " <- ") <> hanging e
        | otherwise -> node e (text (p ++ " <-") <> D.nest 2 (D.softline <> expression e))
      -- let's bindings are indented past "let ": the value continues two
      -- columns further.
      Let lhs e
        | hangs e -> text "let " <> D.nest 4 (text (lhs ++ " = ") <> hanging e)
        | otherwise -> node e (text "let " <> D.nest 4 (text (lhs ++ " =") <> D.nest 2 (D.softline <> expression e)))
      Run e -> expression e
      Comment ls -> D.joinWith D.hardline [text (if null l then "--" else "-- " ++ l) | l <- ls]
      Blank -> mempty

-- | A top-level or where-bound declaration: lhs = expression.
declaration :: String -> Expr -> D.Doc
declaration lhs e
  | hangs e = text (lhs ++ " = ") <> hanging e
  | otherwise = node e (text (lhs ++ " =") <> D.nest 2 (D.softline <> expression e))

-- | name :: a -> b, or over several lines with one type per line.
signature :: String -> [String] -> D.Doc
signature name types = D.group (text (name ++ " ::") <> D.nest 2
  (D.softline <> D.joinWith (text " ->" <> D.softline) (map text types)))

-- | data T = C {field :: type, ...}, the fields one per line in braces when
-- they do not fit on one.
recordDeclaration :: String -> String -> [(String, String)] -> D.Doc
recordDeclaration typeName con [] = text ("data " ++ typeName ++ " = " ++ con)
recordDeclaration typeName con fields = D.group (text ("data " ++ typeName ++ " = " ++ con) <> D.nest 2 (D.softline <> text "{" <>
  D.whenBroken (text " ") <> D.nest 2 (D.joinWith (text "," <> D.softline) [text (n ++ " :: " ++ t) | (n, t) <- fields]) <>
  D.softbreak <> text "}"))

-- | Comment lines.
comment :: [String] -> D.Doc
comment ls = D.joinWith D.hardline [text (if null l then "--" else "-- " ++ l) | l <- ls]

-- | ormolu's conventional width.
layout :: Bool -> D.Layout
layout minify = D.selectLayout minify (D.Pretty 80)

-- | Words as a Haskell value name: shared fakeGateway is sharedFakeGateway.
camelName :: [String] -> String
camelName = cased Camel . concatMap nameWords

-- | The names of a function's values, as an operation's clause takes them.
uniqueValues :: Int -> [String]
uniqueValues 1 = ["value"]
uniqueValues n = ["value" ++ show i | i <- [1 .. n]]

-- | The names a native call binds its checked arguments to.
uniqueArguments :: Int -> [String]
uniqueArguments 1 = ["argument"]
uniqueArguments n = ["argument" ++ show i | i <- [1 .. n]]
