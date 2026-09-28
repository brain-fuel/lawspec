-- Execution feasibility and deterministic cases are planned after elaboration.
-- This module consumes only typed core, never surface syntax or inference.
module LawSpec.Testing where
import LawSpec.Core
import LawSpec.Common
import LawSpec.Scalar
import LawSpec.Core.Eval (evaluateValue, evaluateValuePure)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Total (constructorProofContracts)
import LawSpec.Core.Value
import LawSpec.Core.Types (TypeRegistry, makeRegistry, registryDeclarations, builtinDataDeclarations, lookupData, constructorFieldsFor, generationRequirements)
import qualified Data.Map.Strict as M
import Data.List (nub, sort)
import Control.Monad (filterM, unless)
import Control.Monad.State.Strict (StateT, evalStateT, get, modify, lift)

data Plan = Plan
  { planMachineBits :: Int, planDataDeclarations :: [DataDeclaration]
  , plannedUnits :: [PlannedUnit]
  } deriving (Eq, Show)
data PlannedUnit = PlannedUnit { plannedUnit :: Unit, plannedProperties :: [PlannedProperty] } deriving (Eq, Show)
data PlannedProperty = PlannedProperty
  { plannedProperty :: Property, finiteCases :: Maybe [[Value]], boundaryCases :: [[Value]]
  , generatorRequirements :: [GeneratorRequirement]
  } deriving (Eq, Show)
data GeneratorRequirement = GeneratorRequirement { generatorBinder :: Binder, generatorPredicates :: [Expr], generatorBoundaries :: [Value], generatorBounds :: [(BinaryOp,Expr)], generatorHints :: [Expr] } deriving (Eq, Show)

planTesting :: Program -> Either [Diagnostic] Plan
planTesting program@Program{..} = do
  invoke <- prepareDefinitions program
  registry <- either (Left . pure . (\message -> Diagnostic "generation" message Nothing)) Right (makeRegistry programDataDeclarations)
  Plan programMachineBits programDataDeclarations <$> mapM (unit registry invoke) programUnits
  where
    unit registry invoke u = PlannedUnit u <$> mapM (property registry invoke) (unitProperties u)
    property registry invoke p = either (Left . pure . (\m -> Diagnostic "generation" m (Just (propertyLocation p)))) Right $ do
      let qs = propertyInputs p
          settings = propertyGeneration p
          types = map (binderType . quantifiedBinder) qs
      mapM_ (supportedWithRegistry registry) types
      let inhabitants = population registry
      mapM_ (\ty -> unless (inhabited inhabitants ty) (Left ("uninhabited input domain: " ++ show ty))) types
      mapM_ (\e -> if null (freeBinders e) then do
          v <- evaluateValue registry programMachineBits invoke [] e
          unless (v == ScalarValue (SBool True)) (Left "refined input domain has no valid tuples")
        else Right ()) (concatMap quantifiedPredicates qs)
      domains <- mapM (finiteValuesWithRegistry registry programMachineBits (exhaustiveLimit settings)) types
      finite <- case sequence domains of
        Just sets | product (map (toInteger . length) sets) <= toInteger (exhaustiveLimit settings) -> Just <$> filterM (validTupleWithDefinitions registry programMachineBits invoke qs) (sequence sets)
        _ -> Right Nothing
      unless (finite /= Just []) (Left "refined input domain has no valid tuples")
      bs <- sequence [case domain of
          Just values | hasValueContracts registry ty -> pure values
          _ -> boundariesWithRegistry registry programMachineBits ty
        | (ty,domain) <- zip types domains]
      unless (all (not . null) bs) (Left "uninhabited input domain")
      let tuples = if null bs then [[]] else [[xs !! (i `mod` length xs) | xs <- bs] | i <- [0..maximum (map length bs)-1]]
      cases <- filterM (validTupleWithDefinitions registry programMachineBits invoke qs) tuples
      mapM_ (\example -> do
        bindings <- mapM (\(name,value) -> (,) name <$> evaluateValuePure registry programMachineBits [] value)
          (exampleBindings example)
        values <- mapM (\q -> maybe (Left "missing example input") Right
          (lookup (binderId (quantifiedBinder q)) bindings)) qs
        valid <- validTupleWithDefinitions registry programMachineBits invoke qs values
        unless valid (Left ("example " ++ exampleName example ++ " violates refinement"))) (propertyExamples p)
      pure (PlannedProperty p finite cases [GeneratorRequirement (quantifiedBinder q) (quantifiedPredicates q) b (quantifiedBounds q) (domainHints q) | (q,b) <- zip qs bs])

