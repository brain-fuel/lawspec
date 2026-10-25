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
--
-- Functions are named after their definitions, locals after the source's
-- binders, conversions after their types (toPayment, fromNativeListInt32),
-- and the module is laid out as ormolu lays it out (LawSpec.Code.Haskell).
-- ref:DEC-typed-native-definitions ref:DEC-readable-output-default
module LawSpec.Typed.Haskell (HaskellTyped(..), emitHaskellTyped) where

import Control.Monad (forM, forM_)
import Control.Monad.State.Strict
import Data.Binary (Binary)
import GHC.Generics (Generic)
import System.IO.Unsafe (unsafePerformIO)
import LawSpec.Memo (Table, newPersistentTable, memoized)
import qualified LawSpec.Dependencies as Identity
import qualified LawSpec.Typed.EmissionContext as Context
import Data.List (intercalate, sortOn, nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, listToMaybe, mapMaybe)
import qualified Data.Set as S
import LawSpec.Collections (collectionsUnit)
import LawSpec.Core
import LawSpec.CorePersist ()
import LawSpec.Scalar
import LawSpec.Typed.Plan
import LawSpec.HaskellData (namesFor, haskellDataType, moduleImports)
import LawSpec.AbilityNames (interfaceName, fieldName)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Code.Haskell as H
import LawSpec.Code.Haskell (Stmt(Bind, Run), call, var, string, integer, lambda, operator)
import LawSpec.Naming (Scope, claim, claimAll, scopeWith, nativeIdentifier, NameKind(..), readableDefinitionName, nameWords, sourceDefinitionName)
import LawSpec.SourceLink (labelled, sourceLink, generatedHeader, unitSourceFile)
import LawSpec.TargetNames (targetKeywords)

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
  , envNames :: M.Map Id String          -- type and constructor names, as LawSpecData's
  , envUnits :: [Unit]
  , envDeclarations :: [DataDeclaration]
  , envIdentity :: Identity.Graph
  , envHelperNames :: M.Map (String,String) String
  , envLiteralNames :: M.Map String String
  }

-- | The function being written's locals, the module's names, the
-- conversions wanted and their names, and the literals made once.
data St = St
  { stLocals :: Scope
  , stModule :: Scope
  , stHelpers :: M.Map String Type
  , stWanted :: S.Set (String, String)
  , stHelperNames :: M.Map (String, String) String
  , stLiterals :: M.Map String (String, H.Expr)
  } deriving (Show, Generic)

instance Binary St

type M = StateT St (Either String)

lift' :: Either String a -> M a
lift' = lift

-- | A local named after a source binder or what it holds, distinct in its
-- function.
fresh :: String -> M String
fresh base = do
  s <- get
  let (chosen, scope) = claim (stLocals s) (H.localName base)
  put s { stLocals = scope }
  pure chosen

-- | A function's locals start afresh, apart from the module's names.
enterFunction :: () -> M ()
enterFunction _ = modify (\s -> s { stLocals = stModule s })

-- | Names a function's locals must not shadow.
moduleReserved :: [String]
moduleReserved = targetKeywords "haskell" ++ words "symbols orderingOf"

-- | A conversion of a type, named after it: toPayment, fromListInt32,
-- toNativeInt32, fromNativeMaybeText.
helper :: String -> Type -> M String
helper kind ty = do
  let key = show ty
  st <- get
  case M.lookup (kind,key) (stHelperNames st) of
    Nothing -> lift' (Left ("typed Haskell: unplanned helper " ++ kind ++ " " ++ key))
    Just name -> do
      put st { stHelpers = M.insert key ty (stHelpers st), stWanted = S.insert (kind,key) (stWanted st) }
      pure name

helperBase :: String -> Type -> String
helperBase kind ty = H.camelName (kindWord kind : typeNameWords ty)
  where
    kindWord k = case k of
      "to" -> "to"
      "from" -> "from"
      "tn" -> "toNative"
      _ -> "fromNative"

-- | A type's words: its constructors' last segments and its arguments'.
typeNameWords :: Type -> [String]
typeNameWords ty = case ty of
  Constructor n args -> nameWords (lastSegment n) ++ concat [typeNameWords t | TypeArgument t <- args]
  TypeVariable v -> nameWords (idText v)
  Arrow a b -> typeNameWords a ++ ["to"] ++ typeNameWords b
  where
    lastSegment s = case break (== ':') s of
      (whole, []) -> whole
      (_, rest) -> lastSegment (dropWhile (== ':') rest)

-- | A literal Text or ByteString, made once and named after what it holds.
literal :: Env -> String -> H.Expr -> M String
literal env key definition = do
  st <- get
  case M.lookup key (stLiterals st) of
    Just (name,_) -> pure name
    Nothing -> case M.lookup key (envLiteralNames env) of
      Nothing -> lift' (Left "typed Haskell: unplanned sequence literal")
      Just name -> do
        put st { stLiterals = M.insert key (name,definition) (stLiterals st) }
        pure name

sequenceLiterals :: Expr -> [Scalar]
sequenceLiterals expression = case expressionNode expression of
  Constant value@(SSequence name _) | name `elem` ["Text","Bytes"] -> [value]
  _ -> concatMap sequenceLiterals (children expression)

literalKey :: Scalar -> String
literalKey (SSequence name units) = name ++ " " ++ show units
literalKey _ = error "typed Haskell: not a sequence literal"

literalAllocation :: Identity.Graph -> [String] -> [Scalar] -> M.Map String String
literalAllocation graph reserved values = M.fromList [(literalKey value,chosen value) | value <- nub values]
  where
    base (SSequence "Text" units) = let words' = nameWords (map toEnum units)
      in if null words' then "emptyText" else H.camelName ("text" : take 3 words')
    base _ = "bytes"
    suffix value = Identity.semanticKey graph "typed-haskell-literal" value
    short value = base value ++ "_" ++ take 12 (suffix value)
    chosen value
      | length [other | other <- nub values,short other == short value] == 1,short value `notElem` reserved = short value
      | otherwise = base value ++ "_" ++ suffix value

