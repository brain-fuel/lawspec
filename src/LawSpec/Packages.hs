-- Packages: named, versioned groups of units. A package's units live in its
-- namespace (the package name or names below it), a package names the
-- packages it depends on with version ranges, and a unit may import only
-- units of its own package (or project) and of that package's direct
-- dependencies. Resolution is exact: the request supplies one version of each
-- package, and every range must accept it.
module LawSpec.Packages
  ( Package(..), Project(..), emptyProject, preparePackages, packagesView
  , Version, parseVersion, parseRange, satisfies
  ) where

import LawSpec.Common
import LawSpec.Parser (sourceUnit)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson
import Data.Aeson.Key (Key)
import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.List (intercalate, isPrefixOf, sort)
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
preparePackages :: Project -> [Package] -> [Source] -> Either [Diagnostic] ([Source], String -> String -> Maybe String, [(Package, [String])])
preparePackages project packages sources
  | null packages && M.null (projectDependencies project) && projectPackage project == Nothing =
      pure (sources, \_ _ -> Nothing, [])
  | otherwise = do
      let root = maybe "" fst (projectPackage project)
          rootDependencies = projectDependencies project
      forM_ (maybe [] pure (projectPackage project)) $ \(name, version) -> do
        validName name
        _ <- versionOf name version
        pure ()
      forM_ packages $ \p -> do
        validName (packageName p)
        _ <- versionOf (packageName p) (packageVersion p)
        when (packageName p == root) (failure ("package " ++ root ++ " is also supplied as a dependency"))
      let names = map packageName packages
      forM_ names $ \n -> when (length (filter (== n) names) > 1) (failure ("package supplied more than once: " ++ n))
      let table = M.fromList [(packageName p, p) | p <- packages]
      -- Every range must accept the supplied version.
      forM_ (("the project", rootDependencies) : [(packageName p, packageDependencies p) | p <- packages]) $ \(owner, dependencies) ->
        forM_ (M.toList dependencies) $ \(name, range) -> do
          when (name == owner || Just name == fmap fst (projectPackage project))
            (failure (owner ++ " depends on itself"))
          constraint <- either (\m -> failure (owner ++ ": invalid version range for " ++ name ++ ": " ++ m)) pure (parseRange range)
          p <- maybe (failure (owner ++ " depends on " ++ name ++ " " ++ range ++ ", which is not supplied")) pure (M.lookup name table)
          version <- versionOf (packageName p) (packageVersion p)
          unless (satisfies constraint version)
            (failure (owner ++ " requires " ++ name ++ " " ++ range ++ ", but version " ++ packageVersion p ++ " is supplied"))
      -- No cycles, and nothing supplied that nothing requires.
      let edges n = maybe [] (M.keys . packageDependencies) (M.lookup n table)
          acyclic path n = forM_ (edges n) $ \m -> do
            when (m `elem` path) (failure ("package dependency cycle: " ++ intercalate " -> " (reverse (m : path))))
            acyclic (m : path) m
      forM_ names $ \n -> acyclic [n] n
      let reachable = closure (M.keys rootDependencies)
          closure frontier = go [] frontier
            where go seen [] = seen
                  go seen (n : rest) | n `elem` seen = go seen rest
                                     | otherwise = go (n : seen) (edges n ++ rest)
      forM_ names $ \n -> unless (n `elem` reachable)
        (failure ("package " ++ n ++ " is supplied but not required by the project or its dependencies"))
      -- Units stay in their package's namespace.
      rootUnits <- forM sources unitOf
      packageUnits <- forM packages $ \p -> do
        units <- forM (packageSources p) unitOf
        forM_ units $ \u -> unless (within (packageName p) u)
          (failure ("unit " ++ u ++ " of package " ++ packageName p ++ " must be named " ++ packageName p ++ " or " ++ packageName p ++ ".<name>"))
        pure (p, units)
      forM_ rootUnits $ \u -> do
        forM_ names $ \n -> when (within n u)
          (failure ("unit " ++ u ++ " is in the namespace of package " ++ n ++ "; project units need their own names"))
        forM_ (projectPackage project) $ \(name, _) -> unless (within name u)
          (failure ("unit " ++ u ++ " of package " ++ name ++ " must be named " ++ name ++ " or " ++ name ++ ".<name>"))
      let owner = M.fromList ([(u, root) | u <- rootUnits] ++ [(u, packageName p) | (p, units) <- packageUnits, u <- units])
          dependencies group = if group == root then M.keys rootDependencies else edges group
          label group = if null group then "the project" else "package " ++ group
          visible importer imported = case (M.lookup importer owner, M.lookup imported owner) of
            (Just from, Just to)
              | from == to || to `elem` dependencies from -> Nothing
              | otherwise -> Just (imported ++ " belongs to " ++ label to ++ ", which is not a dependency of " ++ label from)
            _ -> Nothing
      pure (concatMap packageSources packages ++ sources, visible, packageUnits)
  where
    failure message = Left [Diagnostic "package" message Nothing]
    validName name = unless (qualifiedName name && name /= "prelude" && not ("prelude." `isPrefixOf` name))
      (failure ("invalid package name: " ++ show name ++ "; use a qualified name such as acme.money"))
    versionOf name version = either (\m -> failure ("package " ++ name ++ ": invalid version " ++ show version ++ ": " ++ m)) pure (parseVersion version)
    unitOf source = either (const (Left [Diagnostic "parse" ("cannot read the unit name of " ++ path source) Nothing])) pure (sourceUnit source)
    within name u = u == name || (name ++ ".") `isPrefixOf` u

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
