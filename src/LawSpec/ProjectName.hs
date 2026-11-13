-- | The names lawspec init gives a project's build files. One logical name is
-- chosen (an option, an existing build file, the manifest or the directory)
-- and written the way each target's build tool expects it. The host reads
-- files and passes text; every rule is here. ref:DEC-scaffold-project-name
module LawSpec.ProjectName
  ( ProjectNames (..),
    NameSource (..),
    Project (..),
    exampleProject,
    projectNames,
    resolveProject,
    buildFileName,
    portableName,
    groupTargets,
    nameLimit,
  )
where

import Data.Aeson (Value (..), decode)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as B
import Data.Char (isAlphaNum, isAscii, isDigit, isLower, isSpace, isUpper, toLower)
import Data.List (intercalate, isPrefixOf, isSuffixOf, stripPrefix, tails)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import LawSpec.Naming (Casing (..), cased, nameWords)
import LawSpec.TargetNames (targetKeywords)
import LawSpec.Targets (artifactTargets)

-- | One project's name in each spelling a build file uses.
data ProjectNames = ProjectNames
  { -- | npm, Cargo, pyproject, Maven artifactId, Gradle root project, Stack.
    projectPackage :: String,
    -- | The Erlang and Mix application and the Gleam package.
    projectAtom :: String,
    -- | The .NET solution, projects and root namespace, and the Swift package.
    projectType :: String,
    -- | The module that holds the Mix project.
    projectModule :: String,
    -- | The Erlang application's description.
    projectDescription :: String,
    -- | Maven's groupId.
    projectGroup :: String,
    -- | Gradle's group, written only when one was given.
    projectGradleGroup :: Maybe String,
    projectGoModule :: String
  }
  deriving (Eq, Show)

-- | The project of the examples corpus, Learn, the documentation samples and
-- the acceptance suites, whose fixtures spell these names. They predate the
-- derivation below and are kept as they were.
exampleProject :: ProjectNames
exampleProject =
  ProjectNames
    { projectPackage = "lawspec-example",
      projectAtom = "lawspec_example",
      projectType = "Example",
      projectModule = "LawSpecExample",
      projectDescription = "LawSpec example",
      projectGroup = "example",
      projectGradleGroup = Nothing,
      projectGoModule = "example.com/lawspec-example"
    }

-- | Where the logical name came from, in the order init looks.
data NameSource = FromOption | FromBuildFile FilePath | FromManifest | FromDirectory
  deriving (Eq, Show)

-- | Cargo's limit on a package name, the tightest any target documents. It is
-- applied to every target so that one name is valid wherever it is used.
nameLimit :: Int
nameLimit = 64

-- | The targets whose build files have a group: Maven's groupId, Gradle's
-- group and the leading elements of a Go module path.
groupTargets :: [String]
groupTargets = ["java", "kotlin", "groovy", "go"]

-- | What init learns about the project it is naming.
data Project = Project
  { projectSource :: NameSource,
    -- | The logical name, as it was found.
    projectName :: String,
    -- | The component name a new manifest takes.
    projectComponent :: String,
    projectBuildNames :: ProjectNames,
    -- | The name as the target's build files write it and where it came
    -- from, for init's report. Nothing when they carry no name.
    projectSummary :: Maybe String
  }
  deriving (Eq, Show)

-- | Targets whose build files carry no project name: the artifact targets
-- write none, Scala CLI's directives and deps.edn have no name field.
unnamedTargets :: [String]
unnamedTargets = artifactTargets ++ ["scala", "clojure"]

-- | The first name found among --name, a build file already in the target's
-- root, the manifest's component or package, and the directory.
resolveProject ::
  String ->
  Maybe String ->
  Maybe String ->
  [(FilePath, String)] ->
  Maybe String ->
  String ->
  Either String Project
