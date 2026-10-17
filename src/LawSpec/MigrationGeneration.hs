-- | Generate both checked programs with the existing emitters. This records
-- generation acceptance and artifacts, never native execution or law truth.
module LawSpec.MigrationGeneration (generationReceipt) where

import Data.Aeson (Value(..),ToJSON,object,(.=),encode)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.List (sortOn)
import qualified LawSpec.Core as C
import LawSpec.Common (Artifact(..),Diagnostic(..),Generation,adapterReference)
import LawSpec.CoreEmit (emitPlanWithNativeOptions)
import LawSpec.Digest (digest,digestHex,digestString)
import LawSpec.NativeRequest
import LawSpec.MigrationBoundary (boundaryReceipt)
import LawSpec.Testing (planTesting)

generationReceipt :: String -> Maybe String -> Maybe String -> Bool -> Generation
  -> Value -> Value -> Value -> C.Program -> C.Program -> NativeRequest -> Maybe NativeRequest -> Value
generationReceipt target sourceDir testDir minify settings bindings originalInputs migratedInputs before after original proposed =
  object ["version" .= (1::Int),"algorithm" .= ("sha256"::String),
    "scope" .= ("existing target emitters and legacy harness plans; no native compiler or implementation execution"::String),
    "status" .= (if accepted old && accepted new then "accepted" else "not-established"::String),
    "target" .= target,"machineBits" .= C.programMachineBits before,
    "sourceDir" .= sourceDir,"testDir" .= testDir,"minify" .= minify,
    "generation" .= settings,"planning" .= ("legacy-harnesses"::String),
    "bindingProposal" .= bindings,
    "sourceInputs" .= object ["before" .= fingerprint originalInputs,"after" .= fingerprint migratedInputs],
    "before" .= old,"after" .= new,
    "nativeBoundary" .= boundaryReceipt target before after original proposed,
    "nativeConformance" .= ("not-established"::String),
    "lawVerification" .= ("not-established-by-generation"::String)]
  where
    fingerprint :: ToJSON a => a -> String
    fingerprint=digestHex . digest . BL.toStrict . encode
    unavailable reason=object ["status" .= ("not-established"::String),"reason" .= reason]
    attempt program request = do
      resolved <- either (Left . pure . (\reason -> Diagnostic "native-binding" reason Nothing)) Right
        (resolveNativeRequest program request)
      plan <- planTesting program
      files <- (++ networkArtifacts request) <$> emitPlanWithNativeOptions minify target sourceDir testDir resolved plan
      pure files
    view result=case result of
      Left diagnostics->object ["status" .= ("rejected"::String),"diagnostics" .= diagnostics]
      Right artifacts->
        let manifest=[object (["path" .= artifactPath file,"ownership" .= ownership file,
              "placement" .= artifactPlacement file,"contentDigest" .= digestHex (digestString (artifactContent file))] ++
              ["adapterReferenceDigest" .= digestHex (digestString reference) | Just reference<-[adapterReference file]]) |
              file<-sortOn artifactPath artifacts]
        in object ["status" .= ("accepted"::String),"diagnostics" .= ([]::[Diagnostic]),
          "files" .= manifest,"artifactDigest" .= fingerprint manifest]
    old=view (attempt before original)
    new=case proposed of
      Nothing->unavailable ("A complete checked binding proposal is required before canonical generation."::String)
      Just request->view (attempt after request)
    accepted (Object fields)=KM.lookup "status" fields==Just (String "accepted")
    accepted _=False
