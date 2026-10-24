-- | Tests of a unit's stateful models for the targets whose law tests come
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
import LawSpec.ScalaData (scalaQuoted)
import LawSpec.SourceLink (generatedHeader, goGeneratedMarker, unitSourceFile)
import LawSpec.Code.Literal (literalFor)
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.Code.Haskell as H
import LawSpec.HaskellDefinitions (sortedImports)

data Callbacks = Callbacks
  { startCallbacks :: Maybe (String, String)
  , commandCallbacks :: [(String, String, Maybe String)]
  , abstractCallback :: Maybe String
  , invariantCallbacks :: [String] }

-- | A Go model callback: a function literal whose body spans lines, so
-- gofmt leaves it as it is.
goCallback :: String -> [String]
goCallback call =
  [ "func(s map[string]*LawSpecSymbol, a []LawSpecValue) LawSpecValue {"
  , "\treturn " ++ call
  , "}" ]

-- | A Go composite literal of a type, one element per line.
goList :: String -> [[String]] -> [String]
goList ty [] = [ty ++ "{}"]
goList ty items = [ty ++ "{"] ++ concatMap (map ('\t' :) . withComma) items ++ ["}"]

withComma :: [String] -> [String]
withComma [] = []
withComma ls = init ls ++ [last ls ++ ","]

-- | Keyed fields of a Go composite literal, each value its lines: gofmt
-- aligns the values of consecutive one-line fields in a column.
goFields :: String -> [(String, [String])] -> [String]
goFields indent fields = concatMap run (groups fields)
  where
    groups [] = []
    groups xs@((_, [_]) : _) = let (single, rest) = span (\(_, v) -> length v == 1) xs in single : groups rest
    groups (x : rest) = [x] : groups rest
    run entries = let width = maximum (map (length . fst) entries) in concat
      [ case withComma value of
          first : more -> (indent ++ key ++ ":" ++ replicate (if length entries > 1 then width - length key + 1 else 1) ' ' ++ first) : map (indent ++) more
          [] -> []
      | (key, value) <- entries ]

-- | Each machine's spec and callbacks, wrapped by the target's lambda.
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

