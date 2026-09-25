module LawSpec.CoreEmit (emitPlan, emitPlanWithLayout, targets) where
import LawSpec.Backend
import LawSpec.Common
import LawSpec.Testing
import LawSpec.RustEmit (emitRust)
import qualified LawSpec.CoreScalarEmit as Scalar
import qualified LawSpec.CoreNativeScalarEmit as Native
import LawSpec.RuntimeSources
import Data.Char (toUpper, toLower, isAscii, isAlphaNum)
import Data.List (intercalate, nub, stripPrefix, isPrefixOf, isSuffixOf)
import Control.Monad (unless)

targets :: [String]
targets = ["java","python","javascript","typescript","go","haskell","kotlin","rust"]
split :: Char -> String -> [String]
split c s = case break (==c) s of (a,[]) -> [a]; (a,_:b) -> a:split c b
cap :: String -> String
cap [] = []
cap (a:b) = toUpper a:b
comma :: [String] -> String
comma = intercalate ", "

reserved :: [String]
reserved = words "class interface enum public private protected static return import package module where data type newtype case of if then else let in do forall object fun val var when is as null true false None True False def lambda pass raise from with yield async await export default function const new delete switch throw try catch finally break continue for while match typealias struct func map range select defer go chan int string error assert test"

emitPlan :: String -> Plan -> Either [Diagnostic] [Artifact]
emitPlan "rust" plan = emitRust plan
emitPlan target Plan{..} = do
  unless (target `elem` targets) (Left [Diagnostic "target" ("unknown target: " ++ target) Nothing])
  let units = map plannedUnit plannedUnits
      laws = concatMap plannedProperties plannedUnits
      bad = [n | u <- units,n <- map fst (functions u) ++ split '.' (unitName u),n `elem` reserved || not (all (\c -> isAscii c && (isAlphaNum c || c == '_')) n)]
  unless (null bad) (Left [Diagnostic "identifier" ("reserved target identifier: " ++ comma bad) Nothing])
  emitted <- mapM (emitUnit laws) (filter (\u -> not (null (functions u)) || any ((== unitName u) . owner) laws) units)
  let needsRuntime = not (null emitted)
      runtime = case target of
        "python" -> Artifact "src/lawspec_runtime.py" (runtimeSource "python") "generated" "source"
        "java" -> Artifact "src/main/java/lawspec/runtime/LawSpecRuntime.java" (runtimeSource "java") "generated" "source"
        "kotlin" -> Artifact "src/main/java/lawspec/runtime/LawSpecRuntime.java" (runtimeSource "java") "generated" "source"
        "typescript" -> Artifact "src/lawspec_runtime.ts" ("// @ts-nocheck\n" ++ runtimeSource "javascript") "generated" "source"
        "haskell" -> Artifact "src/LawSpecRuntime.hs" (runtimeSource "haskell") "generated" "source"
        _ -> Artifact "src/lawspec_runtime.mjs" (runtimeSource "javascript") "generated" "source"
      files = concat emitted ++ [runtime | needsRuntime && target /= "go"]
  unless (length files == length (nub (map (map toLower . artifactPath) files))) (Left [Diagnostic "collision" "units map to the same output path" Nothing])
  let generatedNames u = map (\(n,_) -> if target == "go" then cap n else n) (functions u)
  unless (all (\u -> let ns = generatedNames u in length ns == length (nub ns)) units) (Left [Diagnostic "collision" "functions map to the same target identifier" Nothing])
  pure files
  where
    emitUnit laws u
      | target `elem` ["java","kotlin","go","haskell"] = Native.nativeScalarEmit planMachineBits target u laws
      | otherwise = Scalar.scalarEmit planMachineBits target u laws

-- Paths and imports are transformed together so custom layouts remain executable.
emitPlanWithLayout :: String -> Maybe String -> Maybe String -> Plan -> Either [Diagnostic] [Artifact]
emitPlanWithLayout target sourceDir testDir plan = do
  files <- emitPlan target plan
  let defaults = case target of
        "java" -> ("src/main/java", "src/test/java")
        "kotlin" -> ("src/main/kotlin", "src/test/kotlin")
        "python" -> ("src", "tests")
        "rust" -> ("src", "tests")
        "go" -> ("", "")
        _ -> ("src", "test")
      src = maybe (fst defaults) id sourceDir
      tst = maybe (snd defaults) id testDir
      safe p = (null p && target == "go") || (not (null p) && all (\part -> not (null part) && part /= "." && part /= ".." && all (\c -> isAlphaNum c || c `elem` ("_-" :: String)) part) (split '/' p))
  unless (safe src && safe tst) (Left [Diagnostic "layout" "output directories must be relative paths without traversal" Nothing])
  unless (target /= "go" || src == tst) (Left [Diagnostic "layout" "Go adapters and tests must share a source directory" Nothing])
  let prefix p f = if null p then f else p ++ "/" ++ f
      move old new f = prefix new (maybe f id (stripPrefix (if null old then "" else old ++ "/") f))
      rel a b = case (a,b) of
        (x:xs,y:ys) | x == y -> rel xs ys
        _ -> intercalate "/" (replicate (length a) ".." ++ b)
      relative = rel (split '/' tst) (split '/' src)
      importRoot = if null relative then "." else if ".." `isPrefixOf` relative then relative else "./" ++ relative
      replace old new text
        | null text = []
        | Just rest <- stripPrefix old text = new ++ replace old new rest
        | c:rest <- text = c:replace old new rest
        | otherwise = []
      sourceBase a = if target == "kotlin" && ".java" `isSuffixOf` artifactPath a then "src/main/java" else fst defaults
      sourceRoot a = if target == "kotlin" && ".java" `isSuffixOf` artifactPath a then maybe "src/main/java" id sourceDir else src
      adjust a = a { artifactPath = if artifactPlacement a == "source" then move (sourceBase a) (sourceRoot a) (artifactPath a) else move (snd defaults) tst (artifactPath a)
                   , artifactContent = if target `elem` ["javascript","typescript"] && artifactPlacement a == "test" then replace "from '../src/" ("from '" ++ importRoot ++ "/") (artifactContent a) else if target == "rust" && artifactPlacement a == "test" then replace "\"../src/" ("\"" ++ importRoot ++ "/") (artifactContent a) else artifactContent a }
      result = map adjust files
  unless (length result == length (nub (map (map toLower . artifactPath) result))) (Left [Diagnostic "collision" "custom layout causes an output collision" Nothing])
  pure result
