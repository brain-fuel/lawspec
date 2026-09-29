-- How each contract and construction obligation of a checked program is discharged. Definition
-- postconditions are proved by the totality audit (compilation fails
-- otherwise), so emitters never re-check them at runtime. Preconditions guard
-- native callers, and adapter contracts cover code LawSpec cannot inspect, so
-- both are checked at runtime.
module LawSpec.Core.Evidence
  ( Status(..), Obligation(..), statusName, programEvidence, runtimePostconditions
  ) where

import qualified Data.Set as S
import LawSpec.Core

data Status = Proved | RuntimeChecked deriving (Eq, Show)

statusName :: Status -> String
statusName Proved = "proved"
statusName RuntimeChecked = "runtime-checked"

data Obligation = Obligation
  { obligationUnit :: Id
  , obligationDeclaration :: Id
  , obligationStage :: String
  , obligationClaim :: Expr
  , obligationStatus :: Status
  , obligationReason :: String
  } deriving (Eq, Show)

programEvidence :: Program -> [Obligation]
programEvidence program =
  concatMap unitEvidence (programUnits program) ++ concatMap dataEvidence (programDataDeclarations program)
  where
    -- Constructor field refinements, including wrapper constraints, make an
    -- invalid value unrepresentable: construction and native decoding check them.
    dataEvidence declaration =
      [ Obligation (dataId declaration) (constructorId constructor) "construction" claim RuntimeChecked
          "checked whenever a value is constructed or decoded"
      | constructor <- dataConstructors declaration, claim <- constructorPredicates constructor ]
    unitEvidence unit =
      let definitions = S.fromList [declarationId (definitionDeclaration d) | d <- unitDefinitions unit]
      in concatMap (contractEvidence (unitId unit) definitions) (unitContracts unit)
    contractEvidence owner definitions contract
      | contractDeclaration contract `S.member` definitions =
          [ obligation "precondition" claim RuntimeChecked "checked before a native caller's arguments reach the definition"
          | claim <- contractPreconditions contract ] ++
          [ obligation "postcondition" claim Proved "proved from the definition body by the totality audit"
          | claim <- contractPostconditions contract ]
      | otherwise =
          [ obligation "precondition" claim RuntimeChecked "checked before each adapter call"
          | claim <- contractPreconditions contract ] ++
          [ obligation "postcondition" claim RuntimeChecked "checked on each native adapter result"
          | claim <- contractPostconditions contract ]
      where obligation stage claim = Obligation owner (contractDeclaration contract) stage claim

-- Definition emitters call this for the result checks they generate. Every
-- definition postcondition is proved, so there is nothing left to check.
runtimePostconditions :: Contract -> [Expr]
runtimePostconditions _ = []
