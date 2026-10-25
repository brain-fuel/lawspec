-- | Execution feasibility and deterministic cases are planned after elaboration.
-- This module consumes only typed core, never surface syntax or inference.
module LawSpec.Testing where
import GHC.Generics (Generic)
import LawSpec.Core
import qualified LawSpec.Core.EqSet as EqSet
import qualified LawSpec.Core.Verification as V
import LawSpec.Common
import LawSpec.Scalar
import LawSpec.Core.Eval (evaluateValue, evaluateValuePure)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Quantification (lowerFinitePropositionCandidates, lowerWitnessPropositionCandidates, lowerSearchPropositionCandidates)
import LawSpec.Core.Search (Candidate(..), applyCandidate, strategyCandidates)
import LawSpec.Core.QuantifierDomain (finiteQuantifierTerms, finiteQuantifierCandidates)
import LawSpec.Core.Total (constructorProofContracts)
import LawSpec.Core.Value
import LawSpec.Testing.Cover (FiniteCover(..), compressCases, coverCases, coverCount)
import LawSpec.Core.Types (TypeRegistry, makeRegistry, registryDeclarations, builtinDataDeclarations, lookupData, constructorFieldsFor, compatibleConstructors, generationRequirements, freeExistentials, substitute, witnessPool)
import qualified Data.Map.Strict as M
import Data.Containers.ListUtils (nubOrd)
import LawSpec.Memo (Table, newPersistentTable, memoized)
import LawSpec.CorePersist ()
import LawSpec.Core.Identity (Encode, Collect)
import LawSpec.Core.RecordIdentity (internRecordDeclarations)
import LawSpec.Core.RecordNormalize (normalizeProgramRecords)
import Data.Binary (Binary)
import LawSpec.Dependencies (dependencyGraphWithBits, lawReferences, closure, fullKey, reachableData, reachableDefinitions)
import System.IO.Unsafe (unsafePerformIO)
import Control.Exception (evaluate)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.Mem.StableName (StableName, makeStableName)
import Data.List (find, nub, partition, sort, stripPrefix, zip3)
import LawSpec.Regex (Regex, parseRegex, regexSamples)
import LawSpec.IndexTerm
import Control.Monad (filterM, unless, when)
import Control.Monad.State.Strict (StateT, evalStateT, get, modify, lift)

-- | The testing plan is computed once, from Core, and shared by every target,
-- so each target tests the same cases. ref:DEC-planned-generation
data Plan = Plan
  { planMachineBits :: Int, planDataDeclarations :: [DataDeclaration]
  , plannedUnits :: [PlannedUnit]
  -- Execution selection is separate from the authoritative typed units.
  , planModelChecks :: Bool
  , planPropertyChecks :: Bool
  } deriving (Eq, Show, Generic)
-- | Each unit's laws are planned together because they are emitted together.
data PlannedUnit = PlannedUnit { plannedUnit :: Unit, plannedProperties :: [PlannedProperty] } deriving (Eq, Show, Generic)
-- | The finite domain, when there is one, turns a property test into an
-- exhaustive check; boundary cases run before random ones on every target.
-- ref:DEC-evidence-statuses
data PlannedProperty = PlannedProperty
  { plannedProperty :: Property, finiteCover :: Maybe FiniteCover, boundaryCases :: [[Value]]
  , generatorRequirements :: [GeneratorRequirement]
  -- Presentation keeps the checked claim, not the execution loop or its
  -- three-valued implementation. It must never expand into one body per value.
  , sourceBody :: Proposition
  } deriving (Eq, Show, Generic)

-- | Reference/evidence compatibility view. Native emitters consume caseCover
-- to keep intervals and shared suffixes in their generated source.
finiteCases :: PlannedProperty -> Maybe [[Value]]
finiteCases = fmap coverCases . finiteCover

caseCover :: PlannedProperty -> Either String FiniteCover
caseCover p = maybe (compressCases (boundaryCases p)) Right (finiteCover p)
-- | What each input's generator must respect, so every target's framework
-- generates inside the same domain. ref:DEC-shrink-within-domain
data GeneratorRequirement = GeneratorRequirement { generatorBinder :: Binder, generatorPredicates :: [Expr], generatorBoundaries :: [Value], generatorBounds :: [(BinaryOp,Expr)], generatorHints :: [Expr], generatorIndex :: Maybe IndexedGeneration } deriving (Eq, Show, Generic)

-- | A predicate m x == target, where m is the index measure of a family,
-- directs generation. Each constructor of every family reachable through
-- index fields carries its index term then its guards, in prefix notation
-- (indexTermText). Runtimes solve the target backwards over field indices, so
-- the predicate never rejects a sample.
data IndexedGeneration = IndexedGeneration
  { indexedTarget :: Expr
  , indexedEquations :: [(Id, [String])]
  } deriving (Eq, Show, Generic)

-- | An unavailable execution plan is a generation error. Legacy input domains
-- require inhabitants; canonical universal domains can be proved empty, with
-- explicit zero-case evidence rather than successful property-testing evidence.
-- ref:DEC-never-pass-vacuously
-- | The plan sees each definition's field nodes as the matches they stand
-- for (lowerFieldNodes), as every backend does.
planTesting :: Program -> Either [Diagnostic] Plan
planTesting program = do
  normalized <- normalizeProgramRecords program
  planLowered (lowerProgramFields normalized)

