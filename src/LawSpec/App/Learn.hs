-- | lawspec learn, ported from learn.mjs's serveLearn: the Learn site served
-- over HTTP on the loopback interface. The host only listens, hands over
-- each request and sends the answer back (serve, accept, respond); which
-- file answers which request, with which status and headers, is decided
-- here, as learn.mjs's request handler decided it. The site is the static
-- files under the package's learn/ folder, its core_jsffi.js, and its
-- compiler gzipped (core.wasm.gz). learn.mjs gzipped core.wasm itself, at
-- level 9, on the first request; the core has no compressor that gives
-- Node's bytes, so tools/wasm.sh and tools/learn-build.mjs write the same
-- gzipSync output beside core.wasm, and the core serves that file once it
-- matches core.wasm (its trailer's length, and not older).
--
-- The handler's path handling is learn.mjs's: the request target is parsed
-- as a URL against http://localhost (the WHATWG URL parser, for the part of
-- it a request target reaches), its pathname percent-decoded as
-- decodeURIComponent does, joined to the site's folder as path.join does,
-- and resolved with realpath, which must stay inside the folder.
-- ref:DEC-haskell-application-port ref:DEC-host-effect-abi
module LawSpec.App.Learn
  ( learnCommand,
    Site (..),
    answer,
    urlPathname,
    decodeComponent,
    extensionOf,
  )
where

import Control.Monad (forM_, unless)
import Data.Bits (shiftL, (.&.), (.|.))
import qualified Data.ByteString as B
import Data.Char (chr, digitToInt, isAsciiLower, isAsciiUpper, isDigit, isHexDigit, ord, toLower)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Maybe (fromMaybe)
import LawSpec.App.Command
import LawSpec.Host.Effect
import LawSpec.Host.Path (join, normalise)

-- | Where the site's files are: the package's learn/ folder as realpath
-- gives it, its core_jsffi.js, and the gzipped compiler with the length of
-- core.wasm it must hold.
data Site = Site
  { siteRoot :: FilePath,
    siteCompilerGlue :: FilePath,
    siteCompressed :: FilePath,
    siteCompilerSize :: Integer
  }

-- | learn.mjs's packagedAssets() message.
missingAssets :: String
missingAssets = "Learn assets are missing. In a compiler checkout run npm ci --prefix learn, make generate, and npm run build --prefix learn."

-- | serveLearn(port): check the packaged assets, listen, print where, and
-- answer requests until the host stops the process (SIGINT, as for the
-- legacy server). The resources directory is the one the host ships, or
-- none.
learnCommand :: (Monad m) => Maybe FilePath -> Maybe String -> Command m Int
learnCommand resources requested = do
  directory <- maybe (failWith missingAssets) pure resources
  let learn = join directory "learn"
      glue = join directory "core_jsffi.js"
      compressed = join directory "core.wasm.gz"
      compiler = join directory "core.wasm"
  grantRead [learn, glue, compressed, compiler]
  forM_ ["vendor/manifest.json", "sandbox-frame.html"] $ \asset ->
    effectOr (ReadFile (join learn asset)) >>= either (const (failWith missingAssets)) (const (pure ()))
  let text = fromMaybe "8384" requested
  unless (not (null text) && all isDigit text && read text <= (65535 :: Integer)) $
    failWith "--port must be an integer from 1 to 65535 (0 selects an available port)"
  let port = read text :: Int
  compilerSize <- freshCompressed compiler compressed
  root <- effect (nodeFailure "realpath" learn) (RealPath learn)
  grantListening
  Listening listener actual <- effect (listenFailure port) (Serve port)
  printLine ("Learn LawSpec: http://127.0.0.1:" ++ show actual ++ "/")
  serveRequests (Site root glue compressed compilerSize) listener

-- | The gzipped compiler must be there, no older than core.wasm; its size
-- is checked against the file's trailer when it is first read.
freshCompressed :: (Monad m) => FilePath -> FilePath -> Command m Integer
freshCompressed compiler compressed = do
  source <- effectOr (Stat Follow compiler)
  archive <- effectOr (Stat Follow compressed)
  case (source, archive) of
    (Right original, Right gzipped)
      | statusKind gzipped == FileKind && statusModified gzipped >= statusModified original -> pure (statusSize original)
    _ -> failWith (stale compressed)

stale :: FilePath -> String
stale compressed = "Learn's compiler archive " ++ compressed ++ " is missing or older than core.wasm. In a compiler checkout run node tools/learn-build.mjs."

