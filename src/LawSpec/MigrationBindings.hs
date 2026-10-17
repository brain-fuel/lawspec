-- | Binding proposals are obtained from admitted source payload plans and the
-- existing native resolver. Matching this configuration does not verify any
-- external implementation, codec, generator, handler or target executable.
module LawSpec.MigrationBindings (bindingProposal,nativeRequestView) where

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

-- The original wire object is echoed so a coordinator can reject stale facts
-- prepared for another target configuration without reimplementing resolution.
bindingProposal :: String -> Value -> PayloadPlan -> SourceTemplates -> SourceTemplates
  -> C.Program -> C.Program -> NativeRequest -> Maybe NativeRequest -> Either String Value
bindingProposal target requested plan previous next before after original override = do
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
    "targetGeneration" .= ("not-established"::String),"lawVerification" .= ("not-established-by-binding-correspondence"::String)])
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
      let mappings=map migrateType (typeBindings (requestBindings request))
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
    migrateType binding =
      let pairs=case find ((==boundType binding) . C.dataId . fst) (payloadDeclarations plan) of
            Just (old,new)->[(a,b) | (a,b)<-zip (C.dataConstructors old) (C.dataConstructors new)]
            Nothing->[]
          entries=map (migrateConstructor (boundType binding) pairs) (boundConstructors binding)
          hooks=["codec for "++C.idText (boundType binding)++" receives a changed logical representation; its implementation needs independent correspondence checks" |
            boundCodec binding/=Nothing,affected (boundType binding)]
      in (binding{boundConstructors=[made | (made,_,_)<-entries]},concat [changes | (_,changes,_)<-entries],
          hooks++concat [limits | (_,_,limits)<-entries])
    migrateConstructor identity pairs binding=case find ((==boundConstructor binding) . C.constructorName . fst) pairs of
      Just (old,new) | [field]<-C.constructorFields old,[payload]<-C.constructorFields new,
        C.binderType field==C.binderType payload ->
          let changes=[object ["kind" .= ("single-payload-field"::String),"type" .= C.idText identity,
                "constructor" .= boundConstructor binding,"from" .= C.binderName field,"to" .= C.binderName payload,
                "native" .= nativeField mapped] | mapped<-boundFields binding,C.binderName field/=C.binderName payload]
          in (binding{boundFields=[mapped{boundField=C.binderName payload} | mapped<-boundFields binding]},changes,[])
      Just (old,new) | length (C.constructorFields old)>1,[payload]<-C.constructorFields new ->
        (binding{boundFields=[NestedFieldBinding (C.binderName payload) (nativeField mapped) [C.binderName field] index |
          (index,field)<-zip [0..] (C.constructorFields old),mapped<-boundFields binding,boundField mapped==C.binderName field]},
          [object ["kind" .= ("grouped-record-payload"::String),"type" .= C.idText identity,
          "constructor" .= boundConstructor binding,"fields" .=
            [object ["field" .= C.binderName field,"native" .= nativeField mapped,"nativeArgumentIndex" .= index,
              "payloadPath" .= [C.binderName payload,C.binderName field]] |
              (index,field)<-zip [0::Int ..] (C.constructorFields old),mapped<-boundFields binding,boundField mapped==C.binderName field],
          "payload" .= C.binderName payload]],[])
      _->(binding,[],[])

typeNames :: C.Type -> [C.Id]
typeNames (C.TypeVariable _) = []
typeNames (C.Arrow a b)=typeNames a++typeNames b
typeNames (C.Constructor name arguments)=C.Id name:concat [typeNames ty | C.TypeArgument ty<-arguments]

-- Normalize only orders already made irrelevant by the existing resolver.
-- In particular native constructor arguments follow declaration order.
normalized :: NativeRequest -> BindingPlan -> Value
normalized request resolved=nativeRequestView request{requestBindings=Bindings types generators,
  requestFunctions=sortOn functionDeclaration (requestFunctions request),requestNames=sortOn nameDeclaration (requestNames request),
  requestHandlers=sortOn boundAbility (requestHandlers request),requestFailures=sortOn (referenceParts . mappedNative) (requestFailures request),
  requestGoImports=sortOn goImportAlias (requestGoImports request)}
  where
    types=[TypeBinding (C.dataId (resolvedDeclaration binding)) (resolvedNativeType binding)
      [ConstructorBinding (C.constructorName (resolvedConstructor constructor)) (resolvedNativeConstructor constructor)
        (resolvedConstructorStyle constructor) (case resolvedFieldPaths constructor of
          Nothing->[FieldBinding (C.binderName field) native | (field,native)<-resolvedFields constructor]
          Just paths->[NestedFieldBinding label native rest index |
            (index,((_,native),label:rest))<-zip [0..] (zip (resolvedFields constructor) paths)]) |
        constructor<-resolvedConstructors binding] (resolvedCodec binding) (resolvedArguments binding) |
      binding<-sortOn (C.dataId . resolvedDeclaration) (resolvedTypes (bindingRepresentations resolved))]
    generators=sortOn generatorType (generatorBindings (requestBindings request))

fieldView field=object (["field" .= boundField field,"native" .= nativeField field]++case field of
  FieldBinding{}->[]
  NestedFieldBinding{..}->["path" .= nestedFieldPath,"argument" .= fieldArgument])

nativeRequestView :: NativeRequest -> Value
nativeRequestView request=object
  (["types" .= map typeView (typeBindings (requestBindings request)),
    "generators" .= map generatorView (generatorBindings (requestBindings request)),
    "functions" .= map functionView (requestFunctions request),
    "goImports" .= [object ["alias" .= goImportAlias item,"path" .= goImportPath item] | item<-requestGoImports request],
    "erlangIncludes" .= [object ["path" .= erlangIncludePath item,"library" .= erlangIncludeLibrary item] | item<-requestErlangIncludes request],
    "handlers" .= [object ["ability" .= boundAbility item,"native" .= referenceParts (boundNative item)] | item<-requestHandlers request],
    "failures" .= [object ["failure" .= mappedFailure item,"native" .= referenceParts (mappedNative item)] | item<-requestFailures request],
    "names" .= [object ["declaration" .= C.idText (nameDeclaration item),"name" .= nameOverride item] | item<-requestNames request]] ++
    ["rustCrate" .= name | Just name<-[requestRustCrate request]]++
    ["network" .= object (["identity" .= name | Just name<-[networkIdentity item]]++
      ["trusted" .= name | Just name<-[networkTrusted item]]) | Just item<-[requestNetwork request]])
  where
    typeView item=object (["type" .= C.idText (boundType item),"native" .= referenceParts (nativeType item),
      "constructors" .= [object ["constructor" .= boundConstructor constructor,
        "native" .= referenceParts (nativeConstructor constructor),"style" .= style (constructorStyle constructor),
        "fields" .= map fieldView (boundFields constructor)] | constructor<-boundConstructors item]]++
      ["codec" .= object ["toNative" .= referenceParts (codecToNative codec),"fromNative" .= referenceParts (codecFromNative codec)] | Just codec<-[boundCodec item]]++
      ["arguments" .= arguments | Just arguments<-[boundArguments item]])
    generatorView item=object ["type" .= C.idText (generatorType item),"factory" .= referenceParts (generatorFactory item),"stub" .= generatorStub item]
    functionView item=object (["declaration" .= C.idText (functionDeclaration item)]++case functionNative item of
      StaticCall ref->["native" .= referenceParts ref]
      MethodCall name->["method" .= name]
      ConstructorCall ref->["constructor" .= referenceParts ref])
    style RecordConstructor="record"::String
    style VariantConstructor="variant"
    style UnitConstructor="unit"
