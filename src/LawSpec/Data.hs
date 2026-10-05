-- Source data declarations are resolved once, before core validation. Target
-- emitters only see qualified identities and specialized core field types.
module LawSpec.Data (elaborateDataDeclarations, elaborateDataDeclarationsWithProfile, qualifyDataNames) where

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

elaborateDataDeclarations :: [S.Unit] -> Either [Diagnostic] [C.DataDeclaration]
elaborateDataDeclarations = elaborateDataDeclarationsWithProfile 64

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

-- Resolve local type and constructor names before generic law expansion. The
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
  , S.abilities = [a {S.abilityOperations = map pair (S.abilityOperations a), S.abilityLaws = map law (S.abilityLaws a)} | a <- S.abilities unit]
  , S.handlerDeclarations = [h {S.handlerAbility = ty (S.handlerAbility h),
      S.handlerState = (\(n, t, e) -> (n, ty t, expr e)) <$> S.handlerState h} | h <- S.handlerDeclarations unit]
  , S.declaredUses = [(n, map ty ts) | (n, ts) <- S.declaredUses unit]
  , S.abilityRows = [(n, map ty ts) | (n, ts) <- S.abilityRows unit]
  , S.lawAssignments = [(n, [(ty t, c) | (t, c) <- a]) | (n, a) <- S.lawAssignments unit]
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
      S.definition = definition (S.definition l), S.examples =
        [e {S.bindings = [(name,literal value) | (name,value) <- S.bindings e],
            S.expectations = [S.Expectation (expr (S.actual x)) (literal (S.expected x)) | x <- S.expectations e]}
          | e <- S.examples l]}
