-- | Hspec/Hedgehog documents over checked propositions and generation plans.
module LawSpec.HaskellProperties (Config(..), emitTests) where

import LawSpec.Bounds (inputRange)
import LawSpec.Backend
import LawSpec.Common
import LawSpec.TestNames (unitTestNames)
import LawSpec.Testing
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.HaskellExpr as E
import qualified LawSpec.HaskellTestHelpers as Helpers
import Data.List (intercalate, stripPrefix)
import LawSpec.Scalar (Scalar(..))

-- | What the Haskell test emitter needs besides the plan: names, layout and
-- bindings, gathered so the emitter takes one argument.
data Config = Config
  { moduleName :: String
  -- An async adapter's call, awaited.
  , awaitResult :: String -> D.Doc -> D.Doc
  , nativeGenerators :: Bool
  , hasDefinitions :: Bool
  , hasWorkflows :: Bool
  , constructorContracts :: Bool
  -- Built-in collections need LawSpecCollectionCodecs (and containers).
  , usesCollections :: Bool
  , nodeBudget :: Integer
  , reference :: Type -> D.Doc
  , machineBits :: Int
  , expression :: Expr -> D.Doc
  , literal :: V.Value -> Either [Diagnostic] D.Doc
  , checked :: Type -> D.Doc -> D.Doc
  , structural :: Type -> Bool
  , typeKey :: Type -> String
  , generator :: Type -> D.Doc
  -- A generator drawing a top-level integer from a refinement's range.
  , generatorWithin :: Maybe (Integer, Integer) -> Type -> D.Doc
  , nativeArgument :: Type -> D.Doc -> D.Doc
  , nativeCall :: String -> [D.Doc] -> D.Doc
  , nativeResult :: Type -> D.Doc -> D.Doc
  -- The statements that install a law's handlers with symbols, for each case.
  , handlerInstalls :: Expanded -> [D.Doc]
  -- The unit's ability records and handlers, when it has abilities.
  , abilityModules :: Maybe (String, String)
  -- The modules of bound production handlers.
  , nativeImports :: [String]
  -- Each input's descriptor, for LawSpec's own search (LawSpec.Search):
  -- Nothing when the law takes no part in it.
  , searchDescriptors :: Expanded -> Maybe [String]
  }

text = D.text
statements = D.joinWith D.hardline
separate = D.joinWith (D.hardline <> D.hardline)
quoted :: String -> D.Doc
quoted = E.quoted
number :: Show a => a -> D.Doc
number = text . show
apply = E.apply
parens = E.parens
runtime name = apply ("LS." ++ name)
truth value = runtime "truth" [value]
bind name value = text ("let " ++ name ++ " =") <> D.nest 6 (D.hardline <> value)
conjunction [] = text "True"
conjunction xs = D.group (D.joinWith (D.softline <> text "&& ") (map parens xs))
symbols = text "symbols <- LS.newSymbolContext"
fromValues xs = statements [bind (inputId input) (text ("_values !! " ++ show index)) |
  (index,input) <- zip [0::Int ..] xs]
-- Explicit let braces also keep compact expressions independent of layout.
letIn bindings body = D.group (text "let {" <> D.nest 2 (D.softline <>
  D.joinWith (text ";" <> D.softline) [D.group (text (name ++ " =") <> D.nest 2 (D.softline <> value)) | (name,value) <- bindings]) <>
  D.softline <> text "} in" <> D.nest 2 (D.softline <> body))
lambda args body = D.group (text ("\\" ++ args ++ " ->") <> D.nest 2 (D.softline <> body))
sequenceDocs docs = statements (if null docs then [text "pure ()"] else docs)

