-- | Java property scaffolding consumes checked propositions and generation plans.
module LawSpec.JavaProperties (Config(..), emitTests, TestCase(..), testCases, casePlan) where

import LawSpec.Bounds (inputRange, drawRange)
import qualified LawSpec.JavaAbi as Abi
import qualified LawSpec.JavaTestStyle as Style
import qualified LawSpec.JvmCases as Finite
import qualified LawSpec.Testing.Cover as Cover
import qualified LawSpec.Core as C
import LawSpec.Backend
import LawSpec.Common
import LawSpec.Testing
import qualified LawSpec.Testing.Draws as Draws
import qualified Data.Set as S
import qualified Data.Map.Strict as M
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.JavaExpr as E
import qualified LawSpec.JavaTestHelpers as Helpers
import Data.Char (isAlphaNum, toLower, toUpper)
import Data.List (intercalate, isPrefixOf, stripPrefix)
import LawSpec.TestNames (unitTestNames, lawWords)
import LawSpec.JvmNames (exampleTestNames, boundaryTestName, contractMethod, googleCase, jvmClaimAll, jvmClaim)
import LawSpec.Naming (displayLabel)
import LawSpec.SourceLink (generatedHeader, labelled, locationLink, originLocation, exampleLocation)

-- | What the Java test emitter needs besides the plan: names, layout and
-- bindings, gathered so the emitter takes one argument.
-- A drawn value, or the declarations that draw it and then its value.
data DrawBody = DrawValue D.Doc | DrawSteps [D.Doc] D.Doc

data Config = Config
  { testFile :: FilePath
  , testStyle :: Style.TestStyle
  , packageName :: String
  -- An async adapter's call, awaited.
  , awaitResult :: String -> D.Doc -> D.Doc
  , className :: String
  , schemaNeeded :: Bool
  , nativeGenerators :: Bool
  , constructorContracts :: Bool
  , nodeBudget :: Integer
  , machineBits :: Int
  -- Native adapters convert logical arguments and failures once per signature.
  , adapterWrappers :: [D.Doc]
  , expression :: Expr -> D.Doc
  , scopedExpression :: [(C.Id,String)] -> Expr -> D.Doc
  , literal :: V.Value -> Either [Diagnostic] D.Doc
  , checked :: Type -> D.Doc -> D.Doc
  , structural :: Type -> Bool
  , custom :: Type -> Bool
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
  }

