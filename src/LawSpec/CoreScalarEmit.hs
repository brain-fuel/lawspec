module LawSpec.CoreScalarEmit (scalarEmit, scalarEmitWithData, scalarEmitWithDefinitions, scalarEmitWithFormat, scalarEmitWithNativeGenerators, typeKey) where
import LawSpec.Backend
import LawSpec.Common
import LawSpec.Testing
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Core as C
import qualified LawSpec.PythonData as PythonData
import qualified LawSpec.WebData as WebData
import qualified LawSpec.WebExpr as WebExpr
import qualified LawSpec.PythonExpr as PythonExpr
import qualified LawSpec.Code.Doc as Doc
import qualified LawSpec.PortableGenerator as Generator
import qualified LawSpec.PortableTestHelpers as Helpers
import LawSpec.Scalar
import LawSpec.MachineSpec (machineSpec)
import LawSpec.Bounds (inputRange)
import LawSpec.Core.Program (Program(..), programSpec)
import qualified LawSpec.Core.Machine as C
import Data.Aeson (encode, toJSON)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T
import Data.List (intercalate, isPrefixOf, isInfixOf, stripPrefix, nub)
import Control.Monad (unless, foldM)
import Data.Char (toLower)
import qualified LawSpec.AbilityEmit.Python as PythonAbilities
import qualified LawSpec.AbilityEmit.Web as WebAbilities
import LawSpec.AbilityNames (specName, recordingName, productionName, interfaceName, ownAbilities, ownerName, unitAbility, unitAbilityPieces)
import LawSpec.TestNames (unitTestNames, lawWords)

