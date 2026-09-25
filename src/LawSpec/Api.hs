module LawSpec.Api (dispatch) where
import Data.Aeson
import Control.Monad (unless)
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as B
import LawSpec.Model
import LawSpec.Compile
import LawSpec.Emit

dispatch :: B.ByteString -> B.ByteString
dispatch bytes = encode $ case eitherDecode bytes >>= parseEither request of
  Left err -> failure [Diagnostic "request" err Nothing]
  Right (method,sources,target,sourceDir,testDir,bits,settings) -> case compileWithSettings bits settings sources of
    Left ds -> failure ds
    Right (us,es) -> case method of
      "check" -> result bits settings us es []
      "expand" -> result bits settings us es []
      "planGeneration" -> either failure (result bits settings us es) (emitWithLayoutProfile bits target sourceDir testDir us es)
      _ -> failure [Diagnostic "request" ("unknown method: " ++ method) Nothing]
  where
    request = withObject "request" $ \o -> do
      version <- o .:? "schemaVersion" .!= (2 :: Int)
      unless (version == 2) (fail "LawSpec requires API schemaVersion 2; see API-MIGRATION.md")
      (,,,,,,) <$> o .:? "method" .!= "check" <*> o .: "sources" <*> o .:? "target" .!= "" <*> o .:? "sourceDir" <*> o .:? "testDir" <*> o .:? "machineBits" .!= 64 <*> o .:? "generation" .!= defaultGeneration
    failure ds = object ["schemaVersion" .= (2 :: Int), "diagnostics" .= ds]
    result bits settings us es files = object ["schemaVersion" .= (2 :: Int), "machineBits" .= bits, "generation" .= settings, "refinements" .= [object ["owner" .= unitName u,"declaration" .= r] | u <- us,r <- refinements u], "contracts" .= [object ["owner" .= unitName u,"contract" .= c] | u <- us,c <- contracts u], "diagnostics" .= ([] :: [Diagnostic]), "laws" .= es, "expansions" .= map prettyExpanded es, "files" .= (files :: [Artifact])]
