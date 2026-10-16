-- | Certify representation shapes from both admitted frontends, including
-- unused generic declarations. This is a prerequisite for executable transport,
-- never permission to rewrite, unwrap nominal data, or change native bindings.
module LawSpec.MigrationPayloads (payloadCorrespondence, payloadCorrespondenceWithPlan) where

import Control.Monad (unless)
import Data.Aeson (Value,object,(.=))
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BL
import Data.List (sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import qualified LawSpec.Core as C
import LawSpec.Core.Migration (Project(..),Context(..))
import LawSpec.Core.PayloadTransport (PayloadPlan(..))
import LawSpec.Core.RecordIdentity (validateRecordDeclaration)
import LawSpec.Core.Types (makeRegistry,constructorFieldsFor,constructorPredicatesFor)
import LawSpec.Digest (digest,digestHex)
import LawSpec.Elaboration (coreTypeWithSourceRecords)
import LawSpec.MigrationTemplates (SourceTemplates(..))
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
        old{C.dataConstructors=[]} new{C.dataConstructors=[]}
      unless (map C.constructorId (C.dataConstructors old)==map C.constructorId (C.dataConstructors new))
        (Left "constructor identities or declaration order changed")
      plans <- sequence [constructorPlan source original migrated old a b |
        (a,b)<-zip (C.dataConstructors old) (C.dataConstructors new)]
      pure (concatMap fst plans,map snd plans)
    constructorPlan source original migrated owner old new = do
      oldView <- project plain old
      newView <- project plain new
      if oldView==newView then pure ([],object ["constructor" .= C.idText (C.constructorId old),"kind" .= ("unchanged"::String)])
      else do
        -- A named record already is a nominal product, not an alternative
        -- whose fields can be wrapped in another product.
        unless (not (length (C.dataConstructors owner)==1 && C.constructorName old==C.dataName owner))
          (Left "named-record fields and restrictions must be preserved")
        same "constructor metadata, GADT equations or existential binders changed"
          old{C.constructorFields=[],C.constructorPredicates=[]} new{C.constructorFields=[],C.constructorPredicates=[]}
        unless (C.dataIndex owner==Nothing && null (C.constructorEquations old) && null (C.constructorExistentials old))
          (Left "changed indexed or existential constructor payloads need a separately checked transport")
        case (C.constructorFields old,C.constructorFields new) of
          ([field],[payload]) -> do
            unless (C.binderName payload=="value" && C.binderType field==C.binderType payload)
              (Left "a single payload must retain its exact type and use the canonical value field")
            predicates (M.singleton (C.binderId field) (C.binderId payload))
              (C.constructorPredicates old) (C.constructorPredicates new)
            pure ([],object ["constructor" .= C.idText (C.constructorId old),"kind" .= ("single-payload"::String),
              "fields" .= [fieldEntry 0 0 field payload]])
          (fields,[payload]) | length fields>1 -> do
            unless (C.binderName payload=="value" && null (C.constructorPredicates new))
              (Left "a grouped payload must use value and introduce no outer constructor restrictions")
            SourceConstructor types _ <- maybe (Left "the checked source constructor context is missing") Right
              (M.lookup (C.constructorId old) (constructorSources source))
            unless (length types==length fields) (Left "the checked source field arity differs")
            let sourceRecord=S.Record [S.RecordField (C.binderName field) (C.binderName field) ty |
                  (field,ty)<-zip fields types]
            (expected,records) <- coreTypeWithSourceRecords source (M.elems original) (templateMachineBits before) sourceRecord
            unless (expected==C.binderType payload)
              (Left "the grouped record descriptor, field types, refinements or parameter relationships differ")
            let recordId=case expected of C.Constructor name _ -> C.Id name; _ -> C.Id ""
            expectedRecord <- maybe (Left "the derived record declaration is missing") Right
              (lookup recordId [(C.dataId value,value) | value<-records])
            actualRecord <- maybe (Left "the migrated structural record declaration is missing") Right (M.lookup recordId migrated)
            validateRecordDeclaration expectedRecord
            validateRecordDeclaration actualRecord
            same "the stored structural descriptors or record restrictions differ" expectedRecord actualRecord
            recordTag <- case C.dataConstructors actualRecord of
              [constructor] -> pure (C.constructorId constructor)
              _ -> Left "a structural payload must have exactly one constructor"
            registry <- makeRegistry (M.elems migrated)
            recordFields <- constructorFieldsFor registry expected recordTag
            recordPredicates <- constructorPredicatesFor registry expected recordTag
            unless (sort (map C.binderName fields)==sort (map C.binderName recordFields))
              (Left "the grouped payload does not preserve exactly the original field labels")
            destinations <- mapM (\field -> maybe (Left "a payload field is missing") Right
              (lookup (C.binderName field) [(C.binderName made,(index,made)) | (index,made)<-zip [0::Int ..] recordFields])) fields
            unless (and [C.binderType field==C.binderType made | (field,(_,made))<-zip fields destinations])
              (Left "instantiated record fields do not preserve the original types")
            predicates (M.fromList [(C.binderId field,C.binderId made) | (field,(_,made))<-zip fields destinations])
              (C.constructorPredicates old) recordPredicates
            pure ([recordId],object ["constructor" .= C.idText (C.constructorId old),"kind" .= ("record-payload"::String),
              "recordType" .= C.idText recordId,"recordConstructor" .= C.idText recordTag,
              "fields" .= [fieldEntry index target field made | (index,(field,(target,made)))<-zip [0::Int ..] (zip fields destinations)]])
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

plain :: Context
plain = Context False False M.empty M.empty M.empty (C.Id "payload-shapes") 0 False Right Right Set.empty Right

uniqueMap :: Ord key => String -> [(key,value)] -> Either String (M.Map key value)
uniqueMap label values = do
  let made=M.fromList values
  unless (M.size made==length values) (Left ("duplicate " ++ label ++ " in checked payload catalogue"))
  pure made
