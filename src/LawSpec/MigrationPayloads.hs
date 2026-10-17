-- | Certify representation shapes from both admitted frontends, including
-- unused generic declarations. This is a prerequisite for executable transport,
-- never permission to rewrite, unwrap nominal data, or change native bindings.
module LawSpec.MigrationPayloads (payloadCorrespondence, payloadCorrespondenceWithPlan) where

import Control.Monad (unless)
import Data.Aeson (Value,object,(.=))
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BL
import Data.List (nub, sort)
import Data.Graph (stronglyConnComp, flattenSCC)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import qualified LawSpec.Core as C
import LawSpec.Core.Migration (Project(..),Context(..))
import LawSpec.Core.PayloadTransport (PayloadPlan(..))
import LawSpec.Core.RecordIdentity (validateRecordDeclaration)
import LawSpec.Core.Types (makeRegistry,constructorFieldsFor,constructorPredicatesFor)
import LawSpec.Digest (digest,digestHex)
import LawSpec.IndexTerm
import LawSpec.Elaboration (coreTypeWithSourceRecords)
import LawSpec.MigrationTemplates (SourceTemplates(..),legacyNominalRecord)
import qualified LawSpec.Model as S
import LawSpec.SourceContext (SourceContext(..),SourceConstructor(..))

payloadCorrespondence :: SourceTemplates -> SourceTemplates -> Either String Value
payloadCorrespondence before after = fst <$> payloadCorrespondenceWithPlan before after

