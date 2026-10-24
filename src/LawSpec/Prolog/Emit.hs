-- | Prolog adapters and PLUnit slots over the checked Python emitter.
-- Metadata comes from Core, not from parsing generated Python source.
-- ref:DEC-prolog-janus
module LawSpec.Prolog.Emit (prologFromPython, prologFromPythonWithLayout, prologFromPythonWithBindings) where

import Control.Monad (forM, unless)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy as B
import Data.List (intercalate, nubBy, nub, isSuffixOf, isPrefixOf, stripPrefix)
import Data.Char (isAlphaNum, isAscii, toLower)
import Data.Maybe (isJust)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified LawSpec.Core as C
import LawSpec.Core.DefinitionContracts (validateNativeEmissionDefinitions)
import LawSpec.Common (Artifact(..), Diagnostic(..), pythonUnitFile)
import LawSpec.Naming (Casing(..), cased, claimAll, displayLabel, escapeKeyword, nameWords, reservedFor, scopeWith)
import LawSpec.SourceLink (generatedHeader, labelled, locationLink, sourceLink, unitSourceFile)
import LawSpec.PythonTypes (pythonTypeReferenceDoc, pythonLayout)
import qualified LawSpec.PythonExpr as E
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.PythonData as Data
import LawSpec.AbilityNames (ownAbilities, ownedAbilityUnits, productionName)
import LawSpec.Builtins (defaultedUnits)
import LawSpec.TestManifest (TestEntry(..), BenchmarkEntry(..), testManifestWithModelChecks, executableEntries, benchmarkManifest)
import LawSpec.BuiltinDefaults (vectorTestPath)
import LawSpec.Testing (Plan(..), PlannedUnit(..))
import LawSpec.RuntimeSources (runtimeSource)
import qualified LawSpec.NativeRequest as NB
import qualified LawSpec.NativeBinding as Binding
import qualified LawSpec.PythonNativeBinding as PythonBinding

-- | Host generation and runtime tests alone never register a public compiler
-- target. Unintegrated execution fragments remain explicit diagnostics.
prologFromPython :: Plan -> [Artifact] -> Either [Diagnostic] [Artifact]
prologFromPython = prologFromPythonWithLayout Nothing Nothing

prologFromPythonWithLayout :: Maybe String -> Maybe String -> Plan -> [Artifact] -> Either [Diagnostic] [Artifact]
prologFromPythonWithLayout sourceDir testDir = prologFromPythonWithBindings sourceDir testDir NB.emptyBindingPlan

prologFromPythonWithBindings :: Maybe String -> Maybe String -> NB.BindingPlan -> Plan -> [Artifact] -> Either [Diagnostic] [Artifact]
prologFromPythonWithBindings sourceDir testDir bindings plan input = do
  host <- withGenerators bindings plan input
  prologFromPreparedPython sourceDir testDir bindings plan host

