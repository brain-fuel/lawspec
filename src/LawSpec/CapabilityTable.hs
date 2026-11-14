-- | The built-in capabilities and their instances, in one table. The parser,
-- the declaration checks and the capability check all read it.
-- ref:DEC-capability-instances
module LawSpec.CapabilityTable
  ( capabilityNames
  , tableInstance
  ) where

import LawSpec.Model (Type(..))

-- | Capabilities decided from a type's own declaration: its scalars, fields
-- and constructors. `LawSpec.CapabilityCheck` holds their rules.
structuralCapabilities :: [String]
structuralCapabilities = ["Eq", "Integer", "Ordered", "Bounded", "Keyed"]

-- | Capabilities with a fixed list of instances, each given by the shape of
-- the type it applies to.
instances :: [(String, [Type -> Bool])]
instances =
  [ ("Mappable", [constructor "List", partial "Either" 1])
  , ("Filterable", [constructor "List"])
  , ("Foldable", [constructor "List"])
  , ("Appendable", [applied "List", scalar "Text", scalar "Bytes"])
  ]
  where
    -- A type constructor still waiting for its element type, such as List.
    constructor name ty = ty == Named name
    -- A type constructor given some of its arguments, such as Either e.
    partial name given ty = case ty of
      Application applied' arguments -> applied' == name && length arguments == given
      _ -> False
    -- A whole type built with the constructor, such as List a.
    applied name ty = case ty of
      Applied applied' _ -> applied' == name
      Application applied' [_] -> applied' == name
      _ -> False
    scalar name ty = ty == Named name

-- | Every name a `requires` clause may use.
capabilityNames :: [String]
capabilityNames = structuralCapabilities ++ map fst instances

-- | Whether the type is an instance, for a capability the table decides;
-- Nothing for a structural capability.
tableInstance :: String -> Type -> Maybe Bool
tableInstance name ty = (\shapes -> any ($ ty) shapes) <$> lookup name instances
