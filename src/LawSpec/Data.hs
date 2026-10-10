-- | Source data declarations are resolved once, before core validation. Target
-- emitters only see qualified identities and specialized core field types.
module LawSpec.Data (elaborateDataDeclarations, elaborateDataDeclarationsWithProfile, qualifyDataNames, inlineFieldDefinitions) where

import Control.Monad (forM, unless)
import Data.List (nub)
import LawSpec.Elaboration (elaborateResolvedWithData)
import LawSpec.Capabilities (satisfiedWithData)
import LawSpec.Core.Total (constructorProofContracts)
import qualified Data.Map.Strict as M
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Scalar (primitive)
import LawSpec.IndexTerm (FamilyIndex(..))

-- | The 64-bit profile unless a caller states another.
-- ref:DEC-explicit-machine-profile
elaborateDataDeclarations :: [S.Unit] -> Either [Diagnostic] [C.DataDeclaration]
elaborateDataDeclarations = elaborateDataDeclarationsWithProfile 64

-- | Data declarations are resolved once, to qualified identities, so emitters
-- never resolve a type name again. ref:DEC-typed-core-boundary
elaborateDataDeclarationsWithProfile :: Int -> [S.Unit] -> Either [Diagnostic] [C.DataDeclaration]
elaborateDataDeclarationsWithProfile bits units = do
  shapes <- concat <$> mapM unit units
  declarations <- forM (zip [(u,d) | u <- units, d <- S.dataTypes u] shapes) $ \((u,source),shape) ->
    contextual (S.dataTypeSpan source) $ do
      let typeVariables = M.fromList (zip (S.dataTypeParameters source) (map C.idText (C.dataParameters shape)))
          substitute = S.mapType (\ty -> case ty of
            S.Variable name -> S.Variable (M.findWithDefault name name typeVariables)
            other -> other) (S.mapExprTypes substitute)
      constructors <- forM (zip (S.dataTypeConstructors source) (C.dataConstructors shape)) $ \(original,constructor) -> do
        let fields = [(name,substitute ty) | (name,ty) <- S.dataConstructorFields original]
            identities = zip (map fst fields) (map C.binderId (C.constructorFields constructor))
            resolve name = M.findWithDefault (C.Id (S.unitName u ++ "::" ++ name)) name (M.fromList identities)
        predicates <- fmap concat $ forM (zip [1..] fields) $ \(count,(name,ty)) -> do
          unless (all (satisfiedWithData shapes bits []) (S.typeConstraints ty))
            (Left ("unsatisfied constructor field capability: " ++ name))
          let scope = [(n,S.baseType t) | (n,t) <- take count fields]
          mapM (elaborateResolvedWithData shapes [] bits (C.constructorId constructor) resolve scope)
            (S.typePredicates (S.Var name) ty)
        pure constructor{C.constructorPredicates=predicates}
      pure shape{C.dataConstructors=constructors}
  _ <- constructorProofContracts bits declarations
  pure declarations
  where
    unit u = mapM (declaration u) (S.dataTypes u)
    declaration u d = contextual (S.dataTypeSpan d) $ do
      let name = S.dataTypeName d
          identity = typeIdentity u name
          parameter n = C.Id (C.idText identity ++ "::" ++ n)
          parameters = M.fromList [(n, parameter n) | n <- S.dataTypeParameters d]
          localTypes = M.fromList [(S.dataTypeName t, typeIdentity u (S.dataTypeName t)) | t <- S.dataTypes u]
          typeName n = maybe n C.idText (M.lookup n localTypes)
          coreWith variables t = case S.baseType t of
            S.Named n -> Right (C.Constructor (typeName n) [])
            S.Variable n -> Right (C.TypeVariable (M.findWithDefault (parameter ("unbound::" ++ n)) n variables))
            S.Applied n a -> C.Constructor (typeName n) . pure . C.TypeArgument <$> coreWith variables a
            S.Application n as -> C.Constructor (typeName n) <$> mapM (fmap C.TypeArgument . coreWith variables) as
            S.Arrow a b -> C.Arrow <$> coreWith variables a <*> coreWith variables b
            S.Qualified [] a -> coreWith variables a
            _ -> Left "unresolved constructor field type"
          sourceVariables t = case S.baseType t of
            S.Variable n -> [n]
            S.Applied _ a -> sourceVariables a
            S.Application _ as -> concatMap sourceVariables as
            S.Arrow a b -> sourceVariables a ++ sourceVariables b
            S.Qualified _ a -> sourceVariables a
            _ -> []
      unless (primitive name == Nothing && name `notElem` ["Type", "Nullable", "Optional", "List", "Maybe", "Either"])
        (Left ("reserved data type name: " ++ name))
      unless (name `notElem` map S.refinementName (S.refinements u))
        (Left ("data type and refinement share a name: " ++ name))
      constructors <- forM (S.dataTypeConstructors d) $ \constructor -> do
        let tag = C.Id (C.idText identity ++ "::" ++ S.dataConstructorName constructor)
            -- Type variables that are not parameters belong to the constructor.
            existentials = nub [v | (_, ty) <- S.dataConstructorFields constructor ++ S.dataConstructorEquations constructor
                                  , v <- sourceVariables ty, v `notElem` S.dataTypeParameters d]
            existential v = C.Id (C.idText tag ++ "::exists::" ++ v)
            variables = M.union parameters (M.fromList [(v, existential v) | v <- existentials])
        fields <- forM (S.dataConstructorFields constructor) $ \(field, ty) ->
          C.Binder (C.Id (C.idText tag ++ "::" ++ field)) field <$> coreWith variables ty
        equations <- forM (S.dataConstructorEquations constructor) $ \(refined, ty) -> do
          identity' <- maybe (Left (S.dataConstructorName constructor ++ ": " ++ refined ++ " is not a type parameter of " ++ name))
            Right (M.lookup refined parameters)
          (,) identity' <$> coreWith variables ty
        pure (C.DataConstructor tag (S.dataConstructorName constructor) fields [] (C.SourceSpan (S.dataConstructorSpan constructor))
          equations (map existential existentials))
      -- Index tables are keyed by source constructor name until here.
      let index = fmap (\i -> i { familyIndexConstructors =
            [(C.idText identity ++ "::" ++ tag, c) | (tag, c) <- familyIndexConstructors i] }) (S.dataTypeIndex d)
      pure (C.MkDataDeclaration identity name (map parameter (S.dataTypeParameters d)) constructors (C.SourceSpan (S.dataTypeSpan d)) index
        (name `elem` S.handles u) Nothing)
    typeIdentity u name = C.Id (S.unitName u ++ "::type::" ++ name)
    contextual range = either (Left . pure . (\message -> Diagnostic "data-type" message (Just (spanStart range)))) Right

