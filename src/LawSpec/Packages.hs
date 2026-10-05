-- Packages: named, versioned groups of units. A package's units live in its
-- namespace (the package name or names below it), a package names the
-- packages it depends on with version ranges, and a unit may import only
-- units of its own package (or project) and of that package's direct
-- dependencies. Each range selects the highest supplied version it accepts,
-- and a package may be supplied in several versions (see preparePackages).
module LawSpec.Packages
  ( Package(..), Project(..), emptyProject, preparePackages, packagesView, versionedDiagnostics
  , Version, parseVersion, parseRange, satisfies
  ) where

import LawSpec.Common
import LawSpec.Parser (sourceUnit)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson
import Data.Aeson.Key (Key)
import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.List (intercalate, isPrefixOf, maximumBy, sort, sortOn)
import Data.Ord (comparing)
import qualified Data.Map.Strict as M

data Package = Package
  { packageName :: String, packageVersion :: String
  , packageDependencies :: M.Map String String, packageSources :: [Source] }
  deriving (Eq, Show)

-- The request's own sources: optionally a package themselves, and the
-- packages they depend on.
data Project = Project
  { projectPackage :: Maybe (String, String), projectDependencies :: M.Map String String }
  deriving (Eq, Show)

emptyProject :: Project
emptyProject = Project Nothing M.empty

instance FromJSON Package where
  parseJSON = withObject "package" $ \o -> Package
    <$> o .: "name" <*> o .: "version" <*> o .:? "dependencies" .!= M.empty <*> o .:? "sources" .!= []

