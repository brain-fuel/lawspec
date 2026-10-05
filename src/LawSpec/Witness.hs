-- Field-only existentials at the backend boundary. Core values and terms carry
-- only declared fields; runtimes carry each existential's type as a trailing
-- Text witness field. Before emission, every construction of such a
-- constructor gains its witnesses as constants, and every planned value gains
-- its witness fields.
module LawSpec.Witness (witnessPlan) where

import LawSpec.Core
import LawSpec.Core.Value (Value(..), witnessFields, witnessKeys)
import LawSpec.Scalar (textScalar)
import LawSpec.Testing

witnessPlan :: Plan -> Plan
witnessPlan plan@Plan{..}
  | not (any (not . null . constructorExistentials) (concatMap dataConstructors planDataDeclarations)) = plan
  | otherwise = plan { plannedUnits = map plannedUnit' plannedUnits }
  where
    declarations = planDataDeclarations
    plannedUnit' (PlannedUnit u properties) = PlannedUnit (unit u) (map planned properties)
    unit u = u
      { unitContracts = map contract (unitContracts u)
      , unitProperties = map property (unitProperties u)
      , unitDefinitions = [d { definitionBody = expr (definitionBody d) } | d <- unitDefinitions u] }
    contract c = c
      { contractPreconditions = map expr (contractPreconditions c)
      , contractPostconditions = map expr (contractPostconditions c)
      , contractRuntimePostconditions = map expr (contractRuntimePostconditions c) }
    property p = p
      { propertyInputs = map quantifier (propertyInputs p)
      , propertyBody = proposition (propertyBody p)
      , propertyExamples = [e { exampleBindings = [(n, expr x) | (n, x) <- exampleBindings e]
                              , exampleExpectations = map proposition (exampleExpectations e) }
                           | e <- propertyExamples p] }
    quantifier q = q
      { quantifiedPredicates = map expr (quantifiedPredicates q)
      , quantifiedBounds = [(op, expr x) | (op, x) <- quantifiedBounds q] }
    proposition prop = case prop of
      Equation evidence a b -> Equation evidence (expr a) (expr b)
      Implication guard body -> Implication (expr guard) (proposition body)
      Conjunction bodies -> Conjunction (map proposition bodies)
    planned p = p
      { plannedProperty = property (plannedProperty p)
      , finiteCases = map (map value) <$> finiteCases p
      , boundaryCases = map (map value) (boundaryCases p)
      , generatorRequirements = map requirement (generatorRequirements p) }
    requirement r = r
      { generatorPredicates = map expr (generatorPredicates r)
      , generatorBoundaries = map value (generatorBoundaries r)
      , generatorBounds = [(op, expr x) | (op, x) <- generatorBounds r]
      , generatorHints = map expr (generatorHints r) }
    -- Idempotent: a construction already carrying its witnesses is kept.
    declared ty tag = case ty of
      Constructor name _ -> case [c | d <- declarations, dataId d == Id name, c <- dataConstructors d, constructorId c == tag] of
        c : _ -> length (constructorFields c)
        [] -> -1
      _ -> -1
    value :: Value -> Value
    value v = case v of
      DataValue ty tag fields
        | length fields == declared ty tag -> DataValue ty tag (map value fields ++ witnessFields declarations ty tag fields)
        | otherwise -> DataValue ty tag (map value fields)
      PresenceValue ty payload -> PresenceValue ty (value <$> payload)
      _ -> v
    expr e = case expressionNode e of
      Construct tag args ->
        let args' = map expr args
            keys | length args == declared (expressionType e) tag = witnessKeys declarations (expressionType e) tag (map expressionType args)
                 | otherwise = []
            text key = Expr (Constructor "Text" []) (Constant (textScalar key)) (expressionOrigin e)
        in e { expressionNode = Construct tag (args' ++ map text keys) }
      Match scrutinee cases -> e { expressionNode = Match (expr scrutinee) [c { caseBody = expr (caseBody c) } | c <- cases] }
      AllElements xs binder predicate -> e { expressionNode = AllElements (expr xs) binder (expr predicate) }
      AllPayloads x predicates -> e { expressionNode = AllPayloads (expr x) [(b, expr p) | (b, p) <- predicates] }
      ExternalCall name args -> e { expressionNode = ExternalCall name (map expr args) }
      Binary op evidence a b -> e { expressionNode = Binary op evidence (expr a) (expr b) }
      Unary op a -> e { expressionNode = Unary op (expr a) }
      ShortCircuit op a b -> e { expressionNode = ShortCircuit op (expr a) (expr b) }
      If c a b -> e { expressionNode = If (expr c) (expr a) (expr b) }
      Convert conversion ty a -> e { expressionNode = Convert conversion ty (expr a) }
      _ -> mapChildren expr e
