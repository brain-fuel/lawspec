module Example.Currying where
import LawSpecRuntime (IntegerValue,integerValue)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
sumFour :: Integer -> Integer -> Integer -> Integer -> IntegerValue
sumFour a b c d = integerValue (a+b+c+d)
format, referenceFormat :: Text -> Bool -> Int32 -> Text -> Text
format prefix enabled port suffix = prefix <> (if enabled then T.pack (show port) else T.empty) <> suffix
referenceFormat prefix enabled port suffix = T.concat [prefix, if enabled then T.pack (show port) else T.empty, suffix]
trim :: Text -> Text
trim = T.strip
