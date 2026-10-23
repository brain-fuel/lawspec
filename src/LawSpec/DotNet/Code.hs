-- | The code the .NET emitters share between F# and C#: expressions over the
-- LawSpec runtime, printed as F# or as C#. Anything that needs a block (a
-- conditional, a function, a local binding) is first bound to a fresh local,
-- so F# never meets the offside rule mid-expression and C# gets statements;
-- arguments keep their left-to-right order. ref:DEC-csharp-over-fsharp
-- ref:DEC-readable-output-default
module LawSpec.DotNet.Code
  ( Lang(..), Ty(..), Fn(..), Expr(..)
  , tValue, tValues, tBool, tUnit, tString, tSchema, tSymbols, tObj, tInt, tFun, tList, tOption, tGen, tType
  , fn, call, str, renderBody, renderStatements, renderExpr, stringLiteral, tyText, isInline, pageWidth
  , Lines, linesDoc, pad, columns, functionLines
  ) where

import qualified LawSpec.Code.Doc as D
import Control.Monad.State.Strict (State, evalState, get, put)
import Control.Monad (guard, forM)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (intercalate)
import LawSpec.Code.Literal (literalFor)
import LawSpec.DotNet.Layout (columns, dottedLines)

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
  (foldr (\(Ty _ ca) rest -> "FSharpFunc<" ++ ca ++ ", " ++ rest ++ ">") cr argsOrUnit)
  where
    argsOrUnit = if null args then [tUnit] else args

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
  Do [] x -> isInline x
  Do {} -> False
  Call _ args -> all isInline args
  Ctor _ args -> all isInline args
  Invoke f args -> all isInline (f : args)
  ListOf _ xs -> all isInline xs
  TupleOf xs -> all isInline xs
  _ -> True

-- | A statement: a binding (of anything, block or not) or a unit effect.
data Stmt = Bind String Ty Expr | Effect Expr

-- | Fresh names, and the width the code being laid out has: Fantomas lays
-- out a parenthesised lambda's body one column narrower than its context.
type Fresh = State (Int, Int)

fresh :: Fresh String
fresh = do
  (n, w) <- get
  put (n + 1, w)
  pure ("ls" ++ show n)

widthNow :: Fresh Int
widthNow = snd <$> get

