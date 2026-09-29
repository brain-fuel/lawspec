module Example.Alternatives where
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Builder as B
import qualified Data.Text.Lazy.Builder.Int as B
render :: Int32 -> Text
render = T.pack . show
referenceRender :: Int32 -> Text
referenceRender = TL.toStrict . B.toLazyText . B.decimal
clamp :: Int32 -> Int32
clamp = max 0
referenceClamp :: Int32 -> Int32
referenceClamp x = if x < 0 then 0 else x
