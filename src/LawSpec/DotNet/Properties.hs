-- | Each unit's laws as xUnit tests, in F# or C#: examples, boundary cases,
-- the property over generated cases (on FsCheck), targeted search
-- and the harness's controls. The law's body is the same IR in both
-- languages. ref:DEC-typed-core-boundary ref:DEC-dotnet-fscheck
-- ref:REQ-harness-units
module LawSpec.DotNet.Properties (emitTests, testNames, emitNativeGenerators) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import LawSpec.Common (Artifact(..), Generation(..))
import LawSpec.Testing
import LawSpec.Core.Types (makeRegistry)
import LawSpec.TestNames (unitTestNames)
import LawSpec.Backend (lawCommentLines)
import LawSpec.Common (Location(..))
import LawSpec.Naming (exampleTestSuffix, displayLabel)
import LawSpec.SourceLink (generatedHeader, unitSourceFile, labelled, locationLink, exampleLocation, originLocation, sourceLink)
import Control.Applicative ((<|>))
import Data.Maybe (listToMaybe, mapMaybe)
import LawSpec.DotNet.Code
import LawSpec.DotNet.Names
import qualified LawSpec.DotNet.Expr as X
import qualified LawSpec.DotNet.Effects as Effects
import qualified LawSpec.DotNet.Policy as Policy
import qualified LawSpec.DotNet.Definitions as Definitions
import qualified LawSpec.DotNet.Data as Data
import qualified LawSpec.AbilityNames as N
import qualified LawSpec.BeamGenerators as BeamGenerators
import qualified LawSpec.BeamProperties as BeamProperties
import LawSpec.TestNames (unitBenchmarkNames)
import Control.Monad (forM, foldM)
import Data.Char (toUpper)
import Data.List (nub, intercalate)

testNames :: Lang -> [String] -> [String]
testNames FSharp labels = unitTestNames "fsharp" labels
testNames CSharp labels = unitTestNames "csharp" labels
  where capital (c : cs) = toUpper c : cs
        capital [] = []

