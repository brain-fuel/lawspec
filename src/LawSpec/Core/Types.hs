-- Shared algebraic type declarations and kind checking. The registry contains
-- core identities, never source names awaiting resolution or target mappings.
module LawSpec.Core.Types
  ( TypeRegistry, makeRegistry, builtinDataDeclarations, registryKinds, registryDeclarations
  , kindOf, checkType, substitute, constructorFieldsFor, constructorPredicatesFor, lookupData, equalityRequirements, generationRequirements
  , constructorCompatibility, compatibleConstructors, matchType, constructorFieldsAt, freeExistentials, witnessPool
  ) where

import Control.Monad (foldM, forM_, unless)
import Data.Graph (SCC(..), stronglyConnComp)
import Data.List (nub, sort)
import qualified Data.Map.Strict as M
import LawSpec.Core
import LawSpec.Scalar (primitiveName, primitives)

data TypeRegistry = TypeRegistry
  { registryKinds :: [(String, Kind)]
  , declarations :: M.Map Id DataDeclaration
  , storedFieldRules :: M.Map Id (Maybe [Id])
  }

registryDeclarations :: TypeRegistry -> [DataDeclaration]
registryDeclarations = M.elems . declarations

builtinDataDeclarations :: [DataDeclaration]
builtinDataDeclarations = [list, optional, eitherType]
  where
    a owner = TypeVariable (Id (owner ++ "::a"))
    b owner = TypeVariable (Id (owner ++ "::b"))
    declaration name parameters constructors = DataDeclaration
      (Id name) name (map (Id . ((name ++ "::") ++)) parameters)
      [DataConstructor (Id (name ++ "::" ++ tag)) tag
        [Binder (Id (name ++ "::" ++ tag ++ "::" ++ field)) field ty | (field, ty) <- fields]
        [] (GeneratedFrom (Id name)) [] [] | (tag, fields) <- constructors]
      (GeneratedFrom (Id name)) Nothing
    list = declaration "List" ["a"]
      [("Nil", []), ("Cons", [("head", a "List"), ("tail", Constructor "List" [TypeArgument (a "List")])])]
    optional = declaration "Maybe" ["a"]
      [("Nothing", []), ("Just", [("value", a "Maybe")])]
    eitherType = declaration "Either" ["a", "b"]
      [("Left", [("value", a "Either")]), ("Right", [("value", b "Either")])]

makeRegistry :: [DataDeclaration] -> Either String TypeRegistry
makeRegistry userDeclarations = do
  let allDeclarations = builtinDataDeclarations ++ userDeclarations
      scalarKinds = [(primitiveName p, TypeKind) | p <- primitives]
      presenceKinds = [(n, KindArrow TypeKind TypeKind) | n <- ["Nullable", "Optional"]]
      kinds = scalarKinds ++ presenceKinds ++
        [(idText (dataId d), foldr (const (KindArrow TypeKind)) TypeKind (dataParameters d)) | d <- allDeclarations]
      registry = TypeRegistry kinds (M.fromList [(dataId d, d) | d <- allDeclarations])
        (deriveStoredFieldCapabilities allDeclarations)
  unique "type constructor identity" (map fst kinds)
  unique "data constructor identity" [constructorId c | d <- allDeclarations, c <- dataConstructors d]
  mapM_ (validateDeclaration registry) allDeclarations
  validateStrictPositivity allDeclarations
  pure registry
  where
    validateDeclaration registry d = do
      unique "type parameter" (dataParameters d)
      unique "constructor name" (map constructorName (dataConstructors d))
      mapM_ (validateConstructor registry (dataParameters d)) (dataConstructors d)
    validateConstructor registry parameters c = do
      unique "field identity" (map binderId (constructorFields c))
      unique "field name" (map binderName (constructorFields c))
      unique "existential type" (constructorExistentials c)
      -- Runtimes append witness fields named witness or witness<k>.
      let witnessed = length [e | e <- constructorExistentials c, e `notElem` concatMap (typeVariables . snd) (constructorEquations c)]
          reserved = "witness" : ["witness" ++ show k | k <- [0 .. witnessed - 1]]
      unless (witnessed == 0 || all ((`notElem` reserved) . binderName) (constructorFields c))
        (Left ("a field of " ++ idText (constructorId c) ++ " cannot be named witness: its type witness takes that name"))
      let scope = parameters ++ constructorExistentials c
      mapM_ (\field -> do
        let ty = binderType field
        checkType registry ty
        unless (all (`elem` scope) (typeVariables ty))
          (Left ("unbound type parameter in constructor " ++ idText (constructorId c)))) (constructorFields c)
      unique "refined type parameter" (map fst (constructorEquations c))
      forM_ (constructorEquations c) $ \(parameter, ty) -> do
        unless (parameter `elem` parameters)
          (Left ("constructor " ++ idText (constructorId c) ++ " refines an unknown type parameter"))
        checkType registry ty
        unless (all (`elem` constructorExistentials c) (typeVariables ty))
          (Left ("unbound type in the refinement of constructor " ++ idText (constructorId c)))

