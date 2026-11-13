-- | A target's build options that change where generated files go and which
-- language release they must compile at, never the checked program:
-- lawspec.edn's :generated-source-dir, :generated-test-dir and :release.
--
-- Placement by ownership follows the established build-tool convention of a
-- separate generated source root (Maven's target/generated-sources/<tool>,
-- registered by build-helper-maven-plugin; Gradle's sourceSets srcDir): files
-- the compiler owns go there, files the user owns stay in the source tree.
-- The host only writes the paths this module decides.
-- ref:DEC-adapter-ownership
module LawSpec.TargetOptions
  ( TargetOptions (..),
    noTargetOptions,
    targetOptions,
    placeByOwnership,
    generatedTestDirectory,
    releaseProblems,
    javaReleases,
    defaultJavaRelease,
    newerJavaUnits,
  )
where

import Control.Applicative ((<|>))
import Data.Char (isAlphaNum, toLower)
import Data.List (intercalate, isPrefixOf, nub, stripPrefix)
import LawSpec.Common (Artifact (..))
import LawSpec.OutputLayout (defaultDirectories)

data TargetOptions = TargetOptions
  { generatedSourceDir :: Maybe FilePath,
    generatedTestDir :: Maybe FilePath,
    targetRelease :: Maybe Int
  }
  deriving (Eq, Show)

noTargetOptions :: TargetOptions
noTargetOptions = TargetOptions Nothing Nothing Nothing

-- | The Java releases generated code is compiled and tested at. 25 is the
-- default; 21 is the earlier LTS.
javaReleases :: [Int]
javaReleases = [21, 25]

defaultJavaRelease :: Int
defaultJavaRelease = 25

-- | Units whose Java handlers call JDK APIs newer than release 21, with the
-- first release that has them. lawspec.crypto and lawspec.network use the
-- JDK's ML-KEM and ML-DSA (JEP 496 and JEP 497, JDK 24).
newerJavaUnits :: [(String, Int, String)]
newerJavaUnits =
  [ ("lawspec.crypto", 24, "the JDK's ML-KEM and ML-DSA"),
    ("lawspec.network", 24, "the JDK's ML-KEM and ML-DSA")
  ]

-- | The options a request gives for a target, or every reason they cannot be
-- used. Each argument is Nothing when absent, Just Nothing when it has the
-- wrong type. Layout directories are checked against the target's source and
-- test directories, because javac treats each root as a package root and one
-- root inside another would compile a file twice.
targetOptions ::
  String ->
  Maybe FilePath ->
  Maybe FilePath ->
  Maybe (Maybe FilePath) ->
  Maybe (Maybe FilePath) ->
  Maybe (Maybe Int) ->
  Either [(String, String)] TargetOptions
targetOptions target sourceDir testDir generatedSource generatedTests release =
  if null problems
    then Right (TargetOptions (given generatedSource) (given generatedTests) (given release))
    else Left problems
  where
    given = (>>= id)
    problems =
      concat
        [ layout (directory "generatedSourceDir" generatedSource),
          layout (directory "generatedTestDir" generatedTests),
          layout
            [ "generatedSourceDir and generatedTestDir are supported by the java target only; "
                ++ target
                ++ " keeps generated and user-owned files in sourceDir and testDir"
            | target /= "java",
              any present [generatedSource, generatedTests]
            ],
          layout
            [ a ++ " (" ++ x ++ ") and " ++ b ++ " (" ++ y ++ ") must be separate directories, neither inside the other"
            | target == "java",
              (i, (a, x)) <- roots,
              (j, (b, y)) <- roots,
              i < j,
              a `elem` generatedNames || b `elem` generatedNames,
              within x y || within y x
            ],
          map ((,) "release") $ case release of
            Nothing -> []
            Just Nothing -> ["release must be an integer, such as 21"]
            Just (Just value)
              | target /= "java" -> ["release is supported by the java target only"]
              | value `notElem` javaReleases ->
                  ["release " ++ show value ++ " is not supported for java; choose " ++ intercalate " or " (map show javaReleases)]
              | otherwise -> []
        ]
    layout = map ((,) "layout")
    present = maybe False (const True)
    generatedNames = ["generatedSourceDir", "generatedTestDir"]
    defaults = defaultDirectories target
    roots =
      zip
        [0 :: Int ..]
        ( [("sourceDir", maybe (fst defaults) id sourceDir), ("testDir", maybe (snd defaults) id testDir)]
            ++ [("generatedSourceDir", d) | Just (Just d) <- [generatedSource], safe d]
            ++ [("generatedTestDir", d) | Just (Just d) <- [generatedTests], safe d]
        )
    within x y = map toLower x == map toLower y || (map toLower x ++ "/") `isPrefixOf` map toLower y
    directory _ Nothing = []
    directory name (Just Nothing) = [name ++ " must be a relative directory path"]
    directory name (Just (Just value)) =
      [name ++ " must be a relative directory path without traversal" | not (safe value)]

-- The same rule CoreEmit applies to sourceDir and testDir.
safe :: FilePath -> Bool
safe value =
  not (null value)
    && all
      (\part -> not (null part) && part /= "." && part /= ".." && all (\c -> isAlphaNum c || c `elem` ("_-" :: String)) part)
      (parts value)
  where
    parts text = case break (== '/') text of
      (part, []) -> [part]
      (part, _ : rest) -> part : parts rest

-- | Moves the files LawSpec owns from the source and test directories to the
-- generated ones, and generated test resources beside the generated tests.
-- User-owned adapters and generator factories keep their paths, and so do
-- generated files outside those directories.
placeByOwnership :: String -> Maybe FilePath -> Maybe FilePath -> TargetOptions -> [Artifact] -> Either String [Artifact]
placeByOwnership target sourceDir testDir options artifacts
  | generatedSourceDir options == Nothing && generatedTestDir options == Nothing = Right artifacts
  | length placed /= length (nub (map (map toLower . artifactPath) placed)) =
      Left "generated directories cause an output collision"
  | otherwise = Right placed
  where
    defaults = defaultDirectories target
    source = maybe (fst defaults) id sourceDir
    tests = maybe (snd defaults) id testDir
    placed = map move artifacts
    move artifact
      | ownership artifact /= "generated" = artifact
      | artifactPlacement artifact == "source" = relocate source (generatedSourceDir options) artifact
      | artifactPlacement artifact == "test" = relocate tests (generatedTestDir options) artifact
      | otherwise = artifact
    relocate _ Nothing artifact = artifact
    relocate from (Just to) artifact =
      case stripPrefix (from ++ "/") (artifactPath artifact) <|> stripPrefix testResources (artifactPath artifact) of
        Just rest -> artifact {artifactPath = to ++ "/" ++ rest}
        Nothing -> artifact
    -- JUnit's configuration, which a harness generates: the generated test
    -- directory is registered as a test resource root as well.
    testResources = "src/test/resources/"

-- | Generated tests are what the test manifest lists, so it reads the
-- generated test directory when one is set.
generatedTestDirectory :: Maybe FilePath -> TargetOptions -> Maybe FilePath
generatedTestDirectory testDir options = generatedTestDir options <|> testDir

-- | Why a program cannot be generated at the chosen release: each unit whose
-- Java handlers need a newer JDK API, with the release that has it.
releaseProblems :: String -> TargetOptions -> [String] -> [String]
releaseProblems "java" options units =
  [ "unit "
      ++ unit
      ++ " requires Java release "
      ++ show minimum'
      ++ " or later ("
      ++ reason
      ++ "); this target sets release "
      ++ show release
      ++ ". Set :release "
      ++ show defaultJavaRelease
      ++ " on this target"
  | Just release <- [targetRelease options],
    (unit, minimum', reason) <- newerJavaUnits,
    unit `elem` units,
    release < minimum'
  ]
releaseProblems _ _ _ = []
