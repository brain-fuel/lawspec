-- | A unit's Scala files: the user-owned adapter object and the generated
-- ScalaTest suite of its laws (LawSpec.ScalaProperties), with the handlers,
-- adapter calls and failures they need.
module LawSpec.ScalaUnitEmit (emitScalaUnit) where

import LawSpec.Bounds ()
import LawSpec.AbilityNames (interfaceName, productionName, specName, recordingName, unitAbility, ownAbilities, ownerName)
import qualified LawSpec.AbilityEmit.Scala as ScalaAbilities
import LawSpec.ModelTests (modelTestArtifacts)
import qualified LawSpec.JavaData as JavaData
import qualified LawSpec.ScalaData as ScalaData
import qualified LawSpec.ScalaExpr as ScalaExpr
import qualified LawSpec.ScalaProperties as ScalaProperties
import qualified LawSpec.ScalaTestHelpers as ScalaTestHelpers
import LawSpec.ScalaDefinitions (adapterResult)
import LawSpec.Backend
import LawSpec.Common
import LawSpec.Testing
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Core as C
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as Doc
import qualified LawSpec.ScalaLayout as ScalaLayout
import qualified Data.Map.Strict as M
import LawSpec.JvmNames (jvmLocalTable, jvmReserved, contractMethod)
import LawSpec.SourceLink (sourceLink, unitSourceFile)
import Data.List (intercalate, nub)
import Data.Maybe (listToMaybe)
import Data.Char (toLower)
import LawSpec.Search (lawDescriptors, searchable)