prologFromPreparedPython :: Maybe String -> Maybe String -> NB.BindingPlan -> Plan -> [Artifact] -> Either [Diagnostic] [Artifact]
prologFromPreparedPython sourceDir testDir bindings plan input = do
  either (Left . pure . (\message -> Diagnostic "total" message Nothing)) Right
    (validateNativeEmissionDefinitions bits datas units)
  unless (length moduleNames == length (nub moduleNames))
    (unsupported "Prolog module identity collision")
  unless (bindings {NB.bindingFunctions=[], NB.bindingCalls=[], NB.bindingHandlers=[], NB.bindingFailures=[],
      NB.bindingRepresentations=Binding.ResolvedBindings [] []} == NB.emptyBindingPlan &&
      all ((==Nothing) . Binding.resolvedCodec) nativeTypes &&
      all ((==Nothing) . Binding.resolvedArguments) nativeTypes)
    (Left [Diagnostic "native-binding" "Prolog native codec hooks and foreign target settings are not integrated" Nothing])
  unless (length nativeIdentities == length (nub nativeIdentities))
    (Left [Diagnostic "native-binding" "Prolog native constructor and handle identities must be distinct across the project" Nothing])
  mapM_ (nativeReference . Binding.resolvedNativeType) nativeTypes
  unless (safe src && safe tst)
    (Left [Diagnostic "layout" "output directories must be relative paths without traversal" Nothing])
  unless (all availableUnit units)
    (Left [Diagnostic "native-name-collision" "an application unit uses a reserved generated Prolog/Python support namespace" Nothing])
  unique input
  schemas <- checked (Data.emitPythonDataWithProfile bits pythonLayout datas)
  bridges <- concat <$> mapM unitArtifacts units
  registry <- models
  let replaced = map artifactPath bridges
      retained = [file | file <- python, artifactPath file `notElem` replaced]
      existing = map artifactPath (retained ++ bridges)
      support = [generated (src ++ "/" ++ file) (runtimeSource key) "source" |
        (file,key) <- [("lawspec_prolog.py","prolog-python"),
                      ("lawspec_prolog.pl","prolog"),
                      ("lawspec_prolog_tests.py","prolog-tests")]]
      cases = map slotMetadata slots
      runner = generated "lawspec_test.py" (unlines
        ["# " ++ generatedHeader specFile, "import sys", "from pathlib import Path", "",
         pyLine 0 (call "sys.path.insert" [D.text "0", call "str" [D.text "Path(__file__).parent / " <> q src]]),
         "from lawspec_prolog_tests import main", "", "raise SystemExit(main())"]) "root"
      outputs = retained ++ bridges ++ [file | file <- map move schemas, artifactPath file `notElem` existing] ++
        support ++ testArtifacts ++ [registry, runner, generated "lawspec-prolog-tests.json"
          (T.unpack (T.decodeUtf8 (B.toStrict (encode cases))) ++ "\n") "root"]
  unique outputs
  pure outputs
  where
    bits = planMachineBits plan
    datas = planDataDeclarations plan
    units = ownedAbilityUnits (map plannedUnit (plannedUnits plan))
    nativeTypes = Binding.resolvedTypes (NB.bindingRepresentations bindings)
    nativeConstructors = concatMap Binding.resolvedConstructors nativeTypes
    handleBindings = [(C.idText (C.dataId (Binding.resolvedDeclaration t)), Binding.resolvedNativeType t) |
      t <- nativeTypes, C.dataHandle (Binding.resolvedDeclaration t)]
    nativeName = intercalate "." . Binding.referenceParts
    nativeIdentities = map (nativeName . Binding.resolvedNativeConstructor) nativeConstructors ++
      map (nativeName . snd) handleBindings
    layoutNode (Binding.NativeLeaf _ index) = array [q "leaf", number index]
    layoutNode (Binding.NativeRecord _ constructor children) = array
      [q "record", q (C.idText (C.constructorId constructor)), array (map layoutNode children)]
    bindingMetadata = if null nativeIdentities && null (NB.bindingFailures bindings) then D.text "None" else array
      [array [array [q (C.idText (C.constructorId (Binding.resolvedConstructor c))),
        q (nativeName (Binding.resolvedNativeConstructor c)), q (style (Binding.resolvedConstructorStyle c)),
        array [q name | (_,name) <- Binding.resolvedFields c],
        array (maybe [array [q "leaf", number index] | index <- [0::Int .. length (Binding.resolvedFields c)-1]]
          (map layoutNode) (Binding.resolvedFieldLayout c))] | c <- nativeConstructors],
       array [array [q ty, q (nativeName native)] | (ty,native) <- handleBindings],
       array [array [q (intercalate "." (C.failureNative f)), q (C.idText (C.failureConstructor f)),
         maybe (array []) failurePayload (C.failurePayload f)] | f <- NB.bindingFailures bindings]]
    style Binding.RecordConstructor = "record"
    style Binding.VariantConstructor = "variant"
    style Binding.UnitConstructor = "unit"
    failurePayload C.ExceptionMessage = array [q "message"]
    failurePayload (C.MessageProduct _ constructor child) = array
      [q "record", q (C.idText constructor), failurePayload child]
    src = maybe "src" id sourceDir
    tst = maybe "tests" id testDir
    split text = case break (=='/') text of (a,[]) -> [a]; (a,_:rest) -> a:split rest
    safe text = not (null text) && all (\p -> p /= "." && p /= ".." && not (null p) && all (\c -> isAlphaNum c || c `elem` ("_-" :: String)) p) (split text)
    relocate old new text = maybe text ((new ++ "/") ++) (stripPrefix (old ++ "/") text)
    move file = file {artifactPath = case artifactPlacement file of
      "source" -> relocate "src" src (artifactPath file)
      "test" -> relocate "tests" tst (artifactPath file)
      _ -> artifactPath file}
    python = map move input
    unique files = unless (length files == length (nub (map (map toLower . artifactPath) files)))
      (Left [Diagnostic "collision" "Prolog project artifacts share an output path" Nothing])
    availableUnit u = all (\reserved -> owner u /= reserved && not ((reserved ++ ".") `isPrefixOf` owner u))
      ["lawspec_runtime","lawspec_data","lawspec_schema","lawspec_prolog","lawspec_prolog_models",
       "lawspec_prolog_tests","lawspec_definition_bodies","lawspec_abilities","lawspec_definitions",
       "lawspec_models","lawspec_typed","lawspec_fast","lawspec_native","lawspec_prolog_generators"]
    names = map owner units
    checked :: Either String a -> Either [Diagnostic] a
    checked = either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right
    unsupported message = Left [Diagnostic "target-unsupported" message Nothing]
    ref = checked . pythonTypeReferenceDoc
    refs ts = array <$> mapM ref ts
    generated path content place = Artifact path content "generated" place
    owner = C.idText . C.unitId
    -- A unit's module is named after it (example.slug is example_slug), as
    -- SWI-Prolog modules are; a name SWI-Prolog's own libraries use gets a
    -- trailing underscore. Its model module adds _model.
    moduleId u = let name = cased Snake (case nameWords (owner u) of [] -> ["unit"]; ws -> ws)
                 in if name `elem` systemModules then name ++ "_" else name
    moduleNames = concat [[moduleId u, moduleId u ++ "_model"] | u <- units]
    entries = nubBy (\a b -> entryFile a == entryFile b && entryName a == entryName b)
      (executableEntries plan (testManifestWithModelChecks (planModelChecks plan) "python" (Just tst)
        (C.Program bits datas units)))
    benchmarks = benchmarkManifest "python" (Just tst) (C.Program bits datas units)
    slots = [(entryFile e,entryName e,isJust (entryKind e),"test") | e <- entries] ++
      [(benchmarkFile e,benchmarkTest e,True,"benchmark") | e <- benchmarks] ++
      [(relocate "tests" tst path,"support_crypto_known_answers",False,"support") |
        Just path <- [vectorTestPath "python"], path `elem` map artifactPath input]
    testFile host = if ".py" `isSuffixOf` host then take (length host-3) host ++ ".pl" else host ++ ".pl"
    -- A test unit is named after its host test file.
    testUnits = zip hosts (fst (claimAll (scopeWith []) [cased Snake (case nameWords (baseName host) of [] -> ["tests"]; ws -> ws) | host <- hosts]))
    hosts = nub [file | (file,_,_,_) <- slots]
    baseName path = takeWhile (/= '.') (reverse (takeWhile (/= '/') (reverse path)))
    testUnit host = maybe "tests" id (lookup host testUnits)
    lawLink name = case [(displayLabel (C.propertyName p), locationLink (C.propertyLocation p)) |
        e <- entries, entryName e == name, u <- units, p <- C.unitProperties u, C.propertyId p == entryLaw e,
        not (null (fileOf (C.propertyLocation p)))] of
      (label, link) : _ -> [comment (labelled label (Just link))]
      [] -> []
    fileOf location = takeWhile (/= ':') (locationLink location)
    slotMetadata (host,name,exact,kind) = object
      ["file" .= testFile host, "name" .= name, "unit" .= testUnit host,
       "hostFile" .= host, "selection" .= (if kind=="support" then "" else name ++ "__"),
       "exact" .= exact, "kind" .= (kind :: String)]
    -- PLUnit slots over the checked host cases, one per case.
    testArtifacts = [generated (testFile host) (prologFile (
      [ [comment (generatedHeader specFile)]
      , [directive (Compound "use_module" [Compound "library" [Atom "plunit"]]),
         directive (Compound "use_module" [Compound "library" [Atom "janus"]])]
      , [directive (Compound "begin_tests" [Atom (testUnit host)])] ] ++
      [ lawLink name ++ [clause (Compound "test" [Atom name]) (Just (Compound "py_call"
          [Infix ":" (Atom "lawspec_prolog_tests") (Compound "run_case" [Atom (testFile host ++ "::" ++ name)]),
           Compound "@" [Atom "true"]]))]
      | (file,name,_,_) <- slots, file == host ] ++
      [[directive (Compound "end_tests" [Atom (testUnit host)])]])) "test" | host <- hosts]
    indented line = if null line then line else "    " ++ line
    linkComment d = ["    # " ++ labelled (C.declarationName d) (Just l) | Just l <- [sourceLink (C.declarationOrigin d)]]
    specFile = case nub [f | u <- units, Just f <- [unitSourceFile u]] of [one] -> Just one; _ -> Nothing
    handlers d = filter (not . C.isFail) (C.declarationUses d)
    failures d = mapM failure [a | a <- C.declarationUses d, C.isFail a]
    failure a = case C.abilityRefArguments a of
      [ty] -> do
        t <- ref ty
        pure (q (C.abilityKey a), t)
      _ -> unsupported "Prolog failures require a concrete payload type"
    failEntry Nothing = pure (D.text "None")
    failEntry (Just a) = do
      (key,ty) <- failure a
      pure (tuple [key,ty])
    operationMap nativePredicate a = do
      entries <- forM (C.abilityOperations a) $ \(name,ty) -> do
        let (args,result) = C.functionType ty
        inputs <- refs args
        output <- ref result
        failing <- failEntry (lookup name (C.abilityFailures a))
        pure (q name <> D.text ": " <> tuple
          ([q (make name) | Just make <- [nativePredicate]] ++ [inputs,output,failing]))
      pure (dictionary entries)
    constructorPredicate a = "handler_" ++ productionName a ++ "_new"
    operationPredicate a name = "handler_" ++ productionName a ++ "_" ++ name
    -- A qualified module still cannot redefine protected system predicates
    -- such as close/2. A uniform prefix also avoids arity-specific escaping.
    predicate d = "ls_" ++ C.declarationName d
    functionBinding d = lookup (C.declarationId d)
      ([(C.declarationId declaration,NB.StaticCall native) | (declaration,native) <- NB.bindingFunctions bindings] ++
       [(C.declarationId declaration,binding) | (declaration,binding) <- NB.bindingCalls bindings])
    boundHandle ty = case ty of C.Constructor name [] -> lookup name handleBindings; _ -> Nothing
    handlePosition d = case [index | (index,ty) <- zip [0::Int ..] (fst (C.functionType (C.declarationType d))),
        C.Constructor name [] <- [ty], any (\declaration -> C.idText (C.dataId declaration)==name && C.dataHandle declaration) datas] of
      index:_ -> pure index
      [] -> Left [Diagnostic "native-binding" "Prolog method binding requires a handle argument" Nothing]
    nativeFunction d = case functionBinding d of
      Nothing -> pure Nothing
      Just (NB.StaticCall native) -> Just <$> nativeReference native
      Just (NB.ConstructorCall native) -> do
        unless (isJust (boundHandle (snd (C.functionType (C.declarationType d)))))
          (Left [Diagnostic "native-binding" "Prolog constructor binding requires a native type binding for its returned handle" Nothing])
        Just <$> nativeReference native
      Just (NB.MethodCall name) -> do
        index <- handlePosition d
        let ty = fst (C.functionType (C.declarationType d)) !! index
        native <- maybe (Left [Diagnostic "native-binding" "Prolog method binding requires a native type binding for its receiver" Nothing]) pure (boundHandle ty)
        (m,_,file) <- nativeReference native
        pure (Just (m,name,file))
    argumentOrder d = case functionBinding d of
      Just (NB.ConstructorCall _) -> pure (array [number i | (i,ty) <- zip [0::Int ..] args, ty /= C.scalarType "Unit"])
      Just (NB.MethodCall _) -> do
        index <- handlePosition d
        pure (array (map number (index : [i | i <- [0..length args-1], i /= index])))
      _ -> pure (D.text "None")
      where args = fst (C.functionType (C.declarationType d))
    handlerBinding a = lookup (C.Id (C.abilityKey (C.abilityInstance a))) (NB.bindingHandlers bindings)
    nativeReference native = case Binding.referenceParts native of
      parts@(_:_:_) -> pure (intercalate "." (init parts), last parts, intercalate "/" (init parts) ++ ".pl")
      _ -> Left [Diagnostic "native-binding" "Prolog references require module path components followed by a predicate" Nothing]
    constructorReference u a = maybe (pure (moduleId u,constructorPredicate a,Nothing))
      (\native -> do (m,n,file) <- nativeReference native; pure (m,n,Just file)) (handlerBinding a)
    productionAbilities u = [a | a <- ownAbilities u, not (C.isFail (C.abilityInstance a)),
      owner u `notElem` defaultedUnits || handlerBinding a /= Nothing]
    adapterArity d = length (handlers d) + length (fst (C.functionType (C.declarationType d))) + 1
    -- A model's variables: its handlers, then its parameters by their source
    -- names (amount is Amount).
    modelParameters definition = fst (claimAll (scopeWith ["Context", "Result"])
      (["Handler" | _ <- handlers (C.definitionDeclaration definition)] ++
       [cased Pascal (case nameWords (C.binderName b) of [] -> ["value"]; ws -> ws) | b <- C.definitionArguments definition]))
    unitArtifacts u = do
      let definitions = map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions u)
          adapters = [d | d <- C.unitDeclarations u, C.declarationId d `notElem` definitions,
            owner u `notElem` defaultedUnits || functionBinding d /= Nothing]
          productions = productionAbilities u
          relativePython = pythonUnitFile names (owner u)
          relativeProlog = map (\c -> if c=='.' then '/' else c) (owner u) ++ ".pl"
          path = src ++ "/" ++ relativePython
          prologPath = src ++ "/" ++ relativeProlog
          modelRelative = "lawspec_models/" ++ relativeProlog
          modelPath = src ++ "/" ++ modelRelative
      nativeFunctions <- mapM nativeFunction adapters
      nativeConstructors <- mapM (constructorReference u) productions
      let defaultNeeded = any (==Nothing) nativeFunctions || any (\(_,_,file) -> file == Nothing) nativeConstructors
          loadFiles = nub ([relativeProlog | defaultNeeded] ++ [file | Just (_,_,file) <- nativeFunctions] ++
            [file | (_,_,Just file) <- nativeConstructors])
          pythonHeader = map indented ["from pathlib import Path", "",
            "import lawspec_data as _data", "import lawspec_prolog as _bridge",
            "import lawspec_prolog_models as _models", "import lawspec_schema as _schema", "",
            "_schema_value = _data.make_schema()"] ++
            [ pyLine 4 (call "_bridge.load_module" [call "str" [D.operation [D.text ("Path(__file__).resolve().parents[" ++
                show (length (filter (=='/') relativePython)) ++ "]"), q file] ["/"]]]) | file <- loadFiles]
      -- The factory's functions and classes are named after the definitions
      -- and handlers they bridge.
      let (localNames, _) = claimAll (scopeWith (["Path", "_bridge", "_models", "_data", "_schema", "_schema_value"] ++ reservedFor "python"))
            (map (escapeKeyword "python" . C.declarationName) adapters ++ map (escapeKeyword "python" . productionName) productions)
          functionNames = take (length adapters) localNames
          classNames = drop (length adapters) localNames
      functions <- forM (zip3 functionNames adapters nativeFunctions) $ \(localName,d,native) -> do
        let (args,result) = C.functionType (C.declarationType d)
            parameters = ["value" ++ show i | i <- [0::Int .. length args-1]]
            hs = ["handler" ++ show i | i <- [0::Int .. length (handlers d)-1]]
            proxies = [call "_models.handler" [q (C.abilityKey a), D.text h] | (a,h) <- zip (handlers d) hs]
        inputs <- refs args
        output <- ref result
        fs <- failures d
        order <- argumentOrder d
        let unkeyed = case fs of [(_,ty)] -> ty; _ -> D.text "None"
        let (nativeModule,nativeFunction) = maybe (moduleId u,predicate d) (\(m,n,_) -> (m,n)) native
            bridged = call "_bridge.call" [D.text "_schema_value", number bits, q nativeModule,
              q nativeFunction, inputs, output, array (map D.text parameters),
              D.text "failure_type=" <> unkeyed, D.text "handlers=" <> array proxies,
              D.text "failure_abilities=" <> array (map (\(key,ty) -> tuple [key,ty]) fs),
              D.text "bindings=_models.native_bindings", D.text "argument_order=" <> order]
        pure (linkComment d ++
          [pyLine 4 (D.text ((if C.declarationAsync d then "async def " else "def ") ++ localName) <>
             D.delimitTrailing 4 "(" ")" (map D.text (hs ++ parameters)) <> D.text ":"),
           pyLine 8 (D.text "return " <> (if C.declarationAsync d
             then D.text "await " <> call "_bridge.call_async" [E.lambdaExpression [] bridged] else bridged))])
      classes <- forM (zip3 classNames productions nativeConstructors) $ \(className,a,(nativeModule,constructor,_)) -> do
        types <- refs (maybe [] pure (C.abilityResource a))
        operations <- operationMap (Just (case handlerBinding a of
          Nothing -> operationPredicate a
          Just _ -> (\name -> constructor ++ "_" ++ name))) a
        let parameters = ["resource" | C.abilityResource a /= Nothing]
        pure ["    class " ++ className ++ "(_bridge.Production):",
          "        def __init__(self" ++ concatMap (", " ++) parameters ++ "):",
          pyLine 12 (call "_bridge.Production.__init__" [D.text "self", D.text "_schema_value", number bits,
            q nativeModule, q constructor, types, array (map D.text parameters), operations,
            D.text "bindings=_models.native_bindings"])]
      let adapterExports = [(predicate d,adapterArity d) | d <- adapters, functionBinding d == Nothing]
          productionExports = concat
            [ (constructorPredicate a, (if C.abilityResource a == Nothing then 0 else 1)+1) :
              [(operationPredicate a name,length (fst (C.functionType ty))+2) | (name,ty) <- C.abilityOperations a]
            | a <- productions, handlerBinding a == Nothing ]
          header comments name exported imports =
            [ map comment comments
            , [moduleDirective name [Infix "/" (Atom n) (Int arity) | (n,arity) <- exported],
               directive (Compound "use_module" [Compound "library" [Atom "janus"]])] ++
              [directive (Compound "use_module" [Atom i]) | i <- imports] ]
          links = [(predicate d, C.declarationName d, sourceLink (C.declarationOrigin d)) | d <- adapters ++ modelDeclarations]
          linkFor name = [comment (labelled label (Just l)) | (n,label,Just l) <- links, n == name]
          stub (name,arity) = linkFor name ++ [clause (Compound name (replicate arity (Var "_")))
            (Just (Compound "throw" [Compound "error" [Compound "not_implemented" [Atom (owner u ++ "::" ++ name)], Var "_"]]))]
          stubs = prologFile (header ["User-owned LawSpec adapter for " ++ owner u ++ maybe "" (" from " ++) (unitSourceFile u) ++ "."]
              (moduleId u) (adapterExports ++ productionExports) [] ++
            map stub (adapterExports ++ productionExports))
          modelDefinitions = C.unitDefinitions u
          modelDeclarations = map C.definitionDeclaration modelDefinitions
          modelExports = concat [[(predicate d,adapterArity d),(predicate d,adapterArity d+1)] | d <- modelDeclarations]
          model = prologFile (header [generatedHeader (unitSourceFile u)] (moduleId u ++ "_model") modelExports
              [replicatePath modelRelative ++ "lawspec_prolog.pl"] ++
              [ let d = C.definitionDeclaration definition
                    parameters = map Var (modelParameters definition)
                    identity = Atom (C.idText (C.declarationId d))
                in linkFor (predicate d) ++
                   [clause (Compound (predicate d) (parameters ++ [Var "Result"]))
                      (Just (Infix ":" (Atom "lawspec_prolog") (Compound "model" [identity, List parameters, Var "Result"]))),
                    clause (Compound (predicate d) (Var "Context" : parameters ++ [Var "Result"]))
                      (Just (Infix ":" (Atom "lawspec_prolog") (Compound "model" [Var "Context", identity, List parameters, Var "Result"])))]
                | definition <- modelDefinitions])
          publicNames = map C.declarationName adapters ++ map productionName productions
          factory = head ["_make_lawspec_bindings" ++ replicate i '_' | i <- [0::Int ..],
            "_make_lawspec_bindings" ++ replicate i '_' `notElem` publicNames]
          exports = [q (C.declarationName d) <> D.text (": " ++ name) | (name,d) <- zip functionNames adapters] ++
            [q (productionName a) <> D.text (": " ++ name) | (name,a) <- zip classNames productions]
          inherited = concat [artifactContent file | owner u `elem` defaultedUnits,
            file <- python, artifactPath file == path]
          -- The bridge is built in a function, so its imports never meet the
          -- names of the unit's own definitions.
          host = (if null inherited then "# " ++ generatedHeader (unitSourceFile u) ++ "\n" else inherited ++ "\n\n") ++
            unlines (["# The Prolog bridge for " ++ owner u ++ ", from checked Core. ref:DEC-prolog-janus",
              "def " ++ factory ++ "():"] ++
              intercalate [""] (pythonHeader : functions ++ classes) ++ [""] ++
                [pyLine 4 (D.text "return " <> dictionary exports)] ++
              ["", "", "globals().update(" ++ factory ++ "())", "del " ++ factory])
      let hostAdapter = any (\file -> artifactPath file == path && ownership file == "user") python
      pure ((if null adapters && null productions && not hostAdapter then [] else
        [generated path host "source"] ++
        [AdapterArtifact prologPath stubs "user" "source" stubs | defaultNeeded]) ++
        [generated modelPath model "source" | not (null modelDeclarations)])
    -- Every user module is under src; the runtime is at its root.
    replicatePath path = concat (replicate (length (filter (=='/') path)) "../")
    models = do
      entries <- concat <$> forM units (\u -> forM (C.unitDefinitions u) (\definition -> do
        let d = C.definitionDeclaration definition
            (args,result) = C.functionType (C.declarationType d)
        inputs <- refs args
        output <- ref result
        fs <- failures d
        pure (q (C.idText (C.declarationId d)) <> D.text ": " <> tuple
          [q ("lawspec_definitions." ++ owner u), q (C.declarationName d),
           array (map (q . C.abilityKey) (handlers d)), inputs, output,
           dictionary [key <> D.text ": " <> ty | (key,ty) <- fs]])))
      let abilities = nubBy (\a b -> C.abilityInstance a == C.abilityInstance b)
            [a | u <- units, a <- C.unitAbilities u, not (C.isFail (C.abilityInstance a))]
      abilityEntries <- forM abilities $ \a -> do
        operations <- operationMap Nothing a
        pure (q (C.abilityKey (C.abilityInstance a)) <> D.text ": " <> operations)
      pure (generated (src ++ "/lawspec_prolog_models.py") (unlines
        (["# " ++ generatedHeader specFile,
          "\"\"\"Checked models the Prolog bridge calls: each definition's module, name,",
          "handlers and types, and each ability's operations. ref:DEC-prolog-janus\"\"\"", "",
          "import importlib", "", "import lawspec_data as data", "import lawspec_prolog as bridge",
          "import lawspec_runtime as ls", "import lawspec_schema as _schema", "",
          "MACHINE_BITS = " ++ show bits,
          pyLine 0 (D.text "native_bindings = " <> bindingMetadata),
          "_schema_value = data.make_schema()",
          pyLine 0 (D.text "_abilities = " <> dictionary abilityEntries),
          pyLine 0 (D.text "_models = " <> dictionary entries)] ++ modelFunctions)) "source")
    -- The models module's fixed functions, as ruff format lays them out.
    modelFunctions =
      [ "", ""
      , "def handler(identity, native):"
      , "    if isinstance(native, bridge.Handler):"
      , "        if native.ability != identity:"
      , "            raise TypeError(\"wrong Prolog ability identity\")"
      , "        return native"
      , "    return bridge.Handler("
      , "        _schema_value, MACHINE_BITS, identity, native, _abilities[identity]"
      , "    )"
      , "", ""
      , "def invoke(identity, packed, symbols=None):"
      , "    module, name, abilities, types, result_type, failures = _models[identity]"
      , "    if len(abilities) + len(types) != len(packed):"
      , "        raise TypeError(\"wrong checked model arity\")"
      , "    if symbols is None:"
      , "        symbols = {}"
      , "    if type(symbols) is not dict:"
      , "        raise TypeError(\"checked model context must be a dict\")"
      , "    native_handlers = []"
      , "    for ability, value in zip(abilities, packed):"
      , "        proxy = bridge.unpack(value)"
      , "        if not isinstance(proxy, bridge.Handler) or proxy.ability != ability:"
      , "            raise TypeError(\"wrong checked model handler identity\")"
      , "        native_handlers.append(proxy.native)"
      , "    values = ["
      , "        _schema_value.to_native(ty, bridge.unpack(value), MACHINE_BITS, symbols)"
      , "        for ty, value in zip(types, packed[len(abilities) :])"
      , "    ]"
      , "    try:"
      , "        result = getattr(importlib.import_module(module), name)("
      , "            symbols, *native_handlers, *values"
      , "        )"
      , "    except ls.Failure as error:"
      , "        if error.ability not in failures:"
      , "            raise ValueError("
      , "                \"checked model raised an undeclared failure ability\""
      , "            ) from error"
      , "        ty = failures[error.ability]"
      , "        value = _schema_value.validate(ty, error.value, MACHINE_BITS, symbols)"
      , "        return [\"ability_failure\", error.ability, bridge.pack(value, _schema_value, ty)]"
      , "    logical = _schema_value.from_native(result_type, result, MACHINE_BITS, symbols)"
      , "    return [\"ok\", bridge.pack(logical, _schema_value, result_type)]" ]

