-- | Kotlin test documents consume checked propositions and native generation
-- plans. The tests are laid out as ktfmt's kotlinlang style lays them out
-- (LawSpec.KotlinLayout), keep the source's binder names, and use the
-- runtime's assertions, configuration and generators (LawSpecTesting,
-- LawSpecScalars), so a test file holds only its laws.
-- ref:DEC-readable-output-default
module LawSpec.KotlinProperties (Config(..), emitTests) where

import LawSpec.Bounds (inputRange, drawRange)
import qualified LawSpec.Core as C
import Control.Monad (foldM)
import Data.Char (isAlphaNum)
import LawSpec.Backend
import LawSpec.Common
import LawSpec.TestNames (unitTestNames)
import LawSpec.Testing
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.KotlinExpr as E
import qualified LawSpec.KotlinLayout as L
import LawSpec.KotlinTestHelpers (scalarGenerators)
import LawSpec.JvmNames (exampleTestNames, boundaryTestName, contractMethod)
import LawSpec.Naming (displayLabel)
import LawSpec.SourceLink (generatedHeader, labelled, locationLink, originLocation, exampleLocation)
import Data.List (intercalate, sort, stripPrefix, nub)

-- | What the Kotlin test emitter needs besides the plan: names, layout and
-- bindings, gathered so the emitter takes one argument.
data Config = Config
  { packageName :: String
  -- An async adapter's call, awaited.
  , awaitResult :: String -> D.Doc -> D.Doc
  , className :: String
  , constructorContracts :: Bool
  , nativeGenerators :: Bool
  , nodeBudget :: Integer
  , machineBits :: Int
  , expression :: Expr -> D.Doc
  , literal :: V.Value -> Either [Diagnostic] D.Doc
  , checked :: Type -> D.Doc -> D.Doc
  , structural :: Type -> Bool
  , reference :: Type -> D.Doc
  , typeKey :: Type -> String
  , generator :: Type -> D.Doc
  -- A generator drawing a top-level integer from a refinement's range.
  , generatorWithin :: Maybe (Integer, Integer) -> Type -> D.Doc
  , nativeArgument :: Type -> D.Doc -> D.Doc
  , nativeResult :: Type -> D.Doc -> D.Doc
  -- The statements that install a law's handlers in symbols, for each case.
  , handlerInstalls :: Expanded -> [D.Doc]
  -- The native handlers made with a resource, installed once the case has
  -- acquired its resources.
  , lateHandlerInstalls :: Expanded -> [D.Doc]
  -- Each input's descriptor, for LawSpec's own search (LawSpec.Search):
  -- Nothing when the law takes no part in it.
  , searchDescriptors :: Expanded -> Maybe [String]
  -- A binder's identifier: its source name (LawSpec.JvmNames).
  , local :: C.Id -> String
  -- The specification the unit is written in, relative to the project.
  , sourceFile :: Maybe String
  -- The codecs the file names as values: name and codec.
  , codecValues :: [(String, D.Doc)]
  }

text :: String -> D.Doc
text = D.text
statements :: [D.Doc] -> D.Doc
statements = L.statements
separate :: [D.Doc] -> D.Doc
separate = D.joinWith (D.hardline <> D.hardline)
call :: String -> [D.Doc] -> D.Doc
call = L.call
quoted :: String -> D.Doc
quoted = L.kotlinString
number :: Show a => a -> D.Doc
number = text . show
bind :: String -> D.Doc -> D.Doc
bind = L.bind
runtime :: String -> [D.Doc] -> D.Doc
runtime name = call ("LawSpecRuntime." ++ name)
truth :: D.Doc -> D.Doc
truth value = runtime "truth" [value]
-- | Conditions joined, broken after each operator, as ktfmt breaks them.
conjunction :: [D.Doc] -> D.Doc
conjunction [] = text "true"
conjunction xs = L.operators "&&" xs
-- | header { body }, the body on lines of its own.
braced :: D.Doc -> [D.Doc] -> D.Doc
braced header body = header <> text " " <> L.block body
symbols :: D.Doc
symbols = text "val symbols = mutableMapOf<String, Any>()"
testType :: String
testType = "suspend TestScope.() -> kotlin.Unit"

