-- | JSON-RPC over the host's standard streams, for lawspec lsp and lawspec
-- mcp: a reader that takes standard input through the host's blocking
-- @input@ effect, the two framings (the Language Server Protocol's
-- Content-Length headers and the Model Context Protocol's lines), and the
-- few JavaScript semantics the legacy servers' replies depend on: a missing
-- member is undefined, not null, and reading a member of either throws.
-- Each server reads one message, answers it and only then reads the next,
-- so its replies come in the order the messages came.
-- ref:DEC-haskell-application-port ref:DEC-host-effect-abi
module LawSpec.App.Rpc
  ( Reader,
    newReader,
    Framed (..),
    readFramed,
    readLine,
    sendBytes,
    property,
    propertyOf,
    jsEquals,
    typeName,
    utf16Length,
  )
where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (isDigit, ord, toLower)
import Data.List (tails)
import LawSpec.App.Command
import LawSpec.App.Json
import LawSpec.Host.Effect

-- | What is buffered from standard input and whether it has ended.
data Reader = Reader
  { readerBuffer :: B.ByteString,
    readerEnded :: Bool
  }

newReader :: Reader
newReader = Reader B.empty False

-- | The most one @input@ effect asks for.
chunkSize :: Int
chunkSize = 65536

-- | Buffer the next chunk of standard input, or 'Nothing' at its end. A host
-- answers @input@ once at least one byte is there, so this blocks until the
-- client writes. A host that cannot read standard input ends it.
fill :: (Monad m) => Reader -> Command m (Maybe Reader)
fill reader
  | readerEnded reader = pure Nothing
  | otherwise = do
      result <- effectOr (ReadInput chunkSize)
      pure $ case result of
        Right (Input bytes ended)
          | not (B.null bytes) -> Just reader {readerBuffer = readerBuffer reader <> bytes, readerEnded = ended}
        _ -> Nothing

-- | One message of the Language Server Protocol's base protocol.
data Framed
  = -- | A message's content.
    Framed B.ByteString
  | -- | A header without a usable Content-Length.
    BadLength
  | -- | Standard input ended before another whole message.
    EndOfInput

-- | lsp.mjs's framing: a header ends at the first blank line and must have
-- a Content-Length line (/^Content-Length:\s*(\d+)\s*$/im) of at most
-- 16 MiB; the content is that many bytes after it.
readFramed :: (Monad m) => Reader -> Command m (Framed, Reader)
readFramed reader = case B.breakSubstring "\r\n\r\n" (readerBuffer reader) of
  (header, rest)
    | not (B.null rest) -> case contentLength (fromUtf8 header) of
        Just size
          | size <= 16 * 1024 * 1024 ->
              let body = B.drop 4 rest
                  size' = fromInteger size
               in if B.length body >= size'
                    then pure (Framed (B.take size' body), reader {readerBuffer = B.drop size' body})
                    else more
        _ -> pure (BadLength, reader)
  _ -> more
  where
    more = fill reader >>= maybe (pure (EndOfInput, reader)) readFramed

-- | The value of the first line of a header that the legacy server's
-- regular expression matches. With the m flag, ^ and $ match at line
-- terminators, and \s also matches them.
contentLength :: String -> Maybe Integer
contentLength header = firstMatch (lineStarts header)
  where
    firstMatch [] = Nothing
    firstMatch (start : others) = maybe (firstMatch others) Just (match start)
    lineStarts text = text : [rest | c : rest <- tails text, terminator c]
    match text = case splitAt (length prefix) text of
      (start, rest)
        | map toLower start == prefix ->
            let (digits, after) = span isDigit (dropWhile jsSpace rest)
                spaces = takeWhile jsSpace after
             in if not (null digits) && (spaces == after || any terminator spaces || null after)
                  then Just (read digits)
                  else Nothing
      _ -> Nothing
    prefix = "content-length:"

-- | A JavaScript line terminator.
terminator :: Char -> Bool
terminator c = c `elem` ("\n\r\x2028\x2029" :: String)

-- | JavaScript's \s.
jsSpace :: Char -> Bool
jsSpace c = c `elem` ("\t\n\v\f\r \xa0\x1680\x2028\x2029\x202f\x205f\x3000\xfeff" :: String) || (c >= '\x2000' && c <= '\x200a')

-- | The Model Context Protocol SDK's ReadBuffer: the next line, without a
-- final carriage return, or 'Nothing' when standard input ends first. Like
-- the SDK, it stops reading when 10 MiB are buffered without a line.
readLine :: (Monad m) => Reader -> Command m (Maybe (String, Reader))
readLine reader = case BC.elemIndex '\n' (readerBuffer reader) of
  Just index ->
    let line = fromUtf8 (B.take index (readerBuffer reader))
        line' = if not (null line) && last line == '\r' then init line else line
     in pure (Just (line', reader {readerBuffer = B.drop (index + 1) (readerBuffer reader)}))
  Nothing
    | B.length (readerBuffer reader) > 10 * 1024 * 1024 -> pure Nothing
    | otherwise -> fill reader >>= maybe (pure Nothing) readLine

-- | Bytes on standard output, as the servers write their replies.
sendBytes :: (Monad m) => B.ByteString -> Command m ()
sendBytes = writeOutput Stdout

-- | @value.name@: undefined ('Nothing') for a missing member or a value
-- without members, and a TypeError for undefined or null.
property :: (Monad m) => String -> Maybe Json -> Command m (Maybe Json)
property name = \case
  Nothing -> failWith ("Cannot read properties of undefined (reading '" ++ name ++ "')")
  Just JNull -> failWith ("Cannot read properties of null (reading '" ++ name ++ "')")
  Just value -> pure (propertyOf name (Just value))

-- | @value?.name@.
propertyOf :: String -> Maybe Json -> Maybe Json
propertyOf name = \case
  Just (JObject fields) -> lookup name fields
  Just (JString text) | name == "length" -> Just (integer (fromIntegral (utf16Length text)))
  Just (JArray items) | name == "length" -> Just (integer (fromIntegral (length items)))
  _ -> Nothing

-- | @===@: scalars by value, undefined only to undefined, and an object or
-- array only to itself, which a value read twice from JSON never is.
jsEquals :: Maybe Json -> Maybe Json -> Bool
jsEquals left right = case (left, right) of
  (Nothing, Nothing) -> True
  (Just (JObject _), _) -> False
  (Just (JArray _), _) -> False
  (Just a, Just b) -> a == b
  _ -> False

-- | The type zod names in "expected X, received Y".
typeName :: Maybe Json -> String
typeName = \case
  Nothing -> "undefined"
  Just JNull -> "null"
  Just (JBool _) -> "boolean"
  Just (JNumber _) -> "number"
  Just (JString _) -> "string"
  Just (JArray _) -> "array"
  Just (JObject _) -> "object"

-- | A string's length in UTF-16 code units, as JavaScript counts it.
utf16Length :: String -> Int
utf16Length = sum . map (\c -> if ord c >= 0x10000 then 2 else 1)
