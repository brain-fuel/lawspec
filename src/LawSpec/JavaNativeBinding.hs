-- | Typed application codecs keep validation in the shared logical schema.
module LawSpec.JavaNativeBinding (emitBindings, emitBindingsProduct) where

import Control.Monad (forM, unless)
import Data.List (intercalate, find, nub, isPrefixOf)
import Data.Char (toUpper, toLower)
import qualified LawSpec.Core as C
import LawSpec.Common
import qualified LawSpec.JvmProduct as Product
import qualified LawSpec.JavaAbi as Abi
import LawSpec.JavaTestStyle (TestStyle(..), propertyPackage)
import LawSpec.Backend (unitName, inputs, inputType)
import LawSpec.Testing
import LawSpec.NativeBinding
import LawSpec.NativeRequest
import qualified LawSpec.JavaData as J
import LawSpec.AbilityNames (interfaceName, ownAbilities, ownerName)
import LawSpec.AbilityEmit.Java (abilitiesClassOf)
import qualified LawSpec.JavaExpr as E
import qualified LawSpec.JavaLayout as JL
import qualified LawSpec.Code.Doc as D
import LawSpec.Scalar (nativeRepresentation)
import qualified LawSpec.JavaDefinitions as Definitions
import qualified LawSpec.CoreNativeScalarEmit as Scalar
import qualified LawSpec.JavaTestingRuntime as JavaTestingRuntime
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.Collections (collectionContainer)
import LawSpec.Time (isDurationType)
import LawSpec.ModelTests (modelTestProductWithBackends)

-- | Bound adapters call the user's Java code directly, through generated
-- conversions. ref:DEC-native-bindings-typed-identity
emitBindings :: Bool -> BindingPlan -> Plan -> [Artifact] -> Either String [Artifact]
emitBindings minify plan testing files =
  Product.jvmArtifacts <$> emitBindingsProduct JUnit minify plan testing (Product.files files)

