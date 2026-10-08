-- | Native BEAM calls and representations cross the same checked Core schema.
-- Constructor layout belongs to the native compiler, including Erlang record
-- headers and Gleam's named constructor fields.
-- ref:DEC-native-bindings-typed-identity
module LawSpec.BeamNativeBinding (emitBindings, boundEntries, hasGenerators) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.BeamCode as E
import qualified LawSpec.GleamCode as G
import qualified LawSpec.ElixirCode as X
import qualified LawSpec.BeamDefinitions as Definitions
import qualified LawSpec.BeamEffects as Effects
import qualified LawSpec.BeamAbilities as Abilities
import LawSpec.NativeBinding
import LawSpec.NativeRequest
import LawSpec.Common (Artifact(..))
import LawSpec.Testing
import LawSpec.Core.Types (freeExistentials)
import Control.Monad (forM, unless)
import Data.Char (isUpper)
import Data.List (nub, intercalate, isPrefixOf)

hasGenerators :: BindingPlan -> Bool
hasGenerators = not . null . resolvedGenerators . bindingRepresentations

boundEntries :: BindingPlan -> [(C.Id,String)]
boundEntries bindings = [(C.declarationId d,"call_" ++ show i)
  | (i,(d,_)) <- zip [0::Int ..] (calls bindings)]

calls :: BindingPlan -> [(C.Declaration,NativeCall)]
calls bindings = [(d,StaticCall ref) | (d,ref) <- bindingFunctions bindings] ++ bindingCalls bindings

