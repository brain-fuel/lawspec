-- | Symbolic, comparison-only coverage of the complete pre-specialization
-- definition plane. Free type variables remain free: no representative native
-- type, law parameter implementation, or sampled input stands in for a scheme.
module LawSpec.MigrationDefinitionTransport (definitionTransport) where

import Control.Monad (unless)
import Data.Aeson (Value(..),object,(.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import qualified LawSpec.Core as C
import LawSpec.Core.Migration (Context(..),Project(..))
import LawSpec.Core.PayloadTransport (PayloadPlan,transportComparisonWithScopes)
import LawSpec.Digest (digest,digestHex)
import LawSpec.MigrationElaboration (symbolicProgram)
import LawSpec.MigrationTemplates (SourceTemplates(..),templateSnapshot)
import qualified LawSpec.Model as S

-- Both inputs have already passed ordinary frontend admission. Lower all
-- definitions together so that unused generic bodies and their transitive
-- dependencies receive the same independent Core and totality checks as
-- executable definitions. An unsupported scheme is a limit, never an opaque
-- replacement for a known body.
definitionTransport :: PayloadPlan -> SourceTemplates -> SourceTemplates -> Either String Value
definitionTransport plan before after = do
  unless (templateMachineBits before==templateMachineBits after)
    (Left "source definition transport requires matching machine widths")
  previous <- templateSnapshot False before
  next <- templateSnapshot True after
  oldHeaders <- headers before
  newHeaders <- headers after
  let headerClaim=object ["status" .= (if oldHeaders==newHeaders then "matched" else "not-established"::String),
        "before" .= oldHeaders,"after" .= newHeaders,
        "scope" .= ("all source definition interfaces, requirements and source/template identities; bodies covered by checked Core"::String)]
      anchors (Object fields)=Object (KM.filterWithKey (\key _ -> key `elem`
        ["declarationsDigest","definitionTemplatesDigest","lawTemplatesDigest","lawBodiesDigest"]) fields)
      anchors _=Null
      evidence = do
        (old,oldScopes) <- symbolicProgram False before (templateUnits before) []
        (new,newScopes) <- symbolicProgram True after (templateUnits after) []
        symbolic . snd <$> transportComparisonWithScopes oldScopes newScopes plan [] old [] new
      (matched,core) = case evidence of
        Left reason -> (False,object ["status" .= ("not-established"::String),"reason" .= reason])
        Right view -> (field "status" view==Just (String "matched"),view)
  pure (object ["status" .= (if oldHeaders==newHeaders && matched then "matched" else "not-established"::String),
    "version" .= (1::Int),"algorithm" .= ("sha256"::String),"machineBits" .= templateMachineBits before,
    "scope" .= ("complete pre-specialization checked definition templates, including unused generic bodies; law templates remain separate"::String),
    "before" .= anchors previous,"after" .= anchors next,
    "interfaces" .= headerClaim,"typedCore" .= core,
    "typeVariables" .= ("symbolic; no sample instantiations"::String),
    "originalsUnchanged" .= True,"lawVerification" .= ("not-established-by-migration-correspondence"::String),
    "nativeConformance" .= ("not-established"::String)])
  where
    field key (Object fields)=KM.lookup key fields
    field _ _=Nothing
    -- The shared transport also serves concrete executable programs. These
    -- snapshots instead contain unspecialized definitions; label that scope
    -- explicitly without changing any fingerprints or correspondence claims.
    symbolic (Object fields)=Object (KM.insert "scope"
      (String "complete checked unspecialized definition Core after certified payload transport")
      (KM.mapWithKey (\key value -> if key `elem` ["before","after"] then snapshot value else value) fields))
      where
        snapshot (Object values)=Object (KM.insert "scope"
          (String "checked unspecialized definition Core; source requirements are separately fingerprinted") values)
        snapshot value=value
    symbolic value=value

-- The complete ordinary Core covers bodies, contracts, exact literals,
-- evaluation order, effects and dependencies. It does not store every source
-- capability requirement or generic declaration header. Keep those separately,
-- from BOTH the actual units and the audited template catalogue. Only the
-- duplicate functionBody field is replaced in this nonexecuting header view.
headers :: SourceTemplates -> Either String String
headers captured = do
  let source=[(S.unitName unit,S.functionDefinitions unit) | unit<-templateUnits captured]
      checked=[(owner,[definition | (definition,_,_,_)<-definitions]) |
        (owner,definitions)<-templateDefinitions captured]
      identities values=[owner++"::"++S.functionName definition | (owner,definitions)<-values,definition<-definitions]
      unique values=unless (length values==Set.size (Set.fromList values))
        (Left "duplicate source definition identity in migration capture")
  unique (identities source)
  unique (identities checked)
  unless (Set.fromList (identities source)==Set.fromList (identities checked))
    (Left "the complete source definition and checked template catalogues differ")
  old <- project plain [(owner,[header definition | definition<-definitions]) | (owner,definitions)<-source]
  audited <- project plain [(owner,[header definition | definition<-definitions]) | (owner,definitions)<-checked]
  pure (digestHex (digest (BL.toStrict (encode (("checked-definition-interfaces-v1"::String),old,audited)))))
  where
    header definition=definition{S.functionBody=S.BoolLit True}
    plain=Context False False M.empty M.empty M.empty (C.Id "definition-interfaces") 0 False Right Right Set.empty M.empty Right
