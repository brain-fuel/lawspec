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
  ) where

import qualified LawSpec.Code.Doc as D
import Control.Monad.State.Strict (State, evalState, get, put)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Char (ord, isAscii, isPrint)
import Data.List (intercalate)
import Numeric (showHex)

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

type Fresh = State Int

fresh :: Fresh String
fresh = do
  n <- get
  put (n + 1)
  pure ("ls" ++ show n)

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
      name <- fresh
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
        name <- fresh
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
renderBody ty e = evalState (body ty Return (distinct e)) 0

-- | A body run for its effects (a Void function).
renderStatements :: Expr -> D.Doc
renderStatements e = evalState (body tVoid Discard (distinct e)) 0

-- | An expression that is already inline.
renderExpr :: Expr -> D.Doc
renderExpr e = evalState (inline (distinct e)) 0

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
    binder :: String -> State (S.Set String) String
    binder n = do
      used <- get
      let n' = case [c | c <- n : [n ++ "_" ++ show k | k <- [1 :: Int ..]], not (S.member c used)] of { c : _ -> c; [] -> n }
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
          Assign name -> (\d -> D.text (name ++ " = ") <> tried result d) <$> inline result
    _ -> finish sink result <$> inline result
  pure (D.joinWith D.hardline (docs ++ [final | final /= mempty]))
  where
    effectLine r
      | inert r = pure mempty
      | returnsVoid r = tried r <$> inline r
      | otherwise = (\d -> D.text "_ = " <> tried r d) <$> inline r

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
        pure [D.text "_ = " <> tried v d]
  Bound name t (If c rt a b) -> do
    d <- conditional rt (Assign name) c a b
    pure [D.text ("let " ++ name ++ ": " ++ tyText (if t == Ty "" then rt else t)) <> D.hardline <> d]
  Bound name t (Lambda ps r b) -> do
    l <- lambda ps r b
    pure [D.text ("let " ++ name ++ annotation t ++ " = ") <> l]
  Bound name t v -> do
    d <- inline v
    pure [D.text ("let " ++ name ++ annotation t ++ " = ") <> tried v d]
  where tyText (Ty x) = x
        annotation (Ty "") = ""
        annotation t = ": " ++ tyText t

-- | A value with no effect: a name, a literal, raw text.
inert :: Expr -> Bool
inert v = case v of
  Var _ -> True
  Raw _ -> True
  Str _ -> True
  IntLit _ -> True
  BigLit _ -> True
  BoolLit _ -> True
  _ -> False

finish :: Sink -> Expr -> D.Doc -> D.Doc
finish Return e d = D.text "return " <> tried e d
finish (Assign name) e d = D.text (name ++ " = ") <> tried e d
finish Discard e d
  | inert e = mempty
  | returnsVoid e = tried e d
  | otherwise = D.text "_ = " <> tried e d

conditional :: Ty -> Sink -> Expr -> Expr -> Expr -> Fresh D.Doc
conditional ty sink c a b = do
  (cs, c') <- flatten tBool c
  pre <- statements cs c'
  cd <- inline c'
  ad <- body ty sink a
  bd <- body ty sink b
  let doc = D.text "if " <> tried c' cd <> D.text " {" <> D.nest 4 (D.hardline <> ad) <>
        D.hardline <> D.text "} else {" <> D.nest 4 (D.hardline <> bd) <> D.hardline <> D.text "}"
  pure (D.joinWith D.hardline (pre ++ [doc]))

lambda :: [(String, Ty)] -> Ty -> Expr -> Fresh D.Doc
lambda ps r b = do
  inner <- body r Return b
  let params = "(" ++ intercalate ", " [p ++ ": " ++ t | (p, Ty t) <- ps] ++ ")"
      Ty rt = r
  pure (D.text ("{ " ++ params ++ " throws -> " ++ rt ++ " in") <> D.nest 4 (D.hardline <> inner) <> D.hardline <> D.text "}")

inline :: Expr -> Fresh D.Doc
inline e = case e of
  Var v -> pure (D.text v)
  Str s -> pure (D.text (stringLiteral s))
  IntLit n -> pure (D.text (show n))
  BigLit n -> pure (D.text (bigLiteral n))
  BoolLit b -> pure (D.text (if b then "true" else "false"))
  Raw r -> pure (D.text r)
  Call f args -> applied f args
  Pure f args -> applied f args
  Invoke f args -> do
    fd <- inline f
    ds <- mapM inline args
    pure (fd <> D.text "(" <> D.joinWith (D.text ", ") ds <> D.text ")")
  ListOf _ xs -> do
    ds <- mapM inline xs
    pure (D.text "[" <> D.joinWith (D.text ", ") ds <> D.text "]")
  TupleOf xs -> do
    ds <- mapM inline xs
    pure (D.text "(" <> D.joinWith (D.text ", ") ds <> D.text ")")
  Lambda ps r b -> lambda ps r b
  Statement x -> inline x
  _ -> do
    -- A block in an inline position: a closure called at once.
    inner <- body tValue Return e
    pure (D.text "{ () throws -> Value in" <> D.nest 4 (D.hardline <> inner) <> D.hardline <> D.text "}()")
  where
    applied f args = do
      ds <- mapM inline args
      pure (D.text f <> D.text "(" <> D.joinWith (D.text ", ") ds <> D.text ")")

bigLiteral :: Integer -> String
bigLiteral n
  | abs n < 2 ^ (62 :: Int) = "BigInt(" ++ show n ++ ")"
  | otherwise = "BigInt(\"" ++ show n ++ "\")!"

-- | A string literal; every character outside printable ASCII is escaped as
-- a Unicode scalar.
stringLiteral :: String -> String
stringLiteral s = "\"" ++ concatMap escapeChar s ++ "\""
  where
    escapeChar c
      | c == '"' = "\\\""
      | c == '\\' = "\\\\"
      | c == '\n' = "\\n"
      | c == '\r' = "\\r"
      | c == '\t' = "\\t"
      | isAscii c && isPrint c = [c]
      | otherwise = "\\u{" ++ showHex (ord c) "" ++ "}"
