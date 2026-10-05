-- Checked bridges in application packages, with compiler-resolved call names.
module LawSpec.GoNativeBinding (preparePlan, emitBindings) where

import Control.Monad (forM, unless)
import Data.Char (toUpper, toLower, isUpper, isAscii, isAlpha, isAlphaNum, isLower)
import Data.List (intercalate, find, nub, isPrefixOf, stripPrefix)
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Backend (unitName, inputs, inputType, functions, owner)
import LawSpec.Testing
import LawSpec.NativeBinding
import LawSpec.NativeRequest
import qualified LawSpec.GoData as G
import qualified LawSpec.GoExpr as E
import qualified LawSpec.GoDefinitions as Definitions
import qualified LawSpec.CoreNativeScalarEmit as Scalar
import qualified LawSpec.Code.Doc as D

-- Only backend spellings change. Qualified type/constructor identities and
-- propositions remain untouched, and every Go emitter sees the same spellings.
preparePlan :: BindingPlan -> Plan -> Either String Plan
preparePlan bindings plan = do
  declarations <- reserve (planDataDeclarations plan)
  pure plan {planDataDeclarations = declarations}
  where
    mappings = resolvedTypes (bindingRepresentations bindings)
    refs = map snd (bindingFunctions bindings) ++ [ref | (_,ConstructorCall ref) <- bindingCalls bindings] ++
      map resolvedGeneratorFactory (resolvedGenerators (bindingRepresentations bindings)) ++
      [ref | m <- mappings, ref <- resolvedNativeType m : map resolvedNativeConstructor (resolvedConstructors m)] ++
      [ref | m <- mappings, Just hook <- [resolvedCodec m], ref <- [codecToNative hook,codecFromNative hook]]
    nativeNames = [name | NativeRef [name] <- refs]
    folded = map toLower
    cap [] = []
    cap (x:xs) = toUpper x : xs
    reserve declarations = do
      names <- G.goGeneratedNames declarations
      families <- G.goEmittedNames declarations
      case find (any (`elem` nativeNames) . snd) families of
        Nothing -> pure declarations
        Just (clash,_) -> do
          let occupied = map folded (names ++ nativeNames)
              candidates = ["Canonical" ++ (if n == 0 then "" else show n) ++ cap (C.dataName clash) | n <- [0::Int ..]]
              family name = name : [name ++ cap (C.constructorName c) | c <- C.dataConstructors clash]
              fresh = head [name | name <- candidates, all ((`notElem` occupied) . folded) (family name)]
          reserve [if C.dataId d == C.dataId clash then d {C.dataName = fresh} else d | d <- declarations]