validTuple :: TypeRegistry -> Int -> [Quantifier] -> [Value] -> Either String Bool
validTuple registry bits qs values = do
  auditDomains registry bits
  validTupleWithDefinitions registry bits
    (\name _ -> Left ("unexpected definition call without a definition environment: " ++ idText name)) qs values

-- The caller obtains this closed dispatcher from prepareDefinitions. It has no
-- adapter hook, and validates native arguments/results at each definition call.
validTupleWithDefinitions :: TypeRegistry -> Int -> (Id -> [Value] -> Either String Value)
  -> [Quantifier] -> [Value] -> Either String Bool
validTupleWithDefinitions registry bits invoke qs values
  | length qs /= length values = Left "input tuple arity mismatch"
  | otherwise = walk [] (zip qs values)
  where
    walk _ [] = Right True
    walk prefix ((q,v):rest) = do
      accepted <- acceptsValue registry bits (binderType (quantifiedBinder q)) v
      let env = prefix ++ [(binderId (quantifiedBinder q),v)]
      ok <- if not accepted then pure False else allM (\p -> (== ScalarValue (SBool True)) <$> evaluateValue registry bits invoke env p) (quantifiedPredicates q)
      if ok then walk env rest else Right False
    allM _ [] = Right True
    allM f (x:xs) = do b <- f x; if b then allM f xs else Right False

-- Registries carry typed predicates. Standalone domain APIs audit them before
-- executing candidates, including unused contracts and dependency cycles.
auditDomains :: TypeRegistry -> Int -> Either String ()
auditDomains registry bits = () <$ either (Left . show) Right
  (constructorProofContracts bits [declaration | declaration <- registryDeclarations registry,
    dataId declaration `notElem` map dataId builtinDataDeclarations])

acceptsValue :: TypeRegistry -> Int -> Type -> Value -> Either String Bool
acceptsValue registry bits ty value = do
  result <- checkValueWith (evaluateValuePure registry bits) registry bits ty value
  pure (case result of ValueAccepted _ -> True; RefinementRejected _ -> False)

-- Compatibility helpers for built-in types use the same registry-driven
-- planner as user-defined types. A sampling limit never defines a domain.
finiteValues :: Int -> Int -> Type -> Maybe [Value]
finiteValues bits limit ty = either (const Nothing) id $
  makeRegistry [] >>= \registry -> finiteValuesWithRegistry registry bits limit ty

boundaries :: Int -> Type -> [Value]
boundaries bits ty = either (const []) id $
  makeRegistry [] >>= \registry -> boundariesWithRegistry registry bits ty

finiteScalars :: Int -> Int -> String -> Maybe [Value]
finiteScalars bits limit name
  | Just (lo,hi) <- integerBounds bits name, hi-lo+1 <= fromIntegral limit =
      Just [ScalarValue (SInteger name x) | x <- [lo..hi]]
  | name `elem` ["Bool", "Unit", "Null", "Undefined"],
      let values = map ScalarValue (scalarBoundaries bits name), length values <= limit = Just values
  | otherwise = Nothing

scalarCases :: Int -> String -> [Value]
scalarCases bits "Text" = map (ScalarValue . textScalar)
  ["", " ", "Hello, World!", "λ日本語😀", "a\n\t\"\\$\0z", "e\x0301"] ++ map ScalarValue (scalarBoundaries bits "Text")
scalarCases bits name = map ScalarValue (scalarBoundaries bits name)

-- Safe comparison operands seed sparse domains without eagerly evaluating a
-- partial expression that the predicate would otherwise guard.
domainHints :: Quantifier -> [Expr]
domainHints q = concatMap walk (quantifiedPredicates q) where
  current = binderId (quantifiedBinder q)
  walk Expr{expressionNode=ShortCircuit _ a b} = concatMap walk [a,b]
  walk Expr{expressionNode=Binary op _ a b} | isComparison op =
    [rhs | (lhs,rhs) <- [(a,b),(b,a)], expressionNode lhs == Local current, current `notElem` freeBinders rhs, safe rhs]
  walk _ = []
  safe e = case expressionNode e of
    Constant _ -> True
    Construct _ fields -> all safe fields
    Local _ -> True
    Binary op _ a b | op `elem` [Add,Subtract,Multiply,Equal,NotEqual,Less,LessEqual,Greater,GreaterEqual] -> safe a && safe b
    Binary op _ a Expr{expressionNode=Constant b} | op `elem` [Divide,Quotient,Remainder] -> safe a && either (const False) (/=0) (exactValue b)
    Unary _ a -> safe a
    _ -> False


