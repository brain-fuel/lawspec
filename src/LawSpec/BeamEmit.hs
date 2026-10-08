-- | Native Erlang artifacts and PropEr tests from a fully elaborated plan.
-- The other BEAM languages share this runtime and the Core expression layer.
-- ref:DEC-typed-core-boundary ref:DEC-native-property-frameworks
module LawSpec.BeamEmit (emitBeam, emitBeamWithBindings) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.ElixirCode as X
import qualified LawSpec.GleamCode as G
import qualified LawSpec.BeamExpr as Expr
import qualified LawSpec.BeamData as Data
import qualified LawSpec.BeamDefinitions as Definitions
import qualified LawSpec.BeamEffects as Effects
import qualified LawSpec.BeamAbilities as Abilities
import qualified LawSpec.BeamNativeBinding as Native
import qualified LawSpec.ElixirNative as Elixir
import qualified LawSpec.GleamNative as Gleam
import LawSpec.Common (Artifact(..), Diagnostic(..), Generation(..))
import LawSpec.Testing
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.DefaultSources (defaultSource)
import LawSpec.Scaffold (gleamTestPackage)
import LawSpec.NativeRequest (BindingPlan, emptyBindingPlan, hasBindings)
import LawSpec.TestNames (unitTestNames)
import LawSpec.Backend (metadataDocument)
import Control.Monad (unless, forM)
import Data.List (nub, isPrefixOf)

emitBeam :: String -> Bool -> Plan -> Either [Diagnostic] [Artifact]
emitBeam target minify = emitBeamWithBindings target minify emptyBindingPlan