unique :: Eq a => String -> [a] -> Either String ()
unique label values = unless (length values == length (nub values)) (Left ("duplicate " ++ label))

kindOf :: [(String, Kind)] -> Type -> Either String Kind
kindOf registry ty = case ty of
  TypeVariable _ -> Right TypeKind
  Arrow a b -> do
    ka <- kindOf registry a
    kb <- kindOf registry b
    unless (ka == TypeKind && kb == TypeKind) (Left "arrow operands must have kind Type")
    pure TypeKind
  Constructor n args -> do
    k <- maybe (Left ("unknown type constructor: " ++ n)) Right (lookup n registry)
    foldM apply k args
  where
    apply (KindArrow expected result) arg = do
      actual <- case arg of
        TypeArgument t -> kindOf registry t
        IndexArgument (Natural n) | n < 0 -> Left "natural index cannot be negative"
        IndexArgument _ -> Right ValueKind
      unless (actual == expected) (Left "type/index argument kind mismatch")
      pure result
    apply _ _ = Left "too many type arguments"

checkType :: TypeRegistry -> Type -> Either String ()
checkType registry ty = do
  k <- kindOf (registryKinds registry) ty
  unless (k == TypeKind) (Left "unsaturated type constructor")

lookupData :: TypeRegistry -> Id -> Either String DataDeclaration
lookupData registry name = maybe (Left ("unknown data type: " ++ idText name)) Right
  (M.lookup name (declarations registry))

-- Check the parent type as well as the tag: equal payloads must never make
-- constructors from different sums interchangeable. Substitute recursively.
constructorFieldsFor :: TypeRegistry -> Type -> Id -> Either String [Binder]
constructorFieldsFor registry ty tag = do
  checkType registry ty
  case ty of
    Constructor name arguments -> do
      declaration <- lookupData registry (Id name)
      constructor <- maybe (Left ("constructor " ++ idText tag ++ " does not belong to " ++ name)) Right
        (lookup tag [(constructorId c, c) | c <- dataConstructors declaration])
      existentials <- constructorCompatibility declaration constructor [t | TypeArgument t <- arguments]
      let substitutions = M.union (M.fromList (zip (dataParameters declaration) [t | TypeArgument t <- arguments])) existentials
      pure [field {binderType = substitute substitutions (binderType field)} | field <- constructorFields constructor]
    _ -> Left "data construction requires an applied data type"

-- A field-only existential is not determined by the type: its type comes from
-- the constructor's arguments (or a value's fields), matched against the
-- field types. Runtimes carry it as a witness.
freeExistentials :: DataDeclaration -> DataConstructor -> [Id]
freeExistentials _ constructor =
  [e | e <- constructorExistentials constructor, e `notElem` concatMap (typeVariables . snd) (constructorEquations constructor)]

-- The types generated values of a field-only existential take. Runtimes use
-- the same pool.
witnessPool :: [Type]
witnessPool = [Constructor "Bool" [], Constructor "Int32" []]

constructorFieldsAt :: TypeRegistry -> Type -> Id -> [Type] -> Either String [Binder]
constructorFieldsAt registry ty tag actual = do
  checkType registry ty
  case ty of
    Constructor name arguments -> do
      declaration <- lookupData registry (Id name)
      constructor <- maybe (Left ("constructor " ++ idText tag ++ " does not belong to " ++ name)) Right
        (lookup tag [(constructorId c, c) | c <- dataConstructors declaration])
      determined <- constructorCompatibility declaration constructor [t | TypeArgument t <- arguments]
      let parameters = M.fromList (zip (dataParameters declaration) [t | TypeArgument t <- arguments])
          known = M.union parameters determined
          free = freeExistentials declaration constructor
      bound <- if null free then pure known else do
        unless (length actual == length (constructorFields constructor))
          (Left ("constructor payload arity mismatch: " ++ idText tag))
        maybe (Left ("the field types of " ++ idText tag ++ " disagree on its existential types")) Right $
          foldM (\acc (field, value) -> matchType free acc (substitute known (binderType field)) value)
            known (zip (constructorFields constructor) actual)
      pure [field {binderType = substitute bound (binderType field)} | field <- constructorFields constructor]
    _ -> Left "data construction requires an applied data type"