-- Least fixed point of minimal sets of parameters needed for a finite value.
-- Symbolic requirements avoid enumerating every Boolean parameter assignment,
-- particularly for high-arity declarations with phantom parameters.
-- Function fields remain nongeneratable and are rejected before this analysis.
type Population = M.Map Id ([Id], [[Id]])

population :: TypeRegistry -> Population
population registry = converge initial
  where
    declarations = registryDeclarations registry
    initial = M.fromList [(dataId d, (dataParameters d, [])) | d <- declarations]
    step table = M.fromList [(dataId d, (dataParameters d, minimal
      (concat [combine [needs table (binderType field) | field <- constructorFields c]
        | c <- dataConstructors d]))) | d <- declarations]
    converge current = let next = step current in if next == current then current else converge next

minimal :: [[Id]] -> [[Id]]
minimal alternatives = [xs | xs <- candidates, not (any (\ys -> ys /= xs && all (`elem` xs) ys) candidates)]
  where candidates = sort (nub (map (sort . nub) alternatives))

combine :: [[[Id]]] -> [[Id]]
combine = foldr (\choices rest -> minimal [xs ++ ys | xs <- choices, ys <- rest]) [[]]

needs :: Population -> Type -> [[Id]]
needs table ty = case ty of
  TypeVariable name -> [[name]]
  Arrow _ _ -> [[]]
  Constructor name args
    | name `elem` ["Nullable", "Optional"] -> [[]]
    | Just _ <- primitive name -> [[]]
    | Just (parameters, alternatives) <- M.lookup (Id name) table ->
        let arguments = zip parameters [t | TypeArgument t <- args]
        in minimal (concat [combine [maybe [] (needs table) (lookup parameter arguments)
              | parameter <- required] | required <- alternatives])
    | otherwise -> []

potential :: Population -> M.Map Id Bool -> Type -> Bool
potential table env ty = any (all (\name -> M.findWithDefault False name env)) (needs table ty)

inhabited :: Population -> Type -> Bool
inhabited table = potential table M.empty

populationKey :: Population -> Type -> (Id, [Bool])
populationKey table (Constructor name args) = (Id name, [inhabited table t | TypeArgument t <- args])
populationKey _ _ = (Id "<non-data>", [])

viableConstructors :: TypeRegistry -> Population -> Type -> Either String [(Id, [Type])]
viableConstructors registry table ty = case ty of
  Constructor name _ -> do
    declaration <- lookupData registry (Id name)
    fields <- mapM (\c -> do
      parameters <- constructorFieldsFor registry ty (constructorId c)
      pure (constructorId c, map binderType parameters)) (dataConstructors declaration)
    pure [(tag,parameters) | (tag,parameters) <- fields, all (inhabited table) parameters]
  _ -> Left ("no constructors for " ++ show ty)

supportedWithRegistry :: TypeRegistry -> Type -> Either String ()
supportedWithRegistry registry ty = do
  required <- generationRequirements registry ty
  unless (null required) (Left ("unresolved generator parameters: " ++ show required))

finiteValuesWithRegistry :: TypeRegistry -> Int -> Int -> Type -> Either String (Maybe [Value])
finiteValuesWithRegistry registry bits limit ty = do
  auditDomains registry bits
  supportedWithRegistry registry ty
  walk [] ty
  where
    table = population registry
    bounded values = if length values <= limit then Just values else Nothing
    walk seen t
      | not (inhabited table t) = Right (Just [])
      | otherwise = case t of
          Constructor name [] | Just _ <- primitive name -> Right (finiteScalars bits limit name)
          Constructor name [TypeArgument element] | name `elem` ["Nullable", "Optional"] -> do
            values <- walk seen element
            pure (values >>= bounded . (PresenceValue t Nothing :) . map (PresenceValue t . Just))
          Constructor _ _ | any (\(key, size) -> key == populationKey table t && size <= typeSize t) seen -> Right Nothing
          Constructor _ _ -> do
            constructors <- viableConstructors registry table t
            alternatives <- mapM (\(tag,fields) -> do
              domains <- mapM (walk ((populationKey table t, typeSize t) : seen)) fields
              -- An empty field eliminates a constructor even if another
              -- field's domain is infinite or beyond the enumeration budget.
              if any (== Just []) domains then pure (Just []) else
                case sequence domains of
                  Nothing -> pure Nothing
                  Just sets | product (map (toInteger . length) sets) > toInteger limit -> pure Nothing
                            | otherwise -> bounded <$> filterM (acceptsValue registry bits t)
                                [DataValue t tag values | values <- sequence sets]) constructors
            pure (sequence alternatives >>= bounded . concat)
          _ -> Left ("no finite domain for " ++ show t)