------------------------------------------------------------------------------
-- Python, as ruff format lays it out

-- | A call on one line; else its arguments on one indented line; else one
-- per line with a trailing comma, as ruff format (and black) split calls.
call :: String -> [D.Doc] -> D.Doc
call name [] = D.text (name ++ "()")
call name args = D.text name <> D.group (D.text "(" <> D.nest 4 (D.softbreak <>
  D.group (D.commaSep (map D.argument args) <> D.whenBroken (D.text ","))) <> D.softbreak <> D.text ")")

-- | A collection on one line, else one item per line with a trailing comma;
-- a single item without a comma is split like a call's arguments.
array, tuple, dictionary :: [D.Doc] -> D.Doc
array = collection "[" "]"
dictionary = collection "{" "}"
tuple [single] = D.group (D.text "(" <> D.nest 4 (D.softbreak <> single <> D.text ",") <> D.softbreak <> D.text ")")
tuple items = collection "(" ")" items

collection :: String -> String -> [D.Doc] -> D.Doc
collection open close [single] = D.group (D.text open <> D.nest 4 (D.softbreak <> single) <> D.softbreak <> D.text close)
collection open close items = D.delimitTrailing 4 open close items

q :: String -> D.Doc
q = E.quoted

number :: Int -> D.Doc
number = D.text . show

