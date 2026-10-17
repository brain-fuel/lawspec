-- | The independent re-check of a whole Core program before any emitter runs:
-- the boundary that lets eight backends trust their input.
-- ref:DEC-typed-core-boundary
module LawSpec.Core.Validate (validateProgram, validateProgramWithScopes, module LawSpec.Core.Expression) where

import LawSpec.Core
import LawSpec.Core.Eval (evaluateValuePure)
import LawSpec.Core.Expression
import LawSpec.Core.Total (validateDefinitionContractsWithScopes)
import LawSpec.Core.CapabilityScope (Capabilities(..),noCapabilities,CapabilityScopes,scopedRegistry)
import LawSpec.Core.DefinitionContracts (definitionContracts)
import qualified LawSpec.Core.Types as Types
import LawSpec.Common
import LawSpec.Scalar
import Control.Monad (unless, foldM)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import Data.List (nub)

-- | Validation failures are compiler bugs, not user errors, so they are reported
-- under the core diagnostic code. ref:DEC-typed-core-boundary
validateProgram :: Program -> Either [Diagnostic] ()
validateProgram = validateProgramWithScopes M.empty

-- A symbolic program is checked under its lexical schemes, with exactly the
-- same typing, totality and contract checks. No execution path supplies these
-- assumptions implicitly, and no wire request can provide a scheme context.
validateProgramWithScopes :: CapabilityScopes -> Program -> Either [Diagnostic] ()
validateProgramWithScopes scopes program = do
  let checked = either (Left . pure . (\m -> Diagnostic "core" m Nothing)) Right
  registry <- checked (Types.makeRegistry (programDataDeclarations program))
  let owners=Set.fromList ([declarationId declaration | unit<-programUnits program,declaration<-unitDeclarations unit]++
        [propertyId property | unit<-programUnits program,property<-unitProperties unit])
  checked (unless (M.keysSet scopes `Set.isSubsetOf` owners) (Left "capability scope names an unknown Core owner"))
  checked (validateProgramWith scopes registry program)
  -- A caller must also supply the capabilities required by a known generic
  -- callee, even if its own body never compares a value directly. The normal
  -- type checker has already checked exact argument/result types here.
  let calls owner expression = do
        case expressionNode expression of
          ExternalCall callee _ -> do
            let Capabilities equality keyed=M.findWithDefault noCapabilities callee scopes
                current=scopedRegistry scopes owner registry
            mapM_ (\variable -> Types.equalityRequirements current (TypeVariable variable) >>= \needed ->
              unless (null needed) (Left "caller does not supply a callee's Eq capability")) (Set.toList equality)
            mapM_ (\variable -> Types.keyedRequirements current (TypeVariable variable) >>= \needed ->
              unless (null needed) (Left "caller does not supply a callee's Keyed capability")) (Set.toList keyed)
          _ -> pure ()
        mapM_ (calls owner) (children expression)
  unless (M.null scopes) $ checked $ mapM_ (uncurry calls)
    ([(declarationId (definitionDeclaration definition),definitionBody definition) |
        unit<-programUnits program,definition<-unitDefinitions unit]++
     [(contractDeclaration contract,expression) | unit<-programUnits program,contract<-unitContracts unit,
        expression<-contractExpressions contract++contractRuntimePostconditions contract]++
     [(propertyId property,expression) | unit<-programUnits program,property<-unitProperties unit,expression<-propertyExpressions property])
  validateDefinitionContractsWithScopes scopes (programMachineBits program) (programDataDeclarations program)
    (concatMap unitDefinitions (programUnits program))
    (definitionContracts (programUnits program))
  -- Evaluating fixtures may invoke constructor predicates. First audit all
  -- predicates, so an invalid cyclic contract cannot run during validation.
  let concrete term
        | isConcrete term = () <$ evaluateValuePure registry (programMachineBits program) [] term
        | otherwise = mapM_ concrete (children term)
  checked (mapM_ concrete [term | unit <- programUnits program,
    property <- unitProperties unit, term <- propertyExpressions property])

-- How a row violation reads: raise names the failure's type.
describe :: AbilityRef -> String -> String
describe ability through
  | isFail ability, through == "raise" = "it raises a failure of type " ++ concatMap show' (abilityRefArguments ability)
  | otherwise = "it uses " ++ abilityKey ability ++ " (through " ++ through ++ ")"
  where show' t = case t of
          Constructor n _ -> reverse (takeWhile (/= ':') (reverse n))
          _ -> show t

