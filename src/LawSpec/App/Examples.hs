-- | @lawspec examples@, ported from examples-command.mjs and
-- native-examples.mjs: the bundled specifications generated for each
-- program target into example_artifacts/<target>, or, with --example
-- payments, each target's payments project (its scaffold, the bundled
-- application files and the payments specification) into
-- native_payments/<target>, every file user-owned. The bundled files are
-- embedded in the core ("LawSpec.App.ExampleSources", which lawspec-dev
-- generate writes from examples/).
-- ref:DEC-haskell-application-port
module LawSpec.App.Examples
  ( examplesCommand,
    paymentsReadme,
  )
where

import Control.Monad (forM, when)
import qualified Data.ByteString as B
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import LawSpec.App.Arguments
import LawSpec.App.Command
import LawSpec.App.Compiler (call)
import LawSpec.App.ExampleSources (exampleSpecifications, paymentsProjects, paymentsSpecification)
import LawSpec.App.Files
import LawSpec.App.Json
import LawSpec.App.Packages (toManifest)
import LawSpec.App.Project (parseEdn)
import LawSpec.Host.Effect (Effect (..))
import LawSpec.Manifest.EDN (writeManifest)
import LawSpec.Scaffold (scaffoldFiles, setupAdvice, testCommand)

-- | generateExamples(options), after main()'s option checks.
examplesCommand :: (Monad m) => Arguments -> Maybe Integer -> FilePath -> [String] -> Command m Int
examplesCommand arguments machineBits cwd selected = do
  let json = flag "json" arguments
      minify = flag "minify" arguments
      bits = fromMaybe 64 machineBits
      output' default' = case option "output" arguments of
        Just directory | not (null directory) -> directory
        _ -> default'
  grantRead [cwd]
  case option "example" arguments of
    Just _ -> do
      results <- exportPayments cwd (output' "native_payments") bits minify selected
      if json
        then printJson (JArray (map fst results))
        else
          printLine $
            intercalate
              "\n"
              [ target
                  ++ ": payment project in "
                  ++ planRoot plan
                  ++ "; "
                  ++ show (length (planPreserved plan))
                  ++ " user files preserved."
                  ++ ( if null (planAdapterUpdates plan)
                         then ""
                         else "\nReview changed example files: " ++ intercalate ", " (map adapterPath (planAdapterUpdates plan))
                     )
              | (target, plan) <- zip selected (map snd results)
              ]
              ++ "\nOpen each project's README.md, run lawspec generate, then its native test command."
      pure 0
    Nothing -> do
      let outputDirectory = output' "example_artifacts"
      root <- safePath cwd outputDirectory
      grantWrite [root]
      artifacts <- forM selected $ \target -> do
        result <-
          call
            "planGeneration"
            ( JObject
                [ ("languageProfile", JString "1.0-rc.2"),
                  ("verification", JObject [("layers", JArray (map JString ["proof", "exhaustive", "property", "examples", "runtime", "model"]))]),
                  ("sources", JArray [JObject [("path", JString name), ("content", JString content)] | (name, content) <- exampleSpecifications]),
                  ("target", JString target),
                  ("machineBits", integer bits),
                  ("minify", JBool minify)
                ]
            )
        case member "diagnostics" result of
          Just found@(JArray (_ : _)) -> failWithDiagnostics "Bundled examples failed to compile" found
          _ -> pure $! packFiles (fromMaybe (JArray []) (member "files" result))
      -- Recheck the destination after compilation, before creating output files.
      _ <- safePath cwd outputDirectory
      makeDirectories root
      -- Each target's files are listed before it is planned, so that only
      -- its plan, whose contents are bytes, outlives its files.
      planned <- forM (zip selected artifacts) $ \(target, packed) -> do
        let files = unpackFiles packed
            listed = [jsObject [(key, value) | key <- ["path", "ownership", "placement"], Just value <- [member key file]] | file <- fromMaybe [] (arrayOf files)]
        targetRoot <- safePath root target
        makeDirectories targetRoot
        plan <- planWrites targetRoot (artifactsFrom files) ".lawspec/generated.json" (const False)
        length (stringify (JArray listed)) `seq` pure (listed, plan)
      let plans = map snd planned
      applyWrites plans
      let results =
            [ JObject
                [ ("target", JString target),
                  ("languageProfile", JString "1.0-rc.2"),
                  ("directory", JString (planRoot plan)),
                  ("files", JArray listed),
                  ("changes", integer (toInteger (length (planChanges plan)))),
                  ("preservedAdapters", JArray (map JString (planPreserved plan))),
                  ("adapterUpdates", adapterUpdatesJson plan)
                ]
            | (target, (listed, plan)) <- zip selected planned
            ]
      if json
        then printJson (JArray results)
        else
          printLine $
            intercalate
              "\n"
              [ target
                  ++ ": "
                  ++ show (length listed)
                  ++ " artifacts in "
                  ++ planRoot plan
                  ++ "; "
                  ++ show (length (planPreserved plan))
                  ++ " user adapters preserved."
                  ++ ( if null (planAdapterUpdates plan)
                         then ""
                         else "\nReview required adapter signatures:\n" ++ intercalate "\n" [adapterPath a ++ "\n" ++ requiredAdapter a | a <- planAdapterUpdates plan]
                     )
              | (target, (listed, plan)) <- zip selected planned
              ]
              ++ "\nInspection artifacts only; native toolchains and dependencies are not checked. Stubs must be implemented before running tests."
      pure 0

-- | A target's planned files with each content as UTF-8 bytes, so that
-- every target's files fit in the 32-bit WASM heap until all are planned.
-- Unpacked, they hold the compiler's response (definitions, evidence and
-- laws, about three times the files) and a String costs several words a
-- character. The planned bytes are what would be written: writes encode the
-- content as UTF-8 too.
newtype Packed = Packed [(Json, Maybe B.ByteString)]

