-- | The names of the built-in rules unit (LawSpec.ContractRules), apart from
-- the source model so that a backend can name the unit without it.
module LawSpec.RuleNames (rulesUnit, rulesAlias) where

rulesUnit :: String
rulesUnit = "lawspec.rules"

-- | The implicit import's alias; prelude.<op> resolves through it.
rulesAlias :: String
rulesAlias = "lawspecRules"
