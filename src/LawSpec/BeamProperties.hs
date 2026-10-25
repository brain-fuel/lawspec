-- | Native property cases and framework generators from checked Core.
-- Test execution planes share these expressions; source syntax stays out.
-- ref:DEC-typed-core-boundary ref:DEC-native-property-frameworks
module LawSpec.BeamProperties (emit, searchDescriptors, caseFunction) where

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
import qualified LawSpec.AbilityNames as N
import LawSpec.Common (Artifact(..), Generation(..))
import LawSpec.Testing
import qualified LawSpec.Testing.Cover as Cover
import LawSpec.NativeRequest (BindingPlan)
import LawSpec.TestNames (unitTestNames, unitBenchmarkNames)
import LawSpec.Search (lawDescriptors, searchable)
import Control.Monad (forM, foldM)
import qualified Data.Map.Strict as M
import Data.Char (toUpper)
import Data.Maybe (listToMaybe, mapMaybe)
import qualified LawSpec.BeamNames as Names
import LawSpec.Backend (lawCommentLines)
import qualified LawSpec.Backend as Backend
import LawSpec.Naming (displayLabel, exampleTestSuffix, boundaryTestSuffix, uniqueNames)
import LawSpec.SourceLink (labelled, locationLink, exampleLocation, originLocation, unitSourceFile)
import LawSpec.Common (Location)

