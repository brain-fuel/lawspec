-- | Lower typed surface expressions once. Law expansion and fixture checking
-- both use this bridge; no backend reinterprets surface syntax.
module LawSpec.Elaboration
  ( coreType, coreTypeWithRecords, equation, elaborateExpression, elaborateResolved, elaborateResolvedWithData, elaborateResolvedWithRecords, equationWithData, binaryOp, elaborateDefinitionUnit, elaborateDefinitionUnitWithRecords, elaborateContract, elaborateContractWithRecords
  , abilityReference, abilityReferenceWithRecords, unitOperations, unitOperationsWithRecords, performOperations
  , CollectRecords, collectRecords, collectType, collectExpression, collectEquation, collectAbilityReference ) where

import LawSpec.Abilities (clauseDefinitionName, abilityArguments, instantiatedOperations, unqualifiedHandler)
import Data.Maybe (listToMaybe)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import Control.Exception (evaluate)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.IO.Unsafe (unsafePerformIO)
import System.Mem.StableName (StableName, makeStableName)

import LawSpec.Time (timeUnit, durationType, instantType, durationArithmetic, durationValue)
import LawSpec.Imports (importedDefinitionName)
import LawSpec.Collections (collectionsUnit, internalConstructor, boundedArithmeticTypes, boundedArithmeticDefinition)
import qualified LawSpec.Model as S
import qualified LawSpec.Inference as S
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Machine as C
import LawSpec.Core.Validate (operationEvidenceWithRegistry)
import LawSpec.Core.Total (constructorProofContracts)
import LawSpec.CapabilityCheck (checkCapability)
import LawSpec.Core.Types (makeRegistry, builtinDataDeclarations)
import qualified LawSpec.Core.RecordIdentity as Records
import LawSpec.Core.Semantics (convertValue)
import LawSpec.Scalar
import LawSpec.Digest (digestHex, digestString)
import Data.List (stripPrefix, nub)
import Control.Monad (forM, unless)
import Control.Monad.State.Strict (StateT, runStateT, get, put, lift)

-- | Surface types become Core types by structure; only checked shapes reach
-- here, so failure is a compiler bug. ref:DEC-typed-core-boundary
coreType :: S.Type -> Either String C.Type
coreType t = case S.baseType t of
  S.Named n -> Right (C.scalarType n)
  S.Variable n -> Right (C.TypeVariable (C.Id n))
  S.Applied n a -> C.Constructor n . pure . C.TypeArgument <$> coreType a
  S.Application n as -> C.Constructor n <$> mapM (fmap C.TypeArgument . coreType) as
  S.Arrow a b -> C.Arrow <$> coreType a <*> coreType b
  _ -> Left "unelaborated type at core boundary"

