-- | Typed Rust for checked definitions (see LawSpec.Typed.Plan): each typed
-- data type is a Rust type, each class of typed definitions one function over
-- them, and the dynamic entry points convert at the boundary. Lists, KeyVal
-- and Set are lawspec_runtime::fast's persistent structures; data with
-- fields is shared behind an Arc, so passing and keeping a value never copies
-- it. ref:DEC-typed-native-definitions
module LawSpec.Typed.Rust (RustTyped(..), emitRustTyped) where

import Control.Monad (forM)
import Control.Monad.State.Strict
import Data.Char (isAlphaNum, isUpper, toLower)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S
import LawSpec.Collections (collectionsUnit)
import LawSpec.Core
import LawSpec.Scalar
import LawSpec.Typed.Plan
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.RustExpr as E
import qualified LawSpec.RustData as Native
import LawSpec.Collections (collectionContainer)
import LawSpec.Time (isDurationType)
import LawSpec.RustAbilityPaths (performBridges)

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

type R = StateT Int (Either String)

fresh :: String -> R String
fresh base = do
  n <- get
  put (n + 1)
  pure (sanitize base ++ "_" ++ show n)

-- | A name as written, made a Rust identifier.
identifier :: String -> String
identifier name = case [c | c <- name, isAlphaNum c || c == '_'] of
  [] -> "f"
  cleaned -> cleaned

sanitize :: String -> String
sanitize name = case [c | c <- map lower name, isAlphaNum c || c == '_'] of
  [] -> "v"
  cleaned@(c : _) | isAlphaNum c && not (c >= '0' && c <= '9') -> cleaned
  cleaned -> "v" ++ cleaned
  where lower c = if isUpper c then toLower c else c

emitRustTyped :: [DataDeclaration] -> [Unit] -> Either String RustTyped
emitRustTyped declarations units = do
  let plan = typedPlanPerforming scalarTypes declarations units
      datas = typedData plan
      names = dataNames datas
      functions = M.fromList [ (c, functionName c d) | (c, d) <- typedRepresentatives plan ]
      env = Env plan names (M.fromList [(idText (dataId d), d) | d <- datas])
        (M.fromList [(constructorId c, (d, c)) | d <- datas, c <- dataConstructors d]) functions ""
        (M.fromList [(i, "crate::" ++ path) | (i, path) <- performBridges units])
      outside = env { envPrefix = modulePath }
  dataDocs <- mapM (dataDoc env) datas
  functionDocs <- mapM (\(c, d) -> functionDoc env c d) (typedRepresentatives plan)
  pairFields <- pairFieldsDoc env
  let directData = directDeclarations declarations datas
  publicDocs <- mapM (publicDoc env declarations) [d | d <- datas, idText (dataId d) `S.member` directData]
  let body = D.text "#![allow(unused_variables, unused_mut, unused_parens, unused_braces, unreachable_code, non_snake_case, non_camel_case_types, dead_code, clippy::all)]" <> D.hardline <>
        D.text "use crate::lawspec_runtime as ls;" <> D.hardline <>
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
    , rustTypedValue = \e -> evalStateT (expression outside Nothing [] e) 0
    , rustPairFields = modulePath ++ "pair_fields"
    , rustTypedNative = directType directData
    , rustTypedPlan = plan }
  where
    functionName _ d = identifier (shortName (declarationName (definitionDeclaration d))) ++ "_" ++ stableSuffix (declarationId (definitionDeclaration d))
    shortName name =
      let unprefixed = if "lawspec_" `isPrefixOf` name then drop 8 name else name
      in reverse (dropHash (reverse unprefixed))
    dropHash reversed = case span (`elem` ("0123456789abcdef" :: String)) reversed of
      (digits@(_ : _), '_' : rest) | length digits >= 8 -> rest
      _ -> reversed