validateProgramWith :: CapabilityScopes -> Types.TypeRegistry -> Program -> Either String ()
validateProgramWith scopes registry Program{..} = do
  unless (programMachineBits `elem` [32,64]) (Left "machineBits must be 32 or 64")
  let unitIds = map unitId programUnits
      propertyIds = [propertyId p | u <- programUnits,p <- unitProperties u]
  unless (length unitIds == Set.size (Set.fromList unitIds) && length propertyIds == Set.size (Set.fromList propertyIds)) (Left "duplicate core unit/property identity")
  let declarations = concatMap unitDeclarations programUnits
      ids = map declarationId declarations
      scope = M.fromList [(declarationId d,declarationType d) | d <- declarations]
  unless (length ids == Set.size (Set.fromList ids)) (Left "duplicate core declaration identity")
  mapM_ (Types.checkType registry . declarationType) declarations
  mapM_ (validateUnit scope) programUnits
  where
    definitions = Set.fromList [declarationId (definitionDeclaration d)
      | u <- programUnits, d <- unitDefinitions u]
    definitionTable = M.fromList [(declarationId (definitionDeclaration d),d)
      | u <- programUnits, d <- unitDefinitions u]
    closedWitness seen e = case expressionNode e of
      ExternalCall name arguments -> all (closedWitness seen) arguments && case M.lookup name definitionTable of
        Just definition -> not (definitionOrchestrates definition) &&
          null (declarationUses (definitionDeclaration definition)) &&
          (name `Set.member` seen || closedWitness (Set.insert name seen) (definitionBody definition))
        Nothing -> False
      Perform _ _ -> False
      Handle _ _ -> False
      Calls _ _ -> False
      Helper operation _ | operation `elem` [Recorded,AcquireResource,ReleaseResource,FreePort] -> False
      _ -> all (closedWitness seen) (children e)
    closedPredicate e = case expressionNode e of
      ExternalCall name arguments -> Set.member name definitions && all closedPredicate arguments
      Perform _ _ -> False
      Calls _ _ -> False
      _ -> all closedPredicate (children e)
    expression current = validateExpressionWithRegistry current programMachineBits
    extend scope b = do
      Types.checkType registry (binderType b)
      unless (M.notMember (binderId b) scope) (Left "duplicate core binder identity")
      pure (M.insert (binderId b) (binderType b) scope)
    predicate current ds scope p = do
      expression current ds scope p
      unless (closedPredicate p) (Left "adapter calls are forbidden in refinement predicates")
      unless (expressionType p == scalarType "Bool") (Left "proposition guard must be Bool")
    proposition current ds scope p = case p of
      Equation ev a b -> do
        expression current ds scope a; expression current ds scope b
        expected <- operationEvidenceWithRegistry current Equal (expressionType a) (expressionType b)
        unless (ev == expected) (Left "invalid proposition equality evidence")
      Implication g body -> do
        expression current ds scope g
        unless (expressionType g == scalarType "Bool") (Left "proposition guard must be Bool")
        proposition current ds scope body
      Conjunction ps -> mapM_ (proposition current ds scope) ps
      Negation body -> proposition current ds scope body
      Quantified _ q body -> do
        scope' <- quantify current ds scope q
        proposition current ds scope' body
    quantify current ds scope q = do
      next <- extend scope (quantifiedBinder q)
      mapM_ (predicate current ds next) (quantifiedPredicates q)
      mapM_ (\(op,e) -> do
        expression current ds scope e
        unless (op `elem` [Equal,Less,LessEqual,Greater,GreaterEqual]) (Left "invalid generator bound operator")
        unless (integerType (binderType (quantifiedBinder q)) && exactType (expressionType e))
          (Left "generator bounds require an integer domain and exact value")
        unless (isPure e && totalBound e) (Left "generator bounds must be total pure expressions")) (quantifiedBounds q)
      pure next
    validateUnit ds u = do
      let own = unitDeclarations u
      mapM_ (\definition -> unless (definitionDeclaration definition `elem` own)
        (Left "total definition must have a matching declaration in its owning unit")) (unitDefinitions u)
      -- A definition's row covers every operation it performs and every row
      -- of what it calls.
      let rows = M.fromList [(declarationId d, declarationUses d) | d <- declarations]
          declarations = concatMap unitDeclarations programUnits
          handlers = M.fromList [(handlerId h, h) | v <- programUnits, h <- unitHandlers v]
      mapM_ (\definition -> do
        let declaration = definitionDeclaration definition
            row = declarationUses declaration
            needs e = case expressionNode e of
              Perform op args -> (operationAbility op, operationName op) : concatMap needs args
              ExternalCall callee args -> [(a, idText callee) | a <- M.findWithDefault [] callee rows] ++ concatMap needs args
              -- handle e with h end answers h's ability inside e, and needs
              -- what h's clauses use.
              Handle (WithHandler ability handler) body -> filter ((/= ability) . fst) (needs body) ++
                [(a, idText clause) | Just h <- [M.lookup (specHandlerId handler) handlers], (_, clause) <- handlerClauses h,
                  a <- M.findWithDefault [] clause rows]
              Handle (CatchFailure ability) body -> filter ((/= ability) . fst) (needs body)
              _ -> concatMap needs (children e)
            specHandlerId handler = case handler of
              SpecHandler i -> i
              RecordingHandler inner -> specHandlerId inner
              ProductionHandler -> Id ""
        mapM_ (\(ability, through) -> unless (ability `elem` row)
          (Left (declarationName declaration ++ ": " ++ describe ability through ++ ", but its row is " ++
            (if null row then "empty" else unwords (map abilityKey row))))) (needs (definitionBody definition))) (unitDefinitions u)
      mapM_ (\property -> validateProperty (scopedRegistry scopes (propertyId property) registry) ds property) (unitProperties u)
      mapM_ (\contract -> validateContract (scopedRegistry scopes (contractDeclaration contract) registry) ds contract) (unitContracts u)
    validateProperty current ds p = do
      parameters <- foldM (quantify current ds) M.empty (propertyParameters p)
      scope <- foldM (quantify current ds) parameters (propertyInputs p)
      -- A law's resources are in scope in its body and examples; each one's
      -- acquire sees none of them, and its release sees it.
      resourceScope <- foldM (\s r -> do
        expression current ds M.empty (resourceAcquire r)
        unless (expressionType (resourceAcquire r) == binderType (resourceBinder r)) (Left "a resource's acquire must give its type")
        own <- extend M.empty (resourceBinder r)
        expression current ds own (resourceRelease r)
        mapM_ (expression current ds own) (resourceReset r)
        extend s (resourceBinder r)) scope (propertyResources p)
      proposition current ds resourceScope (propertyBody p)
      let choices = harnessWitnesses (propertyHarness p)
          targets = [witnessTarget w | w <- choices]
          available = existentialTargets (propertyBody p)
      unless (length targets == length (nub targets) && all (`elem` available) targets)
        (Left "witness choices must select distinct existential binders of their law")
      witnesses current ds scope choices (propertyBody p)
      let searches = harnessSearches (propertyHarness p)
          searchIds = [identity | (identity,_,_,_) <- searches]
          binders = scopedBinders (propertyBody p)
      unless (length searchIds == length (nub searchIds) && all (`elem` map binderId binders) searchIds)
        (Left "search strategies must select distinct scoped binders of their law")
      mapM_ (\(identity,_,_,strategy) -> case [binderType b | b <- binders,binderId b == identity] of
        [ty] -> validateDraw current ds M.empty ty strategy
        _ -> Left "search strategy selects an unknown scoped binder") searches
      let inputScope=M.fromList [(binderId binder,binderType binder) |
            q<-propertyInputs p,let binder=quantifiedBinder q]
      mapM_ (validateExample current ds inputScope resourceScope) (propertyExamples p)
    scopedBinders claim = case claim of
      Quantified _ q body -> quantifiedBinder q : scopedBinders body
      Conjunction bodies -> concatMap scopedBinders bodies
      Implication _ body -> scopedBinders body
      Negation body -> scopedBinders body
      _ -> []
    validateDraw current ds scope expected draw = case draw of
      DrawAny ty aim -> do
        unless (ty == expected) (Left "search generator type does not match its binder")
        mapM_ (\q -> do
          unless (binderType (quantifiedBinder q) == ty) (Left "search generator refinement type mismatch")
          _ <- quantify current ds scope q
          mapM_ pureDraw (quantifiedPredicates q)
          pure ()) aim
      DrawOneOf ty values -> do
        unless (ty == expected && not (null values)) (Left "search choices must have the binder's type and at least one value")
        mapM_ (\value -> do
          expression current ds scope value
          unless (expressionType value == ty) (Left "search candidate type mismatch")
          pureDraw value) values
      DrawFrequency alternatives -> do
        unless (not (null alternatives) && all ((>0) . fst) alternatives) (Left "search weights must be positive")
        mapM_ (validateDraw current ds scope expected . snd) alternatives
      DrawSuchThat inner binder predicate limit -> do
        unless (binderType binder == expected && limit >= 0) (Left "invalid search filter binder or discard limit")
        validateDraw current ds scope expected inner
        own <- extend scope binder
        expression current ds own predicate
        unless (expressionType predicate == scalarType "Bool") (Left "search filters must be Boolean")
        pureDraw predicate
      DrawBind binder from body -> do
        validateDraw current ds scope (binderType binder) from
        own <- extend scope binder
        validateDraw current ds own expected body
    pureDraw value = unless (closedWitness Set.empty value)
      (Left "search strategies may call only pure checked definitions")
    existentialTargets claim = case claim of
      Quantified kind q body -> [binderId (quantifiedBinder q) | kind == ForSome] ++ existentialTargets body
      Conjunction bodies -> concatMap existentialTargets bodies
      Implication _ body -> existentialTargets body
      Negation body -> existentialTargets body
      _ -> []
    witnesses current ds scope choices claim = case claim of
      Quantified _ q body -> do
        let binder = quantifiedBinder q
        mapM_ (\w -> do
          expression current ds scope (witnessValue w)
          unless (expressionType (witnessValue w) == binderType binder)
            (Left "witness expression type does not match its existential binder")
          unless (closedWitness Set.empty (witnessValue w)) (Left "witness expressions may call only pure checked definitions"))
          [w | w <- choices, witnessTarget w == binderId binder]
        scope' <- quantify current ds scope q
        witnesses current ds scope' choices body
      Conjunction bodies -> mapM_ (witnesses current ds scope choices) bodies
      Implication _ body -> witnesses current ds scope choices body
      Negation body -> witnesses current ds scope choices body
      _ -> pure ()
    validateExample current ds scope resourceScope e = do
      unless (M.keys (M.fromList (exampleBindings e)) == M.keys scope && length (exampleBindings e) == M.size scope) (Left "example must bind every input exactly once")
      mapM_ (\(i,v) -> do
        expression current ds M.empty v
        unless (isConcrete v) (Left "example bindings must be concrete constants")
        unless (Just (expressionType v) == M.lookup i scope) (Left "example binding type mismatch")) (exampleBindings e)
      mapM_ (proposition current ds resourceScope) (exampleExpectations e)
    validateContract current ds c = do
      declared <- maybe (Left "unknown contract declaration") Right (M.lookup (contractDeclaration c) ds)
      let (args,result) = functionType declared
      unless (args == map binderType (contractArguments c) && result == binderType (contractResult c)) (Left "contract signature mismatch")
      scope <- foldM extend M.empty (contractArguments c)
      mapM_ (predicate current ds scope) (contractPreconditions c)
      scope' <- extend scope (contractResult c)
      mapM_ (predicate current ds scope') (contractPostconditions c ++ contractRuntimePostconditions c)

-- | Bounds are evaluated before the full short-circuit predicate. Only total
-- exact arithmetic may move across that boundary; guards remain authoritative.
integerType, exactType :: Type -> Bool
integerType (Constructor n []) = isInteger n
integerType _ = False
exactType (Constructor n []) = isExact n
exactType _ = False
totalBound :: Expr -> Bool
totalBound e = case expressionNode e of
  Constant _ -> True
  Local _ -> True
  Unary Negate a -> exactType (expressionType a) && totalBound a
  Binary op _ a b | op `elem` [Add,Subtract,Multiply] -> all (\v -> exactType (expressionType v) && totalBound v) [a,b]
  Binary op _ a b | op `elem` [Divide,Quotient,Remainder], Constant v <- expressionNode b ->
    exactType (expressionType a) && totalBound a && either (const False) (/= 0) (exactValue v)
  Convert _ target a -> totalBound a && (target == expressionType a || integerType (expressionType a) && target `elem` map scalarType ["Integer","BigInt","Decimal","Rational"])
  _ -> False
