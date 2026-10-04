-- Lower typed surface expressions once. Law expansion and fixture checking
-- both use this bridge; no backend reinterprets surface syntax.
module LawSpec.Elaboration
  ( coreType, equation, elaborateExpression, elaborateResolved, elaborateResolvedWithData, equationWithData, binaryOp, elaborateDefinitionUnit, elaborateContract ) where

import LawSpec.Time (timeUnit, durationType, durationArithmetic, durationValue)
import LawSpec.Imports (importedDefinitionName)
import LawSpec.Collections (collectionsUnit, internalConstructor)
import qualified LawSpec.Model as S
import qualified LawSpec.Inference as S
import qualified LawSpec.Core as C
import LawSpec.Core.Validate (operationEvidenceWithRegistry)
import LawSpec.Core.Types (makeRegistry, builtinDataDeclarations)
import LawSpec.Core.Semantics (convertValue)
import LawSpec.Scalar
import Data.List (stripPrefix, nub)
import Control.Monad (forM, unless)

coreType :: S.Type -> Either String C.Type
coreType t = case S.baseType t of
  S.Named n -> Right (C.scalarType n)
  S.Variable n -> Right (C.TypeVariable (C.Id n))
  S.Applied n a -> C.Constructor n . pure . C.TypeArgument <$> coreType a
  S.Application n as -> C.Constructor n <$> mapM (fmap C.TypeArgument . coreType) as
  S.Arrow a b -> C.Arrow <$> coreType a <*> coreType b
  _ -> Left "unelaborated type at core boundary"

-- Equality's contextual typing belongs to elaboration, including the expected
-- result in an example. It is performed exactly once for every backend.
equation :: [C.Id] -> Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> S.Expr -> Either String C.Proposition
equation = equationWithData []

