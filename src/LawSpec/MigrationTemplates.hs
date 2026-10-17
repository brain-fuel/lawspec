{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}
-- | Comparison metadata from the existing checked frontend, before unused
-- generic definitions and reusable laws leave the concrete executable program.
-- No syntax here is executed or admitted by a separate checking mechanism.
module LawSpec.MigrationTemplates
  ( SourceTemplates(..), DefinitionTemplate, templateSnapshot, templateContext ) where

import Control.Monad (unless)
import Data.Aeson (Value,object,(.=))
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import GHC.Generics (from,to)
import qualified LawSpec.Core as C
import LawSpec.Core.Migration (Project(..),GenericProject(..),Context(..),semanticName,normalizeTrace)
import LawSpec.Common (InputDomain(..))
import LawSpec.Digest (digest,digestHex)
import qualified LawSpec.Model as S
import LawSpec.Persist ()

type DefinitionTemplate = (S.FunctionDefinition,S.TypedExpr,[S.TypedExpr],[S.TypedExpr])

-- These are the actual values consumed by ordinary admission and expansion.
-- Keep complete units as well as typed bodies: declarations, capability
-- requirements, effects and unused contracts must not disappear from a match.
data SourceTemplates = SourceTemplates
  { templateMachineBits :: Int
  , templateUnits :: [S.Unit]
  , templateDefinitions :: [(String,[DefinitionTemplate])]
  , templateLaws :: [S.Expanded]
  , templateDataDeclarations :: [C.DataDeclaration]
  , templateConstructors :: [(C.Id,[S.Type],[(C.Id,S.Type)])]
  } deriving (Eq,Show)

instance Project S.Expr where
  project context (S.Located _ value) = project context value
  project context value = to <$> genericProject context (from value)

instance Project S.Unit where
  project context value = do
    made <- to <$> genericProject context (from value)
    -- A canonical function records an explicit empty ability row. A legacy
    -- definition with an inferred empty row has the same checked interface.
    -- Keep nonempty annotations and every adapter annotation verbatim.
    let pureDefinition name = name `elem` map S.functionName (S.functionDefinitions value) &&
          null (M.findWithDefault [] name (M.fromList (S.abilityRows value)))
    pure made{S.declaredUses=[entry | entry@(name,row)<-S.declaredUses made,
      not (null row && pureDefinition name)]}

-- Only fields that actually denote names receive delimiter normalization.
-- In particular StringLit, Symbol IDs, descriptions, labels and opaque text
-- remain byte-for-byte values under the generic traversal.
instance Project S.Law where
  project context value = do
    made <- to <$> genericProject context (from value)
    pure made{S.lawName=rename context (S.lawName value)}

instance Project S.Example where
  project context value = do
    made <- to <$> genericProject context (from value)
    pure made{S.exampleName=semanticName (canonicalSource context) (S.exampleName value)}

instance Project S.Definition where
  project context value = case value of
    S.Invoke name arguments -> S.Invoke (rename context name) <$> project context arguments
    _ -> to <$> genericProject context (from value)

instance Project S.Expanded where
  project context value = do
    made <- to <$> genericProject context (from value)
    pure made{S.name=rename context (S.name value),S.trace=map (renameTrace context) (S.trace value),
      S.inputDomain=if omitDomainPolicy context then UniversalDomain else S.inputDomain value}

rename :: Context -> String -> String
rename context name = M.findWithDefault name name (traceNames context)

-- Expansion constructs these traces from a law name and printed arguments.
-- Normalize only a uniquely recognized declaration-name prefix; leave the
-- argument suffix untouched, including phrase-looking literal contents.
renameTrace :: Context -> String -> String
renameTrace=normalizeTrace

templateSnapshot :: Bool -> SourceTemplates -> Either String Value
templateSnapshot canonical captured = do
  -- Reject a normalization collision before comparing serialized identities.
  mapM_ unique [(S.unitName unit,map (rename context . S.lawName) (S.laws unit)) | unit<-templateUnits captured]
  units <- project context (templateUnits captured)
  definitions <- project context (templateDefinitions captured)
  laws <- project context (templateLaws captured)
  bodies <- project context{omitDomainPolicy=True} (templateLaws captured)
  declarations <- project context (templateDataDeclarations captured)
  constructors <- project context (templateConstructors captured)
  pure (object
    [ "status" .= ("available"::String),"version" .= (1::Int),"algorithm" .= ("sha256"::String)
    , "machineBits" .= templateMachineBits captured
    , "scope" .= ("complete pre-specialization checked source units, typed definition templates and expanded reusable laws"::String)
    , "declarationsDigest" .= fingerprint (units,declarations,constructors)
    , "definitionTemplatesDigest" .= fingerprint definitions
    , "lawTemplatesDigest" .= fingerprint laws
    , "lawBodiesDigest" .= fingerprint bodies
    , "units" .= [part owner unit | unit<-units,let owner=S.unitName unit]
    , "definitions" .= [part (owner ++ "::" ++ S.functionName definition) value |
        (owner,values)<-definitions,value@(definition,_,_,_)<-values]
    , "laws" .= [part (S.owner law ++ "::law::" ++ S.name law) law | law<-laws]
    , "domainPolicies" .= [object ["comparisonId" .= (S.owner law ++ "::law::" ++ S.name law),"policy" .= S.inputDomain law] | law<-laws]
    ])
  where
    context=templateContext canonical captured
    unique (owner,labels) = unless (Set.size (Set.fromList labels)==length labels)
      (Left ("migration template normalization collides law identities in " ++ owner))
    fingerprint value=digestHex (digest (BL.toStrict (encode (("checked-source-templates-v1"::String),value))))
    part identity value=object ["comparisonId" .= identity,"digest" .= fingerprint value]

templateContext :: Bool -> SourceTemplates -> Context
templateContext canonical captured=Context canonical False M.empty M.empty
  (M.fromList [(name,semanticName canonical name) | unit<-templateUnits captured,law<-S.laws unit,let name=S.lawName law])
  (C.Id "source-templates") 0 False Right Right Set.empty M.empty Right
