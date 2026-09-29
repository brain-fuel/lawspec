module CodecDomain
  (Parcel, parcel, unparcel, FlatChain, flatChain, unflatChain,
   Positive, positive, unpositive, copy) where

import Data.Int (Int8)

newtype Parcel a = Parcel a deriving (Eq, Show)
parcel :: a -> Parcel a
parcel = Parcel
unparcel :: Parcel a -> a
unparcel (Parcel value) = value

data FlatChain a = FlatChain [a] Bool deriving (Eq, Show)
flatChain :: [a] -> Bool -> FlatChain a
flatChain = FlatChain
unflatChain :: FlatChain a -> ([a], Bool)
unflatChain (FlatChain values ended) = (values, ended)

newtype Positive = Positive Int8 deriving (Eq, Show)
positive :: Int8 -> Positive
positive = Positive
unpositive :: Positive -> Int8
unpositive (Positive value) = value

copy :: a -> a
copy value = value
