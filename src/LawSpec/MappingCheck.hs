-- | Intrinsic mapping obligations over ordinary, checked Core definitions.
-- Row constants have already passed contextual inference and definition
-- admission. This pass uses the same evaluator, Eq and complete finite covers
-- as the rest of the compiler; it does not verify authored laws.
module LawSpec.MappingCheck (MappingSelection,selectMappingCandidates,contextualizeMappings,checkMappings) where

import Control.Monad (foldM,forM,forM_,unless,when)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Types as Types
import qualified LawSpec.Core.Value as V
import qualified LawSpec.Core.Eval as Eval
import qualified LawSpec.Testing as Testing
import LawSpec.Scalar (Scalar(..))
import LawSpec.Common

data MappingDerivation = MappingDerivation Bool [[Int]] deriving (Eq,Show)
type MappingSelection = M.Map (String,String) MappingDerivation

-- The provisional pass offers candidate inverse declarations for ordinary
-- name/type checking. Only a typed uniqueness result can retain them in the
-- final pass. Reparse/resolution also prevents documentary or imported links
-- to an unavailable inverse from surviving. A real source declaration wins a
-- provisional collision; an actually derived collision is still an error.
selectMappingCandidates :: Maybe MappingSelection -> [S.Import] -> S.Unit -> S.Unit
selectMappingCandidates selected imports unit = unit
  { S.functionDefinitions=retained
  , S.functions=replaceGroups Set.empty (S.functions unit)
  , S.declarationSpans=ranges }
  where
    removed=filter (not.keep) (S.functionDefinitions unit)
    retained=map preimages (filter keep (S.functionDefinitions unit))
    preimages definition=case (selected,S.functionMapping definition) of
      (Just choices,Just origin) | S.mappingRole origin==S.MappingPreimages,
        Just (MappingDerivation _ groups)<-M.lookup (S.mappingOwner origin,S.mappingName origin) choices,
        [forward]<-[d | d<-S.functionDefinitions unit,Just other<-[S.functionMapping d],
          S.mappingRole other==S.MappingForward,S.mappingOwner other==S.mappingOwner origin,
          S.mappingName other==S.mappingName origin],
        Just rows<-sourceRows (length (S.mappingRowSpans origin)) (S.functionBody forward),
        [(input,_)]<-S.functionArguments definition ->
          let select condition yes no=foldl S.Apply (S.Var "prelude.select") [condition,yes,no]
              group indices rest=case [rows!!index | index<-indices] of
                []->rest
                values@((_,output):_)->select (S.Binary "==" (S.Var input) output)
                  (S.ListLit (map fst values)) rest
          in definition{S.functionBody=foldr group (S.ListLit []) groups}
      _->definition
    sourceRows 0 _=Just []
    sourceRows count expression=case expression of
      S.Apply (S.Apply (S.Apply (S.Var "prelude.select") (S.Binary "==" _ key)) output) rest ->
        ((key,output):) <$> sourceRows (count-1) rest
      _->Nothing
    removedNames=Set.fromList (map S.functionName removed)
    removedRanges=[(S.functionName d,S.functionSpan d) | d<-removed]
    ranges=filter (`notElem` removedRanges) (S.declarationSpans unit)
    signature definition=(S.functionName definition,
      foldr S.Arrow (S.functionResult definition) (map snd (S.functionArguments definition)))
    -- Flow/index preparation can copy the first same-named signature onto a
    -- provisional duplicate. Recover retained declarations from their actual
    -- source ranges and bodies, rather than deleting by that rewritten type.
    replacements name=case [(n,range) | (n,range)<-ranges,n==name] of
      []->map signature [d | d<-retained,S.functionName d==name]
      locations->concat [case [d | d<-retained,S.functionName d==name,S.functionSpan d==range] of
        d:_->[signature d]
        []->take 1 [(n,ty) | (n,ty)<-S.functions unit,n==name] | (_,range)<-locations]
    replaceGroups _ []=[]
    replaceGroups seen (entry@(name,_):rest)
      | name `Set.notMember` removedNames=entry:replaceGroups seen rest
      | name `Set.member` seen=replaceGroups seen rest
      | otherwise=replacements name++replaceGroups (Set.insert name seen) rest
    explicit item=case spanStart (S.importSpan item) of Location path _ _->take 1 path/="<"
    importedNames=[unquote name | item<-imports,explicit item,name<-S.importItems item]
    unquote ('`':rest) | not (null rest),last rest=='`'=init rest
    unquote name=name
    keep definition=case S.functionMapping definition of
      Just origin | S.mappingRole origin==S.MappingInverse -> case selected of
        Just choices->case M.lookup (S.mappingOwner origin,S.mappingName origin) choices of
          Just (MappingDerivation eligible _)->eligible
          Nothing->False
        Nothing->S.functionName definition `notElem` importedNames && not (any (\other -> S.functionName other==S.functionName definition &&
          maybe True ((/=S.MappingInverse).S.mappingRole) (S.functionMapping other))
          (S.functionDefinitions unit)) &&
          not (any (\(name,range) -> name==S.functionName definition && range/=S.functionSpan definition)
            (S.declarationSpans unit))
      _->True

