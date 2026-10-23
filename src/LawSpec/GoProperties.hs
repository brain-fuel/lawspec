-- | Go test scaffolding consumes checked propositions and generation plans.
module LawSpec.GoProperties (Config(..), emitTests) where

import LawSpec.Bounds (inputRange, drawRange)
import LawSpec.Backend hiding (inputId, localName, bindings, contractArguments, contractResult)
import LawSpec.Common
import LawSpec.TestNames (unitTestNames, lawWords)
import LawSpec.Naming (exampleTestSuffix, boundaryTestSuffix, displayLabel, cased, Casing(..))
import LawSpec.SourceLink (labelled, locationLink, exampleLocation, originLocation, unitSourceFile)
import LawSpec.Testing
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.GoExpr as E
import qualified LawSpec.GoTestHelpers as Helpers
import Data.List (intercalate, stripPrefix)

-- | What the Go test emitter needs besides the plan: names, layout and
-- bindings, gathered so the emitter takes one argument.
data Config = Config
  { packageName :: String
  -- Each binder's Go name: its source name (LawSpec.Naming).
  , local :: C.Id -> String
  -- An async adapter's call, awaited.
  , awaitResult :: String -> D.Doc -> D.Doc
  , schemaNeeded :: Bool
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
  , nativeFunction :: String -> String
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
  }

text = D.text
statements = D.joinWith D.hardline
separate = D.joinWith (D.hardline <> D.hardline)
block = D.block 8
call = E.call
quoted = E.quoted
number :: Show a => a -> D.Doc
number = text . show
returned x = text "return " <> x
bind n x = text (n ++ " := ") <> x
closure parameters result body = text ("func(" ++ parameters ++ ")" ++
  (if null result then "" else " " ++ result) ++ " ") <> block body
truth x = call "lsTruth" [x]
conjunction [] = text "true"
conjunction xs = D.joinWith (text " && ") xs
-- | A statement list that declares locals: each is marked used only when
-- nothing after it reads it, and symbols is made only when something does.
data Statement = Declare String D.Doc | Pure String D.Doc | Plain D.Doc

body :: [Statement] -> D.Doc
body = statements . go
  where
    go [] = []
    go (Plain d : rest) = d : go rest
    go ss = let (declared, rest) = span (not . plain) ss
            in E.declare [(n, v, pure' s') | s' <- declared, Just (n, v) <- [named s']] (go rest)
    pure' (Pure _ _) = True
    pure' _ = False
    plain (Plain _) = True
    plain _ = False
    named (Declare n v) = Just (n, v)
    named (Pure n v) = Just (n, v)
    named _ = Nothing

symbols :: Statement
symbols = Pure "symbols" (text "map[string]*lawSpecSymbol{}")

