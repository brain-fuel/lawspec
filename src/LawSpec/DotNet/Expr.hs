-- | Core expressions as .NET code over the LawSpec runtime, the same for F#
-- and C#. All shared semantics go through the runtime; this module never
-- reads source syntax. ref:DEC-typed-core-boundary ref:DEC-csharp-over-fsharp
module LawSpec.DotNet.Expr
  ( Context(..), render, proposition, assertion, literal, value, typeRef, typeOfKey, typeKeyOf, valueCall
  , truth, bool, schemaVar, symbolsVar
  ) where

import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import qualified LawSpec.Core.Value as V
import LawSpec.DotNet.Code
import LawSpec.Backend (scalarTypeKey)
import LawSpec.Scalar (Scalar(..))
import Data.List (nub, nubBy, intercalate)
import LawSpec.DotNet.Names (localName, keywords)
import LawSpec.Naming (claimAll, scopeWith)
import Control.Monad.State.Strict (StateT, evalStateT, get, put, lift)

-- | What rendering needs beyond the expression: the machine profile, the
-- schema and symbol context in scope, how binders are named, how calls to
-- definitions and operations are made, and how a type is referred to.
data Context = Context
  { contextBits :: Int
  , contextSchema :: Expr
  , contextSymbols :: Expr
  , contextLocal :: C.Id -> String
  , contextExternal :: Context -> C.Expr -> [Expr] -> Either String Expr
  , contextType :: C.Type -> Either String Expr
  , contextKey :: C.Type -> Either String Expr }

schemaVar, symbolsVar :: Expr
schemaVar = Var "schema"
symbolsVar = Var "symbols"

-- | A runtime constructor of a portable value.
valueCall :: String -> [Expr] -> Expr
valueCall name = Ctor (Fn ("Value." ++ name) ("V." ++ name))

bool :: Bool -> Expr
bool b = valueCall "Bool" [BoolLit b]

-- | A portable boolean as a .NET bool.
truth :: Expr -> Expr
truth v = call "Runtime" "truth" [v]

-- | A closed type as the runtime refers to it.
typeRef :: C.Type -> Either String Expr
typeRef ty = do
  ref <- S.typeReference [] ty
  pure (typeOfKey (refKey ref))

typeOfKey :: String -> Expr
typeOfKey key = call "Scalar" "typeOf" [Str key]

refKey :: S.TypeRef -> String
refKey (S.Parameter i) = "$" ++ show i
refKey (S.Named n []) = n
refKey (S.Named n args) = n ++ concat [" (" ++ refKey a ++ ")" | a <- args]

typeKeyOf :: C.Type -> Either String Expr
typeKeyOf = Right . Str . scalarTypeKey

-- | A scalar literal.
literal :: Expr -> Scalar -> Expr
literal symbols s = case s of
  SInteger _ n -> valueCall "Int" [BigLit n]
  SCharacter _ n -> valueCall "Int" [BigLit (toInteger n)]
  SBool b -> bool b
  SDecimal c e -> call "Scalar" "decimalOf" [Str (show c), IntLit e]
  SRational n d -> call "Scalar" "rationalOf" [Str (show n), Str (show d)]
  SFloat t bits -> call "Scalar" "floatBits" [IntLit (if t == "Float32" then 32 else 64), Str bits]
  SComplex t r i -> valueCall "Complex" [IntLit (if t == "Complex64" then 32 else 64), literal symbols r, literal symbols i]
  -- Text is a string literal; a sequence that is not Unicode scalar values
  -- keeps its units, and the runtime rejects it.
  SSequence "Text" units
    | all (\u -> u >= 0 && u <= 0x10FFFF && (u < 0xD800 || u > 0xDFFF)) units -> valueCall "Text" [Str (map toEnum units)]
    | otherwise -> call "Scalar" "textUnits" [ListOf tInt (map (IntLit . toInteger) units)]
  SSequence "Bytes" units -> call "Scalar" "bytesOf" [ListOf tInt (map (IntLit . toInteger) units)]
  SSequence kind units -> call "Scalar" "rawOf" [Str kind, ListOf tInt (map (IntLit . toInteger) units)]
  SSymbol identity description -> call "Scalar" "symbol" [symbols, Str identity, Str description]
  SAbsent "Null" -> Raw "Value.Null" "V.Null"
  SAbsent "Undefined" -> Raw "Value.Undefined" "V.Undefined"
  SAbsent _ -> Raw "Value.Unit" "V.Unit"
  SPresent kind Nothing -> call "Runtime" "absent" [Str kind]
  SPresent kind (Just v) -> call "Runtime" "present" [Str kind, literal symbols v]