text = D.text
statements = D.joinWith D.hardline
separate = D.joinWith (D.hardline <> D.hardline)
block = D.block 2
-- | A declaration or statement and its block, the brace on a line of its
-- own (Allman, as LawSpec's Java profile asks).
braced :: D.Doc -> D.Doc -> D.Doc
braced header body = header <> D.hardline <> block body
call = E.call
quoted = E.quoted
number :: Show a => a -> D.Doc
number = text . show
statement x = x <> text ";"
returned x = statement (text "return " <> x)
bind n x = D.group (text ("var " ++ n ++ " =") <> D.nest 4 (D.softline <> x) <> text ";")
-- A body that is a block opens on the lambda's line; so does a call whose
-- opening fits there, its arguments breaking instead.
lambda parameters body
  | "LawSpecRuntime.block(() -> {" `isPrefixOf` flat = text (parameters ++ " -> ") <> body
  | (opening@(_ : _), '(' : _) <- break (== '(') flat, all (\c -> isAlphaNum c || c `elem` ("._" :: String)) opening =
      D.prefixChoice (parameters ++ " -> " ++ opening ++ "(") (text (parameters ++ " -> ") <> body) broken
  | otherwise = broken
  where
    flat = D.render D.Compact body
    broken = D.group (text (parameters ++ " ->") <> D.nest 4 (D.softline <> body))
closure parameters body = D.multiline (text (parameters ++ " -> ") <> block body)
chain base methods = D.group (D.nest 4 base <> D.nest 4
  (mconcat [D.softbreak <> call ("." ++ name) args | (name,args) <- methods]))
runtime name = call ("LawSpecRuntime." ++ name)
truth x = runtime "truth" [x]
conjunction [] = text "true"
conjunction [x] = x
conjunction xs = D.group (D.nest 4 (D.joinWith (D.softline <> text "&& ") xs))
symbols = text "var symbols = new HashMap<String, Object>();"

-- | A JUnit test of a unit's test class: its method, why it is skipped,
-- and its law. Spock specifications run them by name.
data TestCase = TestCase { caseMethod :: String, caseSkipped :: Maybe String, caseLaw :: Maybe Expanded, caseKind :: Abi.CaseKind }

-- | The JUnit tests emitTests writes for a unit, in their order.
testCases :: Unit -> [Expanded] -> [TestCase]
testCases unit laws = concat (zipWith cases (unitTestNames "java" (map name laws)) laws) ++
  [ TestCase ("benchmark" ++ concatMap capital (filter ((> 1) . length) (lawWords n))) Nothing Nothing Abi.SingleCase
  | (n, _) <- maybe [] C.harnessBenchmarks (C.unitHarnessSettings unit) ]
  where
    capital (c : cs) = toUpper c : cs
    capital [] = []
    cases base e =
      let h = C.propertyHarness (original e)
          boundaries = boundaryCount e
          examples' = [TestCase (base ++ "_" ++ suffix) Nothing (Just e) Abi.SingleCase | suffix <- exampleSuffixesOf e]
          finite = [TestCase (base ++ "_boundary") Nothing (Just e)
            (Abi.FiniteCases (memberName base "Cases") (memberName base "Boundary") boundaries) | boundaries > 0]
          property' = [TestCase (base ++ "_property") Nothing (Just e) Abi.SingleCase | finiteCover e == Nothing]
      in case (C.harnessSkip h, C.harnessKnownDiscrepancy h) of
        (Just reason, _) -> [TestCase (base ++ "_skipped") (Just (owner e ++ "::" ++ name e ++ ": " ++ reason)) (Just e) Abi.SingleCase]
        (_, Just _) -> [TestCase (base ++ "_knownDiscrepancy") Nothing (Just e) Abi.SingleCase]
        _ -> examples' ++ finite ++ property'

boundaryCount :: Expanded -> Integer
boundaryCount e = maybe (toInteger (length (boundaryCases e))) Cover.coverCount (finiteCover e)

memberName :: String -> String -> String
memberName base suffix = googleCase (concatMap part (splitName base) ++ suffix)
  where
    part = id
    splitName name = case name of
      '_' : c : rest -> [toUpper c] : splitName rest
      c : rest -> [c] : splitName rest
      [] -> []

-- | A target can call plain cases without discovering methods in Java text.
casePlan :: Config -> Unit -> [Expanded] -> Abi.CaseClass
casePlan config unit laws = Abi.CaseClass
  (testFile config) (packageName config) (className config ++ "LawSpecTest")
  (Just (unitName unit))
  [Abi.CaseInfo (caseMethod c) (invocation c) (caseSkipped c)
    (fmap (C.idText . C.propertyId . original) (caseLaw c)) (caseKind c) | c <- testCases unit laws]
  (maybe False C.harnessOrderRandom (C.unitHarnessSettings unit))
  (maybe False C.harnessParallel (C.unitHarnessSettings unit))
  where
    invocation c = case caseKind c of
      Abi.SingleCase -> caseMethodFor (testStyle config) (caseMethod c)
      Abi.FiniteCases _ action _ -> action

caseMethodFor :: Style.TestStyle -> String -> String
caseMethodFor Style.JUnit name = name
caseMethodFor Style.SpockCases name = name
caseMethodFor Style.PlainCases name = "case" ++ capital (camel name)
  where
    capital (c : rest) = toUpper c : rest
    capital [] = []
    camel ('_' : c : rest) = toUpper c : camel rest
    camel (c : rest) = c : camel rest
    camel [] = []

-- | The test names of a law's examples, after its own name.
exampleSuffixesOf :: Expanded -> [String]
exampleSuffixesOf e = exampleTestNames ("property" : "skipped" : "knownDiscrepancy" : "replay" :
  map boundaryTestName [0 .. boundaries - 1]) (map exampleName (examples (original e)))
  where boundaries = length (maybe (boundaryCases e) id (finiteCases e))

-- | Laws become tests in Java's own property framework, so they run with the
-- tools the project already uses. ref:DEC-native-property-frameworks
emitTests :: Config -> Unit -> [Expanded] -> Either [Diagnostic] D.Doc
emitTests Config{..} unit laws = do
  let testNames = unitTestNames "java" (map name laws)
  bodies <- mapM (law testNames) (zip [0::Int ..] laws)
  let needsProperty = any ((== Nothing) . finiteCases) laws
      members = [text "// The machine profile's integer width." <> D.hardline <>
          text ("private static final int MACHINE_BITS = " ++ show machineBits ++ ";")] ++
        [D.group (text "private static final lawspec.runtime.LawSpecSchema SCHEMA =" <>
        D.nest 4 (D.softline <> text "lawspec.runtime.LawSpecDataSchema.create();")) | schemaNeeded] ++
        [seedDoc | needsProperty] ++
        -- Workflows wait on a virtual clock under test, and workflows and
        -- mailboxes read the Clock handler a law installs.
        [braced (text "static") (statements (text "LawSpecRuntime.useVirtualClock(0);" :
          [text "lawspec.Time.registerClock();" | installsClock unit]))] ++
        [braced (text "static") (statement (call "LawSpecHarness.parallelism"
          [quoted (unitName unit), quoted "threads (JUnit concurrent execution)", text "Runtime.getRuntime().availableProcessors()"])) | parallel] ++
        adapterWrappers ++ map contract (contracts unit) ++ bodies ++ map benchmark (maybe [] C.harnessBenchmarks settings)
      body = separate members
      rendered = D.render D.Compact body
      imports = [name | name <- ["java.util.HashMap", "java.util.List", "java.util.Map", "java.util.function.Function", "java.util.function.Supplier",
        "lawspec.runtime.LawSpecDataCodecs", "lawspec.runtime.LawSpecDefinitionBodies",
        "lawspec.runtime.LawSpecRuntime", "lawspec.runtime.LawSpecRuntime.Value", "lawspec.runtime.LawSpecSchema",
        "lawspec.testing.LawSpecDataStrategies", "lawspec.testing.LawSpecHarness", Style.propertyPackage testStyle ++ ".Generator", Style.propertyPackage testStyle ++ ".PropertyChecker",
        "org.junit.jupiter.api.Test"], usesSimple (simpleName name) rendered]
      allImports = imports
  pure $ text ("// " ++ generatedHeader sourceFile) <> D.hardline <> D.hardline <>
    (if null packageName then mempty else text ("package " ++ packageName ++ ";") <> D.hardline <> D.hardline) <>
    (if null allImports then mempty else statements [text ("import " ++ i ++ ";") | i <- allImports] <> D.hardline <> D.hardline) <>
    -- order random: LawSpec's seeded order (LawSpecOrder); parallel: JUnit's
    -- concurrent mode, enabled for such classes in junit-platform.properties.
    (if testStyle == Style.JUnit && orderRandom then text "@org.junit.jupiter.api.TestMethodOrder(lawspec.testing.LawSpecOrder.class)" <> D.hardline else mempty) <>
    (if testStyle == Style.JUnit && parallel then text "@org.junit.jupiter.api.parallel.Execution(org.junit.jupiter.api.parallel.ExecutionMode.CONCURRENT)" <> D.hardline else mempty) <>
    braced (text ("public final class " ++ className ++ "LawSpecTest")) body <> D.hardline
  where
    -- Binders keep their source names (LawSpec.JvmNames).
    inputId = local . C.binderId . C.quantifiedBinder
    localName = local
    bindings ex = [(local i, v) | (i, v) <- C.exampleBindings ex]
    contractArguments c = [(local (C.binderId b), C.binderType b) | b <- C.contractArguments c]
    contractResult c = let b = C.contractResult c in (local (C.binderId b), C.binderType b)
    fromValues xs = statements [bind (inputId input) (text ("values.get(" ++ show index ++ ")")) |
      (index,input) <- zip [0::Int ..] xs]
    identifiers = words . map (\c -> if isAlphaNum c || c == '_' then c else ' ')
    simpleName = reverse . takeWhile (/= '.') . reverse
    -- Whether code names a class by its simple name (not qualified).
    usesSimple n code = any (\(before, rest) -> take (length n) rest == n && not (word before) && not (word' (drop (length n) rest)))
      (zip (' ' : code) (tails' code))
      where
        word c = isAlphaNum c || c == '_' || c == '.'
        word' (c : _) = isAlphaNum c || c == '_'
        word' [] = False
    tails' s = case s of [] -> [[]]; _ : rest -> s : tails' rest
    -- A case's handlers and fixtures are in symbols; a case with neither
    -- does not make it.
    withSymbols docs = let rest = statements docs
      in if "symbols" `elem` identifiers (D.render D.Compact rest) then statements (symbols : docs) else rest
    -- Readable text about a law: its label and source line.
    shownLaw e = owner e ++ "::" ++ displayLabel (name e)
    lawLink e = let l = location (original e) in if null (file l) then Nothing else Just (locationLink l)
    linked e text' = labelled text' (lawLink e)
    -- A test's members are named after its law: normalizersAgreeCase.
    member fn suffix = case break (== '_') (dropHarness fn) of (base, _) -> base ++ suffix
    dropHarness fn = maybe fn id (stripPrefix "harness:" fn)
    constantName fn suffix = map toUpper (concatMap (\c -> if c >= 'A' && c <= 'Z' then ['_', c] else [c]) (dropHarness fn)) ++ suffix
    -- The harness plane (LawSpec.Harness). A test the harness runs is a
    -- method without @Test (harness:name), which the generated test passes
    -- to the runtime.
    settings = C.unitHarnessSettings unit
    orderRandom = maybe False C.harnessOrderRandom settings
    parallel = maybe False C.harnessParallel settings
    testFunction name body = case (stripPrefix "harness:" name, lookup name searchHooks) of
      (Just rest, hook) -> braced (text ("void " ++ harnessMethod rest ++ "() throws Throwable")) (hooked hook body)
      (Nothing, Just hook) -> throwingTest name (hooked (Just hook) body)
      (Nothing, Nothing) -> junitTest name body
    -- A harness body is an ordinary method, so its name has no underscore.
    harnessMethod rest = "harness" ++ capitalised (camel rest)
    camel s = case s of
      '_' : c : more -> toUpper c : camel more
      c : more -> c : camel more
      [] -> []
    capitalised (c : cs) = toUpper c : cs
    capitalised [] = []
    hooked hook body = maybe body (\(before, after) -> statements ([before, body] ++ after)) hook
    -- LawSpec's own search (LawSpec.Search): a law's property test first
    -- replays the failing inputs the failure database kept, and a law with
    -- `target maximize` climbs after it, as JetCheck has no targeting. Each
    -- uses the law's case method, which checks one tuple of inputs.
    searchHooks =
      [ (propertyName index e ++ "_property", (statement (runtime "searchReplay" [quoted label, inputs', caseRef]),
          [statement (runtime "searchClimb" [quoted label, inputs', caseRef]) | C.harnessTarget (C.propertyHarness (original e)) /= Nothing]))
      | (index, e) <- zip [0::Int ..] laws, Just _ <- [searchDescriptors e]
      , let label = owner e ++ "::" ++ name e
            fn = unitTestNames "java" (map name laws) !! index
            inputs' = text (constantName fn "_INPUTS")
            caseRef = text ("this::" ++ member fn "Case") ]
    propertyName index e =
      let h = C.propertyHarness (original e)
          base = unitTestNames "java" (map name laws) !! index
      in (if C.harnessSkip h == Nothing && (C.harnessKnownDiscrepancy h /= Nothing || runSettings h) then "harness:" else "") ++ base
    testMark = if testStyle == Style.JUnit then text "@Test" <> D.hardline else mempty
    junitTest name body = testMark <> braced (text ("public void " ++ caseMethodFor testStyle name ++ "()")) body
    throwingTest name body = testMark <> braced (text ("public void " ++ caseMethodFor testStyle name ++ "() throws Throwable")) body
    runSettings h = C.harnessTimeout h /= Nothing || C.harnessRepeat h /= 1 || C.harnessRetries h /= 0 || observed h
    observed h = not (null (C.harnessCover h) && null (C.harnessClassify h) && null (C.harnessLabels h)) || C.harnessTarget h /= Nothing
    strings xs = text "new String[] {" <> D.commaSep (map quoted xs) <> text "}"
    booleans xs = text "new boolean[] {" <> D.commaSep xs <> text "}"
    observations e =
      let h = C.propertyHarness (original e)
          label = owner e ++ "::" ++ name e
      in [statement (call "LawSpecHarness.observe" [quoted label,
            strings [l | C.Cover _ l _ <- C.harnessCover h], booleans [truth (expr w) | C.Cover _ _ w <- C.harnessCover h],
            strings [l | (_, l) <- C.harnessClassify h], booleans [truth (expr c) | (c, _) <- C.harnessClassify h],
            E.array (map expr (C.harnessLabels h))]) | observed h] ++
         [statement (call "LawSpecHarness.target" [expr score, quoted label]) | Just score <- [C.harnessTarget h]]
    -- The tests a law's harness wraps, skips or expects to fail.
    harnessTests fn label h kinds extraBodies docs = case (C.harnessSkip h, C.harnessKnownDiscrepancy h) of
      (Just reason, _) -> [(if testStyle == Style.JUnit then text "@org.junit.jupiter.api.Disabled(" <> quoted (label ++ ": " ++ reason) <> text ")" <> D.hardline else mempty) <>
        junitTest (fn ++ "_skipped") mempty]
      (_, Just reason) -> docs ++ [junitTest (fn ++ "_knownDiscrepancy") (statements
        ([bind "knownFailures" (call "new java.util.ArrayList<lawspec.testing.LawSpecHarness.Body>" [])] ++
         [statement (call "knownFailures.add" [text ("this::" ++ harnessMethod (fn ++ k))]) | k <- kinds, k /= "_property"] ++
         extraBodies ++
         [statement (call "knownFailures.add" [text ("this::" ++ harnessMethod (fn ++ k))]) | k <- kinds, k == "_property"] ++
         [statement (call "LawSpecHarness.knownDiscrepancy" [quoted label, quoted (fn ++ "_knownDiscrepancy"), quoted reason, text "knownFailures"])]))]
      _ | runSettings h -> docs ++ [throwingTest (fn ++ k) (statement (call "LawSpecHarness.run"
            [quoted label, quoted (fn ++ k), number (maybe 0 id (C.harnessTimeout h)), number (C.harnessRepeat h), number (C.harnessRetries h),
             text "new int[] {" <> D.commaSep [number p | k == "_property", C.Cover p _ _ <- C.harnessCover h] <> text "}",
             strings [l | k == "_property", C.Cover _ l _ <- C.harnessCover h],
             text (if k == "_property" && observed h then "true" else "false"), text ("this::" ++ harnessMethod (fn ++ k))])) | k <- kinds]
        | otherwise -> docs
    benchmark (n, body) = throwingTest ("benchmark" ++ concatMap capital (filter ((> 1) . length) (lawWords n))) (withSymbols [
      statement (call "LawSpecHarness.benchmark" [quoted n, closure "()" (statement (text "var measured = " <> expr body))])])
    capital (c : cs) = toEnum (fromEnum c - (if c >= 'a' && c <= 'z' then 32 else 0)) : cs
    capital [] = []
    -- A property whose inputs harness strategies draw: the strategies draw
    -- in JetCheck's generator; their values' refinements are checked in the
    -- property, and the other inputs' filter the generator.
    harnessProperty fn label e check = do
      let h = C.propertyHarness (original e)
          strategyOf inp = [(n, d) | (i, n, d) <- C.harnessDraws h, i == C.binderId (C.quantifiedBinder inp)]
      draws <- mapM (\plan -> do
        let inp = domainInput plan
        case strategyOf inp of
          (strategy, d) : _ -> (\(defs, body) -> defs ++ [bind (inputId inp) (drawValue body)]) <$> sharedDraw e plan inp strategy (inputId inp) d
          [] -> pure [bind (inputId inp) (call "environment.<Value>generate" [generatorWithin (inputRange machineBits inp) (inputType inp)])]) (generationPlan e)
      let defaults = [inp | inp <- inputs e, null (strategyOf inp)]
          strategyChecks = [statement (call "LawSpecHarness.checkDrawn" [quoted strategy, quoted (inputName inp),
              conjunction (map (truth . expr) (inputRefinements inp)), text (inputId inp)])
            | inp <- inputs e, (strategy, _) : _ <- [strategyOf inp], not (null (inputRefinements inp))]
          base = call "Generator.from" [closure "environment" (statements
            ([symbols] ++ concat draws ++ [returned (call "new LawSpecRuntime.Inputs" [call "java.util.List.of" [text (inputId inp) | inp <- inputs e], text "symbols"])]))]
          predicates = concatMap inputRefinements defaults
          bindingsDoc = statements [text "var symbols = inputs.symbols();", text "var values = inputs.values();", fromValues (inputs e)]
          generator = if null predicates then base else chain base [("suchThat",
            [closure "inputs" (statements [bindingsDoc, returned (conjunction (map (truth . expr) predicates))])])]
      pure $ testFunction (fn ++ "_property") $ statement $ chain (text "checker()")
        [("withIterationCount",[number (cases (generation e))]),
         ("forAll",[generator, closure "inputs" (statements ([bindingsDoc] ++ strategyChecks ++ handlerInstalls e ++ [check, returned (text "true")]))])]
    -- A choice among n: a wide draw, reduced, so the weights hold.
    chooser = lambda "count" (call "environment.generate" [call "Generator.integers" [text "0", text "java.lang.Integer.MAX_VALUE"]] <> text " % count")
    -- Shared helpers receive captured values explicitly. Their bodies sample
    -- only when called, including callbacks for unchosen alternatives.
    sharedDraw expanded requirement inp strategy name draw = do
      let available = map C.quantifiedBinder (inputs expanded) ++ map C.resourceBinder (C.propertyResources (original expanded))
      graph <- either (Left . pure . (\message -> Diagnostic "testing" message Nothing)) pure (Draws.planDraw requirement available draw)
      let nodes = Draws.drawNodes graph
          bound step = case step of
            Draws.FilterDraw _ binder predicate _ -> binder : expressionBinders predicate
            Draws.BindDraw binder _ _ -> [binder]
            Draws.OneOfDraw _ values -> concatMap expressionBinders values
            _ -> []
          taken = S.fromList ("environment" : "symbols" : map (localName . C.binderId)
            (available ++ concatMap Draws.drawCaptures nodes ++ concatMap (bound . Draws.drawStep) nodes))
          (names, allTaken) = jvmClaimAll taken [googleCase (name ++ "Draw" ++ show (Draws.drawNumber node)) | node <- nodes]
          table = M.fromList (zip (map Draws.drawNumber nodes) names)
          invoke aliases child = callDoc (table M.! Draws.drawCallee child ++ ".apply")
            [callDoc "List.of" [text (maybe (localName identity) id (lookup identity aliases)) | identity <- Draws.drawArguments child]]
          callDoc = call
          nodeDoc node = do
            let function = table M.! Draws.drawNumber node
                captured = fst (jvmClaim allTaken (googleCase (function ++ "CapturedValues")))
                binders = M.elems (M.fromList [(C.binderId binder,binder) | binder <- Draws.drawCaptures node ++ bound (Draws.drawStep node)])
                aliases = zip (map C.binderId binders) (fst (jvmClaimAll (S.insert captured allTaken)
                  [googleCase (function ++ " " ++ localName (C.binderId binder)) | binder <- binders]))
                renamed identity = maybe (localName identity) id (lookup identity aliases)
                captures = [bind (renamed (C.binderId binder)) (callDoc (captured ++ ".get") [number i])
                  | (i,binder) <- zip [0::Int ..] (Draws.drawCaptures node)]
            body <- case Draws.drawStep node of
              Draws.AnyDraw ty aim -> snd <$> drawDoc inp strategy name (C.DrawAny ty aim)
              Draws.OneOfDraw _ values -> pure (DrawValue (callDoc "LawSpecHarness.oneOf" [chooser,
                callDoc "List.<Supplier<Value>>of" [lambda "()" (scopedExpression aliases value) | value <- values]]))
              Draws.FrequencyDraw alternatives -> pure (DrawValue (callDoc "LawSpecHarness.frequency" [chooser,
                callDoc "java.util.List.of" [callDoc "new LawSpecHarness.Weighted" [number weight,lambda "()" (invoke aliases child)] | (weight,child) <- alternatives]]))
              Draws.FilterDraw child binder predicate limit -> pure (DrawValue (callDoc "LawSpecHarness.suchThat"
                [lambda "()" (invoke aliases child),lambda (renamed (C.binderId binder)) (truth (scopedExpression aliases predicate)),number limit,quoted strategy]))
              Draws.BindDraw binder from rest -> pure (DrawSteps [bind (renamed (C.binderId binder)) (invoke aliases from)] (invoke aliases rest))
            let statements' = captures ++ case body of DrawValue value -> [returned value]; DrawSteps steps value -> steps ++ [returned value]
            pure (D.group (text ("Function<List<Value>, Value> " ++ function ++ " =") <>
              D.nest 4 (D.softline <> closure captured (statements statements'))) <> text ";")
      helpers <- mapM nodeDoc nodes
      pure (helpers,DrawValue (invoke [] (Draws.drawRoot graph)))
    -- A draw is the suppliers it needs, each naming one sub-draw and
    -- declared before its use, then its value: draws stay flat rather than
    -- nesting a lambda per step.
    drawDoc inp strategy name d = case d of
      C.DrawAny ty aim -> pure ([], DrawValue (call "environment.<Value>generate" [maybe (generator ty) (\range -> generatorWithin (Just range) ty) (drawRange machineBits inp ty aim)]))
      C.DrawOneOf _ values -> pure ([], DrawValue (call "LawSpecHarness.oneOf" [chooser,
        call "List.<Supplier<Value>>of" [lambda "()" (expr v) | v <- values]]))
      C.DrawFrequency alternatives -> do
        options <- mapM (\(k, (w, a)) -> do
          (defs, option) <- named (googleCase (name ++ "Option" ++ show k)) a
          pure (defs, call "new LawSpecHarness.Weighted" [number w, option])) (zip [1 :: Int ..] alternatives)
        pure (concatMap fst options, DrawValue (call "LawSpecHarness.frequency" [chooser, call "java.util.List.of" (map snd options)]))
      C.DrawSuchThat inner binder predicate limit -> do
        (defs, candidate) <- named (googleCase (name ++ "Candidate")) inner
        pure (defs, DrawValue (call "LawSpecHarness.suchThat" [candidate, lambda (localName (C.binderId binder)) (truth (expr predicate)), number limit, quoted strategy]))
      -- draw x, then the rest knowing x: a block of declarations.
      C.DrawBind {} -> do
        let chainOf d' = case d' of
              C.DrawBind binder from rest -> let (steps, final) = chainOf rest in ((binder, from) : steps, final)
              _ -> ([], d')
            (steps, final) = chainOf d
        declarations <- mapM (\(binder, from) -> do
          let n = localName (C.binderId binder)
          (defs, body) <- drawDoc inp strategy n from
          pure (defs ++ [bind n (drawValue body)])) steps
        (finalDefs, finalBody) <- drawDoc inp strategy name final
        pure ([], DrawSteps (concat declarations ++ finalDefs) (drawValue finalBody))
      where
        -- A sub-draw passed on as a supplier: a plain draw stays inline;
        -- anything larger is a named supplier, declared before its use.
        named n sub = do
          (defs, body) <- drawDoc inp strategy n sub
          pure $ case (sub, body) of
            (C.DrawAny _ _, DrawValue v) -> (defs, lambda "()" v)
            (_, DrawValue v) -> (defs ++ [supplier n (lambda "()" v)], text n)
            -- A supplier of several steps opens its block on its own line.
            (_, DrawSteps steps v) -> (defs ++ [D.multiline (text ("Supplier<Value> " ++ n ++ " = () -> ") <> block (statements (steps ++ [returned v]))) <> text ";"], text n)
        supplier n value = D.group (text ("Supplier<Value> " ++ n ++ " =") <> D.nest 4 (D.softline <> value) <> text ";")
    drawValue body = case body of
      DrawValue v -> v
      DrawSteps steps v -> D.multiline (text "LawSpecRuntime.block(() -> " <> block (statements (steps ++ [returned v])) <> text ")")
    -- LAWSPEC_SEED fixes jetCheck's seed, so a run can be repeated exactly
    -- (lawspec test records the seed of every passing run).
    seedDoc = braced (text "private static PropertyChecker.Parameters checker()") (statements
      [ text "var seed = System.getenv(\"LAWSPEC_SEED\");"
      , D.group (text "return seed == null" <> D.nest 4 (D.softline <> text "? PropertyChecker.customized()" <>
          D.softline <> text ": PropertyChecker.customized().withSeed(Long.parseLong(seed));")) ])
    expr = expression
    -- An assertion names its law and case and points at the source line of
    -- what it checks; the expectation itself is in the law's comment.
    assertionDoc context = contextualAssertion (const (quoted context))
    contextualAssertion context proposition = case proposition of
      AssertAll ps -> statements (map (contextualAssertion context) ps)
      AssertImplies guard body -> braced (text "if (" <> truth (expr guard) <> text ")")
        (contextualAssertion context body)
      AssertEqual a b ->
        let message = context (expressionLink a)
        in statement (if custom (expressionType a)
          then call "SCHEMA.check" [message, reference (expressionType a), text "MACHINE_BITS", text "symbols", lambda "()" (expr a), lambda "()" (expr b)]
          else runtime "check" [message, lambda "()" (expr a), lambda "()" (expr b)])
    expressionLink a = case originLocation (C.expressionOrigin a) of
      Just l | take 1 (file l) /= "<" -> Just (locationLink l)
      _ -> Nothing
    -- try { ... } finally { ... }, Allman.
    tryFinally inner final = braced (text "try") inner <> D.hardline <> braced (text "finally") final
    -- A law's resources: each case acquires them, then runs, then releases
    -- them, the last first, even when the case fails.
    bracketed e docs = foldr wrap (statements (lateHandlerInstalls e ++ docs)) (C.propertyResources (original e))
      where
        -- A shared resource (share R per ...): the runtime keeps one per
        -- scope key, resets it before each later use, and releases it when
        -- the JVM exits. Its reset and release see it under another name,
        -- as a lambda may not redeclare the local.
        wrap r inner | Just key <- C.resourceShared r, Just reset <- C.resourceReset r =
          let rid = C.binderId (C.resourceBinder r)
              resource = localName rid
              -- An id no binder has, named as the lambda's parameter.
              other = C.Id (resource ++ "Shared")
              usingIt body = closure (localName other) (bind "unused" (expr (C.renameLocal rid other body)))
          in statements [bind resource (runtime "share" [quoted key, lambda "()" (expr (C.resourceAcquire r)), usingIt reset, usingIt (C.resourceRelease r),
              text (if C.resourceConcurrent r then "true" else "false")]),
            tryFinally inner (statement (runtime "unshare" [quoted key]))]
        wrap r inner =
          let resource = localName (C.binderId (C.resourceBinder r))
          in statements [bind resource (expr (C.resourceAcquire r)),
            tryFinally inner (bind (resource ++ "Released") (expr (C.resourceRelease r)))]
    contract c =
      let args = contractArguments c
          (rn,rt) = contractResult c
          params = text "Map<String, Object> symbols" : [text ("Value " ++ n) | (n,_) <- args]
          context stage ps = quoted (contractName c ++ " " ++ stage ++ ": " ++ intercalate " && " (map prettyExpr ps))
          require stage ps = statement (runtime "requireContract" [conjunction (map (truth . expr) ps),context stage ps])
          invocation = awaitResult (adapterName unit (C.contractDeclaration c)) (call (className ++ "." ++ adapterName unit (C.contractDeclaration c)) [nativeArgument ty (text n) | (n,ty) <- args])
      in braced (call ("private static Value " ++ contractMethod (contractName c)) params)
          (statements [require "precondition" (contractPreconditions c),
          bind rn (nativeResult rt invocation),require "postcondition" (contractPostconditions c),returned (text rn)])
    law testNames (index,e) = do
      let label = owner e ++ "::" ++ name e
          shown = shownLaw e
          h = C.propertyHarness (original e)
          base = testNames !! index
          fn = (if C.harnessSkip h == Nothing && (C.harnessKnownDiscrepancy h /= Nothing || runSettings h) then "harness:" else "") ++ base
          exampleSuffixes = exampleSuffixesOf e
          checkNames = map inputId (inputs e) ++
            [localName (C.binderId (C.resourceBinder resource)) | resource <- C.propertyResources (original e)]
          lawAssertion context = statement (call (member base "Check") [context, text "symbols", E.array (map text checkNames)])
      exampleDocs <- mapM (\(suffix,ex) -> pure $ D.lineComment 98 "// " (labelled ("example " ++ displayLabel (exampleName ex))
          (fmap locationLink (exampleLocation ex))) <>
        testFunction (fn ++ "_" ++ suffix) (withSymbols
        (handlerInstalls e ++ [bind n (expr v) | (n,v) <- bindings ex] ++
        [bracketed e (map (\p -> contextualAssertion (\l -> quoted (labelled (shown ++ " example " ++ displayLabel (exampleName ex)) l)) p) (expectations ex) ++
          [lawAssertion (quoted (linked e shown))])]))) (zip exampleSuffixes (examples (original e)))
      cover <- either (Left . pure . (\message -> Diagnostic "testing" message Nothing)) pure (caseCover e)
      (coverDeclarations, coverData) <- Finite.coverBindings call (lambda "symbols") literal
        finiteDeclaration (constantName base "_CASES") cover
      let helper = member base "BoundaryBody"
          action = member base "Boundary"
          source = member base "Cases"
          argumentsSource = member base "Arguments"
          caseName = D.group (quoted (base ++ "_boundary") <> text " + finiteCase.index()")
          context = D.group (quoted (shown ++ " boundary ") <>
            D.nest 4 (D.softline <> text "+ finiteCase.index()" <>
              maybe mempty (\link -> D.softline <> text "+ " <> quoted (" — " ++ link)) (lawLink e)))
          caseCall = statement (call helper [text "finiteCase"])
          caseBody = closure "()" caseCall
          runCase | runSettings h = statement (call "LawSpecHarness.run"
                      [quoted label, caseName, number (maybe 0 id (C.harnessTimeout h)),
                       number (C.harnessRepeat h), number (C.harnessRetries h),
                       text "new int[] {}", text "new String[] {}", text "false", caseBody])
                  | otherwise = caseCall
          sharedBoundaryDocs = [declaration | C.harnessSkip h == Nothing, declaration <- coverDeclarations] ++
            concat [[braced (call ("private void " ++ member base "Check")
              [text "String context", text "Map<String, Object> symbols", text "Value[] values"])
              (statements ([bind n (text ("values[" ++ show i ++ "]")) | (i,n) <- zip [0::Int ..] checkNames] ++
                [contextualAssertion (const (text "context")) (assertion e)])),
             braced (D.group (text "public static Iterable<LawSpecRuntime.FiniteCase>" <> D.nest 4 (D.softline <> call source [])))
              (returned (if testStyle == Style.SpockCases
                then runtime "selectedFiniteCases" [coverData, quoted (show (Cover.coverCount cover))]
                else runtime "finiteCases" [coverData])),
             braced (call ("public void " ++ action) [text "LawSpecRuntime.FiniteCase finiteCase"] <> text " throws Throwable") runCase,
             braced (call ("private void " ++ helper) [text "LawSpecRuntime.FiniteCase finiteCase"])
              (withSymbols (bind "values" (call "finiteCase.values" [text "symbols"]) : handlerInstalls e ++
                [bind (inputId inp) (checked (inputType inp) (text ("values.get(" ++ show i ++ ")"))) | (i,inp) <- zip [0::Int ..] (inputs e)] ++
                [bracketed e [lawAssertion context]]))]
            | C.harnessSkip h == Nothing]
          argumentFactory = call "org.junit.jupiter.params.provider.Arguments.of"
            [call "org.junit.jupiter.api.Named.of" [caseName, text "finiteCase"]]
          argumentRows = runtime "selectedFiniteCases" [coverData, quoted (show (Cover.coverCount cover))]
          argumentsDoc = braced (D.group (text "public static java.util.stream.Stream<org.junit.jupiter.params.provider.Arguments>" <>
              D.nest 4 (D.softline <> call argumentsSource [])))
            (returned (chain (call "java.util.stream.StreamSupport.stream" [argumentRows <> text ".spliterator()", text "false"])
              [("map", [closure "finiteCase" (returned argumentFactory)])]))
          boundaryDocs = concat [[argumentsDoc,
            text "@org.junit.jupiter.params.ParameterizedTest(name = " <> quoted "{0}" <> text ")" <> D.hardline <>
            call "@org.junit.jupiter.params.provider.MethodSource" [quoted argumentsSource] <> D.hardline <>
            braced (call ("public void " ++ base ++ "_boundary") [text "LawSpecRuntime.FiniteCase finiteCase"] <> text " throws Throwable") runCase]
            | testStyle == Style.JUnit, Cover.coverCount cover > 0, C.harnessSkip h == Nothing, C.harnessKnownDiscrepancy h == Nothing]
          extraBodies = [braced (text "for (var finiteCase : " <> call source [] <> text ")")
            (statement (call "knownFailures.add" [caseBody]))]
      let descriptors = searchDescriptors e
          inputsConstant = constantName fn "_INPUTS"
          remembered doc = case descriptors of
            Nothing -> doc
            Just _ -> braced (text "try") doc <> D.hardline <> braced (text "catch (RuntimeException | Error error)") (statements
              [statement (runtime "searchRemember" [quoted label, text inputsConstant,
                 call "java.util.List.of" [text (inputId inp) | inp <- inputs e]]), text "throw error;"])
          searchDocs = case descriptors of
            Nothing -> []
            Just ds ->
              let refinements = concatMap inputRefinements (inputs e)
              in [ D.group (text ("private static final List<String> " ++ inputsConstant ++ " =") <>
                     D.nest 4 (D.softline <> call "List.of" (map quoted ds))) <> text ";"
                 , braced (D.group (text ("private Double " ++ member fn "Case" ++ "(List<Value> values)") <>
                     D.nest 4 (D.softline <> text "throws Exception"))) (withSymbols
                     (handlerInstalls e ++
                      [bind (inputId inp) (checked (inputType inp) (text ("values.get(" ++ show i ++ ")"))) | (i, inp) <- zip [0::Int ..] (inputs e)] ++
                      [braced (text "if (!(" <> conjunction (map (truth . expr) refinements) <> text "))") (text "return null;") | not (null refinements)] ++
                      [bracketed e [lawAssertion (quoted (linked e (shown ++ " search")))],
                       returned (maybe (text "0.0") (\score -> runtime "searchNumber" [expr score]) (C.harnessTarget h))])) ]
      let check = bracketed e (observations e ++ [remembered (lawAssertion (quoted (linked e (shown ++ " property"))))])
      property <- if finiteCases e /= Nothing then pure []
        else if not (null (C.harnessDraws h)) then (:[]) <$> harnessProperty fn label e check
        else if nativeGenerators || any (structural . inputType) (inputs e) then (:[]) <$> structuralProperty fn e check
        else if any (not . null . inputRefinements) (inputs e) || propertyKind e == "contract"
          then (:[]) <$> refinedProperty fn label e check
          else pure [testFunction (fn ++ "_property") $ statement $ call "checker().forAll"
            [text "Generator.integers()",closure "seed" $ withSymbols (handlerInstalls e ++
              [bind (inputId inp) (runtime "sample" [quoted (typeKey (inputType inp)),
                text ("seed + " ++ show i),text "MACHINE_BITS"]) | (i,inp) <- zip [0::Int ..] (inputs e)] ++
              [check,returned (text "true")])]]
      let kinds = ["_" ++ suffix | suffix <- take (length exampleDocs) exampleSuffixes] ++
            ["_property" | not (null property)]
      pure $ mconcat (map (D.lineComment 98 "// ") (lawCommentLines e)) <>
        separate (searchDocs ++ sharedBoundaryDocs ++ harnessTests base label h kinds extraBodies (exampleDocs ++ boundaryDocs ++ property))
    finiteDeclaration name value =
      D.group (text "private static final LawSpecRuntime.FiniteCover" <> D.nest 4 (D.softline <> text name <> text " =")) <>
        D.nest 4 (D.hardline <> value) <> text ";"
    structuralProperty fn e check = do
      strategies <- mapM (contextualStrategy (generation e)) (generationPlan e)
      let predicatesFor inp = concatMap conjuncts (inputRefinements inp)
          generate inp = call "environment.<Value>generate"
            [maybe (generatorWithin (inputRange machineBits inp) (inputType inp)) id (lookup (inputId inp) strategies)]
          prepare inp | nativeGenerators = generate inp
          prepare inp = prepareElements (C.binderId (C.quantifiedBinder inp))
            (predicatesFor inp) (generate inp)
          valueGenerator = call "java.util.List.of" [text (inputId inp) | inp <- inputs e]
          base = call (if nativeGenerators then "Generator.<LawSpecRuntime.Inputs>from" else "Generator.from") [closure "environment" (statements
            ([symbols] ++ [bind (inputId inp) (prepare inp) | inp <- inputs e] ++
             [returned (call "new LawSpecRuntime.Inputs" [valueGenerator,text "symbols"])]))]
          predicates = concatMap inputRefinements (inputs e)
          bindingsDoc = statements [text "var symbols = inputs.symbols();",
            text "var values = inputs.values();",fromValues (inputs e)]
          captured = if nativeGenerators then call "LawSpecDataStrategies.capture" [base] else base
          inputName = if nativeGenerators then "captured" else "inputs"
          unpack = [bind "inputs" (call "captured.requireValue" []) | nativeGenerators]
          strategy = if null predicates then captured else chain captured [("suchThat",
            [closure inputName (statements
              ([text "if (captured.error() != null)" <> D.hardline <> block (text "return true;") | nativeGenerators] ++
               unpack ++ [bindingsDoc,returned (conjunction (map (truth . expr) predicates))]))])]
          callback = closure inputName (statements (unpack ++ [bindingsDoc] ++ handlerInstalls e ++ [check,returned (text "true")]))
      -- JetCheck rejects repeated generation trees within one session. Small
      -- structural domains can exhaust those trees before the requested case
      -- count. Independent one-case sessions retain its native shrinking and
      -- the growing budget; a seeded stream keeps the complete run repeatable.
      let invocation count size = statement $ chain (text "checker()")
            [("withSeed",[call "seeds.nextLong" []]),
             ("withIterationCount",[number count]),
             ("withSizeHint",[lambda "iteration" size]),
             ("forAll",[strategy,callback])]
          growing iteration = text "(int) " <> call "Math.min"
            [text "java.lang.Integer.MAX_VALUE",text ("2L * " ++ iteration ++ " + 8")]
          body = statements
            [text "var seed = System.getenv(\"LAWSPEC_SEED\");",
             D.group (text "var seeds =" <> D.nest 4 (D.softline <> text "seed == null" <> D.nest 4 (D.softline <> text "? new java.util.Random()" <> D.softline <> text ": new java.util.Random(Long.parseLong(seed));"))),
             text ("for (int caseIndex = 0; caseIndex < " ++ show (cases (generation e)) ++ "; caseIndex++)") <> D.hardline <>
               block (statements [bind "sizeHint" (growing "caseIndex"),invocation (1 :: Int) (text "sizeHint")])]
      pure $ testFunction (fn ++ "_property") body
    contextualStrategy settings plan = do
      let input = domainInput plan
          ty = inputType input
      seeds <- mapM literal (generatorBoundaries plan)
      let hints = [expr hint | hint <- generatorHints plan, expressionType hint == ty,
            case C.expressionNode hint of
              C.Constant _ -> True
              C.Local _ -> True
              _ -> False]
          scalar = case inputRange machineBits input of
            Nothing -> text (Helpers.scalarsClass ++ "::generator")
            Just range -> D.group (text "scalar ->" <> D.nest 4 (D.softline <>
              D.group (call "scalar.equals" [quoted (typeKey ty)] <> D.nest 4
                (D.softline <> text "? " <> generatorWithin (Just range) ty <>
                 D.softline <> text ": " <> call (Helpers.scalarsClass ++ ".generator") [text "scalar"]))))
          strategy = case requiredSymbol plan of
            value:_ -> call "Generator.constant" [expr value]
            [] | Just indexed <- generatorIndex plan ->
              -- The target is evaluated from inputs drawn earlier in this environment.
              chain (call "LawSpecDataStrategies.checkedIndexedGenerator"
                [text "SCHEMA",reference ty,text "MACHINE_BITS",number nodeBudget,
                 number (maxAttempts settings),text "symbols",
                 expr (indexedTarget indexed),equationsDoc (indexedEquations indexed),
                 scalar,if nativeGenerators then call "lawspec.testing.LawSpecNativeGenerators.factories" []
                   else call "java.util.Map.of" []])
                [("map",[text "LawSpecDataStrategies.Checked::requireValue"])]
            [] | nativeGenerators || constructorContracts -> chain
              (call "LawSpecDataStrategies.checkedGenerator"
                ([text "SCHEMA",reference ty,text "MACHINE_BITS",number nodeBudget,number (maxAttempts settings),
                 text "symbols",call "java.util.List.of" (seeds ++ hints),
                 scalar] ++
                [call "lawspec.testing.LawSpecNativeGenerators.factories" [] | nativeGenerators]))
              [("map",[D.group (text "LawSpecDataStrategies.Checked" <> D.nest 4 (D.softbreak <> text "::requireValue"))])]
            [] -> hinted (generatorWithin (inputRange machineBits input) ty)
          -- Constant hints (regex samples, compared literals) are mixed in so
          -- a narrow refinement still meets the filter often enough.
          constants = [expr hint | hint <- generatorHints plan, expressionType hint == ty,
            ty /= C.scalarType "Symbol", case C.expressionNode hint of C.Constant _ -> True; _ -> False]
          hinted generator
            | null constants = generator
            | otherwise = call "Generator.<Value>anyOf"
                [call "Generator.<Value>sampledFrom" [call "java.util.List.of" constants],generator]
      pure (inputId input,strategy)
    equationsDoc equations = call "java.util.Map.ofEntries"
      [call "java.util.Map.entry" [quoted (C.idText tag), call "java.util.List.of" (map quoted texts)]
      | (tag,texts) <- equations]
    requiredSymbol plan
      | nativeGenerators = []
      | inputType (domainInput plan) /= C.scalarType "Symbol" = []
      | otherwise = concatMap required (generatorPredicates plan)
      where
        current = C.binderId (generatorBinder plan)
        required term = case C.expressionNode term of
          C.ShortCircuit C.And a b -> required a ++ required b
          C.Binary C.Equal _ a b -> [value | (local,value) <- [(a,b),(b,a)],
            C.expressionNode local == C.Local current,
            expressionType value == C.scalarType "Symbol",
            current `notElem` C.freeBinders value,
            case C.expressionNode value of
              C.Constant _ -> True
              C.Local _ -> True
              _ -> False]
          _ -> []
    conjuncts term = case C.expressionNode term of
      C.ShortCircuit C.And left right -> conjuncts left ++ conjuncts right
      _ -> [term]
    -- Mapping the framework's native list tree preserves its shrink history.
    -- Every already-valid list is a fixed point; empty element domains still
    -- have the empty-list witness. Keep the final predicate check for any
    -- constraints that relate the entire list to other values.
    prepareElements identity predicates original = foldl prepare original
      [(binder,predicate) | term <- predicates,
        C.AllElements value binder predicate <- [C.expressionNode term],
        C.Local name <- [C.expressionNode value], name == identity]
      where
        prepare value (binder,predicate) =
          let name = localName (C.binderId binder)
              prepared = prepareElements (C.binderId binder) (conjuncts predicate) (text name)
          in runtime "refineElements" [value,lambda name prepared,lambda name (expr predicate)]
    domain e (index,plan) = do
      seeds <- mapM literal (generatorBoundaries plan)
      let inp = domainInput plan
          prior = take index (inputs e)
          bounds = array "LawSpecRuntime.Bound"
            [call "new LawSpecRuntime.Bound" [quoted op,expr v] | (op,v) <- domainBounds plan]
          candidates = runtime "domainCandidates" [quoted (typeKey (inputType inp)),text "caseSeed",text "MACHINE_BITS",
            bounds,E.array (seeds ++ map expr (generatorHints plan))]
          seedFn = closure "(values, caseSeed)" (statements ([fromValues prior | not (null prior)] ++ [returned candidates]))
          predicate = closure "values" (statements
            [fromValues (prior ++ [inp]),returned (conjunction (map (truth . expr) (inputRefinements inp)))])
      pure (call "new LawSpecRuntime.Domain" [seedFn,predicate])
    refinedProperty fn label e check = do
      domains <- mapM (domain e) (zip [0::Int ..] (generationPlan e))
      let cfg = generation e
          callback = closure "values" (statements ([fromValues (inputs e)] ++ handlerInstalls e ++ [check]))
          invocation = runtime "refinedCase" [array "LawSpecRuntime.Domain" domains,
            text "seed",number (maxAttempts cfg),number (maxShrinks cfg),callback,
            quoted (label ++ " | " ++ intercalate "; " (map prettyExpr (concatMap inputRefinements (inputs e))))]
      pure $ testFunction (fn ++ "_property") $ statement $ chain (text "checker()")
        [("withIterationCount",[number (cases cfg)]),
         ("forAll",[text "Generator.integers()",closure "seed" (statements [symbols,statement invocation,returned (text "true")])])]
    array name values = D.group (text ("new " ++ name ++ "[] {") <>
      D.nest 2 (D.softbreak <> D.commaSep values) <> D.softbreak <> text "}")

-- Whether a unit's laws install a Clock handler, so the test registers how
-- the runtime reads one (lawspec.time's registerClock).
installsClock :: Unit -> Bool
installsClock unit = or [ C.abilityKey a == "lawspec.time::ability::Clock"
                        | p <- C.unitProperties unit, (a, _) <- C.propertyHandlers p ]
