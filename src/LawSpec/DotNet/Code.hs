-- | The code the .NET emitters share between F# and C#: expressions over the
-- LawSpec runtime, printed as F# or as C#. Anything that needs a block (a
-- conditional, a function, a local binding) is first bound to a fresh local,
-- so F# never meets the offside rule mid-expression and C# gets statements;
-- arguments keep their left-to-right order. ref:DEC-csharp-over-fsharp
-- ref:DEC-readable-output-default
module LawSpec.DotNet.Code
  ( Lang(..), Ty(..), Fn(..), Expr(..)
  , tValue, tValues, tBool, tUnit, tString, tSchema, tSymbols, tObj, tInt, tFun, tList, tOption, tGen, tType
  , fn, call, str, renderBody, renderStatements, renderExpr, stringLiteral, tyText, isInline
  ) where

import qualified LawSpec.Code.Doc as D
import Control.Monad.State.Strict (State, evalState, get, put)
import Data.Char (ord, isAscii, isPrint)
import Numeric (showHex)

data Lang = FSharp | CSharp deriving (Eq, Show)

-- | A .NET type, as F# and as C# write it.
data Ty = Ty String String deriving (Eq, Show)

-- | A runtime function: its F# name and its C# name.
data Fn = Fn String String deriving (Eq, Show)

data Expr
  = Var String
  | Str String
  | IntLit Integer
  | BigLit Integer
  | BoolLit Bool
  | UnitLit
  | Raw String String
  | Call Fn [Expr]
  -- | A constructor or method applied to a tuple of arguments, as both
  -- languages write it: Value.Data(tag, fields).
  | Ctor Fn [Expr]
  -- | Apply an F# function value.
  | Invoke Expr [Expr]
  | ListOf Ty [Expr]
  | TupleOf [Expr]
  | Lambda [(String, Ty)] Ty Expr
  | Let String Ty Expr Expr
  -- | A .NET bool condition, the type of the result and its two branches.
  | If Expr Ty Expr Expr
  -- | Unit-valued effects, then a value.
  | Do [Expr] Expr
  deriving (Eq, Show)

tValue, tValues, tBool, tUnit, tString, tSchema, tSymbols, tObj, tInt, tGen, tType :: Ty
tValue = Ty "Value" "Value"
tValues = Ty "Value list" "FSharpList<Value>"
tBool = Ty "bool" "bool"
tUnit = Ty "unit" "Unit"
tString = Ty "string" "string"
tSchema = Ty "Schema.Schema" "Schema.Schema"
tSymbols = Ty "Scalar.SymbolContext" "Scalar.SymbolContext"
tObj = Ty "obj" "object"
tInt = Ty "int" "int"
tGen = Ty "Gen<Value>" "Gen<Value>"
tType = Ty "TypeRef" "TypeRef"

tFun :: [Ty] -> Ty -> Ty
tFun args (Ty fr cr) = Ty (unwords [fa ++ " ->" | Ty fa _ <- argsOrUnit] ++ " " ++ fr)
  ("FSharpFunc<" ++ csArgs ++ ">")
  where
    argsOrUnit = if null args then [tUnit] else args
    csArgs = foldr (\(Ty _ ca) rest -> ca ++ ", " ++ rest) cr argsOrUnit

tList :: Ty -> Ty
tList (Ty f c) = Ty (paren f ++ " list") ("FSharpList<" ++ c ++ ">")
  where paren s = if ' ' `elem` s then "(" ++ s ++ ")" else s

tOption :: Ty -> Ty
tOption (Ty f c) = Ty (paren f ++ " option") ("FSharpOption<" ++ c ++ ">")
  where paren s = if ' ' `elem` s then "(" ++ s ++ ")" else s

tyText :: Lang -> Ty -> String
tyText FSharp (Ty f _) = f
tyText CSharp (Ty _ c) = c

-- | A function named the same way in both languages up to its first letter:
-- F# names it in camelCase, C# by its CompiledName in PascalCase.
fn :: String -> String -> Fn
fn owner name = Fn (owner ++ "." ++ name) (owner ++ "." ++ capital name)
  where capital (c : cs) = toEnum (fromEnum c - if c >= 'a' && c <= 'z' then 32 else 0) : cs
        capital [] = []

call :: String -> String -> [Expr] -> Expr
call owner name = Call (fn owner name)

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
  Ctor _ args -> all isInline args
  Invoke f args -> all isInline (f : args)
  ListOf _ xs -> all isInline xs
  TupleOf xs -> all isInline xs
  _ -> True

