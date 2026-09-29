module Example.Slug where
import Data.Text (Text)
import qualified Data.Text as T
normalize :: Text -> Text
normalize = T.replace (T.pack " ") (T.pack "-")
referenceNormalize :: Text -> Text
referenceNormalize = T.map (\c -> if c == ' ' then '-' else c)