-- | A statement at an indentation, laid out at ruff's 88 columns.
pyLine :: Int -> D.Doc -> String
pyLine indentation doc = D.render pythonLayout (D.text (replicate indentation ' ') <> D.nest indentation doc)

-- Reuse the Python target's checked native-generator traversal and shrinking.
-- The Prolog factory constructs a genuine Hypothesis strategy through Janus;
-- it receives child strategies and never samples from a private random engine.
withGenerators :: NB.BindingPlan -> Plan -> [Artifact] -> Either [Diagnostic] [Artifact]
withGenerators bindings plan files
  | null generators = pure files
  | otherwise = do
      references <- mapM reference generators
      -- Each factory is named after the Prolog predicate it calls.
      let factories = fst (claimAll (scopeWith (["Path", "bridge"] ++ reservedFor "python"))
            [escapeKeyword "python" ("factory_" ++ name) | (_,name,_) <- references])
          hostBindings = NB.emptyBindingPlan {NB.bindingRepresentations=Binding.ResolvedBindings []
            [generator {Binding.resolvedGeneratorFactory=Binding.NativeRef ["lawspec_prolog_generators",factory],
              Binding.resolvedGeneratorStub=False} | (factory,generator) <- zip factories generators]}
          helper = unlines (["# Generated by LawSpec. Do not edit. ref:DEC-prolog-janus", "from pathlib import Path", "",
            "import lawspec_prolog as bridge", ""] ++
            [pyLine 0 (call "bridge.load_module" [call "str" [D.operation [D.text "Path(__file__).parent", q file] ["/"]]]) |
              file <- nub [file | (_,_,file) <- references]] ++ concat
            [["", "", pyLine 0 (D.text ("def " ++ factory) <> D.delimitTrailing 4 "(" ")" (map D.text parameters) <> D.text ":"),
              pyLine 4 (D.text "return " <> call "bridge.generator_factory" [q nativeModule, q name, array (map D.text parameters)])] |
              (factory,(generator,(nativeModule,name,_))) <- zip factories (zip generators references),
              let parameters=["child" ++ show n | n <- [0..Binding.generatorParameterCount generator-1]]])
          stubs = [AdapterArtifact ("tests/" ++ file) (stub nativeModule file) "user" "test" (stub nativeModule file) |
            (nativeModule,file) <- nub [(m,file) | (generator,(m,_,file)) <- zip generators references, Binding.resolvedGeneratorStub generator]]
          stub nativeModule file = prologFile
            ([[comment "User-owned Hypothesis strategy factories. ref:DEC-prolog-janus"],
              [moduleDirective nativeModule [Infix "/" (Atom name) (Int arity) | (name,arity) <- predicates],
               directive (Compound "use_module" [Compound "library" [Atom "janus"]])]] ++
             [[clause (Compound name (replicate arity (Var "_")))
                (Just (Compound "throw" [Compound "error" [Compound "not_implemented" [Atom name], Var "_"]]))]
             | (name,arity) <- predicates])
            where
              matches=[(generator,m,n) | (generator,(m,n,f)) <- zip generators references, f==file]
              predicates=nub [(n,Binding.generatorParameterCount generator+1) | (generator,_,n) <- matches]
      generated <- either (Left . pure . (\message -> Diagnostic "native-binding" message Nothing)) Right
        (PythonBinding.emitBindings False hostBindings plan files)
      pure (generated ++ [Artifact "tests/lawspec_prolog_generators.py" helper "generated" "test"] ++ stubs)
  where
    generators=Binding.resolvedGenerators (NB.bindingRepresentations bindings)
    reference generator = case Binding.referenceParts (Binding.resolvedGeneratorFactory generator) of
      parts@(_:_:_) -> pure (intercalate "." (init parts),last parts,intercalate "/" (init parts) ++ ".pl")
      _ -> Left [Diagnostic "native-binding" "Prolog generator references require module path components followed by a predicate" Nothing]

