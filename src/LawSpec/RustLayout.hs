-- | Rust expressions laid out as rustfmt lays them out with its default
-- configuration (style edition 2024). Emitters build the expression's
-- structure; this module chooses where it breaks, with rustfmt's widths:
-- 100 columns, 60 for a call's arguments, an array's items and a method
-- chain on one line, 18 for a struct literal's fields and 50 for a one-line
-- if-else. Nothing here reads generated text back. ref:DEC-readable-output-default
module LawSpec.RustLayout
  ( Expr(..), Stmt(..), Arm(..)
  , expr, stmt, stmts, block, flat, oneLine, function, declaration, armDoc
  , atom, call, method, try', prefix, infixOp, cast, paren, struct, closure, macroCall, vecOf, letIn
  , precedence, typeOf, fieldDoc
  ) where

import Data.Char (isAlphaNum)
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
      Just xs | fitsArguments limit open args xs -> Just (open ++ intercalate ", " xs ++ close)
      _ -> Nothing
    -- Each link on one line, and a chain of several links within 60
    -- columns (rustfmt gives a single link the whole line).
    chained = case (flat e, links) of
      (Just t, Just _) | width t <= 60 || linkCount == 1 -> Just t
      _ -> Nothing
    linkCount = length (snd (unchain e))
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
  Laid _ | laidBlock e -> True
  -- A single operation breaks before its operators inside the call.
  Infix {} -> count == 1
  Call {} -> count == 1
  Macro {} -> count == 1
  Method {} -> count == 1
  Struct {} -> count == 1
  -- (rustfmt keeps an overflowing match's or if's head on one line)
  Match scrutinee _ -> count == 1 && isJust (oneLine scrutinee)
  If c _ _ -> count == 1 && isJust (oneLine c)
  Try a -> overflowable count a
  Prefix _ a -> overflowable count a
  Cast a _ -> overflowable count a
  _ -> False

