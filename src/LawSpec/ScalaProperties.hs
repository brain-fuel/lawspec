-- | Scala test documents consume checked propositions and native generation
-- plans: ScalaTest suites whose properties run on LawSpec's shrink trees.
-- The tests are laid out as scalafmt lays them out (LawSpec.ScalaLayout),
-- keep the source's binder names, and use the runtime's checks and
-- generators (LawSpecTesting, LawSpecScalars), so a test file holds only
-- its laws. ref:DEC-readable-output-default
module LawSpec.ScalaProperties (Config(..), emitTests, emitSplitTests) where

import LawSpec.Bounds (inputRange, drawRange)
import qualified LawSpec.Core as C
import Control.Monad (foldM)
import Data.Char (isAlphaNum, toUpper)
import LawSpec.Backend
import LawSpec.Common
import LawSpec.TestNames (unitTestNames)
import LawSpec.Testing
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.ScalaExpr as E
import qualified LawSpec.ScalaLayout as L
import LawSpec.ScalaTestHelpers (scalarGenerators)
import LawSpec.JvmNames (exampleTestNames, boundaryTestName, contractMethod)
import LawSpec.Naming (displayLabel)
import LawSpec.SourceLink (generatedHeader, labelled, locationLink, originLocation, exampleLocation)
import Data.List (intercalate, nub, sort, stripPrefix)

-- | What the Scala test emitter needs besides the plan: names, layout and
-- bindings, gathered so the emitter takes one argument.
-- A drawn value, or the bindings that draw it and then its value.
data DrawBody = DrawValue D.Doc | DrawSteps [D.Doc] D.Doc

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
  -- Imports the unit's tests need besides the runtime's.
  , extraImports :: [String]
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
quoted = L.scalaString
number :: Show a => a -> D.Doc
number = text . show
bind :: String -> D.Doc -> D.Doc
bind = L.bind
runtime :: String -> [D.Doc] -> D.Doc
runtime name = call ("LawSpecRuntime." ++ name)
truth :: D.Doc -> D.Doc
truth value = runtime "truth" [value]
-- | header { body }, the body on lines of its own.
braced :: D.Doc -> [D.Doc] -> D.Doc
braced header body = header <> text " " <> L.block body
symbols :: D.Doc
symbols = text "val symbols = LawSpecScala.symbols()"
-- | A comment of lines wrapped to the page at an indentation.
comment :: Int -> [String] -> D.Doc
comment indentation = mconcat . map (L.comment (80 - indentation))

-- | Laws become ScalaTest tests whose properties run on LawSpec's shrink
-- trees, so they run with the tools a Scala project already uses.
-- ref:DEC-native-property-frameworks ref:DEC-scala-property-library
emitTests :: Config -> Unit -> [Expanded] -> Either [Diagnostic] D.Doc
emitTests config unit laws = fst <$> emitTestsWith False config unit laws

-- | A unit's tests in files of their own when one file would be too long to
-- read (or for scalafmt to lay out): the object of shared values and the
-- suite class, then each law's trait, named after the unit, in its own file.
emitSplitTests :: Config -> Unit -> [Expanded] -> Either [Diagnostic] (D.Doc, [(String, D.Doc)])
emitSplitTests = emitTestsWith True

