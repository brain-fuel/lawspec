-- | Tests of a unit's stateful models for the targets whose law tests come
-- from their own property emitters: Go, Java, Kotlin and Haskell get a test
-- file of their own, and Rust gets test functions for its law test file.
-- Each test hands the model's spec and its callbacks (the generated bridge
-- definitions, references, preconditions, abstraction and invariants, each
-- wrapped to take a symbol context and a list of logical values) to the
-- target's model runtime.
module LawSpec.ModelTests (modelTestArtifacts, rustModelTests) where

import LawSpec.JavaText (javaText)
import Data.Char (toUpper)
import Data.List (intercalate, stripPrefix)
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
import qualified LawSpec.Code.Doc as Doc
import qualified LawSpec.RustLayout as RL
import qualified LawSpec.JavaExpr as E
import LawSpec.JvmNames (jvmString)
import qualified LawSpec.KotlinLayout as KotlinLayout
import qualified LawSpec.ScalaLayout as ScalaLayout

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
    -- A callback's body is a call name(s, a[0], ...), laid out as a call.
    ktCallback body = D.text "LawSpecRuntime.ModelCallback " <> KotlinLayout.lambda ["s", "a"] [KotlinLayout.call (takeWhile (/= '(') body)
      (map D.text (splitArguments (takeWhile (/= ')') (drop 1 (dropWhile (/= '(') body)))))]
    -- A Scala callback: ((s, a) => name(args)) as the runtime's interface.
    scCallback body = D.group (D.text "(s, a) =>" <> D.nest 2 (D.softline <> ScalaLayout.call (takeWhile (/= '(') body)
      (map D.text (splitArguments (init (drop 1 (dropWhile (/= '(') body)))))))
    scString = ScalaLayout.scalaString
    -- An array of one callback keeps it in its parentheses, as scalafmt does.
    scArray [one] = D.group (D.text "Array[LawSpecRuntime.ModelCallback](" <> one <> D.softbreak <> D.text ")")
    scArray many = ScalaLayout.call "Array[LawSpecRuntime.ModelCallback]" many
    -- A Java callback: (s, a) -> name(args), broken after the arrow.
    jCallback body = case break (== '>') body of
      (params, '>' : ' ' : call) -> D.group (D.text (params ++ ">") <> D.nest 4 (D.softline <> javaText call))
      _ -> D.text body
    splitArguments s = case break (== ',') s of
      (a, []) -> [a]
      (a, _ : rest) -> a : splitArguments (dropWhile (== ' ') rest)
    -- A Java array: new T[] {a, b}, wrapping inside its braces.
    array element items = D.group (D.text ("new " ++ element ++ "[] {") <> D.nest 4 (D.softbreak <> D.commaSep items) <> D.softbreak <> D.text "}")
    braces items = D.group (D.text "{" <> D.nest 4 (D.softbreak <> D.commaSep items) <> D.softbreak <> D.text "}")
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
      "kotlin" -> name ++ "(s" ++ concatMap (", " ++) [arguments n | n > 0] ++ ")"
      "scala" -> name ++ "(s" ++ concatMap (", " ++) [arguments n | n > 0] ++ ")"
      -- The runtime's uncurried takes the arguments from the list.
      _ -> name
    nil = case target of
      "go" -> "nil"
      "haskell" -> "P.Nothing"
      _ -> "null"
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
      -- Java: Allman braces with Google's other rules, as LawSpec's Java
      -- profile asks; the spec wraps at its spaces.
      -- Checked definitions are called through their imported class.
      "java" -> D.render (D.Pretty 100) $ D.mapText unqualifiedBodies $
        D.text "// Generated by LawSpec. Do not edit." <> D.hardline <> D.hardline <>
        (if null pkg then mempty else D.text ("package " ++ pkg ++ ";") <> D.hardline <> D.hardline) <>
        D.text "import lawspec.runtime.LawSpecDefinitionBodies;" <> D.hardline <>
        D.text "import lawspec.runtime.LawSpecRuntime;" <> D.hardline <> D.text "import org.junit.jupiter.api.Test;" <> D.hardline <> D.hardline <>
        D.text ("public final class " ++ cls) <> D.hardline <>
        D.block 2 (D.joinWith (D.hardline <> D.hardline)
          ([ D.text "@Test" <> D.hardline <> D.text ("void model" ++ capitalize (machineName m) ++ "()") <> D.hardline <>
             D.block 2 (D.joinWith D.hardline (
               [ D.group (D.text "var model =" <> D.nest 4 (D.softline <> E.call "new LawSpecRuntime.Model"
                   [ jvmString "java" spec
                   , array "LawSpecRuntime.ModelCallback" (maybe [] (\(r, f) -> [jCallback r, jCallback f]) (startCallbacks cs))
                   , array "LawSpecRuntime.ModelCallback[]" [braces [jCallback r, jCallback f, maybe (D.text nil) jCallback w] | (r, f, w) <- commandCallbacks cs]
                   , maybe (D.text nil) jCallback (abstractCallback cs)
                   , array "LawSpecRuntime.ModelCallback" (map jCallback (invariantCallbacks cs)) ])) <> D.text ";"
               , D.text "LawSpecRuntime.checkModel(model);" ] ++
               [ D.text "LawSpecRuntime.checkModelParallel(model);" | machineShared m ] ++
               [ E.call "LawSpecRuntime.checkScenario" [D.text "model", jvmString "java" (programSpec p)] <> D.text ";" | p <- machineScenarios m ]))
           | (m, (spec, cs)) <- prepared ] ++
           -- A unit with supervisors also checks the runtime's supervision.
           [ D.text "@Test" <> D.hardline <> D.text "void supervision()" <> D.hardline <> D.block 2 (D.text "LawSpecRuntime.checkSupervision();") | supervised ])) <> D.hardline
      -- Kotlin: as ktfmt lays it out (LawSpec.KotlinLayout).
      "kotlin" -> D.render KotlinLayout.kotlinStyle $
        D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
        (if null pkg then mempty else D.text ("package " ++ pkg) <> D.hardline) <> D.hardline <>
        D.text "import io.kotest.core.spec.style.StringSpec" <> D.hardline <> D.text "import lawspec.runtime.LawSpecRuntime" <> D.hardline <> D.hardline <>
        D.text ("class " ++ cls ++ " :") <> D.nest 4 (D.hardline <> D.text "StringSpec({" <> D.nest 4 (D.hardline <> D.joinWith (D.hardline <> D.hardline)
          ([ KotlinLayout.kotlinString (C.idText (C.unitId u) ++ "::model " ++ machineName m) <> D.text " " <> KotlinLayout.lambda []
               ([ KotlinLayout.bind "model" (KotlinLayout.call "LawSpecRuntime.Model"
                   [ KotlinLayout.kotlinString spec
                   , KotlinLayout.call "arrayOf" (maybe [] (\(r, f) -> [ktCallback r, ktCallback f]) (startCallbacks cs))
                   , KotlinLayout.call "arrayOf" [KotlinLayout.call "arrayOf<LawSpecRuntime.ModelCallback?>" [ktCallback r, ktCallback f, maybe (D.text nil) ktCallback w] | (r, f, w) <- commandCallbacks cs]
                   , maybe (D.text nil) ktCallback (abstractCallback cs)
                   , KotlinLayout.call "arrayOf" (map ktCallback (invariantCallbacks cs)) ])
               , D.text "LawSpecRuntime.checkModel(model)" ] ++
               [ D.text "LawSpecRuntime.checkModelParallel(model)" | machineShared m ] ++
               [ KotlinLayout.call "LawSpecRuntime.checkScenario" [D.text "model", KotlinLayout.kotlinString (programSpec p)] | p <- machineScenarios m ])
           | (m, (spec, cs)) <- prepared ] ++
           [ KotlinLayout.kotlinString (C.idText (C.unitId u) ++ "::supervision") <> D.text " " <> KotlinLayout.lambda [] [D.text "LawSpecRuntime.checkSupervision()"] | supervised ])) <>
          D.hardline <> D.text "})") <> D.hardline
      -- Scala: as scalafmt lays it out (LawSpec.ScalaLayout).
      "scala" -> D.render ScalaLayout.scalaStyle $
        D.text "// Generated by LawSpec. Do not edit." <> D.hardline <>
        (if null pkg then mempty else D.text ("package " ++ pkg) <> D.hardline) <> D.hardline <>
        D.text "import lawspec.runtime.LawSpecRuntime" <> D.hardline <> D.text "import org.scalatest.funsuite.AnyFunSuite" <> D.hardline <> D.hardline <>
        D.text ("class " ++ cls ++ " extends AnyFunSuite ") <> ScalaLayout.block [D.joinWith (D.hardline <> D.hardline)
          ([ ScalaLayout.call "test" [scString (C.idText (C.unitId u) ++ "::model " ++ machineName m)] <> D.text " " <> ScalaLayout.block
               ([ ScalaLayout.bind "model" (ScalaLayout.call "LawSpecRuntime.Model"
                   [ scString spec
                   , ScalaLayout.call "Array[LawSpecRuntime.ModelCallback]" (maybe [] (\(r, f) -> [scCallback r, scCallback f]) (startCallbacks cs))
                   , ScalaLayout.call "Array[Array[LawSpecRuntime.ModelCallback]]" [ScalaLayout.call "Array[LawSpecRuntime.ModelCallback]" [scCallback r, scCallback f, maybe (D.text nil) scCallback w] | (r, f, w) <- commandCallbacks cs]
                   , maybe (D.text nil) scCallback (abstractCallback cs)
                   , scArray (map scCallback (invariantCallbacks cs)) ])
               , D.text "LawSpecRuntime.checkModel(model)" ] ++
               [ D.text "LawSpecRuntime.checkModelParallel(model)" | machineShared m ] ++
               [ ScalaLayout.call "LawSpecRuntime.checkScenario" [D.text "model", scString (programSpec p)] | p <- machineScenarios m ])
           | (m, (spec, cs)) <- prepared ] ++
           [ ScalaLayout.call "test" [scString (C.idText (C.unitId u) ++ "::supervision")] <> D.text " " <> ScalaLayout.block [D.text "LawSpecRuntime.checkSupervision()"] | supervised ])] <> D.hardline
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
    -- Laid out as rustfmt lays it out (LawSpec.RustLayout).
    test m = do
      (spec, cs) <- prepare bits datas calls u wrap m
      let rust = Doc.render (Doc.styleLayout (Doc.styleFor "rust"))
          model = RL.struct "ls::Model"
            [ ("spec", RL.atom (literalFor "rust" spec))
            , ("start", RL.Macro "" "[" "]" (maybe [] (\(r, f) -> [RL.atom r, RL.atom f]) (startCallbacks cs)))
            , ("commands", RL.vecOf [RL.Macro "" "(" ")" [RL.atom r, RL.atom f, maybe (RL.atom "None") (\w' -> RL.call "Some" [RL.atom w']) w] | (r, f, w) <- commandCallbacks cs])
            , ("abstract_state", maybe (RL.atom "None") (\a -> RL.call "Some" [RL.atom a]) (abstractCallback cs))
            , ("invariants", RL.vecOf (map RL.atom (invariantCallbacks cs))) ]
          checks = foldl (\acc next -> RL.method acc "and_then" [RL.closure "|_|" next]) (RL.call "ls::check_model" [RL.atom "&model"])
            ([RL.call "ls::check_model_parallel" [RL.atom "&model"] | machineShared m] ++
             [RL.call "ls::check_scenario" [RL.atom "&model", RL.atom (literalFor "rust" (programSpec p))] | p <- machineScenarios m])
          failed = RL.If (RL.prefix "let Err(message) = " (RL.call "ls::with_stack" [RL.closure "move ||" checks]))
            (RL.Block [RL.Semi (RL.macroCall "panic" [RL.atom "\"{}\"", RL.atom "message"])] Nothing) Nothing
      pure (rust (Doc.text "#[test]" <> Doc.hardline <> RL.function ("fn model_" ++ machineName m) [] ""
        (RL.stmts [RL.Let "model" model, RL.Do failed] Nothing)) ++ "\n")

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

-- | Text with lawspec.runtime.LawSpecDefinitionBodies written by its class.
unqualifiedBodies :: String -> String
unqualifiedBodies s = case s of
  [] -> []
  _ | Just rest <- stripPrefix "lawspec.runtime.LawSpecDefinitionBodies." s -> "LawSpecDefinitionBodies." ++ unqualifiedBodies rest
  c : rest -> c : unqualifiedBodies rest