resolveProject target option group files manifest directory = either (Left . explain) Right $ do
  names <-
    if target `elem` unnamedTargets
      then exampleProject <$ traverse (checkedGroup target) group
      else projectNames target group name
  component <- case portableName name of
    "" -> Left "has no letter or digit to make a name from"
    found -> Right found
  Right
    Project
      { projectSource = source,
        projectName = name,
        projectComponent = component,
        projectBuildNames = names,
        projectSummary =
          if target `elem` unnamedTargets
            then Nothing
            else Just ("Project name: " ++ written names ++ " (from " ++ origin ++ ").")
      }
  where
    (source, name) = case (option, buildFileName files, manifest) of
      (Just given, _, _) -> (FromOption, given)
      (_, Just (file, found), _) -> (FromBuildFile file, found)
      (_, _, Just found) -> (FromManifest, found)
      _ -> (FromDirectory, directory)
    explain problem
      | "--group" `isPrefixOf` problem = problem
      | otherwise = subject ++ " " ++ show name ++ " " ++ problem ++ remedy
    (subject, origin) = case source of
      FromOption -> ("--name", "--name")
      FromBuildFile file -> ("the project name in " ++ file ++ ",", file)
      FromManifest -> ("the name in lawspec.edn,", "lawspec.edn")
      FromDirectory -> ("the directory name", "the directory name")
    remedy = if source == FromOption then "" else "; give the project's name with --name"
    written names
      | target == "java" = projectGroup names ++ ":" ++ projectPackage names
      | target == "go" = projectGoModule names
      | target `elem` ["erlang", "elixir", "gleam"] = projectAtom names
      | target `elem` ["fsharp", "csharp", "swift"] = projectType names
      | otherwise = projectPackage names

-- | A logical name in every spelling the target's build files use, or why it
-- cannot be one. Words come from LawSpec.Naming.nameWords, so billing-service,
-- billing_service, BillingService and "Billing Service" are one name, and
-- characters outside ASCII letters and digits separate words.
projectNames :: String -> Maybe String -> String -> Either String ProjectNames
projectNames target group source = do
  given <- traverse (checkedGroup target) group
  found <- case nameWords source of
    [] -> Left "has no ASCII letter or digit to make a build name from"
    ws -> Right ws
  let ws = usable target found
      package = cased Kebab (if target == "haskell" then cabalComponents ws else ws)
      longest = maximum (map length [package, cased Snake ws])
  if longest > nameLimit
    then
      Left
        ( "is too long: it is "
            ++ show longest
            ++ " characters as "
            ++ show package
            ++ ", and a build name may have "
            ++ show nameLimit
        )
    else
      Right
        ProjectNames
          { projectPackage = package,
            projectAtom = cased Snake ws,
            projectType = cased Pascal ws,
            projectModule = cased Pascal ws,
            projectDescription = package,
            projectGroup = fromMaybe (packageSegment found) given,
            projectGradleGroup = given,
            projectGoModule = fromMaybe "example.com" given ++ "/" ++ package
          }

-- | The words as the target can use them. A name the build tool refuses gets
-- the word project: before a leading digit where a name must begin with a
-- letter, and after a name the target reserves.
usable :: String -> [String] -> [String]
usable target = reserved . lettered
  where
    lettered ws
      | target `elem` letterFirst, startsWithDigit ws = "project" : ws
      -- Gleam keeps the gleam_ prefix for its own packages.
      | target == "gleam", take 1 ws == ["gleam"] = "project" : ws
      | otherwise = ws
    reserved ws
      | concat ws `elem` map (map toLower . filter isAlphaNum) (reservedNames target) = ws ++ ["project"]
      | otherwise = ws
    letterFirst = ["rust", "haskell", "erlang", "elixir", "gleam", "fsharp", "csharp", "swift"]

startsWithDigit :: [String] -> Bool
startsWithDigit ws = any isDigit (take 1 (concat ws))

-- | Cabal requires a letter in every hyphen-separated part of a package name,
-- so a part made of digits joins the part before it: app-2 is app2.
cabalComponents :: [String] -> [String]
cabalComponents = foldl join []
  where
    join parts word
      | all isDigit word, not (null parts) = init parts ++ [last parts ++ word]
      | otherwise = parts ++ [word]

-- | A name as one Java package segment, by the convention of The Java
-- Language Specification 6.1: underscores for the characters a package name
-- cannot hold, and the same extra word as above for a digit or a keyword.
packageSegment :: [String] -> String
packageSegment ws
  | segment `elem` targetKeywords "java" = segment ++ "_project"
  | otherwise = segment
  where
    segment = cased Snake (if startsWithDigit ws then "project" : ws else ws)

