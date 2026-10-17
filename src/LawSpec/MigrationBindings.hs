-- | Binding proposals are obtained from admitted source payload plans and the
-- existing native resolver. Matching this configuration does not verify any
-- external implementation, codec, generator, handler or target executable.
module LawSpec.MigrationBindings (bindingProposal,bindingProposalWithRequest,nativeRequestView) where

import Control.Monad (unless)
import Data.Aeson (Value(..),object,(.=),encode,toJSON)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.List (sortOn,find)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Migration as Migration
import LawSpec.Core.PayloadTransport (PayloadPlan(..))
import LawSpec.Digest (digest,digestHex)
import LawSpec.Discharge (bindingEvidence)
import LawSpec.Public (obligationView)
import LawSpec.Core.Evidence (obligationUnit,obligationDeclaration,obligationStage)
import LawSpec.MigrationTemplates (SourceTemplates,templateSnapshot)
import LawSpec.NativeBinding
import qualified LawSpec.Targets as Targets
import LawSpec.NativeRequest
import LawSpec.NativeRequestView (nativeRequestView)

-- The original wire object is echoed so a coordinator can reject stale facts
-- prepared for another target configuration without reimplementing resolution.
bindingProposal :: String -> Value -> PayloadPlan -> SourceTemplates -> SourceTemplates
  -> C.Program -> C.Program -> NativeRequest -> Maybe NativeRequest -> Either String Value
bindingProposal target requested plan previous next before after original override =
  fst <$> bindingProposalWithRequest target requested plan previous next before after original override

-- Return the same admitted destination as typed data to compiler consumers.
-- They must not reconstruct a native request from a documentary JSON receipt.
bindingProposalWithRequest :: String -> Value -> PayloadPlan -> SourceTemplates -> SourceTemplates
  -> C.Program -> C.Program -> NativeRequest -> Maybe NativeRequest -> Either String (Value,Maybe NativeRequest)
