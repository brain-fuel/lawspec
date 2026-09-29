-- Application bindings reuse the Kotlin schema codecs and canonical adapter ABI.
module LawSpec.KotlinNativeBinding (emitBindings) where

import Control.Monad (forM, unless)
import Data.Char (toUpper, toLower)
import Data.List (intercalate, nub, isPrefixOf)
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Backend (unitName, inputs, inputType)
import qualified LawSpec.CoreNativeScalarEmit as Scalar
import qualified LawSpec.JavaDefinitions as Definitions
import LawSpec.Testing
import LawSpec.NativeBinding
import LawSpec.NativeRequest
import qualified LawSpec.KotlinData as K
import qualified LawSpec.KotlinExpr as E
import qualified LawSpec.Code.Doc as D
import LawSpec.RuntimeSources (runtimeSource)

emitBindings :: Bool -> BindingPlan -> Plan -> [Artifact] -> Either String [Artifact]
emitBindings minify plan testing files = do
  unless (bindingRustCrate plan == Nothing) (Left "rustCrate is only valid for Rust bindings")
  unless (null mappings || not (null (bindingFunctions plan)) || not (null generators)) (Left "native types require function bindings")
  mapM_ (mapM_ K.identifier . referenceParts) ([r | (_,r) <- bindingFunctions plan] ++
    [resolvedNativeType m | m <- mappings] ++ [resolvedNativeConstructor c | m <- mappings,c <- resolvedConstructors m] ++
    [ref | m <- mappings, Just hook <- [resolvedCodec m], ref <- [codecToNative hook, codecFromNative hook]])
  mapM_ (K.identifier . snd) [f | m <- mappings,c <- resolvedConstructors m,f <- resolvedFields c]
  codecs <- K.emitKotlinNativeCodecs layout declarations mappings
  bridges <- fmap concat $ forM (plannedUnits testing) $ \p -> do
    let unit = plannedUnit p
        definitions = map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions unit)
        adapters = [d | d <- C.unitDeclarations unit,C.declarationId d `notElem` definitions]
        bound d = lookup (C.declarationId d) [(C.declarationId a,r) | (a,r) <- bindingFunctions plan]
        parts = split '.' (unitName unit)
    mapM_ K.identifier parts
    if not (any (maybe False (const True) . bound) adapters) then pure [] else do
      unless (all (maybe False (const True) . bound) adapters) (Left "a Kotlin bound unit must map every adapter")
      bodies <- forM adapters $ \d -> do
        let (args,result) = C.functionType (C.declarationType d)
            Just ref = bound d
        argTypes <- mapM (K.kotlinDataTypeDoc declarations) args
        resultType <- K.kotlinDataTypeDoc declarations result
        canonical <- mapM (K.kotlinCodecDocWithContext (D.text "symbols") declarations) args
        native <- mapM (K.kotlinNativeCodecDoc declarations) args
        canonicalResult <- K.kotlinCodecDocWithContext (D.text "symbols") declarations result
        nativeResult <- K.kotlinNativeCodecDoc declarations result
        let values = [D.text ("value" ++ show i) | i <- [0::Int ..length args-1]]
            converted = [method n "decode" [method c "encode" [v]] | (n,c,v) <- zip3 native canonical values]
            application = E.call (intercalate "." (referenceParts ref)) converted
            resultBody = if result == C.scalarType "Unit" then application <> D.hardline <> D.text "Unit" else
              D.text "val result = " <> application <> D.hardline <>
              method canonicalResult "decode" [method nativeResult "encode" [D.text "result"]]
        pure (D.text "fun " <> E.call (C.declarationName d) [v <> D.text ": " <> t | (t,v) <- zip argTypes values] <>
          D.text ": " <> resultType <> D.text " " <> D.block 4
          (D.text "val symbols = mutableMapOf<String, Any>()" <> D.hardline <>
           D.text "return try " <> D.block 4 resultBody <> D.text " catch (error: RuntimeException) " <>
           D.block 4 (D.text "throw " <> E.call "IllegalArgumentException"
             [E.quoted ("native binding " ++ C.idText (C.declarationId d) ++ ": ") <> D.text " + error.message",D.text "error"])))
      let name = concatMap cap (split '_' (last parts))
          package = intercalate "." (init parts)
          path = "src/main/kotlin/" ++ concatMap (++ "/") (init parts) ++ name ++ ".kt"
          header = (if null package then mempty else D.text ("package " ++ package) <> D.hardline <> D.hardline) <>
            D.text "import lawspec.runtime.*" <> D.hardline <> D.hardline
          source = header <> D.text ("object " ++ name ++ " ") <> D.block 4
            (D.text "private val schema = LawSpecDataSchema.create()" <> D.hardline <>
             D.text ("private val bits = " ++ show bits) <> D.hardline <> D.hardline <>
             D.joinWith (D.hardline <> D.hardline) bodies)
      pure [Artifact path (render source) "generated" "source"]
  dataFiles <- if any ((== "src/main/java/lawspec/runtime/LawSpecDataSchema.java") . artifactPath) files then pure []
    else K.emitKotlinDataWithProfile bits layout declarations
  generatorFiles <- if null generators then pure [] else do
    let roots = [inputType input | unit <- plannedUnits testing, property <- plannedProperties unit, input <- inputs property]
    concrete <- if any ((>0) . generatorParameterCount) generators
      then reachableGeneratorTypes declarations representations roots else pure []
    methods <- forM (zip [0::Int ..] generators) $ \(index,generator) -> do
      mapM_ K.identifier (referenceParts (resolvedGeneratorFactory generator))
      let family = C.idText (resolvedGeneratorType generator)
          instances = if generatorParameterCount generator == 0 then [C.Constructor family []]
            else [ty | ty@(C.Constructor name _) <- concrete, name == family]
      branches <- forM instances $ \ty -> do
        let args = case ty of C.Constructor _ args -> [t | C.TypeArgument t <- args]; _ -> []
        children <- forM (zip [0::Int ..] args) $ \(i,child) -> do
          bridge <- K.kotlinNativeCodecDoc declarations child
          pure (D.text ("val child" ++ show i ++ " = ") <>
            E.call "LawSpecKotlinStrategies.nativeArguments" [bridge,D.text ("arguments[" ++ show i ++ "]")])
        bridge <- K.kotlinNativeCodecDoc declarations ty
        tyRef <- E.reference ty
        pure (D.text "if (type == " <> tyRef <> D.text ") " <> D.block 4
          (D.joinWith D.hardline (children ++
            [D.text "val source = " <> E.call (intercalate "." (referenceParts (resolvedGeneratorFactory generator)))
              [D.text ("child" ++ show i) | i <- [0..length args-1]],
             D.text "return " <> E.call "LawSpecKotlinStrategies.nativeValues" [bridge,D.text "source"]])))
      pure (D.text "private fun " <> E.call ("factory" ++ show index) (map D.text
        ["schema: LawSpecSchema", "type: LawSpecSchema.Named", "bits: Int", "symbols: MutableMap<String, Any>",
         "arguments: List<Arb<LawSpecRuntime.Value>>"]) <>
        D.text ": Arb<LawSpecRuntime.Value> " <> D.block 4 (D.joinWith D.hardline (branches ++
          [D.text "throw IllegalArgumentException(\"unplanned native generator instantiation: \" + type)"])))
    let entries = [E.quoted (C.idText (resolvedGeneratorType generator)) <>
          D.text " to " <> E.call "LawSpecKotlinStrategies.NativeFactory" [D.text ("::factory" ++ show i)] |
            (i,generator) <- zip [0::Int ..] generators]
        registry = D.text "fun factories(): Map<String, LawSpecKotlinStrategies.NativeFactory> = " <>
          E.call "mapOf" entries
        helper = Artifact "src/test/kotlin/lawspec/testing/LawSpecNativeGenerators.kt" (render
          (D.text "package lawspec.testing" <> D.hardline <> D.hardline <>
           D.text "import io.kotest.property.Arb" <> D.hardline <>
           D.text "import lawspec.runtime.*" <> D.hardline <> D.hardline <>
           D.text "object LawSpecNativeGenerators " <> D.block 4
            (D.joinWith (D.hardline <> D.hardline) (registry:methods)))) "generated" "test"
    emitted <- either (Left . show) Right $ concat <$> mapM (\unit ->
      Scalar.nativeScalarEmitWithNativeGenerators True minify declarations
        (Definitions.definitionCalls (map plannedUnit (plannedUnits testing))) bits "kotlin"
        (plannedUnit unit) (plannedProperties unit))
        [unit | unit <- plannedUnits testing, not (null (plannedProperties unit))]
    pure (helper : [file | file <- emitted,artifactPlacement file == "test"] ++
      [Artifact path (runtimeSource key) "generated" "test" |
        (path,key) <- [("src/test/kotlin/lawspec/testing/LawSpecKotlinStrategies.kt","kotlin-data-strategies"),
          ("src/test/kotlin/lawspec/testing/LawSpecStrategies.kt","kotlin-strategies")],
        not (any ((== path) . artifactPath) files)])
  let support = Artifact "src/main/kotlin/lawspec/runtime/LawSpecNativeCodecs.kt" codecs "generated" "source"
      runtime = [Artifact "src/main/java/lawspec/runtime/LawSpecRuntime.java" (runtimeSource "java") "generated" "source" |
        not (any ((== "src/main/java/lawspec/runtime/LawSpecRuntime.java") . artifactPath) files)]
  unless (all ((/= artifactPath support) . artifactPath) files) (Left "unit shadows native codec support")
  let generated = [f | f <- files,artifactPath f `notElem` map artifactPath (bridges ++ generatorFiles)] ++ dataFiles ++ runtime ++ [support] ++ bridges ++ generatorFiles
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
    split c s = case break (==c) s of (a,[]) -> [a]; (a,_:b) -> a:split c b
    cap [] = []; cap (a:rest) = toUpper a:rest
    method value name args = value <> D.text "." <> E.call name args

    generatorStubs generated = do
      let requested = filter resolvedGeneratorStub generators
          owner = init . referenceParts . resolvedGeneratorFactory
          owners = nub (map owner requested)
          classPath = intercalate "/"
          conflicts a b = map toLower a == map toLower b ||
            (a ++ "/") `isPrefixOf` b || (b ++ "/") `isPrefixOf` a
          existing = [take (length relative - suffix) relative | file <- generated,
            (prefix,suffix) <- [("src/main/kotlin/",3),("src/test/kotlin/",3),("src/main/java/",5)],
            prefix `isPrefixOf` artifactPath file, let relative = drop (length prefix) (artifactPath file)]
          application = [classPath (referenceParts ref) | ref <- map resolvedNativeType mappings ++
            map resolvedNativeConstructor (concatMap resolvedConstructors mappings)] ++
            [classPath (init parts) | ref <- map snd (bindingFunctions plan) ++
              [r | mapping <- mappings, Just hook <- [resolvedCodec mapping], r <- [codecToNative hook,codecFromNative hook]],
              let parts = referenceParts ref, length parts >= 3]
      forM owners $ \parts -> do
        unless (length parts >= 2) (Left "Kotlin generator scaffold requires a package, object and function")
        unless (head parts `notElem` ["kotlin","java"])
          (Left "Kotlin generator scaffold cannot use a reserved runtime package")
        let name = last parts
            path = classPath parts
        unless (not (any (conflicts path) ("io/kotest/property/Arb":existing ++ application)) &&
          not (any (\other -> other /= parts && conflicts path (classPath other)) owners))
          (Left "Kotlin generator scaffold object conflicts with another class or package")
        unless (name `notElem` (words "java kotlin io lawspec" ++
          [head ref | mapping <- mappings, let ref = referenceParts (resolvedNativeType mapping), not (null ref)]))
          (Left "Kotlin generator scaffold object shadows a signature package")
        bodies <- forM (filter ((== parts) . owner) requested) $ \generator -> do
          let methodName = last (referenceParts (resolvedGeneratorFactory generator))
              parameters = [(C.Id ("scaffold::" ++ show i),"T" ++ show i) | i <- [0 .. generatorParameterCount generator - 1]]
              ty = C.Constructor (C.idText (resolvedGeneratorType generator))
                [C.TypeArgument (C.TypeVariable identity) | (identity,_) <- parameters]
          unless (not (null parameters) || methodName `notElem` words "hashCode toString")
            (Left "Kotlin generator scaffold function conflicts with kotlin.Any")
          native <- K.kotlinNativeTypeDoc declarations mappings parameters ty
          let generic = if null parameters then mempty else D.text ("<" ++ intercalate ", " (map snd parameters) ++ "> ")
              arb value = D.group (D.text "io.kotest.property.Arb<" <> D.nest 4 (D.softbreak <> value) <> D.text ">")
              signature = D.text "fun " <> generic <> E.call methodName
                [D.text ("argument" ++ show i ++ ": ") <> arb (D.text name) | (i,(_,name)) <- zip [0::Int ..] parameters] <>
                D.text ": " <> arb native
          pure (signature <> D.text " " <> D.block 4 (D.text "throw " <>
            E.call "kotlin.NotImplementedError" [E.quoted ("Implement generator for " ++ C.idText (resolvedGeneratorType generator))]))
        pure (Artifact ("src/test/kotlin/" ++ path ++ ".kt") (D.render (D.Pretty 100)
          (D.text "// User-owned native generator factories. Implement before running properties." <> D.hardline <>
           D.text ("package " ++ intercalate "." (init parts)) <> D.hardline <> D.hardline <>
           D.text ("object " ++ name ++ " ") <> D.block 4 (D.joinWith (D.hardline <> D.hardline) bodies) <> D.hardline)) "user" "test")
