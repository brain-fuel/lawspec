-- | Application-owned Haskell ADTs cross the same checked schema as generated ADTs.
module LawSpec.HaskellNativeBinding (emitBindings) where

import Control.Monad (forM, unless)
import Data.Char (isUpper, isLower, toUpper, toLower)
import Data.List (intercalate, nub, isSuffixOf, isPrefixOf, find)
import qualified LawSpec.Core as C
import LawSpec.AbilityNames (interfaceName, ownAbilities, ownerName, fieldName)
import LawSpec.Backend (inputs, inputType)
import LawSpec.Common
import LawSpec.Testing
import LawSpec.NativeBinding
import LawSpec.NativeRequest
import qualified LawSpec.HaskellData as H
import qualified LawSpec.HaskellDefinitions as Definitions
import qualified LawSpec.HaskellExpr as E
import qualified LawSpec.CoreNativeScalarEmit as Scalar
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Code.Haskell as HL

-- | Bound adapters call the user's Haskell code directly, through generated
-- conversions. ref:DEC-native-bindings-typed-identity
emitBindings :: Bool -> BindingPlan -> Plan -> [Artifact] -> Either String [Artifact]
emitBindings minify plan testing files = do
  unless (bindingRustCrate plan == Nothing) (Left "rustCrate is only valid for Rust bindings")
  mapM_ (reference False . resolvedGeneratorFactory) generators
  mapM_ (reference True) typeRefs
  mapM_ (reference False) hookRefs
  mapM_ (reference False . snd) (bindingFunctions plan)
  mapM_ (reference False) [ref | (_,ConstructorCall ref) <- bindingCalls plan]
  mapM_ selector [name | (_,MethodCall name) <- bindingCalls plan]
  methodCalls <- mapM (\(d,call) -> (,) d <$> resolveCall d call) (bindingCalls plan)
  let calls = [(d,Static ref) | (d,ref) <- bindingFunctions plan] ++ methodCalls
  let generatedModules = [map (\c -> if c == '/' then '.' else c) (take (length relative - 3) relative) |
        file <- files, ".hs" `isSuffixOf` artifactPath file,
        (_, '/':relative) <- [break (== '/') (artifactPath file)]] ++
        ["LawSpecNativeCodecs", "LawSpecNativeGenerators"]
  unless (all (`notElem` generatedModules) applicationModules)
    (Left "Haskell application module shadows a generated module")
  mapM_ selector [name | m <- mappings,c <- resolvedConstructors m,(_,name) <- resolvedFields c]
  let types = [(C.dataId (resolvedDeclaration m), qualify (resolvedNativeType m)) | m <- mappings]
      constructors = [(C.constructorId (resolvedConstructor c),
        (qualify (resolvedNativeConstructor c), [alias (moduleOf (resolvedNativeConstructor c)) ++ "." ++ field |
          (_,field) <- resolvedFields c])) | m <- mappings,c <- resolvedConstructors m]
      modules = [name ++ " as " ++ alias name | name <- nub (map moduleOf (typeRefs ++ hookRefs))]
      hooks = [(C.dataId (resolvedDeclaration m),(qualify (codecToNative hook),qualify (codecFromNative hook))) |
        m <- mappings,Just hook <- [resolvedCodec m]]
      layouts=[(C.constructorId (resolvedConstructor constructor),constructor) |
        mapping<-mappings,constructor<-resolvedConstructors mapping,resolvedFieldLayout constructor/=Nothing]
  codecs <- H.emitHaskellCodecsWithLayouts layout declarations "LawSpecNativeCodecs" modules types constructors hooks layouts
  concrete <- if null generators then pure [] else reachableGeneratorTypes declarations representations
    [inputType i | p <- plannedUnits testing,property <- plannedProperties p,i <- inputs property]
  let usedGenerators = [g | g <- generators, any (\case C.Constructor name _ -> C.Id name == resolvedGeneratorType g; _ -> False) concrete]
  generatorFiles <- if null usedGenerators then pure [] else do
    methods <- forM (zip [0::Int ..] usedGenerators) $ \(index,g) -> do
      branches <- forM [ty | ty@(C.Constructor name _) <- concrete,C.Id name == resolvedGeneratorType g] $ \ty -> do
        let arguments = case ty of C.Constructor _ args -> [t | C.TypeArgument t <- args]; _ -> []
            names = ["child" ++ show i | i <- [0::Int ..length arguments-1]]
        childCodecs <- mapM (nativeCodec "bits") arguments
        resultCodec <- nativeCodec "bits" ty
        ref <- E.typeReference ty
        let invocation = HL.call (qualify (resolvedGeneratorFactory g))
              [HL.call "Strategies.nativeArguments" [codec, HL.var name] | (codec,name) <- zip childCodecs names]
            value = HL.call "P.Right" [HL.call "Strategies.nativeValues" [resultCodec, invocation]]
        pure ("(" ++ D.render D.Compact (HL.expression ref) ++ ", [" ++ intercalate ", " names ++ "])", value)
      pure (HL.declaration ("factory" ++ show index ++ " reference arguments") (HL.Case (HL.Tuple [HL.var "reference", HL.var "arguments"])
        (branches ++ [("_", HL.call "P.Left" [HL.string "unplanned native generator instantiation"])])))
    let registry = HL.List [HL.Tuple [HL.string (C.idText (resolvedGeneratorType g)), HL.var ("factory" ++ show i)] |
          (i,g) <- zip [0::Int ..] usedGenerators]
        definition = HL.declaration "factories symbols schema bits" registry <> D.nest 2 (D.hardline <> D.text "where" <>
          D.nest 2 (D.hardline <> D.joinWith D.hardline methods))
        rendered = D.render D.Compact definition
        imports = H.moduleImports rendered ([(m, Just a, Nothing) | (m, a) <- [("Prelude", "P"), ("Data.Int", "I"), ("Data.Word", "W"), ("Data.Text", "T"),
          ("Data.ByteString", "B"), ("Data.Complex", "C"), ("LawSpecRuntime", "LS"),
          ("LawSpecSchema", "Schema"), ("LawSpecCodecs", "Codec"), ("LawSpecData", "Data"),
          ("LawSpecNativeCodecs", "NativeCodecs"), ("LawSpecDataStrategies", "Strategies")]] ++
          [(m, Just (alias m), Nothing) | m <- nub (map moduleOf typeRefs ++ map (moduleOf . resolvedGeneratorFactory) usedGenerators)])
        source = D.joinWith D.hardline (map D.text (["-- Generated by LawSpec. Do not edit.",
          "module LawSpecNativeGenerators where", ""] ++ imports ++ ["",
          "-- The native generators the program binds, by type."])) <> D.hardline <>
          HL.signature "factories" ["LS.SymbolContext", "Schema.Schema", "P.Int", "[(P.String, Strategies.NativeFactory)]"] <> D.hardline <>
          definition <> D.hardline
    pure [Artifact "test/LawSpecNativeGenerators.hs" (D.render layout source) "generated" "test"]
  emitted <- fmap concat $ forM (plannedUnits testing) $ \p -> do
    let unit = plannedUnit p
        defined = map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions unit)
        adapters = [d | d <- C.unitDeclarations unit,C.declarationId d `notElem` defined]
        bound d = lookup (C.declarationId d) [(C.declarationId a,r) | (a,r) <- calls]
        boundAdapters = [(d,r) | d <- adapters,Just r <- [bound d]]
        moduleName = intercalate "." (map modulePart (split '.' (C.idText (C.unitId unit))))
        path = "src/" ++ map (\c -> if c == '.' then '/' else c) moduleName ++ ".hs"
    if null boundAdapters && null usedGenerators then pure [] else do
      unless (null boundAdapters || length boundAdapters == length adapters) (Left "a Haskell bound unit must map every adapter")
      unless (moduleName `notElem` map (moduleOf . callRef . snd) boundAdapters)
        (Left "Haskell application module shadows its generated adapter module")
      methods <- mapM bridge boundAdapters
      -- Each bound production handler, wrapped in the generated record: its
      -- operations' values cross with the native codecs.
      let boundHandlers' = [(a, r) | a <- ownAbilities unit, Just r <- [lookup (C.Id (C.abilityKey (C.abilityInstance a))) (bindingHandlers plan)]]
      wrappers <- mapM (wrapper unit) [(a, r) | not (null boundAdapters), (a, r) <- boundHandlers']
      let effectful = any (\(_,c) -> case c of Static _ -> False; _ -> True) boundAdapters
      ordinary <- either (Left . show) Right $
        Scalar.nativeScalarEmitWithAdapterBindings
          [(C.declarationId d,C.declarationName d) | (d,_) <- boundAdapters]
          (not (null usedGenerators)) minify declarations (Definitions.definitionCalls (map plannedUnit (plannedUnits testing)))
          bits "haskell" (modelTestUnit testing unit) (plannedProperties p)
      let declarations' = D.joinWith D.hardline [HL.comment ["The program's types, which values are checked against."],
              HL.signature "schema" ["Schema.Schema"], HL.declaration "schema" (HL.call "P.either" [HL.var "P.error", HL.var "P.id", HL.var "DataSchema.schema"])]
            : methods ++ wrappers
          rendered = D.render D.Compact (D.joinWith D.hardline declarations')
          imports = H.moduleImports rendered ([(m, Just a, Nothing) | (m, a) <- [("Prelude", "P"), ("Data.Int", "I"), ("Data.Word", "W"), ("Data.Text", "T"),
            ("Data.ByteString", "B"), ("Data.Complex", "C"), ("LawSpecRuntime", "LS"),
            ("LawSpecSchema", "Schema"), ("LawSpecCodecs", "Codec"), ("LawSpecData", "Data"),
            ("LawSpecDataSchema", "DataSchema"), ("LawSpecDataCodecs", "Codecs"), ("LawSpecNativeCodecs", "NativeCodecs")]] ++
            [(m, Just (alias m), Nothing) | m <- nub (map moduleOf typeRefs ++ map (moduleOf . callRef . snd) boundAdapters ++ [moduleOf r | (_, r) <- boundHandlers'])] ++
            [(m, Just m, Nothing) | m <- nub (["LawSpecAbilities." ++ modulePart' (ownerName a) | (d, _) <- boundAdapters, ability <- C.declarationUses d, not (C.isFail ability),
                 Just (_, a) <- [C.findAbility units' ability]] ++
                ["LawSpecAbilities." ++ modulePart' (C.idText (C.unitId unit)) | not (null boundHandlers')])])
          source = D.joinWith D.hardline (map D.text
            (["-- Generated by LawSpec. Do not edit."] ++ ["{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}" | effectful] ++
             ["", "module " ++ moduleName ++ " where", ""] ++ imports)) <>
            mconcat [D.hardline <> D.hardline <> d | d <- declarations'] <> D.hardline
      pure ([Artifact path (D.render layout source) "generated" "source" | not (null boundAdapters)] ++
        [f | f <- ordinary, null boundAdapters || artifactPath f /= path])
  let support = Artifact "src/LawSpecNativeCodecs.hs" codecs "generated" "source"
  unless (all ((/= artifactPath support) . artifactPath) files) (Left "unit shadows Haskell native codec support")
  -- Workflows call bound adapters' bridges, which take the symbol context.
  let units = map plannedUnit (plannedUnits testing)
      boundIds = [C.declarationId d | (d,_) <- calls]
  definitions <- if null boundIds then pure [] else
    Definitions.emitHaskellDefinitionsWithBindings boundIds (D.selectLayout minify (D.Pretty 80)) bits declarations units
  let replaced = map artifactPath (emitted ++ definitions)
      generated = [f | f <- files,artifactPath f `notElem` replaced] ++ [support] ++ generatorFiles ++
        [f | f <- definitions, artifactPath f `elem` map artifactPath files] ++ emitted
  stubs <- generatorStubs generated
  pure (generated ++ stubs)
  where
    representations = bindingRepresentations plan
    generators = resolvedGenerators representations
    mappings = resolvedTypes representations
    declarations = planDataDeclarations testing
    bits = planMachineBits testing
    layout = D.selectLayout minify (D.Pretty 100)
    typeRefs = [resolvedNativeType m | m <- mappings] ++
      [resolvedNativeConstructor c | m <- mappings,c <- resolvedConstructors m]
    hookRefs = [ref | m <- mappings,Just hook <- [resolvedCodec m],ref <- [codecToNative hook,codecFromNative hook]]
    callRefs = map snd (bindingFunctions plan) ++ [ref | (_,ConstructorCall ref) <- bindingCalls plan]
    applicationModules = nub (map moduleOf (typeRefs ++ hookRefs ++ callRefs ++
      map resolvedGeneratorFactory generators ++ map snd (bindingHandlers plan)))
    units' = map plannedUnit (plannedUnits testing)
    modulePart' = intercalate "." . map modulePart . split '.'
    abilityRecord a = "LawSpecAbilities." ++ modulePart' (ownerName a) ++ "." ++ interfaceName a
    abilityField a op = "LawSpecAbilities." ++ modulePart' (ownerName a) ++ "." ++ fieldName a op
    wrapper _ (a, r) = do
      let name = lowerFirst' (interfaceName a) ++ "Bound"
          native = alias (moduleOf r) ++ "."
      fields <- forM (C.abilityOperations a) $ \(op, ty) -> do
        let (args, result) = C.functionType ty
            values = HL.uniqueValues (length args)
            arguments' = HL.uniqueArguments (length args)
            codec namespace = H.haskellCodecDocIn Nothing namespace declarations "schema" (show bits)
        canonical <- mapM (codec "Codecs.") args
        nativeArgs <- mapM (nativeCodecIn Nothing (show bits)) args
        resultNative <- nativeCodecIn Nothing (show bits) result
        resultCanonical <- codec "Codecs." result
        let steps = HL.Do ([HL.Let a' (crossing (HL.call "Codec.encode" [c, HL.var v]) n) | (a', (v, c, n)) <- zip arguments' (zip3 values canonical nativeArgs)] ++
              [ HL.Bind "nativeResult" (HL.call (native ++ fieldName a op) (map HL.var ("inner" : arguments')))
              , HL.Run (HL.call "P.pure" [crossing (HL.call "Codec.encode" [resultNative, HL.var "nativeResult"]) resultCanonical]) ])
        pure (abilityField a op, if null values then steps else HL.lambda values steps)
      pure (D.joinWith D.hardline
        [ HL.comment ["The bound production handler of " ++ C.abilityName a ++ ", as the generated record."]
        , HL.signature name ["P.IO " ++ abilityRecord a]
        , HL.declaration name (HL.Do [HL.Bind "inner" (HL.var (qualify r)), HL.Run (HL.call "P.pure" [HL.Record (abilityRecord a) fields])]) ])
    -- A value from one codec's representation to another's.
    crossing encoded decoder = HL.call "P.either" [HL.var "P.error", HL.var "P.id",
      HL.operator "P.>>=" [encoded, HL.call "Codec.decode" [decoder]]]
    lowerFirst' (c:cs) = toLower c : cs
    lowerFirst' [] = []
    nativeCodecIn scope bitsName ty = do
      converter <- H.haskellCodecDocIn scope "NativeCodecs." declarations "schema" bitsName ty
      nativeType <- H.haskellDataTypeWithRepresentations declarations
        [(C.dataId (resolvedDeclaration m),qualify (resolvedNativeType m)) | m <- mappings] ty
      pure (HL.Typed converter ("Codec.Codec " ++ nativeType))
    aliases = zip applicationModules ["NativeModule" ++ show i | i <- [0::Int ..]]
    alias name = maybe (error "unresolved Haskell application module") id (lookup name aliases)
    qualify ref = alias (moduleOf ref) ++ "." ++ last (referenceParts ref)
    moduleOf = intercalate "." . init . referenceParts
    generatorStubs generated = do
      let requested = filter resolvedGeneratorStub generators
          owners = nub (map (moduleOf . resolvedGeneratorFactory) requested)
          generatedModules = [map (\c -> if c == '/' then '.' else c) (take (length relative - 3) relative) |
            file <- generated, ".hs" `isSuffixOf` artifactPath file,
            (_, '/':relative) <- [break (== '/') (artifactPath file)]]
          occupied = generatedModules ++ map moduleOf (typeRefs ++ hookRefs ++ callRefs)
          conflicts a b = map toLower a == map toLower b
          runtimeModule name = name `elem` words
            ("Prelude Hedgehog Numeric Test.Hspec Control.Exception Control.Monad " ++
             "Control.Monad.State.Strict Data.Int Data.Word Data.Text Data.ByteString " ++
             "Data.Complex Data.Bits Data.Char Data.List Data.Ratio Data.Unique " ++
             "Data.Maybe Data.Map.Strict") ||
            any (`isPrefixOf` name) ["Hedgehog.", "GHC.", "LawSpec"]
      forM owners $ \owner -> do
        unless (not (runtimeModule owner) && not (any (conflicts owner) occupied) &&
          not (any (\other -> owner /= other && conflicts owner other) owners))
          (Left "Haskell generator scaffold module conflicts with application, generated or runtime modules")
        bodies <- forM (filter ((== owner) . moduleOf . resolvedGeneratorFactory) requested) $ \generator -> do
          let name = last (referenceParts (resolvedGeneratorFactory generator))
              parameters = [(C.Id ("scaffold::" ++ show i),"a" ++ show i) | i <- [0 .. generatorParameterCount generator - 1]]
              ty = C.Constructor (C.idText (resolvedGeneratorType generator))
                [C.TypeArgument (C.TypeVariable identity) | (identity,_) <- parameters]
          unless (name /= "_") (Left "Haskell generator scaffold cannot declare the wildcard identifier")
          native <- H.haskellNativeTypeWithParameters declarations
            [(C.dataId (resolvedDeclaration m),qualify (resolvedNativeType m)) | m <- mappings] parameters ty
          let gen value = "H.Gen " ++ (if ' ' `elem` value && take 1 value /= "(" then "(" ++ value ++ ")" else value)
              arguments = ["_argument" ++ show i | i <- [0 .. length parameters - 1]]
          pure (D.joinWith D.hardline
            [ HL.signature name (map (gen . snd) parameters ++ [gen native])
            , HL.declaration (unwords (name:arguments)) (HL.call "P.error" [HL.string ("Implement generator for " ++ C.idText (resolvedGeneratorType generator))]) ])
        let rendered = D.render D.Compact (D.joinWith D.hardline bodies)
            imports = H.moduleImports rendered ([(name, Just short, Nothing) |
              (name,short) <- [("Prelude","P"),("Hedgehog","H"),("Data.Int","I"),("Data.Word","W"),
                ("Data.Text","T"),("Data.ByteString","B"),("Data.Complex","C"),
                ("LawSpecRuntime","LS"),("LawSpecData","Data")]] ++
                [(name, Just (alias name), Nothing) | name <- nub (map (moduleOf . resolvedNativeType) mappings)])
        pure (Artifact ("test/" ++ map (\c -> if c == '.' then '/' else c) owner ++ ".hs")
          (D.render (HL.layout False) (D.joinWith D.hardline (map D.text (["-- User-owned native generator factories. Implement before running properties.",
            "module " ++ owner ++ " where", ""] ++ imports)) <>
            mconcat [D.hardline <> D.hardline <> b | b <- bodies] <> D.hardline)) "user" "test")
    selector name = unless (not (null name) && (isLower (head name) || head name == '_') &&
      name `notElem` words "case class data default deriving do else foreign if import in infix infixl infixr instance let module newtype of then type where")
      (Left ("invalid Haskell native value identifier: " ++ name))
    reference upper ref = do
      let parts = referenceParts ref
      unless (length parts >= 2 && all (\n -> not (null n) && isUpper (head n)) (init parts))
        (Left "Haskell native references require a qualified application module")
      if upper then unless (not (null (last parts)) && isUpper (head (last parts)))
        (Left "Haskell native types and constructors must begin with an uppercase letter")
        else selector (last parts)
      unless (moduleOf ref `notElem` ["LawSpecNativeCodecs","LawSpecDataCodecs","LawSpecData", "LawSpecDataSchema"])
        (Left "Haskell native reference shadows generated support")
    split c s = case break (==c) s of (a,[]) -> [a]; (a,_:b) -> a:split c b
    modulePart = concatMap cap . split '_'
    cap [] = []; cap (c:cs) = toUpper c:cs
    nativeCodec = nativeCodecIn (Just (HL.call "P.Just" [HL.var "symbols"]))
    -- A method is a function of the handle's native module taking the
    -- handle first; a constructor is a native function, given the adapter's
    -- non-Unit arguments.
    resolveCall declaration call = case call of
      StaticCall ref -> pure (Static ref)
      ConstructorCall ref -> pure (Construct ref)
      MethodCall name -> do
        let (args,_) = C.functionType (C.declarationType declaration)
            context = C.idText (C.declarationId declaration)
        position <- maybe (Left (context ++ ": a method binding needs a handle argument")) Right
          (lookup True (zip (map isHandle args) [0..]))
        owner <- case args !! position of
          C.Constructor handleName [] | Just m <- find ((== C.Id handleName) . C.dataId . resolvedDeclaration) mappings ->
            pure (resolvedNativeType m)
          C.Constructor handleName [] -> Left (context ++ " is bound to the method " ++ name ++ " of its handle " ++
            lastPart handleName ++ ", but " ++ lastPart handleName ++ " has no type binding. Haskell finds " ++ name ++
            " in the module of the handle's native type, so add {\"type\": \"" ++ handleName ++
            "\", \"native\": [\"Module\", \"Type\"]} to nativeBindings.types in lawspec.json")
          _ -> Left (context ++ ": a method binding needs a handle argument")
        pure (Method position (NativeRef (init (referenceParts owner) ++ [name])))
    isHandle ty = case ty of
      C.Constructor name [] -> any (\d -> C.dataHandle d && C.dataId d == C.Id name) declarations
      _ -> False
    isUnit ty = ty == C.Constructor "Unit" []
    -- An adapter that uses abilities gets their handler records first and
    -- runs in IO; its values cross with the codecs as usual.
    signatureOf declaration extra async' = do
      let (args,result) = C.functionType (C.declarationType declaration)
      types <- mapM (H.haskellDataType declarations) (args ++ [result])
      let wrapType t = if ' ' `elem` t && take 1 t /= "(" && take 1 t /= "[" then "(" ++ t ++ ")" else t
      pure (HL.signature (C.declarationName declaration) (["LS.SymbolContext"] ++ extra ++ map wrapType (init types) ++
        [if async' then "P.IO " ++ wrapType (last types) else last types]))
    -- An adapter that uses abilities gets their handler records first and
    -- runs in IO; its values cross with the codecs as usual.
    bridge (declaration,call)
      | not (null handlerRecords) = do
          let (args,result) = C.functionType (C.declarationType declaration)
              values = HL.uniqueValues (length args)
              arguments' = HL.uniqueArguments (length args)
              handlers = ["handler" ++ show i | i <- [1 .. length handlerRecords]]
              scope = Just (HL.call "P.Just" [HL.var "symbols"])
              codec namespace = H.haskellCodecDocIn scope namespace declarations "schema" (show bits)
          canonical <- mapM (codec "Codecs.") args
          native <- mapM (nativeCodec (show bits)) args
          resultNative <- nativeCodec (show bits) result
          resultCanonical <- codec "Codecs." result
          signature <- signatureOf declaration handlerRecords True
          let body = HL.Do ([HL.Let a' (crossing (HL.call "Codec.encode" [c, HL.var v]) n) | (a', (v, c, n)) <- zip arguments' (zip3 values canonical native)] ++
                [ HL.Bind "nativeResult" (HL.call (qualify (callRef call)) (map HL.var (handlers ++ arguments')))
                , HL.Run (HL.call "P.pure" [crossing (HL.call "Codec.encode" [resultNative, HL.var "nativeResult"]) resultCanonical]) ])
          pure (D.joinWith D.hardline [signature, HL.declaration (unwords (C.declarationName declaration : "symbols" : handlers ++ values)) body])
      where
        handlerRecords = [abilityRecord a | ability <- C.declarationUses declaration, not (C.isFail ability), Just (_, a) <- [C.findAbility units' ability]]
    bridge (declaration,call) = do
      let (args,result) = C.functionType (C.declarationType declaration)
          values = HL.uniqueValues (length args)
          ref = callRef call
          -- The native call's arguments, in order.
          passed = case call of
            Method position _ -> position : [i | i <- [0..length args-1], i /= position]
            Construct _ -> [i | (i,ty) <- zip [0..] args, not (isUnit ty)]
            Static _ -> [0..length args-1]
          discards = isUnit result && case call of Static _ -> False; _ -> True
          scope = Just (HL.call "P.Just" [HL.var "symbols"])
          codec namespace = H.haskellCodecDocIn scope namespace declarations "schema" (show bits)
          logical i = "logical" ++ show i
          argument i = "argument" ++ show i
      canonical <- mapM (codec "Codecs.") args
      native <- mapM (nativeCodec (show bits)) args
      resultNative <- nativeCodec (show bits) result
      resultCanonical <- codec "Codecs." result
      signature <- signatureOf declaration [] (C.declarationAsync declaration)
      let argumentChecks = concat
            [[HL.Bind (logical i) (HL.call "Codec.encode" [c, HL.var value]),
              HL.Bind (argument i) (HL.call "Codec.decode" [n, HL.var (logical i)])] |
              (i,(value,c,n)) <- zip [1::Int ..] (zip3 values canonical native)]
          call' = HL.call (qualify ref) [HL.var (argument (i + 1)) | i <- passed]
          -- Methods and constructors are IO actions, as Haskell's mutable
          -- objects are; the adapter is sync, so the bridge runs each call
          -- in place (the module turns off CSE and full laziness).
          invoke = case call of
            Static _ -> call'
            _ -> HL.call "LS.awaitTask" [call']
          -- Unit's codec ignores its payload; force the call even for Unit.
          -- A method or constructor bound to a Unit adapter discards the
          -- native result once it has run.
          encodeResult = HL.call "P.seq" [HL.var "nativeResult",
            HL.call "Codec.encode" [resultNative, if discards then HL.var "()" else HL.var "nativeResult"]]
          context = HL.call "Codec.context" [HL.string ("native binding " ++ C.idText (C.declarationId declaration))]
          convertResult = [HL.Bind "logicalResult" encodeResult, HL.Run (HL.call "Codec.decode" [resultCanonical, HL.var "logicalResult"])]
          -- An async adapter's bridge is the native IO action, its result
          -- converted when it has run.
          convert = HL.lambda ["nativeResult"] (HL.call "P.either" [HL.var "P.error", HL.var "P.id", HL.dollarIn "P." context (HL.Do convertResult)])
          asyncResult = HL.Run (HL.call "P.pure" [HL.call "P.fmap" [convert, call']])
          body = HL.dollarIn "P." context (HL.Do (argumentChecks ++
            if C.declarationAsync declaration then [asyncResult] else HL.Let "nativeResult" invoke : convertResult))
      pure (D.joinWith D.hardline [signature,
        HL.declaration (unwords (C.declarationName declaration : "symbols" : values)) (HL.call "P.either" [HL.var "P.error", HL.var "P.id", body])])

-- | A bound adapter's native call, its reference resolved.
data Bridge = Static NativeRef | Method Int NativeRef | Construct NativeRef

callRef :: Bridge -> NativeRef
callRef (Static ref) = ref
callRef (Method _ ref) = ref
callRef (Construct ref) = ref

-- | A qualified identity's last segment: example.handles::type::Jobs is Jobs.
lastPart :: String -> String
lastPart s = case breakOn s of
  (_, Just rest) -> lastPart rest
  (whole, Nothing) -> whole
  where
    breakOn str = go "" str
    go acc (':' : ':' : rest) = (reverse acc, Just rest)
    go acc (c : rest) = go (c : acc) rest
    go acc [] = (reverse acc, Nothing)
