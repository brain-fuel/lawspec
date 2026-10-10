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
-- ref:DEC-typed-native-definitions
module LawSpec.Typed.Web (WebTyped(..), emitWebTyped) where

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
import LawSpec.WebTypes (namesFor, webByValue, webTypeReferenceDoc)
import LawSpec.Time (isDurationType)
import qualified LawSpec.Code.Doc as D
import LawSpec.Digest (digestHex, digestString)

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

helper :: String -> Type -> M String
helper kind ty = do
  let key = show ty
  modify (\st -> st { stHelpers = M.insert key ty (stHelpers st), stWanted = S.insert (kind, key) (stWanted st) })
  pure (helperName kind ty)

helperName :: String -> Type -> String
helperName kind ty = kind ++ "_" ++ take 12 (digestHex (digestString (show ty)))

-- | A TypeScript annotation, or nothing in JavaScript.
ann :: Env -> String -> String
ann env t = if envTs env then ": " ++ t else ""

emitWebTyped :: Bool -> Int -> [DataDeclaration] -> [Unit] -> Either String WebTyped
emitWebTyped ts bits declarations units = do
  let plan = typedPlanPerforming scalarTypes declarations units
      datas = typedData plan
      functions = M.fromList [ (c, functionName c d) | (c, d) <- typedRepresentatives plan ]
  names <- namesFor [d | d <- declarations, collectionContainer (idText (dataId d)) == Nothing, not (isDurationType (idText (dataId d))), not (dataHandle d)]
  let env = Env plan (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions (classNames datas)
        (M.fromList names) units bits ts
      typedHandlers = [ h | u <- units, h <- unitHandlers u, isTypedHandler plan h ]
      handlerTypes = [ t | h <- typedHandlers, ref <- handlerAbilities h, Just (_, a) <- [findAbility units ref]
                         , (_, ty) <- abilityOperations a, let (args, result) = functionType ty, t <- result : args ]
      boundary = concat [ let (args, result) = functionType (declarationType (definitionDeclaration d)) in result : args
                        | d <- M.elems (typedDefinitions plan) ]
      starts = [ (handlerId h, "Start_" ++ show k, ty, start) | (k, h) <- zip [0 :: Int ..] typedHandlers, Just (ty, start) <- [handlerState h] ]
  ((classDocs, functionDocs, startDocs, helperDocs), _) <- flip runStateT (St 0 M.empty S.empty) $ do
    cs <- concat <$> mapM (classDoc env) datas
    fs <- mapM (\(c, d) -> functionDoc env c d) (typedRepresentatives plan)
    ss <- forM starts $ \(_, name, ty, start) -> do
      body <- cstmt env Nothing [(symbolsId, "symbols")] Return start
      t <- lift' (tsType env ty)
      pure (D.text ("export function " ++ name ++ "(symbols" ++ ann env "any" ++ ")" ++ ann env t ++ " ") <> braces body)
    forM_ boundary $ \t -> helper "to" t >> helper "from" t
    forM_ handlerTypes $ \t -> helper "nin" t >> helper "nout" t
    hs <- helpers env
    pure (cs, fs, ss, hs)
  let extension = if ts then "js" else "mjs"
      header = map D.text
        [ "// Generated by LawSpec. Do not edit."
        , "// Typed checked definitions over lawspec_fast's values; see"
        , "// docs/how-to/embed-a-generated-model.md."
        , "import * as data from './lawspec_data." ++ extension ++ "';"
        , "import * as ls from './lawspec_runtime." ++ extension ++ "';"
        , "import * as lsf from './lawspec_fast." ++ extension ++ "';"
        , "import * as schema from './lawspec_schema." ++ extension ++ "';"
        , ""
        , "const _lawspec_schema = data.makeSchema();"
        , "void schema;" ]
      source = D.render (D.Pretty 100) (D.joinWith D.hardline header <> D.hardline <> D.hardline <>
        D.joinWith (D.hardline <> D.hardline) (classDocs ++ orderingHelper env ++ functionDocs ++ startDocs ++ helperDocs)) ++ "\n"
  pure WebTyped
    { webTypedModule = source
    , webTypedFunction = \i -> definitionClass plan i >>= (`M.lookup` functions)
    , webTypedFrom = helperName "from"
    , webTypedTo = helperName "to"
    , webTypedNativeIn = helperName "nin"
    , webTypedNativeOut = helperName "nout"
    , webTypedStart = \h -> case [n | (i, n, _, _) <- starts, i == h] of
        n : _ -> Just n
        [] -> Nothing
    , webTypedPlan = plan }
  where
    functionName c d = "Def_" ++ identifier (shortName (declarationName (definitionDeclaration d))) ++ "_" ++ show c
    shortName name =
      let unprefixed = if "lawspec_" `isPrefixOf` name then drop 8 name else name
      in reverse (dropHash (reverse unprefixed))
    dropHash reversed = case span (`elem` ("0123456789abcdef" :: String)) reversed of
      (digits@(_ : _), '_' : rest) | length digits >= 8 -> rest
      _ -> reversed

-- | The class of each typed constructor, and the union of a sum's.
classNames :: [DataDeclaration] -> M.Map Id String
classNames datas = M.fromList (snd (foldl pick (S.empty, []) datas))
  where
    pick (taken, acc) d =
      let base = "T_" ++ identifier (dataName d)
          chosen = firstOf [n | n <- base : [base ++ "_" ++ show k | k <- [2 :: Int ..]], n `S.notMember` taken]
          variants = [ (constructorId c, chosen ++ "_" ++ identifier (constructorName c)) | length (dataConstructors d) > 1, c <- dataConstructors d ]
          own = [ (constructorId c, chosen) | length (dataConstructors d) == 1, c <- dataConstructors d ]
      in (foldr S.insert (S.insert chosen taken) (map snd variants), (dataId d, chosen) : variants ++ own ++ acc)

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
property b = let n = identifier (binderName b) in if n `elem` ["constructor", "k", "__proto__", "prototype"] then "f_" ++ n else n

small :: [String]
small = ["Int8", "Int16", "Int32", "UInt8", "UInt16", "UInt32"]

-- | Types whose === is LawSpec's equality.
plainEq :: Env -> Type -> Bool
plainEq env ty = case ty of
  Constructor n [] | n `elem` scalarTypes -> n /= "Bytes"
  Constructor n _ | Just d <- M.lookup n (envData env) -> fieldless d
  _ -> False

tsType :: Env -> Type -> Either String String
tsType env = go []
  where
    go parameters ty = case ty of
      TypeVariable v | Just p <- lookup v parameters -> pure p
      Constructor "Bool" [] -> pure "boolean"
      Constructor "Unit" [] -> pure "null"
      Constructor n [] | n `elem` small -> pure "number"
      Constructor n [] | n `elem` ["Int64", "UInt64", "Integer"] -> pure "number | bigint"
      Constructor "Text" [] -> pure "string"
      Constructor "Bytes" [] -> pure "Uint8Array"
      Constructor "List" _ -> pure "lsf.Cons | null"
      Constructor "Maybe" _ -> pure "lsf.Just | null"
      Constructor "Either" _ -> pure "lsf.Side"
      _ | isJust (collectionArguments ty) -> pure "lsf.Node | null"
      Constructor n args | Just d <- M.lookup n (envData env) ->
        if fieldless d then pure "number" else do
          rendered <- mapM (\a -> case a of TypeArgument t -> go parameters t; _ -> Left "typed TypeScript: index argument") args
          pure (envClasses env M.! dataId d ++ (if null rendered then "" else "<" ++ intercalate ", " rendered ++ ">"))
      _ -> Left ("no typed TypeScript form for " ++ show ty)

classDoc :: Env -> DataDeclaration -> M [D.Doc]
classDoc env d
  | fieldless d = pure []
  | otherwise = do
      let parameters = zip (dataParameters d) ["T" ++ show k | k <- [0 :: Int ..]]
          generics = if null parameters || not (envTs env) then "" else "<" ++ intercalate ", " (map snd parameters) ++ ">"
          tsField ty = case tsTypeP parameters ty of
            Right t -> t
            Left _ -> "any"
          variant c =
            let name = envClasses env M.! constructorId c
                fields = constructorFields c
                params = [ "a" ++ show k ++ ann env (tsField (binderType f)) | (k, f) <- zip [0 :: Int ..] fields ]
                declarations = if envTs env
                  then [D.text ("readonly k: " ++ show (rankOf d c) ++ ";") | not (isProductType d)] ++
                       [D.text ("readonly " ++ property f ++ ": " ++ tsField (binderType f) ++ ";") | f <- fields]
                  else []
                assignments = [D.text ("this.k = " ++ show (rankOf d c) ++ ";") | not (isProductType d)] ++
                  [D.text ("this." ++ property f ++ " = a" ++ show k ++ ";") | (k, f) <- zip [0 :: Int ..] fields]
            in D.text ("// " ++ idText (constructorId c)) <> D.hardline <>
               D.text ("export class " ++ name ++ generics ++ " ") <> braces
                 (declarations ++ [D.text ("constructor(" ++ intercalate ", " params ++ ") ") <> braces assignments])
          union = [ D.text ("export type " ++ envClasses env M.! dataId d ++ generics ++ " = " ++
                      intercalate " | " [envClasses env M.! constructorId c ++ generics | c <- dataConstructors d] ++ ";")
                  | envTs env, not (isProductType d) ]
      pure (map variant (dataConstructors d) ++ union)
  where
    tsTypeP parameters ty = case ty of
      TypeVariable v | Just p <- lookup v parameters -> pure p
      Constructor n args | Just d' <- M.lookup n (envData env), not (fieldless d') -> do
        rendered <- mapM (\a -> case a of TypeArgument t -> tsTypeP parameters t; _ -> Left "index") args
        pure (envClasses env M.! dataId d' ++ (if null rendered then "" else "<" ++ intercalate ", " rendered ++ ">"))
      _ -> tsType env ty

orderingHelper :: Env -> [D.Doc]
orderingHelper env = case M.lookup (collectionsUnit ++ "::type::Ordering") (envData env) of
  Nothing -> []
  Just d ->
    let rank name = firstOf ([rankOf d c | c <- dataConstructors d, constructorName c == name] ++ [0])
    in [D.text ("function Ordering_of(c" ++ ann env "number" ++ ")" ++ ann env "number" ++ " ") <> braces
         [D.text ("return c < 0 ? " ++ show (rank "Less") ++ " : c === 0 ? " ++ show (rank "Equal") ++ " : " ++ show (rank "Greater") ++ ";")]]

-- Statements.

braces :: [D.Doc] -> D.Doc
braces body = D.text "{" <> D.nest 2 (D.hardline <> D.joinWith D.hardline body) <> D.hardline <> D.text "}"

stmtBlock :: D.Doc -> [D.Doc] -> D.Doc
stmtBlock header body = header <> D.text " " <> braces body

paren :: D.Doc -> D.Doc
paren x = D.text "(" <> x <> D.text ")"

data Target = Return | Assign String

type Scope = [(Id, String)]

symbolsId :: Id
symbolsId = Id "lawspec::symbols"

functionDoc :: Env -> Int -> Definition -> M D.Doc
functionDoc env c d = do
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
      x <- intrinsicCall env intrinsic [(D.text l, binderType b) | ((_, l, _), b) <- zip params (definitionArguments d)]
      pure [D.text "return " <> x <> D.text ";"]
    Nothing -> cstmt env selfCall scope Return (definitionBody d)
  pure (D.text ("// " ++ idText (declarationId declaration)) <> D.hardline <>
    D.text ("export function " ++ name ++ "(" ++ intercalate ", " (["symbols" ++ ann env "any" | contextual] ++ [l ++ ann env t | (_, l, t) <- params]) ++ ")" ++ ann env resultType ++ " ") <>
      braces (if looping then [stmtBlock (D.text "for (;;)") body] else body))

hasTailSelf :: Env -> Int -> Expr -> Bool
hasTailSelf env c e = case expressionNode e of
  ExternalCall i _ -> definitionClass (envPlan env) i == Just c && M.notMember i (typedIntrinsics (envPlan env))
  If _ a b -> hasTailSelf env c a || hasTailSelf env c b
  Match _ cases -> any (hasTailSelf env c . caseBody) cases
  Let _ _ body -> hasTailSelf env c body
  Helper Select [_, a, b] -> hasTailSelf env c a || hasTailSelf env c b
  _ -> False

deliver :: Target -> D.Doc -> D.Doc
deliver Return x = D.text "return " <> x <> D.text ";"
deliver (Assign v) x = D.text (v ++ " = ") <> x <> D.text ";"

cstmt :: Env -> Maybe (Int, [String]) -> Scope -> Target -> Expr -> M [D.Doc]
cstmt env selfCall scope target e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    local <- fresh (binderName binder)
    rest <- cstmt env selfCall ((binderId binder, local) : scope) target body
    pure (s ++ [D.text ("const " ++ local ++ " = ") <> x <> D.text ";"] ++ rest)
  If c a b -> do
    (s, x) <- cexpr env scope c
    yes <- cstmt env selfCall scope target a
    no <- cstmt env selfCall scope target b
    pure (s ++ [stmtBlock (D.text "if (" <> x <> D.text ")") yes <> D.text " else " <> braces no])
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
          pure (s ++ [D.text ("const " ++ t ++ " = ") <> x <> D.text ";"], D.text (p ++ " = " ++ t ++ ";"))
        pure (concatMap fst evaluated ++ map snd evaluated ++ [D.text "continue;"])
  Helper Unreachable _ -> pure [D.text "return lsf.unreachable();"]
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
    name <- lift' (maybe (Left ("typed JavaScript: unbound local " ++ idText i)) Right (lookup i scope))
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
        c <- lift' (maybe (Left ("typed JavaScript: untyped callee " ++ idText i)) Right (definitionClass (envPlan env) i))
        parts <- mapM (cexpr env scope) args
        let context = [D.text "symbols" | isContextual (envPlan env) i]
        pure (concatMap fst parts, D.text (envFunctions env M.! c ++ "(") <> D.joinWith (D.text ", ") (context ++ map snd parts) <> D.text ")")
  ShortCircuit op a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    if null sb
      then pure (sa, paren (xa <> D.text (if op == And then " && " else " || ") <> xb))
      else do
        t <- fresh "logic"
        pure (sa ++ [ D.text ("let " ++ t ++ " = ") <> xa <> D.text ";"
                    , stmtBlock (D.text (if op == And then "if (" ++ t ++ ")" else "if (!" ++ t ++ ")")) (sb ++ [D.text (t ++ " = ") <> xb <> D.text ";"]) ], D.text t)
  Unary Not a -> do
    (s, x) <- cexpr env scope a
    pure (s, D.text "!" <> paren x)
  Unary Negate a -> do
    (s, x) <- cexpr env scope a
    pure (s, D.text "lsf.neg(" <> x <> D.text ")")
  Binary op (Structural t) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    eq <- equaler env t
    let test = if eq == "lsf.eqPlain" then paren (xa <> D.text " === " <> xb) else D.text (eq ++ "(") <> xa <> D.text ", " <> xb <> D.text ")"
    pure (sa ++ sb, if op == Equal then test else D.text "!" <> test)
  Binary op (Numeric _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    let smallOperands = all (isSmall . expressionType) [a, b]
        infix' symbol = pure (sa ++ sb, paren (xa <> D.text symbol <> xb))
        call f = pure (sa ++ sb, D.text ("lsf." ++ f ++ "(") <> xa <> D.text ", " <> xb <> D.text ")")
    case op of
      Add | smallOperands -> infix' " + "
          | otherwise -> call "add"
      Subtract | smallOperands -> infix' " - "
               | otherwise -> call "sub"
      Multiply -> call "mul"
      Quotient -> call "quot"
      Remainder -> call "rem"
      Power -> call "power"
      Equal -> infix' " === "
      NotEqual -> infix' " !== "
      Less -> infix' " < "
      LessEqual -> infix' " <= "
      Greater -> infix' " > "
      GreaterEqual -> infix' " >= "
      _ -> lift' (Left ("typed JavaScript: unsupported operator " ++ show op))
  Convert _ target value -> convert env scope target value
  Helper Compare [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    cmp <- comparer env (expressionType a)
    pure (sa ++ sb, D.text ("Ordering_of(" ++ cmp ++ "(") <> xa <> D.text ", " <> xb <> D.text "))")
  Helper Length [x] -> do
    (s, v) <- cexpr env scope x
    pure (s, case expressionType x of
      Constructor "Text" [] -> D.text "lsf.textLength(" <> v <> D.text ")"
      Constructor "Bytes" [] -> v <> D.text ".length"
      _ -> D.text "lsf.length(" <> v <> D.text ")")
  Helper Unreachable _ -> pure ([], D.text "lsf.unreachable()")
  Helper Checked _ -> pure ([], D.text "true")
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
    pure (sx ++ [ D.text ("let " ++ t ++ " = true;")
                , stmtBlock (D.text ("for (let " ++ cell ++ ann env "lsf.Cons | null" ++ " = ") <> xs <> D.text ("; " ++ cell ++ " !== null; " ++ cell ++ " = " ++ cell ++ ".t)"))
                    ([D.text ("const " ++ item ++ " = " ++ cell ++ ".h;")] ++ sp ++
                     [stmtBlock (D.text "if (!" <> paren p <> D.text ")") [D.text (t ++ " = false;"), D.text "break;"]]) ], D.text t)
  Perform (Operation ref "raise") [x] | isFail ref -> do
    (s, v) <- cexpr env scope x
    to <- helper "to" (expressionType x)
    pure (s ++ [D.text ("throw new ls.Failure(" ++ quote (abilityKey ref) ++ ", " ++ to ++ "(") <> v <> D.text "));"], D.text "lsf.unreachable()")
  Perform op args -> do
    parts <- mapM (cexpr env scope) args
    outs <- mapM (helper "nout" . expressionType) args
    nin <- helper "nin" (expressionType e)
    r <- fresh "performed"
    let call = D.text ("(ls.handler(symbols, " ++ quote (abilityKey (operationAbility op)) ++ ")" ++ (if envTs env then " as any" else "") ++ ")." ++ operationName op ++ "(") <>
          D.joinWith (D.text ", ") [D.text (o ++ "(") <> x <> D.text ", symbols)" | (o, x) <- zip outs (map snd parts)] <> D.text ")"
    failure <- case performedFailure (envUnits env) op of
      Just failing@(AbilityRef _ [failureType]) -> do
        ref <- lift' (webTypeReferenceDoc failureType)
        pure (Just (failing, ref))
      _ -> pure Nothing
    let invoke = case failure of
          Nothing -> [D.text ("const " ++ r ++ " = ") <> call <> D.text ";"]
          Just (failing, ref) ->
            [ D.text ("let " ++ r ++ ann env "unknown" ++ ";")
            , stmtBlock (D.text "try") [D.text (r ++ " = ") <> call <> D.text ";"] <> D.text " catch (error) " <> braces
                [ stmtBlock (D.text "if (error instanceof ls.Fail)")
                    [D.text ("throw new ls.Failure(" ++ quote (abilityKey failing) ++ ", ls.handlerSchema(_lawspec_schema).fromNative(") <> ref <>
                     D.text (", (error" ++ (if envTs env then " as any" else "") ++ ").value, " ++ show (envBits env) ++ ", symbols));")]
                , D.text "throw error;" ] ]
    pure (concatMap fst parts ++ invoke, D.text (nin ++ "(" ++ r ++ ", symbols)"))
  Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, _] <- expressionType e -> do
    t <- fresh "attempted"
    from <- helper "from" failure
    (s, v) <- cexpr env scope body
    pure ([ D.text ("let " ++ t ++ ann env "lsf.Side" ++ ";")
          , stmtBlock (D.text "try") (s ++ [D.text (t ++ " = lsf.right(") <> v <> D.text ");"]) <> D.text " catch (failure) " <> braces
              [ stmtBlock (D.text ("if (!(failure instanceof ls.Failure) || (failure" ++ (if envTs env then " as any" else "") ++ ").ability !== " ++ quote (abilityKey ref) ++ ")")) [D.text "throw failure;"]
              , D.text (t ++ " = lsf.left(" ++ from ++ "((failure" ++ (if envTs env then " as any" else "") ++ ").value));") ] ], D.text t)
  Helper Append [a, b] -> case expressionType a of
    Constructor "Text" [] -> do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, paren (xa <> D.text " + " <> xb))
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
    pure (sx ++ si ++ sj, D.text (f ++ "(") <> v <> D.text ", " <> i <> D.text ", " <> j <> D.text ")")
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
      ty <- lift' (tsType env (expressionType e))
      s <- cstmt env Nothing scope (Assign t) e
      pure (D.text ("let " ++ t ++ (if envTs env then "!: " ++ ty else "") ++ ";") : s, D.text t)

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

quote :: String -> String
quote s = "'" ++ concatMap escape s ++ "'"
  where
    escape c
      | c == '\'' = "\\'"
      | c == '\\' = "\\\\"
      | ord c < 32 || ord c == 127 = "\\x" ++ pad 2 (showHex (ord c) "")
      | ord c > 127 && ord c < 0x10000 = "\\u" ++ pad 4 (showHex (ord c) "")
      | ord c >= 0x10000 = "\\u{" ++ showHex (ord c) "" ++ "}"
      | otherwise = [c]
    pad n h = replicate (n - length h) '0' ++ h

constant :: Scalar -> Either String D.Doc
constant s = case s of
  SBool b -> pure (D.text (if b then "true" else "false"))
  SAbsent "Unit" -> pure (D.text "null")
  SInteger _ n -> pure (D.text (integerLiteral n))
  SSequence "Text" units -> pure (D.text (quote (map toEnum units)))
  SSequence "Bytes" units -> pure (D.text ("Uint8Array.of(" ++ intercalate ", " (map show units) ++ ")"))
  _ -> Left ("typed JavaScript: unsupported constant " ++ show s)

-- | A canonical integer: a number when safe, a BigInt beyond.
integerLiteral :: Integer -> String
integerLiteral n
  | abs n <= 9007199254740991 = if n < 0 then "(" ++ show n ++ ")" else show n
  | otherwise = "(" ++ show n ++ "n)"

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
      in if inside then pure (s, x)
         else pure (s, D.text "lsf.narrow(" <> x <> D.text (", " ++ integerLiteral lo ++ ", " ++ integerLiteral hi ++ ", " ++ quote t ++ ")"))
    _ -> pure (s, x)

construct :: Env -> Type -> Id -> [D.Doc] -> M D.Doc
construct env ty tag values = case (idText tag, values) of
  ("List::Nil", []) -> pure (D.text "null")
  ("List::Cons", [h, t]) -> pure (D.text "new lsf.Cons(" <> h <> D.text ", " <> t <> D.text ")")
  ("Maybe::Nothing", []) -> pure (D.text "null")
  ("Maybe::Just", [x]) -> pure (D.text "new lsf.Just(" <> x <> D.text ")")
  ("Either::Left", [x]) -> pure (D.text "lsf.left(" <> x <> D.text ")")
  ("Either::Right", [x]) -> pure (D.text "lsf.right(" <> x <> D.text ")")
  (_, [items]) | Just ("KeyVal", [k, _]) <- collectionArguments ty -> do
    cmp <- comparer env k
    (key, value) <- entryAccess env
    pure (D.text "lsf.keyValOf(" <> items <> D.text (", " ++ key ++ ", " ++ value ++ ", " ++ cmp ++ ")"))
  (_, [items]) | Just ("Set", [a]) <- collectionArguments ty -> do
    cmp <- comparer env a
    pure (D.text "lsf.setOf(" <> items <> D.text (", " ++ cmp ++ ")"))
  _ -> case M.lookup tag (envConstructors env) of
    Just (d, c)
      | fieldless d -> pure (D.text (show (rankOf d c)))
      | otherwise -> pure (D.text ("new " ++ envClasses env M.! constructorId c ++ "(") <> D.joinWith (D.text ", ") values <> D.text ")")
    Nothing -> lift' (Left ("typed JavaScript: unknown constructor " ++ idText tag))

-- | An Entry's key and value, as functions.
entryAccess :: Env -> M (String, String)
entryAccess env = case M.lookup (collectionsUnit ++ "::type::Entry") (envData env) of
  Just d | [c] <- dataConstructors d, [k, v] <- constructorFields c ->
    pure ("(e" ++ ann env "any" ++ ") => e." ++ property k, "(e" ++ ann env "any" ++ ") => e." ++ property v)
  _ -> lift' (Left "typed JavaScript: no typed Entry")

entryMaker :: Env -> M String
entryMaker env = case M.lookup (collectionsUnit ++ "::type::Entry") (envData env) of
  Just d | [c] <- dataConstructors d -> pure ("(k" ++ ann env "any" ++ ", v" ++ ann env "any" ++ ") => new " ++ envClasses env M.! constructorId c ++ "(k, v)")
  _ -> lift' (Left "typed JavaScript: no typed Entry")

intrinsicCall :: Env -> Intrinsic -> [(D.Doc, Type)] -> M D.Doc
intrinsicCall env intrinsic args = case (intrinsic, args) of
  (KeyValOf, [(es, Constructor "List" [TypeArgument (Constructor _ [TypeArgument k, _])])]) -> do
    cmp <- comparer env k
    (key, value) <- entryAccess env
    pure (D.text "lsf.keyValOf(" <> es <> D.text (", " ++ key ++ ", " ++ value ++ ", " ++ cmp ++ ")"))
  (KeyValLookup, [(k, kt), (m, _)]) -> keyed kt "lsf.lookup" [m, k]
  (KeyValPut, [(k, kt), (v, _), (m, _)]) -> keyed kt "lsf.put" [m, k, v]
  (KeyValDelete, [(k, kt), (m, _)]) -> keyed kt "lsf.remove" [m, k]
  (KeyValKeys, [(m, _)]) -> pure (D.text "lsf.keysList(" <> m <> D.text ")")
  (KeyValValues, [(m, _)]) -> pure (D.text "lsf.valuesList(" <> m <> D.text ")")
  (KeyValEntries, [(m, _)]) -> do
    entry <- entryMaker env
    pure (D.text "lsf.entriesList(" <> m <> D.text (", " ++ entry ++ ")"))
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
      pure (D.text (f ++ "(") <> D.joinWith (D.text ", ") (xs ++ [D.text cmp]) <> D.text ")")
    setOp f s st t = case collectionArguments st of
      Just (_, [a]) -> keyed a f [s, t]
      _ -> lift' (Left "typed JavaScript: set operation on a non-set")

matchStatements :: Env -> Maybe (Int, [String]) -> Scope -> Target -> Expr -> [MatchCase] -> M [D.Doc]
matchStatements env selfCall scope target value cases = do
  let ty = expressionType value
      used c b = binderId b `elem` freeBinders (caseBody c)
      arm c accesses = do
        bound <- forM (zip (caseBinders c) accesses) $ \(b, access) ->
          if used c b then do
            n <- fresh (binderName b)
            pure (Just (binderId b, n), [D.text ("const " ++ n ++ " = " ++ access ++ ";")])
          else pure (Nothing, [])
        body <- cstmt env selfCall ([x | (Just x, _) <- bound] ++ scope) target (caseBody c)
        pure (concatMap snd bound ++ body)
      unreachable = [D.text "return lsf.unreachable();"]
      caseOf tag = [c | c <- cases, idText (caseConstructor c) == tag]
      orUnreachable tag accesses = case caseOf tag of
        c : _ -> arm c accesses
        [] -> pure unreachable
      cast x cls = if envTs env then "(" ++ x ++ " as " ++ cls ++ ")" else x
  (prelude, subject) <- case expressionNode value of
    Local i | Just name <- lookup i scope -> pure ([], name)
    _ -> do
      (s, x) <- cexpr env scope value
      t <- fresh "matched"
      pure (s ++ [D.text ("const " ++ t ++ " = ") <> x <> D.text ";"], t)
  let two condition yesTag yesAccess noTag noAccess = do
        yes <- orUnreachable yesTag yesAccess
        no <- orUnreachable noTag noAccess
        pure (prelude ++ [stmtBlock (D.text ("if (" ++ condition ++ ")")) yes <> D.text " else " <> braces no])
      anyCast x = if envTs env then "(" ++ x ++ " as any)" else x
  case ty of
    Constructor "Maybe" _ -> two (subject ++ " !== null") "Maybe::Just" [anyCast subject ++ ".v"] "Maybe::Nothing" []
    Constructor "Either" _ -> two (subject ++ ".r") "Either::Right" [subject ++ ".v"] "Either::Left" [subject ++ ".v"]
    Constructor "List" _ -> two (subject ++ " === null") "List::Nil" [] "List::Cons" [anyCast subject ++ ".h", anyCast subject ++ ".t"]
    _ | Just (kind, _) <- collectionArguments ty, [c] <- cases -> do
          entry <- if kind == "KeyVal" then entryMaker env else pure ""
          (prelude ++) <$> arm c [if kind == "KeyVal" then "lsf.entriesList(" ++ subject ++ ", " ++ entry ++ ")" else "lsf.keysList(" ++ subject ++ ")"]
    Constructor n _ | Just d <- M.lookup n (envData env) -> do
      let conOf c = snd (envConstructors env M.! caseConstructor c)
          fieldsOf c = [cast subject (envClasses env M.! constructorId (conOf c) ++ "<any>") ++ "." ++ property f | f <- constructorFields (conOf c)]
          fieldsOf' c = if null (dataParameters d) then [cast subject (envClasses env M.! constructorId (conOf c)) ++ "." ++ property f | f <- constructorFields (conOf c)] else fieldsOf c
      if isProductType d
        then case cases of
          [c] -> (prelude ++) <$> arm c [subject ++ "." ++ property f | f <- constructorFields (conOf c)]
          _ -> lift' (Left "typed JavaScript: product match")
        else do
          arms <- forM (sortOn (rankOf d . conOf) cases) $ \c -> do
            body <- arm c (fieldsOf' c)
            pure (rankOf d (conOf c), body)
          let tag = if fieldless d then subject else subject ++ ".k"
          pure (prelude ++ [D.text ("switch (" ++ tag ++ ") ") <> braces
            ([ D.text ("case " ++ show r ++ ": ") <> braces (body ++ [D.text "break;"]) | (r, body) <- arms ] ++ [D.text "default: " <> braces unreachable])])
    _ -> lift' (Left ("typed JavaScript: cannot match on " ++ show ty))

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
      a = ann env "any"
      fn params result body = D.text ("// " ++ kind ++ " " ++ show ty) <> D.hardline <>
        D.text ("export function " ++ name ++ "(" ++ intercalate ", " [p ++ a | p <- params] ++ ")" ++ ann env result ++ " ") <> braces body
  case kind of
    "eq" -> fn ["a", "b"] "boolean" <$> equality env ty
    "cmp" -> fn ["a", "b"] "number" <$> ordering env ty
    "to" -> fn ["x"] "any" <$> toValue env ty
    "from" -> fn ["v"] "any" <$> fromValue env ty
    "tonative" -> fn ["x"] "any" <$> toNative env ty
    "fromnative" -> fn ["n"] "any" <$> fromNative env ty
    "nin" -> fn ["n", "symbols"] "any" <$> nativeIn env ty
    _ -> fn ["x", "symbols"] "any" <$> nativeOut env ty

nativeIn :: Env -> Type -> M [D.Doc]
nativeIn env ty
  | ty == Constructor "Unit" [] = pure [D.text "return null;"]
  | otherwise = do
      ref <- lift' (webTypeReferenceDoc ty)
      from <- helper "from" ty
      let viaSchema = D.text ("return " ++ from ++ "(ls.handlerSchema(_lawspec_schema).fromNative(") <> ref <> D.text (", n, " ++ show (envBits env) ++ ", symbols));")
      if nativeDirect env S.empty ty
        then do
          direct <- helper "fromnative" ty
          pure [D.text ("if (!lsf.bound()) return " ++ direct ++ "(n);"), viaSchema]
        else pure [viaSchema]

nativeOut :: Env -> Type -> M [D.Doc]
nativeOut env ty
  | ty == Constructor "Unit" [] = pure [D.text "return undefined;"]
  | otherwise = do
      ref <- lift' (webTypeReferenceDoc ty)
      to <- helper "to" ty
      let viaSchema = D.text "return ls.handlerSchema(_lawspec_schema).toNative(" <> ref <> D.text (", " ++ to ++ "(x), " ++ show (envBits env) ++ ", symbols);")
      if nativeDirect env S.empty ty
        then do
          direct <- helper "tonative" ty
          pure [D.text ("if (!lsf.bound()) return " ++ direct ++ "(x);"), viaSchema]
        else pure [viaSchema]

equality :: Env -> Type -> M [D.Doc]
equality env ty = case ty of
  _ | plainEq env ty -> pure [D.text "return a === b;"]
  Constructor "Bytes" [] -> pure [D.text "return lsf.eqBytes(a, b);"]
  Constructor "List" [TypeArgument a] -> (\e -> [D.text ("return lsf.eqList(a, b, " ++ e ++ ");")]) <$> equaler env a
  Constructor "Maybe" [TypeArgument a] -> (\e -> [D.text ("return lsf.eqMaybe(a, b, " ++ e ++ ");")]) <$> equaler env a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    el <- equaler env a
    er <- equaler env b
    pure [D.text ("return lsf.eqEither(a, b, " ++ el ++ ", " ++ er ++ ");")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ek <- equaler env k
        ev <- equaler env v
        pure [D.text ("return lsf.eqMap(a, b, " ++ ek ++ ", " ++ ev ++ ");")]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        ek <- equaler env a
        pure [D.text ("return lsf.eqMap(a, b, " ++ ek ++ ", lsf.eqUnit);")]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    checks <- forM (dataConstructors d) $ \c -> forM (zip (constructorFields c) (fieldTypes d targs c)) $ \(f, ft) -> do
      e <- equaler env ft
      let p = property f
      pure (if e == "lsf.eqPlain" then "a." ++ p ++ " === b." ++ p else e ++ "(a." ++ p ++ ", b." ++ p ++ ")")
    if isProductType d
      then pure [D.text "if (a === b) return true;", D.text ("return " ++ intercalate " && " ("true" : firstOf checks) ++ ";")]
      else pure ([ D.text "if (a === b) return true;", D.text "if (a.k !== b.k) return false;" ] ++
                 [ D.text ("if (a.k === " ++ show (rankOf d c) ++ ") return " ++ intercalate " && " ("true" : cs) ++ ";")
                 | (c, cs) <- zip (dataConstructors d) checks, not (null cs) ] ++ [D.text "return true;"])
  _ -> lift' (Left ("typed JavaScript: no equality for " ++ show ty))

ordering :: Env -> Type -> M [D.Doc]
ordering env ty = case ty of
  Constructor "List" [TypeArgument a] -> (\c -> [D.text ("return lsf.cmpList(a, b, " ++ c ++ ");")]) <$> comparer env a
  Constructor "Maybe" [TypeArgument a] -> (\c -> [D.text ("return lsf.cmpMaybe(a, b, " ++ c ++ ");")]) <$> comparer env a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- comparer env a
    cr <- comparer env b
    pure [D.text ("return lsf.cmpEither(a, b, " ++ cl ++ ", " ++ cr ++ ");")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ck <- comparer env k
        cv <- comparer env v
        pure [D.text ("return lsf.cmpMap(a, b, " ++ ck ++ ", " ++ cv ++ ");")]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        ck <- comparer env a
        pure [D.text ("return lsf.cmpMap(a, b, " ++ ck ++ ", lsf.cmpUnit);")]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    comparisons <- forM (dataConstructors d) $ \c -> forM (zip (constructorFields c) (fieldTypes d targs c)) $ \(f, ft) -> do
      cmp <- comparer env ft
      let p = property f
      pure (D.text ("{ const c = " ++ cmp ++ "(a." ++ p ++ ", b." ++ p ++ "); if (c !== 0) return c; }"))
    if isProductType d
      then pure (firstOf comparisons ++ [D.text "return 0;"])
      else pure ([ D.text "if (a.k !== b.k) return a.k < b.k ? -1 : 1;" ] ++
                 [ stmtBlock (D.text ("if (a.k === " ++ show (rankOf d c) ++ ")")) cs | (c, cs) <- zip (dataConstructors d) comparisons, not (null cs) ] ++
                 [D.text "return 0;"])
  _ -> lift' (Left ("typed JavaScript: no order for " ++ show ty))

-- Conversions to and from the dynamic values, whose integers are BigInts.

toValue :: Env -> Type -> M [D.Doc]
toValue env ty = case ty of
  Constructor "Unit" [] -> pure [D.text "return ls.UNIT;"]
  Constructor n [] | n `elem` ["Bool", "Text", "Bytes"] -> pure [D.text "return x;"]
  Constructor n [] | n `elem` scalarTypes -> pure [D.text "return BigInt(x);"]
  Constructor "List" [TypeArgument a] -> (\f -> [D.text ("return lsf.toListValue(x, " ++ f ++ ");")]) <$> helper "to" a
  Constructor "Maybe" [TypeArgument a] -> do
    f <- helper "to" a
    pure [D.text ("return x === null ? new ls.DataValue('Maybe::Nothing', []) : new ls.DataValue('Maybe::Just', [" ++ f ++ "(x.v)]);")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "to" a
    fr <- helper "to" b
    pure [D.text ("return x.r ? new ls.DataValue('Either::Right', [" ++ fr ++ "(x.v)]) : new ls.DataValue('Either::Left', [" ++ fl ++ "(x.v)]);")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "to" k
        fv <- helper "to" v
        pure [ D.text ("const out" ++ ann env "any[]" ++ " = [];")
             , D.text ("lsf.each(x, (k" ++ ann env "any" ++ ", v" ++ ann env "any" ++ ") => { out.push(new ls.DataValue(" ++ quote (collectionsUnit ++ "::type::Entry::Entry") ++ ", [" ++ fk ++ "(k), " ++ fv ++ "(v)])); });")
             , D.text ("return new ls.DataValue(" ++ quote (collectionsUnit ++ "::type::KeyVal::KeyValEntries") ++ ", [out]);") ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- helper "to" a
        pure [ D.text ("const out" ++ ann env "any[]" ++ " = [];")
             , D.text ("lsf.each(x, (k" ++ ann env "any" ++ ") => { out.push(" ++ f ++ "(k)); });")
             , D.text ("return new ls.DataValue(" ++ quote (collectionsUnit ++ "::type::Set::SetItems") ++ ", [out]);") ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    if fieldless d
      then pure [D.text ("return new ls.DataValue(" ++ tagTable d ++ "[x], []);")]
      else do
        encoders <- forM (dataConstructors d) $ \c -> mapM (helper "to") (fieldTypes d targs c)
        let fieldsOf c es = intercalate ", " [e ++ "(x." ++ property f ++ ")" | (f, e) <- zip (constructorFields c) es]
        if isProductType d
          then let c = firstOf (dataConstructors d) in pure [D.text ("return new ls.DataValue(" ++ quote (idText (constructorId c)) ++ ", [" ++ fieldsOf c (firstOf encoders) ++ "]);")]
          else pure ([ D.text ("if (x.k === " ++ show (rankOf d c) ++ ") return new ls.DataValue(" ++ quote (idText (constructorId c)) ++ ", [" ++ fieldsOf c es ++ "]);")
                     | (c, es) <- zip (dataConstructors d) encoders ] ++ [D.text "return lsf.unreachable();"])
  _ -> lift' (Left ("typed JavaScript: no conversion for " ++ show ty))

tagTable :: DataDeclaration -> String
tagTable d = "[" ++ intercalate ", " [quote (idText (constructorId c)) | c <- sortOn (rankOf d) (dataConstructors d)] ++ "]"

fromValue :: Env -> Type -> M [D.Doc]
fromValue env ty = case ty of
  Constructor "Unit" [] -> pure [D.text "return null;"]
  Constructor n [] | n `elem` ["Bool", "Text", "Bytes"] -> pure [D.text "return v;"]
  Constructor n [] | n `elem` small -> pure [D.text "return Number(v);"]
  Constructor n [] | n `elem` scalarTypes -> pure [D.text "return lsf.norm(BigInt(v));"]
  Constructor "List" [TypeArgument a] -> (\f -> [D.text ("return lsf.fromListValue(v, " ++ f ++ ");")]) <$> helper "from" a
  Constructor "Maybe" [TypeArgument a] -> do
    f <- helper "from" a
    pure [D.text ("return v.tag === 'Maybe::Just' ? new lsf.Just(" ++ f ++ "(v.fields[0])) : null;")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "from" a
    fr <- helper "from" b
    pure [D.text ("return v.tag === 'Either::Right' ? lsf.right(" ++ fr ++ "(v.fields[0])) : lsf.left(" ++ fl ++ "(v.fields[0]));")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "from" k
        fv <- helper "from" v
        cmp <- comparer env k
        pure [ D.text ("let out" ++ ann env "lsf.Node | null" ++ " = null;")
             , D.text ("for (const item of v.fields[0]) out = lsf.put(out, " ++ fk ++ "(item.fields[0]), " ++ fv ++ "(item.fields[1]), " ++ cmp ++ ");")
             , D.text "return out;" ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- helper "from" a
        cmp <- comparer env a
        pure [ D.text ("let out" ++ ann env "lsf.Node | null" ++ " = null;")
             , D.text ("for (const item of v.fields[0]) out = lsf.setInsert(out, " ++ f ++ "(item), " ++ cmp ++ ");")
             , D.text "return out;" ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
    decoders <- forM (dataConstructors d) $ \c -> mapM (helper "from") (fieldTypes d targs c)
    let made c ds
          | fieldless d = show (rankOf d c)
          | otherwise = "new " ++ envClasses env M.! constructorId c ++ "(" ++ intercalate ", " [dec ++ "(v.fields[" ++ show k ++ "])" | (k, dec) <- zip [0 :: Int ..] ds] ++ ")"
    pure ([ D.text ("if (v.tag === " ++ quote (idText (constructorId c)) ++ ") return " ++ made c ds ++ ";") | (c, ds) <- zip (dataConstructors d) decoders ] ++
          [D.text ("throw new TypeError('expected " ++ dataName d ++ ", found ' + v.tag);")])
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

toNative :: Env -> Type -> M [D.Doc]
toNative env ty = case ty of
  Constructor n [] | n `elem` ["Bool", "Text", "Bytes"] || n `elem` small -> pure [D.text "return x;"]
  Constructor n [] | n `elem` scalarTypes -> pure [D.text "return BigInt(x);"]
  Constructor "List" [TypeArgument a] -> (\f -> [D.text ("return Object.freeze(lsf.toListValue(x, " ++ f ++ "));")]) <$> helper "tonative" a
  Constructor "Maybe" [TypeArgument a] -> do
    f <- helper "tonative" a
    pure [D.text ("return x === null ? new data.Nothing() : new data.Just(" ++ f ++ "(x.v));")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "tonative" a
    fr <- helper "tonative" b
    pure [D.text ("return x.r ? new data.Right(" ++ fr ++ "(x.v)) : new data.Left(" ++ fl ++ "(x.v));")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "tonative" k
        fv <- helper "tonative" v
        pure [ D.text ("const pairs" ++ ann env "any[]" ++ " = [];")
             , D.text ("lsf.each(x, (k" ++ ann env "any" ++ ", v" ++ ann env "any" ++ ") => { pairs.push(Object.freeze([" ++ fk ++ "(k), " ++ fv ++ "(v)])); });")
             , D.text (if byValueKey k then "return new Map(pairs);" else "return Object.freeze(pairs);") ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- helper "tonative" a
        pure [ D.text ("const out" ++ ann env "any[]" ++ " = [];")
             , D.text ("lsf.each(x, (k" ++ ann env "any" ++ ") => { out.push(" ++ f ++ "(k)); });")
             , D.text (if byValueKey a then "return new Set(out);" else "return Object.freeze(out);") ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
        nativeOf c = "data." ++ envNative env M.! constructorId c
    converters <- forM (dataConstructors d) $ \c -> mapM (helper "tonative") (fieldTypes d targs c)
    let made c cs = "new " ++ nativeOf c ++ "(" ++ intercalate ", " [cv ++ "(x." ++ property f ++ ")" | (f, cv) <- zip (constructorFields c) cs] ++ ")"
    if fieldless d
      then pure [D.text ("return [" ++ intercalate ", " ["() => new " ++ nativeOf c ++ "()" | c <- sortOn (rankOf d) (dataConstructors d)] ++ "][x]();")]
      else if isProductType d
        then pure [D.text ("return " ++ made (firstOf (dataConstructors d)) (firstOf converters) ++ ";")]
        else pure ([ D.text ("if (x.k === " ++ show (rankOf d c) ++ ") return " ++ made c cs ++ ";") | (c, cs) <- zip (dataConstructors d) converters ] ++
                   [D.text "return lsf.unreachable();"])
  _ -> lift' (Left ("typed JavaScript: no native conversion for " ++ show ty))

fromNative :: Env -> Type -> M [D.Doc]
fromNative env ty = case ty of
  Constructor n [] | n `elem` ["Bool", "Text", "Bytes"] || n `elem` small -> pure [D.text "return n;"]
  Constructor n [] | n `elem` scalarTypes -> pure [D.text "return lsf.norm(BigInt(n));"]
  Constructor "List" [TypeArgument a] -> (\f -> [D.text ("return lsf.fromListValue(n, " ++ f ++ ");")]) <$> helper "fromnative" a
  Constructor "Maybe" [TypeArgument a] -> do
    f <- helper "fromnative" a
    pure [D.text ("return n instanceof data.Just ? new lsf.Just(" ++ f ++ "(n.value)) : null;")]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "fromnative" a
    fr <- helper "fromnative" b
    pure [D.text ("return n instanceof data.Right ? lsf.right(" ++ fr ++ "(n.value)) : lsf.left(" ++ fl ++ "(n.value));")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "fromnative" k
        fv <- helper "fromnative" v
        cmp <- comparer env k
        pure [ D.text ("let out" ++ ann env "lsf.Node | null" ++ " = null;")
             , D.text ("for (const [k, v] of (n instanceof Map ? n.entries() : n)) out = lsf.put(out, " ++ fk ++ "(k), " ++ fv ++ "(v), " ++ cmp ++ ");")
             , D.text "return out;" ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- helper "fromnative" a
        cmp <- comparer env a
        pure [ D.text ("let out" ++ ann env "lsf.Node | null" ++ " = null;")
             , D.text ("for (const item of n) out = lsf.setInsert(out, " ++ f ++ "(item), " ++ cmp ++ ");")
             , D.text "return out;" ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let targs = [t | TypeArgument t <- args]
        nativeOf c = "data." ++ envNative env M.! constructorId c
    converters <- forM (dataConstructors d) $ \c -> mapM (helper "fromnative") (fieldTypes d targs c)
    let made c cs
          | fieldless d = show (rankOf d c)
          | otherwise = "new " ++ envClasses env M.! constructorId c ++ "(" ++ intercalate ", " [cv ++ "(n." ++ binderName f ++ ")" | (f, cv) <- zip (constructorFields c) cs] ++ ")"
    if isProductType d
      then pure [D.text ("return " ++ made (firstOf (dataConstructors d)) (firstOf converters) ++ ";")]
      else pure ([ D.text ("if (n instanceof " ++ nativeOf c ++ ") return " ++ made c cs ++ ";") | (c, cs) <- zip (dataConstructors d) converters ] ++
                 [D.text ("throw new TypeError('expected " ++ dataName d ++ "');")])
  _ -> lift' (Left ("typed JavaScript: no native conversion for " ++ show ty))