-- | Rust names for the typed data types: the declared name, unless another
-- typed type or a name the generated code uses has it.
dataNames :: [DataDeclaration] -> M.Map String String
dataNames datas = M.fromList (snd (foldl pick (reserved, []) datas))
  where
    reserved = S.fromList ["Option", "Result", "Some", "None", "Ok", "Err", "Vec", "Box", "String", "Arc", "Self", "Ordering", "Either", "List", "Map", "Set", "Int", "Text", "Bytes", "Dyn", "POrd", "ls", "std", "crate", "super"]
    pick (taken, acc) d =
      let base = [c | c <- dataName d, isAlphaNum c || c == '_']
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
  fieldTypes <- forM variants $ \c -> mapM (rustTypeP env { envPrefix = "" } parameters . binderType) (constructorFields c)
  if null variants then pure (header <> D.hardline <>
    line "#[derive(Clone, Copy, PartialEq, Eq, Debug)]" <> D.hardline <> line ("pub enum " ++ name ++ " {}") <> D.hardline <>
    line ("impl POrd for " ++ name ++ " ") <> D.block 4 (line "fn pcmp(&self, _: &Self) -> std::cmp::Ordering { match *self {} }") <> D.hardline <>
    line ("impl Dyn for " ++ name ++ " ") <> D.block 4 (D.joinWith D.hardline
      [ line "fn to_dyn(&self) -> ls::Value { match *self {} }"
      , line ("fn from_dyn(_: ls::Value) -> ls::Result<Self> { Err(" ++ E.quoted ("no value of " ++ dataName d) ++ ".into()) }") ]))
  else if fieldless d then pure (header <> D.hardline <>
    line "#[derive(Clone, Copy, PartialEq, Eq, Debug)]" <> D.hardline <>
    line ("pub enum " ++ name ++ " ") <> D.block 4 (D.joinWith D.hardline [line (variantName c ++ ",") | c <- variants]) <> D.hardline <>
    line ("impl " ++ name ++ " ") <> D.block 4 (line "fn rank(&self) -> u32 " <> D.block 4 (line "match self " <> D.block 4
      (D.joinWith D.hardline [line (name ++ "::" ++ variantName c ++ " => " ++ show (rank c) ++ ",") | c <- variants]))) <> D.hardline <>
    line ("impl POrd for " ++ name ++ " ") <> D.block 4 (line "fn pcmp(&self, other: &Self) -> std::cmp::Ordering { self.rank().cmp(&other.rank()) }") <> D.hardline <>
    line ("impl Dyn for " ++ name ++ " ") <> D.block 4 (D.joinWith D.hardline
      [ line "fn to_dyn(&self) -> ls::Value " <> D.block 4 (line "let tag = match self " <> D.block 4
          (D.joinWith D.hardline [line (name ++ "::" ++ variantName c ++ " => " ++ tagOf c ++ ",") | c <- variants]) <> line ";" <> D.hardline <>
          line "ls::Value::Data(tag.into(), vec![])")
      , line "fn from_dyn(value: ls::Value) -> ls::Result<Self> " <> D.block 4 (line "match ls::fast::tag(&value)? " <> D.block 4
          (D.joinWith D.hardline ([line (tagOf c ++ " => Ok(" ++ name ++ "::" ++ variantName c ++ "),") | c <- variants] ++
            [line ("other => Err(format!(\"expected " ++ dataName d ++ ", found {other}\")),")]))) ]))
  else do
    let node = name ++ "Node"
        patternOf prefix c = node ++ "::" ++ variantName c ++ (if null (constructorFields c) then "" else
          "(" ++ intercalate ", " [prefix ++ show k | k <- [0 .. length (constructorFields c) - 1]] ++ ")")
        compareArm c = line ("(" ++ patternOf "a" c ++ ", " ++ patternOf "b" c ++ ") => ") <>
          (if null (constructorFields c) then line "std::cmp::Ordering::Equal," else
            line (foldl1 (\acc x -> acc ++ ".then_with(|| " ++ x ++ ")")
              ["a" ++ show k ++ ".pcmp(b" ++ show k ++ ")" | k <- [0 .. length (constructorFields c) - 1]] ++ ","))
        wildcard c = node ++ "::" ++ variantName c ++ (if null (constructorFields c) then "" else
          "(" ++ intercalate ", " (replicate (length (constructorFields c)) "_") ++ ")")
        toDynArm c = line (patternOf "f" c ++ " => ls::Value::Data(" ++ tagOf c ++ ".into(), vec![" ++
          intercalate ", " ["f" ++ show k ++ ".to_dyn()" | k <- [0 .. length (constructorFields c) - 1]] ++ "]),")
        fromDynArm c ts = line (tagOf c ++ " => ") <> D.block 4 (D.joinWith D.hardline
          ([line ("let mut fields = ls::fast::fields(value, " ++ tagOf c ++ ", " ++ show (length ts) ++ ")?;") | not (null ts)] ++
           [line ("Ok(" ++ name ++ "(std::sync::Arc::new(" ++ node ++ "::" ++ variantName c ++
             (if null ts then "" else "(" ++ intercalate ", " ["<" ++ t ++ " as Dyn>::from_dyn(fields.next().unwrap())?" | t <- ts] ++ ")") ++ ")))")]))
    pure (header <> D.hardline <>
      line "#[derive(Clone, PartialEq, Eq, Debug)]" <> D.hardline <>
      line ("pub struct " ++ name ++ generics ++ "(pub std::sync::Arc<" ++ node ++ generics ++ ">);") <> D.hardline <>
      line "#[derive(PartialEq, Eq, Debug)]" <> D.hardline <>
      line ("pub enum " ++ node ++ generics ++ " ") <> D.block 4 (D.joinWith D.hardline
        [line (variantName c ++ (if null ts then "" else "(" ++ intercalate ", " ts ++ ")") ++ ",") | (c, ts) <- zip variants fieldTypes]) <> D.hardline <>
      line ("impl" ++ generics ++ " " ++ name ++ generics ++ " ") <> D.block 4 (line "fn rank(&self) -> u32 " <> D.block 4 (line "match &*self.0 " <> D.block 4
        (D.joinWith D.hardline [line (wildcard c ++ " => " ++ show (rank c) ++ ",") | c <- variants]))) <> D.hardline <>
      line ("impl" ++ bound "POrd" ++ " POrd for " ++ name ++ generics ++ " ") <> D.block 4
        (line "fn pcmp(&self, other: &Self) -> std::cmp::Ordering " <> D.block 4
          (line "if std::sync::Arc::ptr_eq(&self.0, &other.0) { return std::cmp::Ordering::Equal; }" <> D.hardline <>
           line "match (&*self.0, &*other.0) " <> D.block 4 (D.joinWith D.hardline
             (map compareArm variants ++ [line "_ => self.rank().cmp(&other.rank()),"])))) <> D.hardline <>
      line ("impl" ++ bound "Dyn" ++ " Dyn for " ++ name ++ generics ++ " ") <> D.block 4 (D.joinWith D.hardline
        [ line "fn to_dyn(&self) -> ls::Value " <> D.block 4 (line "match &*self.0 " <> D.block 4 (D.joinWith D.hardline (map toDynArm variants)))
        , line "fn from_dyn(value: ls::Value) -> ls::Result<Self> " <> D.block 4 (line "match ls::fast::tag(&value)? " <> D.block 4
            (D.joinWith D.hardline (zipWith fromDynArm variants fieldTypes ++
              [line ("other => Err(format!(\"expected " ++ dataName d ++ ", found {other}\")),")]))) ]))