-- | Resolve local type and constructor names before generic law expansion. The
-- qualified identities survive imported/reused law bodies without re-resolution.
qualifyDataNames :: S.Unit -> S.Unit
qualifyDataNames unit = unit
  { S.dataTypes = [d{S.dataTypeConstructors=
      [c{S.dataConstructorFields=map pair (S.dataConstructorFields c)} | c <- S.dataTypeConstructors d]}
      | d <- S.dataTypes unit]
  , S.functions = map pair (S.functions unit)
  , S.functionDefinitions = [d
      {S.functionArguments = map pair (S.functionArguments d)
      , S.functionResult = ty (S.functionResult d)
      , S.functionRequirements = map constraint (S.functionRequirements d)
      , S.functionBody = expr (S.functionBody d)} | d <- S.functionDefinitions unit]
  , S.laws = map law (S.laws unit)
  -- Protocol steps and mailboxes name data types too.
  , S.protocols = [p {S.protocolSteps = map step (S.protocolSteps p)} | p <- S.protocols unit]
  , S.mailboxes = [(n, ty t, at) | (n, t, at) <- S.mailboxes unit]
  -- So do ability instances, handler states and operation types.
  , S.abilities = [a {S.abilityOperations = map pair (S.abilityOperations a), S.abilityLaws = map law (S.abilityLaws a)
                     , S.abilityFailures = map pair (S.abilityFailures a), S.abilityResource = ty <$> S.abilityResource a} | a <- S.abilities unit]
  , S.handlerDeclarations = [h {S.handlerAbility = ty (S.handlerAbility h), S.handlerAlso = map ty (S.handlerAlso h),
      S.handlerState = (\(n, t, e) -> (n, ty t, expr e)) <$> S.handlerState h} | h <- S.handlerDeclarations unit]
  , S.declaredUses = [(n, map ty ts) | (n, ts) <- S.declaredUses unit]
  , S.abilityRows = [(n, map ty ts) | (n, ts) <- S.abilityRows unit]
  , S.lawAssignments = [(n, [(ty t, c) | (t, c) <- a]) | (n, a) <- S.lawAssignments unit]
  , S.resourceDeclarations = [r {S.resourceType = ty (S.resourceType r), S.resourceAcquire = expr (S.resourceAcquire r),
      S.resourceRelease = fmap expr (S.resourceRelease r), S.resourceReset = fmap (fmap expr) (S.resourceReset r)}
      | r <- S.resourceDeclarations unit]
  -- A harness's strategies and expressions name data types and constructors.
  , S.lawHarness = [(n, harnessPlan plan) | (n, plan) <- S.lawHarness unit]
  , S.unitHarness = (\h -> h {S.harnessItems = map harnessItem (S.harnessItems h)}) <$> S.unitHarness unit
  , S.contracts = [c {S.contractArguments = map pair (S.contractArguments c),
      S.contractResult = pair (S.contractResult c),
      S.contractPreconditions = map expr (S.contractPreconditions c),
      S.contractPostconditions = map expr (S.contractPostconditions c)} | c <- S.contracts unit]
  }
  where
    types = [(S.dataTypeName d, S.unitName unit ++ "::type::" ++ S.dataTypeName d) | d <- S.dataTypes unit]
    constructors = [(S.dataConstructorName c, qualified ++ "::" ++ S.dataConstructorName c)
      | d <- S.dataTypes unit, Just qualified <- [lookup (S.dataTypeName d) types], c <- S.dataTypeConstructors d]
    qualify table name = maybe name id (lookup name table)
    ty = S.mapType change expr
    change (S.Named name) = S.Named (qualify types name)
    change (S.Applied name a) = S.Applied (qualify types name) a
    change (S.Application name args) = S.Application (qualify types name) args
    change t = t
    pair (name,t) = (name,ty t)
    step (S.Send t) = S.Send (ty t)
    step (S.Receive t) = S.Receive (ty t)
    constraint (S.Capability name t) = S.Capability name (ty t)
    expr e = case e of
      S.Located range value -> S.Located range (expr value)
      S.ConstructLit name fields -> S.ConstructLit (qualify constructors name) (map expr fields)
      S.AllPayloadsExpr value predicates -> S.AllPayloadsExpr (expr value) [(binder,expr body) | (binder,body) <- predicates]
      S.AllElementsExpr value binder predicate -> S.AllElementsExpr (expr value) binder (expr predicate)
      S.MatchExpr value branches -> S.MatchExpr (expr value)
        [S.MatchBranch (qualify constructors tag) names (expr body) | S.MatchBranch tag names body <- branches]
      S.ListLit xs -> S.ListLit (map expr xs)
      S.Apply a b -> S.Apply (expr a) (expr b)
      S.Compose a b -> S.Compose (expr a) (expr b)
      S.Binary op a b -> S.Binary op (expr a) (expr b)
      S.Unary op a -> S.Unary op (expr a)
      S.Annotate a t -> S.Annotate (expr a) (ty t)
      S.TypeBound bound t -> S.TypeBound bound (ty t)
      _ -> e
    harnessPlan plan = plan
      { S.planCover = [(p, label, expr e) | (p, label, e) <- S.planCover plan]
      , S.planClassify = [(expr e, label) | (e, label) <- S.planClassify plan]
      , S.planLabels = map expr (S.planLabels plan)
      , S.planTarget = expr <$> S.planTarget plan
      , S.planDraws = [(i, n, ty t, gen g) | (i, n, t, g) <- S.planDraws plan] }
    gen g = case g of
      S.GenAny t -> S.GenAny (ty <$> t)
      S.GenNamed n -> S.GenNamed n
      S.GenOneOf values -> S.GenOneOf (map expr values)
      S.GenFrequency alternatives -> S.GenFrequency [(w, gen a) | (w, a) <- alternatives]
      S.GenSuchThat inner p n -> S.GenSuchThat (gen inner) (expr p) n
      S.GenBind x t from body -> S.GenBind x (ty t) (gen from) (gen body)
    harnessItem item = case item of
      S.HarnessBenchmark n e range -> S.HarnessBenchmark n (expr e) range
      S.HarnessStrategy st -> S.HarnessStrategy st { S.strategyType = ty (S.strategyType st), S.strategyBody = gen (S.strategyBody st) }
      other -> other
    literal (S.ConstructorLiteral tag fields) = S.ConstructorLiteral (qualify constructors tag) (map literal fields)
    literal (S.ListLiteral xs) = S.ListLiteral (map literal xs)
    literal other = other
    definition d = case d of
      S.Forall binders body -> S.Forall (map pair binders) (definition body)
      S.Equal a b -> S.Equal (expr a) (expr b)
      S.Holds value -> S.Holds (expr value)
      S.Implies guard body -> S.Implies (expr guard) (definition body)
      S.And a b -> S.And (definition a) (definition b)
      S.Invoke name args -> S.Invoke name (map expr args)
    law l = l {S.parameters = map pair (S.parameters l), S.requirements = map constraint (S.requirements l),
      S.lawResources = map pair (S.lawResources l),
      S.definition = definition (S.definition l), S.examples =
        [e {S.bindings = [(name,literal value) | (name,value) <- S.bindings e],
            S.expectations = [S.Expectation (expr (S.actual x)) (literal (S.expected x)) | x <- S.expectations e]}
          | e <- S.examples l]}