-- Fixed-point reachability follows stored parameters rather than all type
-- arguments: Phantom Positive has no constrained values, while growing recursive
-- applications can eventually store a constrained argument. The finite lattice
-- contains only declaration parameters and a direct-contract bit.
hasValueContracts :: TypeRegistry -> Type -> Bool
hasValueContracts registry ty
  | not (any own declarations) = False
  | otherwise = fst (requirements (converge initial) ty)
  where
    declarations = registryDeclarations registry
    own declaration = any (not . null . constructorPredicates) (dataConstructors declaration)
    initial = M.fromList [(dataId d,(dataParameters d,(own d,[]))) | d <- declarations]
    merge values = (any fst values, sort (nub (concatMap snd values)))
    requirements table value = case value of
      TypeVariable name -> (False,[name])
      Arrow a b -> merge [requirements table a,requirements table b]
      Constructor name args
        | name `elem` ["Nullable","Optional"] -> merge
            [requirements table t | TypeArgument t <- args]
        | Just (parameters,(direct,stored)) <- M.lookup (Id name) table ->
            let bindings = zip parameters [t | TypeArgument t <- args]
            in merge ((direct,[]) : [requirements table t | parameter <- stored,
                 Just t <- [lookup parameter bindings]])
        | otherwise -> (False,[])
    step table = M.fromList [(dataId d,(dataParameters d,merge ((own d,[]) :
      [requirements table (binderType field) | constructor <- dataConstructors d,
        field <- constructorFields constructor]))) | d <- declarations]
    converge table = let next = step table in if next == table then table else converge next

-- Boundaries sample each constructor and each field's deterministic extremes.
-- Recursive expansion is bounded; a growing search first finds a witness, so a
-- long acyclic chain is never mistaken for an uninhabited domain.
boundariesWithRegistry :: TypeRegistry -> Int -> Type -> Either String [Value]
boundariesWithRegistry registry bits ty = do
  auditDomains registry bits
  supportedWithRegistry registry ty
  if hasContracts then do
    finite <- finiteValuesWithRegistry registry bits 256 ty
    case finite of
      Just values -> pure values
      Nothing -> do
        values <- constrainedBoundaries registry bits ty
        if null values then Left ("constructor field boundary search exhausted without a witness for " ++ show ty)
          else pure values
  else if not (inhabited table ty) then pure [] else findDepth 3
  where
    table = population registry
    hasContracts = hasValueContracts registry ty
    findDepth depth = do
      values <- walk depth ty
      complete <- coversConstructors values
      if complete then pure values else findDepth (depth * 2)
    coversConstructors values = case ty of
      Constructor name [] | Just _ <- primitive name -> pure (not (null values))
      Constructor name [TypeArgument element] | name `elem` ["Nullable", "Optional"] ->
        pure (not (inhabited table element) || any present values)
      Constructor _ _ -> do
        constructors <- viableConstructors registry table ty
        pure (all (\(tag, _) -> any (hasTag tag) values) constructors)
      _ -> pure False
    present (PresenceValue _ (Just _)) = True
    present _ = False
    hasTag expected (DataValue _ tag _) = expected == tag
    hasTag _ _ = False
    walk depth t
      | not (inhabited table t) = Right []
      | otherwise = case t of
          Constructor name [] | Just _ <- primitive name -> Right (scalarCases bits name)
          Constructor name [TypeArgument element] | name `elem` ["Nullable", "Optional"] -> do
            values <- if depth <= 0 then pure [] else walk (depth - 1) element
            pure (PresenceValue t Nothing : map (PresenceValue t . Just) values)
          Constructor "List" [TypeArgument element] -> do
            elements <- if depth <= 0 then pure [] else take 16 <$> walk (depth - 1) element
            let ordered = case elements of a:b:_ -> [[a,b],[b,a]]; _ -> []
            pure (map (listValue element) ([] : ordered ++ concat [[[value],[value,value]] | value <- elements]))
          Constructor _ _ -> do
            constructors <- viableConstructors registry table t
            concat <$> mapM (\(tag, fields) -> do
              domains <- if depth <= 0 && not (null fields) then pure [[]]
                else mapM (fmap (take 16) . walk (depth - 1)) fields
              pure [DataValue t tag values | values <- diagonal domains]) constructors
          _ -> Left ("no boundaries for " ++ show t)
    diagonal [] = [[]]
    diagonal sets | any null sets = []
                  | otherwise = [[values !! (index `mod` length values) | values <- sets]
                      | index <- [0 .. maximum (map length sets) - 1]]


