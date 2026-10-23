-- User-owned LawSpec adapter.
module Example.Arithmetic (mirror, area, duplicate, countPairs, dropFirst) where

import qualified LawSpecData as Data

size :: Data.Row -> Integer
size Data.RowEnd = 0
size (Data.RowCell (Data.CellDetails _ rest)) = 1 + size rest

mirror :: Data.Perfect -> Data.Perfect
mirror leaf@(Data.PerfectLeaf _) = leaf
mirror (Data.PerfectNode (Data.NodeDetails left right)) = Data.PerfectNode (Data.NodeDetails (mirror right) (mirror left))

area :: Data.Grid -> Integer
area (Data.Grid (Data.GridDetails columns rows)) = size rows * size columns

duplicate :: Data.Row -> Data.Halves
duplicate row = Data.Halves (Data.HalvesDetails row row)

countPairs :: Data.Row -> Data.Pairs
countPairs = Data.Pairs

dropFirst :: Data.Row -> Data.Rest
dropFirst = Data.Rest