operationTypes :: [Unit] -> Expr -> [Type]
operationTypes units expression = case expressionNode expression of
  Perform operation arguments ->
    [failure | Just (AbilityRef _ [failure]) <- [performedFailure units operation]] ++ concatMap (operationTypes units) arguments
  _ -> concatMap (operationTypes units) (children expression)

emitHaskellTyped :: [DataDeclaration] -> [Unit] -> Either String HaskellTyped
emitHaskellTyped declarations units = do
  let plan = typedPlanPerforming scalarTypes declarations units
      datas = typedData plan
      -- Each typed function is named after its definition.
      (functionNames, moduleScope) = claimAll (scopeWith moduleReserved)
        [ nativeIdentifier "haskell" FunctionName (readableDefinitionName (declarationName (definitionDeclaration d))
            (fst (functionType (declarationType (definitionDeclaration d)))))
        | (_, d) <- typedRepresentatives plan ]
      functions = M.fromList (zip (map fst (typedRepresentatives plan)) functionNames)
  natives <- namesFor declarations
  let env = Env plan (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions
        (M.union (M.fromList natives) (fallbackNames datas)) units declarations graph helperNames literalNames
      typedHandlers = [ h | u <- units, h <- unitHandlers u, isTypedHandler plan h ]
      handlerTypes = [ t | h <- typedHandlers, ref <- handlerAbilities h, Just (_, a) <- [findAbility units ref]
                         , (_, ty) <- abilityOperations a, let (args, result) = functionType ty, t <- result : args ] ++
                     [ t | h <- typedHandlers, Just (t, _) <- [handlerState h] ]
      boundary = concat [ let (args, result) = functionType (declarationType (definitionDeclaration d)) in result : args
                        | d <- M.elems (typedDefinitions plan) ]
      stateful = [h | h <- typedHandlers, Just _ <- [handlerState h]]
      (startNames, startScope) = claimAll moduleScope [nativeIdentifier "haskell" FunctionName ("start " ++ handlerName h) | h <- stateful]
      starts = [ (handlerId h, name, ty, start) | (h, name) <- zip stateful startNames, Just (ty, start) <- [handlerState h] ]
      graph = Identity.dependencyGraph declarations units
      definitionTypes definition = Context.definitionTypes definition ++ operationTypes units (definitionBody definition)
      allTypes = Context.typeClosure (envData env) (boundary ++ handlerTypes ++
        concatMap (definitionTypes . snd) (typedRepresentatives plan) ++ concatMap (Context.expressionTypes . fourth) starts)
      fourth (_,_,_,value) = value
      helperNames = Context.helperAllocation graph (functionNames ++ startNames ++ moduleReserved) helperBase helperKinds allTypes
      literalNames = literalAllocation graph (functionNames ++ startNames ++ M.elems helperNames ++ moduleReserved)
        (concatMap (sequenceLiterals . definitionBody . snd) (typedRepresentatives plan) ++ concatMap (sequenceLiterals . fourth) starts)
      allocatedScope = scopeWith (functionNames ++ startNames ++ M.elems helperNames ++ M.elems literalNames ++ moduleReserved)
      abilityModules = nub [ abilityModule u | d <- M.elems (typedDefinitions plan), op <- performedIn (definitionBody d)
                           , Just (u, _) <- [findAbility units (operationAbility op)] ]
  dataDocs <- mapM (memoData env) datas
  ((functionDocs, startDocs, helperDocs, literalDocs), final) <- flip runStateT (St allocatedScope allocatedScope M.empty S.empty helperNames M.empty) $ do
    fs <- mapM (\(c, d) -> memoFunction env c d) (typedRepresentatives plan)
    ss <- forM starts $ \(_, name, ty, start) -> do
      enterFunction ()
      body <- cstmt env [(symbolsId, "symbols")] start
      t <- lift' (hsType env ty)
      pure (D.joinWith D.hardline [H.signature name ["LS.SymbolContext", "P.IO " ++ t], H.declaration (name ++ " symbols") (H.Do body)])
    forM_ boundary $ \t -> helper "to" t >> helper "from" t
    forM_ handlerTypes $ \t -> helper "tn" t >> helper "fn" t
    hs <- helpers env
    ls <- gets (M.elems . stLiterals)
    pure (fs, ss, hs, [H.declaration name definition | (name, definition) <- ls])
  let body = concat dataDocs ++ orderingHelper env ++ functionDocs ++ startDocs ++ helperDocs ++ literalDocs
      rendered = D.render D.Compact (D.joinWith D.hardline body)
      sourceFile = listToMaybe (mapMaybe unitSourceFile units)
      header = map D.text
        ([ "-- " ++ generatedHeader sourceFile
         , "-- Typed checked definitions over LawSpecFast's values; see"
         , "-- docs/how-to/embed-a-generated-model.md." ] ++
         [ "{-# LANGUAGE " ++ e ++ " #-}" | e <- ["BangPatterns"] ++ (if any (null . dataConstructors) datas then ["EmptyDataDecls", "EmptyDataDeriving"] else []) ++ ["ScopedTypeVariables"] ] ++
         [ ""
         , "module LawSpecTyped where" ] ++
         (let imports = moduleImports rendered
                ([ ("Prelude", Just "P", Nothing) ] ++
                 [ (m, Just a, Nothing) | (m, a) <- [("Data.Int", "I"), ("Data.Word", "W"), ("Data.Text", "T"), ("Data.ByteString", "B"),
                     ("Data.Map.Strict", "Map"), ("Data.Set", "Set"), ("LawSpecRuntime", "LS"), ("LawSpecFast", "LSF"), ("LawSpecData", "Data")] ] ++
                 [ ("LawSpecRuntime", Nothing, Just ["Scalar (..)"]) ] ++
                 [ (m, Just m, Nothing) | m <- abilityModules ])
          in if null imports then [] else "" : imports))
      source = D.render (H.layout False) (D.joinWith D.hardline header <> mconcat [D.hardline <> D.hardline <> d | d <- body]) ++ "\n"
      pairName = case [c | d <- datas, idText (dataId d) == collectionsUnit ++ "::type::Pair", c <- dataConstructors d] of
        c : _ -> "Typed." ++ envNames env M.! constructorId c
        [] -> "Typed.Pair"
      helperNameOf kind ty = fromMaybe ("missing" ++ kind) (M.lookup (kind, show ty) (stHelperNames final))
  pure HaskellTyped
    { hsTypedModule = source
    , hsTypedFunction = \i -> definitionClass plan i >>= (`M.lookup` functions)
    , hsTypedFrom = helperNameOf "from"
    , hsTypedTo = helperNameOf "to"
    , hsTypedFromNative = helperNameOf "fn"
    , hsTypedToNative = helperNameOf "tn"
    , hsTypedStart = \h -> case [n | (i, n, _, _) <- starts, i == h] of
        n : _ -> Just n
        [] -> Nothing
    , hsTypedType = hsTypeWith "Typed." env
    , hsTypedPair = pairName
    , hsTypedPlan = plan }
  where
    performedIn e = case expressionNode e of
      Perform op args | operationName op /= "raise" || not (isFail (operationAbility op)) -> op : concatMap performedIn args
      _ -> concatMap performedIn (children e)

-- | Names for typed data the program's names do not cover (instances made
-- for typing), distinct from the program's.
fallbackNames :: [DataDeclaration] -> M.Map Id String
fallbackNames datas = M.fromList (concat [ (dataId d, base) : [(constructorId c, base ++ concatMap capital' (nameWords (constructorName c))) | c <- dataConstructors d]
  | (d, base) <- zip datas (fst (claimAll (scopeWith []) [concatMap capital' (nameWords (dataName d)) ++ "Typed" | d <- datas])) ])
  where capital' (c : cs) = toEnum (fromEnum c - (if c >= 'a' && c <= 'z' then 32 else 0)) : cs
        capital' [] = []

abilityModule :: Unit -> String
abilityModule u = intercalate "." ("LawSpecAbilities" : map (concatMap capitalize . split '_') (split '.' (idText (unitId u))))
  where
    split c s = case break (== c) s of
      (a, []) -> [a]
      (a, _ : rest) -> a : split c rest
    capitalize (c : cs) = toEnum (fromEnum c - (if c >= 'a' && c <= 'z' then 32 else 0)) : cs
    capitalize [] = []

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

-- | A strict data type, its constructors in the portable order, one per
-- line, as ormolu lays out a declaration written over several lines.
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
  pure [D.text ("-- " ++ labelled name (sourceLink (dataOrigin d) >>= \l -> if take 1 l == "<" then Nothing else Just l)) <> D.hardline <>
    D.text ("data " ++ unwords (name : map snd parameters)) <> D.nest 2
      ((if null variants then mempty else D.hardline <> D.text "= " <>
          D.joinWith (D.hardline <> D.text "| ") (map D.text variants)) <>
        D.hardline <> D.text "deriving (P.Eq, P.Ord)")]
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
    let con name = case [envNames env M.! constructorId c | c <- dataConstructors d, constructorName c == name] of
          n : _ -> n
          [] -> "P.undefined"
    in [D.joinWith D.hardline
         [ H.signature "orderingOf" ["P.Ordering", envNames env M.! dataId d]
         , H.declaration "orderingOf o" (H.Case (var "o") [("P.LT", var (con "Less")), ("P.EQ", var (con "Equal")), ("P.GT", var (con "Greater"))]) ]]

-- Statements: the lines of a do-block whose last line gives its value.

type Scope' = [(Id, String)]

symbolsId :: Id
symbolsId = Id "lawspec::symbols"

-- | P.pure P.$! x: a statement's value, evaluated.
returned :: H.Expr -> Stmt
returned x = Run (operator "P.$!" [var "P.pure", x])

-- | A binding evaluated where it is written.
strictLet :: String -> H.Expr -> Stmt
strictLet name = H.Let ("!" ++ name)

strictBind :: String -> H.Expr -> Stmt
strictBind name = Bind ("!" ++ name)

helperKinds :: [String]
helperKinds = ["to","from","tn","fn"]

functionTable :: Table (Either String (D.Doc,St))
functionTable = unsafePerformIO (newPersistentTable "typed-haskell-function" (8 * 1024 * 1024) (length . show))
{-# NOINLINE functionTable #-}

dataTable :: Table (Either String [D.Doc])
dataTable = unsafePerformIO (newPersistentTable "typed-haskell-data" (4 * 1024 * 1024) (length . show))
{-# NOINLINE dataTable #-}

nativeContext :: Env -> [Type] -> [(Id,Maybe String)]
nativeContext env types = [(identity,M.lookup identity (envNames env)) |
  Constructor name _ <- types, Just declaration <- [M.lookup name (envData env)],
  identity <- dataId declaration : map constructorId (dataConstructors declaration)]

memoData :: Env -> DataDeclaration -> Either String [D.Doc]
memoData env declaration = memoized dataTable key (dataDoc env declaration)
  where
    types = Context.typeClosure (envData env) [Constructor (idText (dataId declaration)) []]
    key = Identity.fullKey (envIdentity env) ("typed-haskell-data:" ++ show (nativeContext env types)) declaration

memoFunction :: Env -> Int -> Definition -> M D.Doc
memoFunction env classification definition = do
  before <- get
  let calls = Context.calledFunctions (envPlan env) (envFunctions env) classification definition
      types = Context.typeClosure (envData env) (Context.definitionTypes definition ++ operationTypes (envUnits env) (definitionBody definition))
      selectedHelpers = [((kind,show ty),name) | ty <- types, kind <- helperKinds,
        Just name <- [M.lookup (kind,show ty) (envHelperNames env)]]
      selectedLiterals = [(literalKey value,name) | value <- nub (sequenceLiterals (definitionBody definition)),
        Just name <- [M.lookup (literalKey value) (envLiteralNames env)]]
      names = scopeWith (moduleReserved ++ [name | (name,_,_,_) <- calls] ++ map snd selectedHelpers ++ map snd selectedLiterals)
      own = St names names M.empty S.empty (M.fromList selectedHelpers) M.empty
      key = Identity.fullKey (envIdentity env) ("typed-haskell:" ++ show (calls,selectedHelpers,selectedLiterals,nativeContext env types)) definition
  (document,requested) <- lift' (memoized functionTable key (runStateT (functionDoc env classification definition) own))
  put before { stHelpers = M.union (stHelpers requested) (stHelpers before),
               stWanted = S.union (stWanted requested) (stWanted before),
               stLiterals = M.union (stLiterals requested) (stLiterals before) }
  pure document

functionDoc :: Env -> Int -> Definition -> M D.Doc
functionDoc env c d = do
  let declaration = definitionDeclaration d
      (args, result) = functionType (declarationType declaration)
      name = envFunctions env M.! c
      contextual = isContextual (envPlan env) (declarationId declaration)
  enterFunction ()
  params <- forM (definitionArguments d) $ \b -> do
    local <- fresh (binderName b)
    pure (binderId b, local)
  types <- lift' (mapM (hsType env) args)
  resultType <- lift' (hsType env result)
  let scope = [(symbolsId, "symbols") | contextual] ++ params
  body <- case M.lookup (declarationId declaration) (typedIntrinsics (envPlan env)) of
    Just intrinsic -> do
      x <- intrinsicCall env intrinsic [(var l, binderType b) | ((_, l), b) <- zip params (definitionArguments d)]
      pure [returned x]
    Nothing -> cstmt env scope (definitionBody d)
  pure (D.joinWith D.hardline
    [ H.comment [labelled (sourceDefinitionName (declarationName declaration)) (sourceLink (declarationOrigin declaration))]
    , H.signature name (["LS.SymbolContext" | contextual] ++ types ++ ["P.IO " ++ resultType])
    , H.declaration (unwords (name : ["symbols" | contextual] ++ ["!" ++ l | (_, l) <- params])) (H.Do body) ])

cstmt :: Env -> Scope' -> Expr -> M [Stmt]
cstmt env scope e = case expressionNode e of
  Let binder value body -> do
    (s, x) <- cexpr env scope value
    local <- fresh (binderName binder)
    rest <- cstmt env ((binderId binder, local) : scope) body
    pure (s ++ [strictLet local x] ++ rest)
  If c a b -> do
    (s, x) <- cexpr env scope c
    yes <- cstmt env scope a
    no <- cstmt env scope b
    pure (s ++ [Run (H.If x (H.Do yes) (H.Do no))])
  Helper Select [c, a, b] -> cstmt env scope (e { expressionNode = If c a b })
  Match value cases -> matchStatements env scope value cases
  ExternalCall i args | M.notMember i (typedIntrinsics (envPlan env)) -> do
    (s, invocation) <- callOf env scope i args
    pure (s ++ [Run invocation])
  Helper Unreachable _ -> pure [Run (var "LSF.unreachable")]
  Perform (Operation ref "raise") [x] | isFail ref -> do
    (s, v) <- cexpr env scope x
    to <- helper "to" (expressionType x)
    pure (s ++ [Run (call "LSF.raise" [string (abilityKey ref), call to [v]])])
  _ -> do
    (s, x) <- cexpr env scope e
    pure (s ++ [returned x])

callOf :: Env -> Scope' -> Id -> [Expr] -> M ([Stmt], H.Expr)
callOf env scope i args = do
  c <- lift' (maybe (Left ("typed Haskell: untyped callee " ++ idText i)) Right (definitionClass (envPlan env) i))
  parts <- mapM (cexpr env scope) args
  let context = [var "symbols" | isContextual (envPlan env) i]
  pure (concatMap fst parts, call (envFunctions env M.! c) (context ++ map snd parts))

-- | An expression's value: the lines that compute it, and a pure expression.
cexpr :: Env -> Scope' -> Expr -> M ([Stmt], H.Expr)
cexpr env scope e = case expressionNode e of
  Let {} -> viaStatements
  Match {} -> viaStatements
  If {} -> viaStatements
  Helper Select _ -> viaStatements
  Constant s -> constant env s
  Local i -> do
    name <- lift' (maybe (Left ("typed Haskell: unbound local " ++ idText i)) Right (lookup i scope))
    pure ([], var name)
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
        (s, invocation) <- callOf env scope i args
        t <- fresh "result"
        pure (s ++ [strictBind t invocation], var t)
  ShortCircuit op a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    if null sb
      then pure (sa, operator (if op == And then "P.&&" else "P.||") [xa, xb])
      else do
        t <- fresh "logic"
        let rest = H.Do (sb ++ [returned xb])
        pure (sa ++ [strictBind t (if op == And then H.If xa rest (call "P.pure" [var "P.False"])
                                   else H.If xa (call "P.pure" [var "P.True"]) rest)], var t)
  Unary Not a -> do
    (s, x) <- cexpr env scope a
    pure (s, call "P.not" [x])
  Unary Negate a -> do
    (s, x) <- cexpr env scope a
    narrowTo (expressionType e) (s, call "P.negate" [integral (expressionType a) x])
  Binary op (Structural _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    pure (sa ++ sb, operator (if op == Equal then "P.==" else "P./=") [xa, xb])
  Binary op (Numeric _) a b -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    let same = expressionType a == expressionType b
        ia = integral (expressionType a) xa
        ib = integral (expressionType b) xb
        compare' symbol = pure (sa ++ sb, if same then operator symbol [xa, xb] else operator symbol [ia, ib])
        arithmetic r = narrowTo (expressionType e) (sa ++ sb, r)
    case op of
      Add -> arithmetic (operator "P.+" [ia, ib])
      Subtract -> arithmetic (operator "P.-" [ia, ib])
      Multiply -> arithmetic (operator "P.*" [ia, ib])
      Quotient -> arithmetic (call "LSF.quot'" [ia, ib])
      Remainder -> arithmetic (call "LSF.rem'" [ia, ib])
      Power -> arithmetic (call "LSF.power" [ia, ib])
      Equal -> compare' "P.=="
      NotEqual -> compare' "P./="
      Less -> compare' "P.<"
      LessEqual -> compare' "P.<="
      Greater -> compare' "P.>"
      GreaterEqual -> compare' "P.>="
      _ -> lift' (Left ("typed Haskell: unsupported operator " ++ show op))
  Convert _ target value -> do
    (s, x) <- cexpr env scope value
    convert target (expressionType value) (s, x)
  Helper Compare [a, b] -> do
    (sa, xa) <- cexpr env scope a
    (sb, xb) <- cexpr env scope b
    pure (sa ++ sb, call "orderingOf" [call "P.compare" [xa, xb]])
  Helper Length [x] -> do
    (s, v) <- cexpr env scope x
    pure (s, call "P.toInteger" [case expressionType x of
      Constructor "Text" [] -> call "T.length" [v]
      Constructor "Bytes" [] -> call "B.length" [v]
      _ -> call "LSF.len" [v]])
  Helper Unreachable _ -> do
    t <- fresh "never"
    pure ([strictBind t (var "LSF.unreachable")], var t)
  Helper Checked _ -> pure ([], var "P.True")
  Helper StartsWith [a, b] -> flipped "T.isPrefixOf" a b
  Helper EndsWith [a, b] -> flipped "T.isSuffixOf" a b
  Helper TextContains [a, b] -> flipped "T.isInfixOf" a b
  Helper RegexMatches [a, b] -> call2 "LSF.regexMatches" a b
  AllElements value binder predicate -> do
    (sx, xs) <- cexpr env scope value
    t <- fresh "all"
    every <- fresh "every"
    items <- fresh "items"
    item <- fresh (binderName binder)
    rest <- fresh "rest"
    (sp, p) <- cexpr env ((binderId binder, item) : scope) predicate
    -- every items: whether each item satisfies the predicate, in order.
    let go = H.Let (every ++ " " ++ items) (H.Case (var items)
          [ ("LSF.Nil", call "P.pure" [var "P.True"])
          , ("LSF.Cons " ++ item ++ " " ++ rest ++ " _", H.Do (sp ++ [Run (H.If p (call every [var rest]) (call "P.pure" [var "P.False"]))])) ])
    pure (sx ++ [go, strictBind t (call every [xs])], var t)
  Perform (Operation ref "raise") [x] | isFail ref -> do
    (s, v) <- cexpr env scope x
    to <- helper "to" (expressionType x)
    t <- fresh "never"
    pure (s ++ [strictBind t (call "LSF.raise" [string (abilityKey ref), call to [v]])], var t)
  Perform op args -> do
    parts <- mapM (cexpr env scope) args
    outs <- mapM (helper "tn" . expressionType) args
    fromNativeResult <- helper "fn" (expressionType e)
    (owner, ability) <- lift' (maybe (Left ("typed Haskell: unknown ability " ++ abilityKey (operationAbility op))) Right (findAbility (envUnits env) (operationAbility op)))
    r <- fresh "performed"
    t <- fresh "value"
    let record = abilityModule owner ++ "." ++ interfaceName ability
        operation = abilityModule owner ++ "." ++ fieldName ability (operationName op)
        handler = H.Typed (call "LS.handlerOf" [var "symbols", string (abilityKey (operationAbility op))]) record
        invocation = call operation (handler : [call o [x] | (o, x) <- zip outs (map snd parts)])
    performing <- case performedFailure (envUnits env) op of
      Just failing@(AbilityRef _ [failureType]) -> do
        native <- lift' (haskellDataType (envDeclarations env) failureType)
        to <- helper "to" failureType
        from <- helper "fn" failureType
        pure (call "LSF.performing" [string (abilityKey failing), lambda ["(native :: " ++ native ++ ")"] (call to [call from [var "native"]]), invocation])
      _ -> pure invocation
    pure (concatMap fst parts ++ [strictBind r performing, strictLet t (call fromNativeResult [var r])], var t)
  Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, _] <- expressionType e -> do
    t <- fresh "attempted"
    r <- fresh "outcome"
    from <- helper "from" failure
    lines' <- cstmt env scope body
    pure ([ strictBind r (call "LSF.attempt" [string (abilityKey ref), H.Do lines'])
          , strictLet t (H.Case (var r) [("P.Left failure", call "LSF.L" [call from [var "failure"]]), ("P.Right value", call "LSF.R" [var "value"])]) ], var t)
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
    pure (sx ++ si ++ sj, call f [v, integral (expressionType from) i, integral (expressionType to) j])
  Helper At [x, k] -> do
    (sx, v) <- cexpr env scope x
    (sk, i) <- cexpr env scope k
    let f = if expressionType x == Constructor "Bytes" [] then "LSF.atBytes" else "LSF.atList"
    pure (sx ++ sk, call f [v, integral (expressionType k) i])
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
      pure (s, call f [x])
    call2 f a b = do
      (sa, xa) <- cexpr env scope a
      (sb, xb) <- cexpr env scope b
      pure (sa ++ sb, call f [xa, xb])
    flipped f a b = call2 f b a
    viaStatements = do
      t <- fresh "value"
      lines' <- cstmt env scope e
      pure ([strictBind t (H.Do lines')], var t)

-- | An integral value as an Integer.
integral :: Type -> H.Expr -> H.Expr
integral ty x = if ty == Constructor "Integer" [] then x else call "P.toInteger" [x]

boundsOf :: String -> Maybe (Integer, Integer)
boundsOf t = lookup t
  [ ("Int8", (-128, 127)), ("Int16", (-32768, 32767)), ("Int32", (-2147483648, 2147483647))
  , ("Int64", (-(2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1)), ("UInt8", (0, 255)), ("UInt16", (0, 65535))
  , ("UInt32", (0, 4294967295)), ("UInt64", (0, 2 ^ (64 :: Int) - 1)) ]

-- | An Integer result into the expression's type.
narrowTo :: Type -> ([Stmt], H.Expr) -> M ([Stmt], H.Expr)
narrowTo ty (s, x) = case ty of
  Constructor t [] | Just (lo, hi) <- boundsOf t, Just h <- lookup t scalarHs ->
    pure (s, H.Typed (call "LSF.narrow" [integer lo, integer hi, string t, x]) h)
  _ -> pure (s, x)

convert :: Type -> Type -> ([Stmt], H.Expr) -> M ([Stmt], H.Expr)
convert target source (s, x)
  | target == source = pure (s, x)
  | target == Constructor "Integer" [] = pure (s, integral source x)
  | Constructor t [] <- target, Just (lo, hi) <- boundsOf t, Just h <- lookup t scalarHs =
      let inside = case source of
            Constructor n [] | Just (slo, shi) <- boundsOf n -> slo >= lo && shi <= hi
            _ -> False
      in if inside then pure (s, H.Typed (call "P.fromIntegral" [x]) h)
         else narrowTo target (s, integral source x)
  | otherwise = pure (s, x)

constant :: Env -> Scalar -> M ([Stmt], H.Expr)
constant env s = case s of
  SBool b -> pure ([], var (if b then "P.True" else "P.False"))
  SAbsent "Unit" -> pure ([], var "()")
  SInteger t n | Just h <- lookup t scalarHs -> pure ([], H.Typed (integer n) h)
  SSequence "Text" units -> do
    name <- literal env (literalKey s) (call "T.pack" [string (map toEnum units)])
    pure ([], var name)
  SSequence "Bytes" units -> do
    name <- literal env (literalKey s) (call "B.pack" [H.List (map (integer . toInteger) units)])
    pure ([], var name)
  _ -> lift' (Left ("typed Haskell: unsupported constant " ++ show s))

construct :: Env -> Type -> Id -> [H.Expr] -> M H.Expr
construct env ty tag values = case (idText tag, values) of
  ("List::Nil", []) -> pure (var "LSF.Nil")
  ("List::Cons", [h, t]) -> pure (call "LSF.cons" [h, t])
  ("Maybe::Absent", []) -> pure (var "LSF.None")
  ("Maybe::Present", [x]) -> pure (call "LSF.Some" [x])
  ("Either::Left", [x]) -> pure (call "LSF.L" [x])
  ("Either::Right", [x]) -> pure (call "LSF.R" [x])
  (_, [items]) | Just ("KeyVal", _) <- collectionArguments ty -> do
    (key, value) <- entryAccess env
    pure (call "LSF.keyValOf" [key, value, items])
  (_, [items]) | Just ("Set", _) <- collectionArguments ty -> pure (call "LSF.setOf" [items])
  _ -> case M.lookup tag (envConstructors env) of
    Just _ -> pure (call (envNames env M.! tag) values)
    Nothing -> lift' (Left ("typed Haskell: unknown constructor " ++ idText tag))

entryAccess :: Env -> M (H.Expr, H.Expr)
entryAccess env = case M.lookup (collectionsUnit ++ "::type::Entry") (envData env) of
  Just d | [c] <- dataConstructors d ->
    let con = envNames env M.! constructorId c in pure (lambda ["(" ++ con ++ " k _)"] (var "k"), lambda ["(" ++ con ++ " _ v)"] (var "v"))
  _ -> lift' (Left "typed Haskell: no typed Entry")

entryMaker :: Env -> M String
entryMaker env = case M.lookup (collectionsUnit ++ "::type::Entry") (envData env) of
  Just d | [c] <- dataConstructors d -> pure (envNames env M.! constructorId c)
  _ -> lift' (Left "typed Haskell: no typed Entry")

intrinsicCall :: Env -> Intrinsic -> [(H.Expr, Type)] -> M H.Expr
intrinsicCall env intrinsic args = case (intrinsic, args) of
  (KeyValOf, [(es, _)]) -> do
    (key, value) <- entryAccess env
    pure (call "LSF.keyValOf" [key, value, es])
  (KeyValLookup, [(k, _), (m, _)]) -> apply "LSF.lookupMap" [k, m]
  (KeyValPut, [(k, _), (v, _), (m, _)]) -> apply "Map.insert" [k, v, m]
  (KeyValDelete, [(k, _), (m, _)]) -> apply "Map.delete" [k, m]
  (KeyValKeys, [(m, _)]) -> apply "LSF.keysList" [m]
  (KeyValValues, [(m, _)]) -> apply "LSF.valuesList" [m]
  (KeyValEntries, [(m, _)]) -> do
    entry <- entryMaker env
    pure (call "LSF.entriesList" [var entry, m])
  (SetOf, [(xs, _)]) -> apply "LSF.setOf" [xs]
  (SetMember, [(x, _), (s, _)]) -> apply "Set.member" [x, s]
  (SetInsert, [(x, _), (s, _)]) -> apply "Set.insert" [x, s]
  (SetRemove, [(x, _), (s, _)]) -> apply "Set.delete" [x, s]
  (SetUnion, [(s, _), (t, _)]) -> apply "Set.union" [s, t]
  (SetIntersection, [(s, _), (t, _)]) -> apply "Set.intersection" [s, t]
  (SetDifference, [(s, _), (t, _)]) -> apply "Set.difference" [s, t]
  _ -> lift' (Left ("typed Haskell: bad intrinsic " ++ show intrinsic))
  where apply f xs = pure (call f xs)

matchStatements :: Env -> Scope' -> Expr -> [MatchCase] -> M [Stmt]
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
        pure (pattern' (map snd bound), H.Do body)
      unreachableArm = ("_", var "LSF.unreachable")
  (prelude, subject) <- case expressionNode value of
    Local i | Just name <- lookup i scope -> pure ([], var name)
    _ -> cexpr env scope value
  arms <- case ty of
    Constructor n _ | n `elem` ["Maybe", "Either", "List"] -> forM cases $ \c -> alternative c (\names -> case (idText (caseConstructor c), names) of
      ("Maybe::Absent", _) -> "LSF.None"
      ("Maybe::Present", [x]) -> "LSF.Some " ++ x
      ("Either::Left", [x]) -> "LSF.L " ++ x
      ("Either::Right", [x]) -> "LSF.R " ++ x
      ("List::Nil", _) -> "LSF.Nil"
      ("List::Cons", [h, t]) -> "LSF.Cons " ++ h ++ " " ++ t ++ " _"
      _ -> "_")
    _ | Just (kind, _) <- collectionArguments ty, [c] <- cases -> do
          subjectName <- fresh "subject"
          items <- if kind == "KeyVal" then do
            entry <- entryMaker env
            pure (call "LSF.entriesList" [var entry, var subjectName])
            else pure (call "LSF.listOf" [call "Set.toAscList" [var subjectName]])
          bound <- binders c
          body <- cstmt env ([x | (Just x, _) <- bound] ++ scope) (caseBody c)
          let binding = case bound of
                [(_, n)] | n /= "_" -> [strictLet n items]
                _ -> []
          pure [(subjectName, H.Do (binding ++ body))]
    Constructor n _ | Just d <- M.lookup n (envData env) -> do
      arms <- forM cases $ \c -> alternative c (\names -> unwords (envNames env M.! caseConstructor c : names))
      pure (arms ++ [unreachableArm | length cases < length (dataConstructors d)])
    _ -> lift' (Left ("typed Haskell: cannot match on " ++ show ty))
  pure (prelude ++ [Run (H.Case subject arms)])

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
helperTable = unsafePerformIO (newPersistentTable "typed-haskell-helper" (4 * 1024 * 1024) (length . show))
{-# NOINLINE helperTable #-}

memoHelper :: Env -> String -> Type -> M D.Doc
memoHelper env kind ty = do
  before <- get
  let types = Context.typeClosure (envData env) [ty]
      selected = [((helperKind,show value),name) | value <- types, helperKind <- helperKinds,
        Just name <- [M.lookup (helperKind,show value) (envHelperNames env)]]
      names = scopeWith (moduleReserved ++ map snd selected)
      own = St names names M.empty S.empty (M.fromList selected) M.empty
      key = Identity.fullKey (envIdentity env) ("typed-haskell-helper:" ++ show (kind,selected,nativeContext env types)) ty
  (document,requested) <- lift' (memoized helperTable key (runStateT (helperDoc env kind ty) own))
  put before { stHelpers = M.union (stHelpers requested) (stHelpers before),
               stWanted = S.union (stWanted requested) (stWanted before),
               stLiterals = M.union (stLiterals requested) (stLiterals before) }
  pure document

helperDoc :: Env -> String -> Type -> M D.Doc
helperDoc env kind ty = do
  name <- helper kind ty
  typed <- lift' (hsType env ty)
  native <- lift' (haskellDataType (envDeclarations env) ty)
  let parenthesized t = if ' ' `elem` t && take 1 t /= "(" && take 1 t /= "[" then "(" ++ t ++ ")" else t
      fn from to arg body = D.joinWith D.hardline [H.signature name [from, to], H.declaration (name ++ " " ++ arg) body]
  case kind of
    "to" -> fn typed "Scalar" "x" <$> toValue env ty
    "from" -> fn "Scalar" typed "v" <$> fromValue env ty
    "tn" -> fn typed (parenthesized native) "x" <$> toNative env ty
    _ -> fn (parenthesized native) typed "n" <$> fromNative env ty

dataOf :: Env -> Type -> Maybe (DataDeclaration, [Type])
dataOf env ty = case ty of
  Constructor n args | Just d <- M.lookup n (envData env) -> Just (d, [t | TypeArgument t <- args])
  _ -> Nothing

fields :: Int -> [String]
fields n = ["f" ++ show k | k <- [0 .. n - 1]]

sdata :: String -> [H.Expr] -> H.Expr
sdata tag xs = call "SData" [string tag, H.List xs]

toValue :: Env -> Type -> M H.Expr
toValue env ty = case ty of
  Constructor "Bool" [] -> pure (call "SBool" [var "x"])
  Constructor "Unit" [] -> pure (call "SAbsent" [string "Unit"])
  Constructor "Text" [] -> pure (call "LSF.textScalar" [var "x"])
  Constructor "Bytes" [] -> pure (call "LSF.bytesScalar" [var "x"])
  Constructor n [] | isJust (boundsOf n) || n == "Integer" -> pure (call "SInteger" [string n, call "P.toInteger" [var "x"]])
  Constructor "List" [TypeArgument a] -> (\f -> call "SList" [call "P.map" [var f, call "LSF.items" [var "x"]]]) <$> helper "to" a
  Constructor "Maybe" [TypeArgument a] -> do
    f <- helper "to" a
    pure (H.Case (var "x") [("LSF.None", sdata "Maybe::Absent" []), ("LSF.Some v", sdata "Maybe::Present" [call f [var "v"]])])
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "to" a
    fr <- helper "to" b
    pure (H.Case (var "x") [("LSF.L v", sdata "Either::Left" [call fl [var "v"]]), ("LSF.R v", sdata "Either::Right" [call fr [var "v"]])])
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "to" k
        fv <- helper "to" v
        pure (sdata (collectionsUnit ++ "::type::KeyVal::KeyValEntries")
          [call "SList" [var ("[SData " ++ H.renderString (collectionsUnit ++ "::type::Entry::Entry") ++ " [" ++ fk ++ " k, " ++ fv ++ " v] | (k, v) <- Map.toAscList x]")]])
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- helper "to" a
        pure (sdata (collectionsUnit ++ "::type::Set::SetItems") [call "SList" [call "P.map" [var f, call "Set.toAscList" [var "x"]]]])
  _ | Just (d, targs) <- dataOf env ty -> do
        arms <- forM (dataConstructors d) $ \c -> do
          encoders <- mapM (helper "to") (fieldTypes d targs c)
          let names = fields (length encoders)
          pure (unwords (envNames env M.! constructorId c : names), sdata (idText (constructorId c)) [call e [var n] | (e, n) <- zip encoders names])
        pure (H.Case (var "x") arms)
  _ -> lift' (Left ("typed Haskell: no conversion for " ++ show ty))

fromValue :: Env -> Type -> M H.Expr
fromValue env ty = case ty of
  Constructor "Bool" [] -> pure (call "LSF.scalarBool" [var "v"])
  Constructor "Unit" [] -> pure (var "()")
  Constructor "Text" [] -> pure (call "LSF.scalarText" [var "v"])
  Constructor "Bytes" [] -> pure (call "LSF.scalarBytes" [var "v"])
  Constructor n [] | isJust (boundsOf n) || n == "Integer" -> pure (call "P.fromInteger" [call "LSF.scalarInteger" [var "v"]])
  Constructor "List" [TypeArgument a] -> (\f -> call "LSF.listOf" [call "P.map" [var f, call "LSF.scalarItems" [var "v"]]]) <$> helper "from" a
  Constructor "Maybe" [TypeArgument a] -> do
    f <- helper "from" a
    pure (H.Case (call "LSF.scalarData" [var "v"]) [("(\"Maybe::Present\", [x])", call "LSF.Some" [call f [var "x"]]), ("_", var "LSF.None")])
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "from" a
    fr <- helper "from" b
    pure (H.Case (call "LSF.scalarData" [var "v"])
      [ ("(\"Either::Right\", [x])", call "LSF.R" [call fr [var "x"]]), ("(_, [x])", call "LSF.L" [call fl [var "x"]])
      , ("_", call "P.error" [string "expected Either"]) ])
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "from" k
        fv <- helper "from" v
        pure (call "Map.fromList" [var ("[(" ++ fk ++ " k, " ++ fv ++ " x) | SData _ [k, x] <- LSF.scalarItems (LSF.onlyField v)]")])
    | Just ("Set", [a]) <- collectionArguments ty -> do
        f <- helper "from" a
        pure (call "Set.fromList" [call "P.map" [var f, call "LSF.scalarItems" [call "LSF.onlyField" [var "v"]]]])
  _ | Just (d, targs) <- dataOf env ty -> do
        arms <- forM (dataConstructors d) $ \c -> do
          decoders <- mapM (helper "from") (fieldTypes d targs c)
          let names = fields (length decoders)
          pure ("(" ++ H.renderString (idText (constructorId c)) ++ ", [" ++ intercalate ", " names ++ "])",
            call (envNames env M.! constructorId c) [call dec [var n] | (dec, n) <- zip decoders names])
        pure (H.Case (call "LSF.scalarData" [var "v"]) (arms ++
          [("(tag, _)", call "P.error" [operator "P.++" [string ("expected " ++ dataName d ++ ", found "), var "tag"]])]))
  _ -> lift' (Left ("typed Haskell: no conversion for " ++ show ty))

toNative :: Env -> Type -> M H.Expr
toNative env ty = case ty of
  Constructor n [] | n `elem` scalarTypes -> pure (var "x")
  Constructor "List" [TypeArgument a] -> (\f -> call "P.map" [var f, call "LSF.items" [var "x"]]) <$> helper "tn" a
  Constructor "Maybe" [TypeArgument a] -> (\f -> H.Case (var "x") [("LSF.None", var "P.Nothing"), ("LSF.Some v", call "P.Just" [call f [var "v"]])]) <$> helper "tn" a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "tn" a
    fr <- helper "tn" b
    pure (H.Case (var "x") [("LSF.L v", call "P.Left" [call fl [var "v"]]), ("LSF.R v", call "P.Right" [call fr [var "v"]])])
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "tn" k
        fv <- helper "tn" v
        pure (call "Map.fromList" [var ("[(" ++ fk ++ " k, " ++ fv ++ " v) | (k, v) <- Map.toAscList x]")])
    | Just ("Set", [a]) <- collectionArguments ty -> (\f -> call "Set.fromList" [call "P.map" [var f, call "Set.toAscList" [var "x"]]]) <$> helper "tn" a
  _ | Just (d, targs) <- dataOf env ty -> do
        arms <- forM (dataConstructors d) $ \c -> do
          converters <- mapM (helper "tn") (fieldTypes d targs c)
          let names = fields (length converters)
          pure (unwords (envNames env M.! constructorId c : names),
            call ("Data." ++ envNames env M.! constructorId c) [call cv [var n] | (cv, n) <- zip converters names])
        pure (H.Case (var "x") arms)
  _ -> lift' (Left ("typed Haskell: no native conversion for " ++ show ty))

fromNative :: Env -> Type -> M H.Expr
fromNative env ty = case ty of
  Constructor n [] | n `elem` scalarTypes -> pure (var "n")
  Constructor "List" [TypeArgument a] -> (\f -> call "LSF.listOf" [call "P.map" [var f, var "n"]]) <$> helper "fn" a
  Constructor "Maybe" [TypeArgument a] -> (\f -> H.Case (var "n") [("P.Nothing", var "LSF.None"), ("P.Just v", call "LSF.Some" [call f [var "v"]])]) <$> helper "fn" a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    fl <- helper "fn" a
    fr <- helper "fn" b
    pure (H.Case (var "n") [("P.Left v", call "LSF.L" [call fl [var "v"]]), ("P.Right v", call "LSF.R" [call fr [var "v"]])])
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        fk <- helper "fn" k
        fv <- helper "fn" v
        pure (call "Map.fromList" [var ("[(" ++ fk ++ " k, " ++ fv ++ " v) | (k, v) <- Map.toAscList n]")])
    | Just ("Set", [a]) <- collectionArguments ty -> (\f -> call "Set.fromList" [call "P.map" [var f, call "Set.toAscList" [var "n"]]]) <$> helper "fn" a
  _ | Just (d, targs) <- dataOf env ty -> do
        arms <- forM (dataConstructors d) $ \c -> do
          converters <- mapM (helper "fn") (fieldTypes d targs c)
          let names = fields (length converters)
          pure (unwords (("Data." ++ envNames env M.! constructorId c) : names),
            call (envNames env M.! constructorId c) [call cv [var n] | (cv, n) <- zip converters names])
        pure (H.Case (var "n") arms)
  _ -> lift' (Left ("typed Haskell: no native conversion for " ++ show ty))