-- | A checked Core value, as a boundary or example case writes it.
value :: Expr -> V.Value -> Expr
value symbols v = case v of
  V.ScalarValue s -> literal symbols s
  V.DataValue _ (C.Id "List::Nil") [] -> valueCall "List" [ListOf tValue []]
  V.DataValue _ (C.Id "List::Cons") _ -> valueCall "List" [ListOf tValue (map (value symbols) (items v))]
  V.DataValue _ tag fields -> valueCall "Data" [Str (C.idText tag), ListOf tValue (map (value symbols) fields)]
  V.PresenceValue (C.Constructor n _) Nothing -> call "Runtime" "absent" [Str n]
  V.PresenceValue (C.Constructor n _) (Just x) -> call "Runtime" "present" [Str n, value symbols x]
  V.PresenceValue _ _ -> Raw "failwith \"presence\"" "throw new System.InvalidOperationException()"
  where
    items (V.DataValue _ (C.Id "List::Cons") [h, t]) = h : items t
    items _ = []

-- | An expression of a law or definition.
render :: Context -> C.Expr -> Either String Expr
render context root = evalStateT (go context root) 0
  where
    fresh :: String -> StateT Int (Either String) String
    fresh prefix = do
      n <- get
      put (n + 1)
      pure (prefix ++ show n)
    external ctx term args = lift (contextExternal ctx ctx term args)
    binders = nubBy (\a b -> C.binderId a == C.binderId b) [binder | term <- terms root, binder <- case C.expressionNode term of
      C.AllElements _ b _ -> [b]
      C.AllPayloads _ ps -> map fst ps
      C.Match _ cs -> concatMap C.caseBinders cs
      C.Let b _ _ -> [b]
      _ -> []]
    ids = map C.binderId binders
    terms term = term : concatMap terms (C.children term)
    occupied = [contextLocal context identity | term <- terms root, C.Local identity <- [C.expressionNode term], identity `notElem` ids]
    -- Binders inside an expression keep their source names, clear of the
    -- names around them; shadowing between them is undone when printed.
    -- Each binder has its own name, so no binder hides another the
    -- expression still reads.
    bindings = zip ids (fst (claimAll (scopeWith (occupied ++ reservedLocals)) [sourceLocal (C.binderName b) | b <- binders]))
    local identity = maybe (contextLocal context identity) id (lookup identity bindings)
    go ctx term
      | Just (fields, binders, body) <- C.concurrentGroup term = do
          steps <- mapM (go ctx) fields
          inner <- go ctx body
          results <- fresh "results"
          pure (Let results tValues (call "Runtime" "concurrently" [ListOf (tFun [] tValue) [Lambda [] tValue s | s <- steps]])
            (foldr (\(i, b) rest -> Let (local (C.binderId b)) tValue (call "Runtime" "item" [IntLit i, Var results]) rest)
              inner (zip [0 ..] binders)))
    go ctx term = case C.expressionNode term of
      C.Constant scalar -> checked ctx (C.expressionType term) (literal (contextSymbols ctx) scalar)
      C.Local identity -> pure (Var (local identity))
      -- A list written out is one list value, as the runtime builds a
      -- cons onto a list (Schema.construct).
      C.Construct (C.Id "List::Cons") _ | Just items <- listItems term -> do
        values <- mapM (go ctx) items
        pure (valueCall "List" [ListOf tValue values])
      C.Construct tag args -> do
        values <- mapM (go ctx) args
        ref <- lift (contextType ctx (C.expressionType term))
        pure (call "Schema" "construct" [Str (C.idText tag), ListOf tValue values, ref, contextSchema ctx])
      C.Match scrutinee branches -> do
        subject <- go ctx scrutinee
        name <- fresh "matched"
        cases <- mapM (branch ctx (Var name)) branches
        pure (Let name tValue subject (foldr (\(tag, body) rest ->
          If (call "Runtime" "hasTag" [Str tag, Var name]) tValue body rest)
          (call "Runtime" "noMatch" [Var name]) cases))
      C.Let binder bound body -> do
        argument <- go ctx bound
        inner <- go ctx body
        pure (Let (local (C.binderId binder)) tValue argument inner)
      C.AllElements subject binder predicate -> do
        argument <- go ctx subject
        body <- go ctx predicate
        pure (call "Runtime" "allElements" [argument, Lambda [(local (C.binderId binder), tValue)] tValue body])
      C.AllPayloads subject predicates -> do
        argument <- go ctx subject
        ref <- lift (contextType ctx (C.expressionType subject))
        callbacks <- mapM (\(b, p) -> Lambda [(local (C.binderId b), tValue)] tValue <$> go ctx p) predicates
        pure (call "Runtime" "allPayloads" [argument, ref, ListOf (tFun [tValue] tValue) callbacks, contextSchema ctx])
      C.ExternalCall _ args -> mapM (go ctx) args >>= external ctx term
      C.Perform _ args -> mapM (go ctx) args >>= external ctx term
      C.Handle (C.WithHandler _ _) body -> do
        name <- fresh "handled"
        rendered <- go ctx { contextSchema = Var name } body
        external ctx term [Lambda [(name, tSchema)] tValue rendered]
      C.Handle (C.CatchFailure _) body -> do
        rendered <- go ctx body
        external ctx term [Lambda [] tValue rendered]
      C.Calls _ args -> mapM (go ctx) (maybe [] id args) >>= external ctx term
      C.Convert mode ty source -> do
        v <- go ctx source
        case mode of
          C.CheckedArgument | ty == C.expressionType source -> checked ctx ty v
          -- A checked numeric bridge also changes the portable representation
          -- (for example Int to Decimal), before validating its destination.
          -- Core admits differing types here only for exact numeric operands.
          C.CheckedArgument -> do
            ref <- lift (contextType ctx ty)
            checked ctx ty (call "Scalar" "convert" [v, ref, IntLit (toInteger (contextBits ctx))])
          C.Explicit -> do
            ref <- lift (contextType ctx ty)
            pure (call "Scalar" "convert" [v, ref, IntLit (toInteger (contextBits ctx))])
      C.If condition yes no -> do
        c <- go ctx condition
        a <- go ctx yes
        b <- go ctx no
        pure (If (truth c) tValue a b)
      C.ShortCircuit op a b -> do
        x <- go ctx a
        y <- go ctx b
        pure (if op == C.And then If (truth x) tValue y (bool False) else If (truth x) tValue (bool True) y)
      C.Unary C.Not a -> (\v -> call "Runtime" "not" [v]) <$> go ctx a
      C.Unary C.Negate a -> (\v -> call "Scalar" "negate" [v]) <$> go ctx a
      C.Binary op _ a b -> do
        left <- go ctx a
        right <- go ctx b
        ta <- lift (contextKey ctx (C.expressionType a))
        tb <- lift (contextKey ctx (C.expressionType b))
        pure (call "Scalar" "binary" [Str (C.binaryName op), left, right, ta, tb])
      C.Helper C.Concurrently [arg] -> go ctx arg
      C.Helper C.Recorded [keyValue, recordedValue] -> do
        name <- go ctx keyValue
        argument <- go ctx recordedValue
        ref <- lift (contextType ctx (C.expressionType recordedValue))
        pure (call "Runtime" "recorded" [name, argument, ref, contextSchema ctx])
      C.Helper builtin args -> do
        values <- mapM (go ctx) args
        types <- lift (mapM (contextKey ctx . C.expressionType) args)
        pure (call "Runtime" "helper" [Str (C.builtinName builtin), ListOf tValue values, ListOf tString types,
          IntLit (toInteger (contextBits ctx))])
      _ -> lift $ Left ("no .NET rendering for " ++ take 80 (show (C.expressionNode term)))
    listItems t = case C.expressionNode t of
      C.Construct (C.Id "List::Nil") [] -> Just []
      C.Construct (C.Id "List::Cons") [h, rest] -> (h :) <$> listItems rest
      _ -> Nothing
    checked ctx ty v = do
      ref <- lift (contextType ctx ty)
      pure (call "Schema" "validate" [v, ref, contextSchema ctx])
    branch ctx subject c = do
      body <- go ctx (C.caseBody c)
      let binders = C.caseBinders c
          bound = foldr (\(i, b) rest -> Let (local (C.binderId b)) tValue (call "Runtime" "field" [subject, IntLit i]) rest)
            body (zip [0 ..] binders)
      pure (C.idText (C.caseConstructor c), bound)

