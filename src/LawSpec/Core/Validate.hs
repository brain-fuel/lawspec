module LawSpec.Core.Validate (validateProgram, module LawSpec.Core.Expression) where

import LawSpec.Core
import LawSpec.Core.Eval (evaluateValuePure)
import LawSpec.Core.Expression
import LawSpec.Core.Total (validateDefinitionContracts)
import LawSpec.Core.DefinitionContracts (definitionContracts)
import qualified LawSpec.Core.Types as Types
import LawSpec.Common
import LawSpec.Scalar
import Control.Monad (unless, foldM)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import Data.List (nub)

validateProgram :: Program -> Either [Diagnostic] ()
validateProgram program = do
  let checked = either (Left . pure . (\m -> Diagnostic "core" m Nothing)) Right
  registry <- checked (Types.makeRegistry (programDataDeclarations program))
  checked (validateProgramWith registry program)
  validateDefinitionContracts (programMachineBits program) (programDataDeclarations program)
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

validateProgramWith :: Types.TypeRegistry -> Program -> Either String ()
validateProgramWith registry Program{..} = do
  unless (programMachineBits `elem` [32,64]) (Left "machineBits must be 32 or 64")
  let unitIds = map unitId programUnits
      propertyIds = [propertyId p | u <- programUnits,p <- unitProperties u]
  unless (length unitIds == length (nub unitIds) && length propertyIds == length (nub propertyIds)) (Left "duplicate core unit/property identity")
  let declarations = concatMap unitDeclarations programUnits
      ids = map declarationId declarations
      scope = M.fromList [(declarationId d,declarationType d) | d <- declarations]
  unless (length ids == length (nub ids)) (Left "duplicate core declaration identity")
  mapM_ (Types.checkType registry . declarationType) declarations
  mapM_ (validateUnit scope) programUnits
  where
    definitions = Set.fromList [declarationId (definitionDeclaration d)
      | u <- programUnits, d <- unitDefinitions u]
    closedPredicate e = case expressionNode e of
      ExternalCall name arguments -> Set.member name definitions && all closedPredicate arguments
      Perform _ _ -> False
      Calls _ _ -> False
      _ -> all closedPredicate (children e)
    expression = validateExpressionWithRegistry registry programMachineBits
    extend scope b = do
      Types.checkType registry (binderType b)
      unless (M.notMember (binderId b) scope) (Left "duplicate core binder identity")
      pure (M.insert (binderId b) (binderType b) scope)
    predicate ds scope p = do
      expression ds scope p
      unless (closedPredicate p) (Left "adapter calls are forbidden in refinement predicates")
      unless (expressionType p == scalarType "Bool") (Left "proposition guard must be Bool")
    proposition ds scope p = case p of
      Equation ev a b -> do
        expression ds scope a; expression ds scope b
        expected <- operationEvidenceWithRegistry registry Equal (expressionType a) (expressionType b)
        unless (ev == expected) (Left "invalid proposition equality evidence")
      Implication g body -> do
        expression ds scope g
        unless (expressionType g == scalarType "Bool") (Left "proposition guard must be Bool")
        proposition ds scope body
      Conjunction ps -> mapM_ (proposition ds scope) ps
    validateUnit ds u = do
      let own = unitDeclarations u
      mapM_ (\definition -> unless (definitionDeclaration definition `elem` own)
        (Left "total definition must have a matching declaration in its owning unit")) (unitDefinitions u)
      -- A definition's row covers every operation it performs and every row
      -- of what it calls.
      let rows = M.fromList [(declarationId d, declarationUses d) | d <- declarations]
          declarations = concatMap unitDeclarations programUnits
      mapM_ (\definition -> do
        let declaration = definitionDeclaration definition
            row = declarationUses declaration
            needs e = case expressionNode e of
              Perform op args -> (operationAbility op, operationName op) : concatMap needs args
              ExternalCall callee args -> [(a, idText callee) | a <- M.findWithDefault [] callee rows] ++ concatMap needs args
              _ -> concatMap needs (children e)
        mapM_ (\(ability, through) -> unless (ability `elem` row)
          (Left (declarationName declaration ++ ": " ++ describe ability through ++ ", but its row is " ++
            (if null row then "empty" else unwords (map abilityKey row))))) (needs (definitionBody definition))) (unitDefinitions u)
      mapM_ (validateProperty ds) (unitProperties u)
      mapM_ (validateContract ds) (unitContracts u)
    validateProperty ds p = do
      scope <- foldM (\s q -> do
        next <- extend s (quantifiedBinder q)
        mapM_ (predicate ds next) (quantifiedPredicates q)
        mapM_ (\(op,e) -> do
          expression ds s e
          unless (op `elem` [Equal,Less,LessEqual,Greater,GreaterEqual]) (Left "invalid generator bound operator")
          unless (integerType (binderType (quantifiedBinder q)) && exactType (expressionType e)) (Left "generator bounds require an integer domain and exact value")
          unless (isPure e && totalBound e) (Left "generator bounds must be total pure expressions")) (quantifiedBounds q)
        pure next) M.empty (propertyInputs p)
      proposition ds scope (propertyBody p)
      mapM_ (validateExample ds scope) (propertyExamples p)
    validateExample ds scope e = do
      unless (M.keys (M.fromList (exampleBindings e)) == M.keys scope && length (exampleBindings e) == M.size scope) (Left "example must bind every input exactly once")
      mapM_ (\(i,v) -> do
        expression ds M.empty v
        unless (isConcrete v) (Left "example bindings must be concrete constants")
        unless (Just (expressionType v) == M.lookup i scope) (Left "example binding type mismatch")) (exampleBindings e)
      mapM_ (proposition ds scope) (exampleExpectations e)
    validateContract ds c = do
      declared <- maybe (Left "unknown contract declaration") Right (M.lookup (contractDeclaration c) ds)
      let (args,result) = functionType declared
      unless (args == map binderType (contractArguments c) && result == binderType (contractResult c)) (Left "contract signature mismatch")
      scope <- foldM extend M.empty (contractArguments c)
      mapM_ (predicate ds scope) (contractPreconditions c)
      scope' <- extend scope (contractResult c)
      mapM_ (predicate ds scope') (contractPostconditions c ++ contractRuntimePostconditions c)

-- Bounds are evaluated before the full short-circuit predicate. Only total
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
