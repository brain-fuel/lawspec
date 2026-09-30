module LawSpec.Api (dispatch) where
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Control.Monad (unless)
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as B
import LawSpec.Model
import LawSpec.Compile
import LawSpec.Frontend (elaborate)
import LawSpec.Testing (planTesting)
import LawSpec.CoreEmit (emitPlanWithNativeOptions)
import LawSpec.NativeRequest
import LawSpec.Public (programView)
import LawSpec.Packages
import LawSpec.Discharge (dischargeEvidence, bindingEvidence)

dispatch :: B.ByteString -> B.ByteString
dispatch bytes = encode $ versioned $ case eitherDecode bytes >>= parseEither request of
  Left err -> failure [Diagnostic "request" err Nothing]
  Right ((method,sources,target,sourceDir,testDir,bits,settings,minify,native),(project,packages)) -> case preparePackages project packages sources of
   Left ds -> failure ds
   Right (allSources,visible,described) -> case compileWithImports visible bits settings allSources of
    Left ds -> failure ds
    Right (us,es) -> case elaborate bits us es of
      Left ds -> failure ds
      Right core -> case resolveNativeRequest core native of
        Left message -> failure [Diagnostic "native-binding" message Nothing]
        Right bindings -> case dischargeEvidence core of
         Left ds -> failure ds
         Right evidence -> let result files = withPackages project described (programView settings us (map prettyExpanded es) files (evidence ++ bindingEvidence bindings) core) in case method of
          "check" -> result []
          "expand" -> result []
          "planGeneration" -> either failure result (planTesting core >>= emitPlanWithNativeOptions minify target sourceDir testDir bindings)
          _ -> failure [Diagnostic "request" ("unknown method: " ++ method) Nothing]

  where
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
    failure ds = object ["schemaVersion" .= (3 :: Int), "diagnostics" .= ds]
