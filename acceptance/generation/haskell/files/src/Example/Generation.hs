-- User-owned LawSpec adapter: the portable generator under test.
module Example.Generation where

import qualified Data.Int as I
import qualified Data.Text as T
import qualified Data.Word as W
import qualified LawSpecRuntime as LS

generated :: T.Text -> W.Word64 -> I.Int32 -> I.Int32 -> [T.Text]
generated descriptor seed size count = map T.pack (LS.generatedValues (T.unpack descriptor) seed (toInteger size) (toInteger count))

shrunk :: T.Text -> W.Word64 -> I.Int32 -> [T.Text]
shrunk descriptor seed size = map T.pack (LS.shrunkValues (T.unpack descriptor) seed (toInteger size))
