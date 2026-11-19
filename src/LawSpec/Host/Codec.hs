{-# LANGUAGE GADTs #-}

-- | The versioned JSON envelope of the host-effect ABI. The core encodes an
-- 'Effect' with 'encodeEffect' and decodes the host's answer with
-- 'decodeResult'; the host-side halves ('decodeEffect', 'encodeResult') let
-- Haskell tests, the conformance suite and future Haskell hosts speak the
-- same bytes. docs/reference/host-effects.md is the normative description.
-- ref:DEC-host-effect-abi
module LawSpec.Host.Codec
  ( abiVersion,
    encodeEffect,
    decodeEffect,
    encodeResult,
    decodeResult,
    encodeEffectBytes,
    decodeResultBytes,
    encodePolicy,
    decodePolicy,
  )
where

import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as JSON
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (toList)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import LawSpec.Host.Base64 (decodeBase64, encodeBase64)
import LawSpec.Host.Effect
import LawSpec.Host.Policy (Policy (..))

-- | Raised only when an incompatible change is made to the envelope or to an
-- existing operation. New operations do not change it: a host that predates
-- one answers it 'Unsupported'. Version 2 added the mandatory @policy@ of
-- every effect request; @realpath@, @terminal@ and @rename@, and the
-- optional @permissions@ of @write@, @mkdirs@ and @stat@, were added within
-- it.
abiVersion :: Int
abiVersion = 2

encodeEffectBytes :: Policy -> Effect a -> B.ByteString
encodeEffectBytes policy = BL.toStrict . JSON.encode . encodeEffect policy

decodeResultBytes :: Effect a -> B.ByteString -> Either String (Either HostError a)
decodeResultBytes effect bytes = JSON.eitherDecodeStrict bytes >>= decodeResult effect

-- | An effect request, with the policy the host must enforce again.
encodeEffect :: Policy -> Effect a -> Value
encodeEffect policy effect =
  object (["abi" .= abiVersion, "op" .= effectName effect, "policy" .= encodePolicy policy] ++ fields effect)
  where
    fields :: Effect b -> [(K.Key, Value)]
    fields = \case
      ReadFile path -> ["path" .= path]
      WriteFile mode permissions path bytes ->
        ["path" .= path, "data" .= bytesValue bytes, "mode" .= writeModeName mode] ++ permissionsField permissions
      ListDirectory path -> ["path" .= path]
      Stat follow path -> ["path" .= path, "follow" .= (follow == Follow)]
      RealPath path -> ["path" .= path]
      Remove recursive path -> ["path" .= path, "recursive" .= (recursive == Recursive)]
      Rename from to -> ["from" .= from, "to" .= to]
      MakeDirectories permissions path -> ["path" .= path] ++ permissionsField permissions
      Spawn request ->
        [ "argv" .= spawnArguments request,
          "cwd" .= spawnDirectory request,
          "env" .= maybe Null pairsObject (spawnEnvironment request),
          "stdin" .= maybe Null bytesValue (spawnInput request)
        ]
      Poll handles timeout -> ["handles" .= [handle | ProcessHandle handle <- handles], "timeoutMs" .= timeout]
      Kill (ProcessHandle handle) -> ["handle" .= handle]
      Fetch request ->
        [ "url" .= fetchUrl request,
          "method" .= fetchMethod request,
          "headers" .= headersValue (fetchHeaders request),
          "body" .= maybe Null bytesValue (fetchBody request)
        ]
      GetEnvironment name -> ["name" .= name]
      GetClock -> []
      WriteOutput stream bytes -> ["stream" .= streamName stream, "data" .= bytesValue bytes]
      ReadInput limit -> ["max" .= limit]
      QueryTerminal stream -> ["stream" .= standardStreamName stream]
      Serve port -> ["port" .= port]
      Accept (Listener listener) timeout -> ["listener" .= listener, "timeoutMs" .= timeout]
      Respond (RequestId request) response ->
        [ "request" .= request,
          "status" .= responseStatus response,
          "headers" .= headersValue (responseHeaders response),
          "body" .= bytesValue (responseBody response)
        ]

-- | @{"read":[...],"write":[...],"programs":[...],"network":b,"listen":b,
-- "protected":[...],"cwd":path|null,"projects":[...]}@. The last three are
-- the guard's anchors; each only adds refusals, so a request without them
-- decodes with none.
encodePolicy :: Policy -> Value
encodePolicy policy =
  object
    [ "read" .= readRoots policy,
      "write" .= writeRoots policy,
      "programs" .= programs policy,
      "network" .= network policy,
      "listen" .= listening policy,
      "protected" .= protectedPaths policy,
      "cwd" .= workingDirectory policy,
      "projects" .= projectRoots policy
    ]

decodePolicy :: Value -> Either String Policy
decodePolicy value = do
  fields <- asObject "policy" value
  let strings name = field fields name >>= asList name (asString name)
      optionalStrings name = maybe (Right []) (asList name (asString name)) (KM.lookup (K.fromString name) fields)
      bool name = field fields name >>= asBool name
      directory = case KM.lookup "cwd" fields of
        Nothing -> Right Nothing
        Just Null -> Right Nothing
        Just path -> Just <$> asString "cwd" path
  Policy
    <$> strings "read"
    <*> strings "write"
    <*> strings "programs"
    <*> bool "network"
    <*> bool "listen"
    <*> optionalStrings "protected"
    <*> directory
    <*> optionalStrings "projects"

decodeEffect :: Value -> Either String (Policy, SomeEffect)
decodeEffect value = do
  fields <- asObject "request" value
  version <- field fields "abi" >>= asInt "abi"
  if version /= abiVersion
    then Left ("unsupported ABI version " ++ show version)
    else pure ()
  policy <- field fields "policy" >>= decodePolicy
  (,) policy <$> decodeOperation fields

decodeOperation :: KM.KeyMap Value -> Either String SomeEffect
decodeOperation fields = do
  op <- field fields "op" >>= asString "op"
  let path = field fields "path" >>= asString "path"
      bytes name = field fields name >>= asBytes name
      int name = field fields name >>= asInt name
      bool name = field fields name >>= asBool name
      permissions = optionalPermissions fields
  case op of
    "read" -> SomeEffect . ReadFile <$> path
    "write" -> do
      mode <- field fields "mode" >>= asString "mode" >>= writeModeFromName
      bits <- permissions
      SomeEffect <$> (WriteFile mode bits <$> path <*> bytes "data")
    "list" -> SomeEffect . ListDirectory <$> path
    "stat" -> do
      follow <- bool "follow"
      SomeEffect . Stat (if follow then Follow else NoFollow) <$> path
    "realpath" -> SomeEffect . RealPath <$> path
    "remove" -> do
      recursive <- bool "recursive"
      SomeEffect . Remove (if recursive then Recursive else NotRecursive) <$> path
    "rename" -> do
      from <- field fields "from" >>= asString "from"
      SomeEffect . Rename from <$> (field fields "to" >>= asString "to")
    "mkdirs" -> do
      bits <- permissions
      SomeEffect . MakeDirectories bits <$> path
    "spawn" -> do
      arguments <- field fields "argv" >>= asList "argv" (asString "argv")
      directory <- field fields "cwd" >>= asString "cwd"
      environment <- nullable (field fields "env") (asPairsObject "env")
      input <- nullable (field fields "stdin") (asBytes "stdin")
      pure (SomeEffect (Spawn (SpawnRequest arguments directory environment input)))
    "poll" -> do
      handles <- field fields "handles" >>= asList "handles" (asInt "handles")
      SomeEffect . Poll (map ProcessHandle handles) <$> int "timeoutMs"
    "kill" -> SomeEffect . Kill . ProcessHandle <$> int "handle"
    "fetch" -> do
      url <- field fields "url" >>= asString "url"
      method <- field fields "method" >>= asString "method"
      headers <- field fields "headers" >>= asHeaders "headers"
      body <- nullable (field fields "body") (asBytes "body")
      pure (SomeEffect (Fetch (FetchRequest url method headers body)))
    "env" -> SomeEffect . GetEnvironment <$> (field fields "name" >>= asString "name")
    "clock" -> pure (SomeEffect GetClock)
    "output" -> do
      stream <- field fields "stream" >>= asString "stream" >>= streamFromName
      SomeEffect . WriteOutput stream <$> bytes "data"
    "input" -> SomeEffect . ReadInput <$> int "max"
    "terminal" -> SomeEffect . QueryTerminal <$> (field fields "stream" >>= asString "stream" >>= standardStreamFromName)
    "serve" -> SomeEffect . Serve <$> int "port"
    "accept" -> do
      listener <- int "listener"
      SomeEffect . Accept (Listener listener) <$> int "timeoutMs"
    "respond" -> do
      request <- int "request"
      status <- int "status"
      headers <- field fields "headers" >>= asHeaders "headers"
      body <- bytes "body"
      pure (SomeEffect (Respond (RequestId request) (Response status headers body)))
    _ -> Left ("unknown operation " ++ show op)

-- | A host's answer: @{"abi":1,"ok":...}@ or @{"abi":1,"error":{...}}@.
encodeResult :: Effect a -> Either HostError a -> Value
encodeResult effect result =
  object
    ( "abi" .= abiVersion : case result of
        Left (HostError kind message) ->
          ["error" .= object ["kind" .= errorKindName kind, "message" .= message]]
        Right value -> ["ok" .= encodeValue effect value]
    )

encodeValue :: Effect a -> a -> Value
encodeValue effect value = case effect of
  ReadFile {} -> object ["data" .= bytesValue value]
  WriteFile {} -> unit
  ListDirectory {} ->
    object ["entries" .= [object ["name" .= name, "kind" .= entryKindName kind] | Entry name kind <- value]]
  Stat {} ->
    object
      ( [ "kind" .= entryKindName (statusKind value),
          "size" .= statusSize value,
          "modifiedMs" .= statusModified value
        ]
          ++ permissionsField (statusPermissions value)
      )
  RealPath {} -> object ["path" .= value]
  Remove {} -> unit
  Rename {} -> unit
  MakeDirectories {} -> unit
  Spawn {} -> let ProcessHandle handle = value in object ["handle" .= handle]
  Poll {} -> object ["events" .= map eventValue value]
  Kill {} -> unit
  Fetch {} ->
    object
      [ "status" .= fetchStatus value,
        "headers" .= headersValue (fetchResponseHeaders value),
        "body" .= bytesValue (fetchResponseBody value)
      ]
  GetEnvironment {} -> object ["value" .= value]
  GetClock -> object ["wallMs" .= wallMilliseconds value, "monotonicUs" .= monotonicMicroseconds value]
  WriteOutput {} -> unit
  ReadInput {} -> object ["data" .= bytesValue (inputBytes value), "eof" .= inputEnded value]
  QueryTerminal {} -> object ["terminal" .= isTerminal value, "columns" .= terminalColumns value]
  Serve {} ->
    let Listener listener = listeningOn value
     in object ["listener" .= listener, "port" .= listeningPort value]
  Accept {} -> object ["request" .= fmap requestValue value]
  Respond {} -> unit
  where
    unit = object []
    eventValue (Chunk (ProcessHandle handle) stream bytes) =
      object ["handle" .= handle, "stream" .= streamName stream, "data" .= bytesValue bytes]
    eventValue (Exited (ProcessHandle handle) (ExitCode code)) = object ["handle" .= handle, "exit" .= code]
    eventValue (Exited (ProcessHandle handle) (Signalled signal)) = object ["handle" .= handle, "signal" .= signal]
    requestValue (IncomingRequest (RequestId request) method path headers body) =
      object
        [ "id" .= request,
          "method" .= method,
          "path" .= path,
          "headers" .= headersValue headers,
          "body" .= bytesValue body
        ]

decodeResult :: Effect a -> Value -> Either String (Either HostError a)
decodeResult effect value = do
  fields <- asObject "response" value
  version <- field fields "abi" >>= asInt "abi"
  if version /= abiVersion
    then Left ("unsupported ABI version " ++ show version)
    else pure ()
  case (KM.lookup "ok" fields, KM.lookup "error" fields) of
    (Just ok, Nothing) -> Right <$> decodeValue effect ok
    (Nothing, Just failure) -> do
      details <- asObject "error" failure
      kindName <- field details "kind" >>= asString "kind"
      kind <- maybe (Left ("unknown error kind " ++ show kindName)) Right (errorKindFromName kindName)
      message <- field details "message" >>= asString "message"
      pure (Left (HostError kind message))
    _ -> Left "response needs exactly one of ok and error"

decodeValue :: Effect a -> Value -> Either String a
decodeValue effect value = do
  fields <- asObject "ok" value
  let bytes name = field fields name >>= asBytes name
      int name = field fields name >>= asInt name
      integer name = field fields name >>= asInteger name
      string name = field fields name >>= asString name
  case effect of
    ReadFile {} -> bytes "data"
    WriteFile {} -> pure ()
    ListDirectory {} ->
      field fields "entries"
        >>= asList
          "entries"
          ( \entry -> do
              entryFields <- asObject "entry" entry
              name <- field entryFields "name" >>= asString "name"
              kind <- field entryFields "kind" >>= asString "kind" >>= entryKind
              pure (Entry name kind)
          )
    Stat {} -> do
      kind <- string "kind" >>= entryKind
      Status kind <$> integer "size" <*> integer "modifiedMs" <*> optionalPermissions fields
    RealPath {} -> string "path"
    Remove {} -> pure ()
    Rename {} -> pure ()
    MakeDirectories {} -> pure ()
    Spawn {} -> ProcessHandle <$> int "handle"
    Poll {} -> field fields "events" >>= asList "events" event
    Kill {} -> pure ()
    Fetch {} ->
      FetchResponse
        <$> int "status"
        <*> (field fields "headers" >>= asHeaders "headers")
        <*> bytes "body"
    GetEnvironment {} -> nullable (field fields "value") (asString "value")
    GetClock -> Clock <$> integer "wallMs" <*> integer "monotonicUs"
    WriteOutput {} -> pure ()
    ReadInput {} -> Input <$> bytes "data" <*> (field fields "eof" >>= asBool "eof")
    QueryTerminal {} -> Terminal <$> (field fields "terminal" >>= asBool "terminal") <*> nullable (field fields "columns") (asInt "columns")
    Serve {} -> Listening <$> (Listener <$> int "listener") <*> int "port"
    Accept {} -> nullable (field fields "request") request
    Respond {} -> pure ()
  where
    entryKind name = maybe (Left ("unknown entry kind " ++ show name)) Right (entryKindFromName name)
    event item = do
      fields <- asObject "event" item
      handle <- ProcessHandle <$> (field fields "handle" >>= asInt "handle")
      case (KM.lookup "stream" fields, KM.lookup "exit" fields, KM.lookup "signal" fields) of
        (Just stream, Nothing, Nothing) -> do
          name <- asString "stream" stream >>= streamFromName
          Chunk handle name <$> (field fields "data" >>= asBytes "data")
        (Nothing, Just code, Nothing) -> Exited handle . ExitCode <$> asInt "exit" code
        (Nothing, Nothing, Just signal) -> Exited handle . Signalled <$> asString "signal" signal
        _ -> Left "an event has exactly one of stream, exit and signal"
    request item = do
      fields <- asObject "request" item
      IncomingRequest
        <$> (RequestId <$> (field fields "id" >>= asInt "id"))
        <*> (field fields "method" >>= asString "method")
        <*> (field fields "path" >>= asString "path")
        <*> (field fields "headers" >>= asHeaders "headers")
        <*> (field fields "body" >>= asBytes "body")

-- | @"permissions"@, present only when there are permission bits, so a
-- request without them is the request an older host decodes.
permissionsField :: Maybe Permissions -> [(K.Key, Value)]
permissionsField = maybe [] (\bits -> ["permissions" .= bits])

-- | The optional @"permissions"@ field: absent or null is none; otherwise an
-- integer within 'permissionMask'.
optionalPermissions :: KM.KeyMap Value -> Either String (Maybe Permissions)
optionalPermissions fields = case KM.lookup "permissions" fields of
  Nothing -> Right Nothing
  Just Null -> Right Nothing
  Just value -> do
    bits <- asInt "permissions" value
    if bits < 0 || bits > permissionMask
      then Left "permissions must be an integer from 0 to 0o7777"
      else Right (Just bits)

writeModeName :: WriteMode -> String
writeModeName Replace = "replace"
writeModeName Create = "create"

writeModeFromName :: String -> Either String WriteMode
writeModeFromName "replace" = Right Replace
writeModeFromName "create" = Right Create
writeModeFromName other = Left ("unknown write mode " ++ show other)

streamName :: Stream -> String
streamName Stdout = "stdout"
streamName Stderr = "stderr"

streamFromName :: String -> Either String Stream
streamFromName "stdout" = Right Stdout
streamFromName "stderr" = Right Stderr
streamFromName other = Left ("unknown stream " ++ show other)

standardStreamName :: StandardStream -> String
standardStreamName StandardInput = "stdin"
standardStreamName StandardOutput = "stdout"
standardStreamName StandardError = "stderr"

standardStreamFromName :: String -> Either String StandardStream
standardStreamFromName name =
  maybe (Left ("unknown stream " ++ show name)) Right (lookup name [(standardStreamName stream, stream) | stream <- [minBound .. maxBound]])

bytesValue :: B.ByteString -> Value
bytesValue = String . TE.decodeLatin1 . encodeBase64

-- | Environment variables are an object: names are unique.
pairsObject :: [(String, String)] -> Value
pairsObject pairs = object [K.fromString name .= value | (name, value) <- pairs]

-- | Header lists keep order and repeated names.
headersValue :: [(String, String)] -> Value
headersValue headers = toJSONList [[name, value] | (name, value) <- headers]
  where
    toJSONList = JSON.toJSON

field :: KM.KeyMap Value -> String -> Either String Value
field fields name = maybe (Left ("missing field " ++ name)) Right (KM.lookup (K.fromString name) fields)

nullable :: Either String Value -> (Value -> Either String a) -> Either String (Maybe a)
nullable (Left problem) _ = Left problem
nullable (Right Null) _ = Right Nothing
nullable (Right value) decode = Just <$> decode value

asObject :: String -> Value -> Either String (KM.KeyMap Value)
asObject _ (Object fields) = Right fields
asObject name _ = Left (name ++ " must be an object")

asString :: String -> Value -> Either String String
asString _ (String text) = Right (T.unpack text)
asString name _ = Left (name ++ " must be a string")

asBool :: String -> Value -> Either String Bool
asBool _ (Bool flag) = Right flag
asBool name _ = Left (name ++ " must be a boolean")

asInteger :: String -> Value -> Either String Integer
asInteger name value@(Number _) = case JSON.fromJSON value of
  JSON.Success whole -> Right whole
  JSON.Error _ -> Left (name ++ " must be an integer")
asInteger name _ = Left (name ++ " must be an integer")

asInt :: String -> Value -> Either String Int
asInt name value = do
  whole <- asInteger name value
  if whole < fromIntegral (minBound :: Int) || whole > fromIntegral (maxBound :: Int)
    then Left (name ++ " is out of range")
    else Right (fromIntegral whole)

asList :: String -> (Value -> Either String a) -> Value -> Either String [a]
asList _ decode (Array items) = mapM decode (toList items)
asList name _ _ = Left (name ++ " must be an array")

asBytes :: String -> Value -> Either String B.ByteString
asBytes name (String text) = either (\problem -> Left (name ++ ": " ++ problem)) Right (decodeBase64 (TE.encodeUtf8 text))
asBytes name _ = Left (name ++ " must be a base64 string")

asPairsObject :: String -> Value -> Either String [(String, String)]
asPairsObject name value = do
  fields <- asObject name value
  mapM (\(key, item) -> (,) (K.toString key) <$> asString name item) (KM.toList fields)

asHeaders :: String -> Value -> Either String [(String, String)]
asHeaders name = asList name pair
  where
    pair (Array items) | [String key, String value] <- toList items = Right (T.unpack key, T.unpack value)
    pair _ = Left (name ++ " entries must be [name, value] string pairs")
