-- | Native generator composition from checked inputs and harness strategies.
-- Every choice and bind retains its framework's own shrink tree.
-- ref:DEC-typed-core-boundary ref:DEC-native-property-frameworks ref:REQ-harness-units
module LawSpec.BeamGenerators (inputs, inputsWithHelpers, inputsWithLiteralHelpers, directBounds, lengthBounds, nonEmptyBounds) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.BeamExpr as Expr
import qualified LawSpec.BeamNames as Names
import qualified LawSpec.BeamDefinitions as Definitions
import LawSpec.Core.Value (Value)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Scalar (Scalar(..))
import LawSpec.Testing
import qualified LawSpec.Testing.Draws as Draws
import Data.List (nub)

inputs :: String -> D.Doc -> D.Doc -> Plan -> (C.Id -> String) -> PlannedProperty -> Either String D.Doc
inputs framework schema symbols plan local planned = fst <$> buildInputs Nothing (Right . E.value symbols) framework schema symbols plan local planned

-- | Native modules retain helper functions beside the root generator call.
inputsWithHelpers :: String -> String -> D.Doc -> D.Doc -> Plan -> (C.Id -> String) -> PlannedProperty -> Either String (D.Doc, [D.Doc])
inputsWithHelpers prefix framework schema symbols = buildInputs (Just prefix) (Right . E.value symbols) framework schema symbols

-- | Generator witnesses use the same fresh structural factories as finite
-- cases, without retaining values or evaluating an unchosen branch.
inputsWithLiteralHelpers :: String -> (Value -> Either String D.Doc) -> String -> D.Doc -> D.Doc -> Plan -> (C.Id -> String) -> PlannedProperty -> Either String (D.Doc, [D.Doc])
inputsWithLiteralHelpers prefix = buildInputs (Just prefix)

