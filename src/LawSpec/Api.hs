module LawSpec.Api (dispatch) where
import Data.Aeson
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as B
import LawSpec.Model
import LawSpec.Compile
import LawSpec.Emit

dispatch :: B.ByteString -> B.ByteString
dispatch bytes = encode $ case eitherDecode bytes >>= parseEither request of
  Left err -> failure [Diagnostic "request" err Nothing]
  Right (method,sources,target,sourceDir,testDir) -> case compile sources of
    Left ds -> failure ds
    Right (us,es) -> case method of
      "check" -> result es []
      "expand" -> result es []
      "planGeneration" -> either failure (result es) (emitWithLayout target sourceDir testDir us es)
      _ -> failure [Diagnostic "request" ("unknown method: " ++ method) Nothing]
  where
    request = withObject "request" $ \o -> (,,,,) <$> o .:? "method" .!= "check" <*> o .: "sources" <*> o .:? "target" .!= "" <*> o .:? "sourceDir" <*> o .:? "testDir"
    failure ds = object ["diagnostics" .= ds]
    result es files = object ["diagnostics" .= ([] :: [Diagnostic]), "laws" .= es, "expansions" .= map prettyExpanded es, "files" .= (files :: [Artifact])]
