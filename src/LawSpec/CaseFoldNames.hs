-- | Shared identities for the compiler-owned portable text provider. Backends
-- depend on these names without importing source syntax or inference.
-- ref:DEC-typed-core-boundary
module LawSpec.CaseFoldNames
  (caseFoldUnit,caseFoldAlias,caseFoldOperation) where

caseFoldUnit, caseFoldAlias :: String
caseFoldUnit = "lawspec.text"
caseFoldAlias = "lawspecText"

caseFoldOperation :: String -> Maybe String
caseFoldOperation "caseFold" = Just "textCaseFold"
caseFoldOperation "textContains" = Just "textContains"
caseFoldOperation _ = Nothing