emitTestsWith :: Bool -> Config -> Unit -> [Expanded] -> Either [Diagnostic] (D.Doc, [(String, D.Doc)])
emitTestsWith split Config{..} unit laws = do
  let testNames = unitTestNames "scala" (map name laws)
  generated <- mapM (law testNames) (zip [0::Int ..] laws)
  let lawDocs = map snd generated
      sharedCases = concatMap fst generated
      testClass = className ++ "LawSpecTest"
      -- Each law registers its tests in a trait of its own: the JVM bounds
      -- a method's bytecode and a class's constant pool.
      lawFunctions = uniqueFunctions (map (functionName . name) laws ++ ["benchmark" ++ capital (functionName n) | (n, _) <- benchmarks])
      registrations = [(n, comments, doc) | (n, (comments, doc)) <- zip lawFunctions (lawDocs ++ map benchmark benchmarks)]
      traitName n = (if split then className else "") ++ capital n ++ "Law"
      registration (n, comments, doc) = comments <>
        braced (D.group (text ("trait " ++ traitName n) <> D.nest 4 (D.softline <> text "extends AnyFunSuite" <>
          (if parallel then D.softline <> text "with lawspec.testing.LawSpecParallel" else mempty))))
          ([text "protected def registerTest(name: String)(body: => Unit): Unit" | orderRandom] ++
           [D.group (text ("def register" ++ capital n ++ "()") <> D.nest 4 (D.softbreak <> text ": Unit =")) <> text " " <> L.block [doc]])
      parents = ["AnyFunSuite"] ++ ["lawspec.testing.LawSpecParallel" | parallel] ++ [(if split then "" else testClass ++ ".") ++ traitName n | (n, _, _) <- registrations]
      header = D.group (text ("class " ++ testClass) <> D.nest 4 (D.softline <> text ("extends " ++ head parents) <>
        mconcat [D.softline <> text ("with " ++ p) | p <- tail parents]))
      classBody = separate (statements ([text ("import " ++ testClass ++ ".*")] ++
          -- Workflows wait on a virtual clock under test, and workflows and
          -- mailboxes read the Clock handler a law installs.
          [text "LawSpecRuntime.useVirtualClock(0)"] ++
          [text "lawspec.Time.registerClock()" | installsClock unit]) :
        [call "lawspec.testing.LawSpecHarness.parallelism" [quoted unitLabel, quoted "tests on a thread per processor (LawSpecParallel)",
           text "Runtime.getRuntime().availableProcessors()"] | parallel] ++
        ordered [text ("register" ++ capital n ++ "()") | (n, _, _) <- registrations])
      members = [text "// The machine profile's integer width." <> D.hardline <> text (visibility ++ "val MachineBits = " ++ show machineBits)] ++
        [text (visibility ++ "val Schema = LawSpecDataSchema.create()") | usesSchema] ++
        [statements [bind' n codec | (n, codec) <- codecs] | not (null codecs)] ++
        map contract (contracts unit) ++ sharedCases ++ (if split then [] else map registration registrations)
      code = D.render D.Compact (separate ([doc | (_, _, doc) <- registrations] ++ sharedCases ++ map contract (contracts unit)))
      codecs = [(n, codec) | (n, codec) <- codecValues, n `elem` identifiers code]
      bind' n codec = D.group (text (visibility ++ "val " ++ n ++ " =") <> D.nest 2 (D.softline <> codec))
      usesSchema = "Schema" `elem` identifiers (code ++ " " ++ concatMap (D.render D.Compact . snd) codecs)
      body = separate [braced (text ("object " ++ testClass)) [separate members], header <> text " " <> L.block [classBody]]
      rendered = D.render D.Compact body
      used = identifiers rendered
      importsFor used' = sort (nub ([i | i <- candidateImports, simpleName i `elem` used'] ++
        ["scala.jdk.CollectionConverters.*" | any (`elem` used') ["asScala", "asJava"]] ++ extraImports))
      file imports content = text ("// " ++ generatedHeader sourceFile) <> D.hardline <>
        (if null packageName then mempty else text ("package " ++ packageName) <> D.hardline <> D.hardline) <>
        (if null imports then mempty else statements [text ("import " ++ i) | i <- imports] <> D.hardline <> D.hardline) <>
        content <> D.hardline
      -- A law's own file reads the shared values from the suite's object.
      traitFile r@(n, _, _) =
        let doc = registration r
        in (traitName n, file (importsFor (identifiers (D.render D.Compact doc)) ++ [testClass ++ ".*"]) doc)
  pure (file (importsFor used) body, if split then map traitFile registrations else [])
  where
    visibility = if split then "" else "private "
    -- Binders keep their source names (LawSpec.JvmNames).
    inputId = local . C.binderId . C.quantifiedBinder
    localName = local
    bindings ex = [(local i, v) | (i, v) <- C.exampleBindings ex]
    contractArguments c = [(local (C.binderId b), C.binderType b) | b <- C.contractArguments c]
    contractResult c = let b = C.contractResult c in (local (C.binderId b), C.binderType b)
    fromValues xs = [bind (inputId input) (text ("values(" ++ show index ++ ")")) | (index, input) <- zip [0::Int ..] xs]
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
      [ "org.scalatest.funsuite.AnyFunSuite"
      , "lawspec.runtime.LawSpecDataCodecs", "lawspec.runtime.LawSpecDataSchema", "lawspec.runtime.LawSpecRuntime"
      , "lawspec.runtime.LawSpecSchema", "lawspec.runtime.LawSpecScala", "lawspec.runtime.LawSpecScalaCodecs"
      , "lawspec.testing.Arb", "lawspec.testing.LawSpecProperty", "lawspec.testing.LawSpecScalaStrategies"
      , "lawspec.testing.LawSpecScalars", "lawspec.testing.LawSpecTesting", "lawspec.testing.LawSpecDraws" ]
    -- A case's handlers and fixtures are in symbols; a case with neither
    -- does not make it.
    withSymbols docs = if "symbols" `elem` identifiers (D.render D.Compact (statements docs)) then symbols : docs else docs
    -- Readable text about a law: its label and source line.
    shownLaw e = owner e ++ "::" ++ displayLabel (name e)
    lawLink e = let l = location (original e) in if null (file l) then Nothing else Just (locationLink l)
    linked e text' = labelled text' (lawLink e)
    capital (c : cs) = toUpper c : cs
    capital [] = []
    -- A law's registration: its test name.
    functionName label = case unitTestNames "scala" [label] of
      n : _ -> n
      [] -> "law"
    uniqueFunctions = go []
      where
        go _ [] = []
        go seen (n : rest) = let chosen = head [c | c <- n : [n ++ show k | k <- [2 :: Int ..]], c `notElem` seen]
                             in chosen : go (chosen : seen) rest
    benchmarks = maybe [] C.harnessBenchmarks settings
    -- The harness plane (LawSpec.Harness). A test the harness runs is a
    -- function value (harness:name), which the generated test passes to the
    -- runtime shared with Java.
    settings = C.unitHarnessSettings unit
    orderRandom = maybe False C.harnessOrderRandom settings
    parallel = maybe False C.harnessParallel settings
    unitLabel = C.idText (C.unitId unit)
    -- order random: the unit's tests are collected, then registered in an
    -- order the run's seed chooses.
    ordered docs
      | orderRandom =
          [ D.group (text "private val tests =" <> D.nest 2 (D.softline <> text "scala.collection.mutable.ArrayBuffer[(String, () => Unit)]()"))
          , text "protected def registerTest(name: String)(body: => Unit): Unit =" <> D.nest 2 (D.hardline <> text "tests += ((name, () => body))")
          , statements docs
          , bind "shuffled" (D.group (text "lawspec.testing.LawSpecHarness" <> D.nest 2 (D.softbreak <> call ".shuffled" [quoted unitLabel, text "tests.asJava"] <> D.softbreak <> text ".asScala")))
          , braced (text "for ((name, body) <- shuffled)") [text (finalRegister ++ "(name)(body())")] ]
      | otherwise = docs
    register = if orderRandom then "registerTest" else finalRegister
    -- A parallel unit's tests start together (lawspec.testing.LawSpecParallel).
    finalRegister = if parallel then "parallelTest" else "test"
    testFunction testName body = case stripPrefix "harness:" testName of
      Just rest -> D.multiline (text ("val " ++ harnessValue (takeWhile (/= ':') rest) ++ ": () => Unit = () => ") <> L.block body)
      Nothing -> braced (call register [quoted testName]) body
    harnessValue rest = "harness" ++ capital (filter isAlphaNum rest)
    runSettings h = C.harnessTimeout h /= Nothing || C.harnessRepeat h /= 1 || C.harnessRetries h /= 0 || observed h
    observed h = not (null (C.harnessCover h) && null (C.harnessClassify h) && null (C.harnessLabels h)) || C.harnessTarget h /= Nothing
    harness name' = call ("lawspec.testing.LawSpecHarness." ++ name')
    harnessBody name' = text ("() => " ++ name' ++ "()")
    observations e =
      let h = C.propertyHarness (original e)
          label = owner e ++ "::" ++ name e
      in [harness "observe" [quoted label,
            call "Array[String]" [quoted l | C.Cover _ l _ <- C.harnessCover h], call "Array[Boolean]" [truth (expr w) | C.Cover _ _ w <- C.harnessCover h],
            call "Array[String]" [quoted l | (_, l) <- C.harnessClassify h], call "Array[Boolean]" [truth (expr c) | (c, _) <- C.harnessClassify h],
            call "Array[LawSpecRuntime.Value]" (map expr (C.harnessLabels h))] | observed h] ++
         [harness "target" [expr score, quoted label] | Just score <- [C.harnessTarget h]]
    -- The tests a law's harness wraps, skips or expects to fail.
    harnessTests fn label h kinds docs = case (C.harnessSkip h, C.harnessKnownFailing h) of
      (Just reason, _) -> [braced (call "ignore" [quoted (fn ++ "_skipped: " ++ label)]) [text ("// " ++ reason)]]
      (_, Just reason) -> docs ++ [braced (call register [quoted (fn ++ "_knownFailing: " ++ label)]) [harness "knownFailing"
        [quoted label, quoted (fn ++ "_knownFailing"), quoted reason, call "java.util.List.of[lawspec.testing.LawSpecHarness.Body]" [harnessBody (harnessValue (fn ++ k)) | k <- kinds]]]]
      _ | runSettings h -> docs ++ [braced (call register [quoted (fn ++ k ++ (if k == "_property" then ": " ++ label else ""))]) [harness "run"
            [quoted label, quoted (fn ++ k), number (maybe 0 id (C.harnessTimeout h)), number (C.harnessRepeat h), number (C.harnessRetries h),
             call "Array[Int]" [number p | k == "_property", C.Cover p _ _ <- C.harnessCover h],
             call "Array[String]" [quoted l | k == "_property", C.Cover _ l _ <- C.harnessCover h],
             text (if k == "_property" && observed h then "true" else "false"), harnessBody (harnessValue (fn ++ k))]] | k <- kinds]
        | otherwise -> docs
    benchmark (n, b) = (mempty, braced (call register [quoted ("benchmark " ++ n)]) (withSymbols
      [harness "benchmark" [quoted n, L.arrow "()" (L.block [bind "measured" (expr b), text "()"])]]))
    -- A property whose inputs harness strategies draw, from the property's
    -- random source; their values' refinements are checked in the property.
    harnessProperty fn label e check = do
      let h = C.propertyHarness (original e)
          strategyOf inp = [(n, d) | (i, n, d) <- C.harnessDraws h, i == C.binderId (C.quantifiedBinder inp)]
      draws <- mapM (\plan -> do
        let inp = domainInput plan
        case strategyOf inp of
          (strategy, d) : _ -> (\(defs, body) -> defs ++ [bind (inputId inp) (drawValue body)]) <$> drawDoc inp strategy (inputId inp) d
          [] -> pure [bind (inputId inp) (sampled (generatorWithin (inputRange machineBits inp) (inputType inp)))]) (generationPlan e)
      let defaults = [inp | inp <- inputs e, null (strategyOf inp)]
          strategyChecks = [harness "checkDrawn" [quoted strategy, quoted (inputName inp),
              L.conjunction (map (truth . expr) (inputRefinements inp)), text (inputId inp)]
            | inp <- inputs e, (strategy, _) : _ <- [strategyOf inp], not (null (inputRefinements inp))]
          base = L.trailing (text "Arb.from") ["random"]
            ([symbols] ++ concat draws ++ [text "(" <> call "List" [text (inputId inp) | inp <- inputs e] <> text ", symbols)"])
          predicates = concatMap inputRefinements defaults
          bindingsDoc = text "val (values, symbols) = inputs" : fromValues (inputs e)
          strategy = if null predicates then base else filtered base (bindingsDoc ++ [L.conjunctionStatement (map (truth . expr) predicates)])
      pure $ testFunction (fn ++ "_property: " ++ label) [L.trailingCall "LawSpecProperty.checkAll" [quoted label, number (cases (generation e)), strategy] ["inputs"]
        (bindingsDoc ++ strategyChecks ++ handlerInstalls e ++ [check])]
    filtered generator predicate = L.trailingChain generator [] "filter" ["inputs"] predicate
    -- A generator's value drawn from the property's random source.
    sampled gen = L.chainWith gen [("sample", [text "random"])] (Just (text ".value"))
    supplier = L.arrow "()"
    -- A draw is the definitions it needs, each a named method drawing one
    -- sub-draw, followed by its value: draws stay flat rather than nesting a
    -- supplier per step.
    drawDoc inp strategy name d = case d of
      C.DrawAny ty aim -> pure ([], DrawValue (sampled (maybe (generator ty) (\range -> generatorWithin (Just range) ty) (drawRange machineBits inp ty aim))))
      C.DrawOneOf _ values -> pure ([], DrawValue (call "LawSpecDraws.oneOf" (text "random" : [supplier (expr v) | v <- values])))
      C.DrawFrequency alternatives -> do
        options <- mapM (\(k, (w, a)) -> do
          let n = name ++ "Option" ++ show k
          (defs, body) <- drawDoc inp strategy n a
          pure (defs ++ [method n (drawValue body)], text ("(" ++ show w ++ ", () => " ++ n ++ "())"))) (zip [1 :: Int ..] alternatives)
        pure (concatMap fst options, DrawValue (call "LawSpecDraws.frequency" (text "random" : map snd options)))
      C.DrawSuchThat inner binder predicate limit -> do
        (defs, candidate) <- named (name ++ "Candidate") inner
        pure (defs, DrawValue (harness "suchThat" [candidate,
          L.arrow ("(" ++ localName (C.binderId binder) ++ ": LawSpecRuntime.Value)") (truth (expr predicate)),
          number limit, quoted strategy]))
      C.DrawBind _ _ _ -> do
        -- A chain of draws is one block of bindings, not a block per draw.
        let chained d' = case d' of
              C.DrawBind binder from rest -> let (bs, final) = chained rest in ((binder, from) : bs, final)
              _ -> ([], d')
            (binds, final) = chained d
        bound <- mapM (\(binder, from) -> do
          let n = localName (C.binderId binder)
          (defs, body) <- drawDoc inp strategy n from
          pure (defs ++ [bind n (drawValue body)])) binds
        (finalDefs, finalBody) <- drawDoc inp strategy name final
        pure ([], DrawSteps (concat bound ++ finalDefs) (drawValue finalBody))
      where
        -- A sub-draw passed on as a supplier: a plain sample stays inline;
        -- anything larger is a method, defined before its use.
        named n sub = do
          (defs, body) <- drawDoc inp strategy n sub
          pure $ case (sub, body) of
            (C.DrawAny _ _, DrawValue v) -> (defs, supplier v)
            (_, DrawValue v) -> (defs ++ [method n v], supplier (text (n ++ "()")))
            (_, DrawSteps steps v) -> (defs ++ [method n (L.block (steps ++ [v]))], supplier (text (n ++ "()")))
    method n = L.equalsBody (text ("def " ++ n ++ "(): LawSpecRuntime.Value"))
    drawValue body = case body of
      DrawValue v -> v
      DrawSteps steps v -> L.block (steps ++ [v])
    expr = expression
    -- An assertion names its law and case and points at the source line of
    -- what it checks; the expectation itself is in the law's comment.
    assertionDoc context = contextualAssertion (const (quoted context))
    contextualAssertion context proposition = case proposition of
      AssertAll ps -> statements (map (contextualAssertion context) ps)
      AssertImplies guard body -> braced (L.condition "if" (truth (expr guard))) [contextualAssertion context body]
      AssertEqual a b ->
        let message = context (expressionLink a)
        in if structural (expressionType a)
          then call "LawSpecTesting.check" [message, text "Schema", reference (expressionType a), text "MachineBits", text "symbols", expr a, expr b]
          else call "LawSpecTesting.check" [message, expr a, expr b]
    expressionLink a = case originLocation (C.expressionOrigin a) of
      Just l | take 1 (file l) /= "<" -> Just (locationLink l)
      _ -> Nothing
    contract c =
      let args = contractArguments c
          (rn,rt) = contractResult c
          params = text "symbols: LawSpecScala.Symbols" : [text (n ++ ": LawSpecRuntime.Value") | (n,_) <- args]
          context stage ps = quoted (contractName c ++ " " ++ stage ++ ": " ++ intercalate " && " (map prettyExpr ps))
          require stage ps = runtime "requireContract" [L.conjunction (map (truth . expr) ps),context stage ps]
          invocation = awaitResult (adapterName unit (C.contractDeclaration c)) (call (qualifiedAdapter ++ "." ++ adapterName unit (C.contractDeclaration c)) [nativeArgument ty (text n) | (n,ty) <- args])
      in braced (L.parameters (text (visibility ++ "def " ++ contractMethod (contractName c))) params <> text ": LawSpecRuntime.Value =")
          [require "precondition" (contractPreconditions c),
           bind rn (nativeResult rt invocation),require "postcondition" (contractPostconditions c),text rn]
    qualifiedAdapter = if null packageName then className else packageName ++ "." ++ className
    tryFinally inner final = braced (text "try") [inner] <> text " finally " <> L.block [final]
    -- A law's resources: each case acquires them, then runs, then releases
    -- them, the last first, even when the case fails.
    bracketed e docs = foldr wrap (statements (lateHandlerInstalls e ++ docs)) (C.propertyResources (original e))
      where
        -- A shared resource (share R per ...): the runtime keeps one per
        -- scope key, resets it before each later use, and releases it when
        -- the JVM exits.
        wrap r inner | Just key <- C.resourceShared r, Just reset <- C.resourceReset r =
          let resource = localName (C.binderId (C.resourceBinder r))
              use body = text ("(" ++ resource ++ ": LawSpecRuntime.Value) => ") <> L.block [body]
          in statements [bind resource (runtime "share" [quoted key, text "() => " <> L.block [expr (C.resourceAcquire r)],
              use (expr reset), use (expr (C.resourceRelease r)),
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
      exampleDocs <- mapM (\(suffix,ex) -> pure $ comment 6 [labelled ("example " ++ displayLabel (exampleName ex))
          (fmap locationLink (exampleLocation ex))] <>
        testFunction (fn ++ "_" ++ suffix) (withSymbols
        (handlerInstalls e ++ [bind n (expr v) | (n,v) <- bindings ex] ++
        [bracketed e (map (contextualAssertion (\l -> quoted (labelled (exampleContext ex) l))) (expectations ex) ++
          [contextualAssertion (const (quoted (linked e shown))) (assertion e)])]))) (zip exampleSuffixes (examples (original e)))
      boundaryValues <- mapM (mapM literal) (maybe (boundaryCases e) id (finiteCases e))
      -- Share large handler-bound assertions before registration is chunked:
      -- repeated bodies can overflow the JVM constant pool below 1,024 cases.
      let sharedBoundaries = length boundaryValues >= 64
          helper = base' ++ "Boundary"
          names = map inputId (inputs e) ++ [localName (C.binderId (C.resourceBinder resource)) | resource <- C.propertyResources (original e)]
          valuesArray = call "Array[LawSpecRuntime.Value]" (map text names)
          boundaryDocs = [testFunction (fn ++ "_" ++ boundaryTestName i) $ withSymbols
            (handlerInstalls e ++ [bind (inputId inp) (checked (inputType inp) v) | (inp,v) <- zip (inputs e) values] ++
            [bracketed e [if sharedBoundaries then call helper [quoted context, text "symbols", valuesArray]
            else assertionDoc context (assertion e)]]) | (i,values) <- zip [0::Int ..] boundaryValues
            , let context = linked e (shown ++ " boundary " ++ show (i + 1))]
          sharedDocs = [braced (L.parameters (text (visibility ++ "def " ++ helper))
              [text "context: String", text "symbols: LawSpecScala.Symbols", text "values: Array[LawSpecRuntime.Value]"] <> text ": Unit =")
            ([bind n (text ("values(" ++ show i ++ ")")) | (i,n) <- zip [0::Int ..] names] ++
              [contextualAssertion (const (text "context")) (assertion e)]) | sharedBoundaries, C.harnessSkip h == Nothing]
          -- A registration method also has a JVM bytecode size limit. Keep
          -- the same test names and order in bounded registration methods.
          registeredBoundaries
            | sharedBoundaries && C.harnessSkip h == Nothing && C.harnessKnownFailing h == Nothing && not (runSettings h) =
                concat [let part' = "boundaries" ++ show part in
                  [braced (text ("def " ++ part' ++ "(): Unit =")) [separate group'], text (part' ++ "()")]
                  | (part, group') <- zip [1::Int ..] (groupsOf 64 boundaryDocs)]
            | otherwise = boundaryDocs
      -- LawSpec's own search (LawSpec.Search): the failure database's
      -- inputs are replayed before the law's generated cases, a failing
      -- case's inputs are kept, and a law with `target maximize` climbs
      -- after them.
      let descriptors = searchDescriptors e
          remembered doc = case descriptors of
            Nothing -> doc
            Just _ -> braced (text "try") [doc] <> text " catch " <> L.block [text "case error: Throwable =>" <> D.nest 2 (D.hardline <> statements
              [runtime "searchRemember" [quoted label, text "searchInputs", call "java.util.List.of[LawSpecRuntime.Value]" [text (inputId inp) | inp <- inputs e]], text "throw error"])]
          searchCase = text "searchCase"
          score = maybe (text "java.lang.Double.valueOf(0.0)") (\s -> runtime "searchNumber" [expr s]) (C.harnessTarget h)
          (searchBefore, searchAfter) = case descriptors of
            Nothing -> ([], [])
            Just ds ->
              let refinements = concatMap inputRefinements (inputs e)
                  checkedCase = [bracketed e [assertionDoc (linked e (shown ++ " search")) (assertion e)], score]
              in ( [ bind "searchInputs" (call "java.util.List.of[String]" (map quoted ds))
                   , braced (L.parameters (text "def searchCase") [text "values: java.util.List[LawSpecRuntime.Value]"] <> text ": java.lang.Double =") (withSymbols (handlerInstalls e ++
                       [bind (inputId inp) (checked (inputType inp) (text ("values.get(" ++ show i ++ ")"))) | (i, inp) <- zip [0::Int ..] (inputs e)] ++
                       (if null refinements then checkedCase
                        else [braced (L.condition "if" (text "!(" <> L.conjunction (map (truth . expr) refinements) <> text ")")) [text "null"] <>
                          text " else " <> L.block checkedCase])))
                   , braced (call register [quoted (base' ++ "_replay")]) [runtime "searchReplay" [quoted label, text "searchInputs", searchCase]] ]
                 , [braced (call register [quoted (base' ++ "_search")]) [runtime "searchClimb" [quoted label, text "searchInputs", searchCase]] | C.harnessTarget h /= Nothing] )
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
      pure (sharedDocs, (comment 2 (lawCommentLines e), separate (searchBefore ++ harnessTests base' propertyLabel h kinds (exampleDocs ++ registeredBoundaries ++ property) ++ searchAfter)))
    groupsOf _ [] = []
    groupsOf count values = let (group', rest) = splitAt count values in group' : groupsOf count rest
    contextualProperty fn label e check = do
      let inputBindings xs = [text "val symbols = inputs.symbols", text "val values = inputs.values"] ++ fromValues xs
          state value = call "LawSpecScalaStrategies.Case" [value, text "symbols", text "drawn.error"]
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
                  Just range -> text "(tpe: String) =>" <> D.nest 2 (D.softline <> D.group (text "if (tpe == " <> quoted (typeKey ty) <> text ")" <>
                      D.nest 2 (D.softline <> generatorWithin (Just range) ty) <> D.softline <>
                      text "else " <> call "LawSpecScalars.generator" [text "tpe", text "MachineBits"]))
                strategy = case (if nativeGenerators then [] else requiredSymbol plan) of
                  value:_ -> ("Arb", "constant", [call "LawSpecScalaStrategies.Checked" [expr value,text "null"]])
                  -- The target is evaluated from the inputs bound above.
                  [] | Just indexed <- generatorIndex plan -> ("LawSpecScalaStrategies", "indexedGenerator",
                    [text "Schema",reference ty,text "MachineBits",number nodeBudget,text "symbols",
                     expr (indexedTarget indexed),
                     call "Map" [quoted (C.idText tag) <> text " -> " <> call "List" (map quoted texts)
                       | (tag,texts) <- indexedEquations indexed],
                     scalarGenerators])
                  [] -> (,,) "LawSpecScalaStrategies" "checkedGenerator" $
                    [text "Schema",reference ty,text "MachineBits",number nodeBudget,
                     number (maxAttempts (generation e)),text "symbols",call "List" (seeds ++ hints)] ++
                    [text "lawspec.testing.LawSpecNativeGenerators.factories()" | nativeGenerators] ++
                    [scalar]
                (owner', method', args') = strategy
                added = L.trailingChain (text owner') [(method', args')] "map" ["drawn"]
                  [braced (L.condition "if" (text "drawn.error != null")) [state (text "values")] <> text " else " <>
                   L.block [state (text "values :+ drawn.requireValue()")]]
            pure $ L.trailing (call "Arb.flatMap" [prior]) ["inputs"]
              [braced (L.condition "if" (text "inputs.error != null")) [call "Arb.constant" [text "inputs"]] <> text " else " <>
               L.block (inputBindings (take index (inputs e)) ++ [added])]
      base <- foldM step (text "LawSpecScalaStrategies.cases()") (zip [0::Int ..] (generationPlan e))
      let predicates = concatMap inputRefinements (inputs e)
          strategy = if null predicates then base else L.trailing (call "LawSpecScalaStrategies.filterCases" [base,number (maxAttempts (generation e))]) ["inputs"]
            (inputBindings (inputs e) ++ [L.conjunctionStatement (map (truth . expr) predicates)])
          body = [text "val symbols = inputs.symbols", text "val values = inputs.requireValues()"] ++ fromValues (inputs e) ++ handlerInstalls e ++ [check]
      pure $ testFunction (fn ++ "_property: " ++ label) [L.trailingCall "LawSpecProperty.checkAll" [quoted label, number (cases (generation e)), strategy] ["inputs"] body]
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
            hints -> call "Arb.choice" [call "Arb.element" [L.block [symbols, call "List" hints]], gen]
          -- The inputs drawn together, with fresh symbols (LawSpecTesting).
          base = call "LawSpecTesting.inputs" [hinted inp (generatorWithin (inputRange machineBits inp) (inputType inp)) | inp <- inputs e]
          predicates = concatMap inputRefinements (inputs e)
          bindingsDoc = text "val (values, symbols) = inputs" : fromValues (inputs e)
          strategy = if null predicates then base else filtered base (bindingsDoc ++ [L.conjunctionStatement (map (truth . expr) predicates)])
      in testFunction (fn ++ "_property: " ++ label) [L.trailingCall "LawSpecProperty.checkAll" [quoted label, number (cases (generation e)), strategy] ["inputs"]
        (bindingsDoc ++ handlerInstalls e ++ [check])]
    domain e (index,plan) = do
      seeds <- mapM literal (generatorBoundaries plan)
      let inp = domainInput plan
          prior = take index (inputs e)
          valuesOf = text "val values = javaValues.asScala.toList"
          bounds = call "Array[LawSpecRuntime.Bound]" [call "LawSpecRuntime.Bound" [quoted op,expr v] | (op,v) <- domainBounds plan]
          candidates = runtime "domainCandidates" [quoted (typeKey (inputType inp)),text "caseSeed",text "MachineBits",
            bounds,E.array (seeds ++ map expr (generatorHints plan))]
          seedFn = L.parameters mempty [text "javaValues: java.util.List[LawSpecRuntime.Value]", text "caseSeed: Integer"] <> text " => " <>
            L.block ([valuesOf | not (null prior)] ++ (if null prior then [] else fromValues prior) ++ [candidates])
          predicate = text "(javaValues: java.util.List[LawSpecRuntime.Value]) => " <> L.block
            ([valuesOf] ++ fromValues (prior ++ [inp]) ++ [L.conjunctionStatement (map (truth . expr) (inputRefinements inp))])
      pure (call "LawSpecRuntime.Domain" [seedFn,predicate])
    refinedProperty fn label e check = do
      domains <- mapM (domain e) (zip [0::Int ..] (generationPlan e))
      let cfg = generation e
          callback = text "(javaValues: java.util.List[LawSpecRuntime.Value]) => " <> L.block
            ([text "val values = javaValues.asScala.toList"] ++ fromValues (inputs e) ++ handlerInstalls e ++ [check])
          invocation = runtime "refinedCase" [call "Array[LawSpecRuntime.Domain]" domains,
            text "seed",number (maxAttempts cfg),number (maxShrinks cfg),callback,
            quoted (label ++ " | " ++ intercalate "; " (map prettyExpr (concatMap inputRefinements (inputs e))))]
      pure $ testFunction (fn ++ "_property: " ++ label) [L.trailingCall "LawSpecProperty.checkAll"
        [quoted label, number (cases cfg), text "Arb.int(Int.MinValue to Int.MaxValue)"] ["seed"] (withSymbols [invocation])]

-- Whether a unit's laws install a Clock handler, so the test registers how
-- the runtime reads one (lawspec.time's registerClock).
installsClock :: Unit -> Bool
installsClock unit = or [ C.abilityKey a == "lawspec.time::ability::Clock"
                        | p <- C.unitProperties unit, (a, _) <- C.propertyHandlers p ]
