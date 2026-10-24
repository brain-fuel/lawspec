-- | Hspec/Hedgehog documents over checked propositions and generation plans.
--
-- A law's tests are named after the law and their example
-- (lawNormalizersAgree_spacesBecomeHyphens), each is linked to its source
-- line, and they call the runtime (LawSpecTesting, LawSpecSchema) for what
-- every test shares, so a test module holds only its laws. The module is
-- laid out as ormolu lays it out (LawSpec.Code.Haskell).
-- ref:DEC-readable-output-default
module LawSpec.HaskellProperties (Config(..), emitTests, haskellReserved, wrapComment) where

import LawSpec.Bounds (inputRange, drawRange)
import LawSpec.Backend hiding (inputId, bindings, contractArguments, contractResult, Expr)
import LawSpec.Common
import LawSpec.Naming (exampleTestSuffix, boundaryTestSuffix, displayLabel, nameWords, cased, Casing(..))
import LawSpec.SourceLink (labelled, locationLink, exampleLocation, originLocation, generatedHeader, sourceLink)
import LawSpec.TestNames (unitTestNames)
import LawSpec.HaskellDefinitions (sortedImports)
import LawSpec.TargetNames (targetKeywords)
import LawSpec.Testing
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Code.Haskell as H
import LawSpec.Code.Haskell (Expr, Stmt(..), call, var, string, integer, dollar, lambda, operator)
import Data.Char (isAlphaNum)
import Data.List (intercalate, isInfixOf, nub, sortOn, stripPrefix)
import LawSpec.Scalar (Scalar(..))

-- | What the Haskell test emitter needs besides the plan: names, layout and
-- bindings, gathered so the emitter takes one argument.
data Config = Config
  { moduleName :: String
  -- The specification file the unit comes from, for the header.
  , sourceFile :: Maybe FilePath
  -- An async adapter's call, awaited.
  , awaitResult :: String -> Expr -> Expr
  , nativeGenerators :: Bool
  , hasDefinitions :: Bool
  , hasWorkflows :: Bool
  , constructorContracts :: Bool
  -- Built-in collections need LawSpecCollectionCodecs (and containers).
  , usesCollections :: Bool
  , nodeBudget :: Integer
  , reference :: Type -> Expr
  , machineBits :: Int
  , expression :: Expr' -> Expr
  , literal :: V.Value -> Either [Diagnostic] Expr
  , checked :: Type -> Expr -> Expr
  , structural :: Type -> Bool
  , typeKey :: Type -> String
  , generator :: Type -> Expr
  -- A generator drawing a top-level integer from a refinement's range.
  , generatorWithin :: Maybe (Integer, Integer) -> Type -> Expr
  , nativeArgument :: Type -> Expr -> Expr
  , nativeCall :: String -> [Expr] -> Expr
  , nativeResult :: Type -> Expr -> Expr
  -- The statements that install a law's handlers with symbols, for each case.
  , handlerInstalls :: Expanded -> [Stmt]
  -- The native handlers made with a resource, installed once the case has
  -- acquired its resources.
  , lateHandlerInstalls :: Expanded -> [Stmt]
  -- The unit's ability records and handlers, when it has abilities.
  , abilityModules :: Maybe (String, String)
  -- The modules of bound production handlers.
  , nativeImports :: [String]
  -- Each input's descriptor, for LawSpec's own search (LawSpec.Search):
  -- Nothing when the law takes no part in it.
  , searchDescriptors :: Expanded -> Maybe [String]
  -- Each binder's name in generated code.
  , local :: C.Id -> String
  -- The scalar codecs a module may name once: textCodec = Codec.textCodec ...
  , scalarCodecs :: [(String, Expr)]
  -- Whether an expression's value is already checked against its type: a
  -- primitive's literal, or an adapter's result its codec checked.
  , selfChecked :: Expr' -> Bool
  }

type Expr' = C.Expr

-- | Names generated test modules use in a case's scope, which a source
-- binder must not shadow: Haskell's keywords, the module's own names and
-- the unqualified names it calls.
haskellReserved :: [String]
haskellReserved = targetKeywords "haskell" ++ words
  "spec schema machineBits integerLimit symbols values seed passed check it parallel pendingWith runIO afterAll_ \
  \hedgehog modifyMaxSuccess forAll footnote evalIO evaluate pure fmap map sequence const show \
  \shouldBe main"

-- | Comment lines wrapped at whole words, as near the width as words allow.
-- A line that would start a Haddock comment is prefixed as ormolu does.
wrapComment :: Int -> [String] -> [String]
wrapComment width = concatMap (map guard . wrapLine . words)
  where
    wrapLine [] = [""]
    wrapLine ws = go [] ws
    go current [] = [unwords current | not (null current)]
    go current (w : rest)
      | not (null current) && length (unwords (current ++ [w])) > width = unwords current : go [w] rest
      | otherwise = go (current ++ [w]) rest
    guard line@(c : _) | c `elem` ("|^$*" :: String) = '\\' : line
    guard line = line

