-- | The code the Swift emitters share: expressions over the LawSpec runtime,
-- printed as Swift statements. Anything that needs a block (a conditional,
-- a closure, a local binding) is first bound to a fresh constant, so
-- arguments keep their left-to-right order; a throwing call is marked with
-- try, a binding nothing reads is dropped or discarded, and no name is bound
-- twice in one body, so the output compiles without warnings.
-- ref:DEC-swift-runtime-from-scratch ref:DEC-readable-output-default
module LawSpec.Swift.Code
  ( Ty(..), Expr(..)
  , tValue, tValues, tBool, tVoid, tString, tSchema, tSymbols, tInt, tFun, tArray, tOptional, tGen, tType
  , call, pure', str, renderBody, renderStatements, renderExpr, stringLiteral, isInline, throws
  , indentation, swiftLayout, hangValue, intLiteral, closure, brokenList, callDoc, argumentsDoc, arrayDoc, signature, typeDeclaration, fileHeader, blockDoc, comment
  ) where

import qualified LawSpec.Code.Doc as D
import Control.Monad.State.Strict (State, evalState, get, put)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Char (isAscii)
import Data.List (intercalate, sort)
import LawSpec.Code.Literal (literalFor)

-- | A Swift type, as written.
newtype Ty = Ty String deriving (Eq, Show)

data Expr
  = Var String
  | Str String
  | IntLit Integer
  -- | A BigInt literal.
  | BigLit Integer
  | BoolLit Bool
  -- | Swift text that neither throws nor needs a block.
  | Raw String
  -- | A call that may throw: f(a, b).
  | Call String [Expr]
  -- | A call or constructor that never throws: Value.text(a).
  | Pure String [Expr]
  -- | A closure applied to arguments; it may throw.
  | Invoke Expr [Expr]
  | ListOf Ty [Expr]
  | TupleOf [Expr]
  | Lambda [(String, Ty)] Ty Expr
  | Let String Ty Expr Expr
  -- | A Swift Bool condition, the type of the result and its two branches.
  | If Expr Ty Expr Expr
  -- | Effects, then a value.
  | Do [Expr] Expr
  -- | A call whose result is Void, as a statement of its own.
  | Statement Expr
  deriving (Eq, Show)

tValue, tValues, tBool, tVoid, tString, tSchema, tSymbols, tInt, tGen, tType :: Ty
tValue = Ty "Value"
tValues = Ty "[Value]"
tBool = Ty "Bool"
tVoid = Ty "Void"
tString = Ty "String"
tSchema = Ty "Schema"
tSymbols = Ty "SymbolContext"
tInt = Ty "Int"
tGen = Ty "Gen<Value>"
tType = Ty "TypeRef"

tFun :: [Ty] -> Ty -> Ty
tFun args (Ty r) = Ty ("(" ++ intercalate ", " [a | Ty a <- args] ++ ") throws -> " ++ r)

tArray :: Ty -> Ty
tArray (Ty t) = Ty ("[" ++ t ++ "]")

tOptional :: Ty -> Ty
tOptional (Ty t) = Ty (if ' ' `elem` t then "(" ++ t ++ ")?" else t ++ "?")

call :: String -> String -> [Expr] -> Expr
call owner name = Call (owner ++ "." ++ name)

pure' :: String -> String -> [Expr] -> Expr
pure' owner name = Pure (owner ++ "." ++ name)

str :: String -> Expr
str = Str

-- | Whether an expression prints on one line, with no statement in it.
isInline :: Expr -> Bool
isInline e = case e of
  Lambda {} -> False
  Let {} -> False
  If {} -> False
  Do {} -> False
  Call _ args -> all isInline args
  Pure _ args -> all isInline args
  Invoke f args -> all isInline (f : args)
  ListOf _ xs -> all isInline xs
  TupleOf xs -> all isInline xs
  _ -> True

-- | Whether evaluating an inline expression may throw (closures aside).
throws :: Expr -> Bool
throws e = case e of
  Call _ _ -> True
  Invoke _ _ -> True
  Pure _ args -> any throws args
  ListOf _ xs -> any throws xs
  TupleOf xs -> any throws xs
  Lambda {} -> False
  Let _ _ v b -> throws v || throws b
  If c _ a b -> throws c || throws a || throws b
  Do xs v -> any throws xs || throws v
  Statement x -> throws x
  _ -> False

