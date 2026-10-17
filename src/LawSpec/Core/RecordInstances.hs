-- | Proof-only links from a parametric product to its checked instances.
-- No nominal identity is expanded or equated, and links are not transitive.
module LawSpec.Core.RecordInstances (RecordInstances,emptyInstances,fromRegistry,projects) where

import Control.Monad (foldM,guard)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Core
import LawSpec.Core.Types (TypeRegistry,registryDeclarations,matchType,substitute)
import LawSpec.Core.RecordIdentity (instantiateRecordDeclaration,rebuildRecordDeclaration)

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
      Just bound <- [foldM (\known (pattern,value) -> matchStored S.empty (dataParameters template) known pattern value)
        M.empty (zip (map binderType (constructorFields templateConstructor)) (map binderType (constructorFields actualConstructor)))],
      Just arguments <- [mapM (`M.lookup` bound) (dataParameters template)],
      Just (made,_) <- [normalizedInstance S.empty template arguments],
      dataId made == dataId actual, dataStructural made == dataStructural actual])
  where
    records=[declaration | declaration <- registryDeclarations registry,dataStructural declaration/=Nothing]
    catalog=M.fromList [(dataId declaration,declaration) | declaration<-records]
    -- Ordinary matching stays authoritative. Only structural products can be
    -- opened when canonical instantiation has changed a nested product's ID.
    -- Actual variables remain rigid, and repeated parameters keep one binding.
    matchStored seen flexible known pattern actual = case matchType flexible known pattern actual of
      Just result -> Just result
      Nothing | (pattern,actual) `S.member` seen -> Nothing
      Nothing -> let next=S.insert (pattern,actual) seen in case (pattern,actual) of
        (Constructor left xs,Constructor right ys)
          | left==right,length xs==length ys -> foldM (argument next flexible) known (zip xs ys)
          | otherwise -> do
              a<-storedFields left xs;b<-storedFields right ys
              guard (map binderName a==map binderName b)
              foldM (\bound (x,y) -> matchStored next flexible bound (binderType x) (binderType y)) known (zip a b)
        (Arrow a b,Arrow c d) -> matchStored next flexible known a c >>= \bound -> matchStored next flexible bound b d
        _ -> Nothing
    argument seen flexible known (TypeArgument pattern,TypeArgument actual)=matchStored seen flexible known pattern actual
    argument _ _ known (pattern,actual) | pattern==actual=Just known
    argument _ _ _ _=Nothing
    storedFields name arguments=do
      declaration<-M.lookup (Id name) catalog
      [constructor]<-pure (dataConstructors declaration)
      types<-mapM (\argument -> case argument of TypeArgument ty->Just ty;_->Nothing) arguments
      guard (length types==length (dataParameters declaration))
      let bound=M.fromList (zip (dataParameters declaration) types)
      pure [field{binderType=substitute bound (binderType field)} | field<-constructorFields constructor]

    -- Follow the existing record-normalization sequence: instantiate, normalize
    -- nested field types, then rebuild the full descriptor. This is comparison
    -- metadata only; it never creates a declaration or representation coercion.
    -- Changing a field type beneath a predicate needs expression normalization
    -- and remains unsupported here. Never drop that predicate to obtain a link.
    normalizedInstance seen original arguments=do
      let key=Constructor (idText (dataId original)) (map TypeArgument arguments)
      guard (key `S.notMember` seen)
      (made,remaining)<-either (const Nothing) Just
        (instantiateRecordDeclaration original arguments (GeneratedFrom (dataId original)))
      [constructor]<-pure (dataConstructors made)
      fields<-mapM (normalType (S.insert key seen) . binderType) (constructorFields constructor)
      let oldFields=map binderType (constructorFields constructor)
      (rebuilt,parameters)<-if fields==oldFields then Just (made,dataParameters made) else do
        guard (null (constructorPredicates constructor))
        either (const Nothing) Just (rebuildRecordDeclaration made (dataParameters made) fields [] (dataOrigin original))
      admitted<-M.lookup (dataId rebuilt) catalog
      guard (dataStructural rebuilt==dataStructural admitted)
      let bound=M.fromList (zip (dataParameters made) remaining)
      actual<-mapM (`M.lookup` bound) parameters
      pure (rebuilt,actual)
    normalType seen ty=case ty of
      Constructor name arguments -> do
        arguments'<-mapM (\argument -> case argument of
          TypeArgument child->TypeArgument <$> normalType seen child
          other->Just other) arguments
        case M.lookup (Id name) catalog of
          Nothing->Just (Constructor name arguments')
          Just declaration->do
            types<-mapM (\argument -> case argument of TypeArgument child->Just child;_->Nothing) arguments'
            (made,remaining)<-normalizedInstance seen declaration types
            pure (Constructor (idText (dataId made)) (map TypeArgument remaining))
      Arrow a b->Arrow <$> normalType seen a <*> normalType seen b
      other->Just other

projects :: RecordInstances -> Id -> Id -> Bool
projects (RecordInstances pairs) expected actual = expected == actual || (expected,actual) `S.member` pairs