-- | A field's refinement may call the unit's checked definitions
-- (`label :: (v :: Text where validName v)`). A data type's predicates are
-- checked wherever a value is built, on every target and in the runtime's
-- schemas, with no definitions in scope, so each call is unfolded into the
-- definition's body: its arguments bound first, in order, by let. Recursive
-- definitions are not unfolded, and stay an error.
inlineFieldDefinitions :: S.Unit -> S.Unit
inlineFieldDefinitions u = u { S.dataTypes = map declaration (S.dataTypes u) }
  where
    definitions = M.fromList [(S.functionName d, d) | d <- S.functionDefinitions u]
    declaration d = d { S.dataTypeConstructors = [c { S.dataConstructorFields = [(n, fieldType t) | (n, t) <- S.dataConstructorFields c] } | c <- S.dataTypeConstructors d] }
    fieldType = S.mapType id (unfold (0 :: Int) [])
    unfold depth active e = case e of
      _ | depth > 16 -> e
      S.Located r a -> S.Located r (unfold depth active a)
      S.Apply _ _ | (S.Var f, args) <- spine e [], Just d <- M.lookup f definitions
                  , f `notElem` active, length args == length (S.functionArguments d) ->
          let parameters = [("lawspecInline" ++ show depth ++ "_" ++ p, p) | (p, _) <- S.functionArguments d]
              body = unfold (depth + 1) (f : active) (rename (M.fromList [(p, fresh) | (fresh, p) <- parameters]) (S.functionBody d))
          in foldr (\((fresh, _), a) rest -> S.MatchExpr (unfold depth active a) [S.MatchBranch S.letTag [fresh] rest]) body (zip parameters args)
      S.Var f | Just d <- M.lookup f definitions, null (S.functionArguments d), f `notElem` active ->
          unfold (depth + 1) (f : active) (S.functionBody d)
      S.Apply a b -> S.Apply (unfold depth active a) (unfold depth active b)
      S.Compose a b -> S.Compose (unfold depth active a) (unfold depth active b)
      S.ListLit xs -> S.ListLit (map (unfold depth active) xs)
      S.ConstructLit n xs -> S.ConstructLit n (map (unfold depth active) xs)
      S.MatchExpr v bs -> S.MatchExpr (unfold depth active v) [S.MatchBranch t ns (unfold depth active b) | S.MatchBranch t ns b <- bs]
      S.AllElementsExpr v n p -> S.AllElementsExpr (unfold depth active v) n (unfold depth active p)
      S.AllPayloadsExpr v ps -> S.AllPayloadsExpr (unfold depth active v) [(n, unfold depth active b) | (n, b) <- ps]
      S.Binary op a b -> S.Binary op (unfold depth active a) (unfold depth active b)
      S.Unary op a -> S.Unary op (unfold depth active a)
      S.Annotate a t -> S.Annotate (unfold depth active a) t
      other -> other
    spine e args = case e of
      S.Apply f x -> spine f (x : args)
      S.Located _ inner -> spine inner args
      other -> (other, args)
    -- The definition's parameters, renamed apart; a binder that shadows one
    -- hides it in its body.
    rename table e = case e of
      S.Var n | Just m <- M.lookup n table -> S.Var m
      S.Located r a -> S.Located r (rename table a)
      S.Apply a b -> S.Apply (rename table a) (rename table b)
      S.Compose a b -> S.Compose (rename table a) (rename table b)
      S.ListLit xs -> S.ListLit (map (rename table) xs)
      S.ConstructLit n xs -> S.ConstructLit n (map (rename table) xs)
      S.MatchExpr v bs -> S.MatchExpr (rename table v) [S.MatchBranch t ns (rename (foldr M.delete table ns) b) | S.MatchBranch t ns b <- bs]
      S.AllElementsExpr v n p -> S.AllElementsExpr (rename table v) n (rename (M.delete n table) p)
      S.AllPayloadsExpr v ps -> S.AllPayloadsExpr (rename table v) [(n, rename (M.delete n table) b) | (n, b) <- ps]
      S.Binary op a b -> S.Binary op (rename table a) (rename table b)
      S.Unary op a -> S.Unary op (rename table a)
      S.Annotate a t -> S.Annotate (rename table a) t
      other -> other
