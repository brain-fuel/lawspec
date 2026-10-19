-- User-owned LawSpec adapter.
module Example.Arithmetic (mirror, area, duplicate, countPairs, dropFirst) where

import qualified LawSpecData as Data

size :: Data.Row -> Integer
size Data.RowEnd = 0
size (Data.RowCell (Data.Record3b011c4276dbdecc2735ac0f8fa7ce5517233cc5b302ba305baeed3dec2f677f _ rest)) = 1 + size rest

mirror :: Data.Perfect -> Data.Perfect
mirror leaf@(Data.PerfectLeaf _) = leaf
mirror (Data.PerfectNode (Data.Recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8 left right)) = Data.PerfectNode (Data.Recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8 (mirror right) (mirror left))

area :: Data.Grid -> Integer
area (Data.Grid (Data.Recordc0281b0d702b4d15fb4288afca7f776df7cdbc7cc164691755e2475920fa5bd9 columns rows)) = size rows * size columns

duplicate :: Data.Row -> Data.Halves
duplicate row = Data.Halves (Data.Record90e2e86ad982c9c5e71a6cd286ab605cf2b3d771c37021fb930810c33933eb3d row row)

countPairs :: Data.Row -> Data.Pairs
countPairs = Data.Pairs

dropFirst :: Data.Row -> Data.Rest
dropFirst = Data.Rest