-- | A test file for each unit with laws.
emitTests :: Lang -> D.Layout -> Bool -> Plan -> Either String [Artifact]
emitTests lang layout nativeGenerators plan = fmap concat $ forM (plannedUnits plan) $ \planned ->
  if null (plannedProperties planned) then pure [] else do
    let unit = plannedUnit planned
        properties = plannedProperties planned
        names = testNames lang (map (C.propertyName . plannedProperty) properties)
    lawBodies <- concat <$> sequence [lawTests unit n p | (n, p) <- zip names properties]
    benchmarkBodies <- benchmarks unit
    let settings = C.unitHarnessSettings unit
        random = maybe False C.harnessOrderRandom settings
        parallel = maybe False C.harnessParallel settings
        -- A parallel unit's tests each get their own class, so xUnit runs
        -- them at once; the other units share one collection and run in turn.
        bodies = if parallel then concatMap nestTest (lawBodies ++ benchmarkBodies) else lawBodies ++ benchmarkBodies
        orderer kind cls = attributeText ("Xunit." ++ kind ++ "(typeof" ++ (if lang == FSharp then "<LawSpec.Testing." ++ cls ++ ">" else "(LawSpec.Testing." ++ cls ++ ")") ++ ")")
        unitAttributes = concat [[orderer "TestMethodOrderer" "SeededMethodOrder", orderer "TestCaseOrderer" "SeededOrder"] | random] ++
          [attributeText "Xunit.Collection(\"LawSpec\")" | not parallel]
        moduleName = testModule (C.unitId unit)
        doc = case lang of
          FSharp -> D.text ("// " ++ generatedHeader (unitSourceFile unit)) <> D.hardline <>
            D.text ("/// The laws of " ++ C.idText (C.unitId unit) ++ ".") <> D.hardline <>
            mconcat [D.text a <> D.hardline | a <- unitAttributes] <>
            D.text ("module " ++ moduleName) <> D.hardline <> D.hardline <>
            D.text "open Xunit" <> D.hardline <> D.text "open LawSpec.Runtime" <> D.hardline <>
            D.text "open LawSpec.Testing" <> D.hardline <> D.hardline <>
            D.joinWith (D.hardline <> D.hardline) [d | (d, _, _) <- bodies] <> D.hardline
          CSharp -> D.text ("// " ++ generatedHeader (unitSourceFile unit)) <> D.hardline <>
            D.text ("namespace " ++ intercalate "." (init (splitDots moduleName)) ++ ";") <> D.hardline <> D.hardline <>
            D.joinWith D.hardline (map D.text (Definitions.csUsingLines ++ ["using LawSpec.Testing;", "using Xunit;"])) <> D.hardline <> D.hardline <>
            D.text ("/// <summary>The laws of " ++ C.idText (C.unitId unit) ++ ".</summary>") <> D.hardline <>
            mconcat [D.text a <> D.hardline | a <- unitAttributes] <>
            D.text ("public sealed class " ++ last (splitDots moduleName)) <> D.hardline <>
            D.block 4 (D.joinWith (D.hardline <> D.hardline) [d | (d, _, _) <- bodies]) <> D.hardline
    pure [Artifact ("tests/LawSpec/" ++ last (splitDots moduleName) ++ extension lang) (D.render layout doc) "generated" "test"]
  where
    bits = planMachineBits plan
    units = map plannedUnit (plannedUnits plan)
    external = Effects.external units
    schemaRef = Raw "LawSpec.Generated.Program.schema" "LawSpec.Generated.Program.Schema"
    setup inner = Let "symbols" tSymbols (Raw "Scalar.SymbolContext()" "new Scalar.SymbolContext()")
      (Let "schema" tSchema schemaRef inner)
    attributeText attribute = case lang of
      FSharp -> "[<" ++ attribute ++ ">]"
      CSharp -> "[" ++ attribute ++ "]"
    -- Each test of a parallel unit in a nested module (a class of its own).
    nestTest (doc, isTest, testName) = if not isTest then [(doc, isTest, testName)] else case lang of
      FSharp -> [(D.text ("module " ++ capitalFirst testName ++ " =") <> D.nest 4 (D.hardline <> doc), isTest, testName)]
      CSharp -> [(D.text ("public sealed class " ++ capitalFirst testName ++ "Test") <> D.hardline <> D.block 4 doc, isTest, testName)]
    capitalFirst (c : cs) = toUpper c : cs
    capitalFirst [] = []
    benchmarks unit = do
      let measured = maybe [] C.harnessBenchmarks (C.unitHarnessSettings unit)
          names = unitBenchmarkNames (map fst measured)
      forM (zip names measured) $ \(n, (benchmarkLabel, expression)) -> do
        body <- X.render (X.Context bits X.schemaVar X.symbolsVar (\i -> error ("unbound .NET benchmark binder: " ++ C.idText i)) external X.typeRef X.typeKeyOf) expression
        handled <- Effects.withHandlers units X.schemaVar X.symbolsVar [] (const body)
        let measure = call "Harness" "benchmark" [Str (C.idText (C.unitId unit)), Str benchmarkLabel,
              Lambda [] tUnit (Do [call "Runtime" "ignore" [handled]] UnitLit)]
        pure (declareTest (nested unit) (if lang == FSharp then camel n else pascal n) ("benchmark " ++ benchmarkLabel)
          (labelled ("benchmark " ++ benchmarkLabel) (sourceLink (C.expressionOrigin expression))) (setup measure))
    lawTests unit name planned = do
      let law = plannedProperty planned
          parameters = map C.quantifiedBinder (C.propertyInputs law)
          resources = C.propertyResources law
          -- Inputs and resources keep their source names.
          sourceNames = localNames lang generatedLocals (map C.binderName (parameters ++ map C.resourceBinder resources))
          aliases = zip (map C.binderId parameters) sourceNames
          resourceAliases = zip (map (C.binderId . C.resourceBinder) resources) (drop (length parameters) sourceNames)
          local identity = maybe (error ("unbound .NET law binder: " ++ C.idText identity)) id (lookup identity (aliases ++ resourceAliases))
          contextWith l = X.Context bits X.schemaVar X.symbolsVar l external X.typeRef X.typeKeyOf
          render = X.render (contextWith local)
          label = C.idText (C.unitId unit) ++ "::" ++ C.propertyName law
          -- Failures name the law and the source line they come from.
          shown = C.idText (C.unitId unit) ++ "::" ++ displayLabel (C.propertyName law)
          lawLink = sourceLinkOf (C.propertyLocation law)
          harness = C.propertyHarness law
          require v = call "Runtime" "require" [v, Str label]
          caseName = name ++ "Scoped"
          inputs = ListOf tValue (map (Var . snd) aliases)
      unsupported law
      body <- X.assertion (labelled shown lawLink) render (C.propertyBody law)
      -- The law's body runs on a schema with its handlers in scope; a case
      -- makes that scope, and an example makes one for its own inputs and
      -- expectations too.
      -- A native handler made with a resource (ability A with T) is made
      -- once the case has acquired its T, inside the bracket.
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
            pure (Let "withResources" tSchema (call "Effects" "install" [sch, ListOf (Ty "string * Effects.Handler" "Tuple<string, Effects.Handler>") made]) (inner (Var "withResources")))
      let bodyName = name
          handlers = [(a, c) | (a, c) <- C.propertyHandlers law, a `notElem` [x | (x, _, _) <- late]]
          inBody s values = Call (Fn bodyName bodyName) ([s, X.symbolsVar, values] ++ [ListOf tValue (map (Var . snd) resourceAliases) | not (null resources)])
          bodyDoc = private' $ function lang True bodyName ([("schema", tSchema), ("symbols", tSymbols), ("inputs", tValues)] ++ [("resources", tValues) | not (null resources)]) tValue
            (foldr (\(i, (_, a)) rest -> Let a tValue (call "Runtime" "item" [IntLit i, Var "inputs"]) rest)
              (foldr (\(i, (_, a)) rest -> Let a tValue (call "Runtime" "item" [IntLit i, Var "resources"]) rest) body (zip [0 ..] resourceAliases))
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
                  reset <- maybe (Left "a shared .NET resource requires reset") rendered (C.resourceReset r)
                  pure (call "Resources" "withShared" [Str key, Lambda [] tValue acquire, Lambda [(binder, tValue)] tValue reset,
                    Lambda [(binder, tValue)] tValue release, BoolLit (C.resourceConcurrent r), Lambda [(binder, tValue)] tValue rest])
                Nothing -> pure (call "Resources" "withResource" [Lambda [] tValue acquire, Lambda [(binder, tValue)] tValue release,
                  Lambda [(binder, tValue)] tValue rest])) inner (reverse resources)
      let scopeVar = if all (C.isFail . fst) handlers then X.schemaVar else Var "scoped"
      lateCase <- installLate scopeVar (\sch -> inBody sch (Var "inputs"))
      bracketedCase <- bracket scopeVar lateCase
      scoped <- Policy.withTestRuntime units tValue <$> Effects.withHandlers units X.schemaVar X.symbolsVar handlers (const bracketedCase)
      -- A law with no handlers, resources or policies runs its body as it is.
      let trivial = scoped == inBody X.schemaVar (Var "inputs")
          invoke values = if trivial then inBody X.schemaVar values else Call (Fn caseName caseName) [X.schemaVar, X.symbolsVar, values]
          caseDoc = [private' $ function lang True caseName [("schema", tSchema), ("symbols", tSymbols), ("inputs", tValues)] tValue scoped | not trivial]
      -- An example's test is named after the example, and linked to it.
      let exampleNames = map (suffix . camel) (exampleTestSuffix "fsharp" reservedKinds (map C.exampleName (C.propertyExamples law)))
      examples <- forM (zip3 [0 :: Int ..] exampleNames (C.propertyExamples law)) $ \(i, exampleName, example) -> do
        let exampleSchema = if all (C.isFail . fst) handlers then X.schemaVar else Var "scoped"
            renderIn = X.render ((contextWith local) { X.contextSchema = exampleSchema })
        arguments <- forM parameters $ \parameter -> case lookup (C.binderId parameter) (C.exampleBindings example) of
          Nothing -> Left "missing .NET example input"
          Just expression -> renderIn expression
        let exampleLink = locationLink <$> exampleLocation example
            context = shown ++ " example " ++ displayLabel (C.exampleName example)
        expectations <- mapM (\p -> X.assertion (labelled context (propositionLink p <|> exampleLink)) renderIn p) (C.exampleExpectations example)
        lateChecks <- installLate exampleSchema (\sch -> foldr (\(a, v) rest -> Let a tValue v rest)
              (Do (require (inBody sch inputs) : map require expectations) (X.bool True)) (zip (map snd aliases) arguments))
        bracketed <- bracket exampleSchema lateChecks
        inScope <- Policy.withTestRuntime units tValue <$> Effects.withHandlers units X.schemaVar X.symbolsVar handlers (const bracketed)
        pure (test (name ++ exampleName) (label ++ " example " ++ show i ++ ": " ++ C.exampleName example) False
          (labelled ("example " ++ displayLabel (C.exampleName example)) exampleLink) (setup (discarded inScope)))
      let cases = maybe (boundaryCases planned) id (finiteCases planned)
          boundary = [ test (name ++ suffix "boundary") (label ++ " boundary") False (labelled (displayLabel (C.propertyName law) ++ " boundary cases") lawLink) (setup
                         (call "Property" "boundaries" [Str label, ListOf tValues [ListOf tValue (map (X.value X.symbolsVar) values) | values <- cases],
                           Lambda [("values", tValues)] tValue (invoke (Var "values"))]))
                     | not (null cases) ]
      random <- case finiteCases planned of
        Just _ -> pure [test (name ++ suffix "statistics") (label ++ " statistics") True (labelled (displayLabel (C.propertyName law) ++ " statistics") lawLink) UnitLit | observed harness]
        Nothing -> do
          generator <- generators bits plan external local planned
          covers <- mapM (render . C.coverWhen) (C.harnessCover harness)
          classes <- forM (C.harnessClassify harness) $ \(predicate, className) -> do
            v <- render predicate
            pure (TupleOf [Str className, v])
          labels <- mapM render (C.harnessLabels harness)
          score <- maybe (pure (Raw "None" "FSharpOption<Value>.None")) (fmap (\v -> call "Runtime" "some" [v]) . render) (C.harnessTarget harness)
          let Generation caseCount attempts shrinks _ = C.propertyGeneration law
              config = call "Property" "settings" [IntLit (toInteger caseCount), IntLit (toInteger attempts), IntLit (toInteger shrinks)]
              observation = Lambda [] (Ty "Harness.Observation" "Harness.Observation")
                (call "Harness" "observation" [ListOf tValue covers, ListOf (Ty "string * Value" "Tuple<string, Value>") classes, ListOf tValue labels, score])
              -- Only the inputs the body reads are taken from the case.
              boundInputs inner = foldr (\(i, (_, a)) rest -> if mentions a rest then Let a tValue (call "Runtime" "item" [IntLit i, Var "values"]) rest else rest) inner (zip [0 ..] aliases)
              descriptors = BeamProperties.searchDescriptors plan planned
              remembered values = case descriptors of
                Nothing -> invoke values
                Just ds -> call "Search" "guard" [Str label, ListOf tString (map Str ds), values, Lambda [] tValue (invoke values)]
              property = if not (observed harness) then Lambda [("values", tValues)] tValue (remembered (Var "values"))
                else Lambda [("values", tValues)] tValue (boundInputs (call "Harness" "sample" [observation, Lambda [] tValue (remembered (Var "values"))]))
          predicates <- mapM render (concatMap C.quantifiedPredicates (C.propertyInputs law))
          let inDomain body = foldr (\p rest -> If (X.truth p) (tOption tValue) rest (Raw "None" "FSharpOption<Value>.None")) body predicates
              replay = [ call "Search" "replay" [Str label, ListOf tString (map Str ds),
                           Lambda [("values", tValues)] (tOption tValue) (boundInputs (inDomain (call "Runtime" "some" [invoke (Var "values")])))]
                       | Just ds <- [descriptors] ]
              check = Let "generation" (Ty "Generators.Context" "Generators.Context")
                (if nativeGenerators
                  then call "Property" "generationWith" [X.schemaVar, X.symbolsVar, IntLit (toInteger attempts),
                    Raw "LawSpec.Tests.NativeGenerators.factories" "LawSpec.Tests.NativeGenerators.Factories"]
                  else call "Property" "generation" [X.schemaVar, X.symbolsVar, IntLit (toInteger attempts)])
                (Let "generator" (Ty "Gen<Value list>" "Gen<FSharpList<Value>>") generator
                  (Do replay (call "Property" "check" [Str label, config, Var "generator", property])))
          searches <- case (C.harnessTarget harness, descriptors) of
            (Just target, Just ds) -> do
              scoreValue <- render target
              let climbed = Lambda [("values", tValues)] (tOption tValue) (boundInputs (inDomain
                    (Do [require (invoke (Var "values"))] (call "Runtime" "some" [scoreValue]))))
              pure [test (name ++ suffix "search") (label ++ " search") False (labelled (displayLabel (C.propertyName law) ++ " search") lawLink)
                (setup (call "Search" "climb" [Str label, ListOf tString (map Str ds), climbed]))]
            _ -> pure []
          pure ([test (name ++ suffix "property") (label ++ " property") (observed harness)
            (labelled (displayLabel (C.propertyName law) ++ " generated cases") lawLink) (setup check)] ++ searches)
      let ordinary = examples ++ boundary ++ random
          tests = case (C.harnessSkip harness, C.harnessKnownFailing harness) of
            (Just reason, _) -> [declareTest (nested unit) (name ++ suffix "skipped") (label ++ " skipped") (labelled (displayLabel (C.propertyName law) ++ " skipped") lawLink)
              (Do [call "Harness" "skip" [Str label, Str reason]]
                (Raw ("Assert.Skip " ++ stringLiteral FSharp reason) ("Assert.Skip(" ++ stringLiteral CSharp reason ++ ")")))]
            (_, Just reason) -> [declareTest (nested unit) (name ++ suffix "knownFailing") (label ++ " known failing") (labelled (displayLabel (C.propertyName law) ++ " known failing") lawLink)
              (call "Harness" "knownFailing" [Str label, Str (label ++ " known failing"), Str reason,
                ListOf (tFun [] tUnit) [Lambda [] tUnit (wrapHarness label d o harness b) | (_, d, o, _, b) <- ordinary]])]
            _ -> map (\(n, d, o, note, b) -> declareTest (nested unit) n d note (wrapHarness label d o harness b)) ordinary
      -- The law's description, expansion and expectations, as every target
      -- writes them beside its tests.
      let (bodyText, bodyTest, bodyName') = bodyDoc
          described = (comment (lawCommentLines planned) <> bodyText, bodyTest, bodyName')
      pure (described : caseDoc ++ tests)
    suffix kind = case lang of
      FSharp -> "_" ++ kind
      CSharp -> "_" ++ capital kind
    -- The kinds of a law's other tests, which no example's test may take.
    reservedKinds = ["boundary", "property", "statistics", "search", "skipped", "known_failing"]
    capital (c : cs) = toUpper c : cs
    capital [] = []
    test n display o note body = (n, display, o, note, body)
    -- A test: its source link, its fact and its function.
    declareTest inner n display note body = (comment [note] <> attributeLines ("Fact(DisplayName = " ++ stringLiteral lang display ++ ")") <>
      function' inner lang False n [] tUnit body, True, n)
    -- A parallel unit's tests are nested a level deeper (see nestTest).
    nested u = maybe False C.harnessParallel (C.unitHarnessSettings u)
    -- Comment lines, at the file's indentation.
    comment ls = mconcat [D.text (if null l then "//" else "// " ++ l) <> D.hardline | l <- ls]
    -- An attribute; Fantomas breaks one whose arguments end past the line's
    -- width after its first =.
    attributeLines attribute = case lang of
      FSharp | columns attribute + 1 > pageWidth, (before, '=' : ' ' : after) <- break (== '=') attribute ->
        D.text ("[<" ++ before ++ "=") <> D.nest 4 (D.hardline <> D.text (after ++ ">]")) <> D.hardline
      _ -> attributeDoc attribute <> D.hardline
    -- An example's expectations and the law's statement, without a value.
    discarded e = case e of
      Let n t v b -> Let n t v (discarded b)
      Do effects v | v == X.bool True -> Do effects UnitLit
      Do effects v -> Do effects (discarded v)
      _ -> Do [call "Runtime" "ignore" [e]] UnitLit
    private' doc = (doc, False, "")
    wrapHarness law display observations harness body
      | not observations && not (controlled harness) = body
      | otherwise = call "Harness" "run" [Str law, Str display,
          ListOf (Ty "int * string" "Tuple<int, string>") [TupleOf [IntLit percent, Str name'] | observations, C.Cover percent name' _ <- C.harnessCover harness],
          call "Harness" "options" [IntLit (C.harnessRepeat harness), IntLit (C.harnessRetries harness),
            maybe (Raw "None" "FSharpOption<int>.None") (\ms -> call "Runtime" "some" [IntLit ms]) (C.harnessTimeout harness),
            BoolLit False, BoolLit observations],
          Lambda [] tUnit body]
    controlled h = C.harnessTimeout h /= Nothing || C.harnessRepeat h /= 1 || C.harnessRetries h /= 0
    attributeDoc attribute = case lang of
      FSharp -> D.text ("[<" ++ attribute ++ ">]")
      CSharp -> D.text ("[" ++ attribute ++ "]")
    -- A test or helper function, at the indentation its file gives it: a
    -- module's top level in F#, a class's members in C#.
    function = function' False
    function' inner l private' n params result body =
      let indentation = (if l == FSharp then 0 else 4) + (if inner then 4 else 0)
          declaration = case l of
            FSharp -> "let " ++ (if private' then "private " else "") ++ n
            CSharp -> (if private' then "private static " ++ tyText CSharp result ++ " " else "public void ") ++ n
      in linesDoc indentation (functionLines l indentation declaration params result body)
    unsupported _ = pure () :: Either String ()

-- | file:line of a law, when it is written in a source.
sourceLinkOf :: Location -> Maybe String
sourceLinkOf l = if null (file l) then Nothing else Just (locationLink l)

-- | Where an expectation is written: its first located expression.
propositionLink :: C.Proposition -> Maybe String
propositionLink p = locationLink <$> listToMaybe (mapMaybe (originLocation . C.expressionOrigin) (expressions p))
  where
    expressions q = case q of
      C.Equation _ a b -> [a, b]
      C.Implication a r -> a : expressions r
      C.Conjunction ps -> concatMap expressions ps
      C.Negation r -> expressions r
      C.Quantified _ _ r -> expressions r

-- | Names generated tests give their own locals, which source names avoid.
generatedLocals :: [String]
generatedLocals = ["schema", "symbols", "inputs", "values", "resources", "generation", "generator", "scoped", "withResources", "result", "drawn", "drawnSoFar"]

observed :: C.LawHarness -> Bool
observed harness = not (null (C.harnessCover harness) && null (C.harnessClassify harness) && null (C.harnessLabels harness)) ||
  C.harnessTarget harness /= Nothing

-- | The generator of a law's inputs: each input drawn knowing the earlier
-- ones, within its refinement, or from the harness's strategy for it.
generators :: Int -> Plan -> (X.Context -> C.Expr -> [Expr] -> Either String Expr) -> (C.Id -> String) -> PlannedProperty -> Either String Expr
generators bits plan external local planned = do
  -- Each input is drawn by a step that knows the inputs drawn before it.
  steps <- walk [] (generatorRequirements planned)
  pure (call "Gen" "dependent" [ListOf (tFun [tValues] (Ty "Gen<Value>" "Gen<Value>")) steps])
  where
    strategies = C.harnessDraws (C.propertyHarness (plannedProperty planned))
    renderWith names = X.render (X.Context bits X.schemaVar X.symbolsVar names external X.typeRef X.typeKeyOf)
    genTy = Ty "Gen<Value>" "Gen<Value>"
    listGen = Ty "Gen<Value list>" "Gen<FSharpList<Value>>"
    bind generator name body resultTy = call "Gen" "bind" [generator, Lambda [(name, tValue)] resultTy body]
    bindName binder name outer identity = if C.binderId binder == identity then name else outer identity
    conjunction ps = foldr (\a b -> If (X.truth a) tBool b (BoolLit False)) (BoolLit True) ps
    walk _ [] = pure []
    walk previous (requirement : rest) = do
      let binder = generatorBinder requirement
          name = local (C.binderId binder)
      generator <- case [(s, d) | (identity, s, d) <- strategies, identity == C.binderId binder] of
        [] -> regular local requirement
        (strategy, draw) : _ -> do
          generated <- strategyDraw local requirement strategy (show (length previous)) draw
          let checkedName = name ++ "Checked"
          predicates <- mapM (renderWith (bindName binder checkedName local)) (generatorPredicates requirement)
          pure (if null predicates then generated else call "Gen" "map" [Lambda [(checkedName, tValue)] tValue
            (call "Property" "checkDrawn" [Str strategy, Str (C.binderName binder), Var checkedName, conjunction predicates]), generated])
      let earlier = foldr (\(i, n) body -> if mentions n body then Let n tValue (call "Runtime" "item" [IntLit i, Var "drawn"]) body else body)
            generator (zip [0 ..] previous)
      (Lambda [("drawn", tValues)] genTy earlier :) <$> walk (previous ++ [name]) rest
    regular names requirement = do
      generator <- raw names requirement
      predicates <- mapM (renderWith names) (generatorPredicates requirement)
      pure (if null predicates then generator else call "Gen" "refine"
        [Lambda [(names (C.binderId (generatorBinder requirement)), tValue)] tBool (conjunction predicates), generator])
    raw names requirement = do
      ref <- X.typeRef (C.binderType (generatorBinder requirement))
      bounds <- mapM (\(op, expression) -> (\v -> call "Generators" "compareBound" [Str (C.binaryName op), v]) <$> renderWith names expression)
        (nub (generatorBounds requirement ++ BeamGenerators.directBounds requirement))
      lengths <- mapM (\(op, expression) -> (\v -> call "Generators" "lengthBound" [Str (C.binaryName op), v]) <$> renderWith names expression)
        (BeamGenerators.lengthBounds requirement ++ BeamGenerators.nonEmptyBounds requirement)
      hints <- mapM (renderWith names) [hint | hint <- generatorHints requirement,
        C.expressionType hint == C.binderType (generatorBinder requirement)]
      index <- case generatorIndex requirement of
        Nothing -> pure (call "Generators" "noIndex" [])
        Just indexed -> do
          target <- renderWith names (indexedTarget indexed)
          pure (call "Generators" "index" [target, ListOf tString [Str (C.idText tag) | (tag, _) <- indexedEquations indexed],
            ListOf (tList tString) [ListOf tString (map Str terms) | (_, terms) <- indexedEquations indexed]])
      pure (call "Generators" "generator" [Var "generation", ref, ListOf (Ty "Generators.Bound" "Generators.Bound") (bounds ++ lengths),
        ListOf tValue (map (X.value X.symbolsVar) (generatorBoundaries requirement) ++ hints), index])
    directed quantifier witnesses = GeneratorRequirement (C.quantifiedBinder quantifier)
      (C.quantifiedPredicates quantifier) witnesses (C.quantifiedBounds quantifier) (domainHints quantifier)
      (indexedGeneration (planDataDeclarations plan) (concatMap (C.unitDefinitions . plannedUnit) (plannedUnits plan)) quantifier)
    witnessesFor ty = makeRegistry (planDataDeclarations plan) >>= \registry ->
      boundariesWithRegistry registry (planMachineBits plan) ty
    strategyDraw names requirement strategy path draw = case draw of
      C.DrawAny ty (Just aim) -> do
        let name = "aim" ++ show (length path)
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
        branches <- mapM (fmap (\v -> Lambda [] genTy (call "Gen" "constant" [v])) . renderWith names) values
        pure (choose path (call "Gen" "range" [IntLit 0, IntLit (toInteger (length values - 1))]) branches)
      C.DrawFrequency alternatives -> do
        branches <- sequence [Lambda [] genTy <$> strategyDraw names requirement strategy (path ++ "f" ++ show i) d
          | (i, (_, d)) <- zip [0 :: Int ..] alternatives]
        let selector = call "Gen" "frequency" [ListOf (Ty "int * Gen<int>" "Tuple<int, Gen<int>>")
              [TupleOf [IntLit weight, call "Gen" "constant" [IntLit (toInteger i)]] | (i, (weight, _)) <- zip [0 :: Int ..] alternatives]]
        pure (choose path selector branches)
      C.DrawSuchThat inner binder predicate limit -> do
        generator <- strategyDraw names requirement strategy (path ++ "s") inner
        let name = "keep" ++ show (length path)
        condition <- renderWith (bindName binder name names) predicate
        pure (call "Property" "suchThat" [Str strategy, Lambda [(name, tValue)] tBool (X.truth condition), IntLit limit, generator])
      -- A run of draws, each knowing the earlier ones, is drawn in turn
      -- (Gen.dependent), then the rest knowing them all.
      C.DrawBind _ _ _ -> do
        let chain d = case d of
              C.DrawBind b from more -> let (bs, final) = chain more in ((b, from) : bs, final)
              other -> ([], other)
            (links, final) = chain draw
            names' = ["draw" ++ show (length path) ++ "_" ++ show k | k <- [1 .. length links]]
            scope = foldl (\outer (b, n) -> bindName b n outer) names (zip (map fst links) names')
            earlier body bound = foldr (\(k, n) rest -> if mentions n rest then Let n tValue (call "Runtime" "item" [IntLit k, Var "drawnSoFar"]) rest else rest)
              body (zip [0 ..] bound)
        steps <- forM (zip3 [0 :: Int ..] links names') $ \(k, (_, from), _) -> do
          let visible = foldl (\outer (b, n) -> bindName b n outer) names (take k (zip (map fst links) names'))
          generator <- strategyDraw visible requirement strategy (path ++ "from" ++ show k) from
          pure (Lambda [("drawnSoFar", tValues)] genTy (earlier generator (take k names')))
        remaining <- strategyDraw scope requirement strategy (path ++ "rest") final
        pure (call "Gen" "bind" [call "Gen" "dependent" [ListOf (tFun [tValues] genTy) steps],
          Lambda [("drawnSoFar", tValues)] genTy (earlier remaining names')])
    choose path selector branches =
      let name = "choice" ++ show (length path)
      in call "Gen" "bind" [selector, Lambda [(name, tInt)] genTy
           (Invoke (call "Runtime" "nth" [Var name, ListOf (tFun [] genTy) branches]) [])]

-- | The application's generators bound in lawspec.json, by type: each
-- factory gives an FsCheck Arbitrary of native values, kept with its own
-- shrinker, which its type's codec makes portable. They
-- compile before the tests, after the test project's Native/ code.
-- ref:DEC-native-bindings-typed-identity
emitNativeGenerators :: Lang -> D.Layout -> Int -> [C.DataDeclaration] -> [(C.Id, [String], Int)] -> Either String [Artifact]
emitNativeGenerators _ _ _ _ [] = pure []
emitNativeGenerators lang layout bits declarations bound = do
  names <- dataNames declarations
  entries <- forM bound $ \(identity, factory, parameters) -> do
    if parameters > 0 then Left (".NET binds generators of types without parameters: " ++ C.idText identity) else pure ()
    codec <- Data.codec lang bits names [] (C.Constructor (C.idText identity) [])
    let ref = intercalate "." factory
    pure $ case lang of
      FSharp -> "(" ++ stringLiteral FSharp (C.idText identity) ++ ", (fun (_: Gen<Value> list) -> Gen.map " ++ codec ++ ".FromNative (Gen.ofArbitrary (" ++ ref ++ " ()))))"
      CSharp -> "Fn.Tuple(" ++ stringLiteral CSharp (C.idText identity) ++ ", Fn.F1((FSharpList<Gen<Value>> _) => Gen.Map(" ++ codec ++ ".FromNative, Gen.OfArbitrary(" ++ ref ++ "()))))"
  let doc = case lang of
        FSharp -> D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
          D.text "/// The application's generators, bound in lawspec.json." <> D.hardline <>
          D.text "module LawSpec.Tests.NativeGenerators" <> D.hardline <> D.hardline <>
          D.text "open LawSpec.Runtime" <> D.hardline <> D.text "open LawSpec.Testing" <> D.hardline <> D.hardline <>
          D.text "let factories : (string * Generators.Factory) list =" <> D.nest 4 (D.hardline <>
            D.text "[ " <> D.joinWith (D.hardline <> D.text "  ") (map D.text entries) <> D.text " ]") <> D.hardline
        CSharp -> D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
          D.text "namespace LawSpec.Tests;" <> D.hardline <> D.hardline <>
          D.joinWith D.hardline (map D.text (Definitions.csUsingLines ++ ["using LawSpec.Testing;"])) <> D.hardline <> D.hardline <>
          D.text "/// <summary>The application's generators, bound in lawspec.json.</summary>" <> D.hardline <>
          D.text "public static class NativeGenerators" <> D.hardline <>
          D.block 4 (D.text "public static FSharpList<Tuple<string, FSharpFunc<FSharpList<Gen<Value>>, Gen<Value>>>> Factories =>" <> D.nest 4 (D.hardline <>
            D.text "Fn.List(" <> D.joinWith (D.text "," <> D.hardline <> D.text "    ") (map D.text entries) <> D.text ");")) <> D.hardline
  pure [Artifact ("tests/LawSpec/NativeGenerators" ++ extension lang) (D.render layout doc) "generated" "test"]