equationWithData :: [C.DataDeclaration] -> [C.Id] -> Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> S.Expr -> Either String C.Proposition
equationWithData dataTypes declarations bits origin resolve env left right = do
  (a,b) <- S.contextualizeStructuralWithData dataTypes bits env left right
  ta <- S.typedExpressionWithData dataTypes bits env (S.normal a)
  tb <- S.typedExpressionWithData dataTypes bits env (S.normal b)
  let contextual e = case S.unlocated e of
        S.ConstructLit _ _ -> True
        S.ListLit _ -> True
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
        S.Refined _ inner _ -> open inner
        _ -> False
      ta' = S.expressionType ta
      tb' = S.expressionType tb
      (a',b') | contextual a || (open ta' && not (open tb')) = (S.Annotate a tb',b)
              | contextual b || (open tb' && not (open ta')) = (a,S.Annotate b ta')
              | otherwise = (a,b)
  x <- elaborateResolvedWithData dataTypes declarations bits origin resolve env a'
  y <- elaborateResolvedWithData dataTypes declarations bits origin resolve env b'
  registry <- makeRegistry dataTypes
  ev <- operationEvidenceWithRegistry registry C.Equal (C.expressionType x) (C.expressionType y)
  pure (C.Equation ev x y)

elaborateExpression :: Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> Either String C.Expr
elaborateExpression = elaborateResolved []

elaborateResolved :: [C.Id] -> Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> Either String C.Expr
elaborateResolved = elaborateResolvedWithData []

elaborateResolvedWithData :: [C.DataDeclaration] -> [C.Id] -> Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> Either String C.Expr
elaborateResolvedWithData dataTypes declarations bits origin resolve env source = S.typedExpressionWithData dataTypes bits env (S.normal source) >>= lowerWith [] where
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
      S.Var n -> pure (node t (if lookup n bound == Nothing && resolve n `elem` declarations then C.ExternalCall (resolve n) [] else C.Local (resolveName n)))
      S.Annotate _ _ -> case operands of
        [a] -> lower a
        _ -> Left "invalid typed annotation"
      S.Binary op _ _ -> case operands of
        [a,b] -> do
          x <- lower a; y <- lower b
          case op of
            "&&" -> pure (node t (C.ShortCircuit C.And x y))
            "||" -> pure (node t (C.ShortCircuit C.Or x y))
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
          ,("compare",C.Compare),("select",C.Select)])
        args <- case (builtin,xs) of
          (C.RoundHalfEven,[a,b]) -> do
            let ty = C.scalarType "Int32"
            b' <- case C.expressionNode b of C.Constant v -> constant ty v; _ -> pure (node ty (C.Convert C.CheckedArgument ty b))
            pure [a,b']
          _ -> pure xs
        pure (node t (C.Helper builtin args))

binaryOp :: String -> Either String C.BinaryOp
binaryOp op = maybe (Left ("unknown binary operation: " ++ op)) Right (lookup op
  [("+",C.Add),("-",C.Subtract),("*",C.Multiply),("/",C.Divide),("quot",C.Quotient),("rem",C.Remainder),("pow",C.Power)
  ,("==",C.Equal),("!=",C.NotEqual),("<",C.Less),("<=",C.LessEqual),(">",C.Greater),(">=",C.GreaterEqual)])

-- Reused by example-domain checking and final program elaboration. This keeps
-- closed definition execution on the same typed Core path as generated code.
elaborateDefinitionUnit :: [C.DataDeclaration] -> Int -> S.Unit -> Either String C.Unit
elaborateDefinitionUnit dataDeclarations bits u = do
  ds <- forM (S.functions u) $ \(n,t) -> (\ty -> C.MkDeclaration (declarationId u n) n ty
    (maybe (C.GeneratedFrom (declarationId u n)) C.SourceSpan (lookup n (S.declarationSpans u)))
    (n `elem` S.asyncFunctions u)) <$> coreType t
  definitions <- forM (S.functionDefinitions u) $ \d -> do
    let name = S.functionName d
        did = declarationId u name
        parameters = S.functionArguments d
        ids = [(n,C.Id (C.idText did ++ "::argument::" ++ show i)) | (i,(n,_)) <- zip [0::Int ..] parameters]
        resolve n = maybe (declarationId u n) id (lookup n ids)
        env = S.functions u ++ parameters
    unless (length parameters == length (nub (map fst parameters))) (Left (name ++ ": duplicate definition argument"))
    -- Parameter names have lexical precedence over top-level declarations.
    let visible = [declarationId u n | (n,_) <- S.functions u, n `notElem` map fst parameters]
    arguments <- forM parameters $ \(n,t) -> C.Binder (resolve n) n <$> coreType t
    body <- elaborateResolvedWithData dataDeclarations visible bits did resolve env
      (S.Annotate (S.functionBody d) (S.functionResult d))
    declaration <- case filter ((== did) . C.declarationId) ds of
      [value] -> Right value
      _ -> Left (name ++ ": missing or duplicate definition signature")
    -- A stage's policy names checked definitions of this unit.
    let policy = fmap (declarationId u) <$> lookup name (S.policies u)
    pure (C.MkDefinition declaration arguments body (name `elem` S.orchestrations u) policy)
  contracts <- mapM (elaborateContract dataDeclarations bits u)
    [contract | contract <- S.contracts u,
      S.contractName contract `elem` map S.functionName (S.functionDefinitions u)]
  pure (C.Unit (C.Id (S.unitName u)) ds contracts [] definitions (map (fmap (declarationId u)) (S.machines u)))
  where declarationId unit n = C.Id (S.unitName unit ++ "::" ++ n)


-- Closed fixture evaluation and final frontend elaboration must preserve the
-- same contract binder identities and ordered predicates.
elaborateContract :: [C.DataDeclaration] -> Int -> S.Unit -> S.Contract -> Either String C.Contract
elaborateContract dataDeclarations bits u c = do
  let declarationId unit n = C.Id (S.unitName unit ++ "::" ++ n)
      cid = declarationId u (S.contractName c)
      pairs = S.contractArguments c ++ [S.contractResult c]
      ids = [(n,C.Id (C.idText cid ++ "::contract::" ++ show i)) | (i,(n,_)) <- zip [0::Int ..] pairs]
      resolve n = maybe (declarationId u n) id (lookup n ids)
      env = S.functions u ++ pairs
      term = elaborateResolvedWithData dataDeclarations [declarationId u n | (n,_) <- S.functions u] bits cid resolve env
  args <- forM (S.contractArguments c) $ \(n,t) -> C.Binder (resolve n) n <$> coreType t
  let (n,t) = S.contractResult c
  result <- C.Binder (resolve n) n <$> coreType t
  C.Contract cid args result <$> mapM term (S.contractPreconditions c) <*> mapM term (S.contractPostconditions c) <*> pure []
