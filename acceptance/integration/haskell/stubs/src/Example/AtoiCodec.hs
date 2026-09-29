-- User-owned LawSpec adapter.
module Example.AtoiCodec where

import Prelude
import qualified Prelude as P
import qualified Data.Int as I
import qualified Data.Word as W
import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.Complex as C
import qualified LawSpecRuntime as LS
import qualified LawSpecData as Data

-- (Int32 -> Text)
itoa :: I.Int32 -> T.Text
itoa _ = error "itoa"

-- (Text -> Int32)
atoi :: T.Text -> I.Int32
atoi _ = error "atoi"
