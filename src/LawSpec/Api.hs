module LawSpec.Api (dispatch) where
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Control.Monad (unless)
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as B
import LawSpec.Model
import LawSpec.Compile
import LawSpec.Frontend (elaborate)
import LawSpec.Testing (Plan, planTesting)
import qualified LawSpec.Core as C
import LawSpec.Core.Evidence (Obligation)
import LawSpec.CoreEmit (emitPlanWithNativeOptions)
import LawSpec.NativeRequest
import LawSpec.Public (programView)
import LawSpec.Packages
import LawSpec.Discharge (dischargeEvidence, bindingEvidence)
import LawSpec.TestManifest (TestEntry(..), testManifest)
import LawSpec.Memo (Table, newTable, memoized, withCacheDirectory)
import qualified Data.ByteString.Lazy.Char8 as BC
import qualified Data.Aeson.Key as K
import qualified Data.Text as T
import System.IO.Unsafe (unsafePerformIO)

dispatch :: B.ByteString -> B.ByteString
dispatch bytes = withCacheDirectory cacheDirectory $ encode $ versioned $ case eitherDecode bytes >>= parseEither request of
  Left err -> failure [Diagnostic "request" err Nothing]
  Right ((method,sources,target,sourceDir,testDir,bits,settings,minify,native),(project,packages)) ->
   -- Compilation, evidence and the testing plan depend on neither the method
   -- nor the target, so a compiler asked for several targets does them once.
   case memoized stagesTable (sharedRequest bytes) (stages project packages sources bits settings native) of
    Left response -> response
    Right (us,es,core,bindings,evidence,described,plan) ->
     let result files = withPackages project described (programView settings us (map prettyExpanded es) files (evidence ++ bindingEvidence bindings) core) in case method of
          "check" -> result []
          "expand" -> result []
          "planGeneration" -> either failure (withTests (testManifest target testDir core) . result)
            (plan >>= emitPlanWithNativeOptions minify target sourceDir testDir bindings)
          _ -> failure [Diagnostic "request" ("unknown method: " ++ method) Nothing]

  where
    -- Where the compiler may keep work between runs; the CLI names one per
    -- project and compiler build.
    cacheDirectory = case decode bytes of
      Just (Object o) | Just (String d) <- KM.lookup "cacheDirectory" o -> Just (T.unpack d)
      _ -> Nothing
    responseVersion = case eitherDecode bytes >>= parseEither
        (withObject "request" (\o -> o .:? "schemaVersion" .!= (3 :: Int))) of
      Right 4 -> 4 :: Int
      _ -> 3
    withPackages project described (Object value) =
      Object (foldr (\(k, v) -> KM.insert k v) value (packagesView project described))
    withPackages _ _ value = value
    versioned (Object value) = Object (KM.insert "schemaVersion" (toJSON responseVersion) value)
    versioned value = value
    request = withObject "request" $ \o -> do
      version <- o .:? "schemaVersion" .!= (3 :: Int)
      unless (version `elem` [3,4]) (fail "LawSpec requires API schemaVersion 3 or 4; see docs/explanation/api-migration.md")
      native <- o .:? "nativeBindings" .!= emptyNativeRequest
      unless (native == emptyNativeRequest || version == 4)
        (fail "nativeBindings requires API schemaVersion 4; schema 3 compilers may ignore bindings")
      -- A project may itself be a package, and may depend on packages whose
      -- sources are supplied alongside its own.
      rootPackage <- o .:? "package" >>= traverse (withObject "package" (\p -> (,) <$> p .: "name" <*> p .: "version"))
      dependencies <- o .:? "dependencies" .!= mempty
      packages <- o .:? "packages" .!= []
      request' <- (,,,,,,,,) <$> o .:? "method" .!= "check" <*> o .: "sources" <*> o .:? "target" .!= "" <*> o .:? "sourceDir" <*> o .:? "testDir" <*> o .:? "machineBits" .!= 64 <*> o .:? "generation" .!= defaultGeneration <*> o .:? "minify" .!= False <*> pure native
      pure (request', (Project rootPackage dependencies, packages))

-- Which generated tests check each law, for running a subset of them.
withTests :: [TestEntry] -> Value -> Value
withTests entries (Object o) = Object (KM.insert "tests" (toJSON (map entry entries)) o)
  where
    entry e = object
      [ "law" .= C.idText (entryLaw e), "unit" .= entryUnit e, "label" .= entryLabel e
      , "index" .= entryIndex e, "file" .= entryFile e, "key" .= entryKey e
      , "callsAdapters" .= entryCallsAdapters e ]
withTests _ value = value

failure :: [Diagnostic] -> Value
failure ds = object ["schemaVersion" .= (3 :: Int), "diagnostics" .= ds]

type Stages = ([Unit], [Expanded], C.Program, BindingPlan, [Obligation], [(Package, [String])], Either [Diagnostic] Plan)

stages :: Project -> [Package] -> [Source] -> Int -> Generation -> NativeRequest -> Either Value Stages
stages project packages sources bits settings native = case preparePackages project packages sources of
  Left ds -> Left (failure ds)
  Right (allSources,visible,described) -> case compileWithImports visible bits settings allSources of
    Left ds -> Left (failure ds)
    Right (us,es) -> case elaborate bits us es of
      Left ds -> Left (failure ds)
      Right core -> case resolveNativeRequest core native of
        Left message -> Left (failure [Diagnostic "native-binding" message Nothing])
        Right bindings -> case dischargeEvidence core of
          Left ds -> Left (failure ds)
          Right evidence -> Right (us, es, core, bindings, evidence, described, planTesting core)

-- The request without the fields that only select a method, target or layout.
sharedRequest :: B.ByteString -> String
sharedRequest bytes = case decode bytes of
  Just (Object o) -> BC.unpack (encode (Object (foldr (KM.delete . K.fromString) o
    ["method", "target", "sourceDir", "testDir", "minify", "cacheDirectory"])))
  _ -> BC.unpack bytes

-- Two entries: each holds a whole compiled program and its plan.
stagesTable :: Table (Either Value Stages)
stagesTable = unsafePerformIO (newTable 2 (const 1))
{-# NOINLINE stagesTable #-}
