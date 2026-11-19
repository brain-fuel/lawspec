-- | JSON text exactly as JavaScript's @JSON.stringify(value, null, 2)@ writes
-- it, so ported commands print the bytes the Node CLI printed. Objects keep
-- their member order; JavaScript's own order puts array-index keys first,
-- ascending, which 'fromValue' reproduces for parsed objects.
-- ref:DEC-host-effect-abi
module LawSpec.App.Json
  ( Json (..),
    fromValue,
    toValue,
    stringify,
    stringifyWith,
    compact,
    numberText,
    parseJson,
    canonical,
    member,
    members,
    setMember,
    dropMember,
    jsObject,
    stringOf,
    arrayOf,
    isTruthy,
    jsString,
    integer,
  )
where

import qualified Data.Aeson as JSON
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Char (chr, isDigit, isHexDigit, ord)
import Data.Foldable (toList)
import Data.List (intercalate, partition, sortOn)
import Data.Scientific (Scientific, scientific, toRealFloat)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Numeric (floatToDigits, readHex, showHex)

data Json
  = JNull
  | JBool Bool
  | JNumber Scientific
  | JString String
  | JArray [Json]
  | JObject [(String, Json)]
  deriving (Eq, Show)

-- | A decoded value in the member order JavaScript gives a parsed object.
-- aeson's maps are ordered by key, which is the order LawSpec's core writes.
fromValue :: JSON.Value -> Json
fromValue = \case
  JSON.Null -> JNull
  JSON.Bool flag -> JBool flag
  JSON.Number number -> JNumber number
  JSON.String text -> JString (T.unpack text)
  JSON.Array items -> JArray (map fromValue (toList items))
  JSON.Object fields ->
    let fields' = [(K.toString key, fromValue item) | (key, item) <- KM.toAscList fields]
        (indices, names) = partition (isArrayIndex . fst) fields'
     in JObject (sortOn (read' . fst) indices ++ names)
  where
    read' text = read text :: Integer

-- | A canonical array index: "0" or digits without a leading zero, below 2^32 - 1.
isArrayIndex :: String -> Bool
isArrayIndex key = case key of
  "0" -> True
  first : _ | first /= '0', all isDigit key, length key <= 10 -> (read key :: Integer) < 4294967295
  _ -> False

stringify :: Json -> String
stringify = render ""

-- | JSON.stringify(value, null, gap) with a string gap: its first ten
-- characters indent each level, and an empty gap writes compact JSON.
stringifyWith :: String -> Json -> String
stringifyWith gap value
  | null unit = compact value
  | otherwise = go "" value
  where
    unit = take 10 gap
    go indent = \case
      JArray items@(_ : _) -> block indent '[' ']' [go (indent ++ unit) item | item <- items]
      JObject fields@(_ : _) -> block indent '{' '}' [quote key ++ ": " ++ go (indent ++ unit) item | (key, item) <- fields]
      other -> stringify other
    block indent open close rows =
      [open, '\n'] ++ intercalate ",\n" (map ((indent ++ unit) ++) rows) ++ "\n" ++ indent ++ [close]

-- | JSON.stringify(value), without indentation.
compact :: Json -> String
compact = \case
  JArray items -> "[" ++ intercalate "," (map compact items) ++ "]"
  JObject fields -> "{" ++ intercalate "," [quote key ++ ":" ++ compact item | (key, item) <- fields] ++ "}"
  other -> stringify other

render :: String -> Json -> String
render indent = \case
  JNull -> "null"
  JBool True -> "true"
  JBool False -> "false"
  JNumber number -> numberText number
  JString text -> quote text
  JArray [] -> "[]"
  JArray items -> block '[' ']' [render inner item | item <- items]
  JObject [] -> "{}"
  JObject fields -> block '{' '}' [quote key ++ ": " ++ render inner item | (key, item) <- fields]
  where
    inner = indent ++ "  "
    block open close rows =
      [open, '\n'] ++ intercalate ",\n" (map (inner ++) rows) ++ "\n" ++ indent ++ [close]

-- | JSON.stringify's string escaping (QuoteJSONString).
quote :: String -> String
quote text = '"' : concatMap escape text ++ "\""
  where
    escape = \case
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\b' -> "\\b"
      '\f' -> "\\f"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      c
        | ord c < 0x20 -> "\\u" ++ pad (showHex (ord c) "")
        | ord c >= 0xD800 && ord c <= 0xDFFF -> "\\u" ++ showHex (ord c) ""
        | otherwise -> [c]
    pad digits = replicate (4 - length digits) '0' ++ digits

-- | ECMAScript Number::toString for the double nearest the given number.
numberText :: Scientific -> String
numberText number
  | isNaN value || isInfinite value = "null"
  | value == 0 = "0"
  | value < 0 = '-' : positive (negate value)
  | otherwise = positive value
  where
    value = toRealFloat number :: Double
    positive x =
      let (digits, n) = floatToDigits 10 x
          s = concatMap show digits
          k = length digits
       in if k <= n && n <= 21
            then s ++ replicate (n - k) '0'
            else
              if 0 < n && n <= 21
                then take n s ++ "." ++ drop n s
                else
                  if -6 < n && n <= 0
                    then "0." ++ replicate (negate n) '0' ++ s
                    else
                      let e = n - 1
                          sign = if e >= 0 then "+" else "-"
                          mantissa = if k == 1 then s else take 1 s ++ "." ++ drop 1 s
                       in mantissa ++ "e" ++ sign ++ show (abs e)

-- | The aeson value of a 'Json', for a compiler request.
toValue :: Json -> JSON.Value
toValue = \case
  JNull -> JSON.Null
  JBool flag -> JSON.Bool flag
  JNumber number -> JSON.Number number
  JString text -> JSON.String (T.pack text)
  JArray items -> JSON.toJSON (map toValue items)
  JObject fields -> JSON.Object (KM.fromList [(K.fromString key, toValue item) | (key, item) <- fields])

-- | An object with JavaScript's member order: array-index keys first,
-- ascending, then the others in insertion order; a repeated key keeps its
-- first position and its last value, as an object literal or JSON.parse does.
jsObject :: [(String, Json)] -> Json
jsObject fields = JObject (sortOn (read' . fst) indices ++ names)
  where
    merged = foldl insert [] fields
    insert kept (key, value)
      | any ((== key) . fst) kept = [(k, if k == key then value else v) | (k, v) <- kept]
      | otherwise = kept ++ [(key, value)]
    (indices, names) = partition (isArrayIndex . fst) merged
    read' text = read text :: Integer

member :: String -> Json -> Maybe Json
member key (JObject fields) = lookup key fields
member _ _ = Nothing

members :: Json -> [(String, Json)]
members (JObject fields) = fields
members _ = []

-- | object[key] = value: replaces in place, or appends a new member.
setMember :: String -> Json -> Json -> Json
setMember key value (JObject fields) = jsObject (fields ++ [(key, value)])
setMember _ _ other = other

-- | delete object[key].
dropMember :: String -> Json -> Json
dropMember key (JObject fields) = JObject (filter ((/= key) . fst) fields)
dropMember _ other = other

stringOf :: Json -> Maybe String
stringOf (JString text) = Just text
stringOf _ = Nothing

arrayOf :: Json -> Maybe [Json]
arrayOf (JArray items) = Just items
arrayOf _ = Nothing

-- | JavaScript truthiness.
isTruthy :: Json -> Bool
isTruthy = \case
  JNull -> False
  JBool flag -> flag
  JNumber number -> number /= 0
  JString text -> not (null text)
  _ -> True

-- | String(value), as a template literal shows a parsed JSON value.
jsString :: Json -> String
jsString = \case
  JString text -> text
  JNumber number -> numberText number
  JBool True -> "true"
  JBool False -> "false"
  JNull -> "null"
  JArray items -> intercalate "," [if item == JNull then "" else jsString item | item <- items]
  JObject _ -> "[object Object]"

integer :: Integer -> Json
integer value = JNumber (scientific value 0)

-- | component.mjs canonical(): object keys sorted by UTF-16 code units,
-- no spaces, JSON.stringify for scalars.
canonical :: Json -> String
canonical = \case
  JArray items -> "[" ++ intercalate "," (map canonical items) ++ "]"
  JObject fields -> "{" ++ intercalate "," [quote key ++ ":" ++ canonical value | (key, value) <- sortOn (concatMap units . fst) fields] ++ "}"
  other -> stringify other
  where
    units c
      | ord c < 0x10000 = [ord c]
      | otherwise = let v = ord c - 0x10000 in [0xD800 + v `div` 0x400, 0xDC00 + v `mod` 0x400]

-- | JSON.parse, keeping JavaScript's member order. The message on failure is
-- not V8's.
parseJson :: String -> Either String Json
parseJson input = case value (skip input) of
  Right (result, rest) | null (skip rest) -> Right result
  Right (_, rest) -> Left ("Unexpected non-whitespace character after JSON at position " ++ show (position rest))
  Left rest -> Left (if null rest then "Unexpected end of JSON input" else "Unexpected token '" ++ take 1 rest ++ "' in JSON at position " ++ show (position rest))
  where
    position rest = length input - length rest
    skip = dropWhile (`elem` (" \t\n\r" :: String))
    value text = case text of
      '{' : rest -> object (skip rest) []
      '[' : rest -> array (skip rest) []
      '"' : rest -> fmap (\(t, r) -> (JString t, r)) (string rest "")
      't' : 'r' : 'u' : 'e' : rest -> Right (JBool True, rest)
      'f' : 'a' : 'l' : 's' : 'e' : rest -> Right (JBool False, rest)
      'n' : 'u' : 'l' : 'l' : rest -> Right (JNull, rest)
      c : _ | c == '-' || isDigit c -> number text
      _ -> Left text
    object ('}' : rest) [] = Right (jsObject [], rest)
    object text kept = case text of
      '"' : rest -> do
        (key, afterKey) <- string rest ""
        case skip afterKey of
          ':' : afterColon -> do
            (item, afterValue) <- value (skip afterColon)
            let kept' = kept ++ [(key, item)]
            case skip afterValue of
              ',' : more -> object (skip more) kept'
              '}' : more -> Right (jsObject kept', more)
              other -> Left other
          other -> Left other
      other -> Left other
    array (']' : rest) [] = Right (JArray [], rest)
    array text kept = do
      (item, afterValue) <- value text
      case skip afterValue of
        ',' : more -> array (skip more) (kept ++ [item])
        ']' : more -> Right (JArray (kept ++ [item]), more)
        other -> Left other
    string text acc = case text of
      '"' : rest -> Right (reverse acc, rest)
      '\\' : c : rest -> case c of
        '"' -> string rest ('"' : acc)
        '\\' -> string rest ('\\' : acc)
        '/' -> string rest ('/' : acc)
        'b' -> string rest ('\b' : acc)
        'f' -> string rest ('\f' : acc)
        'n' -> string rest ('\n' : acc)
        'r' -> string rest ('\r' : acc)
        't' -> string rest ('\t' : acc)
        'u' | (digits, more) <- splitAt 4 rest, length digits == 4, all isHexDigit digits ->
          let code = case readHex digits of [(n, _)] -> n; _ -> 0
           in case (acc, code) of
                (high : earlier, _)
                  | code >= 0xDC00 && code <= 0xDFFF && ord high >= 0xD800 && ord high <= 0xDBFF ->
                      string more (chr (0x10000 + (ord high - 0xD800) * 0x400 + (code - 0xDC00)) : earlier)
                _ -> string more (chr code : acc)
        _ -> Left (c : rest)
      c : rest
        | ord c < 0x20 -> Left text
        | otherwise -> string rest (c : acc)
      [] -> Left []
    number text =
      let (sign, afterSign) = case text of
            '-' : rest -> ("-", rest)
            _ -> ("", text)
          (whole, afterWhole) = span isDigit afterSign
          (fraction, afterFraction) = case afterWhole of
            '.' : rest | (digits@(_ : _), more) <- span isDigit rest -> ('.' : digits, more)
            _ -> ("", afterWhole)
          (exponent', afterExponent) = case afterFraction of
            e : rest
              | e `elem` ("eE" :: String) ->
                  let (signs, more) = case rest of
                        s' : more' | s' `elem` ("+-" :: String) -> ([s'], more')
                        _ -> ("", rest)
                      (digits, after) = span isDigit more
                   in if null digits then ("", afterFraction) else (e : signs ++ digits, after)
            _ -> ("", afterFraction)
       in if null whole || (length whole > 1 && take 1 whole == "0")
            then Left afterSign
            else case JSON.decodeStrict (TE.encodeUtf8 (T.pack (sign ++ whole ++ fraction ++ exponent'))) of
              Just (JSON.Number n) -> Right (JNumber n, afterExponent)
              _ -> Left text