------------------------------------------------------------------------------
-- SWI-Prolog layout

-- | The Prolog terms generated files use, printed as SWI-Prolog's
-- portray_clause/2 (library(listing)) prints them: its conventional layout,
-- checked by tools/prolog-layout.pl. ref:DEC-readable-artifacts
data Term = Atom String | Var String | Int Int | Compound String [Term] | List [Term] | Infix String Term Term

-- | A file of paragraphs (comments and clauses), separated by blank lines.
prologFile :: [[String]] -> String
prologFile paragraphs = unlines (intercalate [""] (filter (not . null) paragraphs))

comment :: String -> String
comment text = "% " ++ text

clause :: Term -> Maybe Term -> String
clause hd Nothing = pprint 0 hd ++ "."
clause hd (Just body) = pprint 0 hd ++ " :-\n    " ++ pprint 4 body ++ "."

directive :: Term -> String
directive goal = ":- " ++ pprint 3 goal ++ "."

-- | portray_clause always writes a module's export list one per line.
moduleDirective :: String -> [Term] -> String
moduleDirective name exports = ":- module(" ++ atom name ++ ",\n" ++ replicate 10 ' ' ++ list ++ ")."
  where
    list = if null exports then "[]" else "[ " ++ intercalate (",\n" ++ replicate 12 ' ') (map (pprint 12) exports) ++
      "\n" ++ replicate 10 ' ' ++ "]"