emitBeamWithBindings :: String -> Bool -> BindingPlan -> Plan -> Either [Diagnostic] [Artifact]
emitBeamWithBindings target minify bindings plan = do
  diagnose "target" (validatePlan target plan)
  bound <- diagnose "native-binding" $ if hasBindings bindings then Native.emitBindings target layout bindings plan else pure []
  ordinary <- diagnose "target" emit
  diagnose "native-binding" $ unless (length (map artifactPath (ordinary ++ bound)) == length (nub (map artifactPath (ordinary ++ bound))))
    (Left "BEAM native bindings produce conflicting artifact paths")
  pure (ordinary ++ bound)
  where
    diagnose code = either (Left . pure . (\message -> Diagnostic code message Nothing)) Right
    emit = do
      names <- E.dataNames declarations
      schemaFile <- Data.emitData target layout bits declarations
      definitions <- Definitions.emitDefinitions target layout bits declarations units (Native.boundEntries bindings)
      abilities <- if hasAbilities then Abilities.emit target layout bits declarations units (hasBindings bindings) else pure []
      adapters <- mapM (adapter names) [u | u <- units, target == "erlang", not (boundUnit u),
        not (null (adapterDeclarations u) && null (Abilities.productionAbilities u))]
      native <- case target of
        "elixir" -> Elixir.emitNative layout bits declarations units
        "gleam" -> Gleam.emitNative layout declarations units
        _ -> pure []
      tests <- concat <$> mapM unitTests [u | u <- plannedUnits plan, not (null (plannedProperties u))]
      pure (schemaFile : definitions ++ abilities ++ adapters ++ [a | a <- native, artifactPath a `notElem` boundPaths] ++ tests ++ runtimes ++ cryptoAssets ++ generators tests)
    runtimes = [Artifact ("src/lawspec_beam_" ++ name ++ ".erl")
        (runtimeSource ("beam-" ++ name)) "generated" "source"
        | name <- ["scalar","schema","regex","runtime"] ++
            (if usesEffects then ["effects","handler","waits"] else []) ++
            ["defaults" | hasPolicies || any Abilities.hasDefault (Effects.abilities units)] ++
            (if hasPolicies then ["random","policy","tasks","attempts","workflow_state","workflow"] else []) ++
            (if usesCrypto then ["crypto","crypto_native"] else []) ++
            ["gleam" | target == "gleam"]] ++
        [Artifact "lib/lawspec/workflow.ex" (runtimeSource "beam-elixir-workflow") "generated" "source"
          | target == "elixir", hasPolicies] ++
        [Artifact ("src/lawspec/" ++ name ++ ".gleam") (runtimeSource ("beam-gleam-" ++ name)) "generated" "source"
          | name <- ["types","scalar"] ++ ["failures" | usesEffects] ++ ["effects" | hasAbilities] ++
              ["workflow" | hasPolicies], target == "gleam"]
    usesCrypto = any ((== "lawspec.crypto") . C.idText . C.unitId) units
    cryptoAssets = if not usesCrypto then [] else
      [Artifact "priv/lawspec_crypto_native.c" (runtimeSource "beam-crypto-native-c") "generated" "source",
       Artifact "lawspec_crypto_build.escript" (runtimeSource "beam-crypto-build") "generated" "source",
       Artifact (testSupport ++ "lawspec_beam_crypto_vectors.erl") vectorSource "generated" "test",
       vectorTests]
    vectorSource = unlines [if line == "vector_text() -> @@VECTORS@@."
      then "vector_text() -> " ++ D.render layout (E.binary (defaultSource "vectors.txt")) ++ "." else line
      | line <- lines (defaultSource "beam/crypto_vectors.erl")]
    vectorKinds = ["sha3-256","shake256","aes-256-gcm","mlkem768-keygen","mlkem768-encaps",
      "mlkem768-decaps","mlkem768-decaps-seed","mldsa65-keygen","mldsa65-verify",
      "mldsa65-sign-seed","slhdsa128f-keygen","slhdsa128f-verify"]
    vectorTests = case target of
      "elixir" -> Artifact "test/lawspec_crypto_vectors_test.exs"
        (D.render layout (X.moduleDoc "LawSpec.CryptoVectorsTest" False (D.text "use ExUnit.Case" :
          [D.text "test " <> X.string kind <> D.text " do" <> D.nest 2 (D.hardline <>
            X.remote ":lawspec_beam_crypto_vectors" "check" [X.string kind]) <> D.hardline <> D.text "end" | kind <- vectorKinds]))) "generated" "test"
      "gleam" -> Artifact "test/lawspec_crypto_vectors_test.gleam"
        (D.render layout (G.fileDoc False (G.external "lawspec_beam_crypto_vectors" "check" "check" [D.text "kind: String"] (D.text "Nil") :
          [G.function (E.snake kind ++ "_test") [] (D.text "Nil") [G.call "check" [G.string kind]] | kind <- vectorKinds]))) "generated" "test"
      _ -> Artifact "test/lawspec_crypto_vectors_tests.erl"
        (D.render layout (E.moduleDoc "lawspec_crypto_vectors_tests" [("crypto_vectors_test_",0)]
          [E.function "crypto_vectors_test_" [] [E.array [E.tuple [D.text (show kind),
            E.lambda [] (E.remote "lawspec_beam_crypto_vectors" "check" [E.binary kind])] | kind <- vectorKinds]]])) "generated" "test"
    hasAbilities = not (null (Effects.abilities units) && null (Effects.handlers units))
    hasPolicies = any ((/= Nothing) . C.definitionPolicy) (concatMap C.unitDefinitions units)
    usesEffects = any (not . null . C.unitAbilities) units ||
      any (not . null . C.declarationUses) (concatMap C.unitDeclarations units)
    generators tests = if null tests then [] else
        [Artifact (testSupport ++ "lawspec_beam_" ++ name ++ ".erl") (runtimeSource ("beam-" ++ name)) "generated" "test"
          | name <- ["generators", "index"]] ++
        [Artifact "test/lawspec_beam_proper.erl" (runtimeSource "beam-proper") "generated" "test" | target == "erlang"] ++
        [Artifact "test/support/lawspec_beam_stream_data.ex" (runtimeSource "beam-stream-data") "generated" "test" | target == "elixir"] ++
        [Artifact "test-support/src/lawspec_beam_qcheck.erl" (runtimeSource "beam-qcheck") "generated" "test" | target == "gleam"] ++
        [Artifact "test-support/gleam.toml" gleamTestPackage "generated" "test" | target == "gleam"]
    declarations = planDataDeclarations plan
    bits = planMachineBits plan
    units = map plannedUnit (plannedUnits plan)
    boundUnit u = any ((`elem` map fst (Native.boundEntries bindings)) . C.declarationId) (C.unitDeclarations u)
    boundPaths = [case target of
      "elixir" -> "lib/" ++ E.moduleName (C.unitId u) ++ ".ex"
      "gleam" -> "src/" ++ E.gleamPath (C.unitId u) ++ ".gleam"
      _ -> "src/" ++ E.moduleName (C.unitId u) ++ ".erl" | u <- units, boundUnit u]
    layout = D.selectLayout minify (D.Pretty 100)
    testSupport = case target of "elixir" -> "test/support/"; "gleam" -> "test-support/src/"; _ -> "test/"
    framework = case target of "erlang" -> "lawspec_beam_proper"; "gleam" -> "lawspec_beam_qcheck"; _ -> "Elixir.LawSpec.Beam.StreamData"
    schema = D.text "_LsSchema"
    symbols = D.text "_LsSymbols"
    context = [D.text "_LsSymbols = make_ref()",D.text "_LsSchema = " <> wrap (E.remote "lawspec_data" "schema" [symbols])]
      where wrap doc = if Native.hasGenerators bindings then E.remote "lawspec_native_generators" "schema" [doc] else doc
    adapterDeclarations u = [d | d <- C.unitDeclarations u,
      C.declarationId d `notElem` map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions u)]
    adapter names unit = do
      functions <- fmap concat $ forM (adapterDeclarations unit) $ \d -> do
        signature <- Definitions.declarationSpec bits names units d
        let args = [D.text ("_Argument" ++ show i) | (i,_) <- zip [0::Int ..] (fst (C.functionType (C.declarationType d)))]
            handlers = [D.text ("_Handler" ++ show i) | (i,_) <- zip [0::Int ..] (Effects.uses d)]
        pure [signature,E.function (E.functionName d) (handlers ++ args) [E.remote "erlang" "error"
          [E.tuple [E.atom "not_implemented",E.binary (C.idText (C.declarationId d))]]]]
      production <- concat <$> mapM (Abilities.productionStub target bits names) (Abilities.productionAbilities unit)
      let name = Definitions.adapterModule unit
          exports = [(E.functionName d,length (Effects.uses d) + length (fst (C.functionType (C.declarationType d)))) | d <- adapterDeclarations unit] ++
            concatMap Abilities.productionExports (Abilities.productionAbilities unit)
          -- The adapter is editable; both layouts retain its readable baseline.
          body = (if Abilities.defaultUnit unit then E.moduleDoc else E.userModuleDoc) name exports (functions ++ production)
      pure (if Abilities.defaultUnit unit then Artifact ("src/" ++ name ++ ".erl") (D.render layout body) "generated" "source"
        else AdapterArtifact ("src/" ++ name ++ ".erl") (D.render layout body)
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
      bodies <- concat <$> sequence [lawTests unit n p | (n,p) <- zip names properties]
      pure (Artifact (testSupport ++ name ++ ".erl")
        (D.render layout (E.moduleDoc name exports (bodies ++ bridges))) "generated" "test" :
        [Elixir.unitTests layout unit names | target == "elixir"] ++
        [Gleam.unitTests layout unit counts | target == "gleam"])
    lawTests unit name planned = do
      let law = plannedProperty planned
          parameters = map (C.quantifiedBinder) (C.propertyInputs law)
          aliases = zip (map C.binderId parameters) ["_LsInput" ++ show i | i <- [0::Int ..]]
          local identity = maybe (error ("unbound BEAM law binder: " ++ C.idText identity)) id (lookup identity aliases)
          renderWith active = Expr.renderExpression bits active symbols local (Definitions.external units symbols)
          render = renderWith schema
          label = C.idText (C.unitId unit) ++ "::" ++ C.propertyName law
          check result = E.remote "lawspec_beam_runtime" "require" [result,E.binary label]
          caseName = name ++ "_case"
          rawName = name ++ "_body"
          invoke values = E.call caseName [schema,symbols,values]
          workflowScope body = if hasPolicies then E.remote "lawspec_beam_workflow" "with_test_runtime" [E.lambda [] body] else body
          test kind statements = E.tuple [E.string (label ++ " " ++ kind), E.lambda [] (E.sequenceDoc (context ++ statements))]
      body <- Expr.assertion label render (C.propertyBody law)
      choices <- Effects.factories units symbols (C.propertyHandlers law)
      let scoped outer active statements = if all (C.isFail . fst) (C.propertyHandlers law)
            then E.apply (E.lambda [active] statements) [outer]
            else E.remote "lawspec_beam_effects" "with_scope" [outer,choices,E.lambda [active] statements]
      examples <- forM (zip [0::Int ..] (C.propertyExamples law)) $ \(i,example) -> do
        let exampleSchema = D.text "_LsExampleSchema"
            exampleRender = renderWith exampleSchema
        arguments <- forM parameters $ \parameter -> case lookup (C.binderId parameter) (C.exampleBindings example) of
          Nothing -> Left "missing BEAM example input"
          Just expression -> exampleRender expression
        expectations <- mapM (Expr.assertion (label ++ " example " ++ C.exampleName example) exampleRender) (C.exampleExpectations example)
        let names = map (D.text . snd) aliases
            assertion = E.apply (E.lambda [E.array names] (E.sequenceDoc
              (map check (E.call rawName [exampleSchema,symbols,E.array names] : expectations)))) [E.array arguments]
        pure (test ("example " ++ show i ++ ": " ++ C.exampleName example) [workflowScope (scoped schema exampleSchema assertion)])
      let boundaryTests = [test ("boundary " ++ show i) [check (invoke (E.array (map (E.value symbols) values)))]
            | (i,values) <- zip [0::Int ..] (maybe (boundaryCases planned) id (finiteCases planned))]
      randomTests <- case finiteCases planned of
        Just _ -> pure []
        Nothing -> do
          generator <- draws render aliases [] (generatorRequirements planned)
          let settings = C.propertyGeneration law
              options = E.array [E.tuple [E.atom k,D.text (show v)] | (k,v) <-
                [("numtests",cases settings),("constraint_tries",maxAttempts settings),("max_shrinks",maxShrinks settings)]]
          let propertyTest = test "property" [E.remote framework "check" [E.binary label,
                E.remote framework "forall" [E.remote framework "complete" [generator],
                  E.lambda [D.text "_LsValues"] (invoke (D.text "_LsValues"))],options]]
          -- EUnit's five-second default covers a single test. A property runs
          -- every sample plus shrinks; match ExUnit's one-minute allowance.
          pure [if target == "erlang" then E.tuple [E.atom "timeout",D.text "60",propertyTest] else propertyTest]
      pure [metadataDocument 100 "%%" planned <>
        E.function rawName [schema,symbols,E.array (map (D.text . snd) aliases)] [body],
        E.function caseName [D.text "_LsBaseSchema",symbols,D.text "_LsValues"]
          [workflowScope (scoped (D.text "_LsBaseSchema") schema (E.call rawName [schema,symbols,D.text "_LsValues"]))],
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
          indexTarget <- render (indexedTarget directed)
          pure (E.tuple [indexTarget,E.record [(E.binary (C.idText tag),E.array (map E.binary terms))
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
      generated = ["lawspec_data","lawspec_definitions","lawspec_abilities","lawspec_native_bindings","lawspec_native_generators"] ++
        [Definitions.adapterModule u ++ suffix | u <- units, suffix <- ["_definitions","_definitions_ffi","_lawspec_tests","_lawspec_cases"]] ++
        ["lawspec_abilities_" ++ Definitions.adapterModule u | u <- units]
      collisions = [n | n <- moduleNames, n `elem` generated || "lawspec_beam_" `isPrefixOf` n]
      natives = [E.nativeModule target u | u <- units,
        not (null (C.unitDeclarations u) && null (Abilities.productionAbilities u))]
      nativeGenerated = [E.nativeModule target u ++ suffix | u <- units, suffix <- [".Definitions", ".LawSpecTest"]]
      functionClashes u = let names = map (E.nativeFunction target) (C.unitDeclarations u) ++
                               map Abilities.productionName (Abilities.productionAbilities u)
                         in length names /= length (nub names)
  unless (length moduleNames == length (nub moduleNames) && null collisions && all (not . null) moduleNames)
    (Left "BEAM module names collide after snake_case conversion or with generated runtime modules")
  unless (length natives == length (nub natives) && (target /= "elixir" ||
    all (\n -> not ("Elixir.LawSpec." `isPrefixOf` n) && n `notElem` nativeGenerated) natives))
    (Left "Elixir module names collide after normalization or with the LawSpec namespace")
  unless (target /= "gleam" || all (\n -> (not ("lawspec@" `isPrefixOf` n) ||
    n `elem` [E.nativeModule target u | u <- units,
      Abilities.defaultUnit u || C.idText (C.unitId u) == "lawspec.resilience"]) &&
    n `notElem` [E.nativeModule target u ++ "@definitions" | u <- units]) natives)
    (Left "Gleam module names collide with generated modules or the lawspec namespace")
  unless (all ((<= 230) . length) (moduleNames ++ generated ++ natives) &&
    all (\d -> length (Effects.uses d) + length (fst (C.functionType (C.declarationType d))) <= 253) declarations)
    (Left "BEAM module name or function arity exceeds the Erlang limit")
  unless (all (\d -> let n = E.nativeFunction target d in not (null n) && length n <= 255) declarations)
    (Left "BEAM function name is empty or exceeds the Erlang atom limit")
  unless (not (any functionClashes units)) (Left "BEAM function names collide after snake_case conversion")
  unless (all (null . C.unitMachines) units && all (null . C.unitSessions) units &&
    all (null . C.unitSupervisors) units && all (null . C.unitMailboxes) units)
    (Left "BEAM models, sessions, actors and mailboxes are not implemented yet")
  unless (all (null . C.propertyResources . plannedProperty) laws && all ((== Nothing) . C.unitHarnessSettings) units &&
    all ((== C.noHarness) . C.propertyHarness . plannedProperty) laws)
    (Left "BEAM resources and harness settings are not implemented yet")