-- Whether a constructor builds values of a declaration at these arguments,
-- and the existential types its equations then determine.
constructorCompatibility :: DataDeclaration -> DataConstructor -> [Type] -> Either String (M.Map Id Type)
constructorCompatibility declaration constructor arguments =
  maybe (Left (constructorName constructor ++ " is not a value of " ++ dataName declaration ++
      concatMap ((" " ++) . show) arguments)) Right $
    foldM (\bound (parameter, pattern) -> do
      argument <- lookup parameter (zip (dataParameters declaration) arguments)
      matchType (constructorExistentials constructor) bound pattern argument) M.empty
      (constructorEquations constructor)

-- One-way matching: existential variables in the pattern bind to the type.
matchType :: [Id] -> M.Map Id Type -> Type -> Type -> Maybe (M.Map Id Type)
matchType existentials bound pattern ty = case (pattern, ty) of
  (TypeVariable v, _) | v `elem` existentials -> case M.lookup v bound of
    Just previous | previous == ty -> Just bound
                  | otherwise -> Nothing
    Nothing -> Just (M.insert v ty bound)
  (Constructor a xs, Constructor b ys) | a == b, length xs == length ys ->
    foldM (\acc (x, y) -> case (x, y) of
      (TypeArgument p, TypeArgument t) -> matchType existentials acc p t
      _ | x == y -> Just acc
        | otherwise -> Nothing) bound (zip xs ys)
  (Arrow a b, Arrow c d) -> matchType existentials bound a c >>= \acc -> matchType existentials acc b d
  _ | pattern == ty -> Just bound
    | otherwise -> Nothing

-- Constructors whose values can have this type.
compatibleConstructors :: TypeRegistry -> Type -> Either String [DataConstructor]
compatibleConstructors registry ty = case ty of
  Constructor name arguments -> do
    declaration <- lookupData registry (Id name)
    pure [c | c <- dataConstructors declaration,
      either (const False) (const True) (constructorCompatibility declaration c [t | TypeArgument t <- arguments])]
  _ -> Left "constructors require an applied data type"

-- Instantiation retains resolved field identities while substituting every
-- type carried by an expression, including match binders and numeric evidence.
constructorPredicatesFor :: TypeRegistry -> Type -> Id -> Either String [Expr]
constructorPredicatesFor registry ty tag = do
  _ <- constructorFieldsFor registry ty tag
  case ty of
    Constructor name arguments -> do
      declaration <- lookupData registry (Id name)
      constructor <- maybe (Left "unknown constructor predicate owner") Right
        (lookup tag [(constructorId c,c) | c <- dataConstructors declaration])
      let types = M.fromList (zip (dataParameters declaration) [t | TypeArgument t <- arguments])
      pure (map (instantiateExpression types) (constructorPredicates constructor))
    _ -> Left "constructor predicates require an applied data type"

instantiateExpression :: M.Map Id Type -> Expr -> Expr
instantiateExpression substitutions = go
  where
    ty = substitute substitutions
    binder b = b{binderType=ty (binderType b)}
    evidence (Numeric t) = Numeric (ty t)
    evidence (Structural t) = Structural (ty t)
    go e = e{expressionType=ty (expressionType e),expressionNode=case expressionNode e of
      Constant scalar -> Constant scalar
      Local identity -> Local identity
      Construct identity values -> Construct identity (map go values)
      Match value branches -> Match (go value)
        [branch{caseBinders=map binder (caseBinders branch),caseBody=go (caseBody branch)} | branch <- branches]
      AllElements value field predicate -> AllElements (go value) (binder field) (go predicate)
      AllPayloads value predicates -> AllPayloads (go value)
        [(binder field,go predicate) | (field,predicate) <- predicates]
      ExternalCall identity arguments -> ExternalCall identity (map go arguments)
      Binary op ev left right -> Binary op (evidence ev) (go left) (go right)
      Unary op value -> Unary op (go value)
      ShortCircuit op left right -> ShortCircuit op (go left) (go right)
      Convert mode target value -> Convert mode (ty target) (go value)
      Helper builtin arguments -> Helper builtin (map go arguments)}

typeVariables :: Type -> [Id]
typeVariables (TypeVariable n) = [n]
typeVariables (Arrow a b) = typeVariables a ++ typeVariables b
typeVariables (Constructor _ args) = concat [typeVariables t | TypeArgument t <- args]

substitute :: M.Map Id Type -> Type -> Type
substitute env ty = case ty of
  TypeVariable n -> M.findWithDefault ty n env
  Arrow a b -> Arrow (substitute env a) (substitute env b)
  Constructor n args -> Constructor n
    [case arg of TypeArgument t -> TypeArgument (substitute env t); _ -> arg | arg <- args]

