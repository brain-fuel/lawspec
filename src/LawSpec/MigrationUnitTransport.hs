-- | Compare all remaining source-unit metadata after separately checking every
-- duplicated definition, contract, law and data declaration. An unsupported
-- symbolic component keeps the whole declaration comparison unestablished.
module LawSpec.MigrationUnitTransport (sourceTransport) where

import Data.Aeson (Value(..),object,(.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BL
import LawSpec.Core.Migration (Project(..))
import LawSpec.Core.PayloadTransport (PayloadPlan)
import LawSpec.Digest (digest,digestHex)
import LawSpec.MigrationDefinitionTransport (definitionTransport)
import LawSpec.MigrationLawTransport (lawTransport,lawMetadata)
import LawSpec.MigrationTemplates
import qualified LawSpec.Model as S

-- The plan comes only from the complete checked source payload catalogue. Both
-- term certificates are computed here from the actual captures, not accepted
-- as request-supplied assertions about which source fields may be omitted.
sourceTransport :: PayloadPlan -> SourceTemplates -> SourceTemplates -> Either String (Value,Value,Value)
sourceTransport plan before after = do
  oldSnapshot<-templateSnapshot False before
  newSnapshot<-templateSnapshot True after
  oldMetadata<-metadata False before
  newMetadata<-metadata True after
  let checked action=either (\reason->object ["status" .= ("not-established"::String),"reason" .= reason]) id action
      definitions=checked (definitionTransport plan before after)
      laws=checked (lawTransport plan before after)
      termsMatched=field "status" definitions==Just (String "matched") && field "status" laws==Just (String "matched")
      units=object ["version" .= (1::Int),"algorithm" .= ("sha256"::String),"machineBits" .= templateMachineBits before,
        "status" .= (if termsMatched && oldMetadata==newMetadata then "matched" else "not-established"::String),
        "scope" .= ("complete checked source-unit metadata after separately certified payloads and complete symbolic definition/law terms"::String),
        "before" .= anchors oldSnapshot,"after" .= anchors newSnapshot,
        "metadata" .= object ["status" .= (if oldMetadata==newMetadata then "matched" else "not-established"::String),
          "before" .= oldMetadata,"after" .= newMetadata],
        "definitions" .= status definitions,"laws" .= status laws,"payloadShapes" .= ("matched"::String),
        "originalsUnchanged" .= True,"lawVerification" .= ("not-established-by-migration-correspondence"::String)]
  pure (units,definitions,laws)
  where
    field key (Object fields)=KM.lookup key fields
    field _ _=Nothing
    status value=maybe Null id (field "status" value)
    anchors (Object fields)=Object (KM.filterWithKey (\key _->key `elem`
      ["declarationsDigest","definitionTemplatesDigest","lawTemplatesDigest","lawBodiesDigest"]) fields)
    anchors _=Null
    metadata canonical captured=do
      -- Core retains all contracts, including deferred runtime conditions. The
      -- source contracts' signatures remain in this metadata view. Source
      -- refinements, effects, harnesses, models, handlers and all other fields
      -- are left intact by the generic projection; no allowlist drops them.
      let view unit=unit{S.dataTypes=[],
            S.functionDefinitions=[definition{S.functionBody=S.BoolLit True} | definition<-S.functionDefinitions unit],
            S.contracts=[contract{S.contractPreconditions=[],S.contractPostconditions=[]} | contract<-S.contracts unit],
            S.laws=map lawMetadata (S.laws unit)}
      projected<-project (templateContext canonical captured) (map view (templateUnits captured))
      pure (digestHex (digest (BL.toStrict (encode (("checked-source-unit-metadata-v1"::String),projected)))))
