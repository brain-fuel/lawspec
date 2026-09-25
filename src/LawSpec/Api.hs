module LawSpec.Api (dispatch) where
import Data.Aeson
import Control.Monad (unless)
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as B
import LawSpec.Model
import LawSpec.Compile
import LawSpec.Frontend (elaborate)
import LawSpec.Testing (planTesting)
import LawSpec.CoreEmit (emitPlanWithLayout)
import LawSpec.Public (programView)

dispatch :: B.ByteString -> B.ByteString
dispatch bytes = encode $ case eitherDecode bytes >>= parseEither request of
  Left err -> failure [Diagnostic "request" err Nothing]
  Right (method,sources,target,sourceDir,testDir,bits,settings) -> case compileWithSettings bits settings sources of
    Left ds -> failure ds
    Right (us,es) -> case elaborate bits us es of
      Left ds -> failure ds
      Right core -> let result files = programView settings us (map prettyExpanded es) files core in case method of
        "check" -> result []
        "expand" -> result []
        "planGeneration" -> either failure result (planTesting core >>= emitPlanWithLayout target sourceDir testDir)
        _ -> failure [Diagnostic "request" ("unknown method: " ++ method) Nothing]

  where
    request = withObject "request" $ \o -> do
      version <- o .:? "schemaVersion" .!= (3 :: Int)
      unless (version == 3) (fail "LawSpec requires API schemaVersion 3; see API-MIGRATION.md")
      (,,,,,,) <$> o .:? "method" .!= "check" <*> o .: "sources" <*> o .:? "target" .!= "" <*> o .:? "sourceDir" <*> o .:? "testDir" <*> o .:? "machineBits" .!= 64 <*> o .:? "generation" .!= defaultGeneration
    failure ds = object ["schemaVersion" .= (3 :: Int), "diagnostics" .= ds]