bindingProposalWithRequest target requested plan previous next before after original override = do
  unless (null target || target `elem` Targets.targets) (Left ("unknown binding migration target: "++target))
  unless (C.programMachineBits before==C.programMachineBits after)
    (Left "native binding migration requires matching machine widths")
  oldPlan<-resolveNativeRequest before original
  -- A supplied destination is always checked, including when automatic
  -- conversion reports an unsupported representation below.
  explicit<-traverse (resolveNativeRequest after) override
  oldSnapshot<-Migration.migrationSnapshot False [] before
  newSnapshot<-Migration.migrationSnapshot True [] after
  oldTemplates<-templateSnapshot False previous
  newTemplates<-templateSnapshot True next
  let (proposed,changes,limits)=automatic original oldPlan
      proposedPlan=resolveNativeRequest after proposed
      selected=case override of Just made->made;Nothing->proposed
      selectedPlan=case explicit of Just made->Right made;Nothing->proposedPlan
      expected=normalized proposed <$> proposedPlan
      actual=normalized selected <$> selectedPlan
      equal=case (expected,actual) of (Right a,Right b)->a==b;_->False
      reasons=limits++[reason | Left reason<-[selectedPlan]]++
        ["destination binding choices differ from the checked automatic proposal" | null limits,Right _<-[actual],not equal]
      oldObligations=orderedEvidence oldPlan
      newObligations=orderedEvidence <$> selectedPlan
      evidenceMatches=case newObligations of Right made->oldObligations==made;_->False
      status=if null reasons && equal && evidenceMatches then "matched" else "not-established"::String
      candidate=case selectedPlan of Right made->normalized selected made;Left _->nativeRequestView proposed
      pair=object ["status" .= (if equal then "matched" else "not-established"::String),"before" .= either (const Null) (toJSON . fingerprint) expected,
        "after" .= either (const Null) (toJSON . fingerprint) actual]
  pure (object ["version" .= (1::Int),"algorithm" .= ("sha256"::String),"status" .= status,
    "scope" .= ("explicit native binding configuration after checked payload adaptation; external behavior and generated APIs remain separate"::String),
    "target" .= target,"machineBits" .= C.programMachineBits before,"inputBindings" .= requested,
    "originalsUnchanged" .= True,"beforeValidated" .= True,"afterValidated" .= either (const False) (const True) selectedPlan,
    "before" .= anchor oldSnapshot,"after" .= anchor newSnapshot,
    "sourceTemplates" .= object ["before" .= anchors oldTemplates,"after" .= anchors newTemplates],
    "bindings" .= pair,"originalBindingsDigest" .= fingerprint (normalized original oldPlan),
    "obligations" .= object ["status" .= (if evidenceMatches then "matched" else "not-established"::String),
      "before" .= map (obligationView []) oldObligations,"after" .= either (const Null) (toJSON . map (obligationView [])) newObligations],
    "proposedNativeBindings" .= candidate,"changes" .= changes,"requirements" .= reasons,
    "proposalComplete" .= null limits,"nativeConformance" .= ("not-established"::String),
    "targetGeneration" .= ("not-established"::String),"lawVerification" .= ("not-established-by-binding-correspondence"::String)],
    case selectedPlan of Right checked | status=="matched" -> Just (normalizedNativeRequest selected checked); _ -> Nothing)
  where
    orderedEvidence=sortOn (\item -> (obligationUnit item,obligationDeclaration item,obligationStage item)) . bindingEvidence
    fingerprint=digestHex . digest . BL.toStrict . encode
    anchor (Object fields)=object ["programDigest" .= KM.lookup "programDigest" fields,
      "definitionPlaneDigest" .= KM.lookup "definitionPlaneDigest" fields,"lawBodiesDigest" .= KM.lookup "lawBodiesDigest" fields]
    anchor _=Null
    anchors (Object fields)=Object (KM.filterWithKey (\key _->key `elem`
      ["declarationsDigest","definitionTemplatesDigest","lawTemplatesDigest","lawBodiesDigest"]) fields)
    anchors _=Null
    changed=Set.fromList [C.dataId old | (old,_)<-payloadDeclarations plan]
    graph=M.fromList [(C.dataId declaration,concat [typeNames (C.binderType field) |
      constructor<-C.dataConstructors declaration,field<-C.constructorFields constructor]) |
      declaration<-C.programDataDeclarations before]
    affected identity=not (Set.null (Set.intersection changed (closure Set.empty [identity])))
    closure seen []=seen
    closure seen (identity:rest) | identity `Set.member` seen=closure seen rest
      | otherwise=closure (Set.insert identity seen) (M.findWithDefault [] identity graph++rest)
    automatic request resolved =
      let mappings=map (migrateType resolved) (typeBindings (requestBindings request))
          generators=["generator for "++C.idText (generatorType generator)++
              " uses a changed generated representation and needs independent native correspondence checks" |
            generator<-generatorBindings (requestBindings request),affected (generatorType generator),
            generatorType generator `notElem` map (C.dataId . resolvedDeclaration) (resolvedTypes (bindingRepresentations resolved))]
          interfaces=[("native function "++C.idText (C.declarationId declaration),C.declarationType declaration) |
              declaration<-map fst (bindingFunctions resolved)++map fst (bindingCalls resolved)]++
            [("mapped native field "++C.idText (C.binderId field),C.binderType field) |
              mapping<-resolvedTypes (bindingRepresentations resolved),constructor<-resolvedConstructors mapping,(field,_)<-resolvedFields constructor]++
            [("native handler operation "++operation,ty) | unit<-C.programUnits before,ability<-C.unitAbilities unit,
              C.Id (C.abilityKey (C.abilityInstance ability)) `elem` map fst (bindingHandlers resolved),
              (operation,ty)<-C.abilityOperations ability]
          functions=[label++" exposes a changed generated representation without a corresponding native type binding" |
            (label,ty)<-interfaces,identity<-Set.toList (Set.fromList (typeNames ty)),affected identity,
            identity `notElem` map (C.dataId . resolvedDeclaration) (resolvedTypes (bindingRepresentations resolved))]
      in (request{requestBindings=(requestBindings request){typeBindings=[binding | (binding,_,_)<-mappings]}},
          concat [changes | (_,changes,_)<-mappings],concat [limits | (_,_,limits)<-mappings]++generators++functions)
    migrateType resolved binding =
      let pairs=case find ((==boundType binding) . C.dataId . fst) (payloadDeclarations plan) of
            Just (old,new)->[(a,b) | (a,b)<-zip (C.dataConstructors old) (C.dataConstructors new)]
            Nothing->[]
          originals=[constructor | mapping<-resolvedTypes (bindingRepresentations resolved),
            C.dataId (resolvedDeclaration mapping)==boundType binding,constructor<-resolvedConstructors mapping]
          entries=map (migrateConstructor (boundType binding) pairs originals) (boundConstructors binding)
          hooks=["codec for "++C.idText (boundType binding)++" receives a changed logical representation; its implementation needs independent correspondence checks" |
            boundCodec binding/=Nothing,affected (boundType binding)]
      in (binding{boundConstructors=[made | (made,_,_)<-entries]},concat [changes | (_,changes,_)<-entries],
          hooks++concat [limits | (_,_,limits)<-entries])
    migrateConstructor identity pairs originals binding=case find ((==boundConstructor binding) . C.constructorName . fst) pairs of
      Just (old,new) | [field]<-C.constructorFields old,[payload]<-C.constructorFields new,
        C.binderType field==C.binderType payload ->
          let changes=[object ["kind" .= ("single-payload-field"::String),"type" .= C.idText identity,
                "constructor" .= boundConstructor binding,"from" .= C.binderName field,"to" .= C.binderName payload,
                "native" .= nativeField mapped] | mapped<-boundFields binding,C.binderName field/=C.binderName payload]
          in (binding{boundFields=[mapped{boundField=C.binderName payload} | mapped<-boundFields binding]},changes,[])
      Just (old,new) | length (C.constructorFields old)>1,[payload]<-C.constructorFields new ->
        case find ((==C.constructorId old) . C.constructorId . resolvedConstructor) originals of
          Nothing->(binding,[],["checked original constructor layout is unavailable"])
          Just original->
            let fields=resolvedFields original
                paths=case resolvedFieldPaths original of
                  Just values->values
                  Nothing->[[C.binderName field] | (field,_)<-fields]
                ordered=zip [0::Int ..] (zip fields paths)
            in (binding{boundFields=[NestedFieldBinding (C.binderName payload) native path index |
                  (index,((_,native),path))<-ordered]},
                [object ["kind" .= ("grouped-record-payload"::String),"type" .= C.idText identity,
                  "constructor" .= boundConstructor binding,"fields" .=
                    [object ["field" .= label,"native" .= native,"nativeArgumentIndex" .= index,
                      "payloadPath" .= (C.binderName payload:path)] |
                      (index,((_,native),path@(label:_)))<-ordered],
                  "payload" .= C.binderName payload]],[])
      _->(binding,[],[])

typeNames :: C.Type -> [C.Id]
typeNames (C.TypeVariable _) = []
typeNames (C.Arrow a b)=typeNames a++typeNames b
typeNames (C.Constructor name arguments)=C.Id name:concat [typeNames ty | C.TypeArgument ty<-arguments]

-- Normalize only orders already made irrelevant by the existing resolver.
-- In particular native constructor arguments follow declaration order.
normalized :: NativeRequest -> BindingPlan -> Value
normalized request resolved=nativeRequestView (normalizedNativeRequest request resolved)
