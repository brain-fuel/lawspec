-- | Groovy runs over Java, as C# runs over F#: the program's model (data
-- types as records and sealed interfaces, codecs, ability interfaces,
-- checked definitions, schema, actors, sessions, mailboxes and the network)
-- is the Java target's, which Gradle compiles jointly with the Groovy
-- sources. The adapters a user writes are Groovy classes, type-checked with
-- @CompileStatic, and the laws are Spock specifications whose properties
-- run on JetCheck. ref:DEC-groovy-over-java ref:DEC-groovy-property-library
module LawSpec.Groovy.Emit (groovyFromJava, groovyLayout, groovyTestTitle, groovySourceDirectory, groovyTestDirectory) where

import Data.Char (isAlphaNum, isDigit, isUpper, toLower, toUpper)
import Data.List (isInfixOf, isSuffixOf, stripPrefix)
import Data.Maybe (listToMaybe)
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..), Diagnostic(..), mapArtifactContent)
import LawSpec.Testing (Plan(..), PlannedUnit(..), PlannedProperty(..))
import LawSpec.TestNames (unitTestNames, lawWords, kindSuffix)
import LawSpec.Groovy.Source (groovyLiterals, idiomaticGroovy)
import LawSpec.Groovy.Spock (spockSpecification, specClassName, needsJavaBody, javaBodySpecification)
import LawSpec.GroovySources (groovySource)

groovySourceDirectory, groovyTestDirectory :: String
groovySourceDirectory = "src/main/groovy"
groovyTestDirectory = "src/test/groovy"

-- | The Groovy project from the Java target's files for the same plan.
groovyFromJava :: Plan -> [Artifact] -> Either [Diagnostic] [Artifact]
groovyFromJava plan javaFiles = do
  let converted = concatMap convert javaFiles
      ordered = any ((== "src/test/java/lawspec/testing/LawSpecOrder.java") . artifactPath) javaFiles
      parallel = any ((== "src/test/resources/junit-platform.properties") . artifactPath) javaFiles
      runtime = any (("lawspec.testing.LawSpecGroovy." `isInfixOf`) . artifactContent) converted
  -- Resolve tail decisions before exposing the converted stream. Otherwise
  -- their thunks retain every original Java character until the last file has
  -- been consumed, alongside the complete converted project.
  ordered `seq` parallel `seq` runtime `seq` pure (converted ++
    [ Artifact "src/test/groovy/lawspec/testing/LawSpecGroovy.groovy" (groovySource "LawSpecGroovy.groovy") "generated" "test"
    | runtime ] ++
    [ Artifact "src/test/groovy/lawspec/testing/LawSpecRandomOrder.groovy" (groovySource "LawSpecRandomOrder.groovy") "generated" "test" | ordered ] ++
    [ Artifact "src/test/resources/SpockConfig.groovy" (groovySource "SpockConfig.groovy") "generated" "test" | parallel ])
  where
    convert a
      | path `elem` ["src/test/java/lawspec/testing/LawSpecOrder.java", "src/test/resources/junit-platform.properties"] = []
      | ownership a == "user", Just rest <- stripPrefix "src/main/java/" path, ".java" `isSuffixOf` rest =
          [(mapArtifactContent idiomaticGroovy a) { artifactPath = groovySourceDirectory ++ "/" ++ groovyFile rest }]
      | Just rest <- stripPrefix "src/test/java/" path, ".java" `isSuffixOf` rest, "@Test" `isInfixOf` artifactContent a =
          let className = takeWhile (/= '.') (reverse (takeWhile (/= '/') (reverse rest)))
              directory = take (length rest - length className - 5) rest
              (body, specification) = javaBodySpecification className (title path) (artifactContent a)
              bodyArtifact = a { artifactPath = "src/test/java/" ++ directory ++ className ++ "Body.java", artifactContent = body }
              specificationArtifact = a { artifactPath = groovyTestDirectory ++ "/" ++ directory ++ specClassName className ++ ".groovy",
                                          artifactContent = specification }
          in if needsJavaBody (artifactContent a)
             -- Materialize both records before exposing the first. A deferred
             -- record update for the wrapper would otherwise retain a's
             -- original Java content until after the complete body is emitted.
             then bodyArtifact `seq` specificationArtifact `seq` [bodyArtifact, specificationArtifact]
             else [a { artifactPath = groovyTestDirectory ++ "/" ++ directory ++ specClassName className ++ ".groovy"
                     , artifactContent = spockSpecification className (title path) (groovyLiterals (artifactContent a)) }]
      | otherwise = [a]
      where path = artifactPath a
    groovyFile rest = take (length rest - 5) rest ++ ".groovy"
    -- A unit's test methods are named after its laws (LawSpec.TestNames).
    title path name = maybe (spaced name) (\u -> groovyTestTitle u name)
      (listToMaybe [pu | pu <- plannedUnits plan, javaTestPath (C.idText (C.unitId (plannedUnit pu))) == path])

-- | A project's own source and test directories, when it names them: the
-- Java model and the Groovy sources move together, as Gradle compiles them
-- jointly from one source set.
groovyLayout :: Maybe String -> Maybe String -> [Artifact] -> [Artifact]
groovyLayout sourceDir testDir = map move
  where
    move a = maybe a (\p -> a { artifactPath = p }) (relocate (artifactPath a))
    relocate path =
      listToMaybe [ d ++ "/" ++ rest | (Just d, bases) <- [(sourceDir, ["src/main/groovy/", "src/main/java/"]), (testDir, ["src/test/groovy/", "src/test/java/"])]
                  , base <- bases, Just rest <- [stripPrefix base path] ]

-- | The feature a Java test method becomes: the law's words, a colon and
-- the kind of test (example 0, boundary 1, property, skipped, known
-- failing), as lawspec test selects them.
groovyTestTitle :: PlannedUnit -> String -> String
groovyTestTitle pu name =
  case [ g ++ kindSuffix "groovy" kind | (j, g) <- zip (unitTestNames "java" labels) (unitTestNames "groovy" labels)
       , Just ('_' : kind) <- [stripPrefix j name] ] ++
       [ "benchmark: " ++ unwords (lawWords n) | (n, _) <- benchmarks, name == "benchmark" ++ concatMap capital (lawWords n) ] of
    t : _ -> t
    [] -> spaced name
  where
    labels = map (C.propertyName . plannedProperty) (plannedProperties pu)
    benchmarks = maybe [] C.harnessBenchmarks (C.unitHarnessSettings (plannedUnit pu))
    capital (c : cs) = toUpper c : cs
    capital [] = []

-- | A method name's words: knownFailing is known failing, example0 example 0.
spaced :: String -> String
spaced = unwords . words . go
  where
    go (a : b : rest) | isAlphaNum a && not (isDigit a) && isDigit b = toLower a : ' ' : go (b : rest)
    go (c : rest)
      | isUpper c = ' ' : toLower c : go rest
      | c == '_' = ' ' : go rest
      | otherwise = c : go rest
    go [] = []

-- The Java test file of a unit (LawSpec.TestManifest's for Java).
javaTestPath :: String -> String
javaTestPath unit = "src/test/java/" ++ concatMap (++ "/") (init parts) ++ capitalWords (last parts) ++ "LawSpecTest.java"
  where
    parts = splitOn '.' unit
    capitalWords = concatMap capital . splitOn '_'
    capital (c : rest) = toUpper c : rest
    capital [] = []
    splitOn c s = case break (== c) s of
      (a, []) -> [a]
      (a, _ : b) -> a : splitOn c b
