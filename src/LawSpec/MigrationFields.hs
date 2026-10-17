-- | Source edit facts from the existing checked typed expressions. These are
-- documentary constructor/field identities, never executable terms or a second
-- inference engine. Exact suffix ranges come from the original parser.
module LawSpec.MigrationFields (sourceFields) where

import Control.Monad (unless)
import Data.Aeson (Value,object,(.=))
import Data.List (sortOn,stripPrefix,nub)
import qualified Data.Map.Strict as M
import qualified LawSpec.Core as C
import LawSpec.Common (Span(..),Location(..))
import LawSpec.Elaboration (coreTypeWithSourceRecords)
import qualified LawSpec.Model as S
import LawSpec.MigrationScopes (sourceContext)
import LawSpec.MigrationTemplates (SourceTemplates(..),legacyNominalRecord)
import LawSpec.SourceSyntax

sourceFields :: SourceTemplates -> [SourceSyntax] -> Either String Value
sourceFields captured syntax = do
  facts <- concat <$> mapM (visit Nothing 0 0) terms
  unique <- foldl insert (Right M.empty) facts
  let covered=map fst facts
  unless (all (\node -> key (syntaxSpan node) `elem` covered) nodes)
    (Left "some source field operations have no checked typed occurrence")
  pure (object ["version" .= (1::Int),"status" .= ("available"::String),"uses" .= M.elems unique,
    "constructors" .= [object ["constructor" .= C.idText (C.constructorId tag),
      "nominalRecord" .= legacyNominalRecord declaration tag] |
      declaration<-templateDataDeclarations captured,tag<-C.dataConstructors declaration]])
  where
    nodes=nub [node | source<-syntax,node<-syntaxNodes source,syntaxKind node `elem` ["field-access","field-update"]]
    terms=concat [body:before++after | (_,definitions)<-templateDefinitions captured,(_,body,before,after)<-definitions] ++
      concatMap S.typedExpressions (templateLaws captured)
    spanValue (Span start end)=object ["start" .= start,"end" .= end]
    key=show
    location (Location path line column)=(path,line,column)
    contains (Span a b) (Span c d)=location a<=location c && location d<=location b && file a==file c && file b==file d
    suffix kind depth range label=do
      let within=[node | node<-nodes,syntaxKind node==kind,contains range (syntaxSpan node)]
          direct=[node | node<-within,not (any (\outer -> outer/=node && contains (syntaxSpan outer) (syntaxSpan node)) within)]
          candidates=reverse (sortOn (location . spanStart . syntaxSpan) direct)
      case drop depth candidates of
        node:_ | syntaxName node==Just label -> Right (syntaxSpan node)
        _ -> Left ("cannot associate checked "++kind++" with its source suffix: "++label)
    constructor value label=do
      let rigid=S.mapType (\ty -> case ty of S.Variable name->S.Named ('@':name);other->other) (S.mapExprTypes rigid)
      (ty,_)<-coreTypeWithSourceRecords (sourceContext captured) (templateDataDeclarations captured)
        (templateMachineBits captured) (rigid (S.expressionType value))
      case ty of
        C.Constructor parent _ | [declaration]<-[d | d<-templateDataDeclarations captured,C.idText (C.dataId d)==parent],
          [tag]<-C.dataConstructors declaration,
          [(index,_)]<-[(index,field) | (index,field)<-zip [0::Int ..] (C.constructorFields tag),C.binderName field==label] ->
            Right (C.constructorId tag,index)
        _ -> Left ("checked source field has no unique nominal constructor: "++label)
    insert result (identity,value)=do
      values<-result
      case M.lookup identity values of
        Just old | old/=value -> Left "a source field suffix resolves to inconsistent constructor identities"
        _ -> Right (M.insert identity value values)
    unlocated typed=case S.expression typed of
      S.Located _ inner->unlocated typed{S.expression=inner}
      _->typed
    base typed=case (S.expression (unlocated typed),S.operands typed) of
      (S.Apply (S.Apply (S.Var name) _) _,value:_) | Just _<-stripPrefix S.fieldUpdatePrefix name -> base value
      _ -> case S.expression typed of
        S.Located range _->Just range
        _->Nothing
    visit origin projections updates typed=case S.expression typed of
      S.Located range inner->visit (Just range) 0 0 typed{S.expression=inner}
      expression->do
        let own kind depth label value extras=case origin of
              Just range | any (\node -> syntaxKind node==kind && contains range (syntaxSpan node)) nodes -> do
                at<-suffix kind depth range label
                (tag,index)<-constructor value label
                pure [(key at,object (["kind" .= kind,"field" .= label,"constructor" .= C.idText tag,
                  "index" .= index,"span" .= spanValue at]++extras))]
              _ -> pure []
        (found,children)<-case (expression,S.operands typed) of
          (S.Apply (S.Var name) _,[value]) | Just label<-stripPrefix S.fieldAccessPrefix name -> do
            found<-own "field-access" projections label value []
            children<-visit origin (projections+1) updates value
            pure (found,children)
          (S.Apply (S.Apply (S.Var name) _) _,[value,replacement]) | Just label<-stripPrefix S.fieldUpdatePrefix name -> do
            let ranges=case (base value,origin) of
                  (Just selected,Just range)->["base" .= spanValue selected,"expression" .= spanValue (Span (spanStart selected) (spanEnd range))]
                  _->[]
            found<-own "field-update" updates label value ranges
            children<-(++) <$> visit origin projections (updates+1) value <*> visit origin 0 0 replacement
            pure (found,children)
          _ -> (,) [] . concat <$> mapM (visit origin 0 0) (S.operands typed)
        cases<-concat <$> mapM (\(S.TypedCase _ _ body)->visit origin 0 0 body) (S.typedCases typed)
        pure (found++children++cases)
