{-# LANGUAGE FlexibleContexts #-}
-- | Reconcile canonical structural types with the parameterized storage of
-- nominal constructors. A view uses ordinary checked matching/construction;
-- nominal identities and constructor layouts remain unchanged.
-- ref:DEC-typed-core-boundary ref:DEC-total-definitions
module LawSpec.Core.RecordViews (structuralViews,structuralViewsWith,adaptStructuralWith) where

import Control.Monad (unless,zipWithM,zipWithM_,foldM)
import Control.Monad.State.Strict
import Control.Monad.Except
import qualified Data.Map.Strict as M
import LawSpec.Core
import qualified LawSpec.Core.Types as Types
import qualified LawSpec.Core.RecordInstances as Instances
import LawSpec.Digest (digestHex,digestString)

type Scope = M.Map Id Type

-- The canonicalizer proves equality using complete typed descriptors, including
-- restrictions; labels alone never authorize a representation conversion.
structuralViews :: Monad m => (Type -> m Type) -> [DataDeclaration] -> Scope -> Expr -> m (Either String Expr)
structuralViews canonical declarations = structuralViewsWith canonical declarations
  (\_ _ -> pure (Left "a structural representation view requires matching record storage"))

-- The enclosing program supplies ordinary checked functions for recursive
-- nominal containers. Standalone closed data needs only finite reconstruction.
structuralViewsWith :: Monad m => (Type -> m Type) -> [DataDeclaration]
  -> (Type -> Expr -> m (Either String Expr)) -> Scope -> Expr -> m (Either String Expr)
structuralViewsWith canonical declarations convert outer = runViews canonical declarations convert outer Nothing

adaptStructuralWith :: Monad m => (Type -> m Type) -> [DataDeclaration]
  -> (Type -> Expr -> m (Either String Expr)) -> Type -> Expr -> m (Either String Expr)
adaptStructuralWith canonical declarations convert wanted = runViews canonical declarations convert M.empty (Just wanted)

runViews :: Monad m => (Type -> m Type) -> [DataDeclaration]
  -> (Type -> Expr -> m (Either String Expr)) -> Scope -> Maybe Type -> Expr -> m (Either String Expr)
runViews canonical declarations convert outer wanted source =
  evalStateT (runExceptT (maybe (go outer source) (\target -> adapt target source) wanted)) (0 :: Int)
  where
    registry=Types.makeRegistry declarations
    catalog=M.fromList [(dataId d,d) | d<-Types.builtinDataDeclarations++declarations]
    fingerprint=digestHex (digestString (show source))
    prefix="lawspec::record-view::"++fingerprint
    equal a b=do
      a'<-lift (lift (canonical a));b'<-lift (lift (canonical b))
      unless (a'==b') (throwError "structural representation types differ")
    fields ty tag actual=do
      known<-liftEither registry
      case Types.constructorFieldsAt known ty tag actual of
        Right made->pure made
        Left reason->do
          -- A free existential is inferred from the actual payload, not from
          -- its parent type. Canonical records may have changed product IDs.
          -- Candidate matching opens only structural products; complete type
          -- normalization below must still establish the same descriptor.
          original<-liftEither (Types.constructorFieldsFor known ty tag)
          declaration<-case ty of
            Constructor name _->liftEither (Types.lookupData known (Id name))
            _->throwError reason
          constructor<-maybe (throwError reason) pure
            (lookup tag [(constructorId c,c) | c<-dataConstructors declaration])
          let flexible=Types.freeExistentials declaration constructor
          unless (not (null flexible) && length original==length actual) (throwError reason)
          bound<-maybe (throwError reason) pure (foldM (\current (field,value)->
            Instances.matchParameters known flexible current (binderType field) value)
            M.empty (zip original actual))
          made<-liftEither (Types.constructorFieldsAt known ty tag
            [Types.substitute bound (binderType field) | field<-original])
          zipWithM_ (\field value->equal (binderType field) value) made actual
          pure made
    projectedFields ty tag=liftEither (registry >>= \known->Types.constructorFieldsFor known ty tag)
    adapt wanted value
      | wanted==expressionType value=pure value
      | otherwise=do
          equal wanted (expressionType value)
          case (expressionType value,wanted) of
            (Constructor from _,Constructor to _) -> case (M.lookup (Id from) catalog,M.lookup (Id to) catalog) of
              (Just before,Just after) | dataStructural before/=Nothing,dataStructural after/=Nothing,
                  [old]<-dataConstructors before,[new]<-dataConstructors after -> do
                oldFields<-fields (expressionType value) (constructorId old) []
                newFields<-fields wanted (constructorId new) []
                unless (map binderName oldFields==map binderName newFields)
                  (throwError "structural representation field labels differ")
                nested<-or <$> zipWithM (\a b -> needsContainer (binderType a) (binderType b)) oldFields newFields
                closedValue<-if nested then closed M.empty value else pure Nothing
                case closedValue of
                  Just literal -> finite wanted literal
                  Nothing -> do
                    bound<-mapM fresh oldFields
                    let local b=Expr (binderType b) (Local (binderId b)) (expressionOrigin value)
                    values<-zipWithM (\target sourceField->adapt (binderType target) (local sourceField)) newFields bound
                    pure (Expr wanted (Match value [MatchCase (constructorId old) bound
                      (Expr wanted (Construct (constructorId new) values) (expressionOrigin value))]) (expressionOrigin value))
              _ | from==to -> do
                    literal<-closed M.empty value
                    case literal of
                      Just constant -> finite wanted constant
                      Nothing -> lift (lift (convert wanted value)) >>= liftEither
                | otherwise -> throwError "a structural representation view requires matching record storage"
            _->throwError "a structural representation view requires record storage"
    same a b = do
      a'<-lift (lift (canonical a));b'<-lift (lift (canonical b))
      pure (a'==b')
    needsContainer a b | a==b = pure False
    needsContainer a@(Constructor from _) b@(Constructor to _) =
      case (M.lookup (Id from) catalog,M.lookup (Id to) catalog) of
        (Just before,Just after) | dataStructural before/=Nothing,dataStructural after/=Nothing,
          [old]<-dataConstructors before,[new]<-dataConstructors after -> do
            left<-fields a (constructorId old) [];right<-fields b (constructorId new) []
            or <$> zipWithM (\x y -> needsContainer (binderType x) (binderType y)) left right
        _ -> pure (from==to)
    needsContainer _ _ = pure False
    -- Pure data may be reconstructed finitely without executing a function.
    -- Do not drop unused lets, partial matches, or a refinement-forgetting
    -- reconstruction: each original constructor check must remain represented.
    closed scope original = case expressionNode original of
      Constant _ -> pure (Just original)
      Local name -> pure (M.lookup name scope)
      Construct tag values -> do
        children'<-mapM (closed scope) values
        pure ((\made -> original{expressionNode=Construct tag made}) <$> sequence children')
      Let bound value body | uses (binderId bound) body==1 -> do
        value'<-closed scope value
        case value' of
          Just actual -> do
            compatible<-same (binderType bound) (expressionType actual)
            if compatible then closed (M.insert (binderId bound) actual scope) body else pure Nothing
          _ -> pure Nothing
      Match value [branch] -> do
        value'<-closed scope value
        compatible<-same (expressionType original) (expressionType value)
        let structural ty=case ty of
              Constructor name _ -> maybe False ((/=Nothing) . dataStructural) (M.lookup (Id name) catalog)
              _ -> False
        case value' of
          Just actual | Construct tag values<-expressionNode actual,
            tag==caseConstructor branch,compatible,structural (expressionType value),structural (expressionType original),
            length values==length (caseBinders branch) -> do
              expected<-fields (expressionType actual) tag (map expressionType values)
              valid<-and <$> zipWithM (\a b -> same (binderType a) (binderType b)) expected (caseBinders branch)
              if valid then closed (M.union (M.fromList (zip (map binderId (caseBinders branch)) values)) scope) (caseBody branch)
                else pure Nothing
          _ -> pure Nothing
      _ -> pure Nothing
    uses name expression=case expressionNode expression of
      Local identity -> if identity==name then 1 else 0
      Let bound value body -> uses name value + if binderId bound==name then 0 else uses name body
      Match value branches -> uses name value + sum [uses name (caseBody branch) | branch<-branches,name `notElem` map binderId (caseBinders branch)]
      AllElements value bound predicate -> uses name value + if binderId bound==name then 0 else uses name predicate
      AllPayloads value predicates -> uses name value + sum [uses name body | (bound,body)<-predicates,binderId bound/=name]
      _ -> sum (map (uses name) (children expression))
    finite wanted value = do
      equal wanted (expressionType value)
      case expressionNode value of
        Construct tag values -> do
          let targetTag=case wanted of
                Constructor name _ | Just declaration<-M.lookup (Id name) catalog,
                  dataStructural declaration/=Nothing,[constructor]<-dataConstructors declaration -> constructorId constructor
                _ -> tag
          expected<-fields wanted targetTag (map expressionType values)
          unless (length expected==length values) (throwError "structural constant view arity mismatch")
          made<-zipWithM (\field item -> finite (binderType field) item) expected values
          pure value{expressionType=wanted,expressionNode=Construct targetTag made}
        _ | wanted==expressionType value -> pure value
          | otherwise -> throwError "a structural constant view requires constructor data"
    fresh field=do
      index<-lift get;lift (put (index+1))
      let name="lawspecRecordView"++take 12 fingerprint++show index
      pure field{binderId=Id (prefix++"::"++name),binderName=name}
    go scope original=case expressionNode original of
      Local identity -> case M.lookup identity scope of
        Nothing->pure original
        Just actual->adapt (expressionType original) original{expressionType=actual}
      Construct tag values -> do
        values'<-mapM (go scope) values
        expected<-fields (expressionType original) tag (map expressionType values')
        unless (length expected==length values') (throwError "structural constructor view arity mismatch")
        made<-zipWithM (\field value->adapt (binderType field) value) expected values'
        pure original{expressionNode=Construct tag made}
      Project tag index subject -> do
        value<-go scope subject
        expected<-projectedFields (expressionType value) tag
        case drop index expected of
          field:_->adapt (expressionType original) original{expressionType=binderType field,expressionNode=Project tag index value}
          []->throwError "structural projection field is out of range"
      Update tag index subject replacement -> do
        value<-go scope subject;field<-go scope replacement
        expected<-projectedFields (expressionType value) tag
        case drop index expected of
          chosen:_->do
            made<-adapt (binderType chosen) field
            pure original{expressionNode=Update tag index value made}
          []->throwError "structural update field is out of range"
      Match subject branches -> do
        value<-go scope subject
        made<-mapM (branch scope value) branches
        pure original{expressionNode=Match value made}
      Let bound value body -> do
        value'<-go scope value >>= adapt (binderType bound)
        body'<-go (M.insert (binderId bound) (binderType bound) scope) body
        pure original{expressionNode=Let bound value' body'}
      AllElements value bound predicate -> do
        value'<-go scope value
        predicate'<-go (M.insert (binderId bound) (binderType bound) scope) predicate
        pure original{expressionNode=AllElements value' bound predicate'}
      AllPayloads value predicates -> do
        value'<-go scope value
        predicates'<-mapM (\(bound,predicate)->do
          predicate'<-go (M.insert (binderId bound) (binderType bound) scope) predicate
          pure (bound,predicate')) predicates
        pure original{expressionNode=AllPayloads value' predicates'}
      _ -> traverseChildren (go scope) original
    branch scope subject old=do
      expected<-fields (expressionType subject) (caseConstructor old) (map binderType (caseBinders old))
      unless (length expected==length (caseBinders old)) (throwError "structural match view arity mismatch")
      bound<-zipWithM (\sourceField target->do
        equal (binderType sourceField) (binderType target)
        pure sourceField{binderType=binderType target}) (caseBinders old) expected
      body<-go (M.union (M.fromList [(binderId b,binderType b) | b<-bound]) scope) (caseBody old)
      pure old{caseBinders=bound,caseBody=body}
