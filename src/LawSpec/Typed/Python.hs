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
import Data.Binary (Binary)
import GHC.Generics (Generic)
import System.IO.Unsafe (unsafePerformIO)
import LawSpec.Memo (Table, newPersistentTable, memoized)
import qualified LawSpec.Dependencies as Identity
import qualified LawSpec.Typed.EmissionContext as Context
import Data.Char (isAlphaNum, isUpper, toLower, ord)
import Data.List (intercalate, isPrefixOf, sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as S
import Numeric (showHex)
import LawSpec.Collections (collectionsUnit, collectionContainer)
import LawSpec.Core
import LawSpec.CorePersist ()
import LawSpec.Scalar
import LawSpec.Typed.Plan
import LawSpec.PythonTypes (namesFor, pythonHashable, pythonTypeReferenceDoc, pythonLayout)
import LawSpec.Time (isDurationType)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Naming as N
import LawSpec.Naming (claim, claimAll, scopeWith, localIdentifier, nativeIdentifier, NameKind(..), readableDefinitionName, typeWords, reservedFor, sourceDefinitionName)
import LawSpec.SourceLink (labelled, sourceLink)
import LawSpec.Code.Literal (literalFor)
import qualified LawSpec.PythonExpr as E

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
  , envIdentity :: Identity.Graph
  , envHelperNames :: M.Map (String,String) String
  , envBits :: Int
  }

-- Names are their source names (LawSpec.Naming): each function's locals
-- are claimed afresh from the module's names, and each helper is named
-- for its kind and type (to_settings), with _2 only on a clash.
data St = St { stLocals :: N.Scope, stBase :: N.Scope, stModule :: N.Scope, stNames :: M.Map (String, String) String
             , stShown :: M.Map String String
             , stHelpers :: M.Map String Type, stWanted :: S.Set (String, String) } deriving (Show, Generic)

instance Binary St

type M = StateT St (Either String)

lift' :: Either String a -> M a
lift' = lift

fresh :: String -> M String
fresh base = do
  s <- get
  let (name, scope) = claim (stLocals s) (localIdentifier "python" base)
  put s { stLocals = scope }
  pure name

-- | A function's locals start from the module's names.
enterFunction :: M ()
enterFunction = modify (\s -> s { stLocals = stBase s })