payloadCorrespondenceWithPlan :: SourceTemplates -> SourceTemplates -> Either String (Value,Maybe PayloadPlan)
payloadCorrespondenceWithPlan before after = do
  unless (templateMachineBits before == templateMachineBits after)
    (Left "payload comparison requires matching machine widths")
  original <- catalogue (templateDataDeclarations before)
  migrated <- catalogue (templateDataDeclarations after)
  sources <- uniqueMap "source constructor" [(identity,SourceConstructor fields equations) |
    (identity,fields,equations)<-templateConstructors before]
  old <- project plain original
  new <- project plain migrated
  let changes=[(identity,declaration) | (identity,declaration)<-M.toAscList original,
        M.lookup identity old /= M.lookup identity new]
      compareOne (identity,declaration) = case M.lookup identity migrated of
        Nothing -> pure (False,[],object ["type" .= C.idText identity,"status" .= ("not-established"::String),
          "reason" .= ("the migrated nominal or structural type is missing"::String)])
        Just made -> case declarationPlan (SourceContext sources) original migrated declaration made of
          Left reason -> pure (False,[],object ["type" .= C.idText identity,"status" .= ("not-established"::String),"reason" .= reason])
          Right (records,rows) -> pure (True,records,object ["type" .= C.idText identity,
            "status" .= ("matched"::String),"constructors" .= rows])
  checked <- mapM compareOne changes
  let authorized=Set.fromList (concat [records | (_,records,_)<-checked])
      added=[identity | identity<-M.keys migrated,identity `M.notMember` original]
      unexplained=[identity | identity<-added,identity `Set.notMember` authorized]
      matched=all (\(ok,_,_) -> ok) checked && null unexplained
      fingerprint captured = do
        declarations <- project plain (templateDataDeclarations captured)
        constructors <- project plain (templateConstructors captured)
        pure (digestHex (digest (BL.toStrict (encode (("migration-payload-shapes-v1"::String),
          templateMachineBits captured,declarations,constructors)))))
  previousDigest <- fingerprint before
  nextDigest <- fingerprint after
  let plan=if matched then Just (PayloadPlan [(previous,next) | (identity,previous)<-changes,Just next<-[M.lookup identity migrated]]
        [record | identity<-Set.toAscList authorized,Just record<-[M.lookup identity migrated]]) else Nothing
  pure (object ["version" .= (1::Int),"algorithm" .= ("sha256"::String),"status" .= ("not-established"::String),
    "machineBits" .= templateMachineBits before,
    "scope" .= ("checked pre-specialization constructor payload shapes only"::String),
    "beforeDigest" .= previousDigest,"afterDigest" .= nextDigest,
    "payloadShapes" .= object ["status" .= (if matched then "matched" else "not-established"::String),
      "unchangedTypes" .= (M.size original-length changes),"changes" .= [row | (_,_,row)<-checked],
      "introducedRecords" .= map C.idText [identity | identity<-Set.toAscList authorized,identity `elem` added],"unexplainedAddedTypes" .= map C.idText unexplained],
    "executableTransport" .= pending "Typed constructions, matches, projections and updates still require executable transport correspondence.",
    "dependencyBehavior" .= pending "Called definition behavior and transitive nominal dependencies require whole-program correspondence.",
    "nativeBindings" .= pending "Payload field and representation bindings require separate native correspondence.",
    "lawVerification" .= ("not-established-by-payload-shapes"::String),"validated" .= False],plan)
  where
    catalogue declarations=uniqueMap "data declaration" [(C.dataId value,value) | value<-declarations]
    pending reason=object ["status" .= ("not-established"::String),"reason" .= (reason::String)]
    declarationPlan source original migrated old new = do
      unless (C.dataStructural old == Nothing && C.dataStructural new == Nothing)
        (Left "an existing structural type changed; its identity and full descriptor must be preserved")
      same "nominal identity, parameters, family index or native representation changed"
        old{C.dataConstructors=[],C.dataIndex=Nothing} new{C.dataConstructors=[],C.dataIndex=Nothing}
      unless (map C.constructorId (C.dataConstructors old)==map C.constructorId (C.dataConstructors new))
        (Left "constructor identities or declaration order changed")
      plans <- sequence [constructorPlan source original migrated old a b |
        (a,b)<-zip (C.dataConstructors old) (C.dataConstructors new)]
      let layouts=M.fromList [(C.idText (C.constructorId constructor),layout) |
            (constructor,(_,_,layout))<-zip (C.dataConstructors old) plans]
      moved <- traverse (remapFamily layouts) (C.dataIndex old)
      same "family index equations or guards changed under the payload field paths"
        (canonicalFamily <$> moved) (canonicalFamily <$> C.dataIndex new)
      pure (concat [records | (records,_,_)<-plans],[row | (_,row,_)<-plans])
    constructorPlan source original migrated owner old new = do
      oldView <- project plain old
      newView <- project plain new
      if oldView==newView then pure ([],object ["constructor" .= C.idText (C.constructorId old),"kind" .= ("unchanged"::String)],[(index,[index]) | index<-[0..length (C.constructorFields old)-1]])
      else do
        -- A named record already is a nominal product, not an alternative
        -- whose fields can be wrapped in another product.
        unless (not (legacyNominalRecord owner old))
          (Left "named-record fields and restrictions must be preserved")
        same "constructor metadata, GADT equations or existential binders changed"
          old{C.constructorFields=[],C.constructorPredicates=[]} new{C.constructorFields=[],C.constructorPredicates=[]}
        case (C.constructorFields old,C.constructorFields new) of
          ([field],[payload]) -> do
            -- Only the formal field name changes. The complete constructor
            -- metadata above retains index equations and existential scope;
            -- the existing transport renames this formal and validates Core.
            unless (C.binderName payload=="value" && C.binderType field==C.binderType payload)
              (Left "a single payload must retain its exact type and use the canonical value field")
            predicates (M.singleton (C.binderId field) (C.binderId payload))
              (C.constructorPredicates old) (C.constructorPredicates new)
            pure ([],object ["constructor" .= C.idText (C.constructorId old),"kind" .= ("single-payload"::String),
              "fields" .= [fieldEntry 0 0 field payload]],[(0,[0])])
          (fields,[payload]) | length fields>1 -> do
            unless (null (C.constructorEquations old) && null (C.constructorExistentials old))
              (Left "grouped GADT or existential payloads need a separately checked transport")
            unless (C.binderName payload=="value" && null (C.constructorPredicates new))
              (Left "a grouped payload must use value and introduce no outer constructor restrictions")
            SourceConstructor types _ <- maybe (Left "the checked source constructor context is missing") Right
              (M.lookup (C.constructorId old) (constructorSources source))
            unless (length types==length fields) (Left "the checked source field arity differs")
            -- The destination supplies a candidate constraint set, not an
            -- assumption. Its field types/restrictions are reconstructed from
            -- the original source, and its index guards must follow from the
            -- original constructor guards before the descriptor can match.
            recordId <- case C.binderType payload of
              C.Constructor name _ -> pure (C.Id name)
              _ -> Left "a grouped destination must be an applied structural record"
            actualRecord <- maybe (Left "the migrated structural record declaration is missing") Right (M.lookup recordId migrated)
            validateRecordDeclaration actualRecord
            recordTag <- case C.dataConstructors actualRecord of
              [constructor] -> pure (C.constructorId constructor)
              _ -> Left "a structural payload must have exactly one constructor"
            registry <- makeRegistry (M.elems migrated)
            recordFields <- constructorFieldsFor registry (C.binderType payload) recordTag
            recordPredicates <- constructorPredicatesFor registry (C.binderType payload) recordTag
            unless (sort (map C.binderName fields)==sort (map C.binderName recordFields))
              (Left "the grouped payload does not preserve exactly the original field labels")
            destinations <- mapM (\field -> maybe (Left "a payload field is missing") Right
              (lookup (C.binderName field) [(C.binderName made,(index,made)) | (index,made)<-zip [0::Int ..] recordFields])) fields
            unless (and [C.binderType field==C.binderType made | (field,(_,made))<-zip fields destinations])
              (Left "instantiated record fields do not preserve the original types")
            let guards=maybe [] C.structuralIndexGuards (C.dataStructural actualRecord)
                inverse=M.fromList [(target,[from]) | (from,(target,_))<-zip [0..] destinations]
                prior=case C.dataIndex owner >>= lookup (C.idText (C.constructorId old)) . familyIndexConstructors of
                  Just index -> constructorIndexGuards index
                  Nothing -> []
            lifted <- mapM (remapGuard (fieldPath inverse)) guards
            unless (guardsFollow prior lifted)
              (Left "payload index relationships do not follow from the original constructor guards")
            let sourceFields=[S.RecordField (C.binderName field) (C.binderName field) ty |
                  (field,ty)<-zip fields types]
                sourceRecord=if null guards then S.Record sourceFields
                  else S.IndexedRecord sourceFields (S.RecordIndexConstraints guards)
            (expected,records) <- coreTypeWithSourceRecords source (M.elems original) (templateMachineBits before) sourceRecord
            unless (expected==C.binderType payload)
              (Left "the grouped record descriptor, field types, refinements or parameter relationships differ")
            expectedRecord <- maybe (Left "the derived record declaration is missing") Right
              (lookup recordId [(C.dataId value,value) | value<-records])
            validateRecordDeclaration expectedRecord
            same "the stored structural descriptors or record restrictions differ" expectedRecord actualRecord
            predicates (M.fromList [(C.binderId field,C.binderId made) | (field,(_,made))<-zip fields destinations])
              (C.constructorPredicates old) recordPredicates
            pure ([recordId],object ["constructor" .= C.idText (C.constructorId old),"kind" .= ("record-payload"::String),
              "recordType" .= C.idText recordId,"recordConstructor" .= C.idText recordTag,
              "fields" .= [fieldEntry index target field made | (index,(field,(target,made)))<-zip [0::Int ..] (zip fields destinations)]],
              [(from,[0,target]) | (from,(target,_))<-zip [0..] destinations])
          _ -> Left "payload arity changed outside the supported explicit-payload migration"
    same reason a b = do
      x <- project plain a
      y <- project plain b
      unless (x==y) (Left reason)
    predicates renames a b = do
      x <- project plain{globalIds=renames} a
      y <- project plain b
      unless (x==y) (Left "constructor restrictions or their dependent field relationships changed")
    fieldEntry from to a b=object ["label" .= C.binderName a,"fromIndex" .= (from::Int),"toIndex" .= (to::Int),
      "fromBinder" .= C.idText (C.binderId a),"toBinder" .= C.idText (C.binderId b)]

