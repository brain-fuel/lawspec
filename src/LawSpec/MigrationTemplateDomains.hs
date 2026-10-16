-- | Input-domain evidence for admitted source templates, including reusable
-- laws omitted from executable Core. Law bodies are never evaluated here.
module LawSpec.MigrationTemplateDomains (withTemplateInputDomains) where

import Data.Aeson (Value(..),object,toJSON,(.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import qualified Data.Text as T
import qualified Data.Map.Strict as M
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import qualified LawSpec.SourceContext as Source
import LawSpec.Common (Diagnostic,message)
import LawSpec.Core.Migration (semanticName)
import LawSpec.Digest (digestHex,digestString)
import LawSpec.Frontend (elaborateWithSourceDeclarations)
import LawSpec.MigrationDomains (domainSnapshot)
import LawSpec.MigrationTemplates (SourceTemplates(..))
import LawSpec.SpecializeDefinitions (specializeDefinitionsWithContext)
import LawSpec.CapabilityCheck (checkCapability)
import LawSpec.Elaboration (coreTypeWithSourceRecords)
import LawSpec.Memo (Table,newTable,memoized)
import System.IO.Unsafe (unsafePerformIO)

-- The anchor binds evidence to every complete source-template component.
-- Matching a domain is never a substitute for matching unused definitions,
-- requirements, expanded bodies, or either population policy.
withTemplateInputDomains :: Bool -> SourceTemplates -> C.Program -> Value -> Value -> Value
withTemplateInputDomains canonical captured core concrete (Object fields) =
  Object (KM.insert "inputDomains" snapshot fields)
  where
    bits=templateMachineBits captured
    anchors=Object (KM.filterWithKey (\key _ -> key `elem`
      ["declarationsDigest","definitionTemplatesDigest","lawTemplatesDigest","lawBodiesDigest"]) fields)
    concreteRows=case concrete of
      Object value | KM.lookup "status" value==Just (String "available"),
        KM.lookup "version" value==Just (Number 1),
        KM.lookup "machineBits" value==Just (toJSON bits),
        KM.lookup "lawBodiesEvaluated" value==Just (Bool False) ->
          case KM.lookup "domains" value of Just (Array rows) -> toList rows; _ -> []
      _ -> []
    properties=[(C.idText (C.unitId unit),property) | unit<-C.programUnits core,property<-C.unitProperties unit]
    reused=if length concreteRows==length properties then zip properties concreteRows else []
    sourceTypes=Source.SourceContext (M.fromList [(identity,Source.SourceConstructor types equations) |
      (identity,types,equations)<-templateConstructors captured])
    -- Harness execution, examples, resources and actual law bodies are not
    -- part of this analysis copy. The original capture remains untouched.
    units=[unit{S.laws=[],S.lawHarness=[],S.unitHarness=Nothing,S.lawHandlers=[],S.lawAssignments=[]} |
      unit<-templateUnits captured]
    names=[(C.Id (S.unitName unit++"::law::"++S.lawName law),S.lawName law) |
      unit<-templateUnits captured,law<-S.laws unit]
    identity law=S.owner law++"::law::"++semanticName canonical (S.name law)
    unsupported :: S.Expanded -> String -> Value
    unsupported law reason=object
      ["comparisonId" .= identity law,"inputCount" .= length (S.inputs law),
       "domainDigest" .= digestHex (digestString (show ("source-template-domain-unavailable-v1"::String,anchors,identity law,S.inputs law))),
       "status" .= ("unsupported"::String),"reason" .= reason,"complete" .= False,
       "search" .= ("unsupported"::String),"candidateChecks" .= (0::Int),"searchLimit" .= (0::Int),"finiteLimit" .= (0::Int),"notes" .= ([]::[String])]
    attach law (Object value)=Object (KM.insert "comparisonId" (String (T.pack (identity law))) value)
    attach law _=unsupported law "The compiler did not return an input-domain row."
    -- Reuse the actual concrete property only when its owner, name and full
    -- input binder names agree with the admitted source expansion.
    existing law=[row | ((owner,property),row)<-reused,owner==S.owner law,
      semanticName canonical (C.propertyName property)==semanticName canonical (S.name law),
      map (C.binderName . C.quantifiedBinder) (C.propertyInputs property)==map S.inputName (S.inputs law)]
    row law
      | null (S.parameters (S.original law)), [value]<-existing law = attach law value
      | not (null dependent) = unsupported law
          ("The input domain depends on reusable-law parameters or resources: "++unwords dependent++". No uniform input witness was established.")
      | otherwise = case materialize law of
          Left reason -> unsupported law reason
          Right program -> case domainSnapshot canonical names program of
            Right (Object values) -> case KM.lookup "domains" values of
              Just (Array found) | [value]<-toList found -> attach law value
              _ -> unsupported law "The domain-only program did not return exactly one input domain."
            Left reason -> unsupported law reason
            _ -> unsupported law "The domain-only program did not return input-domain evidence."
      where
        free=concat [S.typeValueVars (S.inputType input)++concatMap S.exprVars (S.inputRefinements input) | input<-S.inputs law]++
          concat [S.exprVars value | plan<-S.generationPlan law,(_,value)<-S.domainBounds plan]
        dependent=[name | (name,_)<-S.parameters (S.original law)++S.lawResources (S.original law),name `elem` free]
    materialize law = either (Left . unlines . map message) Right $ memoized programs
      (digestHex (digestString (show (canonical,bits,sourceTypes,templateDataDeclarations captured,units,copy)))) $ do
        (specialized,properties)<-specializeDefinitionsWithContext sourceTypes (templateDataDeclarations captured) bits
          (checkCapability (coreTypeWithSourceRecords sourceTypes (templateDataDeclarations captured) bits)
            (templateDataDeclarations captured) bits []) units [copy]
        elaborateWithSourceDeclarations canonical sourceTypes (templateDataDeclarations captured) bits specialized properties
      where
        truth=S.BoolLit True
        copy=law{S.left=truth,S.right=truth,S.guards=[],S.assertion=S.AssertEqual truth truth,
          S.typedExpressions=[],S.refinementArgumentChecks=[],
          S.original=(S.original law){S.parameters=[],S.definition=S.Holds truth,S.examples=[],S.lawResources=[],S.references=[]}}
    snapshot=object ["status" .= ("available"::String),"version" .= (1::Int),"algorithm" .= ("sha256"::String),
      "machineBits" .= bits,"scope" .= ("checked source-template input domains, uniform over admissible law parameters; no law body evaluated"::String),
      "lawBodiesEvaluated" .= False,"sourceTemplates" .= anchors,"domains" .= map row (templateLaws captured)]
withTemplateInputDomains _ _ _ _ value=value

programs :: Table (Either [Diagnostic] C.Program)
programs=unsafePerformIO (newTable (32*1024*1024) (length . show))
{-# NOINLINE programs #-}
