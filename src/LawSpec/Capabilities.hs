-- Capability discharge shared by declaration and law checking.
module LawSpec.Capabilities (satisfiedWithData) where

import LawSpec.Model
import LawSpec.Scalar
import qualified LawSpec.Core as Core
import qualified LawSpec.Core.Types as Types
import LawSpec.Elaboration (coreType)

satisfiedWithData :: [Core.DataDeclaration] -> Int -> [Constraint] -> Constraint -> Bool
satisfiedWithData declarations bits allowed constraint@(Capability name ty)
  | constraint `elem` allowed = True
  | name `elem` ["Eq","Ordered","Keyed"], Capability "Integer" ty `elem` allowed = True
  -- A portable order decides equality too.
  | name == "Eq", Capability "Keyed" ty `elem` allowed = True
  | name == "Keyed" = either (const False) id $ do
      registry <- Types.makeRegistry declarations
      core <- coreType (mapType (\t -> case t of Named n@('@':_) -> Variable n; _ -> t) id ty)
      needed <- Types.keyedRequirements registry core
      pure (all (\n -> let variable = Named (Core.idText n) in
        Capability "Keyed" variable `elem` allowed || Capability "Integer" variable `elem` allowed) needed)
  | name == "Eq" = either (const False) id $ do
      registry <- Types.makeRegistry declarations
      core <- coreType (mapType (\t -> case t of Named n@('@':_) -> Variable n; _ -> t) id ty)
      needed <- Types.equalityRequirements registry core
      pure (all (\n -> let variable = Named (Core.idText n) in
        any (\c -> Capability c variable `elem` allowed) ["Eq", "Keyed", "Integer"]) needed)
  | otherwise = case baseType ty of
      Named n -> case name of
        "Integer" -> isInteger n
        "Ordered" -> isNumeric n && n `notElem` ["Complex64","Complex128"]
        "Bounded" -> maybe False (const True) (integerBounds bits n)
        _ -> False
      _ -> False
