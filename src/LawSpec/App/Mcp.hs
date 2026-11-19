-- | lawspec mcp, ported from mcp.mjs and the part of the Model Context
-- Protocol SDK (@modelcontextprotocol/server 2.4.0) it used: a stdio server
-- of newline-delimited JSON-RPC on the 2025 protocol, with the six
-- read-only tools. Each tool calls the compiler in-process. The server reads
-- one line, answers it and only then reads the next, until standard input
-- ends. The replies, their member orders and the validation messages are
-- the SDK's and zod's, for the requests a client sends.
-- ref:DEC-haskell-application-port ref:DEC-host-effect-abi
module LawSpec.App.Mcp
  ( mcpCommand,
    toolList,
  )
where

import Control.Monad.Trans.Except (catchE)
import Data.List (find, intercalate)
import Data.Maybe (fromMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Version (showVersion)
import LawSpec.App.Advice (collectNativeSources)
import LawSpec.App.Command
import LawSpec.App.Compiler (callOrdered, diagnosticText)
import LawSpec.App.Files (collectSources)
import LawSpec.App.Json
import LawSpec.App.Packages (ResolveOptions (..), Resolved (..), resolveDependencies, resolveOptions)
import LawSpec.App.Project (dependencyRanges, findManifest, isoTime, readManifest)
import LawSpec.App.Rpc
import LawSpec.Authoring.Syntax (Source (..))
import LawSpec.Host.Effect
import LawSpec.Host.Path (resolve, takeDirectory)
import qualified Data.Text as T
import Paths_lawspec (version)

-- | The manifest the tools read: given with --config, or found from the
-- working directory by the first tool that needs it and kept.
data Server = Server
  { serverDirectory :: FilePath,
    serverConfig :: Maybe FilePath
  }

mcpCommand :: (Monad m) => FilePath -> Maybe FilePath -> Command m Int
mcpCommand cwd config = loop (Server cwd config) newReader
  where
    loop server reader =
      readLine reader >>= \case
        Nothing -> pure 0
        Just (line, reader') -> case parseJson line of
          Right message
            | Just (identifier, method, params) <- request message -> do
                server' <- answer server identifier method params
                loop server' reader'
          -- Notifications, responses, and lines that are not JSON-RPC 2.0
          -- messages produce nothing.
          _ -> loop server reader'

-- | A JSON-RPC 2.0 request as the SDK's message schema admits it: an id that
-- is a string or a safe integer, a method, and params that are an object
-- when present.
request :: Json -> Maybe (Json, String, Maybe Json)
request message = do
  JString "2.0" <- member "jsonrpc" message
  identifier <- member "id" message
  validId identifier
  JString method <- member "method" message
  let params = member "params" message
  case params of
    Nothing -> pure ()
    Just (JObject _) -> pure ()
    _ -> Nothing
  pure (identifier, method, params)
  where
    validId = \case
      JString _ -> Just ()
      JNumber n | Right whole <- floatingOrInteger n :: Either Double Integer, abs whole <= 9007199254740991 -> Just ()
      _ -> Nothing

answer :: (Monad m) => Server -> Json -> String -> Maybe Json -> Command m Server
answer server identifier method params = case method of
  "initialize" -> case issues ["params"] params initializeShape of
    [] -> do
      let requested = propertyOf "protocolVersion" params
          negotiated = case requested of
            Just (JString wanted) | wanted `elem` protocolVersions -> wanted
            _ -> latestProtocolVersion
      server
        <$ result
          ( JObject
              [ ("protocolVersion", JString negotiated),
                ("capabilities", JObject [("tools", JObject [("listChanged", JBool True)])]),
                ("serverInfo", JObject [("name", JString "lawspec"), ("version", JString (showVersion version))])
              ]
          )
    found -> server <$ failure (-32603) (stringify (JArray found))
  "ping" -> server <$ result (JObject [])
  "tools/list" -> case issues ["params"] (Just (fromMaybe (JObject []) params)) (Shape [("cursor", Optional Text)]) of
    [] -> server <$ result toolList
    found -> server <$ failure (-32603) (stringify (JArray found))
  "tools/call" -> case issues ["params"] params (Shape [("name", Required Text), ("arguments", Optional Record)]) of
    [] -> do
      let name = maybe "" jsString (propertyOf "name" params)
          arguments = fromMaybe (JObject []) (propertyOf "arguments" params)
      case lookup name tools of
        Nothing -> server <$ failure (-32602) ("Tool " ++ name ++ " not found")
        Just (shape, run) -> case issues [] (Just arguments) shape of
          [] -> do
            (server', text) <- run server arguments
            server' <$ result (either toolError (\t -> JObject [("content", JArray [textContent t])]) text)
          found ->
            server
              <$ result
                ( toolError
                    ( "Input validation error: Invalid arguments for tool "
                        ++ name
                        ++ ": "
                        ++ intercalate ", " [intercalate "." (pathOf issue) ++ ": " ++ maybe "" jsString (member "message" issue) | issue <- found]
                    )
                )
    found -> server <$ failure (-32602) ("Invalid tools/call request: " ++ stringify (JArray found))
  _ -> server <$ failure (-32601) "Method not found"
  where
    result value = send (JObject [("result", value), ("jsonrpc", JString "2.0"), ("id", identifier)])
    failure code message = send (JObject [("jsonrpc", JString "2.0"), ("id", identifier), ("error", JObject [("code", integer code), ("message", JString message)])])
    pathOf issue = [maybe "" jsString (Just part) | Just parts <- [member "path" issue >>= arrayOf], part <- parts]
    textContent text = JObject [("type", JString "text"), ("text", JString text)]
    toolError message = JObject [("content", JArray [textContent message]), ("isError", JBool True)]

latestProtocolVersion :: String
latestProtocolVersion = "2025-11-25"

-- | The 2025 protocol versions the SDK negotiates, newest first.
protocolVersions :: [String]
protocolVersions = [latestProtocolVersion, "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"]

-- | The part of a zod object schema that the servers' requests and tools
-- use: members of a type, required or optional, or an enumeration.
data Kind = Text | Object Shape | Record | Enumeration [String]

newtype Shape = Shape [(String, Member)]

data Member = Required Kind | Optional Kind

initializeShape :: Shape
initializeShape =
  Shape
    [ ("protocolVersion", Required Text),
      ("capabilities", Required (Object (Shape []))),
      ("clientInfo", Required (Object (Shape [("name", Required Text), ("version", Required Text)])))
    ]

-- | zod's issues for a value that must be an object of the shape, as JSON
-- in zod's member order.
issues :: [String] -> Maybe Json -> Shape -> [Json]
issues path value shape = check path value (Required (Object shape))
  where
    check at found = \case
      Optional kind -> maybe [] (const (check at found (Required kind))) found
      Required kind -> case (kind, found) of
        (Text, Just (JString _)) -> []
        (Text, _) -> [invalidType at "string" found]
        (Record, Just (JObject _)) -> []
        (Record, _) -> [invalidType at "record" found]
        (Object (Shape expectedMembers), Just (JObject fields)) -> concat [check (at ++ [name]) (lookup name fields) expected | (name, expected) <- expectedMembers]
        (Object _, _) -> [invalidType at "object" found]
        (Enumeration options, Just (JString option)) | option `elem` options -> []
        (Enumeration options, _) ->
          [ JObject
              [ ("code", JString "invalid_value"),
                ("values", JArray (map JString options)),
                ("path", JArray (map JString at)),
                ("message", JString ("Invalid option: expected one of " ++ intercalate "|" (map show options)))
              ]
          ]
    invalidType at expected found =
      JObject
        [ ("expected", JString expected),
          ("code", JString "invalid_type"),
          ("path", JArray (map JString at)),
          ("message", JString ("Invalid input: expected " ++ expected ++ ", received " ++ typeName found))
        ]

-- | tools/list's result: mcp.mjs's registrations as the SDK lists them,
-- their zod input schemas as JSON Schema.
toolList :: Json
toolList =
  JObject
    [ ( "tools",
        JArray
          [ tool "lawspec_prelude" "Read the installed compiler prelude inventory without a project." [("query", JObject [("type", JString "string")])] [],
            tool "lawspec_inspect" "Read actual generated or bound interfaces without writing files." [target] ["target"],
            tool "lawspec_advise" "Read authoring review candidates and explicit analysis limits. No application files are changed." [target] ["target"],
            tool "lawspec_check" "Validate the current LawSpec project and run only the law checks selected by lawspec.edn. Returns compiler diagnostics, verification selection, and explicit evidence statuses." [] [],
            tool "lawspec_list_laws" "List the laws declared in the current LawSpec project after validating its definitions. This does not imply that laws have been proved or tested." [] [],
            tool
              "lawspec_explain"
              "Explain one LawSpec law in readable, mathematical, or developer form. Reads and validates the current project before explaining it."
              [ ("law", JObject [("type", JString "string"), ("description", JString "Law identity, such as example.codec::round trip")]),
                ( "view",
                  JObject
                    [ ("default", JString "eng"),
                      ("description", JString "Explanation style"),
                      ("type", JString "string"),
                      ("enum", JArray (map JString views))
                    ]
                )
              ]
              ["law"]
          ]
      )
    ]
  where
    target = ("target", JObject [("type", JString "string")])
    tool name description properties required =
      JObject
        [ ("name", JString name),
          ("description", JString description),
          ( "inputSchema",
            JObject
              ( [ ("type", JString "object"),
                  ("$schema", JString "https://json-schema.org/draft/2020-12/schema"),
                  ("properties", JObject properties)
                ]
                  ++ [("required", JArray (map JString required)) | not (null required)]
              )
          ),
          ("annotations", JObject [("readOnlyHint", JBool True)])
        ]

views :: [String]
views = ["eng", "math", "dev"]

-- | Each tool's argument shape and handler. A handler's failure is the
-- tool's error result, with the failure's message.
tools :: (Monad m) => [(String, (Shape, Server -> Json -> Command m (Server, Either String String)))]
tools =
  [ ( "lawspec_prelude",
      ( Shape [("query", Optional Text)],
        \server arguments -> (,) server <$> attemptText (prelude arguments)
      )
    ),
    ("lawspec_inspect", (Shape [("target", Required Text)], \server arguments -> project server (targeted "inspect" arguments server))),
    ("lawspec_advise", (Shape [("target", Required Text)], \server arguments -> project server (targeted "advise" arguments server))),
    ( "lawspec_check",
      ( Shape [],
        \server _ -> project server $ \file -> do
          input <- projectInput server file
          stringify <$> (callOrdered "check" input >>= checked)
      )
    ),
    ( "lawspec_list_laws",
      ( Shape [],
        \server _ -> project server $ \file -> do
          input <- projectInput server file
          checkedResult <- callOrdered "check" (setMember "verification" (JObject [("layers", JArray [])]) input) >>= checked
          let laws =
                [ jsObject
                    ( [("id", JString (shown (member "owner" law) ++ "::" ++ shown (member "name" law)))]
                        ++ present "owner" law
                        ++ present "name" law
                        ++ present "description" law
                        ++ present "location" law
                        ++ [("kind", maybe (JString "property") id (nonNullish (member "kind" law)))]
                        ++ [("declaration", value) | Just value <- [member "id" law]]
                        ++ [("scope", value) | Just value <- [member "scope" law], isTruthy value]
                    )
                | law <- items "laws" checkedResult ++ items "temporalLaws" checkedResult
                ]
          pure (stringify (JObject [("laws", JArray laws)]))
      )
    ),
    ( "lawspec_explain",
      ( Shape [("law", Required Text), ("view", Optional (Enumeration views))],
        \server arguments -> project server $ \file -> do
          input <- projectInput server file
          explained <-
            callOrdered
              "explain"
              ( jsObject
                  ( members input
                      ++ [ ("law", fromMaybe JNull (member "law" arguments)),
                           ("view", fromMaybe (JString "eng") (member "view" arguments))
                         ]
                  )
              )
              >>= checked
          pure (maybe "" jsString (member "text" explained))
      )
    )
  ]
  where
    shown = maybe "undefined" jsString
    present key value = [(key, found) | Just found <- [member key value]]
    nonNullish = \case
      Just JNull -> Nothing
      other -> other

-- | The prelude tool: the compiler's inventory, as compact JSON.
prelude :: (Monad m) => Json -> Command m String
prelude arguments = compact <$> (callOrdered "prelude" (JObject [(key, value) | (key, value) <- members arguments, key == "query"]) >>= checked)

-- | inspect and advise for one configured target.
targeted :: (Monad m) => String -> Json -> Server -> FilePath -> Command m String
targeted method arguments server file = do
  input <- projectInput server file
  config <- readManifest file
  let wanted = member "target" arguments
  selected <- case find (\item -> member "language" item == wanted) (items "targets" config) of
    Just item -> pure item
    Nothing -> failWith "No matching configured target"
  extra <-
    if method /= "advise"
      then pure []
      else do
        root <- case member "root" selected of
          Just (JString path) -> pure path
          other -> failWith ("The \"paths[1]\" argument must be of type string. Received " ++ received other)
        sources <- collectNativeSources (resolve (takeDirectory file) root)
        pure
          [ ("nativeSources", JArray [JObject [("path", JString (sourcePath s)), ("content", JString (T.unpack (sourceContent s)))] | s <- sources]),
            ("exceptions", fromMaybe (JArray []) (nonNullish (member "authoringExceptions" config)))
          ]
  result <-
    callOrdered
      method
      ( jsObject
          ( members input
              ++ [("target", fromMaybe JNull wanted)]
              ++ [(key, value) | key <- ["sourceDir", "testDir", "generatedSourceDir", "generatedTestDir", "release", "nativeBindings", "actors"], Just value <- [member key selected]]
              ++ extra
          )
      )
      >>= checked
  pure (maybe "undefined" compact (member (if method == "advise" then "advice" else "interface") result))
  where
    received = \case
      Nothing -> "undefined"
      Just JNull -> "null"
      Just other -> "type " ++ typeName (Just other)
    nonNullish = \case
      Just JNull -> Nothing
      other -> other

-- | A tool that reads the project: the manifest is found first (and kept,
-- even when the tool then fails), then the tool runs.
project :: (Monad m) => Server -> (FilePath -> Command m String) -> Command m (Server, Either String String)
project server run = do
  located <- attemptText (maybe (findManifest (serverDirectory server)) pure (serverConfig server))
  case located of
    Left message -> pure (server, Left message)
    Right file -> do
      grantRead [takeDirectory file]
      (,) server {serverConfig = Just file} <$> attemptText (run file)

-- | mcp.mjs request(): the compiler input for the project, its packages
-- resolved offline and read-only.
projectInput :: (Monad m) => Server -> FilePath -> Command m Json
projectInput server file = do
  let root = takeDirectory file
  config <- readManifest file
  resolved <-
    resolveDependencies
      file
      config
      (resolveOptions (serverDirectory server)) {resolveReadOnly = True, resolveWriteLock = False, resolveOffline = True}
  sources <- collectSources root [entry | Just entries <- [member "sources" config >>= arrayOf], JString entry <- entries] root
  clock <- effect (\problem -> Failure (errorMessage problem) Nothing) GetClock
  let projectVersion = case nonNullish (member "component" config >>= member "version") of
        Just value -> Just value
        Nothing -> member "package" config >>= member "version"
  pure . jsObject $
    [("sources", JArray [JObject [("path", JString path), ("content", JString content)] | (path, content) <- sources])]
      ++ [("languageProfile", value) | Just value <- [member "languageProfile" config]]
      ++ [("verification", fromMaybe (JObject [("layers", JArray [])]) (nonNullish (member "verification" config)))]
      ++ [("package", value) | Just value <- [member "package" config], isTruthy value]
      ++ [ ("dependencies", dependencyRanges config),
           ("packages", JArray (resolvedPackages resolved))
         ]
      ++ [("generation", value) | Just value <- [member "generation" config], isTruthy value]
      ++ [("machineBits", fromMaybe (integer 64) (nonNullish (member "machineBits" config)))]
      ++ [("projectVersion", value) | Just value <- [projectVersion], isTruthy value]
      ++ [("now", JString (isoTime (wallMilliseconds clock)))]
  where
    nonNullish = \case
      Just JNull -> Nothing
      other -> other

-- | mcp.mjs diagnostics(result): fail with every diagnostic, one per line.
checked :: (Monad m) => Json -> Command m Json
checked result = case member "diagnostics" result of
  Just (JArray found@(_ : _)) -> failWithDiagnostics (intercalate "\n" (map diagnosticText found)) (JArray found)
  _ -> pure result

-- | A step's result, or its failure's message. Behaviour that is not ported
-- cannot fall back to the legacy CLI once the server has answered, so it is
-- the tool's error too.
attemptText :: (Monad m) => Command m String -> Command m (Either String String)
attemptText command =
  (Right <$> command) `catchE` \case
    Aborted problem -> pure (Left (failureMessage problem))
    Unported reason -> pure (Left reason)

items :: String -> Json -> [Json]
items key value = fromMaybe [] (member key value >>= arrayOf)

-- | One line of JSON on standard output.
send :: (Monad m) => Json -> Command m ()
send value = sendBytes (utf8 (compact value ++ "\n"))