-- A representation map changes only the root constructor field. Every later
-- structural projection and the final family-index selector stay intact.
fieldPath :: M.Map Int [Int] -> Int -> Either String [Int]
fieldPath layout index=maybe (Left "an index refers to an unmapped constructor field") Right (M.lookup index layout)

remapTerm :: (Int -> Either String [Int]) -> IndexTerm -> Either String IndexTerm
remapTerm field term=case term of
  IndexConstant _ -> pure term
  IndexApply op a b -> IndexApply op <$> remapTerm field a <*> remapTerm field b
  IndexField position index -> field position >>= \path -> pure (reference (path,index))
  IndexPath [] _ -> Left "an index field path is empty"
  IndexPath (position:rest) index -> field position >>= \path -> pure (reference (path++rest,index))

remapGuard :: (Int -> Either String [Int]) -> IndexGuard -> Either String IndexGuard
remapGuard field (IndexGuard relation a b)=IndexGuard relation <$> remapTerm field a <*> remapTerm field b

remapFamily :: M.Map String [(Int,[Int])] -> FamilyIndex -> Either String FamilyIndex
remapFamily layouts family=do
  constructors<-mapM (\(tag,index) -> do
    layout<-maybe (Left "an indexed constructor has no checked payload layout") Right (M.lookup tag layouts)
    terms<-mapM (remapTerm (fieldPath (M.fromList layout))) (constructorIndexTerms index)
    guards<-mapM (remapGuard (fieldPath (M.fromList layout))) (constructorIndexGuards index)
    pure (tag,ConstructorIndex terms guards)) (familyIndexConstructors family)
  pure family{familyIndexConstructors=constructors}