emitBindingsProduct :: TestStyle -> Bool -> BindingPlan -> Plan -> Product.JvmProduct -> Either String Product.JvmProduct
emitBindingsProduct javaStyle minify plan testing product = do
  unless (bindingRustCrate plan == Nothing) (Left "rustCrate is only valid for Rust bindings")
  unless (null mappings || not (null (bindingFunctions plan)) || not (null (bindingCalls plan)) || not (null generators)
      || not (null (bindingActors plan)))
    (Left "native types require function or generator bindings")
  mapM_ J.identifier [name | (_,MethodCall name) <- bindingCalls plan]
  mapM_ (mapM_ J.identifier . referenceParts) ([ref | (_,ref) <- bindingFunctions plan] ++
    [r | (_,ConstructorCall r) <- bindingCalls plan] ++
    [resolvedNativeType m | m <- mappings] ++ [resolvedNativeConstructor c | m <- mappings,c <- resolvedConstructors m] ++
    [ref | m <- mappings, Just hook <- [resolvedCodec m], ref <- [codecToNative hook, codecFromNative hook]])
  mapM_ (J.identifier . snd) [f | m <- mappings,c <- resolvedConstructors m,f <- resolvedFields c]
  -- Built-in collections and durations use the schema's own codecs.
  methods <- mapM codecMethod [(i,d) | (i,d) <- zip [0::Int ..] declarations, builtin (C.idText (C.dataId d)) == Nothing]
  let support = Artifact "src/main/java/lawspec/runtime/LawSpecNativeCodecs.java"
        (render (D.text "package lawspec.runtime;" <> D.hardline <> D.hardline <>
          D.text "public final class LawSpecNativeCodecs" <> D.hardline <> D.block 2
          (D.joinWith (D.hardline <> D.hardline)
            (D.text "private LawSpecNativeCodecs() {}":methods)))) "generated" "source"
  bridges <- fmap concat $ forM (plannedUnits testing) $ \p -> do
    let unit = plannedUnit p
        definitions = map (C.declarationId . C.definitionDeclaration) (C.unitDefinitions unit)
        adapters = [d | d <- C.unitDeclarations unit,C.declarationId d `notElem` definitions]
        bound d = lookup (C.declarationId d) ([(C.declarationId a,StaticCall r) | (a,r) <- bindingFunctions plan] ++
          [(C.declarationId a,c) | (a,c) <- bindingCalls plan])
        -- An adapter a native actor stands for: the actor runs it, so its
        -- bridge only says so.
        actorBound d = lookup (C.declarationId d)
          [(adapter,actor) | actor <- bindingActors plan, adapter <- resolvedActorAdapters actor]
        covered d = bound d /= Nothing || actorBound d /= Nothing
    mapM_ J.identifier (split '.' (unitName unit))
    if not (any covered adapters) then pure [] else do
      unless (all covered adapters) (Left "a Java bound unit must map every adapter")
      bodies <- forM adapters $ \d -> case actorBound d of
       Just actor -> do
        let (args,result) = C.functionType (C.declarationType d)
        argTypes <- mapM (J.javaDataTypeDoc declarations) args
        resultType <- if result == C.scalarType "Unit" then pure (D.text "void") else J.javaDataTypeDoc declarations result
        let values = [D.text ("value" ++ show i) | i <- [0::Int ..length args-1]]
        pure (D.group (D.text "public static " <> resultType <>
          D.nest 4 (D.softline <> call (C.declarationName d) [t <> D.text " " <> v | (t,v) <- zip argTypes values])) <>
          D.hardline <> D.block 2 (D.text "throw " <> call "new UnsupportedOperationException"
            [E.quoted (C.idText (C.declarationId d) ++ " runs in the native actor bound to " ++
              actorIdentity actor ++ "; LawSpec checks it through that actor")] <> D.text ";"))
       Nothing -> do
        let (args,result) = C.functionType (C.declarationType d)
            Just ref = bound d
        argTypes <- mapM (J.javaDataTypeDoc declarations) args
        resultType <- J.javaDataTypeDoc declarations result
        canonical <- mapM (J.javaCodecDocWithContext (D.text "symbols") declarations bits) args
        native <- mapM (codec [] (D.text "SCHEMA") (D.text (show bits))) args
        canonicalResult <- J.javaCodecDocWithContext (D.text "symbols") declarations bits result
        nativeResult <- codec [] (D.text "SCHEMA") (D.text (show bits)) result
        nativeResultType <- nativeType [] result
        let values = [D.text ("value" ++ show i) | i <- [0::Int ..length args-1]]
            -- An adapter that uses abilities gets their handlers first, as
            -- the generated interfaces.
            handlerParams = [ (D.text (interfaceType a), D.text ("handler" ++ show i))
                            | (i, a) <- zip [0::Int ..] (C.declarationUses d), not (C.isFail a) ]
            converted = map snd handlerParams ++ [method n "decode" [method c "encode" [v]] | (n,c,v) <- zip3 native canonical values]
            handleArgument = lookup True [(isHandle t,i) | (i,t) <- zip [0::Int ..] args]
        application <- case ref of
          StaticCall r -> pure (call (reference r) converted)
          -- A method of the first handle argument, given the rest.
          MethodCall name -> case handleArgument of
            Just i -> do
              receiverType <- nativeType [] (args !! i)
              let plain = drop (length handlerParams) converted
              pure (D.text "((" <> receiverType <> D.text ") " <> plain !! i <> D.text ")" <>
                call ("." ++ name) (map snd handlerParams ++ [v | (j,v) <- zip [0..] plain, j /= i]))
            Nothing -> Left ("method binding without a handle argument: " ++ C.idText (C.declarationId d))
          ConstructorCall r -> pure (call ("new " ++ reference r)
            [v | (t,v) <- zip args (drop (length handlerParams) converted), t /= C.scalarType "Unit"])
        let static = case ref of StaticCall _ -> True; _ -> False
            returned = D.text "return " <> method canonicalResult "decode" [method nativeResult "encode" [D.text "result"]] <> D.text ";"
        maybeElement <- case result of
          C.Constructor "Maybe" [C.TypeArgument element] | not static -> Just <$> nativeType [] element
          _ -> pure Nothing
        let resultBody
              | result == C.scalarType "Unit" = application <> D.text ";"
              | static = assigned (D.text "var result") application <> D.hardline <> returned
              -- A method's null is Nothing; anything else is Just.
              | Just element <- maybeElement =
                  assigned (D.text "java.lang.Object found") application <> D.hardline <>
                  nativeResultType <> D.text " result = found == null" <> D.nest 4 (D.hardline <>
                    D.text "? new lawspec.runtime.LawSpecRuntime.Absent<>()" <> D.hardline <>
                    D.text ": new lawspec.runtime.LawSpecRuntime.Present<>((" <> element <> D.text ") found);") <> D.hardline <> returned
              | otherwise = assigned (nativeResultType <> D.text " result") (D.group (D.text "(" <> nativeResultType <> D.text ")" <> D.nest 4 (D.softline <> application))) <> D.hardline <> returned
        -- An async bridge converts the native task's result once it completes.
        -- A constructor is called at once, and its bridge returns a completed task.
        let async = C.declarationAsync d
            unit = result == C.scalarType "Unit"
            boxedResult = if unit then D.text "lawspec.runtime.LawSpecRuntime.Value" else D.text (boxed (D.render D.Compact resultType))
            future = D.text "java.util.concurrent.CompletableFuture"
            converted' found
              | unit = D.text "lawspec.runtime.LawSpecRuntime.absent(\"Unit\")"
              | Just element <- maybeElement = D.text "(" <> found <> D.text " == null" <> D.nest 4 (D.hardline <>
                  D.text "? " <> method canonicalResult "decode" [method nativeResult "encode" [D.text "new lawspec.runtime.LawSpecRuntime.Absent<>()"]] <> D.hardline <>
                  D.text ": " <> method canonicalResult "decode" [method nativeResult "encode"
                    [D.text "new lawspec.runtime.LawSpecRuntime.Present<>((" <> element <> D.text ") " <> found <> D.text ")"]] <> D.text ")")
              | static = method canonicalResult "decode" [method nativeResult "encode" [found]]
              | otherwise = method canonicalResult "decode" [method nativeResult "encode" [D.text "(" <> nativeResultType <> D.text ") " <> found]]
            asyncBody = case ref of
              ConstructorCall _ -> assigned (D.text "java.lang.Object found") application <> D.hardline <>
                D.text "return " <> future <> D.text ".completedFuture(" <> converted' (D.text "found") <> D.text ");"
              _ -> D.text "return " <> application <>
                D.text ".thenApply(found -> " <> D.nest 4 (converted' (D.text "found")) <> D.text ");"
        pure (D.group (D.text "public static " <> (if async then future <> D.text "<" <> boxedResult <> D.text ">"
          else if unit then D.text "void" else resultType) <>
          D.nest 4 (D.softline <> call (C.declarationName d) ([t <> D.text " " <> v | (t,v) <- handlerParams] ++ [t <> D.text " " <> v | (t,v) <- zip argTypes values]))) <>
          D.hardline <> D.block 2 (D.text "var symbols = new java.util.HashMap<String, Object>();" <> D.hardline <>
            D.text "try" <> D.hardline <> D.block 2 (if async then asyncBody else resultBody) <> D.hardline <> D.group (D.text "catch (" <> D.nest 4 (D.softbreak <> D.group (D.text "IllegalArgumentException" <> D.nest 4 (mconcat [D.softline <> D.text ("| " ++ e) | e <- ["IllegalStateException", "ClassCastException", "ArithmeticException error"]]))) <> D.text ")") <> D.hardline <>
            D.block 2 (D.text "throw " <> call "new IllegalArgumentException"
              [E.quoted ("native binding " ++ C.idText (C.declarationId d) ++ ": ") <> D.text " + error.getMessage()",D.text "error"] <> D.text ";")))
      -- Each bound production handler, wrapped in the generated interface:
      -- its operations' values cross with the native codecs.
      wrappers <- forM [(a, r) | a <- ownAbilities unit, Just r <- [lookup (C.Id (C.abilityKey (C.abilityInstance a))) (bindingHandlers plan)]] $ \(a, r) -> do
        operations <- forM (C.abilityOperations a) $ \(op, ty) -> do
          let (args, result) = C.functionType ty
          types <- mapM (J.javaDataTypeDoc declarations) args
          resultType <- if result == C.scalarType "Unit" then pure (D.text "void") else J.javaDataTypeDoc declarations result
          canonical <- mapM (J.javaCodecDocWithContext (D.text "symbols") declarations bits) args
          native <- mapM (codec [] (D.text "SCHEMA") (D.text (show bits))) args
          canonicalResult <- J.javaCodecDocWithContext (D.text "symbols") declarations bits result
          nativeResult <- codec [] (D.text "SCHEMA") (D.text (show bits)) result
          let values = [D.text ("value" ++ show i) | i <- [0::Int ..length args-1]]
              invocation = call ("inner." ++ op) [method n "decode" [method c "encode" [v]] | (n,c,v) <- zip3 native canonical values]
              body = if result == C.scalarType "Unit" then invocation <> D.text ";"
                else D.text "return " <> method canonicalResult "decode" [method nativeResult "encode" [invocation]] <> D.text ";"
          pure (D.text "@Override" <> D.hardline <> D.text "public " <> resultType <> D.text " " <>
            call op [t <> D.text " " <> v | (t,v) <- zip types values] <> D.hardline <>
            D.block 2 (D.text "var symbols = new java.util.HashMap<String, Object>();" <> D.hardline <> body))
        let name = interfaceName a ++ "Bound"
        pure (D.text ("/** The bound production handler of " ++ C.abilityName a ++ ", " ++ reference r ++ ", as the generated interface. */") <> D.hardline <>
          D.text ("public static final class " ++ name ++ " implements " ++ interfaceType' a ++ "") <> D.hardline <> D.block 2 (D.joinWith (D.hardline <> D.hardline)
            ([D.text ("private final " ++ reference r ++ " inner = new " ++ reference r ++ "();")] ++ operations)))
      let parts = split '.' (unitName unit)
          name = concatMap cap (split '_' (last parts))
          package = intercalate "." (init parts)
          path = "src/main/java/" ++ concatMap (++ "/") (init parts) ++ name ++ ".java"
          header = if null package then mempty else D.text ("package " ++ package ++ ";") <> D.hardline <> D.hardline
          source = header <> D.text ("public final class " ++ name ++ "") <> D.hardline <> D.block 2
            (D.group (D.text "private static final lawspec.runtime.LawSpecSchema SCHEMA =" <>
             D.nest 4 (D.softline <> D.text "lawspec.runtime.LawSpecDataSchema.create();")) <>
             D.hardline <> D.hardline <> D.joinWith (D.hardline <> D.hardline) (bodies ++ wrappers))
      pure [Artifact path (render source) "generated" "source"]
  dataFiles <- if any ((== "src/main/java/lawspec/runtime/LawSpecDataSchema.java") . artifactPath) files then pure []
    else J.emitJavaDataWithProfile bits layout declarations
  generatorProduct <- if null generators then pure mempty else do
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
        pure (D.text "if (type.equals(" <> tyRef <> D.text "))" <> D.hardline <> D.block 2
          (D.joinWith D.hardline (children ++
            [applied "Generator" [native] <> D.text " source = " <>
              call (reference (resolvedGeneratorFactory generator)) [D.text ("child" ++ show i) | i <- [0..length args-1]] <> D.text ";",
             D.text "return " <> call "LawSpecDataStrategies.nativeValues" [bridge,D.text "source"] <> D.text ";"])))
      pure (D.text "private static Generator<lawspec.runtime.LawSpecRuntime.Value> " <>
        call ("factory" ++ show index) (map D.text
          ["LawSpecSchema schema", "LawSpecSchema.Named type", "int bits", "java.util.Map<String, Object> symbols",
           "java.util.List<Generator<lawspec.runtime.LawSpecRuntime.Value>> arguments"]) <>
        D.hardline <> D.block 2 (D.joinWith D.hardline (branches ++
          [D.text "throw new IllegalArgumentException(\"unplanned native generator instantiation: \" + type);"])))
    let entries = [call "java.util.Map.<String, LawSpecDataStrategies.NativeFactory>entry"
          [E.quoted (C.idText (resolvedGeneratorType generator)),D.text ("LawSpecNativeGenerators::factory" ++ show i)] |
            (i,generator) <- zip [0::Int ..] generators]
        registry = D.text "public static java.util.Map<String, LawSpecDataStrategies.NativeFactory> factories()" <> D.hardline <>
          D.block 2 (D.text "return " <> call "java.util.Map.ofEntries" entries <> D.text ";")
        helper = Artifact "src/test/java/lawspec/testing/LawSpecNativeGenerators.java" (render
          (D.text "package lawspec.testing;" <> D.hardline <> D.hardline <>
           D.text "import lawspec.runtime.LawSpecSchema;" <> D.hardline <>
           D.text ("import " ++ propertyPackage javaStyle ++ ".Generator;") <> D.hardline <> D.hardline <>
           D.text "public final class LawSpecNativeGenerators" <> D.hardline <> D.block 2
            (D.joinWith (D.hardline <> D.hardline)
             (D.text "private LawSpecNativeGenerators() {}":registry:factoryMethods)))) "generated" "test"
    emitted <- either (Left . show) Right $ mconcat <$> mapM (\unit ->
      Scalar.nativeScalarProductWithAdapterBindings javaStyle [] True minify declarations
        (Definitions.definitionCalls (map plannedUnit (plannedUnits testing))) bits "java"
        (modelTestUnit testing (plannedUnit unit)) (plannedProperties unit))
        [unit | unit <- plannedUnits testing, not (null (plannedProperties unit))]
    pure (emitted { Product.jvmAdapters = [], Product.jvmArtifacts = helper : [file | file <- Product.jvmArtifacts emitted,artifactPlacement file == "test"] ++
      [Artifact "src/test/java/lawspec/testing/LawSpecDataStrategies.java" (JavaTestingRuntime.dataStrategies javaStyle) "generated" "test" |
        not (any ((== "src/test/java/lawspec/testing/LawSpecDataStrategies.java") . artifactPath) files)] })
  (actorFiles, actorCases) <- nativeActors
  let generatorFiles = Product.jvmArtifacts generatorProduct ++ actorFiles
      replaced = map artifactPath (bridges ++ generatorFiles)
  unless (all ((/= artifactPath support) . artifactPath) files) (Left "unit shadows native codec support")
  let runtime = [Artifact "src/main/java/lawspec/runtime/LawSpecRuntime.java" (runtimeSource "java") "generated" "source" |
        not (any ((== "src/main/java/lawspec/runtime/LawSpecRuntime.java") . artifactPath) files)]
  let generated = [f | f <- files,artifactPath f `notElem` replaced] ++ dataFiles ++ runtime ++ [support] ++ bridges ++ generatorFiles
  stubs <- generatorStubs generated
  pure (product
    { Product.jvmArtifacts = generated ++ stubs
    , Product.jvmAdapters = [(path, abi) | (path,abi) <- Product.jvmAdapters product, path `notElem` replaced]
    , Product.jvmCases = [cases | cases <- Product.jvmCases product, Abi.casePath cases `notElem` replaced] ++ Product.jvmCases generatorProduct ++ actorCases
    })
  where
    -- Existing Pekko actors stand in for LawSpec actors: each bound actor's
    -- model test drives its behaviour through LawSpecPekkoNative, made by a
    -- generated factory that builds each handler's message and reads its
    -- reply through the native codecs. ref:DEC-native-actor-binding
    nativeActors
      | null (bindingActors plan) = pure ([], [])
      | otherwise = do
          factories <- forM (bindingActors plan) $ \actor -> do
            source <- case resolvedActorSource actor of
              BehaviorFactory ref -> do
                mapM_ J.identifier (referenceParts ref)
                unless (length (referenceParts ref) >= 2)
                  (Left ("native actor " ++ actorIdentity actor ++ ": behavior names a class and its static factory"))
                pure (methodReference ref)
              SpringActorClass _ -> Left ("native actor " ++ actorIdentity actor ++
                ": unsupported: Spring starter actors are not yet checked on Java; bind its Pekko behavior")
            unless (resolvedActorEntity actor == Nothing)
              (Left ("native actor " ++ actorIdentity actor ++ ": unsupported: sharded entities are not yet checked; remove entity to check one actor"))
            handlers <- mapM (handlerLink actor) (resolvedActorHandlers actor)
            let start = call (if resolvedActorPersistence actor == Just EventSourced
                  then "LawSpecPekkoNative.eventSourced" else "LawSpecPekkoNative.behavior")
                  [E.quoted (actorIdentity actor), source]
            pure (D.text ("/** " ++ actorIdentity actor ++ ", run by the native " ++ (case resolvedActorSource actor of
                    BehaviorFactory ref -> reference ref
                    SpringActorClass ref -> reference ref) ++ ". */") <> D.hardline <>
              D.text ("public static LawSpecRuntime.ActorBackend " ++ actorMethod actor ++ "()") <> D.hardline <>
              D.block 2 (D.text "return " <> start <> D.nest 4 (mconcat [D.hardline <> D.text "." <> h | h <- handlers]) <> D.text ";"))
          let wiring = Artifact "src/test/java/lawspec/testing/LawSpecNativeActors.java" (render
                (D.text "package lawspec.testing;" <> D.hardline <> D.hardline <>
                 D.text "import lawspec.pekko.LawSpecPekkoNative;" <> D.hardline <>
                 D.text "import lawspec.runtime.LawSpecRuntime;" <> D.hardline <>
                 D.text "import lawspec.runtime.LawSpecSchema;" <> D.hardline <> D.hardline <>
                 D.text "public final class LawSpecNativeActors" <> D.hardline <> D.block 2
                  (D.joinWith (D.hardline <> D.hardline)
                    ([D.group (D.text "private static final LawSpecSchema SCHEMA =" <>
                       D.nest 4 (D.softline <> D.text "lawspec.runtime.LawSpecDataSchema.create();")),
                      D.text "private LawSpecNativeActors() {}"] ++ factories)))) "generated" "test"
              backend = Artifact "src/test/java/lawspec/pekko/LawSpecPekkoNative.java"
                (runtimeSource "java-pekko-native") "generated" "test"
          -- Each unit with a bound actor: its model test drives the native actor.
          models <- fmap concat $ forM (plannedUnits testing) $ \p -> do
            let unit = plannedUnit p
                backends = [(resolvedActorName actor, D.text ("lawspec.testing.LawSpecNativeActors." ++ actorMethod actor ++ "()")) |
                  actor <- bindingActors plan, resolvedActorUnit actor == C.unitId unit]
            if null backends then pure [] else do
              product' <- either (Left . unwords . map message) Right
                (modelTestProductWithBackends False backends javaStyle "java" bits declarations
                  (Definitions.definitionCalls (map plannedUnit (plannedUnits testing))) (modelTestUnit testing unit))
              pure [product']
          pure ([wiring, backend] ++ concatMap Product.jvmArtifacts models, concatMap Product.jvmCases models)
    -- One handler as a link of the backend's chain: its message from the
    -- arguments after the state, and its reply's result.
    handlerLink actor handler = do
      let binding = resolvedHandlerBinding handler
          context message = Left ("native actor " ++ actorIdentity actor ++ ": handler " ++ boundHandlerName binding ++ ": " ++ message)
      mapM_ J.identifier (referenceParts (handlerMessage binding))
      mapM_ (mapM_ J.identifier . referenceParts) (handlerReply binding)
      mapM_ J.identifier (handlerResult binding)
      decoded <- forM (zip [0::Int ..] (resolvedHandlerArguments handler)) $ \(i,ty) -> do
        bridge <- either context Right (codec [] (D.text "SCHEMA") (D.text (show bits)) ty)
        pure (method bridge "decode" [D.text ("arguments.get(" ++ show i ++ ")")])
      let messageOf replyTo = call ("new " ++ reference (handlerMessage binding)) (decoded ++ [D.text "replyTo" | replyTo])
          name = E.quoted (boundHandlerName binding)
      case (resolvedHandlerResult handler, handlerReply binding) of
        (Just ty, Just reply) -> do
          bridge <- either context Right (codec [] (D.text "SCHEMA") (D.text (show bits)) ty)
          let value = maybe (D.text "reply") (\accessor -> D.text ("reply." ++ accessor ++ "()")) (handlerResult binding)
          pure (call "ask" [name, JL.lambdaValue ["symbols", "arguments", "replyTo"] (messageOf True),
            D.text (reference reply ++ ".class"), JL.lambdaValue ["symbols", "reply"] (method bridge "encode" [value])])
        (Nothing, Just reply) -> pure (call "acknowledged" [name,
          JL.lambdaValue ["symbols", "arguments", "replyTo"] (messageOf True), D.text (reference reply ++ ".class")])
        (Nothing, Nothing) -> pure (call "tell" [name, JL.lambdaValue ["symbols", "arguments"] (messageOf False)])
        (Just _, Nothing) -> context "returns a result, so it needs a reply class"
    actorIdentity actor = C.idText (resolvedActorUnit actor) ++ "::" ++ resolvedActorName actor
    -- unit example.bank, actor account: exampleBankAccount.
    actorMethod actor = case concatMap (split '_') (split '.' (C.idText (resolvedActorUnit actor))) ++ [resolvedActorName actor] of
      first : rest -> first ++ concatMap cap rest
      [] -> resolvedActorName actor
    methodReference ref = D.text (intercalate "." (init (referenceParts ref)) ++ "::" ++ last (referenceParts ref))
    files = Product.jvmArtifacts product
    boxed value = maybe value ("java.lang." ++) (lookup value
      [("byte","Byte"),("short","Short"),("int","Integer"),("long","Long"),
       ("float","Float"),("double","Double"),("char","Character"),("boolean","Boolean")])
    declarations = planDataDeclarations testing
    interfaceType ability = maybe "Object" (interfaceType' . snd) (C.findAbility (map plannedUnit (plannedUnits testing)) ability)
    interfaceType' a = abilitiesClassOf (ownerName a) ++ "." ++ interfaceName a
    bits = planMachineBits testing
    representations = bindingRepresentations plan
    mappings = resolvedTypes representations
    generators = resolvedGenerators representations
    layout = D.selectLayout minify (D.Pretty 100)
    render doc = D.render layout (D.text "// Generated by LawSpec. Do not edit." <> D.hardline <> D.hardline <> doc <> D.hardline)
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
    nativeName d = maybe (if C.dataHandle d then Right "java.lang.Object" else J.javaDataName declarations (C.dataId d))
      (Right . reference . resolvedNativeType) (mapping d)
    isHandle (C.Constructor name []) = any (\d -> C.dataHandle d && C.dataId d == C.Id name) declarations
    isHandle _ = False
    variable ps v = maybe (Left "unbound native codec parameter") Right (lookup v ps)
    argument f (C.TypeArgument ty) = f ty
    argument _ _ = Left "indexed native codec arguments are unsupported"
    ref ps (C.TypeVariable v) = (\(_,c) -> D.text (c ++ ".type()")) <$> variable ps v
    ref ps (C.Constructor name args) = call "new LawSpecSchema.Named" . (E.quoted name :) <$> mapM (argument (ref ps)) args
    ref _ _ = Left "function cannot cross native codec"
    builtin name
      | isDurationType name = Just "Duration"
      | otherwise = collectionContainer name
    nativeType ps ty = case ty of
      C.TypeVariable v -> D.text . fst <$> variable ps v
      C.Constructor name args | Just short <- builtin name -> do
        children <- mapM (argument (nativeType ps)) args
        pure $ case short of
          "Duration" -> D.text "java.time.Duration"
          "Set" -> applied "java.util.Set" children
          "KeyVal" -> applied "java.util.Map" children
          _ -> applied "java.util.ArrayDeque" children
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
            [classPath (referenceParts r) | (_,ConstructorCall r) <- bindingCalls plan] ++
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
              signature = D.text "public static " <> generic <> applied (propertyPackage javaStyle ++ ".Generator") [result] <>
                D.text " " <> call methodName
                  [applied (propertyPackage javaStyle ++ ".Generator") [D.text t] <> D.text (" argument" ++ show i) |
                    (i,(_,(t,_))) <- zip [0::Int ..] parameters]
          pure (signature <> D.hardline <> D.block 2 (D.text "throw " <>
            call "new java.lang.UnsupportedOperationException"
              [E.quoted ("Implement generator for " ++ C.idText (resolvedGeneratorType generator))] <> D.text ";"))
        pure (Artifact ("src/test/java/" ++ path ++ ".java") (D.render (D.Pretty 100)
          (D.text "// User-owned native generator factories. Implement before running properties." <>
           D.hardline <> D.text ("package " ++ intercalate "." (init parts) ++ ";") <> D.hardline <> D.hardline <>
           D.text ("public final class " ++ name ++ "") <> D.hardline <> D.block 2
             (D.text ("private " ++ name ++ "() {}") <> D.hardline <> D.hardline <>
              D.joinWith (D.hardline <> D.hardline) bodies) <> D.hardline)) "user" "test")
    codec ps schema width ty = case ty of
      C.TypeVariable v -> D.text . snd <$> variable ps v
      C.Constructor name args | Just short <- builtin name -> do
        children <- mapM (argument (codec ps schema width)) args
        pure $ case short of
          "Duration" -> method schema "duration" [width,D.text "symbols"]
          "Set" -> method schema "set" (children ++ [width,D.text "symbols"])
          "KeyVal" -> method schema "keyVal" (children ++ [width,D.text "symbols"])
          _ -> method schema "sequence" (D.text (show short) : children ++ [width,D.text "symbols"])
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
    -- A handle's native codec passes its native object through, both ways.
    codecMethod (i,d) | C.dataHandle d = do
      native <- nativeName d
      pure (D.text "public static " <> applied "LawSpecSchema.Codec" [D.text native] <> D.text " " <>
        call ("type" ++ show i) [D.text "LawSpecSchema schema",D.text "int bits",D.text "java.util.Map<String, Object> symbols"] <>
        D.hardline <> D.block 2 (D.text ("var type = new LawSpecSchema.Named(" ++ D.render D.Compact (E.quoted (C.idText (C.dataId d))) ++ ");") <> D.hardline <>
          D.text "return schema.codec(" <> D.nest 4
            (D.hardline <> D.joinWith (D.text "," <> D.hardline)
              [D.text "type",D.text "bits",D.text "symbols",
               D.text "value -> LawSpecRuntime.handle(LawSpecSchema.key(type), value)",
               D.text ("value -> (" ++ native ++ ") LawSpecRuntime.handleTarget(value)")]) <> D.text ");"))
    codecMethod (i,d) = do
      let ps = zip (C.dataParameters d) [("T" ++ show n,"type" ++ show n) | n <- [0::Int ..]]
          args = [D.text t | (_,(t,_)) <- ps]
          ty = C.Constructor (C.idText (C.dataId d)) [C.TypeArgument (C.TypeVariable v) | (v,_) <- ps]
      native <- nativeType ps ty
      tyRef <- ref ps ty
      arms <- forM (C.dataConstructors d) $ \c -> do
        let mapped = mapping d >>= \m -> find ((== C.constructorId c) . C.constructorId . resolvedConstructor) (resolvedConstructors m)
        base <- maybe (J.javaConstructorClass declarations d c)
          (Right . reference . resolvedNativeConstructor) mapped
        case mapped >>= resolvedFieldLayout of
          Just tree -> do
            let fields=maybe [] resolvedFields mapped
                paths=nativeLayoutPaths tree
            codecs<-mapM (codec ps (D.text "schema") (D.text "bits") . C.binderType . fst) fields
            packed<-foldNativeLayoutM (Right . D.text . ("nativeField"++) . show)
              (\field constructor children->do
                ty<-ref ps (C.binderType field)
                pure (call "schema.construct" [ty,E.quoted (C.idText (C.constructorId constructor)),
                  call "java.util.List.of" children,D.text "bits",D.text "symbols"])) tree
            let locals=[D.text ("var nativeField"++show index++" = ") <>
                  call "LawSpecSchema.encodeField" [bridge,D.text ("item."++native++"()"),
                    E.quoted (C.idText (C.constructorId c)++"."++intercalate "." path)]<>D.text ";" |
                    (index,((bridge,(_,native)),path))<-zip [0::Int ..]
                      (zip (zip codecs fields) (maybe [] id (mapped >>= resolvedFieldPaths)))]
                root=call "schema.construct" [D.text "type",E.quoted (C.idText (C.constructorId c)),
                  call "java.util.List.of" packed,D.text "bits",D.text "symbols"]
                encode=D.text ("if (value.getClass() == "++base++".class)")<>D.hardline<>D.block 2
                  (D.text "var item = ("<>applied base args<>D.text ") value;"<>D.hardline<>
                   D.joinWith D.hardline (locals++[D.text "return "<>root<>D.text ";"]))
                project []=D.text "value"
                project (index:rest)=foldl (\value child->D.text "((LawSpecRuntime.Data) "<>value<>
                  D.text (".data()).fields().get("++show child++")"))
                  (D.text ("data.fields().get("++show index++")")) rest
                decoded=[method bridge "decode" [project path] | (bridge,path)<-zip codecs paths]
                decode=D.group (D.text "case "<>E.quoted (C.idText (C.constructorId c))<>D.text " ->"<>
                  D.nest 4 (D.softline<>call ("new "++base++if null ps then "" else "<>") decoded)<>D.text ";")
            pure (encode,decode)
          Nothing -> do
            codecs <- mapM (codec ps (D.text "schema") (D.text "bits") . C.binderType) (C.constructorFields c)
            let unit = maybe False ((== UnitConstructor) . resolvedConstructorStyle) mapped
                nativeFields = maybe (map C.binderName (C.constructorFields c)) (map snd . resolvedFields) mapped
                -- Generated types are records, like mapped native types: accessors.
                access field = D.text ("item." ++ field ++ "()")
                encoded = [call "LawSpecSchema.encodeField" [bridge,access field,
                  E.quoted (C.idText (C.constructorId c) ++ "." ++ C.binderName logical)] |
                    (bridge,field,logical) <- zip3 codecs nativeFields (C.constructorFields c)]
                encode = D.text "if (" <> (if unit then D.text ("value == " ++ base)
                  else D.text ("value.getClass() == " ++ base ++ ".class")) <> D.text ")" <> D.hardline <>
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
            D.text "return switch (data.tag())" <> D.hardline <> D.block 2
              (D.joinWith D.hardline (map snd arms ++ [D.text "default -> " <> failure])) <> D.text ";")
      (setup, encodeBody, decodeBody) <- case mapping d >>= resolvedCodec of
        Nothing -> pure (mempty, encoder, decoder)
        Just hook -> do
          name <- J.javaDataName declarations (C.dataId d)
          let simple = last (split '.' name)
              codecName = J.javaCodecName simple
              canonical = call ("LawSpecDataCodecs." ++ codecName)
                ([D.text "schema",D.text "bits",D.text "symbols"] ++
                 [call "schema.supported" [D.text (v ++ ".type()"),D.text "bits",D.text "symbols"] |
                   (_,(_,v)) <- ps])
              converters methodName = [D.text (v ++ "::" ++ methodName) | (_,(_,v)) <- ps]
              contextual direction expression = D.text "value -> " <> D.block 2
                (D.text "try" <> D.hardline <> D.block 2 (D.text "return " <> expression <> D.text ";") <>
                 D.hardline <> D.text "catch (RuntimeException error)" <> D.hardline <> D.block 2
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
      body<-case mapping d of
        Nothing | not (null mappings)->do
          name<-J.javaDataName declarations (C.dataId d)
          let simple=last (split '.' name)
              canonical=case simple of []->"dataCodec";first:rest->toLower first:rest++"Codec"
          pure (D.text "return "<>call ("LawSpecDataCodecs."++canonical)
            ([D.text "schema",D.text "bits",D.text "symbols"]++[D.text value | (_,(_,value))<-ps])<>D.text ";")
        _->pure (D.text "var type = "<>tyRef<>D.text ";"<>D.hardline<>setup<>
          D.text "return schema.codec("<>D.nest 4
            (D.hardline<>D.joinWith (D.text ","<>D.hardline)
              [D.text "type",D.text "bits",D.text "symbols",encodeBody,decodeBody])<>D.text ");")
      pure (D.text "public static " <> (if null ps then mempty else applied "" args <> D.text " ") <>
        applied "LawSpecSchema.Codec" [native] <> D.text " " <> call ("type" ++ show i)
          ([D.text "LawSpecSchema schema",D.text "int bits",D.text "java.util.Map<String, Object> symbols"] ++
           [applied "LawSpecSchema.Codec" [D.text t] <> D.text (" " ++ v) | (_,(t,v)) <- ps]) <>
        D.hardline <> D.block 2 body)

-- | name = value;, the value on the next line when the line is too long.
assigned :: D.Doc -> D.Doc -> D.Doc
assigned name value = D.group (name <> D.text " =" <> D.nest 4 (D.softline <> value)) <> D.text ";"
