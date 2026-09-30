-- Native names for data declarations that share a short name. Units scope
-- their declarations, so two units may both declare a Currency; targets with
-- one data namespace qualify such a name by its unit (ShopDomainCurrency).
module LawSpec.DataNames (qualifiedDataName, flatDataCandidates) where

import Data.Char (isAlphaNum, toLower, toUpper)
import qualified LawSpec.Core as C

-- shop.domain::type::Currency becomes ShopDomainCurrency, and its constructor
-- shop.domain::type::Currency::Usd becomes ShopDomainCurrencyUsd.
qualifiedDataName :: String -> String
qualifiedDataName = concatMap capitalize . words . map (\c -> if isAlphaNum c then c else ' ') . dropTypeMarker
  where
    dropTypeMarker (':' : ':' : 't' : 'y' : 'p' : 'e' : ':' : ':' : rest) = "::" ++ dropTypeMarker rest
    dropTypeMarker (c : rest) = c : dropTypeMarker rest
    dropTypeMarker [] = []
    capitalize [] = []
    capitalize (c : cs) = toUpper c : cs

-- For targets whose constructors share the type namespace (TypeConstructor):
-- an ambiguous type is qualified, and its constructors follow the type's final
-- name, so every constructor of ShopDomainCurrency is ShopDomainCurrency<Tag>.
-- A constructor that is still ambiguous is qualified by its own identity.
-- The case function adapts short names to the target (capitalization).
flatDataCandidates :: (String -> String) -> (String -> Bool) -> [C.DataDeclaration] -> [(C.Id, String)]
flatDataCandidates cased forced declarations = types ++ constructors
  where
    shortTypes = [(C.dataId d, cased (C.dataName d)) | d <- declarations]
    shortConstructors = [(C.constructorId c, cased (C.dataName d) ++ cased (C.constructorName c))
      | d <- declarations, c <- C.dataConstructors d]
    ambiguous name xs = length (filter ((== map toLower name) . map toLower . snd) xs) > 1
    types = [(identity, if ambiguous name (shortTypes ++ shortConstructors) || forced name
      then qualifiedDataName (C.idText identity) else name) | (identity, name) <- shortTypes]
    typed = [(C.constructorId c, final ++ cased (C.constructorName c))
      | d <- declarations, Just final <- [lookup (C.dataId d) types], c <- C.dataConstructors d]
    constructors = [(identity, if ambiguous name (types ++ typed) || forced name
      then qualifiedDataName (C.idText identity) else name) | (identity, name) <- typed]