-- | A source binder's name as an expression local. Both languages' keywords
-- are escaped, since one expression is printed as F# and as C#.
sourceLocal :: String -> String
sourceLocal n = let l = localName FSharp n in if l `elem` keywords CSharp then l ++ "_" else l

-- | Names the code around an expression uses for its own values.
reservedLocals :: [String]
reservedLocals = ["schema", "symbols", "inputs", "values", "resources", "result", "scoped", "generation", "generator", "withResources", "receiver"]

-- | A proposition as a portable boolean, without failing.
proposition :: (C.Expr -> Either String Expr) -> C.Proposition -> Either String Expr
proposition = propositionWith (\a b -> valueCall "Bool" [call "Scalar" "equal" [a, b]])

-- | A proposition that fails with both sides of an equation that does not hold.
assertion :: String -> (C.Expr -> Either String Expr) -> C.Proposition -> Either String Expr
assertion label = propositionWith (\a b -> call "Runtime" "assertEqual" [a, b, Str label])

propositionWith :: (Expr -> Expr -> Expr) -> (C.Expr -> Either String Expr) -> C.Proposition -> Either String Expr
propositionWith equal renderer p = case p of
  C.Equation _ a b -> equal <$> renderer a <*> renderer b
  C.Implication c inner -> do
    condition <- renderer c
    body <- propositionWith equal renderer inner
    pure (If (truth condition) tValue body (bool True))
  C.Conjunction ps -> do
    parts <- mapM (propositionWith equal renderer) ps
    pure (foldr (\a rest -> If (truth a) tValue rest (bool False)) (bool True) parts)
  C.Quantified _ _ _ -> Left "a scoped proposition requires complete search planning before native emission"
  C.Negation _ -> Left "proposition negation requires execution planning before native emission"
  where _ = intercalate