-- Contextualize constants after aliases have expanded. Storage annotations
-- select numeric representations without asserting refinements: full declared
-- contracts remain on the definitions and each constant is checked separately.
contextualizeMappings :: S.Unit -> S.Unit
contextualizeMappings unit=unit{S.functionDefinitions=map contextualize (S.functionDefinitions unit)}
  where
    annotation ty expression=S.Annotate expression (S.baseType ty)
    comparison ty (S.Binary "==" input value)=S.Binary "==" input (annotation ty value)
    comparison _ other=other
    contextualize d=case (S.functionMapping d,S.functionArguments d) of
      (Just origin,[(_,inputType)])->d{S.functionBody=case S.mappingRole origin of
        S.MappingForward->forward inputType (S.functionResult d) (S.functionBody d)
        S.MappingPreimages->case S.functionResult d of
          S.Applied "List" keyType->preimages inputType keyType (S.functionBody d)
          _->S.functionBody d
        S.MappingInverse->case S.functionResult d of
          S.Applied "Maybe" keyType->inverse inputType keyType (S.functionBody d)
          _->S.functionBody d}
      _->d
    forward inputType resultType (S.Apply (S.Apply (S.Apply root condition) value) rest)=
      S.Apply (S.Apply (S.Apply root (comparison inputType condition)) (annotation resultType value))
        (forward inputType resultType rest)
    forward _ resultType body=annotation resultType body
    preimages inputType keyType (S.Apply (S.Apply (S.Apply root condition) (S.ListLit values)) rest)=
      S.Apply (S.Apply (S.Apply root (comparison inputType condition))
        (S.ListLit (map (annotation keyType) values))) (preimages inputType keyType rest)
    preimages _ _ body=body
    inverse inputType keyType (S.Apply (S.Apply (S.Apply root condition) (S.ConstructLit "Maybe::Present" [key])) rest)=
      S.Apply (S.Apply (S.Apply root (comparison inputType condition))
        (S.ConstructLit "Maybe::Present" [annotation keyType key])) (inverse inputType keyType rest)
    inverse _ _ body=body

checkMappings :: S.Generation -> [S.Unit] -> C.Program
  -> (C.Id -> [V.Value] -> Either String V.Value)
  -> Either [Diagnostic] MappingSelection