-- | Whether rustfmt lets a closure's body break without a block around it.
multilineBody :: Expr -> Bool
multilineBody e = case e of
  Block _ _ -> True
  Match {} -> True
  Struct {} -> True
  Try a -> multilineBody a
  Prefix _ a -> multilineBody a
  Cast a _ -> multilineBody a
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
  Infix _ _ a _ -> opening a
  -- A call whose last argument is a block or closure overflowing it
  -- keeps its other arguments and that opening on its line.
  Call f args
    | not (null args), blocky (last args), Just inits <- mapM oneLine (init args)
    , let line' = maybe "" id (flat f) ++ "(" ++ concatMap (++ ", ") inits ++ opening (last args), width line' <= 60 -> line'
    | otherwise -> maybe "" id (flat f) ++ "("
  Macro "" "(" _ args
    | not (null args), blocky (last args), Just inits <- mapM oneLine (init args)
    , let line' = concatMap (++ ", ") inits ++ opening (last args), width line' <= 60 -> "(" ++ line'
  Macro name open _ _ -> name ++ open
  Closure h (Block _ _) -> h ++ " {"
  Closure h body
    | not (multilineBody body), isNothing (oneLine body) -> h ++ " {"
    | otherwise -> h ++ " " ++ opening body
  Block _ _ -> "{"
  Laid _ | laidBlock e -> "{"
  Match s _ -> "match " ++ maybe "" id (flat s) ++ " {"
  If c _ _ -> "if " ++ maybe "" id (flat c) ++ " {"
  Struct name _ -> name ++ " {"
  Try a -> opening a
  Cast a _ -> opening a
  Prefix op a -> op ++ opening a
  Method {} -> chainOpening
  Field {} -> chainOpening
  _ -> maybe "" id (flat e)
  where
    chainOpening = case (chainPrefix e, snd (unchain e)) of
      -- (the chain up to its last call stays on one line only within 60
      -- columns; otherwise it breaks after its root)
      (Just p, links@(_ : _)) | LinkCall name _ _ <- last links, width (p ++ "." ++ name ++ "(") <= 60 -> p ++ "." ++ name ++ "("
      -- (a call root that breaks opens the chain's first line)
      _ -> case fst (unchain e) of
        [Left r] | callRoot r, maybe True ((> 60) . width) (oneLine r) -> opening r
        root -> concat [maybe "" id (either flat flatLink r) | r <- root]

-- | A block, or a closure: always overflowable.
blocky :: Expr -> Bool
blocky e = case e of
  Block _ _ -> True
  Laid _ -> laidBlock e
  Closure {} -> True
  _ -> False

-- | An expression's layout.
expr :: Expr -> D.Doc
expr e = case e of
  Atom s -> D.text s
  Laid d -> d
  -- A qualified path whose type is too long for its line breaks inside
  -- the type's brackets (<T as Trait>::f), as rustfmt does.
  Call (Atom path) args
    | '<' : inner <- path, (ty, rest) <- breakAs inner, Just t@(Type _ (_ : _)) <- parseType ty ->
        D.prefixChoice (path ++ "(") (D.text path <> arguments path Nothing "(" ")" 60 args)
          (D.text "<" <> typeBroken t <> D.text rest <> arguments path Nothing "(" ")" 60 args)
    where
      breakAs str = go "" str
      go acc r = case r of
        [] -> (reverse acc, "")
        _ | take 4 r == " as " -> (reverse acc, r)
        c : r' -> go (c : acc) r'
  Call f args -> expr f <> arguments (maybe "    " id (flat f)) Nothing "(" ")" 60 args
  Macro name open close args -> D.text name <> arguments name Nothing open close 60 args
  Method {} -> chain e
  Field {} -> chain e
  Try a | isChain a -> chain e
        | otherwise -> expr a <> D.text "?"
  Prefix op a -> D.text op <> expr a
  Infix {} -> infixDoc e
  -- A cast that does not fit breaks before as.
  -- (A value that breaks keeps its cast on its last line.)
  Cast a t -> case (oneLine e, oneLine a) of
    (Just line', _) -> oneOf [D.text line', expr a <> D.nest 4 (D.hardline <> castType t)]
    (Nothing, Just _) -> expr a <> D.nest 4 (D.hardline <> castType t)
    (Nothing, Nothing) -> expr a <> D.text (" as " ++ t)
  Paren a -> D.text "(" <> expr a <> D.text ")"
  Block ss tailExpr -> blockDoc ss tailExpr
  If c a b -> ifDoc c a b
  -- rustfmt measures a match's head in bytes: a scrutinee with wide
  -- characters that fits by width puts its brace on the next line.
  -- (its brace goes on the next line when a scrutinee on one line leaves
  -- no room for it)
  Match scrutinee arms
    | Just t <- flat scrutinee ->
        oneOf [ D.utf8Text ("match " ++ t ++ " ") <> armsDoc arms
              , D.text ("match " ++ t) <> D.hardline <> armsDoc arms
              , D.text "match " <> expr scrutinee <> D.text " " <> armsDoc arms ]
    | otherwise -> D.text "match " <> expr scrutinee <> D.text " " <> armsDoc arms
  -- A closure's body that is not a block, match or struct literal is on
  -- the closure's line or in a block of its own (rustfmt vetoes breaking
  -- it there).
  Closure h body
    | multilineBody body -> D.text (h ++ " ") <> expr body
    | otherwise -> case oneLine body of
        Just t -> oneOf [D.text (h ++ " " ++ t), D.text (h ++ " ") <> blockDoc [] (Just body)]
        Nothing -> D.text (h ++ " ") <> blockDoc [] (Just body)
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
-- (callee is what the arguments follow: rustfmt lets a broken chain
-- overflow only a callee shorter than an indent, such as Ok)
arguments :: String -> Maybe Int -> String -> String -> Int -> [Expr] -> D.Doc
arguments _ _ open close _ [] = D.text (open ++ close)
arguments callee cap open close limit args =
  case mapM oneLine args of
    Just texts | fitsArguments limit open args texts
               , maybe True (\c -> width (open ++ intercalate ", " texts ++ close) <= c) cap ->
      oneOf ([D.text (open ++ intercalate ", " texts ++ close)] ++ rest)
    -- A call's single argument that is a call it cannot overflow within
    -- its budget is still on the call's line when the whole line fits.
    Just [t] | open == "(", nestedCall (head args), not overflowFits, isNothing cap ->
      oneOf [D.text (open ++ t ++ close), vertical]
    _ -> case rest of
      [only] -> only
      _ -> oneOf rest
  where
    -- Short simple arguments (names and literals of at most 10 columns)
    -- are packed onto the lines, as rustfmt's mixed layout packs them.
    vertical = case mapM oneLine args of
      Just texts | all simple args, all ((<= 10) . width) texts ->
        D.text open <> D.nest 4 (D.hardline <> D.flow [D.text (t ++ ",") | t <- texts]) <> D.hardline <> D.text close
      -- (each argument's lines leave room for its comma)
      _ -> D.text open <> D.nest 4 (D.hardline <> D.joinWith (D.text "," <> D.hardline) (map item args) <> D.text ",") <>
        D.hardline <> D.text close
    initial = init args
    item a = case a of
      If {} -> expr a
      Match {} -> expr a
      Block _ _ -> expr a
      _ -> D.narrow 1 (expr a)
    -- A closure whose body's opening does not fit there overflows with its
    -- body in a block.
    lastArg = case last args of
      Closure h body | not (multilineBody body), not (fitsWith (last args)), fitsWith (Closure h (Block [] (Just body))) ->
        Closure h (Block [] (Just body))
      a -> a
    initialTexts = [t | Just t <- map oneLine initial]
    -- An operation overflows only outside a nested call's budget.
    overflowLast = overflowable (length args) lastArg && all (isJust . oneLine) initial &&
      (isNothing cap || not (isInfix lastArg)) && (width callee < 4 || not (brokenChain lastArg || forcedChain lastArg))
    -- (rustfmt keeps a chain of several links that overflows a longer
    -- callee on one line, so it does not overflow there)
    forcedChain x = case x of
      Try a -> forcedChain a
      Method {} -> length (snd (unchain x)) >= 2
      _ -> False
    brokenChain x = case x of
      Prefix _ a -> brokenChain a
      Try a -> brokenChain a
      Cast a _ -> brokenChain a
      _ -> isChain x && maybe True ((> 60) . width) (flat x) && not (lastCallKept x)
    -- (a chain kept on one line up to its last call, which breaks)
    lastCallKept x = case (chainPrefix x, snd (unchain x)) of
      (Just p, links@(_ : _)) | LinkCall name args _ <- last links -> width (p ++ "." ++ name ++ "(" ++ inner args) <= 60
      _ -> False
    -- (with the opening of a single argument that overflows it)
    inner as = case as of
      [a] | nestedCall a -> opening a
      _ -> ""
    isInfix x = case x of
      Infix {} -> True
      _ -> False
    -- The overflowing argument has what is left of the call's 60 columns,
    -- or, when the call has none, 60 columns of its own if it is a call.
    lastCap = case cap of
      Just c -> Just (c - width (open ++ concatMap (++ ", ") initialTexts))
      Nothing | nestedCall (last args) -> Just 60
              | otherwise -> Nothing
    overflowed = D.text open <> mconcat [D.text (t ++ ", ") | t <- initialTexts] <> overflowing lastCap lastArg <> D.text close
    -- rustfmt overflows the last argument whenever the line up to its
    -- opening fits.
    firstLine = open ++ concatMap (++ ", ") initialTexts ++ opening lastArg
    -- A single chain of one link would overflow onto two lines; rustfmt
    -- puts it on a line of its own instead when it fits there.
    twoLines = case (args, lastArg) of
      ([_], Method {}) -> length (snd (unchain lastArg)) == 1
      ([_], Try a@(Method {})) -> length (snd (unchain a)) == 1
      _ -> False
    -- Within an overflowing argument's budget, the line up to the last
    -- argument's opening must fit the budget too.
    -- With other arguments before it, the line's arguments up to the last
    -- one's opening must be within the width limit too.
    overflowFits = fitsWith lastArg
    fitsWith a = maybe True (\c -> width (open ++ concatMap (++ ", ") initialTexts ++ opening a) <= c) cap &&
      maybe True (\c -> width (opening a) <= c) lastCap &&
      width (concatMap (++ ", ") initialTexts ++ opening a) <= limit
    -- The first line's width counts the call's closing delimiter, and the
    -- enclosing call's when this one overflows in it: rustfmt's shape
    -- leaves room for both.
    reserved = firstLine ++ close ++ (if isJust cap then ")" else "")
    rest
      | overflowLast, overflowFits, twoLines, Just t <- oneLine lastArg = [D.fitsIndented 4 (width t + 1) vertical (D.prefixChoice reserved overflowed vertical)]
      | overflowLast, overflowFits = [D.prefixChoice reserved overflowed vertical]
      | otherwise = [vertical]

-- | Whether arguments go on the call's line: within the width limit, or a
-- call's single argument on the whole line, where an argument that is
-- itself a call or macro still has 60 columns.
fitsArguments :: Int -> String -> [Expr] -> [String] -> Bool
fitsArguments limit open args texts =
  width (intercalate ", " texts) <= limit ||
  -- An array's single literal (a string) stays whole on its line.
  (open == "[" && case args of
    [Atom t] -> take 1 t == "\""
    _ -> False) ||
  (open == "(" && case (args, texts) of
    ([a], [t]) -> not (nestedCall a) || width t <= 60
    _ -> False)

-- | rustfmt's simple expression: a literal or a one-segment name, or a
-- reference, cast, field or call of one.
simple :: Expr -> Bool
simple e = case e of
  Atom t -> not (null t) && (take 1 t == "\"" || "::" `notInfix` t && all (\c -> isAlphaNum c || c `elem` ("_.\"'-" :: String)) t)
  -- (a string literal laid out as one)
  Laid _ -> maybe False ((== "\"") . take 1) (flat e)
  Call f _ -> simple f
  Prefix op a -> op `elem` ["&", "*", "!", "-", "&mut "] && simple a
  Cast a _ -> simple a
  Field a _ -> simple a
  _ -> False
  where notInfix needle hay = not (any (\i -> take (length needle) (drop i hay) == needle) [0 .. length hay])

-- | rustfmt's nested call: a call or macro as an argument, or one behind
-- a reference, ?, a prefix operator or a cast.
nestedCall :: Expr -> Bool
nestedCall e = case e of
  Call {} -> True
  Macro {} -> True
  Try a -> nestedCall a
  Prefix _ a -> nestedCall a
  Cast a _ -> nestedCall a
  _ -> False

-- | A cast's type after its value: a generic type that does not fit
-- breaks inside its angle brackets, as rustfmt breaks it.
castType :: String -> D.Doc
castType t = case parseType t of
  Just ty@(Type _ (_ : _)) -> D.fitsIndented 0 (width ("as " ++ t) + 2) (D.text ("as " ++ t)) (D.text "as " <> typeBroken ty)
  _ -> D.text ("as " ++ t)

-- | A call's overflowing last argument, within the columns left to it: a
-- call or macro there keeps its arguments on its line only when the whole
-- fits.
overflowing :: Maybe Int -> Expr -> D.Doc
overflowing cap e = case e of
  -- Its closing delimiter is counted too.
  Call f args | Just name <- flat f -> D.text name <> arguments name (subtract (width name + 1) <$> cap) "(" ")" 60 args
  Macro name open close args -> D.text name <> arguments name (subtract (width name + 1) <$> cap) open close 60 args
  Prefix op a -> D.text op <> overflowing (subtract (width op) <$> cap) a
  Try a@(Call {}) -> overflowing (subtract 1 <$> cap) a <> D.text "?"
  -- An overflowing cast breaks inside its value, then before as.
  Cast a@(Call {}) t | maybe True (\line' -> maybe False (width line' >) cap) (oneLine e) ->
    overflowing cap a <> D.nest 4 (D.hardline <> castType t)
  -- rustfmt keeps an overflowing chain on one line up to its last call.
  _ | isChain e, Just prefix <- chainPrefix e, (_, links@(_ : _)) <- unchain e, l@(LinkCall name _ _) <- last links
    , width (prefix ++ "." ++ name ++ "(") <= 60 ->
        D.text prefix <> linkDoc l
  _ -> expr e

