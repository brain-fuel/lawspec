-- | Wire projection of input-domain facts. The dependency fingerprint retains
-- transitive checked dependencies, so nominal references and same-named
-- predicate calls cannot conceal a changed domain implementation.
module LawSpec.MigrationDomains (domainSnapshot) where

import Data.Aeson (Value,object,(.=))
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import qualified LawSpec.Core as C
import LawSpec.Core.Migration (normalizedProgram)
import LawSpec.Core.DomainEvidence
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Digest (digest,digestHex)
import LawSpec.Public (valueView)
import qualified LawSpec.Dependencies as Dependencies
import LawSpec.Scalar (Scalar(..))

domainSnapshot :: Bool -> [(C.Id,String)] -> C.Program -> Either String Value
domainSnapshot canonical names program = do
  normalized <- normalizedProgram canonical False names program
  registry <- makeRegistry (C.programDataDeclarations program)
  invoke <- either (Left . show) Right (prepareDefinitions program)
  let definitions=[definition | unit<-C.programUnits program,definition<-C.unitDefinitions unit]
      graph=Dependencies.dependencyGraph (C.programDataDeclarations normalized) (C.programUnits normalized)
      ambient=normalized{C.programDataDeclarations=[],C.programUnits=[unit{C.unitProperties=[],
        C.unitDefinitions=[],C.unitDeclarations=[],C.unitContracts=[]} | unit<-C.programUnits normalized]}
      digestFor property =
        let origin=C.GeneratedFrom (C.propertyId property)
            truth=C.Expr (C.scalarType "Bool") (C.Constant (SBool True)) origin
            domain=property{C.propertyBody=C.Equation (C.Structural (C.scalarType "Bool")) truth truth,
              C.propertyExamples=[],C.propertyHandlers=[]}
            reached=Dependencies.closure graph (Dependencies.lawReferences graph domain)
            known identity=Dependencies.DeclarationNode identity `Set.member` reached
            declarations=M.toAscList (M.fromList [(C.declarationId declaration,declaration) |
              unit<-C.programUnits normalized,declaration<-C.unitDeclarations unit ++ map C.definitionDeclaration (C.unitDefinitions unit),
              known (C.declarationId declaration)])
            contracts=M.toAscList (M.fromList [(C.contractDeclaration contract,contract) |
              unit<-C.programUnits normalized,contract<-C.unitContracts unit,known (C.contractDeclaration contract)])
        in digestHex (digest (BL.toStrict (encode (("migration-input-domain-v1"::String),ambient,
          Dependencies.reachableData graph reached,declarations,contracts,
          Dependencies.reachableDefinitions graph reached,C.propertyInputs property))))
      original=[property | unit<-C.programUnits program,property<-C.unitProperties unit]
      compared=[property | unit<-C.programUnits normalized,property<-C.unitProperties unit]
      bits=C.programMachineBits program
      entry (property,made) = do
        let evidence=inputDomainEvidence registry bits invoke definitions property
            fingerprint=digestFor made
            fields=["comparisonId" .= C.idText (C.propertyId made),"domainDigest" .= fingerprint,"inputCount" .= length (C.propertyInputs made),
              "search" .= domainSearch evidence,"candidateChecks" .= domainCandidateChecks evidence,
              "searchLimit" .= domainSearchLimit evidence,"finiteLimit" .= domainFiniteLimit evidence,
              "notes" .= domainNotes evidence]
        case domainStatus evidence of
          VerifiedInputTuple values -> do
            bindings <- sequence [object . (\value -> ["binder" .= C.idText (C.binderId (C.quantifiedBinder q)),"value" .= value])
              <$> valueView value | (q,value)<-zip (C.propertyInputs made) values]
            pure (object (fields++["status" .= ("inhabited"::String),"witness" .= bindings]))
          CompleteEmptyDomain -> pure (object (fields++["status" .= ("empty"::String),"complete" .= True]))
          InconclusiveDomain reason -> pure (object (fields++["status" .= ("incomplete"::String),"reason" .= reason,"complete" .= False]))
          UnsupportedInputDomain reason -> pure (object (fields++["status" .= ("unsupported"::String),"reason" .= reason,"complete" .= False]))
  entries <- mapM entry (zip original compared)
  pure (object ["status" .= ("available"::String),"version" .= (1::Int),"algorithm" .= ("sha256"::String),
    "machineBits" .= bits,"scope" .= ("input-domain facts only; no law body evaluated or verified"::String),
    "lawBodiesEvaluated" .= False,"domains" .= entries])
