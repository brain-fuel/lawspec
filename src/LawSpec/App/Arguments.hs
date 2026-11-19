-- | The command line as the Node CLI parses it (templates/npm/bin/lawspec.mjs):
-- the verb, valued and repeatable options, flags and positional arguments.
-- A parse failure is returned, not reported: "LawSpec.App.Main" reports it
-- as a usage error, where the legacy CLI ends with an uncaught exception.
-- ref:DEC-haskell-application-port
module LawSpec.App.Arguments
  ( Arguments (..),
    parseArguments,
    option,
    flag,
    present,
    given,
    javascriptNumber,
  )
where

import Data.Char (digitToInt, isDigit, isHexDigit, isOctDigit, isSpace)
import Data.List (foldl', isPrefixOf)
import qualified Data.Map.Strict as M
import Data.Ratio ((%))

data Arguments = Arguments
  { verb :: Maybe String,
    -- | Valued options by name without dashes; the last occurrence wins.
    options :: M.Map String String,
    -- | Repeatable list options (@--tag@, @--exclude-tag@).
    lists :: M.Map String [String],
    flags :: [String],
    positional :: [String]
  }
  deriving (Eq, Show)

valued :: [String]
valued =
  [ "mutation-timeout",
    "mutated-generated",
    "port",
    "languages",
    "target",
    "project",
    "config",
    "output",
    "machine-bits",
    "example",
    "seed",
    "report",
    "attestation",
    "view",
    "solver",
    "proof-timeout",
    "proof-memory",
    "proof-rlimit",
    "proof-seed",
    "release",
    "generated-source-dir",
    "generated-test-dir",
    "name",
    "group"
  ]

repeatable :: [String]
repeatable = ["tag", "exclude-tag"]

booleans :: [String]
booleans =
  [ "dry-run",
    "check",
    "json",
    "minify",
    "no-cache",
    "timings",
    "no-install",
    "fresh",
    "coverage",
    "update-recorded",
    "benchmarks",
    "stdio",
    "warn-matches",
    "no-advice",
    "strict",
    "compile",
    "locked",
    "offline"
  ]

parseArguments :: [String] -> Either String Arguments
parseArguments [] = Right (Arguments Nothing M.empty M.empty [] [])
parseArguments (first : rest) = go rest (Arguments (Just first) M.empty M.empty [] [])
  where
    go [] parsed = Right parsed {flags = reverse (flags parsed), positional = reverse (positional parsed)}
    go (argument : more) parsed
      | Just name <- dashed argument,
        name `elem` valued = do
          (value, remaining) <- needValue argument more
          go remaining parsed {options = M.insert name value (options parsed)}
      | Just name <- dashed argument,
        name `elem` repeatable = do
          (value, remaining) <- needValue argument more
          let values = filter (not . null) (splitOn ',' value)
          go remaining parsed {lists = M.insertWith (flip (++)) name values (lists parsed)}
      | Just name <- dashed argument,
        name `elem` booleans =
          go more parsed {flags = name : flags parsed}
      | "--" `isPrefixOf` argument = Left ("Unknown option: " ++ argument)
      | otherwise = go more parsed {positional = argument : positional parsed}
    dashed argument = if "--" `isPrefixOf` argument then Just (drop 2 argument) else Nothing
    needValue argument more = case more of
      value : remaining | not (null value), not ("--" `isPrefixOf` value) -> Right (value, remaining)
      _ -> Left ("Missing value for " ++ argument)

oneOf :: Char -> String -> Bool
oneOf = elem

splitOn :: Char -> String -> [String]
splitOn separator text = case break (== separator) text of
  (part, []) -> [part]
  (part, _ : rest) -> part : splitOn separator rest

option :: String -> Arguments -> Maybe String
option name = M.lookup name . options

flag :: String -> Arguments -> Bool
flag name = elem name . flags

-- | Whether a valued, repeatable or boolean option was given at all, as the
-- Node CLI's @options[name] !== undefined@ (or truthiness, for flags).
present :: String -> Arguments -> Bool
present name arguments =
  M.member name (options arguments) || M.member name (lists arguments) || flag name arguments

-- | Every option given, by name: Object.keys(options) without the keys the
-- Node CLI adds itself (machineBits, beside machine-bits).
given :: Arguments -> [String]
given arguments = M.keys (options arguments) ++ M.keys (lists arguments) ++ flags arguments

-- | ECMAScript's Number(string) (StringToNumber), as an exact rational.
-- 'Nothing' is NaN; infinities are 'Nothing' too, since no caller accepts them.
javascriptNumber :: String -> Maybe Rational
javascriptNumber input = case trim input of
  "" -> Just 0
  '0' : x : digits | x `oneOf` "xX" -> radix 16 isHexDigit digits
  '0' : o : digits | o `oneOf` "oO" -> radix 8 isOctDigit digits
  '0' : b : digits | b `oneOf` "bB" -> radix 2 (`oneOf` "01") digits
  '+' : text -> decimal text
  '-' : text -> negate <$> decimal text
  text -> decimal text
  where
    trim = reverse . dropWhile javascriptSpace . reverse . dropWhile javascriptSpace
    javascriptSpace c = isSpace c || c `oneOf` "\x00A0\xFEFF\x2028\x2029\x1680\x202F\x205F\x3000" || (c >= '\x2000' && c <= '\x200A')
    radix base valid digits
      | not (null digits), all valid digits = Just (fromIntegral (foldl' (\total d -> total * base + toInteger (digitToInt d)) 0 digits))
      | otherwise = Nothing
    decimal text =
      let (whole, afterWhole) = span isDigit text
          (fraction, afterFraction) = case afterWhole of
            '.' : more -> span isDigit more
            _ -> ("", afterWhole)
       in if null whole && null fraction
            then Nothing
            else case afterFraction of
              [] -> Just (mantissa whole fraction)
              e : exponentText
                | e `oneOf` "eE" -> scaled whole fraction exponentText
              _ -> Nothing
    mantissa whole fraction = fromInteger (digitsValue (whole ++ fraction)) / (10 ^ length fraction)
    digitsValue digits = foldl' (\total d -> total * 10 + toInteger (digitToInt d)) 0 digits
    scaled whole fraction exponentText = case exponentText of
      '+' : digits -> power whole fraction digits id
      '-' : digits -> power whole fraction digits negate
      digits -> power whole fraction digits id
    power whole fraction digits sign
      | null digits || not (all isDigit digits) = Nothing
      -- A magnitude this large is far from any accepted value.
      | length digits > 6 = Just (if sign 1 > (0 :: Integer) then 10 ^ (400 :: Int) else 0)
      | otherwise =
          let e = sign (read digits :: Integer)
              base = mantissa whole fraction
           in Just (if e >= 0 then base * fromInteger (10 ^ e) else base * (1 % (10 ^ negate e)))
