-- User-owned LawSpec adapter.
module Example.Arithmetic (mirror, area, duplicate, countPairs, dropFirst) where

import qualified LawSpecData as Data

size :: Data.Row -> Integer
size Data.RowEnd = 0
size (Data.RowCell _ rest) = 1 + size rest

mirror :: Data.Perfect -> Data.Perfect
mirror leaf@(Data.PerfectLeaf _) = leaf
mirror (Data.PerfectNode left right) = Data.PerfectNode (mirror right) (mirror left)

area :: Data.Grid -> Integer
area (Data.Grid rows columns) = size rows * size columns

duplicate :: Data.Row -> Data.Halves
duplicate row = Data.Halves row row

countPairs :: Data.Row -> Data.Pairs
countPairs = Data.Pairs

dropFirst :: Data.Row -> Data.Rest
dropFirst = Data.Rest