-- | A statement: a binding (of anything, block or not) or a unit effect.
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
  Let name t value body -> do
    s1 <- bindTo name t value
    (s2, rest) <- flatten ty body
    pure (s1 ++ s2, rest)
  Do effects value -> do
    ss <- mapM effect effects
    (s2, rest) <- flatten ty value
    pure (concat ss ++ s2, rest)
  Call f args -> do
    (ss, args') <- arguments args
    pure (ss, Call f args')
  Ctor f args -> do
    (ss, args') <- arguments args
    pure (ss, Ctor f args')
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
  Lambda {} -> hoisted
  If {} -> hoisted
  _ -> pure ([], e)
  where
    hoisted = do
      name <- fresh
      pure ([Bind name ty e], Var name)
    effect x = do
      (ss, x') <- flatten tUnit x
      pure (ss ++ [Effect x'])

arguments :: [Expr] -> Fresh ([Stmt], [Expr])
arguments args
  | all isInline args = pure ([], args)
  | otherwise = do
      results <- mapM one args
      pure (concatMap fst results, map snd results)
  where
    one a | simple a = pure ([], a)
    one a = do
      (ss, a') <- flatten tValue a
      if isInline a && not (simple a') then do
        name <- fresh
        pure (ss ++ [Bind name tValue a'], Var name)
      else pure (ss, a')
    simple a = case a of
      Var _ -> True
      Str _ -> True
      IntLit _ -> True
      BigLit _ -> True
      BoolLit _ -> True
      UnitLit -> True
      Raw _ _ -> True
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
renderBody :: Lang -> Ty -> Expr -> D.Doc
renderBody lang ty e = evalState (body lang ty Return e) 0

-- | A body run for its effects (a C# void method, an F# unit function).
renderStatements :: Lang -> Expr -> D.Doc
renderStatements lang e = evalState (body lang tUnit Discard e) 0

-- | An expression that is already inline.
renderExpr :: Lang -> Expr -> D.Doc
renderExpr lang e = evalState (inline lang e) 0

-- | Where a C# block's result goes: returned, assigned to a local, or
-- dropped (a void body).
data Sink = Return | Assign String | Discard

body :: Lang -> Ty -> Sink -> Expr -> Fresh D.Doc
body lang ty sink e = do
  (ss, result) <- flatten ty e
  docs <- mapM (statement lang) ss
  let unitSink = if lang == CSharp && ty == tUnit then (case sink of Return -> UnitReturn; _ -> Dropped) else Plain
  final <- case result of
    If c t a b -> conditional lang t sink c a b
    Lambda ps r b -> do
      l <- lambda lang ps r b
      pure (finish lang sink l)
    UnitLit | unitSink == UnitReturn -> pure (D.text "return Fn.Unit;")
    UnitLit | unitSink == Dropped -> pure mempty
    UnitLit | lang == FSharp && sinkDiscards sink && not (null docs) -> pure mempty
    _ | unitSink == UnitReturn -> (\d -> d <> D.text ";" <> D.hardline <> D.text "return Fn.Unit;") <$> inline lang result
    _ | unitSink == Dropped -> (<> D.text ";") <$> inline lang result
    _ -> finish lang sink <$> inline lang result
  pure (D.joinWith D.hardline (docs ++ [final | final /= mempty]))

data UnitSink = Plain | UnitReturn | Dropped deriving Eq

sinkDiscards :: Sink -> Bool
sinkDiscards Discard = True
sinkDiscards _ = False

finish :: Lang -> Sink -> D.Doc -> D.Doc
finish FSharp _ d = d
finish CSharp Return d = D.text "return " <> d <> D.text ";"
finish CSharp (Assign name) d = D.text (name ++ " = ") <> d <> D.text ";"
finish CSharp Discard d = d <> D.text ";"

statement :: Lang -> Stmt -> Fresh D.Doc
statement lang s = case s of
  Effect e -> do
    d <- inline lang e
    pure (if lang == FSharp then d else d <> D.text ";")
  Bind name t (If c rt a b) -> case lang of
    FSharp -> do
      d <- conditional lang rt Return c a b
      pure (D.text ("let " ++ name ++ " =") <> D.nest 4 (D.hardline <> d))
    CSharp -> do
      d <- conditional lang rt (Assign name) c a b
      pure (D.text (tyText CSharp t ++ " " ++ name ++ ";") <> D.hardline <> d)
  Bind name t (Lambda ps r b) -> do
    l <- lambda lang ps r b
    pure $ case lang of
      FSharp -> D.text ("let " ++ name ++ " =") <> D.nest 4 (D.hardline <> l)
      CSharp -> D.text ("var " ++ name ++ " = ") <> l <> D.text ";" <> mempty' t
  Bind name t e -> do
    d <- inline lang e
    pure $ case lang of
      FSharp -> D.text ("let " ++ name ++ " = ") <> d
      CSharp -> D.text (tyText CSharp t ++ " " ++ name ++ " = ") <> d <> D.text ";"
  where mempty' _ = mempty

conditional :: Lang -> Ty -> Sink -> Expr -> Expr -> Expr -> Fresh D.Doc
conditional lang ty sink c a b = do
  (cs, c') <- flatten tBool c
  pre <- mapM (statement lang) cs
  cd <- inline lang c'
  ad <- body lang ty sink a
  bd <- body lang ty sink b
  let doc = case lang of
        FSharp -> D.text "if " <> cd <> D.text " then" <> D.nest 4 (D.hardline <> ad) <>
          D.hardline <> D.text "else" <> D.nest 4 (D.hardline <> bd)
        CSharp -> D.text "if (" <> cd <> D.text ")" <> D.hardline <> D.block 4 ad <>
          D.hardline <> D.text "else" <> D.hardline <> D.block 4 bd
  pure (D.joinWith D.hardline (pre ++ [doc]))

lambda :: Lang -> [(String, Ty)] -> Ty -> Expr -> Fresh D.Doc
lambda lang ps r b = do
  inner <- body lang r Return b
  pure $ case lang of
    FSharp -> D.text "fun " <> D.text (if null ps then "()" else unwords ["(" ++ p ++ ": " ++ tyText FSharp t ++ ")" | (p, t) <- ps]) <>
      D.text " ->" <> D.nest 4 (D.hardline <> inner)
    CSharp ->
      let converter = "Fn.F" ++ show (length ps)
          params = "(" ++ commaList [tyText CSharp t ++ " " ++ p | (p, t) <- ps] ++ ")"
      in D.text (converter ++ "(" ++ params ++ " =>") <> D.hardline <> D.block 4 inner <> D.text ")"
  where
    commaList [] = ""
    commaList xs = foldr1 (\x y -> x ++ ", " ++ y) xs

inline :: Lang -> Expr -> Fresh D.Doc
inline lang e = case e of
  Var v -> pure (D.text v)
  Str s -> pure (D.text (stringLiteral lang s))
  IntLit n -> pure (D.text (show n))
  BigLit n -> pure (D.text (bigLiteral lang n))
  BoolLit b -> pure (D.text (if b then "true" else "false"))
  UnitLit -> pure (D.text (if lang == FSharp then "()" else "Fn.Unit"))
  Raw f c -> pure (D.text (if lang == FSharp then f else c))
  Call (Fn f c) args -> do
    ds <- mapM (inline lang) args
    pure $ case lang of
      FSharp -> if null ds then D.text (f ++ " ()") else D.text f <> mconcat [D.text " " <> atom a d | (a, d) <- zip args ds]
      CSharp -> D.text c <> D.text "(" <> D.joinWith (D.text ", ") ds <> D.text ")"
  Ctor (Fn f c) args -> do
    ds <- mapM (inline lang) args
    pure (D.text (if lang == FSharp then f else c) <> D.text "(" <> D.joinWith (D.text ", ") ds <> D.text ")")
  Invoke f args -> do
    fd <- inline lang f
    ds <- mapM (inline lang) args
    pure $ case lang of
      FSharp -> atom f fd <> mconcat [D.text " " <> atom a d | (a, d) <- zip args (if null ds then [D.text "()"] else ds)]
      CSharp -> D.text "Fn.Invoke(" <> D.joinWith (D.text ", ") (fd : ds) <> D.text ")"
  ListOf t xs -> do
    ds <- mapM (inline lang) xs
    pure $ case lang of
      FSharp -> if null ds then D.text "[]" else D.text "[ " <> D.joinWith (D.text "; ") ds <> D.text " ]"
      CSharp -> D.text ("Fn.List<" ++ tyText CSharp t ++ ">(") <> D.joinWith (D.text ", ") ds <> D.text ")"
  TupleOf xs -> do
    ds <- mapM (inline lang) xs
    pure (D.text "(" <> D.joinWith (D.text ", ") ds <> D.text ")")
  _ -> do
    -- A block in an inline position: bind it in a function of no arguments.
    inner <- body lang tValue Return e
    pure $ case lang of
      FSharp -> D.text "(fun () ->" <> D.nest 4 (D.hardline <> inner) <> D.text ") ()"
      CSharp -> D.text "Fn.Run(() =>" <> D.hardline <> D.block 4 inner <> D.text ")"
  where
    atom a d = if needsParens a then D.text "(" <> d <> D.text ")" else d
    needsParens a = case a of
      Call _ (_ : _) -> True
      Call _ [] -> True
      Ctor _ _ -> True
      Invoke _ _ -> True
      IntLit n -> n < 0
      BigLit n -> n < 0
      Raw f _ -> any (== ' ') f && not (wrapped f)
      _ -> False
    wrapped s = take 1 s `elem` ["(", "["] && True

bigLiteral :: Lang -> Integer -> String
bigLiteral FSharp n = show n ++ "I"
bigLiteral CSharp n
  | abs n < 2 ^ (62 :: Int) = "new BigInteger(" ++ show n ++ "L)"
  | otherwise = "BigInteger.Parse(\"" ++ show n ++ "\")"

-- | A string literal; every character outside printable ASCII is escaped,
-- with surrogate pairs for supplementary characters.
stringLiteral :: Lang -> String -> String
stringLiteral _ s = "\"" ++ concatMap escape s ++ "\""
  where
    escape c
      | c == '"' = "\\\""
      | c == '\\' = "\\\\"
      | c == '\n' = "\\n"
      | c == '\r' = "\\r"
      | c == '\t' = "\\t"
      | isAscii c && isPrint c = [c]
      | ord c > 0xFFFF = let n = ord c - 0x10000
                             hi = 0xD800 + n `div` 0x400
                             lo = 0xDC00 + n `mod` 0x400
                         in unit hi ++ unit lo
      | otherwise = unit (ord c)
    unit n = "\\u" ++ pad (showHex n "")
    pad h = replicate (4 - length h) '0' ++ h
