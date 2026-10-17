-- | Capability contexts are obtained from admitted source schemes, never a
-- request option. They permit symbolic operation typing only, not class laws.
module LawSpec.MigrationScopes (sourceScopes,sourceContext) where

import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import Control.Monad (unless)
import qualified LawSpec.Core as C
import LawSpec.Core.CapabilityScope
import qualified LawSpec.Core.Types as Types
import LawSpec.Elaboration (coreTypeWithSourceRecords)
import LawSpec.Frontend (sourcePropertyId)
import LawSpec.MigrationTemplates (SourceTemplates(..))
import qualified LawSpec.Model as S
import qualified LawSpec.SourceContext as Source

sourceContext :: SourceTemplates -> Source.SourceContext
sourceContext captured=Source.SourceContext (M.fromList [(identity,Source.SourceConstructor fields equations) |
  (identity,fields,equations)<-templateConstructors captured])

sourceScopes :: SourceTemplates -> [S.Expanded] -> Either String CapabilityScopes
sourceScopes captured laws = do
  registry<-Types.makeRegistry (templateDataDeclarations captured)
  rows<-mapM (scope registry)
    ([(C.Id (S.unitName unit++"::"++name),S.typeConstraints ty++
        concat [S.functionRequirements definition | definition<-S.functionDefinitions unit,S.functionName definition==name]) |
      unit<-templateUnits captured,(name,ty)<-S.functions unit,name `notElem` S.operationNames unit]++
     [(sourcePropertyId (S.owner law) (S.name law),S.requirements (S.original law)) | law<-laws])
  let nonempty=[row | row@(_,capabilities)<-rows,capabilities/=noCapabilities]
      made=M.fromList nonempty
  unless (length nonempty==M.size made) (Left "duplicate symbolic capability owner")
  pure made
  where
    scope registry (owner,constraints)=do
      needs<-mapM (constraint registry) constraints
      pure (owner,Capabilities (Set.fromList (concatMap fst needs)) (Set.fromList (concatMap snd needs)))
    constraint registry (S.Capability capability ty)
      | capability `elem` ["Eq","Keyed","Integer"] = do
          (lowered,records)<-coreTypeWithSourceRecords (sourceContext captured)
            (templateDataDeclarations captured) (templateMachineBits captured) ty
          known<-if null records then pure registry else Types.makeRegistry (templateDataDeclarations captured++records)
          equality<-Types.equalityRequirements known lowered
          keyed<-if capability `elem` ["Keyed","Integer"] then Types.keyedRequirements known lowered else pure []
          pure (equality,keyed)
      | otherwise=pure ([],[])
