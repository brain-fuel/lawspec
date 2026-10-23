-- Haskell pieces of a unit's abilities (see LawSpec.AbilityNames). Each
-- ability is a record of IO functions, one per operation, in
-- LawSpecAbilities.<Unit>; its spec handlers (fakeGateway :: SymbolContext ->
-- IO Gateway) and recording (gatewayRecording) are in LawSpecHandlers.<Unit>,
-- apart, since the definitions that perform operations import the records
-- and the handlers call the definitions. Handlers travel with the symbol
-- context (LS.installHandlers); a performed operation finds its handler
-- with LS.handlerOf and runs with LS.performIO.
module LawSpec.AbilityEmit.Haskell (emit, productionStub, typesModule, handlersModule, handlerFunction, recordingFunction, productionFunction) where

import Data.Char (isAlphaNum, toLower, toUpper)
import Data.List (intercalate)
import Control.Monad (forM)
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..))
import LawSpec.AbilityNames
import LawSpec.Collections (isCollectionsType)
import qualified LawSpec.HaskellData as Native
import qualified LawSpec.HaskellDefinitions as Definitions
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Code.Haskell as H
import LawSpec.Code.Haskell (Stmt(Bind, Run), call, var, lambda, operator)
import LawSpec.SourceLink (labelled, sourceLink, generatedHeader, unitSourceFile)
import LawSpec.Typed.Plan (typedPlanPerforming, scalarTypes, isTypedHandler)

capitalize, lower :: String -> String
capitalize (c : cs) = toUpper c : cs
capitalize [] = []
lower (c : cs) = toLower c : cs
lower [] = []

split :: Char -> String -> [String]
split c s = case break (== c) s of
  (a, []) -> [a]
  (a, _ : rest) -> a : split c rest

modulePart :: String -> String
modulePart = concatMap capitalize . split '_'

unitModule :: String -> C.Unit -> String
unitModule prefix u = intercalate "." (prefix : map modulePart (split '.' (C.idText (C.unitId u))))

-- The module of a unit's ability records, and of its handlers.
typesModule, handlersModule :: C.Unit -> String
typesModule = unitModule "LawSpecAbilities"
handlersModule = unitModule "LawSpecHandlers"

-- fakeGateway's function, gatewayRecording, gatewayHandler (the user's).
handlerFunction :: C.Handler -> String
handlerFunction = C.handlerName

recordingFunction, productionFunction :: C.Ability -> String
recordingFunction = lower . recordingName
productionFunction = lower . productionName

