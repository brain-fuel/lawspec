-- The only bridge from checked surface syntax to the typed core. Targets never
-- receive TypedExpr's source tree or perform contextual literal inference.
module LawSpec.Frontend (compileCore, elaborate, elaborateExpression) where
import qualified LawSpec.Model as S
import qualified LawSpec.Compile as S
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Core.Validate (operationEvidence, validateProgram)
import LawSpec.Core.Semantics (convertValue)
import LawSpec.Scalar
import Control.Monad (forM)
import Data.List (stripPrefix)

compileCore :: Int -> Generation -> [Source] -> Either [Diagnostic] C.Program
compileCore bits settings sources = do
  (units,properties) <- S.compileWithSettings bits settings sources
  elaborate bits units properties

elaborate :: Int -> [S.Unit] -> [S.Expanded] -> Either [Diagnostic] C.Program
elaborate bits units properties = do
  core <- C.Program bits <$> mapM unit units
  validateProgram core
  pure core
  where
    unit u = contextual Nothing $ do
      ds <- forM (S.functions u) $ \(n,t) -> C.Declaration (declarationId u n) n <$> coreType t <*> pure (maybe (C.GeneratedFrom (declarationId u n)) C.SourceSpan (lookup n (S.declarationSpans u)))
      cs <- mapM (contract u) (S.contracts u)
      ps <- mapM (property u) (filter ((== S.unitName u) . S.owner) properties)
      pure (C.Unit (C.Id (S.unitName u)) ds cs ps)
    declarationId u n = C.Id (S.unitName u ++ "::" ++ n)
    property u p = do
      let pid = C.Id (S.unitName u ++ "::law::" ++ escapeIdentity (S.name p))
          original = S.original p
          bindings = [(S.inputId i,C.Id (C.idText pid ++ "::input::" ++ show index)) | (index,i) <- zip [0::Int ..] (S.inputs p)]
          env = S.functions u ++ [(S.inputId i,S.inputType i) | i <- S.inputs p]
          resolve n = maybe (declarationId u n) id (lookup n bindings)
          term = elaborateResolved [declarationId u n | (n,_) <- S.functions u] bits pid resolve env
          equal a b = equation [declarationId u n | (n,_) <- S.functions u] bits pid resolve env a b
          assertion (S.AssertEqual a b) = equal a b
          assertion (S.AssertImplies g body) = C.Implication <$> term g <*> assertion body
          assertion (S.AssertAll bodies) = C.Conjunction <$> mapM assertion bodies
      qs <- forM (S.inputs p) $ \i -> do
        t <- coreType (S.inputType i)
        preds <- mapM term (S.inputRefinements i)
        let bounds = concat [S.domainBounds plan | plan <- S.generationPlan p, S.inputId (S.domainInput plan) == S.inputId i]
        boundTerms <- mapM (\(op,e) -> (,) <$> binaryOp op <*> term e) bounds
        pure (C.Quantifier (C.Binder (resolve (S.inputId i)) (S.inputName i) t) preds boundTerms)
      body <- assertion (S.assertion p)
      examples <- forM (S.examples original) $ \e -> do
        let aliases = [(S.inputName i,S.Var (S.inputId i)) | i <- S.inputs p]
            replace = S.replaceExprVars aliases
        values <- forM (S.inputs p) $ \i -> do
          lit <- maybe (Left ("missing example binding: " ++ S.inputName i)) Right (lookup (S.inputName i) (S.bindings e))
          value <- term (S.Annotate (S.literalExpr lit) (S.inputType i))
          pure (resolve (S.inputId i),value)
        expects <- forM (S.expectations e) $ \x -> equal (replace (S.actual x)) (S.literalExpr (S.expected x))
        pure (C.Example (S.exampleName e) values expects)
      pure C.Property
        { C.propertyId=pid, C.propertyName=S.name p, C.propertyLocation=S.location original
        , C.propertyInputs=qs, C.propertyBody=body, C.propertyExamples=examples
        , C.propertyGeneration=S.generation p, C.propertyDescription=S.description original
        , C.propertyRationale=S.rationale original, C.propertyReferences=S.references original
        , C.propertyTrace=S.trace p }
    contract u c = do
      let cid = declarationId u (S.contractName c)
          pairs = S.contractArguments c ++ [S.contractResult c]
          ids = [(n,C.Id (C.idText cid ++ "::contract::" ++ show i)) | (i,(n,_)) <- zip [0::Int ..] pairs]
          resolve n = maybe (declarationId u n) id (lookup n ids)
          env = S.functions u ++ pairs
          term = elaborateResolved [declarationId u n | (n,_) <- S.functions u] bits cid resolve env
      args <- forM (S.contractArguments c) $ \(n,t) -> C.Binder (resolve n) n <$> coreType t
      let (n,t) = S.contractResult c
      result <- C.Binder (resolve n) n <$> coreType t
      C.Contract cid args result <$> mapM term (S.contractPreconditions c) <*> mapM term (S.contractPostconditions c)
    contextual at = either (Left . pure . (\msg -> Diagnostic "elaboration" msg at)) Right