buildInputs :: Maybe String -> (Value -> Either String D.Doc) -> String -> D.Doc -> D.Doc -> Plan -> (C.Id -> String) -> PlannedProperty -> Either String (D.Doc, [D.Doc])
buildInputs helperPrefix literal framework schema symbols plan local planned = walk [] (generatorRequirements planned)
  where
    units = map plannedUnit (plannedUnits plan)
    strategies = C.harnessDraws (C.propertyHarness (plannedProperty planned))
    render names = Expr.renderExpression (planMachineBits plan) schema symbols names (Definitions.external units symbols)
    native = E.remote framework
    bind generator name body = native "bind" [generator,E.lambda [D.text name] body]
    bindName binder name outer identity = if C.binderId binder == identity then name else outer identity
    conjunction [] = E.atom "true"
    conjunction ps = foldr1 (E.operator "andalso") ps
    walk previous [] = pure (native "exactly" [E.array previous], [])
    walk previous (requirement:rest) = do
      let binder = generatorBinder requirement
          name = local (C.binderId binder)
      (generator, helpers) <- case [(s,d) | (identity,s,d) <- strategies, identity == C.binderId binder] of
        [] -> (\generator -> (generator,[])) <$> regular local requirement
        (strategy,draw):_ -> do
          (generated, helpers) <- case helperPrefix of
            Nothing -> (\generator -> (generator,[])) <$> strategyDraw local requirement strategy (show (length previous)) draw
            Just prefix -> sharedDraw (prefix ++ "_" ++ show (length previous)) local requirement strategy draw
          let checkedName = name ++ "_Checked"
          predicates <- mapM (render (bindName binder checkedName local)) (generatorPredicates requirement)
          pure ((if null predicates then generated else native "map" [generated,E.lambda [D.text name]
            (E.remote "lawspec_beam_generators" "check_drawn" [E.binary strategy,E.binary (C.binderName binder),
              E.lambda [D.text checkedName] (conjunction predicates),
              D.text name])]), helpers)
      (remaining, laterHelpers) <- walk (previous ++ [D.text name]) rest
      pure (bind generator name remaining, helpers ++ laterHelpers)
    regular names requirement = do
      generator <- raw names requirement
      predicates <- mapM (render names) (generatorPredicates requirement)
      pure (if null predicates then generator else native "refine_input" [generator,
        E.lambda [D.text (names (C.binderId (generatorBinder requirement)))] (conjunction predicates)])
    raw names requirement = do
      ref <- E.typeReference (C.binderType (generatorBinder requirement))
      bounds <- mapM (\(op,expression) -> E.tuple . (E.binary (C.binaryName op) :) . pure <$> render names expression)
        (nub (generatorBounds requirement ++ directBounds requirement))
      lengths <- mapM (\(op,expression) -> do
        bound <- render names expression
        pure (E.tuple [E.atom "length",E.binary (C.binaryName op),bound])) (lengthBounds requirement)
      hints <- mapM (render names) [hint | hint <- generatorHints requirement,
        C.expressionType hint == C.binderType (generatorBinder requirement)]
      index <- case generatorIndex requirement of
        Nothing -> pure (E.atom "none")
        Just indexed -> do
          target <- render names (indexedTarget indexed)
          pure (E.tuple [target,E.record [(E.binary (C.idText tag),E.array (map E.binary terms))
            | (tag,terms) <- indexedEquations indexed]])
      witnesses <- mapM literal (generatorBoundaries requirement)
      pure (native "generator" [ref,schema,symbols,E.array (bounds ++ lengths),
        E.array (witnesses ++ hints),index])
    directed quantifier witnesses = GeneratorRequirement (C.quantifiedBinder quantifier)
      (C.quantifiedPredicates quantifier) witnesses (C.quantifiedBounds quantifier) (domainHints quantifier)
      (indexedGeneration (planDataDeclarations plan) (concatMap C.unitDefinitions units) quantifier)
    witnessesFor ty = makeRegistry (planDataDeclarations plan) >>= \registry ->
      boundariesWithRegistry registry (planMachineBits plan) ty
    strategyDraw names requirement strategy path draw = case draw of
      C.DrawAny ty (Just aim) -> do
        let name = "_" ++ Names.variableName (C.binderName (C.quantifiedBinder aim)) ++ path
            aliases = bindName (C.quantifiedBinder aim) name names
        witnesses <- if ty == C.binderType (generatorBinder requirement)
          then pure (generatorBoundaries requirement) else witnessesFor ty
        raw aliases (directed aim witnesses)
      C.DrawAny ty Nothing
        | ty == C.binderType (generatorBinder requirement) -> regular names requirement
        | otherwise -> do
            witnesses <- witnessesFor ty
            raw names (directed (C.Quantifier (C.Binder (C.Id ("draw::" ++ path)) "draw" ty) [] []) witnesses)
      C.DrawOneOf _ values -> do
        -- Only the selected expression is evaluated. Constructing all branch
        -- generators eagerly would execute unchosen partial expressions.
        branches <- mapM (fmap (native "exactly" . pure) . render names) values
        pure (choose strategy path (native "integer" [D.text "1",D.text (show (length values))]) branches)
      C.DrawFrequency alternatives -> do
        branches <- sequence [strategyDraw names requirement strategy (path ++ "_f" ++ show i) d
          | (i,(_,d)) <- zip [0::Int ..] alternatives]
        let selector = native "frequency" [E.array [E.tuple [D.text (show weight),native "exactly" [D.text (show i)]]
              | (i,(weight,_)) <- zip [1::Int ..] alternatives]]
        pure (choose strategy path selector branches)
      C.DrawSuchThat inner binder predicate limit -> do
        generator <- strategyDraw names requirement strategy (path ++ "_s") inner
        let name = "_" ++ Names.variableName (C.binderName binder) ++ path
        condition <- render (bindName binder name names) predicate
        pure (native "such_that" [generator,E.lambda [D.text name] condition,D.text (show limit),E.binary strategy])
      C.DrawBind binder from rest -> do
        generator <- strategyDraw names requirement strategy (path ++ "_from") from
        let name = "_" ++ Names.variableName (C.binderName binder) ++ path
        remaining <- strategyDraw (bindName binder name names) requirement strategy (path ++ "_rest") rest
        pure (bind generator name remaining)
    sharedDraw prefix outer requirement strategy draw = do
      let visible = map generatorBinder (takeWhile
            ((/= C.binderId (generatorBinder requirement)) . C.binderId . generatorBinder) (generatorRequirements planned)) ++
            map C.resourceBinder (C.propertyResources (plannedProperty planned))
      graph <- Draws.planDraw requirement visible draw
      let helperName number = prefix ++ "_draw_" ++ show number
          invoke names call = E.call (helperName (Draws.drawCallee call))
            (schema : symbols : map (D.text . names) (Draws.drawArguments call))
          nodeDoc node = do
            let captures = Draws.drawCaptures node
                captureNames = Names.variables Names.generatedVariables (map C.binderName captures)
                names identity = maybe (error ("unbound shared BEAM strategy capture: " ++ C.idText identity)) id
                  (lookup identity (zip (map C.binderId captures) captureNames))
                bound binder = case Names.variables (Names.generatedVariables ++ captureNames) [C.binderName binder] of
                  name : _ -> name
                  [] -> "Drawn"
                path = show (Draws.drawNumber node)
            body <- case Draws.drawStep node of
              Draws.AnyDraw ty aim -> strategyDraw
                (bindName (generatorBinder requirement) (bound (generatorBinder requirement)) names)
                requirement strategy path (C.DrawAny ty aim)
              Draws.OneOfDraw ty values -> strategyDraw names requirement strategy path (C.DrawOneOf ty values)
              Draws.FrequencyDraw alternatives -> do
                let selector = native "frequency" [E.array [E.tuple [D.text (show weight),native "exactly" [D.text (show i)]]
                      | (i,(weight,_)) <- zip [1::Int ..] alternatives]]
                pure (choose strategy path selector [invoke names call | (_,call) <- alternatives])
              Draws.FilterDraw child binder predicate limit -> do
                let name = bound binder
                condition <- render (bindName binder name names) predicate
                pure (native "such_that" [invoke names child,E.lambda [D.text name] condition,D.text (show limit),E.binary strategy])
              Draws.BindDraw binder from rest -> do
                let name = bound binder
                pure (bind (invoke names from) name (invoke (bindName binder name names) rest))
            pure (E.function (helperName (Draws.drawNumber node))
              (E.variable "Schema" body : E.variable "Symbols" body : [E.variable name body | name <- captureNames]) [body])
      helpers <- mapM nodeDoc (Draws.drawNodes graph)
      pure (invoke outer (Draws.drawRoot graph), helpers)
    choose strategy path selector branches =
      let name = "_" ++ Names.variableName strategy ++ "Choice" ++ path
      in bind selector name (E.apply (E.remote "lists" "nth"
        [D.text name,E.array (map (E.lambda []) branches)]) [])

