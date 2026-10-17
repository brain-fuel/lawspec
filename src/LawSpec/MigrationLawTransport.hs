-- | Compare reusable-law templates with their parameters kept symbolic. No
-- implementation or witness is chosen. Law bodies are never emitted or
-- executed; independent domain-only checks may use the admitted definitions.
module LawSpec.MigrationLawTransport (lawTransport,lawMetadata) where

import Control.Monad (unless)
import Data.Aeson (Value(..),object,(.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import qualified LawSpec.Core as C
import LawSpec.Core.Migration (Context(..),Project(..),semanticName)
import LawSpec.Core.PayloadTransport (PayloadPlan,transportComparisonWithScopes)
import LawSpec.Digest (digest,digestHex)
import LawSpec.MigrationElaboration (symbolicProgramWithFormalValues)
import LawSpec.Frontend (sourcePropertyId)
import LawSpec.MigrationDomains (withTransportDomainsWithScopes)
import LawSpec.MigrationTemplates
import qualified LawSpec.Model as S

-- The original headers and non-body execution metadata are retained. Only
-- duplicated terms carried by the complete checked property are removed from
-- this nonexecuting comparison view. Uncovered source differences still block.
lawMetadata :: S.Law -> S.Law
lawMetadata law=law{S.definition=S.Holds (S.BoolLit True),S.examples=[]}

lawTransport :: PayloadPlan -> SourceTemplates -> SourceTemplates -> Either String Value
lawTransport plan before after = do
  unless (templateMachineBits before==templateMachineBits after)
    (Left "law template transport requires matching machine widths")
  oldSnapshot<-templateSnapshot False before
  newSnapshot<-templateSnapshot True after
  oldMetadata<-metadata False before
  newMetadata<-metadata True after
  let lowered=do
        (old,oldScopes)<-lower False before
        (new,newScopes)<-lower True after
        (copy,view)<-transportComparisonWithScopes oldScopes newScopes plan (names old) old (names new) new
        pure (withTransportDomainsWithScopes oldScopes newScopes (names old) copy (names new) new view)
      (matched,core)=case lowered of
        Left reason->(False,object ["status" .= ("not-established"::String),"reason" .= reason])
        Right view->(field "status" view==Just (String "matched"),symbolic view)
  pure (object ["version" .= (1::Int),"algorithm" .= ("sha256"::String),"machineBits" .= templateMachineBits before,
    "status" .= (if oldMetadata==newMetadata && matched then "matched" else "not-established"::String),
    "scope" .= ("complete expanded source law templates with symbolic parameters, including unused reusable laws; population policies remain separate"::String),
    "before" .= anchors oldSnapshot,"after" .= anchors newSnapshot,
    "metadata" .= object ["status" .= (if oldMetadata==newMetadata then "matched" else "not-established"::String),
      "before" .= oldMetadata,"after" .= newMetadata],
    "typedCore" .= core,"originalsUnchanged" .= True,"lawBodiesEvaluated" .= False,
    "parameterInterpretation" .= ("lexically bound formal values and fresh abstract function declarations; no parameter implementation or population witness chosen"::String),
    "lawVerification" .= ("not-established-by-migration-correspondence"::String)])
  where
    names program=[(C.propertyId law,C.propertyName law) | unit<-C.programUnits program,law<-C.unitProperties unit]
    field key (Object fields)=KM.lookup key fields
    field _ _=Nothing
    anchors (Object fields)=Object (KM.filterWithKey (\key _->key `elem`
      ["declarationsDigest","definitionTemplatesDigest","lawTemplatesDigest","lawBodiesDigest"]) fields)
    anchors _=Null
    symbolic (Object fields)=Object (KM.insert "scope" (String "checked symbolic law-template Core; population policies remain separate") fields)
    symbolic value=value
    metadata canonical captured=do
      let lawView law=law{S.left=S.BoolLit True,S.right=S.BoolLit True,S.guards=[],
            S.assertion=S.AssertEqual (S.BoolLit True) (S.BoolLit True),S.typedExpressions=[],
            S.original=lawMetadata (S.original law)}
      projected<-project (templateContext canonical captured){omitDomainPolicy=True} (map lawView (templateLaws captured))
      pure (digestHex (digest (BL.toStrict (encode (("checked-law-template-metadata-v1"::String),projected)))))
    lower canonical captured=do
      made<-mapM (parameterized canonical) (templateLaws captured)
      let laws=[law | (law,_,_)<-made]
          declarations=[(S.owner law,functions) | (law,functions,_)<-made]
          formals=M.fromList [(sourcePropertyId (S.owner law) (S.name law),count) | (law,_,count)<-made,count>0]
          units=[unit{S.functions=S.functions unit++concat [functions | (owner,functions)<-declarations,owner==S.unitName unit]} |
            unit<-templateUnits captured]
      mapM_ (\unit->unless (length (S.functions unit)==Set.size (Set.fromList (map fst (S.functions unit))))
        (Left "symbolic law parameter declaration collides with a source declaration")) units
      symbolicProgramWithFormalValues formals canonical captured units laws
    parameterized canonical law=do
      let parameters=S.parameters (S.original law)
          occupied=map S.inputId (S.inputs law++S.assertionInputs (S.assertion law))
          identity=digestHex (digest (BL.toStrict (encode (S.owner law,semanticName canonical (S.name law)))))
          -- These are universally scoped type variables, just as in ordinary
          -- reusable-law expansion. Keeping them rigid prevents two callback
          -- invocations from choosing different error or result carriers.
          rigid=S.mapType (\value->case value of
            S.Variable name->scoped name
            S.Named ('@':name)->scoped name
            other->other) (S.mapExprTypes rigid)
          scoped name=S.Named ("@<law-type:"++identity++":"++name++">")
          formal index="<law-parameter:"++identity++":"++show index++">"
          declarations=[(formal index,rigid value) | (index,(_,value))<-zip [0::Int ..] parameters,isFunctionParameter value]
          replacements=[(name,S.Var (formal index)) | (index,(name,_))<-zip [0::Int ..] parameters]
          term=S.mapExprTypes rigid . S.replaceExprVars replacements
          ty=rigid . S.replaceTypeValueVars replacements
          values=[S.Input name (formal index) (S.baseType (ty value))
            (S.typePredicates (S.Var (formal index)) (ty value)) |
            (index,(name,value))<-zip [0::Int ..] parameters,not (isFunctionParameter value)]
          input value=value{S.inputType=ty (S.inputType value),S.inputRefinements=map term (S.inputRefinements value)}
          assertion value=case value of
            S.AssertEqual a b->S.AssertEqual (term a) (term b)
            S.AssertImplies condition body->S.AssertImplies (term condition) (assertion body)
            S.AssertAll bodies->S.AssertAll (map assertion bodies)
            S.AssertNot body->S.AssertNot (assertion body)
            S.AssertQuantified kind binder body->S.AssertQuantified kind (input binder) (assertion body)
          aliases=[(S.inputName binder,S.Var (S.inputId binder)) | binder<-S.inputs law]
          example value=value{S.expectations=[expectation{S.actual=term (S.replaceExprVars aliases (S.actual expectation))} |
            expectation<-S.expectations value]}
          original=(S.original law){S.parameters=[],S.examples=map example (S.examples (S.original law)),
            S.requirements=[S.Capability name (ty value) | S.Capability name value<-
              S.requirements (S.original law)++concatMap (S.typeConstraints.snd) parameters],
            S.lawResources=[(name,ty value) | (name,value)<-S.lawResources (S.original law)]}
      unless (all (`notElem` occupied) (map fst parameters))
        (Left "a symbolic law parameter collides with an expanded input")
      pure (law{S.inputs=values++map input (S.inputs law),S.left=term (S.left law),S.right=term (S.right law),
        S.guards=map term (S.guards law),S.assertion=assertion (S.assertion law),S.original=original,S.typedExpressions=[],
        S.generationPlan=[plan{S.domainInput=input (S.domainInput plan),S.domainBounds=[(operator,term value) |
          (operator,value)<-S.domainBounds plan]} | plan<-S.generationPlan law],
        S.refinementArgumentChecks=map term (S.refinementArgumentChecks law)},declarations,length values)