-- | The error Node's server.listen() rejects with, for the two errors a
-- host classifies; any other is the host's own message.
listenFailure :: Int -> HostError -> Failure
listenFailure port (HostError kind message) = Failure text Nothing
  where
    address = "127.0.0.1:" ++ show port
    text = case kind of
      AlreadyExists -> "listen EADDRINUSE: address already in use " ++ address
      PermissionDenied -> "listen EACCES: permission denied " ++ address
      _ -> message

-- | One request at a time, in the order they arrive. The compiler archive is
-- read once, on the first request for it, and kept, as learn.mjs kept it.
serveRequests :: (Monad m) => Site -> Listener -> Command m Int
serveRequests site listener = loop Nothing
  where
    loop cached = do
      next <- effectOr (Accept listener 60000)
      case next of
        Left problem -> failWith (errorMessage problem)
        Right Nothing -> loop cached
        Right (Just request) -> do
          (response, cached') <- answer site cached request
          _ <- effectOr (Respond (requestId request) response)
          loop cached'

-- | learn.mjs's request handler: the response to one request, and the
-- compiler archive once it has been read.
answer :: (Monad m) => Site -> Maybe B.ByteString -> IncomingRequest -> Command m (Response, Maybe B.ByteString)
answer site cached request
  | method `notElem` ["GET", "HEAD"] = pure (Response 405 [] B.empty, cached)
  | otherwise = case urlPathname (requestPath request) >>= decodeComponent of
      Nothing -> pure (notFound, cached)
      Just "/core.wasm.gz"
        | head' -> pure (compressedResponse B.empty, cached)
        | Just bytes <- cached -> pure (compressedResponse bytes, cached)
        | otherwise -> do
            loaded <- effectOr (ReadFile (siteCompressed site))
            case loaded of
              Right bytes | trailerSize bytes == siteCompilerSize site `mod` 4294967296 -> pure (compressedResponse bytes, Just bytes)
              Right _ -> do
                printError ("lawspec: " ++ stale (siteCompressed site))
                pure (notFound, cached)
              Left _ -> pure (notFound, cached)
      Just pathname -> do
        let glue = pathname == "/core_jsffi.js"
            candidate
              | glue = Just (siteCompilerGlue site)
              | otherwise = nodeJoin (siteRoot site) (if pathname == "/" then "index.html" else pathname)
        file <- maybe (pure Nothing) (fmap (either (const Nothing) Just) . effectOr . RealPath) candidate
        status <- maybe (pure Nothing) (fmap (either (const Nothing) Just) . effectOr . Stat Follow) file
        case (file, status) of
          (Just real, Just found)
            | glue || (siteRoot site ++ "/") `isPrefixOf` real,
              statusKind found == FileKind -> do
                body <- if head' then pure (Right B.empty) else effectOr (ReadFile real)
                pure $ case body of
                  Right bytes ->
                    ( Response
                        200
                        [ ("Content-Type", fromMaybe "application/octet-stream" (lookup (extensionOf real) contentTypes)),
                          ("X-Content-Type-Options", "nosniff"),
                          ("Cache-Control", "no-cache")
                        ]
                        bytes,
                      cached
                    )
                  Left _ -> (notFound, cached)
          _ -> pure (notFound, cached)
  where
    method = requestMethod request
    head' = method == "HEAD"
    notFound = Response 404 [] (utf8 "Not found")
    compressedResponse = Response 200 [("Content-Type", "application/gzip"), ("Cache-Control", "no-cache")]

-- | learn.mjs's types, by path.extname of the resolved file.
contentTypes :: [(String, String)]
contentTypes =
  [ (".html", "text/html; charset=utf-8"),
    (".mjs", "text/javascript; charset=utf-8"),
    (".js", "text/javascript; charset=utf-8"),
    (".css", "text/css; charset=utf-8"),
    (".json", "application/json; charset=utf-8"),
    (".wasm", "application/wasm"),
    (".woff2", "font/woff2")
  ]

-- | The uncompressed length a gzip member's trailer records (ISIZE, the
-- length modulo 2^32), or -1 when there is no trailer.
trailerSize :: B.ByteString -> Integer
trailerSize bytes
  | B.length bytes < 18 = -1
  | otherwise = foldr (\byte total -> total * 256 + fromIntegral byte) 0 (B.unpack (B.drop (B.length bytes - 4) bytes))

-- | path.join(root, pathname) as realpath then sees it. A pathname with a
-- NUL is refused by realpath, and one that ends in a separator keeps it
-- through path.join, so realpath either fails (a file) or names a
-- directory: neither is served.
nodeJoin :: FilePath -> String -> Maybe FilePath
nodeJoin root pathname
  | '\0' `elem` pathname = Nothing
  | "/" `isSuffixOf` pathname = Nothing
  | otherwise = Just (normalise (root ++ "/" ++ pathname))

