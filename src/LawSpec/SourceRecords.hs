-- | Collect source structural type occurrences before shared Core admission.
-- The declaration stream is distinct from the lookup catalogue; callers never
-- discard a differently ordered invariant by interning an equal identity.
-- ref:DEC-typed-core-boundary ref:DEC-total-definitions
module LawSpec.SourceRecords (recordDeclarations,recordDeclarationsWithContext,unitTypeReferences,typedTypeReferences,mapUnitTypeReferences) where

import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import LawSpec.Elaboration (coreTypeWithSourceRecords)
import qualified LawSpec.SourceContext as Source

recordDeclarations :: [C.DataDeclaration] -> Int -> [S.Type] -> Either String [C.DataDeclaration]
recordDeclarations = recordDeclarationsWithContext Source.emptyContext

recordDeclarationsWithContext :: Source.SourceContext -> [C.DataDeclaration] -> Int -> [S.Type] -> Either String [C.DataDeclaration]
recordDeclarationsWithContext context known bits types = concatMap snd <$> mapM (coreTypeWithSourceRecords context known bits) (filter contains types)
  where
    contains ty = case S.baseType ty of
      S.RecordShape _ -> True
      S.Arrow a b -> contains a || contains b
      S.Applied _ t -> contains t
      S.Application _ ts -> any contains ts
      _ -> False

typedTypeReferences :: S.TypedExpr -> [S.Type]
typedTypeReferences tree = S.expressionType tree : maybe [] pure (S.requiredConversion tree) ++
  concatMap typedTypeReferences (S.operands tree) ++
  concat [map snd fields ++ typedTypeReferences body | S.TypedCase _ fields body <- S.typedCases tree]

unitTypeReferences :: S.Unit -> [S.Type]
unitTypeReferences unit = map snd (S.functions unit) ++
  concat [map snd (S.dataConstructorFields c ++ S.dataConstructorEquations c) |
    d <- S.dataTypes unit,c <- S.dataTypeConstructors d] ++
  concat [map snd (S.refinementParameters r) ++ [S.refinementBody r] ++ constraints (S.refinementRequirements r) | r <- S.refinements unit] ++
  concat [map snd (S.functionArguments d) ++ [S.functionResult d] ++ constraints (S.functionRequirements d) ++ expression (S.functionBody d) | d <- S.functionDefinitions unit] ++
  concat [map snd (S.contractArguments c) ++ [snd (S.contractResult c)] ++ concatMap expression (S.contractPreconditions c ++ S.contractPostconditions c) | c <- S.contracts unit] ++
  concatMap law (S.laws unit) ++
  concat [map snd (S.abilityOperations a ++ S.abilityFailures a) ++ maybe [] pure (S.abilityResource a) ++ concatMap law (S.abilityLaws a) | a <- S.abilities unit] ++
  concat [S.handlerAbility h : S.handlerAlso h ++ maybe [] (\(_,t,e) -> t:expression e) (S.handlerState h) ++ concatMap (expression . S.clauseBody) (S.handlerClauses h) | h <- S.handlerDeclarations unit] ++
  concatMap snd (S.declaredUses unit ++ S.abilityRows unit) ++ concatMap (map fst . snd) (S.lawAssignments unit) ++
  concat [t:expression (S.resourceAcquire r) ++ expression (snd (S.resourceRelease r)) ++ maybe [] (expression . snd) (S.resourceReset r) | r <- S.resourceDeclarations unit,let t=S.resourceType r] ++
  concat [map step (S.protocolSteps p) | p <- S.protocols unit] ++ [t | (_,t,_) <- S.mailboxes unit] ++
  maybe [] (concatMap item . S.harnessItems) (S.unitHarness unit) ++ concatMap (plan . snd) (S.lawHarness unit)
  where
    constraints values = [t | S.Capability _ t <- values]
    law l = map snd (S.parameters l ++ S.lawResources l) ++ constraints (S.requirements l) ++ definition (S.definition l) ++
      concat [concatMap (expression . S.actual) (S.expectations e) | e <- S.examples l]
    definition d = case d of
      S.Forall binders body -> map snd binders ++ definition body
      S.Exists binders body -> map snd binders ++ definition body
      S.Equal a b -> expression a ++ expression b
      S.Holds a -> expression a
      S.Implies a b -> expression a ++ definition b
      S.And a b -> definition a ++ definition b
      S.Not a -> definition a
      S.Invoke _ args -> concatMap expression args
    step (S.Send t) = t
    step (S.Receive t) = t
    item value = case value of
      S.HarnessStrategy strategy -> S.strategyType strategy : generator (S.strategyBody strategy)
      S.HarnessDefault value _ -> setting value
      S.HarnessFor _ values _ -> concatMap (setting . fst) values
      S.HarnessBenchmark _ body _ -> expression body
      _ -> []
    setting value = case value of
      S.WitnessSetting _ body _ -> expression body
      S.CoverSetting _ _ body -> expression body
      S.ClassifySetting body _ -> expression body
      S.LabelSetting body -> expression body
      S.TargetMaximize body -> expression body
      _ -> []
    plan p = concat [t:generator gen | (_,_,t,gen) <- S.planDraws p] ++
      concat [S.inputType (S.witnessInput w) : map S.inputType (S.witnessScope w) ++ expression (S.witnessExpression w) | w <- S.planResolvedWitnesses p] ++
      concatMap (expression . (\(_,_,e) -> e)) (S.planCover p) ++ concatMap (expression . fst) (S.planClassify p) ++
      concatMap expression (S.planLabels p) ++ maybe [] expression (S.planTarget p)
    generator value = case value of
      S.GenAny ty -> maybe [] pure ty
      S.GenNamed _ -> []
      S.GenOneOf values -> concatMap expression values
      S.GenFrequency branches -> concatMap (generator . snd) branches
      S.GenSuchThat inner predicate _ -> generator inner ++ expression predicate
      S.GenBind _ ty first rest -> ty : generator first ++ generator rest