-- | A helper of a kind for a type, named by the type.
helper :: String -> Type -> M String
helper kind ty = do
  let key = show ty
  st <- get
  case M.lookup (kind,key) (stNames st) of
    Nothing -> lift' (Left ("typed Python: unplanned helper " ++ kind ++ " " ++ key))
    Just name -> do
      put st { stHelpers = M.insert key ty (stHelpers st), stWanted = S.insert (kind,key) (stWanted st) }
      pure name

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
      -- Each typed function is named after its definition.
      (functionNames, moduleScope) = claimAll (scopeWith (reservedFor "python" ++ moduleReserved))
        [ nativeIdentifier "python" FunctionName (readableDefinitionName (declarationName (definitionDeclaration d))
            (fst (functionType (declarationType (definitionDeclaration d)))))
        | (_, d) <- typedRepresentatives plan ]
      functions = M.fromList (zip (map fst (typedRepresentatives plan)) functionNames)
  names <- namesFor [d | d <- declarations, collectionContainer (idText (dataId d)) == Nothing, not (isDurationType (idText (dataId d))), not (dataHandle d)]
  let env = Env plan (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions
        (M.fromList names) units graph helperNames bits
      typedHandlers = [ h | u <- units, h <- unitHandlers u, isTypedHandler plan h ]
      handlerTypes = [ t | h <- typedHandlers, ref <- handlerAbilities h, Just (_, a) <- [findAbility units ref]
                         , (_, ty) <- abilityOperations a, let (args, result) = functionType ty, t <- result : args ] ++
                     [ t | h <- typedHandlers, Just (t, _) <- [handlerState h] ] ++
                     [ failure | h <- typedHandlers, ref <- handlerAbilities h, Just (_, a) <- [findAbility units ref]
                               , (_, AbilityRef _ [failure]) <- abilityFailures a ]
      boundary = concat [ let (args, result) = functionType (declarationType (definitionDeclaration d)) in result : args
                        | d <- M.elems (typedDefinitions plan) ]
      (startNames, startScope) = claimAll moduleScope
        [ "start_" ++ nativeIdentifier "python" FunctionName (handlerName h) | h <- typedHandlers, Just _ <- [handlerState h] ]
      starts = [ (handlerId h, name, start) | (h, name) <- zip [h | h <- typedHandlers, Just _ <- [handlerState h]] startNames
               , Just (_, start) <- [handlerState h] ]
      graph = Identity.dependencyGraphWithBits bits declarations units
      allTypes = Context.typeClosure (envData env) (boundary ++ handlerTypes ++
        concatMap (Context.definitionTypes . snd) (typedRepresentatives plan) ++ concatMap (Context.expressionTypes . third) starts)
      third (_,_,value) = value
      helperNames = Context.helperAllocation graph (functionNames ++ startNames ++ reservedFor "python" ++ moduleReserved)
        (\kind ty -> kind ++ "_" ++ intercalate "_" (typeSlug (M.fromList [(idText i,n) | (i,n) <- names]) ty))
        helperKinds allTypes
      startState = St startScope startScope startScope helperNames (M.fromList [(idText i, n) | (i, n) <- names]) M.empty S.empty
  ((functionDocs, startDocs, helperDocs), final) <- flip runStateT startState $ do
    fs <- mapM (\(c, d) -> memoFunction env c d) (typedRepresentatives plan)
    ss <- forM starts $ \(_, name, start) -> do
      enterFunction
      body <- cstmt env Nothing [(Id "lawspec::symbols", "symbols")] Return start
      pure (block ("def " ++ name ++ "(symbols)") body)
    forM_ boundary $ \t -> helper "to" t >> helper "from" t
    forM_ handlerTypes $ \t -> helper "nin" t >> helper "nout" t
    hs <- helpers env
    pure (fs, ss, hs)
  let line = D.text
      definitionsDoc = D.joinWith (D.hardline <> D.hardline <> D.hardline) (orderingHelper env ++ functionDocs ++ startDocs ++ helperDocs)
      -- Only the runtime functions the module calls are imported.
      used = words (map (\c -> if isAlphaNum c || c == '_' then c else ' ') (D.render D.Compact definitionsDoc))
      imported = [n | n <- runtimeNames, ("lsf_" ++ n) `elem` used]
      header = map line
        [ "# Generated by LawSpec. Do not edit."
        , "\"\"\"Typed checked definitions over lawspec_fast's values; see"
        , "docs/how-to/embed-a-generated-model.md.\"\"\""
        , ""
        , "import lawspec_data as data"
        , "import lawspec_runtime as ls"
        , "import lawspec_schema as _schema" ] ++
        [ importFrom "lawspec_fast" [line (n ++ " as lsf_" ++ n) | n <- imported] | not (null imported) ] ++
        [ line ""
        , line "_lawspec_schema = data.make_schema()" ] ++
        [ line "# The machine profile's integer width." <> D.hardline <> line ("MACHINE_BITS = " ++ show bits)
        | "MACHINE_BITS" `elem` used ]
      source = D.render pythonLayout (D.joinWith D.hardline header <> D.hardline <> D.hardline <> D.hardline <>
        definitionsDoc) ++ "\n"
      helperOf kind t = M.findWithDefault (kind ++ "_" ++ intercalate "_" (typeSlug M.empty t)) (kind, show t) (stNames final)
  pure PythonTyped
    { pyTypedModule = source
    , pyTypedFunction = \i -> definitionClass plan i >>= (`M.lookup` functions)
    , pyTypedFrom = helperOf "from"
    , pyTypedTo = helperOf "to"
    , pyTypedNativeIn = helperOf "nin"
    , pyTypedNativeOut = helperOf "nout"
    , pyTypedStart = \h -> case [n | (i, n, _) <- starts, i == h] of
        n : _ -> Just n
        [] -> Nothing
    , pyTypedPlan = plan }
  where

-- | A type's words for a helper's name, with data types by the names the
-- generated code shows them (an anonymous record's display name).
typeSlug :: M.Map String String -> Type -> [String]
typeSlug shown ty = case ty of
  Constructor n args | Just name <- M.lookup n shown ->
    N.nameWords name ++ concat [typeSlug shown t | TypeArgument t <- args]
  Constructor n args -> typeWords (Constructor n []) ++ concat [typeSlug shown t | TypeArgument t <- args]
  _ -> typeWords ty

-- | from module import names, parenthesised only when it breaks, as ruff
-- writes it.
importFrom :: String -> [D.Doc] -> D.Doc
importFrom name items = D.group (D.text ("from " ++ name ++ " import ") <> D.whenBroken (D.text "(") <>
  D.nest 4 (D.softbreak <> D.commaSep items <> D.whenBroken (D.text ",")) <> D.softbreak <> D.whenBroken (D.text ")"))

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
    in [block "def ordering_of(c)" [D.text ("return " ++ show (rank "Less") ++ " if c < 0 else (" ++ show (rank "Equal") ++ " if c == 0 else " ++ show (rank "Greater") ++ ")")]]

-- Statements.

block :: String -> [D.Doc] -> D.Doc
block header body = D.text (header ++ ":") <> D.nest 4 (D.hardline <> D.joinWith D.hardline (if null body then [D.text "pass"] else body))

blockD :: D.Doc -> [D.Doc] -> D.Doc
blockD header body = header <> D.text ":" <> D.nest 4 (D.hardline <> D.joinWith D.hardline (if null body then [D.text "pass"] else body))

-- | A parenthesised expression; its contents break inside the parentheses.
paren :: D.Doc -> D.Doc
paren = D.parens

-- | A binary operator, parenthesised; it breaks before the operator.
infixD :: D.Doc -> String -> D.Doc -> D.Doc
infixD a op b = D.operation [a, b] [op]

-- | A conditional expression, without parentheses.
ternary :: D.Doc -> D.Doc -> D.Doc -> D.Doc
ternary yes condition no = yes <> D.softline <> D.text "if " <> condition <> D.softline <> D.text "else " <> no

-- | return with a conditional, parenthesised only when it breaks.
returnTernary :: D.Doc -> D.Doc -> D.Doc -> D.Doc
returnTernary yes condition no = D.text "return " <> D.unparen (D.parens (ternary yes condition no))

callD :: String -> [D.Doc] -> D.Doc
callD = E.call

data Target = Return | Assign String

type Scope = [(Id, String)]

symbolsId :: Id
symbolsId = Id "lawspec::symbols"

moduleReserved :: [String]
moduleReserved = ["data", "ls", "symbols", "ordering_of", "MACHINE_BITS"] ++ ["lsf_" ++ n | n <- runtimeNames]

helperKinds :: [String]
helperKinds = ["eq", "cmp", "to", "from", "nin", "nout", "tonative", "fromnative"]

functionTable :: Table (Either String (D.Doc, St))
functionTable = unsafePerformIO (newPersistentTable "typed-python-function" (8 * 1024 * 1024) (length . show))
{-# NOINLINE functionTable #-}

memoFunction :: Env -> Int -> Definition -> M D.Doc
memoFunction env classification definition = do
  before <- get
  let calls = Context.calledFunctions (envPlan env) (envFunctions env) classification definition
      types = Context.typeClosure (envData env) (Context.definitionTypes definition)
      helpersForFunction = [(kind,show ty,name) | ty <- types, kind <- helperKinds,
        Just name <- [M.lookup (kind,show ty) (envHelperNames env)]]
      names = scopeWith ([name | (name,_,_,_) <- calls] ++ [name | (_,_,name) <- helpersForFunction] ++ moduleReserved ++
        reservedFor "python")
      allocated = M.fromList [((kind,ty),name) | (kind,ty,name) <- helpersForFunction]
      own = St names names names allocated (stShown before) M.empty S.empty
      reached = Identity.reachableData (envIdentity env) (Identity.closure (envIdentity env)
        (Identity.referencesOf (envIdentity env) definition))
      nativeNames = [(identity,M.lookup identity (envNative env)) | declaration <- reached,
        identity <- dataId declaration : map constructorId (dataConstructors declaration)]
      key = Identity.fullKey (envIdentity env) ("typed-python:" ++ show (envBits env,calls,helpersForFunction,nativeNames)) definition
  (document,requested) <- lift' (memoized functionTable key (runStateT (functionDoc env classification definition) own))
  put before { stHelpers = M.union (stHelpers requested) (stHelpers before)
             , stWanted = S.union (stWanted requested) (stWanted before) }
  pure document

functionDoc :: Env -> Int -> Definition -> M D.Doc
functionDoc env c d = do
  let declaration = definitionDeclaration d
      name = envFunctions env M.! c
      contextual = isContextual (envPlan env) (declarationId declaration)
  enterFunction
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
  pure (D.lineComment 88 "# " (labelled (sourceDefinitionName (declarationName declaration)) (sourceLink (declarationOrigin declaration))) <>
    blockD (D.text ("def " ++ name) <> D.delimitTrailing 4 "(" ")" (map D.text (["symbols" | contextual] ++ map snd params)))
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
deliver Return x = D.text "return " <> D.statementValue x
deliver (Assign name) x = D.text (name ++ " = ") <> D.statementValue x

cstmt :: Env -> Maybe (Int, [String]) -> Scope -> Target -> Expr -> M [D.Doc]
cstmt env selfCall scope target e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    local <- fresh (binderName binder)
    rest <- cstmt env selfCall ((binderId binder, local) : scope) target body
    pure (s ++ [D.text (local ++ " = ") <> D.statementValue x] ++ rest)
  If c a b -> do
    (s, x) <- cexpr env scope c
    yes <- cstmt env selfCall scope target a
    no <- cstmt env selfCall scope target b
    pure (s ++ [blockD (D.text "if " <> D.unparen x) yes, block "else" no])
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
          t <- fresh "next_value"
          pure (s ++ [D.text (t ++ " = ") <> D.statementValue x], D.text (p ++ " = " ++ t))
        pure (concatMap fst evaluated ++ map snd evaluated ++ [D.text "continue"])
  Helper Unreachable _ -> pure [D.text "lsf_unreachable()"]
  Perform (Operation ref "raise") [_] | isFail ref -> fst <$> cexpr env scope e
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
        pure (concatMap fst parts, callD (envFunctions env M.! c) (context ++ map snd parts))
  ShortCircuit op a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    if null sb
      then pure (sa, infixD xa (if op == And then "and" else "or") xb)
      else do
        t <- fresh "logic"
        pure (sa ++ [ D.text (t ++ " = ") <> D.statementValue xa
                    , blockD (D.text (if op == And then "if " ++ t else "if not " ++ t)) (sb ++ [D.text (t ++ " = ") <> D.statementValue xb]) ], D.text t)
  Unary Not a -> do
    (s, x) <- cexpr env scope a
    pure (s, paren (D.prefixed "not" x))
  Unary Negate a -> do
    (s, x) <- cexpr env scope a
    pure (s, paren (D.text "-" <> x))
  Binary op (Structural t) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    if plainEq env t
      then pure (sa ++ sb, infixD xa (if op == Equal then "==" else "!=") xb)
      else do
        eq <- helper "eq" t
        let test = callD eq [xa, xb]
        pure (sa ++ sb, if op == Equal then test else paren (D.prefixed "not" test))
  Binary op (Numeric _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    let infix' symbol = pure (sa ++ sb, infixD xa symbol xb)
        call f = pure (sa ++ sb, callD f [xa, xb])
    case op of
      Add -> infix' "+"
      Subtract -> infix' "-"
      Multiply -> infix' "*"
      Quotient -> call "lsf_quot"
      Remainder -> call "lsf_rem"
      Power -> call "lsf_power"
      Equal -> infix' "=="
      NotEqual -> infix' "!="
      Less -> infix' "<"
      LessEqual -> infix' "<="
      Greater -> infix' ">"
      GreaterEqual -> infix' ">="
      _ -> lift' (Left ("typed Python: unsupported operator " ++ show op))
  Convert _ target value -> convert env scope target value
  Helper Compare [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    cmp <- comparer env (expressionType a)
    pure (sa ++ sb, callD "ordering_of" [callD cmp [xa, xb]])
  Helper Length [x] -> do
    (s, v) <- cexpr env scope x
    pure (s, case expressionType x of
      Constructor n [] | n `elem` ["Text", "Bytes"] -> callD "len" [v]
      _ -> D.text "lsf_length(" <> v <> D.text ")")
  Helper Unreachable _ -> pure ([D.text "lsf_unreachable()"], D.text "None")
  Helper Checked _ -> pure ([], D.text "True")
  Helper StartsWith [a, b] -> method "startswith" a b
  Helper EndsWith [a, b] -> method "endswith" a b
  Helper TextContains [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    pure (sa ++ sb, infixD xb "in" xa)
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
    pure (s ++ [D.text "raise " <> callD "ls.Failure" [D.text (quote (abilityKey ref)), callD to [v]]], D.text "None")
  -- An operation of another ability: its handler in the context, called
  -- with native values, as the dynamic code calls it.
  Perform op args -> do
    parts <- mapM (cexpr env scope) args
    outs <- mapM (helper "nout" . expressionType) args
    nin <- helper "nin" (expressionType e)
    r <- fresh "performed"
    let call = callD "ls.handler" [D.text "symbols", D.text (quote (abilityKey (operationAbility op)))] <> D.text "." <>
          callD (operationName op) [callD o [x, D.text "symbols"] | (o, x) <- zip outs (map snd parts)]
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
                [D.text "raise " <> callD "ls.Failure" [D.text (quote (abilityKey failing)),
                   E.handlerSchemaCall "from_native" [ref, D.text "error.value", D.text "MACHINE_BITS", D.text "symbols"]] <>
                 D.text " from error"] ]
    pure (concatMap fst parts ++ invoke, callD nin [D.text r, D.text "symbols"])
  -- attempt e: Right of e's value, or Left of the failure it raised.
  Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, _] <- expressionType e -> do
    t <- fresh "attempted"
    from <- helper "from" failure
    (s, v) <- cexpr env scope body
    pure ([ block "try" (s ++ [D.text (t ++ " = (1, ") <> v <> D.text ")"])
          , block "except ls.Failure as failure"
              [ blockD (D.text "if " <> D.unparen (infixD (D.text "failure.ability") "!=" (D.text (quote (abilityKey ref))))) [D.text "raise"]
              , D.text (t ++ " = (0, " ++ from ++ "(failure.value))") ] ], D.text t)
  Helper Append [a, b] -> case expressionType a of
    Constructor n [] | n `elem` ["Text", "Bytes"] -> do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, infixD xa "+" xb)
    _ -> call2 "lsf_append" a b
  Helper Slice [x, from, to] -> do
    (sx, v) <- cexpr env scope x
    (si, i) <- cexpr env scope from
    (sj, j) <- cexpr env scope to
    let f = case expressionType x of
          Constructor n [] | n `elem` ["Text", "Bytes"] -> "lsf_slice_seq"
          _ -> "lsf_slice_list"
    pure (sx ++ si ++ sj, callD f [v, i, j])
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
      pure (s, callD f [x])
    call2 f a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, callD f [xa, xb])
    method m a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, xa <> D.text "." <> callD m [xb])
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
quote = literalFor "python"

constant :: Scalar -> Either String D.Doc
constant s = case s of
  SBool b -> pure (D.text (if b then "True" else "False"))
  SAbsent "Unit" -> pure (D.text "None")
  SInteger _ n -> pure (if n < 0 then D.parens (D.text (show n)) else D.text (show n))
  SSequence "Text" units -> pure (D.text (quote (map toEnum units)))
  SSequence "Bytes" units -> pure (E.bytesLiteral units)
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
        pure (s ++ [ D.text (v ++ " = ") <> D.statementValue x
                   , block ("if " ++ v ++ " < " ++ showInt lo ++ " or " ++ v ++ " > " ++ showInt hi) [D.text ("lsf_outside(" ++ quote t ++ ")")] ], D.text v)
    _ -> pure (s, x)
  where showInt n = if n < 0 then "(" ++ show n ++ ")" else show n

construct :: Env -> Type -> Id -> [D.Doc] -> M D.Doc
construct env ty tag values = case (idText tag, values) of
  ("List::Nil", []) -> pure (D.text "None")
  ("List::Cons", [h, t]) -> pure (callD "lsf_cons" [h, t])
  ("Maybe::Absent", []) -> pure (D.text "()")
  ("Maybe::Present", [x]) -> pure (tuple [x])
  ("Either::Left", [x]) -> pure (tuple [D.text "0", x])
  ("Either::Right", [x]) -> pure (tuple [D.text "1", x])
  (_, [items]) | Just ("KeyVal", [k, _]) <- collectionArguments ty ->
    if plainOrd env k then pure (callD "lsf_key_val_of" [items])
    else (\cmp -> callD "lsf_key_val_of_by" [items, D.text cmp]) <$> comparer env k
  (_, [items]) | Just ("Set", [a]) <- collectionArguments ty ->
    if plainOrd env a then pure (callD "lsf_set_of" [items])
    else (\cmp -> callD "lsf_set_of_by" [items, D.text cmp]) <$> comparer env a
  _ -> case M.lookup tag (envConstructors env) of
    Just (d, c)
      | fieldless d -> pure (D.text (show (rankOf d c)))
      | isProductType d -> pure (tuple values)
      | otherwise -> pure (tuple (D.text (show (rankOf d c)) : values))
    Nothing -> lift' (Left ("typed Python: unknown constructor " ++ idText tag))

-- | A tuple; a one-tuple keeps its comma however it breaks.
tuple :: [D.Doc] -> D.Doc
tuple [x] = D.group (D.text "(" <> D.nest 4 (D.softbreak <> x <> D.text ",") <> D.softbreak <> D.text ")")
tuple xs = D.delimitTrailing 4 "(" ")" xs

intrinsicCall :: Env -> Intrinsic -> [(D.Doc, Type)] -> M D.Doc
intrinsicCall env intrinsic args = case (intrinsic, args) of
  (KeyValOf, [(es, Constructor "List" [TypeArgument (Constructor _ [TypeArgument k, _])])]) -> keyed k "lsf_key_val_of" [es]
  (KeyValLookup, [(k, kt), (m, _)]) -> keyed kt "lsf_lookup" [m, k]
  (KeyValPut, [(k, kt), (v, _), (m, _)]) -> keyed kt "lsf_put" [m, k, v]
  (KeyValDelete, [(k, kt), (m, _)]) -> keyed kt "lsf_delete" [m, k]
  (KeyValKeys, [(m, _)]) -> pure (callD "lsf_keys_list" [m])
  (KeyValValues, [(m, _)]) -> pure (callD "lsf_values_list" [m])
  (KeyValEntries, [(m, _)]) -> pure (callD "lsf_entries_list" [m])
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
      | plainOrd env kt = pure (callD f xs)
      | otherwise = do
          cmp <- comparer env kt
          pure (callD (f ++ "_by") (xs ++ [D.text cmp]))
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
      pure (s ++ [D.text (t ++ " = ") <> D.statementValue x], t)
  let two condition yesTag yesAccess noTag noAccess = do
        yes <- orUnreachable yesTag yesAccess
        no <- orUnreachable noTag noAccess
        pure (prelude ++ [block ("if " ++ condition) yes, block "else" no])
  case ty of
    Constructor "Maybe" _ -> two subject "Maybe::Present" [subject ++ "[0]"] "Maybe::Absent" []
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
        docs <- forM pending $ \(kind, key) -> memoHelper env kind (stHelpers st M.! key)
        rest <- go (S.union done (S.fromList pending))
        pure (docs ++ rest)

helperTable :: Table (Either String (D.Doc,St))
helperTable = unsafePerformIO (newPersistentTable "typed-python-helper" (4 * 1024 * 1024) (length . show))
{-# NOINLINE helperTable #-}

memoHelper :: Env -> String -> Type -> M D.Doc
memoHelper env kind ty = do
  before <- get
  let types = Context.typeClosure (envData env) [ty]
      selected = [((helperKind,show value),name) | value <- types, helperKind <- helperKinds,
        Just name <- [M.lookup (helperKind,show value) (envHelperNames env)]]
      names = scopeWith (moduleReserved ++ reservedFor "python" ++ map snd selected)
      own = St names names names (M.fromList selected) (stShown before) M.empty S.empty
      declarations = [declaration | Constructor name _ <- types, Just declaration <- [M.lookup name (envData env)]]
      nativeNames = [(identity,M.lookup identity (envNative env)) | declaration <- declarations,
        identity <- dataId declaration : map constructorId (dataConstructors declaration)]
      key = Identity.fullKey (envIdentity env) ("typed-python-helper:" ++ show (envBits env,kind,selected,nativeNames)) ty
  (document,requested) <- lift' (memoized helperTable key (runStateT (helperDoc env kind ty) own))
  put before { stHelpers = M.union (stHelpers requested) (stHelpers before),
               stWanted = S.union (stWanted requested) (stWanted before) }
  pure document

helperDoc :: Env -> String -> Type -> M D.Doc
helperDoc env kind ty = do
  enterFunction
  name <- helper kind ty
  let fn params body = D.text ("# " ++ helperPurpose kind ++ " " ++ prettyTypeOf ty ++ ".") <> D.hardline <> block ("def " ++ name ++ "(" ++ params ++ ")") body
  case kind of
    "eq" -> fn "a, b" <$> equality env ty
    "cmp" -> fn "a, b" <$> ordering env ty
    "to" -> fn "x" <$> toValue env ty
    "from" -> fn "v" <$> fromValue env ty
    "tonative" -> fn "x" <$> toNative env ty
    "fromnative" -> fn "n" <$> fromNative env ty
    "nin" -> fn "n, symbols" <$> nativeIn env ty
    _ -> fn "x, symbols" <$> nativeOut env ty

-- | What a helper does, for its comment.
helperPurpose :: String -> String
helperPurpose kind = case kind of
  "eq" -> "Equality of"
  "cmp" -> "The order of"
  "to" -> "To the dynamic value of a"
  "from" -> "From the dynamic value of a"
  "tonative" -> "To the native value of a"
  "fromnative" -> "From the native value of a"
  "nin" -> "From a handler's native value of a"
  _ -> "To a handler's native value of a"

-- | A type as LawSpec writes it, for comments.
prettyTypeOf :: Type -> String
prettyTypeOf ty = case ty of
  Constructor n [] -> shortName n
  Constructor n args -> unwords (shortName n : [argument t | TypeArgument t <- args])
  TypeVariable v -> idText v
  Arrow a b -> prettyTypeOf a ++ " -> " ++ prettyTypeOf b
  where
    argument t@(Constructor _ (_ : _)) = "(" ++ prettyTypeOf t ++ ")"
    argument t = prettyTypeOf t
    shortName n = case break (== ':') n of
      (_, ':' : ':' : rest) -> shortName rest
      (whole, _) -> whole

-- | Native -> typed: directly where the native types are the generated
-- ones, through the handler schema where bindings replace them.
nativeIn :: Env -> Type -> M [D.Doc]
nativeIn env ty
  | ty == Constructor "Unit" [] = pure [D.text "return None"]
  | otherwise = do
      ref <- lift' (pythonTypeReferenceDoc ty)
      from <- helper "from" ty
      let viaSchema = D.text "return " <> callD from [E.handlerSchemaCall "from_native"
            [ref, D.text "n", D.text "MACHINE_BITS", D.text "symbols"]]
      if nativeDirect env S.empty ty
        then do
          direct <- helper "fromnative" ty
          pure [block "if ls._HANDLER_SCHEMA is None" [D.text "return " <> callD direct [D.text "n"]], viaSchema]
        else pure [viaSchema]

nativeOut :: Env -> Type -> M [D.Doc]
nativeOut env ty
  | ty == Constructor "Unit" [] = pure [D.text "return None"]
  | otherwise = do
      ref <- lift' (pythonTypeReferenceDoc ty)
      to <- helper "to" ty
      let viaSchema = D.text "return " <> E.handlerSchemaCall "to_native"
            [ref, callD to [D.text "x"], D.text "MACHINE_BITS", D.text "symbols"]
      if nativeDirect env S.empty ty
        then do
          direct <- helper "tonative" ty
          pure [block "if ls._HANDLER_SCHEMA is None" [D.text "return " <> callD direct [D.text "x"]], viaSchema]
        else pure [viaSchema]

-- | Names as documents.
v :: String -> D.Doc
v = D.text

-- | f(x), or x when no conversion is needed.
applyD :: String -> D.Doc -> D.Doc
applyD "" x = x
applyD f x = callD f [x]

-- | a and b and ..., parenthesised only when it breaks after return.
returnAll :: [D.Doc] -> D.Doc
returnAll [] = D.text "return True"
returnAll [x] = D.text "return " <> x
returnAll xs = D.text "return " <> D.unparen (D.operation xs (replicate (length xs - 1) "and"))

equality :: Env -> Type -> M [D.Doc]
equality env ty = case ty of
  _ | plainEq env ty -> pure [D.text "return a == b"]
  Constructor "List" [TypeArgument a]
    | plainEq env a -> pure [D.text "return lsf_eq_list_plain(a, b)"]
    | otherwise -> (\e -> [D.text "return " <> callD "lsf_eq_list" [v "a", v "b", v e]]) <$> helper "eq" a
  Constructor "Maybe" [TypeArgument a] -> do
    e <- equaler env a
    pure [returnTernary (v "a == b") (v "not a or not b") (callD e [v "a[0]", v "b[0]"])]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    el <- equaler env a
    er <- equaler env b
    pure [returnAll [v "a[0] == b[0]", paren (ternary (callD er [v "a[1]", v "b[1]"]) (v "a[0]") (callD el [v "a[1]", v "b[1]"]))]]
  _ | Just ("KeyVal", [k, val]) <- collectionArguments ty -> do
        ek <- equaler env k
        ev <- equaler env val
        pure [D.text "return " <> callD "lsf_eq_map" [v "a", v "b", v ek, v ev]]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        ek <- equaler env a
        pure [D.text "return " <> callD "lsf_eq_map" [v "a", v "b", v ek, v "lsf_eq_unit"]]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    checks <- forM (dataConstructors d) $ \c -> forM (zip [0 :: Int ..] (fieldTypes d targs c)) $ \(k, ft) -> do
      e <- equaler env ft
      let offset = if isProductType d then k else k + 1
          field side = v (side ++ "[" ++ show offset ++ "]")
      pure (if e == "lsf_eq_plain" then field "a" <> v " == " <> field "b"
            else callD e [field "a", field "b"])
    if isProductType d
      then pure [block "if a is b" [v "return True"], returnAll (firstOf checks)]
      else pure ([ block "if a is b" [v "return True"]
                 , block "if a[0] != b[0]" [v "return False"] ] ++
                 [ block ("if a[0] == " ++ show (rankOf d c)) [returnAll cs]
                 | (c, cs) <- zip (dataConstructors d) checks, not (null cs) ] ++ [v "return True"])
  _ -> lift' (Left ("typed Python: no equality for " ++ show ty))

ordering :: Env -> Type -> M [D.Doc]
ordering env ty = case ty of
  _ | plainOrd env ty -> pure [D.text "return -1 if a < b else (1 if b < a else 0)"]
  Constructor "Unit" [] -> pure [D.text "return 0"]
  Constructor "List" [TypeArgument a] -> (\c -> [D.text "return " <> callD "lsf_cmp_list" [v "a", v "b", v c]]) <$> comparer env a
  Constructor "Maybe" [TypeArgument a] -> do
    c <- comparer env a
    pure [ block "if not a or not b" [D.text "return (len(a) > len(b)) - (len(a) < len(b))"]
         , D.text "return " <> callD c [v "a[0]", v "b[0]"] ]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- comparer env a
    cr <- comparer env b
    pure [ block "if a[0] != b[0]" [D.text "return -1 if a[0] < b[0] else 1"]
         , returnTernary (callD cr [v "a[1]", v "b[1]"]) (v "a[0]") (callD cl [v "a[1]", v "b[1]"]) ]
  _ | Just ("KeyVal", [k, val]) <- collectionArguments ty -> do
        ck <- comparer env k
        cv <- comparer env val
        pure [D.text "return " <> callD "lsf_cmp_map" [v "a", v "b", v ck, v cv]]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        ck <- comparer env a
        pure [D.text "return " <> callD "lsf_cmp_map" [v "a", v "b", v ck, v "lsf_cmp_unit"]]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    comparisons <- forM (dataConstructors d) $ \c -> forM (zip [0 :: Int ..] (fieldTypes d targs c)) $ \(k, ft) -> do
      cmp <- comparer env ft
      let offset = if isProductType d then k else k + 1
      pure (D.text "c = " <> callD cmp [v ("a[" ++ show offset ++ "]"), v ("b[" ++ show offset ++ "]")] <> D.hardline <>
            block "if c" [v "return c"])
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

-- | A dynamic data value: ls.DataValue(tag, (fields...)).
dataValue :: String -> [D.Doc] -> D.Doc
dataValue tag fields = callD "ls.DataValue" [v (quote tag), if null fields then v "()" else tuple fields]

toValue :: Env -> Type -> M [D.Doc]
toValue env ty = case ty of
  Constructor "Unit" [] -> pure [D.text "return ls.UNIT"]
  _ | sameDynamic ty -> pure [D.text "return x"]
  Constructor "List" [TypeArgument a] -> do
    f <- converter "to" a
    pure [D.text "return " <> (if null f then callD "lsf_items" [v "x"] else callD "lsf_to_list" [v "x", v f])]
  Constructor "Maybe" [TypeArgument a] -> do
    f <- converter "to" a
    pure [returnTernary (dataValue "Maybe::Present" [applyD f (v "x[0]")]) (v "x") (dataValue "Maybe::Absent" [])]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- converter "to" a
    fr <- converter "to" b
    pure [returnTernary (dataValue "Either::Right" [applyD fr (v "x[1]")]) (v "x[0]") (dataValue "Either::Left" [applyD fl (v "x[1]")])]
  _ | Just ("KeyVal", [k, val]) <- collectionArguments ty -> do
        fk <- converter "to" k
        fv <- converter "to" val
        let entry = dataValue (collectionsUnit ++ "::type::Entry::Entry") [applyD fk (v "k"), applyD fv (v "v")]
        pure [D.text "return " <> callD "ls.DataValue" [v (quote (collectionsUnit ++ "::type::KeyVal::KeyValEntries")),
          tuple [comprehension "[" "]" entry "for k, v in lsf_entries(x)"]]]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- converter "to" a
        pure [D.text "return " <> callD "ls.DataValue" [v (quote (collectionsUnit ++ "::type::Set::SetItems")),
          tuple [comprehension "[" "]" (applyD f (v "k")) "for k, _ in lsf_entries(x)"]]]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    if fieldless d
      then pure [D.text "return " <> callD "ls.DataValue" [tagTable d <> v "[x]", v "()"]]
      else do
        encoders <- forM (dataConstructors d) $ \c -> mapM (converter "to") (fieldTypes d targs c)
        let fieldsOf offset es = [applyD e (v ("x[" ++ show (k + offset) ++ "]")) | (k, e) <- zip [0 :: Int ..] es]
        if isProductType d
          then pure [D.text "return " <> dataValue (idText (constructorId (firstOf (dataConstructors d)))) (fieldsOf 0 (firstOf encoders))]
          else pure ([ block ("if x[0] == " ++ show (rankOf d c)) [D.text "return " <> dataValue (idText (constructorId c)) (fieldsOf 1 es)]
                     | (c, es) <- zip (dataConstructors d) encoders ] ++ [D.text "lsf_unreachable()"])
  _ -> lift' (Left ("typed Python: no conversion for " ++ show ty))

-- | A comprehension: [element for ...], broken as ruff breaks it.
comprehension :: String -> String -> D.Doc -> String -> D.Doc
comprehension open close element clauses = D.group (D.text open <> D.nest 4 (D.softbreak <>
  D.group (element <> D.softline <> D.text clauses)) <> D.softbreak <> D.text close)

-- | A fieldless type's tags, by rank.
tagTable :: DataDeclaration -> D.Doc
tagTable d = tuple [v (quote (idText (constructorId c))) | c <- sortOn (rankOf d) (dataConstructors d)]

fromValue :: Env -> Type -> M [D.Doc]
fromValue env ty = case ty of
  Constructor "Unit" [] -> pure [D.text "return None"]
  _ | sameDynamic ty -> pure [D.text "return v"]
  Constructor "List" [TypeArgument a] -> do
    f <- converter "from" a
    pure [D.text "return " <> (if null f then callD "lsf_list_of" [v "v"] else callD "lsf_from_list" [v "v", v f])]
  Constructor "Maybe" [TypeArgument a] -> do
    f <- converter "from" a
    pure [returnTernary (tuple [applyD f (v "v.fields[0]")]) (v ("v.tag == " ++ quote "Maybe::Present")) (v "()")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- converter "from" a
    fr <- converter "from" b
    pure [returnTernary (tuple [v "1", applyD fr (v "v.fields[0]")]) (v ("v.tag == " ++ quote "Either::Right"))
      (tuple [v "0", applyD fl (v "v.fields[0]")])]
  _ | Just ("KeyVal", [k, val]) <- collectionArguments ty -> do
        fk <- converter "from" k
        fv <- converter "from" val
        cmp <- if plainOrd env k then pure [] else (\c -> [v c]) <$> comparer env k
        let putter = if null cmp then "lsf_put" else "lsf_put_by"
        pure [ D.text "out = None"
             , block "for item in v.fields[0]" [D.text "out = " <> callD putter ([v "out", applyD fk (v "item.fields[0]"), applyD fv (v "item.fields[1]")] ++ cmp)]
             , D.text "return out" ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- converter "from" a
        insert <- if plainOrd env a then pure (callD "lsf_set_insert" [v "out", applyD f (v "item")])
          else (\c -> callD "lsf_set_insert_by" [v "out", applyD f (v "item"), v c]) <$> comparer env a
        pure [D.text "out = None", block "for item in v.fields[0]" [D.text "out = " <> insert], D.text "return out"]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    decoders <- forM (dataConstructors d) $ \c -> mapM (converter "from") (fieldTypes d targs c)
    let made c ds
          | fieldless d = v (show (rankOf d c))
          | isProductType d = tuple [applyD dec (v ("v.fields[" ++ show k ++ "]")) | (k, dec) <- zip [0 :: Int ..] ds]
          | otherwise = tuple (v (show (rankOf d c)) : [applyD dec (v ("v.fields[" ++ show k ++ "]")) | (k, dec) <- zip [0 :: Int ..] ds])
    pure ([ blockD (D.text "if " <> D.unparen (infixD (v "v.tag") "==" (v (quote (idText (constructorId c)))))) [D.text "return " <> made c ds]
          | (c, ds) <- zip (dataConstructors d) decoders ] ++
          [D.text "raise " <> callD "ValueError" [infixD (v (quote ("expected " ++ shownName env d ++ ", found "))) "+" (v "v.tag")]])
  _ -> lift' (Left ("typed Python: no conversion for " ++ show ty))

-- | A data type's name as the generated code shows it.
shownName :: Env -> DataDeclaration -> String
shownName env d = M.findWithDefault (dataName d) (dataId d) (envNative env)

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
    pure [D.text "return " <> (if null f then callD "lsf_items" [v "x"] else callD "lsf_to_list" [v "x", v f])]
  Constructor "Maybe" [TypeArgument a] -> do
    f <- nativeConverter "tonative" a
    pure [returnTernary (callD "_schema.Present" [applyD f (v "x[0]")]) (v "x") (v "_schema.Absent()")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- nativeConverter "tonative" a
    fr <- nativeConverter "tonative" b
    pure [returnTernary (callD "_schema.Right" [applyD fr (v "x[1]")]) (v "x[0]") (callD "_schema.Left" [applyD fl (v "x[1]")])]
  _ | Just ("KeyVal", [k, val]) <- collectionArguments ty -> do
        fk <- nativeConverter "tonative" k
        fv <- nativeConverter "tonative" val
        pure [D.text "return " <> (if hashableKey k
          then comprehension "{" "}" (applyD fk (v "k") <> v ": " <> applyD fv (v "v")) "for k, v in lsf_entries(x)"
          else comprehension "tuple(" ")" (tuple [applyD fk (v "k"), applyD fv (v "v")]) "for k, v in lsf_entries(x)")]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- nativeConverter "tonative" a
        pure [D.text "return " <> comprehension (if hashableKey a then "frozenset(" else "tuple(") ")" (applyD f (v "k")) "for k, _ in lsf_entries(x)"]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
        nativeOf c = "data." ++ envNative env M.! constructorId c
    converters <- forM (dataConstructors d) $ \c -> mapM (nativeConverter "tonative") (fieldTypes d targs c)
    let made offset c cs = callD (nativeOf c) [applyD cv (v ("x[" ++ show (k + offset) ++ "]")) | (k, cv) <- zip [0 :: Int ..] cs]
    if fieldless d
      then pure [D.text "return " <> tuple [v (nativeOf c) | c <- sortOn (rankOf d) (dataConstructors d)] <> v "[x]()"]
      else if isProductType d
        then pure [D.text "return " <> made 0 (firstOf (dataConstructors d)) (firstOf converters)]
        else pure ([ block ("if x[0] == " ++ show (rankOf d c)) [D.text "return " <> made 1 c cs] | (c, cs) <- zip (dataConstructors d) converters ] ++
                   [D.text "lsf_unreachable()"])
  _ -> lift' (Left ("typed Python: no native conversion for " ++ show ty))

fromNative :: Env -> Type -> M [D.Doc]
fromNative env ty = case ty of
  _ | sameDynamic ty -> pure [D.text "return n"]
  Constructor "List" [TypeArgument a] -> do
    f <- nativeConverter "fromnative" a
    pure [D.text "return " <> (if null f then callD "lsf_list_of" [v "n"] else callD "lsf_from_list" [v "n", v f])]
  Constructor "Maybe" [TypeArgument a] -> do
    f <- nativeConverter "fromnative" a
    pure [returnTernary (tuple [applyD f (v "n.value")]) (v "isinstance(n, _schema.Present)") (v "()")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- nativeConverter "fromnative" a
    fr <- nativeConverter "fromnative" b
    pure [returnTernary (tuple [v "1", applyD fr (v "n.value")]) (v "isinstance(n, _schema.Right)") (tuple [v "0", applyD fl (v "n.value")])]
  _ | Just ("KeyVal", [k, val]) <- collectionArguments ty -> do
        fk <- nativeConverter "fromnative" k
        fv <- nativeConverter "fromnative" val
        cmp <- if plainOrd env k then pure [] else (\c -> [v c]) <$> comparer env k
        let putter = if null cmp then "lsf_put" else "lsf_put_by"
        pure [ D.text "out = None"
             , block (if hashableKey k then "for k, v in n.items()" else "for k, v in n")
                 [D.text "out = " <> callD putter ([v "out", applyD fk (v "k"), applyD fv (v "v")] ++ cmp)]
             , D.text "return out" ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- nativeConverter "fromnative" a
        insert <- if plainOrd env a then pure (callD "lsf_set_insert" [v "out", applyD f (v "item")])
          else (\c -> callD "lsf_set_insert_by" [v "out", applyD f (v "item"), v c]) <$> comparer env a
        pure [D.text "out = None", block "for item in n" [D.text "out = " <> insert], D.text "return out"]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
        nativeOf c = "data." ++ envNative env M.! constructorId c
    converters <- forM (dataConstructors d) $ \c -> mapM (nativeConverter "fromnative") (fieldTypes d targs c)
    let made c cs
          | fieldless d = v (show (rankOf d c))
          | isProductType d = tuple [applyD cv (v ("n." ++ binderName f)) | (f, cv) <- zip (constructorFields c) cs]
          | otherwise = tuple (v (show (rankOf d c)) : [applyD cv (v ("n." ++ binderName f)) | (f, cv) <- zip (constructorFields c) cs])
    if isProductType d
      then pure [D.text "return " <> made (firstOf (dataConstructors d)) (firstOf converters)]
      else pure ([D.text "kind = type(n)"] ++
                 [ block ("if kind is " ++ nativeOf c) [D.text "return " <> made c cs] | (c, cs) <- zip (dataConstructors d) converters ] ++
                 [D.text "raise " <> callD "TypeError" [v (quote ("expected " ++ shownName env d))]])
  _ -> lift' (Left ("typed Python: no native conversion for " ++ show ty))
