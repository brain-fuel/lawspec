-- | Native Erlang artifacts and PropEr tests from a fully elaborated plan.
-- The other BEAM languages share this runtime and the Core expression layer.
-- ref:DEC-typed-core-boundary ref:DEC-native-property-frameworks
module LawSpec.BeamEmit (emitBeam) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.BeamExpr as Expr
import qualified LawSpec.BeamData as Data
import qualified LawSpec.BeamDefinitions as Definitions
import qualified LawSpec.ElixirNative as Elixir
import qualified LawSpec.GleamNative as Gleam
import LawSpec.Common (Artifact(..), Diagnostic(..), Generation(..))
import LawSpec.Testing
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.Scaffold (gleamTestPackage)
import LawSpec.TestNames (unitTestNames)
import LawSpec.Backend (metadataDocument)
import Control.Monad (unless, forM)
import Data.List (nub, isPrefixOf)

emitBeam :: String -> Bool -> Plan -> Either [Diagnostic] [Artifact]
emitBeam target minify plan = either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right $ do
  validatePlan target plan
  names <- E.dataNames declarations
  schemaFile <- Data.emitData target layout bits declarations
  definitions <- Definitions.emitDefinitions target layout bits declarations units
  adapters <- mapM (adapter names) [u | u <- units, target == "erlang", not (null (adapterDeclarations u))]
  native <- case target of
    "elixir" -> Elixir.emitNative layout bits declarations units
    "gleam" -> Gleam.emitNative layout declarations units
    _ -> pure []
  tests <- concat <$> mapM unitTests [u | u <- plannedUnits plan, not (null (plannedProperties u))]
  let runtimes = [Artifact ("src/lawspec_beam_" ++ name ++ ".erl")
        (runtimeSource ("beam-" ++ name)) "generated" "source"
        | name <- ["scalar","schema","regex","runtime"] ++ ["gleam" | target == "gleam"]] ++
        [Artifact ("src/lawspec/" ++ name ++ ".gleam") (runtimeSource ("beam-gleam-" ++ name)) "generated" "source"
          | name <- ["types","scalar"], target == "gleam"]
      generators = if null tests then [] else
        [Artifact (testSupport ++ "lawspec_beam_" ++ name ++ ".erl") (runtimeSource ("beam-" ++ name)) "generated" "test"
          | name <- ["generators", "index"]] ++
        [Artifact "test/lawspec_beam_proper.erl" (runtimeSource "beam-proper") "generated" "test" | target == "erlang"] ++
        [Artifact "test/support/lawspec_beam_stream_data.ex" (runtimeSource "beam-stream-data") "generated" "test" | target == "elixir"] ++
        [Artifact "test-support/src/lawspec_beam_qcheck.erl" (runtimeSource "beam-qcheck") "generated" "test" | target == "gleam"] ++
        [Artifact "test-support/gleam.toml" gleamTestPackage "generated" "test" | target == "gleam"]
  pure (schemaFile : definitions ++ adapters ++ native ++ tests ++ runtimes ++ generators)
  where
    declarations = planDataDeclarations plan
    bits = planMachineBits plan
    units = map plannedUnit (plannedUnits plan)
    layout = D.selectLayout minify (D.Pretty 100)
    testSupport = case target of "elixir" -> "test/support/"; "gleam" -> "test-support/src/"; _ -> "test/"
    framework = case target of "erlang" -> "lawspec_beam_proper"; "gleam" -> "lawspec_beam_qcheck"; _ -> "Elixir.LawSpec.Beam.StreamData"
    schema = D.text "_LsSchema"
    symbols = D.text "_LsSymbols"
    context = [D.text "_LsSymbols = make_ref()",D.text "_LsSchema = " <> E.remote "lawspec_data" "schema" [symbols]]
    adapterDeclarations u = [d | d <- C.unitDeclarations u,
      C.declarationId d `notElem` map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions u)]
    adapter names unit = do
      functions <- fmap concat $ forM (adapterDeclarations unit) $ \d -> do
        signature <- Definitions.declarationSpec bits names d
        let args = [D.text ("_Argument" ++ show i) | (i,_) <- zip [0::Int ..] (fst (C.functionType (C.declarationType d)))]
        pure [signature,E.function (E.functionName d) args [E.remote "erlang" "error"
          [E.tuple [E.atom "not_implemented",E.binary (C.idText (C.declarationId d))]]]]
      let name = Definitions.adapterModule unit
          exports = [(E.functionName d,length (fst (C.functionType (C.declarationType d)))) | d <- adapterDeclarations unit]
          -- The adapter is editable; both layouts retain its readable baseline.
          body = E.userModuleDoc name exports functions
      pure (AdapterArtifact ("src/" ++ name ++ ".erl") (D.render layout body)
        "user" "source" (D.render (D.Pretty 100) body))
    unitTests planned = do
      let unit = plannedUnit planned
          properties = plannedProperties planned
          names = unitTestNames target (map (C.propertyName . plannedProperty) properties)
          name = Definitions.adapterModule unit ++ (if target == "erlang" then "_lawspec_tests" else "_lawspec_cases")
          counts = [(n, length (C.propertyExamples (plannedProperty p)) +
            length (maybe (boundaryCases p) id (finiteCases p)) + (if finiteCases p == Nothing then 1 else 0))
            | (n,p) <- zip names properties]
          gleamCases = [(n,i) | (n,count) <- counts, i <- [0..count-1], target == "gleam"]
          caseEntry n i = n ++ "_case_" ++ show i
          bridges = [E.function (caseEntry n i) [] [E.remote "lawspec_beam_gleam" "run_case"
            [E.call (n ++ "_test_") [],D.text (show i)]] | (n,i) <- gleamCases]
          exports = if target == "gleam" then [(caseEntry n i,0) | (n,i) <- gleamCases] else [(n ++ "_test_",0) | n <- names]
      bodies <- concat <$> sequence [lawTests n p | (n,p) <- zip names properties]
      pure (Artifact (testSupport ++ name ++ ".erl")
        (D.render layout (E.moduleDoc name exports (bodies ++ bridges))) "generated" "test" :
        [Elixir.unitTests layout unit names | target == "elixir"] ++
        [Gleam.unitTests layout unit counts | target == "gleam"])
    lawTests name planned = do
      let law = plannedProperty planned
          parameters = map (C.quantifiedBinder) (C.propertyInputs law)
          aliases = zip (map C.binderId parameters) ["_LsInput" ++ show i | i <- [0::Int ..]]
          local identity = maybe (error ("unbound BEAM law binder: " ++ C.idText identity)) id (lookup identity aliases)
          render = Expr.renderExpression bits schema symbols local (Definitions.external units schema symbols)
          label = C.idText (C.propertyId law)
          check result = E.remote "lawspec_beam_runtime" "require" [result,E.binary label]
          caseName = name ++ "_case"
          invoke values = E.call caseName [schema,symbols,values]
          test kind statements = E.tuple [E.string (label ++ " " ++ kind), E.lambda [] (E.sequenceDoc (context ++ statements))]
      body <- Expr.assertion label render (C.propertyBody law)
      examples <- forM (zip [0::Int ..] (C.propertyExamples law)) $ \(i,example) -> do
        arguments <- forM parameters $ \parameter -> case lookup (C.binderId parameter) (C.exampleBindings example) of
          Nothing -> Left "missing BEAM example input"
          Just expression -> render expression
        expectations <- mapM (Expr.assertion (label ++ " example " ++ C.exampleName example) render) (C.exampleExpectations example)
        let names = map (D.text . snd) aliases
            assertion = E.apply (E.lambda [E.array names] (E.sequenceDoc
              (map check (invoke (E.array names) : expectations)))) [E.array arguments]
        pure (test ("example " ++ show i ++ ": " ++ C.exampleName example) [assertion])
      let boundaryTests = [test ("boundary " ++ show i) [check (invoke (E.array (map (E.value symbols) values)))]
            | (i,values) <- zip [0::Int ..] (maybe (boundaryCases planned) id (finiteCases planned))]
      randomTests <- case finiteCases planned of
        Just _ -> pure []
        Nothing -> do
          generator <- draws render aliases [] (generatorRequirements planned)
          let settings = C.propertyGeneration law
              options = E.array [E.tuple [E.atom k,D.text (show v)] | (k,v) <-
                [("numtests",cases settings),("constraint_tries",maxAttempts settings),("max_shrinks",maxShrinks settings)]]
          pure [test "property" [E.remote framework "check" [E.binary label,
            E.remote framework "forall" [E.remote framework "complete" [generator],
              E.lambda [D.text "_LsValues"] (invoke (D.text "_LsValues"))],options]]]
      pure [metadataDocument 100 "%%" planned <>
        E.function caseName [schema,symbols,E.array (map (D.text . snd) aliases)] [body],
        E.function (name ++ "_test_") [] [E.array (examples ++ boundaryTests ++ randomTests)]]
    draws _ _ previous [] = pure (E.remote framework "exactly" [E.array previous])
    draws render aliases previous (requirement:rest) = do
      let binder = generatorBinder requirement
      name <- maybe (Left "missing BEAM generator binder") Right (lookup (C.binderId binder) aliases)
      ref <- E.typeReference (C.binderType binder)
      bounds <- mapM (\(op,expression) -> E.tuple . (E.binary (C.binaryName op) :) . pure <$> render expression)
        (nub (generatorBounds requirement ++ directBounds requirement))
      predicates <- mapM render (generatorPredicates requirement)
      index <- case generatorIndex requirement of
        Nothing -> pure (E.atom "none")
        Just directed -> do
          target <- render (indexedTarget directed)
          pure (E.tuple [target,E.record [(E.binary (C.idText tag),E.array (map E.binary terms))
            | (tag,terms) <- indexedEquations directed]])
      let raw = E.remote framework "generator" [ref,schema,symbols,E.array bounds,
            E.array (map (E.value symbols) (generatorBoundaries requirement)),index]
          predicate = foldr (\a b -> D.text "(" <> a <> D.text " andalso " <> b <> D.text ")") (E.atom "true") predicates
          constrained = if null predicates then raw else E.remote framework "refine_input" [raw,E.lambda [D.text name] predicate]
      remaining <- draws render aliases (previous ++ [D.text name]) rest
      pure (E.remote framework "bind" [constrained,E.lambda [D.text name] remaining])

