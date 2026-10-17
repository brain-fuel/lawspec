-- | Proof-only links from a parametric product to its checked instances.
-- No nominal identity is expanded or equated, and links are not transitive.
module LawSpec.Core.RecordInstances (RecordInstances,emptyInstances,fromRegistry,projects) where

import Control.Monad (foldM)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Core
import LawSpec.Core.Types (TypeRegistry,registryDeclarations,matchType)
import LawSpec.Core.RecordIdentity (instantiateRecordDeclaration)

newtype RecordInstances = RecordInstances (S.Set (Id,Id)) deriving (Eq,Ord,Show)

emptyInstances :: RecordInstances
emptyInstances = RecordInstances S.empty

-- Actual type variables stay rigid. Matching only chooses the template's
-- declared parameters; rebuilding checks the complete descriptor, including
-- restrictions and dependent relationships, rather than just field arity.
fromRegistry :: TypeRegistry -> RecordInstances
fromRegistry registry = RecordInstances (S.fromList
  [(constructorId templateConstructor,constructorId actualConstructor)
    | template <- records, not (null (dataParameters template)),
      [templateConstructor] <- [dataConstructors template],
      actual <- records, dataId actual /= dataId template,
      [actualConstructor] <- [dataConstructors actual],
      map binderName (constructorFields templateConstructor) == map binderName (constructorFields actualConstructor),
      Just bound <- [foldM (\known (pattern,value) -> matchType (dataParameters template) known pattern value)
        M.empty (zip (map binderType (constructorFields templateConstructor)) (map binderType (constructorFields actualConstructor)))],
      Just arguments <- [mapM (`M.lookup` bound) (dataParameters template)],
      Right (made,_) <- [instantiateRecordDeclaration template arguments (GeneratedFrom (dataId template))],
      dataId made == dataId actual, dataStructural made == dataStructural actual])
  where records=[declaration | declaration <- registryDeclarations registry,dataStructural declaration/=Nothing]

projects :: RecordInstances -> Id -> Id -> Bool
projects (RecordInstances pairs) expected actual = expected == actual || (expected,actual) `S.member` pairs