-- | Execution is planned independently of completed evidence. No layers means
-- no optional tests; typed definitions still reach every native emitter.
planTestingWith :: V.Verification -> Program -> Either [Diagnostic] Plan
planTestingWith config program = do
  let executable = any (V.selected config) [V.Exhaustive,V.Property,V.Examples]
      selectedProgram = program { programUnits =
        [ u { unitProperties = if not executable then []
              else if any (V.selected config) [V.Exhaustive,V.Property] then unitProperties u
              else filter (not . null . propertyExamples) (unitProperties u) }
        | u <- programUnits program ] }
  plan <- planTesting selectedProgram
  when (V.selected config V.Exhaustive && not (V.selected config V.Property) &&
    any ((== Nothing) . finiteCases) (concatMap plannedProperties (plannedUnits plan)))
    (Left [Diagnostic "verification-incomplete" "complete finite coverage was requested but exceeds the finite domain or exhaustive limit; no exhaustive success is claimed" Nothing])
  pure plan { planModelChecks = V.selected config V.Model,
    planPropertyChecks = V.selected config V.Property,
    plannedUnits = [let properties = map choose (plannedProperties u)
    in u { plannedProperties = properties, plannedUnit = (plannedUnit u) { unitProperties = map plannedProperty properties } }
    | u <- plannedUnits plan] }
  where
    choose p = p
      { plannedProperty = (plannedProperty p) { propertyExamples =
          if V.selected config V.Examples then propertyExamples (plannedProperty p) else [] }
      , finiteCover = if propertyInputDomain (plannedProperty p) == UniversalDomain && finiteCases p == Just [] then Just (Alternatives [])
          else if V.selected config V.Exhaustive && finiteCover p /= Nothing then finiteCover p
          else if V.selected config V.Property then
            -- A complete singleton has no varying choices. Execute that
            -- input once, just as a law with no inputs, instead of asking a
            -- native framework to invent distinct random samples.
            if null (propertyInputs (plannedProperty p)) || singleton p then finiteCover p else Nothing
          else Just (Alternatives [])
      , boundaryCases = if V.selected config V.Property then boundaryCases p else [] }
    singleton p = maybe False ((== 1) . coverCount) (finiteCover p)

planLowered :: Program -> Either [Diagnostic] Plan
planLowered program@Program{..} = do
  plan <- lawPlanner program
  -- lawPlanner admits all original constructor contracts before duplicate
  -- structural products are shared by generated native declarations.
  interned <- either (Left . pure . (\message -> Diagnostic "generation" message Nothing)) Right
    (internRecordDeclarations programDataDeclarations)
  let unit u = do
        properties <- mapM property (unitProperties u)
        pure (PlannedUnit (u { unitProperties = map plannedProperty properties }) properties)
      property p = either (Left . pure . (\m -> Diagnostic "generation" m (Just (propertyLocation p)))) Right (plan p)
  units<-mapM unit programUnits
  pure (Plan programMachineBits interned units True True)

-- | Only model-test builders receive this execution view. Public actor and
-- supervisor APIs, validation, definitions and source/evidence views use the
-- complete plannedUnit. Never replace the units stored in a Plan with it.
modelTestUnit :: Plan -> Unit -> Unit
modelTestUnit plan unit
  | planModelChecks plan=unit
  | otherwise=unit{unitMachines=[],unitSupervisors=[]}

modelTestUnits :: Plan -> [Unit]
modelTestUnits plan=map (modelTestUnit plan . plannedUnit) (plannedUnits plan)

-- | How each law of a program is planned, by the generated tests and by
-- evidence discharge alike. A law is planned from what it reaches: the types
-- and definitions in its dependency closure. A plan shows names, so its key
-- is the law's semantic and presentation hashes (LawSpec.Dependencies):
-- an edit replans exactly the laws that can reach it, and reverting an edit
-- finds the earlier plans again.
lawPlanner :: Program -> Either [Diagnostic] (Property -> Either String PlannedProperty)
lawPlanner program@Program{..} = do
  invoke <- prepareDefinitions program
  _ <- either (Left . pure . (\message -> Diagnostic "generation" message Nothing)) Right (makeRegistry programDataDeclarations)
  let graph = dependencyGraphWithBits programMachineBits programDataDeclarations programUnits
  pure $ \p ->
    let refs = lawReferences graph p
        reached = closure graph refs
    in memoized planTable (fullKey graph (show programMachineBits) p) $ do
      registry <- makeRegistry (reachableData graph reached)
      planProperty registry programMachineBits invoke (reachableDefinitions graph reached) p

instance Binary GeneratorRequirement
instance Binary IndexedGeneration
instance Binary PlannedProperty
instance Binary PlannedUnit
instance Binary Plan
instance Encode GeneratorRequirement
instance Encode IndexedGeneration
instance Encode PlannedProperty
instance Collect GeneratorRequirement
instance Collect IndexedGeneration
instance Collect PlannedProperty