-- Recursive data must be strictly positive. Follow parameter use through other
-- declarations too: putting a recursive value in Box a is unsafe when Box
-- consumes a through a function argument. Double negation is not sufficient.
validateStrictPositivity :: [DataDeclaration] -> Either String ()
validateStrictPositivity definitions = mapM_ checkComponent components
  where
    fields d = [binderType f | c <- dataConstructors d, f <- constructorFields c]
    names (TypeVariable _) = []
    names (Arrow a b) = names a ++ names b
    names (Constructor name arguments) = Id name : concat [names t | TypeArgument t <- arguments]
    components = stronglyConnComp [(d, dataId d, concatMap names (fields d)) | d <- definitions]
    initial = M.fromList [(dataId d, replicate (length (dataParameters d)) False) | d <- definitions]
    unsafeParameters = fixedPoint initial
    fixedPoint previous =
      let next = M.fromList
            [(dataId d, [any (usesUnsafely previous parameter False) (fields d) | parameter <- dataParameters d]) | d <- definitions]
      in if next == previous then next else fixedPoint next
    argumentRisks table name arguments = zip arguments
      (M.findWithDefault (replicate (length arguments) False) (Id name) table)
    usesUnsafely table parameter unsafe ty = case ty of
      TypeVariable n -> n == parameter && unsafe
      Arrow a b -> usesUnsafely table parameter True a || usesUnsafely table parameter unsafe b
      Constructor name arguments -> or
        [usesUnsafely table parameter (unsafe || risk) t
          | (TypeArgument t, risk) <- argumentRisks table name arguments]
    checkComponent (AcyclicSCC _) = Right ()
    checkComponent (CyclicSCC members) = do
      let recursive = map dataId members
      mapM_ (\d -> unless (all (positive recursive False) (fields d))
        (Left ("recursive data type is not strictly positive: " ++ idText (dataId d)))) members
    positive recursive unsafe ty = case ty of
      TypeVariable _ -> True
      Arrow a b -> positive recursive True a && positive recursive unsafe b
      Constructor name arguments ->
        not (unsafe && Id name `elem` recursive) && and
          [positive recursive (unsafe || risk) t
            | (TypeArgument t, risk) <- argumentRisks unsafeParameters name arguments]

-- Derivation computes the parameters actually inspected by equality, rather
-- than demanding Eq for every argument. The finite fixed point also handles
-- mutual and non-regular recursion without unfolding an infinite type tree.
-- Nothing means a stored field has no equality (for example a function).
deriveStoredFieldCapabilities :: [DataDeclaration] -> M.Map Id (Maybe [Id])
deriveStoredFieldCapabilities definitions = fixedPoint initial
  where
    table = M.fromList [(dataId d, d) | d <- definitions]
    initial = M.fromList [(dataId d, Just []) | d <- definitions]
    fixedPoint previous =
      let next = M.fromList
            [(dataId d, combineNeeds
              -- An existential's types (the witness pool, or those its
              -- equations fix) all have equality and generators.
              [filter (`notElem` constructorExistentials c) <$> storedFieldNeeds table previous (binderType f)
                | c <- dataConstructors d, f <- constructorFields c])
              | d <- definitions]
      in if next == previous then next else fixedPoint next

combineNeeds :: [Maybe [Id]] -> Maybe [Id]
combineNeeds = fmap (sort . nub . concat) . sequence

storedFieldNeeds :: M.Map Id DataDeclaration -> M.Map Id (Maybe [Id]) -> Type -> Maybe [Id]
storedFieldNeeds definitions rules ty = case ty of
  TypeVariable n -> Just [n]
  Arrow _ _ -> Nothing
  Constructor name arguments
    | name `elem` ["Nullable", "Optional"], [TypeArgument element] <- arguments ->
        storedFieldNeeds definitions rules element
    | Just declaration <- M.lookup (Id name) definitions -> do
        required <- M.lookup (Id name) rules >>= id
        let parameters = zip (dataParameters declaration) [t | TypeArgument t <- arguments]
        combineNeeds [lookup parameter parameters >>= storedFieldNeeds definitions rules | parameter <- required]
    | null arguments, name `elem` map primitiveName primitives -> Just []
    | otherwise -> Nothing

-- Return outstanding Eq obligations for type variables. A concrete type has
-- derived equality exactly when this list is empty.
equalityRequirements :: TypeRegistry -> Type -> Either String [Id]
equalityRequirements = storedRequirements "structural equality"

-- Current built-in value domains support both generation and equality. Both
-- derivations follow stored fields, including parameter transformations in
-- recursive declarations; neither acquires support for function-valued fields.
generationRequirements :: TypeRegistry -> Type -> Either String [Id]
generationRequirements = storedRequirements "generation"

storedRequirements :: String -> TypeRegistry -> Type -> Either String [Id]
storedRequirements capability registry ty = do
  checkType registry ty
  maybe (Left ("type does not support " ++ capability ++ ": " ++ show ty)) Right
    (storedFieldNeeds (declarations registry) (storedFieldRules registry) ty)