-- | Laws become tests in Haskell's own property framework, so they run with
-- the tools the project already uses. ref:DEC-native-property-frameworks
emitTests :: Config -> Unit -> [Expanded] -> Either [Diagnostic] D.Doc
emitTests Config{..} unit laws = do
  let testNames = unitTestNames "haskell" (map name laws)
  parts <- mapM (law testNames) (zip [0::Int ..] laws)
  contractDocs <- pure (map contract (contracts unit))
  let helpers = concatMap fst parts
      bodies = map snd parts
      body = ([Run (call "runIO" [call "LS.useVirtualClock" [integer 0]])] ++
        [Run (call "LawSpecHarness.parallelism" [string (C.idText (C.unitId unit))]) | parallel] ++
        -- Workflows read the Clock handler a law installs (any of them).
        [Run (call "runIO" [var "Lawspec.Time.registerClock"]) | readsClock] ++
        concat [Blank : b | b <- ordered (filter (not . null) bodies) ++ map benchmark (maybe [] C.harnessBenchmarks settings)])
      -- Shared resources are released after the unit's spec.
      specBody = if sharing then dollar (call "afterAll_" [var "LS.releaseShared"]) (H.Do body) else H.Do body
      declarations =
        [ D.joinWith D.hardline [H.comment ["The machine profile's integer width."],
            H.signature "machineBits" ["P.Int"], H.declaration "machineBits" (integer (toInteger machineBits))]
        , D.joinWith D.hardline [H.comment ["The program's types, which values are checked against."],
            H.signature "schema" ["Schema.Schema"], H.declaration "schema" (call "P.either" [var "P.error", var "P.id", var "DataSchema.schema"])] ] ++
        [D.joinWith D.hardline [H.comment ["The largest magnitude an unbounded integer is drawn with."],
            H.signature "integerLimit" ["P.Integer"], H.declaration "integerLimit" (operator "P.^" [integer 2, H.Typed (integer 256) "P.Int"])]
        | usesLimit ] ++
        [H.declaration n e | (n, e) <- scalarCodecs, n `elem` identifiers (D.render D.Compact (D.joinWith D.hardline (contractDocs ++ helpers ++ [H.expression specBody])))] ++
        contractDocs ++ helpers ++
        [D.joinWith D.hardline [H.signature "spec" ["Spec"], H.declaration "spec" specBody]]
      usesLimit = "integerLimit" `elem` identifiers (D.render D.Compact (D.joinWith D.hardline (contractDocs ++ helpers ++ [H.expression specBody])))
      rendered = D.render D.Compact (D.joinWith D.hardline declarations)
      used qualifier = (qualifier ++ ".") `isInfixOf` rendered
      usesWord w = w `elem` identifiers rendered
      imports = sortedImports (
        [ ("Prelude", Nothing, Nothing), ("Prelude", Just "P", Nothing), ("Test.Hspec", Nothing, Nothing)
        , (moduleName, Just "Impl", Nothing) ] ++
        [ ("Test.Hspec.Hedgehog", Nothing, Just (filter usesWord ["hedgehog", "modifyMaxSuccess"]))
        | any usesWord ["hedgehog", "modifyMaxSuccess"] ] ++
        [ ("Hedgehog", Nothing, Just (filter usesWord ["evalIO", "footnote", "forAll"]))
        | any usesWord ["evalIO", "footnote", "forAll"] ] ++
        [ ("Control.Exception", Nothing, Just ["evaluate"]) | usesWord "evaluate" ] ++
        [ (m, Just alias, Nothing) | (m, alias) <-
            [ ("Hedgehog", "Hedgehog"), ("Hedgehog.Gen", "Gen"), ("Hedgehog.Range", "Range")
            , ("LawSpecRuntime", "LS"), ("LawSpecTesting", "T"), ("LawSpecSchema", "Schema")
            , ("LawSpecDataSchema", "DataSchema"), ("LawSpecCodecs", "Codec"), ("LawSpecDataCodecs", "Codecs")
            , ("LawSpecDataStrategies", "Strategies"), ("LawSpecCollectionCodecs", "Collections")
            , ("LawSpecDefinitionBodies", "Definitions"), ("LawSpecWorkflows", "Workflows")
            , ("LawSpecNativeGenerators", "NativeGenerators") ] ++
            concat [[(records, "Abilities"), (handlers, "Handlers")] | Just (records, handlers) <- [abilityModules]]
        , used alias ] ++
        [ ("LawSpecRuntime", Nothing, Just ["Scalar (..)"]) | any usesWord scalarConstructors ] ++
        [ (m, Just m, Nothing) | m <- nub (nativeImports ++ ["LawSpecHarness", "Lawspec.Time"]), used m ])
  pure $ D.joinWith D.hardline (
      [D.text ("-- " ++ generatedHeader sourceFile)] ++
      -- Each performed operation must run where it is written, once.
      [D.text "{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}" <> D.hardline | Just _ <- [abilityModules]] ++
      [D.text ("module " ++ moduleName ++ "Spec (spec) where")]) <>
    D.hardline <> D.hardline <> D.joinWith D.hardline (map D.text imports) <> D.hardline <> D.hardline <>
    D.joinWith (D.hardline <> D.hardline) declarations <> D.hardline
  where
    scalarConstructors = words "SInteger SBool SDecimal SRational SFloat SComplex SSequence SCharacter SSymbol SAbsent SPresent SList SData"
    identifiers = words . map (\c -> if isAlphaNum c || c `elem` ("_'." :: String) then c else ' ')
    readsClock = clockReader unit
    -- The harness plane (LawSpec.Harness). A test the harness runs is an
    -- IO action bound with let (harness:name), which the generated example
    -- passes to the runtime; parallel marks every example parallel.
    settings = C.unitHarnessSettings unit
    -- order random: each law's tests in one block, the blocks in an order
    -- the run's seed chooses (LawSpecHarness.shuffled).
    ordered bodies
      | maybe False C.harnessOrderRandom settings =
          [[Run (call "LawSpecHarness.shuffled" [string (C.idText (C.unitId unit)), H.List [H.Do b | b <- bodies]])]]
      | otherwise = bodies
    sharing = any (\e -> any ((/= Nothing) . C.resourceShared) (C.propertyResources (original e))) laws
    parallel = maybe False C.harnessParallel settings
    inputId = local . C.binderId . C.quantifiedBinder
    testFunction testName body = case stripPrefix "harness:" testName of
      Just rest -> Let ("lawspecHarness" ++ takeWhile (/= ':') rest) (H.Do (doBody body))
      Nothing -> example testName (H.Do (doBody body))
    doBody body = if null body then [Run (call "pure" [var "()"])] else body
    -- Under parallel, the action is a block, so the chain of $ hangs.
    example testName action = Run (if parallel
      then dollar (var "parallel") (dollar (call "it" [string testName]) (case action of H.Do _ -> action; _ -> H.Do [Run action]))
      else dollar (call "it" [string testName]) action)
    runSettings h = C.harnessTimeout h /= Nothing || C.harnessRepeat h /= 1 || C.harnessRetries h /= 0 || observed h
    observed h = not (null (C.harnessCover h) && null (C.harnessClassify h) && null (C.harnessLabels h)) || C.harnessTarget h /= Nothing
    observations e =
      let h = C.propertyHarness (original e)
          label = owner e ++ "::" ++ name e
          pairs xs = H.List [H.Tuple [string l, truth (expr w)] | (l, w) <- xs]
      in [Run (call "LawSpecHarness.observe" [string label, pairs [(l, w) | C.Cover _ l w <- C.harnessCover h],
            pairs [(l, c) | (c, l) <- C.harnessClassify h], H.List (map expr (C.harnessLabels h))]) | observed h] ++
         [Run (call "LawSpecHarness.target" [expr score, string label]) | Just score <- [C.harnessTarget h]]
    -- The tests a law's harness wraps, skips or expects to fail.
    harnessTests fn label h kinds tests = case (C.harnessSkip h, C.harnessKnownFailing h) of
      (Just reason, _) -> [[example (fn ++ "_skipped: " ++ label) (call "pendingWith" [string reason])]]
      (_, Just reason) -> tests ++ [pure $ example (fn ++ "_knownFailing: " ++ label) (call "LawSpecHarness.knownFailing"
        [string label, string (fn ++ "_knownFailing"), string reason, H.List [var ("lawspecHarness" ++ fn ++ k) | k <- kinds]])]
      _ | runSettings h -> tests ++ [pure $ example (fn ++ k ++ (if k == "_property" then ": " ++ label else "")) (call "LawSpecHarness.run"
            [string label, string (fn ++ k), integer (maybe 0 id (C.harnessTimeout h)), integer (toInteger (C.harnessRepeat h)),
             integer (toInteger (C.harnessRetries h)),
             H.List [H.Tuple [integer (toInteger p), string l] | k == "_property", C.Cover p l _ <- C.harnessCover h],
             var (if k == "_property" && observed h then "True" else "False"), var ("lawspecHarness" ++ fn ++ k)]) | k <- kinds]
        | otherwise -> tests
    benchmark (n, b) = [example ("benchmark " ++ n) (H.Do [newSymbols,
      Run (call "LawSpecHarness.benchmark" [string n, operator "$!" [var "pure", expr b]])])]
    newSymbols = Bind "symbols" (var "LS.newSymbolContext")
    -- A case's statements, making symbols only when they are used.
    withSymbols stmts = if usesSymbols stmts then newSymbols : stmts else stmts
    usesSymbols stmts = "symbols" `elem` identifiers (D.render D.Compact (H.statements stmts))
    -- A Hedgehog property, checked with LAWSPEC_SEED's seed (T.holds).
    propertyTest fn label e body = case stripPrefix "harness:" fn of
      Nothing -> Run (dollar (call "modifyMaxSuccess" [call "const" [integer (toInteger (cases (generation e)))]])
        (dollar (call "it" [string (fn ++ "_property")]) (dollar (var "hedgehog") (H.Do body))))
      Just _ -> testFunction (fn ++ "_property") [Run (dollar (call "T.holdsFor" [integer (toInteger (cases (generation e)))]) (H.Do body))]
    -- A property whose inputs harness strategies draw, in Hedgehog's Gen.
    harnessProperty fn label e check = do
      let h = C.propertyHarness (original e)
          strategyOf inp = [(n, d) | (i, n, d) <- C.harnessDraws h, i == C.binderId (C.quantifiedBinder inp)]
      draws <- mapM (\plan -> do
        let inp = domainInput plan
        case strategyOf inp of
          (strategy, d) : _ -> Bind (inputId inp) <$> drawDoc inp strategy d
          [] -> pure (Bind (inputId inp) (generatorWithin (inputRange machineBits inp) (inputType inp)))) (generationPlan e)
      let names = H.List (map (var . inputId) (inputs e))
          defaults = [inp | inp <- inputs e, null (strategyOf inp)]
          predicates = concatMap inputRefinements defaults
          base = H.Do (draws ++ [Run (call "pure" [names])])
          strategy = if null predicates then base else call "Gen.filterT"
            [lambda [render names] (conjunction (map (truth . expr) predicates)), base]
          checks = [Run (call "LawSpecHarness.checkDrawn" [string strategy', string (inputName inp),
              conjunction (map (truth . expr) (inputRefinements inp)), var (inputId inp)])
            | inp <- inputs e, (strategy', _) : _ <- [strategyOf inp], not (null (inputRefinements inp))]
          body = [Bind "symbols" (call "evalIO" [var "LS.newSymbolContext"]),
            Bind (render names) (call "forAll" [strategy]),
            Run (call "footnote" [string label]),
            Run (dollar (var "evalIO") (H.Do (checks ++ handlerInstalls e ++ check)))]
      pure $ case stripPrefix "harness:" fn of
        Just _ -> propertyTest fn label e body
        Nothing -> example (fn ++ "_property")
          (dollar (call "T.holdsFor" [integer (toInteger (cases (generation e)))]) (H.Do body))
    drawDoc inp strategy d = case d of
      C.DrawAny ty aim -> pure (maybe (generator ty) (\range -> generatorWithin (Just range) ty) (drawRange machineBits inp ty aim))
      C.DrawOneOf _ values -> pure (call "Gen.element" [H.List (map expr values)])
      C.DrawFrequency alternatives -> do
        options <- mapM (\(w, a) -> (\g -> H.Tuple [integer (toInteger w), g]) <$> drawDoc inp strategy a) alternatives
        pure (call "Gen.frequency" [H.List options])
      C.DrawSuchThat inner binder predicate _ -> do
        g <- drawDoc inp strategy inner
        pure (call "Gen.filterT" [lambda [local (C.binderId binder)] (truth (expr predicate)), g])
      C.DrawBind binder from rest -> do
        fromG <- drawDoc inp strategy from
        restG <- drawDoc inp strategy rest
        pure (operator ">>=" [fromG, lambda [local (C.binderId binder)] restG])
    render = D.render D.Compact . H.expression
    expr = expression
    truth value = call "LS.truth" [value]
    conjunction [] = var "True"
    conjunction xs = operator "P.&&" xs
    -- An assertion names its law, its case and the source line it checks.
    assertionStmts context link proposition = case proposition of
      AssertAll ps -> concatMap (assertionStmts context link) ps
      AssertImplies guard body -> [Run (H.If (truth (expr guard)) (H.Do (doBody (assertionStmts context link body))) (call "pure" [var "()"]))]
      AssertEqual a b -> [Run (call "T.assertEqual"
        [context (maybe "" (" — " ++) (expectationLink a link)),
         side a, side b])]
    side x = if selfChecked x then expr x else checked (expressionType x) (expr x)
    -- The line an expectation is written on, else the law's.
    expectationLink a link = case originLocation (C.expressionOrigin a) of
      Just l | take 1 (file l) /= "<" -> Just (locationLink l)
      _ -> link
    contract c =
      let args = [(local (C.binderId b), C.binderType b) | b <- C.contractArguments c]
          resultBinder = C.contractResult c
          rn = local (C.binderId resultBinder)
          rt = C.binderType resultBinder
          context stage ps = string (contractName c ++ " " ++ stage ++ ": " ++ intercalate " && " (map (prettyExprWith True local) ps))
          require stage ps body = call "LS.contract" [context stage ps, conjunction (map (truth . expr) ps), body]
          invocation = awaitResult (adapterName unit (C.contractDeclaration c)) (nativeCall (contractName c) [nativeArgument ty (var n) | (n, ty) <- args])
          result = nativeResult rt invocation
          post = call "LS.forcing" [H.List [var rn], require "postcondition" (contractPostconditions c) (var rn)]
          body = require "precondition" (contractPreconditions c) (H.LetIn [(rn, result)] post)
          helper = contractHelper c
      in D.joinWith D.hardline
        [ H.comment (wrapComment 78 [labelled ("contract of " ++ contractName c)
            (case [C.declarationOrigin d | d <- C.unitDeclarations unit, C.declarationId d == C.contractDeclaration c] of
               origin : _ -> sourceLink origin
               [] -> Nothing)])
        , H.signature helper (["LS.SymbolContext"] ++ replicate (length args + 1) "Scalar")
        , H.declaration (unwords (helper : "symbols" : map fst args)) body ]
    -- A law's resources: each case acquires them, then runs, then releases
    -- them, the last first, even when the case fails. A built-in resource is
    -- acquired in IO, so each case gets its own.
    bracketed e stmts = foldr wrap (lateHandlerInstalls e ++ stmts) (C.propertyResources (original e))
      where
        -- A shared resource (share R per ...): the runtime keeps one per
        -- scope key, resets it before each later use, holds it for one case
        -- at a time, and releases it after the unit's spec.
        wrap r inner | Just key <- C.resourceShared r, Just reset <- C.resourceReset r =
          let name' = local (C.binderId (C.resourceBinder r))
              using body = lambda [name'] (call "evaluate" [call "LS.forceScalar" [expr body]])
          in [Run (dollar (call "LS.withShared" [string key, var (if C.resourceConcurrent r then "P.True" else "P.False"),
               call "pure" [expr (C.resourceAcquire r)], using reset, using (C.resourceRelease r)])
               (lambda [name'] (H.Do (doBody inner))))]
        wrap r inner =
          let name' = local (C.binderId (C.resourceBinder r))
              (acquire, release) = case builtin r of
                Just (kind, tag) -> (call "LS.acquireBuiltin" [string kind, string tag], call "LS.releaseBuiltin" [string kind])
                Nothing -> (call "pure" [expr (C.resourceAcquire r)],
                  lambda [name'] (call "evaluate" [call "LS.forceScalar" [expr (C.resourceRelease r)]]))
          in [Run (dollar (call "LS.withResource" [acquire, release]) (lambda [name'] (H.Do (doBody inner))))]
        builtin r = case C.expressionNode (C.resourceAcquire r) of
          C.Construct tag [argument] | C.Helper h [kind] <- C.expressionNode argument, h `elem` [C.AcquireResource, C.FreePort]
            , C.Constant (SSequence _ points) <- C.expressionNode kind -> Just (map toEnum points, C.idText tag)
          _ -> Nothing
    camel = cased Camel . concatMap nameWords . splitUnderscore
    splitUnderscore s = case break (== '_') s of
      (a, []) -> [a]
      (a, _ : rest) -> a : splitUnderscore rest
    law testNames (index,e) = do
      let label = owner e ++ "::" ++ name e
          shown = owner e ++ "::" ++ displayLabel (name e)
          h = C.propertyHarness (original e)
          base' = testNames !! index
          short = case stripPrefix "law" base' of
            Just (c : rest) -> cased Camel (nameWords (c : rest))
            _ -> base'
          fn = (if C.harnessSkip h == Nothing && (C.harnessKnownFailing h /= Nothing || runSettings h) then "harness:" else "") ++ base'
          lawLink = propertyLink (original e)
          boundaryValues = maybe (boundaryCases e) id (finiteCases e)
          shareBoundaries = length boundaryValues >= 64
          boundaryName = short ++ "Boundary"
          bind' inp value = Let (inputId inp) value
          boundaryBody values check = handlerInstalls e ++
            [bind' inp (checked (inputType inp) value) | (inp,value) <- zip (inputs e) values] ++
            bracketed e check
          -- Examples are named by their words (lawX_spacesBecomeHyphens),
          -- boundaries numbered from 1.
          exampleSuffixes = map camel (exampleTestSuffix "haskell"
            ("property" : "replay" : "search" : "skipped" : "known_failing" : map boundaryTestSuffix [0 .. length boundaryValues - 1])
            (map exampleName (examples (original e))))
          -- Keep every case independently registered, but compile its handler
          -- setup and checked assertion once. Large repeated bodies otherwise
          -- exceed native assembler branch ranges even without optimization.
          boundaryHelpers = [D.joinWith D.hardline
            [ D.text ("{-# NOINLINE " ++ boundaryName ++ " #-}")
            , H.signature boundaryName ["P.String", "(LS.SymbolContext -> [Scalar])", "P.IO ()"]
            , H.declaration (boundaryName ++ " context values") (H.Do (withSymbols (boundaryBody
                [operator "P.!!" [call "values" [var "symbols"], integer (toInteger i)] | i <- [0 .. length (inputs e) - 1]]
                (assertionStmts (\suffix -> operator "P.++" [var "context", string suffix]) lawLink (assertion e))))) ]
            | shareBoundaries]
          examplesLinked = [ (suffix, ex) | (suffix, ex) <- zip exampleSuffixes (examples (original e)) ]
      exampleDocs <- mapM (\(suffix, ex) -> do
        let exLink = maybe lawLink (Just . locationLink) (exampleLocation ex)
            context = shown ++ " example " ++ displayLabel (exampleName ex)
        pure [ Comment (wrapComment 78 [labelled ("example " ++ displayLabel (exampleName ex)) exLink])
             , testFunction (fn ++ "_" ++ suffix) (withSymbols
                (handlerInstalls e ++ [Let (local i) (expr v) | (i,v) <- C.exampleBindings ex] ++
                 bracketed e (concatMap (assertionStmts (string . (context ++)) exLink) (expectations ex) ++
                   assertionStmts (string . (shown ++)) lawLink (assertion e)))) ]) examplesLinked
      boundaryDocs <- mapM (\(i,vs) -> do
        values <- mapM literal vs
        let suffix = camel (boundaryTestSuffix i)
            context = shown ++ " boundary " ++ show (i + 1)
        pure [ Comment (wrapComment 78 [labelled (displayLabel (name e) ++ ", boundary " ++ show (i + 1)) lawLink])
             , testFunction (fn ++ "_" ++ suffix)
                (if shareBoundaries then [Run (call boundaryName [string context, lambda ["symbols"] (H.List values)])]
                 else withSymbols (boundaryBody values (assertionStmts (string . (context ++)) lawLink (assertion e)))) ])
        (zip [0::Int ..] boundaryValues)
      -- LawSpec's own search (LawSpec.Search): the failure database's
      -- inputs are replayed before the law's generated cases, a failing
      -- case's inputs are kept, and a law with `target maximize` climbs
      -- after them, as Hedgehog has no targeting.
      let descriptors = searchDescriptors e
          inputsName = short ++ "Inputs"
          caseName = short ++ "Case"
          names = H.List (map (var . inputId) (inputs e))
          remembered stmts = case descriptors of
            Nothing -> stmts
            Just _ -> [Run (dollar (call "LS.searchGuard" [string label, var inputsName, names]) (H.Do stmts))]
          (searchBefore, searchAfter) = case descriptors of
            Nothing -> ([], [])
            Just ds ->
              let refinements = concatMap inputRefinements (inputs e)
                  score = maybe (integer 0) (\s' -> call "LS.searchNumber" [checked (expressionType s') (expr s')]) (C.harnessTarget h)
                  checking = bracketed e (assertionStmts (string . ((shown ++ " search") ++)) lawLink (assertion e)) ++
                    [Run (call "P.pure" [call "P.Just" [score]])]
              in ( [ Let inputsName (H.List (map string ds))
                   , Let (caseName ++ " values") (H.Do (withSymbols (handlerInstalls e ++
                       [bind' inp (checked (inputType inp) (operator "!!" [var "values", integer (toInteger i)])) | (i, inp) <- zip [0::Int ..] (inputs e)] ++
                       (if null refinements then checking
                        else [Run (H.If (call "P.not" [conjunction (map (truth . expr) refinements)]) (call "P.pure" [var "P.Nothing"]) (H.Do checking))]))))
                   , example (base' ++ "_replay") (call "LS.searchReplay" [string label, var inputsName, var caseName]) ]
                 , [example (base' ++ "_search") (call "LS.searchClimb" [string label, var inputsName, var caseName]) | C.harnessTarget h /= Nothing] )
      let check = bracketed e (observations e ++ remembered (assertionStmts (string . ((shown ++ " property") ++)) lawLink (assertion e)))
      property <- if finiteCases e /= Nothing then pure []
        else if not (null (C.harnessDraws h)) then (:[]) <$> harnessProperty fn label e check
        else if nativeGenerators || constructorContracts || any (maybe False (const True) . generatorIndex) (generationPlan e)
          then (:[]) <$> contextualProperty fn label e check
        else if any (structural . inputType) (inputs e) then pure [nativeProperty fn label e check]
        else if any (not . null . inputRefinements) (inputs e) || propertyKind e == "contract"
          then (:[]) <$> refinedProperty fn label e check
          else pure [nativeProperty fn label e check]
      let kinds = ["_" ++ s | s <- take (length exampleDocs) exampleSuffixes] ++
            ["_" ++ camel (boundaryTestSuffix i) | i <- [0 .. length boundaryDocs - 1]] ++
            ["_property" | not (null property)]
          tests = exampleDocs ++ boundaryDocs ++ map pure property
          lawComment = Comment (wrapComment 78 (lawLine (lawCommentLines e)))
          lawLine (first : rest) = ("law " ++ first) : rest
          lawLine [] = []
          groups = filter (not . null) ([searchBefore] ++ harnessTests base' label h kinds tests ++ map pure searchAfter)
      -- A law with no tests here (its cases are all excluded) has no block.
      pure (boundaryHelpers, if null groups then [] else lawComment : intercalate [Blank] groups)
    -- The search case's statements sit in an if: run them as one block.
    contextualProperty fn label e check = do
      draws <- mapM (\plan -> do
        seeds <- mapM literal (generatorBoundaries plan)
        let inp = domainInput plan
            ty = inputType inp
            hints = [expr hint | hint <- generatorHints plan, expressionType hint == ty,
              case C.expressionNode hint of C.Constant _ -> True; C.Local _ -> True; _ -> False]
            scalar = case inputRange machineBits inp of
              Nothing -> call "Strategies.primitiveStrategy" [var "machineBits"]
              Just range -> lambda ["scalarName"]
                (H.If (operator "P.==" [var "scalarName", string (typeKey ty)])
                  (call "P.Right" [generatorWithin (Just range) ty])
                  (call "Strategies.primitiveStrategy" [var "machineBits", var "scalarName"]))
            strategy = case requiredSymbol plan of
              value:_ -> call "pure" [expr value]
              -- The target is evaluated from the inputs drawn above.
              [] | Just indexed <- generatorIndex plan -> orFail (call "Strategies.indexedStrategy"
                [var "schema", reference ty, var "machineBits", integer nodeBudget,
                 expr (indexedTarget indexed),
                 H.List [H.Tuple [string (C.idText tag), H.List (map string texts)] | (tag,texts) <- indexedEquations indexed],
                 call "Strategies.primitiveStrategy" [var "machineBits"]])
              [] -> orFail (call (if nativeGenerators then "Strategies.checkedStrategyWith" else "Strategies.checkedStrategy")
                ([call "NativeGenerators.factories" [var "symbols", var "schema", var "machineBits"] | nativeGenerators] ++
                 [var "schema", reference ty, var "machineBits", integer nodeBudget,
                  call "P.Just" [var "symbols"], H.List (seeds ++ hints), scalar]))
        pure ([Bind (inputId inp) strategy] ++
          [Run (dollar (call "LS.forcing" [H.List [var (inputId inp)]]) (call "pure" [var "()"])) | not nativeGenerators])) (generationPlan e)
      let names = H.List (map (var . inputId) (inputs e))
          base = H.Do (concat draws ++ [Run (call "pure" [names])])
          predicates = concatMap inputRefinements (inputs e)
          strategy = if null predicates then base else call "Gen.filterT"
            [lambda [render names] (conjunction (map (truth . expr) predicates)), base]
          draw = if nativeGenerators then call "Hedgehog.forAllWith"
            [lambda ["_"] (string "native generated inputs"), strategy] else call "forAll" [strategy]
          body = [Bind "symbols" (call "evalIO" [var "LS.newSymbolContext"]), Bind (render names) draw] ++
            [Run (call "evalIO" [call "evaluate" [call "LS.forceScalar" [var (inputId inp)]]]) |
              nativeGenerators, inp <- inputs e] ++
            [Run (call "footnote" [call "show" [names]]) | nativeGenerators] ++
            [Run (call "footnote" [string label]), Run (dollar (var "evalIO") (H.Do (handlerInstalls e ++ check)))]
          cfg = generation e
          holds = call "T.holds" [integer (toInteger (cases cfg)), integer (toInteger (maxAttempts cfg)), integer (toInteger (maxShrinks cfg))]
      pure $ case stripPrefix "harness:" fn of
        Just _ -> testFunction (fn ++ "_property") [Run (dollar holds (H.Do body))]
        Nothing -> example (fn ++ "_property") (dollar holds (H.Do body))
    orFail x = call "P.either" [var "P.error", var "P.id", x]
    requiredSymbol plan
      | nativeGenerators = []
      | inputType (domainInput plan) /= C.scalarType "Symbol" = []
      | otherwise = concatMap required (generatorPredicates plan)
      where
        current = C.binderId (generatorBinder plan)
        required term = case C.expressionNode term of
          C.ShortCircuit C.And a b -> required a ++ required b
          C.Binary C.Equal _ a b -> [value | (local',value) <- [(a,b),(b,a)],
            C.expressionNode local' == C.Local current,
            expressionType value == C.scalarType "Symbol",
            current `notElem` C.freeBinders value,
            case C.expressionNode value of C.Constant _ -> True; C.Local _ -> True; _ -> False]
          _ -> []
    nativeProperty fn label e check =
      let names = H.List (map (var . inputId) (inputs e))
          predicates = concatMap inputRefinements (inputs e)
          base = call "fmap" [call "map" [call "LS.scopeSymbols" [var "symbols"]],
            call "sequence" [H.List [hinted inp (generatorWithin (inputRange machineBits inp) (inputType inp)) | inp <- inputs e]]]
          -- Constant hints (regex samples, compared literals) are mixed in so
          -- a narrow refinement still meets the filter often enough.
          hinted inp generator' = case [expr hint | plan <- generationPlan e,
              inputId (domainInput plan) == inputId inp, hint <- generatorHints plan,
              expressionType hint == inputType inp, expressionType hint /= C.scalarType "Symbol",
              case C.expressionNode hint of C.Constant _ -> True; _ -> False] of
            [] -> generator'
            hints -> call "Gen.choice" [H.List [call "Gen.element" [H.List hints], generator']]
          strategy = if null predicates then base else call "Gen.filter"
            [lambda [render names] (conjunction (map (truth . expr) predicates)), base]
      in propertyTest fn label e
        [Bind "symbols" (call "evalIO" [var "LS.newSymbolContext"]), Bind (render names) (call "forAll" [strategy]),
         Run (call "footnote" [string label]),
         Run (dollar (var "evalIO") (H.Do (handlerInstalls e ++ check)))]
    domain e (index,plan) = do
      seeds <- mapM literal (generatorBoundaries plan)
      let inp = domainInput plan
          prior = take index (inputs e)
          bindingsOf xs = [(inputId input, operator "!!" [var "values", integer (toInteger i)]) | (i,input) <- zip [0::Int ..] xs]
          closure xs args body = lambda args (if null xs then body else H.LetIn (bindingsOf xs) body)
          bounds = H.List [H.Tuple [string op, expr v] | (op,v) <- domainBounds plan]
          candidates = call "LS.domainCandidates" [string (typeKey (inputType inp)), var "seed", var "machineBits",
            bounds, H.List (seeds ++ map expr (generatorHints plan))]
      pure (call "LS.Domain" [closure prior ["values", "seed"] candidates,
        closure (prior ++ [inp]) ["values"] (conjunction (map (truth . expr) (inputRefinements inp)))])
    refinedProperty fn label e check = do
      domains <- mapM (domain e) (zip [0::Int ..] (generationPlan e))
      let cfg = generation e
          callback = Let "check values" (H.Do ([Let (inputId input) (operator "!!" [var "values", integer (toInteger i)]) | (i, input) <- zip [0::Int ..] (inputs e)] ++
            handlerInstalls e ++ check))
          invocation = call "LS.refinedCase" [H.List domains, var "seed", integer (toInteger (maxAttempts cfg)), integer (toInteger (maxShrinks cfg)), var "check",
            string (label ++ " | " ++ intercalate "; " (map (prettyExprWith True (sourceNames (original e))) (concatMap inputRefinements (inputs e))))]
      pure $ propertyTest fn label e
        [Bind "symbols" (call "evalIO" [var "LS.newSymbolContext"]),
         Bind "seed" (call "forAll" [call "Gen.int" [call "Range.linear" [integer 0, integer 2147483647]]]),
         Run (call "footnote" [string label]), callback, Run (call "evalIO" [invocation])]
    contractHelper c = "checked" ++ capital (contractName c)
    capital (x : xs) = toEnum (fromEnum x - (if x >= 'a' && x <= 'z' then 32 else 0)) : xs
    capital [] = []

-- Whether a unit's laws install a Clock handler, so the test registers how
-- workflows read one (lawspec.time's registerClock).
clockReader :: Unit -> Bool
clockReader unit = or [ C.abilityKey a == "lawspec.time::ability::Clock"
                      | p <- C.unitProperties unit, (a, _) <- C.propertyHandlers p ]