emitBindings :: Bool -> BindingPlan -> Plan -> [Artifact] -> Either String [Artifact]
emitBindings minify plan testing files = do
  unless (bindingRustCrate plan == Nothing) (Left "rustCrate is only valid for Rust bindings")
  unless (null mappings || not (null (bindingFunctions plan)) || not (null (bindingCalls plan)) || not (null generators))
    (Left "native types require function bindings")
  mapM_ (identifier . goImportAlias) (bindingGoImports plan)
  mapM_ identifier [method | (_,MethodCall method) <- bindingCalls plan]
  mapM_ nativeRef ([r | (_,r) <- bindingFunctions plan] ++ [r | (_,ConstructorCall r) <- bindingCalls plan] ++ [resolvedNativeType m | m <- originalMappings] ++
    [resolvedNativeConstructor c | m <- originalMappings,c <- resolvedConstructors m] ++ map resolvedGeneratorFactory originalGenerators ++
    [ref | m <- originalMappings, Just hook <- [resolvedCodec m], ref <- [codecToNative hook,codecFromNative hook]])
  mapM_ (\c -> case referenceParts (resolvedNativeConstructor c) of
    [_,_] -> mapM_ (exported . snd) (resolvedFields c)
    _ -> pure ()) [c | m <- originalMappings,c <- resolvedConstructors m]
  mapM_ (identifier . snd) [f | m <- mappings,c <- resolvedConstructors m,f <- resolvedFields c]
  let requested = filter resolvedGeneratorStub generators
      roots = [inputType input | unit <- plannedUnits testing, property <- plannedProperties unit, input <- inputs property]
  selected <- if null requested then pure [] else reachableGeneratorTypes declarations representations roots
  mapM_ (\generator -> do
    unless (length (referenceParts (resolvedGeneratorFactory generator)) == 1)
      (Left "Go generator scaffolds require package-local factories; keep imported factories import-only")
    unless (any (\case C.Constructor name _ -> C.Id name == resolvedGeneratorType generator; _ -> False) selected)
      (Left ("Go generator scaffold requires a quantified use to select its package: " ++ C.idText (resolvedGeneratorType generator)))) requested
  emitted <- fmap concat $ forM (plannedUnits testing) $ \p -> do
    let unit = plannedUnit p
        defined = map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions unit)
        adapters = [d | d <- C.unitDeclarations unit,C.declarationId d `notElem` defined]
        -- Static functions, and a handle's methods and constructors.
        bound d = lookup (C.declarationId d) ([(C.declarationId a,StaticCall (normalize r)) | (a,r) <- bindingFunctions plan] ++
          [(C.declarationId a,normalizeCall c) | (a,c) <- bindingCalls plan])
        parts = split '.' (unitName unit)
        directory = intercalate "/" parts
        package = last parts
        name d = "lawSpecBound" ++ cap (C.declarationName d)
        boundAdapters = filter (maybe False (const True) . bound) adapters
        propertyRoots = [inputType i | property <- plannedProperties p,i <- inputs property]
    concrete <- if null generators then pure [] else reachableGeneratorTypes declarations representations propertyRoots
    let usedGenerators = [g | g <- generators, any (\case C.Constructor name _ -> C.Id name == resolvedGeneratorType g; _ -> False) concrete]
    if null boundAdapters && null usedGenerators then pure [] else do
      unless (null boundAdapters || all (maybe False (const True) . bound) adapters) (Left "a Go bound unit must map every adapter")
      let roots = map C.declarationType adapters ++ propertyRoots
          needed = reachable [] roots
          usedMappings = [m | m <- mappings,C.dataId (resolvedDeclaration m) `elem` needed]
          callNames = [(C.declarationId d,name d) | d <- boundAdapters]
      generatedNames <- G.goGeneratedNames declarations
      let nativeNames = [n | m <- usedMappings, NativeRef [n] <- resolvedNativeType m : map resolvedNativeConstructor (resolvedConstructors m)]
      emittedNames <- concatMap snd <$> G.goEmittedNames declarations
      unless (all (`notElem` emittedNames) nativeNames)
        (Left "package-local Go native names collide with canonical data; rename the LawSpec declaration or use a distinct native name")
      bodies <- forM boundAdapters $ \d -> do
        let (args,result) = C.functionType (C.declarationType d)
            Just call = bound d
            unit = C.scalarType "Unit"
        types <- mapM (G.goDataType declarations) args
        resultType <- G.goDataType declarations result
        canonical <- mapM (G.goCodecWithContext "symbols" declarations) args
        native <- mapM (G.goNativeCodec declarations usedMappings) args
        canonicalResult <- G.goCodecWithContext "symbols" declarations result
        nativeResult <- G.goNativeCodec declarations usedMappings result
        let values = [D.text ("value" ++ show i) | i <- [0::Int ..length args-1]]
            converted = [E.call (n ++ ".toNative") [E.call (c ++ ".fromNative") [v]] |
              (n,c,v) <- zip3 native canonical values]
            function ref = do
              let application = intercalate "." (referenceParts ref)
              unless (application `notElem` map snd callNames) (Left "native function shadows generated Go bridge")
              pure application
        invocation <- case call of
          StaticCall ref -> (\application -> E.call application converted) <$> function ref
          -- A constructor takes the adapter's arguments but its Units.
          ConstructorCall ref -> (\application -> E.call application [v | (t,v) <- zip args converted, t /= unit]) <$> function ref
          -- A method is called on the first handle argument, with the rest.
          MethodCall method -> case [i | (i,t) <- zip [0::Int ..] args, isHandle t] of
            receiver : _ -> do
              unless (any ((== handleId (args !! receiver)) . Just . C.dataId . resolvedDeclaration) usedMappings)
                (Left (C.idText (C.declarationId d) ++ ": a Go method binding needs its handle bound to a native type"))
              pure (D.text "(" <> converted !! receiver <> D.text (")." ++ method) <>
                E.call "" [v | (i,v) <- zip [0::Int ..] converted, i /= receiver])
            [] -> Left (C.idText (C.declarationId d) ++ ": a method binding needs a handle argument")
        -- A function form's Maybe result is nil for Nothing, anything else Just.
        nativeMaybe <- case (call,result) of
          (StaticCall _,_) -> pure Nothing
          (_,C.Constructor "Maybe" [C.TypeArgument inner]) -> Just <$> G.goNativeTypeWithParameters declarations usedMappings [] inner
          _ -> pure Nothing
        -- An async bridge is a task that awaits the native task and converts its
        -- result; a constructor is called at once, and its task is already done.
        let async = C.declarationAsync d
            constructor = case call of ConstructorCall _ -> True; _ -> False
            awaited = if async && not constructor then invocation <> D.text ".Await()" else invocation
            nativeValue = maybe awaited (\inner -> E.call ("lsNativeMaybe[" ++ inner ++ "]") [awaited]) nativeMaybe
            body = if result == unit then awaited <> D.hardline <> D.text "return LawSpecUnit{}"
              else D.text "return " <> E.call (canonicalResult ++ ".toNative") [E.call (nativeResult ++ ".fromNative") [nativeValue]]
            bridge = E.call "lsNativeContext" [E.quoted ("native binding " ++ C.idText (C.declarationId d)),
              D.text ("func() " ++ resultType ++ " ") <> D.block 8 body]
            resultStatement
              | async && constructor = D.text "done := " <> bridge <> D.hardline <>
                  D.text ("return LawSpecGo(func() " ++ resultType ++ " { return done })")
              | async = D.text ("return LawSpecGo(func() " ++ resultType ++ " ") <> D.block 8 (D.text "return " <> bridge) <> D.text ")"
              | otherwise = (if result == C.scalarType "Unit" then D.text "_ = " else D.text "return ") <> bridge
        pure (D.text "func " <> E.call (name d) [v <> D.text (" " ++ t) | (t,v) <- zip types values] <>
          D.text (if async then " LawSpecTask[" ++ resultType ++ "] " else if result == C.scalarType "Unit" then " " else " " ++ resultType ++ " ") <> D.block 8
          (D.text "schema := lawSpecDataSchemaRegistry()" <> D.hardline <>
           D.text ("bits := " ++ show bits) <> D.hardline <>
           D.text "symbols := map[string]*lawSpecSymbol{}" <> D.hardline <>
           D.text "_, _, _ = schema, bits, symbols" <> D.hardline <> resultStatement))
      codecs <- G.emitGoNativeCodecs layout package
        (importsFor ([resolvedNativeType m | m <- usedMappings] ++
          [resolvedNativeConstructor c | m <- usedMappings,c <- resolvedConstructors m] ++
          [ref | m <- usedMappings, Just hook <- [resolvedCodec m], ref <- [codecToNative hook,codecFromNative hook]])) declarations usedMappings needed
      generatorFiles <- if null usedGenerators then pure [] else do
        methods <- forM (zip [0::Int ..] usedGenerators) $ \(index,generator) -> do
          branches <- forM [ty | ty@(C.Constructor family _) <- concrete, C.Id family == resolvedGeneratorType generator] $ \ty -> do
            let arguments = case ty of C.Constructor _ args -> [t | C.TypeArgument t <- args]; _ -> []
            children <- forM (zip [0::Int ..] arguments) $ \(i,child) -> do
              codec <- G.goNativeCodec declarations usedMappings child
              pure (D.text ("child" ++ show i ++ " := ") <> E.call "lsNativeGeneratorArguments"
                [D.text codec,D.text ("arguments[" ++ show i ++ "]")])
            codec <- G.goNativeCodec declarations usedMappings ty
            ref <- G.goTypeReference ty
            pure (D.text ("if reference.key() == " ++ ref ++ ".key() ") <> D.block 8
              (D.joinWith D.hardline (children ++
                [D.text "source := " <> E.call (intercalate "." (referenceParts (resolvedGeneratorFactory generator)))
                  [D.text ("child" ++ show i) | i <- [0..length arguments-1]],
                 D.text "return " <> E.call "lsNativeGeneratorValues" [D.text codec,D.text "source"]])))
          pure (D.text ("func lawSpecNativeFactory" ++ show index ++ "(schema *lawSpecSchema, reference lawSpecTypeRef, bits int, symbols map[string]*lawSpecSymbol, arguments []*rapid.Generator[LawSpecValue]) *rapid.Generator[LawSpecValue] ") <>
            D.block 8 (D.joinWith D.hardline (branches ++
              [D.text "panic(\"unplanned native generator instantiation: \" + reference.key())"])))
        let registry = D.text "func lawSpecNativeFactories() map[string]lawSpecNativeFactory " <>
              D.block 8 (D.joinWith D.hardline
                ([D.text "factories := map[string]lawSpecNativeFactory{}"] ++
                 [D.text "factories[" <> E.quoted (C.idText (resolvedGeneratorType g)) <>
                   D.text ("] = lawSpecNativeFactory" ++ show i) | (i,g) <- zip [0::Int ..] usedGenerators] ++
                 [D.text "return factories"]))
            source = D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
              D.text ("package " ++ package) <> D.hardline <> D.hardline <>
              D.text "import \"pgregory.net/rapid\"" <> D.hardline <> D.hardline <>
              importDocs (map resolvedGeneratorFactory usedGenerators) <>
              D.joinWith (D.hardline <> D.hardline) (registry:methods) <> D.hardline
        stubs <- generatorStubs directory package
          (generatedNames ++ [cap (C.declarationName d) | d <- adapters, bound d == Nothing])
          usedMappings [r | d <- boundAdapters, Just r <- [bound d >>= callRef]] usedGenerators
        pure (Artifact (directory ++ "/lawspec_native_generators_test.go") (D.render layout source) "generated" "test" : stubs)
      ordinary <- either (Left . show) Right $
        Scalar.nativeScalarEmitWithAdapterBindings callNames (not (null usedGenerators)) minify declarations
          (Definitions.definitionCalls (map plannedUnit (plannedUnits testing))) bits "go" unit (plannedProperties p)
      -- Orchestrations call the bridges too.
      definitions <- Definitions.emitGoDefinitionsWithCalls callNames layout bits declarations
        (filter (\u -> not (null (functions u)) || any ((== unitName u) . owner) laws) units)
      let bridge = Artifact (directory ++ "/adapter.go") (D.render layout
            (D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
             D.text ("package " ++ package) <> D.hardline <> D.hardline <>
             importDocs [r | d <- boundAdapters,Just r <- [bound d >>= callRef]] <>
             D.joinWith (D.hardline <> D.hardline) bodies <> D.hardline)) "generated" "source"
          support = Artifact (directory ++ "/lawspec_native_codecs.go") codecs "generated" "source"
      unless (all ((/= artifactPath support) . artifactPath) files) (Left "unit shadows Go native codec support")
      let ownDefinitions = [f | f <- definitions, artifactPath f == directory ++ "/lawspec_definitions.go", not (null boundAdapters)]
      pure ([bridge | not (null boundAdapters)] ++ [support] ++ generatorFiles ++ ownDefinitions ++
        [f | f <- ordinary,null boundAdapters || artifactPath f /= artifactPath bridge])
  pure ([f | f <- files,artifactPath f `notElem` map artifactPath emitted] ++ emitted)
  where
    declarations = planDataDeclarations testing
    units = map plannedUnit (plannedUnits testing)
    laws = concatMap plannedProperties (plannedUnits testing)
    bits = planMachineBits testing
    representations = bindingRepresentations plan
    originalMappings = resolvedTypes representations
    originalGenerators = resolvedGenerators representations
    mappings = [m {resolvedNativeType = normalize (resolvedNativeType m),
      resolvedCodec = (\hook -> hook {codecToNative = normalize (codecToNative hook),
        codecFromNative = normalize (codecFromNative hook)}) <$> resolvedCodec m,
      resolvedConstructors = [c {resolvedNativeConstructor = normalize (resolvedNativeConstructor c)} |
        c <- resolvedConstructors m]} | m <- originalMappings]
    generators = [g {resolvedGeneratorFactory = normalize (resolvedGeneratorFactory g)} | g <- originalGenerators]
    aliases = [(goImportAlias entry,("lawSpecImport" ++ show index,goImportPath entry)) |
      (index,entry) <- zip [0::Int ..] (bindingGoImports plan)]
    normalize (NativeRef [alias,name]) = case lookup alias aliases of
      Just (internal,_) -> NativeRef [internal,name]
      Nothing -> NativeRef [alias,name]
    normalize ref = ref
    normalizeCall (StaticCall ref) = StaticCall (normalize ref)
    normalizeCall (ConstructorCall ref) = ConstructorCall (normalize ref)
    normalizeCall call = call
    callRef (StaticCall ref) = Just ref
    callRef (ConstructorCall ref) = Just ref
    callRef (MethodCall _) = Nothing
    handleId ty = case ty of
      C.Constructor name [] | Just d <- find ((== C.Id name) . C.dataId) declarations, C.dataHandle d -> Just (C.dataId d)
      _ -> Nothing
    isHandle = maybe False (const True) . handleId
    importsFor refs = nub [(alias,path) | NativeRef [alias,_] <- refs,
      (_, (internal,path)) <- aliases, alias == internal]
    importDocs refs = D.joinWith D.hardline
      [D.text ("import " ++ alias ++ " ") <> E.quoted path | (alias,path) <- importsFor refs] <>
      (if null (importsFor refs) then mempty else D.hardline <> D.hardline)
    layout = D.selectLayout minify (D.PrettyTabs 100)
    split c s = case break (==c) s of (a,[]) -> [a]; (a,_:b) -> a:split c b
    cap [] = []; cap (a:rest) = toUpper a:rest
    identifier n = do
      unless (case n of
        c:cs -> isAscii c && (isAlpha c || c == '_') && n /= "_" && all (\x -> isAscii x && (isAlphaNum x || x == '_')) cs
        [] -> False) (Left ("invalid Go native identifier: " ++ n))
      unless (n `notElem` words "break default func interface select case defer go map struct chan else goto package switch const fallthrough if range type continue for import return var")
        (Left ("reserved Go native identifier: " ++ n))
    nativeRef (NativeRef [n]) = identifier n
    nativeRef (NativeRef [alias,name]) = do
      identifier alias
      exported name
      unless (alias `elem` map goImportAlias (bindingGoImports plan))
        (Left ("unknown Go import alias: " ++ alias))
    nativeRef _ = Left "Go native references require a local identifier or an import alias and exported identifier"
    exported name = do
      identifier name
      unless (isUpper (head name)) (Left ("external Go native identifier must be exported: " ++ name))
    generatorStubs directory package generatedNames scopedMappings boundRefs used = do
      let requested = filter resolvedGeneratorStub used
          applicationNames = [name | NativeRef [name] <- boundRefs ++
            [ref | m <- scopedMappings, ref <- resolvedNativeType m : map resolvedNativeConstructor (resolvedConstructors m)] ++
            [ref | m <- scopedMappings, Just hook <- [resolvedCodec m], ref <- [codecToNative hook,codecFromNative hook]]]
          builtin = words "any comparable bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr append cap clear close complex copy delete imag len make max min new panic print println real recover true false iota nil init main rapid fmt math big rand reflect strconv strings utf8 flag sync testing"
          testName name = any (\prefix -> case stripPrefix prefix name of
            Just [] -> True
            Just (first:_) -> not (isLower first)
            Nothing -> False) ["Test","Benchmark","Fuzz","Example"]
          nativeReferences = [resolvedNativeType m | generator <- requested, m <- mappings,
            C.dataId (resolvedDeclaration m) == resolvedGeneratorType generator]
      if null requested then pure [] else do
        bodies <- forM requested $ \generator -> do
          let name = head (referenceParts (resolvedGeneratorFactory generator))
          unless (name `notElem` (builtin ++ applicationNames ++ generatedNames) && not (testName name) &&
            not (any (`isPrefixOf` name) ["LawSpec","lawSpec","ls","_lawspec","_lawSpec"]))
            (Left ("Go generator scaffold factory conflicts with an application or generated identifier: " ++ name))
          let occupied = name : applicationNames ++ generatedNames
              parameterNames = take (generatorParameterCount generator)
                [candidate | i <- [0::Int ..], let candidate = "T" ++ show i, candidate `notElem` occupied]
              parameters = [(C.Id ("scaffold::" ++ show i),parameter) | (i,parameter) <- zip [0::Int ..] parameterNames]
              ty = C.Constructor (C.idText (resolvedGeneratorType generator))
                [C.TypeArgument (C.TypeVariable identity) | (identity,_) <- parameters]
              generic = if null parameters then "" else "[" ++ intercalate ", " [p ++ " any" | (_,p) <- parameters] ++ "]"
          native <- G.goNativeTypeWithParameters declarations mappings parameters ty
          pure (D.text "func " <> E.call (name ++ generic)
            [D.text ("argument" ++ show i ++ " *rapid.Generator[" ++ p ++ "]") | (i,(_,p)) <- zip [0::Int ..] parameters] <>
            D.text (" *rapid.Generator[" ++ native ++ "] ") <> D.block 8
              (E.call "panic" [E.quoted ("Implement generator for " ++ C.idText (resolvedGeneratorType generator))]))
        pure [Artifact (directory ++ "/native_generators_test.go") (D.render (D.PrettyTabs 100)
          (D.text "// User-owned native generator factories. Implement before running properties." <> D.hardline <>
           D.text ("package " ++ package) <> D.hardline <> D.hardline <>
           D.text "import \"pgregory.net/rapid\"" <> D.hardline <> D.hardline <>
           importDocs nativeReferences <> D.joinWith (D.hardline <> D.hardline) bodies <> D.hardline)) "user" "test"]
    reachable seen [] = seen
    reachable seen (ty:rest) = case ty of
      C.Arrow a b -> reachable seen (a:b:rest)
      C.Constructor n args ->
        let children = [t | C.TypeArgument t <- args]
        in case find ((== C.Id n) . C.dataId) declarations of
          Just d | C.dataId d `notElem` seen -> reachable (C.dataId d:seen)
            (children ++ [C.binderType f | c <- C.dataConstructors d,f <- C.constructorFields c] ++ rest)
          _ -> reachable seen (children ++ rest)
      _ -> reachable seen rest
