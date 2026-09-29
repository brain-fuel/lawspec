module Example.CanonicalUrl where
import Data.Text (Text)
import qualified Data.Text as T
canonicalize :: Text -> Text
canonicalize = T.dropWhileEnd (== '/')