-- | Structural products return their declarations along with their type.
-- Restrictions are typed in an explicit field context before descriptor
-- construction. Callers retain every occurrence until mandatory admission;
-- a shared identity must never erase a different restriction ordering.
coreTypeWithRecords :: [C.DataDeclaration] -> Int -> S.Type -> Either String (C.Type,[C.DataDeclaration])
coreTypeWithRecords dataTypes bits source = case S.baseType source of
  S.Record fields -> do
    let labels = map S.recordFieldLabel fields
        bindings = map S.recordFieldBinding fields
    unless (all (not . null) labels && length labels == length (nub labels))
      (Left "duplicate or empty record field label")
    unless (all (not . null) bindings && length bindings == length (nub bindings))
      (Left "duplicate or empty record field binding")
    lowered <- mapM (coreTypeWithRecords dataTypes bits . S.recordFieldType) fields
    let nested = concatMap snd lowered
        origin = C.GeneratedFrom (C.Id "lawspec::source-record")
        binders = [C.Binder (C.Id ("lawspec::source-record::field::" ++ S.recordFieldLabel field))
          (S.recordFieldLabel field) ty | (field,(ty,_)) <- zip fields lowered]
        identities = zip bindings (map C.binderId binders)
        resolve name = maybe (C.Id ("lawspec::source-record::unbound::" ++ name)) id (lookup name identities)
    known <- Records.internRecordDeclarations (dataTypes ++ nested)
    stored <- sequence [do
      let scope = [(S.recordFieldBinding f,rigid (S.baseType (S.recordFieldType f))) | f <- take count fields]
      unless (all (checkCapability (coreTypeWithRecords known bits) known bits [])
          (S.typeConstraints (S.recordFieldType field)))
        (Left ("unsatisfied record field capability: " ++ S.recordFieldLabel field))
      loweredPredicates <- mapM (elaborateResolvedWithRecords False known [] bits (C.Id "lawspec::source-record") resolve scope)
        (map (S.mapExprTypes rigid) (S.typePredicates (S.Var (S.recordFieldBinding field)) (S.recordFieldType field)))
      pure (Records.RecordField binder (map fst loweredPredicates),concatMap snd loweredPredicates)
      | (count,(field,binder)) <- zip [1..] (zip fields binders)]
    let recordFields = map fst stored
        predicateRecords = concatMap snd stored
    let parameters = nub (concat [typeVariables (C.binderType binder) ++
          concatMap expressionVariables predicates | Records.RecordField binder predicates <- recordFields])
    (declaration,arguments) <- Records.makeRecordDeclaration parameters recordFields origin
    pure (C.Constructor (C.idText (C.dataId declaration)) (map (C.TypeArgument . C.TypeVariable) arguments),nested ++ predicateRecords ++ [declaration])
  S.Arrow a b -> do
    (a',left) <- coreTypeWithRecords dataTypes bits a
    (b',right) <- coreTypeWithRecords (dataTypes ++ left) bits b
    pure (C.Arrow a' b',left ++ right)
  S.Applied name argument -> application name [argument]
  S.Application name arguments -> application name arguments
  S.Named ('@':parameter) -> pure (C.TypeVariable (C.Id parameter),[])
  ty -> do
    lowered <- coreType ty
    pure (lowered,[])
  where
    -- A declaration's enclosing parameters are fixed while checking its
    -- restrictions. Only a use site may instantiate them. Otherwise an
    -- annotation in a predicate could silently replace a parameter and drop
    -- its dependency from the structural descriptor.
    rigid = S.mapType (\ty -> case ty of
      S.Variable name -> S.Named ('@':name)
      other -> other) (S.mapExprTypes rigid)
    application name arguments = do
      lowered <- mapM (coreTypeWithRecords dataTypes bits) arguments
      pure (C.Constructor name (map (C.TypeArgument . fst) lowered),concatMap snd lowered)
    typeVariables ty = case ty of
      C.TypeVariable name -> [name]
      C.Constructor _ arguments -> concat [typeVariables t | C.TypeArgument t <- arguments]
      C.Arrow a b -> typeVariables a ++ typeVariables b
    expressionVariables value = typeVariables (C.expressionType value) ++
      concatMap expressionVariables (C.children value) ++ case C.expressionNode value of
        C.Let binder _ _ -> typeVariables (C.binderType binder)
        C.Match _ cases -> concat [concatMap (typeVariables . C.binderType) (C.caseBinders entry) | entry <- cases]
        _ -> []

-- | Equality's contextual typing belongs to elaboration, including the expected
-- result in an example. It is performed exactly once for every backend.
equation :: [C.Id] -> Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> S.Expr -> Either String C.Proposition
equation = equationWithData []

-- | Both sides of an equation are typed in one context, so a literal on one side
-- takes the other side's type.
equationWithData :: [C.DataDeclaration] -> [C.Id] -> Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> S.Expr -> Either String C.Proposition
equationWithData dataTypes declarations bits origin resolve env left right = do
  collected <- collectRecords dataTypes
    (collectEquation declarations bits origin resolve env left right)
  requireRegisteredRecords dataTypes bits collected

collectEquation :: [C.Id] -> Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> S.Expr -> CollectRecords C.Proposition
collectEquation declarations bits origin resolve env left right = do
  RecordCollection dataTypes _ <- get
  (a,b) <- lift (S.contextualizeStructuralWithData dataTypes bits env left right)
  ta <- lift (S.typedExpressionWithData dataTypes bits env (S.normal a))
  tb <- lift (S.typedExpressionWithData dataTypes bits env (S.normal b))
  let contextual e = case S.unlocated e of
        S.ConstructLit _ _ -> True
        S.ListLit _ -> True
        S.RecordLit _ -> True
        S.Number _ -> True
        S.DecimalNumber _ _ -> True
        S.ScalarLit s -> scalarName s `elem` ["Null","Undefined","Nullable","Optional"]
        _ -> False
      -- A side whose type is still open, such as a select or match whose
      -- branches leave an error type undetermined, takes the other side's.
      open t = case t of
        S.Variable _ -> True
        S.Applied _ inner -> open inner
        S.Application _ ts -> any open ts
        S.Arrow x y -> open x || open y
        S.Record fields -> any (open . S.recordFieldType) fields
        S.Refined _ inner _ -> open inner
        _ -> False
      ta' = S.expressionType ta
      tb' = S.expressionType tb
      (a',b') | contextual a || (open ta' && not (open tb')) = (S.Annotate a tb',b)
              | contextual b || (open tb' && not (open ta')) = (a,S.Annotate b ta')
              | otherwise = (a,b)
  let declared = (`Set.member` Set.fromList declarations)
  x <- collectExpression False declared bits origin resolve (S.monoEnvironment env) a'
  y <- collectExpression False declared bits origin resolve (S.monoEnvironment env) b'
  RecordCollection known _ <- get
  registry <- lift (makeRegistry known)
  ev <- lift (operationEvidenceWithRegistry registry C.Equal (C.expressionType x) (C.expressionType y))
  pure (C.Equation ev x y)

-- | The default for an expression that calls no declaration.
elaborateExpression :: Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> Either String C.Expr
elaborateExpression = elaborateResolved []

-- | The default for an expression over built-in types only.
elaborateResolved :: [C.Id] -> Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> Either String C.Expr
elaborateResolved = elaborateResolvedWithData []

-- | Each surface expression is lowered once, with its resolved names and
-- arithmetic evidence, so no later stage resolves or infers again.
-- ref:DEC-elaborate-before-core
elaborateResolvedWithData :: [C.DataDeclaration] -> [C.Id] -> Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> Either String C.Expr
elaborateResolvedWithData dataTypes declarations bits origin resolve env =
  elaborateResolvedIn False dataTypes (`Set.member` Set.fromList declarations) bits origin resolve (S.monoEnvironment env)

-- | The explicit collector for expressions that introduce anonymous products.
-- Its result uses ordinary typed Core; whole-program admission remains the
-- caller's responsibility, exactly as for existing source data declarations.
-- Keep field nodes while auditing a definition; lower them for a law term,
-- just as the existing definition and proposition elaborators do.
elaborateResolvedWithRecords :: Bool -> [C.DataDeclaration] -> [C.Id] -> Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> Either String (C.Expr,[C.DataDeclaration])
elaborateResolvedWithRecords projections dataTypes declarations bits origin resolve env =
  elaborateResolvedRecordsIn projections dataTypes (`Set.member` Set.fromList declarations) bits origin resolve (S.monoEnvironment env)

-- | As elaborateResolvedWithData, with the declarations as a membership test
-- and the environment already made: a unit elaborates thousands of
-- definitions against the same ones.
-- With projections, a field access and a record update stay Core's Project
-- and Update (a definition's body, which checking reads directly); without,
-- they are the matches they stand for (a law's terms).
elaborateResolvedIn :: Bool -> [C.DataDeclaration] -> (C.Id -> Bool) -> Int -> C.Id -> (String -> C.Id) -> S.Env -> S.Expr -> Either String C.Expr
elaborateResolvedIn projections dataTypes declared bits origin resolve env source = do
  collected <- elaborateResolvedRecordsIn projections dataTypes declared bits origin resolve env source
  requireRegisteredRecords dataTypes bits collected

-- Discarding occurrences is permitted only when the caller already owns the
-- declarations, and only after checking every occurrence's predicate order.
requireRegisteredRecords :: [C.DataDeclaration] -> Int -> (a,[C.DataDeclaration]) -> Either String a
requireRegisteredRecords dataTypes bits (value,records) = do
  unless (all (\record -> C.dataId record `elem` map C.dataId dataTypes) records)
    (Left "structural record declarations require an explicit elaboration collector")
  -- A caller may already hold the same descriptor from another occurrence.
  -- Before discarding duplicate declarations, audit their actual predicate
  -- order as well: equal type identities do not imply equal definedness.
  unless (null records) $ either (Left . unlines . map S.message) (const (pure ()))
    (constructorProofContracts bits (dataTypes ++ records))
  pure value

-- The lookup catalogue may share descriptors while the admission stream must
-- retain every source occurrence. No global mutable registry participates in
-- collection. Empty additions keep the catalogue's identity and its caches.
data RecordCollection = RecordCollection [C.DataDeclaration] [[C.DataDeclaration]]
type CollectRecords = StateT RecordCollection (Either String)

collectRecords :: [C.DataDeclaration] -> CollectRecords a -> Either String (a,[C.DataDeclaration])
collectRecords declarations action = do
  (value,RecordCollection _ occurrences) <- runStateT action (RecordCollection declarations [])
  pure (value,concat (reverse occurrences))

collectLowered :: ([C.DataDeclaration] -> Either String (a,[C.DataDeclaration])) -> CollectRecords a
collectLowered lower = do
  RecordCollection known occurrences <- get
  (value,records) <- lift (lower known)
  unless (null records) $ do
    catalog <- lift (Records.internRecordDeclarations (known ++ records))
    put (RecordCollection catalog (records:occurrences))
  pure value

collectType :: Int -> S.Type -> CollectRecords C.Type
collectType bits ty = collectLowered (\known -> coreTypeWithRecords known bits ty)

collectExpression :: Bool -> (C.Id -> Bool) -> Int -> C.Id -> (String -> C.Id) -> S.Env -> S.Expr -> CollectRecords C.Expr
collectExpression projections declared bits origin resolve env source =
  collectLowered (\known -> elaborateResolvedRecordsIn projections known declared bits origin resolve env source)

elaborateResolvedRecordsIn :: Bool -> [C.DataDeclaration] -> (C.Id -> Bool) -> Int -> C.Id -> (String -> C.Id) -> S.Env -> S.Expr -> Either String (C.Expr,[C.DataDeclaration])
elaborateResolvedRecordsIn projections dataTypes declared bits origin resolve env source = do
  (typed,_) <- S.typedExpressionWithSchemes dataTypes bits env (S.normal source)
  records <- concatMap snd <$> mapM (coreTypeWithRecords dataTypes bits) (filter containsRecord (types typed))
  known <- if null records then pure dataTypes else Records.internRecordDeclarations (dataTypes ++ records)
  value <- lowerResolvedTree projections known declared bits origin resolve typed
  pure (value,records)
  where
    types tree = S.expressionType tree : maybe [] pure (S.requiredConversion tree) ++
      concatMap types (S.operands tree) ++ concat [map snd fields ++ types body | S.TypedCase _ fields body <- S.typedCases tree]
    containsRecord ty = case S.baseType ty of
      S.Record _ -> True
      S.Arrow a b -> containsRecord a || containsRecord b
      S.Applied _ t -> containsRecord t
      S.Application _ ts -> any containsRecord ts
      _ -> False

lowerResolvedTree :: Bool -> [C.DataDeclaration] -> (C.Id -> Bool) -> Int -> C.Id -> (String -> C.Id) -> S.TypedExpr -> Either String C.Expr
lowerResolvedTree projections dataTypes declared bits origin resolve typed = finish <$> lowerWith [] typed where
  coreType ty = fst <$> coreTypeWithRecords dataTypes bits ty
  finish e = if projections then e else C.lowerFieldNodes (builtinDataDeclarations ++ dataTypes) (C.idText origin) e
  -- The constructor and position of a field of a value of this type.
  -- The program's index of types by name (built once, LawSpec.Inference).
  fieldOf ty field = case ty of
    C.Constructor parent _ | Just [d] <- M.lookup parent (fst (S.dataIndex dataTypes))
                           , [c] <- C.dataConstructors d
                           , (index, _) : _ <- [x | x@(_, b) <- zip [0 ..] (C.constructorFields c), C.binderName b == field] ->
      Right (C.constructorId c, index)
    _ -> Left ("." ++ field ++ ": not a field of " ++ show ty)
  operationEvidence op a b = makeRegistry dataTypes >>= \registry -> operationEvidenceWithRegistry registry op a b
  constructorTag parent name = do
    let qualified = C.Id (parent ++ "::" ++ name)
        explicit = C.Id name
    -- Qualified constructor references are resolved before specialization.
    pure (if any (\d -> any ((== explicit) . C.constructorId) (C.dataConstructors d)) (builtinDataDeclarations ++ dataTypes) then explicit else qualified)
  generated = C.GeneratedFrom origin
  node t n = C.Expr t n generated
  lowerWith bound old@(S.TypedExpr ty expression operands conversion cases) = do
    let lower = lowerWith bound
        resolveName n = maybe (resolve n) id (lookup n bound)
    t <- coreType ty
    e <- case expression of
      S.Located range sourceExpr -> do
        result <- lower old{S.expression=sourceExpr,S.requiredConversion=Nothing}
        pure result{C.expressionOrigin=C.SourceSpan range}
      S.Number n -> constant t (SInteger "Integer" n)
      S.DecimalNumber c ex -> constant t (SDecimal c ex)
      S.BoolLit b -> constant t (SBool b)
      S.StringLit text -> constant t (textScalar text)
      S.ScalarLit s -> constant t s
      S.ConstructLit name _ -> case t of
        C.Constructor parent _ -> do
          tag <- constructorTag parent name
          node t . C.Construct tag <$> mapM lower operands
        _ -> Left "constructor expression requires a data type"
      S.RecordLit fields -> case t of
        C.Constructor parent arguments -> do
          declaration <- case [d | d <- dataTypes,C.idText (C.dataId d) == parent,C.dataStructural d /= Nothing] of
            [d] -> Right d
            _ -> Left "record literal requires a collected structural declaration"
          parameters <- mapM (\argument -> case argument of
            C.TypeArgument ty -> Right ty
            _ -> Left "record literal has an unresolved dependent type argument") arguments
          values <- mapM lower operands
          let identity = C.Id (C.idText origin ++ "::record::" ++ digestHex (digestString (show expression)))
          Records.constructRecord identity declaration parameters (zip (map fst fields) values) generated
        _ -> Left "record literal requires a structural record type"
      S.AllPayloadsExpr _ _ -> case operands of
        [value] -> do
          scrutinee <- lower value
          predicates <- sequence [case entry of
            S.TypedCase _ [(name,fieldType)] predicate -> do
              binder <- C.Binder (C.Id (C.idText origin ++ "::payload::" ++ show (length bound) ++ "::" ++ show index ++ "::" ++ name)) name <$> coreType fieldType
              body <- lowerWith ((name,C.binderId binder):bound) predicate
              pure (binder,body)
            _ -> Left "invalid typed payload callback"
            | (index,entry) <- zip [0::Int ..] cases]
          pure (node t (C.AllPayloads scrutinee predicates))
        _ -> Left "invalid typed payload predicate"
      S.AllElementsExpr _ _ _ -> case (operands,cases) of
        ([value],[S.TypedCase _ [(name,fieldType)] predicate]) -> do
          scrutinee <- lower value
          binder <- C.Binder (C.Id (C.idText origin ++ "::match::" ++ show (length bound) ++ "::element::" ++ name)) name <$> coreType fieldType
          body <- lowerWith ((name,C.binderId binder):bound) predicate
          pure (node t (C.AllElements scrutinee binder body))
        _ -> Left "invalid typed List predicate"
      -- let x = e in body.
      S.MatchExpr _ [S.MatchBranch tag _ _] | tag == S.letTag, [value] <- operands, [S.TypedCase _ [(name, fieldType)] body] <- cases -> do
        valueCore <- lower value
        binder <- C.Binder (C.Id (C.idText origin ++ "::let::" ++ show (length bound) ++ "::" ++ name)) name <$> coreType fieldType
        inner <- lowerWith ((name, C.binderId binder) : bound) body
        pure (node t (C.Let binder valueCore inner))
      S.MatchExpr _ _ -> case operands of
        [value] -> do
          scrutinee <- lower value
          parent <- case C.expressionType scrutinee of
            C.Constructor name _ -> Right name
            _ -> Left "match requires a data type"
          branches <- sequence [do
            binders <- sequence [C.Binder (C.Id (C.idText origin ++ "::match::" ++ show (length bound) ++ "::" ++ show index ++ "::" ++ name)) name <$> coreType fieldType
              | (name, fieldType) <- fields]
            body' <- lowerWith ([(C.binderName b, C.binderId b) | b <- binders] ++ bound) body
            tagId <- constructorTag parent tag
            pure (C.MatchCase tagId binders body')
            | (index, S.TypedCase tag fields body) <- zip [0::Int ..] cases]
          pure (node t (C.Match scrutinee branches))
        _ -> Left "invalid typed match"
      S.ListLit _ -> do
        values <- mapM lower operands
        pure (foldr (\value rest -> node t (C.Construct (C.Id "List::Cons") [value,rest]))
          (node t (C.Construct (C.Id "List::Nil") [])) values)
      S.Var n -> pure (node t (if lookup n bound == Nothing && declared (resolve n) then C.ExternalCall (resolve n) [] else C.Local (resolveName n)))
      S.Annotate _ _ -> case operands of
        [a] -> lower a
        _ -> Left "invalid typed annotation"
      S.Binary op _ _ -> case operands of
        [a,b] -> do
          x <- lower a; y <- lower b
          case op of
            "&&" -> pure (node t (C.ShortCircuit C.And x y))
            "||" -> pure (node t (C.ShortCircuit C.Or x y))
            _ | op `notElem` ["==","!="], any isInstant [x,y] -> instantBinary t op x y
            _ | op `notElem` ["==","!="], any isDuration [x,y] -> durationBinary t op x y
            _ -> do
              operator <- binaryOp op
              evidence <- operationEvidence operator (C.expressionType x) (C.expressionType y)
              pure (node t (C.Binary operator evidence x y))
        _ -> Left "invalid typed binary operation"
      S.Unary op _ -> case operands of
        [a] -> do
          operator <- case op of "-" -> Right C.Negate; "!" -> Right C.Not; _ -> Left "unknown unary operation"
          node t . C.Unary operator <$> lower a
        _ -> Left "invalid typed unary operation"
      -- b.f and b with f = v (LawSpec.Inference keeps them as field nodes).
      S.Apply (S.Var n) _ | Just field <- stripPrefix S.fieldAccessPrefix n, [value] <- operands -> do
        subject <- lower value
        (tag, index) <- fieldOf (C.expressionType subject) field
        pure (node t (C.Project tag index subject))
      S.Apply (S.Apply (S.Var n) _) _ | Just field <- stripPrefix S.fieldUpdatePrefix n, [value, replacement] <- operands -> do
        subject <- lower value
        field' <- lower replacement
        (tag, index) <- fieldOf (C.expressionType subject) field
        pure (node t (C.Update tag index subject field'))
      S.Apply _ _ -> case application old of
        (S.Var n,args) | Just builtin <- stripPrefix "prelude." n -> do
          xs <- mapM lower operands
          builtinNode t builtin xs
        (S.Var n,args) -> node t . C.ExternalCall (resolve n) <$> mapM lower args
        _ -> Left "higher-order expression survived specialization"
      _ -> Left "unresolved expression at core boundary"
    case conversion of
      Nothing -> pure e
      Just target -> do
        tt <- coreType target
        pure (node tt (C.Convert C.CheckedArgument tt e))
  constant t s = node t . C.Constant <$> convertValue bits t s
  -- prelude.wrapping, prelude.saturating and prelude.bounded call the
  -- collections unit's definition for the type the context wants.
  boundedArithmetic t n x = do
    let integer = C.scalarType "Integer"
        target = case (n, t) of
          ("bounded", C.Constructor "Maybe" [C.TypeArgument inner]) -> inner
          _ -> t
        widened = if C.expressionType x == integer then x else node integer (C.Convert C.Explicit integer x)
    name <- case target of
      C.Constructor typeName [] | typeName `elem` boundedArithmeticTypes -> Right typeName
      _ -> Left ("prelude." ++ n ++ " gives a bounded integer type, such as Int32; say which with an annotation")
    pure (node t (C.ExternalCall (resolve (importedDefinitionName collectionsUnit (boundedArithmeticDefinition n name))) [widened]))
  integerConstant k = node (C.scalarType "Integer") (C.Constant (SInteger "Integer" k))
  application e = case (S.unlocated (S.expression e),S.operands e) of
    (S.Annotate _ _,[value]) -> application value
    (S.Apply _ _,[f,x]) | not (builtinApplication (S.expression e)) -> let (callee,args) = application f in (callee,args++[x])
    _ -> (root (S.expression e),[])
  root (S.Located _ e) = root e
  root (S.Apply f _) = root f
  root e = e
  -- A collection's items: its single constructor's field.
  collectionItems x = case C.expressionType x of
    C.Constructor "List" _ -> pure x
    C.Constructor name arguments
      | Just short <- stripPrefix (collectionsUnit ++ "::type::") name, Just constructor <- internalConstructor short -> do
          let itemType = case (short, [a | C.TypeArgument a <- arguments]) of
                ("KeyVal", [k, v]) -> C.Constructor (collectionsUnit ++ "::type::Entry") [C.TypeArgument k, C.TypeArgument v]
                (_, a : _) -> a
                _ -> C.scalarType "Unit"
              listType = C.Constructor "List" [C.TypeArgument itemType]
              binder = C.Binder (C.Id (C.idText origin ++ "::items")) "items" listType
          pure (node listType (C.Match x [C.MatchCase (C.Id (name ++ "::" ++ constructor)) [binder] (node listType (C.Local (C.binderId binder)))]))
    _ -> Left "collection helper requires a collection"
  builtinApplication e = case root e of S.Var n -> take 8 n == "prelude."; _ -> False
  -- Arithmetic on durations calls the time unit's checked definitions, whose
  -- preconditions keep results in range; comparisons compare microseconds.
  isDuration e = C.expressionType e == C.Constructor durationType []
  durationBinary t op x y = do
    let integer = C.scalarType "Integer"
        widen e = if C.expressionType e == integer then e else node integer (C.Convert C.Explicit integer e)
        -- The importing unit's copies, which its own facts mention.
        copy name = resolve (importedDefinitionName timeUnit name)
        call name args = node t (C.ExternalCall (copy name) args)
        -- A constructed duration, such as a literal, unwraps to its field.
        unwrap e = case C.expressionNode e of
          C.Construct _ [value] -> value
          _ -> node integer (C.ExternalCall (copy durationValue) [e])
        constant e = case C.expressionNode e of C.Construct _ [value] -> Just value; _ -> Nothing
        scaled micros k = do
          evidence <- operationEvidence C.Multiply integer integer
          pure (call "microseconds" [node integer (C.Binary C.Multiply evidence micros (widen k))])
    case durationArithmetic op of
      Just name | op `elem` ["+","-"] -> pure (call name [x,y])
                -- A constant duration scales linearly: 500ms * n is
                -- microseconds (500000 * n), which the totality audit can bound.
                | op == "*", Just micros <- constant x -> scaled micros y
                | op == "*", Just micros <- constant y -> scaled micros x
                | isDuration x -> pure (call name [x,widen y])
                | otherwise -> pure (call name [y,widen x])
      Nothing -> do
        operator <- binaryOp op
        evidence <- operationEvidence operator integer integer
        pure (node t (C.Binary operator evidence (unwrap x) (unwrap y)))
  -- Arithmetic on instants calls the time unit's checked definitions too;
  -- comparisons compare microseconds.
  isInstant e = C.expressionType e == C.Constructor instantType []
  instantBinary t op x y = do
    let copy name = resolve (importedDefinitionName timeUnit name)
        call name args = node t (C.ExternalCall (copy name) args)
        integer = C.scalarType "Int64"
        unwrap e = node integer (C.ExternalCall (copy "valueOfInstant") [e])
    case op of
      "+" | isInstant x -> pure (call "instantPlus" [x, y])
          | otherwise -> pure (call "instantPlus" [y, x])
      "-" | isInstant y -> pure (call "instantBetween" [x, y])
          | otherwise -> pure (call "instantMinus" [x, y])
      _ -> do
        operator <- binaryOp op
        evidence <- operationEvidence operator integer integer
        pure (node t (C.Binary operator evidence (unwrap x) (unwrap y)))
  builtinNode t n xs
    | isNumeric n, [x] <- xs = pure (node t (C.Convert C.Explicit t x))
    | n == "quot", [a,b] <- xs, isDuration a = durationBinary t n a b
    | n `elem` ["quot","rem","pow"], [a,b] <- xs = do
        op <- binaryOp n
        ev <- operationEvidence op (C.expressionType a) (C.expressionType b)
        pure (node t (C.Binary op ev a b))
    | n == "toList", [x] <- xs = collectionItems x
    | n == "size", [x] <- xs = do
        items <- collectionItems x
        pure (node t (C.Helper C.Length [items]))
    -- select c a b evaluates only the branch c selects, as if c then a else b.
    | n == "select", [c, a, b] <- xs = pure (node t (C.If c a b))
    -- handle e with h end; the handler is resolved with the unit's handlers
    -- (performOperations).
    | Just handler <- S.handledBy ("prelude." ++ n), [e] <- xs =
        pure (node t (C.Handle (C.WithHandler (C.AbilityRef (C.Id "") []) (C.SpecHandler (C.Id handler))) e))
    -- raise e performs the Fail ability's operation at e's type.
    | n == "raise", [e] <- xs = pure (node t (C.Perform (C.Operation (C.AbilityRef C.failAbilityId [C.expressionType e]) "raise") [e]))
    -- attempt e handles Fail E around e, giving Either E A.
    | n == "attempt", [e] <- xs = case t of
        C.Constructor "Either" [C.TypeArgument failure, _] ->
          pure (node t (C.Handle (C.CatchFailure (C.AbilityRef C.failAbilityId [failure])) e))
        _ -> Left "prelude.attempt gives an Either"
    -- calls of op: the operation is resolved with the unit's abilities
    -- (performOperations); op itself was lowered as a call without values.
    | n == "calls", (op : rest) <- xs = case C.expressionNode op of
        C.ExternalCall identity [] -> pure (node t (C.Calls (C.Operation (C.AbilityRef (C.Id "") []) (C.idText identity))
          (if null rest then Nothing else Just rest)))
        _ -> Left "calls of names an ability operation"
    -- Matchers (LawSpec.Matchers).
    | n == "contains", [whole, part] <- xs = case C.expressionType whole of
        C.Constructor "Text" [] -> pure (node t (C.Helper C.TextContains [whole, part]))
        C.Constructor "List" [C.TypeArgument element] -> do
          -- Not every item differs from part.
          let binder = C.Binder (C.Id (C.idText origin ++ "::match::contains" ++ take 12 (digestHex (digestString (show (whole, part)))) ++ "::element::item")) "item" element
          evidence <- operationEvidence C.NotEqual element (C.expressionType part)
          let differs = node t (C.Binary C.NotEqual evidence (node element (C.Local (C.binderId binder))) part)
          pure (node t (C.Unary C.Not (node t (C.AllElements whole binder differs))))
        _ -> Left "contains needs a List or a Text"
    | n == "startsWith", [whole, part] <- xs = pure (node t (C.Helper C.StartsWith [whole, part]))
    | n == "endsWith", [whole, part] <- xs = pure (node t (C.Helper C.EndsWith [whole, part]))
    | n == "regexMatches", [pattern, text] <- xs = pure (node t (C.Helper C.RegexMatches [pattern, text]))
    -- within tolerance x y: if x >= y then x - y <= tolerance else y - x <= tolerance.
    | n == "within", [tolerance, x, y] <- xs = do
        let numberType = C.expressionType x
            difference = case numberType of
              C.Constructor name [] | isInteger name -> C.scalarType "Integer"
              _ -> numberType
            bool = C.scalarType "Bool"
            compareWith op a b = do
              evidence <- operationEvidence op (C.expressionType a) (C.expressionType b)
              pure (node bool (C.Binary op evidence a b))
            minus a b = do
              evidence <- operationEvidence C.Subtract (C.expressionType a) (C.expressionType b)
              pure (node difference (C.Binary C.Subtract evidence a b))
        ordered <- compareWith C.GreaterEqual x y
        down <- minus x y >>= \d -> compareWith C.LessEqual d tolerance
        up <- minus y x >>= \d -> compareWith C.LessEqual d tolerance
        pure (node t (C.If ordered down up))
    -- messageContains failure text: the failure's message field, in whichever
    -- constructor built it, contains text; false for a constructor without one.
    | n == "messageContains", [failure, text] <- xs = case C.expressionType failure of
        C.Constructor parent arguments -> do
          declaration <- case [d | d <- builtinDataDeclarations ++ dataTypes, C.idText (C.dataId d) == parent] of
            [d] -> Right d
            _ -> Left "message contains needs a data type"
          let table = zip (C.dataParameters declaration) [a | C.TypeArgument a <- arguments]
              instantiate ty = case ty of
                C.TypeVariable v -> maybe ty id (lookup v table)
                C.Constructor name args -> C.Constructor name (map instantiateArgument args)
                C.Arrow a b -> C.Arrow (instantiate a) (instantiate b)
              instantiateArgument a = case a of
                C.TypeArgument inner -> C.TypeArgument (instantiate inner)
                other -> other
              bool b = node (C.scalarType "Bool") (C.Constant (SBool b))
          cases <- forM (zip [0 :: Int ..] (C.dataConstructors declaration)) $ \(k, c) -> do
            let binders = [C.Binder (C.Id (C.idText origin ++ "::match::message" ++ show k ++ "::" ++ show i))
                  (C.binderName f) (instantiate (C.binderType f)) | (i, f) <- zip [0 :: Int ..] (C.constructorFields c)]
                body = case [b | b <- binders, C.binderName b == "message", C.binderType b == C.scalarType "Text"] of
                  b : _ -> node t (C.Helper C.TextContains [node (C.binderType b) (C.Local (C.binderId b)), text])
                  [] -> bool False
            pure (C.MatchCase (C.constructorId c) binders body)
          pure (node t (C.Match failure cases))
        _ -> Left "message contains needs a data type"
    -- recorded name value: the key is the unit's folder and the name.
    | n == "recorded", [key, value] <- xs = case C.expressionNode key of
        C.Constant (SSequence "Text" name) ->
          let unit = takeUnit (C.idText origin)
              keyText = C.Constant (SSequence "Text" (map fromEnum (unit ++ "/") ++ name))
          in pure (node t (C.Helper C.Recorded [key { C.expressionNode = keyText }, value]))
        _ -> Left "a recording's name is a literal"
    -- Arithmetic into a bounded integer type, by name: a value that leaves
    -- the type wraps around it, saturates at its bound, or is Nothing.
    | n `elem` ["wrapping", "saturating", "bounded"], [x] <- xs = boundedArithmetic t n x
    -- Sequences (LawSpec.Core's Append ... Join): the subject first.
    | n == "append", [a, b] <- xs = pure (node t (C.Helper C.Append [a, b]))
    | n == "slice", [from, to, x] <- xs = pure (node t (C.Helper C.Slice [x, from, to]))
    | n == "take", [k, x] <- xs = pure (node t (C.Helper C.Slice [x, integerConstant 0, k]))
    -- drop k x is the slice from k to the end: an end past the last item is
    -- clamped to it.
    | n == "drop", [k, x] <- xs = pure (node t (C.Helper C.Slice [x, k, integerConstant (2 ^ (63 :: Int) - 1)]))
    | n == "at", [i, x] <- xs = pure (node t (C.Helper C.At [x, i]))
    | n == "range", [lo, hi] <- xs = pure (node t (C.Helper C.Range [lo, hi]))
    | Just builtin <- lookup n [("octets", C.Octets), ("bytesOf", C.BytesOf), ("utf8", C.Utf8), ("textOf", C.TextOf), ("join", C.Join)] =
        pure (node t (C.Helper builtin xs))
    | n == "isEmpty", [x] <- xs = do
        items <- collectionItems x
        let listType = C.expressionType items
            element = case listType of C.Constructor _ [C.TypeArgument e] -> e; _ -> listType
            binder suffix ty = C.Binder (C.Id (C.idText origin ++ "::isEmpty::" ++ suffix)) suffix ty
            bool b = node (C.scalarType "Bool") (C.Constant (SBool b))
        pure (node t (C.Match items
          [ C.MatchCase (C.Id "List::Nil") [] (bool True)
          , C.MatchCase (C.Id "List::Cons") [binder "head" element, binder "tail" listType] (bool False) ]))
    | otherwise = do
        builtin <- maybe (Left ("unknown resolved helper: " ++ n)) Right (lookup n
          [("length",C.Length),("isPresent",C.IsPresent),("presentValue",C.PresentValue),("real",C.RealPart),("imag",C.ImaginaryPart)
          ,("isNaN",C.IsNaN),("isInfinite",C.IsInfinite),("isFinite",C.IsFinite),("isNegativeZero",C.IsNegativeZero),("round",C.RoundHalfEven),("checked",C.Checked)
          ,("compare",C.Compare),("select",C.Select),("unreachable",C.Unreachable),("concurrently",C.Concurrently)])
        args <- case (builtin,xs) of
          (C.RoundHalfEven,[a,b]) -> do
            let ty = C.scalarType "Int32"
            b' <- case C.expressionNode b of C.Constant v -> constant ty v; _ -> pure (node ty (C.Convert C.CheckedArgument ty b))
            pure [a,b']
          _ -> pure xs
        pure (node t (C.Helper builtin args))

-- The unit an identity belongs to: unit::law::name gives unit.
takeUnit :: String -> String
takeUnit text = case text of
  ':' : ':' : _ -> ""
  c : rest -> c : takeUnit rest
  [] -> []

-- | Operators are spelled once, here, for every later stage.
binaryOp :: String -> Either String C.BinaryOp
binaryOp op = maybe (Left ("unknown binary operation: " ++ op)) Right (lookup op
  [("+",C.Add),("-",C.Subtract),("*",C.Multiply),("/",C.Divide),("quot",C.Quotient),("rem",C.Remainder),("pow",C.Power)
  ,("==",C.Equal),("!=",C.NotEqual),("<",C.Less),("<=",C.LessEqual),(">",C.Greater),(">=",C.GreaterEqual)])

-- | Reused by example-domain checking and final program elaboration. This keeps
-- closed definition execution on the same typed Core path as generated code.
elaborateDefinitionUnit :: [C.DataDeclaration] -> Int -> S.Unit -> Either String C.Unit
elaborateDefinitionUnit dataDeclarations bits u = do
  collected <- elaborateDefinitionUnitWithRecords dataDeclarations bits u
  requireRegisteredRecords dataDeclarations bits collected

-- | Lower a whole implementation plane in one explicit structural context.
-- The returned occurrences are part of the caller's program and must undergo
-- normal constructor and definition admission before interning or execution.
elaborateDefinitionUnitWithRecords :: [C.DataDeclaration] -> Int -> S.Unit -> Either String (C.Unit,[C.DataDeclaration])
elaborateDefinitionUnitWithRecords dataDeclarations bits u = unsafePerformIO $ do
  -- Compilation and elaboration both elaborate each unit's definitions, the
  -- same unit with the same data types: the results are kept, keyed by the
  -- unit's identity in memory and the data types (a pure
  -- function, so this is only a cache).
  name <- evaluate u >>= makeStableName
  let key = (bits, dataDeclarations)
  cached <- readIORef unitCache
  case [result | (n, k, result) <- cached, n == name, k == key] of
    result : _ -> pure result
    [] -> do
      let result = collectRecords dataDeclarations (elaborateDefinitionUnitCollected bits u)
      writeIORef unitCache (take 64 ((name, key, result) : cached))
      pure result
{-# NOINLINE elaborateDefinitionUnitWithRecords #-}

unitCache :: IORef [(StableName S.Unit, (Int, [C.DataDeclaration]), Either String (C.Unit,[C.DataDeclaration]))]
unitCache = unsafePerformIO (newIORef [])
{-# NOINLINE unitCache #-}

elaborateDefinitionUnitCollected :: Int -> S.Unit -> CollectRecords C.Unit
elaborateDefinitionUnitCollected bits u = do
  -- Ability operations are not declarations: handlers answer them.
  ds <- forM [f | f@(n,_) <- S.functions u, n `notElem` S.operationNames u] $ \(n,t) -> do
    ty <- collectType bits t
    uses <- mapM (abilityReferenceWith (collectType bits) u) (maybe [] id (lookup n (S.abilityRows u)))
    pure (C.MkDeclaration (declarationId u n) n ty
      (maybe (C.GeneratedFrom (declarationId u n)) C.SourceSpan (lookup n (S.declarationSpans u)))
      (n `elem` S.asyncFunctions u) uses)
  (abilities, operations) <- unitOperationsWith (collectType bits) u
  -- What every definition's body sees, made once for the unit.
  let unitEnvironment = S.monoEnvironment (S.functions u)
      unitDeclarations = Set.fromList [declarationId u n | (n,_) <- S.functions u]
      declarationTable = M.fromListWith (++) [(C.declarationId d, [d]) | d <- ds]
  definitions <- forM (S.functionDefinitions u) $ \d -> do
    let name = S.functionName d
        did = declarationId u name
        parameters = S.functionArguments d
        ids = [(n,C.Id (C.idText did ++ "::argument::" ++ show i)) | (i,(n,_)) <- zip [0::Int ..] parameters]
        resolve n = maybe (declarationId u n) id (lookup n ids)
        -- Parameter names have lexical precedence over top-level declarations.
        env = M.union (S.monoEnvironment parameters) unitEnvironment
        hidden = Set.fromList [declarationId u n | (n,_) <- parameters]
        visible i = i `Set.member` unitDeclarations && i `Set.notMember` hidden
    unless (length parameters == length (nub (map fst parameters))) (lift (Left (name ++ ": duplicate definition argument")))
    arguments <- forM parameters $ \(n,t) -> C.Binder (resolve n) n <$> collectType bits t
    body <- performOperations operations <$> collectExpression True visible bits did resolve env
      (S.Annotate (S.functionBody d) (S.functionResult d))
    declaration <- case M.findWithDefault [] did declarationTable of
      [value] -> pure value
      _ -> lift (Left (name ++ ": missing or duplicate definition signature"))
    -- A stage's policy names checked definitions of this unit.
    let policy = fmap (declarationId u) <$> lookup name (S.policies u)
    pure (C.MkDefinition declaration arguments body (name `elem` S.orchestrations u) policy)
  contracts <- mapM (elaborateContractCollected bits u)
    [contract | contract <- S.contracts u,
      S.contractName contract `elem` map S.functionName (S.functionDefinitions u)]
  let machines = map (fmap (declarationId u)) (S.machines u)
  bridges <- lift (concat <$> mapM (machineBridges ds) machines)
  sessions <- mapM session (S.protocols u)
  mailboxes <- mapM (\(n, t, _) -> C.Mailbox n <$> collectType bits t) (S.mailboxes u)
  handlers <- forM (S.handlerDeclarations u) $ \h -> do
    ability <- abilityReferenceWith (collectType bits) u (S.handlerAbility h)
    also <- mapM (abilityReferenceWith (collectType bits) u) (S.handlerAlso h)
    let identity = C.Id (S.unitName u ++ "::handler::" ++ S.handlerName h)
        clauses = [(op, declarationId u (clauseDefinitionName (S.handlerName h) op)) | ref <- ability : also, (op, _) <- C.abilityOperations
          (maybe C.failAbility id (lookup ref [(C.abilityInstance a, a) | a <- abilities]))]
        visible = [declarationId u n | (n,_) <- S.functions u]
    state <- forM (S.handlerState h) $ \(_, ty, start) -> do
      t <- collectType bits ty
      value <- collectExpression False (`Set.member` Set.fromList visible) bits identity (declarationId u) (S.monoEnvironment (S.functions u)) (S.Annotate start ty)
      pure (t, value)
    pure (C.Handler identity (S.handlerName h) ability clauses state (C.SourceSpan (S.handlerSpan h)) also)
  pure (C.MkUnit (C.Id (S.unitName u)) (ds ++ map C.definitionDeclaration bridges) contracts [] (definitions ++ bridges) machines sessions (S.supervisors u) mailboxes abilities handlers [] Nothing)
  where
    declarationId unit n = C.Id (S.unitName unit ++ "::" ++ n)
    sessionIdentity n = C.Id (S.unitName u ++ "::session::" ++ n)
    -- A step naming another protocol sends that protocol's first end.
    session p = C.Session (sessionIdentity (S.protocolName p)) (S.protocolName p) <$> mapM step (S.protocolSteps p)
    step (S.Send t) = (,) True <$> stepType t
    step (S.Receive t) = (,) False <$> stepType t
    stepType t = case t of
      S.Named n | n `elem` map S.protocolName (S.protocols u) -> pure (C.Constructor (C.idText (sessionIdentity n)) [])
      _ -> collectType bits t

-- | A model's commands, start and abstraction are adapters; the model runtime
-- calls each through a generated orchestration definition of the same type,
-- which converts logical values to native ones and back like any definition
-- that calls an adapter.
machineBridges :: [C.Declaration] -> C.Machine C.Id -> Either String [C.Definition]
machineBridges ds machine = mapM bridge
  ([(C.commandRun c, C.commandSystem c) | c <- C.machineCommands machine] ++
   [(C.startRun s, C.startSystem s) | Just s <- [C.machineStart machine]] ++
   [(run, f) | (Just run, Just f) <- [(C.machineAbstractRun machine, C.machineAbstract machine)], run /= f])
  where
    bridge (run, target) = do
      adapter <- case filter ((== target) . C.declarationId) ds of
        [d] -> Right d
        _ -> Left ("model " ++ C.machineName machine ++ ": " ++ C.idText target ++ " is not an adapter")
      let ty = C.declarationType adapter
          (args, result) = C.functionType ty
          origin = C.GeneratedFrom target
          binders = [C.Binder (C.Id (C.idText run ++ "::argument::" ++ show i)) ("argument" ++ show i) t | (i, t) <- zip [0 :: Int ..] args]
          call = C.Expr result (C.ExternalCall target [C.Expr (C.binderType b) (C.Local (C.binderId b)) origin | b <- binders]) origin
          name = reverse (takeWhile (/= ':') (reverse (C.idText run)))
          declaration = adapter { C.declarationId = run, C.declarationName = name, C.declarationOrigin = origin }
      pure (C.MkDefinition declaration binders call True Nothing)


-- | Closed fixture evaluation and final frontend elaboration must preserve the
-- same contract binder identities and ordered predicates.
elaborateContract :: [C.DataDeclaration] -> Int -> S.Unit -> S.Contract -> Either String C.Contract
elaborateContract dataDeclarations bits u contract = do
  collected <- elaborateContractWithRecords dataDeclarations bits u contract
  requireRegisteredRecords dataDeclarations bits collected

-- | Contracts use the same collector as signatures and definition bodies.
elaborateContractWithRecords :: [C.DataDeclaration] -> Int -> S.Unit -> S.Contract -> Either String (C.Contract,[C.DataDeclaration])
elaborateContractWithRecords dataDeclarations bits u contract =
  collectRecords dataDeclarations (elaborateContractCollected bits u contract)

elaborateContractCollected :: Int -> S.Unit -> S.Contract -> CollectRecords C.Contract
elaborateContractCollected bits u c = do
  let declarationId unit n = C.Id (S.unitName unit ++ "::" ++ n)
      cid = declarationId u (S.contractName c)
      pairs = S.contractArguments c ++ [S.contractResult c]
      ids = [(n,C.Id (C.idText cid ++ "::contract::" ++ show i)) | (i,(n,_)) <- zip [0::Int ..] pairs]
      resolve n = maybe (declarationId u n) id (lookup n ids)
      env = S.monoEnvironment (S.functions u ++ pairs)
      visible = Set.fromList [declarationId u n | (n,_) <- S.functions u,
        n `notElem` map fst pairs]
      term = collectExpression False (`Set.member` visible) bits cid resolve env
  args <- forM (S.contractArguments c) $ \(n,t) -> C.Binder (resolve n) n <$> collectType bits t
  let (n,t) = S.contractResult c
  result <- C.Binder (resolve n) n <$> collectType bits t
  C.Contract cid args result <$> mapM term (S.contractPreconditions c) <*> mapM term (S.contractPostconditions c) <*> pure []


-- An ability type of a unit, as Core refers to it: Gateway is
-- <unit>::ability::Gateway, where <unit> declares it (an imported ability
-- keeps its owner), and Fail E the built-in Fail at E.
abilityReference :: S.Unit -> S.Type -> Either String C.AbilityRef
abilityReference = abilityReferenceWith coreType

abilityReferenceWithRecords :: [C.DataDeclaration] -> Int -> S.Unit -> S.Type -> Either String (C.AbilityRef,[C.DataDeclaration])
abilityReferenceWithRecords declarations bits unit ty =
  collectRecords declarations (collectAbilityReference bits unit ty)

collectAbilityReference :: Int -> S.Unit -> S.Type -> CollectRecords C.AbilityRef
collectAbilityReference bits = abilityReferenceWith (collectType bits)

abilityReferenceWith :: Monad m => (S.Type -> m C.Type) -> S.Unit -> S.Type -> m C.AbilityRef
abilityReferenceWith lower u t = do
  arguments <- mapM lower (abilityArguments t)
  let name = S.abilityTypeName t
      owner = case [S.abilityOrigin a | a <- S.abilities u, S.abilityName a == name] of
        origin : _ | not (null origin) -> origin
        _ -> S.unitName u
  pure (if name == S.failAbilityName then C.AbilityRef C.failAbilityId arguments
        else C.AbilityRef (C.Id (owner ++ "::ability::" ++ name)) arguments)

-- What elaboration resolves against a unit's abilities: each operation's
-- instances (a call names <unit>::<op>, and its types pick the instance),
-- and each handler by name, for handle ... with h end.
data Operations = Operations
  { operationInstances :: M.Map C.Id [(C.Operation, C.Type)]
  , operationHandlers :: M.Map String (C.AbilityRef, C.Id) }

-- A unit's abilities at each type it uses them at, and its operations.
unitOperations :: S.Unit -> Either String ([C.Ability], Operations)
unitOperations = unitOperationsWith coreType

unitOperationsWithRecords :: [C.DataDeclaration] -> Int -> S.Unit -> Either String (([C.Ability], Operations),[C.DataDeclaration])
unitOperationsWithRecords declarations bits unit =
  collectRecords declarations (unitOperationsWith (collectType bits) unit)

unitOperationsWith :: Monad m => (S.Type -> m C.Type) -> S.Unit -> m ([C.Ability], Operations)
unitOperationsWith lower u = do
  let mentioned = concatMap snd (S.abilityRows u) ++ concatMap S.handlerAbilities (S.handlerDeclarations u) ++
        concatMap (map fst . snd) (S.lawAssignments u) ++ concatMap snd (S.declaredUses u)
  found <- forM (S.abilities u) $ \a -> do
    let instances = if null (S.abilityParameters a) then [S.Named (S.abilityName a)]
          else nub [t | t <- mentioned, S.abilityTypeName t == S.abilityName a]
    forM instances $ \t -> do
      ref <- abilityReferenceWith lower u t
      operations <- forM (instantiatedOperations a t) $ \(op, ty) -> (,) op <$> lower ty
      failures <- forM (S.abilityFailures a) $ \(op, failure) -> do
        failureType <- lower failure
        pure (op, C.AbilityRef C.failAbilityId [failureType])
      resource <- traverse lower (S.abilityResource a)
      pure (C.Ability (C.abilityRefId ref) (S.abilityName a) [] operations (C.SourceSpan (S.abilitySpan a)) (C.abilityRefArguments ref) Nothing failures resource, ref)
  let present = concat found
  handlers <- forM (S.handlerDeclarations u) $ \h -> do
    ref <- abilityReferenceWith lower u (S.handlerAbility h)
    pure (S.handlerName h, (ref, C.Id (S.unitName u ++ "::handler::" ++ S.handlerName h)))
  pure (map fst present, Operations
    (M.fromListWith (flip (++))
      [ (C.Id (S.unitName u ++ "::" ++ op), [(C.Operation ref op, ty)])
      | (ability, ref) <- present, (op, ty) <- C.abilityOperations ability ])
    (M.fromList handlers))

-- Calls to ability operations become Perform (at the instance the call's
-- types pick); `calls of` names its operation; handle ... with h end names
-- h's ability and handler.
performOperations :: Operations -> C.Expr -> C.Expr
performOperations (Operations operations handlers) = go
  where
    pick candidates args result = case [op | (op, ty) <- candidates, C.functionType ty == (map C.expressionType args, result)] of
      op : _ -> Just op
      [] -> fst <$> listToMaybe candidates
    pickNamed candidates args = case args of
      Just xs | (op : _) <- [op | (op, ty) <- candidates, fst (C.functionType ty) == map C.expressionType xs] -> Just op
      _ -> fst <$> listToMaybe candidates
    go e = e { C.expressionNode = case C.expressionNode e of
      C.ExternalCall identity args | Just op <- M.lookup identity operations >>= \cs -> pick cs args (C.expressionType e) ->
        C.Perform op (map go args)
      C.ExternalCall identity args -> C.ExternalCall identity (map go args)
      C.Calls (C.Operation (C.AbilityRef (C.Id "") []) name) args
        | Just op <- M.lookup (C.Id name) operations >>= (`pickNamed` args) -> C.Calls op (map go <$> args)
      C.Handle (C.WithHandler (C.AbilityRef (C.Id "") []) (C.SpecHandler (C.Id name))) body
        | Just (ref, identity) <- M.lookup (unqualifiedHandler name) handlers -> C.Handle (C.WithHandler ref (C.SpecHandler identity)) (go body)
      C.Calls op args -> C.Calls op (map go <$> args)
      C.Perform op args -> C.Perform op (map go args)
      C.Handle handling body -> C.Handle handling (go body)
      C.Let binder value body -> C.Let binder (go value) (go body)
      C.Constant v -> C.Constant v
      C.Construct tag fields -> C.Construct tag (map go fields)
      C.Match value cases -> C.Match (go value) [c { C.caseBody = go (C.caseBody c) } | c <- cases]
      C.AllElements value binder predicate -> C.AllElements (go value) binder (go predicate)
      C.AllPayloads value predicates -> C.AllPayloads (go value) [(b, go p) | (b, p) <- predicates]
      C.Local identity -> C.Local identity
      C.Binary op ev a b -> C.Binary op ev (go a) (go b)
      C.Unary op a -> C.Unary op (go a)
      C.ShortCircuit op a b -> C.ShortCircuit op (go a) (go b)
      C.If c a b -> C.If (go c) (go a) (go b)
      C.Convert mode ty a -> C.Convert mode ty (go a)
      C.Helper builtin args -> C.Helper builtin (map go args)
      C.Project tag index value -> C.Project tag index (go value)
      C.Update tag index value field -> C.Update tag index (go value) (go field) }
