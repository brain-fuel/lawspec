-- User-owned LawSpec adapter.
module Example.Indexed (replicate, append, zip, flatten) where

import Prelude hiding (replicate, zip)
import qualified Data.Int as I
import qualified LawSpecData as Data

replicate :: Integer -> I.Int8 -> Data.Vec I.Int8
replicate n x = if n <= 0 then Data.VecVNil else Data.VecVCons (Data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec x (replicate (n - 1) x))

append :: Data.Vec I.Int8 -> Data.Vec I.Int8 -> Data.Vec I.Int8
append Data.VecVNil ys = ys
append (Data.VecVCons (Data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec x xs)) ys = Data.VecVCons (Data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec x (append xs ys))

zip :: Data.Vec I.Int8 -> Data.Vec Bool -> Data.Vec Bool
zip (Data.VecVCons (Data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec _ xs)) (Data.VecVCons (Data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec y ys)) = Data.VecVCons (Data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec y (zip xs ys))
zip _ _ = Data.VecVNil

flatten :: Data.Tree I.Int8 -> Data.Vec I.Int8
flatten Data.TreeTip = Data.VecVNil
flatten (Data.TreeBin (Data.Recorde00f7d8e028cf6be6e08b4ed1f9853199bee01cf39e5a2faa3e38b8ad29bf271 left right value)) =
  append (flatten left) (Data.VecVCons (Data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec value (flatten right)))