type IndexReference=([Int],Int)

reference :: IndexReference -> IndexTerm
reference ([position],index)=IndexField position index
reference (path,index)=IndexPath path index

asReference :: IndexTerm -> Maybe IndexReference
asReference term=case term of
  IndexField position index -> Just ([position],index)
  IndexPath path index -> Just (path,index)
  _ -> Nothing

-- Equalities are an equivalence relation over *readable* index references.
-- Keep a star mentioning every member, including a singleton's self equality:
-- dropping that last read would forget the original definedness requirement.
indexClasses :: [IndexGuard] -> [[IndexReference]]
indexClasses guards=map (sort . flattenSCC) (stronglyConnComp
  [(vertex,vertex,Set.toList (M.findWithDefault Set.empty vertex graph)) | vertex<-M.keys graph])
  where
    graph=M.fromListWith Set.union [(a,Set.singleton b) | IndexGuard IndexEqual left right<-guards,
      Just x<-[asReference left],Just y<-[asReference right],(a,b)<-[(x,y),(y,x)]]

aliases :: [IndexGuard] -> M.Map IndexReference IndexReference
aliases guards=M.fromList [(member,head group) | group<-indexClasses guards,member<-group]

replaceReferences :: M.Map IndexReference IndexReference -> IndexTerm -> IndexTerm
replaceReferences names term=case asReference term of
  Just field -> reference (M.findWithDefault field field names)
  Nothing -> case term of
    IndexApply op a b -> IndexApply op (recur a) (recur b)
    _ -> term
  where recur=replaceReferences names

canonicalConstructorIndex :: ConstructorIndex -> ConstructorIndex
canonicalConstructorIndex (ConstructorIndex terms guards)=ConstructorIndex (map rewrite terms) (sort (nub (equalities++other)))
  where
    rewrite=replaceReferences (aliases guards)
    equalities=concat [case group of
      [one] -> [IndexGuard IndexEqual (reference one) (reference one)]
      first:rest -> [IndexGuard IndexEqual (reference first) (reference member) | member<-rest]
      [] -> [] | group<-indexClasses guards]
    other=[IndexGuard relation (rewrite a) (rewrite b) | IndexGuard relation a b<-guards,
      not (relation==IndexEqual && asReference a/=Nothing && asReference b/=Nothing)]

canonicalFamily :: FamilyIndex -> FamilyIndex
canonicalFamily family=family{familyIndexConstructors=[(name,canonicalConstructorIndex index) | (name,index)<-familyIndexConstructors family]}

-- This is structural equality transport, not an arithmetic solver. Unknown
-- additional restrictions stay unestablished. In particular, a bounded sample
-- of matching values cannot justify a missing equation or a stronger payload.
guardsFollow :: [IndexGuard] -> [IndexGuard] -> Bool
guardsFollow prior=all follows
  where
    names=aliases prior
    follows (IndexGuard IndexEqual a b) | Just x<-asReference a,Just y<-asReference b =
      case (M.lookup x names,M.lookup y names) of
        (Just p,Just q) -> p==q
        _ -> False
    follows _=False

plain :: Context
plain = Context False False M.empty M.empty M.empty (C.Id "payload-shapes") 0 False Right Right Set.empty M.empty Right

uniqueMap :: Ord key => String -> [(key,value)] -> Either String (M.Map key value)
uniqueMap label values = do
  let made=M.fromList values
  unless (M.size made==length values) (Left ("duplicate " ++ label ++ " in checked payload catalogue"))
  pure made
