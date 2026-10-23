-- | Core expressions as Swift code over the LawSpec runtime. All shared
-- semantics go through the runtime; this module never reads source syntax.
-- ref:DEC-typed-core-boundary ref:DEC-swift-runtime-from-scratch
module LawSpec.Swift.Expr
  ( Context(..), render, proposition, assertion, literal, value, typeRef, typeOfKey, typeKeyOf, valueCall
  , truth, bool, schemaVar, symbolsVar
  ) where

import qualified LawSpec.Core as C
import qualified LawSpec.Core.Schema as S
import qualified LawSpec.Core.Value as V
import LawSpec.Swift.Code
import LawSpec.Backend (scalarTypeKey)
import LawSpec.Scalar (Scalar(..))
import Control.Monad.State.Strict (StateT, evalStateT, get, put, lift)
import LawSpec.Naming (Scope, claim, claimAll, scopeWith)
import LawSpec.Swift.Names (localName, reservedLocals)

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

-- | A portable value made by one of its cases.
valueCall :: String -> [Expr] -> Expr
valueCall name = Pure ("Value." ++ name)

bool :: Bool -> Expr
bool b = valueCall "bool" [BoolLit b]

-- | A portable boolean as a Swift Bool.
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

ints :: [Int] -> Expr
ints = ListOf (Ty "[Int]") . map (IntLit . toInteger)

-- | A scalar literal.
literal :: Expr -> Scalar -> Expr
literal symbols s = case s of
  SInteger _ n -> valueCall "int" [BigLit n]
  SCharacter _ n -> valueCall "int" [BigLit (toInteger n)]
  SBool b -> bool b
  SDecimal c e -> call "Scalar" "decimalOf" [Str (show c), IntLit e]
  SRational n d -> call "Scalar" "rationalOf" [Str (show n), Str (show d)]
  SFloat t bits -> call "Scalar" "floatBits" [IntLit (if t == "Float32" then 32 else 64), Str bits]
  SComplex t r i -> pure' "Scalar" "complexOf" [IntLit (if t == "Complex64" then 32 else 64), literal symbols r, literal symbols i]
  -- Text is a native string literal; a unit no Swift string can hold (a
  -- surrogate) keeps the runtime's check.
  SSequence "Text" units
    | all scalarValue units -> valueCall "text" [Str (map toEnum units)]
    | otherwise -> call "Scalar" "textUnits" [ints units]
  SSequence "Bytes" units -> call "Scalar" "bytesOf" [ints units]
  SSequence kind units -> call "Scalar" "rawOf" [Str kind, ints units]
  SSymbol identity description -> pure' "Scalar" "symbol" [symbols, Str identity, Str description]
  SAbsent "Null" -> Raw "Value.null"
  SAbsent "Undefined" -> Raw "Value.undefined"
  SAbsent _ -> Raw "Value.unit"
  SPresent kind Nothing -> pure' "Runtime" "absent" [Str kind]
  SPresent kind (Just v) -> pure' "Runtime" "present" [Str kind, literal symbols v]

scalarValue :: Int -> Bool
scalarValue n = n >= 0 && n <= 0x10FFFF && (n < 0xD800 || n > 0xDFFF)

-- | A checked Core value, as a boundary or example case writes it.
value :: Expr -> V.Value -> Expr
value symbols v = case v of
  V.ScalarValue s -> literal symbols s
  V.DataValue _ (C.Id "List::Nil") [] -> valueCall "list" [ListOf tValues []]
  V.DataValue _ (C.Id "List::Cons") _ -> valueCall "list" [ListOf tValues (map (value symbols) (items v))]
  V.DataValue _ tag fields -> valueCall "data" [Str (C.idText tag), ListOf tValues (map (value symbols) fields)]
  V.PresenceValue (C.Constructor n _) Nothing -> pure' "Runtime" "absent" [Str n]
  V.PresenceValue (C.Constructor n _) (Just x) -> pure' "Runtime" "present" [Str n, value symbols x]
  V.PresenceValue _ _ -> call "Runtime" "noMatch" [Raw "Value.unit"]
  where
    items (V.DataValue _ (C.Id "List::Cons") [h, t]) = h : items t
    items _ = []