-- | A term on one line, as writeq with spaces after argument commas.
flatTerm :: Term -> String
flatTerm term = case term of
  Atom a -> atom a
  Var v -> v
  Int n -> show n
  Compound f args -> atom f ++ "(" ++ intercalate ", " (map flatTerm args) ++ ")"
  List items -> "[" ++ intercalate ", " (map flatTerm items) ++ "]"
  Infix op a b -> flatTerm a ++ op ++ flatTerm b

-- | listing's pprint: a compound or list starting at a column is wrapped,
-- one argument per line, when it passes the 78-column line width and is
-- longer than a quarter of it; a term longer than the width counts as the
-- width. Operator terms are never wrapped. The length is write_length/3's
-- with default options: atoms unquoted, no space after commas, and a
-- variable (bound to '$VAR'(Name) by portray_clause) as $VAR(Name).
pprint :: Int -> Term -> String
pprint column term
  | wrappable && column + measured > lineWidth && 4 * measured > lineWidth = wrapped
  | otherwise = flatTerm term
  where
    lineWidth = 78
    measured = min lineWidth (writeLength term)
    wrappable = case term of
      Compound _ (_:_) -> True
      List (_:_) -> True
      _ -> False
    wrapped = case term of
      List items -> "[ " ++ intercalate (",\n" ++ replicate (column + 2) ' ') (map (pprint (column + 2)) items) ++
        "\n" ++ replicate column ' ' ++ "]"
      Compound f args -> let inner = column + length (atom f) + 1
        in atom f ++ "(" ++ intercalate (",\n" ++ replicate inner ' ') (map (pprint inner) args) ++ ")"
      _ -> flatTerm term