checkMappings settings source program invoke = do
  registry<-at Nothing "mapping" (Types.makeRegistry (C.programDataDeclarations program))
  results<-forM [(unit,definition,origin) | unit<-source,definition<-S.functionDefinitions unit,
    Just origin<-[S.functionMapping definition],S.mappingRole origin==S.MappingForward] $ \(unit,definition,origin)->do
      let identity=C.Id (S.unitName unit++"::"++S.functionName definition)
          location=Just (spanStart (S.functionSpan definition))
          candidates=[d | u<-C.programUnits program,d<-C.unitDefinitions u,
            C.declarationId (C.definitionDeclaration d)==identity]
      compiled<-at location "mapping" $ case candidates of
        [d]->Right d
        _->Left "a mapping requires a closed, checked definition"
      argument<-at location "mapping" $ case C.definitionArguments compiled of
        [value]->Right value
        _->Left "a mapping must have exactly one input"
      (rows,fallback)<-at location "mapping" (splitRows (length (S.mappingRowSpans origin)) (C.definitionBody compiled))
      let contracts=[contract | u<-C.programUnits program,
            contract<-C.unitContracts u,C.contractDeclaration contract==identity]
          -- Contract binders have their own resolved identities. Align them
          -- with the definition input for a complete-domain query; evaluation
          -- of the original contracts uses their original argument scope.
          predicates=[C.renameLocal (C.binderId input) (C.binderId argument) predicate
            | contract<-contracts,input<-C.contractArguments contract,
              predicate<-C.contractPreconditions contract]
          evaluate=Eval.evaluateValue registry bits invoke
          constant range expected expression=at (Just (spanStart range)) "mapping-constant" $ do
            value<-evaluate [] expression
            V.validateValueWith evaluate registry bits expected value
          requirement range key=forM_ contracts $ \contract->
            forM_ (C.contractPreconditions contract) $ \predicate->do
              value<-at (Just (spanStart range)) "mapping-key"
                (evaluate [(C.binderId input,key) | input<-C.contractArguments contract] predicate)
              unless (value==V.ScalarValue (SBool True)) (Left [Diagnostic "mapping-key"
                "mapping key violates its declared input restriction" (Just (spanStart range))])
          outputRequirements range key value=forM_ contracts $ \contract->do
            let bindings=(C.binderId (C.contractResult contract),value):
                  maybe [] (\value->[(C.binderId input,value) | input<-C.contractArguments contract]) key
                known=map fst bindings
            forM_ (C.contractPostconditions contract++C.contractRuntimePostconditions contract) $ \predicate->
              -- A row fixes its input. An explicit fallback must independently
              -- satisfy closed result restrictions; input-dependent claims
              -- retain ordinary definition proof/runtime enforcement.
              when (key/=Nothing || all (`elem` known) (C.freeBinders predicate)) $ do
                valid<-at (Just (spanStart range)) "mapping-constant" (evaluate bindings predicate)
                unless (valid==V.ScalarValue (SBool True)) (Left [Diagnostic "mapping-constant"
                  "mapping output violates its declared result restriction" (Just (spanStart range))])
      values<-forM (zip (S.mappingRowSpans origin) rows) $ \(range,(key,output))->do
        keyValue<-constant range (C.binderType argument) key
        requirement range keyValue
        outputValue<-constant range (C.expressionType (C.definitionBody compiled)) output
        outputRequirements range (Just keyValue) outputValue
        reflexive<-at (Just (spanStart range)) "mapping-key" (V.equalValues bits keyValue keyValue)
        unless reflexive (Left [Diagnostic "mapping-key"
          "mapping keys must be reflexive under Eq; NaN is not a key" (Just (spanStart range))])
        pure (keyValue,outputValue)
      forM_ (zip3 [0::Int ..] (S.mappingRowSpans origin) values) $ \(index,range,(key,_))->forM_ (drop (index+1) values) $ \(other,_)->do
        equal<-at location "mapping-key" (V.equalValues bits key other)
        when equal (Left [Diagnostic "mapping-duplicate" "duplicate mapping key under typed Eq"
          (Just (spanStart range))])
      case S.mappingFallbackSpan origin of
        Just range->do
          value<-constant range (C.expressionType (C.definitionBody compiled)) fallback
          outputRequirements range Nothing value
        Nothing->do
          let limit=max (S.exhaustiveLimit settings) (length rows+1)
              quantifier=C.Quantifier argument predicates []
          complete<-at location "mapping-coverage"
            (Testing.finiteUniversalInputs registry bits limit invoke [quantifier])
          domain<-at location "mapping-coverage" $ maybe
            (Left "complete finite mapping coverage was not established; supply an explicit otherwise value") Right complete
          forM_ domain $ \tuple->case tuple of
            [value]->do
              covered<-at location "mapping-coverage" (or <$> mapM (V.equalValues bits value . fst) values)
              unless covered (Left [Diagnostic "mapping-coverage"
                "mapping omits an input; supply its row or an explicit otherwise value" location])
            _->Left [Diagnostic "mapping-coverage" "invalid complete mapping input cover" location]
      let outputs=map snd values
      reflexive<-at location "mapping-inverse" (and <$> mapM (\value->V.equalValues bits value value) outputs)
      distinct<-at location "mapping-inverse" (and <$> sequence
        [not <$> V.equalValues bits value other | (index,value)<-zip [0::Int ..] outputs,other<-drop (index+1) outputs])
      groups<-foldM (insertOutput outputs location) [] [0..length outputs-1]
      pure ((S.mappingOwner origin,S.mappingName origin),MappingDerivation
        (S.mappingFallbackSpan origin==Nothing && reflexive && distinct) groups)
  let grouped=M.fromListWith (++) [(identity,[eligible]) | (identity,eligible)<-results]
  forM_ (M.elems grouped) $ \values->case values of
    []->Left [Diagnostic "mapping" "missing mapping derivation" Nothing]
    first:rest->unless (all (==first) rest)
      (Left [Diagnostic "mapping" "mapping derivation differs across imported copies" Nothing])
  pure (M.map head grouped)
  where
    bits=C.programMachineBits program
    at location code=either (Left . pure . (\message->Diagnostic code message location)) Right
    insertOutput _ _ groups index | null groups=pure [[index]]
    insertOutput outputs location (group:rest) index=do
      equal<-at location "mapping-inverse" (V.equalValues bits (outputs!!head group) (outputs!!index))
      if equal then pure ((group++[index]):rest)
        else (group:) <$> insertOutput outputs location rest index
    insertOutput _ _ [] index=pure [[index]]
    splitRows 0 body=Right ([],body)
    splitRows count body=case C.expressionNode body of
      C.If condition output rest->case C.expressionNode condition of
        C.Binary C.Equal _ _ key->do
          (rows,fallback)<-splitRows (count-1) rest
          pure ((key,output):rows,fallback)
        _->Left "checked mapping row lost its typed equality"
      _->Left "checked mapping body lost its row boundaries"
