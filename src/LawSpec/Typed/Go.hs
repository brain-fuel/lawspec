-- | Typed Go for checked definitions (see LawSpec.Typed.Plan), in each
-- package's lawspec_typed.go: a Go type per typed data type, a function per
-- class of typed definitions, and, per concrete type the code needs, its
-- equality, its portable order and its conversions to and from LawSpecValue.
-- Every identifier starts lsf, apart from the package's own names. Lists,
-- KeyVal and Set are lawspec_fast.go's persistent structures; data with
-- fields is a pointer, so passing and keeping a value never copies it.
-- Errors panic, as the dynamic bodies' do. ref:DEC-typed-native-definitions
module LawSpec.Typed.Go (GoTyped(..), emitGoTyped) where

import Control.Monad (forM, forM_)
import Control.Monad.State.Strict
import Data.Char (isAlphaNum, isUpper, toLower, toUpper, ord)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S
import Numeric (showHex)
import LawSpec.Collections (collectionsUnit, collectionContainer)
import LawSpec.Core
import LawSpec.Scalar
import LawSpec.Typed.Plan
import LawSpec.GoTypeRefs (goDataKey)
import qualified LawSpec.GoData as GoData
import LawSpec.DataNames (isProduct)
import LawSpec.Time (isDurationType)
import qualified LawSpec.Code.Doc as D
import LawSpec.Digest (digestHex, digestString)

data GoTyped = GoTyped
  { -- A package's file: its typed definitions and boundary types, with the
    -- dynamic code's rendering of an operation (over dynamic arguments).
    goTypedSource :: (Expr -> [D.Doc] -> Either String D.Doc) -> String -> [Id] -> [Type] -> Either String String
  , goTypedFunction :: Id -> Maybe String
  , goTypedType :: Type -> Either String String
  , goTypedFrom :: Type -> Either String String  -- LawSpecValue -> typed, a function name
  , goTypedTo :: Type -> Either String String    -- typed -> LawSpecValue
  , goTypedValue :: Expr -> Either String String
    -- Direct conversions from and to a native type, when it has them.
  , goTypedNative :: Type -> Maybe (String, String)
  , goTypedPlan :: TypedPlan
  }

