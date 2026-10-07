-- | Native names for data declarations that share a short name. Units scope
-- their declarations, so two units may both declare a Currency; targets with
-- one data namespace qualify such a name by its unit (ShopDomainCurrency).
module LawSpec.DataNames (qualifiedDataName, flatDataCandidates, isProduct, productConstructors, caseNames, caseInsensitiveCounts, ambiguous) where

import Data.Char (isAlphaNum, toLower, toUpper)
import qualified LawSpec.Core as C
import qualified Data.Map.Strict as M

-- | shop.domain::type::Currency becomes ShopDomainCurrency, and its constructor
-- shop.domain::type::Currency::Usd becomes ShopDomainCurrencyUsd.
qualifiedDataName :: String -> String
qualifiedDataName = concatMap capitalize . words . map (\c -> if isAlphaNum c then c else ' ') . dropTypeMarker
  where
    dropTypeMarker (':' : ':' : 't' : 'y' : 'p' : 'e' : ':' : ':' : rest) = "::" ++ dropTypeMarker rest
    dropTypeMarker (c : rest) = c : dropTypeMarker rest
    dropTypeMarker [] = []
    capitalize [] = []
    capitalize (c : cs) = toUpper c : cs

-- | A product has exactly one constructor. Targets represent it as one native
-- record, struct or class named after the type, with no separate constructor
-- name; sums get a closed family of cases.
isProduct :: C.DataDeclaration -> Bool
isProduct declaration = length (C.dataConstructors declaration) == 1

-- | Each product's constructor, given the native names of the types: it shares
-- its type's name.
productConstructors :: [C.DataDeclaration] -> [(C.Id, String)] -> [(C.Id, String)]
productConstructors declarations names =
  [ (C.constructorId c, name) | d <- declarations, isProduct d, c <- C.dataConstructors d
  , Just name <- [lookup (C.dataId d) names] ]

-- | The nested case names of a sum in targets that nest cases in their type
-- (Java, Kotlin): the constructor's own name, or <name>Case where it would
-- clash with the type or with another case.
caseNames :: String -> [C.DataConstructor] -> [(C.Id, String)]
caseNames owner constructors =
  [ (C.constructorId c, if clash (C.constructorName c) then C.constructorName c ++ "Case" else C.constructorName c)
  | c <- constructors ]
  where
    clash name = name == owner || length (filter ((== name) . C.constructorName) constructors) > 1 ||
      (name ++ "Case") `elem` map C.constructorName constructors

-- | For targets whose constructors share the type namespace (TypeConstructor):
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
    -- Names are compared ignoring case, counted once per list: a program
    -- with many data types would otherwise scan every name for every name.
    shortCounts = caseInsensitiveCounts (shortTypes ++ shortConstructors)
    types = [(identity, if ambiguous shortCounts name || forced name
      then qualifiedDataName (C.idText identity) else name) | (identity, name) <- shortTypes]
    typeTable = M.fromList types
    typed = [(C.constructorId c, final ++ cased (C.constructorName c))
      | d <- sums, Just final <- [M.lookup (C.dataId d) typeTable], c <- C.dataConstructors d]
    typedCounts = caseInsensitiveCounts (types ++ typed)
    constructors = [(identity, if ambiguous typedCounts name || forced name
      then qualifiedDataName (C.idText identity) else name) | (identity, name) <- typed]

-- | How many names in a list are each name, ignoring case.
caseInsensitiveCounts :: [(a, String)] -> M.Map String Int
caseInsensitiveCounts xs = M.fromListWith (+) [(map toLower name, 1) | (_, name) <- xs]

-- | Whether more than one name in the counted list is this one, ignoring case.
ambiguous :: M.Map String Int -> String -> Bool
ambiguous counts name = M.findWithDefault 0 (map toLower name) counts > 1