-- | Whether a call returns Void, so its result needs no discarding.
returnsVoid :: Expr -> Bool
returnsVoid e = case e of
  Statement _ -> True
  Call f _ -> f `elem` voidFunctions
  Pure f _ -> f `elem` voidFunctions
  _ -> False

-- | The runtime functions that return nothing.
voidFunctions :: [String]
voidFunctions =
  [ "Runtime.require", "Runtime.ignore", "Harness.skip", "Harness.benchmark", "Harness.run", "Harness.knownFailing"
  , "Harness.recordParallel", "Search.replay", "Search.climb", "Property.boundaries", "Property.check", "Effects.setHandlerState" ]

-- | Whether an expression mentions a name.
mentions :: String -> Expr -> Bool
mentions n e = case e of
  Var v -> v == n
  Raw r -> n `elem` tokens r
  Call _ args -> any (mentions n) args
  Pure _ args -> any (mentions n) args
  Invoke f args -> any (mentions n) (f : args)
  ListOf _ xs -> any (mentions n) xs
  TupleOf xs -> any (mentions n) xs
  Lambda ps _ b -> n `notElem` map fst ps && mentions n b
  Let x _ v b -> mentions n v || (x /= n && mentions n b)
  If c _ a b -> any (mentions n) [c, a, b]
  Do xs v -> any (mentions n) (v : xs)
  Statement x -> mentions n x
  _ -> False
  where
    tokens s = words (map (\c -> if isIdent c then c else ' ') s)
    isIdent c = isAscii c && (c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || c `elem` ['0' .. '9'] || c == '_')

-- | A statement: a binding (of anything, block or not) or an effect.
data Stmt = Bind String Ty Expr | Effect Expr

-- | The names a body already uses, so a made name is new.
type Fresh = State (S.Set String)

