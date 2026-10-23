-- | Typed Rust for checked definitions (see LawSpec.Typed.Plan): each typed
-- data type is a Rust type, each class of typed definitions one function over
-- them, and the dynamic entry points convert at the boundary. Lists, KeyVal
-- and Set are lawspec_runtime::fast's persistent structures; data with
-- fields is shared behind an Arc, so passing and keeping a value never copies
-- it. ref:DEC-typed-native-definitions
module LawSpec.Typed.Rust (RustTyped(..), emitRustTyped) where

import Control.Monad (forM)
import Control.Monad.State.Strict
import Data.Char (isAlphaNum)
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S
import LawSpec.Collections (collectionsUnit)
import LawSpec.Core
import LawSpec.Scalar
import LawSpec.Typed.Plan
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.RustExpr as E
import LawSpec.RustLayout (Arm(..))
import qualified LawSpec.RustLayout as L
import LawSpec.Naming (NameKind(..), claim, claimAll, scopeWith, localIdentifier, nativeIdentifier, readableDefinitionName)
import qualified LawSpec.RustData as Native
import LawSpec.Collections (collectionContainer)
import LawSpec.Time (isDurationType)
import LawSpec.RustAbilityPaths (performBridges)
import LawSpec.RecordNames (recordDisplayNames)

