module Example.Mixed.Inputs where
import Data.Text (Text)
import Data.Int (Int32)
import qualified Data.Text as T
normalize :: Text -> Text
normalize = T.replace (T.pack " ") (T.pack "-")
identity :: Int32 -> Int32
identity = id