q :: String -> String
q = T.unpack . T.decodeUtf8 . encode
typeKey :: Type -> String
typeKey = scalarTypeKey
scalarEmit :: Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
scalarEmit = scalarEmitWithData []
scalarEmitWithData :: [C.DataDeclaration] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
scalarEmitWithData declarations = scalarEmitWithDefinitions declarations []
scalarEmitWithDefinitions :: [C.DataDeclaration] -> [(C.Id,String)] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
scalarEmitWithDefinitions = scalarEmitWithFormat False
scalarEmitWithFormat :: Bool -> [C.DataDeclaration] -> [(C.Id,String)] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
scalarEmitWithFormat = scalarEmitWithNativeGenerators False
scalarEmitWithNativeGenerators :: Bool -> Bool -> [C.DataDeclaration] -> [(C.Id,String)] -> Int -> String -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
scalarEmitWithNativeGenerators nativeGenerators minify declarations definitions bits target u allLaws = do
  unless (target `elem` ["python","javascript","typescript"]) (Left [Diagnostic "target-runtime" ("portable scalar runtime is not implemented for " ++ target) Nothing])
  lawTexts <- concat <$> mapM lawTests (zip [0 :: Int ..] ls)
  modelTexts <- concat <$> mapM modelTest (C.unitMachines u)
  -- A unit with supervisors also checks the runtime's supervision.
  let supervision
        | null (C.unitSupervisors u) = ""
        | py = renderDocument (function "test_supervision" [] (statement (runtime "check_supervision" [])))
        | otherwise = renderDocument (text "test(" <> message (unitName u ++ "::supervision") <> text ", async () => " <>
            Doc.block 2 (statement (text "await " <> runtime "checkSupervisionAsync" [])) <> text ");")
      -- The unit's harness: benchmarks, and order random.
      benchmarks = concatMap (renderDocument . benchmarkTest) (maybe [] C.harnessBenchmarks (C.unitHarnessSettings u))
      orderRandom = maybe False C.harnessOrderRandom (C.unitHarnessSettings u)
      shuffled = if not py || not orderRandom then "" else
        renderDocument (statement (invoke "_harness.shuffle_tests" [invoke "globals" [],
          array [quoted n | l <- lines lawTexts, Just rest <- [stripPrefix "def " l], let n = takeWhile (/= '(') rest, "test_" `isPrefixOf` n]]))
      -- JavaScript collects the law tests, then registers them shuffled.
      laws' = if py || not orderRandom then lawTexts else
        "const _ordered = [];\n{\n  const test = (...registration) => { _ordered.push(registration); };\n" ++ lawTexts ++
        "}\nfor (const registration of _harness.shuffled(_ordered)) test(...registration);\n\n"
      tests = laws' ++ modelTexts ++ supervision ++ benchmarks ++ shuffled
  wrappers <- concat <$> mapM contractWrapper (contracts u)
  let completeHeader = if py || hasData || "fc." `isInfixOf` tests then testHeader else unlines (filter (/= "import fc from 'fast-check';") (lines testHeader))
  pure [Artifact stubPath stub "user" "source",Artifact testPath (finish (completeHeader ++ dataHelpers ++ testHelpers ++ wrappers ++ tests)) "generated" "test"]
  where
    finish content = if py then reverse (dropWhile (== '\n') (reverse content)) ++ "\n" else content
    adapterFunctions = [(C.declarationName d,C.declarationType d) | d <- C.unitDeclarations u, C.declarationId d `notElem` map fst definitions]
    py = target == "python"
    hasData = (nativeGenerators || not (null definitions) || not (null declarations) || any (usesData . snd) (functions u) ||
      unitAbilityPieces u || not (null (C.unitAbilities u)) ||
      any (any (usesData . inputType) . inputs) ls ||
      any expressionNeedsSchema (concatMap C.contractExpressions (contracts u) ++
        concatMap (C.propertyExpressions . original) ls))
    fieldContracts = any (not . null . C.constructorPredicates)
      (concatMap C.dataConstructors declarations)
    usesData = (if py then PythonData.requiresSchema else WebData.requiresSchema) declarations
    expressionNeedsSchema term | C.AllPayloads _ _ <- C.expressionNode term = True
    expressionNeedsSchema term = usesData (expressionType term) || any expressionNeedsSchema (C.children term)
    dataImports = if hasData then "import builtins as _builtins\nimport lawspec_data as data\nimport lawspec_schema as _schema\n" else ""
    nodeCount (V.ScalarValue _) = 1
    nodeCount (V.PresenceValue _ value) = 1 + maybe 0 nodeCount value
    nodeCount value@(V.DataValue (C.Constructor "List" _) _ _) = either (const 1) ((+1) . sum . map nodeCount) (V.listItems value)
    nodeCount (V.DataValue _ _ fields) = 1 + sum (map nodeCount fields)
    budget = maximum (64 : [8 + nodeCount value | law <- ls, requirement <- generationPlan law, value <- generatorBoundaries requirement])
    outputLayout = Doc.selectLayout minify (Doc.Pretty (if py then 79 else 80))
    referenceDoc ty = either error id ((if py then PythonData.pythonTypeReferenceDoc else WebData.webTypeReferenceDoc) ty)
    generatorDoc = Generator.generatorDoc py bits usesData referenceDoc
    dataHelpers = if not hasData then "" else
      (if py then "from " ++ (if nativeGenerators then "lawspec_native_generators" else "lawspec_data_strategies") ++ " import strategy as _data_strategy\n\n\n"
       else "import {strategy as _data_strategy} from './" ++ (if nativeGenerators then "lawspec_native_generators" else "lawspec_data_strategies") ++ "." ++ (if ts then "js" else "mjs") ++ "';\n\n") ++
      Doc.render outputLayout (Helpers.dataHelperDoc py bits budget
        [(if py then PythonExpr.quoted else WebExpr.quoted) (primitiveName p) <> Doc.text ": " <>
          generatorDoc (Named (primitiveName p)) | p <- primitives]) ++
      (if py then "\n\n\n" else "\n\n")
    ts = target == "typescript"
    ext = if py then ".py" else if ts then ".ts" else ".mjs"
    parts = split (unitName u)
    slash = intercalate "/" parts
    stubPath = "src/" ++ slash ++ ext
    testPath = (if py then "tests/test_" else "test/") ++ intercalate "_" parts ++ (if py then "_lawspec" else ".lawspec") ++ (if py then ".py" else ".test" ++ ext)
    ls = filter ((== unitName u) . owner) allLaws
    testNames = unitTestNames target (map name ls)
    hasHarness = C.unitHarnessSettings u /= Nothing || any ((/= Nothing) . C.harnessUnit . C.propertyHarness . original) ls
    runtimeImport = if py then "import lawspec_runtime as ls\n" else "import * as ls from '../src/lawspec_runtime." ++ (if ts then "js" else "mjs") ++ "';\n"
    testHeader = (if ts then "// @ts-nocheck\n" else "") ++ (if py then "#" else "//") ++ " Generated by LawSpec.\n" ++ runtimeImport ++ if py
      then (if null definitions then "" else "import lawspec_definition_bodies as _definitions\n") ++ dataImports ++ "import json\nimport os\nfrom hypothesis import assume, given, settings, strategies as st\nfrom hypothesis import seed as _lawspec_seed\nfrom hypothesis.database import DirectoryBasedExampleDatabase\n" ++ (if null adapterFunctions && null (ownAbilities u) then "" else "import " ++ unitName u ++ " as impl\n") ++
        (if not (unitAbilityPieces u) then "" else "import " ++ PythonAbilities.moduleName u ++ " as _abilities\n") ++
        (if hasHarness then "import lawspec_harness as _harness\n" else "")
      else (if null definitions then "" else "import * as _definitions from '../src/lawspec_definition_bodies." ++ (if ts then "js" else "mjs") ++ "';\n") ++ webImports "../src/" ++ "import {test} from 'node:test';\nimport assert from 'node:assert/strict';\nimport fc from 'fast-check';\nimport * as impl from '../src/" ++ slash ++ (if ts then ".js" else ".mjs") ++ "';\n" ++
        (if not (unitAbilityPieces u) then "" else "import * as _abilities from '../src/lawspec_abilities/" ++ slash ++ (if ts then ".js" else ".mjs") ++ "';\n") ++
        concat ["import * as _impl" ++ show i ++ " from '../src/" ++ ownerSlash o ++ (if ts then ".js" else ".mjs") ++ "';\n" ++
                "import * as _abilities" ++ show i ++ " from '../src/lawspec_abilities/" ++ ownerSlash o ++ (if ts then ".js" else ".mjs") ++ "';\n"
               | (i, o) <- zip [0 :: Int ..] foreignOwners] ++
        concat ["import {" ++ last parts ++ " as " ++ boundAlias parts ++ "} from '../src/" ++ intercalate "/" (init parts) ++ (if ts then ".js" else ".mjs") ++ "';\n" | parts <- boundHandlers] ++
        concat ["import {" ++ last parts ++ " as " ++ failureAlias parts ++ "} from '../src/" ++ intercalate "/" (init parts) ++ (if ts then ".js" else ".mjs") ++ "';\n" | parts <- failureImports] ++
        (if hasHarness then "import * as _harness from './lawspec_harness." ++ (if ts then "js" else "mjs") ++ "';\n" else "")
    testHelpers = (if hasData then "" else if py then "\n\n" else "\n") ++
      Doc.render outputLayout (Helpers.assertionHelperDoc py) ++ seedHelper ++
      (if asyncMode then "\n\n" ++ Doc.render outputLayout (Helpers.asyncAssertionHelpersDoc bits) else "") ++
      (if py then "\n\n\n" else "\n\n")
    native ty | usesData ty = either error id ((if py then PythonData.pythonDataType else WebData.webDataType) declarations ty)
    native (Applied "Maybe" _) = if py then "ls.DataValue" else "unknown"
    native (C.Constructor "Either" _) = if py then "ls.DataValue" else "unknown"
    native (Applied "List" element) =
      if py then "list[" ++ (if element == Named "Unit" then "ls.Absence" else native element) ++ "]"
      else "Array<" ++ (if element == Named "Unit" then "unknown" else native element) ++ ">"
    native (Named n)
      | py = case n of
          "Bytes" -> "bytes"; "Bool" -> "bool"; "Text" -> "str"; "Char" -> "str"; "Decimal" -> "ls.Decimal"; "Rational" -> "ls.Fraction"
          "Float32" -> "float"; "Float64" -> "float"; "Complex64" -> "complex"; "Complex128" -> "complex"
          "Symbol" -> "ls.Symbol"; "Unit" -> "None"; _ | isInteger n || n `elem` ["CodePoint","CodeUnit16"] -> "int"
          _ | n `elem` ["Unit","Null","Undefined"] -> "ls.Absence"
          _ -> "ls.Raw"
      | otherwise = case n of
          "Bytes" -> "Uint8Array"; "Bool" -> "boolean"; "Text" -> "string"; "Char" -> "string"; "Symbol" -> "symbol"
          "Integer" -> "number | bigint"; "Null" -> "null"; "Undefined" -> "undefined"; "Unit" -> "void"
          _ | isInteger n -> if n `elem` ["Int8","Int16","Int32","UInt8","UInt16","UInt32"] then "number" else "bigint"
          _ | n `elem` ["Float32","Float64","CodePoint","CodeUnit16"] -> "number"
          _ -> "unknown"
    native _ = if py then "ls.Presence" else "unknown"
    stub = (if py then "#" else "//") ++ " User-owned LawSpec adapter.\n" ++ (if py then dataImports ++ "import lawspec_runtime as ls\n" else webImports (concat (replicate (length parts - 1) "../") ++ "./") ++
      (if ts && not (null (ownAbilities u)) then "import type * as abilities from '" ++ concat (replicate (length parts - 1) "../") ++ "./lawspec_abilities/" ++ slash ++ ".js';\n" else "") ++ (if hasData then "import * as ls from '" ++ (if length parts == 1 then "./" else concat (replicate (length parts - 1) "../")) ++ "lawspec_runtime." ++ (if ts then "js" else "mjs") ++ "';\n" else "")) ++ (if py && not (null adapterFunctions && null (ownAbilities u)) then "\n\n" else "") ++ intercalate (if py then "\n\n" else "\n") (map stubFn adapterFunctions ++ map productionStub (ownAbilities u))
    -- Each ability's production handler is written by hand, like an adapter.
    productionStub ability
      | py = either error id (PythonAbilities.productionStub declarations ability)
      | otherwise = either error id (WebAbilities.productionStub ts declarations ability)
    webImports root = if not hasData then "" else "import * as data from '" ++ root ++ "lawspec_data." ++ (if ts then "js" else "mjs") ++ "';\nimport * as schema from '" ++ root ++ "lawspec_schema." ++ (if ts then "js" else "mjs") ++ "';\n"
    nativeArg ty | usesData ty = native ty
    nativeArg (Applied "List" element) = if py then "list[" ++ nativeArg element ++ "]" else "Array<" ++ nativeArg element ++ ">"
    nativeArg t = if t == Named "Integer" then (if py then "int" else "bigint") else if t == Named "Unit" then (if py then "ls.Absence" else "unknown") else native t
    stubFn (n,t) = Doc.render outputLayout $
      let (args,r) = functionType t
          pythonType ty = if usesData ty then either error id (PythonData.pythonDataTypeDoc declarations ty) else Doc.text (nativeArg ty)
          -- First, a handler for each ability the adapter uses.
          handlerArguments = [Doc.text (handlerParameter ability) <>
            (if py then Doc.text (": " ++ q (maybe "object" (\a -> PythonAbilities.moduleNameOf (ownerName a) ++ "." ++ interfaceName a) (abilityNamed ability)))
             else Doc.text (if ts then ": " ++ maybe "unknown" tsInterface (abilityNamed ability) else "")) |
            d <- C.unitDeclarations u, C.declarationName d == n, ability <- C.declarationUses d, not (C.isFail ability)]
          arguments = handlerArguments ++ [Doc.text ("value" ++ show i) <>
            (if py then Doc.text ": " <> pythonType a
             else Doc.text (if ts then ": " ++ nativeArg a else "")) |
            (i,a) <- zip [0 :: Int ..] args]
          -- Native representations can erase LawSpec distinctions. Keep the
          -- declared interface visible in both the stub and its canonical key.
          signatureComments =
            mconcat [stubComment ("LawSpec argument " ++ show i ++ ": " ++ prettyType a) |
              (i,a) <- zip [0 :: Int ..] args] <>
            stubComment ("LawSpec result: " ++ prettyType r)
          asyncStub = n `elem` asyncFunctions u
          signature = Doc.text ((if py then (if asyncStub then "async def " else "def ") else (if asyncStub then "export async function " else "export function ")) ++ n) <>
            Doc.delimit 4 "(" ")" arguments <>
            (if py then Doc.text " -> " <> (if r == Named "Unit" then Doc.text "None" else pythonType r) <> Doc.text ":"
             else Doc.text (if ts then ": " ++ native r else ""))
      in signatureComments <> signature <>
        (if py then Doc.nest 4 (Doc.hardline <> Doc.text ("raise NotImplementedError(" ++ q n ++ ")"))
         else Doc.text " " <> Doc.block 2 (Doc.text "throw " <> WebExpr.call "new Error" [WebExpr.quoted n] <> Doc.text ";")) <> Doc.hardline

    stubComment = Doc.lineComment (if py then 72 else 80) (if py then "# " else "// ")
    text = Doc.text
    quoted = if py then PythonExpr.quoted else WebExpr.quoted
    -- Diagnostics are expression values, so long messages can concatenate
    -- literal chunks without changing their runtime payload.
    message value
      | quotedWidth value <= 60 = quoted value
      | otherwise = parenthesized (Doc.joinWith (if py then Doc.softline <> text "+ " else text " +" <> Doc.softline)
          (map quoted (chunks value)))
      where
        quotedWidth = length . Doc.render Doc.Compact . quoted
        chunks [] = []
        chunks rest =
          -- A quoted prefix only widens as it grows, so the longest prefix
          -- that fits is found by bisection instead of quoting every one.
          let fits n = quotedWidth (take n rest) <= 40
              longest low high
                | low >= high = low
                | fits middle = longest middle high
                | otherwise = longest low (middle - 1)
                where middle = (low + high + 1) `div` 2
              limit = max 1 (longest 0 (length (take 40 rest)))
              wordEnd = foldl (\lastSpace (index,c) -> if c == ' ' then index + 1 else lastSpace)
                0 (zip [0 :: Int ..] (take limit rest))
              count = if wordEnd == 0 then limit else wordEnd
          in take count rest : chunks (drop count rest)
    invoke = if py then PythonExpr.call else WebExpr.call
    array = if py then PythonExpr.array else WebExpr.array
    indentation = if py then 4 else 2
    width = text (show bits)
    runtime name = invoke ("ls." ++ name)
    schema name arguments = invoke ("_lawspec_schema." ++ name)
      (arguments ++ [text "symbols"])
    statement value = value <> if py then mempty else text ";"
    statements = Doc.joinWith Doc.hardline
    parenthesized value = Doc.group (text "(" <> Doc.nest 4 (Doc.softbreak <> value) <> Doc.softbreak <> text ")")
    object fields = Doc.delimitTrailing indentation "{" "}"
      [text name <> text ": " <> value | (name,value) <- fields]
    method value name arguments = value <> text "." <> invoke name arguments
    lambda parameters value = if py
      then PythonExpr.lambdaExpression parameters value
      else Doc.delimitTrailing 4 "(" ")" parameters <> text " => " <> value
    -- JavaScript tests that call async adapters await them, so their test
    -- bodies, property callbacks and assertion thunks are async too.
    asyncMode = not py && (not (null (asyncFunctions u)) || any (isPrefixOf "await " . snd) definitions)
    asyncPrefix = text (if asyncMode then "async " else "")
    callback parameters body = asyncPrefix <> Doc.delimitTrailing 4 "(" ")" parameters <> text " => " <> Doc.block 2 body
    function name parameters body =
      let header = text ((if py then "def " else "function ") ++ name) <>
            Doc.delimitTrailing indentation "(" ")" (map text parameters)
      in if py then PythonExpr.suite header body else header <> text " " <> Doc.block 2 body
    assign name value = statement (text ((if py then "" else "const ") ++ name ++ " = ") <> value)
    freshSymbols = assign "symbols" (if py then text "{}" else invoke "new Map" [])
    renderDocument doc = Doc.render outputLayout doc ++ if py then "\n\n\n" else "\n\n"
    -- Calls containing statement blocks use mandatory argument breaks. A flat
    -- enclosing call group must not flatten the groups inside a callback body.
    blockCall name arguments = text (name ++ "(") <>
      Doc.nest 4 (Doc.hardline <> Doc.joinWith (text "," <> Doc.hardline) arguments <>
        text ",") <> Doc.hardline <> text ")"
    testBlock label name body = if py then function name [] body
      else text "test(" <> message label <> text ", " <> callback [] body <> text ");"
    nativeInput ty value = if usesData ty
      then schema (if py then "to_native" else "toNative") [referenceDoc ty,value,width] else value
    checkedResult ty value = if usesData ty
      then schema (if py then "from_native" else "fromNative") [referenceDoc ty,value,width]
      else runtime "validate"
        [if ty == Named "Unit" then runtime (if py then "unit_result" else "unitResult") [value] else value,
         quoted (typeKey ty),width]
    -- A handler's values cross with the handler schema: the bound native
    -- types when lawspec.json binds them (ls.handler_schema).
    handlerSchema name args = invoke (Doc.render Doc.Compact (runtime (if py then "handler_schema" else "handlerSchema") [text "_lawspec_schema"]) ++ "." ++ name)
      (args ++ [text "symbols"])
    handlerInput ty value = if usesData ty
      then handlerSchema (if py then "to_native" else "toNative") [referenceDoc ty,value,width] else value
    handlerResult ty value = if usesData ty
      then handlerSchema (if py then "from_native" else "fromNative") [referenceDoc ty,value,width]
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
    installs e = case [(ability, choice) | (ability, choice) <- C.propertyHandlers (original e), not (C.isFail ability)] of
      [] -> []
      chosen -> [statement (runtime (if py then "install_handlers" else "installHandlers") [text "symbols", Doc.delimitTrailing indentation "{" "}"
        [quoted (C.abilityKey ability) <> text ": " <> construct ability choice | (ability, choice) <- chosen]])]
    construct ability choice = case choice of
      C.ProductionHandler -> case abilityNamed ability >>= C.abilityNative of
        -- A production handler bound in lawspec.json.
        Just parts | py -> runtime "native_handler" [quoted (intercalate "." (init parts)), quoted (last parts)]
                   | otherwise -> invoke ("new " ++ boundAlias parts) []
        Nothing -> case abilityNamed ability of
          -- An imported ability's production handler is its owner's.
          Just a | ownerName a /= unitName u, py -> runtime "native_handler" [quoted (ownerName a), quoted (productionName a)]
                 | ownerName a /= unitName u -> invoke ("new " ++ foreignModule "_impl" a ++ "." ++ productionName a) []
          _ -> invoke ((if py then "impl." else "new impl.") ++ maybe "Unknown" productionName (abilityNamed ability)) []
      C.SpecHandler h -> invoke ((if py then "_abilities." else "new _abilities.") ++ maybe "Unknown" specName
        (lookup h [(C.handlerId x, x) | x <- C.unitHandlers u])) [text "symbols"]
      C.RecordingHandler inner -> case abilityNamed ability of
        Just a | ownerName a /= unitName u, py ->
                   runtime "native_class" [quoted (PythonAbilities.moduleNameOf (ownerName a)), quoted (recordingName a)] <>
                   Doc.delimitTrailing indentation "(" ")" [construct ability inner, text "symbols"]
               | ownerName a /= unitName u -> invoke ("new " ++ foreignModule "_abilities" a ++ "." ++ recordingName a) [construct ability inner, text "symbols"]
        _ -> invoke ((if py then "_abilities." else "new _abilities.") ++ maybe "Unknown" recordingName (abilityNamed ability))
          [construct ability inner, text "symbols"]
    handlerParameter ability = case maybe "handler" C.abilityName (abilityNamed ability) of
      c : rest -> toLower c : rest
      [] -> "handler"
    boundHandlers = nub [parts | a <- C.unitAbilities u, Just parts <- [C.abilityNative a]]
    boundAlias parts = "_lawspecHandler" ++ show (length (takeWhile (/= parts) boundHandlers))
    abilityNamed = unitAbility u
    -- An adapter that fails with E: native code raises the runtime's Fail
    -- with a native E (or an exception lawspec.json maps to one), which
    -- becomes the Fail E failure.
    nativeFailures decl call = case [a | d <- C.unitDeclarations u, C.declarationId d == decl, a@(C.AbilityRef _ [_]) <- C.declarationUses d, C.isFail a] of
      ability@(C.AbilityRef _ [failure]) : _ | not asyncMode ->
        runtime (if py then "native_failures" else "nativeFailures")
          [quoted (C.abilityKey ability), lambda [text "_failure"] (checkedResult failure (text "_failure")), lambda [] call,
           mappedFailures failure]
      _ -> call
    mappedFailures failure = case [b | b <- C.unitFailureBindings u, C.failureType b == failure] of
      [] -> text (if py then "()" else "[]")
      bindings -> Doc.delimitTrailing indentation "[" "]"
        [ (if py then Doc.delimitTrailing indentation "(" ")" else Doc.delimitTrailing indentation "[" "]")
            [ if py then runtime "native_class" [quoted (intercalate "." (init (C.failureNative b))), quoted (last (C.failureNative b))]
                    else text (failureAlias (C.failureNative b))
            , lambda [text "_error"] (constructed failure (C.idText (C.failureConstructor b))
                [converted (C.scalarType "Text") (if py then text "_builtins.str(_error)" else text "String(_error?.message ?? _error)") | C.failureMessage b]) ]
        | b <- bindings ]
    failureImports = nub [C.failureNative b | b <- C.unitFailureBindings u]
    failureAlias parts = "_lawspecFailure" ++ show (length (takeWhile (/= parts) failureImports))
    -- Units whose abilities this unit imports, in a fixed order.
    foreignOwners = nub [ownerName a | a <- C.unitAbilities u, ownerName a /= unitName u]
    foreignModule prefix a = prefix ++ show (length (takeWhile (/= ownerName a) foreignOwners))
    ownerSlash o = intercalate "/" (split o)
    tsInterface a
      | ownerName a == unitName u = "abilities." ++ interfaceName a
      | otherwise = "import('" ++ concat (replicate (length parts - 1) "../") ++ "./lawspec_abilities/" ++ ownerSlash (ownerName a) ++ ".js')." ++ interfaceName a
    fresh e = statements (freshSymbols : installs e)
    -- A law's resources: each case acquires them, then runs, then releases
    -- them, the last first, even when the case fails.
    bracket e doc = foldr wrap doc (C.propertyResources (original e))
      where
        wrap r inner = statements
          [ assign (localName (C.binderId (C.resourceBinder r))) (render (C.resourceAcquire r))
          , if py then PythonExpr.suite (text "try") inner <> Doc.hardline <>
                PythonExpr.suite (text "finally") (statement (render (C.resourceRelease r)))
            else text "try " <> Doc.block 2 inner <> text " finally " <> Doc.block 2 (statement (render (C.resourceRelease r))) ]
    render term = either error id (renderer declarations bits localName external term)
      where
        renderer = if py then PythonExpr.renderExpression else WebExpr.renderExpression ts
        external expression values = case C.expressionNode expression of
          -- raise aborts to the nearest attempt of its Fail ability.
          C.Perform op [_] | C.isFail (C.operationAbility op) ->
            Right (runtime (if py then "raise_failure" else "raiseFailure") (quoted (C.abilityKey (C.operationAbility op)) : values))
          -- An operation goes to the handler installed for its ability.
          C.Perform op args ->
            let call = method (handlerDoc (C.operationAbility op)) (C.operationName op)
                  [handlerInput (expressionType a) (converted (expressionType a) value) | (a,value) <- zip args values]
            in Right (handlerResult (expressionType expression) call)
          -- handle e with h end: e runs with h installed for its ability.
          C.Handle (C.WithHandler ability choice) _ | [body] <- values ->
            Right (runtime (if py then "with_handlers" else "withHandlers") [text "symbols",
              Doc.delimitTrailing indentation "{" "}" [quoted (C.abilityKey ability) <> text ": " <> construct ability choice],
              lambda [] body])
          C.Handle (C.CatchFailure ability) _ -> case (expressionType expression, values) of
            (C.Constructor "Either" [C.TypeArgument failure, C.TypeArgument result], [body]) ->
              let side tag ty = lambda [text "_value"] (constructed (expressionType expression) tag [converted ty (text "_value")])
                  attempt = runtime (if asyncMode then "attemptAsync" else "attempt") [quoted (C.abilityKey ability), asyncPrefix <> lambda [] body,
                    side "Either::Right" result, side "Either::Left" failure]
              in Right (if asyncMode then text "(await " <> attempt <> text ")" else attempt)
            _ -> Left "attempt gives an Either"
          C.Calls op args ->
            let matches = case args of
                  Nothing -> text (if py then "None" else "null")
                  Just xs -> lambda [text "_recorded"] (conjunction
                    [equality (expressionType a) (text ("_recorded[" ++ show i ++ "]")) value | (i,(a,value)) <- zip [0 :: Int ..] (zip xs values)])
            in Right (runtime (if py then "count_calls" else "countCalls") [handlerDoc (C.operationAbility op), quoted (C.operationName op), matches])
          C.ExternalCall decl args -> case lookup decl definitions of
            -- An asynchronous definition (an async workflow) is awaited.
            Just name | Just plain <- stripPrefix "await " name -> Right (text "(await " <> invoke plain (text "symbols":values) <> text ")")
            Just name -> Right (invoke name (text "symbols":values))
            Nothing ->
              let convertedValues = [converted (expressionType a) value | (a,value) <- zip args values]
                  -- A native adapter gets a handler for each ability it uses, first.
                  handlers = [handlerDoc ability | d <- C.unitDeclarations u, C.declarationId d == decl, ability <- C.declarationUses d, not (C.isFail ability)]
                  invocation = awaited (adapterName u decl) (invoke ("impl." ++ adapterName u decl)
                    (handlers ++ [nativeInput (expressionType a) value | (a,value) <- zip args convertedValues]))
              in Right (if declarationName decl `elem` map contractName (contracts u)
                then (if asyncMode then \call -> text "(await " <> call <> text ")" else id)
                  (invoke ("_lawspec_call_" ++ declarationName decl) (text "symbols":convertedValues))
                else nativeFailures decl (checkedResult (expressionType expression) invocation))
          _ -> Left "expected portable external call"
    assertionDoc context proposition = case proposition of
      AssertAll propositions -> statements (map (assertionDoc context) propositions)
      AssertImplies guard body -> if py
        then PythonExpr.suite (text "if " <> parenthesized (render guard)) (assertionDoc context body)
        else text "if " <> parenthesized (render guard) <> text " " <> Doc.block 2 (assertionDoc context body)
      AssertEqual left right ->
        let thunk value = asyncPrefix <> lambda [] value
            arguments = [message (context ++ " | expect " ++ propositionText proposition),
              thunk (render left),thunk (render right)]
            structural = usesData (expressionType left)
            extra = if structural then [referenceDoc (expressionType left),text "symbols"]
              else map (quoted . typeKey . expressionType) [left,right]
            helper = (if structural then "_lawspec_data_assert" else if py then "_lawspec_assert" else "_lawspecAssert") ++
              (if asyncMode then "Async" else "")
        in statement ((if asyncMode then text "await " else mempty) <> invoke helper (arguments ++ extra))
    conjunction [] = text (if py then "True" else "true")
    conjunction expressions = parenthesized (Doc.joinWith
      (if py then Doc.softline <> text "and " else text " &&" <> Doc.softline) (map parenthesized expressions))
    -- LAWSPEC_SEED fixes each property's random seed, so a run can be
    -- repeated exactly (lawspec test records the seed of every passing run).
    seedHelper = if py
      then "\n\n\n# Adapters may be slow (networks, timers): no per-example deadline.\n# Under lawspec test, failing examples are kept in its failure database.\n_lawspec_failures = os.environ.get(\"LAWSPEC_FAILURES\")\n_lawspec_database = (\n    {\"database\": DirectoryBasedExampleDatabase(\n        os.path.join(_lawspec_failures, \"hypothesis\"))}\n    if _lawspec_failures else {})\nsettings.register_profile(\"lawspec\", deadline=None, **_lawspec_database)\nsettings.load_profile(\"lawspec\")\n\n\ndef _lawspec_seeded(test):\n    value = os.environ.get(\"LAWSPEC_SEED\")\n    return test if value is None else _lawspec_seed(int(value))(test)\n" ++
        "\n\n# Workflows wait on a virtual clock under test.\nls.use_virtual_clock()\n"
      else "\nconst _lawspecSeed = globalThis.process?.env?.LAWSPEC_SEED;\nconst _lawspecSeeded = (options) => _lawspecSeed === undefined\n  ? options\n  : {...options, seed: Number(_lawspecSeed) | 0};\n" ++
        "\n// Workflows wait on a virtual clock under test.\nls.useVirtualClock();\n"
    propertyInvocation label generators parameters body options =
      let property = blockCall (if asyncMode then "fc.asyncProperty" else "fc.property") (generators ++ [callback parameters body])
          assertion = (if asyncMode then text "await " else mempty) <> blockCall "fc.assert" (property : map (\o -> invoke "_lawspecSeeded" [o]) (if null options then [text "{}"] else options))
      in testBlock (label ++ " property") "unused" (statement assertion)
    pythonProperty prefix decorators names body = statements
      (map (\decorator -> text "@" <> decorator) (text "_lawspec_seeded" : decorators) ++ [function (prefix ++ "_property") names body])
    lawTests (index,e) = do
      let label = owner e ++ "::" ++ name e
          harness = C.propertyHarness (original e)
          -- Python names a law's tests after its label (LawSpec.TestNames);
          -- a known-failing law's tests are helpers its one test calls.
          base = testNames !! index
          wrapped = py && C.harnessSkip harness == Nothing && C.harnessKnownFailing harness == Nothing && runSettings harness
          prefix = (if py && C.harnessKnownFailing harness /= Nothing then "_lawspec_known_" ++ drop 5 base
            else if wrapped then "_" ++ base else base) ++ "_"
          examples' = [testBlock (label ++ " example: " ++ exampleName example)
            (prefix ++ "_example" ++ show j) (statements
              (fresh e : [assign name (render value) | (name,value) <- bindings example] ++
               [bracket e (statements (map (assertionDoc (label ++ " example " ++ exampleName example)) (expectations example) ++
                 [assertionDoc label (assertion e)]))])) |
            (j,example) <- zip [0 :: Int ..] (examples (original e))]
          finite = finiteCases e
          cases' = maybe (boundaryCases e) id finite
      boundaries' <- mapM (\(j,values) -> do
        literals <- mapM valueLit values
        pure (testBlock label (prefix ++ "_boundary" ++ show j) (statements
          (fresh e : [assign (inputId input) value | (input,value) <- zip (inputs e) literals] ++
           [bracket e (assertionDoc (label ++ " boundary " ++ show j) (assertion e))])))) (zip [0 :: Int ..] cases')
      let body = statements (observations e ++ [bracket e (assertionDoc (label ++ " property") (assertion e))])
          generators = map (generatorDoc . inputType) (inputs e)
          names = map inputId (inputs e)
          ordinary = if py then pythonProperty prefix [invoke "given" generators] names
            (statements [fresh e,body])
            else propertyInvocation label generators (map text names) (statements [fresh e,body]) []
      refined <- (if any (containsStructural . inputType) (inputs e) then nativeRefinedProperty else refinedProperty) prefix label e body
      let needsContext = nativeGenerators || fieldContracts && any (usesData . inputType) (inputs e)
            || any (maybe False (const True) . generatorIndex) (generationPlan e)
      contextual <- if needsContext then
        (if py then contextualProperty prefix else webContextualProperty label) e body
        else pure ordinary
      drawn <- if not (null (C.harnessDraws harness)) then pure <$> harnessProperty prefix label e body else pure []
      let properties = if maybe False (const True) finite then [] else
            if not (null drawn) then drawn else
            [if needsContext then contextual else if any (not . null . inputRefinements) (inputs e) || propertyKind e == "contract" then refined else ordinary]
          tests = examples' ++ boundaries' ++ properties
          suffixes = ["_example" ++ show j | j <- [0 .. length examples' - 1]] ++
            ["_boundary" ++ show j | j <- [0 .. length boundaries' - 1]] ++
            ["_property" | not (null properties)]
      pure (Doc.render outputLayout (metadataDocument (if py then 72 else 80) (if py then "#" else "//") e) ++
        if not py then webHarness label harness tests
        else case (C.harnessSkip harness, C.harnessKnownFailing harness) of
          -- A skipped law runs nothing; it is still an obligation.
          (Just reason, _) -> renderDocument (function (base ++ "__skipped") []
            (statement (invoke "_harness.skip" [message label, message reason])))
          (_, Just reason) -> concatMap renderDocument tests ++ renderDocument (function (base ++ "__known_failing") []
            (statement (invoke "_harness.known_failing" [message label, quoted (base ++ "__known_failing"), message reason,
              array [text (prefix ++ suffix) | suffix <- suffixes]])))
          _ | wrapped -> concat [renderDocument doc ++ renderDocument (harnessRun label harness (prefix ++ suffix) (base ++ "_" ++ suffix) (suffix == "_property"))
                                | (suffix, doc) <- zip suffixes tests]
            | otherwise -> concatMap renderDocument tests)
    -- The harness plane (LawSpec.Harness). A law whose harness sets how its
    -- tests run (timeout, repeat, retry flaky, adequacy) has each test
    -- wrapped: the generated test calls the runtime with the law's own test.
    runSettings harness = C.harnessTimeout harness /= Nothing || C.harnessRepeat harness /= 1 ||
      C.harnessRetries harness /= 0 || observed harness
    observed harness = not (null (C.harnessCover harness) && null (C.harnessClassify harness) &&
      null (C.harnessLabels harness)) || C.harnessTarget harness /= Nothing
    harnessRun label harness inner public isProperty = function public [] (statement (invoke "_harness.run"
      ([message label, quoted public, text inner] ++
       [text "timeout=" <> text (show ms) | Just ms <- [C.harnessTimeout harness]] ++
       [text ("repeat=" ++ show (C.harnessRepeat harness)) | C.harnessRepeat harness /= 1] ++
       [text ("retries=" ++ show (C.harnessRetries harness)) | C.harnessRetries harness /= 0] ++
       [text "covers=" <> array [array [text (show p), quoted l] | C.Cover p l _ <- C.harnessCover harness] | isProperty, not (null (C.harnessCover harness))] ++
       [text "observed=True" | isProperty, observed harness])))
    -- What a generated case covers, classifies and labels, and the score
    -- targeted search maximizes. Only property tests observe.
    observations e =
      let harness = C.propertyHarness (original e)
          label = owner e ++ "::" ++ name e
          field key value = if py then text (key ++ "=") <> value else text (key ++ ": ") <> value
          fields = [field "covers" (array [array [quoted l, render w] | C.Cover _ l w <- C.harnessCover harness]) | not (null (C.harnessCover harness))] ++
            [field "classes" (array [array [quoted l, render c] | (c, l) <- C.harnessClassify harness]) | not (null (C.harnessClassify harness))] ++
            [field "labels" (array (map render (C.harnessLabels harness))) | not (null (C.harnessLabels harness))]
      in if not (observed harness) then [] else
        [statement (invoke "_harness.observe" ([message label] ++ if py then fields else [object [(k, v) | (k, v) <- jsFields harness label]]))] ++
        [statement (invoke "_harness.target" [render score, message label]) | Just score <- [C.harnessTarget harness]]
    jsFields harness _ =
      [("covers", array [array [quoted l, render w] | C.Cover _ l w <- C.harnessCover harness]) | not (null (C.harnessCover harness))] ++
      [("classes", array [array [quoted l, render c] | (c, l) <- C.harnessClassify harness]) | not (null (C.harnessClassify harness))] ++
      [("labels", array (map render (C.harnessLabels harness))) | not (null (C.harnessLabels harness))]
    -- JavaScript and TypeScript register a law's tests through `test`; a
    -- harness redefines it in a block around them, so each registered test
    -- runs under the harness (run settings), is collected (known failing), or
    -- is replaced by one skipped test.
    webHarness label harness tests =
      let rendered = concatMap renderDocument tests
          register = "  const _register = test;\n"
      in case (C.harnessSkip harness, C.harnessKnownFailing harness) of
        (Just reason, _) -> renderDocument (text "test(" <> message (label ++ " skipped") <> text ", {skip: " <>
          message reason <> text "}, () => " <> invoke "_harness.skip" [message label, message reason] <> text ");")
        (_, Just reason) -> "{\n" ++ register ++ "  const _known = [];\n  {\n    const test = (_name, body) => { _known.push(body); };\n" ++
          rendered ++ "  }\n  _register(" ++ Doc.render Doc.Compact (message (label ++ " known failing")) ++ ", () => " ++
          Doc.render Doc.Compact (invoke "_harness.knownFailing" [message label, message (label ++ " known failing"), message reason, text "_known"]) ++ ");\n}\n\n"
        _ | runSettings harness -> "{\n" ++ register ++ "  {\n    const test = (name, body) => _register(name, () => " ++
              Doc.render Doc.Compact (invoke "_harness.run" [message label, text "name", text "body", object
                ([("timeout", text (show ms)) | Just ms <- [C.harnessTimeout harness]] ++
                 [("repeat", text (show (C.harnessRepeat harness))) | C.harnessRepeat harness /= 1] ++
                 [("retries", text (show (C.harnessRetries harness))) | C.harnessRetries harness /= 0] ++
                 [("covers", array [array [text (show pc), quoted l] | C.Cover pc l _ <- C.harnessCover harness]) | not (null (C.harnessCover harness))] ++
                 [("observed", text "name.endsWith(' property')") | observed harness])]) ++ ");\n" ++
              rendered ++ "  }\n}\n\n"
          | otherwise -> rendered
    -- A property whose inputs a harness strategy draws: each strategy's
    -- value must satisfy its input's refinements; other inputs are drawn as
    -- usual and filtered by theirs.
    harnessProperty prefix label e body
      | py = do
          let harness = C.propertyHarness (original e)
              strategyOf input = [(n, d) | (i, n, d) <- C.harnessDraws harness, i == C.binderId (C.quantifiedBinder input)]
          draws <- mapM (\plan -> do
            let input = domainInput plan
                predicate = conjunction (map render (inputRefinements input))
            case strategyOf input of
              (strategy, draw) : _ -> do
                value <- drawDoc e plan strategy draw
                pure [assign (inputId input) (invoke "_harness.check_drawn"
                  [quoted strategy, quoted (inputName input), lambda [text (inputId input)] predicate, value])]
              [] -> do
                strategy <- contextStrategy e plan
                pure ([assign (inputId input) (method (text "_draw") "draw" [strategy])] ++
                  [statement (invoke "assume" [predicate]) | not (null (inputRefinements input))])) (generationPlan e)
          pure (pythonProperty prefix
            [pythonSettings (cases (generation e)), invoke "given" [invoke "st.data" []]] ["_draw"]
            (statements (fresh e : concat draws ++ [body])))
      -- fast-check composes a strategy into one arbitrary (oneof, filter,
      -- chain), so its shrinking follows the strategy's structure. Values
      -- are built with symbols made for generation.
      | otherwise = do
          let harness = C.propertyHarness (original e)
              strategyOf input = [(n, d) | (i, n, d) <- C.harnessDraws harness, i == C.binderId (C.quantifiedBinder input)]
          arbitraries <- mapM (\plan -> case strategyOf (domainInput plan) of
            (strategy, draw) : _ -> webArbitrary e plan draw >>= \a -> pure (Just strategy, a)
            [] -> (\a -> (Nothing, a)) <$> contextStrategy e plan) (generationPlan e)
          let checks = concat
                [ case strategy of
                    Just name' -> [statement (invoke "_harness.checkDrawn" [quoted name', quoted (inputName input),
                      lambda [text (inputId input)] (conjunction (map render (inputRefinements input))), text (inputId input)])
                      | not (null (inputRefinements input))]
                    Nothing -> [statement (invoke "fc.pre" [conjunction (map render (inputRefinements input))]) | not (null (inputRefinements input))]
                | ((strategy, _), plan) <- zip arbitraries (generationPlan e), let input = domainInput plan ]
              generated = [parenthesized (lambda [text "symbols"] a) <> text "(_generation)" | (_, a) <- arbitraries]
          pure (testBlock (label ++ " property") "unused" (statements
            [ assign "_generation" (invoke "new Map" [])
            , statement ((if asyncMode then text "await " else mempty) <> blockCall "fc.assert"
                [ blockCall (if asyncMode then "fc.asyncProperty" else "fc.property")
                    (generated ++ [callback (map (text . inputId) (inputs e)) (statements ([fresh e] ++ checks ++ [body]))])
                , invoke "_lawspecSeeded" [object [("numRuns", text (show (cases (generation e))))]] ]) ]))
    -- A strategy as one fast-check arbitrary.
    webArbitrary e plan draw = case draw of
      C.DrawAny ty
        | ty == inputType (domainInput plan) -> contextStrategy e plan
        | otherwise -> pure (generatorDoc ty)
      C.DrawOneOf _ values -> pure (method (invoke "fc.integer" [object [("min", text "0"), ("max", text (show (length values - 1)))]]) "map"
        [lambda [text "_choice"] (array [lambda [] (render v) | v <- values] <> text "[_choice]()")])
      C.DrawFrequency alternatives -> do
        options <- mapM (\(w, d) -> (\a -> object [("arbitrary", a), ("weight", text (show w))]) <$> webArbitrary e plan d) alternatives
        pure (invoke "fc.oneof" options)
      C.DrawSuchThat inner binder predicate _ -> do
        a <- webArbitrary e plan inner
        pure (method a "filter" [lambda [text (localName (C.binderId binder))] (render predicate)])
      C.DrawBind binder from rest -> do
        fromA <- webArbitrary e plan from
        restA <- webArbitrary e plan rest
        pure (method fromA "chain" [lambda [text (localName (C.binderId binder))] restA])
    -- A strategy's draw, as a Python expression.
    drawDoc e plan strategy draw = case draw of
      C.DrawAny ty
        | ty == inputType (domainInput plan) -> (\s -> method (text "_draw") "draw" [s]) <$> contextStrategy e plan
        | otherwise -> pure (method (text "_draw") "draw" [generatorDoc ty])
      C.DrawOneOf _ values -> pure (invoke "_harness.draw_one_of" [text "_draw", array [lambda [] (render v) | v <- values]])
      C.DrawFrequency alternatives -> do
        options <- mapM (\(w, d) -> (\doc -> array [text (show w), lambda [] doc]) <$> drawDoc e plan strategy d) alternatives
        pure (invoke "_harness.draw_frequency" [text "_draw", array options])
      C.DrawSuchThat inner binder predicate limit -> do
        doc <- drawDoc e plan strategy inner
        pure (invoke "_harness.draw_such_that" [lambda [] doc, lambda [text (localName (C.binderId binder))] (render predicate),
          text (show limit), quoted strategy])
      C.DrawBind binder from rest -> do
        fromDoc <- drawDoc e plan strategy from
        restDoc <- drawDoc e plan strategy rest
        pure (parenthesized (lambda [text (localName (C.binderId binder))] restDoc) <> Doc.delimitTrailing 4 "(" ")" [fromDoc])
    -- A benchmark: measured, never asserted.
    benchmarkTest (n, body) = if py
      then function ("test_benchmark__" ++ intercalate "_" (lawWords n)) []
        (statements [freshSymbols, statement (invoke "_harness.benchmark" [message n, lambda [] (render body)])])
      else text "test(" <> message ("benchmark " ++ n) <> text ", async () => " <> Doc.block 2
        (statements [freshSymbols, statement (text "await " <> invoke "_harness.benchmark" [message n, asyncPrefix <> lambda [] (render body)])]) <> text ");"
    -- A stateful model's test: the model runtime generates runs, executes
    -- them through the generated bridge definitions and checks them against
    -- the reference definitions.
    modelTest machine = do
      spec <- either (\m -> Left [Diagnostic "model" m Nothing]) Right
        (machineSpec bits declarations (C.unitDeclarations u) (C.unitContracts u) machine)
      let call identity = case lookup identity definitions of
            Just name -> Right (text (maybe name id (stripPrefix "await " name)))
            Nothing -> Left [Diagnostic "model" ("model " ++ C.machineName machine ++ ": " ++ C.idText identity ++ " is not a checked definition") Nothing]
          optional = maybe (pure (text (if py then "None" else "null"))) call
      start <- case C.machineStart machine of
        Just s -> (\r m -> array [r, m]) <$> call (C.startRun s) <*> call (C.startModel s)
        Nothing -> pure (text (if py then "None" else "null"))
      commands <- mapM (\c -> (\r f w -> array [r, f, w]) <$> call (C.commandRun c) <*> call (C.commandReference c) <*> optional (C.commandWhen c))
        (C.machineCommands machine)
      abstract <- optional (C.machineAbstractRun machine)
      invariants <- mapM (\i -> call (case i of C.OnModel f -> f; C.OnState f -> f)) (C.machineInvariants machine)
      let model = invoke (if py then "ls.Model" else "new ls.Model") [quoted spec, start, array commands, abstract, array invariants]
          label = unitName u ++ "::model " ++ C.machineName machine
          -- JavaScript callbacks may be async definitions, so the model
          -- runtime awaits each one.
          check = statement (if py then runtime "check_model" [model] else text "await " <> runtime "checkModelAsync" [model])
          block = if py then function ("test_model_" ++ C.machineName machine) [] check
            else text "test(" <> message label <> text ", async () => " <> Doc.block 2 check <> text ");"
          -- A shared model's commands also run at the same time; every
          -- history must be linearizable.
          parallel = statement (if py then runtime "check_model_parallel" [model] else text "await " <> runtime "checkModelParallelAsync" [model])
          parallelBlock = if py then function ("test_model_" ++ C.machineName machine ++ "_parallel") [] parallel
            else text "test(" <> message (label ++ " in parallel") <> text ", async () => " <> Doc.block 2 parallel <> text ");"
          -- Each scenario of the model runs on many schedules.
          scenario (i, program) =
            let run = statement (if py then runtime "check_scenario" [model, quoted (programSpec program)]
                  else text "await " <> runtime "checkScenarioAsync" [model, quoted (programSpec program)])
            in if py then function ("test_model_" ++ C.machineName machine ++ "_scenario" ++ show (i :: Int)) [] run
               else text "test(" <> message (unitName u ++ "::scenario " ++ programTitle program) <> text ", async () => " <> Doc.block 2 run <> text ");"
      pure (renderDocument block ++ (if C.machineShared machine then renderDocument parallelBlock else "") ++
        concatMap (renderDocument . scenario) (zip [0 ..] (C.machineScenarios machine)))
    -- An async adapter's task is awaited where it is called.
    awaited name call
      | name `notElem` asyncFunctions u = call
      | py = runtime "await_task" [call]
      | otherwise = text "(await " <> call <> text ")"
    contractWrapper contract =
      let arguments = contractArguments contract
          (resultName,resultType) = contractResult contract
          require label predicates = statement (runtime (if py then "require_contract" else "requireContract")
            [conjunction (map render predicates),message (contractName contract ++ " " ++ label ++ ": " ++
              intercalate " && " (map prettyExpr predicates))])
          invocation = awaited (adapterName u (C.contractDeclaration contract)) (invoke ("impl." ++ adapterName u (C.contractDeclaration contract))
            [nativeInput ty (converted ty (text name)) | (name,ty) <- arguments])
          body = statements
            [require "precondition" (contractPreconditions contract),
             assign resultName (checkedResult resultType invocation),
             require "postcondition" (contractPostconditions contract),
             statement (text ("return " ++ resultName))]
      in pure (renderDocument ((if asyncMode then text "async " else mempty) <>
        function ("_lawspec_call_" ++ contractName contract) ("symbols":map fst arguments) body))
    valueLit (V.ScalarValue value) = Right (if py then PythonExpr.scalarLiteral value else runtime "literal"
      [WebExpr.literalValue (toJSON value),text "symbols"])
    valueLit value@(V.DataValue (C.Constructor "List" _) _ _) = do
      items <- either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right (V.listItems value)
      array <$> mapM valueLit items
    valueLit (V.PresenceValue (C.Constructor wrapper _) payload) = do
      field <- traverse valueLit payload
      pure (invoke (if py then "ls.Presence" else "new ls.Presence")
        (quoted wrapper : case field of
          Nothing -> [text (if py then "False" else "false")]
          Just value -> [text (if py then "True" else "true"),value]))
    valueLit (V.DataValue ty tag fields) | usesData ty = do
      values <- mapM valueLit fields
      pure (schema "construct" [referenceDoc ty,quoted (C.idText tag),array values,width])
    valueLit (V.DataValue (C.Constructor name _) tag fields) | name `elem` ["Maybe","Either"] = do
      values <- mapM valueLit fields
      pure (runtime "construct" [quoted (C.idText tag),array values])
    valueLit _ = Left [Diagnostic "target" ("structural literal is not implemented for " ++ target) Nothing]
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
      let ty = inputType (domainInput plan)
      seeds <- mapM valueLit (generatorBoundaries plan)
      let hints = [render hint | hint <- generatorHints plan,
            C.expressionType hint == ty, case C.expressionNode hint of
              C.Constant _ -> True
              C.Local _ -> True
              _ -> False]
      pure (case requiredSymbol plan of
        value:_ -> invoke (if py then "st.just" else "fc.constant") [render value]
        [] -> invoke "_data_strategy"
          ([text "_lawspec_schema",referenceDoc ty,width,text (show budget),
            text (if py then "_lawspec_primitive_generators.__getitem__"
              else "(name) => _lawspec_primitive_generators[name]"),
            text "symbols",array (seeds ++ hints)] ++
            [text (show (maxAttempts (generation e))) | not py] ++
            -- The generated native wrapper takes index directly; the shared
            -- runtime receives its default native generators and schema.
            [text "undefined" | not py, not nativeGenerators, generatorIndex plan /= Nothing] ++
            [text "undefined" | not py, not nativeGenerators, generatorIndex plan /= Nothing] ++
            maybe [] (pure . indexDoc) (generatorIndex plan)))
    -- Index-directed generation: the target is evaluated from earlier draws.
    indexDoc indexed =
      let equation (tag,texts) = (quoted (C.idText tag),
            if py then Doc.delimitTrailing 4 "(" ")" (map quoted texts ++ [mempty | length texts == 1])
            else array (map quoted texts))
          table = Doc.delimitTrailing 4 "{" "}"
            [key <> text ": " <> value | (key,value) <- map equation (indexedEquations indexed)]
          pair = if py then Doc.delimitTrailing 4 "(" ")" [render (indexedTarget indexed),table]
            else array [render (indexedTarget indexed),table]
      in if py then text "index=" <> pair else pair
    webContextualProperty label e body = do
      let state names = object [("_values",array names),("symbols",text "symbols")]
          initial = method (invoke "fc.constant" [text "null"]) "map"
            [lambda [] (parenthesized (object [("_values",array []),("symbols",invoke "new Map" [])]))]
          step source (index,plan) = do
            strategy <- contextStrategy e plan
            let previous = map (text . inputId) (take index (inputs e))
                mapped = method strategy "map" [lambda [text "_value"]
                  (parenthesized (state (previous ++ [text "_value"])))]
            pure (method source "chain" [lambda [state previous] mapped])
      cases' <- foldM step initial (zip [0 :: Int ..] (generationPlan e))
      let predicate = conjunction (map render (concatMap inputRefinements (inputs e)))
          cfg = generation e
          checkedBody = statements ([statement (invoke "fc.pre" [predicate])] ++ installs e ++ [body])
      pure (propertyInvocation label [cases'] [state (map (text . inputId) (inputs e))]
        checkedBody [object [("numRuns",text (show (cases cfg))),
          ("maxSkipsPerRun",text (show (maxAttempts cfg))) ]])
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
    nativeRefinedProperty prefix label e body =
      let names = map (text . inputId) (inputs e)
          -- An integer input draws from its refinement's constant range;
          -- the filter still checks every refinement.
          generators = [Generator.generatorDocWithin py bits usesData referenceDoc (inputRange bits input) (inputType input) | input <- inputs e]
          predicate = conjunction (map render (concatMap inputRefinements (inputs e)))
          cfg = generation e
          tuple = invoke (if py then "st.tuples" else "fc.tuple") generators
          caseValue = if py then Doc.delimitTrailing 4 "(" ")" [text "_values",text "{}"]
            else parenthesized (object [("_values",text "_values"),("symbols",invoke "new Map" [])])
          mapped = method tuple "map" [lambda [text "_values"] caseValue]
          pattern = object [("_values",array names),("symbols",text "symbols")]
          condition = if py then lambda [text "_case"]
            (parenthesized (lambda (text "symbols":names) predicate) <>
              Doc.delimitTrailing 4 "(" ")" [text "_case[1]",text "*_case[0]"])
            else lambda [pattern] predicate
          filtered = method mapped "filter" [condition]
          assignments = [assign (inputId input) (text ("_values[" ++ show index ++ "]")) |
            (index,input) <- zip [0 :: Int ..] (inputs e)]
      in pure $ if py then pythonProperty prefix
        [pythonSettings (cases cfg),invoke "given" [filtered]]
        ["_case"] (statements ([text "_values, symbols = _case"] ++ assignments ++ installs e ++ [body]))
        else propertyInvocation label [filtered] [pattern] (statements (installs e ++ [body]))
          [object [("numRuns",text (show (cases cfg))),("maxSkipsPerRun",text (show (maxAttempts cfg)))]]
    -- No per-example deadline: adapters may do real work (I/O, timeouts),
    -- and solving an index table is a one-time cost of the first example.
    pythonSettings count = invoke "settings" [text ("max_examples=" ++ show count), text "deadline=None"]
    refinedProperty prefix label e body = do
      domains <- mapM (domainCode e) (zip [0 :: Int ..] (generationPlan e))
      let cfg = generation e
          checkBody = statements ([assign (inputId input) (text ("_values[" ++ show index ++ "]")) |
            (index,input) <- zip [0 :: Int ..] (inputs e)] ++ installs e ++ [body])
          check = if py then function "_check" ["_values"] checkBody
            else assign "_check" (callback [text "_values"] checkBody)
          run = statement ((if asyncMode then text "await " else mempty) <> runtime (if py then "refined_case" else if asyncMode then "refinedCaseAsync" else "refinedCase")
            [array domains,text "_seed",text (show (maxAttempts cfg)),text (show (maxShrinks cfg)),text "_check",
             message (label ++ " | " ++ intercalate "; " (map prettyExpr (concatMap inputRefinements (inputs e))))])
          seededBody = statements [freshSymbols, (if py then Doc.hardline else mempty) <> check, run]
      pure $ if py then pythonProperty prefix
        [pythonSettings (cases cfg),
         invoke "given" [invoke "st.integers" [text "min_value=0",text "max_value=2147483647"]]]
        ["_seed"] seededBody
        else propertyInvocation label [invoke "fc.integer" [object [("min",text "0"),("max",text "2147483647")]]]
          [text "_seed"] seededBody [object [("numRuns",text (show (cases cfg)))]]
    domainCode e (index,plan) = do
      seeds <- mapM valueLit (generatorBoundaries plan)
      let input = domainInput plan
          previous = take index (inputs e)
          bind inputs' seeded expression =
            let names = map (text . inputId) inputs'
                seedArgument = if seeded then [text "_seed"] else []
            in if py then lambda (text "_values":seedArgument)
              (parenthesized (lambda names expression) <> Doc.delimitTrailing 4 "(" ")" [text "*_values"])
              else lambda (array names:seedArgument) expression
          bounds = [array [quoted operator,render value] | (operator,value) <- domainBounds plan]
          candidates = runtime (if py then "domain_candidates" else "domainCandidates")
            [quoted (typeKey (inputType input)),text "_seed",width,array bounds,
             array (seeds ++ map render (generatorHints plan))]
          predicate = conjunction (map render (inputRefinements input))
      pure (array [bind previous True candidates,bind (previous ++ [input]) False predicate])
    split s = case break (== '.') s of (a,[]) -> [a]; (a,_:b) -> a:split b