coreType :: S.Type -> Either String C.Type
coreType t = case S.baseType t of
  S.Named n -> Right (C.scalarType n)
  S.Variable n -> Right (C.TypeVariable (C.Id n))
  S.Applied n a -> C.Constructor n . pure . C.TypeArgument <$> coreType a
  S.Arrow a b -> C.Arrow <$> coreType a <*> coreType b
  _ -> Left "unelaborated type at core boundary"

-- Equality's contextual typing belongs to elaboration, including the expected
-- result in an example. It is performed exactly once for every backend.
equation :: [C.Id] -> Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> S.Expr -> Either String C.Proposition
equation declarations bits origin resolve env a b = do
  ta <- S.typedExpression bits env (S.normal a)
  tb <- S.typedExpression bits env (S.normal b)
  let contextual e = case S.unlocated e of
        S.Number _ -> True
        S.DecimalNumber _ _ -> True
        S.ScalarLit s -> scalarName s `elem` ["Null","Undefined","Nullable","Optional"]
        _ -> False
      (a',b') | contextual a = (S.Annotate a (S.expressionType tb),b)
              | contextual b = (a,S.Annotate b (S.expressionType ta))
              | otherwise = (a,b)
  x <- elaborateResolved declarations bits origin resolve env a'
  y <- elaborateResolved declarations bits origin resolve env b'
  ev <- operationEvidence C.Equal (C.expressionType x) (C.expressionType y)
  pure (C.Equation ev x y)

elaborateExpression :: Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> Either String C.Expr
elaborateExpression = elaborateResolved []

elaborateResolved :: [C.Id] -> Int -> C.Id -> (String -> C.Id) -> [(String,S.Type)] -> S.Expr -> Either String C.Expr
elaborateResolved declarations bits origin resolve env source = S.typedExpression bits env (S.normal source) >>= lower where
  generated = C.GeneratedFrom origin
  node t n = C.Expr t n generated
  lower old@(S.TypedExpr ty expression operands conversion) = do
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
      S.Var n -> pure (node t (if resolve n `elem` declarations then C.ExternalCall (resolve n) [] else C.Local (resolve n)))
      S.Annotate _ _ -> case operands of
        [a] -> lower a
        _ -> Left "invalid typed annotation"
      S.Binary op _ _ -> case operands of
        [a,b] -> do
          x <- lower a; y <- lower b
          case op of
            "&&" -> pure (node t (C.ShortCircuit C.And x y))
            "||" -> pure (node t (C.ShortCircuit C.Or x y))
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
    (S.Apply _ _,[f,x]) | not (builtinApplication (S.expression e)) -> let (callee,args) = application f in (callee,args++[x])
    _ -> (root (S.expression e),[])
  root (S.Located _ e) = root e
  root (S.Apply f _) = root f
  root e = e
  builtinApplication e = case root e of S.Var n -> take 8 n == "prelude."; _ -> False
  builtinNode t n xs
    | isNumeric n, [x] <- xs = pure (node t (C.Convert C.Explicit t x))
    | n `elem` ["quot","rem"], [a,b] <- xs = do
        op <- binaryOp n
        ev <- operationEvidence op (C.expressionType a) (C.expressionType b)
        pure (node t (C.Binary op ev a b))
    | otherwise = do
        builtin <- maybe (Left ("unknown resolved helper: " ++ n)) Right (lookup n
          [("length",C.Length),("isPresent",C.IsPresent),("presentValue",C.PresentValue),("real",C.RealPart),("imag",C.ImaginaryPart)
          ,("isNaN",C.IsNaN),("isInfinite",C.IsInfinite),("isFinite",C.IsFinite),("isNegativeZero",C.IsNegativeZero),("round",C.RoundHalfEven),("checked",C.Checked)])
        args <- case (builtin,xs) of
          (C.RoundHalfEven,[a,b]) -> do
            let ty = C.scalarType "Int32"
            b' <- case C.expressionNode b of C.Constant v -> constant ty v; _ -> pure (node ty (C.Convert C.CheckedArgument ty b))
            pure [a,b']
          _ -> pure xs
        pure (node t (C.Helper builtin args))

binaryOp :: String -> Either String C.BinaryOp
binaryOp op = maybe (Left ("unknown binary operation: " ++ op)) Right (lookup op
  [("+",C.Add),("-",C.Subtract),("*",C.Multiply),("/",C.Divide),("quot",C.Quotient),("rem",C.Remainder)
  ,("==",C.Equal),("!=",C.NotEqual),("<",C.Less),("<=",C.LessEqual),(">",C.Greater),(">=",C.GreaterEqual)])

-- Quoted law names may contain separators. Escape them before composing IDs so
-- a display name cannot masquerade as a binder segment in target accessors.
escapeIdentity :: String -> String
escapeIdentity = concatMap (\c -> case c of ':' -> "%3A"; '%' -> "%25"; _ -> [c])
