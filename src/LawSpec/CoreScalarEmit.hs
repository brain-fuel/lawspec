-- | The emitter for the dynamically typed targets, Python, JavaScript and
-- TypeScript, whose tests run on LawSpec's portable runtime rather than native
-- numeric types. Python's tests are written here; JavaScript's and
-- TypeScript's by LawSpec.WebTests. ref:DEC-portable-exact-arithmetic
module LawSpec.CoreScalarEmit (scalarEmit, scalarEmitWithData, scalarEmitWithDefinitions, scalarEmitWithFormat, scalarEmitWithNativeGenerators, typeKey) where
import LawSpec.Backend hiding (inputId, localName, bindings, contractArguments, contractResult)
import qualified LawSpec.Backend as Backend
import qualified Data.Map.Strict as M
import LawSpec.Naming (claim, scopeWith, localIdentifier, exampleTestSuffix, boundaryTestSuffix, displayLabel)
import LawSpec.SourceLink (generatedHeader, unitSourceFile, labelled, locationLink, exampleLocation, originLocation)
import LawSpec.Common
import LawSpec.Testing
import qualified LawSpec.Testing.Cover as Cover
import qualified LawSpec.Testing.Literals as Literals
import qualified LawSpec.Testing.Draws as Draws
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Core as C
import qualified LawSpec.PythonData as PythonData
import qualified LawSpec.WebTests as WebTests
import qualified LawSpec.PythonExpr as PythonExpr
import LawSpec.PythonTypes (pythonLayout)
import qualified LawSpec.Code.Doc as Doc
import qualified LawSpec.PortableGenerator as Generator
import qualified LawSpec.PortableTestHelpers as Helpers
import LawSpec.Scalar
import LawSpec.MachineSpec (machineSpec)
import LawSpec.Bounds (inputRange)
import LawSpec.Core.Program (programSpec)
import qualified LawSpec.Core.Machine as C
import Data.Aeson (encode)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T
import Data.List (intercalate, stripPrefix, nub)
import Data.Maybe (listToMaybe)
import Control.Monad (unless)
import Data.Char (toLower, isAlphaNum)
import qualified LawSpec.AbilityEmit.Python as PythonAbilities
import LawSpec.AbilityNames (specName, recordingName, productionName, interfaceName, ownAbilities, ownerName, unitAbility, unitAbilityPieces)
import LawSpec.TestNames (unitTestNames, lawWords)
import LawSpec.Search (lawDescriptors, searchable)