-- | Laws become tests in Haskell's own property framework, so they run with
-- the tools the project already uses. ref:DEC-native-property-frameworks
emitTests :: Config -> Unit -> [Expanded] -> Either [Diagnostic] D.Doc
emitTests Config{..} unit laws = do
  let testNames = unitTestNames "haskell" (map name laws)
  bodies <- mapM (law testNames) (zip [0::Int ..] laws)
  let imports = ["import qualified Prelude as P", "import Prelude", "import Test.Hspec",
        "import Control.Exception (SomeException, catch, displayException, evaluate)",
        "import Test.Hspec.Hedgehog (hedgehog, modifyMaxSuccess)",
        "import Hedgehog (forAll, evalIO, footnote)",
        "import qualified Hedgehog",
        "import qualified Hedgehog.Gen as Gen", "import qualified Hedgehog.Range as Range",
        "import qualified Hedgehog.Internal.Config as HedgehogConfig",
        "import qualified Hedgehog.Internal.Region as HedgehogRegion",
        "import qualified Hedgehog.Internal.Report as HedgehogReport",
        "import qualified Hedgehog.Internal.Runner as HedgehogRunner",
        "import qualified Hedgehog.Internal.Seed as HedgehogSeed",
        "import qualified System.Environment",
        "import LawSpecRuntime (Scalar(..))", "import qualified LawSpecRuntime as LS",
        "import qualified " ++ moduleName ++ " as Impl"] ++
        ["import qualified LawSpecHarness" | harnessed] ++
        ["import qualified LawSpecDefinitionBodies as Definitions" | hasDefinitions] ++
        ["import qualified LawSpecWorkflows as Workflows" | hasWorkflows] ++
        ["import qualified LawSpecNativeGenerators as NativeGenerators" | nativeGenerators] ++
        ["import qualified LawSpecSchema as Schema", "import qualified LawSpecDataSchema as DataSchema",
         "import qualified LawSpecCodecs as Codec", "import qualified LawSpecDataCodecs as Codecs",
         "import qualified LawSpecDataStrategies as Strategies"] ++
        ["import qualified LawSpecCollectionCodecs as Collections" | usesCollections] ++
        concat [["import qualified " ++ records ++ " as Abilities", "import qualified " ++ handlers ++ " as Handlers"]
               | Just (records, handlers) <- [abilityModules]] ++
        ["import qualified " ++ m | m <- nativeImports]
  pure $ statements ([text "-- Generated by LawSpec."] ++
      -- Each performed operation must run where it is written, once.
      [text "{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}" | Just _ <- [abilityModules]] ++
      [text ("module " ++ moduleName ++ "Spec (spec) where")]) <>
    D.hardline <> D.hardline <> statements (map text imports) <> D.hardline <> D.hardline <>
    separate ([Helpers.schemaDoc,Helpers.assertionDoc,seedDoc] ++ map contract (contracts unit)) <>
    D.hardline <> D.hardline <> text "spec :: Spec" <> D.hardline <>
    -- Shared resources are released after the unit's spec.
    text (if sharing then "spec = afterAll_ LS.releaseShared $ do" else "spec = do") <>
    -- Workflows wait on a virtual clock under test.
    D.nest 2 (D.hardline <> text "runIO (LS.useVirtualClock 0)" <> D.hardline <>
      (if parallel then apply "LawSpecHarness.parallelism" [quoted (C.idText (C.unitId unit))] <> D.hardline else mempty) <>
      (if null bodies then text "pure ()" else separate (ordered bodies ++ map benchmark (maybe [] C.harnessBenchmarks settings)))) <> D.hardline
  where
    -- The harness plane (LawSpec.Harness). A test the harness runs is an
    -- IO action bound with let (harness:name), which the generated example
    -- passes to the runtime; parallel marks every example parallel.
    settings = C.unitHarnessSettings unit
    -- order random: each law's tests in one block, the blocks in an order
    -- the run's seed chooses (LawSpecHarness.shuffled).
    ordered docs
      | maybe False C.harnessOrderRandom settings =
          [text "LawSpecHarness.shuffled " <> quoted (C.idText (C.unitId unit)) <> D.nest 2 (D.hardline <> text "[ " <>
            D.joinWith (D.hardline <> text ", ") [text "do" <> D.nest 4 (D.hardline <> d) | d <- docs] <> D.hardline <> text "]")]
      | otherwise = docs
    sharing = any (\e -> any ((/= Nothing) . C.resourceShared) (C.propertyResources (original e))) laws
    harnessed = settings /= Nothing
    parallel = maybe False C.harnessParallel settings
    testFunction name body = case stripPrefix "harness:" name of
      Just rest -> text "let" <> D.nest 4 (D.hardline <> text ("lawspecHarness" ++ takeWhile (/= ':') rest ++ " = do") <>
        D.nest 2 (D.hardline <> sequenceDocs body))
      Nothing -> example name (text "do" <> D.nest 2 (D.hardline <> sequenceDocs body))
    example name action = (if parallel then text "parallel $ " else mempty) <> apply "it" [quoted name] <> text " $ " <> action
    runSettings h = C.harnessTimeout h /= Nothing || C.harnessRepeat h /= 1 || C.harnessRetries h /= 0 || observed h
    observed h = not (null (C.harnessCover h) && null (C.harnessClassify h) && null (C.harnessLabels h)) || C.harnessTarget h /= Nothing
    observations e =
      let h = C.propertyHarness (original e)
          label = owner e ++ "::" ++ name e
          pairs xs = E.array [D.delimit 2 "(" ")" [quoted l, truth (expr w)] | (l, w) <- xs]
      in [apply "LawSpecHarness.observe" [quoted label, pairs [(l, w) | C.Cover _ l w <- C.harnessCover h],
            pairs [(l, c) | (c, l) <- C.harnessClassify h], E.array (map expr (C.harnessLabels h))] | observed h] ++
         [apply "LawSpecHarness.target" [expr score, quoted label] | Just score <- [C.harnessTarget h]]
    -- The tests a law's harness wraps, skips or expects to fail.
    harnessTests fn label h kinds docs = case (C.harnessSkip h, C.harnessKnownFailing h) of
      (Just reason, _) -> [example (fn ++ "_skipped: " ++ label) (apply "pendingWith" [quoted reason])]
      (_, Just reason) -> docs ++ [example (fn ++ "_knownFailing: " ++ label) (apply "LawSpecHarness.knownFailing"
        [quoted label, quoted (fn ++ "_knownFailing"), quoted reason, E.array [text ("lawspecHarness" ++ fn ++ k) | k <- kinds]])]
      _ | runSettings h -> docs ++ [example (fn ++ k ++ (if k == "_property" then ": " ++ label else "")) (apply "LawSpecHarness.run"
            [quoted label, quoted (fn ++ k), number (maybe 0 id (C.harnessTimeout h)), number (C.harnessRepeat h), number (C.harnessRetries h),
             E.array [D.delimit 2 "(" ")" [number p, quoted l] | k == "_property", C.Cover p l _ <- C.harnessCover h],
             text (if k == "_property" && observed h then "True" else "False"), text ("lawspecHarness" ++ fn ++ k)]) | k <- kinds]
        | otherwise -> docs
    benchmark (n, b) = example ("benchmark " ++ n) (text "do" <> D.nest 2 (D.hardline <> statements [symbols,
      apply "LawSpecHarness.benchmark" [quoted n, parens (text "pure $! " <> expr b)]]))
    -- A Hedgehog property inside hspec, or, for a test the harness runs, as
    -- an IO action.
    propertyTest fn label e body = case stripPrefix "harness:" fn of
      Nothing -> propertyHeader fn label e <> D.nest 2 (D.hardline <> body)
      Just _ -> testFunction (fn ++ "_property") [text "_passed <- _lawspecCheck $ Hedgehog.withTests " <> number (cases (generation e)) <>
        text " $ Hedgehog.property $ do" <> D.nest 2 (D.hardline <> body), text "_passed `shouldBe` True"]
    -- A property whose inputs harness strategies draw, in Hedgehog's Gen.
    harnessProperty fn label e check = do
      let h = C.propertyHarness (original e)
          strategyOf inp = [(n, d) | (i, n, d) <- C.harnessDraws h, i == C.binderId (C.quantifiedBinder inp)]
      draws <- mapM (\plan -> do
        let inp = domainInput plan
        case strategyOf inp of
          (strategy, d) : _ -> (\g -> text (inputId inp ++ " <-") <> D.nest 2 (D.hardline <> g)) <$> drawDoc inp strategy d
          [] -> pure (text (inputId inp ++ " <-") <> D.nest 2 (D.hardline <> generatorWithin (inputRange machineBits inp) (inputType inp)))) (generationPlan e)
      let names = E.array (map (text . inputId) (inputs e))
          defaults = [inp | inp <- inputs e, null (strategyOf inp)]
          predicates = concatMap inputRefinements defaults
          base = D.multiline (text "do" <> D.nest 2 (D.hardline <> statements (draws ++ [apply "pure" [names]])))
          strategy = if null predicates then base else apply "Gen.filterT"
            [D.group (text "\\" <> names <> text " ->" <> D.nest 2 (D.softline <> conjunction (map (truth . expr) predicates))), base]
          checks = [apply "LawSpecHarness.checkDrawn" [quoted strategy', quoted (inputName inp),
              conjunction (map (truth . expr) (inputRefinements inp)), text (inputId inp)]
            | inp <- inputs e, (strategy', _) : _ <- [strategyOf inp], not (null (inputRefinements inp))]
          body = statements [text "symbols <- evalIO LS.newSymbolContext",
            D.group (names <> text " <-" <> D.nest 2 (D.softline <> apply "forAll" [strategy])),
            apply "footnote" [quoted label],
            text "evalIO $ do" <> D.nest 2 (D.hardline <> statements (checks ++ handlerInstalls e ++ [check]))]
      pure $ case stripPrefix "harness:" fn of
        Just _ -> propertyTest fn label e body
        Nothing -> testFunction (fn ++ "_property: " ++ label) [text "_passed <- _lawspecCheck $ Hedgehog.withTests " <> number (cases (generation e)) <>
          text " $ Hedgehog.property $ do" <> D.nest 2 (D.hardline <> body), text "_passed `shouldBe` True"]
    drawDoc inp strategy d = case d of
      C.DrawAny ty -> pure (parens (if ty == inputType inp then generatorWithin (inputRange machineBits inp) ty else generator ty))
      C.DrawOneOf _ values -> pure (parens (apply "Gen.element" [E.array (map expr values)]))
      C.DrawFrequency alternatives -> do
        options <- mapM (\(w, a) -> (\g -> D.delimit 2 "(" ")" [number w, g]) <$> drawDoc inp strategy a) alternatives
        pure (parens (apply "Gen.frequency" [E.array options]))
      C.DrawSuchThat inner binder predicate _ -> do
        g <- drawDoc inp strategy inner
        pure (parens (apply "Gen.filterT" [parens (lambda (localName (C.binderId binder)) (truth (expr predicate))), g]))
      C.DrawBind binder from rest -> do
        fromG <- drawDoc inp strategy from
        restG <- drawDoc inp strategy rest
        pure (parens (fromG <> text " >>= " <> parens (lambda (localName (C.binderId binder)) restG)))
    -- LAWSPEC_SEED fixes the seed of properties checked directly with
    -- Hedgehog; hspec's HSPEC_SEED seeds the others. lawspec test sets both,
    -- and records the seed of every passing run.
    seedDoc = statements (map text
      [ "_lawspecCheck :: Hedgehog.Property -> P.IO P.Bool"
      , "_lawspecCheck property = do"
      , "  seed <- System.Environment.lookupEnv \"LAWSPEC_SEED\""
      , "  color <- HedgehogConfig.detectColor"
      , "  HedgehogRegion.displayRegion (\\region -> (P.== HedgehogReport.OK) P.. HedgehogReport.reportStatus P.<$>"
      , "    HedgehogRunner.checkNamed region color P.Nothing (P.fmap (HedgehogSeed.from P.. P.read) seed) property)" ])
    expr = expression
    assertionDoc context proposition = case proposition of
      AssertAll ps -> sequenceDocs (map (assertionDoc context) ps)
      AssertImplies guard body -> text "if " <> D.nest 2 (parens (truth (expr guard))) <>
        D.nest 2 (D.hardline <> text "then do" <> D.nest 2 (D.hardline <> assertionDoc context body) <>
          D.hardline <> text "else pure ()")
      AssertEqual a b -> apply "_lawspecAssert"
        [quoted (context ++ " | expect " ++ prettyExpr a ++ " = " ++ prettyExpr b),
         checked (expressionType a) (expr a),checked (expressionType b) (expr b)]
    contract c =
      let args = contractArguments c
          (rn,rt) = contractResult c
          context stage ps = quoted (contractName c ++ " " ++ stage ++ ": " ++ intercalate " && " (map prettyExpr ps))
          require stage ps body = runtime "contract" [context stage ps,conjunction (map (truth . expr) ps),body]
          invocation = awaitResult (adapterName unit (C.contractDeclaration c)) (nativeCall (contractName c) [nativeArgument ty (text name) | (name,ty) <- args])
          result = nativeResult rt invocation
          post = D.group (text (rn ++ " `seq`") <> D.nest 2 (D.softline <>
            require "postcondition" (contractPostconditions c) (text rn)))
          body = require "precondition" (contractPreconditions c) (letIn [(rn,result)] post)
          name = "_lawspec_call_" ++ contractName c
          signature = D.group (text (name ++ " :: LS.SymbolContext ->") <> D.nest 2
            (D.softline <> D.joinWith (text " ->" <> D.softline) (replicate (length args + 1) (text "Scalar"))))
      in signature <> D.hardline <> text (unwords (name : "symbols" : map fst args) ++ " =") <>
        D.nest 2 (D.hardline <> body)
    -- A law's resources: each case acquires them, then runs, then releases
    -- them, the last first, even when the case fails. A built-in resource is
    -- acquired in IO, so each case gets its own.
    bracketed e docs = foldr wrap (sequenceDocs docs) (C.propertyResources (original e))
      where
        -- A shared resource (share R per ...): the runtime keeps one per
        -- scope key, resets it before each later use, holds it for one case
        -- at a time, and releases it after the unit's spec.
        wrap r inner | Just key <- C.resourceShared r, Just reset <- C.resourceReset r =
          let local = localName (C.binderId (C.resourceBinder r))
              using body = text ("\\" ++ local ++ " -> ") <> apply "evaluate" [runtime "forceScalar" [expr body]]
          in apply "LS.withShared" [quoted key, text (if C.resourceConcurrent r then "P.True" else "P.False"), apply "pure" [expr (C.resourceAcquire r)], parens (using reset), parens (using (C.resourceRelease r))] <>
            text (" $ \\" ++ local ++ " -> do") <> D.nest 2 (D.hardline <> inner)
        wrap r inner =
          let local = localName (C.binderId (C.resourceBinder r))
              (acquire, release) = case builtin r of
                Just (kind, tag) -> (apply "LS.acquireBuiltin" [quoted kind, quoted tag], apply "LS.releaseBuiltin" [quoted kind])
                Nothing -> (apply "pure" [expr (C.resourceAcquire r)],
                  text ("\\" ++ local ++ " -> ") <> apply "evaluate" [runtime "forceScalar" [expr (C.resourceRelease r)]])
          in apply "LS.withResource" [acquire, release] <> text (" $ \\" ++ local ++ " -> do") <>
            D.nest 2 (D.hardline <> inner)
        builtin r = case C.expressionNode (C.resourceAcquire r) of
          C.Construct tag [argument] | C.Helper h [kind] <- C.expressionNode argument, h `elem` [C.AcquireResource, C.FreePort]
            , C.Constant (SSequence _ points) <- C.expressionNode kind -> Just (map toEnum points, C.idText tag)
          _ -> Nothing
    law testNames (index,e) = do
      let label = owner e ++ "::" ++ name e
          h = C.propertyHarness (original e)
          base' = testNames !! index
          fn = (if C.harnessSkip h == Nothing && (C.harnessKnownFailing h /= Nothing || runSettings h) then "harness:" else "") ++ base'
      exampleDocs <- mapM (\(i,ex) -> pure $ testFunction (fn ++ "_example" ++ show i)
        ([symbols] ++ handlerInstalls e ++ [bind n (expr v) | (n,v) <- bindings ex] ++
        [bracketed e (map (assertionDoc (label ++ " example " ++ exampleName ex)) (expectations ex) ++
          [assertionDoc label (assertion e)])])) (zip [0::Int ..] (examples (original e)))
      boundaryDocs <- mapM (\(i,vs) -> do
        values <- mapM literal vs
        pure $ testFunction (fn ++ "_boundary" ++ show i)
          ([symbols] ++ handlerInstalls e ++ [bind (inputId inp) (checked (inputType inp) v) | (inp,v) <- zip (inputs e) values] ++
          [bracketed e [assertionDoc (label ++ " boundary " ++ show i) (assertion e)]]))
        (zip [0::Int ..] (maybe (boundaryCases e) id (finiteCases e)))
      -- LawSpec's own search (LawSpec.Search): the failure database's
      -- inputs are replayed before the law's generated cases, a failing
      -- case's inputs are kept, and a law with `target maximize` climbs
      -- after them, as Hedgehog has no targeting.
      let descriptors = searchDescriptors e
          inputsName = "_lawspecInputs" ++ show index
          caseName = "_lawspecCase" ++ show index
          remembered doc = case descriptors of
            Nothing -> doc
            Just _ -> apply "LS.searchGuard" [quoted label, text inputsName, E.array (map (text . inputId) (inputs e))] <>
              text " $ do" <> D.nest 2 (D.hardline <> doc)
          (searchBefore, searchAfter) = case descriptors of
            Nothing -> ([], [])
            Just ds ->
              let refinements = concatMap inputRefinements (inputs e)
                  score = maybe (text "0") (\s' -> runtime "searchNumber" [checked (expressionType s') (expr s')]) (C.harnessTarget h)
                  checking = statements [bracketed e [assertionDoc (label ++ " search") (assertion e)],
                    apply "P.pure" [parens (apply "P.Just" [parens score])]]
              in ( [ bind inputsName (E.array (map quoted ds))
                   , text ("let " ++ caseName ++ " _values = do") <> D.nest 6 (D.hardline <> statements
                       ([symbols] ++ handlerInstalls e ++
                        [bind (inputId inp) (checked (inputType inp) (text ("_values !! " ++ show i))) | (i, inp) <- zip [0::Int ..] (inputs e)] ++
                        [if null refinements then checking
                         else text "if P.not " <> D.nest 4 (parens (conjunction (map (truth . expr) refinements))) <> text " then P.pure P.Nothing else do" <>
                           D.nest 2 (D.hardline <> checking)]))
                   , example (base' ++ "_replay") (runtime "searchReplay" [quoted label, text inputsName, text caseName]) ]
                 , [example (base' ++ "_search") (runtime "searchClimb" [quoted label, text inputsName, text caseName]) | C.harnessTarget h /= Nothing] )
      let check = bracketed e (observations e ++ [remembered (assertionDoc (label ++ " property") (assertion e))])
      property <- if finiteCases e /= Nothing then pure []
        else if not (null (C.harnessDraws h)) then (:[]) <$> harnessProperty fn label e check
        else if nativeGenerators || constructorContracts || any (maybe False (const True) . generatorIndex) (generationPlan e)
          then (:[]) <$> contextualProperty fn label e check
        else if any (structural . inputType) (inputs e) then pure [nativeProperty fn label e check]
        else if any (not . null . inputRefinements) (inputs e) || propertyKind e == "contract"
          then (:[]) <$> refinedProperty fn label e check
          else pure [nativeProperty fn label e check]
      let kinds = ["_example" ++ show i | i <- [0 .. length exampleDocs - 1]] ++ ["_boundary" ++ show i | i <- [0 .. length boundaryDocs - 1]] ++
            ["_property" | not (null property)]
      pure $ metadataDocument 78 "--" e <> separate (searchBefore ++ harnessTests base' label h kinds (exampleDocs ++ boundaryDocs ++ property) ++ searchAfter)
    propertyHeader fn label e = apply "modifyMaxSuccess" [apply "const" [number (cases (generation e))]] <>
      text " $ " <> apply "it" [quoted (fn ++ "_property: " ++ label)] <> text " $ hedgehog $ do"
    contextualProperty fn label e check = do
      draws <- mapM (\plan -> do
        seeds <- mapM literal (generatorBoundaries plan)
        let inp = domainInput plan
            ty = inputType inp
            hints = [expr hint | hint <- generatorHints plan, expressionType hint == ty,
              case C.expressionNode hint of C.Constant _ -> True; C.Local _ -> True; _ -> False]
            strategy = case requiredSymbol plan of
              value:_ -> apply "pure" [expr value]
              -- The target is evaluated from the inputs drawn above.
              [] | Just indexed <- generatorIndex plan -> E.checked (apply "Strategies.indexedStrategy"
                [text "_lawspecSchema",reference ty,number machineBits,number nodeBudget,
                 expr (indexedTarget indexed),
                 E.array [text "(" <> quoted (C.idText tag) <> text ", " <> E.array (map quoted texts) <> text ")"
                   | (tag,texts) <- indexedEquations indexed],
                 apply "Strategies.primitiveStrategy" [number machineBits]])
              [] -> E.checked (apply (if nativeGenerators then "Strategies.checkedStrategyWith" else "Strategies.checkedStrategy")
                ([apply "NativeGenerators.factories" [text "symbols",text "_lawspecSchema",number machineBits] | nativeGenerators] ++ [text "_lawspecSchema",reference ty,number machineBits,number nodeBudget,
                 apply "P.Just" [text "symbols"],E.array (seeds ++ hints),
                 apply "Strategies.primitiveStrategy" [number machineBits]]))
        pure (statements
          ([text (inputId inp ++ " <-") <> D.nest 2 (D.hardline <> strategy)] ++
           [runtime "forceScalar" [text (inputId inp)] <> text " `seq` pure ()" | not nativeGenerators]))) (generationPlan e)
      let names = E.array (map (text . inputId) (inputs e))
          base = D.multiline (text "do" <> D.nest 2 (D.hardline <>
            statements (draws ++ [apply "pure" [names]])))
          predicates = concatMap inputRefinements (inputs e)
          strategy = if null predicates then base else apply "Gen.filterT"
            [D.group (text "\\" <> names <> text " ->" <> D.nest 2
              (D.softline <> conjunction (map (truth . expr) predicates))),base]
          draw = if nativeGenerators then apply "Hedgehog.forAllWith"
            [lambda "_" (quoted "native generated inputs"),strategy] else apply "forAll" [strategy]
          body = statements ([text "symbols <- evalIO LS.newSymbolContext",
            D.group (names <> text " <-" <> D.nest 2 (D.softline <> draw))] ++
            [apply "evalIO" [apply "evaluate" [runtime "forceScalar" [text (inputId inp)]]] |
              nativeGenerators,inp <- inputs e] ++
            [apply "footnote" [apply "show" [names]] | nativeGenerators] ++
            [apply "footnote" [quoted label],text "evalIO $ do" <> D.nest 2 (D.hardline <> statements (handlerInstalls e ++ [check]))])
          cfg = generation e
          settings = [apply name [number value] | (name,value) <-
            [("Hedgehog.withTests",cases cfg),("Hedgehog.withDiscards",maxAttempts cfg),
             ("Hedgehog.withShrinks",maxShrinks cfg)]]
          run = text "_passed <- _lawspecCheck $" <> D.nest 2 (D.hardline <>
            D.joinWith (text " $" <> D.hardline) (settings ++ [text "Hedgehog.property $ do"]) <>
            D.nest 2 (D.hardline <> body))
      pure $ testFunction (fn ++ "_property: " ++ label) [run,text "_passed `shouldBe` True"]
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
            case C.expressionNode value of C.Constant _ -> True; C.Local _ -> True; _ -> False]
          _ -> []
    nativeProperty fn label e check =
      let names = E.array (map (text . inputId) (inputs e))
          predicates = concatMap inputRefinements (inputs e)
          base = apply "fmap" [apply "map" [apply "LS.scopeSymbols" [text "symbols"]],
            apply "sequence" [E.array [generatorWithin (inputRange machineBits inp) (inputType inp) | inp <- inputs e]]]
          strategy = if null predicates then base else apply "Gen.filter"
            [D.group (text "\\" <> names <> text " ->" <> D.nest 2
              (D.softline <> conjunction (map (truth . expr) predicates))),base]
      in propertyTest fn label e (statements
        [text "symbols <- evalIO LS.newSymbolContext",D.group (names <> text " <-" <>
          D.nest 2 (D.softline <> apply "forAll" [strategy])),apply "footnote" [quoted label],
         text "evalIO $ do" <> D.nest 2 (D.hardline <> statements (handlerInstalls e ++ [check]))])
    domain e (index,plan) = do
      seeds <- mapM literal (generatorBoundaries plan)
      let inp = domainInput plan
          prior = take index (inputs e)
          bindingsDoc xs = [(inputId input,text ("_values !! " ++ show i)) | (i,input) <- zip [0::Int ..] xs]
          closure xs args body = lambda args (if null xs then body else letIn (bindingsDoc xs) body)
          bounds = E.array [D.delimit 2 "(" ")" [quoted op,expr v] | (op,v) <- domainBounds plan]
          candidates = runtime "domainCandidates" [quoted (typeKey (inputType inp)),text "_seed",number machineBits,
            bounds,E.array (seeds ++ map expr (generatorHints plan))]
      pure (apply "LS.Domain" [closure prior "_values _seed" candidates,
        closure (prior ++ [inp]) "_values" (conjunction (map (truth . expr) (inputRefinements inp)))])
    refinedProperty fn label e check = do
      domains <- mapM (domain e) (zip [0::Int ..] (generationPlan e))
      let cfg = generation e
          callback = text "let _check _values = do" <> D.nest 6 (D.hardline <>
            statements ([fromValues (inputs e)] ++ handlerInstalls e ++ [check]))
          invocation = runtime "refinedCase" [E.array domains,text "seed",number (maxAttempts cfg),number (maxShrinks cfg),text "_check",
            quoted (label ++ " | " ++ intercalate "; " (map prettyExpr (concatMap inputRefinements (inputs e))))]
      pure $ propertyTest fn label e (statements
        [text "symbols <- evalIO LS.newSymbolContext",
         text "seed <- forAll (Gen.int (Range.linear 0 2147483647))",apply "footnote" [quoted label],
         callback,apply "evalIO" [invocation]])
