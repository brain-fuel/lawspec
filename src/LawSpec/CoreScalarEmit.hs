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
import Data.Aeson (encode, toJSON)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T
import Data.List (intercalate, isPrefixOf, isInfixOf)
import Control.Monad (unless, foldM)

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
  tests <- concat <$> mapM lawTests (zip [0 :: Int ..] ls)
  wrappers <- concat <$> mapM contractWrapper (contracts u)
  let completeHeader = if py || hasData || "fc." `isInfixOf` tests then testHeader else unlines (filter (/= "import fc from 'fast-check';") (lines testHeader))
  pure [Artifact stubPath stub "user" "source",Artifact testPath (finish (completeHeader ++ dataHelpers ++ testHelpers ++ wrappers ++ tests)) "generated" "test"]
  where
    finish content = if py then reverse (dropWhile (== '\n') (reverse content)) ++ "\n" else content
    adapterFunctions = [(n,t) | (n,t) <- functions u, C.Id (unitName u ++ "::" ++ n) `notElem` map fst definitions]
    py = target == "python"
    hasData = (nativeGenerators || not (null definitions) || not (null declarations) || any (usesData . snd) (functions u) ||
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
    runtimeImport = if py then "import lawspec_runtime as ls\n" else "import * as ls from '../src/lawspec_runtime." ++ (if ts then "js" else "mjs") ++ "';\n"
    testHeader = (if ts then "// @ts-nocheck\n" else "") ++ (if py then "#" else "//") ++ " Generated by LawSpec.\n" ++ runtimeImport ++ if py
      then (if null definitions then "" else "import lawspec_definition_bodies as _definitions\n") ++ dataImports ++ "import json\nfrom hypothesis import assume, given, settings, strategies as st\n" ++ (if null adapterFunctions then "" else "import " ++ unitName u ++ " as impl\n")
      else (if null definitions then "" else "import * as _definitions from '../src/lawspec_definition_bodies." ++ (if ts then "js" else "mjs") ++ "';\n") ++ webImports "../src/" ++ "import {test} from 'node:test';\nimport assert from 'node:assert/strict';\nimport fc from 'fast-check';\nimport * as impl from '../src/" ++ slash ++ (if ts then ".js" else ".mjs") ++ "';\n"
    testHelpers = (if hasData then "" else if py then "\n\n" else "\n") ++
      Doc.render outputLayout (Helpers.assertionHelperDoc py) ++
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
    stub = (if py then "#" else "//") ++ " User-owned LawSpec adapter.\n" ++ (if py then dataImports ++ "import lawspec_runtime as ls\n" else webImports (concat (replicate (length parts - 1) "../") ++ "./") ++ (if hasData then "import * as ls from '" ++ (if length parts == 1 then "./" else concat (replicate (length parts - 1) "../")) ++ "lawspec_runtime." ++ (if ts then "js" else "mjs") ++ "';\n" else "")) ++ (if py && not (null adapterFunctions) then "\n\n" else "") ++ intercalate (if py then "\n\n" else "\n") (map stubFn adapterFunctions)
    webImports root = if not hasData then "" else "import * as data from '" ++ root ++ "lawspec_data." ++ (if ts then "js" else "mjs") ++ "';\nimport * as schema from '" ++ root ++ "lawspec_schema." ++ (if ts then "js" else "mjs") ++ "';\n"
    nativeArg ty | usesData ty = native ty
    nativeArg (Applied "List" element) = if py then "list[" ++ nativeArg element ++ "]" else "Array<" ++ nativeArg element ++ ">"
    nativeArg t = if t == Named "Integer" then (if py then "int" else "bigint") else if t == Named "Unit" then (if py then "ls.Absence" else "unknown") else native t
    stubFn (n,t) = Doc.render outputLayout $
      let (args,r) = functionType t
          pythonType ty = if usesData ty then either error id (PythonData.pythonDataTypeDoc declarations ty) else Doc.text (nativeArg ty)
          arguments = [Doc.text ("value" ++ show i) <>
            (if py then Doc.text ": " <> pythonType a
             else Doc.text (if ts then ": " ++ nativeArg a else "")) |
            (i,a) <- zip [0 :: Int ..] args]
          -- Native representations can erase LawSpec distinctions. Keep the
          -- declared interface visible in both the stub and its canonical key.
          signatureComments =
            mconcat [stubComment ("LawSpec argument " ++ show i ++ ": " ++ prettyType a) |
              (i,a) <- zip [0 :: Int ..] args] <>
            stubComment ("LawSpec result: " ++ prettyType r)
          signature = Doc.text ((if py then "def " else "export function ") ++ n) <>
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
          let candidates = takeWhile (\n -> quotedWidth (take n rest) <= 40) [1 .. length (take 40 rest)]
              limit = foldl (\_ n -> n) 1 candidates
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
    callback parameters body = Doc.delimitTrailing 4 "(" ")" parameters <> text " => " <> Doc.block 2 body
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
    converted ty value = if usesData ty then schema "validate" [referenceDoc ty,value,width]
      else runtime "convert" [value,quoted (typeKey ty),width]
    render term = either error id (renderer declarations bits localName external term)
      where
        renderer = if py then PythonExpr.renderExpression else WebExpr.renderExpression ts
        external expression values = case C.expressionNode expression of
          C.ExternalCall decl args -> case lookup decl definitions of
            Just name -> Right (invoke name (text "symbols":values))
            Nothing ->
              let convertedValues = [converted (expressionType a) value | (a,value) <- zip args values]
                  invocation = invoke ("impl." ++ declarationName decl)
                    [nativeInput (expressionType a) value | (a,value) <- zip args convertedValues]
              in Right (if declarationName decl `elem` map contractName (contracts u)
                then invoke ("_lawspec_call_" ++ declarationName decl) (text "symbols":convertedValues)
                else checkedResult (expressionType expression) invocation)
          _ -> Left "expected portable external call"
    assertionDoc context proposition = case proposition of
      AssertAll propositions -> statements (map (assertionDoc context) propositions)
      AssertImplies guard body -> if py
        then PythonExpr.suite (text "if " <> parenthesized (render guard)) (assertionDoc context body)
        else text "if " <> parenthesized (render guard) <> text " " <> Doc.block 2 (assertionDoc context body)
      AssertEqual left right ->
        let arguments = [message (context ++ " | expect " ++ propositionText proposition),
              lambda [] (render left),lambda [] (render right)]
            structural = usesData (expressionType left)
            extra = if structural then [referenceDoc (expressionType left),text "symbols"]
              else map (quoted . typeKey . expressionType) [left,right]
            helper = if structural then "_lawspec_data_assert" else if py then "_lawspec_assert" else "_lawspecAssert"
        in statement (invoke helper (arguments ++ extra))
    conjunction [] = text (if py then "True" else "true")
    conjunction expressions = parenthesized (Doc.joinWith
      (if py then Doc.softline <> text "and " else text " &&" <> Doc.softline) (map parenthesized expressions))
    propertyInvocation label generators parameters body options =
      let property = blockCall "fc.property" (generators ++ [callback parameters body])
          assertion = blockCall "fc.assert" (property:options)
      in testBlock (label ++ " property") "unused" (statement assertion)
    pythonProperty prefix decorators names body = statements
      (map (\decorator -> text "@" <> decorator) decorators ++ [function (prefix ++ "_property") names body])
    lawTests (index,e) = do
      let label = owner e ++ "::" ++ name e
          prefix = "test_law" ++ show index
          examples' = [testBlock (label ++ " example: " ++ exampleName example)
            (prefix ++ "_example" ++ show j) (statements
              (freshSymbols : [assign name (render value) | (name,value) <- bindings example] ++
               map (assertionDoc (label ++ " example " ++ exampleName example)) (expectations example) ++
               [assertionDoc label (assertion e)])) |
            (j,example) <- zip [0 :: Int ..] (examples (original e))]
          finite = finiteCases e
          cases' = maybe (boundaryCases e) id finite
      boundaries' <- mapM (\(j,values) -> do
        literals <- mapM valueLit values
        pure (testBlock label (prefix ++ "_boundary" ++ show j) (statements
          (freshSymbols : [assign (inputId input) value | (input,value) <- zip (inputs e) literals] ++
           [assertionDoc (label ++ " boundary " ++ show j) (assertion e)])))) (zip [0 :: Int ..] cases')
      let body = assertionDoc (label ++ " property") (assertion e)
          generators = map (generatorDoc . inputType) (inputs e)
          names = map inputId (inputs e)
          ordinary = if py then pythonProperty prefix [invoke "given" generators] names
            (statements [freshSymbols,body])
            else propertyInvocation label generators (map text names) (statements [freshSymbols,body]) []
      refined <- (if any (containsStructural . inputType) (inputs e) then nativeRefinedProperty else refinedProperty) prefix label e body
      let needsContext = nativeGenerators || fieldContracts && any (usesData . inputType) (inputs e)
            || any (maybe False (const True) . generatorIndex) (generationPlan e)
      contextual <- if needsContext then
        (if py then contextualProperty prefix else webContextualProperty label) e body
        else pure ordinary
      let properties = if maybe False (const True) finite then [] else
            [if needsContext then contextual else if any (not . null . inputRefinements) (inputs e) || propertyKind e == "contract" then refined else ordinary]
      pure (Doc.render outputLayout (metadataDocument (if py then 72 else 80) (if py then "#" else "//") e) ++
        concatMap renderDocument (examples' ++ boundaries' ++ properties))
    contractWrapper contract =
      let arguments = contractArguments contract
          (resultName,resultType) = contractResult contract
          require label predicates = statement (runtime (if py then "require_contract" else "requireContract")
            [conjunction (map render predicates),message (contractName contract ++ " " ++ label ++ ": " ++
              intercalate " && " (map prettyExpr predicates))])
          invocation = invoke ("impl." ++ contractName contract)
            [nativeInput ty (converted ty (text name)) | (name,ty) <- arguments]
          body = statements
            [require "precondition" (contractPreconditions contract),
             assign resultName (checkedResult resultType invocation),
             require "postcondition" (contractPostconditions contract),
             statement (text ("return " ++ resultName))]
      in pure (renderDocument (function ("_lawspec_call_" ++ contractName contract) ("symbols":map fst arguments) body))
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
      -- Solving an index table is a one-time cost of the first example, so
      -- index-directed properties have no per-example deadline.
      let deadline = [text "deadline=None" | any ((/= Nothing) . generatorIndex) (generationPlan e)]
      pure (pythonProperty prefix
        [invoke "settings" (text ("max_examples=" ++ show (cases (generation e))) : deadline),
         invoke "given" [invoke "st.data" []]] ["_draw"]
        (statements (freshSymbols : draws ++ [statement (invoke "assume" [predicate]),body])))
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
          checkedBody = statements [statement (invoke "fc.pre" [predicate]),body]
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
          generators = map (generatorDoc . inputType) (inputs e)
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
        [invoke "settings" [text ("max_examples=" ++ show (cases cfg))],invoke "given" [filtered]]
        ["_case"] (statements ([text "_values, symbols = _case"] ++ assignments ++ [body]))
        else propertyInvocation label [filtered] [pattern] body
          [object [("numRuns",text (show (cases cfg))),("maxSkipsPerRun",text (show (maxAttempts cfg)))]]
    refinedProperty prefix label e body = do
      domains <- mapM (domainCode e) (zip [0 :: Int ..] (generationPlan e))
      let cfg = generation e
          checkBody = statements ([assign (inputId input) (text ("_values[" ++ show index ++ "]")) |
            (index,input) <- zip [0 :: Int ..] (inputs e)] ++ [body])
          check = if py then function "_check" ["_values"] checkBody
            else assign "_check" (callback [text "_values"] checkBody)
          run = statement (runtime (if py then "refined_case" else "refinedCase")
            [array domains,text "_seed",text (show (maxAttempts cfg)),text (show (maxShrinks cfg)),text "_check",
             message (label ++ " | " ++ intercalate "; " (map prettyExpr (concatMap inputRefinements (inputs e))))])
          seededBody = statements [freshSymbols, (if py then Doc.hardline else mempty) <> check, run]
      pure $ if py then pythonProperty prefix
        [invoke "settings" [text ("max_examples=" ++ show (cases cfg))],
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