-- | Every file without its content, fully evaluated, and the content's
-- bytes; a file whose content is not a string is kept as it is.
packFiles :: Json -> Packed
packFiles files = forced `seq` Packed packed
  where
    packed =
      [ case member "content" file of
          Just (JString content) -> (JObject [field | field@(key, _) <- members file, key /= "content"], Just (utf8 content))
          _ -> (file, Nothing)
      | file <- fromMaybe [] (arrayOf files)
      ]
    forced = foldr (\(file, bytes) rest -> length (stringify file) `seq` maybe () (`seq` ()) bytes `seq` rest) () packed

unpackFiles :: Packed -> Json
unpackFiles (Packed packed) =
  JArray
    [ maybe file (\bytes -> JObject (insertContent (JString (fromUtf8 bytes)) (members file))) content
    | (file, content) <- packed
    ]
  where
    -- The content back in its place: the compiler writes keys in order.
    insertContent value fields = let (before, after) = span ((< "content") . fst) fields in before ++ [("content", value)] ++ after

adapterUpdatesJson :: Plan -> Json
adapterUpdatesJson plan = JArray [JObject [("path", JString (adapterPath a)), ("requiredAdapter", JString (requiredAdapter a))] | a <- planAdapterUpdates plan]

-- | mkdir(directory, {recursive: true}).
makeDirectories :: (Monad m) => FilePath -> Command m ()
makeDirectories directory = effect (nodeFailure "mkdir" directory) (MakeDirectories Nothing directory)