q :: String -> String
q = T.unpack . T.decodeUtf8 . encode
-- | Runtime calls name a value's type by a stable key, so generated code and the
-- runtime agree without sharing a type system.
typeKey :: Type -> String
typeKey = scalarTypeKey
-- | The default for callers with no data declarations.
scalarEmit :: Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
scalarEmit = scalarEmitWithData []
-- | The default for callers with no checked definitions.
scalarEmitWithData :: [C.DataDeclaration] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
scalarEmitWithData declarations = scalarEmitWithDefinitions declarations []
-- | Readable output is the default. ref:DEC-readable-output-default
scalarEmitWithDefinitions :: [C.DataDeclaration] -> [(C.Id,String)] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
scalarEmitWithDefinitions = scalarEmitWithFormat False
-- | Built-in generators unless the project binds its own.
scalarEmitWithFormat :: Bool -> [C.DataDeclaration] -> [(C.Id,String)] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
scalarEmitWithFormat = scalarEmitWithNativeGenerators False
-- | Only the targets that run on the portable runtime are accepted here; asking
-- for another is a compiler bug and fails loudly.
scalarEmitWithNativeGenerators :: Bool -> Bool -> [C.DataDeclaration] -> [(C.Id,String)] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
scalarEmitWithNativeGenerators nativeGenerators minify declarations definitions bits target u allLaws
  | target `elem` ["javascript", "typescript"] = WebTests.webTests nativeGenerators minify declarations definitions bits target u allLaws
  | otherwise = do
  unless (target == "python") (Left [Diagnostic "target-runtime" ("portable scalar runtime is not implemented for " ++ target) Nothing])
  lawTexts <- concat <$> mapM lawTests (zip [0 :: Int ..] ls)
  literalHelpers <- literalFunctions
  modelTexts <- concat <$> mapM modelTest (C.unitMachines u)
  -- A unit with supervisors also checks the runtime's supervision.
  let supervision
        | null (C.unitSupervisors u) = ""
        | otherwise = renderDocument (function "test_supervision" [] (statement (runtime "check_supervision" [])))
      -- The unit's harness: benchmarks, and order random.
      benchmarks = concatMap (renderDocument . benchmarkTest) (maybe [] C.harnessBenchmarks (C.unitHarnessSettings u))
      orderRandom = maybe False C.harnessOrderRandom (C.unitHarnessSettings u)
      -- Python: the harness driver's pytest hooks (lawspec_harness, through
      -- the generated conftest) read these flags.
      shuffled =
        concat [renderDocument (text "_LAWSPEC_ORDER_RANDOM = True") | orderRandom] ++
        concat [renderDocument (text "_LAWSPEC_PARALLEL = True") | parallel]
      -- parallel: Python's law tests are run by pytest-xdist when lawspec
      -- test finds it (see LawSpec.TestManifest).
      parallel = maybe False C.harnessParallel (C.unitHarnessSettings u)
      tests = lawTexts ++ modelTexts ++ supervision ++ benchmarks ++ shuffled
  wrappers <- concat <$> mapM contractWrapper (contracts u)
  let rest = testHelpers ++ literalHelpers ++ wrappers ++ tests
      -- The machine profile's width is named once (DEC-native-string-literals).
      usedNames = identifiers (dataHelpers ++ rest)
      constants = ["# The machine profile's integer width.\nMACHINE_BITS = " ++ show bits | "MACHINE_BITS" `elem` usedNames] ++
        ["# Unbounded integers are drawn within this limit.\nINTEGER_DRAW_LIMIT = 2**256" | "INTEGER_DRAW_LIMIT" `elem` usedNames]
      -- The constants come first: the data helpers' generator table uses them.
      bitsConstant = if not (null constants)
        then (if hasData then "\n" else "\n\n") ++ intercalate "\n" constants ++ (if hasData then "\n\n" else "\n") else ""
      body = bitsConstant ++ dataHelpers ++ rest
  pure [Artifact stubPath stub "user" "source",Artifact testPath (finish (pythonHeader body ++ body)) "generated" "test"]
  where
    finish content = reverse (dropWhile (== '\n') (reverse content)) ++ "\n"
    adapterFunctions = [(C.declarationName d,C.declarationType d) | d <- C.unitDeclarations u, C.declarationId d `notElem` map fst definitions]
    hasData = (nativeGenerators || not (null definitions) || not (null declarations) || any (usesData . snd) (functions u) ||
      unitAbilityPieces u || not (null (C.unitAbilities u)) ||
      any (any (usesData . inputType) . inputs) ls ||
      any expressionNeedsSchema (concatMap C.contractExpressions (contracts u) ++
        concatMap (C.propertyExpressions . original) ls))
    fieldContracts = hasConstructorContracts declarations
    usesData = PythonData.requiresSchema declarations
    expressionNeedsSchema term | C.AllPayloads _ _ <- C.expressionNode term = True
    expressionNeedsSchema term = usesData (expressionType term) || any expressionNeedsSchema (C.children term)
    -- A Python test module imports only what it uses.
    pythonHeader body =
      let used n = n `elem` identifiers body
          hypothesis = [n | n <- ["assume", "given", "settings"], used n] ++ ["strategies as st" | used "st"]
      in "# " ++ generatedHeader (unitSourceFile u) ++ "\n" ++ unlines (
        ["import lawspec_runtime as ls" | used "ls"] ++
        ["import lawspec_definition_bodies as _definitions" | not (null definitions), used "_definitions"] ++
        [i | hasData, (n, i) <- [("_builtins", "import builtins as _builtins"), ("data", "import lawspec_data as data"), ("_schema", "import lawspec_schema as _schema")], used n] ++
        ["import json" | used "json"] ++ ["import os" | used "os"] ++
        ["from hypothesis import " ++ intercalate ", " hypothesis | not (null hypothesis)] ++
        ["from hypothesis import seed as _lawspec_seed" | used "_lawspec_seed"] ++
        ["from hypothesis.database import DirectoryBasedExampleDatabase" | used "DirectoryBasedExampleDatabase"] ++
        ["import " ++ unitName u ++ " as impl" | not (null adapterFunctions && null (ownAbilities u)), used "impl"] ++
        ["import " ++ PythonAbilities.moduleName u ++ " as _abilities" | unitAbilityPieces u, used "_abilities"] ++
        ["import lawspec_harness as _harness" | hasHarness, used "_harness"])
    dataImports = if hasData then "import builtins as _builtins\nimport lawspec_data as data\nimport lawspec_schema as _schema\n" else ""
    nodeCount (V.ScalarValue _) = 1
    nodeCount (V.PresenceValue _ value) = 1 + maybe 0 nodeCount value
    nodeCount value@(V.DataValue (C.Constructor "List" _) _ _) = either (const 1) ((+1) . sum . map nodeCount) (V.listItems value)
    nodeCount (V.DataValue _ _ fields) = 1 + sum (map nodeCount fields)
    budget = maximum (64 : [8 + nodeCount value | law <- ls, requirement <- generationPlan law, value <- generatorBoundaries requirement])
    outputLayout = Doc.selectLayout minify pythonLayout
    referenceDoc ty = either error id (PythonData.pythonTypeReferenceDoc ty)
    generatorDoc = Generator.generatorDoc bits usesData referenceDoc
    dataHelpers = if not hasData then "" else
      "from " ++ (if nativeGenerators then "lawspec_native_generators" else "lawspec_data_strategies") ++ " import strategy as _data_strategy\n\n\n" ++
      Doc.render outputLayout (Helpers.dataHelperDoc bits budget
        [PythonExpr.quoted (primitiveName p) <> Doc.text ": " <>
          generatorDoc (Named (primitiveName p)) | p <- primitives]) ++
      "\n\n\n"
    ext = ".py"
    parts = split (unitName u)
    slash = intercalate "/" parts
    stubPath = "src/" ++ slash ++ ext
    testPath = "tests/test_" ++ intercalate "_" parts ++ "_lawspec.py"
    ls = filter ((== unitName u) . owner) allLaws
    testNames = unitTestNames target (map name ls)
    hasHarness = C.unitHarnessSettings u /= Nothing || any ((/= Nothing) . C.harnessUnit . C.propertyHarness . original) ls
    testHelpers = (if hasData then "" else "\n\n") ++
      Doc.render outputLayout Helpers.assertionHelperDoc ++ seedHelper ++ "\n\n\n"
    native ty | usesData ty = either error id (PythonData.pythonDataType declarations ty)
    native (Applied "Maybe" _) = "ls.DataValue"
    native (C.Constructor "Either" _) = "ls.DataValue"
    native (Applied "List" element) = "list[" ++ (if element == Named "Unit" then "ls.Absence" else native element) ++ "]"
    native (Named n) = case n of
      "Bytes" -> "bytes"; "Bool" -> "bool"; "Text" -> "str"; "Char" -> "str"; "Decimal" -> "ls.Decimal"; "Rational" -> "ls.Fraction"
      "Float32" -> "float"; "Float64" -> "float"; "Complex64" -> "complex"; "Complex128" -> "complex"
      "Symbol" -> "ls.Symbol"; "Unit" -> "None"; _ | isInteger n || n `elem` ["CodePoint","CodeUnit16"] -> "int"
      _ | n `elem` ["Unit","Null","Undefined"] -> "ls.Absence"
      _ -> "ls.Raw"
    native _ = "ls.Presence"
    stub = "# User-owned LawSpec adapter.\n" ++ dataImports ++ "import lawspec_runtime as ls\n" ++ (if not (null adapterFunctions && null (ownAbilities u)) then "\n\n" else "") ++ intercalate "\n\n" (map stubFn adapterFunctions ++ map productionStub (ownAbilities u))
    -- Each ability's production handler is written by hand, like an adapter.
    productionStub ability = either error id (PythonAbilities.productionStub declarations ability)
    nativeArg ty | usesData ty = native ty
    nativeArg (Applied "List" element) = "list[" ++ nativeArg element ++ "]"
    nativeArg t = if t == Named "Integer" then "int" else if t == Named "Unit" then "ls.Absence" else native t
    stubFn (n,t) = Doc.render outputLayout $
      let (args,r) = functionType t
          pythonType ty = if usesData ty then either error id (PythonData.pythonDataTypeDoc declarations ty) else Doc.text (nativeArg ty)
          -- First, a handler for each ability the adapter uses.
          handlerArguments = [Doc.text (handlerParameter ability) <>
            Doc.text (": " ++ q (maybe "object" (\a -> PythonAbilities.moduleNameOf (ownerName a) ++ "." ++ interfaceName a) (abilityNamed ability))) |
            d <- C.unitDeclarations u, C.declarationName d == n, ability <- C.declarationUses d, not (C.isFail ability)]
          arguments = handlerArguments ++ [Doc.text ("value" ++ show i) <>
            Doc.text ": " <> pythonType a |
            (i,a) <- zip [0 :: Int ..] args]
          -- Native representations can erase LawSpec distinctions. Keep the
          -- declared interface visible in both the stub and its canonical key.
          signatureComments =
            mconcat [stubComment ("LawSpec argument " ++ show i ++ ": " ++ prettyType a) |
              (i,a) <- zip [0 :: Int ..] args] <>
            stubComment ("LawSpec result: " ++ prettyType r)
          asyncStub = n `elem` asyncFunctions u
          signature = Doc.text ((if asyncStub then "async def " else "def ") ++ n) <>
            Doc.delimitTrailing 4 "(" ")" arguments <>
            -- ruff breaks the parameters before the return annotation.
            Doc.text " -> " <> (if r == Named "Unit" then Doc.text "None" else Doc.text (Doc.render Doc.Compact (pythonType r))) <> Doc.text ":"
      in signatureComments <> signature <>
        Doc.nest 4 (Doc.hardline <> Doc.text ("raise NotImplementedError(" ++ q n ++ ")")) <> Doc.hardline

    stubComment = Doc.lineComment 72 "# "
    text = Doc.text
    quoted = PythonExpr.quoted
    -- A message is one string literal; ruff never splits one.
    message = quoted
    invoke = PythonExpr.call
    array = PythonExpr.array
    indentation = 4
    width = text "MACHINE_BITS"
    -- Python locals keep their source names (LawSpec.Naming), each law's
    -- distinct within it.
    localName identity = M.findWithDefault (Backend.localName identity) identity pythonLocals
    inputId = localName . C.binderId . C.quantifiedBinder
    bindings example = [(localName i, v) | (i, v) <- C.exampleBindings example]
    contractArguments contract = [(localName (C.binderId b), C.binderType b) | b <- C.contractArguments contract]
    contractResult contract = let b = C.contractResult contract in (localName (C.binderId b), C.binderType b)
    pythonLocals = M.fromList (concatMap (allocate . propertyBinders . original) ls ++
      concatMap (\c -> allocate (C.contractArguments c ++ [C.contractResult c])) (contracts u))
    allocate binders = snd (foldl (\(scope, named) b -> if any ((== C.binderId b) . fst) named then (scope, named) else
      let (chosen, scope') = claim scope (localIdentifier "python" (C.binderName b))
      in (scope', named ++ [(C.binderId b, chosen)])) (scopeWith (PythonExpr.pythonReserved ++ testModuleNames), []) binders)
    -- What a Python test module imports, which its locals must not shadow.
    testModuleNames = words "impl json os st given settings assume _case_values _case_context" ++
      ["_assert_" ++ drop 5 name | name <- testNames]
    -- Readable text about a law names its binders as the source does.
    shownLaw e = owner e ++ "::" ++ displayLabel (name e)
    -- A failing assertion names its law and case and points at its source.
    expectationLink proposition = case proposition of
      AssertEqual a _ | Just l <- originLocation (C.expressionOrigin a), take 1 (file l) /= "<" -> Just (locationLink l)
      _ -> Nothing
    -- symbols holds a case's handlers and fixtures; a test without either
    -- does not make it.
    usesSymbols doc = "symbols" `elem` identifiers (Doc.render Doc.Compact doc)
    identifiers = words . map (\c -> if isAlphaNum c || c == '_' then c else ' ')
    runtime name = invoke ("ls." ++ name)
    schema name arguments = invoke ("_lawspec_schema." ++ name)
      (arguments ++ [text "symbols"])
    statement value = value
    statements = Doc.joinWith Doc.hardline
    parenthesized value = Doc.group (text "(" <> Doc.nest 4 (Doc.softbreak <> value) <> Doc.softbreak <> text ")")
    method value name arguments = value <> text "." <> invoke name arguments
    lambda = PythonExpr.lambdaExpression
    function name parameters body =
      let header = text ("def " ++ name) <>
            Doc.delimitTrailing indentation "(" ")" (map text parameters)
      in PythonExpr.suite header body
    assign name value = statement (text (name ++ " = ") <> Doc.statementValue value)
    freshSymbols = assign "symbols" (text "{}")
    renderDocument doc = Doc.render outputLayout doc ++ "\n\n\n"
    testBlock _ name body = function name [] body
    nativeInput ty value = if usesData ty
      then schema "to_native" [referenceDoc ty,value,width] else value
    checkedResult ty value = if usesData ty
      then schema "from_native" [referenceDoc ty,value,width]
      else runtime "validate"
        [if ty == Named "Unit" then runtime "unit_result" [value] else value,
         quoted (typeKey ty),width]
    -- A handler's values cross with the handler schema: the bound native
    -- types when lawspec.edn binds them (ls.handler_schema).
    handlerSchema name args = PythonExpr.handlerSchemaCall name (args ++ [text "symbols"])
    handlerInput ty value = if usesData ty
      then handlerSchema "to_native" [referenceDoc ty,value,width] else value
    handlerResult ty value = if usesData ty
      then handlerSchema "from_native" [referenceDoc ty,value,width]
      else checkedResult ty value
    converted ty value = if usesData ty then schema "validate" [referenceDoc ty,value,width]
      else runtime "convert" [value,quoted (typeKey ty),width]
    -- The handler a law installed for an ability.
    handlerDoc ability = runtime "handler" [text "symbols", quoted (C.abilityKey ability)]
    constructed ty tag fields = if usesData ty
      then schema "construct" [referenceDoc ty,quoted tag,array fields,width]
      else runtime "construct" [quoted tag,array fields]
    equality ty a b = if usesData ty then schema "equal" [referenceDoc ty,a,b,width]
      else runtime "equal" [a,b,quoted (typeKey ty),quoted (typeKey ty)]
    -- A law's handlers, made afresh for each case and installed in its
    -- symbols, where the code it calls finds them.
    -- A handler of several abilities is made once, and installed for each.
    -- A native handler made with a resource (ability A with T) is made once
    -- the case has acquired its T, inside the bracket.
    installs e = [assign (sharedName h) (construct plainContext (C.handlerAbility h) (C.SpecHandler (C.handlerId h))) | h <- sharedHandlers e] ++
      installing e [(a, c) | (a, c) <- chosenHandlers e, resourceFor e a c == Nothing]
    lateInstalls e = installing e [(a, c) | (a, c) <- chosenHandlers e, resourceFor e a c /= Nothing]
    installing e chosen = case chosen of
      [] -> []
      _ -> [statement (runtime "install_handlers" [text "symbols", Doc.delimitTrailing indentation "{" "}"
        [quoted (C.abilityKey ability) <> text ": " <> construct (lawContext e) ability choice | (ability, choice) <- chosen]])]
    -- What making a law's handlers needs: the handlers it shares, and the
    -- resources its native handlers are made with.
    lawContext e = (sharedHandlers e, resourceFor e)
    plainContext = ([], \_ _ -> Nothing)
    chosenHandlers e = [(ability, choice) | (ability, choice) <- C.propertyHandlers (original e), not (C.isFail ability)]
    sharedHandlers e = nub [h | (_, c) <- chosenHandlers e, h <- specHandlersOf c, not (null (C.handlerAlso h))]
    specHandlersOf c = case c of
      C.SpecHandler h -> [x | x <- C.unitHandlers u, C.handlerId x == h]
      C.RecordingHandler inner -> specHandlersOf inner
      C.ProductionHandler -> []
    sharedName h = "_lawspec_shared_" ++ C.handlerName h
    -- The resource a native handler is made with, as the case holds it.
    resourceFor e ability choice = case choice of
      C.ProductionHandler -> do
        a <- abilityNamed ability
        t <- C.abilityResource a
        r <- listToMaybe [r | r <- C.propertyResources (original e), C.binderType (C.resourceBinder r) == t]
        pure (nativeInput t (text (localName (C.binderId (C.resourceBinder r)))))
      C.RecordingHandler inner -> resourceFor e ability inner
      C.SpecHandler _ -> Nothing
    construct context@(shared, resourceOf) ability choice = let made = maybe [] pure (resourceOf ability choice) in case choice of
      C.ProductionHandler -> case abilityNamed ability >>= C.abilityNative of
        -- A production handler bound in lawspec.edn.
        Just parts -> runtime "native_handler" ([quoted (intercalate "." (init parts)), quoted (last parts)] ++ made)
        Nothing -> case abilityNamed ability of
          -- An imported ability's production handler is its owner's.
          Just a | ownerName a /= unitName u -> runtime "native_handler" ([quoted (ownerName a), quoted (productionName a)] ++ made)
          _ -> invoke ("impl." ++ maybe "Unknown" productionName (abilityNamed ability)) made
      C.SpecHandler h | Just x <- lookup h [(C.handlerId x, x) | x <- shared] -> text (sharedName x)
      C.SpecHandler h -> invoke ("_abilities." ++ maybe "Unknown" specName
        (lookup h [(C.handlerId x, x) | x <- C.unitHandlers u])) [text "symbols"]
      C.RecordingHandler inner -> case abilityNamed ability of
        Just a | ownerName a /= unitName u ->
                   runtime "native_class" [quoted (PythonAbilities.moduleNameOf (ownerName a)), quoted (recordingName a)] <>
                   Doc.delimitTrailing indentation "(" ")" [construct context ability inner, text "symbols"]
        _ -> invoke ("_abilities." ++ maybe "Unknown" recordingName (abilityNamed ability))
          [construct context ability inner, text "symbols"]
    handlerParameter ability = case maybe "handler" C.abilityName (abilityNamed ability) of
      c : rest -> toLower c : rest
      [] -> "handler"
    abilityNamed = unitAbility u
    -- An adapter that fails with E: native code raises the runtime's Fail
    -- with a native E (or an exception lawspec.edn maps to one), which
    -- becomes the Fail E failure.
    nativeFailures decl call = case [a | d <- C.unitDeclarations u, C.declarationId d == decl, a@(C.AbilityRef _ [_]) <- C.declarationUses d, C.isFail a] of
      ability@(C.AbilityRef _ [failure]) : _ ->
        runtime "native_failures"
          [quoted (C.abilityKey ability), lambda [text "_failure"] (checkedResult failure (text "_failure")), lambda [] call,
           mappedFailures failure]
      _ -> call
    -- An operation that fails with E: a native handler raises the
    -- runtime's Fail with a native E, which becomes the Fail E failure; a
    -- spec handler's raise passes through.
    operationFailures op call = case abilityNamed (C.operationAbility op) >>= lookup (C.operationName op) . C.abilityFailures of
      Just ability@(C.AbilityRef _ [failure]) ->
        runtime "native_failures"
          [quoted (C.abilityKey ability), lambda [text "_failure"] (checkedResult failure (text "_failure")), lambda [] call,
           mappedFailures failure]
      _ -> call
    mappedFailures failure = case [b | b <- C.unitFailureBindings u, C.failureType b == failure] of
      [] -> text "()"
      bindings -> Doc.delimitTrailing indentation "[" "]"
        [ Doc.delimitTrailing indentation "(" ")"
            [ runtime "native_class" [quoted (intercalate "." (init (C.failureNative b))), quoted (last (C.failureNative b))]
            , lambda [text "_error"] (constructed failure (C.idText (C.failureConstructor b))
                (C.mapFailureFields (\ty tag -> constructed ty (C.idText tag))
                  (converted (C.scalarType "Text") (text "_builtins.str(_error)")) b)) ]
        | b <- bindings ]
    fresh e = statements (freshSymbols : installs e)
    -- A case makes symbols only when something in it uses them.
    withSymbols e docs
      | null (installs e) && null (C.propertyResources (original e)) && not (any usesSymbols docs) = statements docs
      | otherwise = statements (fresh e : docs)
    -- A law's resources: each case acquires them, then runs, then releases
    -- them, the last first, even when the case fails.
    bracket e doc = foldr wrap (statements (lateInstalls e ++ [doc])) (C.propertyResources (original e))
      where
        -- A shared resource (share R per ...): the runtime keeps one per
        -- scope key, resets it before every use after the first, holds it
        -- for one case at a time, and releases it when the process ends.
        wrap r inner | Just key <- C.resourceShared r, Just reset <- C.resourceReset r =
          let local = localName (C.binderId (C.resourceBinder r))
              shareCall = runtime "share"
                [quoted key, lambda [] (render (C.resourceAcquire r)),
                 lambda [text local] (render reset), lambda [text local] (render (C.resourceRelease r)),
                 text (if C.resourceConcurrent r then "True" else "False")]
              returned = statement (runtime "unshare" [quoted key])
          in statements
          [ assign local shareCall
          , PythonExpr.suite (text "try") inner <> Doc.hardline <> PythonExpr.suite (text "finally") returned ]
        wrap r inner = statements
          [ assign (localName (C.binderId (C.resourceBinder r))) (render (C.resourceAcquire r))
          , PythonExpr.suite (text "try") inner <> Doc.hardline <>
                PythonExpr.suite (text "finally") (statement (render (C.resourceRelease r))) ]
    render = renderWith False
    -- A lambda's body, where Python drops redundant parentheses.
    renderBody = renderWith True
    renderWith atBody term = either error id (renderer declarations bits localName external term)
      where
        renderer = if atBody then PythonExpr.renderExpressionBody else PythonExpr.renderExpression
        external expression values = case C.expressionNode expression of
          -- raise aborts to the nearest attempt of its Fail ability.
          C.Perform op [_] | C.isFail (C.operationAbility op) ->
            Right (runtime "raise_failure" (quoted (C.abilityKey (C.operationAbility op)) : values))
          -- An operation goes to the handler installed for its ability.
          C.Perform op args ->
            let call = method (handlerDoc (C.operationAbility op)) (C.operationName op)
                  [handlerInput (expressionType a) (converted (expressionType a) value) | (a,value) <- zip args values]
            in Right (operationFailures op (handlerResult (expressionType expression) call))
          -- handle e with h end: e runs with h installed for its ability.
          C.Handle (C.WithHandler ability choice) _ | [body] <- values ->
            Right (runtime "with_handlers" [text "symbols",
              Doc.delimitTrailing indentation "{" "}" [quoted (C.abilityKey ability) <> text ": " <> construct plainContext ability choice],
              lambda [] body])
          C.Handle (C.CatchFailure ability) _ -> case (expressionType expression, values) of
            (C.Constructor "Either" [C.TypeArgument failure, C.TypeArgument result], [body]) ->
              let side tag ty = lambda [text "_value"] (constructed (expressionType expression) tag [converted ty (text "_value")])
                  attempt = runtime "attempt" [quoted (C.abilityKey ability), lambda [] body,
                    side "Either::Right" result, side "Either::Left" failure]
              in Right attempt
            _ -> Left "attempt gives an Either"
          C.Calls op args ->
            let matches = case args of
                  Nothing -> text "None"
                  Just xs -> lambda [text "_recorded"] (conjunction
                    [equality (expressionType a) (text ("_recorded[" ++ show i ++ "]")) value | (i,(a,value)) <- zip [0 :: Int ..] (zip xs values)])
            in Right (runtime "count_calls" [handlerDoc (C.operationAbility op), quoted (C.operationName op), matches])
          C.ExternalCall decl args -> case lookup decl definitions of
            -- An asynchronous definition (an async workflow) is awaited.
            Just name -> Right (invoke name (text "symbols":values))
            Nothing ->
              let convertedValues = [converted (expressionType a) value | (a,value) <- zip args values]
                  -- A native adapter gets a handler for each ability it uses, first.
                  handlers = [handlerDoc ability | d <- C.unitDeclarations u, C.declarationId d == decl, ability <- C.declarationUses d, not (C.isFail ability)]
                  invocation = awaited (adapterName u decl) (invoke ("impl." ++ adapterName u decl)
                    (handlers ++ [nativeInput (expressionType a) value | (a,value) <- zip args convertedValues]))
              in Right (if declarationName decl `elem` map contractName (contracts u)
                then invoke ("_lawspec_call_" ++ declarationName decl) (text "symbols":convertedValues)
                else nativeFailures decl (checkedResult (expressionType expression) invocation))
          _ -> Left "expected portable external call"
    -- Python messages end with the expectation's source line, or the law's.
    assertionDocLinked fallback context = assertionDocWith fallback (\link -> message (labelled context link))
    assertionDocWith fallback context proposition = case proposition of
      AssertAll propositions -> statements (map (assertionDocWith fallback context) propositions)
      AssertImplies guard body ->
        PythonExpr.suite (text "if " <> Doc.unparen (renderBody guard)) (assertionDocWith fallback context body)
      AssertEqual left right ->
        let thunk value = lambda [] value
            arguments = [context (maybe fallback Just (expectationLink proposition)),
              thunk (renderBody left),thunk (renderBody right)]
            structural = usesData (expressionType left)
            extra = if structural then [referenceDoc (expressionType left),text "symbols"]
              else map (quoted . typeKey . expressionType) [left,right]
            helper = if structural then "_lawspec_data_assert" else "_lawspec_assert"
        in statement (invoke helper (arguments ++ extra))
    conjunction [] = text "True"
    -- Python operands are calls or already parenthesised.
    conjunction [x] = x
    conjunction expressions = Doc.operation expressions (replicate (length expressions - 1) "and")
    -- LAWSPEC_SEED fixes each property's random seed, so a run can be
    -- repeated exactly (lawspec test records the seed of every passing run).
    seedHelper = "\n\n\n# Adapters may be slow (networks, timers): no per-example deadline.\n# Under lawspec test, failing examples are kept in its failure database.\n_lawspec_failures = os.environ.get(\"LAWSPEC_FAILURES\")\n_lawspec_database = (\n    {\n        \"database\": DirectoryBasedExampleDatabase(\n            os.path.join(_lawspec_failures, \"hypothesis\")\n        )\n    }\n    if _lawspec_failures\n    else {}\n)\nsettings.register_profile(\"lawspec\", deadline=None, **_lawspec_database)\nsettings.load_profile(\"lawspec\")\n\n\ndef _lawspec_seeded(test):\n    value = os.environ.get(\"LAWSPEC_SEED\")\n    return test if value is None else _lawspec_seed(int(value))(test)\n" ++
        "\n\n# Workflows wait on a virtual clock under test.\nls.use_virtual_clock()" ++
        (if installsClock u then "\n\n# Workflows and mailboxes read the Clock handler a law installs.\nls.native_class(\"lawspec.time\", \"register_clock\")()" else "")
    pythonProperty prefix decorators names body = statements
      (map (\decorator -> text "@" <> decorator) (text "_lawspec_seeded" : decorators) ++ [function (prefix ++ "_property") names body])
    lawTests (index,e) = do
      let label = owner e ++ "::" ++ name e
          harness = C.propertyHarness (original e)
          -- Python names a law's tests after its label (LawSpec.TestNames);
          -- a known-discrepancy law's tests are helpers its one test calls.
          base = testNames !! index
          wrapped = C.harnessSkip harness == Nothing && C.harnessKnownDiscrepancy harness == Nothing && runSettings harness
          prefix = (if C.harnessKnownDiscrepancy harness /= Nothing then "_lawspec_known_" ++ drop 5 base
            else if wrapped then "_" ++ base else base) ++ "_"
          -- Python names an example's test after the example
          -- (normalizers_agree__spaces_become_hyphens) and numbers boundaries
          -- from 1; each test's comment links it to its source line.
          exampleSuffixes = map ("_" ++) (exampleTestSuffix "python" ("property" : "replay" : "skipped" : "known_discrepancy" :
              map boundaryTestSuffix [0 .. length cases' - 1]) (map exampleName (examples (original e))))
          sharedAssertion = "_assert_" ++ drop 5 base
          assertionNames = map inputId (inputs e) ++
            [localName (C.binderId (C.resourceBinder resource)) | resource <- C.propertyResources (original e)]
          assertionContext link = Doc.operation [text "_case_context", message (labelled "" link)] ["+"]
          assertionFunction = function sharedAssertion ("_case_context" : "symbols" : assertionNames)
            (assertionDocWith lawLink assertionContext (assertion e))
          checkClaim context = statement (invoke sharedAssertion
            (context : text "symbols" : map text assertionNames))
          shown = shownLaw e
          exampleContext example = shown ++ " example " ++ displayLabel (exampleName example)
          linked context link test = Doc.lineComment 88 "# " (labelled context link) <> test
          lawLink = if null (file (location (original e))) then Nothing else Just (locationLink (location (original e)))
          short = displayLabel (name e)
          examples' = [linked ("example " ++ displayLabel (exampleName example)) (locationLink <$> exampleLocation example) $
            testBlock (label ++ " example: " ++ exampleName example)
            (prefix ++ suffix) (
              (withSymbols e ([assign name (render value) | (name,value) <- bindings example] ++
               [bracket e (statements (map (assertionDocLinked lawLink (exampleContext example)) (expectations example) ++
                 [checkClaim (message shown)]))]))) |
            (suffix,example) <- zip exampleSuffixes (examples (original e))]
          finite = finiteCases e
          cases' = maybe (boundaryCases e) id finite
      cover <- either (Left . pure . (\message -> Diagnostic "generation" message Nothing)) Right (caseCover e)
      coverExpression <- caseCoverExpression cover
      let coverCheck = "_check_" ++ drop 5 base
          coverRun = coverCheck ++ "_run"
          coverFunctions = "_cases_" ++ drop 5 base
          coverPrefix = if wrapped then base ++ "_" else prefix
          coverAssignments = [assign (inputId input)
            (invoke ("_case_values[" ++ show i ++ "]") [text "symbols"])
            | (i, input) <- zip [0 :: Int ..] (inputs e)]
          checkDoc = function coverCheck ["_case_values", "_case_context"]
            (withSymbols e (coverAssignments ++ [bracket e (checkClaim (text "_case_context"))]))
          wrapDoc = function coverRun ["name", "body"] (harnessInvocation label harness (text "body") (text "name") False)
          registerDoc = statement (text (coverFunctions ++ " = ") <> runtime "register_finite_cases"
            ([invoke "globals" [], quoted coverPrefix, coverExpression, text coverCheck, message shown] ++
             [text coverRun | wrapped]))
          boundariesText = if Cover.coverCount cover == 0 then "" else
            renderDocument (linked (short ++ ", finite cases") lawLink checkDoc) ++
            (if wrapped then renderDocument wrapDoc else "") ++ renderDocument registerDoc
      -- LawSpec's own search (LawSpec.Search): a failing generated case's
      -- inputs are kept in the failure database, and replayed before the
      -- law's next cases; where fast-check cannot target, a law with
      -- `target maximize` also climbs (Hypothesis targets by itself).
      let descriptors = if searchable (maybe False (const True) finite) (original e) then lawDescriptors bits declarations (original e) else Nothing
          -- Each input's descriptor, kept once beside the law's tests.
          descriptorName = "_lawspec_inputs_" ++ drop 5 base
          descriptorDoc _ = text descriptorName
          remembered doc = case descriptors of
            Nothing -> doc
            Just ds ->
              let remember = statement (runtime "search_remember" [message label, descriptorDoc ds, array (map (text . inputId) (inputs e))])
              in PythonExpr.suite (text "try") doc <> Doc.hardline <> PythonExpr.suite (text "except Exception") (statements [remember, text "raise"])
          caseName = "_lawspec_case_" ++ drop 5 base
          caseDoc = let
              assigned = [assign (inputId input) (converted (inputType input) (text ("_values[" ++ show i ++ "]"))) | (i, input) <- zip [0 :: Int ..] (inputs e)]
              refinements = concatMap inputRefinements (inputs e)
              guardDoc = if null refinements then [] else
                [PythonExpr.suite (text "if not " <> conjunction (map render refinements)) (text "return None")]
              score = maybe (text "0") render (C.harnessTarget harness)
              bodyDoc = withSymbols e (assigned ++ guardDoc ++
                [bracket e (checkClaim (message (shown ++ " search"))), statement (text "return " <> score)])
            in function caseName ["_values"] bodyDoc
          searchDocs = case descriptors of
            Nothing -> ("", "")
            Just ds ->
              ( renderDocument (assign descriptorName (array (map quoted ds))) ++
                renderDocument caseDoc ++
                renderDocument (function (base ++ "__replay") [] (statement (runtime "search_replay" [message label, descriptorDoc ds, text caseName])))
              , "" )
      let body = statements (observations e ++ [remembered (bracket e (checkClaim (message (shown ++ " property"))))])
          generators = map (generatorDoc . inputType) (inputs e)
          names = map inputId (inputs e)
          ordinary = pythonProperty prefix [invoke "given" generators] names
            (withSymbols e [body])
      refined <- (if any (containsStructural . inputType) (inputs e) then nativeRefinedProperty else refinedProperty) prefix e body
      let needsContext = nativeGenerators || fieldContracts && any (usesData . inputType) (inputs e)
            || any (maybe False (const True) . generatorIndex) (generationPlan e)
      contextual <- if needsContext then
        contextualProperty prefix e body
        else pure ordinary
      drawn <- if not (null (C.harnessDraws harness)) then pure <$> harnessProperty prefix e body else pure []
      let properties = if maybe False (const True) finite then [] else
            if not (null drawn) then drawn else
            [if needsContext then contextual else if any (not . null . inputRefinements) (inputs e) || propertyKind e == "contract" then refined else ordinary]
          propertyDocs = map (linked (short ++ ", property") lawLink) properties
          propertySuffixes = ["_property" | not (null properties)]
          renderTests suffixes docs = if wrapped then concat
            [renderDocument doc ++ renderDocument (harnessRun label harness (prefix ++ suffix) (base ++ "_" ++ suffix) (suffix == "_property"))
            | (suffix, doc) <- zip suffixes docs] else concatMap renderDocument docs
          knownCases = Doc.operation
            [array [text (prefix ++ suffix) | suffix <- exampleSuffixes],
             if Cover.coverCount cover == 0 then array [] else text coverFunctions,
             array [text (prefix ++ suffix) | suffix <- propertySuffixes]] ["+", "+"]
      pure ((if C.harnessSkip harness /= Nothing then "" else renderDocument assertionFunction) ++
        Doc.render outputLayout (mconcat (map (Doc.lineComment 88 "# ") (lawCommentLines e))) ++ fst searchDocs ++ (++ snd searchDocs) (
        case (C.harnessSkip harness, C.harnessKnownDiscrepancy harness) of
          -- A skipped law runs nothing; it is still an obligation.
          (Just reason, _) -> renderDocument (function (base ++ "__skipped") []
            (statement (invoke "_harness.skip" [message label, message reason])))
          (_, Just reason) -> concatMap renderDocument examples' ++ boundariesText ++ concatMap renderDocument propertyDocs ++
            renderDocument (function (base ++ "__known_discrepancy") []
            (statement (invoke "_harness.known_discrepancy" [message label, quoted (base ++ "__known_discrepancy"), message reason,
              knownCases])))
          _ -> renderTests exampleSuffixes examples' ++ boundariesText ++ renderTests propertySuffixes propertyDocs))
    -- The harness plane (LawSpec.Harness). A law whose harness sets how its
    -- tests run (timeout, repeat, retry flaky, adequacy) has each test
    -- wrapped: the generated test calls the runtime with the law's own test.
    runSettings harness = C.harnessTimeout harness /= Nothing || C.harnessRepeat harness /= 1 ||
      C.harnessRetries harness /= 0 || observed harness
    observed harness = not (null (C.harnessCover harness) && null (C.harnessClassify harness) &&
      null (C.harnessLabels harness)) || C.harnessTarget harness /= Nothing
    harnessRun label harness inner public isProperty = function public []
      (harnessInvocation label harness (text inner) (quoted public) isProperty)
    harnessInvocation label harness inner public isProperty = statement (invoke "_harness.run"
      ([message label, public, inner] ++
       [text "timeout=" <> text (show ms) | Just ms <- [C.harnessTimeout harness]] ++
       [text ("repeat=" ++ show (C.harnessRepeat harness)) | C.harnessRepeat harness /= 1] ++
       [text ("retries=" ++ show (C.harnessRetries harness)) | C.harnessRetries harness /= 0] ++
       [text "covers=" <> array [array [text (show p), quoted l] | C.Cover p l _ <- C.harnessCover harness] | isProperty, not (null (C.harnessCover harness))] ++
       [text "observed=True" | isProperty, observed harness]))
    -- What a generated case covers, classifies and labels, and the score
    -- targeted search maximizes. Only property tests observe.
    observations e =
      let harness = C.propertyHarness (original e)
          label = owner e ++ "::" ++ name e
          field key value = text (key ++ "=") <> value
          fields = [field "covers" (array [array [quoted l, render w] | C.Cover _ l w <- C.harnessCover harness]) | not (null (C.harnessCover harness))] ++
            [field "classes" (array [array [quoted l, render c] | (c, l) <- C.harnessClassify harness]) | not (null (C.harnessClassify harness))] ++
            [field "labels" (array (map render (C.harnessLabels harness))) | not (null (C.harnessLabels harness))]
      in if not (observed harness) then [] else
        [statement (invoke "_harness.observe" ([message label] ++ fields))] ++
        [statement (invoke "_harness.target" [render score, message label]) | Just score <- [C.harnessTarget harness]]
    -- A property whose inputs a harness strategy draws: each strategy's
    -- value must satisfy its input's refinements; other inputs are drawn as
    -- usual and filtered by theirs.
    harnessProperty prefix e body = do
      let harness = C.propertyHarness (original e)
          strategyOf input = [(n, d) | (i, n, d) <- C.harnessDraws harness, i == C.binderId (C.quantifiedBinder input)]
      draws <- mapM (\(index,plan) -> do
        let input = domainInput plan
            predicate = conjunction (map render (inputRefinements input))
        case strategyOf input of
          (strategy, draw) : _ -> do
            (helpers,value) <- sharedDraw e index plan strategy draw
            pure (helpers,[assign (inputId input) (invoke "_harness.check_drawn"
              [quoted strategy, quoted (inputName input), lambda [text (inputId input)] predicate, value])])
          [] -> do
            strategy <- contextStrategy e plan
            pure ([],[assign (inputId input) (method (text "_draw") "draw" [strategy])] ++
              [statement (invoke "assume" [predicate]) | not (null (inputRefinements input))]))
        (zip [0 :: Int ..] (generationPlan e))
      let helpers = concatMap fst draws
          assignments = concatMap snd draws
          separated = case assignments of
            first : rest | not (null helpers) -> (Doc.hardline <> first) : rest
            _ -> assignments
      pure (pythonProperty prefix
        [pythonSettings (cases (generation e)), invoke "given" [invoke "st.data" []]] ["_draw"]
        (statements (fresh e : map (Doc.hardline <>) helpers ++ separated ++ [body])))
    sharedDraw e index requirement strategy draw = do
      graph <- literalChecked (Draws.planDraw requirement
        (map generatorBinder (take index (generationPlan e))) draw)
      let helperName number = "_draw_" ++ inputId (domainInput requirement) ++ "_" ++ show index ++ "_" ++ show number
          call node = invoke (helperName (Draws.drawCallee node))
            (map (text . localName) (Draws.drawArguments node))
          helper node = do
            body <- case Draws.drawStep node of
              Draws.AnyDraw ty (Just aim) | Just range <- inputRange bits aim -> pure
                (method (text "_draw") "draw" [Generator.generatorDocWithin bits usesData referenceDoc (Just range) ty])
              Draws.AnyDraw ty _ | ty == inputType (domainInput requirement) ->
                (\source -> method (text "_draw") "draw" [source]) <$> contextStrategy e requirement
              Draws.AnyDraw ty _ -> pure (method (text "_draw") "draw" [generatorDoc ty])
              Draws.OneOfDraw _ values -> pure (invoke "_harness.draw_one_of"
                [text "_draw",array [lambda [] (render value) | value <- values]])
              Draws.FrequencyDraw alternatives -> pure (invoke "_harness.draw_frequency"
                [text "_draw", array [array [text (show weight),lambda [] (call child)] | (weight,child) <- alternatives]])
              Draws.FilterDraw child binder predicate limit -> pure (invoke "_harness.draw_such_that"
                [lambda [] (call child),lambda [text (localName (C.binderId binder))] (render predicate),
                 text (show limit),quoted strategy])
              Draws.BindDraw binder from rest -> pure
                (parenthesized (lambda [text (localName (C.binderId binder))] (call rest)) <>
                  Doc.delimitTrailing 4 "(" ")" [call from])
            pure (function (helperName (Draws.drawNumber node))
              (map (localName . C.binderId) (Draws.drawCaptures node)) (text "return " <> body))
      helpers <- mapM helper (Draws.drawNodes graph)
      pure (helpers,call (Draws.drawRoot graph))
    -- A benchmark: measured, never asserted.
    benchmarkTest (n, body) = function ("test_benchmark__" ++ intercalate "_" (lawWords n)) []
      (statements [freshSymbols, statement (invoke "_harness.benchmark" [message n, lambda [] (render body)])])
    -- A stateful model's test: the model runtime generates runs, executes
    -- them through the generated bridge definitions and checks them against
    -- the reference definitions.
    modelTest machine = do
      spec <- either (\m -> Left [Diagnostic "model" m Nothing]) Right
        (machineSpec bits declarations (C.unitDeclarations u) (C.unitContracts u) machine)
      let call identity = case lookup identity definitions of
            Just name -> Right (text (maybe name id (stripPrefix "await " name)))
            Nothing -> Left [Diagnostic "model" ("model " ++ C.machineName machine ++ ": " ++ C.idText identity ++ " is not a checked definition") Nothing]
          optional = maybe (pure (text "None")) call
      start <- case C.machineStart machine of
        Just s -> (\r m -> array [r, m]) <$> call (C.startRun s) <*> call (C.startModel s)
        Nothing -> pure (text "None")
      commands <- mapM (\c -> (\r f w -> array [r, f, w]) <$> call (C.commandRun c) <*> call (C.commandReference c) <*> optional (C.commandWhen c))
        (C.machineCommands machine)
      abstract <- optional (C.machineAbstractRun machine)
      invariants <- mapM (\i -> call (case i of C.OnModel f -> f; C.OnState f -> f)) (C.machineInvariants machine)
      let model = invoke "ls.Model" [quoted spec, start, array commands, abstract, array invariants]
          check = statement (runtime "check_model" [model])
          block = function ("test_model_" ++ C.machineName machine) [] check
          -- A shared model's commands also run at the same time; every
          -- history must be linearizable.
          parallel = statement (runtime "check_model_parallel" [model])
          parallelBlock = function ("test_model_" ++ C.machineName machine ++ "_parallel") [] parallel
          -- Each scenario of the model runs on many schedules.
          scenario (i, program) =
            let run = statement (runtime "check_scenario" [model, quoted (programSpec program)])
            in function ("test_model_" ++ C.machineName machine ++ "_scenario" ++ show (i :: Int)) [] run
      pure (renderDocument block ++ (if C.machineShared machine then renderDocument parallelBlock else "") ++
        concatMap (renderDocument . scenario) (zip [0 ..] (C.machineScenarios machine)))
    -- An async adapter's task is awaited where it is called.
    awaited name call
      | name `notElem` asyncFunctions u = call
      | otherwise = runtime "await_task" [call]
    contractWrapper contract =
      let arguments = contractArguments contract
          (resultName,resultType) = contractResult contract
          require label predicates = statement (runtime "require_contract"
            [conjunction (map render predicates),message (contractName contract ++ " " ++ label ++ ": " ++
              intercalate " && " (map (prettyExprWith True localName) predicates))])
          invocation = awaited (adapterName u (C.contractDeclaration contract)) (invoke ("impl." ++ adapterName u (C.contractDeclaration contract))
            [nativeInput ty (converted ty (text name)) | (name,ty) <- arguments])
          body = statements
            [require "precondition" (contractPreconditions contract),
             assign resultName (checkedResult resultType invocation),
             require "postcondition" (contractPostconditions contract),
             statement (text ("return " ++ resultName))]
      in pure (renderDocument (function ("_lawspec_call_" ++ contractName contract) ("symbols":map fst arguments) body))
    caseCoverExpression (Cover.Complete count) = pure (text (show count))
    caseCoverExpression (Cover.Alternatives alternatives) = array <$> mapM branch alternatives
      where
        branch (domain, suffix) = do
          values <- case domain of
            Cover.Values items -> do
              literals <- mapM valueLit items
              pure (array [text "0", array [lambda [text "symbols"] literal | literal <- literals]])
            Cover.IntegerInterval name first last' -> do
              endpoints <- mapM (valueLit . V.ScalarValue . SInteger name) [first, last']
              pure (array (text "1" : endpoints))
          rest <- caseCoverExpression suffix
          pure (array [values, rest])
    literalChecked = either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right
    literalPlan = literalChecked $ do
      covers <- mapM caseCover ls
      Literals.planLiterals (concatMap Literals.coverLiterals covers ++
        [value | law <- ls, requirement <- generationPlan law, value <- generatorBoundaries requirement])
    shapeName index = "_literal_shape_" ++ show index
    factoryName index = "_literal_value_" ++ show index
    literalTerm = Literals.foldLiteral (pure . PythonExpr.scalarLiteral)
      (\index fields -> pure (invoke (shapeName index) [text "symbols", array fields]))
      (\index -> pure (invoke (factoryName index) [text "symbols"]))
    valueLit (V.ScalarValue value) = pure (PythonExpr.scalarLiteral value)
    valueLit value = do
      plan <- literalPlan
      literalChecked (Literals.literalReference plan value) >>= literalTerm
    literalFunctions = do
      plan <- literalPlan
      shapes <- mapM (\(index,shape) -> do
        body <- literalShape shape
        pure (renderDocument (function (shapeName index) ["symbols", "fields"]
          (text "return " <> body)))) (Literals.literalShapes plan)
      factories <- mapM (\(index,term) -> do
        body <- literalTerm term
        pure (renderDocument (function (factoryName index) ["symbols"]
          (text "return " <> body)))) (Literals.literalFactories plan)
      pure (concat (shapes ++ factories))
    literalShape (Literals.ListShape _) = pure (text "fields")
    literalShape (Literals.PresenceShape (C.Constructor wrapper _) present) = pure
      (invoke "ls.Presence" (quoted wrapper : text (if present then "True" else "False") :
        [text "fields[0]" | present]))
    literalShape (Literals.ConstructorShape ty tag) | usesData ty = pure
      (schema "construct" [referenceDoc ty,quoted (C.idText tag),text "fields",width])
    literalShape (Literals.ConstructorShape (C.Constructor name _) tag) | name `elem` ["Maybe","Either"] = pure
      (runtime "construct" [quoted (C.idText tag),text "fields"])
    literalShape _ = Left [Diagnostic "target" ("structural literal is not implemented for " ++ target) Nothing]
    containsStructural ty | usesData ty = True
    containsStructural (C.Constructor name args) = name `elem` ["List","Maybe","Either"] ||
      any (\arg -> case arg of C.TypeArgument inner -> containsStructural inner; _ -> False) args
    containsStructural _ = False
    -- Hypothesis owns the draw and shrink lifecycle. The fixture identity map
    -- is created per case and retained for generation, contracts and assertions.
    contextualProperty prefix e body = do
      draws <- mapM (\plan -> do
        let input = domainInput plan
        strategy <- contextStrategy e plan
        pure (assign (inputId input) (method (text "_draw") "draw" [strategy])))
        (generationPlan e)
      let predicate = conjunction (map render (concatMap inputRefinements (inputs e)))
      pure (pythonProperty prefix
        [pythonSettings (cases (generation e)),
         invoke "given" [invoke "st.data" []]] ["_draw"]
        (statements (fresh e : draws ++ [statement (invoke "assume" [predicate]),body])))
    contextStrategy e plan = do
      let input = domainInput plan
          ty = inputType input
      seeds <- mapM valueLit (generatorBoundaries plan)
      let hints = [render hint | hint <- generatorHints plan,
            C.expressionType hint == ty, case C.expressionNode hint of
              C.Constant _ -> True
              C.Local _ -> True
              _ -> False]
          -- Seed values are supplementary draws, so they must obey the same
          -- restrictions as the narrowed scalar generator. Recompute them in
          -- the actual lexical prefix on every draw/shrink. Earlier restrictions
          -- guard partial expressions in later restrictions in source order.
          prefix = takeWhile ((/= inputId input) . inputId) (inputs e) ++ [input]
          predicates = concatMap inputRefinements prefix
          candidates = array (seeds ++ hints)
          accepted = lambda [text (inputId input)] (conjunction (map render predicates))
          witnesses
            | null predicates = candidates
            | otherwise = invoke "list" [invoke "filter" [accepted,candidates]]
          scalarName = text "_lawspecScalarName"
          fallback = invoke "_lawspec_primitive_generators.__getitem__" [scalarName]
          scalar = case inputRange bits (domainInput plan) of
            Nothing -> text "_lawspec_primitive_generators.__getitem__"
            Just range ->
              let bounded = Generator.generatorDocWithin bits usesData referenceDoc (Just range) ty
                  selected = scalarName <> text " == " <> quoted (typeKey ty)
              in lambda [scalarName] (Doc.parens (bounded <> Doc.softline <> text "if " <> selected <> Doc.softline <> text "else " <> fallback))
      pure (case requiredSymbol plan of
        value:_ -> invoke "st.just" [render value]
        [] -> invoke "_data_strategy"
          ([text "_lawspec_schema",referenceDoc ty,width,text (show budget),
            scalar,text "symbols",witnesses] ++
            maybe [] (pure . indexDoc) (generatorIndex plan)))
    -- Index-directed generation: the target is evaluated from earlier draws.
    indexDoc indexed =
      let equation (tag,texts) = (quoted (C.idText tag), PythonExpr.tuple (map quoted texts))
          table = Doc.delimitTrailing 4 "{" "}"
            [key <> text ": " <> value | (key,value) <- map equation (indexedEquations indexed)]
          pair = Doc.delimitTrailing 4 "(" ")" [render (indexedTarget indexed),table]
      in text "index=" <> pair
    -- Identity equality restricts Symbol to one fixture. Only required
    -- conjuncts qualify; an equality under disjunction does not define a domain.
    requiredSymbol plan
      | nativeGenerators = []
      | inputType (domainInput plan) /= C.scalarType "Symbol" = []
      | otherwise = concatMap required (generatorPredicates plan)
      where
        current = C.binderId (generatorBinder plan)
        required expression = case C.expressionNode expression of
          C.ShortCircuit C.And a b -> required a ++ required b
          C.Binary C.Equal _ a b -> [value | (local,value) <- [(a,b),(b,a)],
            C.expressionNode local == C.Local current,
            C.expressionType value == C.scalarType "Symbol",
            current `notElem` C.freeBinders value,
            case C.expressionNode value of
              C.Constant _ -> True
              C.Local _ -> True
              _ -> False]
          _ -> []
    nativeRefinedProperty prefix e body =
      let names = map (text . inputId) (inputs e)
          -- An integer input draws from its refinement's constant range;
          -- the filter still checks every refinement.
          generators = [hinted input (Generator.generatorDocWithin bits usesData referenceDoc (inputRange bits input) (inputType input)) | input <- inputs e]
          -- Constant hints (regex samples, compared literals) are mixed in so
          -- a narrow refinement still meets the filter often enough.
          hinted input generator = case [render hint | plan <- generationPlan e,
              inputId (domainInput plan) == inputId input, hint <- generatorHints plan,
              C.expressionType hint == inputType input, isConstant hint,
              C.expressionType hint /= C.scalarType "Symbol", withinRange input hint] of
            [] -> generator
            -- Literals render against a symbol table; these hold no symbols,
            -- so a throwaway table is enough outside a case.
            hints -> let values = parenthesized (lambda [text "symbols"] (array hints)) <>
                           parenthesized (text "{}")
              in invoke "st.one_of"
                [invoke "st.sampled_from" [values], generator]
          withinRange input hint = case (inputRange bits input,C.expressionNode hint) of
            (Just (lo,hi),C.Constant (SInteger _ value)) -> value >= lo && value <= hi
            _ -> True
          isConstant hint = case C.expressionNode hint of
            C.Constant _ -> True
            _ -> False
          predicate = conjunction (map render (concatMap inputRefinements (inputs e)))
          cfg = generation e
          tuple = invoke "st.tuples" generators
          caseValue = Doc.delimitTrailing 4 "(" ")" [text "_values",text "{}"]
          condition = lambda [text "_case"]
            (parenthesized (lambda (text "symbols":names) predicate) <>
              Doc.delimitTrailing 4 "(" ")" [text "_case[1]",text "*_case[0]"])
          -- ruff writes a chain of two or more calls one per line when it breaks.
          filtered = Doc.group (tuple <> Doc.softbreak <> text "." <> invoke "map" [lambda [text "_values"] caseValue] <>
              Doc.softbreak <> text "." <> invoke "filter" [condition])
          assignments = [assign (inputId input) (text ("_values[" ++ show index ++ "]")) |
            (index,input) <- zip [0 :: Int ..] (inputs e)]
      in pure (pythonProperty prefix
        [pythonSettings (cases cfg),invoke "given" [filtered]]
        ["_case"] (statements ([text "_values, symbols = _case"] ++ assignments ++ installs e ++ [body])))
    -- No per-example deadline: adapters may do real work (I/O, timeouts),
    -- and solving an index table is a one-time cost of the first example.
    pythonSettings count = invoke "settings" [text ("max_examples=" ++ show count), text "deadline=None"]
    refinedProperty prefix e body = do
      domains <- mapM (domainCode e) (zip [0 :: Int ..] (generationPlan e))
      let cfg = generation e
          checkBody = statements ([assign (inputId input) (text ("_values[" ++ show index ++ "]")) |
            (index,input) <- zip [0 :: Int ..] (inputs e)] ++ installs e ++ [body])
          check = function "_check" ["_values"] checkBody
          label = owner e ++ "::" ++ name e
          run = statement (runtime "refined_case"
            [array domains,text "_seed",text (show (maxAttempts cfg)),text (show (maxShrinks cfg)),text "_check",
             message (label ++ " | " ++ intercalate "; " (map (prettyExprWith True (sourceNames (original e)))
               (concatMap inputRefinements (inputs e))))])
          seededBody = statements [freshSymbols, Doc.hardline <> check, Doc.hardline <> run]
      pure (pythonProperty prefix
        [pythonSettings (cases cfg),
         invoke "given" [invoke "st.integers" [text "min_value=0",text "max_value=2147483647"]]]
        ["_seed"] seededBody)
    domainCode e (index,plan) = do
      seeds <- mapM valueLit (generatorBoundaries plan)
      let input = domainInput plan
          previous = take index (inputs e)
          bind inputs' seeded expression =
            let names = map (text . inputId) inputs'
                seedArgument = if seeded then [text "_seed"] else []
            in lambda (text "_values":seedArgument)
              (parenthesized (lambda names expression) <> Doc.delimitTrailing 4 "(" ")" [text "*_values"])
          bounds = [array [quoted operator,render value] | (operator,value) <- domainBounds plan]
          candidates = runtime "domain_candidates"
            [quoted (typeKey (inputType input)),text "_seed",width,array bounds,
             array (seeds ++ map render (generatorHints plan))]
          predicate = conjunction (map render (inputRefinements input))
      pure (array [bind previous True candidates,bind (previous ++ [input]) False predicate])
    split s = case break (== '.') s of (a,[]) -> [a]; (a,_:b) -> a:split b

-- Whether a unit's laws install a Clock handler: its tests then register how
-- the runtime reads one (lawspec.time's register_clock).
installsClock :: C.Unit -> Bool
installsClock unit = or [C.abilityKey a == "lawspec.time::ability::Clock" | p <- C.unitProperties unit, (a, _) <- C.propertyHandlers p]