-- | Lay out the body of a parenthesised lambda.
narrower :: Fresh a -> Fresh a
narrower action = do
  (n, w) <- get
  put (n, w - 1)
  x <- action
  (n', _) <- get
  put (n', w)
  pure x

-- | Statements that compute an expression, and the inline expression left.
-- Block constructs in argument position are bound first; when one argument
-- is, the arguments before it are too, so effects keep their order. A
-- statement's own call keeps a function as its last argument, as F# and C#
-- write a callback.
flatten :: Bool -> Ty -> Expr -> Fresh ([Stmt], Expr)
flatten top ty e = case e of
  Let name t value body -> do
    s1 <- bindTo name t value
    (s2, rest) <- flatten top ty body
    pure (s1 ++ s2, rest)
  Do effects value -> do
    ss <- mapM effect effects
    (s2, rest) <- flatten top ty value
    pure (concat ss ++ s2, rest)
  Call f args | top, not (null args), Lambda {} <- last args -> do
    (ss, front) <- arguments (init args)
    pure (ss, Call f (front ++ [last args]))
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
  Lambda {} | not top -> hoisted
  If {} | not top -> hoisted
  _ -> pure ([], e)
  where
    hoisted = do
      name <- fresh
      -- A conditional's local has the conditional's own type.
      let t = case e of If _ ct _ _ -> ct; _ -> ty
      pure ([Bind name t e], Var name)
    effect x = do
      (ss, x') <- flatten True tUnit x
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
      (ss, a') <- flatten False tValue a
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
    (ss, v) <- flatten True t value
    pure (ss ++ [Bind name t v])

-- | Flattening moves bindings out of sibling argument expressions. Preserve
-- their lexical scopes by giving their binders distinct names before hoisting.
-- F# otherwise accepts the shadowing and changes the value of an earlier
-- operand, while C# refuses it. The first binder keeps its name, which raw
-- text may mention.
distinct :: Expr -> Expr
distinct e = evalState (go M.empty e) S.empty
  where
    go :: M.Map String String -> Expr -> State (S.Set String) Expr
    go env x = case x of
      Var v -> pure (Var (M.findWithDefault v v env))
      Call f args -> Call f <$> mapM (go env) args
      Ctor f args -> Ctor f <$> mapM (go env) args
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
      _ -> pure x
    binder :: String -> State (S.Set String) String
    binder n = do
      used <- get
      let n' = head [c | c <- n : [n ++ "_" ++ show k | k <- [1 :: Int ..]], not (S.member c used)]
      put (S.insert n' used)
      pure n'

-- ---------------------------------------------------------------------------
-- Layout. Both languages are printed at their formatters' width: F# as
-- Fantomas lays code out (its default settings), C# so that dotnet format
-- leaves it unchanged. ref:DEC-readable-output-default

-- | Fantomas's and dotnet format's line width.
pageWidth :: Int
pageWidth = 120

-- | Lines of code. In an expression's lines the first continues the current
-- line and the rest carry their own indentation; a block's lines all do.
type Lines = [String]

pad :: Int -> String -> String
pad i s = replicate i ' ' ++ s

-- | Text after an expression's last line (a closing bracket, a semicolon).
closing :: String -> Lines -> Lines
closing s [] = [s]
closing s ls = init ls ++ [last ls ++ s]

-- | Text before an expression's first line (an opening bracket, let x =).
opening :: String -> Lines -> Lines
opening s [] = [s]
opening s (l : ls) = (s ++ l) : ls


-- | A function: its declaration (an F# let, a C# method) with its
-- parameters, result type and body, as Fantomas lays out a function or
-- dotnet format leaves a method. F# keeps a body of up to 40 columns on the
-- declaration's line while it is under 40 columns; a declaration too wide for its line has a parameter
-- on each line.
functionLines :: Lang -> Int -> String -> [(String, Ty)] -> Ty -> Expr -> Lines
functionLines lang i declaration parameters result e = evalState go (0, pageWidth)
  where
    unitBody = result == tUnit
    body = block lang (i + 4) result (if unitBody then Discard else Return) (distinct e)
    go = case lang of
      FSharp -> do
        inner <- body
        let ps = if null parameters then ["()"] else ["(" ++ p ++ ": " ++ tyText FSharp t ++ ")" | (p, t) <- parameters]
            header = declaration ++ " " ++ unwords ps ++ " : " ++ tyText FSharp result ++ " ="
        pure $ if i + columns header <= pageWidth
          then case inner of
            [only] | let b = dropWhile (== ' ') only, columns b < 40, i + columns header + 1 + columns b <= pageWidth ->
              [pad i (header ++ " " ++ b)]
            _ -> pad i header : inner
          else [pad i declaration] ++ [pad (i + 4) p | p <- ps] ++ [pad (i + 4) (": " ++ tyText FSharp result ++ " =")] ++ inner
      CSharp -> do
        inner <- body
        let ps = [tyText CSharp t ++ " " ++ p | (p, t) <- parameters]
            header = declaration ++ "(" ++ intercalate ", " ps ++ ")"
            heading = if i + columns header <= pageWidth || null ps then [pad i header]
              else (pad i (declaration ++ "(")) : [pad (i + 4) (p ++ (if k == length ps then ")" else ",")) | (k, p) <- zip [1 :: Int ..] ps]
        pure (heading ++ [pad i "{"] ++ inner ++ [pad i "}"])

-- | A block's lines as a document, relative to the block's indentation.
linesDoc :: Int -> Lines -> D.Doc
linesDoc base ls = D.joinWith D.hardline [D.text (drop base l) | l <- ls]

-- | A function body: its statements and its result, at an indentation.
renderBody :: Lang -> Int -> Ty -> Expr -> D.Doc
renderBody lang indentation ty e = linesDoc indentation (evalState (block lang indentation ty Return (distinct e)) (0, pageWidth))

-- | A body run for its effects (a C# void method, an F# unit function).
renderStatements :: Lang -> Int -> Expr -> D.Doc
renderStatements lang indentation e = linesDoc indentation (evalState (block lang indentation tUnit Discard (distinct e)) (0, pageWidth))

-- | An expression that is already inline, on one line.
renderExpr :: Lang -> Expr -> D.Doc
renderExpr lang e = D.text (maybe "" id (flat lang (distinct e)))

-- | Where a C# block's result goes: returned, assigned to a local, or
-- dropped (a void body).
data Sink = Return | Assign String | Discard deriving Eq

data UnitSink = Plain | UnitReturn | Dropped deriving Eq

-- | A block's lines at an indentation. Fantomas separates a statement that
-- spans lines from its neighbours with a blank line.
block :: Lang -> Int -> Ty -> Sink -> Expr -> Fresh Lines
block lang i ty sink e = do
  (ss, result) <- flatten True ty e
  items <- mapM (statement lang i) ss
  let unitSink = if lang == CSharp && ty == tUnit then (if sink == Return then UnitReturn else Dropped) else Plain
  final <- case result of
    If c t a b -> pure <$> conditional lang i t sink c a b
    UnitLit | unitSink == UnitReturn -> pure [[pad i "return default(Unit);"]]
    UnitLit | unitSink == Dropped -> pure []
    UnitLit | lang == FSharp && sink == Discard && not (null items) -> pure []
    _ | unitSink == UnitReturn -> (\ls -> [ls, [pad i "return default(Unit);"]]) <$> exprStatement lang i "" ";" result
    _ | unitSink == Dropped -> pure <$> exprStatement lang i "" ";" result
    _ -> pure <$> finish lang i sink result
  let all' = items ++ final
  pure (if lang == FSharp then separated all' else concat all')

-- | Statements joined, with a blank line around each that spans lines.
separated :: [Lines] -> Lines
separated (a : rest@(b : _)) = a ++ [""  | length a > 1 || length b > 1] ++ separated rest
separated [a] = a
separated [] = []

finish :: Lang -> Int -> Sink -> Expr -> Fresh Lines
finish FSharp i _ e = exprStatement FSharp i "" "" e
finish CSharp i Return e = exprStatement CSharp i "return " ";" e
finish CSharp i (Assign name) e = exprStatement CSharp i (name ++ " = ") ";" e
finish CSharp i Discard e = exprStatement CSharp i "" ";" e

-- | An expression as a statement: its lines after a prefix, then a suffix.
exprStatement :: Lang -> Int -> String -> String -> Expr -> Fresh Lines
exprStatement lang i before after e = do
  ls <- expr lang i (i + length before) (length after) e
  pure (closing after (opening (pad i before) ls))

statement :: Lang -> Int -> Stmt -> Fresh Lines
statement lang i s = case s of
  Effect e -> exprStatement lang i "" (if lang == FSharp then "" else ";") e
  Bind name t (If c rt a b) -> widthNow >>= \w -> case lang of
    FSharp -> case flat FSharp (If c rt a b) of
      Just f | fitsBinding w i name f -> pure [pad i ("let " ++ name ++ " = " ++ f)]
      _ -> (pad i ("let " ++ name ++ " =") :) <$> conditional lang (i + 4) rt Return c a b
    CSharp -> (pad i (tyText CSharp t ++ " " ++ name ++ ";") :) <$> conditional lang i rt (Assign name) c a b
  Bind name _ e -> widthNow >>= \w -> case lang of
    FSharp -> case flat FSharp e of
      Just f | fitsBinding w i name f -> pure [pad i ("let " ++ name ++ " = " ++ f)]
      _ -> do
        ls <- expr lang (i + 4) (i + 4) 0 e
        pure (pad i ("let " ++ name ++ " =") : opening (pad (i + 4) "") ls)
    -- C# infers the local's type, as F# does.
    CSharp -> exprStatement lang i ("var " ++ name ++ " = ") ";" e
  where
    -- Fantomas keeps a value binding on one line while name = value takes
    -- up to 80 columns.
    fitsBinding w indentation name f = columns (name ++ " = " ++ f) <= 80 && indentation + length ("let " ++ name ++ " = ") + columns f <= w

-- | A conditional, after the statements its condition needs. F# writes a
-- short one on one line.
conditional :: Lang -> Int -> Ty -> Sink -> Expr -> Expr -> Expr -> Fresh Lines
conditional lang i ty sink c a b = do
  (cs, c') <- flatten True tBool c
  pre <- mapM (statement lang i) cs
  w <- widthNow
  case flat lang (If c' ty a b) of
    Just f | lang == FSharp, i + columns f <= w -> pure (separated (pre ++ [[pad i f]]))
    _ -> conditionalLines lang i ty sink pre c' a b

conditionalLines :: Lang -> Int -> Ty -> Sink -> [Lines] -> Expr -> Expr -> Expr -> Fresh Lines
conditionalLines lang i ty sink pre c' a b = conditionalLines' True lang i ty sink pre c' a b

conditionalLines' :: Bool -> Lang -> Int -> Ty -> Sink -> [Lines] -> Expr -> Expr -> Expr -> Fresh Lines
conditionalLines' compact lang i ty sink pre c' a b
  -- An else-if chain whose every clause is short has a line per clause.
  | compact, lang == FSharp, Just ls <- compactChain = pure (separated (pre ++ [ls]))
  where
    compactChain = do
      let chain = clauses c' a b
          (conditions, final) = (init chain, snd (last chain))
      guard (length conditions >= 2)
      texts <- forM conditions $ \(cond, body) -> (\x y -> (x, y)) <$> (cond >>= flat FSharp) <*> (guard (isInline body) >> flat FSharp body)
      finalText <- guard (isInline final) >> flat FSharp final
      let lines' = [(if k == 0 then "if " else "else if ") ++ x ++ " then " ++ y | (k, (x, y)) <- zip [0 :: Int ..] texts] ++ ["else " ++ finalText]
      guard (all ((<= 60) . columns) lines')
      pure (map (pad i) lines')
    clauses cond yes no = case no of
      If c2 _ a2 b2 | isInline c2 -> (Just cond, yes) : clauses c2 a2 b2
      _ -> [(Just cond, yes), (Nothing, no)]
conditionalLines' _ lang i ty sink pre c' a b = do
  w <- widthNow
  -- F# writes a condition too long for its line between if and then.
  cd <- case lang of
    FSharp -> case flat FSharp c' of
      Just f | i + 3 + columns f + 5 <= w -> pure [f]
      _ -> do
        inner <- expr lang (i + 4) (i + 4) 0 c'
        pure ("" : opening (pad (i + 4) "") inner ++ [pad i ""])
    CSharp -> expr lang i (i + 4) 1 c'
  ad <- block lang (i + 4) ty sink a
  rest <- case (lang, b) of
    -- else if: an else branch that is only a conditional continues the chain.
    (FSharp, If c2 t2 a2 b2) | isInline c2 -> do
      chained <- conditionalLines' False lang i t2 sink [] c2 a2 b2
      pure (opening (pad i "else ") (dropIndent chained))
    _ -> do
      bd <- block lang (i + 4) ty sink b
      pure $ case lang of
        FSharp -> pad i "else" : bd
        CSharp -> [pad i "else", pad i "{"] ++ bd ++ [pad i "}"]
  let doc = case lang of
        FSharp -> (case cd of
          [f] -> [pad i ("if " ++ f ++ " then")]
          _ -> [pad i "if"] ++ drop 1 (init cd) ++ [pad i "then"]) ++ ad ++ rest
        CSharp -> closing ")" (opening (pad i "if (") cd) ++ [pad i "{"] ++ ad ++ [pad i "}"] ++ rest
  pure (separated (pre ++ [doc]))
  where dropIndent ls = case ls of l : more -> dropWhile (== ' ') l : more; [] -> []

-- | Parameters of a lambda.
lambdaParameters :: Lang -> [(String, Ty)] -> String
lambdaParameters FSharp ps = if null ps then "()" else unwords ["(" ++ p ++ ": " ++ tyText FSharp t ++ ")" | (p, t) <- ps]
lambdaParameters CSharp ps = "(" ++ intercalate ", " [tyText CSharp t ++ " " ++ p | (p, t) <- ps] ++ ")"

-- | A lambda's opening: fun (x: T) -> in F#, Fn.F1((T x) => in C#.
lambdaOpening :: Lang -> [(String, Ty)] -> String
lambdaOpening FSharp ps = "fun " ++ lambdaParameters FSharp ps ++ " ->"
lambdaOpening CSharp ps = "Fn.F" ++ show (length ps) ++ "(" ++ lambdaParameters CSharp ps ++ " =>"

-- | A lambda whose body spans lines, its opening on the current line.
lambdaLines :: Lang -> Int -> [(String, Ty)] -> Ty -> Expr -> Fresh Lines
lambdaLines lang i ps r b = do
  inner <- block lang (i + 4) r Return b
  pure $ case lang of
    FSharp -> lambdaOpening FSharp ps : inner
    CSharp -> [lambdaOpening CSharp ps, pad i "{"] ++ inner ++ [pad i "})"]

-- | An expression on one line, when it has no blocks and Fantomas's widths
-- allow: a list up to 80 columns, a conditional up to 60.
flat :: Lang -> Expr -> Maybe String
flat lang e = case e of
  Var v -> Just v
  Str s -> Just (stringLiteral lang s)
  IntLit n -> Just (show n)
  BigLit n -> Just (bigLiteral lang n)
  BoolLit b -> Just (if b then "true" else "false")
  UnitLit -> Just (if lang == FSharp then "()" else "default(Unit)")
  Raw f c -> Just (if lang == FSharp then f else c)
  Call (Fn f c) args -> case lang of
    FSharp | null args -> Just (f ++ (if methodLike f then "()" else " ()"))
           | [a] <- args, needsParens a || a == UnitLit || isTuple a, methodLike f -> (f ++) <$> atom a
           | otherwise -> unwords . (f :) <$> mapM atom args
    CSharp -> applied c <$> mapM (flat lang) args
  Ctor (Fn f c) args -> applied (if lang == FSharp then f else c) <$> mapM (flat lang) args
  Invoke g args -> case lang of
    FSharp -> if null args then (++ " ()") <$> atom g else unwords <$> mapM atom (g : args)
    CSharp -> applied "Fn.Invoke" <$> mapM (flat lang) (g : args)
  ListOf t xs -> case lang of
    FSharp | null xs -> Just "[]"
           | otherwise -> do
               items <- mapM (flat lang) xs
               let s = "[ " ++ intercalate "; " items ++ " ]"
               if columns s <= 80 then Just s else Nothing
    CSharp -> applied ("Fn.List<" ++ tyText CSharp t ++ ">") <$> mapM (flat lang) xs
  TupleOf xs -> applied (if lang == FSharp then "" else "Fn.Tuple") <$> mapM (flat lang) xs
  Lambda ps r b | isInline b && (lang == FSharp || r /= tUnit) -> do
    body <- flat lang b
    pure $ case lang of
      FSharp -> lambdaOpening FSharp ps ++ " " ++ body
      CSharp -> lambdaOpening CSharp ps ++ " " ++ body ++ ")"
  Do [] x -> flat lang x
  If c _ a b | lang == FSharp, all isInline [c, a, b] -> do
    s <- (\c' a' b' -> "if " ++ c' ++ " then " ++ a' ++ " else " ++ b') <$> flat lang c <*> flat lang a <*> flat lang b
    if columns s <= 60 then Just s else Nothing
  _ -> Nothing
  where
    applied name xs = name ++ "(" ++ intercalate ", " xs ++ ")"
    atom a = (\s -> if needsParens a then "(" ++ s ++ ")" else s) <$> flat lang a
    isTuple a = case a of TupleOf (_ : _) -> True; _ -> False

-- | Whether an F# argument needs parentheses.
needsParens :: Expr -> Bool
needsParens a = case a of
  Call _ _ -> True
  Ctor _ _ -> True
  Invoke _ _ -> True
  Lambda {} -> True
  If {} -> True
  IntLit n -> n < 0
  BigLit n -> n < 0
  Raw f _ -> any (== ' ') f && not (take 1 f `elem` ["(", "["])
  _ -> False

-- | An expression starting at column c of a line indented i, leaving room
-- for t more columns after it: on one line when it fits, else broken as the
-- formatter breaks it.
expr :: Lang -> Int -> Int -> Int -> Expr -> Fresh Lines
expr lang i c t e = widthNow >>= \w -> case flat lang e of
  Just s | c + columns s + t - closer <= w || unbreakable -> pure [s]
  _ -> broken lang i c e
  where
    -- Fantomas leaves a tuple's closing parenthesis out of its measure.
    closer = case (lang, e) of
      (FSharp, TupleOf (_ : _)) -> 1
      _ -> 0
    -- A name, a literal or an empty call has nowhere to break.
    unbreakable = case e of
      Call _ [] -> True
      Ctor _ [] -> True
      Invoke _ [] -> True
      ListOf _ [] -> True
      TupleOf [] -> True
      Call {} -> False
      Ctor {} -> False
      Invoke {} -> False
      ListOf {} -> False
      TupleOf {} -> False
      Lambda {} -> False
      If {} -> False
      Let {} -> False
      Do {} -> False
      _ -> True

broken :: Lang -> Int -> Int -> Expr -> Fresh Lines
broken lang i c e = widthNow >>= \w -> brokenAt w lang i c e

brokenAt :: Int -> Lang -> Int -> Int -> Expr -> Fresh Lines
brokenAt w FSharp i c e = case e of
  Call (Fn f _) args -> application i c f args
  Invoke g args | Just head' <- flat FSharp g -> application i c (if needsParens g then "(" ++ head' ++ ")" else head') args
  Ctor (Fn f _) args -> commaList (f ++ "(") ")" args
  TupleOf xs -> do
    items <- mapM (\(k, x) -> (if k == 1 then id else opening (pad (c + 1) "")) <$> expr FSharp (c + 1) (c + 1) 0 x) (zip [1 :: Int ..] xs)
    let joined = concat [if k == length items then ls else closing "," ls | (k, ls) <- zip [1 :: Int ..] items]
    pure (closing ")" (opening "(" joined))
  ListOf _ xs -> do
    items <- mapM (item (i + 4)) xs
    pure (["["] ++ concat items ++ [pad i "]"])
  Lambda ps r b -> lambdaLines FSharp i ps r b
  _ -> fallback FSharp i e
  where
    item j x = opening (pad j "") <$> expr FSharp j j 0 x
    commaList open close args = do
      items <- mapM (item (i + 4)) args
      pure ([open] ++ concat [if k == length items then ls else closing "," ls | (k, ls) <- zip [1 :: Int ..] items] ++ [pad i close])
    -- f a b: on one line, with a function last kept on the first line (as
    -- a callback), with one parenthesised argument opened on the first
    -- line, or with each argument on a line of its own.
    application j column f args
      | not (null args), Lambda ps r b <- last args, Just fronts <- mapM atom (init args)
      , let open = if null fronts && methodLike f then f ++ "(" ++ lambdaOpening FSharp ps else unwords (f : fronts ++ ["(" ++ lambdaOpening FSharp ps])
      , column + columns open <= w = do
          inner <- narrower (block FSharp (j + 4) r Return b)
          pure (closing ")" (open : inner))
      | [a] <- args, needsParens a, not (isLambda a) = do
          inner <- expr FSharp (j + 4) (j + 4) 0 a
          pure ([f ++ (if methodLike f then "(" else " (")] ++ opening (pad (j + 4) "") inner ++ [pad j ")"])
      -- A name too long for its line breaks at a dot: as many of its parts
      -- as fit, then the rest.
      | column + columns f > w, (first : rest@(_ : _)) <- dottedLines w column (j + 4) f = do
          items <- mapM (argument (j + 4)) args
          pure ([first] ++ rest ++ concat items)
      | otherwise = do
          items <- mapM (argument (j + 4)) args
          pure (f : concat items)
    argument j a
      | needsParens a = do
          inner <- (if isLambda a then narrower else id) (expr FSharp j (j + 1) 0 a)
          pure (closing ")" (opening (pad j "(") inner))
      | otherwise = item j a
    atom a = (\s -> if needsParens a then "(" ++ s ++ ")" else s) <$> flat FSharp a
    isLambda a = case a of Lambda {} -> True; _ -> False

brokenAt w CSharp i c e = case e of
  Call (Fn _ name) args -> call' name args
  Ctor (Fn _ name) args -> call' name args
  Invoke g args -> call' "Fn.Invoke" (g : args)
  ListOf t xs -> call' ("Fn.List<" ++ tyText CSharp t ++ ">") xs
  TupleOf xs -> call' "Fn.Tuple" xs
  Lambda ps r b -> lambdaLines CSharp i ps r b
  _ -> fallback CSharp i e
  where
    -- A callback last stays on the first line when the opening fits;
    -- otherwise each argument goes on a line of its own.
    call' name args
      | not (null args), Lambda ps r b <- last args, Just fronts <- mapM (flat CSharp) (init args)
      , let open = name ++ "(" ++ concatMap (++ ", ") fronts ++ lambdaOpening CSharp ps
      , c + columns open <= w = do
          inner <- block CSharp (i + 4) r Return b
          pure ([open, pad i "{"] ++ inner ++ [pad i "}))"])
      | otherwise = do
          items <- mapM (\a -> opening (pad (i + 4) "") <$> expr CSharp (i + 4) (i + 4) 1 a) args
          pure ((name ++ "(") : concat [closing (if k == length items then ")" else ",") ls | (k, ls) <- zip [1 :: Int ..] items])

-- | Whether F# calls a function as a method: its name's last part is
-- capitalised, and Fantomas writes it next to a parenthesised argument.
methodLike :: String -> Bool
methodLike f = case reverse (takeWhile (/= '.') (reverse f)) of
  c : _ -> c >= 'A' && c <= 'Z'
  [] -> False

-- | A block in an inline position: a function of no arguments, applied.
fallback :: Lang -> Int -> Expr -> Fresh Lines
fallback lang i e = do
  inner <- (if lang == FSharp then narrower else id) (block lang (i + 4) tValue Return e)
  pure $ case lang of
    FSharp -> ["(fun () ->"] ++ closing ") ()" inner
    CSharp -> ["Fn.Run(() =>", pad i "{"] ++ inner ++ [pad i "})"]

bigLiteral :: Lang -> Integer -> String
bigLiteral FSharp n = show n ++ "I"
bigLiteral CSharp n
  | abs n < 2 ^ (62 :: Int) = "new BigInteger(" ++ show n ++ "L)"
  | otherwise = "BigInteger.Parse(\"" ++ show n ++ "\")"

-- | A string literal, as each language writes it: printable characters as
-- they are, the standard escapes, and \u escapes for the rest.
-- ref:DEC-native-string-literals
stringLiteral :: Lang -> String -> String
stringLiteral FSharp = literalFor "fsharp"
stringLiteral CSharp = literalFor "csharp"