-- | The adapter object and test suite of one unit.
emitScalaUnit :: Integer -> Bool -> Bool -> [C.DataDeclaration] -> [(C.Id,String)] -> Int -> Unit -> [Expanded] -> Either [Diagnostic] [Artifact]
emitScalaUnit budget nativeGenerators minify dataDeclarations definitions bits u allLaws = do
  tests <- document <$> ScalaProperties.emitTests properties u ls
  stub <- either (Left . pure . (\m -> Diagnostic "target" m Nothing)) Right stubDoc
  models <- modelTestArtifacts "scala" bits dataDeclarations definitions u
  pure (models ++ [Artifact stubPath stub "user" "source", Artifact testPath tests "generated" "test"])
  where
    document = Doc.render (Doc.selectLayout minify ScalaLayout.scalaStyle)
    java = either error id
    ls = filter ((== unitName u) . owner) allLaws
    parts = splitOn '.' (unitName u)
    cls = concatMap cap (splitOn '_' (last parts))
    pkg = intercalate "." (init parts)
    path = intercalate "/" (init parts ++ [cls])
    stubPath = "src/main/scala/" ++ path ++ ".scala"
    testPath = "src/test/scala/" ++ path ++ "LawSpecTest.scala"
    qualifiedCls = if null pkg then cls else pkg ++ "." ++ cls
    adapterDeclarations = [d | d <- C.unitDeclarations u, C.declarationId d `notElem` map fst definitions]
    custom = ScalaData.requiresSchema dataDeclarations
    key t = if custom t then JavaData.javaDataKey t else builtinKey t
    quote = ScalaData.scalaQuoted
    -- The user-owned adapter object: a stub per adapter, and the production
    -- handler of each of the unit's own abilities.
    stubDoc = do
      functions' <- mapM stubFn adapterDeclarations
      handlers <- mapM (ScalaAbilities.productionStub dataDeclarations u) (ownAbilities u)
      pure $ document $
        Doc.text "// User-owned LawSpec adapter." <> Doc.hardline <>
        (if null pkg then mempty else Doc.text ("package " ++ pkg) <> Doc.hardline <> Doc.hardline) <>
        Doc.text ("object " ++ cls ++ " ") <>
        (if null (functions' ++ handlers) then Doc.text "{}" else
          Doc.block 2 (Doc.joinWith (Doc.hardline <> Doc.hardline) (functions' ++ handlers))) <> Doc.hardline
    stubFn d = do
      let (args, _) = functionType (C.declarationType d)
          n = C.declarationName d
      types <- mapM (ScalaData.scalaDataTypeDoc dataDeclarations) args
      result <- adapterResult dataDeclarations d
      let arguments = [Doc.text (handlerParameter ability ++ ": " ++ scInterface ability) | ability <- usesOf n] ++
            [Doc.text ("value" ++ show i ++ ": ") <> ty | (i,ty) <- zip [0::Int ..] types]
          signature = ScalaLayout.parameters (Doc.text ("def " ++ ScalaData.escaped (adapterName u (C.declarationId d)))) arguments <>
            Doc.text ": " <> result
      pure (Doc.lineComment 78 "// " (n ++ " :: " ++ prettyType (C.declarationType d) ++ maybe "" (" — " ++) (sourceLink (C.declarationOrigin d))) <>
        Doc.group (signature <> Doc.text " =" <>
          Doc.nest 2 (Doc.softline <> Doc.text ("throw NotImplementedError(" ++ quote n ++ ")"))))
    -- An async adapter's Future is awaited where it is called.
    awaitFor adapter call
      | adapter `notElem` asyncFunctions u = call
      | otherwise = Doc.text "scala.concurrent.Await.result(" <> call <> Doc.text ", scala.concurrent.duration.Duration.Inf)"
    render = java . ScalaExpr.renderExpression dataDeclarations bits localName' scExternal
    scChecked ty = java . ScalaExpr.checked dataDeclarations bits ty
    -- Each codec maker is applied to the declarations once per unit, so its
    -- registry and names are built once.
    scCodecDoc = ScalaExpr.codec dataDeclarations bits
    -- A codec the file names as a value is used by its name (textCodec).
    codecOf ty = let doc = java (scCodecDoc ty) in maybe doc Doc.text (lookup (Doc.render Doc.Compact doc) [(Doc.render Doc.Compact c, n) | (n, c) <- codecValues])
    scNativeArgument ty value = ScalaLayout.chain (codecOf ty) [("decode", [value])]
    -- The abstract Integer result is tower-polymorphic: adapters may return
    -- any of Int, Long and BigInt, and the runtime bridge discharges the
    -- logical domain.
    scNativeResult ty value | ty == Named "Integer" = ScalaExpr.call "LawSpecScalaCodecs.integer" [value, Doc.text "MachineBits"]
    scNativeResult ty value = ScalaLayout.chain (codecOf ty) [("encode", [value])]
    scHandler ability = ScalaExpr.call ("LawSpecScala.handler[" ++ scInterface ability ++ "]") [Doc.text "symbols", ScalaExpr.quoted (C.abilityKey ability)]
    -- params => body, the body on its own line when it does not fit.
    arrow params body = Doc.group (Doc.text (params ++ " =>") <> Doc.nest 2 (Doc.softline <> body))
    -- An ability's pieces are its owner's: the trait, the production handler
    -- (in the owner's adapter object) and the recording.
    scInterface ability = maybe "Any" (\a -> ScalaAbilities.abilitiesObjectOf (ownerName a) ++ "." ++ interfaceName a) (abilityNamed ability)
    production a = (if ownerName a == unitName u then qualifiedCls else adapterObjectOf (ownerName a)) ++ "." ++ productionName a
    adapterObjectOf unit = let ps = splitOn '.' unit in intercalate "." (init ps ++ [concatMap cap (splitOn '_' (last ps))])
    scConstruct ty tag fields
      | custom ty = ScalaExpr.call "LawSpecScalaCodecs.construct" [Doc.text "Schema",java (ScalaExpr.reference ty),ScalaExpr.quoted tag,ScalaExpr.call "List" fields,Doc.text "MachineBits",Doc.text "symbols"]
      | otherwise = ScalaExpr.call "LawSpecRuntime.construct" [ScalaExpr.quoted (key ty),ScalaExpr.quoted tag,ScalaExpr.array fields]
    scEqual ty a b
      | custom ty = ScalaExpr.call "Schema.equal" [java (ScalaExpr.reference ty),a,b,Doc.text "MachineBits",Doc.text "symbols"]
      | otherwise = ScalaExpr.call "LawSpecRuntime.truth" [ScalaExpr.call "LawSpecRuntime.binary" [ScalaExpr.quoted "==",a,b]]
    -- An adapter that fails with E answers Either[E, R]: a Left, or an
    -- exception lawspec.json maps, becomes the failure.
    failingAs failing call = case failing of
      ability@(C.AbilityRef _ [failure]) : _ ->
        let native = java (ScalaData.scalaDataType dataDeclarations failure)
            mapped = [ ScalaExpr.call "LawSpecRuntime.MappedFailure"
                         [Doc.text ("classOf[" ++ intercalate "." (C.failureNative b) ++ "]"),
                          arrow "(error: Throwable)" (
                            scConstruct failure (C.idText (C.failureConstructor b))
                              (C.mapFailureFields (\ty tag -> scConstruct ty (C.idText tag)) (scNativeResult (C.scalarType "Text") (Doc.text "java.util.Objects.toString(error.getMessage, \"\")")) b))]
                     | b <- C.unitFailureBindings u, C.failureType b == failure ]
        in ScalaExpr.call "LawSpecRuntime.nativeFailures"
             ([ScalaExpr.quoted (C.abilityKey ability), arrow "(nativeValue: Object)" (scNativeResult failure (Doc.text ("nativeValue.asInstanceOf[" ++ native ++ "]"))),
               arrow "()" call] ++ mapped)
      _ -> call
    orFail failing value = if null failing then value else ScalaExpr.call "LawSpecScala.orFail" [value]
    installs e = [ScalaLayout.bind (sharedVar h) (constructHandler plainMaking (C.handlerAbility h) (C.SpecHandler (C.handlerId h))) | h <- sharedOf e] ++
      installing e (earlyHandlers e)
    lateInstalls e = installing e (lateHandlers e)
    installing e chosen = case chosen of
      [] -> []
      _ -> [ScalaExpr.call "LawSpecRuntime.installHandlers" [Doc.text "symbols", handlerMap (lawMaking e) chosen]]
    handlerMap making chosen = ScalaExpr.call "java.util.Map.of[String, Object]"
      (concat [[ScalaExpr.quoted (C.abilityKey a), constructHandler making a c] | (a, c) <- chosen])
    constructHandler making@(shared, resourceOf) a c = case c of
      C.ProductionHandler | Just ps <- abilityNamed a >>= C.abilityNative -> ScalaExpr.call (intercalate "." ps) madeWith
      C.ProductionHandler -> ScalaExpr.call (maybe "Unknown" production (abilityNamed a)) madeWith
      C.SpecHandler h | h `elem` shared, Just x <- specNamed h -> Doc.text (sharedVar x)
      C.SpecHandler h -> ScalaExpr.call (ScalaAbilities.abilitiesObject u ++ "." ++ maybe "Unknown" specName (specNamed h)) [Doc.text "symbols"]
      C.RecordingHandler inner -> ScalaExpr.call (maybe "Unknown" (\x -> ScalaAbilities.abilitiesObjectOf (ownerName x) ++ "." ++ recordingName x) (abilityNamed a))
        [constructHandler making a inner, Doc.text "symbols"]
      where madeWith = maybe [] (\(t, local) -> [scNativeArgument t (Doc.text local)]) (resourceOf a c)
    scExternal term values = case C.expressionNode term of
      C.ExternalCall identity _ | Just evaluator <- lookup identity definitions ->
        Right (ScalaExpr.call evaluator (Doc.text "symbols" : values))
      -- raise aborts to the nearest attempt of its Fail ability.
      C.Perform op [_] | C.isFail (C.operationAbility op) ->
        Right (ScalaExpr.call "LawSpecRuntime.raiseFailure" (ScalaExpr.quoted (C.abilityKey (C.operationAbility op)) : values))
      -- An operation goes to the handler the law installed for its ability.
      C.Perform op args ->
        let failing = operationFailure op
        in Right (failingAs failing
          (scNativeResult (expressionType term) (orFail failing (ScalaLayout.chain (scHandler (C.operationAbility op)) [(ScalaData.escaped (C.operationName op),
            [scNativeArgument ty v | (ty,v) <- zip (map expressionType args) values])]))))
      C.Handle (C.CatchFailure ability) _ -> case (expressionType term, values) of
        (C.Constructor "Either" [C.TypeArgument failure, C.TypeArgument result], [body]) ->
          let side tag ty = arrow "(value: LawSpecRuntime.Value)" (scConstruct (expressionType term) tag [scChecked ty (Doc.text "value")])
          in Right (ScalaExpr.call "LawSpecRuntime.attempt" [ScalaExpr.quoted (C.abilityKey ability), arrow "()" body,
            side "Either::Right" result, side "Either::Left" failure])
        _ -> Left "attempt gives an Either"
      C.Calls op args ->
        let matches = case args of
              Nothing -> Doc.text "null"
              Just xs -> arrow "(recorded: java.util.List[LawSpecRuntime.Value])" (ScalaLayout.conjunction
                [scEqual (expressionType a) (Doc.text ("recorded.get(" ++ show i ++ ")")) v | (i,(a,v)) <- zip [0 :: Int ..] (zip xs values)])
        in Right (ScalaExpr.call "LawSpecRuntime.countCalls" [ScalaExpr.call "LawSpecRuntime.handler" [Doc.text "symbols", ScalaExpr.quoted (C.abilityKey (C.operationAbility op))],
          ScalaExpr.quoted (C.operationName op), matches])
      C.ExternalCall identity args ->
        let callee = declarationName identity
            typed = zip (map expressionType args) values
            failing = [a | a@(C.AbilityRef _ [_]) <- failuresOf callee]
        in Right $ if callee `elem` map contractName (contracts u)
          then ScalaExpr.call (contractMethod callee)
            (Doc.text "symbols" : [scChecked ty value | (ty,value) <- typed])
          else failingAs failing
            (scNativeResult (expressionType term) (orFail failing (awaitFor (adapterName u identity) (ScalaExpr.call (qualifiedCls ++ "." ++ ScalaData.escaped (adapterName u identity))
            (map scHandler (usesOf callee) ++ [scNativeArgument ty value | (ty,value) <- typed])))))
      -- handle e with h end: e runs with h installed for its ability.
      C.Handle (C.WithHandler ability choice) _ | [body] <- values ->
        Right (ScalaExpr.call "LawSpecRuntime.withHandlers" [Doc.text "symbols",
          handlerMap plainMaking [(ability, choice)], arrow "()" body])
      _ -> Left "expected checked Scala external call"
    valueLiteral value = case value of
      V.ScalarValue scalarValue -> either (Left . pure . (\message -> Diagnostic "target" message Nothing)) Right
        (ScalaExpr.scalarLiteral (C.scalarType (scalarName scalarValue)) scalarValue)
      V.DataValue ty tag fields -> do
        rendered <- mapM valueLiteral fields
        pure (ScalaExpr.call "LawSpecScalaCodecs.construct"
          [Doc.text "Schema",java (ScalaExpr.reference ty),ScalaExpr.quoted (C.idText tag),
           ScalaExpr.call "List" rendered,Doc.text "MachineBits",Doc.text "symbols"])
      V.PresenceValue ty payload -> do
        rendered <- traverse valueLiteral payload
        pure (ScalaExpr.call "LawSpecRuntime.present" [ScalaExpr.quoted (key ty),
          maybe (Doc.text "null") id rendered])
    generatorDoc = ScalaTestHelpers.generatorDoc bits budget custom (java . ScalaExpr.reference) key
    properties = ScalaProperties.Config
      { ScalaProperties.packageName = pkg
      , ScalaProperties.className = cls
      , ScalaProperties.machineBits = bits
      , ScalaProperties.awaitResult = awaitFor
      , ScalaProperties.constructorContracts = hasConstructorContracts dataDeclarations
      , ScalaProperties.nativeGenerators = nativeGenerators
      , ScalaProperties.nodeBudget = budget
      , ScalaProperties.expression = render
      , ScalaProperties.literal = valueLiteral
      , ScalaProperties.checked = scChecked
      , ScalaProperties.structural = custom
      , ScalaProperties.reference = java . ScalaExpr.reference
      , ScalaProperties.typeKey = key
      , ScalaProperties.generator = generatorDoc
      , ScalaProperties.generatorWithin = \within -> ScalaTestHelpers.generatorDocWithin within bits budget custom (java . ScalaExpr.reference) key
      , ScalaProperties.nativeArgument = scNativeArgument
      , ScalaProperties.nativeResult = scNativeResult
      , ScalaProperties.handlerInstalls = installs
      , ScalaProperties.lateHandlerInstalls = lateInstalls
      , ScalaProperties.searchDescriptors = searchDescriptorsOf
      , ScalaProperties.extraImports = []
      , ScalaProperties.local = localName'
      , ScalaProperties.sourceFile = unitSourceFile u
      , ScalaProperties.codecValues = codecValues
      }
    -- Binders keep their source names (LawSpec.JvmNames).
    localName' identity = M.findWithDefault (localName identity) identity jvmLocals
    jvmLocals = M.unions (map (\e -> jvmLocalTable "scala" (jvmReserved "scala") (propertyBinders (original e) ++ planBinders e)) ls ++
      [jvmLocalTable "scala" (jvmReserved "scala") (C.contractArguments c ++ [C.contractResult c]) | c <- contracts u] ++
      [jvmLocalTable "scala" (jvmReserved "scala") (concatMap (expressionBinders . snd) (maybe [] C.harnessBenchmarks (C.unitHarnessSettings u)))])
    planBinders e = [generatorBinder r | r <- generatorRequirements e] ++
      concat [drawBinders d | (_, _, d) <- C.harnessDraws (C.propertyHarness (original e))] ++
      concatMap expressionBinders (concat [generatorPredicates r ++ generatorHints r ++ map snd (generatorBounds r) | r <- generatorRequirements e])
    drawBinders d = case d of
      C.DrawFrequency alternatives -> concatMap (drawBinders . snd) alternatives
      C.DrawSuchThat inner binder predicate _ -> drawBinders inner ++ binder : expressionBinders predicate
      C.DrawBind binder from rest -> binder : drawBinders from ++ drawBinders rest
      _ -> []
    -- The codecs of the unit's scalar types, named as values (textCodec), so
    -- a call reads as what it converts.
    codecValues = [ (codecValueName t, java (scCodecDoc t)) | t <- scalarTypes ]
    scalarTypes = [C.scalarType (primitiveName p) | p <- primitives, primitiveName p `elem` map fst ScalaData.scalaScalars, not (custom (C.scalarType (primitiveName p)))]
    codecValueName t = case prettyType t of
      c : rest -> toLower c : rest ++ "Codec"
      [] -> "codec"
    -- Abilities: the unit's own, its spec handlers, and the handlers a law
    -- installs (Fail's are built in, so none is installed for it).
    abilityNamed = unitAbility u
    specNamed h = lookup h [(C.handlerId x, x) | x <- C.unitHandlers u]
    chosenHandlers e = [(a, c) | (a, c) <- C.propertyHandlers (original e), not (C.isFail a)]
    -- A handler of several abilities is made once per case and installed
    -- for each. A native handler made with a resource (ability A with T) is
    -- made with the case's T, once the case has acquired it.
    sharedOf e = nub [h | (_, c) <- chosenHandlers e, h <- specsOf c, not (null (C.handlerAlso h))]
    specsOf c = case c of
      C.SpecHandler h -> maybe [] pure (specNamed h)
      C.RecordingHandler inner -> specsOf inner
      C.ProductionHandler -> []
    sharedVar h = "shared" ++ cap (C.handlerName h)
    -- What an operation that `fails with E` fails with (Fail E).
    operationFailure op = maybe [] pure (abilityNamed (C.operationAbility op) >>= lookup (C.operationName op) . C.abilityFailures)
    resourceFor e a c = case c of
      C.ProductionHandler -> do
        x <- abilityNamed a
        t <- C.abilityResource x
        r <- listToMaybe [r | r <- C.propertyResources (original e), C.binderType (C.resourceBinder r) == t]
        pure (t, localName' (C.binderId (C.resourceBinder r)))
      C.RecordingHandler inner -> resourceFor e a inner
      C.SpecHandler _ -> Nothing
    earlyHandlers e = [(a, c) | (a, c) <- chosenHandlers e, resourceFor e a c == Nothing]
    lateHandlers e = [(a, c) | (a, c) <- chosenHandlers e, resourceFor e a c /= Nothing]
    lawMaking e = (map C.handlerId (sharedOf e), resourceFor e)
    plainMaking = ([], \_ _ -> Nothing)
    searchDescriptorsOf e = if searchable (finiteCases e /= Nothing) (original e) then lawDescriptors bits dataDeclarations (original e) else Nothing
    usesOf n = [a | d <- C.unitDeclarations u, C.declarationName d == n, a <- C.declarationUses d, not (C.isFail a)]
    failuresOf n = [a | d <- C.unitDeclarations u, C.declarationName d == n, a <- C.declarationUses d, C.isFail a]
    handlerParameter ability = case maybe "handler" C.abilityName (abilityNamed ability) of
      c : rest -> toLower c : rest
      [] -> "handler"
    splitOn c s = case break (== c) s of (a,[]) -> [a]; (a,_:b) -> a:splitOn c b
    cap [] = []
    cap (c:cs) = (if c >= 'a' && c <= 'z' then toEnum (fromEnum c - 32) else c):cs

builtinKey :: Type -> String
builtinKey (C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) =
  "Either (" ++ builtinKey a ++ ") (" ++ builtinKey b ++ ")"
builtinKey (Applied n t) = n ++ " " ++ builtinKey t
builtinKey t = prettyType t
