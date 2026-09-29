-- User-owned LawSpec adapter.
module Example.Indexed (replicate, append, zip, flatten) where

import Prelude hiding (replicate, zip)
import qualified Data.Int as I
import qualified LawSpecData as Data

replicate :: Integer -> I.Int8 -> Data.Vec I.Int8
replicate n x = if n <= 0 then Data.VecVNil else Data.VecVCons x (replicate (n - 1) x)

append :: Data.Vec I.Int8 -> Data.Vec I.Int8 -> Data.Vec I.Int8
append Data.VecVNil ys = ys
append (Data.VecVCons x xs) ys = Data.VecVCons x (append xs ys)

zip :: Data.Vec I.Int8 -> Data.Vec Bool -> Data.Vec Bool
zip (Data.VecVCons _ xs) (Data.VecVCons y ys) = Data.VecVCons y (zip xs ys)
zip _ _ = Data.VecVNil

flatten :: Data.Tree I.Int8 -> Data.Vec I.Int8
flatten Data.TreeTip = Data.VecVNil
flatten (Data.TreeBin left value right) =
  append (flatten left) (Data.VecVCons value (flatten right))
