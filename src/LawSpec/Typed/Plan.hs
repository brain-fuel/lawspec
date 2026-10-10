-- | Which checked definitions run as typed native code, shared by the Rust,
-- Go and JVM emitters. A definition is typed when every value it touches has
-- a typed form (scalars with exact native semantics, lists, Maybe, Either,
-- the built-in KeyVal and Set, and data built from them), it performs no
-- operation, calls only typed definitions, and has no runtime contract or
-- workflow policy; anything else stays on the dynamic path, unchanged.
--
-- Typed definitions that are the same up to their names (imports copy a
-- unit's definitions into every unit that uses them) share one body: the
-- classes are the coarsest partition in which members have the same shape
-- and call members of the same classes. The collections unit's KeyVal and Set
-- operations are intrinsics, which each target implements over its
-- persistent maps. ref:DEC-typed-native-definitions
module LawSpec.Typed.Plan
  ( TypedPlan(..), Intrinsic(..), typedPlan, typedPlanWith, supportedType, isTypedHandler
  , typedFallbacks, failedWith, sequenceBuiltins
  , collectionArguments, scalarTypes, constructorRanks, definitionClass, sharedDefinitions, firstOf
  ) where

import Data.Char (isHexDigit)
import Data.List (isPrefixOf, sortOn, stripPrefix, nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Collections (collectionsUnit, collectionContainer)
import LawSpec.Core
import LawSpec.Scalar (Scalar(..))

-- | The collections unit's operations a target implements natively.
data Intrinsic
  = KeyValOf | KeyValLookup | KeyValPut | KeyValDelete | KeyValKeys | KeyValValues | KeyValEntries
  | SetOf | SetMember | SetInsert | SetRemove | SetUnion | SetIntersection | SetDifference
  deriving (Eq, Ord, Show)

data TypedPlan = TypedPlan
  { -- Every typed definition, by identity.
    typedDefinitions :: M.Map Id Definition
    -- Each typed definition's class, numbered in program order.
  , typedClass :: M.Map Id Int
    -- One definition per class: the first of its members.
  , typedRepresentatives :: [(Int, Definition)]
  , typedIntrinsics :: M.Map Id Intrinsic
    -- The data declarations with a typed form.
  , typedData :: [DataDeclaration]
  , typedDataNames :: S.Set String
    -- The scalars with a typed form on the target.
  , typedScalars :: [String]
    -- Why each definition that is not typed stays dynamic (computed only
    -- when asked for).
  , typedFallbackReasons :: [(Definition, String)]
  }

-- | The first of a list the caller knows is not empty (a product's one
-- constructor, an infinite list of candidates).
firstOf :: [a] -> a
firstOf xs = case xs of
  x : _ -> x
  [] -> error "typed emission: an empty list where one was planned"

-- | The scalars whose typed form has exactly LawSpec's semantics on every
-- typed target.
scalarTypes :: [String]
scalarTypes = ["Bool", "Unit", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64", "Integer", "Text", "Bytes"]

-- | A KeyVal's key and value types, or a Set's item type.
collectionArguments :: Type -> Maybe (String, [Type])
collectionArguments (Constructor name args)
  | Just short <- collectionContainer name, short `elem` ["KeyVal", "Set"] = Just (short, [t | TypeArgument t <- args])
collectionArguments _ = Nothing

-- | Whether a closed type has a typed form, given the typed data types.
supportedType :: TypedPlan -> Type -> Bool
supportedType plan = supportedTypeWith (typedScalars plan) (typedDataNames plan)

supportedTypeWith :: [String] -> S.Set String -> Type -> Bool
supportedTypeWith scalars known ty = case ty of
  Constructor n [] | n `elem` scalars -> True
  Constructor n args
    | n `elem` ["List", "Maybe", "Either"] || maybe False ((`elem` ["KeyVal", "Set"]) . fst) (collectionArguments ty) || n `S.member` known ->
        all argument args && arity n args
  _ -> False
  where
    argument (TypeArgument t) = supportedTypeWith scalars known t
    argument _ = False
    arity "List" args = length args == 1
    arity "Maybe" args = length args == 1
    arity "Either" args = length args == 2
    arity _ _ = True

-- | A data declaration's fields may name its parameters.
supportedField :: [String] -> S.Set String -> [Id] -> Type -> Bool
supportedField scalars known parameters ty = case ty of
  TypeVariable v -> v `elem` parameters
  Constructor n [] | n `elem` scalars -> True
  Constructor n args
    | n `elem` ["List", "Maybe", "Either"] || maybe False ((`elem` ["KeyVal", "Set"]) . fst) (collectionArguments ty) || n `S.member` known ->
        all (\a -> case a of TypeArgument t -> supportedField scalars known parameters t; _ -> False) args
  _ -> False

-- | The typed data declarations: no handles, no indexed families, and every
-- field typed. The built-in containers are native, never data.
typedDeclarations :: [String] -> [DataDeclaration] -> [DataDeclaration]
typedDeclarations scalars declarations = filter ((`S.member` final) . idText . dataId) candidates
  where
    candidates = [ d | d <- declarations, not (dataHandle d), dataIndex d == Nothing
                 , collectionContainer (idText (dataId d)) `notElem` [Just "KeyVal", Just "Set"]
                 , all (\c -> null (constructorEquations c) && null (constructorExistentials c)) (dataConstructors d)
                 , all (\p -> any (mentions p . binderType) (concatMap constructorFields (dataConstructors d))) (dataParameters d) ]
    mentions p ty = case ty of
      TypeVariable v -> v == p
      Constructor _ args -> any (\a -> case a of TypeArgument t -> mentions p t; _ -> False) args
      Arrow a b -> mentions p a || mentions p b
    final = go (S.fromList (map (idText . dataId) candidates))
    go known =
      let kept = S.fromList [ idText (dataId d) | d <- candidates, idText (dataId d) `S.member` known
                            , all (all (supportedField scalars known (dataParameters d) . binderType) . constructorFields) (dataConstructors d) ]
      in if kept == known then known else go kept

-- | A data type's constructors ranked in the portable order, which orders
-- constructors by their identities.
constructorRanks :: DataDeclaration -> [(Id, Int)]
constructorRanks d = zip (sortOn idText (map constructorId (dataConstructors d))) [0 ..]

-- | A collections operation, from a definition's name: lawspecCollections<Op>
-- as an import copies it, with the specializer's lawspec_ prefix and hash.
intrinsicOf :: Definition -> Maybe Intrinsic
intrinsicOf d = do
  let name = declarationName (definitionDeclaration d)
      unprefixed = maybe name id (stripPrefix "lawspec_" name)
      base = reverse (dropSuffix (reverse unprefixed))
  operation <- stripPrefix "lawspecCollections" base
  lookup operation
    [ ("KeyValOf", KeyValOf), ("KeyValLookup", KeyValLookup), ("KeyValPut", KeyValPut), ("KeyValDelete", KeyValDelete)
    , ("KeyValKeys", KeyValKeys), ("KeyValValues", KeyValValues), ("KeyValEntries", KeyValEntries)
    , ("SetOf", SetOf), ("SetMember", SetMember), ("SetInsert", SetInsert), ("SetRemove", SetRemove)
    , ("SetUnion", SetUnion), ("SetIntersection", SetIntersection), ("SetDifference", SetDifference) ]
  where
    -- The specializer's suffix: _ and hex digits.
    dropSuffix reversed = case span isHexDigit reversed of
      (digits@(_ : _), '_' : rest) | length digits >= 8 -> rest
      _ -> reversed

typedPlan :: [DataDeclaration] -> [Unit] -> TypedPlan
typedPlan = typedPlanWith scalarTypes

-- | With the target's typed scalars.
typedPlanWith :: [String] -> [DataDeclaration] -> [Unit] -> TypedPlan
typedPlanWith scalars declarations units = TypedPlan
  { typedDefinitions = M.fromList [(idOf d, d) | d <- eligible]
  , typedClass = classes
  , typedRepresentatives = representatives
  , typedIntrinsics = M.fromList [(idOf d, i) | d <- eligible, Just i <- [intrinsicOf d]]
  , typedData = datas
  , typedDataNames = known
  , typedScalars = scalars
  , typedFallbackReasons = [ (d, reason d) | d <- definitions, idOf d `S.notMember` eligibleIds ] }
  where
    eligibleIds = S.fromList (map idOf eligible)
    reason d
      | definitionOrchestrates d = "it is a workflow"
      | definitionPolicy d /= Nothing = "it has a workflow policy"
      | not (all failing (declarationUses (definitionDeclaration d))) =
          "it uses " ++ unwords [abilityKey r | r <- declarationUses (definitionDeclaration d), not (failing r)]
      | idOf d `S.member` contracted = "it has a runtime contract"
      | let (args, _) = functionType (declarationType (definitionDeclaration d)), length args > 12 = "it has more than 12 arguments"
      | t : _ <- [t | let (args, result) = functionType (declarationType (definitionDeclaration d)), t <- result : args ++ map binderType (definitionArguments d), not (supported t)] =
          "its type " ++ show t ++ " has no typed form"
      | intrinsicOf d == Nothing, Just e <- firstUntyped (definitionBody d) =
          "it contains " ++ take 160 (show (expressionNode e)) ++ " :: " ++ show (expressionType e)
      | otherwise = "it calls " ++ unwords [idText c | c <- nub (callees (definitionBody d)), c `S.notMember` eligibleIds]
    firstUntyped e
      | not (supported (expressionType e)) || not (nodeTyped e) = Just e
      | otherwise = foldr (\c acc -> maybe acc Just (firstUntyped c)) Nothing (children e)
    datas = typedDeclarations scalars declarations
    supported = supportedTypeWith scalars known
    known = S.fromList (map (idText . dataId) datas)
    definitions = concatMap unitDefinitions units
    idOf = declarationId . definitionDeclaration
    contracted = S.fromList (map contractDeclaration (concatMap unitContracts units))
    candidates = [ d | d <- definitions, local d ]
    local d = not (definitionOrchestrates d) && definitionPolicy d == Nothing
      && all failing (declarationUses (definitionDeclaration d))
      && idOf d `S.notMember` contracted
      && let (args, result) = functionType (declarationType (definitionDeclaration d))
         in length args <= 12 && all (supported) (result : args)
            && all (supported . binderType) (definitionArguments d)
            && (intrinsicOf d /= Nothing && intrinsicTyped d || expressionTyped (definitionBody d))
    -- A definition that `fails with E` raises as the dynamic code does.
    failing ref = maybe False supported (failedWith ref)
    -- An intrinsic needs only its signature typed.
    intrinsicTyped d = let (args, result) = functionType (declarationType (definitionDeclaration d))
      in all (supported) (result : args)
    eligible = settle (S.fromList (map idOf candidates))
    settle ids =
      let kept = S.fromList [ idOf d | d <- candidates, idOf d `S.member` ids
                            , intrinsicOf d /= Nothing || all (`S.member` ids) (callees (definitionBody d)) ]
      in if kept == ids then [d | d <- candidates, idOf d `S.member` ids] else settle kept
    expressionTyped e = supported (expressionType e) && nodeTyped e && all expressionTyped (children e)
    nodeTyped e = case expressionNode e of
      Constant s -> constantTyped s
      Construct _ _ -> True
      Match value cases -> supported (expressionType value) && all (all (supported . binderType) . caseBinders) cases
      AllElements _ binder _ -> supported (binderType binder)
      AllPayloads _ _ -> False
      Local _ -> True
      ExternalCall _ _ -> True
      Binary op evidence a b -> binaryTyped op evidence a b
      Unary Not _ -> True
      Unary Negate a -> integral (expressionType a)
      ShortCircuit _ _ _ -> True
      If _ _ _ -> True
      Convert _ target value -> integral target && integral (expressionType value) || target == expressionType value
      Helper builtin _ -> builtin `elem` ([Length, Compare, Select, Unreachable, StartsWith, EndsWith, TextContains, RegexMatches, Checked] ++ sequenceBuiltins)
      -- raise e, and attempt e: the Fail ability, at a typed failure.
      Perform (Operation ref "raise") [_] -> failing ref
      Perform _ _ -> False
      Handle (CatchFailure ref) _ -> failing ref
      Handle _ _ -> False
      Calls _ _ -> False
      Let binder _ _ -> supported (binderType binder)
    constantTyped s = case s of
      SInteger t _ -> t `elem` scalars
      SBool _ -> True
      SSequence t _ -> t `elem` ["Text", "Bytes"]
      SAbsent "Unit" -> True
      _ -> False
    binaryTyped op evidence a b = case evidence of
      Numeric (Constructor "Integer" []) ->
        op `elem` [Add, Subtract, Multiply, Quotient, Remainder, Power, Equal, NotEqual, Less, LessEqual, Greater, GreaterEqual]
          && integral (expressionType a) && integral (expressionType b)
      Numeric _ -> False
      Structural t -> op `elem` [Equal, NotEqual] && supported t
    integral (Constructor n []) = n `elem` ["Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64", "Integer"]
    integral _ = False
    -- Classes: shapes with callees abstracted, refined until stable.
    shapes = M.fromList [(idOf d, shapeOf d) | d <- eligible]
    shapeOf d = case intrinsicOf d of
      Just i -> ("intrinsic " ++ show i ++ " " ++ show (declarationType (definitionDeclaration d)), [])
      Nothing -> let (body, calls) = normalize d in (show (declarationType (definitionDeclaration d)) ++ " " ++ body, calls)
    initial = number [(i, fst (shapes M.! i)) | i <- map idOf eligible]
    refine current =
      let next = number [(i, (fst s, map (current M.!) (snd s))) | i <- map idOf eligible, let s = shapes M.! i]
      in if M.size (M.fromList [(c, ()) | c <- M.elems next]) == M.size (M.fromList [(c, ()) | c <- M.elems current])
           then next else refine next
    classes = refine initial
    representatives = reverse (snd (foldl (\(seen, acc) d -> let c = classes M.! idOf d in
      if S.member c seen then (seen, acc) else (S.insert c seen, (c, d) : acc)) (S.empty, []) eligible))

-- | Number keys by first appearance (program order), so classes are stable.
number :: Ord k => [(Id, k)] -> M.Map Id Int
number entries = M.fromList [(i, table M.! k) | (i, k) <- entries]
  where
    table = foldl (\m (_, k) -> if M.member k m then m else M.insert k (M.size m) m) M.empty entries

-- | The definitions an expression calls.
callees :: Expr -> [Id]
callees e = case expressionNode e of
  ExternalCall i args -> i : concatMap callees args
  _ -> concatMap callees (children e)

-- | A definition's body with binders numbered in order and callees replaced
-- by their positions, rendered, and the callees.
normalize :: Definition -> (String, [Id])
normalize d =
  let binders = map binderId (definitionArguments d) ++ boundIn (definitionBody d)
      table = M.fromList (zip (nub binders) [Id ("b" ++ show k) | k <- [0 :: Int ..]])
      calls = nub (callees (definitionBody d))
      callTable = M.fromList (zip calls [Id ("c" ++ show k) | k <- [0 :: Int ..]])
  in (show (strip table callTable (definitionBody d)), calls)
  where
    boundIn e = (case expressionNode e of
      Let b _ _ -> [binderId b]
      Match _ cases -> concatMap (map binderId . caseBinders) cases
      AllElements _ b _ -> [binderId b]
      AllPayloads _ ps -> map (binderId . fst) ps
      _ -> []) ++ concatMap boundIn (children e)
    strip table callTable e =
      let rename i = M.findWithDefault i i table
          binder b = b { binderId = rename (binderId b), binderName = "" }
          inner = strip table callTable
          node = case expressionNode (mapChildren inner e) of
            Local i -> Local (rename i)
            ExternalCall i args -> ExternalCall (M.findWithDefault i i callTable) args
            Let b v body -> Let (binder b) v body
            Match v cases -> Match v [c { caseBinders = map binder (caseBinders c) } | c <- cases]
            AllElements v b p -> AllElements v (binder b) p
            other -> other
      in e { expressionNode = node, expressionOrigin = GeneratedFrom (Id "") }

-- | Definitions that are the same up to their names (an import's copies),
-- typed or not, each mapped to the one that stands for them all: the one
-- with the shortest name (the original, which its copies prefix), then the
-- first. A definition with a contract or a policy, or a workflow, stands
-- alone. Emitters alias the others to it.
sharedDefinitions :: [Unit] -> M.Map Id Id
sharedDefinitions units = M.fromList
  [ (i, primary) | (i, c) <- M.toList classes, Just primary <- [M.lookup c primaries], primary /= i ]
  where
    contracted = S.fromList (map contractDeclaration (concatMap unitContracts units))
    definitions = [ d | d <- concatMap unitDefinitions units
                  , not (definitionOrchestrates d), definitionPolicy d == Nothing
                  , declarationId (definitionDeclaration d) `S.notMember` contracted ]
    idOf = declarationId . definitionDeclaration
    known = S.fromList (map idOf definitions)
    shapes = M.fromList [(idOf d, normalize d) | d <- definitions]
    -- A callee outside the set (an adapter, a definition with a contract)
    -- is part of the shape itself.
    key current (body, calls) = (body, [maybe (Left (idText c)) Right (if c `S.member` known then M.lookup c current else Nothing) | c <- calls])
    initial = number [(i, (show (declarationType (definitionDeclaration d)) ++ fst (shapes M.! i), [idText c | c <- snd (shapes M.! i), c `S.notMember` known])) | d <- definitions, let i = idOf d]
    refine current =
      let next = number [(i, (show (declarationType (definitionDeclaration d)), key current (shapes M.! i))) | d <- definitions, let i = idOf d]
      in if M.size (M.fromList [(c, ()) | c <- M.elems next]) == M.size (M.fromList [(c, ()) | c <- M.elems current])
           then next else refine next
    classes = refine initial
    primaries = M.fromListWith better [ (c, i) | d <- definitions, let i = idOf d, Just c <- [M.lookup i classes] ]
    better new old = if length (nameOf new) < length (nameOf old) then new else old
    names = M.fromList [(idOf d, declarationName (definitionDeclaration d)) | d <- definitions]
    nameOf i = M.findWithDefault "" i names

-- | The failure a Fail ability raises: E of Fail E.
failedWith :: AbilityRef -> Maybe Type
failedWith ref = case ref of
  AbilityRef i [t] | i == failAbilityId -> Just t
  _ -> Nothing

-- | The sequence helpers every typed target implements.
sequenceBuiltins :: [Builtin]
sequenceBuiltins = [Append, Slice, At, Range, Octets, BytesOf, Utf8, TextOf, Join]

-- | The definitions that stay dynamic, by name, and why.
typedFallbacks :: TypedPlan -> [(String, String)]
typedFallbacks plan = [ (declarationName (definitionDeclaration d), why) | (d, why) <- typedFallbackReasons plan ]

-- | A definition's class, when it is typed.
definitionClass :: TypedPlan -> Id -> Maybe Int
definitionClass plan identity = M.lookup identity (typedClass plan)

-- | A stateful or stateless spec handler runs typed when its state has a
-- typed form and every clause is typed.
isTypedHandler :: TypedPlan -> Handler -> Bool
isTypedHandler plan h =
  all ((`M.member` typedDefinitions plan) . snd) (handlerClauses h) &&
  maybe True (\(t, start) -> supportedType plan t && startTyped start) (handlerState h)
  where
    startTyped e = case expressionNode e of
      -- A computed start: a call of a typed definition.
      ExternalCall i args -> i `M.member` typedDefinitions plan && all startTyped args
      Perform _ _ -> False
      Handle _ _ -> False
      Calls _ _ -> False
      Helper _ _ -> False
      AllPayloads _ _ -> False
      Constant s -> case s of
        SInteger t _ -> t `elem` typedScalars plan
        SBool _ -> True
        SSequence t _ -> t `elem` ["Text", "Bytes"]
        SAbsent "Unit" -> True
        _ -> False
      _ -> supportedType plan (expressionType e) && all startTyped (children e)

_unused :: String -> Bool
_unused = (collectionsUnit `isPrefixOf`)