emitBindings :: String -> D.Layout -> BindingPlan -> Plan -> Either String [Artifact]
emitBindings target layout bindings plan = do
  unless (bindingRustCrate bindings == Nothing) (Left "rustCrate is only valid for Rust bindings")
  unless (all ((== Nothing) . resolvedArguments) mappings) (Left "native type arguments are only valid for Kotlin handles")
  unless (null mappings || not (null (calls bindings)) || not (null generators) || not (null (bindingHandlers bindings)))
    (Left "native types require function, handler or generator bindings")
  forM_Units $ \unit -> do
    let defined = map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions unit)
        adapters = [C.declarationId d | d <- C.unitDeclarations unit, C.declarationId d `notElem` defined]
        bound = map fst (boundEntries bindings)
    unless (not (any (`elem` bound) adapters) || all (`elem` bound) adapters)
      (Left "a BEAM bound unit must map every adapter")
    unless (not (any (`elem` bound) adapters) || null (Abilities.productionAbilities unit))
      (Left "a BEAM bound unit must also map its production handlers")
  unless (target /= "erlang" || not (null (bindingErlangIncludes bindings)) ||
    all ((/= RecordConstructor) . resolvedConstructorStyle . snd) constructors)
    (Left "Erlang record bindings need erlangIncludes naming their header files")
  shapes <- forM (zip [0::Int ..] constructors) $ \(i,(mapping,constructor)) -> do
    shape <- nativeShape i mapping constructor
    pure (E.binary (C.idText (C.constructorId (resolvedConstructor constructor))),shape)
  hooks <- forM [(m,h) | m <- mappings, Just h <- [resolvedCodec m]] $ \(mapping,hook) -> do
    let parameters = [D.text ("_Child" ++ show i) | (i,_) <- zip [0::Int ..] (C.dataParameters (resolvedDeclaration mapping))]
        method ref = do
          body <- nativeCall target ref (D.text "_Value" : parameters)
          pure (E.lambda [D.text "_Value",E.array parameters] body)
    encode <- method (codecToNative hook)
    decode <- method (codecFromNative hook)
    pure (E.binary (C.idText (C.dataId (resolvedDeclaration mapping))),
      E.record [(E.atom "encode",encode),(E.atom "decode",decode)])
  functions <- mapM bridge (calls bindings)
  gleam <- if target == "gleam" && not (null constructors) then pure <$> gleamConstructors else pure []
  factories <- if null generators then pure [] else generatorFiles
  stubs <- generatorStubs
  let headers = [D.text (if erlangIncludeLibrary header then "-include_lib(" else "-include(") <>
        E.string (erlangIncludePath header) <> D.text ")." | header <- bindingErlangIncludes bindings] ++
        [D.text "-compile(nowarn_unused_record)." | not (null (bindingErlangIncludes bindings))]
      factory = E.function "schema" [D.text "_Canonical"] [E.remote "lawspec_beam_schema" "with_bindings"
        [D.text "_Canonical",E.record shapes,E.record hooks]]
      exports = ("schema",1) : [(name,2 + length (fst (C.functionType (C.declarationType d))))
        | (d,_) <- calls bindings, Just name <- [lookup (C.declarationId d) (boundEntries bindings)]]
  pure (Artifact "src/lawspec_native_bindings.erl"
    (D.render layout (E.moduleDoc "lawspec_native_bindings" exports (headers ++ factory : functions)))
    "generated" "source" : gleam ++ factories ++ stubs)
  where
    units = map plannedUnit (plannedUnits plan)
    mappings = resolvedTypes (bindingRepresentations bindings)
    generators = resolvedGenerators (bindingRepresentations bindings)
    constructors = [(m,c) | m <- mappings, c <- resolvedConstructors m]
    testSupport = case target of "elixir" -> "test/support/"; "gleam" -> "test-support/src/"; _ -> "test/"
    generatorFiles = do
      factories <- forM generators $ \g -> do
        let variables = [D.text ("_Child" ++ show i) | i <- [0..generatorParameterCount g - 1]]
        body <- nativeCall target (resolvedGeneratorFactory g) variables
        pure (E.binary (C.idText (resolvedGeneratorType g)),E.lambda [E.array variables] body)
      let schema = E.function "schema" [D.text "_Canonical"] [E.remote "lawspec_beam_generators" "with_native"
            [D.text "_Canonical",E.remote "lawspec_native_bindings" "schema" [D.text "_Canonical"],E.record factories]]
      pure [Artifact (testSupport ++ "lawspec_native_generators.erl")
        (D.render layout (E.moduleDoc "lawspec_native_generators" [("schema",1)] [schema])) "generated" "test"]
    generatorStubs = do
      names <- E.dataNames (planDataDeclarations plan)
      let requested = filter resolvedGeneratorStub generators
          modules = nub [init (referenceParts (resolvedGeneratorFactory g)) | g <- requested]
          productionRefs = [ref | (_,call) <- calls bindings, ref <- case call of StaticCall r -> [r]; ConstructorCall r -> [r]; _ -> []] ++
            map resolvedNativeType mappings ++ [ref | m <- mappings, Just hook <- [resolvedCodec m], ref <- [codecToNative hook,codecFromNative hook]]
          productionModules = map (init . referenceParts) productionRefs
      forM modules $ \parts -> do
        let group = [g | g <- requested, init (referenceParts (resolvedGeneratorFactory g)) == parts]
            path = case target of
              "elixir" -> "test/support/" ++ intercalate "_" (map E.snake parts) ++ ".ex"
              "gleam" -> "test/" ++ intercalate "/" parts ++ ".gleam"
              _ -> "test/" ++ intercalate "." parts ++ ".erl"
            moduleName = case target of
              "elixir" -> "Elixir." ++ intercalate "." parts
              "gleam" -> intercalate "@" parts
              _ -> intercalate "." parts
        unless (not (null parts) && parts `notElem` productionModules &&
          not (any (`isPrefixOf` moduleName) ["lawspec", "Elixir.LawSpec"]) &&
          moduleName `notElem` map (E.nativeModule target . plannedUnit) (plannedUnits plan))
          (Left "BEAM generator scaffold module conflicts with a production or generated module")
        let nativeModules = nub [init (referenceParts (resolvedNativeType m)) | g <- group, m <- mappings,
              C.dataId (resolvedDeclaration m) == resolvedGeneratorType g]
            nativeAliases = zip nativeModules ["native_" ++ show i | i <- [0::Int ..]]
        bodies <- forM group $ \g -> do
          let name = last (referenceParts (resolvedGeneratorFactory g))
              parameters = [(C.Id ("a" ++ show i),"a" ++ show i) | i <- [0..generatorParameterCount g - 1]]
              ty = C.Constructor (C.idText (resolvedGeneratorType g)) [C.TypeArgument (C.TypeVariable identity) | (identity,_) <- parameters]
              native = [m | m <- mappings, C.dataId (resolvedDeclaration m) == resolvedGeneratorType g]
              message = "Implement generator for " ++ C.idText (resolvedGeneratorType g)
          _ <- nativeCall target (resolvedGeneratorFactory g) []
          case target of
            "erlang" -> pure ([], [D.text "-spec " <> E.call name (replicate (length parameters) (D.text "proper_types:raw_type()")) <>
                D.text " -> proper_types:raw_type().",
              E.function name [D.text ("_Child" ++ show i) | i <- [0..length parameters-1]]
                [E.remote "erlang" "error" [E.tuple [E.atom "not_implemented",E.binary message]]]])
            "elixir" -> do
              result <- case native of
                [] -> X.nativeType (planMachineBits plan) names parameters ty
                m:_ -> let ref = referenceParts (resolvedNativeType m)
                  in pure (X.remote (intercalate "." (if last ref == "t" then init ref else ref)) "t" (map (D.text . snd) parameters))
              let strategy = X.call "StreamData.t" . pure
                  signature = D.text "@spec " <> X.call name (map (strategy . D.text . snd) parameters) <>
                    D.text " :: " <> strategy result <>
                    (if null parameters then mempty else D.text " when " <> D.joinWith (D.text ", ")
                      [D.text (variable ++ ": term()") | (_,variable) <- parameters])
              pure ([],[signature, X.function name [D.text ("_child" ++ show i) | i <- [0..length parameters-1]]
                [X.call "raise" [X.string message]]])
            _ -> do
              (imports,result) <- case native of
                [] -> do
                  result <- G.nativeType False names parameters ty
                  pure (G.imports False [ty],result)
                m:_ -> do
                  let ref = referenceParts (resolvedNativeType m)
                  unless (length ref >= 2 && capitalized (last ref))
                    (Left "Gleam native types require a module path and a capitalized name")
                  alias <- maybe (Left "missing Gleam generator type module") Right (lookup (init ref) nativeAliases)
                  let applied = if null parameters then D.text (alias ++ "." ++ last ref)
                        else G.call (alias ++ "." ++ last ref) (map (D.text . snd) parameters)
                  pure ([D.text ("import " ++ intercalate "/" (init ref) ++ " as " ++ alias)],applied)
              let strategy = G.call "qcheck.Generator" . pure
              pure (imports, [G.function name [D.text ("_child" ++ show i ++ ": ") <> strategy (D.text variable)
                    | (i,(_,variable)) <- zip [0::Int ..] parameters] (strategy result)
                  [D.text "panic as " <> G.string message]])
        let imports = nub (concatMap fst bodies)
            functions = concatMap snd bodies
            document = case target of
              "elixir" -> X.moduleDoc (intercalate "." parts) True functions
              "gleam" -> G.fileDoc True (D.text "import qcheck" : imports ++ functions)
              _ -> E.userModuleDoc moduleName [(last (referenceParts (resolvedGeneratorFactory g)),generatorParameterCount g) | g <- group] functions
        pure (AdapterArtifact path (D.render layout document) "user" "test" (D.render (D.Pretty 100) document))
    forM_Units action = mapM_ (action . plannedUnit) (plannedUnits plan)
    extraFields m c = ["lawspec_type_" ++ show i | (i,_) <- zip [0::Int ..]
      (freeExistentials (resolvedDeclaration m) (resolvedConstructor c))]
    fieldNames m c = map snd (resolvedFields c) ++ extraFields m c
    variables m c = [D.text ("_Field" ++ show i) | (i,_) <- zip [0::Int ..] (fieldNames m c)]
    nativeShape i m c = do
      let fields = fieldNames m c
          values = variables m c
          parts = referenceParts (resolvedNativeConstructor c)
          shape encode patternDoc = E.record
            [(E.atom "encode",E.lambda [E.array values] encode),
             (E.atom "decode",D.group (D.text "fun(" <> patternDoc <> D.text ") -> " <>
               E.tuple [E.atom "ok",E.array values] <> D.text "; (_) -> no_match end"))]
      case target of
        "erlang" -> do
          unless (length parts == 1) (Left "Erlang native constructors require one atom or record name")
          case resolvedConstructorStyle c of
            RecordConstructor -> do
              let record = D.text "#" <> E.atom (last parts) <>
                    D.delimit 4 "{" "}" [E.atom field <> D.text " = " <> value | (field,value) <- zip fields values]
              pure (shape record record)
            UnitConstructor -> pure (E.record [(E.atom "native_tag",E.atom (last parts))])
            VariantConstructor -> pure (E.record [(E.atom "native_tag",E.atom (last parts))])
        "elixir" -> case (resolvedConstructorStyle c,parts) of
          (UnitConstructor,[tag@(first:_)]) | not (isUpper first) ->
            pure (E.record [(E.atom "native_tag",E.atom tag)])
          _ -> do
            unless (all capitalized parts) (Left "Elixir native structs require capitalized module components")
            let owner = E.atom ("Elixir." ++ intercalate "." parts)
                entries = (E.atom "__struct__",owner) : zip (map E.atom fields) values
            pure (shape (E.remote "Elixir.Kernel" "struct!" [owner,E.record (zip (map E.atom fields) values)])
              (D.delimit 4 "#{" "}" [k <> D.text " := " <> v | (k,v) <- entries]))
        "gleam" -> pure (E.remote "lawspec_beam_schema" "constructor_shape"
          [E.lambda [E.array values] (E.remote "lawspec@native_constructors" ("make_" ++ show i) values),
           D.text (show (length fields))])
        _ -> Left "unknown BEAM native binding target"
    bridge (declaration,call) = do
      let (types,result) = C.functionType (C.declarationType declaration)
          values = [D.text ("_Argument" ++ show i) | (i,_) <- zip [0::Int ..] types]
          schema = D.text "_Native"
          convert method ty value = do
            ref <- E.typeReference ty
            pure (E.remote "lawspec_beam_schema" method [value,ref,schema])
          handle ty = case ty of
            C.Constructor name [] -> [m | m <- mappings, let d = resolvedDeclaration m,
              C.dataHandle d, C.dataId d == C.Id name]
            _ -> []
      nativeValues <- sequence [convert "to_native" ty value | (ty,value) <- zip types values]
      handlers <- mapM (\a -> Effects.toNative units a (D.text "_Canonical") (D.text "_Symbols")
        (E.remote "lawspec_beam_effects" "handler" [D.text "_Canonical",E.binary (C.abilityKey a)])) (Effects.uses declaration)
      let arguments = [D.text ("_NativeArgument" ++ show i) | (i,_) <- zip [0::Int ..] nativeValues]
      invocation <- case call of
        StaticCall ref -> nativeCall target ref (handlers ++ arguments)
        ConstructorCall ref -> nativeCall target ref (handlers ++ [v | (ty,v) <- zip types arguments, ty /= C.scalarType "Unit"])
        MethodCall method -> case [(i,m) | (i,ty) <- zip [0::Int ..] types, m <- handle ty] of
          (receiver,m):_ -> do
            let parts = referenceParts (resolvedNativeType m)
                moduleParts = if target == "elixir" && last parts /= "t" then parts else init parts
            nativeCall target (NativeRef (moduleParts ++ [method]))
              (arguments !! receiver : handlers ++ [v | (i,v) <- zip [0::Int ..] arguments, i /= receiver])
          [] -> Left "a BEAM method binding needs its handle bound to a native type"
      checked <- Definitions.nativeFailures target (bindingFailures bindings) schema declaration invocation
      output <- if result == C.scalarType "Unit" then pure (E.sequenceDoc [checked,E.atom "ls_unit"])
        else convert "from_native" result checked
      name <- maybe (Left "missing BEAM bound entry") Right (lookup (C.declarationId declaration) (boundEntries bindings))
      pure (E.function name (D.text "_Canonical" : D.text "_Symbols" : values)
        [D.text "_Native = " <> E.call "schema" [D.text "_Canonical"],
         E.remote "lawspec_beam_runtime" "contextual" [E.binary ("native binding " ++ C.idText (C.declarationId declaration)),
           E.lambda [] (E.apply (E.lambda arguments output) nativeValues)]])
    gleamConstructors = do
      let modules = nub [init parts | (m,c) <- constructors,
            ref <- [resolvedNativeType m,resolvedNativeConstructor c], let parts = referenceParts ref]
          aliases = zip modules ["native_" ++ show i | i <- [0::Int ..]]
          reference ref = case referenceParts ref of
            [] -> Left "empty Gleam native reference"
            parts -> do
              unless (length parts >= 2 && capitalized (last parts))
                (Left "Gleam native types and constructors require a module path and a capitalized name")
              alias <- maybe (Left "missing Gleam native module") Right (lookup (init parts) aliases)
              pure (alias ++ "." ++ last parts)
      bodies <- forM (zip [0::Int ..] constructors) $ \(i,(m,c)) -> do
        constructor <- reference (resolvedNativeConstructor c)
        nativeType <- reference (resolvedNativeType m)
        let parameters = [D.text ("a" ++ show j) | (j,_) <- zip [0::Int ..] (C.dataParameters (resolvedDeclaration m))]
            fields = fieldNames m c
            values = ["field_" ++ show j | (j,_) <- zip [0::Int ..] fields]
            result = if null parameters then D.text nativeType else G.call nativeType parameters
            invocation = if null values then D.text constructor else G.call constructor
              [D.text (field ++ ": " ++ value) | (field,value) <- zip fields values]
        pure (G.function ("make_" ++ show i) (map D.text values) result [invocation])
      let imports = [D.text ("import " ++ intercalate "/" parts ++ " as " ++ alias) | (parts,alias) <- aliases]
      pure (Artifact "src/lawspec/native_constructors.gleam"
        (D.render layout (G.fileDoc False (imports ++ bodies))) "generated" "source")
    capitalized (first:_) = isUpper first
    capitalized [] = False

nativeCall :: String -> NativeRef -> [D.Doc] -> Either String D.Doc
nativeCall target = E.nativeCall target . referenceParts