-- | native-examples.mjs exportNativePayments: each target's files planned
-- in turn, then every plan applied.
exportPayments :: (Monad m) => FilePath -> String -> Integer -> Bool -> [String] -> Command m [(Json, Plan)]
exportPayments cwd outputDirectory bits minify selected = do
  root <- safePath cwd outputDirectory
  grantWrite [root]
  makeDirectories root
  results <- forM selected $ \target -> do
    directory <- safePath root target
    makeDirectories directory
    scaffold <- either failWith pure (scaffoldFiles minify target)
    let bundled = fromMaybe [] (lookup target paymentsProjects)
        files0 = merge (scaffold ++ bundled ++ [("laws/payments.lawspec", paymentsSpecification)])
    config0 <- parseEdn (fromMaybe "undefined" (lookup "lawspec.edn" files0)) "lawspec.edn"
    when (member "manifestVersion" config0 /= Just (integer 1) || member "languageProfile" config0 /= Just (JString "1.0-rc.2")) $
      failWith ("Bundled native payments configuration for " ++ target ++ " must use lawspec.edn and languageProfile 1.0-rc.2")
    let config = setMember "machineBits" (integer bits) config0
        files = merge (files0 ++ [("lawspec.edn", writeManifest minify (toManifest config)), ("README.md", paymentsReadme target)])
        artifacts = [Artifact path' content User Nothing | (path', content) <- files]
    plan <- planWrites directory artifacts ".lawspec/example.json" (const False)
    pure
      ( JObject
          [ ("target", JString target),
            ("directory", JString directory),
            ("example", JString "payments"),
            ("files", JArray [JObject [("path", JString path'), ("ownership", JString "user")] | (path', _) <- files]),
            ("changes", integer (toInteger (length (planChanges plan)))),
            ("preservedAdapters", JArray (map JString (planPreserved plan))),
            ("adapterUpdates", adapterUpdatesJson plan)
          ],
        plan
      )
  applyWrites (map snd results)
  pure results
  where
    -- Object spread and assignment: a repeated path keeps its first place
    -- and its last content.
    merge pairs = [(key, value) | (key, JString value) <- members (jsObject [(key, JString value) | (key, value) <- pairs])]

-- | The README.md each payments project gets.
paymentsReadme :: String -> String
paymentsReadme target =
  "# Native payments: "
    ++ target
    ++ "\n\nThis project checks application-owned payment types against the shared LawSpec\n\
       \model. Money maps to Price, currency variants have application names, and the\n\
       \archive preserves distinct present and absent payments.\n\
       \\n\
       \The specification uses the canonical language profile. The component manifest\n\
       \selects its verification layers explicitly. Most targets bind\n\
       \application-owned domain types; C#, Clojure and Prolog use the generated model data\n\
       \and bind the application's functions and generators.\n\
       \\n\
       \## Run\n\
       \\n\
       \Install LawSpec and the native dependencies described below, then run:\n\
       \\n\
       \```sh\n\
       \lawspec check\n"
    ++ (if gleam then "node prepare.mjs\n" else "")
    ++ "lawspec generate\n"
    ++ maybe "undefined" id (testCommand target)
    ++ "\n```\n\n"
    ++ instructions
    ++ "\n\n"
    ++ ( if gleam
           then
             "The preparation command compiles dependencies in a temporary project using\n\
             \your dependency requirements and lock file. It leaves application sources in\n\
             \place, so their imports can be resolved after LawSpec generates the runtime.\n"
           else ""
       )
    ++ "\n\nJavaScript and TypeScript projects require `npm install` before testing.\n\
       \The specification includes exact decimal arithmetic and explicit USD/GBP examples.\n\
       \The native price generator deliberately samples only EUR values between 1.00 and\n\
       \2.00; examples and deterministic boundaries still check the other cases. Its\n\
       \framework's mapping operation preserves the native shrinker.\n\
       \\n\
       \The application types use native exact decimals where available and LawSpec's\n\
       \framework-independent numeric runtime otherwise. Run generation before compiling\n\
       \the application so that runtime support is present.\n\
       \\n\
       \## Change the application\n\
       \\n\
       \Edit the domain implementation or generator, then run the native tests again.\n\
       \For example, change the fee from 0.2 to 0.3: the exact-decimal law must fail.\n\
       \Edit `lawspec.edn` to change native bindings and rerun `lawspec generate`.\n\
       \\n\
       \All exported project files are user-owned. Re-exporting preserves your edits;\n\
       \it reports changed bundled versions for review. Compiler-generated files use a\n\
       \separate ownership manifest and remain protected against accidental overwrites.\n"
  where
    gleam = target == "gleam"
    advice = maybe "undefined" id (setupAdvice target)
    instructions
      | gleam = replaceFirst "Prepare dependencies with gleam build, then run gleam test." "Prepare dependencies with node prepare.mjs before generation, then run gleam test." advice
      | otherwise = advice

-- | String.prototype.replace with a string pattern: the first occurrence.
replaceFirst :: String -> String -> String -> String
replaceFirst pattern replacement text = go text
  where
    go rest
      | take (length pattern) rest == pattern = replacement ++ drop (length pattern) rest
      | otherwise = case rest of
          [] -> []
          c : more -> c : go more