-- A bounded witness search is deliberately separate from finite enumeration:
-- failure to find a value does not establish that its type is empty. Memoized
-- expansion and a global node budget bound recursive/growing applications.
-- Every returned candidate is checked by the same evaluator as examples.
constrainedBoundaries :: TypeRegistry -> Int -> Type -> Either String [Value]
constrainedBoundaries registry bits root =
  evalStateT (walk (length (registryDeclarations registry) + 3) root) (256, M.empty)
  where
    table = population registry
    constants = concat [concatMap literals (constructorPredicates c)
      | d <- registryDeclarations registry, c <- dataConstructors d]
    literals expression = case expressionNode expression of
      Constant scalar -> [scalar]
      _ -> concatMap literals (children expression)
    seeds name = nub (scalarCases bits name ++
      [ScalarValue value | literal <- constants,
        Right value <- [convertScalar bits name literal]])
    walk :: Int -> Type -> StateT (Int, M.Map (String,Int) [Value]) (Either String) [Value]
    walk depth ty
      | not (inhabited table ty) = pure []
      | otherwise = do
          (remaining,cache) <- get
          let key = (show ty,depth)
          case M.lookup key cache of
            Just values -> pure values
            Nothing | depth < 0 || remaining <= 0 -> pure []
            Nothing -> do
              modify (\(fuel,memo) -> (fuel-1,memo))
              values <- expand depth ty
              modify (\(fuel,memo) -> (fuel,M.insert key values memo))
              pure values
    expand depth ty = case ty of
      Constructor name [] | Just _ <- primitive name -> pure (seeds name)
      Constructor name [TypeArgument element] | name `elem` ["Nullable","Optional"] -> do
        values <- walk (depth-1) element
        pure (PresenceValue ty Nothing : map (PresenceValue ty . Just) (take 16 values))
      Constructor "List" [TypeArgument element] -> do
        elements <- take 16 <$> walk (depth-1) element
        let pairs = take 32 [[a,b] | a <- elements, b <- elements]
        pure (map (listValue element) ([] : map pure elements ++
          [[v,v] | v <- elements] ++ pairs))
      Constructor _ _ -> do
        constructors <- lift (viableConstructors registry table ty)
        concat <$> mapM (\(tag,fields) -> do
          domains <- mapM (walk (depth-1)) fields
          let candidates = [DataValue ty tag payload | payload <- combinations domains]
          take 32 <$> lift (filterM (acceptsValue registry bits ty) candidates)) constructors
      _ -> lift (Left ("no boundary witnesses for " ++ show ty))
    -- Diagonals preserve coverage of each field's extrema; the bounded product
    -- adds unequal combinations needed by dependent fields such as y > x.
    combinations [] = [[]]
    combinations domains | any null domains = []
    combinations domains = nub (diagonal ++ take 512 (sequence domains))
      where
        diagonal = [[values !! (index `mod` length values) | values <- domains]
          | index <- [0 .. maximum (map length domains) - 1]]


-- A field supplied by a type parameter can itself be a smaller occurrence of
-- the same constructor (Box (Box Bool)). That is finite nesting, not a recursive
-- expansion. Non-decreasing repeated population profiles mark productive cycles.
typeSize :: Type -> Int
typeSize (Constructor _ args) = 1 + sum [typeSize t | TypeArgument t <- args]
typeSize (Arrow a b) = 1 + typeSize a + typeSize b
typeSize (TypeVariable _) = 1
