-- | Public binding configuration is resolved before entering target emission.
module LawSpec.NativeRequest
  ( NativeRequest(..), NetworkBinding(..), networkArtifacts, FunctionBinding(..), NameBinding(..), NativeCall(..), GoImport(..), ErlangInclude(..), BindingPlan(..), HandlerBinding(..), FailureMapping(..)
  , ActorBinding(..), ActorSource(..), ActorPersistence(..), ActorHandlerBinding(..), actorHandler
  , ResolvedActorBinding(..), ResolvedActorHandler(..), actorBoundAdapters
  , emptyNativeRequest, emptyBindingPlan, resolveNativeRequest, normalizedNativeRequest, hasBindings
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Char (isAscii, isAlpha, isAlphaNum, isLower)
import Data.List (find, nub, sortOn)
import qualified LawSpec.Core as C
import LawSpec.Core.Machine (Machine(..), MachineStart(..), Command(..), Invariant(..))
import qualified LawSpec.Core.Types as Types
import LawSpec.NativeBinding
import LawSpec.AbilityNames (interfaceName)
import LawSpec.Common (Artifact(..))

-- | The crate is needed only by Rust test linkage, not by the semantic Core.
data NativeRequest = NativeRequest
  { requestBindings :: Bindings, requestFunctions :: [FunctionBinding]
  , requestRustCrate :: Maybe String, requestGoImports :: [GoImport]
  , requestErlangIncludes :: [ErlangInclude]
  -- The production handler of each ability, by "<unit>::<Ability>".
  , requestHandlers :: [HandlerBinding]
  -- Native exceptions that become failures, by failure constructor.
  , requestFailures :: [FailureMapping]
  -- The node identity and trusted peers of the secure network handler.
  , requestNetwork :: Maybe NetworkBinding
  -- Public generated names are presentation choices, independent of native
  -- implementations and of the declaration's semantic identity.
  , requestNames :: [NameBinding]
  -- Existing native actors (Pekko Typed behaviours) checked against a
  -- LawSpec actor's model, by "<unit>::<actor>".
  , requestActors :: [ActorBinding]
  } deriving (Eq, Show)
-- actors: [{"actor": "<unit>::<actor>", "behavior": [...], "handlers": [...]}]:
-- an existing native actor that stands in for a LawSpec actor in its model
-- checks. LawSpec spawns the behaviour, asks it each handler's message and
-- compares the replies with the model; it never reads the actor's state.
-- ref:DEC-native-actor-binding
data ActorBinding = ActorBinding
  { boundActorName :: String, boundActorSource :: ActorSource
  , boundActorPersistence :: Maybe ActorPersistence, boundActorEntity :: Maybe NativeRef
  , boundActorHandlers :: [ActorHandlerBinding] } deriving (Eq, Show)
-- | Where the native actor comes from: a static factory returning the typed
-- behaviour (Behavior<Command>), or a Spring starter SpringActor class.
data ActorSource = BehaviorFactory NativeRef | SpringActorClass NativeRef deriving (Eq, Show)
-- | An event-sourced actor recovers its state from its journal after a
-- restart; the checks run it on an in-memory journal.
data ActorPersistence = EventSourced deriving (Eq, Show)
-- | A handler is one message class. Its constructor takes the handler's
-- arguments (after the state), then the replyTo ActorRef when replyTo is
-- true; the reply class's result accessor gives the LawSpec result.
--
-- For the samples' own messages (apache/pekko-samples), a handler may also
-- give: the reply's type arguments (StatusReply<Summary>); a public field
-- that holds the result instead of an accessor; a caller, its first
-- argument, whose own reply address the message carries in place of a
-- fresh replyTo, so that every message from one caller comes from one
-- address; and a static factory that makes the message, for a message whose
-- constructor takes values no codec makes. ref:DEC-pekko-sample-suites
data ActorHandlerBinding = ActorHandlerBinding
  { boundHandlerName :: String, handlerMessage :: NativeRef, handlerReplyTo :: Bool
  , handlerReply :: Maybe NativeRef, handlerResult :: Maybe String
  , handlerReplyArguments :: [NativeRef], handlerResultField :: Maybe String
  , handlerCaller :: Bool, handlerMessageFactory :: Bool } deriving (Eq, Show)

-- | A handler binding with only the original fields: a message class, its
-- replyTo, reply class and result accessor.
actorHandler :: String -> NativeRef -> Bool -> Maybe NativeRef -> Maybe String -> ActorHandlerBinding
actorHandler name message replyTo reply result = ActorHandlerBinding name message replyTo reply result [] Nothing False False
-- | An actor binding checked against the actor's declaration: each handler
-- with the adapter it stands for, its argument types after the state, and
-- its result type (Nothing for Unit).
data ResolvedActorBinding = ResolvedActorBinding
  { resolvedActorUnit :: C.Id, resolvedActorName :: String, resolvedActorSource :: ActorSource
  , resolvedActorPersistence :: Maybe ActorPersistence, resolvedActorEntity :: Maybe NativeRef
  , resolvedActorHandlers :: [ResolvedActorHandler]
  -- Every adapter the native actor stands for: its start, handlers and
  -- restart. LawSpec never calls them.
  , resolvedActorAdapters :: [C.Id] } deriving (Eq, Show)
data ResolvedActorHandler = ResolvedActorHandler
  { resolvedHandlerBinding :: ActorHandlerBinding, resolvedHandlerAdapter :: C.Id
  , resolvedHandlerArguments :: [C.Type], resolvedHandlerResult :: Maybe C.Type } deriving (Eq, Show)
-- network: {"identity": "<file>", "trusted": "<file>"}: the file holding a
-- node's ML-DSA-65 identity seed (64 hexadecimal digits), and the file
-- listing the SHA3-256 fingerprints of the only peers to talk to, one per
-- line; both relative to the project. Without it a node makes a fresh
-- identity and talks to any peer. No setting turns security off.
data NetworkBinding = NetworkBinding { networkIdentity :: Maybe FilePath, networkTrusted :: Maybe FilePath }
  deriving (Eq, Show)
-- failures: [{"native": [...], "failure": "<unit>::<Type>::<Constructor>"}]:
-- an adapter that fails with the type turns the native exception (a class,
-- an error type, or a panic payload type) into that constructor, which has
-- no fields or one Text field, given the exception's message.
data FailureMapping = FailureMapping { mappedNative :: NativeRef, mappedFailure :: String } deriving (Eq, Show)
-- handlers: [{"ability": "payments::Gateway", "native": [...]}]: a native
-- constructor (a class, or a function of no arguments; an IO action in
-- Haskell) that makes the production handler.
data HandlerBinding = HandlerBinding { boundAbility :: String, boundNative :: NativeRef } deriving (Eq, Show)
-- | A Go binding names the package it imports and the alias to use, since Go
-- requires both.
data GoImport = GoImport { goImportAlias :: String, goImportPath :: String } deriving (Eq, Show)
-- | Record field positions come from the application's header, never from
-- configuration order. Library headers use Erlang's include_lib directive.
data ErlangInclude = ErlangInclude { erlangIncludePath :: FilePath, erlangIncludeLibrary :: Bool }
  deriving (Eq, Show)
-- | An adapter bound to native code is called directly, with no stub for the user
-- to fill in. ref:DEC-native-bindings-typed-identity
data FunctionBinding = FunctionBinding
  { functionDeclaration :: C.Id, functionNative :: NativeCall } deriving (Eq, Show)
data NameBinding = NameBinding
  { nameDeclaration :: C.Id, nameOverride :: String } deriving (Eq, Show)
-- | How a bound adapter calls native code: a static function, a method of its
-- handle argument (`method`), or a native constructor (`constructor`), for a
-- model's start.
data NativeCall = StaticCall NativeRef | MethodCall String | ConstructorCall NativeRef
  deriving (Eq, Show)
-- | The checked bindings the emitters receive, so they never resolve a name in
-- lawspec.edn themselves.
data BindingPlan = BindingPlan
  { bindingRepresentations :: ResolvedBindings
  -- Static function bindings, and the method and constructor bindings of
  -- handles (never StaticCall).
  , bindingFunctions :: [(C.Declaration, NativeRef)]
  , bindingCalls :: [(C.Declaration, NativeCall)]
  , bindingRustCrate :: Maybe String, bindingGoImports :: [GoImport]
  , bindingErlangIncludes :: [ErlangInclude]
  -- Each bound ability's production handler, by the ability instance's key.
  , bindingHandlers :: [(C.Id, NativeRef)]
  -- The native exceptions that become failures.
  , bindingFailures :: [C.FailureBinding]
  , bindingNames :: [(C.Id, String)]
  -- Native actors checked in place of LawSpec actors.
  , bindingActors :: [ResolvedActorBinding]
  } deriving (Eq, Show)
-- | A request without bindings.
emptyNativeRequest :: NativeRequest
emptyNativeRequest = NativeRequest emptyBindings [] Nothing [] [] [] [] Nothing [] []
-- | A plan without bindings, which emitters treat as the generated-types path.
emptyBindingPlan :: BindingPlan
emptyBindingPlan = BindingPlan (ResolvedBindings [] []) [] [] Nothing [] [] [] [] [] []

-- | The adapters native actors stand for, which LawSpec never calls.
actorBoundAdapters :: BindingPlan -> [C.Id]
actorBoundAdapters = concatMap resolvedActorAdapters . bindingActors
-- | Only resolver-independent configuration orders are normalized. Failure
-- mappings retain their first-match precedence.
normalizedNativeRequest :: NativeRequest -> BindingPlan -> NativeRequest
normalizedNativeRequest request resolved=request{requestBindings=Bindings types generators,
  requestFunctions=sortOn functionDeclaration (requestFunctions request),requestNames=sortOn nameDeclaration (requestNames request),
  requestHandlers=sortOn boundAbility (requestHandlers request),
  requestActors=sortOn boundActorName (requestActors request),
  requestGoImports=sortOn goImportAlias (requestGoImports request)}
  where
    types=[TypeBinding (C.dataId (resolvedDeclaration binding)) (resolvedNativeType binding)
      [ConstructorBinding (C.constructorName (resolvedConstructor constructor)) (resolvedNativeConstructor constructor)
        (resolvedConstructorStyle constructor) (case resolvedFieldPaths constructor of
          Nothing->[FieldBinding (C.binderName field) native | (field,native)<-resolvedFields constructor]
          Just paths->[NestedFieldBinding label native rest index |
            (index,((_,native),label:rest))<-zip [0..] (zip (resolvedFields constructor) paths)]) |
        constructor<-resolvedConstructors binding] (resolvedCodec binding) (resolvedArguments binding) |
      binding<-sortOn (C.dataId . resolvedDeclaration) (resolvedTypes (bindingRepresentations resolved))]
    generators=sortOn generatorType (generatorBindings (requestBindings request))


-- | Projects without bindings skip the binding companion files. Bound handlers
-- and failures do not count: they only change how the tests make production
-- handlers and catch native failures.
hasBindings :: BindingPlan -> Bool
hasBindings plan = plan { bindingHandlers = [], bindingFailures = [], bindingNames = [] } /= emptyBindingPlan

-- | Bindings are checked against the compiled program before emission, so a
-- misspelled name is an error with that name, not a target build failure.
resolveNativeRequest :: C.Program -> NativeRequest -> Either String BindingPlan
resolveNativeRequest program NativeRequest{..} = do
  representations <- resolveBindings (C.programDataDeclarations program) requestBindings
  unless (length requestNames == length (nub (map nameDeclaration requestNames)))
    (Left "duplicate native name override")
  names <- mapM resolveName requestNames
  unless (length requestFunctions == length (nub (map functionDeclaration requestFunctions)))
    (Left "duplicate native function binding")
  functions <- mapM resolve requestFunctions
  mapM_ validIdentifier requestRustCrate
  unless (length requestGoImports == length (nub (map goImportAlias requestGoImports)))
    (Left "duplicate Go import alias")
  unless (length requestGoImports == length (nub (map goImportPath requestGoImports)))
    (Left "duplicate Go import path")
  mapM_ validateGoImport requestGoImports
  mapM_ validateErlangInclude requestErlangIncludes
  unless (length requestErlangIncludes == length (nub requestErlangIncludes))
    (Left "duplicate Erlang include")
  handlers <- mapM handler requestHandlers
  unless (length handlers == length (nub (map fst handlers))) (Left "duplicate native handler binding")
  failures <- mapM failureMapping requestFailures
  unless (length failures == length (nub (map C.failureNative failures))) (Left "duplicate native failure mapping")
  unless (length requestActors == length (nub (map boundActorName requestActors))) (Left "duplicate native actor binding")
  actors <- mapM actorBinding requestActors
  let adapters = concatMap resolvedActorAdapters actors
  unless (length adapters == length (nub adapters)) (Left "two native actor bindings stand for the same adapter")
  forM_ adapters $ \identity -> when (identity `elem` map functionDeclaration requestFunctions)
    (Left ("native function binding " ++ C.idText identity ++ ": the adapter belongs to a natively bound actor"))
  pure (BindingPlan representations [(d, ref) | (d, StaticCall ref) <- functions]
    [(d, call) | (d, call) <- functions, not (isStatic call)] requestRustCrate requestGoImports requestErlangIncludes handlers failures names actors)
  where
    -- A native actor stands for a LawSpec actor's start, handlers and
    -- restart. Shapes LawSpec cannot ask or observe are explicit errors.
    actorBinding ActorBinding{..} = do
      let context message = Left ("native actor " ++ boundActorName ++ ": " ++ message)
          (unitName, actorName) = breakOn boundActorName
          found = [(u, m) | u <- C.programUnits program, C.idText (C.unitId u) == unitName,
                    m <- C.unitMachines u, machineActor m, machineName m == actorName]
      (u, machine) <- case found of
        [x] -> pure x
        _ -> Left ("unknown actor in a native actor binding: " ++ boundActorName ++ " (write <unit>::<actor>)")
      case boundActorSource of
        BehaviorFactory ref -> validReference ref
        SpringActorClass ref -> validReference ref
      mapM_ validReference boundActorEntity
      when (boundActorEntity /= Nothing && boundActorPersistence /= Nothing)
        (context "unsupported: an event-sourced sharded entity; check the entity without sharding, or without persistence")
      let declarationOf identity = find ((== identity) . C.declarationId) (C.unitDeclarations u)
          handlerCommands = [c | c <- machineCommands machine, not (commandRestart c)]
          names = map commandName handlerCommands
          given = map boundHandlerName boundActorHandlers
      unless (length given == length (nub given)) (context "a handler is bound twice")
      forM_ given $ \name -> unless (name `elem` names)
        (context ("there is no handler " ++ name ++ "; the actor's handlers are " ++ unwords names))
      forM_ names $ \name -> unless (name `elem` given)
        (context ("handler " ++ name ++ " has no message binding"))
      -- The native actor keeps its state to itself, so nothing may read it.
      when (machineAbstractRun machine /= Nothing)
        (context "unsupported: its abstract function reads the actor's state, which a native actor keeps private; state the property as a model invariant or a law over replies")
      forM_ [p | OnState p <- machineInvariants machine] $ \p ->
        context ("unsupported: invariant " ++ C.idText p ++ " reads the actor's state, which a native actor keeps private; state it over the model instead")
      start <- case machineStart machine of
        Nothing -> context "it has no start"
        Just s -> pure s
      startDeclaration <- maybe (context "its start is not an adapter") pure (declarationOf (startSystem start))
      unless (all (== C.scalarType "Unit") (fst (C.functionType (C.declarationType startDeclaration))))
        (context "unsupported: its start takes arguments; a native behaviour is spawned from its factory alone")
      handlers <- forM handlerCommands $ \command -> do
        let hcontext message = context ("handler " ++ commandName command ++ ": " ++ message)
        binding <- maybe (hcontext "has no message binding") pure
          (find ((== commandName command) . boundHandlerName) boundActorHandlers)
        declaration <- maybe (hcontext "is not an adapter") pure (declarationOf (commandSystem command))
        unless (null [a | a <- C.declarationUses declaration, not (C.isFail a)])
          (hcontext "unsupported: it uses abilities, which a native message cannot carry")
        when (C.declarationAsync declaration) (hcontext "unsupported: an async handler has no single reply to ask for")
        let (arguments, declared) = C.functionType (C.declarationType declaration)
            others = drop 1 arguments
            result = if commandReturnsUnit command then Nothing else case declared of
              C.Constructor name [C.TypeArgument r, _] | name `elem` ["Pair", "lawspec.collections::type::Pair"] -> Just r
              other -> Just other
            ActorHandlerBinding{..} = binding
        validReference handlerMessage
        mapM_ validReference handlerReply
        mapM_ validReference handlerReplyArguments
        mapM_ validIdentifier handlerResult
        mapM_ validIdentifier handlerResultField
        forM_ (others ++ maybe [] pure result) $ \ty -> unless (firstOrder ty)
          (hcontext ("unsupported: " ++ typeText ty ++ " cannot cross a native message; use data types, collections and scalars"))
        when (handlerResult /= Nothing && handlerResultField /= Nothing)
          (hcontext "give the result's accessor (\"result\") or its field (\"resultField\"), not both")
        let reads = handlerResult /= Nothing || handlerResultField /= Nothing
            -- A caller's own address, or a fresh replyTo, receives the reply.
            answered = handlerReplyTo || handlerCaller
        -- The first argument names the caller, or the sharded entity.
        when (handlerCaller && null others) (hcontext "a caller is its first argument, so it needs one")
        when (handlerCaller && handlerReplyTo)
          (hcontext "its message carries the caller's own address, so it has no replyTo as well")
        when (handlerCaller && boundActorEntity /= Nothing)
          (hcontext "unsupported: a caller of a sharded entity; the first argument names the entity")
        when (boundActorEntity /= Nothing) $ case others of
          C.Constructor "Text" [] : _ -> pure ()
          _ -> hcontext "a sharded entity's handler takes the entity's id, a Text, first"
        unless (null handlerReplyArguments || handlerReply /= Nothing)
          (hcontext "reply type arguments need the reply class (\"reply\")")
        case result of
          Just ty -> do
            unless answered
              (hcontext ("returns " ++ typeText ty ++ ", so its message needs a replyTo to answer with (\"replyTo\": true)"))
            when (handlerReply == Nothing) (hcontext "returns a result, so it needs the reply class (\"reply\")")
          Nothing -> do
            when reads (hcontext "returns no result, so its reply has no result accessor")
            when (handlerReply /= Nothing && not answered) (hcontext "names a reply class but its message has no replyTo")
            when (handlerReplyTo && handlerReply == Nothing) (hcontext "has a replyTo, so it needs the acknowledgement's reply class (\"reply\")")
        when (reads && handlerReply == Nothing) (hcontext "a result accessor needs a reply class")
        pure (ResolvedActorHandler binding (commandSystem command) others result)
      let restart = [commandSystem c | c <- machineCommands machine, commandRestart c]
      pure (ResolvedActorBinding (C.unitId u) actorName boundActorSource boundActorPersistence boundActorEntity
        handlers (startSystem start : map resolvedHandlerAdapter handlers ++ restart))
    typeText ty = case ty of
      C.Constructor name [] -> name
      C.Constructor name arguments -> "(" ++ unwords (name : [typeText t | C.TypeArgument t <- arguments]) ++ ")"
      C.Arrow a b -> "(" ++ typeText a ++ " -> " ++ typeText b ++ ")"
      other -> show other
    -- Values cross a native message through the codecs: functions and
    -- other actors' handles cannot.
    firstOrder ty = case ty of
      C.Arrow _ _ -> False
      C.Constructor name arguments -> name `notElem` actorHandles &&
        and [firstOrder t | C.TypeArgument t <- arguments]
      _ -> True
    actorHandles = [C.idText (C.dataId d) | d <- C.programDataDeclarations program, C.dataHandle d,
      any (\u -> any (\m -> machineActor m && machineState m == C.idText (C.dataId d)) (C.unitMachines u)) (C.programUnits program)]
    resolveName NameBinding{..} = do
      unless (nameDeclaration `elem` [C.declarationId d | u <- C.programUnits program, d <- C.unitDeclarations u])
        (Left ("unknown declaration in native name override: " ++ C.idText nameDeclaration))
      validIdentifier nameOverride
      unless (case nameOverride of c:_ -> isLower c; [] -> False)
        (Left "a public native function name override must start with a lowercase letter")
      pure (nameDeclaration, nameOverride)
    definitions = [C.declarationId (C.definitionDeclaration d) |
      u <- C.programUnits program, d <- C.unitDefinitions u]
    declarations = [d | u <- C.programUnits program, d <- C.unitDeclarations u,
      C.declarationId d `notElem` definitions]
    handles = [C.idText (C.dataId d) | d <- C.programDataDeclarations program, C.dataHandle d]
    -- An ability by <unit>::<Name>, and a parameterized one's instance by
    -- <unit>::<Name><Types> (Store Int32 is StoreInt32); the unit is the
    -- one that declares it.
    abilities = nub [ (owner ++ "::" ++ name, C.Id (C.abilityKey (C.abilityInstance a)))
                    | u <- C.programUnits program, a <- C.unitAbilities u, C.abilityOwner a == C.unitId u
                    , let owner = C.idText (C.unitId u)
                    , name <- [interfaceName a] ++ [C.abilityName a | null (C.abilityArguments a)] ]
    failureMapping FailureMapping{..} = do
      validReference mappedNative
      let (unit, rest) = breakOn mappedFailure
          (typeName, constructor) = breakOn rest
          identity = unit ++ "::type::" ++ typeName ++ "::" ++ constructor
          context = "failure mapping " ++ mappedFailure
      unless (not (null unit) && not (null typeName) && not (null constructor))
        (Left (context ++ ": write <unit>::<Type>::<Constructor>"))
      (declaration, found) <- maybe (Left (context ++ ": there is no such constructor")) Right $ case
        [(d, c) | d <- C.programDataDeclarations program, c <- C.dataConstructors d, C.idText (C.constructorId c) == identity] of
          x : _ -> Just x
          [] -> Nothing
      let wanted = C.Constructor (C.idText (C.dataId declaration)) []
      registry <- Types.makeRegistry (C.programDataDeclarations program)
      fields <- Types.constructorFieldsFor registry wanted (C.constructorId found)
      payload <- case fields of
        [] -> pure Nothing
        [field] -> Just <$> messagePayload registry context [] (C.binderType field)
        _ -> Left (context ++ ": the constructor must have no payload, or one Text/message product payload")
      pure (C.FailureBinding (referenceParts mappedNative) (C.constructorId found) wanted payload)
    messagePayload _ _ _ (C.Constructor "Text" []) = pure C.ExceptionMessage
    messagePayload registry context seen ty@(C.Constructor name _) = do
      let invalid = Left (context ++ ": the message payload must be Text or a nonrecursive single-field product ending in Text")
      -- Repeated applications such as Message (Message Text) descend through
      -- finite type arguments. A recursive field that repeats or grows an
      -- application cannot supply a finite message construction.
      let previous = [prior | prior@(C.Constructor owner _) <- seen, owner == name]
      if case previous of prior:_ -> not (properTypePart ty prior); [] -> False
        then invalid else do
        declaration <- Types.lookupData registry (C.Id name)
        case C.dataConstructors declaration of
          [constructor] | not (C.dataHandle declaration), C.dataIndex declaration == Nothing,
                          null (C.constructorEquations constructor), null (C.constructorExistentials constructor) -> do
            fields <- Types.constructorFieldsFor registry ty (C.constructorId constructor)
            case fields of
              [field] -> C.MessageProduct ty (C.constructorId constructor) <$>
                messagePayload registry context (ty:seen) (C.binderType field)
              _ -> invalid
          _ -> invalid
    messagePayload _ context _ _ = Left (context ++ ": the message payload requires a concrete Text/product type")
    properTypePart wanted (C.Constructor _ arguments) = or
      [wanted == child || properTypePart wanted child | C.TypeArgument child <- arguments]
    properTypePart _ _ = False
    breakOn text = case text of
      ':' : ':' : rest -> ("", rest)
      c : rest -> let (a, b) = breakOn rest in (c : a, b)
      [] -> ("", "")
    handler HandlerBinding{..} = do
      identity <- maybe (Left ("unknown ability in a handler binding: " ++ boundAbility ++ " (write <unit>::<Ability>)")) Right
        (lookup boundAbility abilities)
      validReference boundNative
      pure (identity, boundNative)
    isHandle ty = case ty of
      C.Constructor name [] -> name `elem` handles
      _ -> False
    resolve FunctionBinding{..} = do
      declaration <- maybe (Left ("unknown adapter binding: " ++ C.idText functionDeclaration)) Right
        (find ((== functionDeclaration) . C.declarationId) declarations)
      let (arguments, result) = C.functionType (C.declarationType declaration)
          context = C.idText functionDeclaration
      case functionNative of
        StaticCall ref -> validReference ref
        ConstructorCall ref -> do
          validReference ref
          unless (isHandle result) (Left (context ++ ": a constructor binding must return a handle"))
        MethodCall name -> do
          validIdentifier name
          unless (any isHandle arguments)
            (Left (context ++ ": a method binding needs a handle argument to call it on"))
      -- An async adapter binds a native function or method returning the
      -- target's asynchronous type; its bridge stays asynchronous and
      -- converts the result once it completes. A constructor is called at
      -- once, and its bridge returns a completed task.
      pure (declaration,functionNative)

isStatic :: NativeCall -> Bool
isStatic (StaticCall _) = True
isStatic _ = False

strict :: String -> [String] -> (Object -> Parser a) -> Value -> Parser a
strict label keys parse = withObject label $ \object -> do
  let unknown = [K.toString key | key <- KM.keys object, K.toString key `notElem` keys]
  unless (null unknown) (fail (label ++ ": unknown fields " ++ show unknown))
  parse object
validIdentifier :: String -> Either String ()
validIdentifier value = unless valid (Left ("invalid native identifier: " ++ show value))
  where valid = case value of
          c:cs -> isAscii c && (isAlpha c || c == '_') && value /= "_" &&
            all (\x -> isAscii x && (isAlphaNum x || x == '_')) cs
          [] -> False
validReference :: NativeRef -> Either String ()
validReference (NativeRef parts) = do
  unless (not (null parts)) (Left "empty native reference")
  mapM_ validIdentifier parts
instance FromJSON NativeRef where
  parseJSON value = do
    ref <- NativeRef <$> parseJSON value
    either fail pure (validReference ref)
    pure ref
instance FromJSON ConstructorStyle where
  parseJSON = withText "constructor style" $ \case
    "record" -> pure RecordConstructor
    "variant" -> pure VariantConstructor
    "unit" -> pure UnitConstructor
    _ -> fail "constructor style must be record, variant, or unit"
instance FromJSON FieldBinding where
  parseJSON = strict "native field" ["field","native","path","argument"] $ \o -> do
    field<-o .: "field"
    native<-o .: "native"
    path<-o .:? "path"
    argument<-o .:? "argument"
    case (path,argument) of
      (Nothing,Nothing)->pure (FieldBinding field native)
      (Just names,Just index)->pure (NestedFieldBinding field native names index)
      _->fail "native field path and argument must be supplied together"
instance FromJSON ConstructorBinding where
  parseJSON = strict "native constructor" ["constructor","native","style","fields"] $ \o ->
    ConstructorBinding <$> o .: "constructor" <*> o .: "native" <*> o .: "style" <*> o .:? "fields" .!= []
instance FromJSON CodecBinding where
  parseJSON = strict "native codec" ["toNative","fromNative"] $ \o ->
    CodecBinding <$> o .: "toNative" <*> o .: "fromNative"
instance FromJSON TypeBinding where
  parseJSON = strict "native type" ["type","native","constructors","codec","arguments"] $ \o ->
    TypeBinding <$> (C.Id <$> o .: "type") <*> o .: "native" <*> o .:? "constructors" .!= [] <*> o .:? "codec" <*> o .:? "arguments"
instance FromJSON GeneratorBinding where
  parseJSON = strict "native generator" ["type","factory","stub"] $ \o ->
    GeneratorBinding <$> (C.Id <$> o .: "type") <*> o .: "factory" <*> o .:? "stub" .!= False
instance FromJSON FunctionBinding where
  parseJSON = strict "native function" ["declaration","native","method","constructor"] $ \o -> do
    declaration <- C.Id <$> o .: "declaration"
    native <- o .:? "native"
    method <- o .:? "method"
    constructor <- o .:? "constructor"
    call <- case (native, method, constructor) of
      (Just ref, Nothing, Nothing) -> pure (StaticCall ref)
      (Nothing, Just name, Nothing) -> pure (MethodCall name)
      (Nothing, Nothing, Just ref) -> pure (ConstructorCall ref)
      _ -> fail "native function: give exactly one of native, method or constructor"
    pure (FunctionBinding declaration call)
validateGoImport :: GoImport -> Either String ()
validateGoImport (GoImport alias path) = do
  validIdentifier alias
  let segments value = case break (== '/') value of
        (a,[]) -> [a]
        (a,_:rest) -> a : segments rest
  unless (not (null path) && all (\c -> isAscii c && (isAlphaNum c || c `elem` ("._-/~" :: String))) path &&
    all (\part -> not (null part) && part /= "." && part /= "..") (segments path))
    (Left "Go import path must be a module import path without empty or traversal segments")

instance FromJSON GoImport where
  parseJSON = strict "Go import" ["alias","path"] $ \o -> do
    value <- GoImport <$> o .: "alias" <*> o .: "path"
    either fail pure (validateGoImport value)
    pure value
validateErlangInclude :: ErlangInclude -> Either String ()
validateErlangInclude (ErlangInclude path _) =
  unless (not (null path) && all (`notElem` ['\0','\n','\r']) path)
    (Left "Erlang include path must be nonempty and contain no NUL or newline")
instance FromJSON ErlangInclude where
  parseJSON = strict "Erlang include" ["path","library"] $ \o -> do
    value <- ErlangInclude <$> o .: "path" <*> o .:? "library" .!= False
    either fail pure (validateErlangInclude value)
    pure value
instance FromJSON HandlerBinding where
  parseJSON = strict "native handler" ["ability","native"] $ \o ->
    HandlerBinding <$> o .: "ability" <*> o .: "native"
instance FromJSON FailureMapping where
  parseJSON = strict "native failure" ["native","failure"] $ \o ->
    FailureMapping <$> o .: "native" <*> o .: "failure"
instance FromJSON NameBinding where
  parseJSON = strict "native name override" ["declaration","name"] $ \o ->
    NameBinding . C.Id <$> o .: "declaration" <*> o .: "name"
instance FromJSON ActorBinding where
  parseJSON = strict "native actor" ["actor","behavior","spring","persistence","entity","handlers"] $ \o -> do
    name <- o .: "actor"
    behavior <- o .:? "behavior"
    spring <- o .:? "spring"
    source <- case (behavior, spring) of
      (Just ref, Nothing) -> pure (BehaviorFactory ref)
      (Nothing, Just ref) -> pure (SpringActorClass ref)
      _ -> fail ("native actor " ++ name ++ ": give exactly one of behavior or spring")
    persistence <- (o .:? "persistence" :: Parser (Maybe String)) >>= \case
      Nothing -> pure Nothing
      Just "event-sourced" -> pure (Just EventSourced)
      Just other -> fail ("native actor " ++ name ++ ": persistence must be \"event-sourced\", not " ++ show other)
    ActorBinding name source persistence <$> o .:? "entity" <*> o .: "handlers"
instance FromJSON ActorHandlerBinding where
  parseJSON = strict "native actor handler" ["handler","message","messageFactory","replyTo","reply","replyArguments","result","resultField","caller"] $ \o -> do
    name <- o .: "handler"
    -- One message, one reply: several replies or a stream of them have no
    -- single result to compare with the model.
    (o .:? "reply" :: Parser (Maybe Value)) >>= \case
      -- A reference is an array of names; an array of references is several.
      Just (Array items) | any (\case Array _ -> True; _ -> False) items -> fail ("native actor handler " ++ name ++ ": unsupported: one reply class per handler; several replies or a stream of replies cannot be compared with one model result")
      _ -> pure ()
    message <- o .:? "message"
    factory <- o .:? "messageFactory"
    (ref, made) <- case (message, factory) of
      (Just ref, Nothing) -> pure (ref, False)
      (Nothing, Just ref) -> pure (ref, True)
      _ -> fail ("native actor handler " ++ name ++ ": give exactly one of message or messageFactory")
    binding <- ActorHandlerBinding name ref <$> o .:? "replyTo" .!= False <*> o .:? "reply" <*> o .:? "result"
      <*> o .:? "replyArguments" .!= [] <*> o .:? "resultField" <*> o .:? "caller" .!= False
    pure (binding made)
instance FromJSON NativeRequest where
  parseJSON = strict "nativeBindings" ["types","generators","functions","rustCrate","goImports","erlangIncludes","handlers","failures","network","names","actors"] $ \o -> do
    types <- o .:? "types" .!= []
    generators <- o .:? "generators" .!= []
    NativeRequest (Bindings types generators) <$> o .:? "functions" .!= [] <*> o .:? "rustCrate" <*> o .:? "goImports" .!= []
      <*> o .:? "erlangIncludes" .!= [] <*> o .:? "handlers" .!= [] <*> o .:? "failures" .!= [] <*> o .:? "network" <*> o .:? "names" .!= []
      <*> o .:? "actors" .!= []
instance FromJSON NetworkBinding where
  parseJSON = strict "network" ["identity","trusted"] $ \o ->
    NetworkBinding <$> o .:? "identity" <*> o .:? "trusted"

-- lawspec-network.conf, which every runtime reads when it makes a node
-- (looking in the working directory and the directories above it): a line
-- `identity <file>` and a line `trusted <file>`, relative to the project.
networkArtifacts :: NativeRequest -> [Artifact]
networkArtifacts request = case requestNetwork request of
  Nothing -> []
  Just binding ->
    [ Artifact "lawspec-network.conf" (unlines (
        "# Generated by LawSpec from lawspec.edn (network). Do not edit." :
        ["identity " ++ f | Just f <- [networkIdentity binding]] ++
        ["trusted " ++ f | Just f <- [networkTrusted binding]])) "generated" "source" ]
