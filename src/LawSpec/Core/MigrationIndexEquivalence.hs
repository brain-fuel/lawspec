-- | Comparison-only equality of generated index bodies. A changed recursive
-- read must be a pure storage read and pass the ordinary contract prover under
-- the matched constructor's invariants. Neither a name nor matching types is
-- a proof. These helpers are never emitted or used to execute a law.
module LawSpec.Core.MigrationIndexEquivalence (justifyIndexBodies) where

import Control.Monad (guard)
import Data.Aeson (Value,object,(.=))
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified LawSpec.Core as C
import LawSpec.Core.CapabilityScope (CapabilityScopes)
import LawSpec.Core.Expression (operationEvidence)
import LawSpec.Core.Migration (normalizedProgram)
import LawSpec.Core.Total (validateDefinitionContractsWithScopes)
import LawSpec.Core.Validate (validateProgramWithScopes)
import LawSpec.Digest (digest,digestHex)
import LawSpec.IndexTerm (familyIndexNames)

-- Both originals and the payload-transported copy have already been admitted.
-- Prove each local body equation in the old checked environment. Only recursive
-- index reads change; constructor dispatch, arithmetic, other calls and every
-- interface remain identical. The target's mandatory termination check supplies
-- the well-founded recursion needed to identify the two solutions. This is a
-- trusted compiler equivalence transformation, not an external certificate.
justifyIndexBodies :: CapabilityScopes -> [(C.Id,String)] -> C.Program
  -> [(C.Id,String)] -> C.Program -> Either String (C.Program,[Value])
justifyIndexBodies scopes oldNames original newNames target = do
  old<-normalizedProgram False False oldNames original
  new<-normalizedProgram True False newNames target
  let definitions program=[d | unit<-C.programUnits program,d<-C.unitDefinitions unit]
      identity=C.declarationId . C.definitionDeclaration
      previous=M.fromList [(identity d,d) | d<-definitions old]
      next=M.fromList [(identity d,d) | d<-definitions new]
      changed=S.fromList [name | (name,d)<-M.toList previous,M.lookup name next/=Just d]
      structural=S.fromList [C.constructorId c | d<-C.programDataDeclarations old,
        C.dataStructural d/=Nothing,c<-C.dataConstructors d]
      contracts=[c | unit<-C.programUnits old,c<-C.unitContracts unit]
      attempt name before=do
        after<-M.lookup name next
        guard (eligible old before)
        guard (before{C.definitionBody=C.definitionBody after}==after)
        guard (not (any ((==name) . C.contractDeclaration) contracts))
        guard (all (`S.notMember` S.delete name changed) (calls (C.definitionBody before)))
        True<-readChanges structural name (C.definitionBody before) (C.definitionBody after)
        helper<-comparison before after
        let declaration=C.definitionDeclaration helper
            helperId=C.declarationId declaration
            result=C.Binder (C.Id (C.idText helperId++"::result")) "result" (C.scalarType "Bool")
            post=C.Expr (C.scalarType "Bool") (C.Local (C.binderId result)) (C.GeneratedFrom helperId)
            contract=C.Contract helperId (C.definitionArguments helper) result [] [post] []
            helperScopes=case M.lookup name scopes of
              Nothing->scopes
              Just capabilities->M.insert helperId capabilities scopes
        guard (helperId `M.notMember` previous && helperId `M.notMember` next)
        either (const Nothing) Just (validateDefinitionContractsWithScopes helperScopes
          (C.programMachineBits old) (C.programDataDeclarations old)
          (helper:definitions old) (contract:contracts))
        pure (after,object ["definition" .= C.idText name,
          "beforeBodyDigest" .= fingerprint (C.definitionBody before),
          "afterBodyDigest" .= fingerprint (C.definitionBody after),
          "basis" .= ("ordinary definition-contract proof of branch equality under constructor invariants; mandatory target termination"::String)])
      justified=M.mapMaybeWithKey attempt previous
      replace d=case M.lookup (identity d) justified of
        Nothing->d
        Just (made,_)->d{C.definitionArguments=C.definitionArguments made,C.definitionBody=C.definitionBody made}
      copy=original{C.programUnits=[unit{C.unitDefinitions=map replace (C.unitDefinitions unit)} |
        unit<-C.programUnits original]}
  either (Left . show) Right (validateProgramWithScopes scopes copy)
  pure (copy,map snd (M.elems justified))
  where
    fingerprint value=digestHex (digest (BL.toStrict (encode value)))
    calls expression=[name | C.ExternalCall name _<-[C.expressionNode expression]]++
      concatMap calls (C.children expression)