emit :: String -> D.Layout -> BindingPlan -> Plan -> Either String [Artifact]
emit target layout bindings plan = do
  tests <- concat <$> mapM unitTests testedUnits
  pure (tests ++ [erlangRun | target == "erlang", not (null testedUnits)])
  where
    testedUnits = [u | u <- plannedUnits plan, not (null (plannedProperties u) &&
      null (benchmarks (plannedUnit u)) && null (ModelChecks.checks (modelTestUnit plan (plannedUnit u))))]
    benchmarks = maybe [] C.harnessBenchmarks . C.unitHarnessSettings
    erlangRun = Artifact "test/lawspec_generated_tests.erl"
      (D.render layout (E.moduleDoc "lawspec_generated_tests" [("lawspec_test_",0)]
        [E.function "lawspec_test_" [] [E.tuple [E.atom "setup",
          E.lambda [] (E.remote "lawspec_beam_test_run" "setup" []),
          E.lambda [D.text "Run"] (E.remote "lawspec_beam_test_run" "cleanup" [D.text "Run"]),
          E.lambda [D.text "_Run"] (E.remote "lawspec_beam_test_run" "select_units" [E.array
            [E.tuple [E.binary (C.idText (C.unitId u)), E.lambda [] (E.tuple [E.string (C.idText (C.unitId u)),
              E.remote (Definitions.adapterModule u ++ "_lawspec_tests") "scheduled_cases" []])]
            | p <- testedUnits, let u = plannedUnit p]])]]])) "generated" "test"
    bits = planMachineBits plan
    units = map plannedUnit (plannedUnits plan)
    hasPolicies = any ((/= Nothing) . C.definitionPolicy) (concatMap C.unitDefinitions units)
    testSupport = case target of "elixir" -> "test/support/"; "gleam" -> "test-support/src/"; _ -> "test/"
    framework = case target of "erlang" -> "lawspec_beam_proper"; "gleam" -> "lawspec_beam_qcheck"; _ -> "Elixir.LawSpec.Beam.StreamData"
    schema = D.text "Schema"
    symbols = D.text "Symbols"
    -- A case's schema and symbols, made fresh for each case.
    contextFor statements
      | Native.hasGenerators bindings = [E.assign "Symbols" (E.call "make_ref" []),
          E.assign "Schema" (E.remote "lawspec_native_generators" "schema" [E.remote "lawspec_data" "schema" [symbols]])]
      | otherwise = [E.field "=" (E.tuple [E.variable "Schema" scope, E.variable "Symbols" scope]) (E.remote "lawspec_data" "context" [])]
      where scope = E.sequenceDoc statements
    unitTests planned = do
      let unit = plannedUnit planned
          properties = plannedProperties planned
          names = unitTestNames target (map (C.propertyName . plannedProperty) properties)
          measured = benchmarks unit
          benchmarkNames = unitBenchmarkNames (map fst measured)
          models = ModelChecks.checks (modelTestUnit plan unit)
          allNames = names ++ map ModelChecks.checkName models ++ benchmarkNames
          allowances = zip names (map runnerAllowance properties)
          allowance n = maybe runnerGuard id (lookup n allowances)
          -- What each test checks, linked to its source where it has one.
          described n = maybe n id (lookup n
            ([(n', labelled (displayLabel (C.propertyName (plannedProperty p))) (propertyLink (plannedProperty p))) | (n',p) <- zip names properties] ++
             [(ModelChecks.checkName c, ModelChecks.checkLabel c) | c <- models] ++
             [(n', "benchmark " ++ label) | ((label,_),n') <- zip measured benchmarkNames]))
          groups = [(C.propertyName (plannedProperty p), n) | (p,n) <- zip properties names] ++
            [(ModelChecks.checkLabel c, ModelChecks.checkName c) | c <- models] ++
            [("benchmark " ++ label, n) | ((label,_),n) <- zip measured benchmarkNames]
          name = Definitions.adapterModule unit ++ (if target == "erlang" then "_lawspec_tests" else "_lawspec_cases")
          -- Each test's cases by name; a model check or benchmark has one.
          counts = [(n, caseSuffixes plan p) | (n,p) <- zip names properties] ++
            [(ModelChecks.checkName c,[""]) | c <- models] ++ [(n,[""]) | n <- benchmarkNames]
          skips = [n | (n,p) <- zip names properties, C.harnessSkip (C.propertyHarness (plannedProperty p)) /= Nothing]
          gleamCases = [(n,i,suffix) | (n,suffixes) <- counts, (i,suffix) <- zip [0 :: Int ..] suffixes, target == "gleam", n `elem` benchmarkNames, n `notElem` skips]
          gleamSkips = [n | n <- skips, target == "gleam"]
          caseEntry n suffix = caseFunction n suffix "_case"
          settings = C.unitHarnessSettings unit
          random = maybe False C.harnessOrderRandom settings
          parallel = maybe False C.harnessParallel settings
          scheduled = random || parallel
          schedule groups = E.remote "lawspec_beam_schedule" "eunit"
            [E.binary (C.idText (C.unitId unit)), E.atom (if random then "true" else "false"),
              E.atom (if parallel then "true" else "false"), groups]
          selected groups = E.remote "lawspec_beam_test_run" "select" [E.binary (C.idText (C.unitId unit)), groups]
          groupLabel n = E.string ("lawspec:" ++ C.idText (C.unitId unit) ++ "::" ++ n)
          gleamGroups = selected (E.array
            [E.tuple [E.binary n, E.tuple [groupLabel n, E.call (n ++ "_gleeunit_cases") []]] | n <- allNames])
          gleamFactories = [E.function (n ++ "_gleeunit_cases") []
            [E.remote "lawspec_beam_finite" "with_timeout"
              [D.text (show ((allowance n + 999) `div` 1000)), eunitCases n]] | target == "gleam", n <- allNames]
          gleamSuite = [E.function "lawspec_suite" [] [if scheduled then schedule gleamGroups else gleamGroups]
            | target == "gleam"]
          bridges = [E.function (caseEntry n suffix) [] [E.remote "lawspec_beam_gleam" "run_case"
            [E.call (n ++ "_test_") [],D.text (show i)]] | (n,i,suffix) <- gleamCases] ++
            [E.function (n ++ "_skipped_cases") [] [eunitCases n] | n <- gleamSkips]
          eunitCases n = E.remote "lawspec_beam_harness" "erlang_cases" [E.call (n ++ "_test_") []]
          exports = case target of
            "erlang" -> [("cases",0),("scheduled_cases",0),("suite",0)] ++ [(n ++ "_cases",0) | n <- allNames]
            "gleam" -> [(caseEntry n suffix,0) | (n,_,suffix) <- gleamCases] ++ [(n ++ "_skipped_cases",0) | n <- gleamSkips] ++
              [("lawspec_suite",0)] ++ [(n ++ "_gleeunit_cases",0) | n <- allNames]
            _ -> [(n ++ "_test_",0) | n <- allNames]
          indexedExports = [(n ++ "_case_at", 1) | n <- names, n `notElem` skips]
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
             in if target == "erlang" then E.tuple [E.atom "timeout",D.text (show (runnerGuard `div` 1000)),test] else test]]
            | check <- models]
      measurements <- sequence [benchmarkTest unit n label body | (n,(label,body)) <- zip benchmarkNames measured]
      pure (Artifact (testSupport ++ name ++ ".erl")
        (D.render layout (E.moduleDocFrom (unitSourceFile unit) name (exports ++ indexedExports) (bodies ++ modelTests ++ measurements ++ bridges ++ grouped ++ selections ++ gleamSuite ++ gleamFactories))) "generated" "test" :
        [Elixir.unitTests layout unit [(n, allowance n, described n) | n <- allNames] | target == "elixir"] ++
        [Gleam.unitTests layout unit [(n,suffixes,n `elem` skips,n `elem` benchmarkNames) | (n,suffixes) <- counts] | target == "gleam"])
    benchmarkTest unit name label expression = do
      body <- Expr.renderExpression bits schema symbols
        (\identity -> error ("unbound BEAM benchmark binder: " ++ C.idText identity))
        (Definitions.external units symbols) expression
      let measure = E.remote "lawspec_beam_harness" "benchmark"
            [E.binary (C.idText (C.unitId unit)),E.binary label,E.lambda [] body]
          test = E.tuple [E.string ("benchmark " ++ label),E.lambda [] (E.sequenceDoc (contextFor [measure] ++ [measure]))]
      pure (E.function (name ++ "_test_") [] [E.array
        [if target == "erlang" then E.tuple [E.atom "timeout",D.text (show (runnerGuard `div` 1000)),test] else test]])
    single h = C.harnessSkip h /= Nothing || C.harnessKnownDiscrepancy h /= Nothing
    lawTests unit name planned
      | Just reason <- C.harnessSkip (C.propertyHarness (plannedProperty planned)) =
          let law = plannedProperty planned
              label = C.idText (C.unitId unit) ++ "::" ++ C.propertyName law
          in pure [E.linkComment (displayLabel (C.propertyName law) ++ ", skipped") (propertyLink law) <>
            E.function (name ++ "_test_") [] [E.array [E.tuple [E.string (firstDescriptionOf plan planned),
            E.tuple [E.atom "skip",E.binary label,E.binary reason]]]]]
    lawTests unit name planned = do
      let law = plannedProperty planned
          parameters = map (C.quantifiedBinder) (C.propertyInputs law)
          resources = C.propertyResources law
          -- Inputs and resources keep their source names.
          sourceVariables = Names.variables Names.generatedVariables
            (map C.binderName parameters ++ map (C.binderName . C.resourceBinder) resources)
          aliases = zip (map C.binderId parameters) sourceVariables
          resourceAliases = zip (map (C.binderId . C.resourceBinder) resources) (drop (length parameters) sourceVariables)
          local identity = maybe (error ("unbound BEAM law binder: " ++ C.idText identity)) id
            (lookup identity (aliases ++ resourceAliases))
          renderWith active = Expr.renderExpression bits active symbols local (Definitions.external units symbols)
          render = renderWith schema
          label = C.idText (C.unitId unit) ++ "::" ++ C.propertyName law
          shown = displayLabel (C.propertyName law)
          lawLink = propertyLink law
          -- The law's identity, written once.
          macroName = map toUpper name
          lawIdentity = D.text ("?" ++ macroName)
          harness = C.propertyHarness law
          check result = E.remote "lawspec_beam_runtime" "require" [result,lawIdentity]
          -- An equation checks itself; other propositions are required true.
          checkProposition p doc = case p of
            C.Equation {} -> doc
            _ -> check doc
          caseName = name ++ "_case"
          resourceArguments = [E.array (map (D.text . snd) resourceAliases) | not (null resources)]
          -- A native handler made with a resource (ability A with T) is
          -- made once the case has acquired its T, inside the bracket.
          resourceFor ability choice = case choice of
            C.ProductionHandler -> do
              a <- N.abilityOf units ability
              t <- C.abilityResource a
              case [D.text n | (r,(_,n)) <- zip resources resourceAliases, C.binderType (C.resourceBinder r) == t] of
                found : _ -> Just found
                [] -> Nothing
            C.RecordingHandler inner -> resourceFor ability inner
            C.SpecHandler _ -> Nothing
          late = [(a,c,r) | (a,c) <- C.propertyHandlers law, not (C.isFail a), Just r <- [resourceFor a c]]
          early = [(a,c) | (a,c) <- C.propertyHandlers law, a `notElem` [x | (x,_,_) <- late]]
          installLate active = if null late then pure active else do
            made <- mapM (\(a,c,r) -> (,) (E.binary (C.abilityKey a)) <$> Effects.constructWith units active symbols (Just r) a c) late
            pure (E.remote "lawspec_beam_effects" "install" [active,E.record made])
          raw active values = E.call name ([either error id (installLate active),symbols,values] ++ resourceArguments)
          bracket active = bracketResources active (renderWith active) local resources
          -- A law with no handlers, resources or workflows checks its body
          -- directly; otherwise a case function sets them up first.
          plainScope = all (C.isFail . fst) (C.propertyHandlers law)
          plainCase = plainScope && null resources && not hasPolicies
          invoke values = E.call (if plainCase then name else caseName) [schema,symbols,values]
          workflowScope body = if hasPolicies then E.remote "lawspec_beam_workflow" "with_test_runtime" [E.lambda [] body] else body
          nativeTimeout action = if target == "erlang"
            then E.tuple [E.atom "timeout", D.text (show ((runnerAllowance planned + 999) `div` 1000)), action]
            else action
          descriptions = M.fromList (zip (caseSuffixes plan planned) (caseDescriptions plan planned))
          -- Each case is a function named for it, linked to its source; the
          -- law's test list runs them.
          test suffix link observations statements =
            let function = name ++ "__" ++ suffix
                description = M.findWithDefault (shown ++ " " ++ suffix) suffix descriptions
            in ( nativeTimeout (E.tuple [E.string description, D.text ("fun " ++ function ++ "/0")])
               , E.linkComment description link <>
                 E.function function [] [withHarness label (label ++ " " ++ suffix) harness (not (null resources)) observations
                   (E.sequenceDoc (contextFor statements ++ statements))] )
          scoped outer active statements
            | plainScope = E.remote "lawspec_beam_runtime" "bind" [outer,E.lambda [active] statements]
            | otherwise = E.remote "lawspec_beam_effects" "with_scope" [outer,either error id choicesDoc,E.lambda [active] statements]
          choicesDoc = Effects.factories units symbols early
      body <- Expr.assertionLabelled lawIdentity render (C.propertyBody law)
      _ <- choicesDoc
      _ <- installLate schema
      let exampleSuffixes = take (length (C.propertyExamples law)) (caseSuffixes plan planned)
      examples <- forM (zip exampleSuffixes (C.propertyExamples law)) $ \(suffix,example) -> do
        let exampleSchema = if plainScope then schema else D.text "ExampleSchema"
            exampleRender = renderWith exampleSchema
            exampleLink = locationLink <$> exampleLocation example
            context' = shown ++ " example " ++ displayLabel (C.exampleName example)
        arguments <- forM parameters $ \parameter -> case lookup (C.binderId parameter) (C.exampleBindings example) of
          Nothing -> Left "missing BEAM example input"
          Just expression -> exampleRender expression
        expectations <- forM (C.exampleExpectations example) $ \p -> do
          let link = maybe exampleLink (Just . locationLink) (propositionLocation p)
          checkProposition p <$> Expr.assertion (labelled context' link) exampleRender p
        let names = map (D.text . snd) aliases
            statements = [E.assign v a | ((_,v),a) <- zip aliases arguments] ++
              check (raw exampleSchema (E.array names)) : expectations
        acquired <- bracket exampleSchema (E.sequenceDoc statements)
        let body' = if plainScope && null resources && not hasPolicies then statements
              else [workflowScope (if plainScope then acquired else scoped schema exampleSchema acquired)]
        pure (test suffix exampleLink False body')
      cover <- caseCover planned
      let coverExpression = beamCover cover
          finiteIndex = D.text "CaseIndex"
          finiteFactories = D.text "CaseFactories"
          finiteValues = E.remote "lawspec_beam_finite" "values" [symbols, finiteFactories]
          finiteStatements = [check (invoke finiteValues)]
          finiteBody = withHarnessNamed label
            (E.remote "lawspec_beam_finite" "name" [E.binary (label ++ " " ++ label ++ " boundary_"), finiteIndex])
            harness (not (null resources)) False (E.sequenceDoc (contextFor finiteStatements ++ finiteStatements))
          finiteMake = E.lambda [finiteIndex, finiteFactories] (nativeTimeout (E.tuple
            [E.remote "lawspec_beam_finite" "description" [E.binary shown, finiteIndex], E.lambda [] finiteBody]))
          finiteGroups = [E.tuple [E.atom "finite", coverExpression, finiteMake] | Cover.coverCount cover > 0]
      randomTests <- case finiteCases planned of
        -- An exhaustive law has no random samples to satisfy cover. Still
        -- report zero observations; a cover clause must not silently pass.
        Just _ | not (sampleFinite plan planned) -> pure [test "statistics" lawLink True [E.atom "ok"] | observed harness]
        _ -> do
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
                  [lawIdentity,E.array (map E.binary ds),arguments,E.lambda [] (invoke arguments)]
              callback = if not (observed harness) then E.lambda [D.text "Values"] (remembered (D.text "Values"))
                else E.lambda [values] (E.remote "lawspec_beam_harness" "sample"
                  [E.lambda [] (E.tuple [E.array covers,E.array classes,E.array labels,score]),E.lambda [] (remembered values)])
              condition = foldr1 (E.operator "andalso") predicates
              replayCheck = if null predicates then check (invoke values) else
                E.caseOf condition [(E.atom "true",check (invoke values)),(E.atom "false",E.atom "none")]
              replay = [E.remote "lawspec_beam_search" "replay"
                [lawIdentity,E.array (map E.binary ds),E.lambda [values] replayCheck] | Just ds <- [descriptors]]
              -- EUnit's five-second default covers a single test. A property
              -- runs every sample plus shrinks; match ExUnit's one-minute
              -- allowance.
              propertyTest = test "property" lawLink (observed harness) (replay ++ [E.remote framework "check" [lawIdentity,
                E.remote framework "forall" [E.remote framework "complete" [generator],
                  callback],options]])
          pure [propertyTest]
      searchTests <- case targetSearch plan planned of
        Nothing -> pure []
        Just (descriptors, targetScore) -> do
          score <- render targetScore
          predicates <- mapM render (concatMap C.quantifiedPredicates (C.propertyInputs law))
          let values = E.array (map (D.text . snd) aliases)
              condition = foldr1 (E.operator "andalso") predicates
              checked = E.sequenceDoc [check (invoke values),E.tuple [E.atom "score",score]]
              guarded = if null predicates then checked else
                E.caseOf condition [(E.atom "true",checked),(E.atom "false",E.atom "none")]
          pure [test "search" lawLink False [E.remote "lawspec_beam_search" "climb"
            [lawIdentity,E.array (map E.binary descriptors),E.lambda [values] guarded]]]
      acquired <- bracket schema (raw schema (D.text "Values"))
      let -- Validate explicitly requested draws before deterministic checks
          -- can satisfy a known failure and bypass strategy/coverage checks.
          (before, after)
            | C.harnessKnownDiscrepancy harness /= Nothing && sampleFinite plan planned =
                (randomTests ++ examples, searchTests)
            | otherwise = (examples, randomTests ++ searchTests)
          fixed pairs = [E.tuple [E.atom "fixed", E.array (map fst pairs)] | not (null pairs)]
          planName = name ++ "_plan"
          planDoc = E.function planName [] [E.array (fixed before ++ finiteGroups ++ fixed after)]
          ordinary = E.remote "lawspec_beam_finite" "plan_cases" [E.call planName []]
          caseFunctions = map snd (before ++ after)
          tests = case C.harnessKnownDiscrepancy harness of
            Nothing -> ordinary
            Just reason ->
              let expected = E.tuple [E.string (firstDescriptionOf plan planned),
                    E.lambda [] (E.remote "lawspec_beam_harness" "known_discrepancy"
                      [lawIdentity,E.binary (label ++ " known discrepancy"),E.binary reason,ordinary])]
              in E.array [nativeTimeout expected]
          parameterList = E.array [E.variable v body | (_,v) <- aliases]
          bodyDoc = E.define macroName (E.binary label) <> D.hardline <> D.hardline <>
            E.comment (lawCommentLines planned) <>
            E.function name ([E.variable "Schema" body,E.variable "Symbols" body,parameterList] ++
              [E.array [E.variable v body | (_,v) <- resourceAliases] | not (null resources)]) [body]
          caseDoc = E.function caseName [D.text (if plainScope then "Schema" else "BaseSchema"),symbols,D.text "Values"]
            [workflowScope (if plainScope then acquired else scoped (D.text "BaseSchema") schema acquired)]
          caseAtDoc = E.function (name ++ "_case_at") [D.text "Index"]
            [if C.harnessKnownDiscrepancy harness == Nothing
               then E.remote "lawspec_beam_finite" "case_at" [E.call planName [], D.text "Index"]
               else E.remote "lists" "nth" [E.operator "+" (D.text "Index") (D.text "1"), E.call (name ++ "_test_") []]]
      pure ([bodyDoc] ++ [caseDoc | not plainCase] ++
        [planDoc, E.function (name ++ "_test_") [] [tests], caseAtDoc] ++ caseFunctions)

    beamCover (Cover.Complete count) = E.tuple [E.atom "copies", D.text (show count)]
    beamCover (Cover.Alternatives branches) = E.tuple [E.atom "branches", E.array
      [E.tuple [domainDoc domain, beamCover suffix] | (domain, suffix) <- branches]]
    domainDoc (Cover.Values values) = E.tuple [E.atom "values", E.array
      [E.lambda [symbols] (E.value symbols value) | value <- values]]
    domainDoc (Cover.IntegerInterval _ first last') = E.tuple [E.atom "integers", D.text (show first), D.text (show last')]

-- | The names of a law's cases, in the order its test list runs them:
-- each example's own words, boundary_1, boundary_2, ..., then property,
-- statistics or search. A skipped or known-discrepancy law has one case.
caseSuffixes :: Plan -> PlannedProperty -> [String]
caseSuffixes plan planned
  | C.harnessSkip harness /= Nothing = ["skipped"]
  | C.harnessKnownDiscrepancy harness /= Nothing = ["known_discrepancy"]
  | otherwise = examples ++ boundarySuffixes ++ random ++ search
  where
    law = plannedProperty planned
    harness = C.propertyHarness law
    boundarySuffixes = map boundaryTestSuffix [0 .. length (maybe (boundaryCases planned) id (finiteCases planned)) - 1]
    random = case finiteCases planned of
      Just _ | not (sampleFinite plan planned) -> ["statistics" | observed harness]
      _ -> ["property"]
    search = ["search" | targetSearch plan planned /= Nothing]
    examples = exampleTestSuffix "erlang" (["skipped", "known_discrepancy", "statistics", "property", "search"] ++ boundarySuffixes)
      (map C.exampleName (C.propertyExamples law))

firstDescriptionOf :: Plan -> PlannedProperty -> String
firstDescriptionOf plan planned = case caseDescriptions plan planned of
  d : _ -> d
  [] -> displayLabel (C.propertyName (plannedProperty planned))

-- | What a reader sees of each case, in caseSuffixes' order: the law's
-- label and the case's (|law| example |name|, |law| boundary 1). They are
-- unique and short enough to name an ExUnit test.
caseDescriptions :: Plan -> PlannedProperty -> [String]
caseDescriptions plan planned = uniqueNames (map bounded (zipWith describe (caseSuffixes plan planned) (map Just examples ++ repeat Nothing)))
  where
    law = plannedProperty planned
    shown = displayLabel (C.propertyName law)
    examples = map (displayLabel . C.exampleName) (C.propertyExamples law)
    describe suffix example = case (suffix, example) of
      ("skipped", _) -> shown ++ " skipped"
      ("known_discrepancy", _) -> shown ++ " known discrepancy"
      ("property", _) -> shown ++ " property"
      ("statistics", _) -> shown ++ " statistics"
      ("search", _) -> shown ++ " search"
      (_, Just e) | not (isBoundary suffix) -> shown ++ " example " ++ e
      _ | isBoundary suffix ->
            let ending = " " ++ map (\c -> if c == '_' then ' ' else c) suffix
            in take (max 0 (200 - length ending)) shown ++ ending
        | otherwise -> shown ++ " " ++ map (\c -> if c == '_' then ' ' else c) suffix
    isBoundary suffix = take 9 suffix == "boundary_" && all (`elem` ['0'..'9']) (drop 9 suffix)
    bounded text = if length text <= 200 then text else take 197 text ++ "..."

-- | Where a proposition is written: its first expression's line.
propositionLocation :: C.Proposition -> Maybe Location
propositionLocation p = listToMaybe (mapMaybe (originLocation . C.expressionOrigin) (expressions p))
  where
    expressions q = case q of
      C.Equation _ a b -> [a, b]
      C.Implication a r -> a : expressions r
      C.Conjunction ps -> concatMap expressions ps
      C.Negation r -> expressions r
      C.Quantified _ _ r -> expressions r

-- | A case's function: the test's name, its case's after a double
-- underscore, and a suffix (_case, _test).
caseFunction :: String -> String -> String -> String
caseFunction n suffix extra = (if null suffix then n else n ++ "__" ++ suffix) ++ extra

observed :: C.LawHarness -> Bool
observed harness = not (null (C.harnessCover harness) && null (C.harnessClassify harness) && null (C.harnessLabels harness)) ||
  C.harnessTarget harness /= Nothing

-- Explicit strategies supply requested observations when property testing
-- and complete finite checking are both selected. Keep the complete domain
-- as separate cases; unused fallback strategies remain unnecessary.
-- An empty domain and an unselected property layer never request samples.
sampleFinite :: Plan -> PlannedProperty -> Bool
sampleFinite plan planned = planPropertyChecks plan && finiteCases planned /= Just [] &&
  observed harness && not (null (C.harnessDraws harness))
  where harness = C.propertyHarness (plannedProperty planned)

targetSearch :: Plan -> PlannedProperty -> Maybe ([String], C.Expr)
targetSearch plan planned = do
  let law = plannedProperty planned
  score <- C.harnessTarget (C.propertyHarness law)
  descriptors <- searchDescriptors plan planned
  pure (descriptors,score)

searchDescriptors :: Plan -> PlannedProperty -> Maybe [String]
searchDescriptors plan planned
  | searchable (finiteCases planned /= Nothing && not (sampleFinite plan planned)) (plannedProperty planned) =
      lawDescriptors (planMachineBits plan) (planDataDeclarations plan) (plannedProperty planned)
  | otherwise = Nothing

-- | What EUnit and ExUnit allow a law, a model check or a benchmark beyond its
-- own timeouts (ms): a guard against a hang, not a budget. A law's cases may
-- wait on the real clock (retries over a lossy network), which a loaded
-- machine stretches, and a law with no timeout states nothing about time.
runnerGuard :: Integer
runnerGuard = 600000

-- The native runner must leave time for every configured repetition and for
-- owner cleanup. LawSpec enforces the actual deadline inside this allowance.
runnerAllowance :: PlannedProperty -> Integer
runnerAllowance planned = runnerGuard + count * (attempts * timeout + cleanup)
  where
    law = plannedProperty planned
    harness = C.propertyHarness law
    timeout = maybe 0 id (C.harnessTimeout harness)
    attempts = C.harnessRepeat harness * (1 + C.harnessRetries harness)
    cleanup = 10000 * toInteger (length (C.propertyResources law))
    count = case C.harnessKnownDiscrepancy harness of
      Nothing -> 1
      Just _ -> 2 + toInteger (length (C.propertyExamples law) + length (maybe (boundaryCases planned) id (finiteCases planned)))

withHarness :: String -> String -> C.LawHarness -> Bool -> Bool -> D.Doc -> D.Doc
withHarness label kind = withHarnessNamed label (E.binary (label ++ " " ++ kind))

withHarnessNamed :: String -> D.Doc -> C.LawHarness -> Bool -> Bool -> D.Doc -> D.Doc
withHarnessNamed label testName harness resources observations body
  | not observations && not controlled = body
  | otherwise = E.remote "lawspec_beam_harness" "run" ([E.binary label,testName,
      E.array [E.tuple [D.text (show percent),E.binary name] | observations, C.Cover percent name _ <- C.harnessCover harness]] ++
      [E.record ([(E.atom "repeat",D.text (show (C.harnessRepeat harness))),
        (E.atom "retries",D.text (show (C.harnessRetries harness))),
        (E.atom "resources",E.atom (if resources then "true" else "false")),
        (E.atom "observed",E.atom (if observations then "true" else "false"))] ++
        [(E.atom "timeout",D.text (show ms)) | Just ms <- [C.harnessTimeout harness]]) | controlled] ++ [E.lambda [] body])
  where controlled = resources || C.harnessTimeout harness /= Nothing || C.harnessRepeat harness /= 1 ||
          C.harnessRetries harness /= 0 || C.harnessKnownDiscrepancy harness /= Nothing

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


-- | A law's source line; a law made by the compiler (<contract>) has none.
propertyLink :: C.Property -> Maybe String
propertyLink law = case Backend.propertyLink law of
  Just ('<' : _) -> Nothing
  link -> link