-- | Only safe comparison operands narrow integer generation. Guarded partial
-- expressions remain inside the predicate. Earlier inputs stay in scope.
-- ref:DEC-shrink-within-domain
directBounds :: GeneratorRequirement -> [(C.BinaryOp,C.Expr)]
directBounds = comparisonBounds id

-- | A minimum length must be reachable even at native framework size zero.
-- Only required conjuncts constrain generation; disjunctions keep their domain.
-- ref:DEC-shrink-within-domain
lengthBounds :: GeneratorRequirement -> [(C.BinaryOp,C.Expr)]
lengthBounds = comparisonBounds (\local term -> case C.expressionNode term of
  C.Helper C.Length [inner] -> local inner
  _ -> False)

-- | A required `x != ""` or `x != []` asks for a non-empty sequence, so it is
-- drawn as a minimum length of one rather than filtered from short draws.
-- ref:DEC-shrink-within-domain
nonEmptyBounds :: GeneratorRequirement -> [(C.BinaryOp,C.Expr)]
nonEmptyBounds requirement = nub (concatMap walk (generatorPredicates requirement))
  where
    current = C.binderId (generatorBinder requirement)
    walk term = case C.expressionNode term of
      C.ShortCircuit C.And a b -> walk a ++ walk b
      C.Binary C.NotEqual _ a b
        | local a && empty b || local b && empty a -> [(C.Greater, zero term)]
      _ -> []
    local term = case C.expressionNode term of
      C.Local identity -> identity == current
      C.Convert C.CheckedArgument _ inner -> local inner
      _ -> False
    empty term = case C.expressionNode term of
      C.Constant (SSequence _ []) -> True
      C.Construct (C.Id "List::Nil") [] -> True
      _ -> False
    zero term = C.Expr (C.scalarType "Integer") (C.Constant (SInteger "Integer" 0)) (C.expressionOrigin term)

comparisonBounds :: ((C.Expr -> Bool) -> C.Expr -> Bool) -> GeneratorRequirement -> [(C.BinaryOp,C.Expr)]
comparisonBounds select requirement = concatMap walk (generatorPredicates requirement)
  where
    current = C.binderId (generatorBinder requirement)
    walk term = case C.expressionNode term of
      C.ShortCircuit C.And a b -> walk a ++ walk b
      C.Binary op _ a b | op `elem` [C.Equal,C.Less,C.LessEqual,C.Greater,C.GreaterEqual] ->
        [(direction,rhs) | (lhs,rhs,direction) <- [(a,b,op),(b,a,flipped op)], select local lhs,
          current `notElem` C.freeBinders rhs, safe rhs]
      _ -> []
    local term = case C.expressionNode term of
      C.Local identity -> identity == current
      C.Convert C.CheckedArgument _ inner -> local inner
      _ -> False
    safe term = case C.expressionNode term of
      C.Constant _ -> True
      C.Local _ -> True
      C.Unary C.Negate inner -> safe inner
      C.Binary op _ a b | op `elem` [C.Add,C.Subtract,C.Multiply] -> safe a && safe b
      C.Helper C.Length [inner] -> safe inner
      _ -> False
    flipped op = case op of
      C.Less -> C.Greater
      C.LessEqual -> C.GreaterEqual
      C.Greater -> C.Less
      C.GreaterEqual -> C.LessEqual
      other -> other