-- | A test file per unit with models, for Go, Java, Kotlin and Haskell.
modelTestArtifacts :: String -> Int -> [C.DataDeclaration] -> [(C.Id, String)] -> C.Unit -> Either [Diagnostic] [Artifact]
modelTestArtifacts target bits datas calls u
  | null (C.unitMachines u) && null (C.unitSupervisors u) = pure []
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
      "scala" -> jvmPath "scala" ".scala"
      _ -> "test/" ++ map (\c -> if c == '.' then '/' else c) hsModule ++ ".hs"
    arguments n
      | target == "go" = intercalate ", " ["a[" ++ show i ++ "]" | i <- [0 .. n - 1]]
      | target == "java" = intercalate ", " ["a.get(" ++ show i ++ ")" | i <- [0 .. n - 1]]
      | target == "kotlin" = intercalate ", " ["a[" ++ show i ++ "]" | i <- [0 .. n - 1]]
      | target == "scala" = intercalate ", " ["a.get(" ++ show i ++ ")" | i <- [0 .. n - 1]]
      | otherwise = unwords ["x" ++ show i | i <- [0 .. n - 1]]
    wrap name n = case target of
      -- Go's callbacks are laid out where they are used (goCallback).
      "go" -> name ++ "(s" ++ concatMap (", " ++) [arguments n | n > 0] ++ ")"
      "java" -> "(s, a) -> " ++ name ++ "(s" ++ concatMap (", " ++) [arguments n | n > 0] ++ ")"
      "kotlin" -> "LawSpecRuntime.ModelCallback { s, a -> " ++ name ++ "(s" ++ concatMap (", " ++) [arguments n | n > 0] ++ ") }"
      "scala" -> "((s, a) => " ++ name ++ "(s" ++ concatMap (", " ++) [arguments n | n > 0] ++ ")): LawSpecRuntime.ModelCallback"
      -- The runtime's uncurried takes the arguments from the list.
      _ -> name
    nil = case target of
      "go" -> "nil"
      "haskell" -> "P.Nothing"
      _ -> "null"
    quoted = show
    supervised = not (null (C.unitSupervisors u))
    render prepared = case target of
      "go" -> unlines $
        [ "// " ++ goGeneratedMarker, "", "package " ++ last parts, "", "import \"testing\"", "" ] ++
        intercalate [""] ([ [ "func TestModel" ++ capitalize (machineName m) ++ "(t *testing.T) {"
                 , "\tmodel := LawSpecModel{" ] ++
                 goFields "\t\t"
                   [ ("Spec", [literalFor "go" spec])
                   , ("Start", goList "[2]LawSpecModelCallback" (maybe [] (\(r, f) -> [goCallback r, goCallback f]) (startCallbacks cs)))
                   , ("Commands", goList "[][3]LawSpecModelCallback"
                       [goList "" [goCallback r, goCallback f, maybe [nil] goCallback w] | (r, f, w) <- commandCallbacks cs])
                   , ("Abstract", maybe [nil] goCallback (abstractCallback cs))
                   , ("Invariants", goList "[]LawSpecModelCallback" (map goCallback (invariantCallbacks cs))) ] ++
                 [ "\t}"
                 , "\tif err := LawSpecCheckModel(model); err != nil {"
                 , "\t\tt.Fatal(err)"
                 , "\t}" ] ++
                 -- A shared model's commands also run at the same time.
                 [ l | machineShared m, l <-
                   [ "\tif err := LawSpecCheckModelParallel(model); err != nil {"
                   , "\t\tt.Fatal(err)"
                   , "\t}" ] ] ++
                 -- Each scenario of the model runs on many schedules.
                 concat [ [ "\tif err := LawSpecCheckScenario(model, " ++ literalFor "go" (programSpec p) ++ "); err != nil {"
                          , "\t\tt.Fatal(err)"
                          , "\t}" ] | p <- machineScenarios m ] ++
                 [ "}" ]
               | (m, (spec, cs)) <- prepared ] ++
        -- A unit with supervisors also checks the runtime's supervision.
        [ [ "func TestSupervision(t *testing.T) {"
          , "\tif err := LawSpecCheckSupervision(); err != nil {"
          , "\t\tt.Fatal(err)"
          , "\t}"
          , "}" ] | not (null (C.unitSupervisors u)) ])
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
      "scala" -> unlines $
        [ "// Generated by LawSpec. Do not edit." ] ++ [ "package " ++ pkg | not (null pkg) ] ++
        [ "", "import org.scalatest.funsuite.AnyFunSuite", "import lawspec.runtime.LawSpecRuntime", ""
        , "class " ++ cls ++ " extends AnyFunSuite {" ] ++
        concat [ [ "  test(" ++ scalaQuoted (C.idText (C.unitId u) ++ "::model " ++ machineName m) ++ ") {"
                 , "    val model = LawSpecRuntime.Model(" ++ scalaQuoted spec ++ ","
                 , "      Array[LawSpecRuntime.ModelCallback](" ++ maybe "" (\(r, f) -> r ++ ", " ++ f) (startCallbacks cs) ++ "),"
                 , "      Array[Array[LawSpecRuntime.ModelCallback]](" ++ intercalate ", " ["Array[LawSpecRuntime.ModelCallback](" ++ r ++ ", " ++ f ++ ", " ++ maybe nil id w ++ ")" | (r, f, w) <- commandCallbacks cs] ++ "),"
                 , "      " ++ maybe nil id (abstractCallback cs) ++ ","
                 , "      Array[LawSpecRuntime.ModelCallback](" ++ intercalate ", " (invariantCallbacks cs) ++ "))"
                 , "    LawSpecRuntime.checkModel(model)" ] ++
                 [ "    LawSpecRuntime.checkModelParallel(model)" | machineShared m ] ++
                 [ "    LawSpecRuntime.checkScenario(model, " ++ scalaQuoted (programSpec p) ++ ")" | p <- machineScenarios m ] ++
                 [ "  }" ]
               | (m, (spec, cs)) <- prepared ] ++
        concat [ [ "  test(" ++ scalaQuoted (C.idText (C.unitId u) ++ "::supervision") ++ ") {"
                 , "    LawSpecRuntime.checkSupervision()", "  }" ] | supervised ] ++
        [ "}" ]
      _ -> D.render (H.layout False) $ D.joinWith D.hardline (map D.text
        ([ "-- " ++ generatedHeader (unitSourceFile u), "module " ++ hsModule ++ " (spec) where", "" ] ++
         sortedImports ([("Prelude", Nothing, Nothing), ("Prelude", Just "P", Nothing), ("Test.Hspec", Nothing, Nothing), ("LawSpecRuntime", Just "LS", Nothing)] ++
           [ (m, Just alias, Nothing) | (m, alias) <- [("LawSpecDefinitionBodies", "Definitions"), ("LawSpecWorkflows", "Workflows")]
           , any (\(_, name) -> take (length alias + 1) name == alias ++ ".") calls ]) ++ [""])) <> D.hardline <>
        H.signature "spec" ["Spec"] <> D.hardline <>
        H.declaration "spec" (H.dollar (H.call "describe" [H.string (C.idText (C.unitId u) ++ " models")]) (H.Do
          (concat [ [ H.Run (H.dollar (H.call "it" [H.string ("model " ++ machineName m)]) (H.Do (
                      [ H.Let "model" (H.call "LS.Model" [H.string spec,
                          maybe (H.Tuple []) (\(r, f) -> H.Tuple [callback r, callback f]) (startCallbacks cs),
                          H.List [H.Tuple [callback r, callback f, maybe (H.var "P.Nothing") (\w' -> H.call "P.Just" [callback w']) w] | (r, f, w) <- commandCallbacks cs],
                          maybe (H.var "P.Nothing") (\a -> H.call "P.Just" [callback a]) (abstractCallback cs),
                          H.List (map callback (invariantCallbacks cs))])
                      , H.Bind "failure" (H.call "LS.checkModel" [H.var "model"])
                      , H.Run (expected "failure") ] ++
                      concat [ [ H.Bind "parallelFailure" (H.call "LS.checkModelParallel" [H.var "model"]), H.Run (expected "parallelFailure") ] | machineShared m ] ++
                      concat [ [ H.Bind ("scenarioFailure" ++ show i) (H.call "LS.checkScenario" [H.var "model", H.string (programSpec p)])
                               , H.Run (expected ("scenarioFailure" ++ show i)) ]
                             | (i, p) <- zip [1 :: Int ..] (machineScenarios m) ]))) ]
                  | (m, (spec, cs)) <- prepared ] ++
          -- A unit with supervisors also checks the runtime's supervision.
          concat [ [ H.Run (H.dollar (H.call "it" [H.string "supervision"]) (H.Do
                       [ H.Bind "failure" (H.var "LS.checkSupervision"), H.Run (expected "failure") ])) ]
                 | not (null (C.unitSupervisors u)) ]))) <> D.hardline
    callback name = H.call "LS.uncurried" [H.var name]
    expected failure = H.call "P.maybe" [H.call "P.pure" [H.var "()"], H.var "expectationFailure", H.var failure]

-- | Rust test functions for a unit's models, calling the mounted definitions
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

-- | A Kotlin string literal: as Haskell's, with $ escaped.
kotlinQuoted :: String -> String
kotlinQuoted = concatMap (\c -> if c == '$' then "\\$" else [c]) . show