eligible :: C.Program -> C.Definition -> Bool
eligible program definition = not (C.definitionOrchestrates definition) &&
  C.definitionPolicy definition==Nothing && not (C.declarationAsync declaration) &&
  null (C.declarationUses declaration) && C.expressionType (C.definitionBody definition)==C.scalarType "BigInt" &&
  case C.definitionArguments definition of
    [argument] | C.Constructor family _<-C.binderType argument -> or
      [name `elem` [index++"Of"++C.dataName d | index<-familyIndexNames table] |
        d<-C.programDataDeclarations program,C.dataId d==C.Id family,Just table<-[C.dataIndex d]]
    _->False
  where
    declaration=C.definitionDeclaration definition
    name=maybe (C.declarationName declaration) snd (C.declarationTemplate declaration)

-- Every differing subterm is exactly a self-measure call on total structural
-- storage. Do not drop a field evaluation, change an operator or rewrite a call
-- on arbitrary computation. Full skeletons include binder and type metadata.
readChanges :: S.Set C.Id -> C.Id -> C.Expr -> C.Expr -> Maybe Bool
readChanges structural self before after
  | before==after=Just False
  | C.expressionType before/=C.expressionType after=Nothing
  | C.ExternalCall old [a]<-C.expressionNode before,
    C.ExternalCall new [b]<-C.expressionNode after,old==self,new==self,
    storage a,storage b=Just True
  | skeleton before==skeleton after = do
      flags<-sequence (zipWith (readChanges structural self) (C.children before) (C.children after))
      pure (or flags)
  | otherwise=Nothing
  where
    hole=C.Expr (C.scalarType "Bool") (C.Local (C.Id "<comparison-child>")) (C.GeneratedFrom self)
    skeleton=C.mapChildren (const hole)
    storage value=case C.expressionNode value of
      C.Local{}->True
      C.Project tag _ selected | tag `S.member` structural -> storage selected
      _->False

comparison :: C.Definition -> C.Definition -> Maybe C.Definition
comparison before after=do
  C.Match selected xs<-pure (C.expressionNode (C.definitionBody before))
  C.Match other ys<-pure (C.expressionNode (C.definitionBody after))
  guard (selected==other && length xs==length ys)
  branches<-sequence [do
    guard (C.caseConstructor x==C.caseConstructor y && C.caseBinders x==C.caseBinders y)
    evidence<-either (const Nothing) Just (operationEvidence C.Equal
      (C.expressionType (C.caseBody x)) (C.expressionType (C.caseBody y)))
    pure x{C.caseBody=C.Expr (C.scalarType "Bool")
      (C.Binary C.Equal evidence (C.caseBody x) (C.caseBody y)) origin} | (x,y)<-zip xs ys]
  let declaration=C.definitionDeclaration before
  pure before{C.definitionDeclaration=declaration{C.declarationId=helperId,
      C.declarationName=C.idText helperId,C.declarationTemplate=Nothing,
      C.declarationType=foldr C.Arrow (C.scalarType "Bool") (map C.binderType (C.definitionArguments before))},
    C.definitionBody=C.Expr (C.scalarType "Bool") (C.Match selected branches) origin}
  where
    helperId=C.Id ("<migration-index-equivalence>::"++digestHex (digest (BL.toStrict (encode (before,after)))))
    origin=C.GeneratedFrom helperId
