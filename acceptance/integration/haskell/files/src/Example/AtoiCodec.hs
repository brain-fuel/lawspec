module Example.AtoiCodec where
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
itoa :: Int32 -> Text
itoa = T.pack . show
atoi :: Text -> Int32
atoi = read . T.unpack
