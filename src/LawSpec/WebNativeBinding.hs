-- | Application bridges share the checked JS/TS schema and native arbitraries.
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
import qualified LawSpec.Code.ECMAScript as E
import LawSpec.WebModule (printWebModule)
import qualified LawSpec.Code.Doc as D
import LawSpec.RuntimeSources (runtimeSource)

-- | Bound adapters call the user's JavaScript and TypeScript code directly,
-- through generated conversions. ref:DEC-native-bindings-typed-identity
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
  let entries = [E.Array [E.Str (C.idText (C.constructorId (resolvedConstructor c))),
        E.Object ([E.Prop (E.KName "native") (E.Ident (alias (resolvedNativeConstructor c))),
          E.Prop (E.KName "fields") (E.Array [E.Str n | (_,n) <- resolvedFields c])] ++
          [E.Prop (E.KName "paths") (E.Array [E.Array (map E.Str path') | path' <- paths]) |
            Just paths <- [resolvedFieldPaths c]])] |
        m <- mappings, c <- resolvedConstructors m]
      hooks = [E.Array [E.Str (C.idText (C.dataId (resolvedDeclaration m))),
        E.Object [E.Prop (E.KName "native") (E.Ident (alias (resolvedNativeType m))),
          E.Prop (E.KName "toNative") (E.Ident (alias (codecToNative hook))),
          E.Prop (E.KName "fromNative") (E.Ident (alias (codecFromNative hook)))]] |
        m <- mappings, Just hook <- [resolvedCodec m]]
      functionT = E.TRef "Function" []
      hookType = [E.TKeyword "string", E.TObject [("native", False, functionT), ("toNative", False, functionT), ("fromNative", False, functionT)]]
      mapType = [E.TKeyword "string", E.TObject ([("native", False, functionT), ("fields", False, E.TArray (E.TKeyword "string"))] ++
        [("paths", True, E.TArray (E.TArray (E.TKeyword "string"))) | any ((/=Nothing) . resolvedFieldPaths) (concatMap resolvedConstructors mappings)])]
      newMap types items = E.New (E.Ident "Map") (if ts then types else []) [E.Array items]
      supportBody = sourceImports "./" ++ imports ++
        [ E.Blank
        , exported' (E.constDecl "canonical" (E.call "data.makeSchema" []))
        , exported' (E.constDecl "native" (E.method (E.Ident "canonical") "withNativeBindings" [newMap mapType entries, newMap hookType hooks]))
        , E.Comment ["// Handlers are application code: their values are the bound types."]
        , E.ExprStmt (E.call "ls.setHandlerSchema" [E.Ident "native"]) ] ++
        [E.ExportNamed [(n, Nothing) | n <- exported] Nothing | not (null exported)]
      exported' stmt = case stmt of
        E.VarDecl k p t v -> E.VarDecl ("export " ++ k) p t v
        _ -> stmt
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
        handleTypes = [(C.dataId (resolvedDeclaration m), E.TRef ("bridge." ++ alias (resolvedNativeType m)) []) |
          m <- mappings, C.dataHandle (resolvedDeclaration m)]
        typeOf = Data.webDataTypeOfWith (planDataDeclarations plan) handleTypes
        depth = length (filter (== '.') (unitName unit))
        root = if depth == 0 then "./" else concat (replicate depth "../")
    if not (any (maybe False (const True) . bound) adapters) then pure [] else do
      unless (all (maybe False (const True) . bound) adapters) (Left "a web bound unit must map every adapter")
      bodies <- forM adapters $ \decl -> do
        let (args,result) = C.functionType (C.declarationType decl)
        argTypes <- mapM typeOf args
        resultType <- typeOf result
        argRefs <- mapM Data.webTypeReference args
        resultRef <- Data.webTypeReference result
        let values = ["value" ++ show i | i <- [0::Int ..length args-1]]
            -- An adapter that uses abilities gets their handlers first, as
            -- they are: application code's handlers take the bound types.
            handlerNames = ["handler" ++ show i | (i, a) <- zip [0::Int ..] (C.declarationUses decl), not (C.isFail a)]
            bits = E.num (toInteger (planMachineBits plan))
            convert schema method' ty value = E.call ("bridge." ++ schema ++ "." ++ method') [ty,value,bits,E.Ident "symbols"]
            arguments = [convert "native" "toNative" ty (convert "canonical" "fromNative" ty (E.Ident value)) | (ty,value) <- zip argRefs values]
            isUnit ty = ty == C.scalarType "Unit"
            resultOf ref value = convert "canonical" "toNative" ref (convert "native" "fromNative" ref value)
            returned = E.ret (resultOf resultRef (E.Ident "result"))
        call <- maybe (Left "unbound adapter") Right (bound decl)
        application <- case call of
          StaticCall ref -> pure (E.call ("bridge." ++ alias ref) (map E.Ident handlerNames ++ arguments))
          -- A method of the first handle argument, given the others.
          MethodCall name' -> case [i | (i,ty) <- zip [0::Int ..] args, isHandle ty] of
            h : _ -> pure (E.method (arguments !! h) name' [value | (i,value) <- zip [0..] arguments, i /= h])
            [] -> Left ("method binding " ++ C.idText (C.declarationId decl) ++ " has no handle argument")
          -- A native constructor, given the arguments that are not Unit.
          ConstructorCall ref -> pure (E.new' ("bridge." ++ alias ref)
            [value | (ty,value) <- zip args arguments, not (isUnit ty)])
        -- An async adapter's native returns a Promise; a constructor's result
        -- is ready at once.
        let application' = case call of
              ConstructorCall _ -> application
              _ | C.declarationAsync decl -> E.Await application
              _ -> application
        resultBody <- case (call, result) of
          _ | isUnit result -> pure [E.ExprStmt application']
          (StaticCall _, _) -> pure [E.constDecl "result" application', returned]
          -- A method or constructor's absent value (null or undefined) is Nothing.
          (_, C.Constructor "Maybe" [C.TypeArgument element]) -> do
            elementRef <- Data.webTypeReference element
            pure [ E.constDecl "result" application'
                 , E.ret (E.Conditional (E.or' (E.Binary "===" (E.Ident "result") E.Null) (E.Binary "===" (E.Ident "result") (E.Ident "undefined")))
                     (E.new' "data.Absent" []) (E.new' "data.Present" [resultOf elementRef (E.Ident "result")])) ]
          _ -> pure [E.constDecl "result" application', returned]
        let async = C.declarationAsync decl
            returnType = if result == C.scalarType "Unit" then E.TKeyword "void" else resultType
            params = [(E.param h) { E.paramType = if ts then Just (E.TKeyword "any") else Nothing } | h <- handlerNames] ++
              [(E.param value) { E.paramType = if ts then Just ty else Nothing } | (value,ty) <- zip values argTypes]
        pure [E.FunctionDecl True async (C.declarationName decl) [] params
          (if ts then Just (if async then E.TRef "Promise" [returnType] else returnType) else Nothing)
          [ E.constDecl "symbols" (E.new' "Map" [])
          , E.Try resultBody (Just (Just (E.PIdent "error"),
              -- The application's own errors pass through, so lawspec.edn can map
              -- them to failures.
              [ E.IfSingle (E.notE (E.or' (E.Binary "instanceof" (E.Ident "error") (E.Ident "TypeError"))
                                          (E.Binary "instanceof" (E.Ident "error") (E.Ident "RangeError")))) (E.Throw (E.Ident "error"))
              , E.Throw (E.new' "TypeError" [E.Binary "+" (E.Str ("native binding " ++ C.idText (C.declarationId decl) ++ ": ")) (E.call "String" [E.Ident "error"]),
                  E.Object [E.Prop (E.KName "cause") (E.Ident "error")]]) ])) Nothing ]]
      let pathname = "src/" ++ map (\c -> if c == '.' then '/' else c) (unitName unit) ++ "." ++ ext
          header = sourceImports root ++ [E.ImportDecl False (E.ImportNamespace "bridge") (root ++ "lawspec_native." ++ importExt)]
      pure [Artifact pathname (render (header ++ concatMap (E.Blank :) bodies)) "generated" "source"]
  dataFiles <- if any ((== "src/lawspec_data." ++ ext) . artifactPath) files then pure []
    else Data.emitWebDataWithProfile ts (planMachineBits plan) layout (planDataDeclarations plan)
  generatorFiles <- if null generators then pure [] else do
    imports' <- forM (zip [0::Int ..] generators) $ \(i,generator) ->
      nativeImport "./" ("factory" ++ show i) (resolvedGeneratorFactory generator)
    let factoryType = [E.TKeyword "string", E.TFunction [(E.param "args") { E.paramType = Just (E.TArray (E.TKeyword "any")), E.paramRest = True }] (E.TRef "fc.Arbitrary" [E.TKeyword "any"])]
        factories = E.constDecl "factories" (E.New (E.Ident "Map") (if ts then factoryType else [])
          [E.Array [E.Array [E.Str (C.idText (resolvedGeneratorType g)), E.Ident ("factory" ++ show i)] | (i,g) <- zip [0::Int ..] generators]])
        typedParam n t = (E.param n) { E.paramType = if ts then Just t else Nothing }
        defaulted n t d = (typedParam n t) { E.paramDefault = Just d }
        anyT = E.TKeyword "any"
        wrapper = E.FunctionDecl True False "strategy" []
          [ typedParam "schema" anyT, typedParam "reference" anyT, typedParam "bits" (E.TKeyword "number"), typedParam "budget" (E.TKeyword "number")
          , typedParam "scalar" anyT, (E.param "symbols") { E.paramDefault = Just (E.new' "Map" []) }
          , defaulted "witnesses" (E.TArray anyT) (E.Array []), (E.param "maxAttempts") { E.paramDefault = Just (E.num 1000) }
          , defaulted "index" anyT E.Null ] Nothing
          [E.ret (E.Call (if ts then E.As (E.Ident "baseStrategy") (E.TFunction [(E.param "args") { E.paramType = Just (E.TArray anyT), E.paramRest = True }] (E.TRef "fc.Arbitrary" [anyT])) else E.Ident "baseStrategy") []
            (map E.Ident ["schema", "reference", "bits", "budget", "scalar", "symbols", "witnesses", "maxAttempts", "factories", "bridge.native", "index"]) False)]
        header = [ E.Comment ["// Generated by LawSpec. Do not edit."]
                 , E.ImportDecl False (E.ImportNamespace "fc") "fast-check"
                 , E.ImportDecl False (E.ImportNamespace "bridge") ("../src/lawspec_native." ++ importExt)
                 , E.ImportDecl False (E.ImportNamed [("strategy", Just "baseStrategy")]) ("./lawspec_data_strategies." ++ importExt) ]
        helper = Artifact ("test/lawspec_native_generators." ++ ext)
          (render (header ++ imports' ++ [E.Blank, factories, E.Blank, wrapper])) "generated" "test"
    emitted <- either (Left . show) Right $ concat <$> mapM (\unit ->
      Scalar.scalarEmitWithNativeGenerators True minify (planDataDeclarations plan)
        (Definitions.definitionCalls (planDataDeclarations plan) (map plannedUnit (plannedUnits plan)))
        (planMachineBits plan) target (modelTestUnit plan (plannedUnit unit)) (plannedProperties unit))
        [unit | unit <- plannedUnits plan, not (null (plannedProperties unit))]
    pure (helper : [file | file <- emitted, artifactPlacement file == "test"] ++
      [Artifact ("test/lawspec_data_strategies." ++ ext) (Data.testStrategies ts) "generated" "test" |
        not (any ((== "test/lawspec_data_strategies." ++ ext) . artifactPath) files)])
  let replacements = map artifactPath (bridges ++ generatorFiles)
  unless (all ((/= "src/lawspec_native." ++ ext) . artifactPath) files) (Left "unit shadows generated lawspec_native support")
  let runtime = [Artifact ("src/lawspec_runtime." ++ ext) ((if ts then "// @ts-nocheck\n" else "") ++ runtimeSource "javascript") "generated" "source" |
        not (any ((== "src/lawspec_runtime." ++ ext) . artifactPath) files)]
  -- Generated code that calls handlers loads the bound types first.
  let loading file
        | Just rest <- stripPrefix' "src/lawspec_abilities/" (artifactPath file) =
            addImport (concat (replicate (1 + length (filter (== '/') rest)) "../")) file
        | artifactPath file == "src/lawspec_definition_bodies." ++ ext = addImport "./" file
        | otherwise = file
      addImport root file = file { artifactContent = unlines (concatMap (\l ->
        if take 10 l == "import * a" && "lawspec_runtime" `elem` words (map (\c -> if c `elem` ("/.'\"" :: String) then ' ' else c) l)
          then [l, "import " ++ W.q (root ++ "lawspec_native." ++ importExt) ++ ";"] else [l]) (lines (artifactContent file))) }
      stripPrefix' prefix value = if take (length prefix) value == prefix then Just (drop (length prefix) value) else Nothing
  let generated = [loading file | file <- files, artifactPath file `notElem` replacements] ++
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
    render = printWebModule layout ts
    sourceImports root = E.Comment ["// Generated by LawSpec. Do not edit."] :
      [E.ImportDecl False (E.ImportNamespace alias) (root ++ name ++ "." ++ importExt) |
        (alias,name) <- [("ls","lawspec_runtime"),("data","lawspec_data"),("schema","lawspec_schema")]]
    nativeImport root alias (NativeRef parts) = do
      unless (length parts >= 2) (Left "web native references require a module and export")
      mapM_ (W.identifier True) parts
      pure (E.ImportDecl False (E.ImportNamed [(last parts, Just alias)]) (root ++ intercalate "/" (init parts) ++ "." ++ importExt))

-- | A native arbitrary is supplied by application code. Scaffolds describe its
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
        importType alias file = E.ImportDecl True (E.ImportNamespace alias) file
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
          pure ([E.ImportDecl True (E.ImportNamed [(last ref, Just (nativeAlias i))]) (source ++ intercalate "/" (init ref) ++ "." ++ importExt)],
            E.TRef (nativeAlias i) [E.TRef n' [] | (_,n') <- parameters])
        Nothing -> do
          result <- W.typeDoc "data." names parameters ty
          pure ([],result)
      let arguments = [(E.param ("argument_" ++ show n)) { E.paramType = if ts then Just (E.TRef "_lawspec_fc.Arbitrary" [E.TRef n' []]) else Nothing } |
            (n,(_,n')) <- zip [0::Int ..] parameters]
          resultLabel = maybe (C.idText (resolvedGeneratorType generator))
            (intercalate "." . referenceParts) nativeReference
          body = [ E.Comment ["// Native result: " ++ resultLabel]
                 , E.FunctionDecl True False factory (if ts then map snd parameters else []) arguments
                     (if ts then Just (E.TRef "_lawspec_fc.Arbitrary" [result]) else Nothing)
                     [E.Throw (E.new' "globalThis.Error" [E.Str ("Implement generator for " ++ C.idText (resolvedGeneratorType generator))])] ]
      pure (imports,body)
    let header = E.Comment ["// User-owned native generator factories. Implement before running properties."]
        imports = if ts then [importType "_lawspec_fc" "fast-check",
          importType "ls" (source ++ "lawspec_runtime.js"),
          importType "data" (source ++ "lawspec_data.js")] ++ concatMap fst entries else []
    pure (Artifact (output parts) (E.printModule (if ts then E.TypeScript else E.JavaScript)
      (header : imports ++ concatMap ((E.Blank :) . snd) entries)) "user" "test")

