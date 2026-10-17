-- | Reuse ordinary scheme instantiation at rigid symbolic carriers. Every
-- generic definition receives its own checked root, including unused schemes.
-- No representative concrete type or arbitrary known-body implementation is
-- introduced. Ordinary executable specialization continues to reject rigids.
module LawSpec.MigrationElaboration (symbolicProgram) where

import Control.Monad (unless)
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Set as Set
import qualified LawSpec.Core as C
import LawSpec.Core.CapabilityScope (CapabilityScopes)
import LawSpec.Core.Migration (semanticName)
import LawSpec.CapabilityCheck (checkCapability)
import LawSpec.Digest (digest,digestHex)
import LawSpec.Elaboration (coreTypeWithSourceRecords)
import LawSpec.Frontend (elaborateWithSourceDeclarationsWithScopes)
import LawSpec.Inference (typeVariables)
import LawSpec.MigrationScopes (sourceScopes,sourceContext)
import LawSpec.MigrationTemplates
import LawSpec.SpecializeDefinitions (instantiateSymbolicDefinitions)
import qualified LawSpec.Model as S

symbolicProgram :: Bool -> SourceTemplates -> [S.Unit] -> [S.Expanded] -> Either String (C.Program,CapabilityScopes)
symbolicProgram canonical captured original laws=do
  rooted<-mapM roots original
  let units=map fst rooted
      given=concatMap snd rooted++concatMap (S.requirements.S.original) laws
      satisfies=checkCapability (coreTypeWithSourceRecords context declarations bits) declarations bits given
  (instantiated,properties)<-diagnostics (instantiateSymbolicDefinitions context declarations bits satisfies units laws)
  scopes<-sourceScopes captured{templateUnits=instantiated} properties
  program<-diagnostics (elaborateWithSourceDeclarationsWithScopes scopes canonical context declarations bits instantiated properties)
  pure (program,scopes)
  where
    context=sourceContext captured
    declarations=templateDataDeclarations captured
    bits=templateMachineBits captured
    diagnostics=either (Left . unlines . map S.message) Right
    signature definition=S.Qualified (S.functionRequirements definition)
      (foldr S.Arrow (S.functionResult definition) (map snd (S.functionArguments definition)))
    roots unit=do
      let generic=[definition | definition<-S.functionDefinitions unit,not (null (typeVariables (signature definition)))]
          copies=[(definition,root (S.unitName unit) definition,rigidity (S.unitName unit) definition) | definition<-generic]
          made=[definition | (_,definition,_)<-copies]
          functions=S.functions unit++[(S.functionName definition,signature definition) | definition<-made]
          cloneNames values=values++[S.functionName made | (old,made,_)<-copies,S.functionName old `elem` values]
          rows values=values++[(S.functionName made,map rigid types) | (old,made,rigid)<-copies,
            (name,types)<-values,name==S.functionName old]
          policies=S.policies unit++[(S.functionName made,policy) | (old,made,_)<-copies,
            (name,policy)<-S.policies unit,name==S.functionName old]
          contracts=S.contracts unit++[contract
            {S.contractName=S.functionName made,
             S.contractArguments=[(name,rigid ty) | (name,ty)<-S.contractArguments contract],
             S.contractResult=(fst (S.contractResult contract),rigid (snd (S.contractResult contract))),
             S.contractPreconditions=map (S.mapExprTypes rigid) (S.contractPreconditions contract),
             S.contractPostconditions=map (S.mapExprTypes rigid) (S.contractPostconditions contract)} |
              (old,made,rigid)<-copies,contract<-S.contracts unit,S.contractName contract==S.functionName old]
      unless (length functions==Set.size (Set.fromList (map fst functions)))
        (Left "a symbolic definition root collides with a source declaration")
      pure (unit{S.functions=functions,S.functionDefinitions=S.functionDefinitions unit++made,S.contracts=contracts,
          S.orchestrations=cloneNames (S.orchestrations unit),S.asyncFunctions=cloneNames (S.asyncFunctions unit),
          S.abilityRows=rows (S.abilityRows unit),S.declaredUses=rows (S.declaredUses unit),S.policies=policies},
        concatMap (S.typeConstraints.signature) made)
    root owner definition=definition
      { S.functionName="<definition-template:"++identity++">"
      , S.functionArguments=[(name,rigid ty) | (name,ty)<-S.functionArguments definition]
      , S.functionResult=rigid (S.functionResult definition)
      , S.functionRequirements=[S.Capability name (rigid ty) | S.Capability name ty<-S.functionRequirements definition]
      , S.functionBody=S.mapExprTypes rigid (S.functionBody definition)
      , S.functionTemplate=Just (S.functionName definition) }
      where
        identity=rootIdentity owner definition
        rigid=rigidity owner definition
    rootIdentity owner definition=digestHex (digest (BL.toStrict (encode (owner,semanticName canonical (S.functionName definition)))))
    rigidity owner definition=rigid
      where
        identity=rootIdentity owner definition
        rigid=S.mapType (\ty->case ty of S.Variable name->S.Named ("@<definition-type:"++identity++":"++name++">"); other->other)
          (S.mapExprTypes rigid)