-- | A chain's text up to its last link, when that is on one line.
chainPrefix :: Expr -> Maybe String
chainPrefix e = let (root, links) = unchain e in case links of
  [] -> Nothing
  _ -> concat <$> mapM (either oneLine flatLink) (root ++ map Right (init links))

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
chain e = let (root, links) = unchain e in chainWith root links e

-- | A chain laid out broken, a link a line (an if's condition that does
-- not fit with its brace).
brokenChain' :: Expr -> D.Doc
brokenChain' e = let (root, links) = unchain e in chainWithOf False root links e

chainWith :: [Either Expr Link] -> [Link] -> Expr -> D.Doc
chainWith = chainWithOf True

chainWithOf :: Bool -> [Either Expr Link] -> [Link] -> Expr -> D.Doc
chainWithOf oneLineAllowed root' links' e = case (if oneLineAllowed then chainOneLine else Nothing) of
  Just t -> oneOf [D.text t, broken]
  _ -> broken
  where
    -- The chain's links after its (possibly extended) root decide its width.
    chainOneLine = case (flat e, mapM (either oneLine oneLineLink) root' >> mapM oneLineLink links') of
      (Just t, Just _) | width t <= 60 || children <= 1 -> Just t
      _ -> Nothing
    -- (each ? is a child of the chain too)
    children = length links' + length [() | LinkCall _ _ True <- links'] + length [() | Left (Try _) <- root'] +
      length [() | Right _ <- root']
    rootDoc = mconcat (map (either expr linkDoc) root')
    -- After a block-like root (if, match, a block), links do not indent.
    -- (so does a root that cannot be on one line: its last line closes it)
    blockRoot = case root' of
      [Left r] -> case r of
        If {} -> True
        Match {} -> True
        Block _ _ -> True
        Laid _ -> isNothing (flat r)
        _ | callRoot r -> isNothing (oneLine r)
        _ -> False
      _ -> False
    linkLines = mconcat [D.hardline <> linkDoc l | l <- links']
    -- A call root that breaks closes on its own line, and the links follow
    -- it unindented.
    eachLine = case root' of
      [Left r] | callRoot r, not blockRoot, Just t <- oneLine r -> oneOf [D.text t <> D.nest 4 linkLines, expr r <> linkLines]
      _ -> rootDoc <> (if blockRoot then id else D.nest 4) linkLines
    prefixText = concat <$> mapM (either oneLine flatLink) (root' ++ map Right (init links'))
    -- rustfmt's choice for the last call (format_last_child): on the
    -- chain's line, or the chain broken a link a line.
    -- (the line up to the last call's opening, with its ?, within 60)
    budget = if length (snd (unchain e)) == 1 then Nothing else Just (60 - tries)
    tries = case last links' of
      LinkCall _ _ True -> 1
      _ -> 0
    broken = case links' of
      [] -> rootDoc
      _ -> case (prefixText, last links') of
        (Just p, l@(LinkCall _ _ _)) ->
          let same = D.text p <> linkDoc l
          in D.prefer (D.ChainLast budget) same (D.nest 4 (D.hardline <> linkDoc l)) same eachLine
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
  LinkCall name args tried -> D.text ("." ++ name) <> arguments ("." ++ name) Nothing "(" ")" 60 args <> (if tried then D.text "?" else mempty)
  LinkField name tried -> D.text ("." ++ name ++ (if tried then "?" else ""))

-- | A link on one line within its call's width limit.
oneLineLink :: Link -> Maybe String
oneLineLink l = case l of
  LinkCall name args tried -> case mapM oneLine args of
    Just xs | width (intercalate ", " xs) <= 60 || length xs == 1 -> Just ("." ++ name ++ "(" ++ intercalate ", " xs ++ ")" ++ (if tried then "?" else ""))
    _ -> Nothing
  LinkField name tried -> Just ("." ++ name ++ (if tried then "?" else ""))

flatLink :: Link -> Maybe String
flatLink l = case l of
  LinkCall name args tried -> (\xs -> "." ++ name ++ "(" ++ intercalate ", " xs ++ ")" ++ (if tried then "?" else "")) <$> mapM flat args
  LinkField name tried -> Just ("." ++ name ++ (if tried then "?" else ""))

-- | Operands joined by one operator break before each operator, indented.
infixDoc :: Expr -> D.Doc
infixDoc e = case (flat e, e) of
  (Just t, _) -> oneOf [D.text t, broken]
  -- An operation whose right operand is a block keeps the block's opening
  -- on the operator's line.
  (Nothing, Infix _ op a b@(Block _ _)) | Just l <- oneLine a -> D.text (l ++ " " ++ op ++ " ") <> expr b
  _ -> broken
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
stmts ss tailExpr = D.joinWith D.hardline (map stmt ss ++ maybe [] (pure . leading) tailExpr)

-- | An expression that starts a line: a chain there keeps a root no wider
-- than an indent with its first link (self.calls.record(..)), as rustfmt does.
leading :: Expr -> D.Doc
leading e
  | isChain e, (Left r@(Atom t) : _, l : _) <- unchain e, width t <= 4, not (null (snd (unchain e))) =
      chainWith [Left r, Right l] (drop 1 (snd (unchain e))) e
  | otherwise = expr e

block :: [Stmt] -> Maybe Expr -> D.Doc
block = blockDoc

-- | A statement. A let's value goes on the next line when it fits there
-- on one line and not after the =.
stmt :: Stmt -> D.Doc
stmt s = case s of
  Item d -> d
  Do e -> expr e
  Semi e | isChain e -> leading e <> D.text ";"
  -- rustfmt keeps a column back after return.
  Semi e@(Return (Just _)) -> D.narrow 1 (expr e <> D.text ";")
  Semi e -> expr e <> D.text ";"
  Let pat e -> stmt (Let' ("let " ++ pat) e)
  -- A binding's type too long for its line breaks inside its outer
  -- angle brackets, and the value follows the closing one.
  Let' binding e
    | (name, ':' : ' ' : ty) <- break (== ':') binding, Just t@(Type _ (_ : _)) <- parseType ty ->
        D.fitsIndented 0 (width (binding ++ " =")) (letDoc binding e)
          (D.text (name ++ ": ") <> typeBroken t <> D.text " = " <> expr e <> D.text ";")
  Let' binding e -> letDoc binding e

-- | A let: its value goes on the next line when it fits there on one line
-- and not after the =.
letDoc :: String -> Expr -> D.Doc
letDoc binding e =
    let head' = D.text (binding ++ " =")
        value = expr e <> D.text ";"
        sameValue = D.text " " <> value
        nextValue = D.nest 4 (D.hardline <> value)
        -- (a match whose scrutinee breaks on the let's line goes to the
        -- next line when its scrutinee is on one line there)
        matched = case e of
          Match {} -> True
          If {} -> True
          _ -> False
    in if shallow e || matched
      then head' <> D.prefer (D.NextLineValue (isChain e) (if triedChain e then 2 else 0)) sameValue nextValue sameValue nextValue
      else head' <> sameValue

ifDoc :: Expr -> Expr -> Maybe Expr -> D.Doc
ifDoc c a b = case (flat (If c a b), b) of
  (Just t, Just _) | width t <= 50 -> oneOf [D.text t, broken]
  _ -> broken
  where
    -- A condition that breaks puts the block's brace on a line of its own.
    -- (A condition whose last line only closes brackets keeps it there.)
    closer = if endsOpen c then D.hardline <> D.text "{" else D.text " {"
    endsOpen x = case x of
      Infix _ _ _ (Block _ _) -> False
      Infix {} -> True
      Method {} -> True
      Field {} -> True
      Try a -> endsOpen a
      Prefix _ a -> endsOpen a
      _ -> False
    opened = case oneLine c of
      -- (a condition that breaks has the line less the brace's room)
      Just t -> oneOf [D.text ("if " ++ t ++ " {"), D.text "if " <> (if isChain c then brokenChain' c else expr c) <> closer]
      Nothing -> D.text "if " <> expr c <> closer
    thenBlock = case asBlock a of
      Block ss t -> D.nest 4 (D.hardline <> stmts ss t) <> D.hardline <> D.text "}"
      _ -> D.text "}"
    broken = opened <> thenBlock <> case b of
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
armsDoc [] = D.text "{}"
armsDoc arms = D.text "{" <> D.nest 4 (D.hardline <> D.joinWith D.hardline (map armDoc arms)) <> D.hardline <> D.text "}"

armDoc :: Arm -> D.Doc
armDoc (Arm pat guard body) = armDoc (ArmOf (Atom pat) guard body)
-- (a block of only its value is that value)
armDoc (ArmOf pat guard (Block [] (Just inner))) = armDoc (ArmOf pat guard inner)
armDoc (ArmOf pat (Just guard) body)
  | Just p <- flat pat, Just g <- oneLine guard, not (isBlock body) =
      D.prefixChoice (p ++ " if " ++ g ++ " => {") (armDoc (ArmOf (Atom (p ++ " if " ++ g)) Nothing body))
            ( D.text p <> D.nest 4 (D.hardline <> D.narrow 5 (D.text "if " <> expr guard) <> D.text " =>") <> D.hardline <> blockDoc [] (Just body) )
  where isBlock b = case b of
          Block _ _ -> True
          _ -> False
armDoc (ArmOf pat (Just guard) body@(Block _ _))
  -- A guarded arm whose head does not fit breaks before its guard, and
  -- its block opens on a line of its own.
  | Just p <- flat pat, Just g <- oneLine guard, Block ss tailExpr <- body =
      oneOf [ D.text (p ++ " if " ++ g ++ " => ") <> blockDoc ss tailExpr
            , D.text p <> D.nest 4 (D.hardline <> D.narrow 5 (D.text "if " <> expr guard) <> D.text " =>") <> D.hardline <> blockDoc ss tailExpr ]
armDoc (ArmOf pat guard body) = case unblocked body of
  -- A block opens on the next line when the arm's line has no room for it.
  Block ss tailExpr -> headDoc <> oneOf [D.text " " <> blockDoc ss tailExpr, D.hardline <> blockDoc ss tailExpr]
  inner ->
    let blocked = headDoc <> D.text " {" <> D.nest 4 (D.hardline <> expr inner) <> D.hardline <> D.text "}"
        sameLine = headDoc <> D.text " " <> expr inner <> (if endsInBlock inner then mempty else D.text ",")
        extend = extendable inner
    in if shallow inner
      then headDoc <> D.prefer (D.ArmBody extend) (D.text " " <> expr inner <> comma inner) (D.nest 4 (D.hardline <> expr inner))
        (D.text " " <> expr inner <> comma inner) (D.text " {" <> D.nest 4 (D.hardline <> expr inner) <> D.hardline <> D.text "}")
      else if extend then sameLine else blocked
  where
    headDoc = expr pat <> maybe mempty (\g -> D.text " if " <> maybe (expr g) D.text (oneLine g)) guard <> D.text " =>"
    -- A block that only holds a value is that value.
    unblocked b = case b of
      Block [] (Just inner) -> unblocked inner
      _ -> b
    comma x = if endsInBlock x then mempty else D.text ","
    endsInBlock x = case x of
      Match {} -> True
      If _ _ _ -> isNothing (flat x)
      _ -> False

-- | A function: its signature on one line when it fits, else one
-- parameter a line; then its body.
function :: String -> [String] -> String -> D.Doc -> D.Doc
function head' parameters result body = signatureDoc head' parameters result " {" <>
  D.nest 4 (D.hardline <> body) <> D.hardline <> D.text "}"

-- | A function's declaration without a body (a trait's method).
declaration :: String -> [String] -> String -> D.Doc
declaration head' parameters result = signatureDoc head' parameters result ";"

signatureDoc :: String -> [String] -> String -> String -> D.Doc
signatureDoc head' parameters result end = oneOf [D.text (head' ++ "(" ++ intercalate ", " parameters ++ ")" ++ result' ++ end), broken]
  where
    result' = if null result then "" else " -> " ++ result
    params = D.nest 4 (mconcat [D.hardline <> parameterDoc p <> D.text "," | p <- parameters])
    -- rustfmt puts the brace on a line of its own when the closing line,
    -- with the indentation counted twice, leaves no room for it.
    broken
      | null parameters = D.text (head' ++ "()" ++ result' ++ end)
      | otherwise = D.text (head' ++ "(") <> params <> D.hardline <>
          if end /= " {" then D.text (")" ++ result' ++ end) else
          D.fitsIndentedTwice (width (")" ++ result') + 2) (D.text (")" ++ result' ++ " {"))
            (D.fitsIndented 0 (width (")" ++ result')) (D.text (")" ++ result') <> D.hardline <> D.text "{") genericResult)
    -- A result type too long for its line breaks inside its outer brackets.
    genericResult = case parseType result of
      Just t@(Type _ (_ : _)) -> D.text ") -> " <> typeBroken t <> D.text " {"
      _ -> D.text (")" ++ result') <> D.hardline <> D.text "{"

-- | A parameter, name: type, its type breaking as rustfmt breaks it.
parameterDoc :: String -> D.Doc
parameterDoc p = case break (== ':') p of
  (name, ':' : ' ' : ty) | Just t <- parseType ty -> D.text (name ++ ": ") <> typeDoc t
  _ -> D.text p

-- | A Rust type: a path with its generic arguments, or a tuple.
data Type = Type String [Type] | Tuple [Type]

-- | A type written as text, when it is a path with generic arguments or a
-- tuple of such (a function type stays text).
parseType :: String -> Maybe Type
parseType text' = case go text' of
  Just (t, "") -> Just t
  _ -> Nothing
  where
    go str = case str of
      '(' : rest -> (\(ts, r) -> (Tuple ts, r)) <$> items ')' rest
      _ -> let (h, rest) = span (`notElem` ("<>,()" :: String)) str in
        if null h then Nothing else case rest of
          '<' : r -> (\(ts, r') -> (Type h ts, r')) <$> items '>' r
          _ -> Just (Type h [], rest)
    items close str = case str of
      c : r | c == close -> Just ([], r)
      _ -> do
        (t, r) <- go str
        case r of
          ',' : c : r' | c == close -> Just ([t], r')
          ',' : ' ' : r' -> (\(ts, r'') -> (t : ts, r'')) <$> items close r'
          c : r' | c == close -> Just ([t], r')
          _ -> Nothing

typeText :: Type -> String
typeText t = case t of
  Type h [] -> h
  Type h ts -> h ++ "<" ++ intercalate ", " (map typeText ts) ++ ">"
  Tuple [x] -> "(" ++ typeText x ++ ",)"
  Tuple ts -> "(" ++ intercalate ", " (map typeText ts) ++ ")"

-- | A type on one line when it fits, else broken inside its brackets, one
-- argument a line.
typeDoc :: Type -> D.Doc
typeDoc t = case t of
  Type _ [] -> D.text (typeText t)
  Tuple [] -> D.text "()"
  _ -> oneOf [D.text (typeText t), typeBroken t]

typeBroken :: Type -> D.Doc
typeBroken t = case t of
  Type h ts@(_ : _) -> D.text (h ++ "<") <> inside ts <> D.text ">"
  Tuple ts@(_ : _) -> D.text "(" <> inside ts <> D.text ")"
  _ -> D.text (typeText t)
  where inside ts = D.nest 4 (mconcat [D.hardline <> typeDoc x <> D.text "," | x <- ts]) <> D.hardline

-- | A type, from its text, laid out as rustfmt lays it out.
typeOf :: String -> D.Doc
typeOf ty = maybe (D.text ty) typeDoc (parseType ty)

-- | A struct's field, name: type: its type on the next line when the
-- line has no room for it there, else broken.
fieldDoc :: String -> String -> D.Doc
fieldDoc name ty = oneOf
  [ D.text (name ++ ": " ++ ty)
  , D.fitsIndented 4 (width ty + 1) (D.text (name ++ ":") <> D.nest 4 (D.hardline <> D.text ty)) (D.text (name ++ ": ") <> typeOf ty) ]

-- | A chain whose last link is tried (ends in ?): as a let's value on the
-- let's line, rustfmt keeps two columns back for it.
triedChain :: Expr -> Bool
triedChain e = case e of
  Try a -> isChain a
  _ -> False

-- | A chain's root that is a call (or a tried one): broken, it closes on a
-- line of its own.
callRoot :: Expr -> Bool
callRoot e = case e of
  Call {} -> True
  Paren a -> callRoot a
  Try a -> callRoot a
  _ -> False

-- | A laid-out block (a value built in statements): as overflowable as a
-- block.
laidBlock :: Expr -> Bool
laidBlock e = case e of
  Laid d -> let t = D.render D.Compact d in take 1 t == "{" && '\n' `elem` D.render (D.styleLayout (D.styleFor "rust")) d
  _ -> False