pairFieldsDoc :: Env -> Either String [D.Doc]
pairFieldsDoc env = pure (pair ++ entry)
  where
    pair = case M.lookup (collectionsUnit ++ "::type::Pair") (envNames env) of
      Nothing -> []
      Just name -> [D.text "/// A handler clause's result and next state." <> D.hardline <>
        D.text ("pub fn pair_fields<A: Clone, B: Clone>(pair: " ++ name ++ "<A, B>) -> (A, B) ") <> D.block 4
          (D.text ("match &*pair.0 { " ++ name ++ "Node::Pair(a, b) => (a.clone(), b.clone()) }"))]
    entry = case M.lookup (collectionsUnit ++ "::type::Entry") (envNames env) of
      Nothing -> []
      Just name ->
        [ D.text ("pub fn entry_pair<K: Clone, V: Clone>(entry: &" ++ name ++ "<K, V>) -> (K, V) ") <> D.block 4
            (D.text ("match &*entry.0 { " ++ name ++ "Node::Entry(k, v) => (k.clone(), v.clone()) }"))
        , D.text ("pub fn make_entry<K: Clone, V: Clone>(k: &K, v: &V) -> " ++ name ++ "<K, V> ") <> D.block 4
            (D.text (name ++ "(std::sync::Arc::new(" ++ name ++ "Node::Entry(k.clone(), v.clone())))")) ]

functionDoc :: Env -> Int -> Definition -> Either String D.Doc
functionDoc env c d = flip evalStateT 0 $ do
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
    Just intrinsic -> intrinsicCall env intrinsic [(D.text l, ty) | ((_, l, _), ty) <- zip params (map binderType (definitionArguments d))]
    Nothing -> expression env selfCall scope (definitionBody d)
  let looping = hasTailSelf env c (definitionBody d)
      contextual = isContextual (envPlan env) (declarationId declaration)
      signature = D.text ("pub fn " ++ name) <> D.delimitTrailing 4 "(" ")"
        ([D.text "ctx: &mut ls::Context" | contextual] ++ [D.text ((if looping then "mut " else "") ++ l ++ ": " ++ t) | (_, l, t) <- params]) <>
        D.text (" -> ls::Result<" ++ resultType ++ "> ")
      comment = D.text ("/// " ++ idText (declarationId declaration))
  pure (comment <> D.hardline <> signature <> D.block 4
    (if looping then D.text "loop " <> D.block 4 (D.text "return Ok(" <> body <> D.text ");") else D.text "Ok(" <> body <> D.text ")"))

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

