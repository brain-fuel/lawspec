-- | lawspec lsp --stdio, ported from lsp.mjs: a Language Server Protocol
-- server over the host's standard streams, with the compiler in-process.
-- It reads one Content-Length-framed message, handles it and writes what
-- the legacy server wrote for it, then reads the next, until @exit@ or the
-- end of standard input. Diagnostics are published, for every open
-- document, after each check: on didOpen, didChange and a configuration
-- change, before the request's own reply, as lsp.mjs's queue sent them.
-- The texts and member orders are lsp.mjs's.
-- ref:DEC-haskell-application-port ref:DEC-host-effect-abi
module LawSpec.App.Lsp
  ( lspCommand,
    utf16Position,
    pathToFileUrl,
    fileUrlToPath,
  )
where

import Control.Monad (foldM, forM, forM_, when)
import qualified Data.ByteString as B
import Data.Char (chr, isHexDigit, ord, toLower)
import Data.List (find, isInfixOf, isPrefixOf, sortBy)
import Data.Maybe (fromMaybe)
import Data.Version (showVersion)
import LawSpec.App.Command
import LawSpec.App.Compiler (callOrdered)
import LawSpec.App.Files (compareUtf16)
import LawSpec.App.Json
import LawSpec.App.Project (findManifest, readManifest)
import LawSpec.App.Rpc
import LawSpec.Host.Effect
import LawSpec.Host.Path (join, resolve, takeDirectory)
import Numeric (readHex, showHex)
import Paths_lawspec (version)

-- | A line and a character (UTF-16 code units), from zero.
type Position = (Integer, Integer)

data Range = Range Position Position

-- | A declaration or a use, as lsp.mjs's declarations() and uses() list them.
data Symbol = Symbol
  { symbolId :: Maybe Json,
    symbolName :: Maybe Json,
    symbolKind :: Maybe Integer,
    symbolDetail :: Maybe Json,
    symbolUri :: String,
    symbolRange :: Range
  }

data Server = Server
  { -- | The working directory, or the client's root.
    serverWorkspace :: FilePath,
    -- | The open documents by URI, in the order a JavaScript Map keeps.
    serverDocuments :: [(String, Json)],
    -- | The sources and the result of the last check.
    serverSources :: [(FilePath, String)],
    serverResult :: Maybe Json,
    serverWarnMatches :: Bool,
    serverShuttingDown :: Bool
  }

-- | What a handled message leaves to send.
data Step
  = -- | The result, sent when the message has an id.
    Reply Json
  | -- | Nothing more: an error was sent, or the message needs no reply.
    Done
  | -- | Stop serving.
    Exit