-- | Names a target's build cannot give a project: the words its build tool
-- reserves and the packages the scaffold depends on, which a project of the
-- same name would hide or depend on in a cycle.
reservedNames :: String -> [String]
reservedNames target = case target of
  "javascript" -> words "lawspec fast-check node_modules"
  "typescript" -> words "lawspec fast-check typescript node_modules"
  "python" -> python
  "prolog" -> "janus-swi" : python
  "rust" ->
    targetKeywords "rust"
      ++ words "test core std alloc proc-macro build deps examples incremental proptest num-bigint num-rational num-complex num-traits"
      ++ windowsDevices
  "go" -> windowsDevices
  "haskell" -> words "base text bytestring containers network directory time hspec hedgehog hspec-hedgehog hspec-discover mtl"
  "erlang" -> erlang ++ words "kernel stdlib crypto proper eunit"
  "elixir" -> words "elixir mix logger ex_unit iex eex kernel stdlib crypto stream_data"
  "gleam" -> erlang ++ words "gleeunit qcheck lawspec_test_support as assert auto const delegate derive echo else fn implement import macro opaque panic pub test todo type use"
  "fsharp" -> dotnet
  "csharp" -> dotnet
  _ -> []
  where
    python = words "lawspec pytest hypothesis setuptools cryptography pip test tests"
    erlang = words "after and andalso band begin bnot bor bsl bsr bxor case catch cond div end fun if let maybe not of or orelse receive rem try when xor"
    dotnet = words "LawSpec System Microsoft FSharp Xunit FsCheck Tests"
    windowsDevices = words "con prn aux nul" ++ [device ++ show n | device <- ["com", "lpt"], n <- [1 .. 9 :: Int]]

-- | A group is written by its owner and is checked, never re-spelled.
checkedGroup :: String -> String -> Either String String
checkedGroup target group
  | target `notElem` groupTargets =
      Left ("--group applies to the " ++ intercalate ", " (init groupTargets) ++ " and " ++ last groupTargets ++ " targets; a " ++ target ++ " build file has no group")
  | target == "go" =
      if all element elements && '.' `elem` concat (take 1 elements)
        then Right group
        else refuse "is not the start of a Go module path; write a host and path such as github.com/acme"
  | all segment (splitOn '.' group) = Right group
  | otherwise = refuse "is not a Java package name; write dot-separated identifiers such as com.acme.billing"
  where
    refuse problem = Left ("--group " ++ show group ++ " " ++ problem)
    elements = splitOn '/' group
    element part =
      not (null part)
        && all (\c -> isAscii c && (isAlphaNum c || c `elem` ("-._~" :: String))) part
        && take 1 part /= "."
        && take 1 (reverse part) /= ""
    segment part =
      not (null part)
        && all (\c -> isAscii c && (isAlphaNum c || c == '_')) part
        && not (any isDigit (take 1 part))
        && part `notElem` targetKeywords "java"

