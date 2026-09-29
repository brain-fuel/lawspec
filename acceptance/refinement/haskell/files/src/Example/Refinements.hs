module Example.Refinements where
import LawSpecRuntime (IntegerValue,integerValue)
import Data.Int
import Data.Word
import Data.Text (Text)
import qualified Data.Text as T
add :: Int8 -> Int8 -> IntegerValue
add a b = integerValue (toInteger a+toInteger b)
successor :: Int8 -> IntegerValue
successor a = integerValue (toInteger a+1)
count :: Text -> IntegerValue
count = integerValue . T.length
preserve :: Word64 -> IntegerValue
preserve = integerValue
positive :: Int8 -> Int8
positive = id
abstractEcho :: Integer -> IntegerValue
abstractEcho = integerValue
