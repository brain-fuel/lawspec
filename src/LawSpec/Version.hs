-- | Version admission and selection shared by compiler and application services.
-- This module has no compiler or external-format dependencies.
-- ref:DEC-haskell-application-port ref:semver-2
module LawSpec.Version (Version, Comparator, parseVersion, parseRange, satisfies, VersionSelection (..), selectVersions) where

import Data.Char (isAlphaNum, isDigit)
import Data.List (sortOn)
import Data.Ord (Down (..))

-- | Semantic versions: MAJOR.MINOR.PATCH with an optional -prerelease, which
-- orders before the release.
data Version = Version Integer Integer Integer (Maybe String) deriving (Eq, Show)

instance Ord Version where
  compare (Version a b c p) (Version x y z q) = compare (a, b, c) (x, y, z) <> prerelease p q
    where
      prerelease Nothing Nothing = EQ
      prerelease Nothing (Just _) = GT
      prerelease (Just _) Nothing = LT
      prerelease (Just l) (Just r) = compare (identifiers l) (identifiers r)
      identifiers s = map identifier (splitOn '.' s)
      identifier i = if not (null i) && all isDigit i then Left (read i :: Integer) else Right i

-- | Preserve the established LawSpec version spelling during the port. Build
-- metadata is rejected; numeric leading zeroes and Unicode alphanumerics in
-- prerelease identifiers retain their existing admission behavior. ref:semver-2
parseVersion :: String -> Either String Version
parseVersion text = do
  let (core, pre) = break (== '-') text
  parts <- case splitOn '.' core of
    [a, b, c] -> mapM number [a, b, c]
    _ -> Left "expected MAJOR.MINOR.PATCH"
  prerelease <- case pre of
    "" -> pure Nothing
    '-' : rest | not (null rest) && all (\i -> not (null i) && all (\c -> isAlphaNum c || c == '-') i) (splitOn '.' rest) -> pure (Just rest)
    _ -> Left "invalid prerelease"
  case parts of
    [a, b, c] -> pure (Version a b c prerelease)
    _ -> Left "expected MAJOR.MINOR.PATCH"
  where
    number s
      | not (null s) && all isDigit s && (s == "0" || take 1 s /= "0") = Right (read s)
      | otherwise = Left ("invalid version number " ++ show s)

-- | A range is whitespace-separated comparators, all of which must hold:
-- 1.2.3 (exactly), ^1.2.3, ~1.2.3, >=, >, <=, < and *.
data Comparator = AtLeast Version | Above Version | AtMost Version | Below Version | Exactly Version
  deriving (Eq, Show)

-- | A dependency names a range of versions, so compatible releases are accepted
-- without editing the dependent. ref:semver-2
parseRange :: String -> Either String [Comparator]
parseRange text = case words text of
  [] -> Left "empty range"
  comparators -> concat <$> mapM comparator comparators
  where
    comparator "*" = pure []
    comparator ('^' : v) = caret <$> parseVersion v
    comparator ('~' : v) = tilde <$> parseVersion v
    comparator ('>' : '=' : v) = pure . AtLeast <$> parseVersion v
    comparator ('<' : '=' : v) = pure . AtMost <$> parseVersion v
    comparator ('>' : v) = pure . Above <$> parseVersion v
    comparator ('<' : v) = pure . Below <$> parseVersion v
    comparator ('=' : v) = pure . Exactly <$> parseVersion v
    comparator v = pure . Exactly <$> parseVersion v
    caret v@(Version a b c _)
      | a > 0 = [AtLeast v, Below (Version (a + 1) 0 0 (Just "0"))]
      | b > 0 = [AtLeast v, Below (Version 0 (b + 1) 0 (Just "0"))]
      | otherwise = [AtLeast v, Below (Version 0 0 (c + 1) (Just "0"))]
    tilde v@(Version a b _ _) = [AtLeast v, Below (Version a (b + 1) 0 (Just "0"))]

-- | Prerelease versions satisfy a range only when a comparator names a
-- prerelease of the same MAJOR.MINOR.PATCH, as in npm.
satisfies :: [Comparator] -> Version -> Bool
satisfies comparators version@(Version a b c pre) =
  all holds comparators && (pre == Nothing || any samePatch comparators)
  where
    holds (AtLeast v) = version >= v
    holds (Above v) = version > v
    holds (AtMost v) = version <= v
    holds (Below v) = version < v
    holds (Exactly v) = version == v
    samePatch comparator = case bound comparator of
      Version x y z (Just _) -> (x, y, z) == (a, b, c) && not (synthetic comparator)
      _ -> False
    bound (AtLeast v) = v
    bound (Above v) = v
    bound (AtMost v) = v
    bound (Below v) = v
    bound (Exactly v) = v
    synthetic (Below (Version _ _ _ (Just "0"))) = True
    synthetic _ = False

splitOn :: Char -> String -> [String]
splitOn separator s = case break (== separator) s of
  (a, _ : rest) -> a : splitOn separator rest
  (a, []) -> [a]

-- | A malformed range has no selection; malformed candidate versions retain
-- diagnostics alongside the valid candidates, matching the external protocol.
-- ref:DEC-haskell-application-port
data VersionSelection = VersionSelection
  {versionProblems :: [String], selectedVersions :: Maybe [String]}
  deriving (Eq, Show)

-- | Select in descending semantic-version order without discarding errors.
selectVersions :: String -> [String] -> VersionSelection
selectVersions range versions = case parseRange range of
  Left problem -> VersionSelection [problem] Nothing
  Right constraint ->
    let parsed = [(text, parseVersion text) | text <- versions]
        problems = [problem | (_, Left problem) <- parsed]
        chosen = [text | (text, Right version) <- sortOn (fmap Down . snd) parsed, satisfies constraint version]
     in VersionSelection problems (Just chosen)
