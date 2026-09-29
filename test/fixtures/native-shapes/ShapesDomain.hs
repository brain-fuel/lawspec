module ShapesDomain where

newtype Wrapped a = Wrapped { stored :: a } deriving (Eq, Show)
data Link a = End | Next { remainder :: Maybe (Link a), item :: a }
  deriving (Eq, Show)
data Forest a = Item { datum :: a } | Group { trees :: [Forest a] }
  deriving (Eq, Show)
data Seal = Seal deriving (Eq, Show)

copy :: a -> a
copy value = value