emit :: Bool -> Int -> [C.DataDeclaration] -> [C.Unit] -> Either String [Artifact]
emit minify bits datas units = concat <$> mapM unitFiles (filter wanted units)
  where
    wanted u = not (null (C.unitAbilities u) && null (C.unitHandlers u))
    layout = H.layout minify
    collections = any (isCollectionsType . C.idText . C.dataId) datas
    candidates extra =
      [ ("Prelude", Just "P", Nothing), ("Data.Int", Just "I", Nothing), ("Data.Word", Just "W", Nothing)
      , ("Data.Text", Just "T", Nothing), ("Data.ByteString", Just "B", Nothing), ("Data.Complex", Just "C", Nothing)
      , ("Data.IORef", Just "IORef", Nothing), ("Control.Exception", Just "Exception", Nothing)
      , ("LawSpecRuntime", Nothing, Just ["Scalar (..)"]), ("LawSpecRuntime", Just "LS", Nothing)
      , ("LawSpecSchema", Just "Schema", Nothing), ("LawSpecCodecs", Just "Codec", Nothing)
      , ("LawSpecData", Just "Data", Nothing), ("LawSpecDataSchema", Just "DataSchema", Nothing)
      , ("LawSpecDataCodecs", Just "Codecs", Nothing) ] ++
      (if collections then [ ("LawSpecCollectionCodecs", Just "Collections", Nothing), ("Data.Set", Just "Set", Nothing)
                           , ("Data.Map.Strict", Just "Map", Nothing), ("Data.Sequence", Just "Seq", Nothing) ] else []) ++ extra
    environment = [ D.joinWith D.hardline [H.comment ["The program's types, which values are checked against."],
                      H.signature "schema" ["Schema.Schema"], H.declaration "schema" (call "P.either" [var "P.error", var "P.id", var "DataSchema.schema"])]
                  , D.joinWith D.hardline [H.comment ["The machine profile's integer width."],
                      H.signature "machineBits" ["P.Int"], H.declaration "machineBits" (H.integer (toInteger bits))] ]
    sourceFile u = unitSourceFile u
    -- A module: its header, the imports its code uses, and its declarations.
    file name u description exports extra unqualified bodies =
      let rendered = D.render D.Compact (D.joinWith D.hardline bodies)
          uses w = w `elem` words (map (\c -> if isAlphaNum c then c else ' ') rendered)
          environment' = [d | (d, w) <- zip environment ["schema", "machineBits"], uses w]
          imports = Definitions.moduleImports rendered (candidates extra ++ unqualified)
      in Artifact ("src/" ++ map (\c -> if c == '.' then '/' else c) name ++ ".hs")
      (D.render layout (D.joinWith D.hardline (map D.text
        (["-- " ++ generatedHeader (sourceFile u), "-- " ++ description, "", "module " ++ name ++ exports ++ " where", ""] ++
         (if null imports then [] else imports ++ [""]))) <>
        D.hardline <> D.joinWith (D.hardline <> D.hardline) (environment' ++ bodies) <> D.hardline)) "generated" "source"
    -- The modules of the abilities a unit imports, by their owners.
    ownerOf a = [v | v <- units, C.unitId v == C.abilityOwner a]
    imported u = [(v, a) | a <- C.unitAbilities u, C.abilityOwner a /= C.unitId u, v <- take 1 (ownerOf a)]
    unitFiles u = do
      records <- mapM record (ownAbilities u)
      handlers <- mapM specHandler (C.unitHandlers u)
      recordings <- mapM recording (ownAbilities u)
      tries <- concat <$> mapM attempts (ownAbilities u)
      let owners = nubStrings [typesModule v | (v, _) <- imported u]
          -- An imported ability's records come from its owner's module.
          exports = if null owners then "" else " (module " ++ typesModule u ++ concatMap (", module " ++) owners ++ ")"
          types = file (typesModule u) u ("The abilities of " ++ C.idText (C.unitId u) ++ ": a record of operations for each.")
            exports [] [(m, Nothing, Nothing) | m <- owners] records
          importedRecordings = [(handlersModule v, recordingFunction a) | (v, a) <- imported u]
          handlerExports = if null importedRecordings then "" else
            " (module " ++ handlersModule u ++ concatMap ((", " ++) . snd) importedRecordings ++ ")"
          handlerFile = file (handlersModule u) u ("The spec handlers of " ++ C.idText (C.unitId u) ++ ", and a recording of any handler.")
            handlerExports [("LawSpecDefinitionBodies", Just "Definitions", Nothing) | not (null (C.unitHandlers u))]
            ([(typesModule u, Nothing, Nothing)] ++ [(m, Nothing, Just [f]) | (m, f) <- importedRecordings])
            (handlers ++ recordings ++ tries)
      pure [types, handlerFile]
    nubStrings = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
    -- A spec handler is made by its function with the bodies, which handle
    -- ... with h end regions call too.
    specHandler h = do
      (_, ability) <- maybe (Left ("unknown ability of handler " ++ C.handlerName h)) Right (C.findAbility units (C.handlerAbility h))
      let name = handlerFunction h
          made = Definitions.specHandlerCall units (C.handlerId h)
      -- A handler of several abilities: its state, and a record for each
      -- ability over it, so a law makes the state once.
      others <- forM (C.handlerAbilities h) $ \ref -> maybe (Left ("unknown ability of handler " ++ C.handlerName h)) (Right . snd) (C.findAbility units ref)
      let typedState = isTypedHandler plan h && C.handlerState h /= Nothing
          parts = if null (C.handlerAlso h) && not typedState then [] else
            H.declaration (name ++ "State") (var (made ++ "State")) :
            [H.declaration (name ++ C.abilityName a) (var (made ++ C.abilityName a)) | a <- others] ++
            -- A typed state can be read and replaced, in its native types.
            concat [ [H.declaration (name ++ "Snapshot") (var (made ++ "Snapshot")), H.declaration (name ++ "Restore") (var (made ++ "Restore"))] | typedState ]
      pure (D.joinWith (D.hardline <> D.hardline) (D.joinWith D.hardline [H.comment [labelled ("spec handler " ++ C.handlerName h ++ " for " ++ C.abilityName ability) (sourceLink (C.handlerOrigin h))],
        H.signature name ["LS.SymbolContext", "P.IO " ++ interfaceName ability],
        H.declaration name (var made)] : parts))
    nativeType ty = Native.haskellDataType datas ty
    parenthesized t = if ' ' `elem` t && take 1 t /= "(" && take 1 t /= "[" then "(" ++ t ++ ")" else t
    operationType ty = do
      let (args, result) = C.functionType ty
      types <- mapM nativeType args
      resultType <- nativeType result
      pure (intercalate " -> " (map parenthesized types ++ ["P.IO " ++ parenthesized resultType]))
    record a = do
      fields <- mapM (\(op, ty) -> (\t -> (fieldName a op, t)) <$> operationType ty) (C.abilityOperations a)
      pure (D.joinWith D.hardline [H.comment ["The " ++ C.abilityName a ++ " ability: a handler answers each of its operations."],
        H.recordDeclaration (interfaceName a) (interfaceName a) fields])
    codec ty = Native.haskellCodecDocWithContext (call "P.Just" [var "symbols"]) datas "schema" "machineBits" ty
    plan = typedPlanPerforming scalarTypes datas units
    -- Each operation that fails with E, with its failure as Left, for any
    -- handler of the ability.
    attempts a = forM [ (op, ty, failing, failure) | (op, ty) <- C.abilityOperations a
                      , Just failing@(C.AbilityRef _ [failure]) <- [lookup op (C.abilityFailures a)] ] $ \(op, ty, failing, failure) -> do
      let (args, result) = C.functionType ty
          values = H.uniqueValues (length args)
          name = "try" ++ capitalize (fieldName a op)
      types <- mapM nativeType args
      resultType <- nativeType result
      failureType <- nativeType failure
      failureCodec <- Native.haskellCodecDocWithContext (var "P.Nothing") datas "schema" "machineBits" failure
      pure (D.joinWith D.hardline
        [ H.comment [op ++ ", with the failure it raises as Left rather than an exception."]
        , H.signature name ([interfaceName a] ++ map parenthesized types ++ ["P.IO (P.Either " ++ parenthesized failureType ++ " " ++ parenthesized resultType ++ ")"])
        , H.declaration (unwords (name : "handler" : values)) (H.Do
            [ Bind "outcome" (call "Exception.try" [operator "P.>>=" [call (fieldName a op) (map var ("handler" : values)), var "Exception.evaluate"]])
            , Run (H.Case (var "outcome")
                [ ("P.Right result", call "P.pure" [call "P.Right" [var "result"]])
                , ("P.Left (LS.Failure ability value) | ability P.== " ++ H.renderString (C.abilityKey failing),
                    call "P.fmap" [var "P.Left", call "LS.runClause" [call "Codec.decode" [failureCodec, var "value"]]])
                , ("P.Left failure", call "Exception.throwIO" [var "failure"]) ]) ]) ])
    recording a = do
      fields <- mapM (\(op, ty) -> do
        let (args, _) = C.functionType ty
            values = H.uniqueValues (length args)
        codecs <- mapM codec args
        let logged = call "LS.runClause" [call "P.sequence" [H.List [call "Codec.encode" [c, var v] | (c, v) <- zip codecs values]]]
            steps = H.Do
              [ Bind "logged" logged
              , Run (call "LS.recordCall" [var "calls", H.string op, var "logged"])
              , Run (call (fieldName a op) (map var ("inner" : values))) ]
        pure (fieldName a op, if null values then steps else lambda values steps)) (C.abilityOperations a)
      let name = recordingFunction a
      pure (D.joinWith D.hardline
        [ H.comment ["Records each call to a " ++ C.abilityName a ++ " handler, then passes it on."]
        , H.signature name ["LS.SymbolContext", interfaceName a, "P.IO (" ++ interfaceName a ++ ", LS.Calls)"]
        , H.declaration (name ++ " symbols inner") (H.Do
            [ Bind "calls" (var "LS.newCalls")
            , Run (call "P.pure" [H.Tuple [H.Record (interfaceName a) fields, var "calls"]]) ]) ])

-- The user-owned production handler of each ability, in the unit's adapter
-- module: gatewayHandler :: IO Gateway is what the tests use.
productionStub :: [C.DataDeclaration] -> C.Ability -> Either String D.Doc
productionStub datas a = do
  let name = productionFunction a
      fields = [ ("Abilities." ++ fieldName a op, (if null args then id else lambda (replicate (length args) "_")) (call "P.error" [H.string op]))
               | (op, ty) <- C.abilityOperations a, let (args, _) = C.functionType ty]
  _ <- mapM (Native.haskellDataType datas . snd . C.functionType . snd) (C.abilityOperations a)
  -- ability A with T: the handler is made with the case's T.
  made <- traverse (Native.haskellDataType datas) (C.abilityResource a)
  pure (D.joinWith D.hardline
    [ H.comment ["The native handler of " ++ displayName a ++ ": " ++ intercalate ", " (map fst (C.abilityOperations a)) ++ "."]
    , H.signature name (maybe [] (\t -> [parenthesizedType t]) made ++ ["P.IO Abilities." ++ interfaceName a])
    , H.declaration (name ++ maybe "" (const " _resource") made) (call "P.pure" [H.Record ("Abilities." ++ interfaceName a) fields]) ])
  where parenthesizedType t = if ' ' `elem` t && take 1 t /= "(" then "(" ++ t ++ ")" else t
