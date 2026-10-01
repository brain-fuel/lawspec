module CodecHooks where

import qualified CodecDomain as Domain
import qualified LawSpecData as Data

toParcel :: Data.Parcel a -> (a -> b) -> Either String (Domain.Parcel b)
toParcel (Data.Parcel item) convert = Right (Domain.parcel (convert item))

fromParcel :: Domain.Parcel b -> (b -> a) -> Either String (Data.Parcel a)
fromParcel value convert = Right (Data.Parcel (convert (Domain.unparcel value)))

toChain :: Data.Chain a -> (a -> b) -> Either String (Domain.FlatChain b)
toChain value convert = walk [] value
  where
    walk items Data.ChainStop = Right (Domain.flatChain (reverse items) True)
    walk items (Data.ChainMore item next) = case next of
      Nothing -> Right (Domain.flatChain (reverse (convert item : items)) False)
      Just rest -> walk (convert item : items) rest

fromChain :: Domain.FlatChain b -> (b -> a) -> Either String (Data.Chain a)
fromChain value convert =
  let (items, ended) = Domain.unflatChain value
      tailValue = if ended then Just Data.ChainStop else Nothing
      rebuilt = foldr (\item rest -> Just (Data.ChainMore (convert item) rest)) tailValue items
  in maybe (Left "empty chain without Stop has no logical representation") Right rebuilt

toPositive :: Data.Positive -> Either String Domain.Positive
toPositive (Data.Positive value) = Right (Domain.positive value)

fromPositive :: Domain.Positive -> Either String Data.Positive
fromPositive value = Right (Data.Positive (Domain.unpositive value))
