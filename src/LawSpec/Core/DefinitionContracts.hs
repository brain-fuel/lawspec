-- | Definition-only contract selection shared by closed execution and native APIs.
module LawSpec.Core.DefinitionContracts (definitionContracts, checkedDefinitionContracts,validateEmissionDefinitions) where

import LawSpec.Core
import LawSpec.Core.Total (validateDefinitionContracts)
import LawSpec.Core.Value (witnessKeys)
import LawSpec.Scalar (textScalar)
import Control.Monad (unless)
import qualified Data.Set as S

-- | Adapter contracts have separate test wrappers; they must not become effects
-- available to closed definition implementations.
definitionContracts :: [Unit] -> [Contract]
definitionContracts units =
  let identities = S.fromList [declarationId (definitionDeclaration d)
        | unit <- units, d <- unitDefinitions unit]
  in [contract | unit <- units, contract <- unitContracts unit,
      contractDeclaration contract `S.member` identities]

-- | Check logical definitions before the native witness representation is added.
-- This also rejects malformed manually supplied plans at the public emitter.
validateEmissionDefinitions :: Int -> [DataDeclaration] -> [Unit] -> Either String ()
validateEmissionDefinitions bits declarations units =
  either (Left . show) Right (validateDefinitionContracts bits declarations
    (concatMap unitDefinitions units) (definitionContracts units))

-- | Native emitters receive constructions with trailing runtime witnesses.
-- Recheck their logical view, retaining the materialized conditions for runtime
-- enforcement. Witness constants must equal the ones inferred from the declared
-- logical fields; they are not extra logical constructor arguments.
checkedDefinitionContracts :: Int -> [DataDeclaration] -> [Unit] -> Either String [Contract]
checkedDefinitionContracts bits declarations units = do
  let contracts = definitionContracts units
  if null contracts then pure () else
    do
      definitions<-mapM (\definition -> do
        body<-logical (definitionBody definition)
        pure definition{definitionBody=body}) (concatMap unitDefinitions units)
      conditions<-mapM (\contract -> do
        before<-mapM logical (contractPreconditions contract)
        after<-mapM logical (contractPostconditions contract)
        runtime<-mapM logical (contractRuntimePostconditions contract)
        pure contract{contractPreconditions=before,contractPostconditions=after,
          contractRuntimePostconditions=runtime}) contracts
      either (Left . show) Right (validateDefinitionContracts bits declarations definitions conditions)
  pure contracts
  where
    logical original=do
      value<-traverseChildren logical original
      case expressionNode value of
        Construct tag arguments | Just count<-arity (expressionType value) tag,
          length arguments>count -> do
            let (fields,witnesses)=splitAt count arguments
                keys=witnessKeys declarations (expressionType value) tag (map expressionType fields)
                matches expression key=expressionType expression==scalarType "Text" &&
                  expressionNode expression==Constant (textScalar key)
            unless (not (null keys) && length witnesses==length keys && and (zipWith matches witnesses keys))
              (Left "native constructor witness fields do not match its logical payload")
            pure value{expressionNode=Construct tag fields}
        _->pure value
    arity (Constructor name _) tag=lookup tag
      [(constructorId c,length (constructorFields c)) | d<-declarations,dataId d==Id name,c<-dataConstructors d]
    arity _ _=Nothing