lspCommand :: (Monad m) => FilePath -> Command m Int
lspCommand cwd = loop (Server cwd [] [] Nothing False False) newReader
  where
    loop server reader = do
      (framed, reader') <- readFramed reader
      case framed of
        EndOfInput -> pure 0
        BadLength -> 0 <$ send (JObject [("jsonrpc", JString "2.0"), ("id", JNull), ("error", rpcError (-32700) "Invalid Content-Length")])
        Framed body -> case parseJson (fromUtf8 body) of
          Left _ -> do
            send (JObject [("jsonrpc", JString "2.0"), ("id", JNull), ("error", rpcError (-32700) "Parse error")])
            loop server reader'
          Right message -> do
            (server', step) <- dispatch server message
            case step of
              Exit -> pure 0
              _ -> loop server' reader'

-- | One message: its handler, then its reply, or the failure as an error
-- reply (a request) or a logged message (a notification).
dispatch :: (Monad m) => Server -> Json -> Command m (Server, Step)
dispatch server message = do
  let method = propertyOf "method" (Just message)
      identifier = propertyOf "id" (Just message)
  (server', outcome) <-
    if serverShuttingDown server && method `notElem` map (Just . JString) ["exit", "shutdown"]
      then pure (server, Left (Failure "Server is shutting down" Nothing))
      else handle server message
  case outcome of
    Left failure -> do
      case identifier of
        Just value -> send (JObject [("jsonrpc", JString "2.0"), ("id", value), ("error", rpcError (-32603) (failureMessage failure))])
        Nothing -> send (JObject [("jsonrpc", JString "2.0"), ("method", JString "window/logMessage"), ("params", JObject [("type", integer 1), ("message", JString (failureMessage failure))])])
      pure (server', Done)
    Right (Reply result) -> do
      forM_ identifier $ \value -> send (JObject [("jsonrpc", JString "2.0"), ("id", value), ("result", result)])
      pure (server', Done)
    Right step -> pure (server', step)

handle :: (Monad m) => Server -> Json -> Command m (Server, Either Failure Step)
handle server message = case propertyOf "method" (Just message) of
  Just (JString "initialize") -> do
    let warn = propertyOf "warnMatches" (propertyOf "initializationOptions" params)
    case warn of
      Just value | not (isBoolean value) -> pure (server, Left (Failure "warnMatches must be a Boolean" Nothing))
      _ -> do
        let server' = server {serverWarnMatches = warn == Just (JBool True)}
        workspace <- attempt $ case propertyOf "rootUri" params of
          Just root | isTruthy root -> fileUrlToPath root
          _ -> pure $ case propertyOf "rootPath" params of
            Just (JString path) -> resolve (serverWorkspace server) path
            _ -> serverWorkspace server
        pure $ case workspace of
          Left failure -> (server', Left failure)
          Right path -> (server' {serverWorkspace = path}, Right (Reply capabilities))
  Just (JString "initialized") -> pure (server, Right (Reply JNull))
  Just (JString "workspace/didChangeConfiguration") -> do
    let next = propertyOf "warnMatches" (propertyOf "lawspec" (propertyOf "settings" params))
    case next of
      Just value | not (isBoolean value) -> pure (server, Left (Failure "lawspec.warnMatches must be a Boolean" Nothing))
      _ -> checked server {serverWarnMatches = next == Just (JBool True)}
  Just (JString "shutdown") -> pure (server {serverShuttingDown = True}, Right (Reply JNull))
  Just (JString "exit") -> pure (server, Right Exit)
  Just (JString "textDocument/didOpen") -> do
    opened <- attempt $ do
      document <- property "textDocument" params
      uri <- property "uri" document >>= uriText
      pure (uri, fromMaybe JNull document)
    case opened of
      Left failure -> pure (server, Left failure)
      Right (uri, document) -> checked server {serverDocuments = insert uri document (serverDocuments server)}
  Just (JString "textDocument/didChange") -> do
    changed <- attempt $ do
      uri <- property "textDocument" params >>= property "uri"
      changes <-
        property "contentChanges" params >>= \case
          Just (JArray items) -> pure items
          Nothing -> failWith "Cannot read properties of undefined (reading 'some')"
          Just JNull -> failWith "Cannot read properties of null (reading 'some')"
          Just _ -> failWith "params.contentChanges.some is not a function"
      when (any (isTruthy' . propertyOf "range" . Just) changes) (failWith "LawSpec requires full-document synchronization")
      let document = case uri of
            Just (JString key) -> (,) key <$> lookup key (serverDocuments server)
            _ -> Nothing
      case document of
        Just (key, value) | not (null changes) -> do
          textVersion <- property "textDocument" params >>= property "version"
          let text = fromMaybe JNull (propertyOf "text" (Just (last changes)))
          pure (Just (key, setOrDrop "version" textVersion (setMember "text" text value)))
        _ -> pure Nothing
    case changed of
      Left failure -> pure (server, Left failure)
      Right Nothing -> checked server
      Right (Just (key, document)) -> checked server {serverDocuments = insert key document (serverDocuments server)}
  Just (JString "textDocument/didClose") -> do
    closed <- attempt (property "textDocument" params >>= property "uri")
    case closed of
      Left failure -> pure (server, Left failure)
      Right uri -> do
        let documents = case uri of
              Just (JString text) -> filter ((/= text) . fst) (serverDocuments server)
              _ -> serverDocuments server
        send (notification (JObject ([("uri", value) | Just value <- [uri]] ++ [("diagnostics", JArray [])])))
        pure (server {serverDocuments = documents}, Right (Reply JNull))
  Just (JString "textDocument/formatting") -> stay $ do
    uri <- property "textDocument" params >>= property "uri"
    case uri of
      Just (JString key) | Just document <- lookup key (serverDocuments server) -> do
        sourcePath <- fileUrlToPath (JString key)
        sources <- projectSources server
        response <- callOrdered "format" (JObject [("sources", sourcesJson sources), ("languageProfile", JString "1.0-rc.2"), ("verification", JObject [("layers", JArray [])])])
        if isTruthy' (propertyOf "length" (propertyOf "diagnostics" (Just response)))
          then pure (JArray [])
          else do
            let formatted = find ((== Just (JString sourcePath)) . member "path") (fromMaybe [] (member "formattedSources" response >>= arrayOf))
                text = textOf document
            pure $ case formatted >>= member "content" of
              Just content
                | content /= JString text ->
                    JArray [JObject [("range", rangeJson (Range (0, 0) (endPosition text))), ("newText", content)]]
              _ -> JArray []
      _ -> pure (JArray [])
  Just (JString "textDocument/documentSymbol") -> stay $ do
    uri <- property "textDocument" params >>= property "uri"
    pure . JArray $
      [ JObject
          ( [("name", value) | Just value <- [symbolName entry]]
              ++ [("detail", value) | Just value <- [symbolDetail entry]]
              ++ [("kind", integer kind) | Just kind <- [symbolKind entry]]
              ++ [("range", rangeJson (symbolRange entry)), ("selectionRange", rangeJson (symbolRange entry))]
          )
      | entry <- declarations server,
        Just (JString (symbolUri entry)) == uri
      ]
  Just (JString "textDocument/hover") -> stay $ do
    use <- selected server params
    pure $ case use >>= declarationOf server of
      Just (use', declaration) ->
        JObject
          [ ("contents", JObject [("kind", JString "plaintext"), ("value", JString (shown (symbolName declaration) ++ "\n" ++ shown (symbolDetail declaration)))]),
            ("range", rangeJson (symbolRange use'))
          ]
      Nothing -> JNull
  Just (JString "textDocument/definition") -> stay $ do
    use <- selected server params
    pure $ case use >>= declarationOf server of
      Just (_, declaration) -> locationJson declaration
      Nothing -> JNull
  Just (JString "textDocument/references") -> stay $ do
    use <- selected server params
    case use of
      Nothing -> pure (JArray [])
      Just use' -> do
        let declared = snd <$> declarationOf server use'
            included = isTruthy' (propertyOf "includeDeclaration" (propertyOf "context" params))
        pure . JArray $
          [ locationJson entry
          | entry <- uses server ++ [entry | included, Just entry <- [declared]],
            jsEquals (symbolId entry) (symbolId use')
          ]
  Just (JString "$/cancelRequest") -> pure (server, Right (Reply JNull))
  _ -> do
    forM_ (propertyOf "id" (Just message)) $ \value ->
      send (JObject [("jsonrpc", JString "2.0"), ("id", value), ("error", rpcError (-32601) "Method not found")])
    pure (server, Right Done)
  where
    -- message.params ?? {}
    params = case propertyOf "params" (Just message) of
      Nothing -> Just (JObject [])
      Just JNull -> Just (JObject [])
      value -> value
    stay command = do
      result <- attempt command
      pure (server, Reply <$> result)
    isBoolean = \case
      JBool _ -> True
      _ -> False
    shown = maybe "undefined" jsString
    uriText = \case
      Just (JString text) -> pure text
      other -> failWith ("The \"path\" argument must be of type string or an instance of URL. Received " ++ received other)
    received = \case
      Nothing -> "undefined"
      Just JNull -> "null"
      Just other -> "type " ++ typeName (Just other)

-- | The initialize result.
capabilities :: Json
capabilities =
  JObject
    [ ( "capabilities",
        JObject
          [ ("textDocumentSync", integer 1),
            ("positionEncoding", JString "utf-16"),
            ("documentFormattingProvider", JBool True),
            ("documentSymbolProvider", JBool True),
            ("hoverProvider", JBool True),
            ("definitionProvider", JBool True),
            ("referencesProvider", JBool True)
          ]
      ),
      ("serverInfo", JObject [("name", JString "LawSpec"), ("version", JString (showVersion version))])
    ]

-- | Run a check, then answer the message with null.
checked :: (Monad m) => Server -> Command m (Server, Either Failure Step)
checked server = do
  (server', failure) <- check server
  pure (server', maybe (Right (Reply JNull)) Left failure)

-- | check(): compile the project with the open documents, keep the result,
-- and publish each open document's diagnostics. The result is kept even
-- when publishing fails part of the way.
check :: (Monad m) => Server -> Command m (Server, Maybe Failure)
check server = do
  compiled <- attempt $ do
    sources <- projectSources server
    result <-
      callOrdered
        "check"
        ( JObject
            ( [ ("sources", sourcesJson sources),
                ("languageProfile", JString "1.0-rc.2"),
                ("verification", JObject [("layers", JArray [])])
              ]
                ++ [("warnMatches", JBool True) | serverWarnMatches server]
            )
        )
    pure (sources, result)
  case compiled of
    Left failure -> pure (server, Just failure)
    Right (sources, result) -> do
      let server' = server {serverSources = sources, serverResult = Just result}
      published <- attempt (forM_ (serverDocuments server') (publish server' result))
      pure (server', either Just (const Nothing) published)

publish :: (Monad m) => Server -> Json -> (String, Json) -> Command m ()
publish server result (uri, document) = do
  file <- fileUrlToPath (JString uri)
  let text = textOf document
      items = list "diagnostics" result ++ list "warnings" result
      relevant = [item | item <- items, let at = member "at" item, not (isTruthy' at) || (at >>= member "file") == Just (JString file)]
  send . notification . JObject $
    [("uri", JString uri)]
      ++ [("version", value) | Just value <- [member "version" document]]
      ++ [("diagnostics", JArray (map (diagnostic text) relevant))]
  where
    list key value = fromMaybe [] (member key value >>= arrayOf)
    diagnostic text item =
      let start@(line, character) = case member "at" item of
            Just at | isTruthy at -> utf16Position text at
            _ -> (0, 0)
          content = fromMaybe "" (lookupLine line (splitLines text))
          end = (line, min (fromIntegral (utf16Length content)) (character + firstLength (dropUnits character content)))
          range = case member "span" item of
            Just value | isTruthy value -> fromMaybe (Range start end) (snd <$> spanOf (serverSources server) value)
            _ -> Range start end
          related = fromMaybe [] (member "related" item >>= arrayOf)
       in JObject
            ( [ ("range", rangeJson range),
                ("severity", integer (if member "severity" item == Just (JString "warning") then 2 else 1))
              ]
                ++ [("code", value) | Just value <- [member "code" item]]
                ++ [("source", JString "LawSpec")]
                ++ [("message", value) | Just value <- [member "message" item]]
                ++ [ ( "relatedInformation",
                       JArray
                         [ JObject
                             ( [("location", JObject [("uri", JString origin), ("range", rangeJson originRange)])]
                                 ++ [("message", value) | Just value <- [member "message" entry]]
                             )
                         | entry <- related,
                           Just (origin, originRange) <- [member "span" entry >>= spanOf (serverSources server)]
                         ]
                     )
                   | not (null related)
                   ]
            )
    firstLength rest = case rest of
      c : _ -> if ord c >= 0x10000 then 2 else 1
      [] -> 0

-- | projectSources(): the sources lawspec.edn names in or above the
-- workspace, and the open documents in place of their files.
projectSources :: (Monad m) => Server -> Command m [(FilePath, String)]
projectSources server = do
  let workspace = serverWorkspace server
  found <-
    recover
      (Just <$> findManifest workspace)
      (\failure -> if "No lawspec.edn found" `isInfixOf` failureMessage failure then pure Nothing else abort failure)
  (entries, root) <- case found of
    Nothing -> pure ([], workspace)
    Just file -> do
      config <- readManifest file
      pure ([entry | Just items <- [member "sources" config >>= arrayOf], JString entry <- items], takeDirectory file)
  files <- foldM (\known entry -> let path = resolve root entry in grantRead [path] >> visit known path) [] entries
  documents <- forM (serverDocuments server) $ \(uri, document) -> do
    path <- fileUrlToPath (JString uri)
    pure (path, textOf document)
  pure (foldl (\known (path, content) -> insert path content known) files documents)
  where
    visit known file = do
      status <- effect (nodeFailure "stat" file) (Stat Follow file)
      case statusKind status of
        DirectoryKind -> do
          entries <- effect (nodeFailure "scandir" file) (ListDirectory file)
          foldM (\known' name -> visit known' (join file name)) known (sortBy compareUtf16 (map entryName entries))
        _
          | ".lawspec" `isSuffixOf'` file -> do
              bytes <- effect (nodeFailure "open" file) (ReadFile file)
              pure (insert file (fromUtf8 bytes) known)
          | otherwise -> pure known
    isSuffixOf' suffix text = reverse suffix `isPrefixOf` reverse text

-- | declarations(): the last result's source declarations, data types and
-- laws.
declarations :: Server -> [Symbol]
declarations server = case serverResult server of
  Nothing -> []
  Just result ->
    [ entry 12 declaration (Just (fromMaybe (JString "Type information unavailable") (nonNull (member "typeText" declaration)))) origin
    | unit <- listAt "units" result,
      declaration <- listAt "declarations" unit,
      Just origin <- [sourceOrigin declaration]
    ]
      ++ [entry 23 dataType (Just (JString "Type")) origin | dataType <- listAt "dataTypes" result, Just origin <- [sourceOrigin dataType]]
      ++ [ Symbol (member "id" law) (member "name" law) (Just 12) (Just detail) uri (Range position (line, character + 3))
         | law <- listAt "laws" result ++ listAt "temporalLaws" result,
           Just (uri, position@(line, character)) <- [member "location" law >>= location (serverSources server)],
           let detail = case member "description" law of
                 Just value | isTruthy value -> value
                 _ -> JString "Law"
         ]
  where
    entry kind value detail (uri, range) = Symbol (member "id" value) (member "name" value) (Just kind) detail uri range
    sourceOrigin value = case member "origin" value of
      Just origin | member "kind" origin == Just (JString "source") -> member "span" origin >>= spanOf (serverSources server)
      _ -> Nothing
    nonNull = \case
      Just JNull -> Nothing
      other -> other

-- | The laws' references to laws and functions (documentaryLinks()).
documentaryLinks :: Server -> [Json]
documentaryLinks server =
  [ reference
  | law <- maybe [] (listAt "laws") (serverResult server),
    reference <- listAt "references" law,
    member "kind" reference `elem` [Just (JString "law"), Just (JString "function")]
  ]

documentaryDeclaration :: Server -> Maybe Json -> Maybe Symbol
documentaryDeclaration server identifier = do
  reference <- find (\reference -> jsEquals (member "target" reference >>= member "id") identifier) (documentaryLinks server)
  target <- member "target" reference
  (uri, range) <- member "span" target >>= spanOf (serverSources server)
  pure (Symbol identifier (member "name" target) Nothing (Just (JString (if member "kind" reference == Just (JString "law") then "Law" else "Function"))) uri range)

-- | uses(): every call with a source origin in the laws and definitions, in
-- the order lsp.mjs's walk visits them, then the laws' references.
uses :: Server -> [Symbol]
uses server = case serverResult server of
  Nothing -> []
  Just result ->
    concatMap walk (maybe [] pure (member "laws" result) ++ maybe [] pure (member "definitions" result))
      ++ [ Symbol (member "target" reference >>= member "id") Nothing Nothing Nothing uri range
         | reference <- documentaryLinks server,
           Just (uri, range) <- [member "target" reference >>= member "referenceSpan" >>= spanOf (serverSources server)]
         ]
  where
    walk value = case value of
      JObject fields ->
        let here = case (member "node" value, member "origin" value) of
              (Just node, Just origin)
                | member "kind" node == Just (JString "call"),
                  member "kind" origin == Just (JString "source"),
                  Just (uri, range) <- member "span" origin >>= spanOf (serverSources server) ->
                    [Symbol (member "declaration" node) Nothing Nothing Nothing uri range]
              _ -> []
         in here ++ concatMap (walk . snd) fields
      JArray children -> concatMap walk children
      _ -> []

-- | selected(params): the narrowest use or declaration at the position.
selected :: (Monad m) => Server -> Maybe Json -> Command m (Maybe Symbol)
selected server params = do
  let candidates = uses server ++ declarations server
  if null candidates
    then pure Nothing
    else do
      uri <- property "textDocument" params >>= property "uri"
      position <- property "position" params
      line <- property "line" position
      character <- property "character" position
      let at = (numberOf line, numberOf character)
          matching = [entry | entry <- candidates, Just (JString (symbolUri entry)) == uri, within at (symbolRange entry)]
      pure . fmap fst . uncons' $ sortBy (\a b -> compare (size a) (size b)) matching
  where
    size entry = let Range (l1, c1) (l2, c2) = symbolRange entry in (l2 - l1, c2 - c1)
    uncons' = \case
      first : _ -> Just (first, ())
      [] -> Nothing
    numberOf = \case
      Just (JNumber n) -> Just (toRational n)
      _ -> Nothing
    within (Just line, Just character) (Range (l1, c1) (l2, c2)) =
      (line > toRational l1 || (line == toRational l1 && character >= toRational c1))
        && (line < toRational l2 || (line == toRational l2 && character < toRational c2))
    within _ _ = False

-- | The declaration a use names: a declaration with its id, or a law's
-- reference to it.
declarationOf :: Server -> Symbol -> Maybe (Symbol, Symbol)
declarationOf server use =
  (,) use <$> case find (jsEquals (symbolId use) . symbolId) (declarations server) of
    Just declaration -> Just declaration
    Nothing -> documentaryDeclaration server (symbolId use)

-- | span(span): a source span as a URI and a range, when its file is one of
-- the checked sources.
spanOf :: [(FilePath, String)] -> Json -> Maybe (String, Range)
spanOf sources value = do
  (uri, start) <- either' "start" "spanStart" >>= location sources
  (_, end) <- either' "end" "spanEnd" >>= location sources
  pure (uri, Range start end)
  where
    either' first second = case member first value of
      Just JNull -> member second value
      Nothing -> member second value
      found -> found

-- | location(location): a source location as a URI and a position.
location :: [(FilePath, String)] -> Json -> Maybe (String, Position)
location sources value = do
  JString file <- member "file" value
  content <- lookup file sources
  pure (pathToFileUrl file, utf16Position content value)

-- | utf16Position(text, location): a one-based line and column, columns
-- counting a tab to the next multiple of eight, as a zero-based line and a
-- UTF-16 offset.
utf16Position :: String -> Json -> Position
utf16Position text at = (line, go (1 :: Integer) 0 content)
  where
    line = max 0 (number "line" - 1)
    column = number "column"
    content = fromMaybe "" (lookupLine line (splitLines text))
    number key = case member key at of
      Just (JNumber n) -> floor n
      _ -> 0
    go current character = \case
      c : rest
        | current < column ->
            go (current + (if c == '\t' then 8 - ((current - 1) `mod` 8) else 1)) (character + (if ord c >= 0x10000 then 2 else 1)) rest
      _ -> character

endPosition :: String -> Position
endPosition text = let ls = splitLines text in (fromIntegral (length ls - 1), fromIntegral (utf16Length (last ls)))

-- | text.split('\n').
splitLines :: String -> [String]
splitLines text = case break (== '\n') text of
  (line, _ : rest) -> line : splitLines rest
  (line, []) -> [line]

lookupLine :: Integer -> [String] -> Maybe String
lookupLine index ls
  | index < 0 = Nothing
  | otherwise = case drop (fromIntegral index) ls of
      line : _ -> Just line
      [] -> Nothing

-- | A string after its first n UTF-16 code units.
dropUnits :: Integer -> String -> String
dropUnits n text
  | n <= 0 = text
  | otherwise = case text of
      c : rest -> dropUnits (n - (if ord c >= 0x10000 then 2 else 1)) rest
      [] -> []

-- | url.pathToFileURL(path).href for an absolute POSIX path: the bytes
-- outside the URL path's safe set, and those Node escapes first, as
-- percent escapes of their UTF-8.
pathToFileUrl :: FilePath -> String
pathToFileUrl path = "file://" ++ concatMap escape (B.unpack (utf8 path))
  where
    escape byte
      | byte < 0x21 || byte >= 0x7f || chr (fromIntegral byte) `elem` ("\"#%<>?[\\]^`{|}~" :: String) =
          '%' : map toUpperHex (pad (showHex byte ""))
      | otherwise = [chr (fromIntegral byte)]
    pad digits = replicate (2 - length digits) '0' ++ digits
    toUpperHex c = if c >= 'a' && c <= 'f' then chr (ord c - 32) else c

-- | url.fileURLToPath(url) for a file URL on a POSIX system, with Node's
-- messages for what it refuses.
fileUrlToPath :: (Monad m) => Json -> Command m FilePath
fileUrlToPath = \case
  JString url -> case break (== ':') url of
    (scheme, ':' : rest)
      | not (null scheme) && all validScheme scheme ->
          if map toLower scheme /= "file"
            then failWith "The URL must be of scheme file"
            else do
              let (host, path) = case rest of
                    '/' : '/' : afterSlashes -> break (== '/') afterSlashes
                    _ -> ("", rest)
              when (host `notElem` ["", "localhost"]) (failWith "File URL host must be \"localhost\" or empty on darwin")
              when ("%2f" `isInfixOf` map toLower path) $
                failWith "File URL path must not include encoded / characters"
              pure (normalisePath (fromUtf8 (B.pack (decode path))))
    _ -> failWith "Invalid URL"
  JNull -> failWith "The \"path\" argument must be of type string or an instance of URL. Received null"
  other -> failWith ("The \"path\" argument must be of type string or an instance of URL. Received type " ++ typeName (Just other))
  where
    validScheme c = c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || c `elem` ['0' .. '9'] || c `elem` ("+-." :: String)
    decode = \case
      '%' : a : b : rest
        | isHexDigit a && isHexDigit b,
          [(byte, "")] <- readHex [a, b] ->
            byte : decode rest
      c : rest -> B.unpack (utf8 [c]) ++ decode rest
      [] -> []
    -- The URL parser's dot segments.
    normalisePath path = "/" ++ intercalate' (foldl step [] (splitSlash (dropWhile (== '/') path))) ++ (if trailing path then "/" else "")
      where
        trailing p = not (null p) && last p == '/' && p /= "/"
        step kept segment = case segment of
          "." -> kept
          ".." -> if null kept then [] else init kept
          "" -> kept
          _ -> kept ++ [segment]
    splitSlash text = case break (== '/') text of
      (segment, _ : rest) -> segment : splitSlash rest
      (segment, []) -> [segment]
    intercalate' = foldr1' (\a b -> a ++ "/" ++ b)
    foldr1' f = \case
      [] -> ""
      xs -> foldr1 f xs

locationJson :: Symbol -> Json
locationJson entry = JObject [("uri", JString (symbolUri entry)), ("range", rangeJson (symbolRange entry))]

rangeJson :: Range -> Json
rangeJson (Range start end) = JObject [("start", positionJson start), ("end", positionJson end)]
  where
    positionJson (line, character) = JObject [("line", integer line), ("character", integer character)]

sourcesJson :: [(FilePath, String)] -> Json
sourcesJson sources = JArray [JObject [("path", JString path), ("content", JString content)] | (path, content) <- sources]

textOf :: Json -> String
textOf document = case member "text" document of
  Just (JString text) -> text
  _ -> ""

listAt :: String -> Json -> [Json]
listAt key value = fromMaybe [] (member key value >>= arrayOf)

-- | Map.set: a new key goes last, an existing one keeps its place.
insert :: (Eq k) => k -> v -> [(k, v)] -> [(k, v)]
insert key value entries
  | any ((== key) . fst) entries = [(k, if k == key then value else v) | (k, v) <- entries]
  | otherwise = entries ++ [(key, value)]

setOrDrop :: String -> Maybe Json -> Json -> Json
setOrDrop key value document = maybe (dropMember key document) (\v -> setMember key v document) value

isTruthy' :: Maybe Json -> Bool
isTruthy' = maybe False isTruthy

attempt :: (Monad m) => Command m a -> Command m (Either Failure a)
attempt command = recover (Right <$> command) (pure . Left)

rpcError :: Integer -> String -> Json
rpcError code message = JObject [("code", integer code), ("message", JString message)]

notification :: Json -> Json
notification params = JObject [("jsonrpc", JString "2.0"), ("method", JString "textDocument/publishDiagnostics"), ("params", params)]

-- | A message with its Content-Length header.
send :: (Monad m) => Json -> Command m ()
send value = do
  let payload = utf8 (compact value)
  sendBytes (utf8 ("Content-Length: " ++ show (B.length payload) ++ "\r\n\r\n") <> payload)
