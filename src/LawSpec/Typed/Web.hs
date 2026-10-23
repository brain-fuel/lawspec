-- | Typed JavaScript and TypeScript for checked definitions (see
-- LawSpec.Typed.Plan), in src/lawspec_typed.mjs (.ts): a class per typed
-- data constructor (TypeScript types its fields), a function per class of
-- typed definitions over lawspec_fast's values, and, per concrete type the
-- code needs, its equality, its portable order, and its conversions to and
-- from the dynamic values and the native types. Integers stay numbers while
-- they are safe integers. Lists share their tails and maps copy only the
-- path to a key, so a handler's state is never copied. Failures are the
-- dynamic code's ls.Failure, so each catches the other's, and operations of
-- other abilities go to the handler the context (symbols) holds.
-- Functions are named after their definitions, locals after their source
-- binders, and each helper after its kind and type (fromPairInt64Int64).
-- ref:DEC-typed-native-definitions ref:DEC-readable-generated-names
module LawSpec.Typed.Web (WebTyped(..), emitWebTyped) where

import Control.Monad (forM, forM_)
import Control.Monad.State.Strict
import Data.Char (toUpper)
import Data.List (intercalate, sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as S
import LawSpec.Collections (collectionsUnit, collectionContainer)
import LawSpec.Core
import LawSpec.Scalar
import LawSpec.Typed.Plan
import LawSpec.WebTypes (namesFor, webByValue, webTypeReference)
import LawSpec.Time (isDurationType)
import qualified LawSpec.Code.ECMAScript as E
import qualified LawSpec.Naming as N
import LawSpec.Naming (claim, claimAll, scopeWith, localIdentifier, nativeIdentifier, NameKind(..), readableDefinitionName, typeWords, reservedFor, nameWords)
import LawSpec.SourceLink (labelled, sourceLink)
import LawSpec.WebModule (commentLines)

data WebTyped = WebTyped
  { webTypedModule :: String
  , webTypedFunction :: Id -> Maybe String
  , webTypedFrom :: Type -> String
  , webTypedTo :: Type -> String
  , webTypedNativeIn :: Type -> String
  , webTypedNativeOut :: Type -> String
  , webTypedStart :: Id -> Maybe String
  , webTypedPlan :: TypedPlan
  }

data Env = Env
  { envPlan :: TypedPlan
  , envData :: M.Map String DataDeclaration
  , envConstructors :: M.Map Id (DataDeclaration, DataConstructor)
  , envFunctions :: M.Map Int String
  , envClasses :: M.Map Id String       -- typed class of each constructor (and type, for a sum's union)
  , envNative :: M.Map Id String
  , envUnits :: [Unit]
  , envBits :: Int
  , envTs :: Bool
  }

-- Names are their source names (LawSpec.Naming): each function's locals
-- are claimed afresh from the module's names, and each helper is named for
-- its kind and type, with _2 only on a clash.
data St = St { stLocals :: N.Scope, stBase :: N.Scope, stModule :: N.Scope, stNames :: M.Map (String, String) String
             , stShown :: M.Map String String
             , stHelpers :: M.Map String Type, stWanted :: S.Set (String, String) }

type M = StateT St (Either String)

lift' :: Either String a -> M a
lift' = lift

fresh :: String -> M String
fresh base = do
  s <- get
  let (name, scope) = claim (stLocals s) (localIdentifier "javascript" base)
  put s { stLocals = scope }
  pure name

-- | A function's locals start from the module's names.
enterFunction :: M ()
enterFunction = modify (\s -> s { stLocals = stBase s })

helper :: String -> Type -> M String
helper kind ty = do
  let key = show ty
  modify (\st -> st { stHelpers = M.insert key ty (stHelpers st), stWanted = S.insert (kind, key) (stWanted st) })
  s <- get
  case M.lookup (kind, key) (stNames s) of
    Just existing -> pure existing
    Nothing -> do
      let (chosen, scope) = claim (stModule s) (helperBase (stShown s) kind ty)
      put s { stModule = scope, stNames = M.insert (kind, key) chosen (stNames s) }
      pure chosen

-- | A helper's name: its kind's words, then its type's (toPairInt64Int64).
helperBase :: M.Map String String -> String -> Type -> String
helperBase shown kind ty = N.cased N.Camel (kindWords kind ++ typeSlug shown ty)

kindWords :: String -> [String]
kindWords kind = case kind of
  "eq" -> ["equal"]
  "cmp" -> ["compare"]
  "to" -> ["to"]
  "from" -> ["from"]
  "tonative" -> ["to", "native"]
  "fromnative" -> ["from", "native"]
  "nin" -> ["from", "handler"]
  _ -> ["to", "handler"]

-- | A type's words for a helper's name, with data types by the names the
-- generated code shows them.
typeSlug :: M.Map String String -> Type -> [String]
typeSlug shown ty = case ty of
  Constructor n args | Just name <- M.lookup n shown ->
    nameWords name ++ concat [typeSlug shown t | TypeArgument t <- args]
  Constructor n args -> typeWords (Constructor n []) ++ concat [typeSlug shown t | TypeArgument t <- args]
  _ -> typeWords ty

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

-- | A parameter, annotated in TypeScript.
annotated :: Env -> String -> E.Type -> E.Param
annotated env name t = (E.param name) { E.paramType = if envTs env then Just t else Nothing }

anyT :: E.Type
anyT = E.TKeyword "any"

-- | x as T in TypeScript; x in JavaScript.
cast :: Env -> E.Expr -> E.Type -> E.Expr
cast env x t = if envTs env then E.As x t else x

-- | A function declaration.
function :: Env -> String -> [E.Param] -> E.Type -> [E.Stmt] -> E.Stmt
function env name params result = E.FunctionDecl True False name [] params (if envTs env then Just result else Nothing)

emitWebTyped :: Bool -> Int -> [DataDeclaration] -> [Unit] -> Either String WebTyped
emitWebTyped ts bits declarations units = do
  let plan = typedPlanPerforming scalarTypes declarations units
      datas = typedData plan
  names <- namesFor [d | d <- declarations, collectionContainer (idText (dataId d)) == Nothing, not (isDurationType (idText (dataId d))), not (dataHandle d)]
  let shownName d = maybe (dataName d) id (lookup (dataId d) names)
      (classTable, classScope) = classNames shownName (scopeWith (reservedFor "javascript" ++ moduleReserved)) datas
      -- Each typed function is named after its definition.
      (functionNames, moduleScope) = claimAll classScope
        [ nativeIdentifier "javascript" FunctionName (readableDefinitionName (declarationName (definitionDeclaration d))
            (fst (functionType (declarationType (definitionDeclaration d)))))
        | (_, d) <- typedRepresentatives plan ]
      functions = M.fromList (zip (map fst (typedRepresentatives plan)) functionNames)
      env = Env plan (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions classTable
        (M.fromList names) units bits ts
      typedHandlers = [ h | u <- units, h <- unitHandlers u, isTypedHandler plan h ]
      handlerTypes = [ t | h <- typedHandlers, ref <- handlerAbilities h, Just (_, a) <- [findAbility units ref]
                         , (_, ty) <- abilityOperations a, let (args, result) = functionType ty, t <- result : args ] ++
                     [ t | h <- typedHandlers, Just (t, _) <- [handlerState h] ]
      boundary = concat [ let (args, result) = functionType (declarationType (definitionDeclaration d)) in result : args
                        | d <- M.elems (typedDefinitions plan) ]
      stateful = [h | h <- typedHandlers, Just _ <- [handlerState h]]
      (startNames, startScope) = claimAll moduleScope
        [ "start" ++ nativeIdentifier "javascript" TypeName (handlerName h) | h <- stateful ]
      starts = [ (handlerId h, name, ty, start) | (h, name) <- zip stateful startNames, Just (ty, start) <- [handlerState h] ]
      startState = St startScope startScope startScope M.empty (M.fromList [(idText i, n) | (i, n) <- names]) M.empty S.empty
  ((classStmts, functionStmts, startStmts, helperStmts), final) <- flip runStateT startState $ do
    cs <- concat <$> mapM (classDoc env) datas
    fs <- mapM (\(c, d) -> functionDoc env c d) (typedRepresentatives plan)
    ss <- forM starts $ \(_, name, ty, start) -> do
      enterFunction
      body <- cstmt env Nothing [(symbolsId, "symbols")] Return start
      t <- lift' (tsType env ty)
      pure [function env name [annotated env "symbols" anyT] t body]
    forM_ boundary $ \t -> helper "to" t >> helper "from" t
    forM_ handlerTypes $ \t -> helper "nin" t >> helper "nout" t
    hs <- helpers env
    pure (cs, fs, ss, hs)
  let extension = if ts then "js" else "mjs"
      body = concat (classStmts ++ [orderingHelper env] ++ functionStmts ++ startStmts ++ helperStmts)
      used = usedNames (E.printModule (if ts then E.TypeScript else E.JavaScript) body)
      header =
        [ E.Comment ["// Generated by LawSpec. Do not edit.", "// Typed checked definitions over lawspec_fast's values; see"
                    , "// docs/how-to/embed-a-generated-model.md."] ] ++
        [ E.ImportDecl False (E.ImportNamespace alias) ("./" ++ file ++ "." ++ extension)
        | (alias, file) <- [("data", "lawspec_data"), ("ls", "lawspec_runtime"), ("lsf", "lawspec_fast"), ("schema", "lawspec_schema")]
        , alias `S.member` used || (alias == "data" && "_lawspec_schema" `S.member` used) ] ++
        [E.Blank] ++
        [E.constDecl "_lawspec_schema" (E.call "data.makeSchema" []) | "_lawspec_schema" `S.member` used]
      groups = [g | g <- classStmts ++ [orderingHelper env] ++ functionStmts ++ startStmts ++ helperStmts, not (null g)]
      source = E.printModule (if ts then E.TypeScript else E.JavaScript) (header ++ concat [E.Blank : g | g <- groups])
      helperOf kind t = M.findWithDefault (helperBase M.empty kind t) (kind, show t) (stNames final)
  pure WebTyped
    { webTypedModule = source
    , webTypedFunction = \i -> definitionClass plan i >>= (`M.lookup` functions)
    , webTypedFrom = helperOf "from"
    , webTypedTo = helperOf "to"
    , webTypedNativeIn = helperOf "nin"
    , webTypedNativeOut = helperOf "nout"
    , webTypedStart = \h -> case [n | (i, n, _, _) <- starts, i == h] of
        n : _ -> Just n
        [] -> Nothing
    , webTypedPlan = plan }
  where
    moduleReserved = ["data", "ls", "lsf", "schema", "symbols", "orderingOf", "_lawspec_schema"]
    usedNames text = S.fromList (words (map (\c -> if c `elem` ('_' : '$' : ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9']) then c else ' ') text))

-- | The class of each typed constructor, and the union of a sum's.
classNames :: (DataDeclaration -> String) -> N.Scope -> [DataDeclaration] -> (M.Map Id String, N.Scope)
classNames shownName scope0 datas = let (scope, acc) = foldl pick (scope0, []) datas in (M.fromList acc, scope)
  where
    pick (scope, acc) d =
      let (chosen, scope') = claim scope (nativeIdentifier "javascript" TypeName (shownName d))
          (variantNames, scope'') = claimAll scope'
            [chosen ++ nativeIdentifier "javascript" TypeName (constructorName c) | length (dataConstructors d) > 1, c <- dataConstructors d]
          variants = zip [constructorId c | length (dataConstructors d) > 1, c <- dataConstructors d] variantNames
          own = [ (constructorId c, chosen) | length (dataConstructors d) == 1, c <- dataConstructors d ]
      in (scope'', (dataId d, chosen) : variants ++ own ++ acc)

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

-- | A field's property: its name, unless that is one JavaScript reserves.
property :: Binder -> String
property b = let n = localIdentifier "javascript" (binderName b) in if n `elem` ["constructor", "k", "__proto__", "prototype"] then n ++ "Field" else n

small :: [String]
small = ["Int8", "Int16", "Int32", "UInt8", "UInt16", "UInt32"]

-- | Types whose === is LawSpec's equality.
plainEq :: Env -> Type -> Bool
plainEq env ty = case ty of
  Constructor n [] | n `elem` scalarTypes -> n /= "Bytes"
  Constructor n _ | Just d <- M.lookup n (envData env) -> fieldless d
  _ -> False

nullable :: String -> E.Type
nullable n = E.TUnion [E.TRef n [], E.TKeyword "null"]

tsType :: Env -> Type -> Either String E.Type
tsType env = go []
  where
    go parameters ty = case ty of
      TypeVariable v | Just p <- lookup v parameters -> pure (E.TRef p [])
      Constructor "Bool" [] -> pure (E.TKeyword "boolean")
      Constructor "Unit" [] -> pure (E.TKeyword "null")
      Constructor n [] | n `elem` small -> pure (E.TKeyword "number")
      Constructor n [] | n `elem` ["Int64", "UInt64", "Integer"] -> pure (E.TUnion [E.TKeyword "number", E.TKeyword "bigint"])
      Constructor "Text" [] -> pure (E.TKeyword "string")
      Constructor "Bytes" [] -> pure (E.TRef "Uint8Array" [])
      Constructor "List" _ -> pure (nullable "lsf.Cons")
      Constructor "Maybe" _ -> pure (nullable "lsf.Present")
      Constructor "Either" _ -> pure (E.TRef "lsf.Side" [])
      _ | isJust (collectionArguments ty) -> pure (nullable "lsf.Node")
      Constructor n args | Just d <- M.lookup n (envData env) ->
        if fieldless d then pure (E.TKeyword "number") else do
          rendered <- mapM (\a -> case a of TypeArgument t -> go parameters t; _ -> Left "typed TypeScript: index argument") args
          pure (E.TRef (envClasses env M.! dataId d) rendered)
      _ -> Left ("no typed TypeScript form for " ++ show ty)

classDoc :: Env -> DataDeclaration -> M [[E.Stmt]]
classDoc env d
  | fieldless d = pure []
  | otherwise = do
      let parameters = zip (dataParameters d) ["T" ++ show k | k <- [0 :: Int ..]]
          generics = if envTs env then map snd parameters else []
          tsField ty = case tsTypeP parameters ty of
            Right t -> t
            Left _ -> anyT
          variant c =
            let name = envClasses env M.! constructorId c
                fields = constructorFields c
                params = [ annotated env (property f) (tsField (binderType f)) | f <- fields ]
                declarations = if envTs env
                  then [E.Field ["readonly"] "k" (Just (E.TLiteral (E.num (toInteger (rankOf d c))))) Nothing | not (isProductType d)] ++
                       [E.Field ["readonly"] (property f) (Just (tsField (binderType f))) Nothing | f <- fields]
                  else []
                assignments = [E.ExprStmt (E.Assign "=" (E.member E.This "k") (E.num (toInteger (rankOf d c)))) | not (isProductType d)] ++
                  [E.ExprStmt (E.Assign "=" (E.member E.This (property f)) (E.Ident (property f))) | f <- fields]
            in [ E.Comment (commentLines (labelled (envClasses env M.! dataId d ++ (if isProductType d then "" else "." ++ constructorName c)) (sourceLink (dataOrigin d))))
               , E.ClassDecl True name generics Nothing [] (declarations ++ [E.Method False False "method" "constructor" params Nothing assignments]) ]
          union = [ [E.TypeAlias True (envClasses env M.! dataId d) generics
                      (if null (dataConstructors d) then E.TKeyword "never"
                       else E.TUnion [E.TRef (envClasses env M.! constructorId c) [E.TRef g [] | g <- generics] | c <- dataConstructors d])]
                  | envTs env, not (isProductType d) ]
      pure (map variant (dataConstructors d) ++ union)
  where
    tsTypeP parameters ty = case ty of
      TypeVariable v | Just p <- lookup v parameters -> pure (E.TRef p [])
      Constructor n args | Just d' <- M.lookup n (envData env), not (fieldless d') -> do
        rendered <- mapM (\a -> case a of TypeArgument t -> tsTypeP parameters t; _ -> Left "index") args
        pure (E.TRef (envClasses env M.! dataId d') rendered)
      _ -> tsType env ty

orderingHelper :: Env -> [E.Stmt]
orderingHelper env = case M.lookup (collectionsUnit ++ "::type::Ordering") (envData env) of
  Nothing -> []
  Just d ->
    let rank label' = firstOf ([rankOf d c | c <- dataConstructors d, constructorName c == label'] ++ [0])
        sign = E.Ident "c"
    in [ E.Comment ["// An Ordering from a comparison's sign."]
       , E.FunctionDecl False False "orderingOf" [] [annotated env "c" (E.TKeyword "number")] (if envTs env then Just (E.TKeyword "number") else Nothing)
           [E.ret (E.Conditional (E.Binary "<" sign (E.num 0)) (E.num (toInteger (rank "Less")))
             (E.Conditional (E.Binary "===" sign (E.num 0)) (E.num (toInteger (rank "Equal"))) (E.num (toInteger (rank "Greater")))))] ]

-- Statements.

data Target = Return | Assign String

type Scope = [(Id, String)]

symbolsId :: Id
symbolsId = Id "lawspec::symbols"

functionDoc :: Env -> Int -> Definition -> M [E.Stmt]
functionDoc env c d = do
  enterFunction
  let declaration = definitionDeclaration d
      (_, result) = functionType (declarationType declaration)
      name = envFunctions env M.! c
      contextual = isContextual (envPlan env) (declarationId declaration)
  params <- forM (definitionArguments d) $ \b -> do
    local <- fresh (binderName b)
    t <- lift' (tsType env (binderType b))
    pure (binderId b, local, t)
  resultType <- lift' (tsType env result)
  let scope = [(symbolsId, "symbols") | contextual] ++ [(i, l) | (i, l, _) <- params]
      looping = hasTailSelf env c (definitionBody d)
      selfCall = if looping then Just (c, [l | (_, l, _) <- params]) else Nothing
  body <- case M.lookup (declarationId declaration) (typedIntrinsics (envPlan env)) of
    Just intrinsic -> do
      x <- intrinsicCall env intrinsic [(E.Ident l, binderType b) | ((_, l, _), b) <- zip params (definitionArguments d)]
      pure [E.ret x]
    Nothing -> cstmt env selfCall scope Return (definitionBody d)
  pure [ E.Comment (commentLines (labelled (declarationName declaration) (sourceLink (declarationOrigin declaration))))
       , function env name ([annotated env "symbols" anyT | contextual] ++ [annotated env l t | (_, l, t) <- params]) resultType
           (if looping then [E.For Nothing Nothing Nothing body] else body) ]

hasTailSelf :: Env -> Int -> Expr -> Bool
hasTailSelf env c e = case expressionNode e of
  ExternalCall i _ -> definitionClass (envPlan env) i == Just c && M.notMember i (typedIntrinsics (envPlan env))
  If _ a b -> hasTailSelf env c a || hasTailSelf env c b
  Match _ cases -> any (hasTailSelf env c . caseBody) cases
  Let _ _ body -> hasTailSelf env c body
  Helper Select [_, a, b] -> hasTailSelf env c a || hasTailSelf env c b
  _ -> False

deliver :: Target -> E.Expr -> E.Stmt
deliver Return x = E.ret x
deliver (Assign v) x = E.ExprStmt (E.Assign "=" (E.Ident v) x)

cstmt :: Env -> Maybe (Int, [String]) -> Scope -> Target -> Expr -> M [E.Stmt]
cstmt env selfCall scope target e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    local <- fresh (binderName binder)
    rest <- cstmt env selfCall ((binderId binder, local) : scope) target body
    pure (s ++ [E.constDecl local x] ++ rest)
  If c a b -> do
    (s, x) <- cexpr env scope c
    yes <- cstmt env selfCall scope target a
    no <- cstmt env selfCall scope target b
    pure (s ++ [E.If x yes (Just (Right no))])
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
          t <- fresh ("next " ++ p)
          pure (s ++ [E.constDecl t x], E.ExprStmt (E.Assign "=" (E.Ident p) (E.Ident t)))
        pure (concatMap fst evaluated ++ map snd evaluated ++ [E.Continue])
  Helper Unreachable _ -> pure [E.ret (E.call "lsf.unreachable" [])]
  Perform (Operation ref "raise") [_] | isFail ref -> fst <$> cexpr env scope e
  _ -> do
    (s, x) <- cexpr env scope e
    pure (s ++ [deliver target x])

cexpr :: Env -> Scope -> Expr -> M ([E.Stmt], E.Expr)
cexpr env scope e = case expressionNode e of
  Let {} -> viaStatements
  Match {} -> viaStatements
  If {} -> viaStatements
  Helper Select _ -> viaStatements
  Constant s -> (,) [] <$> lift' (constant s)
  Local i -> do
    name <- lift' (maybe (Left ("typed JavaScript: unbound local " ++ idText i)) Right (lookup i scope))
    pure ([], E.Ident name)
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
        c <- lift' (maybe (Left ("typed JavaScript: untyped callee " ++ idText i)) Right (definitionClass (envPlan env) i))
        parts <- mapM (cexpr env scope) args
        let context = [E.Ident "symbols" | isContextual (envPlan env) i]
        pure (concatMap fst parts, E.call (envFunctions env M.! c) (context ++ map snd parts))
  ShortCircuit op a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    if null sb
      then pure (sa, (if op == And then E.and' else E.or') xa xb)
      else do
        t <- fresh (if op == And then "both" else "either")
        pure (sa ++ [ E.letDecl t xa
                    , E.If (if op == And then E.Ident t else E.notE (E.Ident t)) (sb ++ [E.ExprStmt (E.Assign "=" (E.Ident t) xb)]) Nothing ], E.Ident t)
  Unary Not a -> do
    (s, x) <- cexpr env scope a
    pure (s, E.notE x)
  Unary Negate a -> do
    (s, x) <- cexpr env scope a
    pure (s, E.call "lsf.neg" [x])
  Binary op (Structural t) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    eq <- equaler env t
    let test = if eq == "lsf.eqPlain" then E.Binary (if op == Equal then "===" else "!==") xa xb
          else (if op == Equal then id else E.notE) (E.call eq [xa, xb])
    pure (sa ++ sb, test)
  Binary op (Numeric _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    let smallOperands = all (isSmall . expressionType) [a, b]
        infix' symbol = pure (sa ++ sb, E.Binary symbol xa xb)
        call f = pure (sa ++ sb, E.call ("lsf." ++ f) [xa, xb])
    case op of
      Add | smallOperands -> infix' "+"
          | otherwise -> call "add"
      Subtract | smallOperands -> infix' "-"
               | otherwise -> call "sub"
      Multiply -> call "mul"
      Quotient -> call "quot"
      Remainder -> call "rem"
      Power -> call "power"
      Equal -> infix' "==="
      NotEqual -> infix' "!=="
      Less -> infix' "<"
      LessEqual -> infix' "<="
      Greater -> infix' ">"
      GreaterEqual -> infix' ">="
      _ -> lift' (Left ("typed JavaScript: unsupported operator " ++ show op))
  Convert _ target value -> convert env scope target value
  Helper Compare [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    cmp <- comparer env (expressionType a)
    pure (sa ++ sb, E.call "orderingOf" [E.call cmp [xa, xb]])
  Helper Length [x] -> do
    (s, v) <- cexpr env scope x
    pure (s, case expressionType x of
      Constructor "Text" [] -> E.call "lsf.textLength" [v]
      Constructor "Bytes" [] -> E.member v "length"
      _ -> E.call "lsf.length" [v])
  Helper Unreachable _ -> pure ([], E.call "lsf.unreachable" [])
  Helper Checked _ -> pure ([], E.BoolLit True)
  Helper StartsWith [a, b] -> method "startsWith" a b
  Helper EndsWith [a, b] -> method "endsWith" a b
  Helper TextContains [a, b] -> method "includes" a b
  Helper RegexMatches [a, b] -> call2 "lsf.regexMatches" a b
  AllElements value binder predicate -> do
    (sx, xs) <- cexpr env scope value
    t <- fresh "all"
    cell <- fresh "cell"
    item <- fresh (binderName binder)
    (sp, p) <- cexpr env ((binderId binder, item) : scope) predicate
    pure (sx ++ [ E.letDecl t (E.BoolLit True)
                , E.For (Just ("let", E.PIdent cell, if envTs env then Just (nullable "lsf.Cons") else Nothing, Just xs))
                    (Just (E.Binary "!==" (E.Ident cell) E.Null)) (Just (E.Assign "=" (E.Ident cell) (E.member (E.Ident cell) "t")))
                    ([E.constDecl item (E.member (E.Ident cell) "h")] ++ sp ++
                     [E.If (E.notE p) [E.ExprStmt (E.Assign "=" (E.Ident t) (E.BoolLit False)), E.Break] Nothing]) ], E.Ident t)
  Perform (Operation ref "raise") [x] | isFail ref -> do
    (s, v) <- cexpr env scope x
    to <- helper "to" (expressionType x)
    pure (s ++ [E.Throw (E.new' "ls.Failure" [E.Str (abilityKey ref), E.call to [v]])], E.call "lsf.unreachable" [])
  Perform op args -> do
    parts <- mapM (cexpr env scope) args
    outs <- mapM (helper "nout" . expressionType) args
    nin <- helper "nin" (expressionType e)
    r <- fresh "performed"
    let handler = cast env (E.call "ls.handler" [E.Ident "symbols", E.Str (abilityKey (operationAbility op))]) anyT
        invocation = E.method handler (operationName op) [E.call o [x, E.Ident "symbols"] | (o, x) <- zip outs (map snd parts)]
    failure <- case performedFailure (envUnits env) op of
      Just failing@(AbilityRef _ [failureType]) -> do
        ref <- lift' (webTypeReference failureType)
        pure (Just (failing, ref))
      _ -> pure Nothing
    let invoke = case failure of
          Nothing -> [E.constDecl r invocation]
          Just (failing, ref) ->
            [ E.VarDecl "let" (E.PIdent r) (if envTs env then Just (E.TKeyword "unknown") else Nothing) Nothing
            , E.Try [E.ExprStmt (E.Assign "=" (E.Ident r) invocation)] (Just (Just (E.PIdent "error"),
                [ E.If (E.Binary "instanceof" (E.Ident "error") (E.member (E.Ident "ls") "Fail"))
                    [E.Throw (E.new' "ls.Failure" [E.Str (abilityKey failing),
                      E.method (E.call "ls.handlerSchema" [E.Ident "_lawspec_schema"]) "fromNative"
                        [ref, E.member (cast env (E.Ident "error") anyT) "value", E.num (toInteger (envBits env)), E.Ident "symbols"]])] Nothing
                , E.Throw (E.Ident "error") ])) Nothing ]
    pure (concatMap fst parts ++ invoke, E.call nin [E.Ident r, E.Ident "symbols"])
  Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, _] <- expressionType e -> do
    t <- fresh "attempted"
    from <- helper "from" failure
    (s, v) <- cexpr env scope body
    let failed = cast env (E.Ident "failure") anyT
    pure ([ E.VarDecl "let" (E.PIdent t) (if envTs env then Just (E.TRef "lsf.Side" []) else Nothing) Nothing
          , E.Try (s ++ [E.ExprStmt (E.Assign "=" (E.Ident t) (E.call "lsf.right" [v]))]) (Just (Just (E.PIdent "failure"),
              [ E.If (E.or' (E.notE (E.Binary "instanceof" (E.Ident "failure") (E.member (E.Ident "ls") "Failure")))
                            (E.Binary "!==" (E.member failed "ability") (E.Str (abilityKey ref)))) [E.Throw (E.Ident "failure")] Nothing
              , E.ExprStmt (E.Assign "=" (E.Ident t) (E.call "lsf.left" [E.call from [E.member failed "value"]])) ])) Nothing ], E.Ident t)
  Helper Append [a, b] -> case expressionType a of
    Constructor "Text" [] -> do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, E.Binary "+" xa xb)
    Constructor "Bytes" [] -> call2 "lsf.appendBytes" a b
    _ -> call2 "lsf.append" a b
  Helper Slice [x, from, to] -> do
    (sx, v) <- cexpr env scope x
    (si, i) <- cexpr env scope from
    (sj, j) <- cexpr env scope to
    let f = case expressionType x of
          Constructor "Text" [] -> "lsf.sliceText"
          Constructor "Bytes" [] -> "lsf.sliceBytes"
          _ -> "lsf.sliceList"
    pure (sx ++ si ++ sj, E.call f [v, i, j])
  Helper At [x, k] -> call2 (if expressionType x == Constructor "Bytes" [] then "lsf.atBytes" else "lsf.atList") x k
  Helper Range [lo, hi] -> call2 "lsf.range" lo hi
  Helper Octets [b] -> one "lsf.octets" b
  Helper BytesOf [xs] -> one "lsf.bytesOf" xs
  Helper Utf8 [t] -> one "lsf.utf8" t
  Helper TextOf [n] -> one "String" n
  Helper Join [sep, parts] -> call2 "lsf.join" sep parts
  _ -> lift' (Left ("typed JavaScript: unsupported expression " ++ take 80 (show (expressionNode e))))
  where
    one f a = do
      (s, x) <- cexpr env scope a
      pure (s, E.call f [x])
    call2 f a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, E.call f [xa, xb])
    method m a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, E.method xa m [xb])
    viaStatements = do
      t <- fresh "value"
      ty <- lift' (tsType env (expressionType e))
      s <- cstmt env Nothing scope (Assign t) e
      pure (E.VarDecl "let" (E.PIdent (if envTs env then t ++ "!" else t)) (if envTs env then Just ty else Nothing) Nothing : s, E.Ident t)

isSmall :: Type -> Bool
isSmall (Constructor n []) = n `elem` small
isSmall _ = False

comparer :: Env -> Type -> M String
comparer env ty = case ty of
  Constructor "Bool" [] -> pure "lsf.cmpBool"
  Constructor "Unit" [] -> pure "lsf.cmpUnit"
  Constructor "Text" [] -> pure "lsf.cmpText"
  Constructor "Bytes" [] -> pure "lsf.cmpBytes"
  Constructor n [] | n `elem` scalarTypes -> pure "lsf.cmpNumber"
  Constructor n _ | Just d <- M.lookup n (envData env), fieldless d -> pure "lsf.cmpNumber"
  _ -> helper "cmp" ty

equaler :: Env -> Type -> M String
equaler env ty
  | plainEq env ty = pure "lsf.eqPlain"
  | ty == Constructor "Bytes" [] = pure "lsf.eqBytes"
  | otherwise = helper "eq" ty

constant :: Scalar -> Either String E.Expr
constant s = case s of
  SBool b -> pure (E.BoolLit b)
  SAbsent "Unit" -> pure E.Null
  SInteger _ n -> pure (integerLiteral n)
  SSequence "Text" units -> pure (E.Str (map toEnum units))
  SSequence "Bytes" units -> pure (E.call "Uint8Array.of" (map (E.num . toInteger) units))
  _ -> Left ("typed JavaScript: unsupported constant " ++ show s)

-- | A canonical integer: a number when safe, a BigInt beyond.
integerLiteral :: Integer -> E.Expr
integerLiteral n
  | abs n <= 9007199254740991 = E.num n
  | n < 0 = E.Unary "-" (E.BigIntLit (show (negate n)))
  | otherwise = E.BigIntLit (show n)

boundsOf :: String -> Maybe (Integer, Integer)
boundsOf t = lookup t
  [ ("Int8", (-128, 127)), ("Int16", (-32768, 32767)), ("Int32", (-2147483648, 2147483647))
  , ("Int64", (-(2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1)), ("UInt8", (0, 255)), ("UInt16", (0, 65535))
  , ("UInt32", (0, 4294967295)), ("UInt64", (0, 2 ^ (64 :: Int) - 1)) ]

convert :: Env -> Scope -> Type -> Expr -> M ([E.Stmt], E.Expr)
convert env scope target value = do
  (s, x) <- cexpr env scope value
  case target of
    Constructor t [] | Just (lo, hi) <- boundsOf t ->
      let inside = case expressionType value of
            Constructor n [] | Just (slo, shi) <- boundsOf n -> slo >= lo && shi <= hi
            _ -> False
      in if inside then pure (s, x)
         else pure (s, E.call "lsf.narrow" [x, integerLiteral lo, integerLiteral hi, E.Str t])
    _ -> pure (s, x)

construct :: Env -> Type -> Id -> [E.Expr] -> M E.Expr
construct env ty tag values = case (idText tag, values) of
  ("List::Nil", []) -> pure E.Null
  ("List::Cons", [h, t]) -> pure (E.new' "lsf.Cons" [h, t])
  ("Maybe::Absent", []) -> pure E.Null
  ("Maybe::Present", [x]) -> pure (E.new' "lsf.Present" [x])
  ("Either::Left", [x]) -> pure (E.call "lsf.left" [x])
  ("Either::Right", [x]) -> pure (E.call "lsf.right" [x])
  (_, [items]) | Just ("KeyVal", [k, _]) <- collectionArguments ty -> do
    cmp <- comparer env k
    (key, value) <- entryAccess env
    pure (E.call "lsf.keyValOf" [items, key, value, E.Ident cmp])
  (_, [items]) | Just ("Set", [a]) <- collectionArguments ty -> do
    cmp <- comparer env a
    pure (E.call "lsf.setOf" [items, E.Ident cmp])
  _ -> case M.lookup tag (envConstructors env) of
    Just (d, c)
      | fieldless d -> pure (E.num (toInteger (rankOf d c)))
      | otherwise -> pure (E.New (E.Ident (envClasses env M.! constructorId c)) [] values)
    Nothing -> lift' (Left ("typed JavaScript: unknown constructor " ++ idText tag))

-- | An Entry's key and value, as functions.
entryAccess :: Env -> M (E.Expr, E.Expr)
entryAccess env = case M.lookup (collectionsUnit ++ "::type::Entry") (envData env) of
  Just d | [c] <- dataConstructors d, [k, v] <- constructorFields c ->
    pure (E.arrow [annotated env "e" anyT] (E.member (E.Ident "e") (property k)), E.arrow [annotated env "e" anyT] (E.member (E.Ident "e") (property v)))
  _ -> lift' (Left "typed JavaScript: no typed Entry")

entryMaker :: Env -> M E.Expr
entryMaker env = case M.lookup (collectionsUnit ++ "::type::Entry") (envData env) of
  Just d | [c] <- dataConstructors d -> pure (E.arrow [annotated env "k" anyT, annotated env "v" anyT]
    (E.New (E.Ident (envClasses env M.! constructorId c)) [] [E.Ident "k", E.Ident "v"]))
  _ -> lift' (Left "typed JavaScript: no typed Entry")

intrinsicCall :: Env -> Intrinsic -> [(E.Expr, Type)] -> M E.Expr
intrinsicCall env intrinsic args = case (intrinsic, args) of
  (KeyValOf, [(es, Constructor "List" [TypeArgument (Constructor _ [TypeArgument k, _])])]) -> do
    cmp <- comparer env k
    (key, value) <- entryAccess env
    pure (E.call "lsf.keyValOf" [es, key, value, E.Ident cmp])
  (KeyValLookup, [(k, kt), (m, _)]) -> keyed kt "lsf.lookup" [m, k]
  (KeyValPut, [(k, kt), (v, _), (m, _)]) -> keyed kt "lsf.put" [m, k, v]
  (KeyValDelete, [(k, kt), (m, _)]) -> keyed kt "lsf.remove" [m, k]
  (KeyValKeys, [(m, _)]) -> pure (E.call "lsf.keysList" [m])
  (KeyValValues, [(m, _)]) -> pure (E.call "lsf.valuesList" [m])
  (KeyValEntries, [(m, _)]) -> do
    entry <- entryMaker env
    pure (E.call "lsf.entriesList" [m, entry])
  (SetOf, [(xs, Constructor "List" [TypeArgument a])]) -> keyed a "lsf.setOf" [xs]
  (SetMember, [(x, xt), (s, _)]) -> keyed xt "lsf.member" [s, x]
  (SetInsert, [(x, xt), (s, _)]) -> keyed xt "lsf.setInsert" [s, x]
  (SetRemove, [(x, xt), (s, _)]) -> keyed xt "lsf.remove" [s, x]
  (SetUnion, [(s, st), (t, _)]) -> setOp "lsf.setUnion" s st t
  (SetIntersection, [(s, st), (t, _)]) -> setOp "lsf.setIntersection" s st t
  (SetDifference, [(s, st), (t, _)]) -> setOp "lsf.setDifference" s st t
  _ -> lift' (Left ("typed JavaScript: bad intrinsic " ++ show intrinsic))
  where
    keyed kt f xs = do
      cmp <- comparer env kt
      pure (E.call f (xs ++ [E.Ident cmp]))
    setOp f s st t = case collectionArguments st of
      Just (_, [a]) -> keyed a f [s, t]
      _ -> lift' (Left "typed JavaScript: set operation on a non-set")

matchStatements :: Env -> Maybe (Int, [String]) -> Scope -> Target -> Expr -> [MatchCase] -> M [E.Stmt]
matchStatements env selfCall scope target value cases = do
  let ty = expressionType value
      used c b = binderId b `elem` freeBinders (caseBody c)
      arm c accesses = do
        bound <- forM (zip (caseBinders c) accesses) $ \(b, access) ->
          if used c b then do
            n <- fresh (binderName b)
            pure (Just (binderId b, n), [E.constDecl n access])
          else pure (Nothing, [])
        body <- cstmt env selfCall ([x | (Just x, _) <- bound] ++ scope) target (caseBody c)
        pure (concatMap snd bound ++ body)
      unreachable = [E.ret (E.call "lsf.unreachable" [])]
      caseOf tag = [c | c <- cases, idText (caseConstructor c) == tag]
      orUnreachable tag accesses = case caseOf tag of
        c : _ -> arm c accesses
        [] -> pure unreachable
  (prelude, subject) <- case expressionNode value of
    Local i | Just name <- lookup i scope -> pure ([], E.Ident name)
    _ -> do
      (s, x) <- cexpr env scope value
      t <- fresh "matched"
      pure (s ++ [E.constDecl t x], E.Ident t)
  let two condition yesTag yesAccess noTag noAccess = do
        yes <- orUnreachable yesTag yesAccess
        no <- orUnreachable noTag noAccess
        pure (prelude ++ [E.If condition yes (Just (Right no))])
      anyCast x = cast env x anyT
  case ty of
    Constructor "Maybe" _ -> two (E.Binary "!==" subject E.Null) "Maybe::Present" [E.member (anyCast subject) "v"] "Maybe::Absent" []
    Constructor "Either" _ -> two (E.member subject "r") "Either::Right" [E.member subject "v"] "Either::Left" [E.member subject "v"]
    Constructor "List" _ -> two (E.Binary "===" subject E.Null) "List::Nil" [] "List::Cons" [E.member (anyCast subject) "h", E.member (anyCast subject) "t"]
    _ | Just (kind, _) <- collectionArguments ty, [c] <- cases -> do
          entry <- if kind == "KeyVal" then Just <$> entryMaker env else pure Nothing
          (prelude ++) <$> arm c [maybe (E.call "lsf.keysList" [subject]) (\m -> E.call "lsf.entriesList" [subject, m]) entry]
    Constructor n _ | Just d <- M.lookup n (envData env) -> do
      let conOf c = snd (envConstructors env M.! caseConstructor c)
          className c = envClasses env M.! constructorId (conOf c)
          fieldsOf c = [E.member (cast env subject (E.TRef (className c) [E.TKeyword "any" | not (null (dataParameters d))])) (property f) | f <- constructorFields (conOf c)]
      if isProductType d
        then case cases of
          [c] -> (prelude ++) <$> arm c [E.member subject (property f) | f <- constructorFields (conOf c)]
          _ -> lift' (Left "typed JavaScript: product match")
        else do
          arms <- forM (sortOn (rankOf d . conOf) cases) $ \c -> do
            body <- arm c (fieldsOf c)
            pure (rankOf d (conOf c), body)
          let tag = if fieldless d then subject else E.member subject "k"
          pure (prelude ++ [E.Switch tag ([ (Just (E.num (toInteger r)), [E.Block (body ++ [E.Break])]) | (r, body) <- arms ] ++
            [(Nothing, [E.Block unreachable])])])
    _ -> lift' (Left ("typed JavaScript: cannot match on " ++ show ty))

-- Helpers.

helpers :: Env -> M [[E.Stmt]]
helpers env = go S.empty
  where
    go done = do
      st <- get
      let pending = [w | w <- S.toList (stWanted st), w `S.notMember` done]
      if null pending then pure [] else do
        docs <- forM pending $ \(kind, key) -> helperDoc env kind (stHelpers st M.! key)
        rest <- go (S.union done (S.fromList pending))
        pure (docs ++ rest)

helperDoc :: Env -> String -> Type -> M [E.Stmt]
helperDoc env kind ty = do
  name <- helper kind ty
  enterFunction
  let fn params result body = [ E.Comment ["// " ++ helperPurpose kind ++ " " ++ prettyTypeOf ty ++ "."]
                              , function env name [annotated env p anyT | p <- params] result body ]
  case kind of
    "eq" -> fn ["a", "b"] (E.TKeyword "boolean") <$> equality env ty
    "cmp" -> fn ["a", "b"] (E.TKeyword "number") <$> ordering env ty
    "to" -> fn ["x"] anyT <$> toValue env ty
    "from" -> fn ["v"] anyT <$> fromValue env ty
    "tonative" -> fn ["x"] anyT <$> toNative env ty
    "fromnative" -> fn ["n"] anyT <$> fromNative env ty
    "nin" -> fn ["n", "symbols"] anyT <$> nativeIn env ty
    _ -> fn ["x", "symbols"] anyT <$> nativeOut env ty

ident :: String -> E.Expr
ident = E.Ident

bitsE :: Env -> E.Expr
bitsE env = E.num (toInteger (envBits env))

handlerSchema :: String -> [E.Expr] -> E.Expr
handlerSchema m = E.method (E.call "ls.handlerSchema" [ident "_lawspec_schema"]) m

nativeIn :: Env -> Type -> M [E.Stmt]
nativeIn env ty
  | ty == Constructor "Unit" [] = pure [E.ret E.Null]
  | otherwise = do
      ref <- lift' (webTypeReference ty)
      from <- helper "from" ty
      let viaSchema = E.ret (E.call from [handlerSchema "fromNative" [ref, ident "n", bitsE env, ident "symbols"]])
      if nativeDirect env S.empty ty
        then do
          direct <- helper "fromnative" ty
          pure [E.IfSingle (E.notE (E.call "lsf.bound" [])) (E.ret (E.call direct [ident "n"])), viaSchema]
        else pure [viaSchema]

nativeOut :: Env -> Type -> M [E.Stmt]
nativeOut env ty
  | ty == Constructor "Unit" [] = pure [E.ret (ident "undefined")]
  | otherwise = do
      ref <- lift' (webTypeReference ty)
      to <- helper "to" ty
      let viaSchema = E.ret (handlerSchema "toNative" [ref, E.call to [ident "x"], bitsE env, ident "symbols"])
      if nativeDirect env S.empty ty
        then do
          direct <- helper "tonative" ty
          pure [E.IfSingle (E.notE (E.call "lsf.bound" [])) (E.ret (E.call direct [ident "x"])), viaSchema]
        else pure [viaSchema]

-- | a.p, b.p
fieldsAB :: String -> (E.Expr, E.Expr)
fieldsAB p = (E.member (ident "a") p, E.member (ident "b") p)

conjunction :: [E.Expr] -> E.Expr
conjunction xs = case xs of
  [] -> E.BoolLit True
  _ -> foldl1 E.and' xs

kIs :: Env -> String -> DataDeclaration -> DataConstructor -> E.Expr
kIs _ v d c = E.Binary "===" (E.member (ident v) "k") (E.num (toInteger (rankOf d c)))

equality :: Env -> Type -> M [E.Stmt]
equality env ty = case ty of
  _ | plainEq env ty -> pure [E.ret (E.Binary "===" (ident "a") (ident "b"))]
  Constructor "Bytes" [] -> pure [E.ret (E.call "lsf.eqBytes" [ident "a", ident "b"])]
  Constructor "List" [TypeArgument a] -> (\e -> [E.ret (E.call "lsf.eqList" [ident "a", ident "b", ident e])]) <$> equaler env a
  Constructor "Maybe" [TypeArgument a] -> (\e -> [E.ret (E.call "lsf.eqMaybe" [ident "a", ident "b", ident e])]) <$> equaler env a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    el <- equaler env a
    er <- equaler env b
    pure [E.ret (E.call "lsf.eqEither" [ident "a", ident "b", ident el, ident er])]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ek <- equaler env k
        ev <- equaler env v
        pure [E.ret (E.call "lsf.eqMap" [ident "a", ident "b", ident ek, ident ev])]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        ek <- equaler env a
        pure [E.ret (E.call "lsf.eqMap" [ident "a", ident "b", ident ek, ident "lsf.eqUnit"])]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    checks <- forM (dataConstructors d) $ \c -> forM (zip (constructorFields c) (fieldTypes d targs c)) $ \(f, ft) -> do
      e <- equaler env ft
      let (x, y) = fieldsAB (property f)
      pure (if e == "lsf.eqPlain" then E.Binary "===" x y else E.call e [x, y])
    let same = E.IfSingle (E.Binary "===" (ident "a") (ident "b")) (E.ret (E.BoolLit True))
    if isProductType d
      then pure [same, E.ret (conjunction (firstOf checks))]
      else pure ([ same, E.IfSingle (E.Binary "!==" (E.member (ident "a") "k") (E.member (ident "b") "k")) (E.ret (E.BoolLit False)) ] ++
                 [ E.IfSingle (kIs env "a" d c) (E.ret (conjunction cs))
                 | (c, cs) <- zip (dataConstructors d) checks, not (null cs) ] ++ [E.ret (E.BoolLit True)])
  _ -> lift' (Left ("typed JavaScript: no equality for " ++ show ty))

ordering :: Env -> Type -> M [E.Stmt]
ordering env ty = case ty of
  Constructor "List" [TypeArgument a] -> (\c -> [E.ret (E.call "lsf.cmpList" [ident "a", ident "b", ident c])]) <$> comparer env a
  Constructor "Maybe" [TypeArgument a] -> (\c -> [E.ret (E.call "lsf.cmpMaybe" [ident "a", ident "b", ident c])]) <$> comparer env a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- comparer env a
    cr <- comparer env b
    pure [E.ret (E.call "lsf.cmpEither" [ident "a", ident "b", ident cl, ident cr])]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ck <- comparer env k
        cv <- comparer env v
        pure [E.ret (E.call "lsf.cmpMap" [ident "a", ident "b", ident ck, ident cv])]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        ck <- comparer env a
        pure [E.ret (E.call "lsf.cmpMap" [ident "a", ident "b", ident ck, ident "lsf.cmpUnit"])]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    comparisons <- forM (dataConstructors d) $ \c -> forM (zip (constructorFields c) (fieldTypes d targs c)) $ \(f, ft) -> do
      cmp <- comparer env ft
      let (x, y) = fieldsAB (property f)
      pure (E.Block [ E.constDecl "c" (E.call cmp [x, y])
                    , E.IfSingle (E.Binary "!==" (ident "c") (E.num 0)) (E.ret (ident "c")) ])
    if isProductType d
      then pure (firstOf comparisons ++ [E.ret (E.num 0)])
      else pure ([ E.IfSingle (E.Binary "!==" (E.member (ident "a") "k") (E.member (ident "b") "k"))
                     (E.ret (E.Conditional (E.Binary "<" (E.member (ident "a") "k") (E.member (ident "b") "k")) (E.num (-1)) (E.num 1))) ] ++
                 [ E.If (kIs env "a" d c) cs Nothing | (c, cs) <- zip (dataConstructors d) comparisons, not (null cs) ] ++
                 [E.ret (E.num 0)])
  _ -> lift' (Left ("typed JavaScript: no order for " ++ show ty))

-- Conversions to and from the dynamic values, whose integers are BigInts.

dataValue :: String -> [E.Expr] -> E.Expr
dataValue tag fields = E.new' "ls.DataValue" [E.Str tag, E.Array fields]

-- | const out = []; lsf.each(x, (k, v) => { out.push(...); });
collected :: Env -> String -> [String] -> E.Expr -> [E.Stmt]
collected env out params pushed =
  [ E.VarDecl "const" (E.PIdent out) (if envTs env then Just (E.TArray anyT) else Nothing) (Just (E.Array []))
  , E.ExprStmt (E.call "lsf.each" [ident "x", E.arrowBlock [annotated env p anyT | p <- params]
      [E.ExprStmt (E.method (ident out) "push" [pushed])]]) ]

toValue :: Env -> Type -> M [E.Stmt]
toValue env ty = case ty of
  Constructor "Unit" [] -> pure [E.ret (ident "ls.UNIT")]
  Constructor n [] | n `elem` ["Bool", "Text", "Bytes"] -> pure [E.ret (ident "x")]
  Constructor n [] | n `elem` scalarTypes -> pure [E.ret (E.call "BigInt" [ident "x"])]
  Constructor "List" [TypeArgument a] -> (\f -> [E.ret (E.call "lsf.toListValue" [ident "x", ident f])]) <$> helper "to" a
  Constructor "Maybe" [TypeArgument a] -> do
    f <- helper "to" a
    pure [E.ret (E.Conditional (E.Binary "===" (ident "x") E.Null) (dataValue "Maybe::Absent" [])
      (dataValue "Maybe::Present" [E.call f [E.member (ident "x") "v"]]))]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "to" a
    fr <- helper "to" b
    pure [E.ret (E.Conditional (E.member (ident "x") "r") (dataValue "Either::Right" [E.call fr [E.member (ident "x") "v"]])
      (dataValue "Either::Left" [E.call fl [E.member (ident "x") "v"]]))]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "to" k
        fv <- helper "to" v
        pure (collected env "entries" ["k", "v"] (dataValue (collectionsUnit ++ "::type::Entry::Entry") [E.call fk [ident "k"], E.call fv [ident "v"]]) ++
              [E.ret (dataValue (collectionsUnit ++ "::type::KeyVal::KeyValEntries") [ident "entries"])])
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- helper "to" a
        pure (collected env "items" ["k"] (E.call f [ident "k"]) ++
              [E.ret (dataValue (collectionsUnit ++ "::type::Set::SetItems") [ident "items"])])
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    if fieldless d
      then pure [E.ret (E.new' "ls.DataValue" [E.index (tagTable d) (ident "x"), E.Array []])]
      else do
        encoders <- forM (dataConstructors d) $ \c -> mapM (helper "to") (fieldTypes d targs c)
        let fieldsOf c es = [E.call e [E.member (ident "x") (property f)] | (f, e) <- zip (constructorFields c) es]
        if isProductType d
          then let c = firstOf (dataConstructors d) in pure [E.ret (dataValue (idText (constructorId c)) (fieldsOf c (firstOf encoders)))]
          else pure ([ E.IfSingle (kIs env "x" d c) (E.ret (dataValue (idText (constructorId c)) (fieldsOf c es)))
                     | (c, es) <- zip (dataConstructors d) encoders ] ++ [E.ret (E.call "lsf.unreachable" [])])
  _ -> lift' (Left ("typed JavaScript: no conversion for " ++ show ty))

tagTable :: DataDeclaration -> E.Expr
tagTable d = E.Array [E.Str (idText (constructorId c)) | c <- sortOn (rankOf d) (dataConstructors d)]

fields0 :: Int -> E.Expr
fields0 k = E.index (E.member (ident "v") "fields") (E.num (toInteger k))

fromValue :: Env -> Type -> M [E.Stmt]
fromValue env ty = case ty of
  Constructor "Unit" [] -> pure [E.ret E.Null]
  Constructor n [] | n `elem` ["Bool", "Text", "Bytes"] -> pure [E.ret (ident "v")]
  Constructor n [] | n `elem` small -> pure [E.ret (E.call "Number" [ident "v"])]
  Constructor n [] | n `elem` scalarTypes -> pure [E.ret (E.call "lsf.norm" [E.call "BigInt" [ident "v"]])]
  Constructor "List" [TypeArgument a] -> (\f -> [E.ret (E.call "lsf.fromListValue" [ident "v", ident f])]) <$> helper "from" a
  Constructor "Maybe" [TypeArgument a] -> do
    f <- helper "from" a
    pure [E.ret (E.Conditional (E.Binary "===" (E.member (ident "v") "tag") (E.Str "Maybe::Present"))
      (E.new' "lsf.Present" [E.call f [fields0 0]]) E.Null)]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "from" a
    fr <- helper "from" b
    pure [E.ret (E.Conditional (E.Binary "===" (E.member (ident "v") "tag") (E.Str "Either::Right"))
      (E.call "lsf.right" [E.call fr [fields0 0]]) (E.call "lsf.left" [E.call fl [fields0 0]]))]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "from" k
        fv <- helper "from" v
        cmp <- comparer env k
        let item i = E.index (E.member (ident "item") "fields") (E.num i)
        pure [ E.VarDecl "let" (E.PIdent "out") (if envTs env then Just (nullable "lsf.Node") else Nothing) (Just E.Null)
             , E.ForOf "const" (E.PIdent "item") (fields0 0)
                 [E.ExprStmt (E.Assign "=" (ident "out") (E.call "lsf.put" [ident "out", E.call fk [item 0], E.call fv [item 1], ident cmp]))]
             , E.ret (ident "out") ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- helper "from" a
        cmp <- comparer env a
        pure [ E.VarDecl "let" (E.PIdent "out") (if envTs env then Just (nullable "lsf.Node") else Nothing) (Just E.Null)
             , E.ForOf "const" (E.PIdent "item") (fields0 0)
                 [E.ExprStmt (E.Assign "=" (ident "out") (E.call "lsf.setInsert" [ident "out", E.call f [ident "item"], ident cmp]))]
             , E.ret (ident "out") ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    decoders <- forM (dataConstructors d) $ \c -> mapM (helper "from") (fieldTypes d targs c)
    let made c ds
          | fieldless d = E.num (toInteger (rankOf d c))
          | otherwise = E.New (ident (envClasses env M.! constructorId c)) [] [E.call dec [fields0 k] | (k, dec) <- zip [0 :: Int ..] ds]
    pure ([ E.IfSingle (E.Binary "===" (E.member (ident "v") "tag") (E.Str (idText (constructorId c)))) (E.ret (made c ds))
          | (c, ds) <- zip (dataConstructors d) decoders ] ++
          [E.Throw (E.new' "TypeError" [E.Binary "+" (E.Str ("expected " ++ dataName d ++ ", found ")) (E.member (ident "v") "tag")])])
  _ -> lift' (Left ("typed JavaScript: no conversion for " ++ show ty))

-- | Whether a type converts to and from its generated native type directly.
nativeDirect :: Env -> S.Set String -> Type -> Bool
nativeDirect env seen ty = case ty of
  Constructor n [] | n `elem` scalarTypes -> n /= "Unit"
  Constructor n [TypeArgument a] | n `elem` ["List", "Maybe"] -> nativeDirect env seen a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> nativeDirect env seen a && nativeDirect env seen b
  _ | Just (_, args) <- collectionArguments ty -> all (nativeDirect env seen) args
  Constructor n args | Just d <- M.lookup n (envData env), all (\c -> M.member (constructorId c) (envNative env)) (dataConstructors d) ->
      show ty `S.member` seen || all (nativeDirect env (S.insert (show ty) seen)) (concatMap (fieldTypes d [t | TypeArgument t <- args]) (dataConstructors d))
  _ -> False

byValueKey :: Type -> Bool
byValueKey (Constructor n []) = webByValue n
byValueKey _ = False

frozen :: E.Expr -> E.Expr
frozen x = E.call "Object.freeze" [x]

toNative :: Env -> Type -> M [E.Stmt]
toNative env ty = case ty of
  Constructor n [] | n `elem` ["Bool", "Text", "Bytes"] || n `elem` small -> pure [E.ret (ident "x")]
  Constructor n [] | n `elem` scalarTypes -> pure [E.ret (E.call "BigInt" [ident "x"])]
  Constructor "List" [TypeArgument a] -> (\f -> [E.ret (frozen (E.call "lsf.toListValue" [ident "x", ident f]))]) <$> helper "tonative" a
  Constructor "Maybe" [TypeArgument a] -> do
    f <- helper "tonative" a
    pure [E.ret (E.Conditional (E.Binary "===" (ident "x") E.Null) (E.new' "data.Absent" [])
      (E.new' "data.Present" [E.call f [E.member (ident "x") "v"]]))]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "tonative" a
    fr <- helper "tonative" b
    pure [E.ret (E.Conditional (E.member (ident "x") "r") (E.new' "data.Right" [E.call fr [E.member (ident "x") "v"]])
      (E.new' "data.Left" [E.call fl [E.member (ident "x") "v"]]))]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "tonative" k
        fv <- helper "tonative" v
        pure (collected env "pairs" ["k", "v"] (frozen (E.Array [E.call fk [ident "k"], E.call fv [ident "v"]])) ++
              [E.ret (if byValueKey k then E.new' "Map" [ident "pairs"] else frozen (ident "pairs"))])
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- helper "tonative" a
        pure (collected env "items" ["k"] (E.call f [ident "k"]) ++
              [E.ret (if byValueKey a then E.new' "Set" [ident "items"] else frozen (ident "items"))])
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
        nativeOf c = "data." ++ envNative env M.! constructorId c
    converters <- forM (dataConstructors d) $ \c -> mapM (helper "tonative") (fieldTypes d targs c)
    let made c cs = E.new' (nativeOf c) [E.call cv [E.member (ident "x") (property f)] | (f, cv) <- zip (constructorFields c) cs]
    if fieldless d
      then pure [E.ret (E.Call (E.index (E.Array [E.arrow [] (E.new' (nativeOf c) []) | c <- sortOn (rankOf d) (dataConstructors d)]) (ident "x")) [] [] False)]
      else if isProductType d
        then pure [E.ret (made (firstOf (dataConstructors d)) (firstOf converters))]
        else pure ([ E.IfSingle (kIs env "x" d c) (E.ret (made c cs)) | (c, cs) <- zip (dataConstructors d) converters ] ++
                   [E.ret (E.call "lsf.unreachable" [])])
  _ -> lift' (Left ("typed JavaScript: no native conversion for " ++ show ty))

fromNative :: Env -> Type -> M [E.Stmt]
fromNative env ty = case ty of
  Constructor n [] | n `elem` ["Bool", "Text", "Bytes"] || n `elem` small -> pure [E.ret (ident "n")]
  Constructor n [] | n `elem` scalarTypes -> pure [E.ret (E.call "lsf.norm" [E.call "BigInt" [ident "n"]])]
  Constructor "List" [TypeArgument a] -> (\f -> [E.ret (E.call "lsf.fromListValue" [ident "n", ident f])]) <$> helper "fromnative" a
  Constructor "Maybe" [TypeArgument a] -> do
    f <- helper "fromnative" a
    pure [E.ret (E.Conditional (E.Binary "instanceof" (ident "n") (ident "data.Present"))
      (E.new' "lsf.Present" [E.call f [E.member (ident "n") "value"]]) E.Null)]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "fromnative" a
    fr <- helper "fromnative" b
    pure [E.ret (E.Conditional (E.Binary "instanceof" (ident "n") (ident "data.Right"))
      (E.call "lsf.right" [E.call fr [E.member (ident "n") "value"]]) (E.call "lsf.left" [E.call fl [E.member (ident "n") "value"]]))]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "fromnative" k
        fv <- helper "fromnative" v
        cmp <- comparer env k
        pure [ E.VarDecl "let" (E.PIdent "out") (if envTs env then Just (nullable "lsf.Node") else Nothing) (Just E.Null)
             , E.ForOf "const" (E.PArray [E.PIdent "k", E.PIdent "v"])
                 (E.Conditional (E.Binary "instanceof" (ident "n") (ident "Map")) (E.method (ident "n") "entries" []) (ident "n"))
                 [E.ExprStmt (E.Assign "=" (ident "out") (E.call "lsf.put" [ident "out", E.call fk [ident "k"], E.call fv [ident "v"], ident cmp]))]
             , E.ret (ident "out") ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- helper "fromnative" a
        cmp <- comparer env a
        pure [ E.VarDecl "let" (E.PIdent "out") (if envTs env then Just (nullable "lsf.Node") else Nothing) (Just E.Null)
             , E.ForOf "const" (E.PIdent "item") (ident "n")
                 [E.ExprStmt (E.Assign "=" (ident "out") (E.call "lsf.setInsert" [ident "out", E.call f [ident "item"], ident cmp]))]
             , E.ret (ident "out") ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
        nativeOf c = "data." ++ envNative env M.! constructorId c
    converters <- forM (dataConstructors d) $ \c -> mapM (helper "fromnative") (fieldTypes d targs c)
    let made c cs
          | fieldless d = E.num (toInteger (rankOf d c))
          | otherwise = E.New (ident (envClasses env M.! constructorId c)) [] [E.call cv [E.member (ident "n") (binderName f)] | (f, cv) <- zip (constructorFields c) cs]
    if isProductType d
      then pure [E.ret (made (firstOf (dataConstructors d)) (firstOf converters))]
      else pure ([ E.IfSingle (E.Binary "instanceof" (ident "n") (ident (nativeOf c))) (E.ret (made c cs)) | (c, cs) <- zip (dataConstructors d) converters ] ++
                 [E.Throw (E.new' "TypeError" [E.Str ("expected " ++ dataName d)])])
  _ -> lift' (Left ("typed JavaScript: no native conversion for " ++ show ty))

_unusedTyped :: ()
_unusedTyped = const () (intercalate, toUpper, ident)