data RustTyped = RustTyped
  { rustTypedModule :: D.Doc
    -- The typed function of a typed definition, within the typed module.
  , rustTypedFunction :: Id -> Maybe String
    -- A type's typed form, qualified for use outside the typed module.
  , rustTypedType :: Type -> Either String String
    -- A closed expression (a handler's start value), qualified likewise.
  , rustTypedValue :: Expr -> Either String D.Doc
    -- The two fields of a typed Pair, as a qualified function.
  , rustPairFields :: String
    -- Whether a type converts to and from its public form directly (Public).
  , rustTypedNative :: Type -> Bool
  , rustTypedPlan :: TypedPlan
  }

-- | The path of the typed module from the crate root.
modulePath :: String
modulePath = "crate::lawspec_definitions::typed::"

data Env = Env
  { envPlan :: TypedPlan
  , envNames :: M.Map String String            -- data identity -> Rust type name
  , envData :: M.Map String DataDeclaration
  , envConstructors :: M.Map Id (DataDeclaration, DataConstructor)
  , envFunctions :: M.Map Int String            -- class -> function name
  , envPrefix :: String                         -- "" inside the typed module
  , envBridges :: M.Map Id String               -- each operation's bridge
  }

-- | A function's locals are distinct: each is named from its source name
-- (or what it holds) and claimed in the function's scope.
type R = StateT [String] (Either String)

fresh :: String -> R String
fresh base = do
  taken <- get
  let (chosen, _) = claim (scopeWith taken) (localIdentifier "rust" base)
  put (chosen : taken)
  pure chosen

-- | Names a typed function's locals never take: the functions it calls and
-- the names the module and the runtime use.
moduleReserved :: [String]
moduleReserved = words "ctx ls self pair_fields entry_pair make_entry std crate super"

emitRustTyped :: [DataDeclaration] -> [Unit] -> Either String RustTyped
emitRustTyped declarations units = do
  let plan = typedPlanPerforming scalarTypes declarations units
      datas = typedData plan
      names = dataNames (recordDisplayNames declarations) datas
      -- Each typed function is named after its definition; a specialised
      -- copy after its definition and its argument types.
      functionNames = fst (claimAll (scopeWith moduleReserved)
        [ nativeIdentifier "rust" FunctionName (readableDefinitionName (declarationName (definitionDeclaration d))
            (fst (functionType (declarationType (definitionDeclaration d)))))
        | (_, d) <- typedRepresentatives plan ])
      functions = M.fromList (zip (map fst (typedRepresentatives plan)) functionNames)
      env = Env plan names (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions ""
        (M.fromList [(i, "crate::" ++ path) | (i, path) <- performBridges units])
      outside = env { envPrefix = modulePath }
  dataDocs <- mapM (dataDoc env) datas
  functionDocs <- mapM (\(c, d) -> functionDoc env c d) (typedRepresentatives plan)
  pairFields <- pairFieldsDoc env
  let directData = directDeclarations declarations datas
  publicDocs <- mapM (publicDoc env declarations) [d | d <- datas, idText (dataId d) `S.member` directData]
  let body = D.text "use crate::lawspec_runtime as ls;" <> D.hardline <>
        D.text "use ls::fast::{Dyn, POrd};" <> D.hardline <> D.hardline <>
        D.joinWith (D.hardline <> D.hardline) (dataDocs ++ publicDocs ++ pairFields ++ functionDocs)
      lookupFunction identity = do
        c <- definitionClass plan identity
        (modulePath ++) <$> M.lookup c functions
  pure RustTyped
    { rustTypedModule = D.text "/// Typed checked definitions: see the runtime's fast module." <> D.hardline <>
        D.text "pub mod typed " <> D.block 4 body
    , rustTypedFunction = lookupFunction
    , rustTypedType = rustType outside
    , rustTypedValue = \e -> L.expr <$> evalStateT (expression outside Nothing [] e) (moduleReserved ++ functionNames)
    , rustPairFields = modulePath ++ "pair_fields"
    , rustTypedNative = directType directData
    , rustTypedPlan = plan }

-- | Rust names for the typed data types: the declared name, unless another
-- typed type or a name the generated code uses has it.
dataNames :: M.Map Id String -> [DataDeclaration] -> M.Map String String
dataNames display datas = M.fromList (snd (foldl pick (reserved, []) datas))
  where
    reserved = S.fromList ["Option", "Result", "Some", "None", "Ok", "Err", "Vec", "Box", "String", "Arc", "Self", "Ordering", "Either", "List", "Map", "Set", "Int", "Text", "Bytes", "Dyn", "POrd", "ls", "std", "crate", "super"]
    pick (taken, acc) d =
      let base = [c | c <- M.findWithDefault (dataName d) (dataId d) display, isAlphaNum c || c == '_']
          candidates = base : [base ++ "_" ++ show k | k <- [2 :: Int ..]]
          chosen = firstOf [n | n <- candidates, n `S.notMember` taken, (n ++ "Node") `S.notMember` taken]
      in (S.insert chosen (S.insert (chosen ++ "Node") taken), (idText (dataId d), chosen) : acc)

-- | Whether values of a type are Copy: no clone needed.
isCopy :: Env -> Type -> Bool
isCopy env ty = case ty of
  Constructor n [] | n `elem` ["Bool", "Unit", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64"] -> True
  Constructor n _ | Just d <- M.lookup n (envData env) -> fieldless d
  _ -> False

fieldless :: DataDeclaration -> Bool
fieldless d = all (null . constructorFields) (dataConstructors d)

rustType :: Env -> Type -> Either String String
rustType env = rustTypeP env []

-- | With a data declaration's parameters bound to Rust generics.
rustTypeP :: Env -> [(Id, String)] -> Type -> Either String String
rustTypeP env parameters ty = case ty of
  TypeVariable v | Just p <- lookup v parameters -> pure p
  Constructor "Bool" [] -> pure "bool"
  Constructor "Unit" [] -> pure "()"
  Constructor n [] | Just t <- lookup n fixed -> pure t
  Constructor "Integer" [] -> pure "ls::fast::Int"
  Constructor "Text" [] -> pure "ls::fast::Text"
  Constructor "Bytes" [] -> pure "ls::fast::Bytes"
  Constructor "List" [TypeArgument a] -> (\t -> "ls::fast::List<" ++ t ++ ">") <$> rustTypeP env parameters a
  Constructor "Maybe" [TypeArgument a] -> (\t -> "Option<" ++ t ++ ">") <$> rustTypeP env parameters a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> do
    l <- rustTypeP env parameters a
    r <- rustTypeP env parameters b
    pure ("ls::Either<" ++ l ++ ", " ++ r ++ ">")
  _ | Just ("KeyVal", [k, v]) <- collectionArguments ty -> do
        kt <- rustTypeP env parameters k
        vt <- rustTypeP env parameters v
        pure ("ls::fast::Map<" ++ kt ++ ", " ++ vt ++ ">")
    | Just ("Set", [a]) <- collectionArguments ty -> (\t -> "ls::fast::Set<" ++ t ++ ">") <$> rustTypeP env parameters a
  Constructor n args | Just name <- M.lookup n (envNames env) -> do
    rendered <- mapM (\a -> case a of TypeArgument t -> rustTypeP env parameters t; _ -> Left "typed Rust: index argument") args
    pure (envPrefix env ++ name ++ (if null rendered then "" else "<" ++ intercalate ", " rendered ++ ">"))
  _ -> Left ("no typed Rust form for " ++ show ty)
  where
    fixed = [("Int8", "i8"), ("Int16", "i16"), ("Int32", "i32"), ("Int64", "i64"), ("UInt8", "u8"), ("UInt16", "u16"), ("UInt32", "u32"), ("UInt64", "u64")]

-- A declaration's type parameters, as Rust generics.
parameterNames :: DataDeclaration -> [(Id, String)]
parameterNames d = zip (dataParameters d) ["T" ++ show k | k <- [0 :: Int ..]]

variantName :: DataConstructor -> String
variantName c = let n = [x | x <- constructorName c, isAlphaNum x || x == '_'] in
  if n `elem` ["Self", "Some", "None", "Ok", "Err"] then n ++ "_" else n

dataDoc :: Env -> DataDeclaration -> Either String D.Doc
dataDoc env d = do
  let name = envNames env M.! idText (dataId d)
      parameters = parameterNames d
      generics = if null parameters then "" else "<" ++ intercalate ", " (map snd parameters) ++ ">"
      bound trait = if null parameters then "" else "<" ++ intercalate ", " [p ++ ": " ++ trait | (_, p) <- parameters] ++ ">"
      ranks = constructorRanks d
      rank c = fromMaybe 0 (lookup (constructorId c) ranks)
      tagOf c = E.quoted (idText (constructorId c))
      variants = dataConstructors d
      line = D.text
      header = line ("/// " ++ dataName d ++ " (" ++ idText (dataId d) ++ ").")
      impl head' items = line (head' ++ " ") <> D.block 4 (D.joinWith D.hardline items)
      method' head' params result body = L.function ("fn " ++ head') params result (L.stmts [] (Just body))
      matchOn subject arms = L.Match (L.atom subject) arms
      arm p body = Arm p Nothing body
      expected = L.call "Err" [L.macroCall "format" [L.Laid (E.stringLiteral ("expected " ++ dataName d ++ ", found {other}"))]]
  fieldTypes <- forM variants $ \c -> mapM (rustTypeP env { envPrefix = "" } parameters . binderType) (constructorFields c)
  if null variants then pure (header <> D.hardline <>
    line "#[derive(Clone, Copy, PartialEq, Eq, Debug)]" <> D.hardline <> line ("pub enum " ++ name ++ " {}") <> D.hardline <>
    impl ("impl POrd for " ++ name) [method' "pcmp" ["&self", "_: &Self"] "std::cmp::Ordering" (L.atom "match *self {}")] <> D.hardline <>
    impl ("impl Dyn for " ++ name)
      [ method' "to_dyn" ["&self"] "ls::Value" (L.atom "match *self {}")
      , method' "from_dyn" ["_: ls::Value"] "ls::Result<Self>" (L.call "Err" [L.method (L.Laid (E.stringLiteral ("no value of " ++ dataName d))) "into" []]) ])
  else if fieldless d then pure (header <> D.hardline <>
    line "#[derive(Clone, Copy, PartialEq, Eq, Debug)]" <> D.hardline <>
    line ("pub enum " ++ name ++ " ") <> D.block 4 (D.joinWith D.hardline [line (variantName c ++ ",") | c <- variants]) <> D.hardline <>
    impl ("impl " ++ name) [method' "rank" ["&self"] "u32" (matchOn "self" [arm (name ++ "::" ++ variantName c) (L.atom (show (rank c))) | c <- variants])] <> D.hardline <>
    impl ("impl POrd for " ++ name) [method' "pcmp" ["&self", "other: &Self"] "std::cmp::Ordering" (L.method (L.method (L.atom "self") "rank" []) "cmp" [L.prefix "&" (L.method (L.atom "other") "rank" [])])] <> D.hardline <>
    impl ("impl Dyn for " ++ name)
      [ L.function "fn to_dyn" ["&self"] "ls::Value" (L.stmts
          [L.Let "tag" (matchOn "self" [arm (name ++ "::" ++ variantName c) (L.atom (tagOf c)) | c <- variants])]
          (Just (L.call "ls::Value::Data" [L.method (L.atom "tag") "into" [], L.vecOf []])))
      , method' "from_dyn" ["value: ls::Value"] "ls::Result<Self>" (L.Match (L.try' (L.call "ls::fast::tag" [L.atom "&value"]))
          ([arm (tagOf c) (L.call "Ok" [L.atom (name ++ "::" ++ variantName c)]) | c <- variants] ++ [arm "other" expected])) ])
  else do
    let node = name ++ "Node"
        patternOf prefix' c = node ++ "::" ++ variantName c ++ (if null (constructorFields c) then "" else
          "(" ++ intercalate ", " [prefix' ++ show k | k <- [0 .. length (constructorFields c) - 1]] ++ ")")
        compareArm c = arm ("(" ++ patternOf "a" c ++ ", " ++ patternOf "b" c ++ ")")
          (if null (constructorFields c) then L.atom "std::cmp::Ordering::Equal" else
            foldl1 (\acc x -> L.method acc "then_with" [L.closure "||" x])
              [L.method (L.atom ("a" ++ show k)) "pcmp" [L.atom ("b" ++ show k)] | k <- [0 .. length (constructorFields c) - 1]])
        wildcard c = node ++ "::" ++ variantName c ++ (if null (constructorFields c) then "" else
          "(" ++ intercalate ", " (replicate (length (constructorFields c)) "_") ++ ")")
        toDynArm c = arm (patternOf "f" c) (L.call "ls::Value::Data" [L.method (L.atom (tagOf c)) "into" [],
          L.vecOf [L.method (L.atom ("f" ++ show k)) "to_dyn" [] | k <- [0 .. length (constructorFields c) - 1]]])
        fromDynArm c ts = arm (tagOf c) (L.letIn
          [L.Let "mut fields" (L.try' (L.call "ls::fast::fields" [L.atom "value", L.atom (tagOf c), L.atom (show (length ts))])) | not (null ts)]
          (L.call "Ok" [L.call name [L.call "std::sync::Arc::new" [made c [L.try' (L.call ("<" ++ t ++ " as Dyn>::from_dyn") [L.method (L.method (L.atom "fields") "next" []) "unwrap" []]) | t <- ts]]]]))
        made c values = if null values then L.atom (node ++ "::" ++ variantName c) else L.call (node ++ "::" ++ variantName c) values
    pure (header <> D.hardline <>
      line "#[derive(Clone, PartialEq, Eq, Debug)]" <> D.hardline <>
      line ("pub struct " ++ name ++ generics ++ "(pub std::sync::Arc<" ++ node ++ generics ++ ">);") <> D.hardline <>
      line "#[derive(PartialEq, Eq, Debug)]" <> D.hardline <>
      line ("pub enum " ++ node ++ generics ++ " ") <> D.block 4 (D.joinWith D.hardline
        [line (variantName c ++ (if null ts then "" else "(" ++ intercalate ", " ts ++ ")") ++ ",") | (c, ts) <- zip variants fieldTypes]) <> D.hardline <>
      impl ("impl" ++ generics ++ " " ++ name ++ generics) [method' "rank" ["&self"] "u32" (matchOn "&*self.0" [arm (wildcard c) (L.atom (show (rank c))) | c <- variants])] <> D.hardline <>
      impl ("impl" ++ bound "POrd" ++ " POrd for " ++ name ++ generics)
        [L.function "fn pcmp" ["&self", "other: &Self"] "std::cmp::Ordering" (L.stmts
          [L.Do (L.If (L.call "std::sync::Arc::ptr_eq" [L.atom "&self.0", L.atom "&other.0"]) (L.Block [L.Semi (L.Return (Just (L.atom "std::cmp::Ordering::Equal")))] Nothing) Nothing)]
          (Just (matchOn "(&*self.0, &*other.0)" (map compareArm variants ++ [arm "_" (L.method (L.method (L.atom "self") "rank" []) "cmp" [L.prefix "&" (L.method (L.atom "other") "rank" [])]) | length variants > 1]))))] <> D.hardline <>
      impl ("impl" ++ bound "Dyn" ++ " Dyn for " ++ name ++ generics)
        [ method' "to_dyn" ["&self"] "ls::Value" (matchOn "&*self.0" (map toDynArm variants))
        , method' "from_dyn" ["value: ls::Value"] "ls::Result<Self>" (L.Match (L.try' (L.call "ls::fast::tag" [L.atom "&value"]))
            (zipWith fromDynArm variants fieldTypes ++ [arm "other" expected])) ])

pairFieldsDoc :: Env -> Either String [D.Doc]
pairFieldsDoc env = pure (pair ++ entry)
  where
    fields name constructor first second subject = L.Match (L.atom subject)
      [Arm (name ++ "Node::" ++ constructor ++ "(" ++ first ++ ", " ++ second ++ ")") Nothing
        (L.atom ("(" ++ first ++ ".clone(), " ++ second ++ ".clone())"))]
    pair = case M.lookup (collectionsUnit ++ "::type::Pair") (envNames env) of
      Nothing -> []
      Just name -> [D.text "/// A handler clause's result and next state." <> D.hardline <>
        L.function "pub fn pair_fields<A: Clone, B: Clone>" ["pair: " ++ name ++ "<A, B>"] "(A, B)"
          (L.expr (fields name "Pair" "a" "b" "&*pair.0"))]
    entry = case M.lookup (collectionsUnit ++ "::type::Entry") (envNames env) of
      Nothing -> []
      Just name ->
        [ L.function "pub fn entry_pair<K: Clone, V: Clone>" ["entry: &" ++ name ++ "<K, V>"] "(K, V)"
            (L.expr (fields name "Entry" "k" "v" "&*entry.0"))
        , L.function "pub fn make_entry<K: Clone, V: Clone>" ["k: &K", "v: &V"] (name ++ "<K, V>")
            (L.expr (L.call name [L.call "std::sync::Arc::new" [L.call (name ++ "Node::Entry") [L.method (L.atom "k") "clone" [], L.method (L.atom "v") "clone" []]]])) ]

functionDoc :: Env -> Int -> Definition -> Either String D.Doc
functionDoc env c d = flip evalStateT (moduleReserved ++ M.elems (envFunctions env)) $ do
  let declaration = definitionDeclaration d
      (_, result) = functionType (declarationType declaration)
      name = envFunctions env M.! c
  params <- forM (definitionArguments d) $ \b -> do
    local <- fresh (binderName b)
    ty <- lift (rustType env (binderType b))
    pure (binderId b, local, ty)
  resultType <- lift (rustType env result)
  let scope = [(i, l) | (i, l, _) <- params]
      selfCall = Just (c, map (\(_, l, _) -> l) params)
  body <- case M.lookup (declarationId declaration) (typedIntrinsics (envPlan env)) of
    Just intrinsic -> intrinsicCall env intrinsic [(L.atom l, ty) | ((_, l, _), ty) <- zip params (map binderType (definitionArguments d))]
    Nothing -> expression env selfCall scope (definitionBody d)
  let looping = hasTailSelf env c (definitionBody d)
      contextual = isContextual (envPlan env) (declarationId declaration)
      rendered = L.expr (L.Block [] (Just body))
      -- A parameter the body reassigns (a loop's) is mutable; one it never
      -- reads is marked unused.
      parameter l t = (if looping && reassigned l then "mut " else "") ++ E.unusedAs l rendered ++ ": " ++ t
      reassigned l = l `elem` [n | (i, n, _) <- params, i `elem` tailChanged env c (map (\(i', _, _) -> i') params) (definitionBody d)]
      comment = D.text ("/// " ++ idText (declarationId declaration))
      returned = if looping
        then L.stmts [L.Do (L.Prefix "loop " (L.Block [L.Semi (L.Return (Just (L.call "Ok" [body])))] Nothing))] Nothing
        else L.stmts [] (Just (L.call "Ok" [body]))
  pure (comment <> D.hardline <> L.function ("pub fn " ++ name)
    ([(if E.mentions "ctx" rendered then "ctx" else "_ctx") ++ ": &mut ls::Context" | contextual] ++ [parameter l t | (_, l, t) <- params])
    ("ls::Result<" ++ resultType ++ ">") returned)

-- | The parameters a call of the function's own class in tail position
-- passes something else for: the loop reassigns them.
tailChanged :: Env -> Int -> [Id] -> Expr -> [Id]
tailChanged env c parameters e = case expressionNode e of
  ExternalCall i args | definitionClass (envPlan env) i == Just c && M.notMember i (typedIntrinsics (envPlan env)) ->
    [p | (p, a) <- zip parameters args, expressionNode a /= Local p]
  If _ a b -> tailChanged env c parameters a ++ tailChanged env c parameters b
  Match _ cases -> concatMap (tailChanged env c parameters . caseBody) cases
  Let _ _ body -> tailChanged env c parameters body
  Helper Select [_, a, b] -> tailChanged env c parameters a ++ tailChanged env c parameters b
  _ -> []

-- | Whether a definition calls its own class in tail position.
hasTailSelf :: Env -> Int -> Expr -> Bool
hasTailSelf env c e = case expressionNode e of
  ExternalCall i _ -> definitionClass (envPlan env) i == Just c && M.notMember i (typedIntrinsics (envPlan env))
  If _ a b -> hasTailSelf env c a || hasTailSelf env c b
  Match _ cases -> any (hasTailSelf env c . caseBody) cases
  Let _ _ body -> hasTailSelf env c body
  Helper Select [_, a, b] -> hasTailSelf env c a || hasTailSelf env c b
  _ -> False

type Scope = [(Id, String)]

borrow :: L.Expr -> L.Expr
borrow = L.prefix "&"

-- | An expression of a typed type; selfCall is the enclosing function's class
-- and parameters while the expression is in tail position.
expression :: Env -> Maybe (Int, [String]) -> Scope -> Expr -> R L.Expr
expression env selfCall scope e = case expressionNode e of
  Constant s -> lift (constant s)
  Local i -> do
    name <- lift (maybe (Left ("typed Rust: unbound local " ++ idText i)) Right (lookup i scope))
    pure (if isCopy env (expressionType e) then L.atom name else L.method (L.atom name) "clone" [])
  Let binder value body -> do
    v <- expression env Nothing scope value
    local <- fresh (binderName binder)
    rest <- expression env selfCall ((binderId binder, local) : scope) body
    let pat = E.unusedAs local (L.expr rest)
    pure (case rest of
      L.Block ss t -> L.Block (L.Let pat v : ss) t
      _ -> L.Block [L.Let pat v] (Just rest))
  If c a b -> do
    cond <- expression env Nothing scope c
    yes <- expression env selfCall scope a
    no <- expression env selfCall scope b
    pure (L.If cond yes (Just no))
  Helper Select [c, a, b] -> expression env selfCall scope (e { expressionNode = If c a b })
  ShortCircuit op a b -> do
    l <- expression env Nothing scope a
    r <- expression env Nothing scope b
    pure (L.infixOp (if op == And then "&&" else "||") l r)
  Unary Not a -> L.prefix "!" <$> expression env Nothing scope a
  Unary Negate _ -> integerExpression env scope e
  Binary {} -> binary env scope e
  Convert _ target value
    | target == expressionType value -> expression env Nothing scope value
    | otherwise -> convert env scope target value
  Construct tag args -> do
    values <- mapM (expression env Nothing scope) args
    construct env (expressionType e) tag values args
  Match value cases -> match env selfCall scope value cases (expressionType e)
  ExternalCall i args
    | Just intrinsic <- M.lookup i (typedIntrinsics (envPlan env)) -> do
        values <- mapM (expression env Nothing scope) args
        intrinsicCall env intrinsic (zip values (map expressionType args))
    | Just (c, params) <- selfCall, definitionClass (envPlan env) i == Just c -> do
        let unchanged (p, a) = case expressionNode a of
              Local l -> lookup l scope == Just p
              _ -> False
            changed = [(p, a) | (p, a) <- zip params args, not (unchanged (p, a))]
        values <- mapM (expression env Nothing scope . snd) changed
        temporaries <- mapM (const (fresh "next")) values
        pure (L.Block ([L.Let t v | (t, v) <- zip temporaries values] ++
           [L.Semi (L.atom (p ++ " = " ++ t)) | ((p, _), t) <- zip changed temporaries]) (Just (L.atom "continue")))
    | otherwise -> do
        c <- lift (maybe (Left ("typed Rust: untyped callee " ++ idText i)) Right (definitionClass (envPlan env) i))
        let name = envPrefix env ++ envFunctions env M.! c
        values <- mapM (expression env Nothing scope) args
        if isContextual (envPlan env) i
          then do
            -- The arguments first, so the context is borrowed once at a time.
            temporaries <- mapM (const (fresh "argument")) values
            types <- lift (mapM (rustType env . expressionType) args)
            pure (L.Block [L.Let (t ++ ": " ++ ty) v | (t, (ty, v)) <- zip temporaries (zip types values)]
              (Just (L.try' (L.call name (L.atom "&mut *ctx" : map L.atom temporaries)))))
          else pure (L.try' (L.call name values))
  Helper Compare [a, b] -> do
    x <- expression env Nothing scope a
    y <- expression env Nothing scope b
    ordering <- lift (orderingName env)
    pure (L.Match (L.call "ls::fast::POrd::pcmp" [borrow x, borrow y])
      [Arm ("std::cmp::Ordering::" ++ o) Nothing (L.atom (ordering ++ "::" ++ o)) | o <- ["Less", "Equal", "Greater"]])
  Helper Length [_] -> integerExpression env scope e
  Helper Unreachable _ -> pure (L.Return (Just (L.call "Err" [L.method (L.Laid (E.stringLiteral "unreachable branch reached")) "into" []])))
  Helper Checked _ -> pure (L.atom "true")
  Helper StartsWith [a, b] -> textTest "starts_with" a b
  Helper EndsWith [a, b] -> textTest "ends_with" a b
  Helper TextContains [a, b] -> textTest "contains" a b
  Helper RegexMatches [a, b] -> do
    p <- expression env Nothing scope a
    t <- expression env Nothing scope b
    pure (L.try' (L.call "ls::regex_matches" [borrow p, borrow t]))
  AllElements value binder predicate -> do
    xs <- expression env Nothing scope value
    item <- fresh (binderName binder)
    ok <- fresh "all"
    p <- expression env Nothing ((binderId binder, item) : scope) predicate
    let loopDoc = D.text ("for " ++ item ++ " in ") <> L.expr (L.method xs "iter" []) <> D.text " " <> L.block
          [ L.Let item (L.method (L.atom item) "clone" [])
          , L.Do (L.If (L.prefix "!" p) (L.Block [L.Semi (L.atom (ok ++ " = false")), L.Semi (L.atom "break")] Nothing) Nothing) ] Nothing
    pure (L.Block [L.Let ("mut " ++ ok) (L.atom "true"), L.Item loopDoc] (Just (L.atom ok)))
  -- raise e: a failure of the Fail ability, as the dynamic raise makes it.
  Perform (Operation ref "raise") [x] | isFail ref -> do
    v <- expression env Nothing scope x
    pure (L.Block [L.Semi (L.call "ls::raise_failure" [L.atom (E.quoted (abilityKey ref)), L.call "ls::fast::Dyn::to_dyn" [borrow v]])]
      (Just (L.atom "unreachable!()")))
  -- An operation of another ability: its bridge, which finds the handler
  -- in the context, over the arguments' dynamic values.
  Perform op args -> do
    bridge <- lift (maybe (Left ("typed Rust: no bridge for the operation " ++ operationName op)) Right (M.lookup (operationId op) (envBridges env)))
    values <- mapM (expression env Nothing scope) args
    temporaries <- mapM (const (fresh "argument")) values
    types <- lift (mapM (rustType env . expressionType) args)
    resultType <- lift (rustType env (expressionType e))
    pure (L.Block ([L.Let (t ++ ": " ++ ty) v | (t, (ty, v)) <- zip temporaries (zip types values)] ++
       [ L.Let "performed" (L.try' (L.method (L.call bridge [L.atom "&mut *ctx", L.vecOf [L.call "ls::fast::Dyn::to_dyn" [L.atom ("&" ++ t)] | t <- temporaries]])
           "map_err" [L.closure "|error|" (L.macroCall "format" [L.atom "\"{}: {error}\"", L.atom (E.quoted (operationName op))])])) ])
       (Just (L.try' (L.call ("<" ++ resultType ++ " as ls::fast::Dyn>::from_dyn") [L.atom "performed"]))))
  -- attempt e: Right of e's value, or Left of the failure it raised.
  Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, TypeArgument result] <- expressionType e -> do
    v <- expression env Nothing scope body
    resultType <- lift (rustType env result)
    failureType' <- lift (rustType env failure)
    pure (L.Match (L.try' (L.call "ls::fast::attempt" [L.atom (E.quoted (abilityKey ref)),
        L.closure ("|| -> ls::Result<" ++ resultType ++ ">") (L.Block [] (Just (L.call "Ok" [v])))]))
      [ Arm "Ok(value)" Nothing (L.atom "ls::Either::Right(value)")
      , Arm "Err(failure)" Nothing (L.call "ls::Either::Left" [L.try' (L.call ("<" ++ failureType' ++ " as ls::fast::Dyn>::from_dyn") [L.atom "failure"])]) ])
  Helper Append [a, b] -> do
    x <- expression env Nothing scope a
    y <- expression env Nothing scope b
    let f = case expressionType a of
          Constructor "Text" [] -> "ls::fast::append_text"
          Constructor "Bytes" [] -> "ls::fast::append_bytes"
          _ -> "ls::fast::append_list"
    pure (L.call f [borrow x, borrow y])
  Helper Slice [x, from, to] -> do
    v <- expression env Nothing scope x
    i <- integerExpression env scope from
    j <- integerExpression env scope to
    let f = case expressionType x of
          Constructor "Text" [] -> "ls::fast::slice_text"
          Constructor "Bytes" [] -> "ls::fast::slice_bytes"
          _ -> "ls::fast::slice_list"
    pure (L.call f [borrow v, borrow i, borrow j])
  Helper At [x, i] -> do
    v <- expression env Nothing scope x
    k <- integerExpression env scope i
    let f = if expressionType x == Constructor "Bytes" [] then "ls::fast::at_bytes" else "ls::fast::at_list"
    pure (L.call f [borrow v, borrow k])
  Helper Range [lo, hi] -> do
    a <- expression env Nothing scope lo
    b <- expression env Nothing scope hi
    case expressionType lo of
      Constructor "Integer" [] -> pure (L.call "ls::fast::range_int" [borrow a, borrow b])
      _ -> pure (L.call "ls::fast::List::from_vec" [L.method (L.Paren (L.Infix 2 ".." a b)) "collect" []])
  Helper Octets [b] -> (\v -> L.call "ls::fast::octets" [borrow v]) <$> expression env Nothing scope b
  Helper BytesOf [xs] -> (\v -> L.call "ls::fast::bytes_of" [borrow v]) <$> expression env Nothing scope xs
  Helper Utf8 [t] -> (\v -> L.call "ls::fast::utf8" [borrow v]) <$> expression env Nothing scope t
  Helper TextOf [n] -> case expressionType n of
    Constructor "Integer" [] -> (\v -> L.call "ls::fast::text_of" [borrow v]) <$> expression env Nothing scope n
    _ -> (\v -> L.call "ls::fast::text" [borrow (L.method v "to_string" [])]) <$> expression env Nothing scope n
  Helper Join [sep, parts] -> do
    a <- expression env Nothing scope sep
    b <- expression env Nothing scope parts
    pure (L.call "ls::fast::join" [borrow a, borrow b])
  _ -> lift (Left ("typed Rust: unsupported expression " ++ take 80 (show (expressionNode e))))
  where
    textTest name a b = do
      x <- expression env Nothing scope a
      y <- expression env Nothing scope b
      pure (L.method x name [L.prefix "&*" y])

orderingName :: Env -> Either String String
orderingName env = maybe (Left "typed Rust: Ordering has no typed form") (Right . (envPrefix env ++))
  (M.lookup (collectionsUnit ++ "::type::Ordering") (envNames env))

constant :: Scalar -> Either String L.Expr
constant s = case s of
  SBool b -> pure (L.atom (if b then "true" else "false"))
  SAbsent "Unit" -> pure (L.atom "()")
  SInteger "Integer" n
    | n >= -(2 ^ (63 :: Int)) && n < 2 ^ (63 :: Int) -> pure (L.call "ls::fast::Int::Small" [L.atom (show n)])
    | otherwise -> pure (L.call "ls::fast::Int::from_big" [L.method (L.method (L.atom (show (show n))) "parse::<ls::BigInt>" []) "unwrap" []])
  SInteger t n | Just r <- lookup t fixedTypes -> pure (L.atom (literal r n))
  SSequence "Text" units -> pure (L.call "ls::fast::text" [L.Laid (E.stringLiteral (map toEnum units))])
  SSequence "Bytes" units -> pure (L.call "ls::fast::bytes" [L.prefix "&" (L.Macro "" "[" "]" [L.atom (show u ++ "u8") | u <- units])])
  _ -> Left ("typed Rust: unsupported constant " ++ show s)
  where
    literal r n
      | r == "i64" && n == -(2 ^ (63 :: Int)) = "i64::MIN"
      | n < 0 = "(" ++ show n ++ r ++ ")"
      | otherwise = show n ++ r

fixedTypes :: [(String, String)]
fixedTypes = [("Int8", "i8"), ("Int16", "i16"), ("Int32", "i32"), ("Int64", "i64"), ("UInt8", "u8"), ("UInt16", "u16"), ("UInt32", "u32"), ("UInt64", "u64")]

-- | Bounds of a fixed integer type.
bounds :: String -> Maybe (Integer, Integer)
bounds t = lookup t [ ("Int8", (-128, 127)), ("Int16", (-32768, 32767)), ("Int32", (-2147483648, 2147483647))
                    , ("Int64", (-(2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1)), ("UInt8", (0, 255)), ("UInt16", (0, 65535))
                    , ("UInt32", (0, 4294967295)), ("UInt64", (0, 2 ^ (64 :: Int) - 1)) ]

-- | An integer expression computed exactly in i128, with a bound on its
-- magnitude in bits, when its operands are bounded.
wide :: Env -> Scope -> Expr -> R (Maybe (L.Expr, Int))
wide env scope e = case (expressionNode e, expressionType e) of
  (Constant (SInteger _ n), _) | abs n < 2 ^ (62 :: Int) ->
    pure (Just (L.atom (if n < 0 then "(" ++ show n ++ "i128)" else show n ++ "i128"), max 1 (bitLength (abs n))))
  (_, Constructor t []) | Just _ <- lookup t fixedTypes -> do
    x <- expression env Nothing scope e
    pure (Just (L.cast x "i128", 64))
  (Convert _ (Constructor "Integer" []) value, _) -> wide env scope value
  (Helper Length [x], _) -> do
    v <- expression env Nothing scope x
    pure (Just (L.cast (lengthOf (expressionType x) v) "i128", 64))
  (Unary Negate a, _) -> fmap (\(x, b) -> (L.prefix "-" x, b + 1)) <$> wide env scope a
  (Binary op (Numeric (Constructor "Integer" [])) a b, _) | op `elem` [Add, Subtract, Multiply] -> do
    l <- wide env scope a
    r <- wide env scope b
    pure $ case (l, r) of
      (Just (x, bx), Just (y, by)) ->
        let bits = if op == Multiply then bx + by else max bx by + 1
            symbol = case op of Add -> "+"; Subtract -> "-"; _ -> "*"
        in if bits <= 126 then Just (L.infixOp symbol x y, bits) else Nothing
      _ -> Nothing
  _ -> pure Nothing
  where
    bitLength :: Integer -> Int
    bitLength n = length (takeWhile (> 0) (iterate (`div` 2) n))

lengthOf :: Type -> L.Expr -> L.Expr
lengthOf ty v = case ty of
  Constructor "Text" [] -> L.call "ls::fast::text_length" [borrow v]
  _ -> L.method v "len" []

-- | An expression of type Integer, as an ls::fast::Int.
integerExpression :: Env -> Scope -> Expr -> R L.Expr
integerExpression env scope e = do
  w <- wide env scope e
  case w of
    Just (x, _) -> pure (L.call "ls::fast::Int::from_i128" [x])
    Nothing -> case expressionNode e of
      Unary Negate a -> (\x -> L.method x "neg" []) <$> asInt a
      Binary op _ a b -> do
        x <- asInt a
        y <- asInt b
        pure $ case op of
          Add -> L.method x "add" [borrow y]
          Subtract -> L.method x "sub" [borrow y]
          Multiply -> L.method x "mul" [borrow y]
          Quotient -> L.try' (L.method x "quot" [borrow y])
          Remainder -> L.try' (L.method x "rem" [borrow y])
          _ -> L.try' (L.method x "pow" [borrow y])
      Helper Length [x] -> do
        v <- expression env Nothing scope x
        pure (L.call "ls::fast::Int::from" [lengthOf (expressionType x) v])
      _ -> expression env Nothing scope e
  where
    asInt a = case expressionType a of
      Constructor "Integer" [] -> integerExpression env scope a
      _ -> (\x -> L.call "ls::fast::Int::from" [x]) <$> expression env Nothing scope a

binary :: Env -> Scope -> Expr -> R L.Expr
binary env scope e = case expressionNode e of
  Binary op (Structural _) a b -> do
    x <- expression env Nothing scope a
    y <- expression env Nothing scope b
    pure (L.infixOp (if op == Equal then "==" else "!=") x y)
  Binary op (Numeric _) a b | isComparison op -> do
    let symbol = case op of Equal -> "=="; NotEqual -> "!="; Less -> "<"; LessEqual -> "<="; Greater -> ">"; _ -> ">="
        same = expressionType a == expressionType b && maybe False (const True) (fixedName (expressionType a))
    if same
      then do
        x <- expression env Nothing scope a
        y <- expression env Nothing scope b
        pure (L.infixOp symbol x y)
      else do
        l <- wide env scope a
        r <- wide env scope b
        case (l, r) of
          (Just (x, _), Just (y, _)) -> pure (L.infixOp symbol x y)
          _ -> do
            x <- integerExpression env scope (widen a)
            y <- integerExpression env scope (widen b)
            let test = case op of Equal -> "is_eq"; NotEqual -> "is_ne"; Less -> "is_lt"; LessEqual -> "is_le"; Greater -> "is_gt"; _ -> "is_ge"
            pure (L.method (L.call "ls::fast::POrd::pcmp" [borrow x, borrow y]) test [])
  _ -> integerExpression env scope e
  where
    fixedName (Constructor n []) = lookup n fixedTypes
    fixedName _ = Nothing
    widen a = case expressionType a of
      Constructor "Integer" [] -> a
      _ -> a { expressionType = Constructor "Integer" [], expressionNode = Convert Explicit (Constructor "Integer" []) a }

convert :: Env -> Scope -> Type -> Expr -> R L.Expr
convert env scope target value = case (target, expressionType value) of
  (Constructor "Integer" [], _) -> integerExpression env scope (value { expressionType = target, expressionNode = Convert Explicit target value })
  (Constructor t [], Constructor s []) | Just r <- lookup t fixedTypes -> do
    case (bounds t, bounds s) of
      (Just (lo, hi), Just (slo, shi)) | slo >= lo && shi <= hi -> do
        x <- expression env Nothing scope value
        pure (L.cast x r)
      _ -> do
        w <- wide env scope value
        case w of
          Just (x, _) -> pure (L.try' (L.call ("ls::fast::narrow::<" ++ r ++ ">") [x, L.atom (show t)]))
          Nothing -> do
            x <- integerExpression env scope (if s == "Integer" then value else value { expressionType = Constructor "Integer" [], expressionNode = Convert Explicit (Constructor "Integer" []) value })
            pure (L.try' (L.method x ("narrow::<" ++ r ++ ">") [L.atom (show t)]))
  _ -> lift (Left ("typed Rust: unsupported conversion to " ++ show target))

construct :: Env -> Type -> Id -> [L.Expr] -> [Expr] -> R L.Expr
construct env ty tag values args = case (idText tag, values) of
  ("List::Nil", []) -> pure (L.call "ls::fast::List::nil" [])
  ("List::Cons", [h, t]) -> pure (L.call "ls::fast::List::cons" [h, t])
  ("Maybe::Absent", []) -> pure (L.atom "None")
  ("Maybe::Present", [x]) -> pure (L.call "Some" [x])
  ("Either::Left", [x]) -> pure (L.call "ls::Either::Left" [x])
  ("Either::Right", [x]) -> pure (L.call "ls::Either::Right" [x])
  (_, [items]) | Just ("KeyVal", _) <- collectionArguments ty -> do
    pairs <- lift (entryPairs env)
    pure (L.call "ls::fast::Map::from_entries" [L.method (L.method items "iter" []) "map" [L.atom pairs]])
  (_, [items]) | Just ("Set", _) <- collectionArguments ty ->
    pure (L.call "ls::fast::Set::from_iter" [L.method (L.method items "iter" []) "cloned" []])
  _ -> case M.lookup tag (envConstructors env) of
    Just (d, c) -> do
      let name = envPrefix env ++ envNames env M.! idText (dataId d)
          variant = name ++ "Node::" ++ variantName c
      pure $ if fieldless d then L.atom (name ++ "::" ++ variantName c)
        else L.call name [L.call "std::sync::Arc::new" [if null values then L.atom variant else L.call variant values]]
    Nothing -> lift (Left ("typed Rust: unknown constructor " ++ idText tag ++ " " ++ show (length args)))

-- | The function from an Entry to its key and value.
entryPairs :: Env -> Either String String
entryPairs env = case M.lookup (collectionsUnit ++ "::type::Entry") (envNames env) of
  Just _ -> pure (envPrefix env ++ "entry_pair")
  Nothing -> Left "typed Rust: Entry has no typed form"

-- | The function from a key and value to an Entry.
entryOf :: Env -> Either String String
entryOf env = case M.lookup (collectionsUnit ++ "::type::Entry") (envNames env) of
  Just _ -> pure (envPrefix env ++ "make_entry")
  Nothing -> Left "typed Rust: Entry has no typed form"

intrinsicCall :: Env -> Intrinsic -> [(L.Expr, Type)] -> R L.Expr
intrinsicCall env intrinsic args = case (intrinsic, map fst args) of
  (KeyValOf, [es]) | L.flat es == Just "ls::fast::List::nil()" -> pure (L.call "ls::fast::Map::new" [])
  (KeyValOf, [es]) -> do
    pairs <- lift (entryPairs env)
    pure (L.call "ls::fast::Map::from_entries" [L.method (L.method es "iter" []) "map" [L.atom pairs]])
  (KeyValLookup, [k, m]) -> pure (L.method (L.method m "get" [borrow k]) "cloned" [])
  (KeyValPut, [k, v, m]) -> pure (L.method m "insert" [k, v])
  (KeyValDelete, [k, m]) -> pure (L.method m "remove" [borrow k])
  (KeyValKeys, [m]) -> pure (L.method m "to_list" [L.closure "|k, _|" (L.method (L.atom "k") "clone" [])])
  (KeyValValues, [m]) -> pure (L.method m "to_list" [L.closure "|_, v|" (L.method (L.atom "v") "clone" [])])
  (KeyValEntries, [m]) -> do
    entry <- lift (entryOf env)
    pure (L.method m "to_list" [L.atom entry])
  (SetOf, [xs]) | L.flat xs == Just "ls::fast::List::nil()" -> pure (L.call "ls::fast::Set::new" [])
  (SetOf, [xs]) -> pure (L.call "ls::fast::Set::from_iter" [L.method (L.method xs "iter" []) "cloned" []])
  (SetMember, [x, s]) -> pure (L.method s "contains" [borrow x])
  (SetInsert, [x, s]) -> pure (L.method s "insert" [x])
  (SetRemove, [x, s]) -> pure (L.method s "remove" [borrow x])
  (SetUnion, [s, t]) -> pure (L.method s "union" [borrow t])
  (SetIntersection, [s, t]) -> pure (L.method s "intersection" [borrow t])
  (SetDifference, [s, t]) -> pure (L.method s "difference" [borrow t])
  _ -> lift (Left ("typed Rust: bad intrinsic " ++ show intrinsic))

match :: Env -> Maybe (Int, [String]) -> Scope -> Expr -> [MatchCase] -> Type -> R L.Expr
match env selfCall scope value cases _ = do
  let ty = expressionType value
      used c b = binderId b `elem` freeBinders (caseBody c)
      bindNames c = forM (caseBinders c) $ \b -> if used c b then Just <$> fresh (binderName b) else pure Nothing
      body c names = expression env selfCall ([(binderId b, n) | (b, Just n) <- zip (caseBinders c) names] ++ scope) (caseBody c)
      -- Fields are borrowed from the matched value, and cloned as bound.
      bound c names = do
        fields <- mapM (\n -> maybe (pure Nothing) (\_ -> Just <$> fresh "field") n) names
        b <- body c names
        let clones = [L.Let n (L.method (L.atom f) "clone" []) | (Just n, Just f) <- zip names fields]
        pure (map (maybe "_" id) fields, L.letIn clones b)
  -- The matched value: a local is borrowed where it is; anything else is
  -- bound first.
  (subject, wrap) <- case expressionNode value of
    Local i | Just name <- lookup i scope -> pure (name, id)
    _ -> do
      v <- expression env Nothing scope value
      t <- fresh "matched"
      pure (t, \m -> L.Block [L.Let t v] (Just m))
  let matchOn scrutinee arms = wrap (L.Match (L.atom scrutinee) arms)
      arm p b = Arm p Nothing b
  case ty of
    Constructor "Maybe" _ -> do
      arms <- forM cases $ \c -> do
        names <- bindNames c
        (fields, b) <- bound c names
        pure $ case (idText (caseConstructor c), fields) of
          ("Maybe::Absent", _) -> arm "None" b
          (_, [f]) -> arm ("Some(" ++ f ++ ")") b
          _ -> arm "_" (L.atom "unreachable!()")
      pure (matchOn ("&" ++ subject) arms)
    Constructor "Either" _ -> do
      arms <- forM cases $ \c -> do
        names <- bindNames c
        (fields, b) <- bound c names
        let side = if idText (caseConstructor c) == "Either::Left" then "Left" else "Right"
        pure (arm ("ls::Either::" ++ side ++ "(" ++ concat (take 1 fields) ++ ")") b)
      pure (matchOn ("&" ++ subject) arms)
    Constructor "List" _ -> do
      arms <- forM cases $ \c -> do
        names <- bindNames c
        (fields, b) <- bound c names
        pure $ case (idText (caseConstructor c), fields) of
          ("List::Nil", _) -> arm "None" b
          (_, [h, t]) -> arm ("Some((" ++ h ++ ", " ++ t ++ "))") b
          _ -> arm "_" (L.atom "unreachable!()")
      pure (wrap (L.Match (L.method (L.atom subject) "uncons" []) arms))
    _ | Just (kind, _) <- collectionArguments ty, [c] <- cases, [b] <- caseBinders c -> do
          items <- fresh (binderName b)
          converted <- if kind == "KeyVal"
            then do
              entry <- lift (entryOf env)
              pure (L.method (L.atom subject) "to_list" [L.atom entry])
            else pure (L.method (L.atom subject) "to_list" [])
          rest <- expression env selfCall ((binderId b, items) : scope) (caseBody c)
          pure (wrap (L.letIn [L.Let items converted] rest))
    Constructor n _ | Just d <- M.lookup n (envData env) -> do
      let name = envPrefix env ++ envNames env M.! n
      if fieldless d
        then do
          arms <- forM cases $ \c -> do
            b <- body c []
            con <- lift (maybe (Left "typed Rust: unknown constructor") (Right . snd) (M.lookup (caseConstructor c) (envConstructors env)))
            pure (arm (name ++ "::" ++ variantName con) b)
          pure (matchOn subject arms)
        else do
          arms <- forM cases $ \c -> do
            names <- bindNames c
            (fields, b) <- bound c names
            con <- lift (maybe (Left "typed Rust: unknown constructor") (Right . snd) (M.lookup (caseConstructor c) (envConstructors env)))
            let patternText = name ++ "Node::" ++ variantName con ++
                  (if null names then "" else "(" ++ intercalate ", " fields ++ ")")
            pure (arm patternText b)
          pure (matchOn ("&*" ++ subject ++ ".0") arms)
    _ -> lift (Left ("typed Rust: cannot match on " ++ show ty))


-- | The typed data types whose public form converts directly: not recursive
-- (so never boxed), not a container the public data represents in another
-- shape (a Queue, Stack, Deque or Duration), and with every field direct.
directDeclarations :: [DataDeclaration] -> [DataDeclaration] -> S.Set String
directDeclarations declarations datas = go (S.fromList (map (idText . dataId) candidates))
  where
    candidates = [ d | d <- datas, collectionContainer (idText (dataId d)) == Nothing, not (isDurationType (idText (dataId d)))
                 , not (any (Native.rustFieldBoxed declarations (dataId d) . binderType) (concatMap constructorFields (dataConstructors d)))
                 , not (recursive d) ]
    recursive d = idText (dataId d) `S.member` reach S.empty (fieldNames d)
    fieldNames d = concatMap (namesIn . binderType) (concatMap constructorFields (dataConstructors d))
    namesIn t = case t of
      Constructor n args -> n : concat [namesIn x | TypeArgument x <- args]
      _ -> []
    byName = M.fromList [(idText (dataId d), d) | d <- declarations]
    reach seen [] = seen
    reach seen (n : rest)
      | n `S.member` seen = reach seen rest
      | otherwise = reach (S.insert n seen) (maybe [] fieldNames (M.lookup n byName) ++ rest)
    go known =
      let kept = S.fromList [ idText (dataId d) | d <- candidates, idText (dataId d) `S.member` known
                            , all (directField known (dataParameters d) . binderType) (concatMap constructorFields (dataConstructors d)) ]
      in if kept == known then known else go kept
    directField known parameters t = case t of
      TypeVariable v -> v `elem` parameters
      _ -> directTypeWith known parameters t

directType :: S.Set String -> Type -> Bool
directType known = directTypeWith known []

directTypeWith :: S.Set String -> [Id] -> Type -> Bool
directTypeWith known parameters t = case t of
  TypeVariable v -> v `elem` parameters
  Constructor n [] | n `elem` ["Bool", "Unit", "Integer", "Text", "Bytes"] || n `elem` map fst fixedTypes -> True
  Constructor n [TypeArgument a] | n `elem` ["List", "Maybe"] -> directTypeWith known parameters a
  Constructor "Either" [TypeArgument a, TypeArgument b] -> directTypeWith known parameters a && directTypeWith known parameters b
  _ | Just (_, args) <- collectionArguments t -> all (directTypeWith known parameters) args
  Constructor n args -> n `S.member` known && all (\a -> case a of TypeArgument x -> directTypeWith known parameters x; _ -> False) args
  _ -> False

-- | A typed data type's Public impl: to and from its public form.
publicDoc :: Env -> [DataDeclaration] -> DataDeclaration -> Either String D.Doc
publicDoc env declarations d = do
  let name = envNames env M.! idText (dataId d)
      parameters = parameterNames d
      generics = if null parameters then "" else "<" ++ intercalate ", " (map snd parameters) ++ ">"
      bounded = if null parameters then "" else "<" ++ intercalate ", " [p ++ ": ls::fast::Public" | (_, p) <- parameters] ++ ">"
      nativeParams = [(v, p ++ "::Native") | (v, p) <- parameters]
      node = name ++ "Node"
      variants = dataConstructors d
      line = D.text
      field f = rustIdentifier (binderName f)
      variant c = rustIdentifier (constructorName c)
      count c = length (constructorFields c)
  native <- Native.rustDataTypeWithParameters declarations nativeParams (Constructor (idText (dataId d)) [TypeArgument (TypeVariable p) | p <- dataParameters d])
  let base = takeWhile (/= '<') native
      single = length variants == 1
      nativeOf c = if single then base else base ++ "::" ++ variant c
      nativeRecord c values = L.struct (nativeOf c) [(field f, v) | (f, v) <- zip (constructorFields c) values]
      typedOf c values
        | fieldless d = L.atom (name ++ "::" ++ variantName c)
        | otherwise = L.call name [L.call "std::sync::Arc::new" [if null values then L.atom (node ++ "::" ++ variantName c) else L.call (node ++ "::" ++ variantName c) values]]
      typedPattern c = if fieldless d then name ++ "::" ++ variantName c
        else node ++ "::" ++ variantName c ++ (if count c == 0 then "" else "(" ++ intercalate ", " ["f" ++ show k | k <- [0 .. count c - 1]] ++ ")")
      toArm c = Arm (typedPattern c) Nothing (nativeRecord c [L.method (L.atom ("f" ++ show k)) "to_native" [] | k <- [0 .. count c - 1]])
      -- The native record's pattern binds each field to f0, f1, ...
      fromPattern c = nativeRecord c [L.atom ("f" ++ show k) | k <- [0 .. count c - 1]]
      fromArm c = ArmOf (fromPattern c) Nothing (typedOf c [L.call "ls::fast::Public::from_native" [L.atom ("f" ++ show k)] | k <- [0 .. count c - 1]])
      scrutinee = if null variants then "*self" else if fieldless d then "self" else "&*self.0"
  pure (line ("impl" ++ bounded ++ " ls::fast::Public for " ++ name ++ generics ++ " ") <> D.block 4 (D.joinWith D.hardline
    [ line ("type Native = " ++ native ++ ";")
    , L.function "fn to_native" ["&self"] "Self::Native" (L.expr (L.Match (L.atom scrutinee) (map toArm variants)))
    , L.function "fn from_native" ["native: Self::Native"] "Self" (L.expr (L.Match (L.atom "native")
        (map fromArm variants ++ [Arm "_" Nothing (L.atom "unreachable!()") | null variants]))) ]))

-- | A name as RustData writes it: a keyword is a raw identifier.
rustIdentifier :: String -> String
rustIdentifier name
  | name `elem` words "as async await break const continue dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return static struct trait true type unsafe use where while abstract become box do final macro override priv typeof unsized virtual yield try gen union" = "r#" ++ name
  | otherwise = name

