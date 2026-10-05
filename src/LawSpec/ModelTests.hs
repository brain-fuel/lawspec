-- Tests of a unit's stateful models for the targets whose law tests come
-- from their own property emitters: Go, Java, Kotlin and Haskell get a test
-- file of their own, and Rust gets test functions for its law test file.
-- Each test hands the model's spec and its callbacks (the generated bridge
-- definitions, references, preconditions, abstraction and invariants, each
-- wrapped to take a symbol context and a list of logical values) to the
-- target's model runtime.
module LawSpec.ModelTests (modelTestArtifacts, rustModelTests) where

import Data.Char (toUpper)
import Data.List (intercalate)
import qualified LawSpec.Core as C
import LawSpec.Core.Machine
import LawSpec.Common (Artifact(..), Diagnostic(..))
import LawSpec.MachineSpec (machineSpec)
import LawSpec.Core.Program (programSpec)

data Callbacks = Callbacks
  { startCallbacks :: Maybe (String, String)
  , commandCallbacks :: [(String, String, Maybe String)]
  , abstractCallback :: Maybe String
  , invariantCallbacks :: [String] }

-- Each machine's spec and callbacks, wrapped by the target's lambda.
prepare :: Int -> [C.DataDeclaration] -> [(C.Id, String)] -> C.Unit -> (String -> Int -> String) -> Machine C.Id -> Either [Diagnostic] (String, Callbacks)
prepare bits datas calls u wrap machine = do
  spec <- failing (machineSpec bits datas (C.unitDeclarations u) (C.unitContracts u) machine)
  let arity identity = case [d | d <- C.unitDefinitions u, C.declarationId (C.definitionDeclaration d) == identity] of
        [d] -> Right (length (C.definitionArguments d))
        _ -> Left [Diagnostic "model" ("model " ++ machineName machine ++ ": " ++ C.idText identity ++ " is not a definition of this unit") Nothing]
      callback identity = do
        name <- maybe (Left [Diagnostic "model" ("model " ++ machineName machine ++ ": no evaluator for " ++ C.idText identity) Nothing]) Right
          (lookup identity calls)
        wrap (stripAwait name) <$> arity identity
  start <- traverse (\s -> (,) <$> callback (startRun s) <*> callback (startModel s)) (machineStart machine)
  commands <- mapM (\c -> (,,) <$> callback (commandRun c) <*> callback (commandReference c) <*> traverse callback (commandWhen c))
    (machineCommands machine)
  abstract <- traverse callback (machineAbstractRun machine)
  invariants <- mapM (callback . invariantName) (machineInvariants machine)
  pure (spec, Callbacks start commands abstract invariants)
  where
    failing = either (\m -> Left [Diagnostic "model" m Nothing]) Right
    invariantName (OnModel f) = f
    invariantName (OnState f) = f
    stripAwait name = maybe name id (stripPrefixed "await " name)
    stripPrefixed p s = if take (length p) s == p then Just (drop (length p) s) else Nothing

