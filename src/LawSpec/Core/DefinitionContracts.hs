-- | Definition-only contract selection shared by closed execution and native APIs.
module LawSpec.Core.DefinitionContracts (definitionContracts, checkedDefinitionContracts) where

import LawSpec.Core
import LawSpec.Core.Total (validateDefinitionContracts)
import qualified Data.Set as S

-- | Adapter contracts have separate test wrappers; they must not become effects
-- available to closed definition implementations.
definitionContracts :: [Unit] -> [Contract]
definitionContracts units =
  let identities = S.fromList [declarationId (definitionDeclaration d)
        | unit <- units, d <- unitDefinitions unit]
  in [contract | unit <- units, contract <- unitContracts unit,
      contractDeclaration contract `S.member` identities]

-- | A definition's contracts must hold for the definition itself before native
-- APIs rely on them.
checkedDefinitionContracts :: Int -> [DataDeclaration] -> [Unit] -> Either String [Contract]
checkedDefinitionContracts bits declarations units = do
  let contracts = definitionContracts units
  if null contracts then pure () else
    either (Left . show) Right (validateDefinitionContracts bits declarations
      (concatMap unitDefinitions units) contracts)
  pure contracts