-- All sources in compilation order, with the import visibility rule and the
-- unit names of each package.
--
-- One package may be supplied in several versions. Each dependent then gets
-- the highest supplied version its range accepts, and the units of every
-- version of that package are renamed with a version segment after the
-- package name (acme.money.extra 1.2.0 becomes acme.money.v1_2_0.extra), so
-- the versions have distinct identities, modules and native names on every
-- target. Imports of a renamed unit are rewritten to the version the
-- importing package selects, keeping the alias the import had. A package
-- supplied in one version keeps its names, so nothing changes for it.
preparePackages :: Project -> [Package] -> [Source] -> Either [Diagnostic] ([Source], String -> String -> Maybe String, [(Package, [String])])
preparePackages project packages sources
  | null packages && M.null (projectDependencies project) && projectPackage project == Nothing =
      pure (sources, \_ _ -> Nothing, [])
  | otherwise = do
      let root = maybe "" fst (projectPackage project)
          rootKey = (root, "")
          rootDependencies = projectDependencies project
      forM_ (maybe [] pure (projectPackage project)) $ \(name, version) -> do
        validName name
        _ <- versionOf name version
        pure ()
      versioned <- forM packages $ \p -> do
        validName (packageName p)
        version <- versionOf (packageName p) (packageVersion p)
        when (packageName p == root) (failure ("package " ++ root ++ " is also supplied as a dependency"))
        pure (p, version)
      let keys = map (keyOf . fst) versioned
      forM_ keys $ \k@(n, v) -> when (length (filter (== k) keys) > 1)
        (failure ("package supplied more than once: " ++ n ++ " " ++ v))
      let byName = M.fromListWith (flip (++)) [(packageName p, [(p, version)]) | (p, version) <- versioned]
          table = M.fromList [(keyOf p, p) | p <- packages]
          several n = maybe False ((> 1) . length) (M.lookup n byName)
          label (n, v) | null n = "the project"
                       | several n = "package " ++ n ++ " " ++ v
                       | otherwise = "package " ++ n
          owners = (rootKey, rootDependencies) : [(keyOf p, packageDependencies p) | p <- packages]
      -- Each range selects the highest supplied version it accepts.
      selections <- forM owners $ \(owner, dependencies) -> do
        let ownerName = if null (fst owner) then "the project" else fst owner
        chosen <- forM (M.toList dependencies) $ \(name, range) -> do
          when (name == fst owner || Just name == fmap fst (projectPackage project))
            (failure (ownerName ++ " depends on itself"))
          constraint <- either (\m -> failure (ownerName ++ ": invalid version range for " ++ name ++ ": " ++ m)) pure (parseRange range)
          candidates <- maybe (failure (ownerName ++ " depends on " ++ name ++ " " ++ range ++ ", which is not supplied")) pure (M.lookup name byName)
          case [(version, p) | (p, version) <- candidates, satisfies constraint version] of
            [] -> failure (ownerName ++ " requires " ++ name ++ " " ++ range ++ ", but " ++ case candidates of
              [(p, _)] -> "version " ++ packageVersion p ++ " is supplied"
              _ -> "the supplied versions are " ++ intercalate ", " [packageVersion p | (p, _) <- candidates])
            accepted -> pure (keyOf (snd (maximumBy (comparing fst) accepted)))
        pure (owner, chosen)
      let selected = M.fromList selections
          edges k = M.findWithDefault [] k selected
          -- No cycles, and nothing supplied that nothing requires.
          acyclic path k = forM_ (edges k) $ \m -> do
            when (m `elem` path) (failure ("package dependency cycle: " ++ intercalate " -> " (map fst (reverse (m : path)))))
            acyclic (m : path) m
      forM_ keys $ \k -> acyclic [k] k
      let reachable = go [] (edges rootKey)
            where go seen [] = seen
                  go seen (k : rest) | k `elem` seen = go seen rest
                                     | otherwise = go (k : seen) (edges k ++ rest)
      forM_ keys $ \k -> unless (k `elem` reachable)
        (failure (label k ++ " is supplied but not required by the project or its dependencies"))
      -- Units stay in their package's namespace.
      rootUnits <- forM sources unitOf
      packageUnits <- forM packages $ \p -> do
        units <- forM (packageSources p) unitOf
        forM_ units $ \u -> unless (within (packageName p) u)
          (failure ("unit " ++ u ++ " of package " ++ packageName p ++ " must be named " ++ packageName p ++ " or " ++ packageName p ++ ".<name>"))
        pure (p, units)
      forM_ rootUnits $ \u -> do
        forM_ (M.keys byName) $ \n -> when (within n u)
          (failure ("unit " ++ u ++ " is in the namespace of package " ++ n ++ "; project units need their own names"))
        forM_ (projectPackage project) $ \(name, _) -> unless (within name u)
          (failure ("unit " ++ u ++ " of package " ++ name ++ " must be named " ++ name ++ " or " ++ name ++ ".<name>"))
      -- The names a package's units are compiled under.
      let rename (n, v) u
            | several n && within n u = n ++ "." ++ versionSegment v ++ drop (length n) u
            | otherwise = u
          -- An import from a package's unit names its own package or one of
          -- its dependencies; the longest package name that holds it wins.
          retarget k u = case sortOn (negate . length . fst) [d | d <- k : edges k, not (null (fst d)), within (fst d) u] of
            d : _ -> rename d u
            [] -> u
          rewrite k source
            | all (not . several) (fst k : map fst (edges k)) = source
            | otherwise = source { content = rewriteUnit (rename k) (retarget k) (content source) }
          compiled = [(k, rewrite k source) | p <- packages, let k = keyOf p, source <- packageSources p] ++
            [(rootKey, rewrite rootKey source) | source <- sources]
          renamedUnits = [(p, map (rename (keyOf p)) units) | (p, units) <- packageUnits]
          owner = M.fromList ([(u, rootKey) | u <- rootUnits] ++ [(u, keyOf p) | (p, units) <- renamedUnits, u <- units])
          visible importer imported = case (M.lookup importer owner, M.lookup imported owner) of
            (Just from, Just to)
              | from == to || to `elem` edges from -> Nothing
              | fst from == fst to -> Just (imported ++ " belongs to " ++ label to ++ ", but " ++ label from ++ " uses another version")
              | otherwise -> Just (imported ++ " belongs to " ++ label to ++ ", which is not a dependency of " ++ label from)
            _ -> Nothing
      pure (map snd compiled, visible, renamedUnits)
  where
    failure message = Left [Diagnostic "package" message Nothing]
    keyOf p = (packageName p, packageVersion p)
    validName name = unless (qualifiedName name && name /= "prelude" && not ("prelude." `isPrefixOf` name))
      (failure ("invalid package name: " ++ show name ++ "; use a qualified name such as acme.money"))
    versionOf name version = either (\m -> failure ("package " ++ name ++ ": invalid version " ++ show version ++ ": " ++ m)) pure (parseVersion version)
    unitOf source = either (const (Left [Diagnostic "parse" ("cannot read the unit name of " ++ path source) Nothing])) pure (sourceUnit source)
    within name u = u == name || (name ++ ".") `isPrefixOf` u

