{-# LANGUAGE FlexibleContexts #-}
-- | Reconcile canonical structural types with the parameterized storage of
-- nominal constructors. A view uses ordinary checked matching/construction;
-- nominal identities and constructor layouts remain unchanged.
-- ref:DEC-typed-core-boundary ref:DEC-total-definitions
module LawSpec.Core.RecordViews (structuralViews) where

import Control.Monad (unless,zipWithM)
import Control.Monad.State.Strict
import Control.Monad.Except
import qualified Data.Map.Strict as M
import LawSpec.Core
import qualified LawSpec.Core.Types as Types
import LawSpec.Digest (digestHex,digestString)

type Scope = M.Map Id Type

-- The canonicalizer proves equality using complete typed descriptors, including
-- restrictions; labels alone never authorize a representation conversion.
structuralViews :: Monad m => (Type -> m Type) -> [DataDeclaration] -> Scope -> Expr -> m (Either String Expr)
structuralViews canonical declarations outer source =
  evalStateT (runExceptT (go outer source)) (0 :: Int)
  where
    registry=Types.makeRegistry declarations
    catalog=M.fromList [(dataId d,d) | d<-Types.builtinDataDeclarations++declarations]
    fingerprint=digestHex (digestString (show source))
    prefix="lawspec::record-view::"++fingerprint
    equal a b=do
      a'<-lift (lift (canonical a));b'<-lift (lift (canonical b))
      unless (a'==b') (throwError "structural representation types differ")
    fields ty tag actual=liftEither (registry >>= \known->Types.constructorFieldsAt known ty tag actual)
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
                bound<-mapM fresh oldFields
                let local b=Expr (binderType b) (Local (binderId b)) (expressionOrigin value)
                values<-zipWithM (\target sourceField->adapt (binderType target) (local sourceField)) newFields bound
                pure (Expr wanted (Match value [MatchCase (constructorId old) bound
                  (Expr wanted (Construct (constructorId new) values) (expressionOrigin value))]) (expressionOrigin value))
              _->throwError "a structural representation view requires matching record storage"
            _->throwError "a structural representation view requires record storage"
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
        expected<-fields (expressionType value) tag []
        case drop index expected of
          field:_->adapt (expressionType original) original{expressionType=binderType field,expressionNode=Project tag index value}
          []->throwError "structural projection field is out of range"
      Update tag index subject replacement -> do
        value<-go scope subject;field<-go scope replacement
        expected<-fields (expressionType value) tag []
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