-- | Plans persist across runs, so lawspec test replans only the laws an edit can
-- reach. ref:DEC-incremental-compilation
planTable :: Table (Either String PlannedProperty)
planTable = unsafePerformIO (newPersistentTable "plan" 2048 (const 1))
{-# NOINLINE planTable #-}

-- | One property's finite domain, boundary cases and generator requirements.
planProperty :: TypeRegistry -> Int -> (Id -> [Value] -> Either String Value) -> [Definition]
  -> Property -> Either String PlannedProperty
planProperty registry bits invoke definitions p
  | not (null (propertyParameters p)) = Left "instantiate a law's formal values before planning native tests; sampled parameters cannot establish uniform input domains"
  | propertyInputDomain p == UniversalDomain = do
      let qs = propertyInputs p
          limit = exhaustiveLimit (propertyGeneration p)
      closedRestrictions <- mapM (evaluateValue registry bits invoke [])
        [predicate | q <- qs,predicate <- quantifiedPredicates q,null (freeBinders predicate)]
      finite <- if ScalarValue (SBool False) `elem` closedRestrictions
        then pure (Just []) else finiteUniversalInputs registry bits limit invoke qs
      case finite of
        Just [] -> do
          unless (null (propertyExamples p))
            (Left "an example cannot supply inputs in an empty universal domain")
          -- No input can reach the body, including any inner infinite search
          -- or native operation. Keep the authoritative body in the program;
          -- the execution plan needs neither generators nor a body evaluation.
          let boolean = scalarType "Bool"
              truth = Expr boolean (Constant (SBool True)) (GeneratedFrom (propertyId p))
          pure (PlannedProperty (p { propertyBody = Equation (Structural boolean) truth truth }) (Just (Alternatives [])) [] [] (propertyBody p))
        _ -> planPopulatedProperty registry bits invoke definitions p
  | otherwise = planPopulatedProperty registry bits invoke definitions p

planPopulatedProperty :: TypeRegistry -> Int -> (Id -> [Value] -> Either String Value) -> [Definition]
  -> Property -> Either String PlannedProperty
planPopulatedProperty registry programMachineBits invoke definitions p = do
      let qs = propertyInputs p
          settings = propertyGeneration p
          types = map (binderType . quantifiedBinder) qs
          effectful = withSeen []
          withSeen seen expression = case expressionNode expression of
            Perform _ _ -> True
            Handle _ _ -> True
            Calls _ _ -> True
            Helper operation _ | operation `elem` [Recorded,AcquireResource,ReleaseResource,FreePort] -> True
            ExternalCall name arguments -> any (withSeen seen) arguments || any
              (\definition -> declarationId (definitionDeclaration definition) == name &&
                (definitionOrchestrates definition || not (null (declarationUses (definitionDeclaration definition))) ||
                 (name `notElem` seen && withSeen (name : seen) (definitionBody definition)))) definitions
            _ -> any (withSeen seen) (children expression)
          searched proposition = case proposition of
            Quantified _ _ _ -> propositionExpressions proposition
            Negation body -> searched body
            Conjunction bodies -> concatMap searched bodies
            Implication _ body -> searched body
            Equation _ _ _ -> []
      when (any effectful (searched (propertyBody p)))
        (Left "quantifier-search-unsupported: effectful witness search requires explicit snapshot semantics")
      mapM_ (supportedWithRegistry registry) types
      let inhabitants = population registry
      mapM_ (\ty -> unless (inhabited inhabitants ty) (Left ("uninhabited input domain: " ++ show ty))) types
      mapM_ (\e -> if null (freeBinders e) then do
          v <- evaluateValue registry programMachineBits invoke [] e
          unless (v == ScalarValue (SBool True)) (Left "refined input domain has no valid tuples")
        else Right ()) (concatMap quantifiedPredicates qs)
      domains <- mapM (finiteValuesWithRegistry registry programMachineBits (exhaustiveLimit settings)) types
      finite <- if propertyInputDomain p == UniversalDomain then
        finiteUniversalInputs registry programMachineBits (exhaustiveLimit settings) invoke qs
        else case sequence domains of
          Just sets | product (map (toInteger . length) sets) <= toInteger (exhaustiveLimit settings) -> Just <$> filterM (validTupleWithDefinitions registry programMachineBits invoke qs) (sequence sets)
          _ -> Right Nothing
      unless (finite /= Just []) (Left "refined input domain has no valid tuples")
      -- A text refined by a regex starts from texts the regex matches, and
      -- a value whose field is, from values with such fields.
      bs <- sequence [case domain of
          Just values | hasValueContracts registry ty -> pure values
          _ -> (\base -> patternValues definitions q ++ fieldPatternValues definitions q base ++ base) <$> boundariesWithRegistry registry programMachineBits ty
        | (q,ty,domain) <- zip3 qs types domains]
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
      let scopedDomain = finiteQuantifierCandidates programMachineBits (exhaustiveLimit settings)
            (finiteValuesWithRegistry registry programMachineBits (exhaustiveLimit settings))
      body <- if propertyInputDomain p == UniversalDomain then
        lowerSearchPropositionCandidates scopedDomain (boundedLawSearch registry programMachineBits p)
          (exhaustiveLimit settings) (maxAttempts settings) (propertyId p) (harnessWitnesses (propertyHarness p)) (propertyBody p)
        else lowerWitnessPropositionCandidates scopedDomain
          (exhaustiveLimit settings) (propertyId p) (harnessWitnesses (propertyHarness p)) (propertyBody p)
      exampleBodies <- mapM (\example -> do
        expectations <- mapM (lowerFinitePropositionCandidates scopedDomain
          (exhaustiveLimit settings) (propertyId p)) (exampleExpectations example)
        pure (example { exampleExpectations = expectations })) (propertyExamples p)
      cover <- traverse compressCases finite
      pure (PlannedProperty (p { propertyBody = body, propertyExamples = exampleBodies }) cover cases [GeneratorRequirement (quantifiedBinder q) (quantifiedPredicates q) b (quantifiedBounds q) (domainHints q ++ patternHints definitions q) (indexedGeneration (registryDeclarations registry) definitions q) | (q,b) <- zip qs bs] (propertyBody p))

-- | Bounded deterministic search shares typed strategy expressions with the
-- ordinary harness. Samples are never exposed as complete finite covers.
-- Restrictions are checked later in the actual lexical prefix, including
-- every recheck made while the outer framework shrinks a counterexample.
boundedLawSearch :: TypeRegistry -> Int -> Property -> Quantifier -> Proposition -> Either String [Candidate]
boundedLawSearch registry bits property q body = case selected of
  strategy:_ -> strategyCandidates budget pool strategy
  [] | configured -> pure []
     | otherwise -> map Candidate <$> pool ty (Just q)
  where
    settings = propertyGeneration property
    budget = max 0 (min (cases settings) (maxAttempts settings))
    ty = binderType (quantifiedBinder q)
    identity = binderId (quantifiedBinder q)
    selected = [strategy | (target,_,_,strategy) <- harnessSearches (propertyHarness property),target == identity]
    configured = any ((== identity) . witnessTarget) (harnessWitnesses (propertyHarness property))
    origin = GeneratedFrom (propertyId property)
    pool wanted aim = do
      let target = case aim of
            Just aimed -> aimed
            Nothing | wanted == ty -> q
            _ -> Quantifier (Binder (Id (idText identity ++ "::sample")) "sample" wanted) [] []
          hints = [candidate | hint <- domainHints target,candidate <- nearby wanted hint]
          literals = [normal expression | root <- propositionExpressions body,expression <- descend root,
            expressionType expression == wanted,literalSeed expression]
          small = case wanted of
            Constructor name [] | isInteger name -> [Expr wanted (Constant scalar) origin |
              n <- take budget (0 : concat [[k,negate k] | k <- [1..]]),
              Right scalar <- [validateScalar bits (SInteger name n)]]
            _ -> []
      finite <- finiteQuantifierTerms bits (max 1 (maxAttempts settings))
        (finiteValuesWithRegistry registry bits (max 1 (maxAttempts settings))) target
      edges <- case finite of
        Just values -> pure values
        Nothing -> mapM valueTerm =<< boundariesWithRegistry registry bits wanted
      pure (take budget (nub (map normal (hints ++ literals ++ edges ++ small))))
    descend expression = expression : concatMap descend (children expression)
    normal expression = (mapChildren normal expression) { expressionOrigin = origin }
    literalSeed expression = isConcrete expression || case expressionNode expression of
      Unary Negate value -> literalSeed value
      _ -> False
    valueTerm value = case value of
      ScalarValue scalar -> pure (Expr (valueType value) (Constant scalar) origin)
      DataValue wanted tag values -> (\terms -> Expr wanted (Construct tag terms) origin) <$> mapM valueTerm values
      PresenceValue wanted _ -> (\scalar -> Expr wanted (Constant scalar) origin) <$> toScalarValue value
    nearby wanted hint = case (wanted,expressionType hint) of
      (Constructor name [],Constructor actual []) | isInteger name && isInteger actual ->
        [integerCandidate wanted (adjust offset) | offset <- [0,1,-1]]
        where
          integer = scalarType "Integer"
          base = if expressionType hint == integer then hint else Expr integer (Convert CheckedArgument integer hint) origin
          adjust 0 = base
          adjust offset = Expr integer (Binary Add (Numeric integer) base
            (Expr integer (Constant (SInteger "Integer" offset)) origin)) origin
      _ -> [hint | expressionType hint == wanted]
    integerCandidate wanted value
      | wanted == scalarType "Integer" = value
      | otherwise = let
          name = case wanted of Constructor n [] -> n; _ -> "Integer"
          integer = scalarType "Integer"
          bound op n = Expr (scalarType "Bool") (Binary op (Numeric integer) value
            (Expr integer (Constant (SInteger "Integer" n)) origin)) origin
          conditions = case integerBounds bits name of
            Just (lo,hi) -> [bound GreaterEqual lo,bound LessEqual hi]
            Nothing | name == "BigUInt" -> [bound GreaterEqual 0]
            _ -> []
          valid = foldr (\a b -> Expr (scalarType "Bool") (ShortCircuit And a b) origin)
            (Expr (scalarType "Bool") (Constant (SBool True)) origin) conditions
          in Expr wanted (If valid (Expr wanted (Convert CheckedArgument wanted value) origin)
            (Expr wanted (Constant (SInteger name 0)) origin)) origin

-- | A complete cover may contain terms depending on earlier inputs. Evaluate
-- each in its actual prefix, then recheck every restriction before continuing.
-- The product bounds expansion before constructing tuples; nothing sampled is
-- admitted as a complete domain. Legacy domains retain their prior planning.
finiteUniversalInputs :: TypeRegistry -> Int -> Int -> (Id -> [Value] -> Either String Value)
  -> [Quantifier] -> Either String (Maybe [[Value]])
finiteUniversalInputs registry bits limit invoke qs = do
  domains <- mapM (finiteQuantifierCandidates bits limit (finiteValuesWithRegistry registry bits limit)) qs
  if Just [] `elem` domains then pure (Just []) else case sequence domains of
    Just covers | product (map (toInteger . length) covers) <= toInteger limit ->
      Just <$> walk [] (zip qs covers)
    _ -> pure Nothing
  where
    walk prefix [] = pure [map snd prefix]
    walk prefix ((q,terms):rest) = fmap concat $ mapM (\candidate -> do
      let optional = Constructor "Maybe" [TypeArgument (binderType (quantifiedBinder q))]
          origin = GeneratedFrom (binderId (quantifiedBinder q))
          absent = Expr optional (Construct (Id "Maybe::Absent") []) origin
          present value = Expr optional (Construct (Id "Maybe::Present") [value]) origin
      choice <- evaluateValue registry bits invoke prefix (applyCandidate candidate present absent)
      case choice of
        DataValue _ (Id "Maybe::Absent") [] -> pure []
        DataValue _ (Id "Maybe::Present") [value] -> do
          let bindings = prefix ++ [(binderId (quantifiedBinder q),value)]
          accepted <- allM (\predicate -> (== ScalarValue (SBool True)) <$>
            evaluateValue registry bits invoke bindings predicate) (quantifiedPredicates q)
          if accepted then walk bindings rest else pure []
        _ -> Left "invalid guarded finite candidate") terms
    allM _ [] = pure True
    allM f (x:xs) = do accepted <- f x; if accepted then allM f xs else pure False

-- | Refinements may mention earlier inputs, so a tuple is checked input by input
-- in order.
validTuple :: TypeRegistry -> Int -> [Quantifier] -> [Value] -> Either String Bool
validTuple registry bits qs values = do
  auditDomains registry bits
  validTupleWithDefinitions registry bits
    (\name _ -> Left ("unexpected definition call without a definition environment: " ++ idText name)) qs values

-- | The caller obtains this closed dispatcher from prepareDefinitions. It has no
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

-- | Registries carry typed predicates. Standalone domain APIs audit them before
-- executing candidates, including unused contracts and dependency cycles.
auditDomains :: TypeRegistry -> Int -> Either String ()
auditDomains registry bits = unsafePerformIO $ do
  -- Every law's plan audits the data types it reaches, often the same ones:
  -- the audits are kept, keyed by the declarations' identities in memory
  -- (a pure function, so this is only a cache).
  names <- mapM (\d -> evaluate d >>= makeStableName) declarations
  cached <- readIORef domainCache
  case lookup (bits, names) cached of
    Just result -> pure result
    Nothing -> do
      let result = () <$ either (Left . show) Right (constructorProofContracts bits declarations)
      writeIORef domainCache (take 256 (((bits, names), result) : cached))
      pure result
  where
    builtin = map dataId builtinDataDeclarations
    declarations = [declaration | declaration <- registryDeclarations registry, dataId declaration `notElem` builtin]
{-# NOINLINE auditDomains #-}

domainCache :: IORef [((Int, [StableName DataDeclaration]), Either String ())]
domainCache = unsafePerformIO (newIORef [])
{-# NOINLINE domainCache #-}

-- | Boundary candidates are kept only when they satisfy the type's refinements
-- and contracts, so no generated case lies outside the domain.
-- ref:DEC-shrink-within-domain
acceptsValue :: TypeRegistry -> Int -> Type -> Value -> Either String Bool
acceptsValue registry bits ty value = do
  result <- checkValueWith (evaluateValuePure registry bits) registry bits ty value
  pure (case result of ValueAccepted _ -> True; RefinementRejected _ -> False)

-- | Compatibility helpers for built-in types use the same registry-driven
-- planner as user-defined types. A sampling limit never defines a domain.
finiteValues :: Int -> Int -> Type -> Maybe [Value]
finiteValues bits limit ty = either (const Nothing) id $
  makeRegistry [] >>= \registry -> finiteValuesWithRegistry registry bits limit ty

-- | The edge values of a type, where portable semantics most often differs from
-- a language's own. ref:DEC-portable-exact-arithmetic
boundaries :: Int -> Type -> [Value]
boundaries bits ty = either (const []) id $
  makeRegistry [] >>= \registry -> boundariesWithRegistry registry bits ty

-- | Small primitive types are enumerated outright rather than sampled.
finiteScalars :: Int -> Int -> String -> Maybe [Value]
finiteScalars bits limit name
  | Just (lo,hi) <- integerBounds bits name, hi-lo+1 <= fromIntegral limit =
      Just [ScalarValue (SInteger name x) | x <- [lo..hi]]
  | name `elem` ["Bool", "Unit", "Null", "Undefined"],
      let values = map ScalarValue (scalarBoundaries bits name), length values <= limit = Just values
  | otherwise = Nothing

-- | Fixed cases for each primitive, chosen to be identical on every target.
scalarCases :: Int -> String -> [Value]
scalarCases bits "Text" = map (ScalarValue . textScalar)
  ["", " ", "Hello, World!", "λ日本語😀", "a\n\t\"\\$\0z", "e\x0301"] ++ map ScalarValue (scalarBoundaries bits "Text")
scalarCases bits name = map ScalarValue (scalarBoundaries bits name)

-- | Texts that match the regexes a text input's refinement requires, also
-- through the checked definitions it calls (validName t, whose body says
-- name matches regex ...): generation draws among them, so a refined text
-- is built rather than filtered. ref:DEC-shrink-within-domain
patternHints :: [Definition] -> Quantifier -> [Expr]
patternHints definitions q =
  [ Expr (scalarType "Text") (Constant (SSequence "Text" (map fromEnum sample))) (GeneratedFrom (binderId (quantifiedBinder q)))
  | sample <- concatMap (regexSamples 24) (refinedPatterns definitions q) ]

-- | A few of them, for the boundary cases.
patternValues :: [Definition] -> Quantifier -> [Value]
patternValues definitions q =
  [ScalarValue (SSequence "Text" (map fromEnum sample)) | regex <- refinedPatterns definitions q, sample <- regexSamples 4 regex]

-- | The regexes a text input must match.
refinedPatterns :: [Definition] -> Quantifier -> [Regex]
refinedPatterns definitions q =
  [ regex | binderType (quantifiedBinder q) == scalarType "Text"
  , pattern <- nub (concatMap (patterns (3 :: Int) (binderId (quantifiedBinder q))) (quantifiedPredicates q))
  , Right regex <- [parseRegex pattern] ]
  where
    patterns depth current e = case expressionNode e of
      ShortCircuit And a b -> patterns depth current a ++ patterns depth current b
      Let _ value body -> patterns depth current value ++ patterns depth current body
      Helper RegexMatches [Expr _ (Constant (SSequence _ pattern)) _, Expr _ (Local l) _] | l == current -> [map toEnum pattern]
      -- A call on the input: the callee's body, about its parameter.
      ExternalCall callee [Expr _ (Local l) _] | l == current, depth > 0
        , d : _ <- [d | d <- definitions, declarationId (definitionDeclaration d) == callee]
        , [parameter] <- definitionArguments d ->
          patterns (depth - 1) (binderId parameter) (definitionBody d)
      _ -> []

-- | Boundary values of a data input whose refinement matches one of its
-- fields against a regex (validPet p, whose body says p.name matches regex
-- ...): each boundary value with that field replaced by texts the regex
-- matches, so generation starts from values the refinement accepts rather
-- than filtering random ones. ref:DEC-shrink-within-domain
fieldPatternValues :: [Definition] -> Quantifier -> [Value] -> [Value]
fieldPatternValues definitions q values = nub
  [ DataValue ty tag (take index fields ++ [ScalarValue (SSequence "Text" (map fromEnum sample))] ++ drop (index + 1) fields)
  | (index, pattern) <- nub (concatMap (patterns (3 :: Int) (binderId (quantifiedBinder q))) (quantifiedPredicates q))
  , Right regex <- [parseRegex pattern], sample <- regexSamples 4 regex
  , DataValue ty tag fields <- values, index < length fields
  , ScalarValue (SSequence "Text" _) <- [fields !! index] ]
  where
    patterns depth current e = case expressionNode e of
      ShortCircuit And a b -> patterns depth current a ++ patterns depth current b
      Let _ value body -> patterns depth current value ++ patterns depth current body
      Helper RegexMatches [Expr _ (Constant (SSequence _ pattern)) _, subject]
        | Just index <- field (unconverted subject) -> [(index, map toEnum pattern)]
      -- A call on the input: the callee's body, about its parameter.
      ExternalCall callee [argument] | local argument == Just current, depth > 0
        , d : _ <- [d | d <- definitions, declarationId (definitionDeclaration d) == callee]
        , [parameter] <- definitionArguments d ->
          patterns (depth - 1) (binderId parameter) (definitionBody d)
      _ -> []
      where
        -- p.name, or the match a backend's plan lowers it to.
        field subject = case expressionNode subject of
          Project _ index inner | local inner == Just current -> Just index
          Match inner [MatchCase _ binders (Expr _ (Local chosen) _)] | local inner == Just current ->
            lookup chosen (zip (map binderId binders) [0 ..])
          _ -> Nothing
    local e = case expressionNode (unconverted e) of
      Local l -> Just l
      _ -> Nothing

-- | Texts a constructor's Text field draws besides its native ones: samples of
-- each regex its refinement matches the field against, directly or through a
-- definition the refinement inlines, so a narrow pattern is built rather than
-- filtered. ref:DEC-shrink-within-domain
fieldRegexSamples :: Binder -> [Expr] -> [String]
fieldRegexSamples binder predicates =
  [ sample | binderType binder == scalarType "Text"
  , pattern <- nub (concatMap (patterns [binderId binder]) predicates)
  , Right regex <- [parseRegex pattern], sample <- regexSamples 24 regex ]
  where
    patterns names e = case expressionNode e of
      ShortCircuit And a b -> patterns names a ++ patterns names b
      Let b value body | aliases names value -> patterns (binderId b : names) body
      Let _ value body -> patterns names value ++ patterns names body
      Helper RegexMatches [Expr _ (Constant (SSequence _ pattern)) _, subject] | aliases names subject -> [map toEnum pattern]
      _ -> []
    aliases names e = case expressionNode e of
      Local l -> l `elem` names
      Convert CheckedArgument _ inner -> aliases names inner
      _ -> False

-- | Safe comparison operands seed sparse domains without eagerly evaluating a
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


-- | Least fixed point of minimal sets of parameters needed for a finite value.
-- Symbolic requirements avoid enumerating every Boolean parameter assignment,
-- particularly for high-arity declarations with phantom parameters.
-- Function fields remain nongeneratable and are rejected before this analysis.
type Population = M.Map Id ([Id], [[Id]])

-- | Which data types can have values at all, found by a fixed point over their
-- constructors, so a law over an uninhabited type is refused instead of
-- passing with no cases. ref:DEC-never-pass-vacuously
population :: TypeRegistry -> Population
population registry = converge initial
  where
    declarations = registryDeclarations registry
    initial = M.fromList [(dataId d, (dataParameters d, [])) | d <- declarations]
    step table = M.fromList [(dataId d, (dataParameters d, minimal
      -- A field-only existential takes a witness type, always inhabited.
      (concat [map (filter (`notElem` freeExistentials d c)) (combine [needs table (binderType field) | field <- constructorFields c])
        | c <- dataConstructors d]))) | d <- declarations]
    converge current = let next = step current in if next == current then current else converge next

-- | Only the smallest sets of required type parameters matter for inhabitation.
minimal :: [[Id]] -> [[Id]]
minimal alternatives = [xs | xs <- candidates, not (any (\ys -> ys /= xs && all (`elem` xs) ys) candidates)]
  where candidates = sort (nub (map (sort . nub) alternatives))

-- | A constructor needs every field inhabited, so the requirements of its fields
-- multiply.
combine :: [[[Id]]] -> [[Id]]
combine = foldr (\choices rest -> minimal [xs ++ ys | xs <- choices, ys <- rest]) [[]]

-- | Optional and function types are always inhabited, by absence and by a
-- constant function, so they need nothing.
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

-- | A type is inhabited given which type parameters are.
potential :: Population -> M.Map Id Bool -> Type -> Bool
potential table env ty = any (all (\name -> M.findWithDefault False name env)) (needs table ty)

-- | A type with no values cannot be generated, so laws over it are refused.
-- ref:DEC-never-pass-vacuously
inhabited :: Population -> Type -> Bool
inhabited table = potential table M.empty

-- | Inhabitation is cached per type and per inhabited arguments.
populationKey :: Population -> Type -> (Id, [Bool])
populationKey table (Constructor name args) = (Id name, [inhabited table t | TypeArgument t <- args])
populationKey _ _ = (Id "<non-data>", [])

-- | Generators may only choose constructors that can be completed, or generation
-- would never terminate.
viableConstructors :: TypeRegistry -> Population -> Type -> Either String [(Id, [Type])]
viableConstructors registry table ty = case ty of
  Constructor _ _ -> do
    -- A GADT constructor that cannot build this type is not a candidate. A
    -- field-only existential takes each type of a small witness pool.
    compatible <- compatibleConstructors registry ty
    declaration <- case ty of
      Constructor name _ -> lookupData registry (Id name)
      _ -> Left "no declaration"
    fields <- fmap concat $ mapM (\c -> case freeExistentials declaration c of
      [] -> do
        parameters <- constructorFieldsFor registry ty (constructorId c)
        pure [(constructorId c, map binderType parameters)]
      free -> mapM (\witnesses -> do
        let pinned = M.fromList (zip free witnesses)
        parameters <- constructorFieldsFor registry ty (constructorId c)
        pure (constructorId c, map (substitute pinned . binderType) parameters))
        (sequence [witnessPool | _ <- free])) compatible
    pure [(tag,parameters) | (tag,parameters) <- fields, all (inhabited table) parameters]
  _ -> Left ("no constructors for " ++ show ty)

-- | A type the runtimes cannot generate is refused at planning, with its name,
-- rather than at test time on one target.
supportedWithRegistry :: TypeRegistry -> Type -> Either String ()
supportedWithRegistry registry ty = do
  required <- generationRequirements registry ty
  unless (null required) (Left ("unresolved generator parameters: " ++ show required))

-- | Data types with few values are enumerated too, so laws over them are checked
-- exhaustively. ref:DEC-evidence-statuses
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
          Constructor _ [TypeArgument element] | EqSet.isEqSetType t -> do
            members <- walk ((populationKey table t, typeSize t) : seen) element
            case members of
              Nothing -> pure Nothing
              Just values -> do
                sequences <- EqSet.finiteMemberSequences limit (equalValues bits) (nub values)
                pure (map (\items -> DataValue t EqSet.eqSetConstructorId [listValue element items]) <$> sequences)
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

-- | Intrinsic index guards need the same checked native generation as
-- constructor predicates, including guards carried by structural payloads.
hasConstructorContracts :: [DataDeclaration] -> Bool
hasConstructorContracts = any $ \declaration ->
  any (not . null . constructorPredicates) (dataConstructors declaration) ||
  maybe False (not . null . structuralIndexGuards) (dataStructural declaration) ||
  maybe False (any (not . null . constructorIndexGuards . snd) . familyIndexConstructors) (dataIndex declaration)

-- | Fixed-point reachability follows stored parameters rather than all type
-- arguments: Phantom Positive has no constrained values, while growing recursive
-- applications can eventually store a constrained argument. The finite lattice
-- contains only declaration parameters and a direct-contract bit.
hasValueContracts :: TypeRegistry -> Type -> Bool
hasValueContracts registry ty
  | not (any own declarations) = False
  | otherwise = fst (requirements (converge initial) ty)
  where
    declarations = registryDeclarations registry
    -- Index guards (balanced subtrees, non-negative subtraction) constrain
    -- values just like constructor predicates.
    own declaration = idText (dataId declaration) `elem` ["lawspec.collections::type::Set", "lawspec.collections::type::EqSet", "lawspec.collections::type::KeyVal"] ||
      any (not . null . constructorPredicates) (dataConstructors declaration) ||
      maybe False (not . null . structuralIndexGuards) (dataStructural declaration) ||
      maybe False (any (not . null . constructorIndexGuards . snd) . familyIndexConstructors) (dataIndex declaration)
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

-- | Boundaries sample each constructor and each field's deterministic extremes.
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


-- | A bounded witness search is deliberately separate from finite enumeration:
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
    -- A field a regex constrains takes texts the regex matches as seeds.
    patterns = nub [map toEnum points | d <- registryDeclarations registry, c <- dataConstructors d
                   , predicate <- constructorPredicates c, Helper RegexMatches [pattern, _] <- universeOf predicate
                   , Constant (SSequence "Text" points) <- [expressionNode pattern]]
    universeOf expression = expressionNode expression : concatMap universeOf (children expression)
    seeds name = nub (scalarCases bits name ++
      [ScalarValue value | literal <- constants,
        Right value <- [convertScalar bits name literal]] ++
      [ScalarValue (textScalar sample) | name == "Text", pattern <- patterns, Right regex <- [parseRegex pattern]
                                       , sample <- take 4 (regexSamples 4 regex)])
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
          -- Witnesses are rendered into every test that uses them: prefer
          -- small ones, as deep balanced trees double in size with each
          -- level, and use larger ones only when no small one is valid.
          let candidates = [DataValue ty tag payload | payload <- combinations domains]
              (small, large) = partition ((<= 32) . valueNodes) candidates
          preferred <- lift (acceptedPrefix 32 (acceptsValue registry bits ty) small)
          if null preferred then lift (acceptedPrefix 32 (acceptsValue registry bits ty) large)
            else pure preferred) constructors
      _ -> lift (Left ("no boundary witnesses for " ++ show ty))
    valueNodes value = case value of
      DataValue _ _ fields -> 1 + sum (map valueNodes fields)
      PresenceValue _ (Just inner) -> 1 + valueNodes inner
      _ -> 1 :: Int
    -- Validation can cost a walk of each candidate (index guards recompute
    -- indices), so stop once enough candidates are accepted.
    acceptedPrefix :: Int -> (Value -> Either String Bool) -> [Value] -> Either String [Value]
    acceptedPrefix 0 _ _ = pure []
    acceptedPrefix _ _ [] = pure []
    acceptedPrefix n accepts (candidate : rest) = do
      accepted <- accepts candidate
      if accepted then (candidate :) <$> acceptedPrefix (n - 1) accepts rest
        else acceptedPrefix n accepts rest
    -- Diagonals preserve coverage of each field's extrema; the bounded product
    -- adds unequal combinations needed by dependent fields such as y > x.
    combinations [] = [[]]
    combinations domains | any null domains = []
    combinations domains = nubOrd (diagonal ++ take 512 (sequence domains))
      where
        diagonal = [[values !! (index `mod` length values) | values <- domains]
          | index <- [0 .. maximum (map length domains) - 1]]


-- | A field supplied by a type parameter can itself be a smaller occurrence of
-- the same constructor (Box (Box Bool)). That is finite nesting, not a recursive
-- expansion. Non-decreasing repeated population profiles mark productive cycles.
typeSize :: Type -> Int
typeSize (Constructor _ args) = 1 + sum [typeSize t | TypeArgument t <- args]
typeSize (Arrow a b) = 1 + typeSize a + typeSize b
typeSize (TypeVariable _) = 1

-- | Indexed values are generated by solving the index backwards, so a predicate
-- on the index never rejects a sample. ref:DEC-indexed-families-as-evidence
indexedGeneration :: [DataDeclaration] -> [Definition] -> Quantifier -> Maybe IndexedGeneration
indexedGeneration declarations definitions q = case concatMap claim (concatMap conjuncts (quantifiedPredicates q)) of
  found:_ | declaredData (binderType (quantifiedBinder q)) -> Just found
  _ -> open
  where
    -- Without an index claim, a family whose values carry index guards (such
    -- as balanced subtrees) is still solved, from a few small indices; plain
    -- generation would almost never satisfy the guards.
    open = case binderType (quantifiedBinder q) of
      Constructor name _
        | Just root <- find ((== Id name) . dataId) declarations
        , Just equations <- familyEquations declarations root
        , any (any guard . snd) equations ->
            Just (IndexedGeneration (Expr (Constructor "BigInt" []) (Constant (SInteger "BigInt" (-1)))
              (GeneratedFrom (binderId (quantifiedBinder q)))) equations)
      _ -> Nothing
    guard text = take 3 text `elem` ["== ", ">= "]
    -- Runtime schemas describe declared data by constructor; built-in
    -- containers use native generators and are not index-directed.
    declaredData (Constructor name _) = name `notElem` ["List", "Maybe", "Either"]
    declaredData _ = False
    self = binderId (quantifiedBinder q)
    conjuncts e = case expressionNode e of
      ShortCircuit And a b -> conjuncts a ++ conjuncts b
      _ -> [e]
    claim e = case expressionNode e of
      Binary Equal _ a b -> [IndexedGeneration target equations
        | (measured, target) <- [(a, b), (b, a)]
        , ExternalCall measure [argument] <- [expressionNode (unconverted measured)]
        , expressionNode (unconverted argument) == Local self
        , self `notElem` freeBinders target
        , Just equations <- [indexEquations declarations definitions measure]]
      _ -> []

-- | A measure applied through a conversion is still recognised as a measure.
unconverted :: Expr -> Expr
unconverted e = case expressionNode e of
  Convert _ _ inner -> unconverted inner
  _ -> e

-- | A measure directs generation when it is the only index of a family whose
-- index fields reach only single-index families, each constructor naming at
-- most three index fields (runtimes enumerate their combinations).
indexEquations :: [DataDeclaration] -> [Definition] -> Id -> Maybe [(Id, [String])]
indexEquations declarations definitions measure = do
  definition <- lookup measure [(declarationId (definitionDeclaration d), d) | d <- definitions]
  let name = templateName (declarationName (definitionDeclaration definition))
  root <- case [d | d <- declarations, Just index <- [dataIndex d], [indexName] <- [familyIndexNames index]
                  , name `elem` measureNames d indexName] of
    d : _ -> Just d
    [] -> Nothing
  familyEquations declarations root
  where
    -- A family's measure is <index>Of<Family>; a unit that imports the
    -- family (as every unit imports the built-in collections' SizedStack)
    -- calls it by its imported name, lawspecCollectionsNOfSizedStack.
    measureNames d indexName =
      let base = indexName ++ "Of" ++ dataName d
          owner = ownerUnit (idText (dataId d))
      in base : [importedDefinitionName owner base | not (null owner)]
    ownerUnit text = case text of
      ':' : ':' : _ -> ""
      c : rest -> c : ownerUnit rest
      [] -> ""
    -- Specialized instances are named lawspec_<template>_<hash>.
    templateName n = case stripPrefix "lawspec_" n of
      Just rest | '_' `elem` rest -> reverse (drop 1 (dropWhile (/= '_') (reverse rest)))
      _ -> n

-- | The index equations runtimes solve backwards to generate indexed values.
-- ref:DEC-indexed-families-as-evidence
familyEquations :: [DataDeclaration] -> DataDeclaration -> Maybe [(Id, [String])]
familyEquations declarations root = reach [] [(dataId root, Nothing)]
  where
    byId = M.fromList [(dataId d, d) | d <- declarations]
    -- A structural product can carry the index of one of its projections.
    -- Give that product an equation in the generation plan only: the typed
    -- schema and its validation/guards keep their authoritative index paths.
    -- Different projections of the same product cannot share one equation.
    reach _ [] = Just []
    reach seen (request@(identity, projection) : rest)
      | Just prior <- lookup identity seen = do
          unless' (prior == projection)
          reach seen rest
      | otherwise = do
          d <- M.lookup identity byId
          constructors <- case projection of
            Nothing -> do
              index <- dataIndex d
              unless' (length (familyIndexNames index) == 1)
              mapM (\c -> do
                ConstructorIndex [term] guards <- lookup (idText (constructorId c)) (familyIndexConstructors index)
                pure (c, term, guards)) (dataConstructors d)
            Just path -> do
              -- Projection paths traverse closed structural products only.
              _ <- dataStructural d
              [c] <- pure (dataConstructors d)
              unless' (not (null path))
              pure [(c, IndexPath path 0, [])]
          lowered <- mapM lower constructors
          further <- reach (request : seen) (rest ++ concatMap snd lowered)
          pure (map fst lowered ++ further)
    lower (c, term, guards) = do
      let positions = nub (concatMap termFields (term : concat [[a, b] | IndexGuard _ a b <- guards]))
          roots = nub [head path | (path, _) <- positions, not (null path)]
      unless' (all (\(path, i) -> not (null path) && i == 0) positions && length roots <= 3)
      children <- mapM (\position -> do
        -- Two different nested indices in the same payload need a multi-index
        -- product planner; leave them to checked generation rather than
        -- conflating their independently constrained values.
        [path] <- pure (nub [tail path | (path, _) <- positions, head path == position])
        Constructor child _ : _ <- pure (map binderType (drop position (constructorFields c)))
        pure (Id child, if null path then Nothing else Just path)) roots
      let direct t = case t of
            IndexPath (position : _) i -> IndexField position i
            IndexApply op a b -> IndexApply op (direct a) (direct b)
            _ -> t
          directGuard (IndexGuard relation a b) = IndexGuard relation (direct a) (direct b)
      pure ((constructorId c, indexTermText (direct term) : map (indexGuardText . directGuard) guards), children)
    unless' condition = if condition then Just () else Nothing
