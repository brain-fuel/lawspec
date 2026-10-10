-- | Typed Python for checked definitions (see LawSpec.Typed.Plan), in
-- src/lawspec_typed.py: a function per class of typed definitions over
-- lawspec_fast.py's typed values, and, per concrete type the code needs, its
-- equality, its portable order, and its conversions to and from the dynamic
-- values and the native types. Data is a tuple, so building, matching and
-- comparing it is Python's own tuple code; lists share their tails and maps
-- copy only the path to a key, so a handler's state is never copied.
-- Failures are the dynamic code's ls.Failure, so each catches the other's.
-- Operations of other abilities go to the handler the context (symbols)
-- holds, as the dynamic code's do. ref:DEC-typed-native-definitions
module LawSpec.Typed.Python (PythonTyped(..), emitPythonTyped) where

import Control.Monad (forM, forM_)
import Control.Monad.State.Strict
import Data.Char (isAlphaNum, isUpper, toLower, ord)
import Data.List (intercalate, isPrefixOf, sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as S
import Numeric (showHex)
import LawSpec.Collections (collectionsUnit, collectionContainer)
import LawSpec.Core
import LawSpec.Scalar
import LawSpec.Typed.Plan
import LawSpec.PythonTypes (namesFor, pythonHashable, pythonTypeReferenceDoc)
import LawSpec.Time (isDurationType)
import qualified LawSpec.Code.Doc as D
import LawSpec.Digest (digestHex, digestString)

data PythonTyped = PythonTyped
  { -- src/lawspec_typed.py.
    pyTypedModule :: String
    -- A typed definition's function, in lawspec_typed.
  , pyTypedFunction :: Id -> Maybe String
    -- Dynamic value -> typed, and typed -> dynamic, by name.
  , pyTypedFrom :: Type -> String
  , pyTypedTo :: Type -> String
    -- Native -> typed, and typed -> native: nin(value, symbols) and
    -- nout(value, symbols), through the handler schema when bindings
    -- replace the native types, and directly otherwise.
  , pyTypedNativeIn :: Type -> String
  , pyTypedNativeOut :: Type -> String
    -- A typed spec handler's start value: start(symbols).
  , pyTypedStart :: Id -> Maybe String
  , pyTypedPlan :: TypedPlan
  }

data Env = Env
  { envPlan :: TypedPlan
  , envData :: M.Map String DataDeclaration
  , envConstructors :: M.Map Id (DataDeclaration, DataConstructor)
  , envFunctions :: M.Map Int String
  , envNative :: M.Map Id String
  , envUnits :: [Unit]
  , envBits :: Int
  }

data St = St { stCounter :: Int, stHelpers :: M.Map String Type, stWanted :: S.Set (String, String) }

type M = StateT St (Either String)

lift' :: Either String a -> M a
lift' = lift

fresh :: String -> M String
fresh base = do
  s <- get
  put s { stCounter = stCounter s + 1 }
  pure (sanitize base ++ "_" ++ show (stCounter s))

sanitize :: String -> String
sanitize name = case [c | c <- map lower name, isAlphaNum c && ord c < 128 || c == '_'] of
  [] -> "v"
  cleaned@(c : _) | c >= 'a' && c <= 'z' -> cleaned
  cleaned -> "v" ++ cleaned
  where lower c = if isUpper c then toLower c else c

identifier :: String -> String
identifier name = case [c | c <- name, isAlphaNum c && ord c < 128 || c == '_'] of
  [] -> "x"
  n -> n

-- | A helper of a kind for a type, named by the type.
helper :: String -> Type -> M String
helper kind ty = do
  let key = show ty
  modify (\st -> st { stHelpers = M.insert key ty (stHelpers st), stWanted = S.insert (kind, key) (stWanted st) })
  pure (helperName kind ty)

helperName :: String -> Type -> String
helperName kind ty = kind ++ "_" ++ take 12 (digestHex (digestString (show ty)))

-- | The runtime functions the module uses, imported as lsf_<name>.
runtimeNames :: [String]
runtimeNames =
  [ "outside", "narrow", "quot", "rem", "power", "unreachable", "cons", "length", "list_of", "items", "eq_list", "eq_list_plain"
  , "cmp_list", "cmp_plain", "cmp_unit", "eq_unit", "cmp_list_plain", "append", "slice_list", "slice_seq", "at_list", "at_bytes"
  , "range_list", "octets", "bytes_of", "utf8", "join", "regex_matches", "lookup", "member", "put", "delete", "lookup_by"
  , "member_by", "put_by", "delete_by", "entries", "keys_list", "values_list", "entries_list", "key_val_of", "key_val_of_by"
  , "set_of", "set_of_by", "set_insert", "set_insert_by", "set_union", "set_union_by", "set_intersection", "set_intersection_by"
  , "set_difference", "set_difference_by", "eq_map", "cmp_map", "eq_plain", "from_list", "to_list" ]

emitPythonTyped :: Int -> [DataDeclaration] -> [Unit] -> Either String PythonTyped
emitPythonTyped bits declarations units = do
  let plan = typedPlanPerforming scalarTypes declarations units
      datas = typedData plan
      functions = M.fromList [ (c, functionName c d) | (c, d) <- typedRepresentatives plan ]
  names <- namesFor [d | d <- declarations, collectionContainer (idText (dataId d)) == Nothing, not (isDurationType (idText (dataId d))), not (dataHandle d)]
  let env = Env plan (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions
        (M.fromList names) units bits
      typedHandlers = [ h | u <- units, h <- unitHandlers u, isTypedHandler plan h ]
      handlerTypes = [ t | h <- typedHandlers, ref <- handlerAbilities h, Just (_, a) <- [findAbility units ref]
                         , (_, ty) <- abilityOperations a, let (args, result) = functionType ty, t <- result : args ]
      boundary = concat [ let (args, result) = functionType (declarationType (definitionDeclaration d)) in result : args
                        | d <- M.elems (typedDefinitions plan) ]
      starts = [ (handlerId h, "Start_" ++ show k, start) | (k, h) <- zip [0 :: Int ..] typedHandlers, Just (_, start) <- [handlerState h] ]
  ((functionDocs, startDocs, helperDocs), _) <- flip runStateT (St 0 M.empty S.empty) $ do
    fs <- mapM (\(c, d) -> functionDoc env c d) (typedRepresentatives plan)
    ss <- forM starts $ \(_, name, start) -> do
      body <- cstmt env Nothing [(Id "lawspec::symbols", "symbols")] Return start
      pure (block ("def " ++ name ++ "(symbols)") body)
    forM_ boundary $ \t -> helper "to" t >> helper "from" t
    forM_ handlerTypes $ \t -> helper "nin" t >> helper "nout" t
    hs <- helpers env
    pure (fs, ss, hs)
  let line = D.text
      header = map line
        [ "# Generated by LawSpec. Do not edit."
        , "\"\"\"Typed checked definitions over lawspec_fast's values; see"
        , "docs/how-to/embed-a-generated-model.md.\"\"\""
        , "import lawspec_data as data"
        , "import lawspec_runtime as ls"
        , "import lawspec_schema as _schema"
        , "from lawspec_fast import " ++ intercalate ", " [n ++ " as lsf_" ++ n | n <- runtimeNames]
        , ""
        , "_lawspec_schema = data.make_schema()" ]
      source = D.render (D.Pretty 100) (D.joinWith D.hardline header <> D.hardline <> D.hardline <> D.hardline <>
        D.joinWith (D.hardline <> D.hardline <> D.hardline) (orderingHelper env ++ functionDocs ++ startDocs ++ helperDocs)) ++ "\n"
  pure PythonTyped
    { pyTypedModule = source
    , pyTypedFunction = \i -> definitionClass plan i >>= (`M.lookup` functions)
    , pyTypedFrom = helperName "from"
    , pyTypedTo = helperName "to"
    , pyTypedNativeIn = helperName "nin"
    , pyTypedNativeOut = helperName "nout"
    , pyTypedStart = \h -> case [n | (i, n, _) <- starts, i == h] of
        n : _ -> Just n
        [] -> Nothing
    , pyTypedPlan = plan }
  where
    functionName c d = "Def_" ++ identifier (shortName (declarationName (definitionDeclaration d))) ++ "_" ++ show c
    shortName name =
      let unprefixed = if "lawspec_" `isPrefixOf` name then drop 8 name else name
      in reverse (dropHash (reverse unprefixed))
    dropHash reversed = case span (`elem` ("0123456789abcdef" :: String)) reversed of
      (digits@(_ : _), '_' : rest) | length digits >= 8 -> rest
      _ -> reversed

-- Shapes of data.

fieldless :: DataDeclaration -> Bool
fieldless d = not (null (dataConstructors d)) && all (null . constructorFields) (dataConstructors d)

isProductType :: DataDeclaration -> Bool
isProductType d = length (dataConstructors d) == 1 && not (fieldless d)

rankOf :: DataDeclaration -> DataConstructor -> Int
rankOf d c = fromMaybe 0 (lookup (constructorId c) (constructorRanks d))

substituteIn :: [(Id, Type)] -> Type -> Type
substituteIn table t = case t of
  TypeVariable v -> fromMaybe t (lookup v table)
  Constructor n as -> Constructor n [case a of TypeArgument x -> TypeArgument (substituteIn table x); o -> o | a <- as]
  other -> other

fieldTypes :: DataDeclaration -> [Type] -> DataConstructor -> [Type]
fieldTypes d args c = map (substituteIn (zip (dataParameters d) args) . binderType) (constructorFields c)

typeArguments :: Type -> [Type]
typeArguments (Constructor _ args) = [t | TypeArgument t <- args]
typeArguments _ = []

-- | Whether Python's == is LawSpec's equality on a type's typed values: no
-- list or map inside, whose cells and nodes == would walk recursively.
plainEq :: Env -> Type -> Bool
plainEq env = go S.empty
  where
    go seen ty = case ty of
      Constructor n [] | n `elem` scalarTypes -> True
      Constructor "List" _ -> False
      _ | isJust (collectionArguments ty) -> False
      Constructor n [TypeArgument a] | n == "Maybe" -> go seen a
      Constructor "Either" [TypeArgument a, TypeArgument b] -> go seen a && go seen b
      Constructor n args | Just d <- M.lookup n (envData env) ->
        show ty `S.member` seen || all (go (S.insert (show ty) seen)) (concatMap (fieldTypes d [t | TypeArgument t <- args]) (dataConstructors d))
      _ -> False

-- | Whether Python's < and == are LawSpec's order: Unit (None) has no <,
-- though tuples holding it never reach it.
plainOrd :: Env -> Type -> Bool
plainOrd env ty = plainEq env ty && ty /= Constructor "Unit" []

orderingHelper :: Env -> [D.Doc]
orderingHelper env = case M.lookup (collectionsUnit ++ "::type::Ordering") (envData env) of
  Nothing -> []
  Just d ->
    let rank name = firstOf ([rankOf d c | c <- dataConstructors d, constructorName c == name] ++ [0])
    in [block "def Ordering_of(c)" [D.text ("return " ++ show (rank "Less") ++ " if c < 0 else (" ++ show (rank "Equal") ++ " if c == 0 else " ++ show (rank "Greater") ++ ")")]]

-- Statements.

block :: String -> [D.Doc] -> D.Doc
block header body = D.text (header ++ ":") <> D.nest 4 (D.hardline <> D.joinWith D.hardline (if null body then [D.text "pass"] else body))

blockD :: D.Doc -> [D.Doc] -> D.Doc
blockD header body = header <> D.text ":" <> D.nest 4 (D.hardline <> D.joinWith D.hardline (if null body then [D.text "pass"] else body))

paren :: D.Doc -> D.Doc
paren x = D.text "(" <> x <> D.text ")"

data Target = Return | Assign String

type Scope = [(Id, String)]

symbolsId :: Id
symbolsId = Id "lawspec::symbols"

functionDoc :: Env -> Int -> Definition -> M D.Doc
functionDoc env c d = do
  let declaration = definitionDeclaration d
      name = envFunctions env M.! c
      contextual = isContextual (envPlan env) (declarationId declaration)
  params <- forM (definitionArguments d) $ \b -> do
    local <- fresh (binderName b)
    pure (binderId b, local)
  let scope = [(symbolsId, "symbols") | contextual] ++ params
      looping = hasTailSelf env c (definitionBody d)
      selfCall = if looping then Just (c, map snd params) else Nothing
  body <- case M.lookup (declarationId declaration) (typedIntrinsics (envPlan env)) of
    Just intrinsic -> do
      x <- intrinsicCall env intrinsic [(D.text l, binderType b) | ((_, l), b) <- zip params (definitionArguments d)]
      pure [D.text "return " <> x]
    Nothing -> cstmt env selfCall scope Return (definitionBody d)
  pure (D.text ("# " ++ idText (declarationId declaration)) <> D.hardline <>
    block ("def " ++ name ++ "(" ++ intercalate ", " (["symbols" | contextual] ++ map snd params) ++ ")")
      (if looping then [block "while True" body] else body))

hasTailSelf :: Env -> Int -> Expr -> Bool
hasTailSelf env c e = case expressionNode e of
  ExternalCall i _ -> definitionClass (envPlan env) i == Just c && M.notMember i (typedIntrinsics (envPlan env))
  If _ a b -> hasTailSelf env c a || hasTailSelf env c b
  Match _ cases -> any (hasTailSelf env c . caseBody) cases
  Let _ _ body -> hasTailSelf env c body
  Helper Select [_, a, b] -> hasTailSelf env c a || hasTailSelf env c b
  _ -> False

deliver :: Target -> D.Doc -> D.Doc
deliver Return x = D.text "return " <> x
deliver (Assign v) x = D.text (v ++ " = ") <> x

cstmt :: Env -> Maybe (Int, [String]) -> Scope -> Target -> Expr -> M [D.Doc]
cstmt env selfCall scope target e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    local <- fresh (binderName binder)
    rest <- cstmt env selfCall ((binderId binder, local) : scope) target body
    pure (s ++ [D.text (local ++ " = ") <> x] ++ rest)
  If c a b -> do
    (s, x) <- cexpr env scope c
    yes <- cstmt env selfCall scope target a
    no <- cstmt env selfCall scope target b
    pure (s ++ [blockD (D.text "if " <> x) yes, block "else" no])
  Helper Select [c, a, b] -> cstmt env selfCall scope target (e { expressionNode = If c a b })
  Match value cases -> matchStatements env selfCall scope target value cases
  ExternalCall i args
    | Just (c, params) <- selfCall, definitionClass (envPlan env) i == Just c, M.notMember i (typedIntrinsics (envPlan env)), Return <- target -> do
        let unchanged (p, a) = case expressionNode a of
              Local l -> lookup l scope == Just p
              _ -> False
            changed = [(p, a) | (p, a) <- zip params args, not (unchanged (p, a))]
        evaluated <- forM changed $ \(p, a) -> do
          (s, x) <- cexpr env scope a
          t <- fresh "next"
          pure (s ++ [D.text (t ++ " = ") <> x], D.text (p ++ " = " ++ t))
        pure (concatMap fst evaluated ++ map snd evaluated ++ [D.text "continue"])
  Helper Unreachable _ -> pure [D.text "lsf_unreachable()"]
  Perform (Operation _ "raise") [_] -> fst <$> cexpr env scope e
  _ -> do
    (s, x) <- cexpr env scope e
    pure (s ++ [deliver target x])

cexpr :: Env -> Scope -> Expr -> M ([D.Doc], D.Doc)
cexpr env scope e = case expressionNode e of
  Let {} -> viaStatements
  Match {} -> viaStatements
  If {} -> viaStatements
  Helper Select _ -> viaStatements
  Constant s -> (,) [] <$> lift' (constant s)
  Local i -> do
    name <- lift' (maybe (Left ("typed Python: unbound local " ++ idText i)) Right (lookup i scope))
    pure ([], D.text name)
  Construct tag args -> do
    parts <- mapM (cexpr env scope) args
    x <- construct env (expressionType e) tag (map snd parts)
    pure (concatMap fst parts, x)
  ExternalCall i args
    | Just intrinsic <- M.lookup i (typedIntrinsics (envPlan env)) -> do
        parts <- mapM (cexpr env scope) args
        x <- intrinsicCall env intrinsic (zip (map snd parts) (map expressionType args))
        pure (concatMap fst parts, x)
    | otherwise -> do
        c <- lift' (maybe (Left ("typed Python: untyped callee " ++ idText i)) Right (definitionClass (envPlan env) i))
        parts <- mapM (cexpr env scope) args
        let context = [D.text "symbols" | isContextual (envPlan env) i]
        pure (concatMap fst parts, D.text (envFunctions env M.! c ++ "(") <> D.joinWith (D.text ", ") (context ++ map snd parts) <> D.text ")")
  ShortCircuit op a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    if null sb
      then pure (sa, paren (xa <> D.text (if op == And then " and " else " or ") <> xb))
      else do
        t <- fresh "logic"
        pure (sa ++ [ D.text (t ++ " = ") <> xa
                    , blockD (D.text (if op == And then "if " ++ t else "if not " ++ t)) (sb ++ [D.text (t ++ " = ") <> xb]) ], D.text t)
  Unary Not a -> do
    (s, x) <- cexpr env scope a
    pure (s, D.text "(not " <> x <> D.text ")")
  Unary Negate a -> do
    (s, x) <- cexpr env scope a
    pure (s, D.text "(-" <> x <> D.text ")")
  Binary op (Structural t) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    if plainEq env t
      then pure (sa ++ sb, paren (xa <> D.text (if op == Equal then " == " else " != ") <> xb))
      else do
        eq <- helper "eq" t
        let test = D.text (eq ++ "(") <> xa <> D.text ", " <> xb <> D.text ")"
        pure (sa ++ sb, if op == Equal then test else D.text "(not " <> test <> D.text ")")
  Binary op (Numeric _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    let infix' symbol = pure (sa ++ sb, paren (xa <> D.text symbol <> xb))
        call f = pure (sa ++ sb, D.text (f ++ "(") <> xa <> D.text ", " <> xb <> D.text ")")
    case op of
      Add -> infix' " + "
      Subtract -> infix' " - "
      Multiply -> infix' " * "
      Quotient -> call "lsf_quot"
      Remainder -> call "lsf_rem"
      Power -> call "lsf_power"
      Equal -> infix' " == "
      NotEqual -> infix' " != "
      Less -> infix' " < "
      LessEqual -> infix' " <= "
      Greater -> infix' " > "
      GreaterEqual -> infix' " >= "
      _ -> lift' (Left ("typed Python: unsupported operator " ++ show op))
  Convert _ target value -> convert env scope target value
  Helper Compare [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    cmp <- comparer env (expressionType a)
    pure (sa ++ sb, D.text ("Ordering_of(" ++ cmp ++ "(") <> xa <> D.text ", " <> xb <> D.text "))")
  Helper Length [x] -> do
    (s, v) <- cexpr env scope x
    pure (s, case expressionType x of
      Constructor n [] | n `elem` ["Text", "Bytes"] -> D.text "len(" <> v <> D.text ")"
      _ -> D.text "lsf_length(" <> v <> D.text ")")
  Helper Unreachable _ -> pure ([D.text "lsf_unreachable()"], D.text "None")
  Helper Checked _ -> pure ([], D.text "True")
  Helper StartsWith [a, b] -> method "startswith" a b
  Helper EndsWith [a, b] -> method "endswith" a b
  Helper TextContains [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    pure (sa ++ sb, paren (xb <> D.text " in " <> xa))
  Helper RegexMatches [a, b] -> call2 "lsf_regex_matches" a b
  AllElements value binder predicate -> do
    (sx, xs) <- cexpr env scope value
    t <- fresh "all"
    cell <- fresh "cell"
    item <- fresh (binderName binder)
    (sp, p) <- cexpr env ((binderId binder, item) : scope) predicate
    pure (sx ++ [ D.text (t ++ " = True"), D.text (cell ++ " = ") <> xs
                , block ("while " ++ cell ++ " is not None")
                    ([D.text (item ++ " = " ++ cell ++ "[0]")] ++ sp ++
                     [blockD (D.text "if not " <> paren p) [D.text (t ++ " = False"), D.text "break"],
                      D.text (cell ++ " = " ++ cell ++ "[1]")]) ], D.text t)
  -- raise e: a failure of the Fail ability, as the dynamic raise makes it.
  Perform (Operation ref "raise") [x] | isFail ref -> do
    (s, v) <- cexpr env scope x
    to <- helper "to" (expressionType x)
    pure (s ++ [D.text ("raise ls.Failure(" ++ quote (abilityKey ref) ++ ", " ++ to ++ "(") <> v <> D.text "))"], D.text "None")
  -- An operation of another ability: its handler in the context, called
  -- with native values, as the dynamic code calls it.
  Perform op args -> do
    parts <- mapM (cexpr env scope) args
    outs <- mapM (helper "nout" . expressionType) args
    nin <- helper "nin" (expressionType e)
    r <- fresh "performed"
    let call = D.text ("ls.handler(symbols, " ++ quote (abilityKey (operationAbility op)) ++ ")." ++ operationName op ++ "(") <>
          D.joinWith (D.text ", ") [D.text (o ++ "(") <> x <> D.text ", symbols)" | (o, x) <- zip outs (map snd parts)] <> D.text ")"
    failure <- case performedFailure (envUnits env) op of
      Just failing@(AbilityRef _ [failureType]) -> do
        ref <- lift' (pythonTypeReferenceDoc failureType)
        pure (Just (failing, ref))
      _ -> pure Nothing
    let invoke = case failure of
          Nothing -> [D.text (r ++ " = ") <> call]
          Just (failing, ref) ->
            [ block "try" [D.text (r ++ " = ") <> call]
            , block "except ls.Fail as error"
                [D.text ("raise ls.Failure(" ++ quote (abilityKey failing) ++ ", ls.handler_schema(_lawspec_schema).from_native(") <> ref <>
                 D.text (", error.value, " ++ show (envBits env) ++ ", symbols)) from error")] ]
    pure (concatMap fst parts ++ invoke, D.text (nin ++ "(" ++ r ++ ", symbols)"))
  -- attempt e: Right of e's value, or Left of the failure it raised.
  Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, _] <- expressionType e -> do
    t <- fresh "attempted"
    from <- helper "from" failure
    (s, v) <- cexpr env scope body
    pure ([ block "try" (s ++ [D.text (t ++ " = (1, ") <> v <> D.text ")"])
          , block "except ls.Failure as failure"
              [ block ("if failure.ability != " ++ quote (abilityKey ref)) [D.text "raise"]
              , D.text (t ++ " = (0, " ++ from ++ "(failure.value))") ] ], D.text t)
  Helper Append [a, b] -> case expressionType a of
    Constructor n [] | n `elem` ["Text", "Bytes"] -> do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, paren (xa <> D.text " + " <> xb))
    _ -> call2 "lsf_append" a b
  Helper Slice [x, from, to] -> do
    (sx, v) <- cexpr env scope x
    (si, i) <- cexpr env scope from
    (sj, j) <- cexpr env scope to
    let f = case expressionType x of
          Constructor n [] | n `elem` ["Text", "Bytes"] -> "lsf_slice_seq"
          _ -> "lsf_slice_list"
    pure (sx ++ si ++ sj, D.text (f ++ "(") <> v <> D.text ", " <> i <> D.text ", " <> j <> D.text ")")
  Helper At [x, k] -> call2 (if expressionType x == Constructor "Bytes" [] then "lsf_at_bytes" else "lsf_at_list") x k
  Helper Range [lo, hi] -> call2 "lsf_range_list" lo hi
  Helper Octets [b] -> one "lsf_octets" b
  Helper BytesOf [xs] -> one "lsf_bytes_of" xs
  Helper Utf8 [t] -> one "lsf_utf8" t
  Helper TextOf [n] -> one "str" n
  Helper Join [sep, parts] -> call2 "lsf_join" sep parts
  _ -> lift' (Left ("typed Python: unsupported expression " ++ take 80 (show (expressionNode e))))
  where
    one f a = do
      (s, x) <- cexpr env scope a
      pure (s, D.text (f ++ "(") <> x <> D.text ")")
    call2 f a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, D.text (f ++ "(") <> xa <> D.text ", " <> xb <> D.text ")")
    method m a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, xa <> D.text ("." ++ m ++ "(") <> xb <> D.text ")")
    viaStatements = do
      t <- fresh "value"
      s <- cstmt env Nothing scope (Assign t) e
      pure (s, D.text t)

-- | The order of a type: < and == when they are LawSpec's, else a helper.
comparer :: Env -> Type -> M String
comparer env ty
  | plainOrd env ty = pure "lsf_cmp_plain"
  | ty == Constructor "Unit" [] = pure "lsf_cmp_unit"
  | otherwise = helper "cmp" ty

equaler :: Env -> Type -> M String
equaler env ty
  | plainEq env ty = pure "lsf_eq_plain"
  | otherwise = helper "eq" ty

quote :: String -> String
quote s = "'" ++ concatMap escape s ++ "'"
  where
    escape c
      | c == '\'' = "\\'"
      | c == '\\' = "\\\\"
      | ord c < 32 || ord c == 127 = "\\x" ++ pad 2 (showHex (ord c) "")
      | ord c > 127 && ord c < 0x10000 = "\\u" ++ pad 4 (showHex (ord c) "")
      | ord c >= 0x10000 = "\\U" ++ pad 8 (showHex (ord c) "")
      | otherwise = [c]
    pad n h = replicate (n - length h) '0' ++ h

constant :: Scalar -> Either String D.Doc
constant s = case s of
  SBool b -> pure (D.text (if b then "True" else "False"))
  SAbsent "Unit" -> pure (D.text "None")
  SInteger _ n -> pure (D.text (if n < 0 then "(" ++ show n ++ ")" else show n))
  SSequence "Text" units -> pure (D.text (quote (map toEnum units)))
  SSequence "Bytes" units -> pure (D.text ("b'" ++ concatMap (\u -> "\\x" ++ (if u < 16 then "0" else "") ++ showHex u "") units ++ "'"))
  _ -> Left ("typed Python: unsupported constant " ++ show s)

boundsOf :: String -> Maybe (Integer, Integer)
boundsOf t = lookup t
  [ ("Int8", (-128, 127)), ("Int16", (-32768, 32767)), ("Int32", (-2147483648, 2147483647))
  , ("Int64", (-(2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1)), ("UInt8", (0, 255)), ("UInt16", (0, 65535))
  , ("UInt32", (0, 4294967295)), ("UInt64", (0, 2 ^ (64 :: Int) - 1)) ]

convert :: Env -> Scope -> Type -> Expr -> M ([D.Doc], D.Doc)
convert env scope target value = do
  (s, x) <- cexpr env scope value
  case target of
    Constructor t [] | Just (lo, hi) <- boundsOf t ->
      let inside = case expressionType value of
            Constructor n [] | Just (slo, shi) <- boundsOf n -> slo >= lo && shi <= hi
            _ -> False
      in if inside then pure (s, x) else do
        v <- fresh "narrowed"
        pure (s ++ [ D.text (v ++ " = ") <> x
                   , block ("if " ++ v ++ " < " ++ showInt lo ++ " or " ++ v ++ " > " ++ showInt hi) [D.text ("lsf_outside(" ++ quote t ++ ")")] ], D.text v)
    _ -> pure (s, x)
  where showInt n = if n < 0 then "(" ++ show n ++ ")" else show n

construct :: Env -> Type -> Id -> [D.Doc] -> M D.Doc
construct env ty tag values = case (idText tag, values) of
  ("List::Nil", []) -> pure (D.text "None")
  ("List::Cons", [h, t]) -> pure (D.text "lsf_cons(" <> h <> D.text ", " <> t <> D.text ")")
  ("Maybe::Nothing", []) -> pure (D.text "()")
  ("Maybe::Just", [x]) -> pure (D.text "(" <> x <> D.text ",)")
  ("Either::Left", [x]) -> pure (D.text "(0, " <> x <> D.text ")")
  ("Either::Right", [x]) -> pure (D.text "(1, " <> x <> D.text ")")
  (_, [items]) | Just ("KeyVal", [k, _]) <- collectionArguments ty ->
    if plainOrd env k then pure (D.text "lsf_key_val_of(" <> items <> D.text ")")
    else (\cmp -> D.text "lsf_key_val_of_by(" <> items <> D.text (", " ++ cmp ++ ")")) <$> comparer env k
  (_, [items]) | Just ("Set", [a]) <- collectionArguments ty ->
    if plainOrd env a then pure (D.text "lsf_set_of(" <> items <> D.text ")")
    else (\cmp -> D.text "lsf_set_of_by(" <> items <> D.text (", " ++ cmp ++ ")")) <$> comparer env a
  _ -> case M.lookup tag (envConstructors env) of
    Just (d, c)
      | fieldless d -> pure (D.text (show (rankOf d c)))
      | isProductType d -> pure (tuple values)
      | otherwise -> pure (tuple (D.text (show (rankOf d c)) : values))
    Nothing -> lift' (Left ("typed Python: unknown constructor " ++ idText tag))

tuple :: [D.Doc] -> D.Doc
tuple [x] = D.text "(" <> x <> D.text ",)"
tuple xs = D.text "(" <> D.joinWith (D.text ", ") xs <> D.text ")"

intrinsicCall :: Env -> Intrinsic -> [(D.Doc, Type)] -> M D.Doc
intrinsicCall env intrinsic args = case (intrinsic, args) of
  (KeyValOf, [(es, Constructor "List" [TypeArgument (Constructor _ [TypeArgument k, _])])]) -> keyed k "lsf_key_val_of" [es]
  (KeyValLookup, [(k, kt), (m, _)]) -> keyed kt "lsf_lookup" [m, k]
  (KeyValPut, [(k, kt), (v, _), (m, _)]) -> keyed kt "lsf_put" [m, k, v]
  (KeyValDelete, [(k, kt), (m, _)]) -> keyed kt "lsf_delete" [m, k]
  (KeyValKeys, [(m, _)]) -> pure (D.text "lsf_keys_list(" <> m <> D.text ")")
  (KeyValValues, [(m, _)]) -> pure (D.text "lsf_values_list(" <> m <> D.text ")")
  (KeyValEntries, [(m, _)]) -> pure (D.text "lsf_entries_list(" <> m <> D.text ")")
  (SetOf, [(xs, Constructor "List" [TypeArgument a])]) -> keyed a "lsf_set_of" [xs]
  (SetMember, [(x, xt), (s, _)]) -> keyed xt "lsf_member" [s, x]
  (SetInsert, [(x, xt), (s, _)]) -> keyed xt "lsf_set_insert" [s, x]
  (SetRemove, [(x, xt), (s, _)]) -> keyed xt "lsf_delete" [s, x]
  (SetUnion, [(s, st), (t, _)]) -> setOp "lsf_set_union" s st t
  (SetIntersection, [(s, st), (t, _)]) -> setOp "lsf_set_intersection" s st t
  (SetDifference, [(s, st), (t, _)]) -> setOp "lsf_set_difference" s st t
  _ -> lift' (Left ("typed Python: bad intrinsic " ++ show intrinsic))
  where
    keyed kt f xs
      | plainOrd env kt = pure (D.text (f ++ "(") <> D.joinWith (D.text ", ") xs <> D.text ")")
      | otherwise = do
          cmp <- comparer env kt
          pure (D.text (f ++ "_by(") <> D.joinWith (D.text ", ") (xs ++ [D.text cmp]) <> D.text ")")
    setOp f s st t = case collectionArguments st of
      Just (_, [a]) -> keyed a f [s, t]
      _ -> lift' (Left "typed Python: set operation on a non-set")

matchStatements :: Env -> Maybe (Int, [String]) -> Scope -> Target -> Expr -> [MatchCase] -> M [D.Doc]
matchStatements env selfCall scope target value cases = do
  let ty = expressionType value
      used c b = binderId b `elem` freeBinders (caseBody c)
      arm c accesses = do
        bound <- forM (zip (caseBinders c) accesses) $ \(b, access) ->
          if used c b then do
            n <- fresh (binderName b)
            pure (Just (binderId b, n), [D.text (n ++ " = " ++ access)])
          else pure (Nothing, [])
        body <- cstmt env selfCall ([x | (Just x, _) <- bound] ++ scope) target (caseBody c)
        pure (concatMap snd bound ++ body)
      unreachable = [D.text "lsf_unreachable()"]
      caseOf tag = [c | c <- cases, idText (caseConstructor c) == tag]
      orUnreachable tag accesses = case caseOf tag of
        c : _ -> arm c accesses
        [] -> pure unreachable
  (prelude, subject) <- case expressionNode value of
    Local i | Just name <- lookup i scope -> pure ([], name)
    _ -> do
      (s, x) <- cexpr env scope value
      t <- fresh "matched"
      pure (s ++ [D.text (t ++ " = ") <> x], t)
  let two condition yesTag yesAccess noTag noAccess = do
        yes <- orUnreachable yesTag yesAccess
        no <- orUnreachable noTag noAccess
        pure (prelude ++ [block ("if " ++ condition) yes, block "else" no])
  case ty of
    Constructor "Maybe" _ -> two subject "Maybe::Just" [subject ++ "[0]"] "Maybe::Nothing" []
    Constructor "Either" _ -> two (subject ++ "[0]") "Either::Right" [subject ++ "[1]"] "Either::Left" [subject ++ "[1]"]
    Constructor "List" _ -> two (subject ++ " is None") "List::Nil" [] "List::Cons" [subject ++ "[0]", subject ++ "[1]"]
    _ | Just (kind, _) <- collectionArguments ty, [c] <- cases ->
          (prelude ++) <$> arm c [(if kind == "KeyVal" then "lsf_entries_list(" else "lsf_keys_list(") ++ subject ++ ")"]
    Constructor n _ | Just d <- M.lookup n (envData env) -> do
      let conOf c = snd (envConstructors env M.! caseConstructor c)
      if isProductType d
        then case cases of
          [c] -> (prelude ++) <$> arm c [subject ++ "[" ++ show k ++ "]" | k <- [0 .. length (constructorFields (conOf c)) - 1]]
          _ -> lift' (Left "typed Python: product match")
        else do
          tag <- if fieldless d then pure subject else do
            t <- fresh "tag"
            pure t
          arms <- forM (sortOn (rankOf d . conOf) cases) $ \c -> do
            body <- arm c [subject ++ "[" ++ show k ++ "]" | k <- [1 .. length (constructorFields (conOf c))]]
            pure (rankOf d (conOf c), body)
          let chain = case arms of
                [] -> unreachable
                _ -> [ block ((if k == 0 then "if " else "elif ") ++ tag ++ " == " ++ show r) body | (k, (r, body)) <- zip [0 :: Int ..] (init arms) ] ++
                     [ block (if length arms == 1 then "if True" else "else") (snd (last arms)) ]
          pure (prelude ++ [D.text (tag ++ " = " ++ subject ++ "[0]") | not (fieldless d)] ++ chain)
    _ -> lift' (Left ("typed Python: cannot match on " ++ show ty))

-- Helpers.

helpers :: Env -> M [D.Doc]
helpers env = go S.empty
  where
    go done = do
      st <- get
      let pending = [w | w <- S.toList (stWanted st), w `S.notMember` done]
      if null pending then pure [] else do
        docs <- forM pending $ \(kind, key) -> helperDoc env kind (stHelpers st M.! key)
        rest <- go (S.union done (S.fromList pending))
        pure (docs ++ rest)

helperDoc :: Env -> String -> Type -> M D.Doc
helperDoc env kind ty = do
  let name = helperName kind ty
      fn params body = D.text ("# " ++ kind ++ " " ++ show ty) <> D.hardline <> block ("def " ++ name ++ "(" ++ params ++ ")") body
  case kind of
    "eq" -> fn "a, b" <$> equality env ty
    "cmp" -> fn "a, b" <$> ordering env ty
    "to" -> fn "x" <$> toValue env ty
    "from" -> fn "v" <$> fromValue env ty
    "tonative" -> fn "x" <$> toNative env ty
    "fromnative" -> fn "n" <$> fromNative env ty
    "nin" -> fn "n, symbols" <$> nativeIn env ty
    _ -> fn "x, symbols" <$> nativeOut env ty

-- | Native -> typed: directly where the native types are the generated
-- ones, through the handler schema where bindings replace them.
nativeIn :: Env -> Type -> M [D.Doc]
nativeIn env ty
  | ty == Constructor "Unit" [] = pure [D.text "return None"]
  | otherwise = do
      ref <- lift' (pythonTypeReferenceDoc ty)
      from <- helper "from" ty
      let viaSchema = D.text ("return " ++ from ++ "(ls.handler_schema(_lawspec_schema).from_native(") <> ref <> D.text (", n, " ++ show (envBits env) ++ ", symbols))")
      if nativeDirect env S.empty ty
        then do
          direct <- helper "fromnative" ty
          pure [block "if ls._HANDLER_SCHEMA is None" [D.text ("return " ++ direct ++ "(n)")], viaSchema]
        else pure [viaSchema]

nativeOut :: Env -> Type -> M [D.Doc]
nativeOut env ty
  | ty == Constructor "Unit" [] = pure [D.text "return None"]
  | otherwise = do
      ref <- lift' (pythonTypeReferenceDoc ty)
      to <- helper "to" ty
      let viaSchema = D.text "return ls.handler_schema(_lawspec_schema).to_native(" <> ref <> D.text (", " ++ to ++ "(x), " ++ show (envBits env) ++ ", symbols)")
      if nativeDirect env S.empty ty
        then do
          direct <- helper "tonative" ty
          pure [block "if ls._HANDLER_SCHEMA is None" [D.text ("return " ++ direct ++ "(x)")], viaSchema]
        else pure [viaSchema]

equality :: Env -> Type -> M [D.Doc]
equality env ty = case ty of
  _ | plainEq env ty -> pure [D.text "return a == b"]
  Constructor "List" [TypeArgument a]
    | plainEq env a -> pure [D.text "return lsf_eq_list_plain(a, b)"]
    | otherwise -> (\e -> [D.text ("return lsf_eq_list(a, b, " ++ e ++ ")")]) <$> helper "eq" a
  Constructor "Maybe" [TypeArgument a] -> do
    e <- equaler env a
    pure [D.text ("return a == b if not a or not b else " ++ e ++ "(a[0], b[0])")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    el <- equaler env a
    er <- equaler env b
    pure [D.text ("return a[0] == b[0] and (" ++ er ++ "(a[1], b[1]) if a[0] else " ++ el ++ "(a[1], b[1]))")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ek <- equaler env k
        ev <- equaler env v
        pure [D.text ("return lsf_eq_map(a, b, " ++ ek ++ ", " ++ ev ++ ")")]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        ek <- equaler env a
        pure [D.text ("return lsf_eq_map(a, b, " ++ ek ++ ", lsf_eq_unit)")]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    checks <- forM (dataConstructors d) $ \c -> forM (zip [0 :: Int ..] (fieldTypes d targs c)) $ \(k, ft) -> do
      e <- equaler env ft
      let offset = if isProductType d then k else k + 1
      pure (if e == "lsf_eq_plain" then "a[" ++ show offset ++ "] == b[" ++ show offset ++ "]"
            else e ++ "(a[" ++ show offset ++ "], b[" ++ show offset ++ "])")
    if isProductType d
      then pure [D.text "if a is b:" <> D.nest 4 (D.hardline <> D.text "return True"), D.text ("return " ++ intercalate " and " ("True" : firstOf checks))]
      else pure ([ D.text "if a is b:" <> D.nest 4 (D.hardline <> D.text "return True")
                 , D.text "if a[0] != b[0]:" <> D.nest 4 (D.hardline <> D.text "return False") ] ++
                 [ block ("if a[0] == " ++ show (rankOf d c)) [D.text ("return " ++ intercalate " and " ("True" : cs))]
                 | (c, cs) <- zip (dataConstructors d) checks, not (null cs) ] ++ [D.text "return True"])
  _ -> lift' (Left ("typed Python: no equality for " ++ show ty))

ordering :: Env -> Type -> M [D.Doc]
ordering env ty = case ty of
  _ | plainOrd env ty -> pure [D.text "return -1 if a < b else (1 if b < a else 0)"]
  Constructor "Unit" [] -> pure [D.text "return 0"]
  Constructor "List" [TypeArgument a] -> (\c -> [D.text ("return lsf_cmp_list(a, b, " ++ c ++ ")")]) <$> comparer env a
  Constructor "Maybe" [TypeArgument a] -> do
    c <- comparer env a
    pure [ block "if not a or not b" [D.text "return (len(a) > len(b)) - (len(a) < len(b))"]
         , D.text ("return " ++ c ++ "(a[0], b[0])") ]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- comparer env a
    cr <- comparer env b
    pure [ block "if a[0] != b[0]" [D.text "return -1 if a[0] < b[0] else 1"]
         , D.text ("return " ++ cr ++ "(a[1], b[1]) if a[0] else " ++ cl ++ "(a[1], b[1])") ]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ck <- comparer env k
        cv <- comparer env v
        pure [D.text ("return lsf_cmp_map(a, b, " ++ ck ++ ", " ++ cv ++ ")")]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        ck <- comparer env a
        pure [D.text ("return lsf_cmp_map(a, b, " ++ ck ++ ", lsf_cmp_unit)")]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    comparisons <- forM (dataConstructors d) $ \c -> forM (zip [0 :: Int ..] (fieldTypes d targs c)) $ \(k, ft) -> do
      cmp <- comparer env ft
      let offset = if isProductType d then k else k + 1
      pure (D.text ("c = " ++ cmp ++ "(a[" ++ show offset ++ "], b[" ++ show offset ++ "])") <> D.hardline <>
            D.text "if c:" <> D.nest 4 (D.hardline <> D.text "return c"))
    if isProductType d
      then pure (firstOf comparisons ++ [D.text "return 0"])
      else pure ([ block "if a[0] != b[0]" [D.text "return -1 if a[0] < b[0] else 1"] ] ++
                 [ block ("if a[0] == " ++ show (rankOf d c)) cs | (c, cs) <- zip (dataConstructors d) comparisons, not (null cs) ] ++
                 [D.text "return 0"])
  _ -> lift' (Left ("typed Python: no order for " ++ show ty))

-- | Whether converting a type is the identity, both ways.
sameDynamic :: Type -> Bool
sameDynamic ty = case ty of
  Constructor n [] -> n `elem` (scalarTypes \\\ ["Unit"])
  _ -> False
  where xs \\\ ys = filter (`notElem` ys) xs

converter :: String -> Type -> M String
converter kind ty = if sameDynamic ty then pure "" else helper kind ty

applyTo :: String -> String -> String
applyTo "" x = x
applyTo f x = f ++ "(" ++ x ++ ")"

toValue :: Env -> Type -> M [D.Doc]
toValue env ty = case ty of
  Constructor "Unit" [] -> pure [D.text "return ls.UNIT"]
  _ | sameDynamic ty -> pure [D.text "return x"]
  Constructor "List" [TypeArgument a] -> do
    f <- converter "to" a
    pure [D.text (if null f then "return lsf_items(x)" else "return lsf_to_list(x, " ++ f ++ ")")]
  Constructor "Maybe" [TypeArgument a] -> do
    f <- converter "to" a
    pure [D.text ("return ls.DataValue('Maybe::Just', (" ++ applyTo f "x[0]" ++ ",)) if x else ls.DataValue('Maybe::Nothing', ())")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- converter "to" a
    fr <- converter "to" b
    pure [D.text ("return ls.DataValue('Either::Right', (" ++ applyTo fr "x[1]" ++ ",)) if x[0] else ls.DataValue('Either::Left', (" ++ applyTo fl "x[1]" ++ ",))")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- converter "to" k
        fv <- converter "to" v
        pure [D.text ("return ls.DataValue(" ++ quote (collectionsUnit ++ "::type::KeyVal::KeyValEntries") ++ ", ([ls.DataValue(" ++
          quote (collectionsUnit ++ "::type::Entry::Entry") ++ ", (" ++ applyTo fk "k" ++ ", " ++ applyTo fv "v" ++ ")) for k, v in lsf_entries(x)],))")]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- converter "to" a
        pure [D.text ("return ls.DataValue(" ++ quote (collectionsUnit ++ "::type::Set::SetItems") ++ ", ([" ++ applyTo f "k" ++ " for k, _ in lsf_entries(x)],))")]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    if fieldless d
      then pure [D.text ("return ls.DataValue(" ++ tagTable d ++ "[x], ())")]
      else do
        encoders <- forM (dataConstructors d) $ \c -> mapM (converter "to") (fieldTypes d targs c)
        let fieldsOf offset es = concat [applyTo e ("x[" ++ show (k + offset) ++ "]") ++ ", " | (k, e) <- zip [0 :: Int ..] es]
        if isProductType d
          then pure [D.text ("return ls.DataValue(" ++ quote (idText (constructorId (firstOf (dataConstructors d)))) ++ ", (" ++ fieldsOf 0 (firstOf encoders) ++ "))")]
          else pure ([ block ("if x[0] == " ++ show (rankOf d c)) [D.text ("return ls.DataValue(" ++ quote (idText (constructorId c)) ++ ", (" ++ fieldsOf 1 es ++ "))")]
                     | (c, es) <- zip (dataConstructors d) encoders ] ++ [D.text "lsf_unreachable()"])
  _ -> lift' (Left ("typed Python: no conversion for " ++ show ty))

-- | A fieldless type's tags, by rank.
tagTable :: DataDeclaration -> String
tagTable d = "(" ++ concat [quote (idText (constructorId c)) ++ ", " | c <- sortOn (rankOf d) (dataConstructors d)] ++ ")"

fromValue :: Env -> Type -> M [D.Doc]
fromValue env ty = case ty of
  Constructor "Unit" [] -> pure [D.text "return None"]
  _ | sameDynamic ty -> pure [D.text "return v"]
  Constructor "List" [TypeArgument a] -> do
    f <- converter "from" a
    pure [D.text (if null f then "return lsf_list_of(v)" else "return lsf_from_list(v, " ++ f ++ ")")]
  Constructor "Maybe" [TypeArgument a] -> do
    f <- converter "from" a
    pure [D.text ("return (" ++ applyTo f "v.fields[0]" ++ ",) if v.tag == 'Maybe::Just' else ()")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- converter "from" a
    fr <- converter "from" b
    pure [D.text ("return (1, " ++ applyTo fr "v.fields[0]" ++ ") if v.tag == 'Either::Right' else (0, " ++ applyTo fl "v.fields[0]" ++ ")")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- converter "from" k
        fv <- converter "from" v
        cmp <- if plainOrd env k then pure "" else (", " ++) <$> comparer env k
        let putter = if null cmp then "lsf_put(out, " else "lsf_put_by(out, "
        pure [ D.text "out = None"
             , block "for item in v.fields[0]" [D.text ("out = " ++ putter ++ applyTo fk "item.fields[0]" ++ ", " ++ applyTo fv "item.fields[1]" ++ cmp ++ ")")]
             , D.text "return out" ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- converter "from" a
        insert <- if plainOrd env a then pure ("lsf_set_insert(out, " ++ applyTo f "item" ++ ")")
          else (\c -> "lsf_set_insert_by(out, " ++ applyTo f "item" ++ ", " ++ c ++ ")") <$> comparer env a
        pure [D.text "out = None", block "for item in v.fields[0]" [D.text ("out = " ++ insert)], D.text "return out"]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    decoders <- forM (dataConstructors d) $ \c -> mapM (converter "from") (fieldTypes d targs c)
    let made c ds
          | fieldless d = show (rankOf d c)
          | isProductType d = tupleText [applyTo dec ("v.fields[" ++ show k ++ "]") | (k, dec) <- zip [0 :: Int ..] ds]
          | otherwise = tupleText (show (rankOf d c) : [applyTo dec ("v.fields[" ++ show k ++ "]") | (k, dec) <- zip [0 :: Int ..] ds])
    pure ([ block ("if v.tag == " ++ quote (idText (constructorId c))) [D.text ("return " ++ made c ds)] | (c, ds) <- zip (dataConstructors d) decoders ] ++
          [D.text ("raise ValueError('expected " ++ dataName d ++ ", found ' + v.tag)")])
  _ -> lift' (Left ("typed Python: no conversion for " ++ show ty))

tupleText :: [String] -> String
tupleText [x] = "(" ++ x ++ ",)"
tupleText xs = "(" ++ intercalate ", " xs ++ ")"

-- | Whether a type converts to and from its generated native type
-- directly: no Unit, Duration or other collection, whose natives differ.
nativeDirect :: Env -> S.Set String -> Type -> Bool
nativeDirect env seen ty = case ty of
  Constructor n [] | n `elem` scalarTypes -> n /= "Unit"
  Constructor n [TypeArgument a] | n `elem` ["List", "Maybe"] -> nativeDirect env seen a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> nativeDirect env seen a && nativeDirect env seen b
  _ | Just (_, args) <- collectionArguments ty -> all (nativeDirect env seen) args
  Constructor n args | Just d <- M.lookup n (envData env), all (\c -> M.member (constructorId c) (envNative env)) (dataConstructors d) ->
      show ty `S.member` seen || all (nativeDirect env (S.insert (show ty) seen)) (concatMap (fieldTypes d [t | TypeArgument t <- args]) (dataConstructors d))
  _ -> False

hashableKey :: Type -> Bool
hashableKey (Constructor n []) = pythonHashable n
hashableKey _ = False

nativeConverter :: String -> Type -> M String
nativeConverter kind ty = if sameDynamic ty then pure "" else helper kind ty

toNative :: Env -> Type -> M [D.Doc]
toNative env ty = case ty of
  _ | sameDynamic ty -> pure [D.text "return x"]
  Constructor "List" [TypeArgument a] -> do
    f <- nativeConverter "tonative" a
    pure [D.text (if null f then "return lsf_items(x)" else "return lsf_to_list(x, " ++ f ++ ")")]
  Constructor "Maybe" [TypeArgument a] -> do
    f <- nativeConverter "tonative" a
    pure [D.text ("return _schema.Just(" ++ applyTo f "x[0]" ++ ") if x else _schema.Nothing()")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- nativeConverter "tonative" a
    fr <- nativeConverter "tonative" b
    pure [D.text ("return _schema.Right(" ++ applyTo fr "x[1]" ++ ") if x[0] else _schema.Left(" ++ applyTo fl "x[1]" ++ ")")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- nativeConverter "tonative" k
        fv <- nativeConverter "tonative" v
        pure [D.text (if hashableKey k
          then "return {" ++ applyTo fk "k" ++ ": " ++ applyTo fv "v" ++ " for k, v in lsf_entries(x)}"
          else "return tuple((" ++ applyTo fk "k" ++ ", " ++ applyTo fv "v" ++ ") for k, v in lsf_entries(x))")]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- nativeConverter "tonative" a
        pure [D.text ((if hashableKey a then "return frozenset(" else "return tuple(") ++ applyTo f "k" ++ " for k, _ in lsf_entries(x))")]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
        nativeOf c = "data." ++ envNative env M.! constructorId c
    converters <- forM (dataConstructors d) $ \c -> mapM (nativeConverter "tonative") (fieldTypes d targs c)
    let made offset c cs = nativeOf c ++ "(" ++ intercalate ", " [applyTo cv ("x[" ++ show (k + offset) ++ "]") | (k, cv) <- zip [0 :: Int ..] cs] ++ ")"
    if fieldless d
      then pure [D.text ("return (" ++ concat [nativeOf c ++ ", " | c <- sortOn (rankOf d) (dataConstructors d)] ++ ")[x]()")]
      else if isProductType d
        then pure [D.text ("return " ++ made 0 (firstOf (dataConstructors d)) (firstOf converters))]
        else pure ([ block ("if x[0] == " ++ show (rankOf d c)) [D.text ("return " ++ made 1 c cs)] | (c, cs) <- zip (dataConstructors d) converters ] ++
                   [D.text "lsf_unreachable()"])
  _ -> lift' (Left ("typed Python: no native conversion for " ++ show ty))

fromNative :: Env -> Type -> M [D.Doc]
fromNative env ty = case ty of
  _ | sameDynamic ty -> pure [D.text "return n"]
  Constructor "List" [TypeArgument a] -> do
    f <- nativeConverter "fromnative" a
    pure [D.text (if null f then "return lsf_list_of(n)" else "return lsf_from_list(n, " ++ f ++ ")")]
  Constructor "Maybe" [TypeArgument a] -> do
    f <- nativeConverter "fromnative" a
    pure [D.text ("return (" ++ applyTo f "n.value" ++ ",) if isinstance(n, _schema.Just) else ()")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- nativeConverter "fromnative" a
    fr <- nativeConverter "fromnative" b
    pure [D.text ("return (1, " ++ applyTo fr "n.value" ++ ") if isinstance(n, _schema.Right) else (0, " ++ applyTo fl "n.value" ++ ")")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- nativeConverter "fromnative" k
        fv <- nativeConverter "fromnative" v
        cmp <- if plainOrd env k then pure "" else (", " ++) <$> comparer env k
        let putter = if null cmp then "lsf_put(out, " else "lsf_put_by(out, "
        pure [ D.text "out = None"
             , block (if hashableKey k then "for k, v in n.items()" else "for k, v in n")
                 [D.text ("out = " ++ putter ++ applyTo fk "k" ++ ", " ++ applyTo fv "v" ++ cmp ++ ")")]
             , D.text "return out" ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- nativeConverter "fromnative" a
        insert <- if plainOrd env a then pure ("lsf_set_insert(out, " ++ applyTo f "item" ++ ")")
          else (\c -> "lsf_set_insert_by(out, " ++ applyTo f "item" ++ ", " ++ c ++ ")") <$> comparer env a
        pure [D.text "out = None", block "for item in n" [D.text ("out = " ++ insert)], D.text "return out"]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
        nativeOf c = "data." ++ envNative env M.! constructorId c
    converters <- forM (dataConstructors d) $ \c -> mapM (nativeConverter "fromnative") (fieldTypes d targs c)
    let made c cs
          | fieldless d = show (rankOf d c)
          | isProductType d = tupleText [applyTo cv ("n." ++ binderName f) | (f, cv) <- zip (constructorFields c) cs]
          | otherwise = tupleText (show (rankOf d c) : [applyTo cv ("n." ++ binderName f) | (f, cv) <- zip (constructorFields c) cs])
    if isProductType d
      then pure [D.text ("return " ++ made (firstOf (dataConstructors d)) (firstOf converters))]
      else pure ([D.text "kind = type(n)"] ++
                 [ block ("if kind is " ++ nativeOf c) [D.text ("return " ++ made c cs)] | (c, cs) <- zip (dataConstructors d) converters ] ++
                 [D.text ("raise TypeError('expected " ++ dataName d ++ "')")])
  _ -> lift' (Left ("typed Python: no native conversion for " ++ show ty))
