-- User-owned LawSpec adapter for example.atoi_codec: implement each function.
module Example.AtoiCodec where

import qualified Data.ByteString as B
import qualified Data.Complex as C
import qualified Data.Int as I
import qualified Data.Text as T
import qualified Data.Word as W
import qualified LawSpecData as Data
import qualified LawSpecRuntime as LS
import Prelude
import qualified Prelude as P

-- itoa :: Int32 -> Text — atoi_codec.lawspec:3
itoa :: I.Int32 -> T.Text
itoa _ = P.error "itoa"

-- atoi :: Text -> Int32 — atoi_codec.lawspec:4
atoi :: T.Text -> I.Int32
atoi _ = P.error "atoi"