-- | A name for a value the code makes, by what it holds: chosen (a
-- conditional's value), argument (an argument computed before a block).
fresh :: String -> Fresh String
fresh prefix = do
  used <- get
  let name = case [c | c <- prefix : [prefix ++ show k | k <- [2 :: Int ..]], not (S.member c used)] of
        c : _ -> c
        [] -> prefix
  put (S.insert name used)
  pure name

-- | Every name an expression binds or mentions.
namesIn :: Expr -> S.Set String
namesIn e = case e of
  Var v -> S.singleton v
  Raw r -> S.fromList (words (map (\c -> if isIdent c then c else ' ') r))
  Call f args -> S.insert (takeWhile (/= '.') f) (S.unions (map namesIn args))
  Pure f args -> S.insert (takeWhile (/= '.') f) (S.unions (map namesIn args))
  Invoke f args -> S.unions (map namesIn (f : args))
  ListOf _ xs -> S.unions (map namesIn xs)
  TupleOf xs -> S.unions (map namesIn xs)
  Lambda ps _ b -> S.union (S.fromList (map fst ps)) (namesIn b)
  Let n _ v b -> S.insert n (S.union (namesIn v) (namesIn b))
  If c _ a b -> S.unions (map namesIn [c, a, b])
  Do xs v -> S.unions (map namesIn (v : xs))
  Statement x -> namesIn x
  _ -> S.empty
  where isIdent c = isAscii c && (c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || c `elem` ['0' .. '9'] || c == '_')

-- | A call on a long made receiver (a codec of codecs) names the receiver
-- first, so the call's line can break inside its arguments.
nameReceivers :: Expr -> Expr
nameReceivers e = case e of
  Call f args | Just (receiver, method) <- longReceiver f ->
    Let "codec" (Ty "") (Raw receiver) (Call ("codec." ++ method) (map nameReceivers args))
  Pure f args | Just (receiver, method) <- longReceiver f ->
    Let "codec" (Ty "") (Raw receiver) (Pure ("codec." ++ method) (map nameReceivers args))
  Call f args -> Call f (map nameReceivers args)
  Pure f args -> Pure f (map nameReceivers args)
  Invoke f args -> Invoke (nameReceivers f) (map nameReceivers args)
  ListOf t xs -> ListOf t (map nameReceivers xs)
  TupleOf xs -> TupleOf (map nameReceivers xs)
  Lambda ps r b -> Lambda ps r (nameReceivers b)
  Let n t v b -> Let n t (nameReceivers v) (nameReceivers b)
  If c t a b -> If (nameReceivers c) t (nameReceivers a) (nameReceivers b)
  Do xs v -> Do (map nameReceivers xs) (nameReceivers v)
  Statement x -> Statement (nameReceivers x)
  _ -> e
  where
    longReceiver f = case break (== '.') (reverse f) of
      (method, '.' : receiver) | ')' `elem` receiver, length receiver > 40, '(' `notElem` method ->
        Just (reverse receiver, reverse method)
      _ -> Nothing

-- | Statements that compute an expression, and the inline expression left.
-- Block constructs in argument position are bound first; when one argument
-- is, the arguments before it are too, so effects keep their order.
flatten :: Ty -> Expr -> Fresh ([Stmt], Expr)
flatten ty e = case e of
  Let name t value inner -> do
    s1 <- bindTo name t value
    (s2, rest) <- flatten ty inner
    pure (s1 ++ s2, rest)
  Do effects value -> do
    ss <- mapM effect effects
    (s2, rest) <- flatten ty value
    pure (concat ss ++ s2, rest)
  Call f args -> do
    (ss, args') <- arguments args
    pure (ss, Call f args')
  Pure f args -> do
    (ss, args') <- arguments args
    pure (ss, Pure f args')
  Invoke f args -> do
    (ss, all') <- arguments (f : args)
    case all' of
      f' : args' -> pure (ss, Invoke f' args')
      [] -> pure (ss, e)
  ListOf t xs -> do
    (ss, xs') <- arguments xs
    pure (ss, ListOf t xs')
  TupleOf xs -> do
    (ss, xs') <- arguments xs
    pure (ss, TupleOf xs')
  Statement x -> do
    (ss, x') <- flatten ty x
    pure (ss, Statement x')
  If {} -> hoisted
  _ -> pure ([], e)
  where
    hoisted = do
      name <- fresh "chosen"
      let t = case e of If _ ct _ _ -> ct; _ -> ty
      pure ([Bind name t e], Var name)
    effect x = do
      (ss, x') <- flatten tVoid x
      pure (ss ++ [Effect x'])

arguments :: [Expr] -> Fresh ([Stmt], [Expr])
arguments args
  | all isInline' args = pure ([], args)
  | otherwise = do
      results <- mapM one args
      pure (concatMap fst results, map snd results)
  where
    -- A closure stays where it is written: Swift closures are expressions.
    isInline' a = case a of
      Lambda {} -> True
      _ -> isInline a
    one a | simple a = pure ([], a)
    one a = do
      (ss, a') <- flatten tValue a
      if isInline a && not (simple a') then do
        name <- fresh "argument"
        pure (ss ++ [Bind name (Ty "") a'], Var name)
      else pure (ss, a')
    simple a = case a of
      Var _ -> True
      Str _ -> True
      IntLit _ -> True
      BigLit _ -> True
      BoolLit _ -> True
      Raw _ -> True
      Lambda {} -> True
      _ -> False

-- | Bind an expression to a name: blocks stay blocks, inline parts are hoisted.
bindTo :: String -> Ty -> Expr -> Fresh [Stmt]
bindTo name t value = case value of
  Lambda {} -> pure [Bind name t value]
  If {} -> pure [Bind name t value]
  _ -> do
    (ss, v) <- flatten t value
    pure (ss ++ [Bind name t v])

-- | A function body: its statements and its result.
renderBody :: Ty -> Expr -> D.Doc
renderBody ty e = let e' = distinct (nameReceivers e) in evalState (body ty Return e') (namesIn e')

-- | A body run for its effects (a Void function).
renderStatements :: Expr -> D.Doc
renderStatements e = let e' = distinct (nameReceivers e) in evalState (body tVoid Discard e') (namesIn e')

-- | An expression that is already inline.
renderExpr :: Expr -> D.Doc
renderExpr e = let e' = distinct e in evalState (inline e') (namesIn e')

-- | Swift refuses a constant another in the same body already names, so each
-- binder that reuses a name bound earlier is renamed (the first keeps its
-- name, which raw text may mention).
distinct :: Expr -> Expr
distinct e = evalState (go M.empty e) S.empty
  where
    go :: M.Map String String -> Expr -> State (S.Set String) Expr
    go env x = case x of
      Var v -> pure (Var (M.findWithDefault v v env))
      Call f args -> Call f <$> mapM (go env) args
      Pure f args -> Pure f <$> mapM (go env) args
      Invoke f args -> Invoke <$> go env f <*> mapM (go env) args
      ListOf t xs -> ListOf t <$> mapM (go env) xs
      TupleOf xs -> TupleOf <$> mapM (go env) xs
      Lambda ps r b -> do
        names <- mapM (binder . fst) ps
        b' <- go (foldr (uncurry M.insert) env (zip (map fst ps) names)) b
        pure (Lambda (zip names (map snd ps)) r b')
      Let n t v b -> do
        v' <- go env v
        n' <- binder n
        b' <- go (M.insert n n' env) b
        pure (Let n' t v' b')
      If c t a b -> If <$> go env c <*> pure t <*> go env a <*> go env b
      Do xs v -> Do <$> mapM (go env) xs <*> go env v
      Statement s -> Statement <$> go env s
      _ -> pure x
    -- A keyword's escaped name keeps its backticks around the suffix.
    suffixed ('`' : rest) k = '`' : takeWhile (/= '`') rest ++ "_" ++ show k ++ "`"
    suffixed n k = n ++ "_" ++ show k
    binder :: String -> State (S.Set String) String
    binder n = do
      used <- get
      let n' = case [c | c <- n : [suffixed n k | k <- [2 :: Int ..]], not (S.member c used)] of { c : _ -> c; [] -> n }
      put (S.insert n' used)
      pure n'

-- | Where a block's result goes: returned, assigned to a constant, or
-- dropped (a Void body).
data Sink = Return | Assign String | Discard

tried :: Expr -> D.Doc -> D.Doc
tried e d = if throws e then D.text "try " <> d else d

body :: Ty -> Sink -> Expr -> Fresh D.Doc
body ty sink e = do
  (ss, result) <- flatten ty e
  docs <- statements ss result
  final <- case result of
    If c t a b -> conditional t sink c a b
    _ | ty == tVoid -> case sink of
          Return -> effectLine result
          Discard -> effectLine result
          Assign name -> (\d -> hangValue (name ++ " =") (tried result d)) <$> inline result
    _ -> finish sink result <$> inline result
  pure (D.joinWith D.hardline (docs ++ [final | final /= mempty]))
  where
    effectLine r
      | inert r = pure mempty
      | returnsVoid r = tried r <$> inline r
      | otherwise = (\d -> hangValue "_ =" (tried r d)) <$> inline r

-- | Statements in order; a binding nothing after it reads is dropped, or
-- discarded when it has effects.
statements :: [Stmt] -> Expr -> Fresh [D.Doc]
statements [] _ = pure []
statements (s : rest) result = do
  let later n = any (stmtMentions n) rest || mentions n result
  d <- case s of
    Bind name t v | not (later name) -> statement (Effect' t v)
    Bind name t v -> statement (Bound name t v)
    Effect v -> statement (Effect' tVoid v)
  more <- statements rest result
  pure (d ++ more)
  where
    stmtMentions n st = case st of
      Bind _ _ v -> mentions n v
      Effect v -> mentions n v

data Statement = Bound String Ty Expr | Effect' Ty Expr

statement :: Statement -> Fresh [D.Doc]
statement s = case s of
  Effect' t (If c rt a b) -> do
    d <- conditional rt Discard c a b
    pure [d | t == t || True]
  Effect' _ (Lambda {}) -> pure []
  Effect' _ v
    | inert v -> pure []
    | returnsVoid v -> do
        d <- inline v
        pure [tried v d]
    | otherwise -> do
        d <- inline v
        pure [hangValue "_ =" (tried v d)]
  Bound name t (If c rt a b) -> do
    d <- conditional rt (Assign name) c a b
    pure [D.text ("let " ++ name ++ ": " ++ tyText (if t == Ty "" then rt else t)) <> D.hardline <> d]
  Bound name t (Lambda ps r b) -> do
    l <- lambda ps r b
    pure [hangValue ("let " ++ name ++ annotation t ++ " =") l]
  Bound name t v -> do
    d <- inline v
    pure [hangValue ("let " ++ name ++ annotation t ++ " =") (tried v d)]
  where tyText (Ty x) = x
        annotation (Ty "") = ""
        annotation t = ": " ++ tyText t

-- | A value with no effect: a name, a literal, raw text, a portable value
-- made of them.
inert :: Expr -> Bool
inert v = case v of
  Pure f args | take 6 f == "Value." -> all inert args
  Var _ -> True
  Raw _ -> True
  Str _ -> True
  IntLit _ -> True
  BigLit _ -> True
  BoolLit _ -> True
  _ -> False

finish :: Sink -> Expr -> D.Doc -> D.Doc
finish Return e d = hangValue "return" (tried e d)
finish (Assign name) e d = hangValue (name ++ " =") (tried e d)
finish Discard e d
  | inert e = mempty
  | returnsVoid e = tried e d
  | otherwise = hangValue "_ =" (tried e d)

conditional :: Ty -> Sink -> Expr -> Expr -> Expr -> Fresh D.Doc
conditional ty sink c a b = do
  (cs, c') <- flatten tBool c
  pre <- statements cs c'
  cd <- inline c'
  ad <- body ty sink a
  bd <- body ty sink b
  let doc = D.text "if " <> tried c' cd <> D.text " {" <> D.nest indentation (D.hardline <> ad) <>
        D.hardline <> D.text "} else {" <> D.nest indentation (D.hardline <> bd) <> D.hardline <> D.text "}"
  pure (D.joinWith D.hardline (pre ++ [doc]))

lambda :: [(String, Ty)] -> Ty -> Expr -> Fresh D.Doc
lambda ps r b = do
  inner <- body r Return b
  pure (closure ps r inner)

-- | A closure: its signature, then its body on lines of its own.
closure :: [(String, Ty)] -> Ty -> D.Doc -> D.Doc
closure ps (Ty rt) inner =
  D.text ("{ (" ++ intercalate ", " [p ++ ": " ++ t | (p, Ty t) <- ps] ++ ") throws -> " ++ rt ++ " in") <>
  D.nest indentation (D.hardline <> inner) <> D.hardline <> D.text "}"

inline :: Expr -> Fresh D.Doc
inline e = case e of
  Var v -> pure (D.text v)
  Str s -> pure (D.text (stringLiteral s))
  IntLit n -> pure (D.text (intLiteral n))
  BigLit n -> pure (D.text (bigLiteral n))
  BoolLit b -> pure (D.text (if b then "true" else "false"))
  Raw r -> pure (D.text r)
  Call f args -> applied (D.text f) args
  Pure f args -> applied (D.text f) args
  Invoke f args -> do
    fd <- inline f
    applied fd args
  ListOf _ xs -> do
    ds <- mapM inline xs
    pure (arrayDoc ds)
  TupleOf xs -> do
    ds <- mapM inline xs
    pure (argumentsDoc ds)
  Lambda ps r b -> lambda ps r b
  Statement x -> inline x
  _ -> do
    -- A block in an inline position: a closure called at once.
    inner <- body tValue Return e
    pure (closure [] tValue inner <> D.text "()")
  where
    -- A closure passed last is a trailing closure, as Swift writes it; a
    -- call with closures elsewhere has one argument a line.
    applied f args = case reverse args of
      lastArgument@(Lambda {}) : before | not (any isLambda before), trailing f -> do
        ds <- mapM inline (reverse before)
        lam <- inline lastArgument
        pure (f <> (if null ds then mempty else argumentsDoc ds) <> D.text " " <> lam)
      _ -> do
        ds <- mapM inline args
        pure (f <> argumentsDoc ds)

-- | A generic initializer takes its closure in parentheses.
trailing :: D.Doc -> Bool
trailing f = D.render D.Compact f `notElem` ["UncheckedBox"]

isLambda :: Expr -> Bool
isLambda e = case e of
  Lambda {} -> True
  _ -> False

-- | A list with one item a line, as swift-format keeps one whose items
-- hold closures.
brokenList :: String -> String -> Bool -> [D.Doc] -> D.Doc
brokenList opening closing trailing ds =
  D.text opening <> D.nest indentation (D.hardline <> D.joinWith (D.text "," <> D.hardline) ds <> (if trailing then D.text "," else mempty)) <>
  D.hardline <> D.text closing

-- | A call of documents: its arguments on one line, or one a line.
callDoc :: String -> [D.Doc] -> D.Doc
callDoc f ds = D.text f <> argumentsDoc ds

argumentsDoc :: [D.Doc] -> D.Doc
argumentsDoc ds
  | any spansLines ds = brokenList "(" ")" False ds
  | otherwise = D.delimit indentation "(" ")" ds

-- | Whether a document holds a line break it must keep (a closure's body):
-- swift-format then puts each of its list's items on a line of its own.
spansLines :: D.Doc -> Bool
spansLines d = '\n' `elem` D.render D.Compact d

-- | An array literal: on one line, or one item a line with a trailing
-- comma after each of several, as swift-format writes it. On one line, a
-- literal of several items keeps a column free for that comma, as
-- swift-format measures it.
arrayDoc :: [D.Doc] -> D.Doc
arrayDoc ds | any spansLines ds = brokenList "[" "]" (length ds > 1) ds
arrayDoc [d] = D.delimit indentation "[" "]" [d]
arrayDoc [] = D.text "[]"
arrayDoc ds = D.group (D.text "[" <> D.nest indentation (D.softbreak <> D.commaSep ds <> D.whenBroken (D.text ",")) <>
  D.softbreak <> D.text "]" <> D.flatReserve 1)

-- | A declaration with parameters (func f(a: A) throws -> R): its
-- parameters on one line, or one a line with the closing parenthesis on a
-- line of its own, then its body as a block.
signature :: String -> [String] -> String -> D.Doc -> D.Doc
signature opening parameters closing body =
  D.text opening <> argumentsDoc (map D.text parameters) <> D.text closing <> blockDoc body

-- | A type's declaration (final class C: P, Q): its conformances on one
-- line, or one a line with the brace on a line of its own, then its body.
typeDeclaration :: String -> [String] -> D.Doc -> D.Doc
typeDeclaration opening conformances inner =
  D.group (D.text (opening ++ ":") <> D.nest indentation (D.softline <> D.joinWith (D.text "," <> D.softline) (map D.text conformances)) <>
    D.softline <> D.text "{") <> D.nest indentation (D.hardline <> inner) <> D.hardline <> D.text "}"

-- | A braced block's body on lines of its own.
blockDoc :: D.Doc -> D.Doc
blockDoc body = D.text " {" <> D.nest indentation (D.hardline <> body) <> D.hardline <> D.text "}"

-- | A line comment, wrapped at the width.
comment :: String -> D.Doc
comment = D.lineComment (D.styleWidth (D.styleFor "swift")) "// "

-- | A generated file's header and imports: the header line, then each
-- group of import lines sorted (modules, then declarations, then testable
-- imports), as swift-format orders them.
fileHeader :: String -> [[String]] -> D.Doc
fileHeader header groups =
  D.text ("// " ++ header) <> D.hardline <>
  mconcat [D.hardline <> D.joinWith D.hardline (map D.text (sort imports)) <> D.hardline | imports <- groups, not (null imports)]

-- | swift-format's indentation: two spaces.
indentation :: Int
indentation = D.styleIndent (D.styleFor "swift")

-- | swift-format's layout: a width of 100.
swiftLayout :: D.Layout
swiftLayout = D.styleLayout (D.styleFor "swift")

-- | A statement's prefix (let x =, return) and its value. The value moves
-- to a line of its own only when its first line up to its first break
-- does not fit after the prefix, as swift-format breaks after = and return.
hangValue :: String -> D.Doc -> D.Doc
hangValue prefix value = D.text prefix <> D.prefixChoice (" " ++ firstChunk value) (D.text " " <> value)
  (D.nest indentation (D.hardline <> value))
  where firstChunk = takeWhile (/= '\n') . D.render (D.Pretty 1)

-- | An integer literal, its digits grouped in threes past six, as
-- swift-format groups them.
intLiteral :: Integer -> String
intLiteral n
  | n < 0 = '-' : intLiteral (negate n)
  | length digits > 6 = reverse (grouped (reverse digits))
  | otherwise = digits
  where
    digits = show n
    grouped ds = case splitAt 3 ds of
      (a, []) -> a
      (a, rest) -> a ++ "_" ++ grouped rest

bigLiteral :: Integer -> String
bigLiteral n
  | abs n < 2 ^ (62 :: Int) = "BigInt(" ++ intLiteral n ++ ")"
  | otherwise = "BigInt(\"" ++ show n ++ "\")!"

-- | A Swift string literal: printable characters as they are, Swift's own
-- escapes, and \u{...} for the rest (LawSpec.Code.Literal).
stringLiteral :: String -> String
stringLiteral = literalFor "swift"
