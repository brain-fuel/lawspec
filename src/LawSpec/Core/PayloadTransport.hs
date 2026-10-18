-- | A comparison-only transport of certified payload representations. The
-- ordinary record normalizer and mandatory Core validator audit the result;
-- neither this copy nor its rules are emitted or used to run laws.
module LawSpec.Core.PayloadTransport
  ( PayloadPlan(..), transportProgram, transportProgramWithScopes, transportComparison, transportComparisonWithProgram, transportComparisonWithScopes ) where

import Control.Monad (unless)
import Data.Aeson (Value(..),object,(.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BL
import Data.List (sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import qualified LawSpec.Core as C
import LawSpec.Core.Migration (Context(..),Project(..),transformProgram,transformProgramWithTypes,migrationSnapshot)
import LawSpec.Core.RecordIdentity (constructRecord,validateRecordDeclaration)
import LawSpec.Core.RecordNormalize (normalizeProgramRecords)
import LawSpec.Core.Types (makeRegistry,constructorFieldsFor,constructorBindingsAt,substitute,registryDeclarations)
import LawSpec.Core.Validate (validateProgramWithScopes)
import LawSpec.Core.CapabilityScope (CapabilityScopes)
import LawSpec.Digest (digest,digestHex)

-- Built only after the frontend has compared full checked source descriptors,
-- restrictions and metadata. No wire request can supply or override this plan.
data PayloadPlan = PayloadPlan
  { payloadDeclarations :: [(C.DataDeclaration,C.DataDeclaration)]
  , payloadRecords :: [C.DataDeclaration]
  } deriving (Eq,Show)

-- The frontend certifies the complete record descriptor before constructing
-- this plan. A one-field record payload is still a grouping, not a rename of
-- that field to value; its label and restrictions live inside the record.
regrouped :: C.DataConstructor -> C.DataConstructor -> Bool
regrouped before after = case (C.constructorFields before,C.constructorFields after) of
  ([field],[payload]) | C.binderType field == C.binderType payload -> False
  (fields,[_]) -> not (null fields)
  _ -> False

transportProgram :: PayloadPlan -> C.Program -> Either String C.Program
transportProgram=transportProgramWithScopes M.empty

transportProgramWithScopes :: CapabilityScopes -> PayloadPlan -> C.Program -> Either String C.Program
transportProgramWithScopes scopes plan original = do
  let known=M.fromList [(C.dataId value,value) | value<-C.programDataDeclarations original]
  mapM_ (\(before,_) -> do
    actual<-maybe (Left "a certified source declaration is missing from admitted Core") Right (M.lookup (C.dataId before) known)
    x<-project plain before
    y<-project plain actual
    unless (x==y) (Left "a certified source declaration differs from admitted Core")) (payloadDeclarations plan)
  mapM_ validateRecordDeclaration (payloadRecords plan)
  let replacements=M.fromList [(C.dataId before,after) | (before,after)<-payloadDeclarations plan]
      constructors=M.fromList [(C.constructorId old,(old,new)) | (before,after)<-payloadDeclarations plan,
        (old,new)<-zip (C.dataConstructors before) (C.dataConstructors after),
        regrouped old new]
      additions=[value | value<-payloadRecords plan,C.dataId value `M.notMember` known]
      augmented=original{C.programDataDeclarations=C.programDataDeclarations original++additions}
      declarations=M.elems (M.union replacements known)++additions
      catalogue=M.fromList [(C.dataId value,value) | value<-declarations]
      -- Single-payload constructor restrictions change their formal field ID;
      -- references to those formals elsewhere in checked metadata follow it.
      renames=M.fromList [(C.binderId old,C.binderId new) | (before,after)<-payloadDeclarations plan,
        (a,b)<-zip (C.dataConstructors before) (C.dataConstructors after),
        [old]<-[C.constructorFields a],[new]<-[C.constructorFields b],C.binderType old==C.binderType new]
      declaration value=case M.lookup (C.dataId value) replacements of
        Nothing -> pure value
        Just made -> pure made{C.dataConstructors=[constructor{C.constructorPredicates=map mark (C.constructorPredicates constructor)} |
          constructor<-C.dataConstructors made]}
  registry<-makeRegistry declarations
  oldRegistry<-makeRegistry (C.programDataDeclarations original)
  let sourceData=registryDeclarations oldRegistry
      reordered=Set.fromList [C.dataId before | (before,after)<-payloadDeclarations plan,
        (old,new)<-zip (C.dataConstructors before) (C.dataConstructors after),
        regrouped old new,
        map C.binderName (C.constructorFields old)/=sort (map C.binderName (C.constructorFields old))]
      parameterized=Set.fromList [C.dataId value | value<-sourceData,not (null (C.dataParameters value))]
      changed=Set.fromList [C.dataId before | (before,_)<-payloadDeclarations plan]
      grouped=Set.fromList [C.dataId before | (before,after)<-payloadDeclarations plan,
        (old,new)<-zip (C.dataConstructors before) (C.dataConstructors after),
        regrouped old new]
      allGraph=M.fromList [(C.dataId value,concat [names (C.binderType field) |
        constructor<-C.dataConstructors value,field<-C.constructorFields constructor]) | value<-sourceData]
      payloadGraph=M.fromList [(C.dataId value,concat [names (C.binderType field) |
        constructor<-C.dataConstructors value,field<-C.constructorFields constructor,
        any (`elem` C.dataParameters value) (variables (C.binderType field))]) | value<-sourceData]
      affected graph targets starts=not (Set.null (Set.intersection targets (closure graph (Set.fromList starts))))

  let observes targets ty=affected allGraph targets (names ty) ||
        (not (Set.null targets) && not (null (variables ty)))
      auditType ty = case ty of
        -- These invariants are enforced by ordinary value validation, even
        -- when a function never calls the comparison helper explicitly.
        C.Constructor name (C.TypeArgument key:_) |
            name `elem` ["lawspec.collections::type::Set","lawspec.collections::type::KeyVal"],
            observes reordered key ->
          Left "ordered collection keys need a transport preserving their intrinsic sortedness"
        _->pure ty
      audit expression = case C.expressionNode expression of
        C.AllPayloads selected _ | affected payloadGraph (Set.intersection reordered parameterized)
            (rootName (C.expressionType selected)) ->
          Left "payload traversal needs an explicit transport preserving legacy field visitation order"
        C.Helper C.Compare arguments | any (observes reordered . C.expressionType) arguments ->
          Left "key ordering of regrouped fields needs an explicit legacy-order comparator"
        C.Helper C.Recorded arguments | any (observes changed . C.expressionType) arguments ->
          Left "recorded values need a separately validated representation migration"
        C.Helper C.Concurrently arguments | any (observes grouped . C.expressionType) arguments ->
          Left "concurrent payload construction needs an explicit scheduling-preserving transport"
        _->pure expression
      at ty tag bound = do
        payload<-case constructorFieldsFor registry ty tag of
          Right [field]->pure (substitute bound (C.binderType field))
          _->Left "transport requires one checked destination payload"
        (identity,arguments)<-case payload of
          C.Constructor name args | length args==length [() | C.TypeArgument _<-args] ->
            pure (C.Id name,[argument | C.TypeArgument argument<-args])
          _->Left "transport destination payload is not an applied structural record"
        record<-maybe (Left "transport destination record is missing") Right (M.lookup identity catalogue)
        validateRecordDeclaration record
        recordTag<-case C.dataConstructors record of
          [constructor]->pure (C.constructorId constructor)
          _->Left "transport destination must have one record constructor"
        fields<-constructorFieldsFor registry payload recordTag
        pure (payload,record,arguments,recordTag,fields)
      destination old index fields = do
        field<-case drop index (C.constructorFields old) of
          value:_ | index>=0->pure value
          _->Left "transport source field index is invalid"
        maybe (Left "transport destination field label is missing") Right
          (lookup (C.binderName field) [(C.binderName made,i) | (i,made)<-zip [0::Int ..] fields])
      make ty node=C.Expr ty node marker
      rewrite expression | C.expressionOrigin expression==marker = pure expression
      rewrite expression = case C.expressionNode expression of
        C.Construct tag arguments | Just (old,_)<-M.lookup tag constructors -> do
          unless (length arguments==length (C.constructorFields old)) (Left "transport source constructor arity is invalid")
          bound<-constructorBindingsAt oldRegistry (C.expressionType expression) tag (map C.expressionType arguments)
          (_,record,types,_,_)<-at (C.expressionType expression) tag bound
          payload<-constructRecord (fresh expression "fields") record types
            (zip (map C.binderName (C.constructorFields old)) arguments) marker
          pure (make (C.expressionType expression) (C.Construct tag [payload]))
        C.Match selected cases -> do
          branches<-sequence [case M.lookup (C.caseConstructor branch) constructors of
            Nothing->pure branch
            Just (old,_) -> do
              unless (length (C.caseBinders branch)==length (C.constructorFields old)) (Left "transport source pattern arity is invalid")
              bound<-constructorBindingsAt oldRegistry (C.expressionType selected) (C.caseConstructor branch)
                (map C.binderType (C.caseBinders branch))
              (ty,_,_,tag,fields)<-at (C.expressionType selected) (C.caseConstructor branch) bound
              let binder=C.Binder (fresh expression ("payload-"++show index)) "payload" ty
                  stored=zip (map C.binderName (C.constructorFields old)) (C.caseBinders branch)
              ordered<-mapM (\field -> maybe (Left "transport pattern field is missing") Right (lookup (C.binderName field) stored)) fields
              unless (map C.binderType ordered==map C.binderType fields) (Left "transport pattern field types differ")
              positions<-mapM (\index -> destination old index fields) [0..length (C.caseBinders branch)-1]
              let local=make ty (C.Local (C.binderId binder))
                  -- The canonical pattern elaborator binds named record
                  -- fields through checked projections in author order.
                  body=foldr (\(bound,position) rest -> make (C.expressionType rest)
                    (C.Let bound (make (C.binderType bound) (C.Project tag position local)) rest))
                    (C.caseBody branch) (zip (C.caseBinders branch) positions)
              pure branch{C.caseBinders=[binder],C.caseBody=body}
            | (index,branch)<-zip [0::Int ..] cases]
          pure expression{C.expressionNode=C.Match selected branches,C.expressionOrigin=marker}
        C.Project tag index selected | Just (old,_)<-M.lookup tag constructors -> do
          (ty,_,_,recordTag,fields)<-at (C.expressionType selected) tag M.empty
          target<-destination old index fields
          let payload=make ty (C.Project tag 0 selected)
          pure (make (C.expressionType expression) (C.Project recordTag target payload))
        C.Update tag index selected replacement | Just (old,_)<-M.lookup tag constructors -> do
          (ty,_,_,recordTag,fields)<-at (C.expressionType selected) tag M.empty
          target<-destination old index fields
          -- Update evaluates replacement before selected. Keeping it as the
          -- record Update's replacement preserves both order and once-only
          -- evaluation; outer construction has exactly this one payload.
          let payload=make ty (C.Project tag 0 selected)
              updated=make ty (C.Update recordTag target payload replacement)
          pure (make (C.expressionType expression) (C.Construct tag [updated]))
        _->pure expression
  -- Audit original predicates before replacing certified declaration headers;
  -- marking destination predicates must not hide a source-side observer.
  _<-transformProgramWithTypes M.empty auditType audit Right original
  changed<-transformProgram renames rewrite declaration augmented
  normalized<-either (Left . show) Right (normalizeProgramRecords changed)
  either (Left . show) Right (validateProgramWithScopes scopes normalized)
  pure normalized

-- | Full-Core correspondence after transport. Catalog ordering is not
-- execution order; field and predicate order, units and model metadata remain
-- authoritative. Domain policies are reported separately from body matching.
transportComparison :: PayloadPlan -> [(C.Id,String)] -> C.Program -> [(C.Id,String)] -> C.Program -> Either String Value
transportComparison plan beforeNames before afterNames after =
  snd <$> transportComparisonWithProgram plan beforeNames before afterNames after

-- Return the same validated comparison copy for frontend input-domain evidence;
-- callers must not reconstruct it from the wire view or use it for generation.
transportComparisonWithProgram :: PayloadPlan -> [(C.Id,String)] -> C.Program -> [(C.Id,String)] -> C.Program -> Either String (C.Program,Value)
transportComparisonWithProgram=transportComparisonWithScopes M.empty M.empty

transportComparisonWithScopes :: CapabilityScopes -> CapabilityScopes -> PayloadPlan -> [(C.Id,String)] -> C.Program -> [(C.Id,String)] -> C.Program -> Either String (C.Program,Value)
transportComparisonWithScopes beforeScopes afterScopes plan beforeNames before afterNames after = do
  unless (C.programMachineBits before==C.programMachineBits after) (Left "transport requires matching machine widths")
  either (Left . show) Right (validateProgramWithScopes beforeScopes before)
  either (Left . show) Right (validateProgramWithScopes afterScopes after)
  made<-transportProgramWithScopes beforeScopes plan before
  let order=map C.dataId (C.programDataDeclarations after)
      known=M.fromList [(C.dataId value,value) | value<-C.programDataDeclarations made]
      aligned=if Set.fromList order==M.keysSet known
        then made{C.programDataDeclarations=[value | identity<-order,Just value<-[M.lookup identity known]]}
        else made
  old<-migrationSnapshot False beforeNames aligned
  new<-migrationSnapshot True afterNames after
  source<-migrationSnapshot False beforeNames before
  let field key (Object fields)=maybe (Left "transport snapshot field is missing") Right (KM.lookup key fields)
      field _ _=Left "transport snapshot is not an object"
      fingerprint key snapshot=field key snapshot >>= \value -> case value of
        String text->Right text
        _->Left "transport snapshot fingerprint is invalid"
      result a b=object ["status" .= (if a==b then "matched" else "not-established"::String),"before" .= a,"after" .= b]
      available (Object fields)=Object (KM.insert "status" (String "available") fields)
      available value=value
  oldProgram<-fingerprint "programDigest" old
  newProgram<-fingerprint "programDigest" new
  sourceProgram<-fingerprint "programDigest" source
  oldDefinitions<-fingerprint "definitionPlaneDigest" old
  newDefinitions<-fingerprint "definitionPlaneDigest" new
  oldLaws<-fingerprint "lawBodiesDigest" old
  newLaws<-fingerprint "lawBodiesDigest" new
  oldPolicies<-field "domainPolicies" old
  newPolicies<-field "domainPolicies" new
  let matched=oldDefinitions==newDefinitions && oldLaws==newLaws
  pure (aligned,object ["status" .= (if matched then "matched" else "not-established"::String),
    "version" .= (1::Int),"algorithm" .= ("sha256"::String),"machineBits" .= C.programMachineBits before,
    "scope" .= ("complete checked concrete Core after certified payload transport; body matching excludes input-domain policies"::String),
    "copyValidated" .= True,"originalsUnchanged" .= True,"sourceBeforeDigest" .= sourceProgram,
    "catalogOrdering" .= ("aligned by checked type identity; field and predicate order retained"::String),
    "assumptions" .= ["External adapters and handlers must respect the same value transport; native conformance remains separate."::String],
    "program" .= result oldProgram newProgram,"definitionPlane" .= result oldDefinitions newDefinitions,
    "lawBodies" .= result oldLaws newLaws,
    "domainPolicies" .= object ["before" .= oldPolicies,"after" .= newPolicies,
      "status" .= (if oldPolicies==newPolicies then "matched" else "not-established"::String)],
    "before" .= available old,"after" .= available new])


marker :: C.Origin
marker=C.GeneratedFrom (C.Id "<migration-payload-transport>")

fresh :: C.Expr -> String -> C.Id
fresh expression suffix=C.Id ("<migration-payload-transport>::"++digestHex (digest (BL.toStrict (encode expression)))++"::"++suffix)

mark :: C.Expr -> C.Expr
mark expression=(C.mapChildren mark expression){C.expressionOrigin=marker}

plain :: Context
plain=Context False False M.empty M.empty M.empty (C.Id "transport") 0 False Right Right Set.empty M.empty Right

-- Overapproximations deliberately reject an affected observer instead of
-- equating operations whose ordering, rendering or scheduling can change.
names :: C.Type -> [C.Id]
names (C.Constructor name arguments)=C.Id name:concat [names ty | C.TypeArgument ty<-arguments]
names (C.Arrow a b)=names a++names b
names C.TypeVariable{}=[]

rootName :: C.Type -> [C.Id]
rootName (C.Constructor name _)=[C.Id name]
rootName _=[]

variables :: C.Type -> [C.Id]
variables (C.TypeVariable name)=[name]
variables (C.Constructor _ arguments)=concat [variables ty | C.TypeArgument ty<-arguments]
variables (C.Arrow a b)=variables a++variables b

closure :: M.Map C.Id [C.Id] -> Set.Set C.Id -> Set.Set C.Id
closure graph roots=go Set.empty (Set.toList roots)
  where
    go seen []=seen
    go seen (identity:rest)
      | identity `Set.member` seen=go seen rest
      | otherwise=go (Set.insert identity seen) (M.findWithDefault [] identity graph++rest)