-- Diagnostics name a versioned unit as its own name and the package version,
-- so a mismatch between two versions reads shop.money::type::Money
-- (shop.money 2.1.0) and shop.money::type::Money (shop.money 1.4.0).
versionedDiagnostics :: [(Package, [String])] -> [Diagnostic] -> [Diagnostic]
versionedDiagnostics described
  | M.null renamed = id
  | otherwise = map (\d -> d { message = rewrite (message d) })
  where
    renamed = M.fromList
      [ (u, (n ++ drop (length n + 1 + length segment) u, n ++ " " ++ packageVersion p))
      | (p, units) <- described, let n = packageName p, let segment = versionSegment (packageVersion p)
      , u <- units, (n ++ "." ++ segment) `isPrefixOf` u ]
    rewrite [] = []
    rewrite text@(c : rest)
      | identifier c = let (token, after) = span identifier text in describe token ++ rewrite after
      | otherwise = c : rewrite rest
    identifier c = isAlphaNum c || c `elem` ("_.:" :: String)
    describe token = case breakOn "::" token of
      (u, qualified) | Just (original, version) <- M.lookup u renamed -> original ++ qualified ++ " (" ++ version ++ ")"
      _ -> token
    breakOn separator s = case s of
      [] -> ([], [])
      _ | separator `isPrefixOf` s -> ([], s)
      x : xs -> let (a, b) = breakOn separator xs in (x : a, b)

-- The unit-name segment of a version: 1.2.0 is v1_2_0, 2.0.0-beta.1 is
-- v2_0_0_beta_1.
versionSegment :: String -> String
versionSegment v = 'v' : map (\c -> if isAlphaNum c then c else '_') v

-- Renames the unit line and the targets of the import lines of a source,
-- giving each rewritten import its old alias explicitly.
rewriteUnit :: (String -> String) -> (String -> String) -> String -> String
rewriteUnit renameUnit retarget = unlines . go False . lines
  where
    go _ [] = []
    go named (line : rest) = case words' line of
      Just ("unit", indent, name, after) | not named -> (indent ++ "unit " ++ renameUnit name ++ after) : go True rest
      Just ("import", indent, name, after)
        | retarget name /= name ->
            let alias = if take 3 (dropWhile (== ' ') after) == "as " then "" else " as " ++ baseOf name
            in (indent ++ "import " ++ retarget name ++ alias ++ after) : go named rest
      _ -> line : go named rest
    words' line =
      let (indent, body) = span (== ' ') line
          (keyword, afterKeyword) = span isAlpha body
          (gap, afterGap) = span (== ' ') afterKeyword
          (name, after) = span (\c -> isAlphaNum c || c == '_' || c == '.') afterGap
      in if keyword `elem` ["unit", "import"] && not (null gap) && not (null name)
           then Just (keyword, indent, name, after) else Nothing
    baseOf name = reverse (takeWhile (/= '.') (reverse name))

qualifiedName :: String -> Bool
qualifiedName name = not (null parts) && all segment parts
  where
    parts = split name
    segment (c : cs) = isAlpha c && all (\x -> isAlphaNum x || x == '_') cs
    segment [] = False
    split s = case break (== '.') s of
      (a, _ : rest) -> a : split rest
      (a, []) -> [a]

packagesView :: Project -> [(Package, [String])] -> [(Key, Value)]
packagesView project described
  | null described && projectPackage project == Nothing && M.null (projectDependencies project) = []
  | otherwise =
      [ "packages" .= [object
          [ "name" .= packageName p, "version" .= packageVersion p
          , "dependencies" .= packageDependencies p, "units" .= sort units ] | (p, units) <- described]
      , "project" .= object
          ([ "package" .= object ["name" .= n, "version" .= v] | Just (n, v) <- [projectPackage project] ] ++
           [ "dependencies" .= projectDependencies project ]) ]

-- Semantic versions: MAJOR.MINOR.PATCH with an optional -prerelease, which
-- orders before the release.
data Version = Version Integer Integer Integer (Maybe String) deriving (Eq, Show)

instance Ord Version where
  compare (Version a b c p) (Version x y z q) = compare (a, b, c) (x, y, z) <> prerelease p q
    where prerelease Nothing Nothing = EQ
          prerelease Nothing (Just _) = GT
          prerelease (Just _) Nothing = LT
          prerelease (Just l) (Just r) = compare (identifiers l) (identifiers r)
          identifiers s = map identifier (splitOn '.' s)
          identifier i = if not (null i) && all isDigit i then Left (read i :: Integer) else Right i

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
    number s | not (null s) && all isDigit s && (s == "0" || take 1 s /= "0") = Right (read s)
             | otherwise = Left ("invalid version number " ++ show s)

-- A range is whitespace-separated comparators, all of which must hold:
-- 1.2.3 (exactly), ^1.2.3, ~1.2.3, >=, >, <=, < and *.
data Comparator = AtLeast Version | Above Version | AtMost Version | Below Version | Exactly Version
  deriving (Eq, Show)

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

-- Prerelease versions satisfy a range only when a comparator names a
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
