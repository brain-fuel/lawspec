-- Source data declarations are resolved once, before core validation. Target
-- emitters only see qualified identities and specialized core field types.
module LawSpec.Data (elaborateDataDeclarations, elaborateDataDeclarationsWithProfile, qualifyDataNames) where

import Control.Monad (forM, unless)
import LawSpec.Elaboration (elaborateResolvedWithData)
import LawSpec.Capabilities (satisfiedWithData)
import LawSpec.Core.Total (constructorProofContracts)
import qualified Data.Map.Strict as M
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Scalar (primitive)

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
          core t = case S.baseType t of
            S.Named n -> Right (C.Constructor (typeName n) [])
            S.Variable n -> Right (C.TypeVariable (M.findWithDefault (parameter ("unbound::" ++ n)) n parameters))
            S.Applied n a -> C.Constructor (typeName n) . pure . C.TypeArgument <$> core a
            S.Application n as -> C.Constructor (typeName n) <$> mapM (fmap C.TypeArgument . core) as
            S.Arrow a b -> C.Arrow <$> core a <*> core b
            S.Qualified [] a -> core a
            _ -> Left "unresolved constructor field type"
      unless (primitive name == Nothing && name `notElem` ["Type", "Nullable", "Optional", "List", "Maybe", "Either"])
        (Left ("reserved data type name: " ++ name))
      unless (name `notElem` map S.refinementName (S.refinements u))
        (Left ("data type and refinement share a name: " ++ name))
      constructors <- forM (S.dataTypeConstructors d) $ \constructor -> do
        let tag = C.Id (C.idText identity ++ "::" ++ S.dataConstructorName constructor)
        fields <- forM (S.dataConstructorFields constructor) $ \(field, ty) ->
          C.Binder (C.Id (C.idText tag ++ "::" ++ field)) field <$> core ty
        pure (C.DataConstructor tag (S.dataConstructorName constructor) fields [] (C.SourceSpan (S.dataConstructorSpan constructor)))
      pure (C.DataDeclaration identity name (map parameter (S.dataTypeParameters d)) constructors (C.SourceSpan (S.dataTypeSpan d)))
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