-- | Conjunctive comparisons can narrow a native integer generator even when
-- their bounds depend on previous inputs. Only safe operands are evaluated
-- here: a guarded partial expression remains inside its predicate.
-- ref:DEC-shrink-within-domain
directBounds :: GeneratorRequirement -> [(C.BinaryOp,C.Expr)]
directBounds requirement = concatMap walk (generatorPredicates requirement)
  where
    current = C.binderId (generatorBinder requirement)
    walk term = case C.expressionNode term of
      C.ShortCircuit C.And a b -> walk a ++ walk b
      C.Binary op _ a b | op `elem` [C.Equal,C.Less,C.LessEqual,C.Greater,C.GreaterEqual] ->
        [(direction,rhs) | (lhs,rhs,direction) <- [(a,b,op),(b,a,flipped op)], local lhs,
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
      _ -> False
    flipped op = case op of
      C.Less -> C.Greater
      C.LessEqual -> C.GreaterEqual
      C.Greater -> C.Less
      C.GreaterEqual -> C.LessEqual
      other -> other

-- | Until each execution plane is connected, compilation diagnoses it. No
-- law, policy, recording or resource may silently disappear from a release.
-- ref:DEC-never-pass-vacuously
validatePlan :: String -> Plan -> Either String ()
validatePlan target plan = do
  let units = map plannedUnit (plannedUnits plan)
      declarations = concatMap C.unitDeclarations units
      laws = concatMap plannedProperties (plannedUnits plan)
      moduleNames = map (Definitions.adapterModule) units
      generated = ["lawspec_data","lawspec_definitions"] ++
        [Definitions.adapterModule u ++ suffix | u <- units, suffix <- ["_definitions","_lawspec_tests"]]
      collisions = [n | n <- moduleNames, n `elem` generated || "lawspec_beam_" `isPrefixOf` n]
      natives = map (E.nativeModule target) units
      nativeGenerated = [E.nativeModule target u ++ suffix | u <- units, suffix <- [".Definitions", ".LawSpecTest"]]
      functionClashes u = let names = map (E.nativeFunction target) (C.unitDeclarations u) in length names /= length (nub names)
  unless (length moduleNames == length (nub moduleNames) && null collisions && all (not . null) moduleNames)
    (Left "BEAM module names collide after snake_case conversion or with generated runtime modules")
  unless (length natives == length (nub natives) && (target /= "elixir" ||
    all (\n -> not ("Elixir.LawSpec." `isPrefixOf` n) && n `notElem` nativeGenerated) natives))
    (Left "Elixir module names collide after normalization or with the LawSpec namespace")
  unless (target /= "gleam" || all (\n -> not ("lawspec@" `isPrefixOf` n) &&
    n `notElem` [E.nativeModule target u ++ "@definitions" | u <- units]) natives)
    (Left "Gleam module names collide with generated modules or the lawspec namespace")
  unless (all ((<= 230) . length) (moduleNames ++ generated ++ natives) && all ((<= 253) . length . fst . C.functionType . C.declarationType) declarations)
    (Left "BEAM module name or function arity exceeds the Erlang limit")
  unless (all (\d -> let n = E.nativeFunction target d in not (null n) && length n <= 255) declarations)
    (Left "BEAM function name is empty or exceeds the Erlang atom limit")
  unless (not (any functionClashes units)) (Left "BEAM function names collide after snake_case conversion")
  unless (all (null . C.unitMachines) units && all (null . C.unitSessions) units &&
    all (null . C.unitSupervisors) units && all (null . C.unitMailboxes) units)
    (Left "BEAM models, sessions, actors and mailboxes are not implemented yet")
  unless (all (null . C.declarationUses) declarations && all (null . C.unitAbilities) units &&
    all (null . C.unitHandlers) units && all (null . C.propertyHandlers . plannedProperty) laws)
    (Left "BEAM ability handlers are not implemented yet")
  unless (all (not . C.declarationAsync) declarations && all ((== Nothing) . C.definitionPolicy) (concatMap C.unitDefinitions units))
    (Left "BEAM async adapters and workflow policies are not implemented yet")
  unless (all (null . C.propertyResources . plannedProperty) laws && all ((== Nothing) . C.unitHarnessSettings) units &&
    all ((== C.noHarness) . C.propertyHarness . plannedProperty) laws)
    (Left "BEAM resources and harness settings are not implemented yet")