-- A test file per unit with models, for Go, Java, Kotlin and Haskell.
modelTestArtifacts :: String -> Int -> [C.DataDeclaration] -> [(C.Id, String)] -> C.Unit -> Either [Diagnostic] [Artifact]
modelTestArtifacts target bits datas calls u
  | null (C.unitMachines u) = pure []
  | otherwise = do
      prepared <- mapM (\m -> (,) m <$> prepare bits datas calls u wrap m) (C.unitMachines u)
      pure [Artifact path (render prepared) "generated" "test"]
  where
    parts = split (C.idText (C.unitId u))
    cls = concatMap capitalize (splitOn '_' (last parts)) ++ "ModelTest"
    pkg = intercalate "." (init parts)
    jvmPath root ext = "src/test/" ++ root ++ "/" ++ intercalate "/" (init parts ++ [cls]) ++ ext
    hsModule = intercalate "." (map hsPart (init parts) ++ [hsPart (last parts) ++ "ModelSpec"])
    path = case target of
      "go" -> intercalate "/" parts ++ "/lawspec_models_test.go"
      "java" -> jvmPath "java" ".java"
      "kotlin" -> jvmPath "kotlin" ".kt"
      _ -> "test/" ++ map (\c -> if c == '.' then '/' else c) hsModule ++ ".hs"
    arguments n
      | target == "go" = intercalate ", " ["a[" ++ show i ++ "]" | i <- [0 .. n - 1]]
      | target == "java" = intercalate ", " ["a.get(" ++ show i ++ ")" | i <- [0 .. n - 1]]
      | target == "kotlin" = intercalate ", " ["a[" ++ show i ++ "]" | i <- [0 .. n - 1]]
      | otherwise = unwords ["x" ++ show i | i <- [0 .. n - 1]]
    wrap name n = case target of
      "go" -> "func(s map[string]*LawSpecSymbol, a []LawSpecValue) LawSpecValue { return " ++ name ++ "(s" ++ concatMap (", " ++) [arguments n | n > 0] ++ ") }"
      "java" -> "(s, a) -> " ++ name ++ "(s" ++ concatMap (", " ++) [arguments n | n > 0] ++ ")"
      "kotlin" -> "LawSpecRuntime.ModelCallback { s, a -> " ++ name ++ "(s" ++ concatMap (", " ++) [arguments n | n > 0] ++ ") }"
      _ -> "(\\s a -> case a of { [" ++ intercalate ", " ["x" ++ show i | i <- [0 .. n - 1]] ++ "] -> " ++ name ++ " s " ++ arguments n ++
        "; _ -> P.Left \"model callback arity\" })"
    nil = case target of
      "go" -> "nil"
      "haskell" -> "P.Nothing"
      _ -> "null"
    quoted = show
    supervised = not (null (C.unitSupervisors u))
    render prepared = case target of
      "go" -> unlines $
        [ "// Generated by LawSpec. Do not edit.", "package " ++ last parts, "", "import \"testing\"", "" ] ++
        concat [ [ "func TestModel" ++ capitalize (machineName m) ++ "(t *testing.T) {"
                 , "\tmodel := LawSpecModel{"
                 , "\t\tSpec: " ++ quoted spec ++ ","
                 , "\t\tStart: [2]LawSpecModelCallback{" ++ maybe "" (\(r, f) -> r ++ ", " ++ f) (startCallbacks cs) ++ "},"
                 , "\t\tCommands: [][3]LawSpecModelCallback{" ++ intercalate ", " ["{" ++ r ++ ", " ++ f ++ ", " ++ maybe nil id w ++ "}" | (r, f, w) <- commandCallbacks cs] ++ "},"
                 , "\t\tAbstract: " ++ maybe nil id (abstractCallback cs) ++ ","
                 , "\t\tInvariants: []LawSpecModelCallback{" ++ intercalate ", " (invariantCallbacks cs) ++ "},"
                 , "\t}"
                 , "\tif err := LawSpecCheckModel(model); err != nil {"
                 , "\t\tt.Fatal(err)"
                 , "\t}" ] ++
                 -- A shared model's commands also run at the same time.
                 [ l | machineShared m, l <-
                   [ "\tif err := LawSpecCheckModelParallel(model); err != nil {"
                   , "\t\tt.Fatal(err)"
                   , "\t}" ] ] ++
                 -- Each scenario of the model runs on many schedules.
                 concat [ [ "\tif err := LawSpecCheckScenario(model, " ++ quoted (programSpec p) ++ "); err != nil {"
                          , "\t\tt.Fatal(err)"
                          , "\t}" ] | p <- machineScenarios m ] ++
                 [ "}", "" ]
               | (m, (spec, cs)) <- prepared ] ++
        -- A unit with supervisors also checks the runtime's supervision.
        [ l | not (null (C.unitSupervisors u)), l <-
          [ "func TestSupervision(t *testing.T) {"
          , "\tif err := LawSpecCheckSupervision(); err != nil {"
          , "\t\tt.Fatal(err)"
          , "\t}"
          , "}" ] ]
      "java" -> unlines $
        [ "// Generated by LawSpec. Do not edit." ] ++ [ "package " ++ pkg ++ ";" | not (null pkg) ] ++
        [ "", "import lawspec.runtime.LawSpecRuntime;", "import org.junit.jupiter.api.Test;", ""
        , "public final class " ++ cls ++ " {" ] ++
        concat [ [ "  @Test void model" ++ capitalize (machineName m) ++ "() {"
                 , "    var model = new LawSpecRuntime.Model(" ++ quoted spec ++ ","
                 , "        new LawSpecRuntime.ModelCallback[] {" ++ maybe "" (\(r, f) -> r ++ ", " ++ f) (startCallbacks cs) ++ "},"
                 , "        new LawSpecRuntime.ModelCallback[][] {" ++ intercalate ", " ["{" ++ r ++ ", " ++ f ++ ", " ++ maybe nil id w ++ "}" | (r, f, w) <- commandCallbacks cs] ++ "},"
                 , "        " ++ maybe nil id (abstractCallback cs) ++ ","
                 , "        new LawSpecRuntime.ModelCallback[] {" ++ intercalate ", " (invariantCallbacks cs) ++ "});"
                 , "    LawSpecRuntime.checkModel(model);" ] ++
                 [ "    LawSpecRuntime.checkModelParallel(model);" | machineShared m ] ++
                 [ "    LawSpecRuntime.checkScenario(model, " ++ quoted (programSpec p) ++ ");" | p <- machineScenarios m ] ++
                 [ "  }" ]
               | (m, (spec, cs)) <- prepared ] ++
        -- A unit with supervisors also checks the runtime's supervision.
        concat [ [ "  @Test void supervision() {", "    LawSpecRuntime.checkSupervision();", "  }" ] | supervised ] ++
        [ "}" ]
      "kotlin" -> unlines $
        [ "// Generated by LawSpec. Do not edit." ] ++ [ "package " ++ pkg | not (null pkg) ] ++
        [ "", "import io.kotest.core.spec.style.StringSpec", "import lawspec.runtime.LawSpecRuntime", ""
        , "class " ++ cls ++ " : StringSpec({" ] ++
        concat [ [ "    " ++ quoted (C.idText (C.unitId u) ++ "::model " ++ machineName m) ++ " {"
                 , "        val model = LawSpecRuntime.Model(" ++ quoted spec ++ ","
                 , "            arrayOf(" ++ maybe "" (\(r, f) -> r ++ ", " ++ f) (startCallbacks cs) ++ "),"
                 , "            arrayOf(" ++ intercalate ", " ["arrayOf<LawSpecRuntime.ModelCallback?>(" ++ r ++ ", " ++ f ++ ", " ++ maybe nil id w ++ ")" | (r, f, w) <- commandCallbacks cs] ++ "),"
                 , "            " ++ maybe nil id (abstractCallback cs) ++ ","
                 , "            arrayOf(" ++ intercalate ", " (invariantCallbacks cs) ++ "))"
                 , "        LawSpecRuntime.checkModel(model)" ] ++
                 [ "        LawSpecRuntime.checkModelParallel(model)" | machineShared m ] ++
                 [ "        LawSpecRuntime.checkScenario(model, " ++ kotlinQuoted (programSpec p) ++ ")" | p <- machineScenarios m ] ++
                 [ "    }" ]
               | (m, (spec, cs)) <- prepared ] ++
        concat [ [ "    " ++ quoted (C.idText (C.unitId u) ++ "::supervision") ++ " {"
                 , "        LawSpecRuntime.checkSupervision()", "    }" ] | supervised ] ++
        [ "})" ]
      _ -> unlines $
        [ "-- Generated by LawSpec. Do not edit."
        , "module " ++ hsModule ++ " (spec) where", ""
        , "import qualified Prelude as P", "import Prelude", "import Test.Hspec", "import qualified LawSpecRuntime as LS" ] ++
        [ "import qualified " ++ m ++ " as " ++ alias | (m, alias) <- [("LawSpecDefinitionBodies", "Definitions"), ("LawSpecWorkflows", "Workflows")]
          , any (\(_, name) -> take (length alias + 1) name == alias ++ ".") calls ] ++
        [ "", "spec :: Spec", "spec = describe " ++ quoted (C.idText (C.unitId u) ++ " models") ++ " $ do" ] ++
        concat [ [ "  it " ++ quoted ("model " ++ machineName m) ++ " $ do"
                 , "    let model = LS.Model " ++ quoted spec
                 , "          (" ++ maybe "" (\(r, f) -> r ++ ", " ++ f) (startCallbacks cs) ++ ")"
                 , "          [" ++ intercalate ", " ["(" ++ r ++ ", " ++ f ++ ", " ++ maybe nil (\w' -> "P.Just " ++ w') w ++ ")" | (r, f, w) <- commandCallbacks cs] ++ "]"
                 , "          " ++ maybe nil (\a -> "(P.Just " ++ a ++ ")") (abstractCallback cs)
                 , "          [" ++ intercalate ", " (invariantCallbacks cs) ++ "]"
                 , "    failure <- LS.checkModel model"
                 , "    maybe (pure ()) expectationFailure failure" ] ++
                 [ l | machineShared m, l <-
                   [ "    parallelFailure <- LS.checkModelParallel model"
                   , "    maybe (pure ()) expectationFailure parallelFailure" ] ] ++
                 concat [ [ "    scenarioFailure" ++ show i ++ " <- LS.checkScenario model " ++ quoted (programSpec p)
                          , "    maybe (pure ()) expectationFailure scenarioFailure" ++ show i ]
                        | (i, p) <- zip [0 :: Int ..] (machineScenarios m) ]
               | (m, (spec, cs)) <- prepared ]