-- | Laws become tests in Kotlin's own property framework, so they run with the
-- tools the project already uses. ref:DEC-native-property-frameworks
emitTests :: Config -> Unit -> [Expanded] -> Either [Diagnostic] D.Doc
emitTests Config{..} unit laws = do
  let testNames = unitTestNames "kotlin" (map name laws)
  generated <- mapM (law testNames) (zip [0::Int ..] laws)
  let lawDocs = map snd generated
      sharedCases = concatMap fst generated
      -- The JVM limits a method's bytecode to 64 KiB. Each law registers
      -- its tests in a function of its own, given the function that
      -- registers one test, so seeded ordering still collects them all.
      registrations = [(n, doc) | (n, doc) <- zip lawFunctions (lawDocs ++ map benchmark benchmarks)]
      lawFunctions = uniqueFunctions (map (functionName . name) laws ++ ["benchmark" ++ capital (functionName n) | (n, _) <- benchmarks])
      registration (n, doc) = braced (L.callWith (text ("private fun StringSpec." ++ n)) [text ("register: (String, " ++ testType ++ ") -> kotlin.Unit")])
        [text ("operator fun String.invoke(test: " ++ testType ++ ") = register(this, test)"), doc]
      register (n, _) = text (n ++ " { name, test -> name(test) }")
      specBody = separate (statements (text "LawSpecRuntime.useVirtualClock(0)" :
          [text "lawspec.Time.registerClock()" | installsClock unit]) :
        [call "lawspec.testing.LawSpecHarness.parallelism" [quoted unitLabel, quoted "coroutines on a thread per processor (Kotest concurrency)",
           text "Runtime.getRuntime().availableProcessors()"] | parallel] ++
        ordered (map register registrations))
      spec = text ("class " ++ className ++ "LawSpecTest :") <> D.nest 4 (D.hardline <>
        text "StringSpec({" <> D.nest 4 (D.hardline <> specBody) <> D.hardline <> text "})") <>
        -- parallel: Kotest runs the tests concurrently, on as many threads
        -- as processors.
        (if parallel then text " " <> L.block [separate
          [text "override fun concurrency(): Int = Runtime.getRuntime().availableProcessors()",
           text "@Suppress(\"OVERRIDE_DEPRECATION\")" <> D.hardline <> text "override fun threads(): Int = Runtime.getRuntime().availableProcessors()"]]
         else mempty)
      members = [text "// The machine profile's integer width." <> D.hardline <> text ("private const val MACHINE_BITS = " ++ show machineBits)] ++
        [text "private val SCHEMA = LawSpecDataSchema.create()" | usesSchema] ++
        [L.statements [bind' n codec | (n, codec) <- codecs] | not (null codecs)] ++
        map contract (contracts unit) ++ sharedCases ++ [spec] ++ map registration registrations
      code = D.render D.Compact (separate (map snd registrations ++ sharedCases ++ map contract (contracts unit)))
      codecs = [(n, codec) | (n, codec) <- codecValues, n `elem` identifiers code]
      bind' n codec = D.group (text ("private val " ++ n ++ " =") <> D.nest 4 (D.softline <> codec))
      usesSchema = "SCHEMA" `elem` identifiers (code ++ " " ++ concatMap (D.render D.Compact . snd) codecs)
      body = separate members
      rendered = D.render D.Compact body
      imports = sort (nub [i | i <- candidateImports, simpleName i `elem` identifiers rendered])
  pure $ text ("// " ++ generatedHeader sourceFile) <> D.hardline <>
    (if null packageName then mempty else text ("package " ++ packageName) <> D.hardline <> D.hardline) <>
    (if null imports then mempty else statements [text ("import " ++ i) | i <- imports] <> D.hardline <> D.hardline) <>
    body <> D.hardline
  where
    -- Binders keep their source names (LawSpec.JvmNames).
    inputId = local . C.binderId . C.quantifiedBinder
    localName = local
    bindings ex = [(local i, v) | (i, v) <- C.exampleBindings ex]
    contractArguments c = [(local (C.binderId b), C.binderType b) | b <- C.contractArguments c]
    contractResult c = let b = C.contractResult c in (local (C.binderId b), C.binderType b)
    fromValues xs = statements [bind (inputId input) (text ("values[" ++ show index ++ "]")) |
      (index,input) <- zip [0::Int ..] xs]
    -- The names code uses, outside its string literals and comments.
    identifiers = words . map (\c -> if isAlphaNum c || c == '_' then c else ' ') . outsideStrings
    outsideStrings s = case s of
      '"' : rest -> ' ' : inString rest
      '/' : '/' : rest -> outsideStrings (dropWhile (/= '\n') rest)
      c : rest -> c : outsideStrings rest
      [] -> []
    inString s = case s of
      '\\' : _ : rest -> inString rest
      '"' : rest -> outsideStrings rest
      _ : rest -> inString rest
      [] -> []
    simpleName = reverse . takeWhile (/= '.') . reverse
    candidateImports =
      [ "io.kotest.core.spec.style.StringSpec", "io.kotest.core.test.TestScope", "io.kotest.property.checkAll", "io.kotest.property.Arb"
      , "lawspec.runtime.LawSpecRuntime", "lawspec.runtime.LawSpecSchema", "lawspec.runtime.LawSpecDataSchema"
      , "lawspec.runtime.LawSpecDataCodecs", "lawspec.runtime.LawSpecKotlinCodecs", "lawspec.testing.LawSpecKotlinStrategies"
      , "lawspec.testing.LawSpecScalars", "lawspec.testing.LawSpecTesting"
      , "lawspec.testing.lawspecFlatMap", "lawspec.testing.lawspecList", "lawspec.testing.lawspecChoice" ] ++
      map ("io.kotest.property.arbitrary." ++) ["int","map","bind","filter","constant","element"]
    -- A case's handlers and fixtures are in symbols; a case with neither
    -- does not make it.
    withSymbols docs = if "symbols" `elem` identifiers (D.render D.Compact (statements docs)) then symbols : docs else docs
    -- Readable text about a law: its label and source line.
    shownLaw e = owner e ++ "::" ++ displayLabel (name e)
    lawLink e = let l = location (original e) in if null (file l) then Nothing else Just (locationLink l)
    linked e text' = labelled text' (lawLink e)
    capital (c : cs) = toEnum (fromEnum c - (if c >= 'a' && c <= 'z' then 32 else 0)) : cs
    capital [] = []
    -- A law's registration function: its test name.
    functionName label = case unitTestNames "kotlin" [label] of
      n : _ -> n
      [] -> "law"
    uniqueFunctions = go []
      where
        go _ [] = []
        go seen (n : rest) = let chosen = head [c | c <- n : [n ++ show k | k <- [2 :: Int ..]], c `notElem` seen]
                             in chosen : go (chosen : seen) rest
    benchmarks = maybe [] C.harnessBenchmarks settings
    -- The harness plane (LawSpec.Harness). A test the harness runs is a
    -- suspending function value (harness:name), which the generated test
    -- passes to the runtime shared with Java.
    settings = C.unitHarnessSettings unit
    orderRandom = maybe False C.harnessOrderRandom settings
    parallel = maybe False C.harnessParallel settings
    unitLabel = C.idText (C.unitId unit)
    -- order random: LawSpec registers the unit's tests in an order the
    -- run's seed chooses. A local String.invoke collects them, and they are
    -- registered, shuffled, after the block that declares them.
    ordered docs
      | orderRandom =
          [ text ("val tests = mutableListOf<Pair<String, " ++ testType ++ ">>()")
          , braced (text "run")
              [L.equalsBody (text ("operator fun String.invoke(test: " ++ testType ++ ")")) (text "tests.add(this to test)"), separate docs]
          , braced (text "for ((name, test) in " <> call "lawspec.testing.LawSpecHarness.shuffled" [quoted unitLabel, text "tests"] <> text ")")
              [text "name(test)"] ]
      | otherwise = docs
    testFunction testName body = case stripPrefix "harness:" testName of
      Just rest -> text ("val " ++ harnessValue (takeWhile (/= ':') rest) ++ ": suspend () -> kotlin.Unit = ") <> L.lambda [] body
      Nothing -> quoted testName <> text " " <> L.lambda [] body
    harnessValue rest = "harness" ++ capital (filter (\c -> isAlphaNum c) rest)
    runSettings h = C.harnessTimeout h /= Nothing || C.harnessRepeat h /= 1 || C.harnessRetries h /= 0 || observed h
    observed h = not (null (C.harnessCover h) && null (C.harnessClassify h) && null (C.harnessLabels h)) || C.harnessTarget h /= Nothing
    harness name' = call ("lawspec.testing.LawSpecHarness." ++ name')
    harnessBody name' = text "lawspec.testing.LawSpecHarness.Body " <>
      L.lambda [] [text "kotlinx.coroutines.runBlocking " <> L.lambda [] [text (name' ++ "()")]]
    observations e =
      let h = C.propertyHarness (original e)
          label = owner e ++ "::" ++ name e
      in [harness "observe" [quoted label,
            call "arrayOf<String>" [quoted l | C.Cover _ l _ <- C.harnessCover h], call "booleanArrayOf" [truth (expr w) | C.Cover _ _ w <- C.harnessCover h],
            call "arrayOf<String>" [quoted l | (_, l) <- C.harnessClassify h], call "booleanArrayOf" [truth (expr c) | (c, _) <- C.harnessClassify h],
            call "arrayOf<LawSpecRuntime.Value>" (map expr (C.harnessLabels h))] | observed h] ++
         [harness "target" [expr score, quoted label] | Just score <- [C.harnessTarget h]]
    -- The tests a law's harness wraps, skips or expects to fail.
    harnessTests fn label h kinds docs = case (C.harnessSkip h, C.harnessKnownFailing h) of
      (Just reason, _) -> [D.group (quoted (fn ++ "_skipped: " ++ label) <> D.nest 4 (D.softbreak <> text ".config(enabled = false) " <> L.block [text ("// " ++ reason)]))]
      (_, Just reason) -> docs ++ [quoted (fn ++ "_knownFailing: " ++ label) <> text " " <> L.lambda [] [harness "knownFailing"
        [quoted label, quoted (fn ++ "_knownFailing"), quoted reason, call "listOf" [harnessBody (harnessValue (fn ++ k)) | k <- kinds]]]]
      _ | runSettings h -> docs ++ [quoted (fn ++ k ++ (if k == "_property" then ": " ++ label else "")) <> text " " <> L.lambda [] [harness "run"
            [quoted label, quoted (fn ++ k), number (maybe 0 id (C.harnessTimeout h)), number (C.harnessRepeat h), number (C.harnessRetries h),
             call "intArrayOf" [number p | k == "_property", C.Cover p _ _ <- C.harnessCover h],
             call "arrayOf<String>" [quoted l | k == "_property", C.Cover _ l _ <- C.harnessCover h],
             text (if k == "_property" && observed h then "true" else "false"), harnessBody (harnessValue (fn ++ k))]] | k <- kinds]
        | otherwise -> docs
    benchmark (n, b) = quoted ("benchmark " ++ n) <> text " " <> L.lambda [] (withSymbols
      [harness "benchmark" [quoted n, text "lawspec.testing.LawSpecHarness.Body " <> L.lambda [] [bind "measured" (expr b)]]])
    -- A property whose inputs harness strategies draw, from Kotest's
    -- random source; their values' refinements are checked in the property.
    harnessProperty fn label e check = do
      let h = C.propertyHarness (original e)
          strategyOf inp = [(n, d) | (i, n, d) <- C.harnessDraws h, i == C.binderId (C.quantifiedBinder inp)]
      draws <- mapM (\plan -> do
        let inp = domainInput plan
        case strategyOf inp of
          (strategy, d) : _ -> bind (inputId inp) <$> drawDoc inp strategy d
          [] -> pure (bind (inputId inp) (sampled (generatorWithin (inputRange machineBits inp) (inputType inp))))) (generationPlan e)
      let defaults = [inp | inp <- inputs e, null (strategyOf inp)]
          strategyChecks = [harness "checkDrawn" [quoted strategy, quoted (inputName inp),
              conjunction (map (truth . expr) (inputRefinements inp)), text (inputId inp)]
            | inp <- inputs e, (strategy, _) : _ <- [strategyOf inp], not (null (inputRefinements inp))]
          base = L.trailing (text "io.kotest.property.arbitrary.arbitrary") ["random"]
            ([symbols] ++ draws ++ [call "Pair" [call "listOf" [text (inputId inp) | inp <- inputs e], text "symbols"]])
          predicates = concatMap inputRefinements defaults
          bindingsDoc = [text "val symbols = inputs.second", text "val values = inputs.first", fromValues (inputs e)]
          strategy = if null predicates then base else L.trailingCall "LawSpecTesting.filter" [base] ["inputs"]
            (bindingsDoc ++ [conjunction (map (truth . expr) predicates)])
      pure $ testFunction (fn ++ "_property: " ++ label) [L.trailingCall "checkAll" [call "LawSpecTesting.config" [number (cases (generation e))], strategy] ["inputs"]
        (bindingsDoc ++ strategyChecks ++ handlerInstalls e ++ [check])]
    -- A generator's value drawn from the property's random source.
    sampled gen = L.selects gen [L.call ".sample" [text "random"], text ".value"]
    chooser = text "java.util.function.IntUnaryOperator " <> L.lambda ["count"] [text "random.random.nextInt(count)"]
    supplier doc = text "java.util.function.Supplier " <> L.lambda [] [doc]
    drawDoc inp strategy d = case d of
      C.DrawAny ty aim -> pure (sampled (maybe (generator ty) (\range -> generatorWithin (Just range) ty) (drawRange machineBits inp ty aim)))
      C.DrawOneOf _ values -> pure (harness "oneOf" [chooser, call "listOf" [supplier (expr v) | v <- values]])
      C.DrawFrequency alternatives -> do
        options <- mapM (\(w, a) -> (\doc -> harness "Weighted" [number w, supplier doc]) <$> drawDoc inp strategy a) alternatives
        pure (harness "frequency" [chooser, call "listOf" options])
      C.DrawSuchThat inner binder predicate limit -> do
        doc <- drawDoc inp strategy inner
        pure (harness "suchThat" [supplier doc,
          text "java.util.function.Predicate<LawSpecRuntime.Value> " <> L.lambda [localName (C.binderId binder)] [truth (expr predicate)],
          number limit, quoted strategy])
      C.DrawBind binder from rest -> do
        fromDoc <- drawDoc inp strategy from
        restDoc <- drawDoc inp strategy rest
        pure (L.trailing (text "run") [] [bind (localName (C.binderId binder)) fromDoc, restDoc])
    expr = expression
    -- An assertion names its law and case and points at the source line of
    -- what it checks; the expectation itself is in the law's comment.
    assertionDoc context = contextualAssertion (const (quoted context))
    contextualAssertion context proposition = case proposition of
      AssertAll ps -> statements (map (contextualAssertion context) ps)
      AssertImplies guard body -> braced (L.condition "if" (truth (expr guard))) [contextualAssertion context body]
      AssertEqual a b ->
        let message = context (expressionLink a)
            sides = [L.lambda [] [expr a], L.lambda [] [expr b]]
        in if structural (expressionType a)
          then call "LawSpecTesting.check" ([message, text "SCHEMA", reference (expressionType a), text "MACHINE_BITS", text "symbols"] ++ sides)
          else call "LawSpecTesting.check" (message : sides)
    expressionLink a = case originLocation (C.expressionOrigin a) of
      Just l | take 1 (file l) /= "<" -> Just (locationLink l)
      _ -> Nothing
    contract c =
      let args = contractArguments c
          (rn,rt) = contractResult c
          params = text "symbols: MutableMap<String, Any>" : [text (n ++ ": LawSpecRuntime.Value") | (n,_) <- args]
          context stage ps = quoted (contractName c ++ " " ++ stage ++ ": " ++ intercalate " && " (map prettyExpr ps))
          require stage ps = runtime "requireContract" [conjunction (map (truth . expr) ps),context stage ps]
          invocation = awaitResult (adapterName unit (C.contractDeclaration c)) (call (className ++ "." ++ adapterName unit (C.contractDeclaration c)) [nativeArgument ty (text n) | (n,ty) <- args])
      in braced (call ("private fun " ++ contractMethod (contractName c)) params <> text ": LawSpecRuntime.Value")
          [require "precondition" (contractPreconditions c),
           bind rn (nativeResult rt invocation),require "postcondition" (contractPostconditions c),text "return " <> text rn]
    tryFinally inner final = braced (text "try") [inner] <> text " finally " <> L.block [final]
    -- A law's resources: each case acquires them, then runs, then releases
    -- them, the last first, even when the case fails.
    bracketed e docs = foldr wrap (statements (lateHandlerInstalls e ++ docs)) (C.propertyResources (original e))
      where
        -- A shared resource (share R per ...): the runtime keeps one per
        -- scope key, resets it before each later use, and releases it when
        -- the JVM exits. Each piece runs blocking, as it may suspend.
        wrap r inner | Just key <- C.resourceShared r, Just reset <- C.resourceReset r =
          let resource = localName (C.binderId (C.resourceBinder r))
              blocking body = L.trailing (text "kotlinx.coroutines.runBlocking") [] [body]
          in statements [bind resource (runtime "share" [quoted key, L.lambda [] [blocking (expr (C.resourceAcquire r))],
              L.lambda [resource] [blocking (expr reset)], L.lambda [resource] [blocking (expr (C.resourceRelease r))],
              text (if C.resourceConcurrent r then "true" else "false")]),
            tryFinally inner (runtime "unshare" [quoted key])]
        wrap r inner =
          let resource = localName (C.binderId (C.resourceBinder r))
          in statements [bind resource (expr (C.resourceAcquire r)),
            tryFinally inner (expr (C.resourceRelease r))]
    law testNames (index,e) = do
      let label = owner e ++ "::" ++ name e
          shown = shownLaw e
          h = C.propertyHarness (original e)
          base' = testNames !! index
          fn = (if C.harnessSkip h == Nothing && (C.harnessKnownFailing h /= Nothing || runSettings h) then "harness:" else "") ++ base'
          boundaryCount = length (maybe (boundaryCases e) id (finiteCases e))
          exampleSuffixes = exampleTestNames ("property" : "skipped" : "knownFailing" : "replay" : "search" :
            map boundaryTestName [0 .. boundaryCount - 1]) (map exampleName (examples (original e)))
          exampleContext ex = shown ++ " example " ++ displayLabel (exampleName ex)
      exampleDocs <- mapM (\(suffix,ex) -> pure $ D.lineComment 96 "// " (labelled ("example " ++ displayLabel (exampleName ex))
          (fmap locationLink (exampleLocation ex))) <>
        testFunction (fn ++ "_" ++ suffix) (withSymbols
        (handlerInstalls e ++ [bind n (expr v) | (n,v) <- bindings ex] ++
        [bracketed e (map (contextualAssertion (\l -> quoted (labelled (exampleContext ex) l))) (expectations ex) ++
          [contextualAssertion (const (quoted (linked e shown))) (assertion e)])]))) (zip exampleSuffixes (examples (original e)))
      boundaryValues <- mapM (mapM literal) (maybe (boundaryCases e) id (finiteCases e))
      -- Share large handler-bound assertions before registration is chunked:
      -- repeated bodies can overflow the JVM constant pool below 1,024 cases.
      let sharedBoundaries = length boundaryValues >= 64
          helper = functionName (name e) ++ "Boundary"
          names = map inputId (inputs e) ++ [localName (C.binderId (C.resourceBinder resource)) | resource <- C.propertyResources (original e)]
          valuesArray = call "arrayOf<LawSpecRuntime.Value>" (map text names)
          boundaryDocs = [testFunction (fn ++ "_" ++ boundaryTestName i) $ withSymbols
            (handlerInstalls e ++ [bind (inputId inp) (checked (inputType inp) v) | (inp,v) <- zip (inputs e) values] ++
            [bracketed e [if sharedBoundaries then call helper [quoted context, text "symbols", valuesArray]
            else assertionDoc context (assertion e)]]) | (i,values) <- zip [0::Int ..] boundaryValues
            , let context = linked e (shown ++ " boundary " ++ show (i + 1))]
          sharedDocs = [braced (call ("private suspend fun " ++ helper)
              [text "context: String", text "symbols: MutableMap<String, Any>", text "values: Array<LawSpecRuntime.Value>"])
            ([bind n (text ("values[" ++ show i ++ "]")) | (i,n) <- zip [0::Int ..] names] ++
              [contextualAssertion (const (text "context")) (assertion e)]) | sharedBoundaries, C.harnessSkip h == Nothing]
      -- LawSpec's own search (LawSpec.Search): the failure database's
      -- inputs are replayed before the law's generated cases, a failing
      -- case's inputs are kept, and a law with `target maximize` climbs
      -- after them, as Kotest has no targeting.
      let descriptors = searchDescriptors e
          inputsName = "searchInputs"
          caseName = "searchCase"
          remembered doc = case descriptors of
            Nothing -> doc
            Just _ -> braced (text "try") [doc] <> text " catch (error: Throwable) " <> L.block
              [runtime "searchRemember" [quoted label, text inputsName, call "listOf" [text (inputId inp) | inp <- inputs e]], text "throw error"]
          searchCase = text "LawSpecRuntime.SearchCase " <> L.lambda ["values"]
            [L.trailing (text "kotlinx.coroutines.runBlocking") [] [call caseName [text "values"]]]
          (searchBefore, searchAfter) = case descriptors of
            Nothing -> ([], [])
            Just ds ->
              let refinements = concatMap inputRefinements (inputs e)
              in ( [ bind inputsName (call "listOf" (map quoted ds))
                   , text ("val " ++ caseName ++ ": suspend (List<LawSpecRuntime.Value>) -> Double? = searchCase@") <> L.lambda ["values"]
                       (withSymbols (handlerInstalls e ++
                        [bind (inputId inp) (checked (inputType inp) (text ("values[" ++ show i ++ "]"))) | (i, inp) <- zip [0::Int ..] (inputs e)] ++
                        [braced (L.condition "if" (text "!(" <> conjunction (map (truth . expr) refinements) <> text ")")) [text "return@searchCase null"] | not (null refinements)] ++
                        [bracketed e [assertionDoc (linked e (shown ++ " search")) (assertion e)],
                         maybe (text "0.0") (\score -> runtime "searchNumber" [expr score]) (C.harnessTarget h)]))
                   , quoted (base' ++ "_replay") <> text " " <> L.lambda [] [runtime "searchReplay" [quoted label, text inputsName, searchCase]] ]
                 , [quoted (base' ++ "_search") <> text " " <> L.lambda [] [runtime "searchClimb" [quoted label, text inputsName, searchCase]] | C.harnessTarget h /= Nothing] )
      let check = bracketed e (observations e ++ [remembered (assertionDoc (linked e (shown ++ " property")) (assertion e))])
          propertyLabel = displayLabel label
      property <- if finiteCases e /= Nothing then pure []
        else if not (null (C.harnessDraws h)) then (:[]) <$> harnessProperty fn propertyLabel e check
        else if constructorContracts || nativeGenerators || any (maybe False (const True) . generatorIndex) (generationPlan e)
          then (:[]) <$> contextualProperty fn propertyLabel e check
        else if any (structural . inputType) (inputs e) then pure [nativeProperty fn propertyLabel e check]
        else if any (not . null . inputRefinements) (inputs e) || propertyKind e == "contract"
          then (:[]) <$> refinedProperty fn propertyLabel e check
          else pure [nativeProperty fn propertyLabel e check]
      let kinds = ["_" ++ s | s <- take (length exampleDocs) exampleSuffixes] ++ ["_" ++ boundaryTestName i | i <- [0 .. length boundaryDocs - 1]] ++
            ["_property" | not (null property)]
      let tests = harnessTests base' propertyLabel h kinds (exampleDocs ++ boundaryDocs ++ property)
          -- A complete finite law can register thousands of distinct tests.
          -- Local chunks retain the law's replay state and registration scope.
          chunks [] = []
          chunks docs = take 64 docs : chunks (drop 64 docs)
          registered
            | length tests > 64 && not (runSettings h) && C.harnessKnownFailing h == Nothing =
                [braced (text ("fun chunk" ++ show i ++ "()")) [separate docs] | (i,docs) <- zip [1::Int ..] (chunks tests)] ++
                [text ("chunk" ++ show i ++ "()") | i <- [1..length (chunks tests)]]
            | otherwise = tests
      pure (sharedDocs, mconcat (map (D.lineComment 96 "// ") (lawCommentLines e)) <> separate (searchBefore ++ registered ++ searchAfter))
    contextualProperty fn label e check = do
      let inputBindings xs = [text "val symbols = inputs.symbols", text "val values = inputs.values", fromValues xs]
          state value = call "LawSpecKotlinStrategies.Case" [value, text "symbols", text "drawn.error"]
          step prior (index,plan) = do
            let input = domainInput plan
                ty = inputType input
            seeds <- mapM literal (generatorBoundaries plan)
            let hints = [expr hint | hint <- generatorHints plan, expressionType hint == ty,
                  case C.expressionNode hint of
                    C.Constant _ -> True
                    C.Local _ -> True
                    _ -> False]
                -- Restrict only the top-level primitive. Recursive products keep
                -- their own fields' generators and the checked schema boundary.
                scalar = case inputRange machineBits input of
                  Nothing -> scalarGenerators
                  Just range -> L.lambda ["type"] [D.group (text "if (type == " <> quoted (typeKey ty) <> text ")" <>
                      D.nest 4 (D.softline <> generatorWithin (Just range) ty) <> D.softline <>
                      text "else " <> call "LawSpecScalars.generator" [text "type", text "MACHINE_BITS"])]
                strategy = case (if nativeGenerators then [] else requiredSymbol plan) of
                  value:_ -> call "Arb.constant" [call "LawSpecKotlinStrategies.Checked" [expr value,text "null"]]
                  -- The target is evaluated from the inputs bound above.
                  [] | Just indexed <- generatorIndex plan -> call "LawSpecKotlinStrategies.indexedGenerator"
                    [text "SCHEMA",reference ty,text "MACHINE_BITS",number nodeBudget,text "symbols",
                     expr (indexedTarget indexed),
                     call "mapOf" [L.pairTo (quoted (C.idText tag)) (call "listOf" (map quoted texts))
                       | (tag,texts) <- indexedEquations indexed],
                     scalarGenerators]
                  [] -> call "LawSpecKotlinStrategies.checkedGenerator" $
                    [text "SCHEMA",reference ty,text "MACHINE_BITS",number nodeBudget,
                     number (maxAttempts (generation e)),text "symbols",call "listOf" (seeds ++ hints)] ++
                    [text "lawspec.testing.LawSpecNativeGenerators.factories()" | nativeGenerators] ++
                    [scalar]
                added = L.trailingCall "LawSpecTesting.map" [strategy] ["drawn"]
                  [braced (L.condition "if" (text "drawn.error != null")) [state (text "values")] <> text " else " <>
                   L.block [state (text "values + drawn.requireValue()")]]
            pure $ L.trailingCall "lawspecFlatMap" [prior] ["inputs"]
              [braced (L.condition "if" (text "inputs.error != null")) [text "Arb.constant(inputs)"] <> text " else " <>
               L.block (inputBindings (take index (inputs e)) ++ [added])]
      base <- foldM step (text "LawSpecKotlinStrategies.cases()") (zip [0::Int ..] (generationPlan e))
      let predicates = concatMap inputRefinements (inputs e)
          strategy = if null predicates then base else L.trailingCall "LawSpecKotlinStrategies.filterCases" [base,number (maxAttempts (generation e))] ["inputs"]
            (inputBindings (inputs e) ++ [conjunction (map (truth . expr) predicates)])
          body = [text "val symbols = inputs.symbols", text "val values = inputs.requireValues()", fromValues (inputs e)] ++ handlerInstalls e ++ [check]
      pure $ testFunction (fn ++ "_property: " ++ label) [L.trailingCall "checkAll" [call "LawSpecTesting.config" [number (cases (generation e))],strategy] ["inputs"] body]
    requiredSymbol plan
      | inputType (domainInput plan) /= C.scalarType "Symbol" = []
      | otherwise = concatMap required (generatorPredicates plan)
      where
        current = C.binderId (generatorBinder plan)
        required term = case C.expressionNode term of
          C.ShortCircuit C.And a b -> required a ++ required b
          C.Binary C.Equal _ a b -> [value | (side,value) <- [(a,b),(b,a)],
            C.expressionNode side == C.Local current,
            expressionType value == C.scalarType "Symbol",
            current `notElem` C.freeBinders value,
            case C.expressionNode value of
              C.Constant _ -> True
              C.Local _ -> True
              _ -> False]
          _ -> []
    nativeProperty fn label e check =
      let -- Constant hints (regex samples, compared literals) are mixed in so
          -- a narrow refinement still meets the filter often enough.
          hinted inp gen = case [expr hint | plan <- generationPlan e,
              inputId (domainInput plan) == inputId inp, hint <- generatorHints plan,
              expressionType hint == inputType inp, expressionType hint /= C.scalarType "Symbol",
              case C.expressionNode hint of C.Constant _ -> True; _ -> False] of
            [] -> gen
            hints -> call "lawspecChoice" [call "Arb.element" [L.trailing (text "run") []
              [text "val symbols = mutableMapOf<String, Any>()", call "listOf" hints]], gen]
          -- The inputs drawn together, with fresh symbols (LawSpecTesting).
          base = call "LawSpecTesting.inputs" [hinted inp (generatorWithin (inputRange machineBits inp) (inputType inp)) | inp <- inputs e]
          predicates = concatMap inputRefinements (inputs e)
          bindingsDoc = [text "val symbols = inputs.second", text "val values = inputs.first", fromValues (inputs e)]
          strategy = if null predicates then base else L.trailingCall "LawSpecTesting.filter" [base] ["inputs"]
            (bindingsDoc ++ [conjunction (map (truth . expr) predicates)])
      in testFunction (fn ++ "_property: " ++ label) [L.trailingCall "checkAll" [call "LawSpecTesting.config" [number (cases (generation e))],strategy] ["inputs"]
        (bindingsDoc ++ handlerInstalls e ++ [check])]
    domain e (index,plan) = do
      seeds <- mapM literal (generatorBoundaries plan)
      let inp = domainInput plan
          prior = take index (inputs e)
          bounds = E.array [call "LawSpecRuntime.Bound" [quoted op,expr v] | (op,v) <- domainBounds plan]
          candidates = runtime "domainCandidates" [quoted (typeKey (inputType inp)),text "caseSeed",text "MACHINE_BITS",
            bounds,E.array (seeds ++ map expr (generatorHints plan))]
          seedFn = L.lambda ["values", "caseSeed"] ([fromValues prior | not (null prior)] ++ [candidates])
          predicate = L.lambda ["values"]
            [fromValues (prior ++ [inp]),conjunction (map (truth . expr) (inputRefinements inp))]
      pure (call "LawSpecRuntime.Domain" [seedFn,predicate])
    refinedProperty fn label e check = do
      domains <- mapM (domain e) (zip [0::Int ..] (generationPlan e))
      let cfg = generation e
          callback = L.lambda ["values"] ([fromValues (inputs e)] ++ handlerInstalls e ++ [check])
          invocation = runtime "refinedCase" [E.array domains,
            text "seed",number (maxAttempts cfg),number (maxShrinks cfg),callback,
            quoted (label ++ " | " ++ intercalate "; " (map prettyExpr (concatMap inputRefinements (inputs e))))]
      pure $ testFunction (fn ++ "_property: " ++ label) [L.trailingCall "checkAll" [call "LawSpecTesting.config" [number (cases cfg)],text "Arb.int()"] ["seed"] (withSymbols [invocation])]

-- Whether a unit's laws install a Clock handler, so the test registers how
-- the runtime reads one (lawspec.time's registerClock).
installsClock :: Unit -> Bool
installsClock unit = or [ C.abilityKey a == "lawspec.time::ability::Clock"
                        | p <- C.unitProperties unit, (a, _) <- C.propertyHandlers p ]
