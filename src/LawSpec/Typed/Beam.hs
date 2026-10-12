-- | Typed BEAM code for checked definitions (see LawSpec.Typed.Plan), in
-- src/lawspec_typed.erl, shared by Erlang, Elixir and Gleam: a function per
-- class of typed definitions over each language's own native data, so a
-- typed definition converts nothing at its boundary but KeyVal and Set. Data
-- are the target's tuples (Erlang, Gleam) or structs (Elixir); Maybe, Either
-- and Unit are the target's own; integers are Erlang's, checked where a type
-- bounds them; Text is UTF-8, indexed by code point. KeyVal is a map and Set
-- a version 2 set, whose entries and items come out in the portable order
-- (Erlang's term order where it is the same, a generated comparison where
-- it is not). Raise and attempt throw and catch the dynamic code's failures,
-- so both paths fail alike; a definition that performs another ability's
-- operation takes the handler context (the schema and the symbols) first.
-- Self tail calls are Erlang's own tail calls. Names are stable: each
-- function is named for its definition and a digest of its identity, each
-- conversion and comparison for a digest of its type.
-- ref:DEC-typed-native-definitions
module LawSpec.Typed.Beam
  ( BeamTyped(..), Crossing(..), emitBeamTyped, beamTypedDeclarations
  ) where

