-- | Native property cases and framework generators from checked Core.
-- Test execution planes share these expressions; source syntax stays out.
-- ref:DEC-typed-core-boundary ref:DEC-native-property-frameworks
module LawSpec.BeamProperties (emit, searchDescriptors) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.BeamExpr as Expr
import qualified LawSpec.BeamDefinitions as Definitions
import qualified LawSpec.BeamGenerators as Generators
import qualified LawSpec.BeamEffects as Effects
import qualified LawSpec.BeamNativeBinding as Native
import qualified LawSpec.BeamModelChecks as ModelChecks
import qualified LawSpec.ElixirNative as Elixir
import qualified LawSpec.GleamNative as Gleam
import LawSpec.Common (Artifact(..), Generation(..))
import LawSpec.Testing
import LawSpec.NativeRequest (BindingPlan)
import LawSpec.TestNames (unitTestNames, unitBenchmarkNames)
import LawSpec.Search (lawDescriptors, searchable)
import LawSpec.Backend (metadataDocument)
import Control.Monad (forM, foldM)

emit :: String -> D.Layout -> BindingPlan -> Plan -> Either String [Artifact]
emit target layout bindings plan = do
  tests <- concat <$> mapM unitTests testedUnits
  pure (tests ++ [erlangRun | target == "erlang", not (null testedUnits)])
  where
    testedUnits = [u | u <- plannedUnits plan, not (null (plannedProperties u) &&
      null (benchmarks (plannedUnit u)) && null (ModelChecks.checks (plannedUnit u)))]
    benchmarks = maybe [] C.harnessBenchmarks . C.unitHarnessSettings
    erlangRun = Artifact "test/lawspec_generated_tests.erl"
      (D.render layout (E.moduleDoc "lawspec_generated_tests" [("lawspec_test_",0)]
        [E.function "lawspec_test_" [] [E.tuple [E.atom "setup",
          E.lambda [] (E.remote "lawspec_beam_test_run" "setup" []),
          E.lambda [D.text "_LsRun"] (E.remote "lawspec_beam_test_run" "cleanup" [D.text "_LsRun"]),
          E.lambda [D.text "_LsRun"] (E.remote "lawspec_beam_test_run" "select_units" [E.array
            [E.tuple [E.binary (C.idText (C.unitId u)), E.lambda [] (E.tuple [E.string (C.idText (C.unitId u)),
              E.remote (Definitions.adapterModule u ++ "_lawspec_tests") "scheduled_cases" []])]
            | p <- testedUnits, let u = plannedUnit p]])]]])) "generated" "test"
    bits = planMachineBits plan
    units = map plannedUnit (plannedUnits plan)
    hasPolicies = any ((/= Nothing) . C.definitionPolicy) (concatMap C.unitDefinitions units)
    testSupport = case target of "elixir" -> "test/support/"; "gleam" -> "test-support/src/"; _ -> "test/"
    framework = case target of "erlang" -> "lawspec_beam_proper"; "gleam" -> "lawspec_beam_qcheck"; _ -> "Elixir.LawSpec.Beam.StreamData"
    schema = D.text "_LsSchema"
    symbols = D.text "_LsSymbols"
    context = [D.text "_LsSymbols = make_ref()",D.text "_LsSchema = " <> wrap (E.remote "lawspec_data" "schema" [symbols])]
      where wrap doc = if Native.hasGenerators bindings then E.remote "lawspec_native_generators" "schema" [doc] else doc
    unitTests planned = do
      let unit = plannedUnit planned
          properties = plannedProperties planned
          names = unitTestNames target (map (C.propertyName . plannedProperty) properties)
          measured = benchmarks unit
          benchmarkNames = unitBenchmarkNames (map fst measured)
          models = ModelChecks.checks unit
          allNames = names ++ map ModelChecks.checkName models ++ benchmarkNames
          allowances = zip names (map runnerAllowance properties)
          allowance n = maybe 60000 id (lookup n allowances)
          groups = [(C.propertyName (plannedProperty p), n) | (p,n) <- zip properties names] ++
            [(ModelChecks.checkLabel c, ModelChecks.checkName c) | c <- models] ++
            [("benchmark " ++ label, n) | ((label,_),n) <- zip measured benchmarkNames]
          name = Definitions.adapterModule unit ++ (if target == "erlang" then "_lawspec_tests" else "_lawspec_cases")
          counts = [(n, if single (C.propertyHarness (plannedProperty p)) then 1 else length (C.propertyExamples (plannedProperty p)) +
            length (maybe (boundaryCases p) id (finiteCases p)) +
            (if finiteCases p == Nothing || observed (C.propertyHarness (plannedProperty p)) then 1 else 0) +
            maybe 0 (const 1) (targetSearch plan p))
            | (n,p) <- zip names properties] ++ [(ModelChecks.checkName c,1) | c <- models] ++ [(n,1) | n <- benchmarkNames]
          skips = [n | (n,p) <- zip names properties, C.harnessSkip (C.propertyHarness (plannedProperty p)) /= Nothing]
          gleamCases = [(n,i) | (n,count) <- counts, i <- [0..count-1], target == "gleam", n `notElem` skips]
          gleamSkips = [n | n <- skips, target == "gleam"]
          caseEntry n i = n ++ "_case_" ++ show i
          settings = C.unitHarnessSettings unit
          random = maybe False C.harnessOrderRandom settings
          parallel = maybe False C.harnessParallel settings
          scheduled = random || parallel
          schedule groups = E.remote "lawspec_beam_schedule" "eunit"
            [E.binary (C.idText (C.unitId unit)), E.atom (if random then "true" else "false"),
              E.atom (if parallel then "true" else "false"), groups]
          selected groups = E.remote "lawspec_beam_test_run" "select" [E.binary (C.idText (C.unitId unit)), groups]
          groupLabel n = E.string ("lawspec:" ++ C.idText (C.unitId unit) ++ "::" ++ n)
          facade = Definitions.adapterModule unit ++ "_lawspec_test"
          gleamNative n i = E.remote "erlang" "make_fun"
            [E.atom facade, E.atom (n ++ "__case_" ++ show i ++ "_test"), D.text "0"]
          gleamGroups = selected (E.array
            [E.tuple [E.binary n, E.tuple [groupLabel n, E.array (if n `elem` skips
                then [E.tuple [E.atom "generator", E.remote "erlang" "make_fun"
                  [E.atom facade, E.atom (n ++ "__skipped_test_"), D.text "0"]]]
                else [E.tuple [E.atom "timeout", D.text (show ((allowance n + 999) `div` 1000)), E.tuple [E.string (n ++ "__case_" ++ show i), gleamNative n i]]
                  | i <- [0..count-1]])]] | (n,count) <- counts])
          gleamSuite = [E.function "lawspec_suite" [] [if scheduled then schedule gleamGroups else gleamGroups]
            | target == "gleam"]
          bridges = [E.function (caseEntry n i) [] [E.remote "lawspec_beam_gleam" "run_case"
            [E.call (n ++ "_test_") [],D.text (show i)]] | (n,i) <- gleamCases] ++
            [E.function (n ++ "_skipped_cases") [] [eunitCases n] | n <- gleamSkips]
          eunitCases n = E.remote "lawspec_beam_harness" "erlang_cases" [E.call (n ++ "_test_") []]
          exports = case target of
            "erlang" -> [("cases",0),("scheduled_cases",0),("suite",0)] ++ [(n ++ "_cases",0) | n <- allNames]
            "gleam" -> [(caseEntry n i,0) | (n,i) <- gleamCases] ++ [(n ++ "_skipped_cases",0) | n <- gleamSkips] ++
              [("lawspec_suite",0)]
            _ -> [(n ++ "_test_",0) | n <- allNames]
          grouped = [E.function "cases" [] [E.array
            [E.tuple [groupLabel n, eunitCases n] | (_,n) <- groups]] | target == "erlang"]
          erlangSelected = selected (E.remote "lists" "zip" [E.array (map E.binary allNames), E.call "cases" []])
          -- Native Rebar/EUnit selection uses --generator Module:suite or
          -- Module:law_label_cases. Only the root fixture is auto-discovered,
          -- so a full run owns one pool across units and executes each case once.
          selections = concat [[E.function "scheduled_cases" []
              [if scheduled then schedule erlangSelected else erlangSelected],
              E.function "suite" [] [E.remote "lawspec_beam_test_run" "fixture" [E.call "scheduled_cases" []]]]
            | target == "erlang"] ++
            [E.function (n ++ "_cases") [] [E.remote "lawspec_beam_test_run" "fixture"
              [let group = E.tuple [groupLabel n, eunitCases n]
               in if scheduled then schedule (E.array [group]) else group]]
              | target == "erlang", (_,n) <- groups]
      bodies <- concat <$> sequence [lawTests unit n p | (n,p) <- zip names properties]
      let modelTests = [E.function (ModelChecks.checkName check ++ "_test_") [] [E.array
            [let test = E.tuple [E.string (ModelChecks.checkLabel check), E.lambda []
                   (E.remote (Definitions.adapterModule unit ++ "_lawspec_models") (ModelChecks.checkName check) [])]
             in if target == "erlang" then E.tuple [E.atom "timeout",D.text "60",test] else test]]
            | check <- models]
      measurements <- sequence [benchmarkTest unit n label body | (n,(label,body)) <- zip benchmarkNames measured]
      pure (Artifact (testSupport ++ name ++ ".erl")
        (D.render layout (E.moduleDoc name exports (bodies ++ modelTests ++ measurements ++ bridges ++ grouped ++ selections ++ gleamSuite))) "generated" "test" :
        [Elixir.unitTests layout unit [(n, allowance n) | n <- allNames] | target == "elixir"] ++
        [Gleam.unitTests layout unit [(n,count,n `elem` skips) | (n,count) <- counts] | target == "gleam"])
    benchmarkTest unit name label expression = do
      body <- Expr.renderExpression bits schema symbols
        (\identity -> error ("unbound BEAM benchmark binder: " ++ C.idText identity))
        (Definitions.external units symbols) expression
      let measure = E.remote "lawspec_beam_harness" "benchmark"
            [E.binary (C.idText (C.unitId unit)),E.binary label,E.lambda [] body]
          test = E.tuple [E.string ("benchmark " ++ label),E.lambda [] (E.sequenceDoc (context ++ [measure]))]
      pure (E.function (name ++ "_test_") [] [E.array
        [if target == "erlang" then E.tuple [E.atom "timeout",D.text "60",test] else test]])
    single h = C.harnessSkip h /= Nothing || C.harnessKnownFailing h /= Nothing
    lawTests unit name planned
      | Just reason <- C.harnessSkip (C.propertyHarness (plannedProperty planned)) =
          let label = C.idText (C.unitId unit) ++ "::" ++ C.propertyName (plannedProperty planned)
          in pure [E.function (name ++ "_test_") [] [E.array [E.tuple [E.string (label ++ " skipped"),
            E.tuple [E.atom "skip",E.binary label,E.binary reason]]]]]
    lawTests unit name planned = do
      let law = plannedProperty planned
          parameters = map (C.quantifiedBinder) (C.propertyInputs law)
          aliases = zip (map C.binderId parameters) ["_LsInput" ++ show i | i <- [0::Int ..]]
          resources = C.propertyResources law
          resourceAliases = zip (map (C.binderId . C.resourceBinder) resources)
            ["_LsResource" ++ show i | i <- [0::Int ..]]
          local identity = maybe (error ("unbound BEAM law binder: " ++ C.idText identity)) id
            (lookup identity (aliases ++ resourceAliases))
          renderWith active = Expr.renderExpression bits active symbols local (Definitions.external units symbols)
          render = renderWith schema
          label = C.idText (C.unitId unit) ++ "::" ++ C.propertyName law
          harness = C.propertyHarness law
          check result = E.remote "lawspec_beam_runtime" "require" [result,E.binary label]
          caseName = name ++ "_case"
          rawName = name ++ "_body"
          resourceArguments = [E.array (map (D.text . snd) resourceAliases) | not (null resources)]
          raw active values = E.call rawName ([active,symbols,values] ++ resourceArguments)
          bracket active = bracketResources active (renderWith active) local resources
          invoke values = E.call caseName [schema,symbols,values]
          workflowScope body = if hasPolicies then E.remote "lawspec_beam_workflow" "with_test_runtime" [E.lambda [] body] else body
          nativeTimeout action = if target == "erlang"
            then E.tuple [E.atom "timeout", D.text (show ((runnerAllowance planned + 999) `div` 1000)), action]
            else action
          test kind observations statements = nativeTimeout (E.tuple [E.string (label ++ " " ++ kind),
            E.lambda [] (withHarness label kind harness (not (null resources)) observations (E.sequenceDoc (context ++ statements)))])
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
              (map check (raw exampleSchema (E.array names) : expectations)))) [E.array arguments]
        acquired <- bracket exampleSchema assertion
        pure (test ("example " ++ show i ++ ": " ++ C.exampleName example) False [workflowScope (scoped schema exampleSchema acquired)])
      let boundaryTests = [test ("boundary " ++ show i) False [check (invoke (E.array (map (E.value symbols) values)))]
            | (i,values) <- zip [0::Int ..] (maybe (boundaryCases planned) id (finiteCases planned))]
      randomTests <- case finiteCases planned of
        -- An exhaustive law has no random samples to satisfy cover. Still
        -- report zero observations; a cover clause must not silently pass.
        Just _ -> pure [test "statistics" True [E.atom "ok"] | observed harness]
        Nothing -> do
          generator <- Generators.inputs framework schema symbols plan local planned
          predicates <- mapM render (concatMap C.quantifiedPredicates (C.propertyInputs law))
          covers <- mapM (render . C.coverWhen) (C.harnessCover harness)
          classes <- forM (C.harnessClassify harness) $ \(predicate, name') -> do
            value <- render predicate
            pure (E.tuple [E.binary name',value])
          labels <- mapM render (C.harnessLabels harness)
          score <- maybe (pure (E.atom "none")) (fmap (\v -> E.tuple [E.atom "score",v]) . render) (C.harnessTarget harness)
          let settings = C.propertyGeneration law
              options = E.array [E.tuple [E.atom k,D.text (show v)] | (k,v) <-
                [("numtests",cases settings),("constraint_tries",maxAttempts settings),("max_shrinks",maxShrinks settings)]]
              values = E.array (map (D.text . snd) aliases)
              descriptors = searchDescriptors plan planned
              remembered arguments = case descriptors of
                Nothing -> invoke arguments
                Just ds -> E.remote "lawspec_beam_search" "guard"
                  [E.binary label,E.array (map E.binary ds),arguments,E.lambda [] (invoke arguments)]
              callback = if not (observed harness) then E.lambda [D.text "_LsValues"] (remembered (D.text "_LsValues"))
                else E.lambda [values] (E.remote "lawspec_beam_harness" "sample"
                  [E.lambda [] (E.tuple [E.array covers,E.array classes,E.array labels,score]),E.lambda [] (remembered values)])
              condition = foldr (\a b -> D.text "(" <> a <> D.text " andalso " <> b <> D.text ")") (E.atom "true") predicates
              replayCheck = if null predicates then check (invoke values) else D.group (D.text "case " <> condition <> D.text " of" <>
                D.nest 4 (D.softline <> D.text "true -> " <> check (invoke values) <> D.text ";" <>
                  D.softline <> D.text "false -> none") <> D.softline <> D.text "end")
              replay = [E.remote "lawspec_beam_search" "replay"
                [E.binary label,E.array (map E.binary ds),E.lambda [values] replayCheck] | Just ds <- [descriptors]]
              propertyTest = test "property" (observed harness) (replay ++ [E.remote framework "check" [E.binary label,
                E.remote framework "forall" [E.remote framework "complete" [generator],
                  callback],options]])
          -- EUnit's five-second default covers a single test. A property runs
          -- every sample plus shrinks; match ExUnit's one-minute allowance.
          pure [propertyTest]
      searchTests <- case targetSearch plan planned of
        Nothing -> pure []
        Just (descriptors, targetScore) -> do
          score <- render targetScore
          predicates <- mapM render (concatMap C.quantifiedPredicates (C.propertyInputs law))
          let values = E.array (map (D.text . snd) aliases)
              condition = foldr (\a b -> D.text "(" <> a <> D.text " andalso " <> b <> D.text ")") (E.atom "true") predicates
              checked = E.sequenceDoc [check (invoke values),E.tuple [E.atom "score",score]]
              guarded = if null predicates then checked else D.group (D.text "case " <> condition <> D.text " of" <>
                D.nest 4 (D.softline <> D.text "true -> " <> checked <> D.text ";" <>
                  D.softline <> D.text "false -> none") <> D.softline <> D.text "end")
              searchTest = test "search" False [E.remote "lawspec_beam_search" "climb"
                [E.binary label,E.array (map E.binary descriptors),E.lambda [values] guarded]]
          pure [searchTest]
      acquired <- bracket schema (raw schema (D.text "_LsValues"))
      let ordinary = E.array (examples ++ boundaryTests ++ randomTests ++ searchTests)
          tests = case C.harnessKnownFailing harness of
            Nothing -> ordinary
            Just reason ->
              let expected = E.tuple [E.string (label ++ " known failing"),
                    E.lambda [] (E.remote "lawspec_beam_harness" "known_failing"
                      [E.binary label,E.binary (label ++ " known failing"),E.binary reason,ordinary])]
              in E.array [nativeTimeout expected]
      pure [metadataDocument 100 "%%" planned <>
        E.function rawName ([schema,symbols,E.array (map (D.text . snd) aliases)] ++ resourceArguments) [body],
        E.function caseName [D.text "_LsBaseSchema",symbols,D.text "_LsValues"]
          [workflowScope (scoped (D.text "_LsBaseSchema") schema acquired)],
        E.function (name ++ "_test_") [] [tests]]

observed :: C.LawHarness -> Bool
observed harness = not (null (C.harnessCover harness) && null (C.harnessClassify harness) && null (C.harnessLabels harness)) ||
  C.harnessTarget harness /= Nothing

targetSearch :: Plan -> PlannedProperty -> Maybe ([String], C.Expr)
targetSearch plan planned = do
  let law = plannedProperty planned
  score <- C.harnessTarget (C.propertyHarness law)
  descriptors <- searchDescriptors plan planned
  pure (descriptors,score)

searchDescriptors :: Plan -> PlannedProperty -> Maybe [String]
searchDescriptors plan planned
  | searchable (finiteCases planned /= Nothing) (plannedProperty planned) =
      lawDescriptors (planMachineBits plan) (planDataDeclarations plan) (plannedProperty planned)
  | otherwise = Nothing

-- The native runner must leave time for every configured repetition and for
-- owner cleanup. LawSpec enforces the actual deadline inside this allowance.
runnerAllowance :: PlannedProperty -> Integer
runnerAllowance planned = 60000 + count * (attempts * timeout + cleanup)
  where
    law = plannedProperty planned
    harness = C.propertyHarness law
    timeout = maybe 0 id (C.harnessTimeout harness)
    attempts = C.harnessRepeat harness * (1 + C.harnessRetries harness)
    cleanup = 10000 * toInteger (length (C.propertyResources law))
    count = case C.harnessKnownFailing harness of
      Nothing -> 1
      Just _ -> 2 + toInteger (length (C.propertyExamples law) + length (maybe (boundaryCases planned) id (finiteCases planned)))

withHarness :: String -> String -> C.LawHarness -> Bool -> Bool -> D.Doc -> D.Doc
withHarness label kind harness resources observations body
  | not observations && not controlled = body
  | otherwise = E.remote "lawspec_beam_harness" "run" ([E.binary label,E.binary (label ++ " " ++ kind),
      E.array [E.tuple [D.text (show percent),E.binary name] | observations, C.Cover percent name _ <- C.harnessCover harness]] ++
      [E.record ([(E.atom "repeat",D.text (show (C.harnessRepeat harness))),
        (E.atom "retries",D.text (show (C.harnessRetries harness))),
        (E.atom "resources",E.atom (if resources then "true" else "false")),
        (E.atom "observed",E.atom (if observations then "true" else "false"))] ++
        [(E.atom "timeout",D.text (show ms)) | Just ms <- [C.harnessTimeout harness]]) | controlled] ++ [E.lambda [] body])
  where controlled = resources || C.harnessTimeout harness /= Nothing || C.harnessRepeat harness /= 1 ||
          C.harnessRetries harness /= 0 || C.harnessKnownFailing harness /= Nothing

-- | Acquire and release in a surviving resource owner. The case borrows its
-- handle; nested brackets release in reverse order, including on cancellation.
-- ref:REQ-law-primitives
bracketResources :: D.Doc -> (C.Expr -> Either String D.Doc) -> (C.Id -> String) -> [C.Resource]
  -> D.Doc -> Either String D.Doc
bracketResources schema render local resources body = foldM wrap body (reverse resources)
  where
    wrap inner resource = case C.resourceShared resource of
      Just key -> do
        acquire <- render (C.resourceAcquire resource)
        release <- render (C.resourceRelease resource)
        reset <- maybe (Left "a shared BEAM resource requires reset") render (C.resourceReset resource)
        let name = D.text (local (C.binderId (C.resourceBinder resource)))
        pure (E.remote "lawspec_beam_resources" "with_shared"
          [E.binary key,schema,E.lambda [] acquire,E.lambda [name] reset,E.lambda [name] release,
            E.atom (if C.resourceConcurrent resource then "true" else "false"),E.lambda [name] inner])
      Nothing -> do
        acquire <- render (C.resourceAcquire resource)
        release <- render (C.resourceRelease resource)
        let name = D.text (local (C.binderId (C.resourceBinder resource)))
        pure (E.remote "lawspec_beam_resources" "with_resource"
          [schema,E.lambda [] acquire,E.lambda [name] release,E.lambda [name] inner])