fixedBounds :: [(String, (Integer, Integer))]
fixedBounds =
  [ ("Int8", (-128, 127)), ("Int16", (-32768, 32767)), ("Int32", (-2147483648, 2147483647))
  , ("Int64", (-(2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1)), ("UInt8", (0, 255)), ("UInt16", (0, 65535))
  , ("UInt32", (0, 4294967295)) ]

goFixed :: [(String, String)]
goFixed = [("Int8", "int8"), ("Int16", "int16"), ("Int32", "int32"), ("Int64", "int64"), ("UInt8", "uint8"), ("UInt16", "uint16"), ("UInt32", "uint32"), ("UInt64", "uint64")]

-- | A bounded type whose values all fit an int64.
isLong :: Type -> Bool
isLong (Constructor n []) = n `elem` map fst fixedBounds
isLong _ = False

data Env = Env
  { envPlan :: TypedPlan
  , envNames :: M.Map String String
  , envData :: M.Map String DataDeclaration
  , envConstructors :: M.Map Id (DataDeclaration, DataConstructor)
  , envFunctions :: M.Map Int String
  , envDeclarations :: [DataDeclaration]
  , envNative :: M.Map Id String
  , envPerform :: Expr -> [D.Doc] -> Either String D.Doc
  }

-- | Fresh names, and the per-type helpers the code asks for.
data St = St { stCounter :: Int, stHelpers :: M.Map String (Int, Type), stWanted :: S.Set (String, String) }

type M = StateT St (Either String)

fresh :: String -> M String
fresh base = do
  s <- get
  put s { stCounter = stCounter s + 1 }
  pure (sanitize base ++ show (stCounter s))

sanitize :: String -> String
sanitize name = case [c | c <- map lower name, isAlphaNum c || c == '_'] of
  [] -> "v"
  cleaned@(c : _) | isAlphaNum c && not (c >= '0' && c <= '9') -> "l" ++ capitalize cleaned
  cleaned -> "lv" ++ cleaned
  where lower c = if isUpper c then toLower c else c

capitalize :: String -> String
capitalize (c : cs) = toUpper c : cs
capitalize [] = []

identifier :: String -> String
identifier name = case [c | c <- name, isAlphaNum c || c == '_'] of
  [] -> "x"
  n -> n

lift' :: Either String a -> M a
lift' = lift

-- | A helper of a kind (eq, cmp, to, from, tonative, fromnative) for a type,
-- named by the type, so every package names it alike.
helper :: String -> Type -> M String
helper kind ty = do
  let key = show ty
  modify (\st -> st { stHelpers = M.insert key (0, ty) (stHelpers st), stWanted = S.insert (kind, key) (stWanted st) })
  pure (helperName kind ty)

helperName :: String -> Type -> String
helperName kind ty = "lsf" ++ capitalize kind ++ "_" ++ take 12 (digestHex (digestString (show ty)))

emitGoTyped :: [DataDeclaration] -> [Unit] -> Either String GoTyped
emitGoTyped declarations units = do
  let plan = typedPlanPerforming scalarTypes declarations units
      datas = typedData plan
      names = dataNames datas
      functions = M.fromList [ (c, functionName c d) | (c, d) <- typedRepresentatives plan ]
  nativeNames <- GoData.goEmittedNames declarations
  let envWith perform = Env plan names (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions declarations
        (M.fromList (concat [zip (dataId d : map constructorId (dataConstructors d)) ns | (d, ns) <- nativeNames])) perform
      env = envWith (\_ _ -> Left "typed Go: an operation outside a package's file")
      handlerTypes = [ t | h <- concatMap unitHandlers units, isTypedHandler plan h
                         , ref <- handlerAbilities h, Just (_, a) <- [findAbility units ref]
                         , (_, ty) <- abilityOperations a, let (args, result) = functionType ty, t <- result : args ]
      boundary = concat [ let (args, result) = functionType (declarationType (definitionDeclaration d)) in result : args
                        | d <- M.elems (typedDefinitions plan) ] ++ handlerTypes
  dataDocs <- mapM (dataDoc env) datas
  let line = D.text
      -- A package holds the typed definitions its bodies reach, with the
      -- helpers they and its boundaries need.
      file perform package identities boundaryTypes = do
        let env' = envWith perform
            classes = S.fromList [c | i <- identities, Just c <- [definitionClass plan i]]
            members = [(c, d) | (c, d) <- typedRepresentatives plan, c `S.member` classes]
        ((functionDocs, helperDocs), _) <- flip runStateT (St 0 M.empty S.empty) $ do
          fs <- mapM (\(c, d) -> functionDoc env' c d) members
          forM_ boundaryTypes $ \t -> helper "to" t >> helper "from" t
          forM_ [t | t <- boundaryTypes, nativeDirect env' S.empty t] $ \t -> helper "tonative" t >> helper "fromnative" t
          hs <- helpers env'
          pure (fs, hs)
        pure (D.render (D.PrettyTabs 100) (line "// Generated by LawSpec. Do not edit." <> D.hardline <>
          line ("package " ++ package) <> D.hardline <> D.hardline <>
          line "import (" <> D.nest 8 (D.hardline <> line "\"math/big\"" <> D.hardline <> line "\"strings\"") <> D.hardline <> line ")" <> D.hardline <> D.hardline <>
          line "var _ = big.NewInt" <> D.hardline <> line "var _ = strings.Compare" <> D.hardline <> D.hardline <>
          D.joinWith (D.hardline <> D.hardline) (dataDocs ++ entryHelpers env' ++ orderingHelper env' ++ functionDocs ++ helperDocs)) ++ "\n")
      lookupFunction identity = do
        c <- definitionClass plan identity
        M.lookup c functions
      _ = boundary
  pure GoTyped
    { goTypedSource = file
    , goTypedFunction = lookupFunction
    , goTypedType = goType env
    , goTypedFrom = \t -> pure (helperName "from" t)
    , goTypedTo = \t -> pure (helperName "to" t)
    , goTypedValue = \e -> do
        ((statements, value), _) <- runStateT (cexpr env [] e) (St 0 M.empty S.empty)
        if null statements then pure (D.render D.Compact value) else Left "a typed start value needs statements"
    , goTypedNative = \t -> if nativeDirect env S.empty t then Just (helperName "fromnative" t, helperName "tonative" t) else Nothing
    , goTypedPlan = plan }
  where
    functionName _ d = "lsf" ++ capitalize (identifier (shortName (declarationName (definitionDeclaration d)))) ++ "_" ++ stableSuffix (declarationId (definitionDeclaration d))
    shortName name =
      let unprefixed = if "lawspec_" `isPrefixOf` name then drop 8 name else name
      in reverse (dropHash (reverse unprefixed))
    dropHash reversed = case span (`elem` ("0123456789abcdef" :: String)) reversed of
      (digits@(_ : _), '_' : rest) | length digits >= 8 -> rest
      _ -> reversed

dataNames :: [DataDeclaration] -> M.Map String String
dataNames datas = M.fromList (snd (foldl pick (S.empty, []) datas))
  where
    pick (taken, acc) d =
      let base = "lsf" ++ identifier (dataName d)
          chosen = firstOf [n | n <- base : [base ++ "_" ++ show k | k <- [2 :: Int ..]], n `S.notMember` taken]
      in (S.insert chosen taken, (idText (dataId d), chosen) : acc)

fieldless :: DataDeclaration -> Bool
fieldless d = not (null (dataConstructors d)) && all (null . constructorFields) (dataConstructors d)

isProductType :: DataDeclaration -> Bool
isProductType d = length (dataConstructors d) == 1 && not (fieldless d)

goType :: Env -> Type -> Either String String
goType env = goTypeP env []

goTypeP :: Env -> [(Id, String)] -> Type -> Either String String
goTypeP env parameters ty = case ty of
  TypeVariable v | Just p <- lookup v parameters -> pure p
  Constructor "Bool" [] -> pure "bool"
  Constructor "Unit" [] -> pure "lsfUnit"
  Constructor n [] | Just t <- lookup n goFixed -> pure t
  Constructor "Integer" [] -> pure "lsfInt"
  Constructor "Text" [] -> pure "string"
  Constructor "Bytes" [] -> pure "string"
  Constructor "List" [TypeArgument a] -> (\t -> "*lsfList[" ++ t ++ "]") <$> goTypeP env parameters a
  Constructor "Maybe" [TypeArgument a] -> (\t -> "lsfMaybe[" ++ t ++ "]") <$> goTypeP env parameters a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    l <- goTypeP env parameters a
    r <- goTypeP env parameters b
    pure ("lsfEither[" ++ l ++ ", " ++ r ++ "]")
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        kt <- goTypeP env parameters k
        vt <- goTypeP env parameters v
        pure ("*lsfMap[" ++ kt ++ ", " ++ vt ++ "]")
    | Just ("Set", [a]) <- collectionArguments ty -> (\t -> "*lsfMap[" ++ t ++ ", lsfUnit]") <$> goTypeP env parameters a
  Constructor n args | Just name <- M.lookup n (envNames env), Just d <- M.lookup n (envData env) -> do
    rendered <- mapM (\a -> case a of TypeArgument t -> goTypeP env parameters t; _ -> Left "typed Go: index argument") args
    let applied = name ++ (if null rendered then "" else "[" ++ intercalate ", " rendered ++ "]")
    pure (if isProductType d then "*" ++ applied else applied)
  _ -> Left ("no typed Go form for " ++ show ty)

parameterNames :: DataDeclaration -> [(Id, String)]
parameterNames d = zip (dataParameters d) ["T" ++ show k | k <- [0 :: Int ..]]

fieldName :: Binder -> String
fieldName b = "f" ++ capitalize (identifier (binderName b))

variantType :: Env -> DataDeclaration -> DataConstructor -> String
variantType env d c = envNames env M.! idText (dataId d) ++ "_" ++ identifier (constructorName c)

dataDoc :: Env -> DataDeclaration -> Either String D.Doc
dataDoc env d = do
  let name = envNames env M.! idText (dataId d)
      parameters = parameterNames d
      generics = if null parameters then "" else "[" ++ intercalate ", " [p ++ " any" | (_, p) <- parameters] ++ "]"
      applied = if null parameters then "" else "[" ++ intercalate ", " (map snd parameters) ++ "]"
      ranks = constructorRanks d
      rank c = fromMaybe 0 (lookup (constructorId c) ranks)
      variants = dataConstructors d
      line = D.text
      header = line ("// " ++ name ++ " is " ++ dataName d ++ " (" ++ idText (dataId d) ++ ").")
  fieldTypes <- forM variants $ \c -> forM (constructorFields c) $ \f -> goTypeP env parameters (binderType f)
  let structOf ts c = D.block 8 (D.joinWith D.hardline [line (fieldName f ++ " " ++ t) | (f, t) <- zip (constructorFields c) ts])
  pure $ header <> D.hardline <> if fieldless d
    then line ("type " ++ name ++ " uint8") <> D.hardline <> D.hardline <>
      line "const " <> D.text "(" <> D.nest 8 (D.hardline <> D.joinWith D.hardline
        [line (name ++ "_" ++ identifier (constructorName c) ++ (if k == 0 then " " ++ name ++ " = iota" else "")) | (k, c) <- zip [0 :: Int ..] variants]) <>
        D.hardline <> line ")" <> D.hardline <> D.hardline <>
      line ("var " ++ name ++ "Ranks = [...]int{" ++ intercalate ", " (map (show . rank) variants) ++ "}")
    else if isProductType d
    then line ("type " ++ name ++ generics ++ " struct ") <> structOf (firstOf fieldTypes) (firstOf variants)
    else line ("type " ++ name ++ generics ++ " interface ") <> D.block 8 (line ("lsfTag" ++ name ++ "() int")) <> D.hardline <> D.hardline <>
      D.joinWith (D.hardline <> D.hardline)
        [ line ("type " ++ variantType env d c ++ generics ++ " struct ") <> (if null ts then line "{}" else structOf ts c) <> D.hardline <> D.hardline <>
          line ("func (*" ++ variantType env d c ++ applied ++ ") lsfTag" ++ name ++ "() int { return " ++ show k ++ " }")
        | (k, (c, ts)) <- zip [0 :: Int ..] (zip variants fieldTypes) ] <> D.hardline <> D.hardline <>
      line ("var " ++ name ++ "Ranks = [...]int{" ++ intercalate ", " (map (show . rank) variants) ++ "}")

entryHelpers :: Env -> [D.Doc]
entryHelpers env = case M.lookup (collectionsUnit ++ "::type::Entry") (envNames env) of
  Nothing -> []
  Just name ->
    [ D.text ("func lsfEntryOf[K any, V any](k K, v V) *" ++ name ++ "[K, V] { return &" ++ name ++ "[K, V]{k, v} }")
    , D.text ("func lsfKeyValOf[K any, V any](es *lsfList[*" ++ name ++ "[K, V]], cmp func(K, K) int) *lsfMap[K, V] ") <> D.block 8
        (D.text "var m *lsfMap[K, V]" <> D.hardline <>
         D.text "for c := es; c != nil; c = c.tail {" <> D.nest 8 (D.hardline <> D.text "m = lsfPut(m, c.head.fKey, c.head.fValue, cmp)") <> D.hardline <> D.text "}" <> D.hardline <>
         D.text "return m") ]

orderingHelper :: Env -> [D.Doc]
orderingHelper env = case M.lookup (collectionsUnit ++ "::type::Ordering") (envNames env) of
  Nothing -> []
  Just name -> [D.text ("func lsfOrderingOf(c int) " ++ name ++ " ") <> D.block 8 (D.joinWith D.hardline
    [ D.text ("if c < 0 { return " ++ name ++ "_Less }"), D.text ("if c == 0 { return " ++ name ++ "_Equal }"), D.text ("return " ++ name ++ "_Greater") ])]

-- Functions.

data Target = Return | Assign String

type Scope = [(Id, String)]

functionDoc :: Env -> Int -> Definition -> M D.Doc
functionDoc env c d = do
  let declaration = definitionDeclaration d
      (_, result) = functionType (declarationType declaration)
      name = envFunctions env M.! c
  params <- forM (definitionArguments d) $ \b -> do
    local <- fresh (binderName b)
    ty <- lift' (goType env (binderType b))
    pure (binderId b, local, ty)
  resultType <- lift' (goType env result)
  let contextual = isContextual (envPlan env) (declarationId declaration)
      scope = [(i, l) | (i, l, _) <- params]
      looping = hasTailSelf env c (definitionBody d)
      selfCall = if looping then Just (c, map (\(_, l, _) -> l) params) else Nothing
  body <- case M.lookup (declarationId declaration) (typedIntrinsics (envPlan env)) of
    Just intrinsic -> do
      x <- intrinsicCall env intrinsic [(D.text l, binderType b) | ((_, l, _), b) <- zip params (definitionArguments d)]
      pure [D.text "return " <> x]
    Nothing -> cstmt env selfCall scope Return (definitionBody d)
  pure (D.text ("// " ++ name ++ " is " ++ idText (declarationId declaration) ++ ".") <> D.hardline <>
    D.text ("func " ++ name ++ "(" ++ intercalate ", " (["symbols map[string]*LawSpecSymbol" | contextual] ++ [l ++ " " ++ t | (_, l, t) <- params]) ++ ") " ++ resultType ++ " ") <> D.block 8
      (if looping then D.text "for " <> D.block 8 (D.joinWith D.hardline body) else D.joinWith D.hardline body))

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

block :: [D.Doc] -> D.Doc
block ss = D.block 8 (D.joinWith D.hardline ss)

cstmt :: Env -> Maybe (Int, [String]) -> Scope -> Target -> Expr -> M [D.Doc]
cstmt env selfCall scope target e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    if binderId binder `elem` freeBinders body
      then do
        local <- fresh (binderName binder)
        rest <- cstmt env selfCall ((binderId binder, local) : scope) target body
        pure (s ++ [D.text (local ++ " := ") <> x] ++ rest)
      else do
        rest <- cstmt env selfCall scope target body
        pure (s ++ [D.text "_ = " <> x] ++ rest)
  If c a b -> do
    (s, x) <- cexpr env scope c
    yes <- cstmt env selfCall scope target a
    no <- cstmt env selfCall scope target b
    pure (s ++ [D.text "if " <> x <> D.text " " <> block yes <> D.text " else " <> block no])
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
          pure (s ++ [D.text (t ++ " := ") <> x], D.text (p ++ " = " ++ t))
        pure (concatMap fst evaluated ++ map snd evaluated ++ [D.text "continue"])
  Helper Unreachable _ -> pure [D.text "panic(\"unreachable branch reached\")"]
  -- raise e delivers nothing: it panics.
  Perform (Operation ref "raise") [_] | isFail ref -> do
    (s, _) <- cexpr env scope e
    pure s
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
    name <- lift' (maybe (Left ("typed Go: unbound local " ++ idText i)) Right (lookup i scope))
    pure ([], D.text name)
  Construct tag args -> do
    parts <- mapM (cexpr env scope) args
    x <- construct env (expressionType e) tag (map snd parts) args
    pure (concatMap fst parts, x)
  ExternalCall i args
    | Just intrinsic <- M.lookup i (typedIntrinsics (envPlan env)) -> do
        parts <- mapM (cexpr env scope) args
        x <- intrinsicCall env intrinsic (zip (map snd parts) (map expressionType args))
        pure (concatMap fst parts, x)
    | otherwise -> do
        c <- lift' (maybe (Left ("typed Go: untyped callee " ++ idText i)) Right (definitionClass (envPlan env) i))
        parts <- mapM (cexpr env scope) args
        let context = [D.text "symbols" | isContextual (envPlan env) i]
        pure (concatMap fst parts, D.text (envFunctions env M.! c ++ "(") <> D.joinWith (D.text ", ") (context ++ map snd parts) <> D.text ")")
  ShortCircuit op a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    if null sb
      then pure (sa, D.text "(" <> xa <> D.text (if op == And then " && " else " || ") <> xb <> D.text ")")
      else do
        t <- fresh "logic"
        pure (sa ++ [D.text ("var " ++ t ++ " bool"),
          D.text "if " <> (if op == And then xa else D.text "!" <> paren xa) <> D.text " " <>
            block (sb ++ [D.text (t ++ " = ") <> xb]) <>
            D.text (" else { " ++ t ++ " = " ++ (if op == And then "false" else "true") ++ " }")], D.text t)
  Unary Not a -> do
    (s, x) <- cexpr env scope a
    pure (s, D.text "!" <> paren x)
  Unary Negate _ -> intExpr env scope e
  Binary {} -> binary env scope e
  Convert _ target value
    | target == expressionType value -> cexpr env scope value
    | otherwise -> convert env scope target value
  Helper Compare [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    cmp <- helper "cmp" (expressionType a)
    pure (sa ++ sb, D.text ("lsfOrderingOf(" ++ cmp ++ "(") <> xa <> D.text ", " <> xb <> D.text "))")
  Helper Length [_] -> intExpr env scope e
  Helper Unreachable _ -> do
    ty <- lift' (goType env (expressionType e))
    pure ([D.text "panic(\"unreachable branch reached\")"], D.text ("*new(" ++ ty ++ ")"))
  Helper Checked _ -> pure ([], D.text "true")
  Helper StartsWith [a, b] -> twoText "strings.HasPrefix" a b
  Helper EndsWith [a, b] -> twoText "strings.HasSuffix" a b
  Helper TextContains [a, b] -> twoText "strings.Contains" a b
  Helper RegexMatches [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    pure (sa ++ sb, D.text "lsfRegexMatches(" <> xa <> D.text ", " <> xb <> D.text ")")
  AllElements value binder predicate -> do
    (sx, xs) <- cexpr env scope value
    t <- fresh "all"
    cell <- fresh "cell"
    item <- fresh (binderName binder)
    (sp, p) <- cexpr env ((binderId binder, item) : scope) predicate
    pure (sx ++ [ D.text (t ++ " := true")
                , D.text ("for " ++ cell ++ " := ") <> xs <> D.text ("; " ++ cell ++ " != nil; " ++ cell ++ " = " ++ cell ++ ".tail ") <> block
                    ([D.text (item ++ " := " ++ cell ++ ".head")] ++ sp ++
                     [D.text "if !" <> paren p <> D.text (" { " ++ t ++ " = false; break }")]) ], D.text t)
  -- raise e: a failure of the Fail ability, as the dynamic raise makes it.
  Perform (Operation ref "raise") [x] | isFail ref -> do
    (s, v) <- cexpr env scope x
    to <- helper "to" (expressionType x)
    ty <- lift' (goType env (expressionType e))
    pure (s ++ [D.text ("panic(&LawSpecFailure{Ability: " ++ goQuote (abilityKey ref) ++ ", Value: " ++ to ++ "(") <> v <> D.text ")})"], D.text ("*new(" ++ ty ++ ")"))
  -- An operation of another ability: the dynamic code's call of its
  -- handler in the context, over the arguments' dynamic values.
  Perform _ args -> do
    parts <- mapM (cexpr env scope) args
    tos <- mapM (helper "to" . expressionType) args
    from <- helper "from" (expressionType e)
    viaDynamic <- lift' (envPerform env e [D.text (to ++ "(") <> x <> D.text ")" | (to, x) <- zip tos (map snd parts)])
    t <- fresh "performed"
    pure (concatMap fst parts ++ [D.text (t ++ " := " ++ from ++ "(") <> viaDynamic <> D.text ")"], D.text t)
  -- attempt e: Right of e's value, or Left of the failure it raised.
  Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, TypeArgument result] <- expressionType e -> do
    t <- fresh "attempted"
    ty <- lift' (goType env (expressionType e))
    lt <- lift' (goType env failure)
    rt <- lift' (goType env result)
    from <- helper "from" failure
    (s, v) <- cexpr env scope body
    let witness = "[" ++ lt ++ ", " ++ rt ++ "]"
    pure ([ D.text ("var " ++ t ++ " " ++ ty)
          , D.text "func() " <> block
              ([ D.text "defer func() " <> block
                   [ D.text "if problem := recover(); problem != nil " <> block
                       [ D.text ("if failure, ok := problem.(*LawSpecFailure); ok && failure.Ability == " ++ goQuote (abilityKey ref) ++ " ") <> block
                           [D.text (t ++ " = lsfLeft" ++ witness ++ "(" ++ from ++ "(failure.Value))"), D.text "return"]
                       , D.text "panic(problem)" ] ] <> D.text "()" ] ++
               s ++ [D.text (t ++ " = lsfRight" ++ witness ++ "(") <> v <> D.text ")"]) <> D.text "()" ], D.text t)
  Helper Append [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    pure (sa ++ sb, case expressionType a of
      Constructor n [] | n `elem` ["Text", "Bytes"] -> paren (xa <> D.text " + " <> xb)
      _ -> D.text "lsfAppend(" <> xa <> D.text ", " <> xb <> D.text ")")
  Helper Slice [x, from, to] -> do
    (sx, v) <- cexpr env scope x
    (si, i) <- index from
    (sj, j) <- index to
    let f = case expressionType x of
          Constructor "Text" [] -> "lsfSliceText"
          Constructor "Bytes" [] -> "lsfSliceBytes"
          _ -> "lsfSliceList"
    pure (sx ++ si ++ sj, D.text (f ++ "(") <> v <> D.text ", " <> i <> D.text ", " <> j <> D.text ")")
  Helper At [x, k] -> do
    (sx, v) <- cexpr env scope x
    (si, i) <- index k
    let f = if expressionType x == Constructor "Bytes" [] then "lsfAtBytes" else "lsfAtList"
    pure (sx ++ si, D.text (f ++ "(") <> v <> D.text ", " <> i <> D.text ")")
  Helper Range [lo, hi] -> do
    (sa, a) <- cexpr env scope lo
    (sb, b) <- cexpr env scope hi
    pure (sa ++ sb, D.text (if expressionType lo == Constructor "Integer" [] then "lsfRangeInt(" else "lsfRange(") <> a <> D.text ", " <> b <> D.text ")")
  Helper Octets [b] -> one "lsfOctets" b
  Helper BytesOf [xs] -> one "lsfBytesOf" xs
  -- A Go string is its UTF-8 octets already.
  Helper Utf8 [t] -> cexpr env scope t
  Helper TextOf [n] -> case expressionType n of
    Constructor "Integer" [] -> one "lsfTextOfInt" n
    Constructor "UInt64" [] -> one "lsfTextOfUint" n
    _ -> do
      (s, x) <- cexpr env scope n
      pure (s, D.text "lsfTextOfLong(int64(" <> x <> D.text "))")
  Helper Join [sep, parts] -> twoText "lsfJoin" sep parts
  _ -> lift' (Left ("typed Go: unsupported expression " ++ take 80 (show (expressionNode e))))
  where
    one f a = do
      (s, x) <- cexpr env scope a
      pure (s, D.text (f ++ "(") <> x <> D.text ")")
    -- An Integer index, as an int64 (clamped).
    index a = do
      l <- longExpr env scope a
      case l of
        Just r -> pure r
        Nothing -> do
          (s, x) <- intExpr env scope a
          pure (s, D.text "lsfIndex(" <> x <> D.text ")")
    viaStatements = do
      t <- fresh "value"
      ty <- lift' (goType env (expressionType e))
      s <- cstmt env Nothing scope (Assign t) e
      pure (D.text ("var " ++ t ++ " " ++ ty) : s, D.text t)
    twoText f a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, D.text (f ++ "(") <> xa <> D.text ", " <> xb <> D.text ")")

paren :: D.Doc -> D.Doc
paren x = D.text "(" <> x <> D.text ")"

goQuote :: String -> String
goQuote s = "\"" ++ concatMap escape s ++ "\""
  where
    escape c
      | c == '"' = "\\\""
      | c == '\\' = "\\\\"
      | ord c < 32 || ord c == 127 = "\\x" ++ pad 2 (showHex (ord c) "")
      | ord c > 127 && ord c < 0x10000 = "\\u" ++ pad 4 (showHex (ord c) "")
      | ord c >= 0x10000 = "\\U" ++ pad 8 (showHex (ord c) "")
      | otherwise = [c]
    pad n h = replicate (n - length h) '0' ++ h

constant :: Scalar -> Either String D.Doc
constant s = case s of
  SBool b -> pure (D.text (if b then "true" else "false"))
  SAbsent "Unit" -> pure (D.text "lsfUnit{}")
  SInteger "Integer" n
    | n >= -(2 ^ (63 :: Int)) && n < 2 ^ (63 :: Int) -> pure (D.text ("lsfSmall(" ++ show n ++ ")"))
    | otherwise -> pure (D.text ("lsfFromBig(lsInt(" ++ goQuote (show n) ++ "))"))
  SInteger t n | Just g <- lookup t goFixed -> pure (D.text (if n == -(2 ^ (63 :: Int)) then g ++ "(-1 << 63)" else g ++ "(" ++ show n ++ ")"))
  SSequence "Text" units -> pure (D.text (goQuote (map toEnum units)))
  SSequence "Bytes" units -> pure (D.text ("string([]byte{" ++ intercalate ", " (map show units) ++ "})"))
  _ -> Left ("typed Go: unsupported constant " ++ show s)

-- | An integer expression whose value is an int64 exactly.
longExpr :: Env -> Scope -> Expr -> M (Maybe ([D.Doc], D.Doc))
longExpr env scope e = case (expressionNode e, expressionType e) of
  (Constant (SInteger _ n), _) | n >= -(2 ^ (62 :: Int)) && n < 2 ^ (62 :: Int) -> pure (Just ([], D.text ("int64(" ++ show n ++ ")")))
  (Convert _ (Constructor "Integer" []) value, _) | isLong (expressionType value) -> Just <$> asLong value
  (Helper Length [x], _) -> do
    (s, v) <- cexpr env scope x
    pure (Just (s, lengthOf (expressionType x) v))
  (_, ty) | isLong ty -> Just <$> asLong e
  _ -> pure Nothing
  where
    asLong x = do
      (s, v) <- cexpr env scope x
      pure (s, if expressionType x == Constructor "Int64" [] then v else D.text "int64(" <> v <> D.text ")")

lengthOf :: Type -> D.Doc -> D.Doc
lengthOf ty v = case ty of
  Constructor "Text" [] -> D.text "lsfTextLength(" <> v <> D.text ")"
  Constructor "Bytes" [] -> D.text "int64(len(" <> v <> D.text "))"
  _ -> D.text "int64(" <> v <> D.text ".length())"

-- | An expression of type Integer, as an lsfInt.
intExpr :: Env -> Scope -> Expr -> M ([D.Doc], D.Doc)
intExpr env scope e = do
  l <- longExpr env scope e
  case l of
    Just (s, x) -> pure (s, D.text "lsfSmall(" <> x <> D.text ")")
    Nothing -> case (expressionNode e, expressionType e) of
      (_, Constructor "UInt64" []) -> do
        (s, x) <- cexpr env scope e
        pure (s, D.text "lsfFromUint(" <> x <> D.text ")")
      (Convert _ (Constructor "Integer" []) value, _) -> intExpr env scope value
      (Unary Negate a, _) -> do
        (s, x) <- intExpr env scope a
        pure (s, x <> D.text ".Neg()")
      (Binary op _ a b, _) | not (isComparison op) -> do
        (sa, xa) <- intExpr env scope a
        (sb, xb) <- intExpr env scope b
        let m = case op of Add -> "Add"; Subtract -> "Sub"; Multiply -> "Mul"; Quotient -> "Quot"; Remainder -> "Rem"; _ -> "Pow"
        pure (sa ++ sb, xa <> D.text ("." ++ m ++ "(") <> xb <> D.text ")")
      _ -> cexpr env scope e

binary :: Env -> Scope -> Expr -> M ([D.Doc], D.Doc)
binary env scope e = case expressionNode e of
  Binary op (Structural t) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    test <- if simpleEquality t
      then pure (paren xa <> D.text " == " <> paren xb)
      else do
        eq <- helper "eq" t
        pure (D.text (eq ++ "(") <> xa <> D.text ", " <> xb <> D.text ")")
    pure (sa ++ sb, if op == Equal then paren test else D.text "!" <> paren test)
  Binary op (Numeric _) a b | isComparison op -> do
    let symbol = case op of Equal -> " == "; NotEqual -> " != "; Less -> " < "; LessEqual -> " <= "; Greater -> " > "; _ -> " >= "
    if expressionType a == expressionType b && maybe False (const True) (fixedName (expressionType a))
      then do
        (sa, xa) <- cexpr env scope a
        (sb, xb) <- cexpr env scope b
        pure (sa ++ sb, paren (xa <> D.text symbol <> xb))
      else do
        la <- longExpr env scope a
        lb <- longExpr env scope b
        case (la, lb) of
          (Just (sa, xa), Just (sb, xb)) -> pure (sa ++ sb, paren (xa <> D.text symbol <> xb))
          _ -> do
            (sa, xa) <- intExpr env scope a
            (sb, xb) <- intExpr env scope b
            pure (sa ++ sb, paren (D.text "lsfCmpInt(" <> xa <> D.text ", " <> xb <> D.text ")" <> D.text symbol <> D.text "0"))
  _ -> intExpr env scope e
  where
    fixedName (Constructor n []) = lookup n goFixed
    fixedName _ = Nothing

-- | Types whose == is LawSpec's equality.
simpleEquality :: Type -> Bool
simpleEquality ty = case ty of
  Constructor n [] -> n `elem` ["Bool", "Unit", "Text", "Bytes"] || n `elem` map fst goFixed
  _ -> False

convert :: Env -> Scope -> Type -> Expr -> M ([D.Doc], D.Doc)
convert env scope target value = case (target, expressionType value) of
  (Constructor "Integer" [], _) -> intExpr env scope value
  (Constructor "UInt64" [], source) -> do
    if source `elem` [Constructor n [] | n <- ["UInt8", "UInt16", "UInt32"]]
      then do
        (s, x) <- cexpr env scope value
        pure (s, D.text "uint64(" <> x <> D.text ")")
      else do
        (s, x) <- intExpr env scope value
        pure (s, D.text "lsfNarrowUint64(" <> x <> D.text ")")
  (Constructor t [], source) | Just (lo, hi) <- lookup t fixedBounds, Just g <- lookup t goFixed -> do
    let bounds = showLong lo ++ ", " ++ showLong hi ++ ", " ++ show t
        inside = case source of
          Constructor s [] | Just (slo, shi) <- lookup s fixedBounds -> slo >= lo && shi <= hi
          _ -> False
    if inside
      then do
        (s, x) <- cexpr env scope value
        pure (s, D.text (g ++ "(") <> x <> D.text ")")
      else do
        fused <- case expressionNode value of
          Binary op (Numeric (Constructor "Integer" [])) a b | op `elem` [Add, Subtract, Multiply] -> do
            la <- longExpr env scope a
            lb <- longExpr env scope b
            pure $ case (la, lb) of
              (Just (sa, xa), Just (sb, xb)) ->
                let f = case op of Add -> "lsfAdd"; Subtract -> "lsfSub"; _ -> "lsfMul"
                in Just (sa ++ sb, D.text (g ++ "(" ++ f ++ "(") <> xa <> D.text ", " <> xb <> D.text (", " ++ bounds ++ "))"))
              _ -> Nothing
          _ -> pure Nothing
        case fused of
          Just r -> pure r
          Nothing -> do
            l <- longExpr env scope value
            case l of
              Just (s, x) -> pure (s, D.text (g ++ "(lsfNarrow(") <> x <> D.text (", " ++ bounds ++ "))"))
              Nothing -> do
                (s, x) <- intExpr env scope value
                pure (s, D.text (g ++ "(lsfNarrowInt(") <> x <> D.text (", " ++ bounds ++ "))"))
  _ -> lift' (Left ("typed Go: unsupported conversion to " ++ show target))
  where
    showLong n = if n == -(2 ^ (63 :: Int)) then "-1 << 63" else show n

construct :: Env -> Type -> Id -> [D.Doc] -> [Expr] -> M D.Doc
construct env ty tag values _ = do
  let argumentsOf = case ty of
        Constructor _ args -> [t | TypeArgument t <- args]
        _ -> []
  witnesses <- lift' (mapM (goType env) argumentsOf)
  let witness = "[" ++ intercalate ", " witnesses ++ "]"
      commaSep = D.joinWith (D.text ", ")
  case (idText tag, values) of
    ("List::Nil", []) -> pure (D.text ("(*lsfList" ++ witness ++ ")(nil)"))
    ("List::Cons", [h, t]) -> pure (D.text ("lsfCons" ++ witness ++ "(") <> h <> D.text ", " <> t <> D.text ")")
    ("Maybe::Nothing", []) -> pure (D.text ("lsfNothing" ++ witness ++ "()"))
    ("Maybe::Just", [x]) -> pure (D.text ("lsfJust" ++ witness ++ "(") <> x <> D.text ")")
    ("Either::Left", [x]) -> pure (D.text ("lsfLeft" ++ witness ++ "(") <> x <> D.text ")")
    ("Either::Right", [x]) -> pure (D.text ("lsfRight" ++ witness ++ "(") <> x <> D.text ")")
    (_, [items]) | Just ("KeyVal", [k, _]) <- collectionArguments ty -> do
      cmp <- helper "cmp" k
      pure (D.text "lsfKeyValOf(" <> items <> D.text (", " ++ cmp ++ ")"))
    (_, [items]) | Just ("Set", [a]) <- collectionArguments ty -> do
      cmp <- helper "cmp" a
      pure (D.text "lsfSetOf(" <> items <> D.text (", " ++ cmp ++ ")"))
    _ -> case M.lookup tag (envConstructors env) of
      Just (d, c) -> do
        let name = envNames env M.! idText (dataId d)
            generic = if null witnesses then "" else witness
        pure $ if fieldless d then D.text (name ++ "_" ++ identifier (constructorName c))
          else if isProductType d then D.text ("&" ++ name ++ generic ++ "{") <> commaSep values <> D.text "}"
          else D.text ("&" ++ variantType env d c ++ generic ++ "{") <> commaSep values <> D.text "}"
      Nothing -> lift' (Left ("typed Go: unknown constructor " ++ idText tag))

intrinsicCall :: Env -> Intrinsic -> [(D.Doc, Type)] -> M D.Doc
intrinsicCall env intrinsic args = case (intrinsic, args) of
  (KeyValOf, [(es, Constructor "List" [TypeArgument (Constructor _ [TypeArgument k, _])])]) -> do
    cmp <- helper "cmp" k
    pure (D.text "lsfKeyValOf(" <> es <> D.text (", " ++ cmp ++ ")"))
  (KeyValLookup, [(k, kt), (m, _)]) -> withCmp kt (\cmp -> D.text "lsfLookup(" <> m <> D.text ", " <> k <> D.text (", " ++ cmp ++ ")"))
  (KeyValPut, [(k, kt), (v, _), (m, _)]) -> withCmp kt (\cmp -> D.text "lsfPut(" <> m <> D.text ", " <> k <> D.text ", " <> v <> D.text (", " ++ cmp ++ ")"))
  (KeyValDelete, [(k, kt), (m, _)]) -> withCmp kt (\cmp -> D.text "lsfDelete(" <> m <> D.text ", " <> k <> D.text (", " ++ cmp ++ ")"))
  (KeyValKeys, [(m, mt)]) -> mapTypes mt >>= \(kt, vt) -> pure (D.text "lsfToList(" <> m <> D.text (", func(k " ++ kt ++ ", _ " ++ vt ++ ") " ++ kt ++ " { return k })"))
  (KeyValValues, [(m, mt)]) -> mapTypes mt >>= \(kt, vt) -> pure (D.text "lsfToList(" <> m <> D.text (", func(_ " ++ kt ++ ", v " ++ vt ++ ") " ++ vt ++ " { return v })"))
  (KeyValEntries, [(m, mt)]) -> mapTypes mt >>= \(kt, vt) -> pure (D.text "lsfToList(" <> m <> D.text (", lsfEntryOf[" ++ kt ++ ", " ++ vt ++ "])"))
  (SetOf, [(xs, Constructor "List" [TypeArgument a])]) -> withCmp a (\cmp -> D.text "lsfSetOf(" <> xs <> D.text (", " ++ cmp ++ ")"))
  (SetMember, [(x, xt), (s, _)]) -> withCmp xt (\cmp -> D.text "lsfMember(" <> s <> D.text ", " <> x <> D.text (", " ++ cmp ++ ")"))
  (SetInsert, [(x, xt), (s, _)]) -> withCmp xt (\cmp -> D.text "lsfSetInsert(" <> s <> D.text ", " <> x <> D.text (", " ++ cmp ++ ")"))
  (SetRemove, [(x, xt), (s, _)]) -> withCmp xt (\cmp -> D.text "lsfDelete(" <> s <> D.text ", " <> x <> D.text (", " ++ cmp ++ ")"))
  (SetUnion, [(s, st), (t, _)]) -> setOp "lsfSetUnion" s st t
  (SetIntersection, [(s, st), (t, _)]) -> setOp "lsfSetIntersection" s st t
  (SetDifference, [(s, st), (t, _)]) -> setOp "lsfSetDifference" s st t
  _ -> lift' (Left ("typed Go: bad intrinsic " ++ show intrinsic))
  where
    withCmp t f = (\cmp -> f cmp) <$> helper "cmp" t
    setOp f s st t = case collectionArguments st of
      Just (_, [a]) -> withCmp a (\cmp -> D.text (f ++ "(") <> s <> D.text ", " <> t <> D.text (", " ++ cmp ++ ")"))
      _ -> lift' (Left "typed Go: set operation on a non-set")
    mapTypes mt = case collectionArguments mt of
      Just ("KeyVal", [k, v]) -> do
        kt <- lift' (goType env k)
        vt <- lift' (goType env v)
        pure (kt, vt)
      _ -> lift' (Left "typed Go: not a map")

matchStatements :: Env -> Maybe (Int, [String]) -> Scope -> Target -> Expr -> [MatchCase] -> M [D.Doc]
matchStatements env selfCall scope target value cases = do
  let ty = expressionType value
      used c b = binderId b `elem` freeBinders (caseBody c)
      bindOne c b access = if used c b
        then do
          n <- fresh (binderName b)
          pure (Just (binderId b, n), [D.text (n ++ " := " ++ access)])
        else pure (Nothing, [])
      arm c accesses = do
        bound <- mapM (\(b, a) -> bindOne c b a) (zip (caseBinders c) accesses)
        body <- cstmt env selfCall ([x | (Just x, _) <- bound] ++ scope) target (caseBody c)
        pure (concatMap snd bound ++ body)
  (prelude, subject) <- case expressionNode value of
    Local i | Just name <- lookup i scope -> pure ([], name)
    _ -> do
      (s, x) <- cexpr env scope value
      t <- fresh "matched"
      pure (s ++ [D.text (t ++ " := ") <> x], t)
  let caseOf tag = [c | c <- cases, idText (caseConstructor c) == tag]
      productArm c accesses = do
        body <- arm c accesses
        -- Even an irrefutable match that discards every field evaluates its
        -- subject. Keep that use after unused field bindings are omitted.
        pure (prelude ++ [D.text ("_ = " ++ subject) | not (any (used c) (caseBinders c))] ++ body)
      two yesTag noTag condition yesAccess noAccess = do
        yes <- maybe (pure [D.text "panic(\"unreachable branch reached\")"]) (\c -> arm c yesAccess) (headMaybe (caseOf yesTag))
        no <- maybe (pure [D.text "panic(\"unreachable branch reached\")"]) (\c -> arm c noAccess) (headMaybe (caseOf noTag))
        pure (prelude ++ [D.text ("if " ++ condition ++ " ") <> block yes <> D.text " else " <> block no])
  case ty of
    Constructor "Maybe" _ -> two "Maybe::Just" "Maybe::Nothing" (subject ++ ".ok") [subject ++ ".v"] []
    Constructor "Either" _ -> two "Either::Left" "Either::Right" ("!" ++ subject ++ ".right") [subject ++ ".l"] [subject ++ ".r"]
    Constructor "List" _ -> two "List::Nil" "List::Cons" (subject ++ " == nil") [] [subject ++ ".head", subject ++ ".tail"]
    _ | Just (kind, args) <- collectionArguments ty, [c] <- cases -> do
          access <- if kind == "KeyVal"
            then case args of
              [k, v] -> do
                kt <- lift' (goType env k)
                vt <- lift' (goType env v)
                pure ("lsfToList(" ++ subject ++ ", lsfEntryOf[" ++ kt ++ ", " ++ vt ++ "])")
              _ -> lift' (Left "typed Go: KeyVal arity")
            else pure ("lsfSetItems(" ++ subject ++ ")")
          productArm c [access]
    Constructor n args | Just d <- M.lookup n (envData env) -> do
      let name = envNames env M.! n
      witnesses <- lift' (mapM (goType env) [t | TypeArgument t <- args])
      let generic = if null witnesses then "" else "[" ++ intercalate ", " witnesses ++ "]"
          conOf c = snd (envConstructors env M.! caseConstructor c)
      if fieldless d
        then do
          arms <- forM cases $ \c -> do
            body <- arm c []
            pure (D.text ("case " ++ name ++ "_" ++ identifier (constructorName (conOf c)) ++ ":") <> D.nest 8 (D.hardline <> D.joinWith D.hardline body))
          pure (prelude ++ [D.text ("switch " ++ subject ++ " ") <> D.block 8 (D.joinWith D.hardline (arms ++ [D.text "default:" <> D.nest 8 (D.hardline <> D.text "panic(\"unreachable branch reached\")")]))])
        else if isProductType d
        then case cases of
          [c] -> productArm c [subject ++ "." ++ fieldName f | f <- constructorFields (conOf c)]
          _ -> lift' (Left "typed Go: product match")
        else do
          m <- fresh "variant"
          arms <- forM cases $ \c -> do
            let con = conOf c
            body <- arm c [m ++ "." ++ fieldName f | f <- constructorFields con]
            pure (any (used c) (caseBinders c), D.text ("case *" ++ variantType env d con ++ generic ++ ":") <> D.nest 8 (D.hardline <> D.joinWith D.hardline body))
          let binding = any fst arms
              header = if binding then "switch " ++ m ++ " := " ++ subject ++ ".(type) " else "switch " ++ subject ++ ".(type) "
          pure (prelude ++ [D.text header <> D.block 8 (D.joinWith D.hardline (map snd arms ++ [D.text "default:" <> D.nest 8 (D.hardline <> D.text "panic(\"unreachable branch reached\")")]))])
    _ -> lift' (Left ("typed Go: cannot match on " ++ show ty))
  where
    headMaybe xs = case xs of
      x : _ -> Just x
      [] -> Nothing

-- | The helpers asked for, and any they ask for in turn.
helpers :: Env -> M [D.Doc]
helpers env = go S.empty
  where
    go done = do
      st <- get
      let pending = [w | w <- S.toList (stWanted st), w `S.notMember` done]
      if null pending then pure [] else do
        docs <- forM pending $ \(kind, key) -> do
          let (index, ty) = stHelpers st M.! key
          helperDoc env kind index ty
        rest <- go (S.union done (S.fromList pending))
        pure (docs ++ rest)

helperDoc :: Env -> String -> Int -> Type -> M D.Doc
helperDoc env kind _ ty = do
  t <- lift' (goType env ty)
  let name = helperName kind ty
      line = D.text
      fn signature body = line ("func " ++ name ++ signature ++ " ") <> D.block 8 (D.joinWith D.hardline body)
      key = goDataKey ty
  case kind of
    "eq" -> fn ("(a, b " ++ t ++ ") bool") <$> equality env ty
    "cmp" -> fn ("(a, b " ++ t ++ ") int") <$> ordering env ty
    "to" -> fn ("(x " ++ t ++ ") LawSpecValue") <$> toValue env key ty
    "tonative" -> do
      n <- lift' (GoData.goDataType (envDeclarations env) ty)
      fn ("(x " ++ t ++ ") " ++ n) <$> toNative env ty
    "fromnative" -> do
      n <- lift' (GoData.goDataType (envDeclarations env) ty)
      fn ("(n " ++ n ++ ") " ++ t) <$> fromNative env ty
    _ -> fn ("(v LawSpecValue) " ++ t) <$> fromValue env ty

equality :: Env -> Type -> M [D.Doc]
equality env ty = case ty of
  _ | simpleEquality ty -> pure [D.text "return a == b"]
  Constructor "Integer" [] -> pure [D.text "return lsfCmpInt(a, b) == 0"]
  Constructor "List" [TypeArgument a] -> (\e -> [D.text ("return lsfEqList(a, b, " ++ e ++ ")")]) <$> helper "eq" a
  Constructor "Maybe" [TypeArgument a] -> (\e -> [D.text ("return a.ok == b.ok && (!a.ok || " ++ e ++ "(a.v, b.v))")]) <$> helper "eq" a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    el <- helper "eq" a
    er <- helper "eq" b
    pure [D.text ("return a.right == b.right && ((!a.right && " ++ el ++ "(a.l, b.l)) || (a.right && " ++ er ++ "(a.r, b.r)))")]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ek <- helper "eq" k
        ev <- helper "eq" v
        pure [D.text ("return lsfEqMap(a, b, " ++ ek ++ ", " ++ ev ++ ")")]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        ek <- helper "eq" a
        pure [D.text ("return lsfEqMap(a, b, " ++ ek ++ ", lsfEqUnit)")]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
    if fieldless d then pure [D.text "return a == b"] else do
      witnesses <- lift' (mapM (goType env) (map snd table))
      let generic = if null witnesses then "" else "[" ++ intercalate ", " witnesses ++ "]"
      checks <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> do
        let ft = substitute table (binderType f)
        if simpleEquality ft then pure (\x y -> x ++ " == " ++ y) else (\e x y -> e ++ "(" ++ x ++ ", " ++ y ++ ")") <$> helper "eq" ft
      if isProductType d
        then pure [ D.text "if a == b { return true }"
                  , D.text ("return " ++ intercalate " && " ("true" : [chk ("a." ++ fieldName f) ("b." ++ fieldName f) | (f, chk) <- zip (constructorFields (firstOf (dataConstructors d))) (firstOf checks)])) ]
        else do
          let arms = [ D.text ("case *" ++ variantType env d c ++ generic ++ ":") <> D.nest 8 (D.hardline <> D.joinWith D.hardline
                         ([D.text ("y, ok := b.(*" ++ variantType env d c ++ generic ++ ")")] ++
                          [D.text ("return ok && " ++ intercalate " && " ("true" : [chk ("x." ++ fieldName f) ("y." ++ fieldName f) | (f, chk) <- zip (constructorFields c) cs]))]))
                     | (c, cs) <- zip (dataConstructors d) checks ]
              used = any (not . null . constructorFields) (dataConstructors d)
          pure [ D.text ("switch " ++ (if used then "x := a.(type) " else "a.(type) ")) <> D.block 8 (D.joinWith D.hardline arms)
               , D.text "return false" ]
  _ -> lift' (Left ("typed Go: no equality for " ++ show ty))
  where
    substitute table t = case t of
      TypeVariable v -> fromMaybe t (lookup v table)
      Constructor n as -> Constructor n [case a of TypeArgument x -> TypeArgument (substitute table x); o -> o | a <- as]
      other -> other

ordering :: Env -> Type -> M [D.Doc]
ordering env ty = case ty of
  Constructor "Bool" [] -> pure [D.text "return lsfCmpBool(a, b)"]
  Constructor "Unit" [] -> pure [D.text "return 0"]
  Constructor "UInt64" [] -> pure [D.text "return lsfCmpUint64(a, b)"]
  Constructor n [] | Just _ <- lookup n fixedBounds -> pure [D.text "return lsfCmpInt64(int64(a), int64(b))"]
  Constructor "Integer" [] -> pure [D.text "return lsfCmpInt(a, b)"]
  Constructor n [] | n `elem` ["Text", "Bytes"] -> pure [D.text "return lsfCmpText(a, b)"]
  Constructor "List" [TypeArgument a] -> (\c -> [D.text ("return lsfCmpList(a, b, " ++ c ++ ")")]) <$> helper "cmp" a
  Constructor "Maybe" [TypeArgument a] -> do
    c <- helper "cmp" a
    pure [ D.text "if a.ok != b.ok { if a.ok { return 1 }; return -1 }"
         , D.text ("if !a.ok { return 0 }")
         , D.text ("return " ++ c ++ "(a.v, b.v)") ]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- helper "cmp" a
    cr <- helper "cmp" b
    pure [ D.text "if a.right != b.right { if a.right { return 1 }; return -1 }"
         , D.text ("if a.right { return " ++ cr ++ "(a.r, b.r) }")
         , D.text ("return " ++ cl ++ "(a.l, b.l)") ]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ck <- helper "cmp" k
        cv <- helper "cmp" v
        pure [D.text ("return lsfCmpMap(a, b, " ++ ck ++ ", " ++ cv ++ ")")]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        ck <- helper "cmp" a
        pure [D.text ("return lsfCmpMap(a, b, " ++ ck ++ ", lsfCmpUnit)")]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
        name = envNames env M.! n
    if fieldless d then pure [D.text ("return lsfCmpInt64(int64(" ++ name ++ "Ranks[a]), int64(" ++ name ++ "Ranks[b]))")] else do
      witnesses <- lift' (mapM (goType env) (map snd table))
      let generic = if null witnesses then "" else "[" ++ intercalate ", " witnesses ++ "]"
      comparisons <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> helper "cmp" (substitute table (binderType f))
      let fieldsOf prefixA prefixB c cs = [D.text ("if c := " ++ cmp ++ "(" ++ prefixA ++ fieldName f ++ ", " ++ prefixB ++ fieldName f ++ "); c != 0 { return c }") | (f, cmp) <- zip (constructorFields c) cs]
      if isProductType d
        then pure (fieldsOf "a." "b." (firstOf (dataConstructors d)) (firstOf comparisons) ++ [D.text "return 0"])
        else do
          let arms = [ D.text ("case *" ++ variantType env d c ++ generic ++ ":") <> D.nest 8 (D.hardline <> D.joinWith D.hardline
                         ([D.text ("y := b.(*" ++ variantType env d c ++ generic ++ ")") | not (null (constructorFields c))] ++ fieldsOf "x." "y." c cs))
                     | (c, cs) <- zip (dataConstructors d) comparisons ]
              used = any (not . null . constructorFields) (dataConstructors d)
          pure [ D.text ("if ta, tb := a.lsfTag" ++ name ++ "(), b.lsfTag" ++ name ++ "(); ta != tb { return lsfCmpInt64(int64(" ++ name ++ "Ranks[ta]), int64(" ++ name ++ "Ranks[tb])) }")
               , D.text ("switch " ++ (if used then "x := a.(type) " else "a.(type) ")) <> D.block 8 (D.joinWith D.hardline arms)
               , D.text "return 0" ]
  _ -> lift' (Left ("typed Go: no order for " ++ show ty))
  where
    substitute table t = case t of
      TypeVariable v -> fromMaybe t (lookup v table)
      Constructor n as -> Constructor n [case a of TypeArgument x -> TypeArgument (substitute table x); o -> o | a <- as]
      other -> other

toValue :: Env -> String -> Type -> M [D.Doc]
toValue env key ty = case ty of
  Constructor "Bool" [] -> pure [D.text "return LawSpecValue{\"Bool\", x}"]
  Constructor "Unit" [] -> pure [D.text "return LawSpecValue{\"Unit\", nil}"]
  Constructor "UInt64" [] -> pure [D.text "return LawSpecValue{\"UInt64\", new(big.Int).SetUint64(x)}"]
  Constructor n [] | Just _ <- lookup n fixedBounds -> pure [D.text ("return LawSpecValue{" ++ show n ++ ", big.NewInt(int64(x))}")]
  Constructor "Integer" [] -> pure [D.text "return LawSpecValue{\"Integer\", new(big.Int).Set(x.big())}"]
  Constructor "Text" [] -> pure [D.text "return lsfTextValue(x)"]
  Constructor "Bytes" [] -> pure [D.text "return lsfBytesValue(x)"]
  Constructor "List" [TypeArgument a] -> do
    to <- helper "to" a
    pure [ D.text "items := make([]LawSpecValue, 0, x.length())"
         , D.text ("for c := x; c != nil; c = c.tail { items = append(items, " ++ to ++ "(c.head)) }")
         , D.text ("return LawSpecValue{" ++ goQuote key ++ ", items}") ]
  Constructor "Maybe" [TypeArgument a] -> do
    to <- helper "to" a
    pure [ D.text ("if x.ok { return lsfDataValue(" ++ goQuote key ++ ", \"Maybe::Just\", " ++ to ++ "(x.v)) }")
         , D.text ("return lsfDataValue(" ++ goQuote key ++ ", \"Maybe::Nothing\")") ]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    tl <- helper "to" a
    tr <- helper "to" b
    pure [ D.text ("if x.right { return lsfDataValue(" ++ goQuote key ++ ", \"Either::Right\", " ++ tr ++ "(x.r)) }")
         , D.text ("return lsfDataValue(" ++ goQuote key ++ ", \"Either::Left\", " ++ tl ++ "(x.l))") ]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        tk <- helper "to" k
        tv <- helper "to" v
        kt <- lift' (goType env k)
        vt <- lift' (goType env v)
        let entry = Constructor (collectionsUnit ++ "::type::Entry") [TypeArgument k, TypeArgument v]
        pure [ D.text "entries := make([]LawSpecValue, 0, x.size())"
             , D.text ("lsfEach(x, func(k " ++ kt ++ ", v " ++ vt ++ ") { entries = append(entries, lsfDataValue(" ++ goQuote (goDataKey entry) ++ ", " ++ goQuote (collectionsUnit ++ "::type::Entry::Entry") ++ ", " ++ tk ++ "(k), " ++ tv ++ "(v))) })")
             , D.text ("return lsfDataValue(" ++ goQuote key ++ ", " ++ goQuote (collectionsUnit ++ "::type::KeyVal::KeyValEntries") ++ ", LawSpecValue{" ++ goQuote (goDataKey (Constructor "List" [TypeArgument entry])) ++ ", entries})") ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        ta <- helper "to" a
        at <- lift' (goType env a)
        pure [ D.text "items := make([]LawSpecValue, 0, x.size())"
             , D.text ("lsfEach(x, func(k " ++ at ++ ", _ lsfUnit) { items = append(items, " ++ ta ++ "(k)) })")
             , D.text ("return lsfDataValue(" ++ goQuote key ++ ", " ++ goQuote (collectionsUnit ++ "::type::Set::SetItems") ++ ", LawSpecValue{" ++ goQuote (goDataKey (Constructor "List" [TypeArgument a])) ++ ", items})") ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
        name = envNames env M.! n
    witnesses <- lift' (mapM (goType env) (map snd table))
    let generic = if null witnesses then "" else "[" ++ intercalate ", " witnesses ++ "]"
    if fieldless d
      then pure [ D.text "switch x " <> D.block 8 (D.joinWith D.hardline
                    [D.text ("case " ++ name ++ "_" ++ identifier (constructorName c) ++ ": return lsfDataValue(" ++ goQuote key ++ ", " ++ goQuote (idText (constructorId c)) ++ ")") | c <- dataConstructors d])
                , D.text "panic(\"unreachable branch reached\")" ]
      else do
        encoders <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> helper "to" (substitute table (binderType f))
        let fieldsOf prefix c es = concat [", " ++ e ++ "(" ++ prefix ++ fieldName f ++ ")" | (f, e) <- zip (constructorFields c) es]
        if isProductType d
          then let c = firstOf (dataConstructors d) in
            pure [D.text ("return lsfDataValue(" ++ goQuote key ++ ", " ++ goQuote (idText (constructorId c)) ++ fieldsOf "x." c (firstOf encoders) ++ ")")]
          else do
            let used = any (not . null . constructorFields) (dataConstructors d)
            pure [ D.text ("switch " ++ (if used then "y := x.(type) " else "x.(type) ")) <> D.block 8 (D.joinWith D.hardline
                     [ D.text ("case *" ++ variantType env d c ++ generic ++ ": return lsfDataValue(" ++ goQuote key ++ ", " ++ goQuote (idText (constructorId c)) ++ fieldsOf "y." c es ++ ")")
                     | (c, es) <- zip (dataConstructors d) encoders ])
                 , D.text "panic(\"unreachable branch reached\")" ]
  _ -> lift' (Left ("typed Go: no conversion for " ++ show ty))
  where
    substitute table t = case t of
      TypeVariable v -> fromMaybe t (lookup v table)
      Constructor n as -> Constructor n [case a of TypeArgument x -> TypeArgument (substitute table x); o -> o | a <- as]
      other -> other

fromValue :: Env -> Type -> M [D.Doc]
fromValue env ty = case ty of
  Constructor "Bool" [] -> pure [D.text "return v.Data.(bool)"]
  Constructor "Unit" [] -> pure [D.text "return lsfUnit{}"]
  Constructor "UInt64" [] -> pure [D.text "return lsfValueUint64(v)"]
  Constructor n [] | Just (lo, hi) <- lookup n fixedBounds, Just g <- lookup n goFixed ->
    pure [D.text ("return " ++ g ++ "(lsfValueInt64(v, " ++ (if lo == -(2 ^ (63 :: Int)) then "-1 << 63" else show lo) ++ ", " ++ show hi ++ ", " ++ show n ++ "))")]
  Constructor "Integer" [] -> pure [D.text "return lsfValueInt(v)"]
  Constructor "Text" [] -> pure [D.text "return lsfValueText(v)"]
  Constructor "Bytes" [] -> pure [D.text "return lsfValueBytes(v)"]
  Constructor "List" [TypeArgument a] -> do
    from <- helper "from" a
    t <- lift' (goType env ty)
    pure [ D.text "items := v.Data.([]LawSpecValue)"
         , D.text ("var out " ++ t)
         , D.text ("for i := len(items) - 1; i >= 0; i-- { out = lsfCons(" ++ from ++ "(items[i]), out) }")
         , D.text "return out" ]
  Constructor "Maybe" [TypeArgument a] -> do
    from <- helper "from" a
    at <- lift' (goType env a)
    pure [ D.text "tag, fields := lsfData(v)"
         , D.text ("if tag == \"Maybe::Just\" { return lsfJust[" ++ at ++ "](" ++ from ++ "(fields[0])) }")
         , D.text ("return lsfNothing[" ++ at ++ "]()") ]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "from" a
    fr <- helper "from" b
    lt <- lift' (goType env a)
    rt <- lift' (goType env b)
    pure [ D.text "tag, fields := lsfData(v)"
         , D.text ("if tag == \"Either::Right\" { return lsfRight[" ++ lt ++ ", " ++ rt ++ "](" ++ fr ++ "(fields[0])) }")
         , D.text ("return lsfLeft[" ++ lt ++ ", " ++ rt ++ "](" ++ fl ++ "(fields[0]))") ]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "from" k
        fv <- helper "from" v
        ck <- helper "cmp" k
        t <- lift' (goType env ty)
        pure [ D.text ("var out " ++ t)
             , D.text ("for _, item := range lsfItems(v) { _, fields := lsfData(item); out = lsfPut(out, " ++ fk ++ "(fields[0]), " ++ fv ++ "(fields[1]), " ++ ck ++ ") }")
             , D.text "return out" ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        fa <- helper "from" a
        ca <- helper "cmp" a
        t <- lift' (goType env ty)
        pure [ D.text ("var out " ++ t)
             , D.text ("for _, item := range lsfItems(v) { out = lsfSetInsert(out, " ++ fa ++ "(item), " ++ ca ++ ") }")
             , D.text "return out" ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
        name = envNames env M.! n
    witnesses <- lift' (mapM (goType env) (map snd table))
    let generic = if null witnesses then "" else "[" ++ intercalate ", " witnesses ++ "]"
    decoders <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> helper "from" (substitute table (binderType f))
    let made c ds
          | fieldless d = name ++ "_" ++ identifier (constructorName c)
          | isProductType d = "&" ++ name ++ generic ++ "{" ++ intercalate ", " [dec ++ "(fields[" ++ show k ++ "])" | (k, dec) <- zip [0 :: Int ..] ds] ++ "}"
          | otherwise = "&" ++ variantType env d c ++ generic ++ "{" ++ intercalate ", " [dec ++ "(fields[" ++ show k ++ "])" | (k, dec) <- zip [0 :: Int ..] ds] ++ "}"
        anyFields = any (not . null . constructorFields) (dataConstructors d)
    pure [ D.text (if anyFields then "tag, fields := lsfData(v)" else "tag, _ := lsfData(v)")
         , D.text "switch tag " <> D.block 8 (D.joinWith D.hardline
             [D.text ("case " ++ goQuote (idText (constructorId c)) ++ ": return " ++ made c ds) | (c, ds) <- zip (dataConstructors d) decoders])
         , D.text ("panic(\"expected " ++ dataName d ++ ", found \" + tag)") ]
  _ -> lift' (Left ("typed Go: no conversion for " ++ show ty))
  where
    substitute table t = case t of
      TypeVariable v -> fromMaybe t (lookup v table)
      Constructor n as -> Constructor n [case a of TypeArgument x -> TypeArgument (substitute table x); o -> o | a <- as]
      other -> other

-- | Whether a type converts to and from its native Go type directly: no
-- Duration, Queue, Stack or Deque, whose native forms differ in shape.
nativeDirect :: Env -> S.Set String -> Type -> Bool
nativeDirect env seen ty = case ty of
  Constructor n [] | n `elem` ["Bool", "Unit", "Integer", "Text", "Bytes"] || n `elem` map fst goFixed -> True
  Constructor n [TypeArgument a] | n `elem` ["List", "Maybe"] -> nativeDirect env seen a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> nativeDirect env seen a && nativeDirect env seen b
  _ | Just (_, args) <- collectionArguments ty -> all (nativeDirect env seen) args
  Constructor n args | isDurationType n || collectionContainer n /= Nothing -> False
                     | Just d <- M.lookup n (envData env) ->
      let table = zip (dataParameters d) [t | TypeArgument t <- args]
          key = show ty
      in key `S.member` seen || all (nativeDirect env (S.insert key seen) . substitute table . binderType) (concatMap constructorFields (dataConstructors d))
  _ -> False
  where
    substitute table t = case t of
      TypeVariable v -> fromMaybe t (lookup v table)
      Constructor n as -> Constructor n [case a of TypeArgument x -> TypeArgument (substitute table x); o -> o | a <- as]
      other -> other

nativeArguments :: Env -> Type -> M String
nativeArguments env ty = case ty of
  Constructor _ args -> do
    ns <- lift' (mapM (GoData.goDataType (envDeclarations env)) [t | TypeArgument t <- args])
    pure (if null ns then "" else "[" ++ intercalate ", " ns ++ "]")
  _ -> pure ""

toNative :: Env -> Type -> M [D.Doc]
toNative env ty = case ty of
  Constructor n [] | n `elem` ["Bool", "Text"] || n `elem` map fst goFixed -> pure [D.text "return x"]
  Constructor "Unit" [] -> pure [D.text "return LawSpecUnit{}"]
  Constructor "Bytes" [] -> pure [D.text "return []byte(x)"]
  Constructor "Integer" [] -> pure [D.text "return new(big.Int).Set(x.big())"]
  Constructor "List" [TypeArgument a] -> do
    c <- helper "tonative" a
    na <- lift' (GoData.goDataType (envDeclarations env) a)
    pure [ D.text ("out := make([]" ++ na ++ ", 0, x.length())")
         , D.text ("for c := x; c != nil; c = c.tail { out = append(out, " ++ c ++ "(c.head)) }")
         , D.text "return out" ]
  Constructor "Maybe" [TypeArgument a] -> do
    c <- helper "tonative" a
    na <- lift' (GoData.goDataType (envDeclarations env) a)
    pure [ D.text ("if x.ok { return LawSpecJust[" ++ na ++ "](" ++ c ++ "(x.v)) }"), D.text ("return LawSpecNothing[" ++ na ++ "]()") ]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- helper "tonative" a
    cr <- helper "tonative" b
    nl <- lift' (GoData.goDataType (envDeclarations env) a)
    nr <- lift' (GoData.goDataType (envDeclarations env) b)
    pure [ D.text ("if x.right { return LawSpecRight[" ++ nl ++ ", " ++ nr ++ "](" ++ cr ++ "(x.r)) }")
         , D.text ("return LawSpecLeft[" ++ nl ++ ", " ++ nr ++ "](" ++ cl ++ "(x.l))") ]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ck <- helper "tonative" k
        cv <- helper "tonative" v
        n <- lift' (GoData.goDataType (envDeclarations env) ty)
        kt <- lift' (goType env k)
        vt <- lift' (goType env v)
        let entry = drop 2 n
        pure [ D.text ("out := make(" ++ n ++ ", 0, x.size())")
             , D.text ("lsfEach(x, func(k " ++ kt ++ ", v " ++ vt ++ ") { out = append(out, " ++ entry ++ "{" ++ ck ++ "(k), " ++ cv ++ "(v)}) })")
             , D.text "return out" ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        c <- helper "tonative" a
        n <- lift' (GoData.goDataType (envDeclarations env) ty)
        at <- lift' (goType env a)
        pure [ D.text ("out := make(" ++ n ++ ", 0, x.size())")
             , D.text ("lsfEach(x, func(k " ++ at ++ ", _ lsfUnit) { out = append(out, " ++ c ++ "(k)) })")
             , D.text "return out" ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
    nargs <- nativeArguments env ty
    witnesses <- lift' (mapM (goType env) (map snd table))
    let generic = if null witnesses then "" else "[" ++ intercalate ", " witnesses ++ "]"
        nativeOf c = envNative env M.! constructorId c
    converters <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> helper "tonative" (substituteIn table (binderType f))
    let made prefix c cs = nativeOf c ++ (if isProduct d || null (constructorFields c) then nargs else nargs) ++ "{" ++
          intercalate ", " [cv ++ "(" ++ prefix ++ fieldName f ++ ")" | (f, cv) <- zip (constructorFields c) cs] ++ "}"
    if fieldless d
      then pure [ D.text "switch x " <> D.block 8 (D.joinWith D.hardline
                    [D.text ("case " ++ envNames env M.! n ++ "_" ++ identifier (constructorName c) ++ ": return " ++ made "" c []) | c <- dataConstructors d])
                , D.text "panic(\"unreachable branch reached\")" ]
      else if isProductType d
        then let c = firstOf (dataConstructors d) in pure [D.text ("return " ++ made "x." c (firstOf converters))]
        else do
          let used = any (not . null . constructorFields) (dataConstructors d)
          pure [ D.text ("switch " ++ (if used then "y := x.(type) " else "x.(type) ")) <> D.block 8 (D.joinWith D.hardline
                   [D.text ("case *" ++ variantType env d c ++ generic ++ ": return " ++ made "y." c cs) | (c, cs) <- zip (dataConstructors d) converters])
               , D.text "panic(\"unreachable branch reached\")" ]
  _ -> lift' (Left ("typed Go: no native conversion for " ++ show ty))

fromNative :: Env -> Type -> M [D.Doc]
fromNative env ty = case ty of
  Constructor n [] | n `elem` ["Bool", "Text"] || n `elem` map fst goFixed -> pure [D.text "return n"]
  Constructor "Unit" [] -> pure [D.text "return lsfUnit{}"]
  Constructor "Bytes" [] -> pure [D.text "return string(n)"]
  Constructor "Integer" [] -> pure [D.text "return lsfFromBig(new(big.Int).Set(n))"]
  Constructor "List" [TypeArgument a] -> do
    c <- helper "fromnative" a
    t <- lift' (goType env ty)
    pure [ D.text ("var out " ++ t), D.text ("for i := len(n) - 1; i >= 0; i-- { out = lsfCons(" ++ c ++ "(n[i]), out) }"), D.text "return out" ]
  Constructor "Maybe" [TypeArgument a] -> do
    c <- helper "fromnative" a
    at <- lift' (goType env a)
    pure [ D.text ("if v, ok := n.Value(); ok { return lsfJust[" ++ at ++ "](" ++ c ++ "(v)) }"), D.text ("return lsfNothing[" ++ at ++ "]()") ]
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    cl <- helper "fromnative" a
    cr <- helper "fromnative" b
    lt <- lift' (goType env a)
    rt <- lift' (goType env b)
    pure [ D.text ("if r, ok := n.Right(); ok { return lsfRight[" ++ lt ++ ", " ++ rt ++ "](" ++ cr ++ "(r)) }")
         , D.text "l, _ := n.Left()"
         , D.text ("return lsfLeft[" ++ lt ++ ", " ++ rt ++ "](" ++ cl ++ "(l))") ]
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        ck <- helper "fromnative" k
        cv <- helper "fromnative" v
        cmp <- helper "cmp" k
        t <- lift' (goType env ty)
        pure [ D.text ("var out " ++ t), D.text ("for _, e := range n { out = lsfPut(out, " ++ ck ++ "(e.Key), " ++ cv ++ "(e.Value), " ++ cmp ++ ") }"), D.text "return out" ]
    | Just ("Set", [a]) <- collectionArguments ty -> do
        c <- helper "fromnative" a
        cmp <- helper "cmp" a
        t <- lift' (goType env ty)
        pure [ D.text ("var out " ++ t), D.text ("for _, item := range n { out = lsfSetInsert(out, " ++ c ++ "(item), " ++ cmp ++ ") }"), D.text "return out" ]
  Constructor n args | Just d <- M.lookup n (envData env) -> do
    let table = zip (dataParameters d) [t | TypeArgument t <- args]
        name = envNames env M.! n
    nargs <- nativeArguments env ty
    witnesses <- lift' (mapM (goType env) (map snd table))
    let generic = if null witnesses then "" else "[" ++ intercalate ", " witnesses ++ "]"
        nativeOf c = envNative env M.! constructorId c
    converters <- forM (dataConstructors d) $ \c -> forM (constructorFields c) $ \f -> helper "fromnative" (substituteIn table (binderType f))
    let made prefix c cs
          | fieldless d = name ++ "_" ++ identifier (constructorName c)
          | isProductType d = "&" ++ name ++ generic ++ "{" ++ intercalate ", " [cv ++ "(" ++ prefix ++ GoData.goFieldName (binderName f) ++ ")" | (f, cv) <- zip (constructorFields c) cs] ++ "}"
          | otherwise = "&" ++ variantType env d c ++ generic ++ "{" ++ intercalate ", " [cv ++ "(" ++ prefix ++ GoData.goFieldName (binderName f) ++ ")" | (f, cv) <- zip (constructorFields c) cs] ++ "}"
    if isProduct d
      then let c = firstOf (dataConstructors d) in pure [D.text ("return " ++ made "n." c (firstOf converters))]
      else do
        let used = any (not . null . constructorFields) (dataConstructors d)
        pure [ D.text ("switch " ++ (if used then "y := n.(type) " else "n.(type) ")) <> D.block 8 (D.joinWith D.hardline
                 [D.text ("case " ++ nativeOf c ++ nargs ++ ": return " ++ made "y." c cs) | (c, cs) <- zip (dataConstructors d) converters])
             , D.text "panic(\"unreachable branch reached\")" ]
  _ -> lift' (Left ("typed Go: no native conversion for " ++ show ty))

substituteIn :: [(Id, Type)] -> Type -> Type
substituteIn table t = case t of
  TypeVariable v -> fromMaybe t (lookup v table)
  Constructor n as -> Constructor n [case a of TypeArgument x -> TypeArgument (substituteIn table x); o -> o | a <- as]
  other -> other
