-- | Collect source structural type occurrences before shared Core admission.
-- The declaration stream is distinct from the lookup catalogue; callers never
-- discard a differently ordered invariant by interning an equal identity.
-- ref:DEC-typed-core-boundary ref:DEC-total-definitions
module LawSpec.SourceRecords (recordDeclarations,recordDeclarationsWithContext,unitTypeReferences,typedTypeReferences) where

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
      S.Record _ -> True
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
