-- | Restricted external manifest codec. This ordered representation belongs to
-- the EDN boundary, not to a generic component RPC protocol. Compiler and
-- application WIT interfaces must retain their domain types.
-- ref:DEC-haskell-application-port
module LawSpec.Manifest.EDN
  ( ManifestValue (..),
    ManifestError (..),
    parseManifest,
    writeManifest,
    encodeManifestJSON,
  )
where

import Control.Monad (void)
import Data.Char (chr, digitToInt, ord, toLower, toUpper)
import Data.List (intercalate, sortOn)
import qualified Data.Set as Set
import Numeric (showHex)
import Text.Megaparsec
import Text.Megaparsec.Char (char)
import Text.Read (readMaybe)

-- | Ordered fields preserve writer bytes. Keys are normalized on admission;
-- JavaScript index keys precede other fields, as in Object.entries.
data ManifestValue
  = ManifestMap [(String, ManifestValue)]
  | ManifestVector [ManifestValue]
  | ManifestString String
  | ManifestInteger Integer
  | ManifestBool Bool
  | ManifestNil
  deriving (Eq, Show)

-- | Retain the public codec message independently of a host filename or
-- transport; adapters add their existing diagnostic location.
newtype ManifestError = ManifestError {manifestErrorMessage :: String}
  deriving (Eq, Ord, Show)

instance ShowErrorComponent ManifestError where
  showErrorComponent = manifestErrorMessage

type Parser = Parsec ManifestError String

data Raw
  = RawMap [(Raw, Raw)]
  | RawVector [Raw]
  | RawString String
  | RawKeyword String
  | RawNumber Double
  | RawBool Bool
  | RawNil
  | RawUnsupported
  deriving (Eq, Show)

-- | Parsing and conversion are deliberately separate: incomplete input is
-- reported before duplicate keys or unsupported values, like the reference.
parseManifest :: String -> Either ManifestError ManifestValue
parseManifest input = case runParser document "" (input ++ "\n)\n") of
  Left bundle -> case [problem | FancyError _ errors <- toListErrors bundle, ErrorCustom problem <- Set.toList errors] of
    problem : _ -> Left problem
    [] -> Left completeError
  Right [value@RawMap {}] -> convert value
  Right _ -> Left completeError
  where
    toListErrors = foldr (:) [] . bundleErrors

completeError :: ManifestError
completeError = ManifestError "Expected exactly one complete EDN map"

unsupportedError :: ManifestError
unsupportedError = ManifestError "Unsupported manifest EDN value; use maps, vectors, keywords, strings, integers, booleans or nil"

-- | Reader frames preserve the existing dependency's malformed-delimiter and
-- discard behavior. This is a compatibility codec, not a general EDN reader.
-- Megaparsec owns input consumption, string parsing and explicit parse failures.
data Frame
  = VectorFrame [Raw]
  | ListFrame [Raw]
  | SetFrame [Raw]
  | MapFrame [(Raw, Raw)] (Maybe Raw)
  | TagFrame String