-- | path.extname: the last name's extension from its last dot, or nothing
-- when it has no dot but a leading one (or is @..@).
extensionOf :: FilePath -> String
extensionOf path = case break (== '.') (reverse name) of
  (_, []) -> ""
  (reversed, _ : before)
    | null before || name == ".." -> ""
    | otherwise -> '.' : reverse reversed
  where
    name = reverse (takeWhile (/= '/') (reverse path))

-- | decodeURIComponent: every percent escape decoded as UTF-8, or 'Nothing'
-- (URIError) for a malformed escape or an invalid sequence.
decodeComponent :: String -> Maybe String
decodeComponent text = case text of
  [] -> Just []
  '%' : _ -> do
    (lead, rest) <- escape text
    if lead < 0x80
      then (chr lead :) <$> decodeComponent rest
      else do
        (count, initial, least) <- case () of
          _
            | lead .&. 0xE0 == 0xC0 -> Just (1, lead .&. 0x1F, 0x80)
            | lead .&. 0xF0 == 0xE0 -> Just (2, lead .&. 0x0F, 0x800)
            | lead .&. 0xF8 == 0xF0 -> Just (3, lead .&. 0x07, 0x10000)
            | otherwise -> Nothing
        (point, rest') <- continuation (count :: Int) initial rest
        unless (point >= least && point <= 0x10FFFF && (point < 0xD800 || point > 0xDFFF)) Nothing
        (chr point :) <$> decodeComponent rest'
  c : rest -> (c :) <$> decodeComponent rest
  where
    escape ('%' : a : b : rest) | isHexDigit a && isHexDigit b = Just (digitToInt a * 16 + digitToInt b, rest)
    escape _ = Nothing
    continuation 0 point rest = Just (point, rest)
    continuation n point rest = do
      (byte, rest') <- escape rest
      unless (byte .&. 0xC0 == 0x80) Nothing
      continuation (n - 1) ((point `shiftL` 6) .|. (byte .&. 0x3F)) rest'

-- | The pathname of @new URL(target, 'http://localhost')@, still
-- percent-encoded as the parser leaves it, or 'Nothing' where the parser
-- throws. The request target is Latin-1 text, as a host reports it and as
-- Node's HTTP parser gives request.url. Percent-encoding the path's other
-- characters is left out: decodeComponent, which always follows, undoes
-- it. Covered: absolute URLs with a scheme (special schemes with their
-- authority, file: and other schemes' paths), scheme-relative and
-- path-absolute targets with either slash, relative paths against the base
-- path, query and fragment, and dot segments, %2e spellings included.
-- Hosts are validated for what makes the parser throw short of IDNA: an
-- empty host, a forbidden code point, a bad port or IPv4 number. A
-- non-ASCII host is accepted unchecked.
urlPathname :: String -> Maybe String
urlPathname target = case schemeOf input of
  Just (scheme, rest)
    | scheme == "file" -> case rest of
        a : b : more | slash a && slash b -> Just (special (dropWhile (not . terminator) more))
        _ -> Just (special rest)
    | scheme == "http" && not (startsWithTwo rest) -> relative rest
    | scheme `elem` specialSchemes -> authority (dropWhile slash rest)
    | '/' : '/' : more <- rest -> nonSpecialAuthority more
    | '/' : _ <- rest -> Just (nonSpecial rest)
    | otherwise -> Just (takeWhile (`notAmong` "?#") rest)
  Nothing -> relative input
  where
    input = filter (`notAmong` "\t\n\r") (trim target)
    trim = reverse . dropWhile control . reverse . dropWhile control
    control c = c <= ' '
    slash c = c == '/' || c == '\\'
    terminator c = slash c || c == '?' || c == '#'
    startsWithTwo (a : b : _) = slash a && slash b
    startsWithTwo _ = False
    specialSchemes = ["ftp", "http", "https", "ws", "wss"]
    -- Against http://localhost/, whose path is [""].
    relative rest = case rest of
      a : b : more | slash a && slash b -> authority (dropWhile slash more)
      a : _ | slash a -> Just (special rest)
      [] -> Just "/"
      c : _ | c `among` "?#" -> Just "/"
      _ -> Just (special ('/' : rest))
    authority rest =
      let (hostPort, path) = break terminator rest
       in if validAuthority hostPort then Just (special path) else Nothing
    nonSpecialAuthority rest =
      let (_, path) = break (`among` "/?#") rest
       in Just (nonSpecial path)
    special = serialise . segmentsOf slash . takeWhile (`notAmong` "?#")
    nonSpecial path = case takeWhile (`notAmong` "?#") path of
      [] -> ""
      text -> serialise (segmentsOf (== '/') text)
    serialise segments = concatMap ('/' :) segments

-- | Skip the path's leading separator, then fold its segments as the path
-- state does: a double-dot segment removes the last one, and a dot segment
-- or a double-dot one at the end leaves an empty last segment.
segmentsOf :: (Char -> Bool) -> String -> [String]
segmentsOf separator path = reverse (go [] (case path of c : rest | separator c -> rest; _ -> path))
  where
    go kept text =
      let (segment, rest) = break separator text
          final = null rest
          kept'
            | doubleDot segment = (if final then ("" :) else id) (drop 1 kept)
            | singleDot segment = if final then "" : kept else kept
            | otherwise = segment : kept
       in if final then kept' else go kept' (drop 1 rest)
    lowered = map toLower
    doubleDot segment = lowered segment `elem` ["..", ".%2e", "%2e.", "%2e%2e"]
    singleDot segment = lowered segment `elem` [".", "%2e"]

-- | The scheme and what follows its colon, when the input starts with one.
schemeOf :: String -> Maybe (String, String)
schemeOf text = case text of
  c : rest | isAsciiAlpha c -> case break (== ':') rest of
    (more, ':' : after) | all schemeCharacter more -> Just (map toLower (c : more), after)
    _ -> Nothing
  _ -> Nothing
  where
    isAsciiAlpha c = isAsciiLower c || isAsciiUpper c
    schemeCharacter c = (isAsciiAlpha c || isDigit c) || c `among` "+-."

-- | A special URL's authority: userinfo, a non-empty host and an optional
-- port.
validAuthority :: String -> Bool
validAuthority text = case hostAndPort of
  [] -> False
  _ -> validPort port && validHost host
  where
    hostAndPort = if '@' `elem` text then reverse (takeWhile (/= '@') (reverse text)) else text
    (host, port) = case hostAndPort of
      '[' : _ -> let (inside, after) = break (== ']') hostAndPort in (inside ++ take 1 after, drop 1 after)
      _ -> break (== ':') hostAndPort
    validPort [] = True
    validPort (':' : digits) = all isDigit digits && (null digits || read digits <= (65535 :: Integer))
    validPort _ = False
    validHost [] = False
    validHost ('[' : inside) = "]" `isSuffixOf` inside && all (\c -> isHexDigit c || c `among` ":.]") inside
    validHost name = case decodeComponent name of
      Nothing -> all (\c -> ord c > 0x7F || allowed c) name && ipv4 (map toLower name)
      Just decoded -> all (\c -> ord c > 0x7F || allowed c) decoded && ipv4 (map toLower decoded)
    allowed c = c > ' ' && c /= '\DEL' && c `notAmong` "#%/:<>?@[\\]^|"
    -- A host whose last label is a number must be an IPv4 address.
    ipv4 name =
      let labels = splitDots name
          labels' = if not (null labels) && null (last labels) && length labels > 1 then init labels else labels
       in null labels'
            || not (numeric (last labels'))
            || ( length labels' <= 4
                   && case mapM number labels' of
                     Just values -> all (<= 255) (init values) && last values < 256 ^ (5 - length values)
                     Nothing -> False
               )
    splitDots name = case break (== '.') name of
      (label, []) -> [label]
      (label, _ : rest) -> label : splitDots rest
    -- The last label makes the host an IPv4 address when it is decimal
    -- digits or a 0x number.
    numeric label = case label of
      [] -> False
      '0' : x : hex | x `among` "xX" -> all isHexDigit hex
      _ -> all isDigit label
    -- An IPv4 part: 0x hexadecimal, a leading 0 octal, otherwise decimal.
    number :: String -> Maybe Integer
    number label = case label of
      '0' : x : hex | x `among` "xX", all isHexDigit hex -> Just (foldl (\n d -> n * 16 + toInteger (digitToInt d)) 0 hex)
      '0' : octal@(_ : _) -> if all (`among` "01234567") octal then Just (foldl (\n d -> n * 8 + toInteger (digitToInt d)) 0 octal) else Nothing
      _ | not (null label) && all isDigit label -> Just (read label)
      _ -> Nothing

-- | Whether a character is one of the given ones.
among :: Char -> String -> Bool
among = elem

notAmong :: Char -> String -> Bool
notAmong = notElem
