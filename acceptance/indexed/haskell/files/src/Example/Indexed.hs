-- User-owned LawSpec adapter.
module Example.Indexed (replicate, append, zip, flatten) where

import Prelude hiding (replicate, zip)
import qualified Data.Int as I
import qualified LawSpecData as Data

replicate :: Integer -> I.Int8 -> Data.Vec I.Int8
replicate n x = if n <= 0 then Data.VecVNil else Data.VecVCons (Data.VConsDetails x (replicate (n - 1) x))

append :: Data.Vec I.Int8 -> Data.Vec I.Int8 -> Data.Vec I.Int8
append Data.VecVNil ys = ys
append (Data.VecVCons (Data.VConsDetails x xs)) ys = Data.VecVCons (Data.VConsDetails x (append xs ys))

zip :: Data.Vec I.Int8 -> Data.Vec Bool -> Data.Vec Bool
zip (Data.VecVCons (Data.VConsDetails _ xs)) (Data.VecVCons (Data.VConsDetails y ys)) = Data.VecVCons (Data.VConsDetails y (zip xs ys))
zip _ _ = Data.VecVNil

flatten :: Data.Tree I.Int8 -> Data.Vec I.Int8
flatten Data.TreeTip = Data.VecVNil
flatten (Data.TreeBin (Data.BinDetails left right value)) =
  append (flatten left) (Data.VecVCons (Data.VConsDetails value (flatten right)))