-- | An expression of a law or definition.
render :: Context -> C.Expr -> Either String Expr
render context root = evalStateT (go context root) scope0
  where
    -- Values the code makes (a matched value, a handled body's schema)
    -- are named by what they hold, clear of every other name.
    fresh :: String -> StateT Scope (Either String) String
    fresh prefix = do
      scope <- get
      let (name, scope') = claim scope prefix
      put scope'
      pure name
    external ctx term args = lift (contextExternal ctx ctx term args)
    binders = nubOn C.binderId [binder | term <- terms root, binder <- case C.expressionNode term of
      C.AllElements _ b _ -> [b]
      C.AllPayloads _ ps -> map fst ps
      C.Match _ cs -> concatMap C.caseBinders cs
      C.Let b _ _ -> [b]
      _ -> []]
    ids = map C.binderId binders
    nubOn f = foldr (\x rest -> x : filter ((/= f x) . f) rest) []
    terms term = term : concatMap terms (C.children term)
    occupied = [contextLocal context identity | term <- terms root, C.Local identity <- [C.expressionNode term], identity `notElem` ids]
    -- Binders keep their source names.
    (bound, scope0) = claimAll (scopeWith (reservedLocals ++ occupied)) [localName (C.binderName b) | b <- binders]
    bindings = zip ids bound
    local identity = maybe (contextLocal context identity) id (lookup identity bindings)
    go ctx term
      | Just (fields, binders, body) <- C.concurrentGroup term = do
          steps <- mapM (go ctx) fields
          inner <- go ctx body
          results <- fresh "results"
          pure (Let results tValues (call "Runtime" "concurrently" [ListOf (Ty "[() throws -> Value]") [Lambda [] tValue s | s <- steps]])
            (foldr (\(i, b) rest -> Let (local (C.binderId b)) tValue (pure' "Runtime" "item" [IntLit i, Var results]) rest)
              inner (zip [0 ..] binders)))
    go ctx term = case C.expressionNode term of
      C.Constant scalar -> checked ctx (C.expressionType term) (literal (contextSymbols ctx) scalar)
      C.Local identity -> pure (Var (local identity))
      C.Construct tag args -> do
        values <- mapM (go ctx) args
        ref <- lift (contextType ctx (C.expressionType term))
        pure (call "Schema" "construct" [Str (C.idText tag), ListOf tValues values, ref, contextSchema ctx])
      C.Match scrutinee branches -> do
        subject <- go ctx scrutinee
        name <- fresh "matched"
        cases <- mapM (branch ctx (Var name)) branches
        pure (Let name tValue subject (foldr (\(tag, body) rest ->
          If (pure' "Runtime" "hasTag" [Str tag, Var name]) tValue body rest)
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
        pure (call "Runtime" "allPayloads" [argument, ref, ListOf (Ty "[(Value) throws -> Value]") callbacks, contextSchema ctx])
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
          -- A differing exact numeric type needs its destination representation
          -- before validation. Core excludes nominal/product conversions here.
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
        pure (call "Runtime" "helper" [Str (C.builtinName builtin), ListOf tValues values, ListOf (Ty "[String]") types,
          IntLit (toInteger (contextBits ctx))])
      _ -> lift $ Left ("no Swift rendering for " ++ take 80 (show (C.expressionNode term)))
    checked ctx ty v = do
      ref <- lift (contextType ctx ty)
      pure (call "Schema" "validate" [v, ref, contextSchema ctx])
    branch ctx subject c = do
      body <- go ctx (C.caseBody c)
      let binders = C.caseBinders c
          bound = foldr (\(i, b) rest -> Let (local (C.binderId b)) tValue (call "Runtime" "field" [subject, IntLit i]) rest)
            body (zip [0 ..] binders)
      pure (C.idText (C.caseConstructor c), bound)

-- | A proposition as a portable boolean, without failing.
proposition :: (C.Expr -> Either String Expr) -> C.Proposition -> Either String Expr
proposition = propositionWith (\a b -> valueCall "bool" [pure' "Scalar" "equal" [a, b]])

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