-- | An expression of a typed type; selfCall is the enclosing function's class
-- and parameters while the expression is in tail position.
expression :: Env -> Maybe (Int, [String]) -> Scope -> Expr -> R D.Doc
expression env selfCall scope e = case expressionNode e of
  Constant s -> lift (constant s)
  Local i -> do
    name <- lift (maybe (Left ("typed Rust: unbound local " ++ idText i)) Right (lookup i scope))
    pure (D.text (if isCopy env (expressionType e) then name else name ++ ".clone()"))
  Let binder value body -> do
    v <- expression env Nothing scope value
    local <- fresh (binderName binder)
    rest <- expression env selfCall ((binderId binder, local) : scope) body
    pure (D.block 4 (D.text ("let " ++ local ++ " = ") <> v <> D.text ";" <> D.hardline <> rest))
  If c a b -> do
    cond <- expression env Nothing scope c
    yes <- expression env selfCall scope a
    no <- expression env selfCall scope b
    pure (D.text "if " <> cond <> D.text " " <> D.block 4 yes <> D.text " else " <> D.block 4 no)
  Helper Select [c, a, b] -> expression env selfCall scope (e { expressionNode = If c a b })
  ShortCircuit op a b -> do
    l <- expression env Nothing scope a
    r <- expression env Nothing scope b
    pure (D.text "(" <> l <> D.text (if op == And then " && " else " || ") <> r <> D.text ")")
  Unary Not a -> (\x -> D.text "!" <> paren x) <$> expression env Nothing scope a
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
        pure (D.block 4 (D.joinWith D.hardline
          ([D.text ("let " ++ t ++ " = ") <> v <> D.text ";" | (t, v) <- zip temporaries values] ++
           [D.text (p ++ " = " ++ t ++ ";") | ((p, _), t) <- zip changed temporaries] ++ [D.text "continue"])))
    | otherwise -> do
        c <- lift (maybe (Left ("typed Rust: untyped callee " ++ idText i)) Right (definitionClass (envPlan env) i))
        let name = envPrefix env ++ envFunctions env M.! c
        values <- mapM (expression env Nothing scope) args
        if isContextual (envPlan env) i
          then do
            -- The arguments first, so the context is borrowed once at a time.
            temporaries <- mapM (const (fresh "argument")) values
            types <- lift (mapM (rustType env . expressionType) args)
            pure (D.block 4 (D.joinWith D.hardline
              ([D.text ("let " ++ t ++ ": " ++ ty ++ " = ") <> v <> D.text ";" | (t, (ty, v)) <- zip temporaries (zip types values)] ++
               [D.text name <> D.delimitTrailing 4 "(" ")" (D.text "&mut *ctx" : map D.text temporaries) <> D.text "?"])))
          else pure (D.text name <> D.delimitTrailing 4 "(" ")" values <> D.text "?")
  Helper Compare [a, b] -> do
    x <- expression env Nothing scope a
    y <- expression env Nothing scope b
    ordering <- lift (orderingName env)
    pure (D.text "match ls::fast::POrd::pcmp(&" <> x <> D.text ", &" <> y <> D.text ") " <> D.block 4 (D.joinWith D.hardline
      [D.text ("std::cmp::Ordering::" ++ o ++ " => " ++ ordering ++ "::" ++ o ++ ",") | o <- ["Less", "Equal", "Greater"]]))
  Helper Length [_] -> integerExpression env scope e
  Helper Unreachable _ -> pure (D.text "return Err(\"unreachable branch reached\".into())")
  Helper Checked _ -> pure (D.text "true")
  Helper StartsWith [a, b] -> textTest "starts_with" a b
  Helper EndsWith [a, b] -> textTest "ends_with" a b
  Helper TextContains [a, b] -> textTest "contains" a b
  Helper RegexMatches [a, b] -> do
    p <- expression env Nothing scope a
    t <- expression env Nothing scope b
    pure (D.text "ls::regex_matches(&" <> p <> D.text ", &" <> t <> D.text ")?")
  AllElements value binder predicate -> do
    xs <- expression env Nothing scope value
    item <- fresh (binderName binder)
    ok <- fresh "all"
    p <- expression env Nothing ((binderId binder, item) : scope) predicate
    pure (D.block 4 (D.joinWith D.hardline
      [ D.text ("let mut " ++ ok ++ " = true;")
      , D.text ("for " ++ item ++ " in ") <> xs <> D.text ".iter() " <> D.block 4
          (D.text ("let " ++ item ++ " = " ++ item ++ ".clone();") <> D.hardline <>
           D.text "if !" <> paren p <> D.text (" { " ++ ok ++ " = false; break; }"))
      , D.text ok ]))
  -- raise e: a failure of the Fail ability, as the dynamic raise makes it.
  Perform (Operation ref "raise") [x] | isFail ref -> do
    v <- expression env Nothing scope x
    pure (D.block 4 (D.text ("ls::raise_failure(" ++ E.quoted (abilityKey ref) ++ ", ls::fast::Dyn::to_dyn(&") <> v <> D.text "));" <> D.hardline <> D.text "unreachable!()"))
  -- An operation of another ability: its bridge, which finds the handler
  -- in the context, over the arguments' dynamic values.
  Perform op args -> do
    bridge <- lift (maybe (Left ("typed Rust: no bridge for the operation " ++ operationName op)) Right (M.lookup (operationId op) (envBridges env)))
    values <- mapM (expression env Nothing scope) args
    temporaries <- mapM (const (fresh "argument")) values
    types <- lift (mapM (rustType env . expressionType) args)
    resultType <- lift (rustType env (expressionType e))
    pure (D.block 4 (D.joinWith D.hardline
      ([D.text ("let " ++ t ++ ": " ++ ty ++ " = ") <> v <> D.text ";" | (t, (ty, v)) <- zip temporaries (zip types values)] ++
       [ D.text ("let performed = " ++ bridge ++ "(&mut *ctx, vec![" ++ intercalate ", " ["ls::fast::Dyn::to_dyn(&" ++ t ++ ")" | t <- temporaries] ++ "])" ++
           ".map_err(|error| format!(\"{}: {error}\", " ++ E.quoted (operationName op) ++ "))?;")
       , D.text ("<" ++ resultType ++ " as ls::fast::Dyn>::from_dyn(performed)?") ])))
  -- attempt e: Right of e's value, or Left of the failure it raised.
  Handle (CatchFailure ref) body | Constructor "Either" [TypeArgument failure, TypeArgument result] <- expressionType e -> do
    v <- expression env Nothing scope body
    resultType <- lift (rustType env result)
    failureType' <- lift (rustType env failure)
    pure (D.text ("match ls::fast::attempt(" ++ E.quoted (abilityKey ref) ++ ", || -> ls::Result<" ++ resultType ++ "> ") <>
      D.block 4 (D.text "Ok(" <> v <> D.text ")") <> D.text ")? " <> D.block 4 (D.joinWith D.hardline
        [ D.text "Ok(value) => ls::Either::Right(value),"
        , D.text ("Err(failure) => ls::Either::Left(<" ++ failureType' ++ " as ls::fast::Dyn>::from_dyn(failure)?),") ]))
  Helper Append [a, b] -> do
    x <- expression env Nothing scope a
    y <- expression env Nothing scope b
    let f = case expressionType a of
          Constructor "Text" [] -> "ls::fast::append_text"
          Constructor "Bytes" [] -> "ls::fast::append_bytes"
          _ -> "ls::fast::append_list"
    pure (D.text (f ++ "(&") <> x <> D.text ", &" <> y <> D.text ")")
  Helper Slice [x, from, to] -> do
    v <- expression env Nothing scope x
    i <- integerExpression env scope from
    j <- integerExpression env scope to
    let f = case expressionType x of
          Constructor "Text" [] -> "ls::fast::slice_text"
          Constructor "Bytes" [] -> "ls::fast::slice_bytes"
          _ -> "ls::fast::slice_list"
    pure (D.text (f ++ "(&") <> v <> D.text ", &" <> i <> D.text ", &" <> j <> D.text ")")
  Helper At [x, i] -> do
    v <- expression env Nothing scope x
    k <- integerExpression env scope i
    let f = if expressionType x == Constructor "Bytes" [] then "ls::fast::at_bytes" else "ls::fast::at_list"
    pure (D.text (f ++ "(&") <> v <> D.text ", &" <> k <> D.text ")")
  Helper Range [lo, hi] -> do
    a <- expression env Nothing scope lo
    b <- expression env Nothing scope hi
    case expressionType lo of
      Constructor "Integer" [] -> pure (D.text "ls::fast::range_int(&" <> a <> D.text ", &" <> b <> D.text ")")
      _ -> pure (D.text "ls::fast::List::from_vec((" <> a <> D.text ".." <> b <> D.text ").collect())")
  Helper Octets [b] -> (\v -> D.text "ls::fast::octets(&" <> v <> D.text ")") <$> expression env Nothing scope b
  Helper BytesOf [xs] -> (\v -> D.text "ls::fast::bytes_of(&" <> v <> D.text ")") <$> expression env Nothing scope xs
  Helper Utf8 [t] -> (\v -> D.text "ls::fast::utf8(&" <> v <> D.text ")") <$> expression env Nothing scope t
  Helper TextOf [n] -> case expressionType n of
    Constructor "Integer" [] -> (\v -> D.text "ls::fast::text_of(&" <> v <> D.text ")") <$> expression env Nothing scope n
    _ -> (\v -> D.text "ls::fast::text(&" <> paren v <> D.text ".to_string())") <$> expression env Nothing scope n
  Helper Join [sep, parts] -> do
    a <- expression env Nothing scope sep
    b <- expression env Nothing scope parts
    pure (D.text "ls::fast::join(&" <> a <> D.text ", &" <> b <> D.text ")")
  _ -> lift (Left ("typed Rust: unsupported expression " ++ take 80 (show (expressionNode e))))
  where
    textTest method a b = do
      x <- expression env Nothing scope a
      y <- expression env Nothing scope b
      pure (x <> D.text ("." ++ method ++ "(&*") <> y <> D.text ")")

paren :: D.Doc -> D.Doc
paren x = D.text "(" <> x <> D.text ")"

orderingName :: Env -> Either String String
orderingName env = maybe (Left "typed Rust: Ordering has no typed form") (Right . (envPrefix env ++))
  (M.lookup (collectionsUnit ++ "::type::Ordering") (envNames env))

constant :: Scalar -> Either String D.Doc
constant s = case s of
  SBool b -> pure (D.text (if b then "true" else "false"))
  SAbsent "Unit" -> pure (D.text "()")
  SInteger "Integer" n
    | n >= -(2 ^ (63 :: Int)) && n < 2 ^ (63 :: Int) -> pure (D.text ("ls::fast::Int::Small(" ++ show n ++ ")"))
    | otherwise -> pure (D.text ("ls::fast::Int::from_big(" ++ show (show n) ++ ".parse::<ls::BigInt>().unwrap())"))
  SInteger t n | Just r <- lookup t fixedTypes -> pure (D.text (literal r n))
  SSequence "Text" units -> pure (D.text "ls::fast::text(" <> E.stringLiteral (map toEnum units) <> D.text ")")
  SSequence "Bytes" units -> pure (D.text ("ls::fast::bytes(&[" ++ intercalate ", " (map (\u -> show u ++ "u8") units) ++ "])"))
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
wide :: Env -> Scope -> Expr -> R (Maybe (D.Doc, Int))
wide env scope e = case (expressionNode e, expressionType e) of
  (Constant (SInteger _ n), _) | abs n < 2 ^ (62 :: Int) ->
    pure (Just (D.text (if n < 0 then "(" ++ show n ++ "i128)" else show n ++ "i128"), max 1 (bitLength (abs n))))
  (_, Constructor t []) | Just _ <- lookup t fixedTypes -> do
    x <- expression env Nothing scope e
    pure (Just (paren (x <> D.text " as i128"), 64))
  (Convert _ (Constructor "Integer" []) value, _) -> wide env scope value
  (Helper Length [x], _) -> do
    v <- expression env Nothing scope x
    pure (Just (paren (lengthOf (expressionType x) v <> D.text " as i128"), 64))
  (Unary Negate a, _) -> fmap (\(x, b) -> (D.text "(-" <> x <> D.text ")", b + 1)) <$> wide env scope a
  (Binary op (Numeric (Constructor "Integer" [])) a b, _) | op `elem` [Add, Subtract, Multiply] -> do
    l <- wide env scope a
    r <- wide env scope b
    pure $ case (l, r) of
      (Just (x, bx), Just (y, by)) ->
        let bits = if op == Multiply then bx + by else max bx by + 1
            symbol = case op of Add -> " + "; Subtract -> " - "; _ -> " * "
        in if bits <= 126 then Just (paren (x <> D.text symbol <> y), bits) else Nothing
      _ -> Nothing
  _ -> pure Nothing
  where
    bitLength :: Integer -> Int
    bitLength n = length (takeWhile (> 0) (iterate (`div` 2) n))

lengthOf :: Type -> D.Doc -> D.Doc
lengthOf ty v = case ty of
  Constructor "Text" [] -> D.text "ls::fast::text_length(&" <> v <> D.text ")"
  _ -> v <> D.text ".len()"

-- | An expression of type Integer, as an ls::fast::Int.
integerExpression :: Env -> Scope -> Expr -> R D.Doc
integerExpression env scope e = do
  w <- wide env scope e
  case w of
    Just (x, _) -> pure (D.text "ls::fast::Int::from_i128" <> paren x)
    Nothing -> case expressionNode e of
      Unary Negate a -> (\x -> x <> D.text ".neg()") <$> asInt a
      Binary op _ a b -> do
        x <- asInt a
        y <- asInt b
        pure $ case op of
          Add -> x <> D.text ".add(&" <> y <> D.text ")"
          Subtract -> x <> D.text ".sub(&" <> y <> D.text ")"
          Multiply -> x <> D.text ".mul(&" <> y <> D.text ")"
          Quotient -> x <> D.text ".quot(&" <> y <> D.text ")?"
          Remainder -> x <> D.text ".rem(&" <> y <> D.text ")?"
          _ -> x <> D.text ".pow(&" <> y <> D.text ")?"
      Helper Length [x] -> do
        v <- expression env Nothing scope x
        pure (D.text "ls::fast::Int::from" <> paren (lengthOf (expressionType x) v))
      _ -> expression env Nothing scope e
  where
    asInt a = case expressionType a of
      Constructor "Integer" [] -> integerExpression env scope a
      _ -> (\x -> D.text "ls::fast::Int::from" <> paren x) <$> expression env Nothing scope a

binary :: Env -> Scope -> Expr -> R D.Doc
binary env scope e = case expressionNode e of
  Binary op (Structural _) a b -> do
    x <- expression env Nothing scope a
    y <- expression env Nothing scope b
    pure (paren (x <> D.text (if op == Equal then " == " else " != ") <> y))
  Binary op (Numeric _) a b | isComparison op -> do
    let symbol = case op of Equal -> " == "; NotEqual -> " != "; Less -> " < "; LessEqual -> " <= "; Greater -> " > "; _ -> " >= "
        same = expressionType a == expressionType b && maybe False (const True) (fixedName (expressionType a))
    if same
      then do
        x <- expression env Nothing scope a
        y <- expression env Nothing scope b
        pure (paren (x <> D.text symbol <> y))
      else do
        l <- wide env scope a
        r <- wide env scope b
        case (l, r) of
          (Just (x, _), Just (y, _)) -> pure (paren (x <> D.text symbol <> y))
          _ -> do
            x <- integerExpression env scope (widen a)
            y <- integerExpression env scope (widen b)
            let test = case op of Equal -> "is_eq"; NotEqual -> "is_ne"; Less -> "is_lt"; LessEqual -> "is_le"; Greater -> "is_gt"; _ -> "is_ge"
            pure (D.text "ls::fast::POrd::pcmp(&" <> x <> D.text ", &" <> y <> D.text (")." ++ test ++ "()"))
  _ -> integerExpression env scope e
  where
    fixedName (Constructor n []) = lookup n fixedTypes
    fixedName _ = Nothing
    widen a = case expressionType a of
      Constructor "Integer" [] -> a
      _ -> a { expressionType = Constructor "Integer" [], expressionNode = Convert Explicit (Constructor "Integer" []) a }

convert :: Env -> Scope -> Type -> Expr -> R D.Doc
convert env scope target value = case (target, expressionType value) of
  (Constructor "Integer" [], _) -> integerExpression env scope (value { expressionType = target, expressionNode = Convert Explicit target value })
  (Constructor t [], Constructor s []) | Just r <- lookup t fixedTypes -> do
    case (bounds t, bounds s) of
      (Just (lo, hi), Just (slo, shi)) | slo >= lo && shi <= hi -> do
        x <- expression env Nothing scope value
        pure (paren (x <> D.text (" as " ++ r)))
      _ -> do
        w <- wide env scope value
        case w of
          Just (x, _) -> pure (D.text ("ls::fast::narrow::<" ++ r ++ ">(") <> x <> D.text (", " ++ show t ++ ")?"))
          Nothing -> do
            x <- integerExpression env scope (if s == "Integer" then value else value { expressionType = Constructor "Integer" [], expressionNode = Convert Explicit (Constructor "Integer" []) value })
            pure (x <> D.text (".narrow::<" ++ r ++ ">(" ++ show t ++ ")?"))
  _ -> lift (Left ("typed Rust: unsupported conversion to " ++ show target))

construct :: Env -> Type -> Id -> [D.Doc] -> [Expr] -> R D.Doc
construct env ty tag values args = case (idText tag, values) of
  ("List::Nil", []) -> pure (D.text "ls::fast::List::nil()")
  ("List::Cons", [h, t]) -> pure (D.text "ls::fast::List::cons" <> D.delimitTrailing 4 "(" ")" [h, t])
  ("Maybe::Nothing", []) -> pure (D.text "None")
  ("Maybe::Just", [x]) -> pure (D.text "Some" <> paren x)
  ("Either::Left", [x]) -> pure (D.text "ls::Either::Left" <> paren x)
  ("Either::Right", [x]) -> pure (D.text "ls::Either::Right" <> paren x)
  (_, [items]) | Just ("KeyVal", _) <- collectionArguments ty -> do
    pairs <- lift (entryPairs env)
    pure (D.text "ls::fast::Map::from_entries(" <> items <> D.text (".iter().map(" ++ pairs ++ "))"))
  (_, [items]) | Just ("Set", _) <- collectionArguments ty ->
    pure (D.text "ls::fast::Set::from_iter(" <> items <> D.text ".iter().cloned())")
  _ -> case M.lookup tag (envConstructors env) of
    Just (d, c) -> do
      let name = envPrefix env ++ envNames env M.! idText (dataId d)
      pure $ if fieldless d then D.text (name ++ "::" ++ variantName c)
        else D.text (name ++ "(std::sync::Arc::new(" ++ name ++ "Node::" ++ variantName c) <>
          (if null values then mempty else D.delimitTrailing 4 "(" ")" values) <> D.text "))"
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

intrinsicCall :: Env -> Intrinsic -> [(D.Doc, Type)] -> R D.Doc
intrinsicCall env intrinsic args = case (intrinsic, map fst args) of
  (KeyValOf, [es]) | D.render D.Compact es == "ls::fast::List::nil()" -> pure (D.text "ls::fast::Map::new()")
  (KeyValOf, [es]) -> do
    pairs <- lift (entryPairs env)
    pure (D.text "ls::fast::Map::from_entries(" <> es <> D.text (".iter().map(" ++ pairs ++ "))"))
  (KeyValLookup, [k, m]) -> pure (m <> D.text ".get(&" <> k <> D.text ").cloned()")
  (KeyValPut, [k, v, m]) -> pure (m <> D.text ".insert" <> D.delimitTrailing 4 "(" ")" [k, v])
  (KeyValDelete, [k, m]) -> pure (m <> D.text ".remove(&" <> k <> D.text ")")
  (KeyValKeys, [m]) -> pure (m <> D.text ".to_list(|k, _| k.clone())")
  (KeyValValues, [m]) -> pure (m <> D.text ".to_list(|_, v| v.clone())")
  (KeyValEntries, [m]) -> do
    entry <- lift (entryOf env)
    pure (m <> D.text (".to_list(" ++ entry ++ ")"))
  (SetOf, [xs]) | D.render D.Compact xs == "ls::fast::List::nil()" -> pure (D.text "ls::fast::Set::new()")
  (SetOf, [xs]) -> pure (D.text "ls::fast::Set::from_iter(" <> xs <> D.text ".iter().cloned())")
  (SetMember, [x, s]) -> pure (s <> D.text ".contains(&" <> x <> D.text ")")
  (SetInsert, [x, s]) -> pure (s <> D.text ".insert" <> paren x)
  (SetRemove, [x, s]) -> pure (s <> D.text ".remove(&" <> x <> D.text ")")
  (SetUnion, [s, t]) -> pure (s <> D.text ".union(&" <> t <> D.text ")")
  (SetIntersection, [s, t]) -> pure (s <> D.text ".intersection(&" <> t <> D.text ")")
  (SetDifference, [s, t]) -> pure (s <> D.text ".difference(&" <> t <> D.text ")")
  _ -> lift (Left ("typed Rust: bad intrinsic " ++ show intrinsic))

match :: Env -> Maybe (Int, [String]) -> Scope -> Expr -> [MatchCase] -> Type -> R D.Doc
match env selfCall scope value cases _ = do
  let ty = expressionType value
      used c b = binderId b `elem` freeBinders (caseBody c)
      bindNames c = forM (caseBinders c) $ \b -> if used c b then Just <$> fresh (binderName b) else pure Nothing
      body c names = expression env selfCall ([(binderId b, n) | (b, Just n) <- zip (caseBinders c) names] ++ scope) (caseBody c)
      -- Fields are borrowed from the matched value, and cloned as bound.
      bound c names = do
        fields <- mapM (\n -> maybe (pure Nothing) (\_ -> Just <$> fresh "field") n) names
        b <- body c names
        let clones = [D.text ("let " ++ n ++ " = " ++ f ++ ".clone();") | (Just n, Just f) <- zip names fields]
        pure (map (maybe "_" id) fields, D.block 4 (D.joinWith D.hardline (clones ++ [b])))
  -- The matched value: a local is borrowed where it is; anything else is
  -- bound first.
  (subject, wrap) <- case expressionNode value of
    Local i | Just name <- lookup i scope -> pure (name, id)
    _ -> do
      v <- expression env Nothing scope value
      t <- fresh "matched"
      pure (t, \doc -> D.block 4 (D.text ("let " ++ t ++ " = ") <> v <> D.text ";" <> D.hardline <> doc))
  let matchOn scrutinee arms = wrap (D.text ("match " ++ scrutinee ++ " ") <> D.block 4 (D.joinWith D.hardline arms))
  case ty of
    Constructor "Maybe" _ -> do
      arms <- forM cases $ \c -> do
        names <- bindNames c
        (fields, b) <- bound c names
        pure $ case (idText (caseConstructor c), fields) of
          ("Maybe::Nothing", _) -> D.text "None => " <> b
          (_, [f]) -> D.text ("Some(" ++ f ++ ") => ") <> b
          _ -> D.text "_ => unreachable!(),"
      pure (matchOn ("&" ++ subject) arms)
    Constructor "Either" _ -> do
      arms <- forM cases $ \c -> do
        names <- bindNames c
        (fields, b) <- bound c names
        let side = if idText (caseConstructor c) == "Either::Left" then "Left" else "Right"
        pure (D.text ("ls::Either::" ++ side ++ "(" ++ concat (take 1 fields) ++ ") => ") <> b)
      pure (matchOn ("&" ++ subject) arms)
    Constructor "List" _ -> do
      arms <- forM cases $ \c -> do
        names <- bindNames c
        (fields, b) <- bound c names
        pure $ case (idText (caseConstructor c), fields) of
          ("List::Nil", _) -> D.text "None => " <> b
          (_, [h, t]) -> D.text ("Some((" ++ h ++ ", " ++ t ++ ")) => ") <> b
          _ -> D.text "_ => unreachable!(),"
      pure (matchOn (subject ++ ".uncons()") arms)
    _ | Just (kind, _) <- collectionArguments ty, [c] <- cases, [b] <- caseBinders c -> do
          items <- fresh (binderName b)
          converted <- if kind == "KeyVal"
            then do
              entry <- lift (entryOf env)
              pure (D.text (subject ++ ".to_list(" ++ entry ++ ")"))
            else pure (D.text (subject ++ ".to_list()"))
          rest <- expression env selfCall ((binderId b, items) : scope) (caseBody c)
          pure (wrap (D.block 4 (D.text ("let " ++ items ++ " = ") <> converted <> D.text ";" <> D.hardline <> rest)))
    Constructor n _ | Just d <- M.lookup n (envData env) -> do
      let name = envPrefix env ++ envNames env M.! n
      if fieldless d
        then do
          arms <- forM cases $ \c -> do
            b <- body c []
            con <- lift (maybe (Left "typed Rust: unknown constructor") (Right . snd) (M.lookup (caseConstructor c) (envConstructors env)))
            pure (D.text (name ++ "::" ++ variantName con ++ " => ") <> D.block 4 b)
          pure (matchOn subject arms)
        else do
          arms <- forM cases $ \c -> do
            names <- bindNames c
            (fields, b) <- bound c names
            con <- lift (maybe (Left "typed Rust: unknown constructor") (Right . snd) (M.lookup (caseConstructor c) (envConstructors env)))
            let patternText = name ++ "Node::" ++ variantName con ++
                  (if null names then "" else "(" ++ intercalate ", " fields ++ ")")
            pure (D.text (patternText ++ " => ") <> b)
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
  native <- Native.rustDataTypeWithParameters declarations nativeParams (Constructor (idText (dataId d)) [TypeArgument (TypeVariable p) | p <- dataParameters d])
  let base = takeWhile (/= '<') native
      single = length variants == 1
      nativeOf c = if single then base else base ++ "::" ++ variant c
      nativeRecord c values = nativeOf c ++ (if null (constructorFields c) then "" else " { " ++ intercalate ", " [field f ++ ": " ++ v | (f, v) <- zip (constructorFields c) values] ++ " }")
      typedOf c values
        | fieldless d = name ++ "::" ++ variantName c
        | otherwise = name ++ "(std::sync::Arc::new(" ++ node ++ "::" ++ variantName c ++ (if null values then "" else "(" ++ intercalate ", " values ++ ")") ++ "))"
      typedPattern c = if fieldless d then name ++ "::" ++ variantName c
        else node ++ "::" ++ variantName c ++ (if null (constructorFields c) then "" else "(" ++ intercalate ", " ["f" ++ show k | k <- [0 .. length (constructorFields c) - 1]] ++ ")")
      toArm c = line (typedPattern c ++ " => " ++ nativeRecord c ["f" ++ show k ++ ".to_native()" | k <- [0 .. length (constructorFields c) - 1]] ++ ",")
      fromArm c = line (nativeRecord c [ "f" ++ show k | k <- [0 .. length (constructorFields c) - 1]] ++ " => " ++
        typedOf c ["ls::fast::Public::from_native(f" ++ show k ++ ")" | k <- [0 .. length (constructorFields c) - 1]] ++ ",")
      scrutinee = if fieldless d then "self" else "&*self.0"
  pure (line ("impl" ++ bounded ++ " ls::fast::Public for " ++ name ++ generics ++ " ") <> D.block 4 (D.joinWith D.hardline
    [ line ("type Native = " ++ native ++ ";")
    , line "fn to_native(&self) -> Self::Native " <> D.block 4 (line ("match " ++ scrutinee ++ " ") <> D.block 4 (D.joinWith D.hardline (map toArm variants)))
    , line "fn from_native(native: Self::Native) -> Self " <> D.block 4 (line "match native " <> D.block 4 (D.joinWith D.hardline (map fromArm variants) <>
        (if null variants then line "_ => unreachable!()," else mempty))) ]))

-- | A name as RustData writes it: a keyword is a raw identifier.
rustIdentifier :: String -> String
rustIdentifier name
  | name `elem` words "as async await break const continue dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return static struct trait true type unsafe use where while abstract become box do final macro override priv typeof unsized virtual yield try gen union" = "r#" ++ name
  | otherwise = name