-- | write_length/3 of a term with default write options.
writeLength :: Term -> Int
writeLength term = case term of
  Atom a -> length a
  Var v -> length v + 6
  Int n -> length (show n)
  Compound f args -> length f + 1 + commas args + 1
  List items -> 1 + commas items + 1
  Infix op a b -> writeLength a + length op + writeLength b
  where commas items = sum (map writeLength items) + max 0 (length items - 1)

-- | An atom as writeq writes it: plain when it is a lowercase identifier or
-- made of symbol characters, otherwise quoted.
atom :: String -> String
atom text
  | plain = text
  | otherwise = "'" ++ concatMap escape text ++ "'"
  where
    plain = case text of
      c : rest -> (c >= 'a' && c <= 'z' && all (\x -> isAscii x && (isAlphaNum x || x == '_')) rest) ||
        all (`elem` ("#$&*+-./:<=>?@^~\\" :: String)) text && text `notElem` [".", "/*"] && not ("/*" `isPrefixOf` text)
      [] -> False
    escape '\\' = "\\\\"
    escape '\'' = "\\'"
    escape '\n' = "\\n"
    escape '\t' = "\\t"
    escape c = [c]

-- | Module names SWI-Prolog's system and libraries use.
systemModules :: [String]
systemModules = words "user system prolog lists apply error debug option pairs janus plunit listing \
  \strings readutil aggregate yall ordsets assoc dicts solution_sequences"
