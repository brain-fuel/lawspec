-- Hspec/Hedgehog documents over checked propositions and generation plans.
module LawSpec.HaskellProperties (Config(..), emitTests) where

import LawSpec.Bounds (inputRange)
import LawSpec.Backend
import LawSpec.Common
import LawSpec.Testing
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.HaskellExpr as E
import qualified LawSpec.HaskellTestHelpers as Helpers
import Data.List (intercalate)

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
testFunction name body = apply "it" [quoted name] <> text " $ do" <>
  D.nest 2 (D.hardline <> sequenceDocs body)

emitTests :: Config -> Unit -> [Expanded] -> Either [Diagnostic] D.Doc
emitTests Config{..} unit laws = do
  bodies <- mapM law (zip [0::Int ..] laws)
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
        ["import qualified LawSpecDefinitionBodies as Definitions" | hasDefinitions] ++
        ["import qualified LawSpecWorkflows as Workflows" | hasWorkflows] ++
        ["import qualified LawSpecNativeGenerators as NativeGenerators" | nativeGenerators] ++
        ["import qualified LawSpecSchema as Schema", "import qualified LawSpecDataSchema as DataSchema",
         "import qualified LawSpecCodecs as Codec", "import qualified LawSpecDataCodecs as Codecs",
         "import qualified LawSpecDataStrategies as Strategies"] ++
        ["import qualified LawSpecCollectionCodecs as Collections" | usesCollections] ++
        concat [["import qualified " ++ records ++ " as Abilities", "import qualified " ++ handlers ++ " as Handlers"]
               | Just (records, handlers) <- [abilityModules]] ++
        ["import qualified " ++ m | m <- nativeImports] ++
        ["import qualified Lawspec.Time" | readsClock]
  pure $ statements ([text "-- Generated by LawSpec."] ++
      -- Each performed operation must run where it is written, once.
      [text "{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}" | Just _ <- [abilityModules]] ++
      [text ("module " ++ moduleName ++ "Spec (spec) where")]) <>
    D.hardline <> D.hardline <> statements (map text imports) <> D.hardline <> D.hardline <>
    separate ([Helpers.schemaDoc,Helpers.assertionDoc,seedDoc] ++ map contract (contracts unit)) <>
    D.hardline <> D.hardline <> text "spec :: Spec" <> D.hardline <> text "spec = do" <>
    -- Workflows wait on a virtual clock under test.
    D.nest 2 (D.hardline <> text "runIO (LS.useVirtualClock 0)" <> D.hardline <>
      -- Workflows read the Clock handler a law installs (any of them).
      (if readsClock then text "runIO Lawspec.Time.registerClock" <> D.hardline else mempty) <> (if null bodies then text "pure ()" else separate bodies)) <> D.hardline
  where
    readsClock = clockReader unit
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
    law (index,e) = do
      let label = owner e ++ "::" ++ name e
          fn = "law" ++ show index
      exampleDocs <- mapM (\(i,ex) -> pure $ testFunction (fn ++ "Example" ++ show i)
        ([symbols] ++ handlerInstalls e ++ [bind n (expr v) | (n,v) <- bindings ex] ++
        map (assertionDoc (label ++ " example " ++ exampleName ex)) (expectations ex) ++
        [assertionDoc label (assertion e)])) (zip [0::Int ..] (examples (original e)))
      boundaryDocs <- mapM (\(i,vs) -> do
        values <- mapM literal vs
        pure $ testFunction (fn ++ "Boundary" ++ show i)
          ([symbols] ++ handlerInstalls e ++ [bind (inputId inp) (checked (inputType inp) v) | (inp,v) <- zip (inputs e) values] ++
          [assertionDoc (label ++ " boundary " ++ show i) (assertion e)]))
        (zip [0::Int ..] (maybe (boundaryCases e) id (finiteCases e)))
      let check = assertionDoc (label ++ " property") (assertion e)
      property <- if finiteCases e /= Nothing then pure []
        else if nativeGenerators || constructorContracts || any (maybe False (const True) . generatorIndex) (generationPlan e)
          then (:[]) <$> contextualProperty fn label e check
        else if any (structural . inputType) (inputs e) then pure [nativeProperty fn label e check]
        else if any (not . null . inputRefinements) (inputs e) || propertyKind e == "contract"
          then (:[]) <$> refinedProperty fn label e check
          else pure [nativeProperty fn label e check]
      pure $ metadataDocument 78 "--" e <> separate (exampleDocs ++ boundaryDocs ++ property)
    propertyHeader fn label e = apply "modifyMaxSuccess" [apply "const" [number (cases (generation e))]] <>
      text " $ " <> apply "it" [quoted (fn ++ "Property: " ++ label)] <> text " $ hedgehog $ do"
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
      pure $ testFunction (fn ++ "Property: " ++ label) [run,text "_passed `shouldBe` True"]
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
      in propertyHeader fn label e <> D.nest 2 (D.hardline <> statements
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
      pure $ propertyHeader fn label e <> D.nest 2 (D.hardline <> statements
        [text "symbols <- evalIO LS.newSymbolContext",
         text "seed <- forAll (Gen.int (Range.linear 0 2147483647))",apply "footnote" [quoted label],
         callback,apply "evalIO" [invocation]])

-- Whether a unit's laws install a Clock handler, so the test registers how
-- workflows read one (lawspec.time's registerClock).
clockReader :: Unit -> Bool
clockReader unit = or [ C.abilityKey a == "lawspec.time::ability::Clock"
                      | p <- C.unitProperties unit, (a, _) <- C.propertyHandlers p ]