-- Rust test functions for a unit's models, calling the mounted definitions
-- module's evaluators, which already take a context and a list of values.
rustModelTests :: Int -> [C.DataDeclaration] -> [(C.Id, String)] -> C.Unit -> Either [Diagnostic] [String]
rustModelTests bits datas calls u = (++ supervision) <$> mapM test (C.unitMachines u)
  where
    -- A unit with supervisors also checks the runtime's supervision.
    supervision =
      [ unlines
          [ "#[test]"
          , "fn supervision() {"
          , "    if let Err(message) = ls::actors::check_supervision() {"
          , "        panic!(\"{}\", message);"
          , "    }"
          , "}" ]
      | not (null (C.unitSupervisors u)) ]
    wrap name _ = "lawspec_definitions::" ++ name ++ " as ls::ModelCallback"
    test m = do
      (spec, cs) <- prepare bits datas calls u wrap m
      pure $ unlines
        [ "#[test]"
        , "fn model_" ++ machineName m ++ "() {"
        , "    let model = ls::Model {"
        , "        spec: " ++ show spec ++ ","
        , "        start: [" ++ maybe "" (\(r, f) -> r ++ ", " ++ f) (startCallbacks cs) ++ "],"
        , "        commands: vec![" ++ intercalate ", " ["(" ++ r ++ ", " ++ f ++ ", " ++ maybe "None" (\w' -> "Some(" ++ w' ++ ")") w ++ ")" | (r, f, w) <- commandCallbacks cs] ++ "],"
        , "        abstract_state: " ++ maybe "None" (\a -> "Some(" ++ a ++ ")") (abstractCallback cs) ++ ","
        , "        invariants: vec![" ++ intercalate ", " (invariantCallbacks cs) ++ "],"
        , "    };"
        , "    if let Err(message) = ls::with_stack(move || ls::check_model(&model)" ++
            (if machineShared m then ".and_then(|_| ls::check_model_parallel(&model))" else "") ++
            concat [".and_then(|_| ls::check_scenario(&model, " ++ show (programSpec p) ++ "))" | p <- machineScenarios m] ++ ") {"
        , "        panic!(\"{}\", message);"
        , "    }"
        , "}" ]

split :: String -> [String]
split = splitOn '.'

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, []) -> [a]
  (a, _ : rest) -> a : splitOn c rest

capitalize :: String -> String
capitalize (c : cs) = toUpper c : cs
capitalize [] = []

hsPart :: String -> String
hsPart = concatMap capitalize . splitOn '_'

-- A Kotlin string literal: as Haskell's, with $ escaped.
kotlinQuoted :: String -> String
kotlinQuoted = concatMap (\c -> if c == '$' then "\\$" else [c]) . show