-- The outer wrapper is implicit. A top-level ')' finishes the legacy reader,
-- even when further text remains. Values and frame contents accumulate reversed.
document :: Parser [Raw]
document = scan [] [] ""
  where
    scan frames values atom = do
      next <- lookAhead anySingle
      case next of
        '"' -> do
          (stack, output) <- flush frames values atom
          text <- quotedString
          (updated, result) <- insert stack output (RawString (scalars text))
          scan updated result ""
        ';' -> comment *> scan frames values atom
        c | c `elem` (", \t\n\r" :: String) -> do
          void anySingle
          (stack, output) <- flush frames values atom
          scan stack output ""
        c | c `elem` ("}])" :: String) -> do
          void anySingle
          (stack, output) <- flush frames values atom
          case (c, stack) of
            (')', []) -> pure (reverse output)
            (']', []) -> customFailure (ManifestError "Invalid EDN: undefined is not iterable (cannot read property Symbol(Symbol.iterator))")
            ('}', []) -> scan [] output ""
            (_, frame : rest) -> do
              let value = case (c, frame) of
                    ('}', MapFrame entries _) -> RawMap (reverse entries)
                    (']', _) -> frameValue frame
                    _ -> RawUnsupported
              (updated, result) <- insert rest output value
              scan updated result ""
            _ -> customFailure completeError
        c | c `elem` ("{[(" :: String) -> do
          void anySingle
          let isSet = c == '{' && take 1 atom == "#"
          (stack, output) <- flush frames values (if isSet then drop 1 atom else atom)
          let frame = case c of
                '{' | isSet -> SetFrame []
                '{' -> MapFrame [] Nothing
                '[' -> VectorFrame []
                _ -> ListFrame []
          scan (frame : stack) output ""
        _ -> do
          c <- anySingle
          let nextAtom = c : atom
          if nextAtom == "_#"
            then scan (TagFrame "_" : frames) values ""
            else scan frames values nextAtom
    flush frames values [] = pure (frames, values)
    flush frames values reversed = case reverse reversed of
      '#' : tag -> pure (TagFrame tag : frames, values)
      ':' : keyword -> insert frames values (RawKeyword keyword)
      "nil" -> insert frames values RawNil
      "true" -> insert frames values (RawBool True)
      "false" -> insert frames values (RawBool False)
      name -> insert frames values (maybe RawUnsupported RawNumber (number name))
    insert :: [Frame] -> [Raw] -> Raw -> Parser ([Frame], [Raw])
    insert [] values value = pure ([], value : values)
    insert (frame : rest) values value = case frame of
      VectorFrame entries -> pure (VectorFrame (value : entries) : rest, values)
      ListFrame entries -> pure (ListFrame (value : entries) : rest, values)
      SetFrame entries -> pure (SetFrame (value : entries) : rest, values)
      MapFrame entries Nothing -> pure (MapFrame entries (Just value) : rest, values)
      MapFrame entries (Just key) -> pure (MapFrame ((key, value) : entries) Nothing : rest, values)
      TagFrame "_" -> pure (rest, values)
      TagFrame "inst" -> case value of
        RawString _ -> insert rest values RawUnsupported
        _ -> customFailure (ManifestError "Invalid EDN: #inst value must be a string")
      TagFrame _ -> insert rest values RawUnsupported
    frameValue (VectorFrame entries) = RawVector (reverse entries)
    frameValue (ListFrame entries) = RawVector (reverse entries)
    frameValue (SetFrame entries) = RawVector (reverse entries)
    frameValue (MapFrame entries pending) =
      RawVector
        [RawVector [RawVector [key, value] | (key, value) <- reverse entries], RawVector (maybe [] (: []) pending)]
    frameValue (TagFrame name) = RawString name

comment :: Parser ()
comment = char ';' *> void (takeWhileP Nothing (/= '\n')) *> void (optional (char '\n'))

quotedString :: Parser String
quotedString = char '"' *> many character <* char '"'
  where
    character = satisfy (`notElem` ("\"\\" :: String)) <|> escape
    escape = do
      void (char '\\')
      c <- anySingle
      case lookup c [('t', '\t'), ('r', '\r'), ('n', '\n'), ('b', '\b'), ('f', '\f'), ('\\', '\\'), ('"', '"')] of
        Just value -> pure value
        Nothing | c == 'u' -> unicode "" 4
        _ -> customFailure (ManifestError ("Invalid EDN: Unexpected escape character: \\" ++ [c]))
    unicode :: String -> Int -> Parser Char
    unicode digits 0 = pure (chr (foldl (\n c -> n * 16 + digitToInt c) 0 digits))
    unicode digits remaining = do
      c <- anySingle
      if c `elem` ("0123456789abcdefABCDEF" :: String)
        then unicode (digits ++ [c]) (remaining - 1 :: Int)
        else customFailure (ManifestError ("Invalid EDN: Invalid unicode escape: \\u" ++ digits ++ [c]))

-- | EDN escapes use UTF-16 code units; combine pairs into Unicode scalars.
scalars :: String -> String
scalars (high : low : rest)
  | ord high >= 0xd800 && ord high <= 0xdbff && ord low >= 0xdc00 && ord low <= 0xdfff =
      chr (0x10000 + (ord high - 0xd800) * 1024 + ord low - 0xdc00) : scalars rest
scalars (c : rest) = c : scalars rest
scalars [] = []

-- | Match the dependency's numeric grammar, then its IEEE double admission.
-- This intentionally accepts integral floating spellings and rejects bigint N.
number :: String -> Maybe Double
number input = case runParser numeric "" input of
  Left _ -> Nothing
  Right normalized -> readMaybe normalized
  where
    numeric :: Parser String
    numeric = do
      sign <- optional (oneOf ("+-" :: String))
      whole <- integer
      fraction <- optional ((:) <$> char '.' <*> some digit)
      power <- optional $ do
        void (oneOf ("eE" :: String))
        polarity <- optional (oneOf ("+-" :: String))
        magnitude <- integer
        pure ("e" ++ maybe "" (: []) polarity ++ magnitude)
      void (optional (char 'M'))
      eof
      pure ((if sign == Just '-' then "-" else "") ++ whole ++ maybe "" id fraction ++ maybe "" id power)
    digit = oneOf ("0123456789" :: String)
    integer = ((: []) <$> char '0') <|> ((:) <$> oneOf ("123456789" :: String) <*> many digit)

