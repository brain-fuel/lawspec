-- Typed application codecs keep validation in the shared logical schema.
module LawSpec.JavaNativeBinding (emitBindings) where

import Control.Monad (forM, unless)
import Data.List (intercalate, find, nub, isPrefixOf)
import Data.Char (toUpper, toLower)
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Backend (unitName, inputs, inputType)
import LawSpec.Testing
import LawSpec.NativeBinding
import LawSpec.NativeRequest
import qualified LawSpec.JavaData as J
import qualified LawSpec.JavaExpr as E
import qualified LawSpec.Code.Doc as D
import LawSpec.Scalar (nativeRepresentation)
import qualified LawSpec.JavaDefinitions as Definitions
import qualified LawSpec.CoreNativeScalarEmit as Scalar
import LawSpec.RuntimeSources (runtimeSource)

emitBindings :: Bool -> BindingPlan -> Plan -> [Artifact] -> Either String [Artifact]
emitBindings minify plan testing files = do
  unless (bindingRustCrate plan == Nothing) (Left "rustCrate is only valid for Rust bindings")
  unless (null mappings || not (null (bindingFunctions plan)) || not (null generators)) (Left "native types require function or generator bindings")
  mapM_ (mapM_ J.identifier . referenceParts) ([ref | (_,ref) <- bindingFunctions plan] ++
    [resolvedNativeType m | m <- mappings] ++ [resolvedNativeConstructor c | m <- mappings,c <- resolvedConstructors m] ++
    [ref | m <- mappings, Just hook <- [resolvedCodec m], ref <- [codecToNative hook, codecFromNative hook]])
  mapM_ (J.identifier . snd) [f | m <- mappings,c <- resolvedConstructors m,f <- resolvedFields c]
  methods <- mapM codecMethod (zip [0::Int ..] declarations)
  let support = Artifact "src/main/java/lawspec/runtime/LawSpecNativeCodecs.java"
        (render (D.text "package lawspec.runtime;" <> D.hardline <> D.hardline <>
          D.text "public final class LawSpecNativeCodecs " <> D.block 2
          (D.joinWith (D.hardline <> D.hardline)
            (D.text "private LawSpecNativeCodecs() {}":methods)))) "generated" "source"
  bridges <- fmap concat $ forM (plannedUnits testing) $ \p -> do
    let unit = plannedUnit p
        definitions = map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions unit)
        adapters = [d | d <- C.unitDeclarations unit,C.declarationId d `notElem` definitions]
        bound d = lookup (C.declarationId d) [(C.declarationId a,r) | (a,r) <- bindingFunctions plan]
    mapM_ J.identifier (split '.' (unitName unit))
    if not (any (maybe False (const True) . bound) adapters) then pure [] else do
      unless (all (maybe False (const True) . bound) adapters) (Left "a Java bound unit must map every adapter")
      bodies <- forM adapters $ \d -> do
        let (args,result) = C.functionType (C.declarationType d)
            Just ref = bound d
        argTypes <- mapM (J.javaDataTypeDoc declarations) args
        resultType <- J.javaDataTypeDoc declarations result
        canonical <- mapM (J.javaCodecDocWithContext (D.text "symbols") declarations bits) args
        native <- mapM (codec [] (D.text "_schema") (D.text (show bits))) args
        canonicalResult <- J.javaCodecDocWithContext (D.text "symbols") declarations bits result
        nativeResult <- codec [] (D.text "_schema") (D.text (show bits)) result
        let values = [D.text ("value" ++ show i) | i <- [0::Int ..length args-1]]
            converted = [method n "decode" [method c "encode" [v]] | (n,c,v) <- zip3 native canonical values]
            application = call (reference ref) converted
            resultBody = if result == C.scalarType "Unit" then application <> D.text ";" else
              D.text "var result = " <> application <> D.text ";" <> D.hardline <>
              D.text "return " <> method canonicalResult "decode" [method nativeResult "encode" [D.text "result"]] <> D.text ";"
        pure (D.text "public static " <> (if result == C.scalarType "Unit" then D.text "void" else resultType) <>
          D.text " " <> call (C.declarationName d) [t <> D.text " " <> v | (t,v) <- zip argTypes values] <>
          D.text " " <> D.block 2 (D.text "var symbols = new java.util.HashMap<String, Object>();" <> D.hardline <>
            D.text "try " <> D.block 2 resultBody <> D.text " catch (RuntimeException error) " <>
            D.block 2 (D.text "throw " <> call "new IllegalArgumentException"
              [E.quoted ("native binding " ++ C.idText (C.declarationId d) ++ ": ") <> D.text " + error.getMessage()",D.text "error"] <> D.text ";")))
      let parts = split '.' (unitName unit)
          name = concatMap cap (split '_' (last parts))
          package = intercalate "." (init parts)
          path = "src/main/java/" ++ concatMap (++ "/") (init parts) ++ name ++ ".java"
          header = if null package then mempty else D.text ("package " ++ package ++ ";") <> D.hardline <> D.hardline
          source = header <> D.text ("public final class " ++ name ++ " ") <> D.block 2
            (D.group (D.text "private static final lawspec.runtime.LawSpecSchema _schema =" <>
             D.nest 4 (D.softline <> D.text "lawspec.runtime.LawSpecDataSchema.create();")) <>
             D.hardline <> D.hardline <> D.joinWith (D.hardline <> D.hardline) bodies)
      pure [Artifact path (render source) "generated" "source"]
  dataFiles <- if any ((== "src/main/java/lawspec/runtime/LawSpecDataSchema.java") . artifactPath) files then pure []
    else J.emitJavaDataWithProfile bits layout declarations
  generatorFiles <- if null generators then pure [] else do
    let roots = [inputType input | unit <- plannedUnits testing, property <- plannedProperties unit, input <- inputs property]
    concrete <- if any ((>0) . generatorParameterCount) generators
      then reachableGeneratorTypes declarations representations roots else pure []
    factoryMethods <- forM (zip [0::Int ..] generators) $ \(index,generator) -> do
      mapM_ J.identifier (referenceParts (resolvedGeneratorFactory generator))
      let name = C.idText (resolvedGeneratorType generator)
          instances = if generatorParameterCount generator == 0 then [C.Constructor name []]
            else [ty | ty@(C.Constructor family _) <- concrete, family == name]
      branches <- forM instances $ \ty -> do
        let args = case ty of C.Constructor _ args -> [t | C.TypeArgument t <- args]; _ -> []
        children <- forM (zip [0::Int ..] args) $ \(i,child) -> do
          bridge <- codec [] (D.text "schema") (D.text "bits") child
          childType <- nativeType [] child
          pure (applied "Generator" [childType] <> D.text (" child" ++ show i ++ " = ") <>
            call "LawSpecDataStrategies.nativeArguments" [bridge,D.text ("arguments.get(" ++ show i ++ ")")] <> D.text ";")
        native <- nativeType [] ty
        bridge <- codec [] (D.text "schema") (D.text "bits") ty
        tyRef <- E.reference ty
        pure (D.text "if (type.equals(" <> tyRef <> D.text ")) " <> D.block 2
          (D.joinWith D.hardline (children ++
            [applied "Generator" [native] <> D.text " source = " <>
              call (reference (resolvedGeneratorFactory generator)) [D.text ("child" ++ show i) | i <- [0..length args-1]] <> D.text ";",
             D.text "return " <> call "LawSpecDataStrategies.nativeValues" [bridge,D.text "source"] <> D.text ";"])))
      pure (D.text "private static Generator<lawspec.runtime.LawSpecRuntime.Value> " <>
        call ("factory" ++ show index) (map D.text
          ["LawSpecSchema schema", "LawSpecSchema.Named type", "int bits", "java.util.Map<String, Object> symbols",
           "java.util.List<Generator<lawspec.runtime.LawSpecRuntime.Value>> arguments"]) <>
        D.text " " <> D.block 2 (D.joinWith D.hardline (branches ++
          [D.text "throw new IllegalArgumentException(\"unplanned native generator instantiation: \" + type);"])))
    let entries = [call "java.util.Map.<String, LawSpecDataStrategies.NativeFactory>entry"
          [E.quoted (C.idText (resolvedGeneratorType generator)),D.text ("LawSpecNativeGenerators::factory" ++ show i)] |
            (i,generator) <- zip [0::Int ..] generators]
        registry = D.text "public static java.util.Map<String, LawSpecDataStrategies.NativeFactory> factories() " <>
          D.block 2 (D.text "return " <> call "java.util.Map.ofEntries" entries <> D.text ";")
        helper = Artifact "src/test/java/lawspec/testing/LawSpecNativeGenerators.java" (render
          (D.text "package lawspec.testing;" <> D.hardline <> D.hardline <>
           D.text "import lawspec.runtime.LawSpecSchema;" <> D.hardline <>
           D.text "import org.jetbrains.jetCheck.Generator;" <> D.hardline <> D.hardline <>
           D.text "public final class LawSpecNativeGenerators " <> D.block 2
            (D.joinWith (D.hardline <> D.hardline)
             (D.text "private LawSpecNativeGenerators() {}":registry:factoryMethods)))) "generated" "test"
    emitted <- either (Left . show) Right $ concat <$> mapM (\unit ->
      Scalar.nativeScalarEmitWithNativeGenerators True minify declarations
        (Definitions.definitionCalls (map plannedUnit (plannedUnits testing))) bits "java"
        (plannedUnit unit) (plannedProperties unit))
        [unit | unit <- plannedUnits testing, not (null (plannedProperties unit))]
    pure (helper : [file | file <- emitted,artifactPlacement file == "test"] ++
      [Artifact "src/test/java/lawspec/testing/LawSpecDataStrategies.java" (runtimeSource "java-data-strategies") "generated" "test" |
        not (any ((== "src/test/java/lawspec/testing/LawSpecDataStrategies.java") . artifactPath) files)])
  let replaced = map artifactPath (bridges ++ generatorFiles)
  unless (all ((/= artifactPath support) . artifactPath) files) (Left "unit shadows native codec support")
  let runtime = [Artifact "src/main/java/lawspec/runtime/LawSpecRuntime.java" (runtimeSource "java") "generated" "source" |
        not (any ((== "src/main/java/lawspec/runtime/LawSpecRuntime.java") . artifactPath) files)]
  let generated = [f | f <- files,artifactPath f `notElem` replaced] ++ dataFiles ++ runtime ++ [support] ++ bridges ++ generatorFiles
  stubs <- generatorStubs generated
  pure (generated ++ stubs)
  where
    declarations = planDataDeclarations testing
    bits = planMachineBits testing
    representations = bindingRepresentations plan
    mappings = resolvedTypes representations
    generators = resolvedGenerators representations
    layout = D.selectLayout minify (D.Pretty 100)
    render doc = D.render layout (D.text "// Generated by LawSpec. Do not edit." <> D.hardline <> doc <> D.hardline)
    reference = intercalate "." . referenceParts
    split c s = case break (==c) s of (a,[]) -> [a]; (a,_:b) -> a:split c b
    cap [] = []; cap (a:rest) = toUpper a:rest
    call = E.call
    method value name args = D.group (value <> D.text ("." ++ name ++ "(") <>
      D.nest 4 (D.softbreak <> D.group (D.commaSep args)) <> D.text ")")
    applied name [] = D.text name
    applied name args = D.group (D.text (name ++ "<") <>
      D.nest 8 (D.softbreak <> D.group (D.commaSep args)) <> D.text ">")
    mapping d = find ((== C.dataId d) . C.dataId . resolvedDeclaration) mappings
    nativeName d = maybe (J.javaDataName declarations (C.dataId d)) (Right . reference . resolvedNativeType) (mapping d)
    variable ps v = maybe (Left "unbound native codec parameter") Right (lookup v ps)
    argument f (C.TypeArgument ty) = f ty
    argument _ _ = Left "indexed native codec arguments are unsupported"
    ref ps (C.TypeVariable v) = (\(_,c) -> D.text (c ++ ".type()")) <$> variable ps v
    ref ps (C.Constructor name args) = call "new LawSpecSchema.Named" . (E.quoted name :) <$> mapM (argument (ref ps)) args
    ref _ _ = Left "function cannot cross native codec"
    nativeType ps ty = case ty of
      C.TypeVariable v -> D.text . fst <$> variable ps v
      C.Constructor name args -> do
        children <- mapM (argument (nativeType ps)) args
        case find ((== C.Id name) . C.dataId) declarations of
          Just d -> (\n -> applied n children) <$> nativeName d
          Nothing | name `elem` ["List","Maybe","Either"] -> pure (applied
            (if name == "List" then "java.util.List" else "lawspec.runtime.LawSpecRuntime." ++ name) children)
          Nothing | name `elem` ["Nullable","Optional"] -> pure (D.text "lawspec.runtime.LawSpecRuntime.Value")
          _ -> J.javaDataTypeDoc declarations ty
      _ -> Left "function cannot cross native codec"
    generatorStubs generated = do
      let requested = filter resolvedGeneratorStub generators
          owner = init . referenceParts . resolvedGeneratorFactory
          owners = nub (map owner requested)
          classPath = intercalate "/"
          normalize = map toLower
          conflicts a b = let x = normalize a; y = normalize b
            in x == y || (a ++ "/") `isPrefixOf` b || (b ++ "/") `isPrefixOf` a
          existing = [take (length relative - 5) relative | file <- generated,
            prefix <- ["src/main/java/","src/test/java/"], prefix `isPrefixOf` artifactPath file,
            let relative = drop (length prefix) (artifactPath file)]
          application = [classPath (referenceParts ref) | ref <-
            map resolvedNativeType mappings ++ map resolvedNativeConstructor (concatMap resolvedConstructors mappings)] ++
            [classPath (init parts) | ref <- map snd (bindingFunctions plan) ++
              [ref | mapping <- mappings, Just hook <- [resolvedCodec mapping], ref <- [codecToNative hook,codecFromNative hook]],
              let parts = referenceParts ref, length parts >= 2]
      forM owners $ \parts -> do
        unless (length parts >= 2) (Left "Java generator scaffold requires a package, class and method")
        unless (head parts /= "java") (Left "Java generator scaffold cannot use the reserved java package")
        let name = last parts
            members = filter ((== parts) . owner) requested
            path = classPath parts
        unless (not (any (conflicts path) ("org/jetbrains/jetCheck/Generator":existing ++ application)) &&
          not (any (\other -> other /= parts && conflicts path (classPath other)) owners))
          (Left "Java generator scaffold class conflicts with another class or package")
        unless (name `notElem` (words "java org lawspec" ++
          [head ref | mapping <- mappings, let ref = referenceParts (resolvedNativeType mapping), not (null ref)]))
          (Left "Java generator scaffold class shadows a signature package")
        bodies <- forM members $ \generator -> do
          let methodName = last (referenceParts (resolvedGeneratorFactory generator))
              parameters = [(C.Id ("scaffold::" ++ show i),("T" ++ show i,"")) |
                i <- [0 .. generatorParameterCount generator - 1]]
              ty = C.Constructor (C.idText (resolvedGeneratorType generator))
                [C.TypeArgument (C.TypeVariable identity) | (identity,_) <- parameters]
          unless (not (null parameters) || methodName `notElem`
            words "clone finalize getClass hashCode notify notifyAll toString wait")
            (Left "Java generator scaffold method conflicts with java.lang.Object")
          native <- nativeType parameters ty
          let raw = D.render D.Compact native
              result = if raw `elem` words "Byte Short Integer Long Float Double Boolean Character String Object"
                then D.text ("java.lang." ++ raw) else native
              generic = if null parameters then mempty else D.text ("<" ++ intercalate ", " [t | (_,(t,_)) <- parameters] ++ "> ")
              signature = D.text "public static " <> generic <> applied "org.jetbrains.jetCheck.Generator" [result] <>
                D.text " " <> call methodName
                  [applied "org.jetbrains.jetCheck.Generator" [D.text t] <> D.text (" argument" ++ show i) |
                    (i,(_,(t,_))) <- zip [0::Int ..] parameters]
          pure (signature <> D.text " " <> D.block 2 (D.text "throw " <>
            call "new java.lang.UnsupportedOperationException"
              [E.quoted ("Implement generator for " ++ C.idText (resolvedGeneratorType generator))] <> D.text ";"))
        pure (Artifact ("src/test/java/" ++ path ++ ".java") (D.render (D.Pretty 100)
          (D.text "// User-owned native generator factories. Implement before running properties." <>
           D.hardline <> D.text ("package " ++ intercalate "." (init parts) ++ ";") <> D.hardline <> D.hardline <>
           D.text ("public final class " ++ name ++ " ") <> D.block 2
             (D.text ("private " ++ name ++ "() {}") <> D.hardline <> D.hardline <>
              D.joinWith (D.hardline <> D.hardline) bodies) <> D.hardline)) "user" "test")
    codec ps schema width ty = case ty of
      C.TypeVariable v -> D.text . snd <$> variable ps v
      C.Constructor name args -> do
        children <- mapM (argument (codec ps schema width)) args
        case lookup (C.Id name) [(C.dataId d,i) | (i,d) <- zip [0::Int ..] declarations] of
          Just i -> pure (call ("lawspec.runtime.LawSpecNativeCodecs.type" ++ show i)
            ([schema,width,D.text "symbols"] ++ children))
          Nothing | name `elem` ["List","Maybe","Either"] -> pure (method schema (map toLower name) (children ++ [width,D.text "symbols"]))
          Nothing | name `elem` ["Nullable","Optional","Unit"] || nativeRepresentation "java" name == Nothing -> do
            tyRef <- if null ps then D.text <$> J.javaTypeReference ty else ref ps ty
            pure (method schema "supported" [tyRef,width,D.text "symbols"])
          Nothing -> do
            native <- nativeType ps ty
            pure (method schema "scalar" [E.quoted name,width,native <> D.text ".class"])
      _ -> Left "function cannot cross native codec"
    codecMethod (i,d) = do
      let ps = zip (C.dataParameters d) [("T" ++ show n,"type" ++ show n) | n <- [0::Int ..]]
          args = [D.text t | (_,(t,_)) <- ps]
          ty = C.Constructor (C.idText (C.dataId d)) [C.TypeArgument (C.TypeVariable v) | (v,_) <- ps]
      native <- nativeType ps ty
      tyRef <- ref ps ty
      arms <- forM (C.dataConstructors d) $ \c -> do
        let mapped = mapping d >>= \m -> find ((== C.constructorId c) . C.constructorId . resolvedConstructor) (resolvedConstructors m)
        base <- maybe ((++ ("." ++ C.constructorName c ++ "Case")) <$> J.javaDataName declarations (C.dataId d))
          (Right . reference . resolvedNativeConstructor) mapped
        codecs <- mapM (codec ps (D.text "schema") (D.text "bits") . C.binderType) (C.constructorFields c)
        let unit = maybe False ((== UnitConstructor) . resolvedConstructorStyle) mapped
            nativeFields = maybe (map C.binderName (C.constructorFields c)) (map snd . resolvedFields) mapped
            access field = D.text ("item." ++ field ++ maybe "" (const "()") mapped)
            encoded = [call "LawSpecSchema.encodeField" [bridge,access field,
              E.quoted (C.idText (C.constructorId c) ++ "." ++ C.binderName logical)] |
                (bridge,field,logical) <- zip3 codecs nativeFields (C.constructorFields c)]
            encode = D.text "if (" <> (if unit then D.text ("value == " ++ base)
              else D.text ("value.getClass() == " ++ base ++ ".class")) <> D.text ") " <>
              D.block 2 ((if unit then mempty else D.text "var item = (" <> applied base args <> D.text ") value;" <> D.hardline) <>
                D.text "return " <> call "schema.construct" [D.text "type",E.quoted (C.idText (C.constructorId c)),call "java.util.List.of" encoded,D.text "bits",D.text "symbols"] <> D.text ";")
            decoded = [method bridge "decode" [D.text ("data.fields().get(" ++ show n ++ ")")] | (n,bridge) <- zip [0::Int ..] codecs]
            decode = D.group (D.text "case " <> E.quoted (C.idText (C.constructorId c)) <> D.text " ->" <>
              D.nest 4 (D.softline <> (if unit then D.text base else call ("new " ++ base ++ if null ps then "" else "<>") decoded)) <> D.text ";")
        pure (encode,decode)
      let failure = D.text "throw new IllegalArgumentException(\"invalid native constructor\");"
          encoder = D.text "value -> " <> D.block 2 (D.text "java.util.Objects.requireNonNull(value);" <> D.hardline <>
            D.joinWith D.hardline (map fst arms ++ [failure]))
          decoder = D.text "value -> " <> D.block 2 (if null arms then failure else
            D.text "var data = (LawSpecRuntime.Data) value.data();" <> D.hardline <>
            D.text "return switch (data.tag()) " <> D.block 2
              (D.joinWith D.hardline (map snd arms ++ [D.text "default -> " <> failure])) <> D.text ";")
      (setup, encodeBody, decodeBody) <- case mapping d >>= resolvedCodec of
        Nothing -> pure (mempty, encoder, decoder)
        Just hook -> do
          name <- J.javaDataName declarations (C.dataId d)
          let simple = last (split '.' name)
              codecName = case simple of [] -> "dataCodec"; first:rest -> toLower first : rest ++ "Codec"
              canonical = call ("LawSpecDataCodecs." ++ codecName)
                ([D.text "schema",D.text "bits",D.text "symbols"] ++
                 [call "schema.supported" [D.text (v ++ ".type()"),D.text "bits",D.text "symbols"] |
                   (_,(_,v)) <- ps])
              converters methodName = [D.text (v ++ "::" ++ methodName) | (_,(_,v)) <- ps]
              contextual direction expression = D.text "value -> " <> D.block 2
                (D.text "try " <> D.block 2 (D.text "return " <> expression <> D.text ";") <>
                 D.text " catch (RuntimeException error) " <> D.block 2
                  (D.text "throw " <> call "new IllegalArgumentException"
                    [E.quoted ("native codec " ++ C.idText (C.dataId d) ++ " " ++ direction ++ ": ") <>
                      D.text " + error.getMessage()",D.text "error"] <> D.text ";"))
              encodeHook = call "canonicalCodec.encode"
                [call (reference (codecFromNative hook)) (D.text "value" : converters "encode")]
              decodeHook = call "java.util.Objects.requireNonNull"
                [call (reference (codecToNative hook))
                  (call "canonicalCodec.decode" [D.text "value"] : converters "decode")]
          pure (D.text "var canonicalCodec = " <> canonical <> D.text ";" <> D.hardline,
            contextual "fromNative" encodeHook, contextual "toNative" decodeHook)
      pure (D.text "public static " <> (if null ps then mempty else applied "" args <> D.text " ") <>
        applied "LawSpecSchema.Codec" [native] <> D.text " " <> call ("type" ++ show i)
          ([D.text "LawSpecSchema schema",D.text "int bits",D.text "java.util.Map<String, Object> symbols"] ++
           [applied "LawSpecSchema.Codec" [D.text t] <> D.text (" " ++ v) | (_,(t,v)) <- ps]) <>
        D.text " " <> D.block 2 (D.text "var type = " <> tyRef <> D.text ";" <> D.hardline <> setup <>
          D.text "return schema.codec(" <> D.nest 4
            (D.hardline <> D.joinWith (D.text "," <> D.hardline)
              [D.text "type",D.text "bits",D.text "symbols",encodeBody,decodeBody]) <> D.text ");"))
