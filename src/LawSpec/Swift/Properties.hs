-- | Each unit's laws as Swift Testing tests: examples, boundary cases, the
-- property over generated cases (on the runtime's engine), targeted search
-- and the harness's controls. A law's case runs on a runtime thread, so the
-- synchronous runtime never blocks Swift's cooperative pool.
-- ref:DEC-typed-core-boundary ref:DEC-swift-property-library ref:REQ-harness-units
module LawSpec.Swift.Properties (emitTests, emitNativeGenerators, emitRootSuites) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import LawSpec.Common (Artifact(..), Generation(..), Location(..))
import LawSpec.Testing
import LawSpec.Core.Types (makeRegistry)
import LawSpec.TestNames (unitTestNames, unitBenchmarkNames)
import LawSpec.Backend (lawCommentLines, propertyLink)
import LawSpec.SourceLink (generatedHeader, unitSourceFile, labelled, locationLink, exampleLocation, originLocation)
import LawSpec.Naming (displayLabel, claimAll, scopeWith)
import LawSpec.Swift.Code
import LawSpec.Swift.Names
import qualified LawSpec.Swift.Expr as X
import qualified LawSpec.Swift.Effects as Effects
import qualified LawSpec.Swift.Policy as Policy
import qualified LawSpec.Swift.Data as Data
import qualified LawSpec.AbilityNames as N
import qualified LawSpec.BeamGenerators as BeamGenerators
import qualified LawSpec.BeamProperties as BeamProperties
import Control.Monad (forM, foldM)
import Data.Char (isDigit)
import Data.List (nub, intercalate)

-- | The root suites: the serialized one every unit's laws run in, one at a
-- time, unless the unit's harness lets them run in parallel.
emitRootSuites :: Artifact
emitRootSuites = Artifact "tests/LawSpec/LawSpecTests.swift" (unlines
  [ "// " ++ generatedHeader Nothing
  , ""
  , "import Testing"
  , ""
  , "/// Every unit's laws, run one at a time; a unit whose harness says"
  , "/// parallel has a suite of its own, outside this one."
  , "@Suite(.serialized) struct LawSpecTests {}" ]) "generated" "test"

-- | A test file for each unit with laws.
emitTests :: D.Layout -> Bool -> Plan -> Either String [Artifact]
emitTests layout nativeGenerators plan = fmap concat $ forM (plannedUnits plan) $ \planned ->
  if null (plannedProperties planned) then pure [] else do
    let unit = plannedUnit planned
        properties = plannedProperties planned
        names = unitTestNames "swift" (map (C.propertyName . plannedProperty) properties)
    lawBodies <- concat <$> sequence [lawTests unit n p | (n, p) <- zip names properties]
    benchmarkBodies <- benchmarks unit
    let settings = C.unitHarnessSettings unit
        random = maybe False C.harnessOrderRandom settings
        parallel = maybe False C.harnessParallel settings
        bodies = lawBodies ++ benchmarkBodies
        suite = testName (C.unitId unit)
        helpers = [d | (d, Helper) <- bodies]
        tests = [(n, display, link, body) | (_, Test n display link body) <- bodies]
        skipped = [ testAttribute display <> D.hardline <>
                    D.text ("func " ++ n ++ "() throws") <> blockDoc (
                      callDoc "Harness.skip" [D.text (stringLiteral law), D.text (stringLiteral reason)] <> D.hardline <>
                      callDoc "try Test.cancel" [D.text (stringLiteral reason)])
                  | (_, SkipTest n display law reason) <- bodies ]
        testDocs
          | random =
              [ callDoc "@Test" [D.text (stringLiteral (C.idText (C.unitId unit) ++ " in the run's random order")),
                  D.text "arguments: " <> callDoc "Schedule.order" [D.text (stringLiteral suite), arrayDoc [D.text (stringLiteral n) | (n, _, _, _) <- tests]]] <> D.hardline <>
                D.text "func ordered(_ name: String) async throws" <> blockDoc (
                  D.text "try await LawThread.run" <> blockDoc (
                    D.text "switch name {" <> D.hardline <>
                    D.joinWith D.hardline [ D.text ("case " ++ stringLiteral n ++ ":") <> D.nest 2 (D.hardline <> renderStatements b) | (n, _, _, b) <- tests ] <> D.hardline <>
                    D.text "default:" <> D.nest 2 (D.hardline <> D.text "break") <> D.hardline <> D.text "}")) ]
          | otherwise = [ comment link <> testDoc n display b | (n, display, link, b) <- tests ]
        allTests = testDocs ++ skipped
        suiteDoc = D.text ("/// The laws of " ++ C.idText (C.unitId unit) ++ ".") <> D.hardline <>
          D.text ("@Suite(" ++ stringLiteral (C.idText (C.unitId unit)) ++ (if random then ", .serialized" else "") ++ ") struct " ++ suite) <>
          blockDoc (D.joinWith (D.hardline <> D.hardline) allTests)
        doc = fileHeader (generatedHeader (unitSourceFile unit)) [["import LawSpecRuntime", "import LawSpecTesting", "import Testing"], ["@testable import " ++ moduleName]] <> D.hardline <>
          D.joinWith (D.hardline <> D.hardline) helpers <> (if null helpers then mempty else D.hardline <> D.hardline) <>
          (if parallel then suiteDoc else D.text "extension LawSpecTests" <> blockDoc suiteDoc) <> D.hardline
    pure [Artifact ("tests/LawSpec/" ++ suite ++ ".swift") (D.render layout doc) "generated" "test"]
  where
    bits = planMachineBits plan
    units = map plannedUnit (plannedUnits plan)
    external = Effects.external units
    setup inner = Let "symbols" (Ty "") (Raw "SymbolContext()") (Let "schema" (Ty "") (Raw "LawSpec.Program.schema") inner)
    testDoc n display b =
      testAttribute display <> D.hardline <>
      D.text ("func " ++ n ++ "() async throws") <> blockDoc (D.text "try await LawThread.run" <> blockDoc (renderStatements b))
    benchmarks unit = do
      let measured = maybe [] C.harnessBenchmarks (C.unitHarnessSettings unit)
          names = unitBenchmarkNames (map fst measured)
      forM (zip names measured) $ \(n, (benchmarkLabel, expression)) -> do
        body <- X.render (X.Context bits X.schemaVar X.symbolsVar (\i -> error ("unbound Swift benchmark binder: " ++ C.idText i)) external X.typeRef X.typeKeyOf) expression
        handled <- Effects.withHandlers units X.schemaVar X.symbolsVar [] (const body)
        let measure = call "Harness" "benchmark" [Str (C.idText (C.unitId unit)), Str benchmarkLabel,
              Lambda [] tVoid (Do [handled] (Raw "()"))]
        pure (mempty, Test (camel n) ("benchmark " ++ benchmarkLabel) ("benchmark " ++ benchmarkLabel) (setup measure))
    lawTests unit name planned = do
      let law = plannedProperty planned
          parameters = map C.quantifiedBinder (C.propertyInputs law)
          resources = C.propertyResources law
          -- Inputs and resources keep their source names.
          sourceNames = fst (claimAll (scopeWith reservedLocals)
            (map (localName . C.binderName) (parameters ++ map C.resourceBinder resources)))
          aliases = zip (map C.binderId parameters) sourceNames
          resourceAliases = zip (map (C.binderId . C.resourceBinder) resources) (drop (length parameters) sourceNames)
          local identity = maybe (error ("unbound Swift law binder: " ++ C.idText identity)) id (lookup identity (aliases ++ resourceAliases))
          contextWith l = X.Context bits X.schemaVar X.symbolsVar l external X.typeRef X.typeKeyOf
          render = X.render (contextWith local)
          -- The law's key, as the runtime's records (failures, searches,
          -- the harness) know it; messages show it as a reader writes it.
          label = C.idText (C.unitId unit) ++ "::" ++ C.propertyName law
          shown = C.idText (C.unitId unit) ++ "::" ++ displayLabel (C.propertyName law)
          link = propertyLink law
          lawMessage = labelled shown link
          lawComment = labelled (displayLabel (C.propertyName law)) link
          harness = C.propertyHarness law
          require v = call "Runtime" "require" [v, Str lawMessage]
          -- The law's statement on its inputs, and its case: the statement
          -- in the law's handlers and resources, when it has any.
          bodyName = name
          inputs = ListOf tValues (map (Var . snd) aliases)
      body <- X.assertion lawMessage render (C.propertyBody law)
      let resourceFor ability choice = case choice of
            C.ProductionHandler -> do
              a <- N.abilityOf units ability
              t <- C.abilityResource a
              case [Var n | (r, (_, n)) <- zip resources resourceAliases, C.binderType (C.resourceBinder r) == t] of
                found : _ -> Just found
                [] -> Nothing
            C.RecordingHandler inner -> resourceFor ability inner
            C.SpecHandler _ -> Nothing
          late = [(a, c, r) | (a, c) <- C.propertyHandlers law, not (C.isFail a), Just r <- [resourceFor a c]]
          installLate sch inner = if null late then pure (inner sch) else do
            made <- mapM (\(a, c, r) -> (\f -> TupleOf [Str (C.abilityKey a), f]) <$> Effects.factoryWith units sch X.symbolsVar (Just r) a c) late
            pure (Let "withResources" tSchema (pure' "Effects" "install" [sch, ListOf (Ty "[(String, Effects.Handler)]") made]) (inner (Var "withResources")))
      let handlers = [(a, c) | (a, c) <- C.propertyHandlers law, a `notElem` [x | (x, _, _) <- late]]
          inBody s values = Call bodyName ([s, X.symbolsVar, values] ++ [ListOf tValues (map (Var . snd) resourceAliases) | not (null resources)])
          bodyDoc = function bodyName ([("schema", tSchema), ("symbols", tSymbols), ("inputs", tValues)] ++ [("resources", tValues) | not (null resources)]) tValue
            (foldr (\(i, (_, a)) rest -> Let a (Ty "") (pure' "Runtime" "item" [IntLit i, Var "inputs"]) rest)
              (foldr (\(i, (_, a)) rest -> Let a (Ty "") (pure' "Runtime" "item" [IntLit i, Var "resources"]) rest) body (zip [0 ..] resourceAliases))
              (zip [0 ..] aliases))
          -- Acquire and release around the body; nested brackets release in
          -- reverse order. ref:REQ-law-primitives
          bracket s inner = foldM (\rest r -> do
              let rendered = X.render ((contextWith local) { X.contextSchema = s })
                  binder = local (C.binderId (C.resourceBinder r))
              acquire <- rendered (C.resourceAcquire r)
              release <- rendered (C.resourceRelease r)
              case C.resourceShared r of
                Just key -> do
                  reset <- maybe (Left "a shared Swift resource requires reset") rendered (C.resourceReset r)
                  pure (call "Resources" "withShared" [Str key, Lambda [] tValue acquire, Lambda [(binder, tValue)] tValue reset,
                    Lambda [(binder, tValue)] tValue release, BoolLit (C.resourceConcurrent r), Lambda [(binder, tValue)] tValue rest])
                Nothing -> pure (call "Resources" "withResource" [Lambda [] tValue acquire, Lambda [(binder, tValue)] tValue release,
                  Lambda [(binder, tValue)] tValue rest])) inner (reverse resources)
      let scopeVar = if all (C.isFail . fst) handlers then X.schemaVar else Var "scoped"
      lateCase <- installLate scopeVar (\sch -> inBody sch (Var "inputs"))
      bracketedCase <- bracket scopeVar lateCase
      scoped <- Policy.withTestRuntime units tValue <$> Effects.withHandlers units X.schemaVar X.symbolsVar handlers (const bracketedCase)
      -- A case that is the statement alone is not a function of its own.
      let plainCase = scoped == inBody X.schemaVar (Var "inputs")
          caseName = if plainCase then bodyName else name ++ "Case"
          invoke values = Call caseName [X.schemaVar, X.symbolsVar, values]
          caseDoc = function caseName [("schema", tSchema), ("symbols", tSymbols), ("inputs", tValues)] tValue scoped
      -- A test's declaration (func name() async throws {) fits a line in
      -- its suite.
      examples <- forM (zip (exampleSuffixes (74 - length name - 1) (map C.exampleName (C.propertyExamples law))) (C.propertyExamples law)) $ \(suffix, example) -> do
        let exampleSchema = if all (C.isFail . fst) handlers then X.schemaVar else Var "scoped"
            renderIn = X.render ((contextWith local) { X.contextSchema = exampleSchema })
        arguments <- forM parameters $ \parameter -> case lookup (C.binderId parameter) (C.exampleBindings example) of
          Nothing -> Left "missing Swift example input"
          Just expression -> renderIn expression
        let exampleMessage = shown ++ " example " ++ displayLabel (C.exampleName example)
            exampleLink = locationLink <$> exampleLocation example
        expectations <- mapM (\p -> X.assertion (labelled exampleMessage (maybe exampleLink Just (expectationLink p))) renderIn p) (C.exampleExpectations example)
        lateChecks <- installLate exampleSchema (\sch -> foldr (\(a, v) rest -> Let a (Ty "") v rest)
              (Do (require (inBody sch inputs) : map require expectations) (X.bool True)) (zip (map snd aliases) arguments))
        bracketed <- bracket exampleSchema lateChecks
        inScope <- Policy.withTestRuntime units tValue <$> Effects.withHandlers units X.schemaVar X.symbolsVar handlers (const bracketed)
        pure (test (name ++ "_" ++ suffix) (displayLabel (C.propertyName law) ++ " — " ++ displayLabel (C.exampleName example))
          (labelled ("example " ++ displayLabel (C.exampleName example)) exampleLink) False
          (setup (Do [inScope] (Raw "()"))))
      let cases = maybe (boundaryCases planned) id (finiteCases planned)
          -- One enormous array expression exhausts Swift's type checker.
          -- Construct bounded portions with the original symbol context,
          -- then concatenate before the unchanged, independently indexed loop.
          caseGroups = if length cases >= 1024 && C.harnessSkip harness == Nothing then groupsOf 64 cases else []
          valuesName = name ++ "Boundaries"
          partName i = valuesName ++ "Part" ++ show i
          caseValues values = ListOf (Ty "[[Value]]") [ListOf tValues (map (X.value X.symbolsVar) row) | row <- values]
          caseHelpers = if null caseGroups then [] else
            [function (partName i) [("symbols", tSymbols)] (Ty "[[Value]]") (caseValues values) | (i,values) <- zip [0::Int ..] caseGroups] ++
            [signature ("private func " ++ valuesName) ["_ symbols: SymbolContext"] " throws -> [[Value]]" (D.joinWith D.hardline
                (D.text "var cases: [[Value]] = []" :
                  [D.text ("cases.append(contentsOf: try " ++ partName i ++ "(symbols))") | i <- [0 .. length caseGroups - 1]] ++
                  [D.text "return cases"]))]
          boundaryValues = if null caseGroups then caseValues cases else Call valuesName [X.symbolsVar]
          boundary = [ test (name ++ "_boundary") (displayLabel (C.propertyName law) ++ " boundaries") lawComment False (setup
                         (call "Property" "boundaries" [Str label, boundaryValues,
                           Lambda [("values", tValues)] tValue (invoke (Var "values"))]))
                     | not (null cases) ]
      random <- case finiteCases planned of
        Just _ -> pure [test (name ++ "_statistics") (displayLabel (C.propertyName law) ++ " statistics") lawComment True (Raw "()") | observed harness]
        Nothing -> do
          generator <- generators bits plan external local planned
          covers <- mapM (render . C.coverWhen) (C.harnessCover harness)
          classes <- forM (C.harnessClassify harness) $ \(predicate, className) -> do
            v <- render predicate
            pure (TupleOf [Str className, v])
          labels <- mapM render (C.harnessLabels harness)
          score <- maybe (pure (Raw "nil")) render (C.harnessTarget harness)
          let Generation caseCount attempts shrinks _ = C.propertyGeneration law
              config = pure' "Property" "settings" [IntLit (toInteger caseCount), IntLit (toInteger attempts), IntLit (toInteger shrinks)]
              observation = Lambda [] (Ty "Harness.Observation")
                (pure' "Harness" "observation" [ListOf tValues covers, ListOf (Ty "[(String, Value)]") classes, ListOf tValues labels, score])
              boundInputs inner = foldr (\(i, (_, a)) rest -> Let a (Ty "") (pure' "Runtime" "item" [IntLit i, Var "values"]) rest) inner (zip [0 ..] aliases)
              descriptors = BeamProperties.searchDescriptors plan planned
              remembered values = case descriptors of
                Nothing -> invoke values
                Just ds -> call "Search" "guardCase" [Str label, ListOf (Ty "[String]") (map Str ds), values, Lambda [] tValue (invoke values)]
              property = if not (observed harness) then Lambda [("values", tValues)] tValue (remembered (Var "values"))
                else Lambda [("values", tValues)] tValue (boundInputs (call "Harness" "sample" [observation, Lambda [] tValue (remembered (Var "values"))]))
          predicates <- mapM render (concatMap C.quantifiedPredicates (C.propertyInputs law))
          let inDomain body' = foldr (\p rest -> If (X.truth p) (tOptional tValue) rest (Raw "nil")) body' predicates
              replay = [ call "Search" "replay" [Str label, ListOf (Ty "[String]") (map Str ds),
                           Lambda [("values", tValues)] (tOptional tValue) (boundInputs (inDomain (invoke (Var "values"))))]
                       | Just ds <- [descriptors] ]
              check = Let "generation" (Ty "Generators.Context")
                (if nativeGenerators
                  then pure' "Property" "generationWith" [X.schemaVar, X.symbolsVar, IntLit (toInteger attempts), Raw "nativeGeneratorFactories"]
                  else pure' "Property" "generation" [X.schemaVar, X.symbolsVar, IntLit (toInteger attempts)])
                (Let "generator" (Ty "Gen<[Value]>") generator
                  (Do replay (call "Property" "check" [Str label, config, Var "generator", property])))
          searches <- case (C.harnessTarget harness, descriptors) of
            (Just target, Just ds) -> do
              scoreValue <- render target
              let climbed = Lambda [("values", tValues)] (tOptional tValue) (boundInputs (inDomain
                    (Do [require (invoke (Var "values"))] scoreValue)))
              pure [test (name ++ "_search") (displayLabel (C.propertyName law) ++ " search") lawComment False
                (setup (call "Search" "climb" [Str label, ListOf (Ty "[String]") (map Str ds), climbed]))]
            _ -> pure []
          pure ([test (name ++ "_property") (displayLabel (C.propertyName law) ++ " property") lawComment (observed harness) (setup check)] ++ searches)
      let ordinary = examples ++ boundary ++ random
          tests = case (C.harnessSkip harness, C.harnessKnownFailing harness) of
            (Just reason, _) -> [SkipTest (name ++ "_skipped") (displayLabel (C.propertyName law) ++ " skipped") label reason]
            (_, Just reason) -> [Test (name ++ "_knownFailing") (displayLabel (C.propertyName law) ++ " known failing") lawComment
              (call "Harness" "knownFailing" [Str label, Str (label ++ " known failing"), Str reason,
                ListOf (Ty "[() throws -> Void]") [Lambda [] tVoid (wrapHarness label d o harness b) | (_, d, _, o, b) <- ordinary]])]
            _ -> [Test n d c (wrapHarness label d o harness b) | (n, d, c, o, b) <- ordinary]
      let described = mconcat (map comment (lawCommentLines planned)) <> bodyDoc
      pure ((described, Helper) : [(caseDoc, Helper) | not plainCase] ++ [(doc, Helper) | doc <- caseHelpers] ++ [(mempty, t) | t <- tests])
    groupsOf _ [] = []
    groupsOf count values = let (group,rest) = splitAt count values in group : groupsOf count rest
    test n display link o body = (n, display, link, o, body)
    wrapHarness law display observations harness body
      | not observations && not (controlled harness) = body
      | otherwise = call "Harness" "run" [Str law, Str display,
          ListOf (Ty "[(Int, String)]") [TupleOf [IntLit percent, Str name'] | observations, C.Cover percent name' _ <- C.harnessCover harness],
          pure' "Harness" "options" [IntLit (C.harnessRepeat harness), IntLit (C.harnessRetries harness),
            maybe (Raw "nil") IntLit (C.harnessTimeout harness), BoolLit False, BoolLit observations],
          Lambda [] tVoid body]
    controlled h = C.harnessTimeout h /= Nothing || C.harnessRepeat h /= 1 || C.harnessRetries h /= 0
    function n params result body =
      signature ("private func " ++ n) ["_ " ++ p ++ ": " ++ t | (p, Ty t) <- params] (" throws -> " ++ tyText result) (renderBody result body)
    tyText (Ty t) = t
    -- A failing expectation points at its own line.
    expectationLink proposition = case proposition of
      C.Equation _ a _ | Just l <- originLocation (C.expressionOrigin a), take 1 (file l) /= "<" -> Just (locationLink l)
      _ -> Nothing

-- | A test's attribute, with its display name.
testAttribute :: String -> D.Doc
testAttribute display = callDoc "@Test" [D.text (stringLiteral display)]

-- | A piece of a unit's test file: a helper function, a test, or a skipped
-- law's test (recorded, then cancelled).
data Piece = Helper | Test String String String Expr | SkipTest String String String String

observed :: C.LawHarness -> Bool
observed harness = not (null (C.harnessCover harness) && null (C.harnessClassify harness) && null (C.harnessLabels harness)) ||
  C.harnessTarget harness /= Nothing

-- | The generator of a law's inputs: each input drawn knowing the earlier
-- ones, within its refinement, or from the harness's strategy for it.
generators :: Int -> Plan -> (X.Context -> C.Expr -> [Expr] -> Either String Expr) -> (C.Id -> String) -> PlannedProperty -> Either String Expr
generators bits plan external local planned = walk [] (generatorRequirements planned)
  where
    strategies = C.harnessDraws (C.propertyHarness (plannedProperty planned))
    renderWith names = X.render (X.Context bits X.schemaVar X.symbolsVar names external X.typeRef X.typeKeyOf)
    genTy = Ty "Gen<Value>"
    listGen = Ty "Gen<[Value]>"
    bind generator name body resultTy = pure' "Gens" "bind" [generator, Lambda [(name, tValue)] resultTy body]
    bindName binder name outer identity = if C.binderId binder == identity then name else outer identity
    conjunction ps = foldr (\a b -> If (X.truth a) tBool b (BoolLit False)) (BoolLit True) ps
    walk previous [] = pure (pure' "Gens" "constant" [ListOf tValues (map Var previous)])
    walk previous (requirement : rest) = do
      let binder = generatorBinder requirement
          name = local (C.binderId binder)
      generator <- case [(s, d) | (identity, s, d) <- strategies, identity == C.binderId binder] of
        [] -> regular local requirement
        (strategy, draw) : _ -> do
          generated <- strategyDraw local requirement strategy (show (length previous)) draw
          let checkedName = name ++ "Checked"
          predicates <- mapM (renderWith (bindName binder checkedName local)) (generatorPredicates requirement)
          pure (if null predicates then generated else pure' "Gens" "map" [Lambda [(checkedName, tValue)] tValue
            (call "Property" "checkDrawn" [Str strategy, Str (C.binderName binder), Var checkedName, conjunction predicates]), generated])
      remaining <- walk (previous ++ [name]) rest
      pure (bind generator name remaining listGen)
    regular names requirement = do
      generator <- raw names requirement
      predicates <- mapM (renderWith names) (generatorPredicates requirement)
      pure (if null predicates then generator else pure' "Gens" "refine"
        [Lambda [(names (C.binderId (generatorBinder requirement)), tValue)] tBool (conjunction predicates), generator])
    raw names requirement = do
      ref <- X.typeRef (C.binderType (generatorBinder requirement))
      bounds <- mapM (\(op, expression) -> (\v -> pure' "Generators" "compareBound" [Str (C.binaryName op), v]) <$> renderWith names expression)
        (nub (generatorBounds requirement ++ BeamGenerators.directBounds requirement))
      lengths <- mapM (\(op, expression) -> (\v -> pure' "Generators" "lengthBound" [Str (C.binaryName op), v]) <$> renderWith names expression)
        (BeamGenerators.lengthBounds requirement ++ BeamGenerators.nonEmptyBounds requirement)
      hints <- mapM (renderWith names) [hint | hint <- generatorHints requirement,
        C.expressionType hint == C.binderType (generatorBinder requirement)]
      index <- case generatorIndex requirement of
        Nothing -> pure (pure' "Generators" "noIndex" [])
        Just indexed -> do
          target <- renderWith names (indexedTarget indexed)
          pure (call "Generators" "index" [target, ListOf (Ty "[String]") [Str (C.idText tag) | (tag, _) <- indexedEquations indexed],
            ListOf (Ty "[[String]]") [ListOf (Ty "[String]") (map Str terms) | (_, terms) <- indexedEquations indexed]])
      pure (pure' "Generators" "generator" [Var "generation", ref, ListOf (Ty "[Generators.Bound]") (bounds ++ lengths),
        ListOf tValues (map (X.value X.symbolsVar) (generatorBoundaries requirement) ++ hints), index])
    directed quantifier witnesses = GeneratorRequirement (C.quantifiedBinder quantifier)
      (C.quantifiedPredicates quantifier) witnesses (C.quantifiedBounds quantifier) (domainHints quantifier)
      (indexedGeneration (planDataDeclarations plan) (concatMap (C.unitDefinitions . plannedUnit) (plannedUnits plan)) quantifier)
    witnessesFor ty = makeRegistry (planDataDeclarations plan) >>= \registry ->
      boundariesWithRegistry registry (planMachineBits plan) ty
    strategyDraw names requirement strategy path draw = case draw of
      C.DrawAny ty (Just aim) -> do
        let name = "aim" ++ shortPath path
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
        branches <- mapM (fmap (\v -> Lambda [] genTy (pure' "Gens" "constant" [v])) . renderWith names) values
        pure (choose path (pure' "Gens" "range" [IntLit 0, IntLit (toInteger (length values - 1))]) branches)
      C.DrawFrequency alternatives -> do
        branches <- sequence [Lambda [] genTy <$> strategyDraw names requirement strategy (path ++ "f" ++ show i) d
          | (i, (_, d)) <- zip [0 :: Int ..] alternatives]
        let selector = pure' "Gens" "frequency" [ListOf (Ty "[(Int, Gen<Int>)]")
              [TupleOf [IntLit weight, pure' "Gens" "constant" [IntLit (toInteger i)]] | (i, (weight, _)) <- zip [0 :: Int ..] alternatives]]
        pure (choose path selector branches)
      C.DrawSuchThat inner binder predicate limit -> do
        generator <- strategyDraw names requirement strategy (path ++ "s") inner
        let name = "keep" ++ shortPath path
        condition <- renderWith (bindName binder name names) predicate
        pure (pure' "Property" "suchThat" [Str strategy, Lambda [(name, tValue)] tBool (X.truth condition), IntLit limit, generator])
      C.DrawBind binder from rest -> do
        generator <- strategyDraw names requirement strategy (path ++ "from") from
        let name = "draw" ++ shortPath path
        remaining <- strategyDraw (bindName binder name names) requirement strategy (path ++ "rest") rest
        pure (bind generator name remaining genTy)
    choose path selector branches =
      let name = "choice" ++ shortPath path
      in pure' "Gens" "bind" [selector, Lambda [(name, tInt)] genTy
           (Invoke (pure' "Gens" "nth" [Var name, ListOf (Ty "[() throws -> Gen<Value>]") branches]) [])]

-- | A strategy draw's name: its depth among the strategy's nested draws.
-- A draw is inside only draws of lesser depth, so no draw hides another
-- it reads; siblings may share a name.
shortPath :: String -> String
shortPath p = show (depth (dropWhile isDigit p) :: Int)
  where
    depth s = case s of
      'f' : 'r' : 'o' : 'm' : rest -> 1 + depth rest
      'r' : 'e' : 's' : 't' : rest -> 1 + depth rest
      's' : rest -> 1 + depth rest
      'f' : rest -> 1 + depth (dropWhile isDigit rest)
      _ : rest -> depth rest
      [] -> 0

-- | The application's generators bound in lawspec.json, by type: each
-- factory gives a generator of native values, which its type's codec makes
-- portable. ref:DEC-native-bindings-typed-identity
emitNativeGenerators :: D.Layout -> Int -> [C.DataDeclaration] -> [(C.Id, [String], Int)] -> Either String [Artifact]
emitNativeGenerators _ _ _ [] = pure []
emitNativeGenerators layout bits declarations bound = do
  names <- dataNames declarations
  entries <- forM bound $ \(identity, factory, parameters) -> do
    if parameters > 0 then Left ("Swift binds generators of types without parameters: " ++ C.idText identity) else pure ()
    codecText <- Data.codec bits names [] (C.Constructor (C.idText identity) [])
    let ref = intercalate "." factory
    pure ("(" ++ stringLiteral (C.idText identity) ++ ", { (_: [Gen<Value>]) throws -> Gen<Value> in " ++ ref ++ "().map { try " ++ codecText ++ ".fromNative($0) } }),")
  let doc = fileHeader (generatedHeader Nothing) [["import LawSpecRuntime", "import LawSpecTesting"], ["@testable import " ++ moduleName]] <> D.hardline <>
        D.text "/// The application's generators, bound in lawspec.json, made afresh for each use." <> D.hardline <>
        D.text "var nativeGeneratorFactories: [(String, Generators.Factory)] {" <> D.nest 2 (D.hardline <> D.text "[" <> D.nest 2 (D.hardline <>
          D.joinWith D.hardline (map D.text entries)) <> D.hardline <> D.text "]") <> D.hardline <> D.text "}" <> D.hardline
  pure [Artifact "tests/LawSpec/NativeGenerators.swift" (D.render layout doc) "generated" "test"]