convert :: Raw -> Either ManifestError ManifestValue
convert (RawMap entries) = ManifestMap . indexOrder <$> fields Set.empty entries
  where
    fields _ [] = Right []
    fields seen ((key, value) : rest) = do
      name <- case key of
        RawString text -> Right text
        RawKeyword text -> Right (camel text)
        _ -> Left (ManifestError "Manifest map keys must be strings or keywords")
      if Set.member name seen
        then Left (ManifestError ("Duplicate manifest key: " ++ name))
        else do
          result <- convert value
          remaining <- fields (Set.insert name seen) rest
          pure ((name, result) : remaining)
convert (RawVector values) = ManifestVector <$> traverse convert values
convert (RawString text) = Right (ManifestString text)
convert (RawKeyword text) = Right (ManifestString text)
convert (RawNumber value)
  | not (isNaN value || isInfinite value),
    abs value <= 9007199254740991,
    fromInteger (truncate value) == value =
      Right (ManifestInteger (truncate value))
convert (RawBool value) = Right (ManifestBool value)
convert RawNil = Right ManifestNil
convert _ = Left unsupportedError

camel :: String -> String
camel ('-' : c : rest) | c >= 'a' && c <= 'z' = toUpper c : camel rest
camel (c : rest) = c : camel rest
camel [] = []

indexOrder :: [(String, a)] -> [(String, a)]
indexOrder = sortOn (index . fst)
  where
    index name = case readMaybe name :: Maybe Integer of
      Just n | n >= 0 && n < 4294967295 && show n == name -> (False, n)
      _ -> (True, 0)

-- | Render the public readable or compact layout, with the terminal newline.
-- Caller-supplied map order is retained except for JavaScript array-index keys.
writeManifest :: Bool -> ManifestValue -> String
writeManifest compact value = render Nothing 0 value ++ "\n"
  where
    render parent depth current = case current of
      ManifestMap entries ->
        collection
          '{'
          '}'
          (not compact)
          depth
          [key name ++ " " ++ render (Just name) (depth + 1) child | (name, child) <- indexOrder entries]
      ManifestVector values ->
        collection
          '['
          ']'
          (not compact && any (structured parent) values)
          depth
          [render parent (depth + 1) child | child <- values]
      ManifestString text | identifier parent -> ':' : text
      ManifestString text -> quote text
      ManifestInteger n -> show n
      ManifestBool True -> "true"
      ManifestBool False -> "false"
      ManifestNil -> "nil"
    structured _ ManifestMap {} = True
    structured _ ManifestVector {} = True
    structured parent ManifestString {} = identifier parent
    structured _ _ = False
    identifier parent = parent `elem` [Just "language", Just "layers"]
    key name | portable name = ':' : concatMap kebab name
    key name = quote name
    portable (c : rest) = asciiLower c && all (\v -> asciiLower v || asciiUpper v || v `elem` ['0' .. '9']) rest
    portable [] = False
    kebab c | asciiUpper c = ['-', toLower c]
    kebab c = [c]
    asciiLower c = c >= 'a' && c <= 'z'
    asciiUpper c = c >= 'A' && c <= 'Z'
    collection open close multiline depth entries
      | multiline = [open] ++ "\n" ++ intercalate "\n" [replicate ((depth + 1) * 2) ' ' ++ entry | entry <- entries] ++ "\n" ++ replicate (depth * 2) ' ' ++ [close]
      | otherwise = [open] ++ intercalate " " entries ++ [close]

-- | Match JSON.stringify string escaping, including lone UTF-16 surrogates.
quote :: String -> String
quote text = '"' : concatMap escape text ++ "\""
  where
    escape c = case lookup c [('"', "\\\""), ('\\', "\\\\"), ('\b', "\\b"), ('\f', "\\f"), ('\n', "\\n"), ('\r', "\\r"), ('\t', "\\t")] of
      Just value -> value
      Nothing
        | ord c < 32 || (ord c >= 0xd800 && ord c <= 0xdfff) ->
            let hex = showHex (ord c) ""
             in "\\u" ++ replicate (4 - length hex) '0' ++ hex
      _ -> [c]

-- | Explicit JSON codec, retaining field order and UTF-16 escape values. Aeson's
-- Text/key-map representation would lose lone surrogates and insertion order.
-- No JSON value is used as an internal compiler or component dispatch envelope.
encodeManifestJSON :: ManifestValue -> String
encodeManifestJSON (ManifestMap fields) = "{" ++ intercalate "," [quote name ++ ":" ++ encodeManifestJSON value | (name, value) <- indexOrder fields] ++ "}"
encodeManifestJSON (ManifestVector values) = "[" ++ intercalate "," (map encodeManifestJSON values) ++ "]"
encodeManifestJSON (ManifestString text) = quote text
encodeManifestJSON (ManifestInteger value) = show value
encodeManifestJSON (ManifestBool True) = "true"
encodeManifestJSON (ManifestBool False) = "false"
encodeManifestJSON ManifestNil = "null"