import Control.Monad (forM, forM_, unless, when)
import Control.Monad.State.Strict
import Data.Char (isAlphaNum, isAscii, isUpper, toUpper)
import Data.List (intercalate, isPrefixOf, sortOn, nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S
import LawSpec.Collections (collectionsUnit)
import LawSpec.Core
import LawSpec.Scalar (Scalar(..))
import LawSpec.Typed.Plan
import LawSpec.Digest (digestHex, digestString)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E

-- | The conversions of a typed value: from and to the dynamic values the
-- laws use, and from and to the target's native values.
data Crossing = FromDynamic | ToDynamic | FromNative | ToNative | Ordered
  deriving (Eq, Ord, Show)

data BeamTyped = BeamTyped
  { beamTypedSource :: Maybe String
    -- The typed function of a typed definition, in lawspec_typed.
  , beamTypedFunction :: Id -> Maybe String
    -- Whether a typed definition takes the handler context.
  , beamTypedContextual :: Id -> Bool
    -- The function giving a typed handler's start state, in lawspec_typed.
  , beamTypedStart :: Id -> Maybe String
    -- A conversion of a value of a type the boundary uses, as an expression.
  , beamTypedConvert :: Crossing -> Type -> D.Doc -> D.Doc
    -- The pattern of a typed Pair (first, second).
  , beamTypedPair :: D.Doc -> D.Doc -> D.Doc
  , beamTypedPlan :: TypedPlan
  }

-- | The declarations whose native BEAM form is their typed form: not one
-- an application's binding gives its own representation.
beamTypedDeclarations :: [Id] -> [DataDeclaration] -> [DataDeclaration]
beamTypedDeclarations bound declarations = [ d | d <- declarations, dataId d `notElem` bound ]

data Env = Env
  { envTarget :: String
  , envPlan :: TypedPlan
  , envNames :: [(Id, String)]
  , envAll :: M.Map String DataDeclaration
  , envConstructors :: M.Map Id (DataDeclaration, DataConstructor)
  , envFunctions :: M.Map Int String
  }

data St = St
  { stCounter :: Int
  , stWanted :: M.Map String (Crossing, Type)
  , stOrdering :: Bool
    -- The handler context a function's body uses (LsSchema, LsSymbols).
  , stContext :: S.Set String
  }

type M = StateT St (Either String)

lift' :: Either String a -> M a
lift' = lift

failWith :: String -> M a
failWith message = lift' (Left ("typed BEAM: " ++ message))

-- | A fresh Erlang variable: capitalized, unique in its module.
fresh :: String -> M String
fresh base = do
  s <- get
  put s { stCounter = stCounter s + 1 }
  pure (variable base ++ "_" ++ show (stCounter s))

variable :: String -> String
variable name = case [c | c <- name, isAscii c && (isAlphaNum c || c == '_')] of
  c : cs | isUpper c -> c : cs
  c : cs | c >= 'a' && c <= 'z' -> toUpper c : cs
  cs -> "V" ++ cs

emitBeamTyped :: String -> [Id] -> [DataDeclaration] -> [Unit] -> Either String BeamTyped
emitBeamTyped target bound allDeclarations units = do
  names <- E.dataNames allDeclarations
  let declarations = beamTypedDeclarations bound allDeclarations
      plan = typedPlanPerforming scalarTypes declarations units
      functions = M.fromList [ (c, functionName d) | (c, d) <- typedRepresentatives plan ]
      env = Env target plan names (M.fromList [(idText (dataId d), d) | d <- allDeclarations])
        (M.fromList [(constructorId c, (d, c)) | d <- allDeclarations, c <- dataConstructors d]) functions
      typedHandlers = [ h | u <- units, h <- unitHandlers u, isTypedHandler plan h ]
      starts = [ (handlerId h, "start_" ++ stableSuffix (handlerId h), start) | h <- typedHandlers, Just (_, start) <- [handlerState h] ]
      -- Every type a boundary converts: typed definitions' arguments and
      -- results, typed handlers' states, operations and failures.
      boundary = nub $
        [ t | d <- M.elems (typedDefinitions plan), let (args, result) = functionType (declarationType (definitionDeclaration d)), t <- result : args ] ++
        [ t | h <- typedHandlers, Just (t, _) <- [handlerState h] ] ++
        [ t | h <- typedHandlers, ref <- handlerAbilities h, Just (_, a) <- [findAbility units ref]
            , (op, ty) <- abilityOperations a, let (args, result) = functionType ty
            , t <- result : args ++ [f | Just (AbilityRef _ [f]) <- [lookup op (abilityFailures a)]] ]
      conversions = [FromDynamic, ToDynamic, FromNative, ToNative]
  (docs, st) <- flip runStateT (St 0 M.empty False S.empty) $ do
    forM_ [ (k, t) | t <- boundary, supportedType plan t, k <- conversions ] $ \(k, t) ->
      unless (identity env k t) (() <$ helperName env k t)
    fs <- mapM (\(c, d) -> functionDoc env c d) (typedRepresentatives plan)
    ss <- forM starts $ \(_, name, start) -> do
      modify (\st -> st { stContext = S.empty })
      body <- cstmt env [] start
      used <- gets stContext
      let schema = if "LsSchema" `S.member` used then "LsSchema" else "_LsSchema"
          symbols = if "LsSymbols" `S.member` used then "LsSymbols" else "_LsSymbols"
      pure (D.text "%% A typed handler's start state." <> D.hardline <>
        functionHead name [schema, symbols] body)
    hs <- helpers env S.empty
    ordering <- gets stOrdering
    os <- if ordering then pure <$> orderingDoc env else pure []
    pure (fs ++ ss ++ hs ++ os)
  let helperNames = [ (n, 1) | (n, (k, _)) <- M.toList (stWanted st), k /= Ordered ]
      exports = [ (name, arity d) | (c, d) <- typedRepresentatives plan, Just name <- [M.lookup c functions] ] ++
        [ (name, 2) | (_, name, _) <- starts ] ++ helperNames
      arity d = length (definitionArguments d) + (if isContextual plan (declarationId (definitionDeclaration d)) then 2 else 0)
      wanted = stWanted st
      source = D.render (D.Pretty 100) (
        D.text "%% Generated by LawSpec. Do not edit." <> D.hardline <>
        D.text "%% Typed checked definitions over the program's native BEAM values. Each is" <> D.hardline <>
        D.text "%% named for its definition; see docs/how-to/embed-a-generated-model.md." <> D.hardline <>
        D.text "-module(lawspec_typed)." <> D.hardline <>
        D.text "-export(" <> E.array [E.atom n <> D.text ("/" ++ show a) | (n, a) <- exports] <> D.text ")." <> D.hardline <> D.hardline <>
        D.joinWith (D.hardline <> D.hardline) docs) ++ "\n"
  pure BeamTyped
    { beamTypedSource = if null docs then Nothing else Just source
    , beamTypedFunction = \i -> definitionClass plan i >>= (`M.lookup` functions)
    , beamTypedContextual = isContextual plan
    , beamTypedStart = \h -> case [n | (i, n, _) <- starts, i == h] of
        n : _ -> Just n
        [] -> Nothing
    , beamTypedConvert = \k t x ->
        if identity env k t then x
        else let n = conversionName k t
             in if M.member n wanted then E.remote "lawspec_typed" n [x]
                else E.remote "erlang" "error" [E.tuple [E.atom "lawspec", E.tuple [E.atom "untyped_conversion", E.binary (show t)]]]
    , beamTypedPair = \a b -> case pairConstructor env of
        Just (d, c) -> conPattern env d c [a, b]
        Nothing -> E.tuple [E.atom "pair", a, b]
    , beamTypedPlan = plan }
  where
    functionName d = E.snake (shortName (declarationName (definitionDeclaration d))) ++ "_" ++ stableSuffix (declarationId (definitionDeclaration d))
    shortName name =
      let unprefixed = if "lawspec_" `isPrefixOf` name then drop 8 name else name
      in reverse (dropHash (reverse unprefixed))
    dropHash reversed = case span (`elem` ("0123456789abcdef" :: String)) reversed of
      (digits@(_ : _), '_' : rest) | length digits >= 8 -> rest
      _ -> reversed

functionHead :: String -> [String] -> [D.Doc] -> D.Doc
functionHead name params body =
  E.atom name <> D.text ("(" ++ intercalate ", " params ++ ") ->") <> sequenceBlock body <> D.text "."

-- | Expressions in sequence, each on its own line, indented.
sequenceBlock :: [D.Doc] -> D.Doc
sequenceBlock body = D.nest 4 (D.hardline <> D.joinWith (D.text "," <> D.hardline) body)

-- | case Subject of Pattern -> Body; ... end
caseDoc :: D.Doc -> [(D.Doc, [D.Doc])] -> D.Doc
caseDoc subject arms = D.text "case " <> subject <> D.text " of" <>
  D.nest 4 (D.hardline <> D.joinWith (D.text ";" <> D.hardline) [p <> D.text " ->" <> sequenceBlock b | (p, b) <- arms]) <>
  D.hardline <> D.text "end"

type Scope = [(Id, String)]

functionDoc :: Env -> Int -> Definition -> M D.Doc
functionDoc env c d = do
  let declaration = definitionDeclaration d
      name = envFunctions env M.! c
      contextual = isContextual (envPlan env) (declarationId declaration)
      body' = definitionBody d
      free = freeBinders body'
  modify (\st -> st { stContext = S.empty })
  params <- forM (definitionArguments d) $ \b -> do
    local <- fresh (binderName b)
    pure (binderId b, local)
  body <- case M.lookup (declarationId declaration) (typedIntrinsics (envPlan env)) of
    Just intrinsic -> do
      (s, x) <- intrinsicCall env intrinsic [(D.text l, binderType b) | ((_, l), b) <- zip params (definitionArguments d)]
      pure (s ++ [x])
    Nothing -> cstmt env params body'
  used <- gets stContext
  let intrinsic = M.member (declarationId declaration) (typedIntrinsics (envPlan env))
      shown (i, l) = if intrinsic || i `elem` free then l else "_" ++ l
      context n = if n `S.member` used then n else "_" ++ n
  pure (D.text ("%% " ++ idText (declarationId declaration)) <> D.hardline <>
    functionHead name ([context "LsSchema" | contextual] ++ [context "LsSymbols" | contextual] ++ map shown params) body)

-- | Expressions in sequence whose last is the value.
cstmt :: Env -> Scope -> Expr -> M [D.Doc]
cstmt env scope e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    local <- fresh (binderName binder)
    rest <- cstmt env ((binderId binder, local) : scope) body
    pure (s ++ [letLine binder body local x value] ++ rest)
  If c a b -> do
    (s, x) <- cexpr env scope c
    yes <- cstmt env scope a
    no <- cstmt env scope b
    pure (s ++ [caseDoc x [(D.text "true", yes), (D.text "false", no)]])
  Helper Select [c, a, b] -> cstmt env scope (e { expressionNode = If c a b })
  Match value cases -> matchStatements env scope value cases
  -- A call in tail position stays one, so a self-recursive definition loops.
  ExternalCall i args | M.notMember i (typedIntrinsics (envPlan env)) -> do
    (s, call) <- callOf env scope i args
    pure (s ++ [call])
  _ -> do
    (s, x) <- cexpr env scope e
    pure (s ++ [x])

-- | A let's binding, or, when its body never reads it, its value discarded.
letLine :: Binder -> Expr -> String -> D.Doc -> Expr -> D.Doc
letLine binder body local x value
  | binderId binder `elem` freeBinders body = D.text (local ++ " = ") <> x
  | otherwise = case expressionNode value of
      Local _ -> D.text ("_" ++ local ++ " = ") <> x
      Constant _ -> D.text ("_" ++ local ++ " = ") <> x
      _ -> discarded x

callOf :: Env -> Scope -> Id -> [Expr] -> M ([D.Doc], D.Doc)
callOf env scope i args = do
  c <- maybe (failWith ("untyped callee " ++ idText i)) pure (definitionClass (envPlan env) i)
  parts <- mapM (cexpr env scope) args
  let context = if isContextual (envPlan env) i then [D.text "LsSchema", D.text "LsSymbols"] else []
  when (isContextual (envPlan env) i) (usesContext ["LsSchema", "LsSymbols"])
  pure (concatMap fst parts, E.call (envFunctions env M.! c) (context ++ map snd parts))

usesContext :: [String] -> M ()
usesContext names = modify (\st -> st { stContext = S.union (stContext st) (S.fromList names) })

-- | A value bound to nothing is still computed, as the dynamic code does,
-- and handed to a function, so the compiler sees it used.
discarded :: D.Doc -> D.Doc
discarded x = E.remote "lawspec_beam_fast" "discard" [x]

-- | An expression's value: the expressions that come first, and the value.
cexpr :: Env -> Scope -> Expr -> M ([D.Doc], D.Doc)
cexpr env scope e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    local <- fresh (binderName binder)
    (rest, v) <- cexpr env ((binderId binder, local) : scope) body
    pure (s ++ [letLine binder body local x value] ++ rest, v)
  Match {} -> viaStatements
  If {} -> viaStatements
  Helper Select _ -> viaStatements
  Constant s -> (,) [] <$> constant env s
  Local i -> do
    name <- maybe (failWith ("unbound local " ++ idText i)) pure (lookup i scope)
    pure ([], D.text name)
  Construct tag args -> do
    parts <- mapM (cexpr env scope) args
    x <- construct env (expressionType e) tag (map snd parts)
    pure (concatMap fst parts, x)
  ExternalCall i args
    | Just intrinsic <- M.lookup i (typedIntrinsics (envPlan env)) -> do
        parts <- mapM (cexpr env scope) args
        (s, x) <- intrinsicCall env intrinsic (zip (map snd parts) (map expressionType args))
        pure (concatMap fst parts ++ s, x)
    | isContextual (envPlan env) i -> do
        -- A call that performs is bound first, so effects keep their order.
        (s, call) <- callOf env scope i args
        bind s call
    | otherwise -> callOf env scope i args
  ShortCircuit op a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    if null sb
      then pure (sa, D.text "(" <> xa <> D.text (if op == And then " andalso " else " orelse ") <> xb <> D.text ")")
      else do
        t <- fresh "Logic"
        let rest = sb ++ [xb]
            arms = if op == And then [(D.text "true", rest), (D.text "false", [D.text "false"])]
                   else [(D.text "true", [D.text "true"]), (D.text "false", rest)]
        pure (sa ++ [D.text (t ++ " = ") <> caseDoc xa arms], D.text t)
  Unary Not a -> do
    (s, x) <- cexpr env scope a
    pure (s, D.text "(not " <> x <> D.text ")")
  Unary Negate a -> do
    (s, x) <- cexpr env scope a
    pure (s, narrow (expressionType e) (D.text "(-" <> x <> D.text ")"))
  Binary op (Structural _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    pure (sa ++ sb, D.text "(" <> xa <> D.text (if op == Equal then " =:= " else " =/= ") <> xb <> D.text ")")
  Binary op (Numeric _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    let te = expressionType e
        infix' symbol = D.text "(" <> xa <> D.text symbol <> xb <> D.text ")"
        fast f = E.remote "lawspec_beam_fast" f [xa, xb]
        value = case op of
          Add -> Just (narrow te (infix' " + "))
          Subtract -> Just (narrow te (infix' " - "))
          Multiply -> Just (narrow te (infix' " * "))
          Quotient -> Just (narrow te (fast "quot"))
          Remainder -> Just (narrow te (fast "remainder"))
          Power -> Just (narrow te (fast "power"))
          Equal -> Just (infix' " =:= ")
          NotEqual -> Just (infix' " =/= ")
          Less -> Just (infix' " < ")
          LessEqual -> Just (infix' " =< ")
          Greater -> Just (infix' " > ")
          GreaterEqual -> Just (infix' " >= ")
          _ -> Nothing
    maybe (failWith ("unsupported operator " ++ show op)) (\v -> pure (sa ++ sb, v)) value
  Convert _ target value -> do
    (s, x) <- cexpr env scope value
    pure (s, convertInteger target (expressionType value) x)
  Helper Compare [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    c <- compareCall env (expressionType a) xa xb
    modify (\st -> st { stOrdering = True })
    pure (sa ++ sb, E.call "lawspec_ordering" [c])
  Helper Length [x] -> do
    (s, v) <- cexpr env scope x
    pure (s, case expressionType x of
      Constructor "Text" [] -> E.remote "lawspec_beam_fast" "text_length" [v]
      Constructor "Bytes" [] -> E.call "byte_size" [v]
      _ -> E.call "length" [v])
  Helper Unreachable _ -> pure ([], E.remote "lawspec_beam_fast" "unreachable" [])
  Helper Checked _ -> pure ([], D.text "true")
  Helper StartsWith [a, b] -> call2 "lawspec_beam_fast" "starts_with" a b
  Helper EndsWith [a, b] -> call2 "lawspec_beam_fast" "ends_with" a b
  Helper TextContains [a, b] -> call2 "lawspec_beam_fast" "contains" a b
  Helper RegexMatches [a, b] -> call2 "lawspec_beam_regex" "matches" a b
  AllElements value binder predicate -> do
    (sx, xs) <- cexpr env scope value
    item <- fresh (binderName binder)
    lines' <- cstmt env ((binderId binder, item) : scope) predicate
    let shown = if binderId binder `elem` freeBinders predicate then item else "_" ++ item
    pure (sx, E.remote "lists" "all" [D.text ("fun(" ++ shown ++ ") ->") <> sequenceBlock lines' <> D.hardline <> D.text "end", xs])
  Perform (Operation ref "raise") [x] | isFail ref, Just failure <- failedWith ref -> do
    (s, v) <- cexpr env scope x
    out <- convert env ToDynamic failure v
    pure (s, E.remote "lawspec_beam_effects" "raise_failure" [E.binary (abilityKey ref), out])
  Perform op args -> do
    parts <- mapM (cexpr env scope) args
    values <- forM (zip args parts) $ \(a, (_, v)) -> convert env ToDynamic (expressionType a) v
    usesContext ["LsSchema"]
    let invocation = E.remote "lawspec_beam_effects" "perform" [D.text "LsSchema", E.binary (abilityKey (operationAbility op)),
          E.binary (operationName op), E.array values]
    result <- convert env FromDynamic (expressionType e) invocation
    bind (concatMap fst parts) result
  Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, _] <- expressionType e -> do
    lines' <- cstmt env scope body
    value <- fresh "Value"
    caught <- fresh "Failure"
    back <- convert env FromDynamic failure (D.text caught)
    t <- fresh "Attempted"
    let (left, right) = sides (envTarget env)
    pure ([D.text (t ++ " = try") <> sequenceBlock lines' <> D.hardline <>
      D.text "of" <> D.nest 4 (D.hardline <> D.text (value ++ " -> ") <> E.tuple [E.atom right, D.text value]) <> D.hardline <>
      D.text "catch" <> D.nest 4 (D.hardline <> D.text "throw:" <>
        E.tuple [E.atom "lawspec_failure", E.binary (abilityKey ref), D.text caught] <> D.text " -> " <> E.tuple [E.atom left, back]) <>
      D.hardline <> D.text "end"], D.text t)
  Helper Append [a, b] -> case expressionType a of
    Constructor n [] | n `elem` ["Text", "Bytes"] -> do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, D.text "<<(" <> xa <> D.text ")/binary, (" <> xb <> D.text ")/binary>>")
    _ -> do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, D.text "(" <> xa <> D.text " ++ " <> xb <> D.text ")")
  Helper Slice [x, from, to] -> do
    (sx, v) <- cexpr env scope x
    (si, i) <- cexpr env scope from
    (sj, j) <- cexpr env scope to
    let f = case expressionType x of
          Constructor "Text" [] -> "slice_text"
          Constructor "Bytes" [] -> "slice_bytes"
          _ -> "slice_list"
    pure (sx ++ si ++ sj, E.remote "lawspec_beam_fast" f [v, i, j])
  Helper At [x, k] -> do
    (sx, v) <- cexpr env scope x
    (sk, i) <- cexpr env scope k
    let f = case expressionType x of
          Constructor "Text" [] -> "at_text"
          Constructor "Bytes" [] -> "at_bytes"
          _ -> "at_list"
    item <- fresh "Item"
    t <- fresh "At"
    let (nothing, just) = maybes (envTarget env)
    pure (sx ++ sk ++ [D.text (t ++ " = ") <> caseDoc (E.remote "lawspec_beam_fast" f [v, i])
      [(E.tuple [E.atom "ok", D.text item], [E.tuple [E.atom just, D.text item]]), (E.atom "error", [E.atom nothing])]], D.text t)
  Helper Range [lo, hi] -> call2 "lawspec_beam_fast" "range" lo hi
  Helper Octets [b] -> one "binary_to_list" b
  Helper BytesOf [xs] -> one "list_to_binary" xs
  Helper Utf8 [t] -> cexpr env scope t
  Helper TextOf [n] -> one "integer_to_binary" n
  Helper Join [sep, parts] -> call2 "lawspec_beam_fast" "join" sep parts
  _ -> failWith ("unsupported expression " ++ take 80 (show (expressionNode e)))
  where
    one f a = do
      (s, x) <- cexpr env scope a
      pure (s, E.call f [x])
    call2 m f a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, E.remote m f [xa, xb])
    viaStatements = do
      lines' <- cstmt env scope e
      case reverse lines' of
        [] -> failWith "an empty sequence"
        lastLine : rest -> bind (reverse rest) lastLine
    bind s x = do
      t <- fresh "Value"
      pure (s ++ [D.text (t ++ " = ") <> x], D.text t)

-- | Nothing and Just, by name.
maybes :: String -> (String, String)
maybes "gleam" = ("none", "some")
maybes _ = ("nothing", "just")

-- | Left and Right, by name.
sides :: String -> (String, String)
sides "gleam" = ("error", "ok")
sides _ = ("left", "right")

unitAtom :: String -> String
unitAtom "gleam" = "nil"
unitAtom _ = "ok"

boundedTypes :: [String]
boundedTypes = ["Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64"]

boundsOf :: String -> Maybe (Integer, Integer)
boundsOf t = lookup t
  [ ("Int8", (-128, 127)), ("Int16", (-32768, 32767)), ("Int32", (-2147483648, 2147483647))
  , ("Int64", (-(2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1)), ("UInt8", (0, 255)), ("UInt16", (0, 65535))
  , ("UInt32", (0, 4294967295)), ("UInt64", (0, 2 ^ (64 :: Int) - 1)) ]

-- | An integer into a bounded type, checked.
narrow :: Type -> D.Doc -> D.Doc
narrow ty x = case ty of
  Constructor t [] | t `elem` boundedTypes -> E.remote "lawspec_beam_fast" (checkedName t) [x]
  _ -> x

checkedName :: String -> String
checkedName t = case t of
  "Int8" -> "int8"; "Int16" -> "int16"; "Int32" -> "int32"; "Int64" -> "int64"
  "UInt8" -> "uint8"; "UInt16" -> "uint16"; "UInt32" -> "uint32"; _ -> "uint64"

-- | A conversion between integer types checks only what may not fit.
convertInteger :: Type -> Type -> D.Doc -> D.Doc
convertInteger target source x = case target of
  Constructor t [] | Just (lo, hi) <- boundsOf t ->
    let inside = case source of
          Constructor n [] | Just (slo, shi) <- boundsOf n -> slo >= lo && shi <= hi
          _ -> False
    in if inside then x else narrow target x
  _ -> x

constant :: Env -> Scalar -> M D.Doc
constant env s = case s of
  SBool b -> pure (D.text (if b then "true" else "false"))
  SAbsent "Unit" -> pure (E.atom (unitAtom (envTarget env)))
  SInteger _ n -> pure (D.text (show n))
  SSequence "Text" units -> pure (E.binary (map toEnum (map fromIntegral units)))
  SSequence "Bytes" units -> pure (D.text ("<<" ++ intercalate ", " (map show units) ++ ">>"))
  _ -> failWith ("unsupported constant " ++ show s)

-- | A data constructor's target form, made from its fields.
conConstruct :: Env -> DataDeclaration -> DataConstructor -> [D.Doc] -> D.Doc
conConstruct env d c values = case envTarget env of
  "elixir" -> E.record ((E.atom "__struct__", E.atom ("Elixir." ++ E.elixirDataModule (tagOf env c))) :
    zip (map E.atom (E.elixirFields d c)) values)
  _ -> plainConstructor (nativeTag env c) values

-- | A data constructor's target form, matched.
conPattern :: Env -> DataDeclaration -> DataConstructor -> [D.Doc] -> D.Doc
conPattern env d c values = case envTarget env of
  "elixir" -> D.delimit 4 "#{" "}" [a <> D.text " := " <> b | (a, b) <-
    (E.atom "__struct__", E.atom ("Elixir." ++ E.elixirDataModule (tagOf env c))) : zip (map E.atom (E.elixirFields d c)) values]
  _ -> plainConstructor (nativeTag env c) values

plainConstructor :: String -> [D.Doc] -> D.Doc
plainConstructor tag values = if null values then E.atom tag else E.tuple (E.atom tag : values)

tagOf :: Env -> DataConstructor -> String
tagOf env c = fromMaybe (idText (constructorId c)) (lookup (constructorId c) (envNames env))

nativeTag :: Env -> DataConstructor -> String
nativeTag env c = case envTarget env of
  "gleam" -> E.snake (E.pascal (tagOf env c))
  _ -> tagOf env c

-- | A constructor of a typed data type, a built-in container, or a
-- collection made from its items.
construct :: Env -> Type -> Id -> [D.Doc] -> M D.Doc
construct env ty tag values = case (idText tag, values) of
  ("List::Nil", []) -> pure (D.text "[]")
  ("List::Cons", [h, t]) -> pure (D.text "[" <> h <> D.text " | " <> t <> D.text "]")
  ("Maybe::Nothing", []) -> pure (E.atom (fst (maybes (envTarget env))))
  ("Maybe::Just", [x]) -> pure (E.tuple [E.atom (snd (maybes (envTarget env))), x])
  ("Either::Left", [x]) -> pure (E.tuple [E.atom (fst (sides (envTarget env))), x])
  ("Either::Right", [x]) -> pure (E.tuple [E.atom (snd (sides (envTarget env))), x])
  (_, [items]) | Just ("KeyVal", [k, v]) <- collectionArguments ty -> fromEntries env k v items
  (_, [items]) | Just ("Set", _) <- collectionArguments ty -> pure (E.remote "lawspec_beam_fast" "set_of" [items])
  _ -> case M.lookup tag (envConstructors env) of
    Just (d, c) -> pure (conConstruct env d c values)
    Nothing -> failWith ("unknown constructor " ++ idText tag)

-- | A KeyVal from a list of entries; later entries win.
fromEntries :: Env -> Type -> Type -> D.Doc -> M D.Doc
fromEntries env k v items = do
  (d, c) <- entryConstructor env
  key <- fresh "Key"
  value <- fresh "Value"
  _ <- pure (k, v)
  pure (E.remote "lawspec_beam_fast" "key_val_of" [D.text "[" <> E.tuple [D.text key, D.text value] <>
    D.text " || " <> conPattern env d c [D.text key, D.text value] <> D.text " <- " <> items <> D.text "]"])

collectionDeclaration :: Env -> String -> M (DataDeclaration, DataConstructor)
collectionDeclaration env short = case M.lookup (collectionsUnit ++ "::type::" ++ short) (envAll env) of
  Just d | [c] <- dataConstructors d -> pure (d, c)
  _ -> failWith ("no " ++ short)

entryConstructor :: Env -> M (DataDeclaration, DataConstructor)
entryConstructor env = collectionDeclaration env "Entry"

pairConstructor :: Env -> Maybe (DataDeclaration, DataConstructor)
pairConstructor env = case M.lookup (collectionsUnit ++ "::type::Pair") (envAll env) of
  Just d | [c] <- dataConstructors d -> Just (d, c)
  _ -> Nothing

intrinsicCall :: Env -> Intrinsic -> [(D.Doc, Type)] -> M ([D.Doc], D.Doc)
intrinsicCall env intrinsic args = case (intrinsic, args) of
  (KeyValOf, [(es, Constructor _ [TypeArgument (Constructor _ [TypeArgument k, TypeArgument v])])]) -> (,) [] <$> fromEntries env k v es
  (KeyValOf, [(es, _)]) -> (,) [] <$> fromEntries env (Constructor "Unit" []) (Constructor "Unit" []) es
  (KeyValLookup, [(k, _), (m, _)]) -> do
    found <- fresh "Found"
    t <- fresh "Lookup"
    let (nothing, just) = maybes (envTarget env)
    pure ([D.text (t ++ " = ") <> caseDoc m
      [(D.delimit 4 "#{" "}" [k <> D.text " := " <> D.text found], [E.tuple [E.atom just, D.text found]]), (D.text "_", [E.atom nothing])]], D.text t)
  (KeyValPut, [(k, _), (v, _), (m, _)]) -> plain "maps" "put" [k, v, m]
  (KeyValDelete, [(k, _), (m, _)]) -> plain "maps" "remove" [k, m]
  (KeyValKeys, [(m, ty)]) -> do
    pairs <- sortedPairs env ty m
    key <- fresh "Key"
    pure ([], D.text "[" <> D.text key <> D.text " || {" <> D.text key <> D.text ", _} <- " <> pairs <> D.text "]")
  (KeyValValues, [(m, ty)]) -> do
    pairs <- sortedPairs env ty m
    value <- fresh "Value"
    pure ([], D.text "[" <> D.text value <> D.text " || {_, " <> D.text value <> D.text "} <- " <> pairs <> D.text "]")
  (KeyValEntries, [(m, ty)]) -> (,) [] <$> entriesOf env ty m
  (SetOf, [(xs, _)]) -> plain "lawspec_beam_fast" "set_of" [xs]
  (SetMember, [(x, _), (s, _)]) -> plain "sets" "is_element" [x, s]
  (SetInsert, [(x, _), (s, _)]) -> plain "sets" "add_element" [x, s]
  (SetRemove, [(x, _), (s, _)]) -> plain "sets" "del_element" [x, s]
  (SetUnion, [(s, _), (t, _)]) -> plain "sets" "union" [s, t]
  (SetIntersection, [(s, _), (t, _)]) -> plain "sets" "intersection" [s, t]
  (SetDifference, [(s, _), (t, _)]) -> plain "sets" "subtract" [s, t]
  _ -> failWith ("bad intrinsic " ++ show intrinsic)
  where plain m f xs = pure ([], E.remote m f xs)

-- | A KeyVal's (key, value) pairs in the portable order of its keys.
sortedPairs :: Env -> Type -> D.Doc -> M D.Doc
sortedPairs env ty m = case collectionArguments ty of
  Just ("KeyVal", [k, _]) -> do
    ordered <- termOrdered env k
    if ordered then pure (E.remote "lawspec_beam_fast" "sorted_pairs" [m])
    else do
      n <- helperName env Ordered k
      pure (E.remote "lawspec_beam_fast" "sorted_pairs" [m, D.text ("fun " ++ n ++ "/2")])
  _ -> failWith ("not a KeyVal: " ++ show ty)

-- | A Set's items in the portable order.
sortedItems :: Env -> Type -> D.Doc -> M D.Doc
sortedItems env ty s = case collectionArguments ty of
  Just ("Set", [a]) -> do
    ordered <- termOrdered env a
    if ordered then pure (E.remote "lawspec_beam_fast" "sorted_items" [s])
    else do
      n <- helperName env Ordered a
      pure (E.remote "lawspec_beam_fast" "sorted_items" [s, D.text ("fun " ++ n ++ "/2")])
  _ -> failWith ("not a Set: " ++ show ty)

-- | A KeyVal's entries, as Entry values, in order.
entriesOf :: Env -> Type -> D.Doc -> M D.Doc
entriesOf env ty m = do
  pairs <- sortedPairs env ty m
  (d, c) <- entryConstructor env
  key <- fresh "Key"
  value <- fresh "Value"
  pure (D.text "[" <> conConstruct env d c [D.text key, D.text value] <> D.text " || " <>
    E.tuple [D.text key, D.text value] <> D.text " <- " <> pairs <> D.text "]")

matchStatements :: Env -> Scope -> Expr -> [MatchCase] -> M [D.Doc]
matchStatements env scope value cases = do
  let ty = expressionType value
      used c b = binderId b `elem` freeBinders (caseBody c)
      binders c = forM (caseBinders c) $ \b -> if used c b
        then do
          n <- fresh (binderName b)
          pure (Just (binderId b, n), D.text n)
        else pure (Nothing, D.text "_")
      alternative c pattern' = do
        bound <- binders c
        body <- cstmt env ([x | (Just x, _) <- bound] ++ scope) (caseBody c)
        pure (pattern' (map snd bound), body)
      unreachableArm = (D.text "_", [E.remote "lawspec_beam_fast" "unreachable" []])
      target = envTarget env
  (prelude, subject) <- cexpr env scope value
  case ty of
    Constructor n _ | n `elem` ["Maybe", "Either", "List"] -> do
      arms <- forM cases $ \c -> alternative c (\names -> case (idText (caseConstructor c), names) of
        ("Maybe::Nothing", _) -> E.atom (fst (maybes target))
        ("Maybe::Just", [x]) -> E.tuple [E.atom (snd (maybes target)), x]
        ("Either::Left", [x]) -> E.tuple [E.atom (fst (sides target)), x]
        ("Either::Right", [x]) -> E.tuple [E.atom (snd (sides target)), x]
        ("List::Nil", _) -> D.text "[]"
        ("List::Cons", [h, t]) -> D.text "[" <> h <> D.text " | " <> t <> D.text "]"
        _ -> D.text "_")
      pure (prelude ++ [caseDoc subject (arms ++ [unreachableArm | length cases < 2])])
    _ | Just (kind, _) <- collectionArguments ty, [c] <- cases -> do
          bound <- binders c
          body <- cstmt env ([x | (Just x, _) <- bound] ++ scope) (caseBody c)
          items <- if kind == "KeyVal" then entriesOf env ty subject else sortedItems env ty subject
          let binding = case bound of
                [(Just (_, n'), _)] -> [D.text (n' ++ " = ") <> items]
                _ -> []
          pure (prelude ++ binding ++ body)
    Constructor n _ | Just d <- M.lookup n (envAll env) -> do
      arms <- forM cases $ \c -> do
        (d', ctor) <- maybe (failWith ("unknown constructor " ++ idText (caseConstructor c))) pure (M.lookup (caseConstructor c) (envConstructors env))
        alternative c (conPattern env d' ctor)
      pure (prelude ++ [caseDoc subject (arms ++ [unreachableArm | length cases < length (dataConstructors d)])])
    _ -> failWith ("cannot match on " ++ show ty)

-- Comparison -----------------------------------------------------------------

-- | Whether Erlang's term order on a type's typed values is the portable
-- order: scalars, lists, Maybe and Either of such values, and data whose
-- constructors sort as their native tags do (atoms before tuples, shorter
-- tuples first, then by tag) with fields in that order too. An Elixir
-- struct is a map, ordered by its keys' names, so only a struct whose
-- fields are named in order qualifies. KeyVal and Set never do.
termOrdered :: Env -> Type -> M Bool
termOrdered env = go S.empty
  where
    go seen ty = case ty of
      Constructor n [] | n `elem` scalarTypes -> pure True
      Constructor n [TypeArgument a] | n `elem` ["List", "Maybe"] -> go seen a
      Constructor "Either" [TypeArgument a, TypeArgument b] -> (&&) <$> go seen a <*> go seen b
      _ | Just _ <- collectionArguments ty -> pure False
      Constructor n args | Just d <- M.lookup n (envAll env) ->
        if show ty `S.member` seen then pure True else do
          let typeArgs = [t | TypeArgument t <- args]
              cs = dataConstructors d
              ranks = constructorRanks d
              rank c = fromMaybe 0 (lookup (constructorId c) ranks)
              key c = if null (constructorFields c) then (0 :: Int, 0 :: Int, nativeTag env c) else (1, length (constructorFields c), nativeTag env c)
              shapeOk = case envTarget env of
                "elixir" -> case cs of
                  [c] -> let fs = E.elixirFields d c in fs == sortOn id fs
                  _ -> False
                _ -> map constructorId (sortOn key cs) == map constructorId (sortOn rank cs)
          if not shapeOk then pure False else
            and <$> mapM (go (S.insert (show ty) seen)) (concatMap (fieldTypes d typeArgs) cs)
      _ -> pure False

substituteIn :: [(Id, Type)] -> Type -> Type
substituteIn table t = case t of
  TypeVariable v -> fromMaybe t (lookup v table)
  Constructor n as -> Constructor n [case a of TypeArgument x -> TypeArgument (substituteIn table x); o -> o | a <- as]
  other -> other

fieldTypes :: DataDeclaration -> [Type] -> DataConstructor -> [Type]
fieldTypes d args c = map (substituteIn (zip (dataParameters d) args) . binderType) (constructorFields c)

-- | -1, 0 or 1 as a and b compare.
compareCall :: Env -> Type -> D.Doc -> D.Doc -> M D.Doc
compareCall env ty a b = do
  ordered <- termOrdered env ty
  if ordered then pure (E.remote "lawspec_beam_fast" "compare" [a, b])
  else do
    n <- helperName env Ordered ty
    pure (E.call n [a, b])

orderingDoc :: Env -> M D.Doc
orderingDoc env = case M.lookup (collectionsUnit ++ "::type::Ordering") (envAll env) of
  Just d -> do
    let con name = case [c | c <- dataConstructors d, constructorName c == name] of
          c : _ -> conConstruct env d c []
          [] -> E.atom name
    pure (D.joinWith (D.text ";" <> D.hardline)
      [ D.text ("lawspec_ordering(" ++ n ++ ") -> ") <> con name | (n, name) <- [("-1", "Less"), ("0", "Equal"), ("1", "Greater")] ] <> D.text ".")
  Nothing -> failWith "no typed Ordering"

-- Crossings and comparisons, made once per type --------------------------

-- | Whether a conversion is the identity: dynamic values differ from typed
-- ones in Unit and every constructed value; native ones only in KeyVal and
-- Set.
identity :: Env -> Crossing -> Type -> Bool
identity env k ty = case k of
  Ordered -> False
  _ | k `elem` [FromDynamic, ToDynamic] -> plainDynamic ty
  _ -> noCollections S.empty ty
  where
    plainDynamic t = case t of
      Constructor n [] -> n `elem` scalarTypes && n /= "Unit"
      Constructor "List" [TypeArgument a] -> plainDynamic a
      _ -> False
    noCollections seen t = case t of
      _ | Just _ <- collectionArguments t -> False
      Constructor n args | Just d <- M.lookup n (envAll env), n `S.notMember` seen ->
        let typeArgs = [x | TypeArgument x <- args]
        in all (noCollections (S.insert n seen)) (typeArgs ++ concatMap (fieldTypes d typeArgs) (dataConstructors d))
      Constructor _ args -> all (noCollections seen) [x | TypeArgument x <- args]
      _ -> True

conversionName :: Crossing -> Type -> String
conversionName k ty = prefix ++ "_" ++ take 12 (digestHex (digestString (show ty)))
  where
    prefix = case k of
      FromDynamic -> "from_dynamic"
      ToDynamic -> "to_dynamic"
      FromNative -> "from_native"
      ToNative -> "to_native"
      Ordered -> "compare"

-- | A conversion or comparison's function, made once.
helperName :: Env -> Crossing -> Type -> M String
helperName _ k ty = do
  let n = conversionName k ty
  modify (\st -> st { stWanted = M.insert n (k, ty) (stWanted st) })
  pure n

convert :: Env -> Crossing -> Type -> D.Doc -> M D.Doc
convert env k ty x = if identity env k ty then pure x else do
  n <- helperName env k ty
  pure (E.call n [x])

-- | The helpers asked for, made until none is new.
helpers :: Env -> S.Set String -> M [D.Doc]
helpers env done = do
  wanted <- gets stWanted
  let pending = [ (n, kt) | (n, kt) <- M.toList wanted, n `S.notMember` done ]
  if null pending then pure [] else do
    docs <- forM pending $ \(n, (k, t)) -> helperDoc env n k t
    rest <- helpers env (S.union done (S.fromList (map fst pending)))
    pure (docs ++ rest)

helperDoc :: Env -> String -> Crossing -> Type -> M D.Doc
helperDoc env n k ty = do
  clauses <- if k == Ordered then compareClauses env n ty else conversionClauses env k ty
  pure (D.text ("%% " ++ describe k ++ " " ++ show ty) <> D.hardline <>
    D.joinWith (D.text ";" <> D.hardline) [ E.atom n <> D.text ("(" ++ intercalate ", " ps ++ ") ->") <> sequenceBlock body | (ps, body) <- clauses ] <>
    D.text ".")
  where
    describe c = case c of
      FromDynamic -> "From the dynamic value of"
      ToDynamic -> "To the dynamic value of"
      FromNative -> "From the native value of"
      ToNative -> "To the native value of"
      Ordered -> "The portable order of"

render' :: D.Doc -> String
render' = D.render (D.Pretty 1000)

-- | A conversion's clauses: (patterns, body).
conversionClauses :: Env -> Crossing -> Type -> M [([String], [D.Doc])]
conversionClauses env k ty = case ty of
  Constructor "Unit" [] -> pure $ case k of
    FromDynamic -> [(["ls_unit"], [E.atom (unitAtom target)])]
    ToDynamic -> [([unitAtom target], [E.atom "ls_unit"])]
    _ -> [(["Value"], [D.text "Value"])]
  Constructor "List" [TypeArgument a] -> do
    item <- fresh "Item"
    x <- convert env k a (D.text item)
    pure [(["Values"], [D.text "[" <> x <> D.text (" || " ++ item ++ " <- Values]")])]
  Constructor "Maybe" [TypeArgument a] -> do
    x <- convert env k a (D.text "Value")
    let (nothing, just) = maybes target
    pure $ if dynamicSide
      then if k == FromDynamic
        then [ ([render' (dyn "Maybe::Nothing" [])], [E.atom nothing]), ([render' (dyn "Maybe::Just" [D.text "Value"])], [E.tuple [E.atom just, x]]) ]
        else [ ([nothing], [dyn "Maybe::Nothing" []]), ([render' (E.tuple [E.atom just, D.text "Value"])], [dyn "Maybe::Just" [x]]) ]
      else [ ([nothing], [E.atom nothing]), ([render' (E.tuple [E.atom just, D.text "Value"])], [E.tuple [E.atom just, x]]) ]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    xa <- convert env k a (D.text "Value")
    xb <- convert env k b (D.text "Value")
    let (left, right) = sides target
        typedSide tag v = E.tuple [E.atom tag, v]
    pure $ case k of
      FromDynamic -> [ ([render' (dyn "Either::Left" [D.text "Value"])], [typedSide left xa]), ([render' (dyn "Either::Right" [D.text "Value"])], [typedSide right xb]) ]
      ToDynamic -> [ ([render' (typedSide left (D.text "Value"))], [dyn "Either::Left" [xa]]), ([render' (typedSide right (D.text "Value"))], [dyn "Either::Right" [xb]]) ]
      _ -> [ ([render' (typedSide left (D.text "Value"))], [typedSide left xa]), ([render' (typedSide right (D.text "Value"))], [typedSide right xb]) ]
  _ | Just ("KeyVal", [kt, vt]) <- collectionArguments ty -> do
    (kd, kc) <- collectionDeclaration env "KeyVal"
    (ed, ec) <- entryConstructor env
    key <- fresh "Key"
    value <- fresh "Value"
    xk <- convert env k kt (D.text key)
    xv <- convert env k vt (D.text value)
    let kvTag = idText (constructorId kc)
        entryTag = idText (constructorId ec)
    case k of
      FromDynamic -> pure [([render' (dyn kvTag [D.text "Entries"])],
        [E.remote "lawspec_beam_fast" "key_val_of" [D.text "[" <> E.tuple [xk, xv] <> D.text " || " <> dyn entryTag [D.text key, D.text value] <> D.text " <- Entries]"]])]
      FromNative -> pure [([render' (conPattern env kd kc [D.text "Entries"])],
        [E.remote "lawspec_beam_fast" "key_val_of" [D.text "[" <> E.tuple [xk, xv] <> D.text " || " <> conPattern env ed ec [D.text key, D.text value] <> D.text " <- Entries]"]])]
      ToDynamic -> do
        pairs <- sortedPairs env ty (D.text "Map")
        pure [(["Map"], [dyn kvTag [D.text "[" <> dyn entryTag [xk, xv] <> D.text " || " <> E.tuple [D.text key, D.text value] <> D.text " <- " <> pairs <> D.text "]"]])]
      _ -> do
        pairs <- sortedPairs env ty (D.text "Map")
        pure [(["Map"], [conConstruct env kd kc [D.text "[" <> conConstruct env ed ec [xk, xv] <> D.text " || " <> E.tuple [D.text key, D.text value] <> D.text " <- " <> pairs <> D.text "]"]])]
  _ | Just ("Set", [at]) <- collectionArguments ty -> do
    (sd, sc) <- collectionDeclaration env "Set"
    item <- fresh "Item"
    x <- convert env k at (D.text item)
    let setTag = idText (constructorId sc)
        listOf src = D.text "[" <> x <> D.text (" || " ++ item ++ " <- ") <> src <> D.text "]"
    case k of
      FromDynamic -> pure [([render' (dyn setTag [D.text "Items"])], [E.remote "lawspec_beam_fast" "set_of" [listOf (D.text "Items")]])]
      FromNative -> pure [([render' (conPattern env sd sc [D.text "Items"])], [E.remote "lawspec_beam_fast" "set_of" [listOf (D.text "Items")]])]
      ToDynamic -> do
        items <- sortedItems env ty (D.text "Set")
        pure [(["Set"], [dyn setTag [listOf items]])]
      _ -> do
        items <- sortedItems env ty (D.text "Set")
        pure [(["Set"], [conConstruct env sd sc [listOf items]])]
  Constructor n args | Just d <- M.lookup n (envAll env) -> do
    let typeArgs = [t | TypeArgument t <- args]
    forM (dataConstructors d) $ \c -> do
      let types = fieldTypes d typeArgs c
          fields = [D.text ("Field" ++ show i) | (i, _) <- zip [0 :: Int ..] types]
      converted <- sequence [convert env k t f | (t, f) <- zip types fields]
      let tag = idText (constructorId c)
      pure $ case k of
        FromDynamic -> ([render' (dyn tag fields)], [conConstruct env d c converted])
        ToDynamic -> ([render' (conPattern env d c fields)], [dyn tag converted])
        _ -> ([render' (conPattern env d c fields)], [conConstruct env d c converted])
  _ -> failWith ("no conversion for " ++ show ty)
  where
    target = envTarget env
    dynamicSide = k `elem` [FromDynamic, ToDynamic]
    dyn tag fields = E.tuple [E.atom "ls_data", E.binary tag, E.array fields]

-- | A comparison's clauses, in the order the dynamic code compares.
compareClauses :: Env -> String -> Type -> M [([String], [D.Doc])]
compareClauses env n ty = case ty of
  Constructor "List" [TypeArgument a] -> do
    c <- compareCall env a (D.text "X") (D.text "Y")
    pure [ (["[]", "[]"], [D.text "0"]), (["[]", "_"], [D.text "-1"]), (["_", "[]"], [D.text "1"])
         , (["[X | Xs]", "[Y | Ys]"], [caseDoc c [(D.text "0", [E.call n [D.text "Xs", D.text "Ys"]]), (D.text "Order", [D.text "Order"])]]) ]
  Constructor "Maybe" [TypeArgument a] -> do
    c <- compareCall env a (D.text "X") (D.text "Y")
    let (nothing, just) = maybes (envTarget env)
    pure [ ([nothing, nothing], [D.text "0"]), ([nothing, "_"], [D.text "-1"]), (["_", nothing], [D.text "1"])
         , ([render' (E.tuple [E.atom just, D.text "X"]), render' (E.tuple [E.atom just, D.text "Y"])], [c]) ]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    ca <- compareCall env a (D.text "X") (D.text "Y")
    cb <- compareCall env b (D.text "X") (D.text "Y")
    let (left, right) = sides (envTarget env)
        side tag v = render' (E.tuple [E.atom tag, D.text v])
    pure [ ([side left "X", side left "Y"], [ca]), ([side left "_", "_"], [D.text "-1"]), (["_", side left "_"], [D.text "1"])
         , ([side right "X", side right "Y"], [cb]) ]
  _ | Just ("KeyVal", [kt, vt]) <- collectionArguments ty -> do
    (ed, _) <- entryConstructor env
    let entries = Constructor (idText (dataId ed)) [TypeArgument kt, TypeArgument vt]
    a <- entriesOf env ty (D.text "A")
    b <- entriesOf env ty (D.text "B")
    c <- compareCall env (Constructor "List" [TypeArgument entries]) a b
    pure [(["A", "B"], [c])]
  _ | Just ("Set", [at]) <- collectionArguments ty -> do
    a <- sortedItems env ty (D.text "A")
    b <- sortedItems env ty (D.text "B")
    c <- compareCall env (Constructor "List" [TypeArgument at]) a b
    pure [(["A", "B"], [c])]
  Constructor tn args | Just d <- M.lookup tn (envAll env) -> do
    let typeArgs = [t | TypeArgument t <- args]
        ranks = constructorRanks d
        rank c = fromMaybe 0 (lookup (constructorId c) ranks)
    same <- forM (dataConstructors d) $ \c -> do
      let types = fieldTypes d typeArgs c
          xs = [D.text ("X" ++ show i) | (i, _) <- zip [0 :: Int ..] types]
          ys = [D.text ("Y" ++ show i) | (i, _) <- zip [0 :: Int ..] types]
      body <- lexicographic (zip3 types xs ys)
      pure ([render' (conPattern env d c xs), render' (conPattern env d c ys)], [body])
    -- Different constructors compare by rank, the order of their identities.
    let rankOf c = conPattern env d c [D.text "_" | _ <- constructorFields c] <> D.text (") -> " ++ show (rank c))
        ranks = D.text "Rank = fun" <> D.nest 4 (D.hardline <> D.joinWith (D.text ";" <> D.hardline)
          [D.text "(" <> rankOf c | c <- dataConstructors d]) <> D.hardline <> D.text "end"
        others = [ (["A", "B"], [ranks, E.remote "lawspec_beam_fast" "compare" [D.text "Rank(A)", D.text "Rank(B)"]])
                 | length (dataConstructors d) > 1 ]
    pure (same ++ others)
  _ -> failWith ("no comparison for " ++ show ty)
  where
    lexicographic fields = case fields of
      [] -> pure (D.text "0")
      [(t, x, y)] -> compareCall env t x y
      (t, x, y) : rest -> do
        c <- compareCall env t x y
        inner <- lexicographic rest
        pure (caseDoc c [(D.text "0", [inner]), (D.text "Order", [D.text "Order"])])
