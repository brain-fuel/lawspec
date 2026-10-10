-- | Typed Haskell for checked definitions (see LawSpec.Typed.Plan), in
-- src/LawSpecTyped.hs: a strict data type per typed data type, with its
-- constructors in the portable order so the derived Eq and Ord are
-- LawSpec's, a function per class of typed definitions, and per concrete
-- type the code needs its conversions to and from Scalar and the native
-- types. Typed definitions run in IO, strictly: every binding is evaluated
-- where it is written, raise and attempt throw and catch the dynamic code's
-- Failure, and an operation of another ability goes to the handler the
-- symbol context holds, exactly once and in order. Lists, KeyVal and Set are
-- persistent, so a handler's state is never copied.
-- ref:DEC-typed-native-definitions
module LawSpec.Typed.Haskell (HaskellTyped(..), emitHaskellTyped) where

import Control.Monad (forM, forM_)
import Control.Monad.State.Strict
import Data.Char (isAlphaNum, isUpper, toLower, toUpper, ord)
import Data.List (intercalate, isPrefixOf, sortOn, nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as S
import LawSpec.Collections (collectionsUnit)
import LawSpec.Core
import LawSpec.Scalar
import LawSpec.Typed.Plan
import LawSpec.HaskellData (namesFor, haskellDataType)
import LawSpec.AbilityNames (interfaceName, fieldName)
import qualified LawSpec.Code.Doc as D
import LawSpec.Digest (digestHex, digestString)

data HaskellTyped = HaskellTyped
  { hsTypedModule :: String
    -- Names within LawSpecTyped (callers qualify them).
  , hsTypedFunction :: Id -> Maybe String
  , hsTypedFrom :: Type -> String
  , hsTypedTo :: Type -> String
  , hsTypedFromNative :: Type -> String
  , hsTypedToNative :: Type -> String
  , hsTypedStart :: Id -> Maybe String
    -- A type's typed form, qualified with Typed.
  , hsTypedType :: Type -> Either String String
    -- The typed Pair's constructor.
  , hsTypedPair :: String
  , hsTypedPlan :: TypedPlan
  }

data Env = Env
  { envPlan :: TypedPlan
  , envData :: M.Map String DataDeclaration
  , envConstructors :: M.Map Id (DataDeclaration, DataConstructor)
  , envFunctions :: M.Map Int String
  , envNames :: M.Map Id String          -- typed type and constructor names
  , envNative :: M.Map Id String         -- native constructor names
  , envUnits :: [Unit]
  , envDeclarations :: [DataDeclaration]
  }

data St = St { stCounter :: Int, stHelpers :: M.Map String Type, stWanted :: S.Set (String, String), stLiterals :: M.Map String (String, String) }

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
  cleaned@(c : _) | c >= 'a' && c <= 'z' -> "v_" ++ cleaned
  cleaned -> "v" ++ cleaned
  where lower c = if isUpper c then toLower c else c

identifier :: String -> String
identifier name = case [c | c <- name, isAlphaNum c && ord c < 128 || c == '_'] of
  [] -> "x"
  n -> n

capitalize :: String -> String
capitalize (c : cs) = toUpper c : cs
capitalize [] = []

helper :: String -> Type -> M String
helper kind ty = do
  let key = show ty
  modify (\st -> st { stHelpers = M.insert key ty (stHelpers st), stWanted = S.insert (kind, key) (stWanted st) })
  pure (helperName kind ty)

helperName :: String -> Type -> String
helperName kind ty = kind ++ "_" ++ take 12 (digestHex (digestString (show ty)))

-- | A literal Text or ByteString, made once.
literal :: String -> String -> M String
literal key definition = do
  st <- get
  case M.lookup key (stLiterals st) of
    Just (name, _) -> pure name
    Nothing -> do
      let name = "lit_" ++ show (M.size (stLiterals st))
      put st { stLiterals = M.insert key (name, definition) (stLiterals st) }
      pure name

emitHaskellTyped :: [DataDeclaration] -> [Unit] -> Either String HaskellTyped
emitHaskellTyped declarations units = do
  let plan = typedPlanPerforming scalarTypes declarations units
      datas = typedData plan
      functions = M.fromList [ (c, functionName c d) | (c, d) <- typedRepresentatives plan ]
  natives <- namesFor declarations
  let env = Env plan (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions (typedNames datas)
        (M.fromList natives) units declarations
      typedHandlers = [ h | u <- units, h <- unitHandlers u, isTypedHandler plan h ]
      handlerTypes = [ t | h <- typedHandlers, ref <- handlerAbilities h, Just (_, a) <- [findAbility units ref]
                         , (_, ty) <- abilityOperations a, let (args, result) = functionType ty, t <- result : args ] ++
                     [ t | h <- typedHandlers, Just (t, _) <- [handlerState h] ]
      boundary = concat [ let (args, result) = functionType (declarationType (definitionDeclaration d)) in result : args
                        | d <- M.elems (typedDefinitions plan) ]
      starts = [ (handlerId h, "start_" ++ stableSuffix (handlerId h), ty, start) | h <- typedHandlers, Just (ty, start) <- [handlerState h] ]
      abilityModules = nub [ abilityModule u | d <- M.elems (typedDefinitions plan), op <- performedIn (definitionBody d)
                           , Just (u, _) <- [findAbility units (operationAbility op)] ]
  dataDocs <- mapM (dataDoc env) datas
  ((functionDocs, startDocs, helperDocs, literalDocs), _) <- flip runStateT (St 0 M.empty S.empty M.empty) $ do
    fs <- mapM (\(c, d) -> functionDoc env c d) (typedRepresentatives plan)
    ss <- forM starts $ \(_, name, ty, start) -> do
      body <- cstmt env [(symbolsId, "symbols")] start
      t <- lift' (hsType env ty)
      pure (D.text (name ++ " :: LS.SymbolContext -> P.IO " ++ t) <> D.hardline <> D.text (name ++ " symbols = do") <> nest body)
    forM_ boundary $ \t -> helper "to" t >> helper "from" t
    forM_ handlerTypes $ \t -> helper "tn" t >> helper "fn" t
    hs <- helpers env
    ls <- gets (M.elems . stLiterals)
    pure (fs, ss, hs, [D.text (name ++ " = " ++ definition) | (name, definition) <- ls])
  let header = map D.text
        ([ "{-# LANGUAGE BangPatterns, ScopedTypeVariables #-}"
         , "{-# OPTIONS_GHC -Wno-unused-matches -Wno-unused-local-binds -Wno-name-shadowing -Wno-unused-imports -Wno-unused-do-bind -Wno-incomplete-patterns -Wno-overlapping-patterns #-}"
         , "-- Generated by LawSpec. Do not edit."
         , "-- Typed checked definitions over LawSpecFast's values; see"
         , "-- docs/how-to/embed-a-generated-model.md."
         , "module LawSpecTyped where"
         , ""
         , "import Prelude ()"
         , "import qualified Prelude as P"
         , "import qualified Data.Int as I"
         , "import qualified Data.Word as W"
         , "import qualified Data.Text as T"
         , "import qualified Data.ByteString as B"
         , "import qualified Data.Map.Strict as Map"
         , "import qualified Data.Set as Set"
         , "import LawSpecRuntime (Scalar(..))"
         , "import qualified LawSpecRuntime as LS"
         , "import qualified LawSpecFast as LSF"
         , "import qualified LawSpecData as Data" ] ++
         [ "import qualified " ++ m | m <- abilityModules ])
      source = D.render (D.Pretty 100) (D.joinWith D.hardline header <> D.hardline <> D.hardline <>
        D.joinWith (D.hardline <> D.hardline) (concat dataDocs ++ orderingHelper env ++ functionDocs ++ startDocs ++ helperDocs ++ literalDocs)) ++ "\n"
      pairName = case [c | d <- datas, idText (dataId d) == collectionsUnit ++ "::type::Pair", c <- dataConstructors d] of
        c : _ -> "Typed." ++ envNames env M.! constructorId c
        [] -> "Typed.C_Pair"
  pure HaskellTyped
    { hsTypedModule = source
    , hsTypedFunction = \i -> definitionClass plan i >>= (`M.lookup` functions)
    , hsTypedFrom = helperName "from"
    , hsTypedTo = helperName "to"
    , hsTypedFromNative = helperName "fn"
    , hsTypedToNative = helperName "tn"
    , hsTypedStart = \h -> case [n | (i, n, _, _) <- starts, i == h] of
        n : _ -> Just n
        [] -> Nothing
    , hsTypedType = hsTypeWith "Typed." env
    , hsTypedPair = pairName
    , hsTypedPlan = plan }
  where
    functionName _ d = "def_" ++ identifier (shortName (declarationName (definitionDeclaration d))) ++ "_" ++ stableSuffix (declarationId (definitionDeclaration d))
    shortName name =
      let unprefixed = if "lawspec_" `isPrefixOf` name then drop 8 name else name
      in reverse (dropHash (reverse unprefixed))
    dropHash reversed = case span (`elem` ("0123456789abcdef" :: String)) reversed of
      (digits@(_ : _), '_' : rest) | length digits >= 8 -> rest
      _ -> reversed
    performedIn e = case expressionNode e of
      Perform op args | operationName op /= "raise" || not (isFail (operationAbility op)) -> op : concatMap performedIn args
      _ -> concatMap performedIn (children e)

abilityModule :: Unit -> String
abilityModule u = intercalate "." ("LawSpecAbilities" : map (concatMap capitalize . split '_') (split '.' (idText (unitId u))))
  where
    split c s = case break (== c) s of
      (a, []) -> [a]
      (a, _ : rest) -> a : split c rest

-- | Typed type and constructor names.
typedNames :: [DataDeclaration] -> M.Map Id String
typedNames datas = M.fromList (snd (foldl pick (S.empty, []) datas))
  where
    pick (taken, acc) d =
      let base = "T_" ++ identifier (dataName d)
          chosen = firstOf [n | n <- base : [base ++ "_" ++ show k | k <- [2 :: Int ..]], n `S.notMember` taken]
          constructors = [ (constructorId c, "C" ++ drop 1 chosen ++ (if length (dataConstructors d) > 1 then "_" ++ identifier (constructorName c) else ""))
                         | c <- dataConstructors d ]
      in (S.insert chosen taken, (dataId d, chosen) : constructors ++ acc)

rankOf :: DataDeclaration -> DataConstructor -> Int
rankOf d c = fromMaybe 0 (lookup (constructorId c) (constructorRanks d))

substituteIn :: [(Id, Type)] -> Type -> Type
substituteIn table t = case t of
  TypeVariable v -> fromMaybe t (lookup v table)
  Constructor n as -> Constructor n [case a of TypeArgument x -> TypeArgument (substituteIn table x); o -> o | a <- as]
  other -> other

fieldTypes :: DataDeclaration -> [Type] -> DataConstructor -> [Type]
fieldTypes d args c = map (substituteIn (zip (dataParameters d) args) . binderType) (constructorFields c)

scalarHs :: [(String, String)]
scalarHs =
  [ ("Bool", "P.Bool"), ("Unit", "()"), ("Int8", "I.Int8"), ("Int16", "I.Int16"), ("Int32", "I.Int32"), ("Int64", "I.Int64")
  , ("UInt8", "W.Word8"), ("UInt16", "W.Word16"), ("UInt32", "W.Word32"), ("UInt64", "W.Word64"), ("Integer", "P.Integer")
  , ("Text", "T.Text"), ("Bytes", "B.ByteString") ]

hsType :: Env -> Type -> Either String String
hsType = hsTypeWith ""

hsTypeWith :: String -> Env -> Type -> Either String String
hsTypeWith prefix env = go []
  where
    go parameters ty = case ty of
      TypeVariable v | Just p <- lookup v parameters -> pure p
      Constructor n [] | Just t <- lookup n scalarHs -> pure t
      Constructor "List" [TypeArgument a] -> (\x -> "(LSF.List " ++ x ++ ")") <$> go parameters a
      Constructor "Maybe" [TypeArgument a] -> (\x -> "(LSF.Opt " ++ x ++ ")") <$> go parameters a
      Constructor "Either" [TypeArgument a, TypeArgument b] -> (\x y -> "(LSF.Alt " ++ x ++ " " ++ y ++ ")") <$> go parameters a <*> go parameters b
      _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> (\x y -> "(Map.Map " ++ x ++ " " ++ y ++ ")") <$> go parameters k <*> go parameters v
        | Just ("Set", [a]) <- collectionArguments ty -> (\x -> "(Set.Set " ++ x ++ ")") <$> go parameters a
      Constructor n args | Just d <- M.lookup n (envData env) -> do
        rendered <- mapM (\a -> case a of TypeArgument t -> go parameters t; _ -> Left "typed Haskell: index argument") args
        let name = prefix ++ envNames env M.! dataId d
        pure (if null rendered then name else "(" ++ unwords (name : rendered) ++ ")")
      _ -> Left ("no typed Haskell form for " ++ show ty)

dataDoc :: Env -> DataDeclaration -> Either String [D.Doc]
dataDoc env d = do
  let parameters = zip (dataParameters d) ["a" ++ show k | k <- [0 :: Int ..]]
      name = envNames env M.! dataId d
      field ty = case ty of
        Constructor n [] | n `elem` ["Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64"] ->
          ("{-# UNPACK #-} !" ++) <$> hsTypeP parameters ty
        _ -> ("!" ++) <$> hsTypeP parameters ty
  variants <- forM (sortOn (rankOf d) (dataConstructors d)) $ \c -> do
    fs <- mapM (field . binderType) (constructorFields c)
    pure (unwords (envNames env M.! constructorId c : fs))
  pure [D.text ("-- " ++ idText (dataId d)) <> D.hardline <>
    D.text ("data " ++ unwords (name : map snd parameters)) <> D.nest 2 (D.hardline <> D.text "= " <>
      D.joinWith (D.hardline <> D.text "| ") (map D.text variants) <> D.hardline <> D.text "deriving (P.Eq, P.Ord)")]
  where
    hsTypeP parameters ty = case ty of
      TypeVariable v | Just p <- lookup v parameters -> pure p
      Constructor n args | Just d' <- M.lookup n (envData env) -> do
        rendered <- mapM (\a -> case a of TypeArgument t -> hsTypeP parameters t; _ -> Left "index") args
        let n' = envNames env M.! dataId d'
        pure (if null rendered then n' else "(" ++ unwords (n' : rendered) ++ ")")
      Constructor "List" [TypeArgument a] -> (\x -> "(LSF.List " ++ x ++ ")") <$> hsTypeP parameters a
      Constructor "Maybe" [TypeArgument a] -> (\x -> "(LSF.Opt " ++ x ++ ")") <$> hsTypeP parameters a
      Constructor "Either" [TypeArgument a, TypeArgument b] -> (\x y -> "(LSF.Alt " ++ x ++ " " ++ y ++ ")") <$> hsTypeP parameters a <*> hsTypeP parameters b
      _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> (\x y -> "(Map.Map " ++ x ++ " " ++ y ++ ")") <$> hsTypeP parameters k <*> hsTypeP parameters v
        | Just ("Set", [a]) <- collectionArguments ty -> (\x -> "(Set.Set " ++ x ++ ")") <$> hsTypeP parameters a
      _ -> hsType env ty

orderingHelper :: Env -> [D.Doc]
orderingHelper env = case M.lookup (collectionsUnit ++ "::type::Ordering") (envData env) of
  Nothing -> []
  Just d ->
    let con name = firstOf ([envNames env M.! constructorId c | c <- dataConstructors d, constructorName c == name] ++ ["P.undefined"])
    in [D.text ("ordering_of :: P.Ordering -> " ++ envNames env M.! dataId d) <> D.hardline <>
        D.text ("ordering_of o = case o of { P.LT -> " ++ con "Less" ++ "; P.EQ -> " ++ con "Equal" ++ "; P.GT -> " ++ con "Greater" ++ " }")]

-- Statements: the lines of a do-block whose last line gives its value.

nest :: [D.Doc] -> D.Doc
nest body = D.nest 2 (D.hardline <> D.joinWith D.hardline body)

paren :: D.Doc -> D.Doc
paren x = D.text "(" <> x <> D.text ")"

type Scope = [(Id, String)]

symbolsId :: Id
symbolsId = Id "lawspec::symbols"

functionDoc :: Env -> Int -> Definition -> M D.Doc
functionDoc env c d = do
  let declaration = definitionDeclaration d
      (args, result) = functionType (declarationType declaration)
      name = envFunctions env M.! c
      contextual = isContextual (envPlan env) (declarationId declaration)
  params <- forM (definitionArguments d) $ \b -> do
    local <- fresh (binderName b)
    pure (binderId b, local)
  types <- lift' (mapM (hsType env) args)
  resultType <- lift' (hsType env result)
  let scope = [(symbolsId, "symbols") | contextual] ++ params
  body <- case M.lookup (declarationId declaration) (typedIntrinsics (envPlan env)) of
    Just intrinsic -> do
      x <- intrinsicCall env intrinsic [(D.text l, binderType b) | ((_, l), b) <- zip params (definitionArguments d)]
      pure [D.text "P.pure P.$! " <> paren x]
    Nothing -> cstmt env scope (definitionBody d)
  pure (D.text ("-- " ++ idText (declarationId declaration)) <> D.hardline <>
    D.text (name ++ " :: " ++ intercalate " -> " (["LS.SymbolContext" | contextual] ++ types ++ ["P.IO " ++ resultType])) <> D.hardline <>
    D.text (unwords (name : ["symbols" | contextual] ++ ["!" ++ l | (_, l) <- params]) ++ " = do") <> nest body)

cstmt :: Env -> Scope -> Expr -> M [D.Doc]
cstmt env scope e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    local <- fresh (binderName binder)
    rest <- cstmt env ((binderId binder, local) : scope) body
    pure (s ++ [D.text ("let !" ++ local ++ " = ") <> x] ++ rest)
  If c a b -> do
    (s, x) <- cexpr env scope c
    yes <- cstmt env scope a
    no <- cstmt env scope b
    pure (s ++ [D.text "if " <> x <> D.nest 2 (D.hardline <> D.text "then do" <> nest yes <> D.hardline <> D.text "else do" <> nest no)])
  Helper Select [c, a, b] -> cstmt env scope (e { expressionNode = If c a b })
  Match value cases -> matchStatements env scope value cases
  ExternalCall i args | M.notMember i (typedIntrinsics (envPlan env)) -> do
    (s, call) <- callOf env scope i args
    pure (s ++ [call])
  Helper Unreachable _ -> pure [D.text "LSF.unreachable"]
  Perform (Operation ref "raise") [x] | isFail ref -> do
    (s, v) <- cexpr env scope x
    to <- helper "to" (expressionType x)
    pure (s ++ [D.text ("LSF.raise " ++ show (abilityKey ref) ++ " (" ++ to ++ " ") <> v <> D.text ")"])
  _ -> do
    (s, x) <- cexpr env scope e
    pure (s ++ [D.text "P.pure P.$! " <> paren x])

callOf :: Env -> Scope -> Id -> [Expr] -> M ([D.Doc], D.Doc)
callOf env scope i args = do
  c <- lift' (maybe (Left ("typed Haskell: untyped callee " ++ idText i)) Right (definitionClass (envPlan env) i))
  parts <- mapM (cexpr env scope) args
  let context = [D.text "symbols" | isContextual (envPlan env) i]
  pure (concatMap fst parts, D.joinWith (D.text " ") (D.text (envFunctions env M.! c) : context ++ map (paren . snd) parts))

-- | An expression's value: the lines that compute it, and a pure expression.
cexpr :: Env -> Scope -> Expr -> M ([D.Doc], D.Doc)
cexpr env scope e = case expressionNode e of
  Let {} -> viaStatements
  Match {} -> viaStatements
  If {} -> viaStatements
  Helper Select _ -> viaStatements
  Constant s -> constant s
  Local i -> do
    name <- lift' (maybe (Left ("typed Haskell: unbound local " ++ idText i)) Right (lookup i scope))
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
        (s, call) <- callOf env scope i args
        t <- fresh "result"
        pure (s ++ [D.text ("!" ++ t ++ " <- ") <> call], D.text t)
  ShortCircuit op a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    if null sb
      then pure (sa, paren (xa <> D.text (if op == And then " P.&& " else " P.|| ") <> xb))
      else do
        t <- fresh "logic"
        let rest = sb ++ [D.text "P.pure P.$! " <> paren xb]
        pure (sa ++ [D.text ("!" ++ t ++ " <- if ") <> xa <> D.nest 2 (D.hardline <>
          (if op == And then D.text "then do" <> nest rest <> D.hardline <> D.text "else P.pure P.False"
           else D.text "then P.pure P.True" <> D.hardline <> D.text "else do" <> nest rest))], D.text t)
  Unary Not a -> do
    (s, x) <- cexpr env scope a
    pure (s, D.text "(P.not " <> paren x <> D.text ")")
  Unary Negate a -> do
    (s, x) <- cexpr env scope a
    narrowTo (expressionType e) (s, D.text "(P.negate " <> integer (expressionType a) x <> D.text ")")
  Binary op (Structural _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    pure (sa ++ sb, paren (paren xa <> D.text (if op == Equal then " P.== " else " P./= ") <> paren xb))
  Binary op (Numeric _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    let same = expressionType a == expressionType b
        ia = integer (expressionType a) xa
        ib = integer (expressionType b) xb
        compare' symbol = pure (sa ++ sb, if same then paren (paren xa <> D.text symbol <> paren xb) else paren (ia <> D.text symbol <> ib))
        arithmetic r = narrowTo (expressionType e) (sa ++ sb, r)
    case op of
      Add -> arithmetic (paren (ia <> D.text " P.+ " <> ib))
      Subtract -> arithmetic (paren (ia <> D.text " P.- " <> ib))
      Multiply -> arithmetic (paren (ia <> D.text " P.* " <> ib))
      Quotient -> arithmetic (D.text "(LSF.quot' " <> ia <> D.text " " <> ib <> D.text ")")
      Remainder -> arithmetic (D.text "(LSF.rem' " <> ia <> D.text " " <> ib <> D.text ")")
      Power -> arithmetic (D.text "(LSF.power " <> ia <> D.text " " <> ib <> D.text ")")
      Equal -> compare' " P.== "
      NotEqual -> compare' " P./= "
      Less -> compare' " P.< "
      LessEqual -> compare' " P.<= "
      Greater -> compare' " P.> "
      GreaterEqual -> compare' " P.>= "
      _ -> lift' (Left ("typed Haskell: unsupported operator " ++ show op))
  Convert _ target value -> do
    (s, x) <- cexpr env scope value
    convert target (expressionType value) (s, x)
  Helper Compare [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    pure (sa ++ sb, D.text "(ordering_of (P.compare " <> paren xa <> D.text " " <> paren xb <> D.text "))")
  Helper Length [x] -> do
    (s, v) <- cexpr env scope x
    pure (s, case expressionType x of
      Constructor "Text" [] -> D.text "(P.toInteger (T.length " <> paren v <> D.text "))"
      Constructor "Bytes" [] -> D.text "(P.toInteger (B.length " <> paren v <> D.text "))"
      _ -> D.text "(P.toInteger (LSF.len " <> paren v <> D.text "))")
  Helper Unreachable _ -> do
    t <- fresh "never"
    pure ([D.text ("!" ++ t ++ " <- LSF.unreachable")], D.text t)
  Helper Checked _ -> pure ([], D.text "P.True")
  Helper StartsWith [a, b] -> flipped "T.isPrefixOf" a b
  Helper EndsWith [a, b] -> flipped "T.isSuffixOf" a b
  Helper TextContains [a, b] -> flipped "T.isInfixOf" a b
  Helper RegexMatches [a, b] -> call2 "LSF.regexMatches" a b
  AllElements value binder predicate -> do
    (sx, xs) <- cexpr env scope value
    t <- fresh "all"
    go <- fresh "every"
    item <- fresh (binderName binder)
    rest <- fresh "rest"
    (sp, p) <- cexpr env ((binderId binder, item) : scope) predicate
    let clauses = [ D.text (go ++ " LSF.Nil = P.pure P.True")
                  , D.text (go ++ " (LSF.Cons " ++ item ++ " " ++ rest ++ " _) = do") <> nest
                      (sp ++ [D.text "if " <> paren p <> D.text (" then " ++ go ++ " " ++ rest ++ " else P.pure P.False")]) ]
    pure (sx ++ [D.text "let " <> D.nest 4 (D.joinWith D.hardline clauses), D.text ("!" ++ t ++ " <- " ++ go ++ " ") <> paren xs], D.text t)
  Perform (Operation ref "raise") [x] | isFail ref -> do
    (s, v) <- cexpr env scope x
    to <- helper "to" (expressionType x)
    t <- fresh "never"
    pure (s ++ [D.text ("!" ++ t ++ " <- LSF.raise " ++ show (abilityKey ref) ++ " (" ++ to ++ " ") <> v <> D.text ")"], D.text t)
  Perform op args -> do
    parts <- mapM (cexpr env scope) args
    outs <- mapM (helper "tn" . expressionType) args
    fromNativeResult <- helper "fn" (expressionType e)
    (owner, ability) <- lift' (maybe (Left ("typed Haskell: unknown ability " ++ abilityKey (operationAbility op))) Right (findAbility (envUnits env) (operationAbility op)))
    r <- fresh "performed"
    t <- fresh "value"
    let record = abilityModule owner ++ "." ++ interfaceName ability
        operation = abilityModule owner ++ "." ++ fieldName ability (operationName op)
        call = D.joinWith (D.text " ") (D.text ("(" ++ operation ++ " (LS.handlerOf symbols " ++ show (abilityKey (operationAbility op)) ++ " :: " ++ record ++ "))") :
          [D.text ("(" ++ o ++ " ") <> paren x <> D.text ")" | (o, x) <- zip outs (map snd parts)])
    invocation <- case performedFailure (envUnits env) op of
      Just failing@(AbilityRef _ [failureType]) -> do
        native <- lift' (haskellDataType (envDeclarations env) failureType)
        to <- helper "to" failureType
        from <- helper "fn" failureType
        pure (D.text ("LSF.performing " ++ show (abilityKey failing) ++ " (\\(native :: " ++ native ++ ") -> " ++ to ++ " (" ++ from ++ " native)) ") <> paren call)
      _ -> pure call
    pure (concatMap fst parts ++ [D.text ("!" ++ r ++ " <- ") <> invocation, D.text ("let !" ++ t ++ " = " ++ fromNativeResult ++ " " ++ r)], D.text t)
  Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, _] <- expressionType e -> do
    t <- fresh "attempted"
    r <- fresh "outcome"
    from <- helper "from" failure
    lines' <- cstmt env scope body
    pure ([ D.text ("!" ++ r ++ " <- LSF.attempt " ++ show (abilityKey ref) ++ " (do") <> nest lines' <> D.text ")"
          , D.text ("let !" ++ t ++ " = case " ++ r ++ " of { P.Left failure -> LSF.L (" ++ from ++ " failure); P.Right value -> LSF.R value }") ], D.text t)
  Helper Append [a, b] -> case expressionType a of
    Constructor "Text" [] -> call2 "T.append" a b
    Constructor "Bytes" [] -> call2 "B.append" a b
    _ -> call2 "LSF.append" a b
  Helper Slice [x, from, to] -> do
    (sx, v) <- cexpr env scope x
    (si, i) <- cexpr env scope from
    (sj, j) <- cexpr env scope to
    let f = case expressionType x of
          Constructor "Text" [] -> "LSF.sliceText"
          Constructor "Bytes" [] -> "LSF.sliceBytes"
          _ -> "LSF.sliceList"
    pure (sx ++ si ++ sj, D.text ("(" ++ f ++ " ") <> paren v <> D.text " " <> integer (expressionType from) i <> D.text " " <> integer (expressionType to) j <> D.text ")")
  Helper At [x, k] -> do
    (sx, v) <- cexpr env scope x
    (sk, i) <- cexpr env scope k
    let f = if expressionType x == Constructor "Bytes" [] then "LSF.atBytes" else "LSF.atList"
    pure (sx ++ sk, D.text ("(" ++ f ++ " ") <> paren v <> D.text " " <> integer (expressionType k) i <> D.text ")")
  Helper Range [lo, hi] -> call2 "LSF.range" lo hi
  Helper Octets [b] -> one "LSF.octets" b
  Helper BytesOf [xs] -> one "LSF.bytesOf" xs
  Helper Utf8 [t] -> one "LSF.utf8" t
  Helper TextOf [n] -> one "LSF.textOf" n
  Helper Join [sep, parts] -> call2 "LSF.join" sep parts
  _ -> lift' (Left ("typed Haskell: unsupported expression " ++ take 80 (show (expressionNode e))))
  where
    one f a = do
      (s, x) <- cexpr env scope a
      pure (s, D.text ("(" ++ f ++ " ") <> paren x <> D.text ")")
    call2 f a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, D.text ("(" ++ f ++ " ") <> paren xa <> D.text " " <> paren xb <> D.text ")")
    flipped f a b = call2 f b a
    viaStatements = do
      t <- fresh "value"
      lines' <- cstmt env scope e
      pure ([D.text ("!" ++ t ++ " <- do") <> nest lines'], D.text t)

-- | An integral value as an Integer.
integer :: Type -> D.Doc -> D.Doc
integer ty x = if ty == Constructor "Integer" [] then paren x else D.text "(P.toInteger " <> paren x <> D.text ")"

boundsOf :: String -> Maybe (Integer, Integer)
boundsOf t = lookup t
  [ ("Int8", (-128, 127)), ("Int16", (-32768, 32767)), ("Int32", (-2147483648, 2147483647))
  , ("Int64", (-(2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1)), ("UInt8", (0, 255)), ("UInt16", (0, 65535))
  , ("UInt32", (0, 4294967295)), ("UInt64", (0, 2 ^ (64 :: Int) - 1)) ]

showInteger :: Integer -> String
showInteger n = if n < 0 then "(" ++ show n ++ ")" else show n

-- | An Integer result into the expression's type.
narrowTo :: Type -> ([D.Doc], D.Doc) -> M ([D.Doc], D.Doc)
narrowTo ty (s, x) = case ty of
  Constructor t [] | Just (lo, hi) <- boundsOf t, Just h <- lookup t scalarHs ->
    pure (s, D.text ("(LSF.narrow " ++ showInteger lo ++ " " ++ showInteger hi ++ " " ++ show t ++ " ") <> x <> D.text (" :: " ++ h ++ ")"))
  _ -> pure (s, x)

convert :: Type -> Type -> ([D.Doc], D.Doc) -> M ([D.Doc], D.Doc)
convert target source (s, x)
  | target == source = pure (s, x)
  | target == Constructor "Integer" [] = pure (s, integer source x)
  | Constructor t [] <- target, Just (lo, hi) <- boundsOf t, Just h <- lookup t scalarHs =
      let inside = case source of
            Constructor n [] | Just (slo, shi) <- boundsOf n -> slo >= lo && shi <= hi
            _ -> False
      in if inside then pure (s, D.text "(P.fromIntegral " <> paren x <> D.text (" :: " ++ h ++ ")"))
         else narrowTo target (s, integer source x)
  | otherwise = pure (s, x)

constant :: Scalar -> M ([D.Doc], D.Doc)
constant s = case s of
  SBool b -> pure ([], D.text (if b then "P.True" else "P.False"))
  SAbsent "Unit" -> pure ([], D.text "()")
  SInteger t n | Just h <- lookup t scalarHs -> pure ([], D.text ("(" ++ showInteger n ++ " :: " ++ h ++ ")"))
  SSequence "Text" units -> do
    name <- literal ("text " ++ show units) ("T.pack " ++ show (map toEnum units :: String))
    pure ([], D.text name)
  SSequence "Bytes" units -> do
    name <- literal ("bytes " ++ show units) ("B.pack " ++ show units)
    pure ([], D.text name)
  _ -> lift' (Left ("typed Haskell: unsupported constant " ++ show s))

construct :: Env -> Type -> Id -> [D.Doc] -> M D.Doc
construct env ty tag values = case (idText tag, values) of
  ("List::Nil", []) -> pure (D.text "LSF.Nil")
  ("List::Cons", [h, t]) -> pure (D.text "(LSF.cons " <> paren h <> D.text " " <> paren t <> D.text ")")
  ("Maybe::Nothing", []) -> pure (D.text "LSF.None")
  ("Maybe::Just", [x]) -> pure (D.text "(LSF.Some " <> paren x <> D.text ")")
  ("Either::Left", [x]) -> pure (D.text "(LSF.L " <> paren x <> D.text ")")
  ("Either::Right", [x]) -> pure (D.text "(LSF.R " <> paren x <> D.text ")")
  (_, [items]) | Just ("KeyVal", _) <- collectionArguments ty -> do
    (key, value) <- entryAccess env
    pure (D.text ("(LSF.keyValOf " ++ key ++ " " ++ value ++ " ") <> paren items <> D.text ")")
  (_, [items]) | Just ("Set", _) <- collectionArguments ty -> pure (D.text "(LSF.setOf " <> paren items <> D.text ")")
  _ -> case M.lookup tag (envConstructors env) of
    Just _ -> pure (D.text "(" <> D.joinWith (D.text " ") (D.text (envNames env M.! tag) : map paren values) <> D.text ")")
    Nothing -> lift' (Left ("typed Haskell: unknown constructor " ++ idText tag))

entryAccess :: Env -> M (String, String)
entryAccess env = case M.lookup (collectionsUnit ++ "::type::Entry") (envData env) of
  Just d | [c] <- dataConstructors d ->
    let con = envNames env M.! constructorId c in pure ("(\\(" ++ con ++ " k _) -> k)", "(\\(" ++ con ++ " _ v) -> v)")
  _ -> lift' (Left "typed Haskell: no typed Entry")

entryMaker :: Env -> M String
entryMaker env = case M.lookup (collectionsUnit ++ "::type::Entry") (envData env) of
  Just d | [c] <- dataConstructors d -> pure (envNames env M.! constructorId c)
  _ -> lift' (Left "typed Haskell: no typed Entry")

intrinsicCall :: Env -> Intrinsic -> [(D.Doc, Type)] -> M D.Doc
intrinsicCall env intrinsic args = case (intrinsic, args) of
  (KeyValOf, [(es, _)]) -> do
    (key, value) <- entryAccess env
    pure (D.text ("(LSF.keyValOf " ++ key ++ " " ++ value ++ " ") <> paren es <> D.text ")")
  (KeyValLookup, [(k, _), (m, _)]) -> apply "LSF.lookupMap" [k, m]
  (KeyValPut, [(k, _), (v, _), (m, _)]) -> apply "Map.insert" [k, v, m]
  (KeyValDelete, [(k, _), (m, _)]) -> apply "Map.delete" [k, m]
  (KeyValKeys, [(m, _)]) -> apply "LSF.keysList" [m]
  (KeyValValues, [(m, _)]) -> apply "LSF.valuesList" [m]
  (KeyValEntries, [(m, _)]) -> do
    entry <- entryMaker env
    apply ("LSF.entriesList " ++ entry) [m]
  (SetOf, [(xs, _)]) -> apply "LSF.setOf" [xs]
  (SetMember, [(x, _), (s, _)]) -> apply "Set.member" [x, s]
  (SetInsert, [(x, _), (s, _)]) -> apply "Set.insert" [x, s]
  (SetRemove, [(x, _), (s, _)]) -> apply "Set.delete" [x, s]
  (SetUnion, [(s, _), (t, _)]) -> apply "Set.union" [s, t]
  (SetIntersection, [(s, _), (t, _)]) -> apply "Set.intersection" [s, t]
  (SetDifference, [(s, _), (t, _)]) -> apply "Set.difference" [s, t]
  _ -> lift' (Left ("typed Haskell: bad intrinsic " ++ show intrinsic))
  where apply f xs = pure (D.text ("(" ++ f ++ " ") <> D.joinWith (D.text " ") (map paren xs) <> D.text ")")

matchStatements :: Env -> Scope -> Expr -> [MatchCase] -> M [D.Doc]
matchStatements env scope value cases = do
  let ty = expressionType value
      used c b = binderId b `elem` freeBinders (caseBody c)
      binders c = forM (caseBinders c) $ \b -> if used c b
        then do
          n <- fresh (binderName b)
          pure (Just (binderId b, n), n)
        else pure (Nothing, "_")
      alternative c pattern' = do
        bound <- binders c
        body <- cstmt env ([x | (Just x, _) <- bound] ++ scope) (caseBody c)
        pure (D.text (pattern' (map snd bound) ++ " -> do") <> nest body)
      unreachableArm = D.text "_ -> LSF.unreachable"
  (prelude, subject) <- case expressionNode value of
    Local i | Just name <- lookup i scope -> pure ([], D.text name)
    _ -> cexpr env scope value
  arms <- case ty of
    Constructor n _ | n `elem` ["Maybe", "Either", "List"] -> forM cases $ \c -> alternative c (\names -> case (idText (caseConstructor c), names) of
      ("Maybe::Nothing", _) -> "LSF.None"
      ("Maybe::Just", [x]) -> "LSF.Some " ++ x
      ("Either::Left", [x]) -> "LSF.L " ++ x
      ("Either::Right", [x]) -> "LSF.R " ++ x
      ("List::Nil", _) -> "LSF.Nil"
      ("List::Cons", [h, t]) -> "LSF.Cons " ++ h ++ " " ++ t ++ " _"
      _ -> "_")
    _ | Just (kind, _) <- collectionArguments ty, [c] <- cases -> do
          entry <- entryMaker env
          let items = if kind == "KeyVal" then "(LSF.entriesList " ++ entry ++ " subject)" else "(LSF.listOf (Set.toAscList subject))"
          bound <- binders c
          body <- cstmt env ([x | (Just x, _) <- bound] ++ scope) (caseBody c)
          let binding = case bound of
                [(_, n)] | n /= "_" -> [D.text ("let !" ++ n ++ " = " ++ items)]
                _ -> []
          pure [D.text "subject -> do" <> nest (binding ++ body)]
    Constructor n _ | Just d <- M.lookup n (envData env) -> do
      arms <- forM cases $ \c -> alternative c (\names -> unwords (envNames env M.! caseConstructor c : names))
      pure (arms ++ [unreachableArm | length cases < length (dataConstructors d)])
    _ -> lift' (Left ("typed Haskell: cannot match on " ++ show ty))
  pure (prelude ++ [D.text "case " <> paren subject <> D.text " of" <> nest arms])

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
  typed <- lift' (hsType env ty)
  native <- lift' (haskellDataType (envDeclarations env) ty)
  let parenthesized t = if ' ' `elem` t && take 1 t /= "(" && take 1 t /= "[" then "(" ++ t ++ ")" else t
      signature from to = D.text ("-- " ++ kind ++ " " ++ show ty) <> D.hardline <> D.text (name ++ " :: " ++ from ++ " -> " ++ to)
      fn from to arg body = signature from to <> D.hardline <> D.text (name ++ " " ++ arg ++ " = ") <> body
  case kind of
    "to" -> fn typed "Scalar" "x" <$> toValue env ty
    "from" -> fn "Scalar" typed "v" <$> fromValue env ty
    "tn" -> fn typed (parenthesized native) "x" <$> toNative env ty
    _ -> fn (parenthesized native) typed "n" <$> fromNative env ty

dataOf :: Env -> Type -> Maybe (DataDeclaration, [Type])
dataOf env ty = case ty of
  Constructor n args | Just d <- M.lookup n (envData env) -> Just (d, [t | TypeArgument t <- args])
  _ -> Nothing

alternatives :: [D.Doc] -> D.Doc
alternatives arms = D.nest 2 (D.hardline <> D.joinWith D.hardline arms)

toValue :: Env -> Type -> M D.Doc
toValue env ty = case ty of
  Constructor "Bool" [] -> pure (D.text "SBool x")
  Constructor "Unit" [] -> pure (D.text "SAbsent \"Unit\"")
  Constructor "Text" [] -> pure (D.text "LSF.textScalar x")
  Constructor "Bytes" [] -> pure (D.text "LSF.bytesScalar x")
  Constructor n [] | isJust (boundsOf n) || n == "Integer" -> pure (D.text ("SInteger " ++ show n ++ " (P.toInteger x)"))
  Constructor "List" [TypeArgument a] -> (\f -> D.text ("SList (P.map " ++ f ++ " (LSF.items x))")) <$> helper "to" a
  Constructor "Maybe" [TypeArgument a] -> do
    f <- helper "to" a
    pure (D.text ("case x of { LSF.None -> SData \"Maybe::Nothing\" []; LSF.Some v -> SData \"Maybe::Just\" [" ++ f ++ " v] }"))
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "to" a
    fr <- helper "to" b
    pure (D.text ("case x of { LSF.L v -> SData \"Either::Left\" [" ++ fl ++ " v]; LSF.R v -> SData \"Either::Right\" [" ++ fr ++ " v] }"))
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "to" k
        fv <- helper "to" v
        pure (D.text ("SData " ++ show (collectionsUnit ++ "::type::KeyVal::KeyValEntries") ++ " [SList [SData " ++ show (collectionsUnit ++ "::type::Entry::Entry") ++
          " [" ++ fk ++ " k, " ++ fv ++ " v] | (k, v) <- Map.toAscList x]]"))
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- helper "to" a
        pure (D.text ("SData " ++ show (collectionsUnit ++ "::type::Set::SetItems") ++ " [SList (P.map " ++ f ++ " (Set.toAscList x))]"))
  _ | Just (d, targs) <- dataOf env ty -> do
        arms <- forM (dataConstructors d) $ \c -> do
          encoders <- mapM (helper "to") (fieldTypes d targs c)
          let names = ["f" ++ show k | k <- [0 .. length encoders - 1]]
          pure (D.text (unwords (envNames env M.! constructorId c : names) ++ " -> SData " ++ show (idText (constructorId c)) ++ " [" ++
            intercalate ", " [e ++ " " ++ n | (e, n) <- zip encoders names] ++ "]"))
        pure (D.text "case x of" <> alternatives arms)
  _ -> lift' (Left ("typed Haskell: no conversion for " ++ show ty))

fromValue :: Env -> Type -> M D.Doc
fromValue env ty = case ty of
  Constructor "Bool" [] -> pure (D.text "LSF.scalarBool v")
  Constructor "Unit" [] -> pure (D.text "()")
  Constructor "Text" [] -> pure (D.text "LSF.scalarText v")
  Constructor "Bytes" [] -> pure (D.text "LSF.scalarBytes v")
  Constructor n [] | isJust (boundsOf n) || n == "Integer" -> pure (D.text "P.fromInteger (LSF.scalarInteger v)")
  Constructor "List" [TypeArgument a] -> (\f -> D.text ("LSF.listOf (P.map " ++ f ++ " (LSF.scalarItems v))")) <$> helper "from" a
  Constructor "Maybe" [TypeArgument a] -> do
    f <- helper "from" a
    pure (D.text ("case LSF.scalarData v of { (\"Maybe::Just\", [x]) -> LSF.Some (" ++ f ++ " x); _ -> LSF.None }"))
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "from" a
    fr <- helper "from" b
    pure (D.text ("case LSF.scalarData v of { (\"Either::Right\", [x]) -> LSF.R (" ++ fr ++ " x); (_, [x]) -> LSF.L (" ++ fl ++ " x); _ -> P.error \"expected Either\" }"))
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "from" k
        fv <- helper "from" v
        pure (D.text ("Map.fromList [(" ++ fk ++ " k, " ++ fv ++ " x) | SData _ [k, x] <- LSF.scalarItems (P.head (P.snd (LSF.scalarData v)))]"))
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- helper "from" a
        pure (D.text ("Set.fromList (P.map " ++ f ++ " (LSF.scalarItems (P.head (P.snd (LSF.scalarData v)))))"))
  _ | Just (d, targs) <- dataOf env ty -> do
        arms <- forM (dataConstructors d) $ \c -> do
          decoders <- mapM (helper "from") (fieldTypes d targs c)
          let names = ["f" ++ show k | k <- [0 .. length decoders - 1]]
          pure (D.text ("(" ++ show (idText (constructorId c)) ++ ", [" ++ intercalate ", " names ++ "]) -> " ++
            unwords (envNames env M.! constructorId c : ["(" ++ dec ++ " " ++ n ++ ")" | (dec, n) <- zip decoders names])))
        pure (D.text "case LSF.scalarData v of" <> alternatives (arms ++ [D.text ("(tag, _) -> P.error (\"expected " ++ dataName d ++ ", found \" P.++ tag)")]))
  _ -> lift' (Left ("typed Haskell: no conversion for " ++ show ty))

toNative :: Env -> Type -> M D.Doc
toNative env ty = case ty of
  Constructor n [] | n `elem` scalarTypes -> pure (D.text "x")
  Constructor "List" [TypeArgument a] -> (\f -> D.text ("P.map " ++ f ++ " (LSF.items x)")) <$> helper "tn" a
  Constructor "Maybe" [TypeArgument a] -> (\f -> D.text ("case x of { LSF.None -> P.Nothing; LSF.Some v -> P.Just (" ++ f ++ " v) }")) <$> helper "tn" a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "tn" a
    fr <- helper "tn" b
    pure (D.text ("case x of { LSF.L v -> P.Left (" ++ fl ++ " v); LSF.R v -> P.Right (" ++ fr ++ " v) }"))
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "tn" k
        fv <- helper "tn" v
        pure (D.text ("Map.fromList [(" ++ fk ++ " k, " ++ fv ++ " v) | (k, v) <- Map.toAscList x]"))
    | Just ("Set", [a]) <- collectionArguments ty -> (\f -> D.text ("Set.fromList (P.map " ++ f ++ " (Set.toAscList x))")) <$> helper "tn" a
  _ | Just (d, targs) <- dataOf env ty -> do
        arms <- forM (dataConstructors d) $ \c -> do
          converters <- mapM (helper "tn") (fieldTypes d targs c)
          let names = ["f" ++ show k | k <- [0 .. length converters - 1]]
          pure (D.text (unwords (envNames env M.! constructorId c : names) ++ " -> " ++
            unwords (("Data." ++ envNative env M.! constructorId c) : ["(" ++ cv ++ " " ++ n ++ ")" | (cv, n) <- zip converters names])))
        pure (D.text "case x of" <> alternatives arms)
  _ -> lift' (Left ("typed Haskell: no native conversion for " ++ show ty))

fromNative :: Env -> Type -> M D.Doc
fromNative env ty = case ty of
  Constructor n [] | n `elem` scalarTypes -> pure (D.text "n")
  Constructor "List" [TypeArgument a] -> (\f -> D.text ("LSF.listOf (P.map " ++ f ++ " n)")) <$> helper "fn" a
  Constructor "Maybe" [TypeArgument a] -> (\f -> D.text ("case n of { P.Nothing -> LSF.None; P.Just v -> LSF.Some (" ++ f ++ " v) }")) <$> helper "fn" a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "fn" a
    fr <- helper "fn" b
    pure (D.text ("case n of { P.Left v -> LSF.L (" ++ fl ++ " v); P.Right v -> LSF.R (" ++ fr ++ " v) }"))
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "fn" k
        fv <- helper "fn" v
        pure (D.text ("Map.fromList [(" ++ fk ++ " k, " ++ fv ++ " v) | (k, v) <- Map.toAscList n]"))
    | Just ("Set", [a]) <- collectionArguments ty -> (\f -> D.text ("Set.fromList (P.map " ++ f ++ " (Set.toAscList n))")) <$> helper "fn" a
  _ | Just (d, targs) <- dataOf env ty -> do
        arms <- forM (dataConstructors d) $ \c -> do
          converters <- mapM (helper "fn") (fieldTypes d targs c)
          let names = ["f" ++ show k | k <- [0 .. length converters - 1]]
          pure (D.text (unwords (("Data." ++ envNative env M.! constructorId c) : names) ++ " -> " ++
            unwords (envNames env M.! constructorId c : ["(" ++ cv ++ " " ++ n ++ ")" | (cv, n) <- zip converters names])))
        pure (D.text "case n of" <> alternatives arms)
  _ -> lift' (Left ("typed Haskell: no native conversion for " ++ show ty))