expression :: S.Expr -> [S.Type]
expression source = case source of
  S.Located _ value -> expression value
  S.Annotate value ty -> ty:expression value
  S.TypeBound _ ty -> [ty]
  S.Apply a b -> expression a ++ expression b
  S.Compose a b -> expression a ++ expression b
  S.Binary _ a b -> expression a ++ expression b
  S.Unary _ a -> expression a
  S.RecordLit fields -> concatMap (expression . snd) fields
  S.ConstructLit _ fields -> concatMap expression fields
  S.ListLit fields -> concatMap expression fields
  S.MatchExpr value branches -> expression value ++ concat [expression body | S.MatchBranch _ _ body <- branches]
  S.AllElementsExpr value _ predicate -> expression value ++ expression predicate
  S.AllPayloadsExpr value predicates -> expression value ++ concatMap (expression . snd) predicates
  _ -> []

-- | Transform the same source type-bearing positions that the collector reads.
-- Value expressions retain their structure and origins; only their embedded
-- annotations change. This keeps generated predicate bodies out of authored
-- functions and laws while admitting the types they mention consistently.
mapUnitTypeReferences :: (S.Type -> S.Type) -> S.Unit -> S.Unit
mapUnitTypeReferences ty unit=unit
  { S.functions=map pair (S.functions unit)
  , S.dataTypes=[declaration{S.dataTypeConstructors=
      [constructor{S.dataConstructorFields=map pair (S.dataConstructorFields constructor)
        ,S.dataConstructorEquations=map pair (S.dataConstructorEquations constructor)}
      | constructor<-S.dataTypeConstructors declaration]} | declaration<-S.dataTypes unit]
  , S.refinements=[refinement{S.refinementParameters=map pair (S.refinementParameters refinement)
      ,S.refinementRequirements=map constraint (S.refinementRequirements refinement)
      ,S.refinementBody=ty (S.refinementBody refinement)} | refinement<-S.refinements unit]
  , S.functionDefinitions=[definition{S.functionArguments=map pair (S.functionArguments definition)
      ,S.functionResult=ty (S.functionResult definition)
      ,S.functionRequirements=map constraint (S.functionRequirements definition)
      ,S.functionBody=expr (S.functionBody definition)} | definition<-S.functionDefinitions unit]
  , S.contracts=[contract{S.contractArguments=map pair (S.contractArguments contract)
      ,S.contractResult=pair (S.contractResult contract)
      ,S.contractPreconditions=map expr (S.contractPreconditions contract)
      ,S.contractPostconditions=map expr (S.contractPostconditions contract)} | contract<-S.contracts unit]
  , S.laws=map law (S.laws unit)
  , S.abilities=[ability{S.abilityOperations=map pair (S.abilityOperations ability)
      ,S.abilityFailures=map pair (S.abilityFailures ability)
      ,S.abilityResource=ty <$> S.abilityResource ability
      ,S.abilityLaws=map law (S.abilityLaws ability)} | ability<-S.abilities unit]
  , S.handlerDeclarations=[handler{S.handlerAbility=ty (S.handlerAbility handler)
      ,S.handlerAlso=map ty (S.handlerAlso handler)
      ,S.handlerState=(\(name,value,body)->(name,ty value,expr body)) <$> S.handlerState handler
      ,S.handlerClauses=[clause{S.clauseBody=expr (S.clauseBody clause)} | clause<-S.handlerClauses handler]}
      | handler<-S.handlerDeclarations unit]
  , S.declaredUses=map row (S.declaredUses unit)
  , S.abilityRows=map row (S.abilityRows unit)
  , S.lawAssignments=[(name,[(ty value,choice) | (value,choice)<-assignments]) | (name,assignments)<-S.lawAssignments unit]
  , S.resourceDeclarations=[resource{S.resourceType=ty (S.resourceType resource)
      ,S.resourceAcquire=expr (S.resourceAcquire resource)
      ,S.resourceRelease=fmap expr (S.resourceRelease resource)
      ,S.resourceReset=fmap (fmap expr) (S.resourceReset resource)} | resource<-S.resourceDeclarations unit]
  , S.protocols=[protocol{S.protocolSteps=map step (S.protocolSteps protocol)} | protocol<-S.protocols unit]
  , S.mailboxes=[(name,ty value,range) | (name,value,range)<-S.mailboxes unit]
  , S.unitHarness=(\harness->harness{S.harnessItems=map item (S.harnessItems harness)}) <$> S.unitHarness unit
  , S.lawHarness=[(name,plan value) | (name,value)<-S.lawHarness unit]
  }
  where
    pair (name,value)=(name,ty value)
    row (name,values)=(name,map ty values)
    constraint (S.Capability name value)=S.Capability name (ty value)
    expr=S.mapExprTypes ty
    definition source=case source of
      S.Forall binders body->S.Forall (map pair binders) (definition body)
      S.Exists binders body->S.Exists (map pair binders) (definition body)
      S.Not body->S.Not (definition body)
      S.And left right->S.And (definition left) (definition right)
      S.Implies guard body->S.Implies (expr guard) (definition body)
      S.Equal left right->S.Equal (expr left) (expr right)
      S.Holds value->S.Holds (expr value)
      S.Invoke name arguments->S.Invoke name (map expr arguments)
    law value=value{S.parameters=map pair (S.parameters value)
      ,S.requirements=map constraint (S.requirements value)
      ,S.lawResources=map pair (S.lawResources value)
      ,S.definition=definition (S.definition value)
      ,S.examples=[example{S.expectations=[expectation{S.actual=expr (S.actual expectation)}
          | expectation<-S.expectations example]} | example<-S.examples value]}
    step (S.Send value)=S.Send (ty value)
    step (S.Receive value)=S.Receive (ty value)
    generator value=case value of
      S.GenAny value->S.GenAny (ty <$> value)
      S.GenNamed name->S.GenNamed name
      S.GenOneOf values->S.GenOneOf (map expr values)
      S.GenFrequency values->S.GenFrequency [(weight,generator body) | (weight,body)<-values]
      S.GenSuchThat inner predicate limit->S.GenSuchThat (generator inner) (expr predicate) limit
      S.GenBind name value first rest->S.GenBind name (ty value) (generator first) (generator rest)
    setting value=case value of
      S.WitnessSetting path body names->S.WitnessSetting path (expr body) [(name,expr value) | (name,value)<-names]
      S.CoverSetting percent label body->S.CoverSetting percent label (expr body)
      S.ClassifySetting body label->S.ClassifySetting (expr body) label
      S.LabelSetting body->S.LabelSetting (expr body)
      S.TargetMaximize body->S.TargetMaximize (expr body)
      other->other
    item value=case value of
      S.HarnessStrategy strategy->S.HarnessStrategy strategy{S.strategyType=ty (S.strategyType strategy),S.strategyBody=generator (S.strategyBody strategy)}
      S.HarnessDefault value range->S.HarnessDefault (setting value) range
      S.HarnessFor names values range->S.HarnessFor names [(setting value,span) | (value,span)<-values] range
      S.HarnessBenchmark name body range->S.HarnessBenchmark name (expr body) range
      other->other
    input value=value{S.inputType=ty (S.inputType value),S.inputRefinements=map expr (S.inputRefinements value)}
    plan value=value{S.planDraws=[(identity,name,ty value,generator body) | (identity,name,value,body)<-S.planDraws value]
      ,S.planResolvedWitnesses=[witness{S.witnessInput=input (S.witnessInput witness)
          ,S.witnessScope=map input (S.witnessScope witness),S.witnessExpression=expr (S.witnessExpression witness)} | witness<-S.planResolvedWitnesses value]
      ,S.planCover=[(percent,label,expr body) | (percent,label,body)<-S.planCover value]
      ,S.planClassify=[(expr body,label) | (body,label)<-S.planClassify value]
      ,S.planLabels=map expr (S.planLabels value),S.planTarget=expr <$> S.planTarget value
      ,S.planWitnesses=[(path,expr body,[(name,expr value) | (name,value)<-names],range) | (path,body,names,range)<-S.planWitnesses value]}