-- | The name a new manifest's component takes: the name as given when the
-- manifest admits it (LawSpec.Service.Manifest's portable name), otherwise
-- its kebab-case spelling.
portableName :: String -> String
portableName name
  | not (null name), all (\c -> isAlphaNum c || c `elem` ("._-" :: String)) name = name
  | otherwise = cased Kebab (nameWords name)

-- | The project name an existing build file declares. The files are tried in
-- a fixed order, so the answer does not depend on the order they were read.
buildFileName :: [(FilePath, String)] -> Maybe (FilePath, String)
buildFileName files =
  listToMaybe
    [ (file, name)
      | (matches, reader) <- readers,
        (file, content) <- files,
        matches file,
        Just name <- [reader file content],
        not (null (nameWords name))
    ]
  where
    readers =
      [ ((== "package.json"), const packageJson),
        ((== "Cargo.toml"), const (tomlName "package")),
        ((== "pyproject.toml"), const (tomlName "project")),
        ((== "pom.xml"), const pomArtifact),
        ((`elem` ["settings.gradle.kts", "settings.gradle"]), const (after "rootProject.name" quoted)),
        ((== "go.mod"), const goModule),
        ((== "mix.exs"), const (after "app:" atom)),
        ((== "gleam.toml"), const (tomlName "")),
        ((== "package.yaml"), const (field "name:")),
        ((".cabal" `isSuffixOf`), const (field "name:")),
        ((\file -> any (`isSuffixOf` file) [".slnx", ".sln"]), \file _ -> Just (baseName file)),
        ((== "Package.swift"), const (after "Package(" (after "name:" quoted)))
      ]
    baseName = reverse . drop 1 . dropWhile (/= '.') . reverse

-- | npm's name; a scope (@acme/billing) is the registry's, not the project's.
packageJson :: String -> Maybe String
packageJson content = case decode (B.fromStrict (TE.encodeUtf8 (T.pack content))) of
  Just (Object fields) | Just (String name) <- KM.lookup "name" fields -> Just (last (splitOn '/' (T.unpack name)))
  _ -> Nothing

-- | name = "..." in one table of a TOML file ("" is the top of the file).
tomlName :: String -> String -> Maybe String
tomlName table = go "" . map (dropWhile isSpace) . lines
  where
    go _ [] = Nothing
    go current (line : rest)
      | '[' : header <- line = go (takeWhile (/= ']') header) rest
      | current == table,
        Just value <- stripPrefix "name" line,
        '=' : text <- dropWhile isSpace value =
          quoted text
      | otherwise = go current rest

-- | The artifactId that is a child of project itself, not of its parent,
-- dependencies or plugins.
pomArtifact :: String -> Maybe String
pomArtifact = go []
  where
    go :: [String] -> String -> Maybe String
    go _ [] = Nothing
    go open ('<' : '!' : '-' : '-' : rest) = go open (skipComment rest)
    go open ('<' : '/' : rest) = go (drop 1 open) (drop 1 (dropWhile (/= '>') rest))
    go open ('<' : '?' : rest) = go open (drop 1 (dropWhile (/= '>') rest))
    go open ('<' : rest) =
      let (tag, more) = break (== '>') rest
          name = takeWhile (\c -> not (isSpace c) && c /= '/') tag
          body = drop 1 more
       in if "/" `isSuffixOf` tag
            then go open body
            else
              if name == "artifactId" && open == ["project"]
                then Just (trim (takeWhile (/= '<') body))
                else go (name : open) body
    go open (_ : rest) = go open rest
    skipComment text@(_ : rest)
      | "-->" `isPrefixOf` text = drop 3 text
      | otherwise = skipComment rest
    skipComment [] = []

-- | The last element of the module path, or the one before a major version.
goModule :: String -> Maybe String
goModule content =
  listToMaybe
    [ element
      | line <- lines content,
        "module" : path : _ <- [words line],
        let elements = filter (not . null) (splitOn '/' (filter (/= '"') path)),
        element <- take 1 (dropWhile majorVersion (reverse elements))
    ]
  where
    majorVersion ('v' : digits) = not (null digits) && all isDigit digits
    majorVersion _ = False

-- | The value on the first line that starts with a key (package.yaml, .cabal).
field :: String -> String -> Maybe String
field key content =
  listToMaybe
    [ filter (`notElem` ("\"'" :: String)) (trim (drop (length key) line))
      | line <- lines content,
        map toLower (take (length key) line) == key
    ]

-- | What a parser reads after the first occurrence of a marker.
after :: String -> (String -> Maybe String) -> String -> Maybe String
after marker parser text = listToMaybe (mapMaybe (stripPrefix marker) (tails text)) >>= parser

-- | The first quoted string on the line.
quoted :: String -> Maybe String
quoted text = case dropWhile (`notElem` ("\"'" :: String)) (takeWhile (/= '\n') text) of
  quote : rest | (value, _ : _) <- break (== quote) rest -> Just value
  _ -> Nothing

-- | An Elixir atom literal: :billing_service.
atom :: String -> Maybe String
atom text = case dropWhile isSpace text of
  ':' : rest -> Just (takeWhile (\c -> isAscii c && (isLower c || isUpper c || isDigit c || c == '_')) rest)
  _ -> Nothing

splitOn :: Char -> String -> [String]
splitOn separator text = case break (== separator) text of
  (part, _ : rest) -> part : splitOn separator rest
  (part, []) -> [part]

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace
