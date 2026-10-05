-- Application bridges share the checked JS/TS schema and native arbitraries.
module LawSpec.WebNativeBinding (emitBindings) where

import Control.Monad (forM, unless)
import Data.Char (toLower)
import Data.List (intercalate, nub)
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Backend (unitName)
import LawSpec.Testing
import LawSpec.NativeBinding
import LawSpec.NativeRequest
import qualified LawSpec.WebTypes as W
import qualified LawSpec.WebData as Data
import qualified LawSpec.WebDefinitions as Definitions
import qualified LawSpec.CoreScalarEmit as Scalar
import qualified LawSpec.WebExpr as E
import qualified LawSpec.Code.Doc as D
import LawSpec.RuntimeSources (runtimeSource)

emitBindings :: Bool -> Bool -> BindingPlan -> Plan -> [Artifact] -> Either String [Artifact]
emitBindings ts minify bindings plan files = do
  unless (bindingRustCrate bindings == Nothing) (Left "rustCrate is only valid for Rust bindings")
  unless (null mappings || not (null functions) || not (null calls) || not (null generators))
    (Left "native type mappings require a function or generator binding")
  let constructed = [ref | (_, ConstructorCall ref) <- calls]
      handleNatives = [resolvedNativeType m | m <- mappings, C.dataHandle (resolvedDeclaration m)]
      refs = nub (map snd functions ++ constructed ++ handleNatives ++ [resolvedNativeConstructor c | m <- mappings, c <- resolvedConstructors m] ++
        [ref | m <- mappings, Just hook <- [resolvedCodec m],
          ref <- [resolvedNativeType m, codecToNative hook, codecFromNative hook]])
      alias ref = "native" ++ show (length (takeWhile (/=ref) refs))
  imports <- forM refs $ \ref -> nativeImport "./" (alias ref) ref
  let entries = [E.array [E.quoted (C.idText (C.constructorId (resolvedConstructor c))),
        D.delimitTrailing 2 "{" "}" [D.text ("native: " ++ alias (resolvedNativeConstructor c)),
          D.text "fields: " <> E.array [E.quoted name | (_,name) <- resolvedFields c]]] |
        m <- mappings, c <- resolvedConstructors m]
      hooks = [E.array [E.quoted (C.idText (C.dataId (resolvedDeclaration m))),
        D.delimitTrailing 2 "{" "}" [D.text ("native: " ++ alias (resolvedNativeType m)),
          D.text ("toNative: " ++ alias (codecToNative hook)),
          D.text ("fromNative: " ++ alias (codecFromNative hook))]] |
        m <- mappings, Just hook <- [resolvedCodec m]]
      hookType = if ts then "<string, {native: Function; toNative: Function; fromNative: Function}>" else ""
      mapType = if ts then "<string, {native: Function; fields: string[]}>" else ""
      supportBody = D.joinWith D.hardline (sourceImports "./" ++ imports ++
        [D.text "export const canonical = data.makeSchema();",
         D.text "export const native = canonical.withNativeBindings(" <>
          D.nest 4 (D.softbreak <> E.call ("new Map" ++ mapType) [E.array entries] <> D.text "," <>
            D.softbreak <> E.call ("new Map" ++ hookType) [E.array hooks]) <> D.softbreak <> D.text ");"] ++
        [D.text ("export {" ++ intercalate ", " exported ++ "};") | not (null exported)])
      exported = nub (map alias (map snd functions ++ constructed ++ handleNatives))
      support = Artifact ("src/lawspec_native." ++ ext) (render supportBody) "generated" "source"
  mapM_ (W.identifier False . snd) [field | m <- mappings, c <- resolvedConstructors m, field <- resolvedFields c]
  bridges <- fmap concat $ forM (plannedUnits plan) $ \planned -> do
    let unit = plannedUnit planned
        definitions = map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions unit)
        adapters = [d | d <- C.unitDeclarations unit, C.declarationId d `notElem` definitions]
        bound d = lookup (C.declarationId d) ([(C.declarationId decl,StaticCall ref) | (decl,ref) <- functions] ++
          [(C.declarationId decl,call) | (decl,call) <- calls])
        -- A bound handle is typed by its native class.
        handleTypes = [(C.dataId (resolvedDeclaration m), D.text ("bridge." ++ alias (resolvedNativeType m))) |
          m <- mappings, C.dataHandle (resolvedDeclaration m)]
        typeOf = Data.webDataTypeDocWith (planDataDeclarations plan) handleTypes
        depth = length (filter (== '.') (unitName unit))
        root = if depth == 0 then "./" else concat (replicate depth "../")
    if not (any (maybe False (const True) . bound) adapters) then pure [] else do
      unless (all (maybe False (const True) . bound) adapters) (Left "a web bound unit must map every adapter")
      bodies <- forM adapters $ \decl -> do
        let (args,result) = C.functionType (C.declarationType decl)
        argTypes <- mapM typeOf args
        resultType <- typeOf result
        argRefs <- mapM Data.webTypeReferenceDoc args
        resultRef <- Data.webTypeReferenceDoc result
        let values = [D.text ("value" ++ show i) | i <- [0::Int ..length args-1]]
            bits = D.text (show (planMachineBits plan))
            convert schema method ty value = E.call ("bridge." ++ schema ++ "." ++ method) [ty,value,bits,D.text "symbols"]
            arguments = [convert "native" "toNative" ty (convert "canonical" "fromNative" ty value) | (ty,value) <- zip argRefs values]
            isUnit ty = ty == C.scalarType "Unit"
            resultOf ref value = convert "canonical" "toNative" ref (convert "native" "fromNative" ref value)
            returned = D.text "return " <> resultOf resultRef (D.text "result") <> D.text ";"
        call <- maybe (Left "unbound adapter") Right (bound decl)
        application <- case call of
          StaticCall ref -> pure (E.call ("bridge." ++ alias ref) arguments)
          -- A method of the first handle argument, given the others.
          MethodCall name -> case [i | (i,ty) <- zip [0::Int ..] args, isHandle ty] of
            h : _ -> pure (D.text "(" <> arguments !! h <> D.text ")" <>
              E.call ("." ++ name) [value | (i,value) <- zip [0..] arguments, i /= h])
            [] -> Left ("method binding " ++ C.idText (C.declarationId decl) ++ " has no handle argument")
          -- A native constructor, given the arguments that are not Unit.
          ConstructorCall ref -> pure (E.call ("new bridge." ++ alias ref)
            [value | (ty,value) <- zip args arguments, not (isUnit ty)])
        resultBody <- case (call, result) of
          _ | isUnit result -> pure (application <> D.text ";")
          (StaticCall _, _) -> pure (D.text "const result = " <> application <> D.text ";" <> D.hardline <> returned)
          -- A method or constructor's absent value (null or undefined) is Nothing.
          (_, C.Constructor "Maybe" [C.TypeArgument element]) -> do
            elementRef <- Data.webTypeReferenceDoc element
            pure (D.text "const result = " <> application <> D.text ";" <> D.hardline <>
              D.text "return result === null || result === undefined" <>
              D.nest 4 (D.softline <> D.text "? new data.Nothing()" <> D.softline <> D.text ": " <>
                E.call "new data.Just" [resultOf elementRef (D.text "result")]) <> D.text ";")
          _ -> pure (D.text "const result = " <> application <> D.text ";" <> D.hardline <> returned)
        let signature = D.text ("export function " ++ C.declarationName decl) <>
              D.delimitTrailing 4 "(" ")" [value <> if ts then D.text ": " <> ty else mempty | (value,ty) <- zip values argTypes] <>
              (if ts then D.text ": " <> (if result == C.scalarType "Unit" then D.text "void" else resultType) else mempty)
        pure (signature <> D.text " " <> D.block 2 (D.text "const symbols = new Map();" <> D.hardline <>
          D.text "try " <> D.block 2 resultBody <> D.text " catch (error) " <>
          D.block 2 (D.text "throw " <> E.call "new TypeError"
            [E.quoted ("native binding " ++ C.idText (C.declarationId decl) ++ ": ") <>
             D.text " + String(error)", D.text "{cause: error}"] <> D.text ";")))
      let pathname = "src/" ++ map (\c -> if c == '.' then '/' else c) (unitName unit) ++ "." ++ ext
          header = sourceImports root ++ [D.text ("import * as bridge from " ++ W.q (root ++ "lawspec_native." ++ importExt) ++ ";")]
      pure [Artifact pathname (render (D.joinWith D.hardline header <> D.hardline <> D.hardline <>
        D.joinWith (D.hardline <> D.hardline) bodies)) "generated" "source"]
  dataFiles <- if any ((== "src/lawspec_data." ++ ext) . artifactPath) files then pure []
    else Data.emitWebDataWithProfile ts (planMachineBits plan) layout (planDataDeclarations plan)
  generatorFiles <- if null generators then pure [] else do
    imports' <- forM (zip [0::Int ..] generators) $ \(i,generator) ->
      nativeImport "./" ("factory" ++ show i) (resolvedGeneratorFactory generator)
    let factoryType = if ts then "<string, (...args: any[]) => fc.Arbitrary<any>>" else ""
        factories = D.text "const factories = " <> E.call ("new Map" ++ factoryType)
          [E.array [E.array [E.quoted (C.idText (resolvedGeneratorType g)), D.text ("factory" ++ show i)] |
            (i,g) <- zip [0::Int ..] generators]] <> D.text ";"
        wrapper = D.text "export function strategy" <> D.delimitTrailing 4 "(" ")"
          (map D.text (if ts then ["schema: any", "reference: any", "bits: number", "budget: number",
            "scalar: any", "symbols = new Map()", "witnesses: any[] = []", "maxAttempts = 1000", "index: any = null"]
            else ["schema", "reference", "bits", "budget", "scalar", "symbols = new Map()", "witnesses = []", "maxAttempts = 1000", "index = null"])) <>
          D.text " " <> D.block 2 (D.text "return " <> E.call
            (if ts then "(baseStrategy as (...args: any[]) => fc.Arbitrary<any>)" else "baseStrategy")
            (map D.text ["schema", "reference", "bits", "budget", "scalar", "symbols", "witnesses", "maxAttempts", "factories", "bridge.native", "index"]) <> D.text ";")
        header = map D.text ["// Generated by LawSpec. Do not edit.", "import * as fc from 'fast-check';",
          "import * as bridge from '../src/lawspec_native." ++ importExt ++ "';",
          "import {strategy as baseStrategy} from './lawspec_data_strategies." ++ importExt ++ "';"]
        helper = Artifact ("test/lawspec_native_generators." ++ ext)
          (render (D.joinWith D.hardline (header ++ imports') <> D.hardline <> D.hardline <>
            factories <> D.hardline <> D.hardline <> wrapper)) "generated" "test"
    emitted <- either (Left . show) Right $ concat <$> mapM (\unit ->
      Scalar.scalarEmitWithNativeGenerators True minify (planDataDeclarations plan)
        (Definitions.definitionCalls (map plannedUnit (plannedUnits plan)))
        (planMachineBits plan) target (plannedUnit unit) (plannedProperties unit))
        [unit | unit <- plannedUnits plan, not (null (plannedProperties unit))]
    let strategies = unlines [if line == "import * as ls from './lawspec_runtime.mjs';"
          then "import * as ls from '../src/lawspec_runtime." ++ importExt ++ "';"
          else if line == schemaImport
            then "import {RefinementViolation, witnessed, witnessInstances} from '../src/lawspec_schema." ++ importExt ++ "';"
          else line | line <- lines (runtimeSource "web-data-strategies")]
    pure (helper : [file | file <- emitted, artifactPlacement file == "test"] ++
      [Artifact ("test/lawspec_data_strategies." ++ ext) ((if ts then "// @ts-nocheck\n" else "") ++ strategies) "generated" "test" |
        not (any ((== "test/lawspec_data_strategies." ++ ext) . artifactPath) files)])
  let replacements = map artifactPath (bridges ++ generatorFiles)
  unless (all ((/= "src/lawspec_native." ++ ext) . artifactPath) files) (Left "unit shadows generated lawspec_native support")
  let runtime = [Artifact ("src/lawspec_runtime." ++ ext) ((if ts then "// @ts-nocheck\n" else "") ++ runtimeSource "javascript") "generated" "source" |
        not (any ((== "src/lawspec_runtime." ++ ext) . artifactPath) files)]
  let generated = [file | file <- files, artifactPath file `notElem` replacements] ++
        dataFiles ++ runtime ++ [support] ++ bridges ++ generatorFiles
  stubs <- generatorStubs ts plan bindings generated
  pure (generated ++ stubs)
  where
    representations = bindingRepresentations bindings
    mappings = resolvedTypes representations
    functions = bindingFunctions bindings
    calls = bindingCalls bindings
    handles = [C.dataId d | d <- planDataDeclarations plan, C.dataHandle d]
    isHandle ty = case ty of
      C.Constructor name [] -> C.Id name `elem` handles
      _ -> False
    generators = resolvedGenerators representations
    target = if ts then "typescript" else "javascript"
    ext = if ts then "ts" else "mjs"
    importExt = if ts then "js" else "mjs"
    layout = D.selectLayout minify (D.Pretty 80)
    render doc = D.render layout (doc <> D.hardline)
    sourceImports root = D.text "// Generated by LawSpec. Do not edit." :
      [D.text ("import * as " ++ alias ++ " from " ++ W.q (root ++ name ++ "." ++ importExt) ++ ";") |
        (alias,name) <- [("ls","lawspec_runtime"),("data","lawspec_data"),("schema","lawspec_schema")]]
    nativeImport root alias (NativeRef parts) = do
      unless (length parts >= 2) (Left "web native references require a module and export")
      mapM_ (W.identifier True) parts
      pure (D.text "import " <> D.delimit 2 "{" "}" [D.text (last parts ++ " as " ++ alias)] <>
        D.text (" from " ++ W.q (root ++ intercalate "/" (init parts) ++ "." ++ importExt) ++ ";"))

-- A native arbitrary is supplied by application code. Scaffolds describe its
-- generic signature and remain user-owned, including when support is compact.
generatorStubs :: Bool -> Plan -> BindingPlan -> [Artifact] -> Either String [Artifact]
generatorStubs ts plan bindings files = do
  let representations = bindingRepresentations bindings
      requested = filter resolvedGeneratorStub (resolvedGenerators representations)
      moduleParts = init . referenceParts . resolvedGeneratorFactory
      modules = nub (map moduleParts requested)
      ext = if ts then "ts" else "mjs"
      output parts = "test/" ++ intercalate "/" parts ++ "." ++ ext
      paths = map output modules
      equal a b = map toLower a == map toLower b
  unless (length paths == length (nub (map (map toLower) paths)) &&
    not (any (\path -> any (equal path . artifactPath) files) paths))
    (Left "web generator scaffold module conflicts with another output")
  names <- W.namesFor (planDataDeclarations plan)
  forM modules $ \parts -> do
    unless (not (null parts)) (Left "web generator scaffold requires a module and export")
    let group = filter ((== parts) . moduleParts) requested
        source = concat (replicate (length parts) "../") ++ "src/"
        importExt = if ts then "js" else "mjs"
        nativeAlias i = "_lawspec_native_type_" ++ show i
        imported = ["_lawspec_fc","ls","data"] ++ map nativeAlias [0 .. length group - 1]
        importType alias file = D.text ("import type * as " ++ alias ++ " from " ++ W.q file ++ ";")
    entries <- forM (zip [0::Int ..] group) $ \(i,generator) -> do
      let factory = last (referenceParts (resolvedGeneratorFactory generator))
          parameters = [(C.Id ("scaffold::" ++ show n), "T" ++ show n) |
            n <- [0 .. generatorParameterCount generator - 1]]
          ty = C.Constructor (C.idText (resolvedGeneratorType generator))
            [C.TypeArgument (C.TypeVariable identity) | (identity,_) <- parameters]
          nativeReference = lookup (resolvedGeneratorType generator)
            [(C.dataId (resolvedDeclaration mapping),resolvedNativeType mapping) |
              mapping <- resolvedTypes representations]
      unless (factory /= "globalThis" && (not ts || factory `notElem` imported))
        (Left "web generator scaffold factory conflicts with a signature dependency")
      (imports,result) <- case nativeReference of
        Just (NativeRef ref) -> do
          unless (length ref >= 2) (Left "web native type references require a module and export")
          mapM_ (W.identifier True) ref
          pure ([D.text ("import type {" ++ last ref ++ " as " ++ nativeAlias i ++ "} from " ++
            W.q (source ++ intercalate "/" (init ref) ++ "." ++ importExt) ++ ";")],
            W.application (nativeAlias i) [D.text name | (_,name) <- parameters])
        Nothing -> do
          result <- W.typeDoc "data." names parameters ty
          pure ([],result)
      let generics = if ts && not (null parameters) then D.delimit 4 "<" ">"
            [D.text name | (_,name) <- parameters] else mempty
          arguments = [D.text ("argument_" ++ show n) <>
            (if ts then D.text ": " <> W.application "_lawspec_fc.Arbitrary" [D.text name] else mempty) |
            (n,(_,name)) <- zip [0::Int ..] parameters]
          signature = D.text ("export function " ++ factory) <> generics <>
            D.delimitTrailing 4 "(" ")" arguments <>
            (if ts then D.text ": " <> W.application "_lawspec_fc.Arbitrary" [result] else mempty)
          resultLabel = maybe (C.idText (resolvedGeneratorType generator))
            (intercalate "." . referenceParts) nativeReference
          body = D.text ("// Native result: " ++ resultLabel) <> D.hardline <>
            signature <> D.text " " <> D.block 2 (D.text "throw " <> E.call "new globalThis.Error"
            [E.quoted ("Implement generator for " ++ C.idText (resolvedGeneratorType generator))] <> D.text ";")
      pure (imports,body)
    let header = D.text "// User-owned native generator factories. Implement before running properties."
        imports = if ts then [importType "_lawspec_fc" "fast-check",
          importType "ls" (source ++ "lawspec_runtime.js"),
          importType "data" (source ++ "lawspec_data.js")] ++ concatMap fst entries else []
    pure (Artifact (output parts) (D.render (D.Pretty 80)
      (D.joinWith D.hardline (header:imports) <> D.hardline <> D.hardline <>
       D.joinWith (D.hardline <> D.hardline) (map snd entries) <> D.hardline)) "user" "test")

-- The web strategies' schema import, rewritten to the emitted layout.
schemaImport :: String
schemaImport = "import {RefinementViolation, witnessed, witnessInstances} from './lawspec_schema.mjs';"
