-- Native names for data declarations that share a short name. Units scope
-- their declarations, so two units may both declare a Currency; targets with
-- one data namespace qualify such a name by its unit (ShopDomainCurrency).
module LawSpec.DataNames (qualifiedDataName, flatDataCandidates, isProduct, productConstructors, caseNames) where

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

-- A product has exactly one constructor. Targets represent it as one native
-- record, struct or class named after the type, with no separate constructor
-- name; sums get a closed family of cases.
isProduct :: C.DataDeclaration -> Bool
isProduct declaration = length (C.dataConstructors declaration) == 1

-- Each product's constructor, given the native names of the types: it shares
-- its type's name.
productConstructors :: [C.DataDeclaration] -> [(C.Id, String)] -> [(C.Id, String)]
productConstructors declarations names =
  [ (C.constructorId c, name) | d <- declarations, isProduct d, c <- C.dataConstructors d
  , Just name <- [lookup (C.dataId d) names] ]

-- The nested case names of a sum in targets that nest cases in their type
-- (Java, Kotlin): the constructor's own name, or <name>Case where it would
-- clash with the type or with another case.
caseNames :: String -> [C.DataConstructor] -> [(C.Id, String)]
caseNames owner constructors =
  [ (C.constructorId c, if clash (C.constructorName c) then C.constructorName c ++ "Case" else C.constructorName c)
  | c <- constructors ]
  where
    clash name = name == owner || length (filter ((== name) . C.constructorName) constructors) > 1 ||
      (name ++ "Case") `elem` map C.constructorName constructors

-- For targets whose constructors share the type namespace (TypeConstructor):
-- an ambiguous type is qualified, and a sum's constructors follow the type's
-- final name, so every case of ShopDomainCurrency is ShopDomainCurrency<Tag>.
-- A constructor that is still ambiguous is qualified by its own identity.
-- Products have no constructor name of their own (see productConstructors).
-- The case function adapts short names to the target (capitalization).
flatDataCandidates :: (String -> String) -> (String -> Bool) -> [C.DataDeclaration] -> [(C.Id, String)]
flatDataCandidates cased forced declarations = types ++ constructors
  where
    sums = filter (not . isProduct) declarations
    shortTypes = [(C.dataId d, cased (C.dataName d)) | d <- declarations]
    shortConstructors = [(C.constructorId c, cased (C.dataName d) ++ cased (C.constructorName c))
      | d <- sums, c <- C.dataConstructors d]
    ambiguous name xs = length (filter ((== map toLower name) . map toLower . snd) xs) > 1
    types = [(identity, if ambiguous name (shortTypes ++ shortConstructors) || forced name
      then qualifiedDataName (C.idText identity) else name) | (identity, name) <- shortTypes]
    typed = [(C.constructorId c, final ++ cased (C.constructorName c))
      | d <- sums, Just final <- [lookup (C.dataId d) types], c <- C.dataConstructors d]
    constructors = [(identity, if ambiguous name (types ++ typed) || forced name
      then qualifiedDataName (C.idText identity) else name) | (identity, name) <- typed]