-- | Laws become tests in Go's own property framework, so they run with the
-- tools the project already uses. Tests are named after their law and
-- example, locals keep their source names, and each test links to its
-- source line. ref:DEC-native-property-frameworks ref:DEC-readable-output-default
emitTests :: Config -> Unit -> [Expanded] -> Either [Diagnostic] D.Doc
emitTests Config{..} unit laws = do
  let testNames = unitTestNames "go" (map name laws)
  bodies <- mapM (law testNames) (zip [0::Int ..] laws)
  -- A law checked only by lsRefinedCase draws its inputs without rapid.
  let refinedOnly e = not (constructorContracts || nativeGenerators || any (maybe False (const True) . generatorIndex) (generationPlan e)
        || any (structural . inputType) (inputs e)) && (any (not . null . inputRefinements) (inputs e) || propertyKind e == "contract")
      needsRapid = schemaNeeded || harnessed || any (\e -> finiteCases e == Nothing && not (refinedOnly e)) laws
      importDoc = text "import (" <> D.nest 8 (D.hardline <>
        statements ([quoted "flag" | needsRapid] ++ [quoted "fmt" | schemaNeeded] ++ [quoted "os" | needsRapid || sharing || orderRandom || parallel] ++
          [quoted "testing" | not (null laws)]) <>
        (if needsRapid then D.hardline <> D.hardline <> quoted "pgregory.net/rapid" else mempty)) <>
        D.hardline <> text ")"
  pure $ separate ([E.generatedHeader (unitSourceFile unit) <> D.hardline <> D.hardline <> text ("package " ++ packageName)] ++
    [importDoc | schemaNeeded || not (null laws)] ++ [seedDoc | needsRapid] ++ [clockDoc] ++ [testMainDoc | sharing || orderRandom || parallel] ++
    [Helpers.dataHelpersDoc machineBits generator | schemaNeeded] ++
    map contract (contracts unit) ++ bodies ++ map benchmark (maybe [] C.harnessBenchmarks settings)) <> D.hardline
  where
    inputId = local . C.binderId . C.quantifiedBinder
    fromValues xs = [Declare (inputId input) (text ("values[" ++ show index ++ "]")) | (index,input) <- zip [0::Int ..] xs]
    plainAll = map Plain
    -- The harness plane (LawSpec.Harness). A test the harness runs is a
    -- function of rapid.TB (harness:Name), which the generated Test calls
    -- through the runtime; parallel marks every test parallel.
    settings = C.unitHarnessSettings unit
    harnessed = settings /= Nothing
    parallel = maybe False C.harnessParallel settings
    testFunction name' body' = case stripPrefix "harness:" name' of
      Just rest -> text ("func lawspecHarness" ++ rest ++ "(t rapid.TB) ") <> block body'
      Nothing -> goTest name' body'
    goTest name' body' = text ("func Test" ++ name' ++ "(t *testing.T) ") <> block (if parallel then statements [text "t.Parallel()", body'] else body')
    runSettings h = C.harnessTimeout h /= Nothing || C.harnessRepeat h /= 1 || C.harnessRetries h /= 0 || observed h
    observed h = not (null (C.harnessCover h) && null (C.harnessClassify h) && null (C.harnessLabels h)) || C.harnessTarget h /= Nothing
    observations e =
      let h = C.propertyHarness (original e)
          label = owner e ++ "::" ++ name e
          pairs xs = text "[]lsHarnessPair{" <> D.joinWith (text ", ") [text "{" <> quoted l <> text ", " <> truth (expr w) <> text "}" | (l, w) <- xs] <> text "}"
      in [call "lsHarnessObserve" [text "t", quoted label, pairs [(l, w) | C.Cover _ l w <- C.harnessCover h], pairs [(l, c) | (c, l) <- C.harnessClassify h],
            text "[]LawSpecValue{" <> D.joinWith (text ", ") (map expr (C.harnessLabels h)) <> text "}"] | observed h] ++
         [call "lsHarnessTarget" [text "t", expr score, quoted label] | Just score <- [C.harnessTarget h]]
    -- The tests a law's harness wraps, skips or expects to fail.
    harnessTests fn label h kinds docs = case (C.harnessSkip h, C.harnessKnownFailing h) of
      (Just reason, _) -> [goTest (fn ++ "_Skipped") (call "lsHarnessSkip" [text "t", quoted label, quoted reason])]
      (_, Just reason) -> docs ++ [goTest (fn ++ "_KnownFailing") (call "lsHarnessKnownFailing" [text "t", quoted label, quoted ("Test" ++ fn ++ "_KnownFailing"), quoted reason,
        text "[]func(rapid.TB){" <> D.joinWith (text ", ") [text ("lawspecHarness" ++ fn ++ k) | k <- kinds] <> text "}"])]
      _ | runSettings h -> docs ++ [goTest (fn ++ k) (call "lsHarnessRun" [text "t", quoted label, quoted ("Test" ++ fn ++ k),
            number (maybe 0 id (C.harnessTimeout h)), number (C.harnessRepeat h), number (C.harnessRetries h),
            text "[]lsHarnessCover{" <> D.joinWith (text ", ") [text ("{" ++ show p ++ ", ") <> quoted l <> text "}" | k == "_Property", C.Cover p l _ <- C.harnessCover h] <> text "}",
            text (if k == "_Property" && observed h then "true" else "false"), text ("lawspecHarness" ++ fn ++ k)]) | k <- kinds]
        | otherwise -> docs
    benchmark (n, measured) = goTest ("Benchmark" ++ concatMap capital (lawWords n)) (body [symbols,
      Plain (call "lsHarnessBenchmark" [text "t", quoted n, closure "" "" (text "_ = " <> expr measured)])])
    capital (c : cs) = toEnum (fromEnum c - (if c >= 'a' && c <= 'z' then 32 else 0)) : cs
    capital [] = []
    -- A property whose inputs harness strategies draw.
    harnessProperty fn e check = do
      let h = C.propertyHarness (original e)
          strategyOf inp = [(n, d) | (i, n, d) <- C.harnessDraws h, i == C.binderId (C.quantifiedBinder inp)]
      draws <- mapM (\plan -> do
        let inp = domainInput plan
            predicate = conjunction (map (truth . expr) (inputRefinements inp))
        case strategyOf inp of
          (strategy, d) : _ -> do
            value <- drawDoc inp strategy d
            pure [Declare (inputId inp) (call "lsHarnessCheckDrawn" [quoted strategy, quoted (inputName inp),
              closure (inputId inp ++ " LawSpecValue") "bool" (returned predicate), value])]
          [] -> pure ([Declare (inputId inp) (generatorWithin (inputRange machineBits inp) (inputType inp) <> text ".Draw(t, " <> quoted (inputName inp) <> text ")")] ++
            [Plain (text "if !(" <> predicate <> text ") " <> block (text "t.SkipNow()")) | not (null (inputRefinements inp))])) (generationPlan e)
      pure $ testFunction (fn ++ "_Property") $ call "lsRapidCheck" [text "t",number (cases (generation e)),
        closure "t *rapid.T" "" $ body ([symbols] ++ concat draws ++ plainAll (handlerInstalls e) ++ resourceDocs e ++ [Plain check])]
    drawDoc inp strategy d = case d of
      C.DrawAny ty aim -> pure (maybe (generator ty) (\range -> generatorWithin (Just range) ty) (drawRange machineBits inp ty aim) <> text ".Draw(t, \"value\")")
      C.DrawOneOf _ values -> pure (call "lsHarnessOneOf" [text "t", text "[]func() LawSpecValue{" <>
        D.joinWith (text ", ") [closure "" "LawSpecValue" (returned (expr v)) | v <- values] <> text "}"])
      C.DrawFrequency alternatives -> do
        options <- mapM (\(w, a) -> (\doc -> text ("{" ++ show w ++ ", ") <> closure "" "LawSpecValue" (returned doc) <> text "}") <$> drawDoc inp strategy a) alternatives
        pure (call "lsHarnessFrequency" [text "t", text "[]lsHarnessWeighted{" <> D.joinWith (text ", ") options <> text "}"])
      C.DrawSuchThat inner binder predicate limit -> do
        doc <- drawDoc inp strategy inner
        pure (call "lsHarnessSuchThat" [closure "" "LawSpecValue" (returned doc),
          closure (local (C.binderId binder) ++ " LawSpecValue") "bool" (returned (truth (expr predicate))), number limit, quoted strategy])
      C.DrawBind binder from rest -> do
        fromDoc <- drawDoc inp strategy from
        restDoc <- drawDoc inp strategy rest
        pure (closure (local (C.binderId binder) ++ " LawSpecValue") "LawSpecValue" (returned restDoc) <> text "(" <> fromDoc <> text ")")
    -- LAWSPEC_SEED fixes rapid's seed, so a run can be repeated exactly
    -- (lawspec test records the seed of every passing run).
    seedDoc = text "func init() " <> block (text "if seed := os.Getenv(\"LAWSPEC_SEED\"); seed != \"\" " <>
      block (text "_ = flag.Set(\"rapid.seed\", seed)")) <> D.hardline <> D.hardline <>
      -- A harnessed unit whose laws draw nothing still seeds rapid.
      text "var _ = rapid.Check"
    -- Workflows wait on a virtual clock under test; where a law installs a
    -- Clock handler, workflows and mailboxes read it (lawspec.time's
    -- LawSpecRegisterClock, in this package's copy of the default handlers).
    clockDoc = text "func init() " <> block (statements
      ([text "LawSpecUseVirtualClock(0)"] ++ [text "LawSpecRegisterClock()" | installsClock]))
    installsClock = or [C.abilityKey a == "lawspec.time::ability::Clock"
      | p <- C.unitProperties unit, (a, _) <- C.propertyHandlers p]
    expr = expression
    -- A law's resources: each case acquires them, and releases them when it
    -- ends, the last first, even when it fails (defer).
    resourceDocs e = concat (map resourceDoc (C.propertyResources (original e))) ++ plainAll (lateHandlerInstalls e)
    -- A shared resource (share R per ...): the runtime keeps one per scope
    -- key, resets it before each later use, and releases it in TestMain.
    resourceDoc r
      | Just key <- C.resourceShared r, Just reset <- C.resourceReset r =
          let held = local (C.binderId (C.resourceBinder r))
          in [ Declare held (call "lsShare" [quoted key, closure "" "LawSpecValue" (returned (expr (C.resourceAcquire r))),
                 closure (held ++ " LawSpecValue") "" (text "_ = " <> expr reset),
                 closure (held ++ " LawSpecValue") "" (text "_ = " <> expr (C.resourceRelease r)),
                 text (if C.resourceConcurrent r then "true" else "false")])
             , Plain (text "defer lsUnshare(" <> quoted key <> text ")") ]
      | otherwise =
          [ Declare (local (C.binderId (C.resourceBinder r))) (expr (C.resourceAcquire r))
          , Plain (text "defer func() " <> block (text "_ = " <> expr (C.resourceRelease r)) <> text "()") ]
    sharing = any (\e -> any ((/= Nothing) . C.resourceShared) (C.propertyResources (original e))) laws
    orderRandom = maybe False C.harnessOrderRandom settings
    -- order random: go test shuffles the package's tests with the run's
    -- seed (lsHarnessShuffle). Shared resources are released when the test
    -- binary ends.
    testMainDoc = text "func TestMain(m *testing.M) " <> block (statements
      ([text "lsHarnessShuffle()" | orderRandom] ++ [call "lsHarnessParallelism" [quoted (C.idText (C.unitId unit))] | parallel] ++ [text "code := m.Run()"] ++ [text "lsReleaseShared()" | sharing] ++ [text "os.Exit(code)"]))
    -- A failing assertion names its law and case and points at the
    -- expectation's source line, or the law's.
    assertionDoc fallback context proposition = case proposition of
      AssertAll ps -> statements (map (assertionDoc fallback context) ps)
      AssertImplies guard rest -> text "if " <> truth (expr guard) <> text " " <>
        block (assertionDoc fallback context rest)
      AssertEqual a b ->
        let message = quoted (labelled context (maybe fallback Just (expectationLink proposition)))
            thunk = closure "" "LawSpecValue" . returned . expr
        in if structural (expressionType a)
          then call "_lawspecDataAssert" [message,reference (expressionType a),text "symbols",thunk a,thunk b]
          else call "lsAssert" [message,thunk a,thunk b]
    expectationLink proposition = case proposition of
      AssertEqual a _ | Just l <- originLocation (C.expressionOrigin a), take 1 (file l) /= "<" -> Just (locationLink l)
      _ -> Nothing
    -- Contracts read as the source writes them.
    contractNames c = [(local (C.binderId b), C.binderType b) | b <- C.contractArguments c]
    contract c =
      let args = contractNames c
          (rn,rt) = let b = C.contractResult c in (local (C.binderId b), C.binderType b)
          params = intercalate ", " ("symbols map[string]*lawSpecSymbol" : [n ++ " LawSpecValue" | (n,_) <- args])
          context stage ps = quoted (contractName c ++ " " ++ stage ++ ": " ++ intercalate " && " (map (prettyExprWith True local) ps))
          require stage ps = call "lsRequireContract" [conjunction (map (truth . expr) ps),context stage ps]
          invocation = awaitResult (contractName c) (call (nativeFunction (contractName c)) [nativeArgument ty (text n) | (n,ty) <- args])
      in text ("func _lawspec_call_" ++ contractName c ++ "(" ++ params ++ ") LawSpecValue ") <>
        block (statements [require "precondition" (contractPreconditions c),
          bind rn (nativeResult rt invocation),require "postcondition" (contractPostconditions c),returned (text rn)])
    -- Text and characters are written as Go literals, which are always valid.
    checkedLiteral ty value doc = case value of
      V.ScalarValue _ | ty `elem` [C.scalarType "Text", C.scalarType "Char"] -> doc
      _ -> checked ty doc
    law testNames (index,e) = do
      let label = owner e ++ "::" ++ name e
          shown = owner e ++ "::" ++ displayLabel (name e)
          short = displayLabel (name e)
          lawLink = if null (file (location (original e))) then Nothing else Just (locationLink (location (original e)))
          linked context link test = D.lineComment 100 "// " (labelled context link) <> test
          h = C.propertyHarness (original e)
          base = drop 4 (testNames !! index)
          fn = (if C.harnessSkip h == Nothing && (C.harnessKnownFailing h /= Nothing || runSettings h) then "harness:" else "") ++ base
          finite = maybe (boundaryCases e) id (finiteCases e)
          -- An example's test is named after the example; boundaries are
          -- numbered from 1.
          boundarySuffixes = map (pascal . boundaryTestSuffix) [0 .. length finite - 1]
          exampleSuffixes = map pascal (exampleTestSuffix "go"
            ("property" : "replay" : "search" : "skipped" : "known_failing" : map boundaryTestSuffix [0 .. length finite - 1])
            (map exampleName (examples (original e))))
          bindingsOf ex = [Declare (local i) (expr v) | (i, v) <- C.exampleBindings ex]
          exampleDocs = [linked ("example " ++ displayLabel (exampleName ex)) (locationLink <$> exampleLocation ex) $
            testFunction (fn ++ "_" ++ suffix) $ body
              ([symbols] ++ plainAll (handlerInstalls e) ++ bindingsOf ex ++ resourceDocs e ++
               [Plain (assertionDoc lawLink (shown ++ " example " ++ displayLabel (exampleName ex)) p) | p <- expectations ex] ++
               [Plain (assertionDoc lawLink shown (assertion e))])
            | (suffix, ex) <- zip exampleSuffixes (examples (original e))]
      boundaryDocs <- mapM (\(i,vs) -> do
        values <- mapM literal vs
        pure $ linked (short ++ ", boundary " ++ show (i + 1)) lawLink $ testFunction (fn ++ "_" ++ boundarySuffixes !! i) $ body
          ([symbols] ++ plainAll (handlerInstalls e) ++ [Declare (inputId inp) (checkedLiteral (inputType inp) v doc) | (inp,v,doc) <- zip3 (inputs e) vs values] ++
          resourceDocs e ++ [Plain (assertionDoc lawLink (shown ++ " boundary " ++ show (i + 1)) (assertion e))]))
        (zip [0::Int ..] finite)
      -- LawSpec's own search (LawSpec.Search): a failing generated case's
      -- inputs are kept in the failure database and replayed first; a law
      -- with `target maximize` also climbs, as rapid has no targeting.
      let descriptors = searchDescriptors e
          inputsName = "lawspec" ++ base ++ "Inputs"
          caseName = "lawspec" ++ base ++ "Case"
          values = text "[]LawSpecValue{" <> D.joinWith (text ", ") (map (text . inputId) (inputs e)) <> text "}"
          remembered doc = case descriptors of
            Nothing -> doc
            Just _ -> text "func() " <> block (statements
              [ text "defer func() " <> block (text "if problem := recover(); problem != nil " <> block (statements
                  [call "LawSpecSearchRemember" [quoted label, text inputsName, values], text "panic(problem)"])) <> text "()"
              , doc ]) <> text "()"
          withCase = text caseName
          searchDocs = case descriptors of
            Nothing -> ([], [])
            Just ds ->
              let refinements = concatMap inputRefinements (inputs e)
                  caseDoc = text ("func " ++ caseName ++ "(values []LawSpecValue) (float64, bool) ") <> block (body
                    ([symbols] ++ plainAll (handlerInstalls e) ++
                     [Declare (inputId inp) (checked (inputType inp) (text ("values[" ++ show i ++ "]"))) | (i, inp) <- zip [0::Int ..] (inputs e)] ++
                     [Plain (text "if !(" <> conjunction (map (truth . expr) refinements) <> text ") " <> block (text "return 0, false")) | not (null refinements)] ++
                     resourceDocs e ++ [Plain (assertionDoc lawLink (shown ++ " search") (assertion e)),
                     Plain (text "return " <> maybe (text "0") (\score -> call "lsSearchNumber" [expr score]) (C.harnessTarget h) <> text ", true")]))
              in ( [ text ("var " ++ inputsName ++ " = []string{") <> D.joinWith (text ", ") (map quoted ds) <> text "}"
                   , caseDoc
                   , goTest (base ++ "_Replay") (call "LawSpecSearchReplay" [quoted label, text inputsName, withCase]) ]
                 , [goTest (base ++ "_Search") (call "LawSpecSearchClimb" [quoted label, text inputsName, withCase]) | C.harnessTarget h /= Nothing] )
      let check = statements (observations e ++ [remembered (assertionDoc lawLink (shown ++ " property") (assertion e))])
      property <- if finiteCases e /= Nothing then pure []
        else if not (null (C.harnessDraws h)) then (:[]) <$> harnessProperty fn e check
        else if constructorContracts || nativeGenerators || any (maybe False (const True) . generatorIndex) (generationPlan e)
          then (:[]) <$> contextualProperty fn label e check
        else if any (structural . inputType) (inputs e) then pure [structuralProperty fn label e check]
        else if any (not . null . inputRefinements) (inputs e) || propertyKind e == "contract"
          then (:[]) <$> refinedProperty fn e check
          else pure [testFunction (fn ++ "_Property") $ call "rapid.Check" [text "t",
            closure "t *rapid.T" "" $ body ([Declare "seed" (text "rapid.Int32().Draw(t, \"seed\")"),symbols] ++ plainAll (handlerInstalls e) ++
              [Declare (inputId inp) (call "lsSample" [quoted (typeKey (inputType inp)),
                text (if i == 0 then "int(seed)" else "int(seed)+" ++ show i),number machineBits]) | (i,inp) <- zip [0::Int ..] (inputs e)] ++ resourceDocs e ++ [Plain check])]]
      let kinds = map ("_" ++) (take (length exampleDocs) exampleSuffixes) ++ map ("_" ++) (take (length boundaryDocs) boundarySuffixes) ++
            ["_Property" | not (null property)]
          linkedProperty = map (linked (short ++ ", property") lawLink) property
      pure $ mconcat (map (D.lineComment 100 "// ") (lawCommentLines e)) <> D.hardline <>
        separate (fst searchDocs ++ harnessTests base label h kinds (exampleDocs ++ boundaryDocs ++ linkedProperty) ++ snd searchDocs)
    pascal = cased Pascal . splitOn '_'
    splitOn c xs = case break (== c) xs of
      (part, _ : rest) -> part : splitOn c rest
      (part, []) -> [part]
    contextualProperty fn label e check = do
      draws <- mapM (\plan -> do
        seeds <- mapM literal (generatorBoundaries plan)
        let inp = domainInput plan
            ty = inputType inp
            hints = [expr hint | hint <- generatorHints plan, expressionType hint == ty,
              case C.expressionNode hint of C.Constant _ -> True; C.Local _ -> True; _ -> False]
            scalar = case inputRange machineBits inp of
              Nothing -> text "_lawspecScalarGenerator"
              Just range -> closure "_lawspecScalarName string" "*rapid.Generator[LawSpecValue]"
                (statements [text "if _lawspecScalarName == " <> quoted (typeKey ty) <> text " " <>
                  block (returned (generatorWithin (Just range) ty)),
                  returned (call "_lawspecScalarGenerator" [text "_lawspecScalarName"])])
            strategy = case (if nativeGenerators then [] else requiredSymbol plan) of
              value:_ -> call "rapid.Just" [expr value]
              -- The target is evaluated from the inputs drawn above.
              [] | Just indexed <- generatorIndex plan -> call "lsIndexedDataStrategy"
                [text "_lawspecSchema",reference ty,number machineBits,number nodeBudget,
                 expr (indexedTarget indexed),
                 -- Go requires trailing commas across lines; keep the table on one line.
                 text "map[string][]string{" <> D.joinWith (text ", ")
                   [quoted (C.idText tag) <> text ": {" <> D.joinWith (text ", ") (map quoted texts) <> text "}"
                   | (tag,texts) <- indexedEquations indexed] <> text "}",
                 text "_lawspecScalarGenerator"]
              [] -> call "lsCheckedDataStrategyWithAttempts" $
                [text "_lawspecSchema",reference ty,number machineBits,number nodeBudget,number (maxAttempts (generation e)),
                 text "symbols",E.array (seeds ++ hints),scalar] ++
                [text "lawSpecNativeFactories()" | nativeGenerators]
            suffix = if nativeGenerators || null (requiredSymbol plan) then text ".requireValue()" else mempty
        pure (Declare (inputId inp) (strategy <> text ".Draw(t, " <>
          quoted (inputName inp) <> text ")" <> suffix))) (generationPlan e)
      let base = call "rapid.Custom" [closure "t *rapid.T" "[]LawSpecValue" $
            body ([symbols] ++ draws ++ [Plain (returned (E.array (map (text . inputId) (inputs e))))])]
          predicates = concatMap inputRefinements (inputs e)
          strategy = if null predicates then base else call "lsBoundedFilter"
            [base,number (maxAttempts (generation e)),
             closure "values []LawSpecValue" "bool" (body
               (fromValues (inputs e) ++ [Plain (returned (conjunction (map (truth . expr) predicates)))]))]
      pure $ testFunction (fn ++ "_Property") $ call "lsRapidCheck" [text "t",number (cases (generation e)),
        closure "t *rapid.T" "" $ body ([symbols,
          Declare "values" (strategy <> text ".Draw(t, " <> quoted label <> text ")")] ++
          fromValues (inputs e) ++ plainAll (handlerInstalls e) ++ resourceDocs e ++ [Plain check])]
    requiredSymbol plan
      | inputType (domainInput plan) /= C.scalarType "Symbol" = []
      | otherwise = concatMap required (generatorPredicates plan)
      where
        current = C.binderId (generatorBinder plan)
        required term = case C.expressionNode term of
          C.ShortCircuit C.And a b -> required a ++ required b
          C.Binary C.Equal _ a b -> [value | (held,value) <- [(a,b),(b,a)],
            C.expressionNode held == C.Local current,
            expressionType value == C.scalarType "Symbol",
            current `notElem` C.freeBinders value,
            case C.expressionNode value of C.Constant _ -> True; C.Local _ -> True; _ -> False]
          _ -> []
    structuralProperty fn label e check =
      let draws = [Declare (inputId inp) (hinted inp (generatorWithin (inputRange machineBits inp) (inputType inp)) <> text ".Draw(t, " <> quoted (inputName inp) <> text ")") | inp <- inputs e]
          -- Constant hints (regex samples, compared literals) are mixed in so
          -- a narrow refinement still meets the filter often enough.
          hinted inp generator' = case [expr hint | plan <- generationPlan e,
              inputId (domainInput plan) == inputId inp, hint <- generatorHints plan,
              expressionType hint == inputType inp, expressionType hint /= C.scalarType "Symbol",
              case C.expressionNode hint of C.Constant _ -> True; _ -> False] of
            [] -> generator'
            hints -> call "rapid.OneOf" [call "rapid.SampledFrom" [E.array hints],generator']
          base = call "rapid.Custom" [closure "t *rapid.T" "[]LawSpecValue" $
            body (draws ++ [Plain (returned (E.array (map (text . inputId) (inputs e))))])]
          predicates = concatMap inputRefinements (inputs e)
          strategy = if null predicates then base else call "lsBoundedFilter"
            [base,number (maxAttempts (generation e)),
             closure "values []LawSpecValue" "bool" (body
               (fromValues (inputs e) ++ [Plain (returned (conjunction (map (truth . expr) predicates)))]))]
      in testFunction (fn ++ "_Property") $ call "lsRapidCheck" [text "t",number (cases (generation e)),
        closure "t *rapid.T" "" $ body ([symbols,
          Declare "values" (strategy <> text ".Draw(t, " <> quoted label <> text ")")] ++ fromValues (inputs e) ++
          plainAll (handlerInstalls e) ++ resourceDocs e ++ [Plain check])]
    domain e (index,plan) = do
      seeds <- mapM literal (generatorBoundaries plan)
      let inp = domainInput plan
          prior = take index (inputs e)
          bounds = text "[]lawSpecBound{" <> D.joinWith (text ", ")
            [text "{" <> quoted op <> text ", " <> expr v <> text "}" | (op,v) <- domainBounds plan] <> text "}"
          candidates = call "lsDomainCandidates" [quoted (typeKey (inputType inp)),text "seed",number machineBits,
            bounds,E.array (seeds ++ map expr (generatorHints plan))]
          seedFn = closure "values []LawSpecValue, seed int" "[]LawSpecValue"
            (body (fromValues prior ++ [Plain (returned candidates)]))
          predicate = closure "values []LawSpecValue" "bool" (body
            (fromValues (prior ++ [inp]) ++ [Plain (returned (conjunction (map (truth . expr) (inputRefinements inp))))]))
      pure (text "lawSpecDomain{" <> seedFn <> text ", " <> predicate <> text "}")
    refinedProperty fn e check = do
      domains <- mapM (domain e) (zip [0::Int ..] (generationPlan e))
      let cfg = generation e
          callback = closure "values []LawSpecValue" "" (body (fromValues (inputs e) ++ plainAll (handlerInstalls e) ++ resourceDocs e ++ [Plain check]))
          invocation = call "lsRefinedCase" [text "[]lawSpecDomain{" <> D.joinWith (text ", ") domains <> text "}",
            text "seed",number (maxAttempts cfg),number (maxShrinks cfg),callback,
            quoted (owner e ++ "::" ++ displayLabel (name e) ++ " | " ++ intercalate "; " (map (prettyExprWith True local) (concatMap inputRefinements (inputs e))))]
      pure $ testFunction (fn ++ "_Property") $ statements
        [text "defer " <> closure "" "" (text "if err := recover(); err != nil " <>
          block (text "t.Fatalf(\"%v\", err)")) <> text "()",
         text ("for seed := 0; seed < " ++ show (cases cfg) ++ "; seed++ ") <>
          block (body [symbols, Plain invocation])]
