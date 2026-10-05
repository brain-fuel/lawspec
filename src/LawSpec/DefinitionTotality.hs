-- Lower already-typed templates to the same proof obligations used by Core.
-- This view is never executable IR and is never consumed by target generators.
module LawSpec.DefinitionTotality (auditTemplates) where

import Control.Monad.State.Strict
import Control.Monad (forM, when)
import Data.List (stripPrefix, isInfixOf)
import qualified Data.Map.Strict as M
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Totality as T
import qualified LawSpec.Core.PayloadPlan as P
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Total (safeConversionTypes, constructorProofContracts)
import LawSpec.Elaboration (coreType, binaryOp)
import LawSpec.Refinement (definitionContractFor)
import LawSpec.Scalar
import LawSpec.Common

type ProofM = StateT Int (Either String)

auditTemplates :: [C.DataDeclaration] -> Int -> S.Unit -> [(S.FunctionDefinition, S.TypedExpr, [S.TypedExpr], [S.TypedExpr])] -> Either [Diagnostic] ()
auditTemplates declarations bits unit templates = do
  constructors <- constructorProofContracts bits declarations
  lowered <- mapM lower templates
  -- Non-linear postconditions the prover defers become runtime checks in Core.
  () <$ T.auditDeferring constructors (map snd lowered) (map fst lowered)
  where
    constructorTag ty name
      | "::" `isInfixOf` name = C.Id name
      | otherwise = C.Id (parent (S.baseType ty) ++ "::" ++ name)
      where
        parent (S.Named name) = name
        parent (S.Applied name _) = name
        parent (S.Application name _) = name
        parent _ = "invalid-constructor"
    identity name = C.Id (S.unitName unit ++ "::" ++ name)
    operations = S.operationNames unit
    lower (definition, body, preconditions, postconditions) = either
      (Left . pure . (\message -> Diagnostic "total"
        (S.functionName definition ++ ": " ++ message)
        (Just (spanStart (S.functionSpan definition))))) Right $ do
      let name = identity (S.functionName definition)
          parameters = [(n,C.Id (C.idText name ++ "::argument::" ++ show i)) |
            (i,(n,_)) <- zip [0::Int ..] (S.functionArguments definition)]
          integerVariables = ["@" ++ n | S.Capability "Integer" (S.Variable n) <- S.functionRequirements definition]
      contract <- definitionContractFor definition
      let result = C.Id (C.idText name ++ "::result")
          argumentScope = M.fromList parameters
          resultScope = M.insert (fst (S.contractResult contract)) result argumentScope
      (expression,pre,post) <- flip evalStateT 0 $ (,,)
        <$> proof name integerVariables argumentScope body
        <*> mapM (proof name integerVariables argumentScope) preconditions
        <*> mapM (proof name integerVariables resultScope) postconditions
      pure (T.ProofDefinition name (S.functionName definition)
        (Just (spanStart (S.functionSpan definition))) (map snd parameters) expression
        (concat [T.integerAssumptions bits name primitive
          | ((_,name),(_,ty)) <- zip parameters (S.functionArguments definition)
          , S.Named primitive <- [S.baseType ty]]),
        T.ProofContract name result pre post)
    proof :: C.Id -> [String] -> M.Map String C.Id -> S.TypedExpr -> ProofM T.Proof
    proof owner integers scope typed = do
      let recur = proof owner integers scope
          source = S.unlocated (S.expression typed)
          operands = S.operands typed
          children = T.Sequence <$> mapM recur operands
      expression <- case source of
        S.Number n -> literal (SInteger "Integer" n)
        S.DecimalNumber c e -> literal (SDecimal c e)
        S.ScalarLit value -> literal value
        S.BoolLit value -> pure (T.Literal (SBool value))
        S.StringLit value -> pure (T.Literal (textScalar value))
        S.TypeBound _ _ -> pure (T.Sequence [])
        -- An ability operation is an opaque call: its handler answers it.
        S.Var name | M.notMember name scope, name `elem` operations -> pure (T.Sequence [])
        S.Var name -> pure $ maybe (T.Call (identity name) []) T.Variable (M.lookup name scope)
        S.Annotate _ _ -> case operands of
          [value] -> recur value
          _ -> lift (Left "invalid typed annotation")
        S.ListLit _ -> foldr T.ListCons T.ListNil <$> mapM recur operands
        S.ConstructLit _ _ | S.Applied "List" _ <- S.baseType (S.expressionType typed) ->
          case operands of
            [] -> pure T.ListNil
            [first,rest] -> T.ListCons <$> recur first <*> recur rest
            _ -> lift (Left "invalid typed List construction")
        S.ConstructLit tag _ -> T.Construct (constructorTag (S.expressionType typed) tag) <$> mapM recur operands
        S.AllPayloadsExpr _ _ -> case operands of
          [value] -> do
            scrutinee <- recur value
            registry <- lift (makeRegistry declarations)
            root <- lift (coreType (effectiveType value))
            (name,count) <- case root of
              C.Constructor name arguments -> pure (name,length arguments)
              _ -> lift (Left "invalid typed payload scrutinee")
            predicates <- forM (S.typedCases typed) $ \entry -> case entry of
              S.TypedCase _ [(name,ty)] predicate -> do
                index <- get
                put (index + 1)
                let binder = C.Id (C.idText owner ++ "::payload::" ++ show index)
                    domains = case S.baseType ty of
                      S.Named primitive -> T.integerAssumptions bits binder primitive
                      _ -> []
                body <- proof owner integers (M.insert name binder scope) predicate
                pure (binder,T.TypedDomain domains body)
              _ -> lift (Left "invalid typed payload callback")
            pure (T.payloadPredicate (P.fromRegistry registry)
              (P.Applied name (map P.Parameter [0 .. count - 1])) predicates scrutinee)
          _ -> lift (Left "invalid typed payload predicate")
        S.AllElementsExpr _ _ _ -> case (operands,S.typedCases typed) of
          ([value],[S.TypedCase _ [(name,ty)] predicate]) -> do
            scrutinee <- recur value
            index <- get
            put (index + 1)
            let binder = C.Id (C.idText owner ++ "::element::" ++ show (index :: Int))
                domains = case S.baseType ty of
                  S.Named primitive -> T.integerAssumptions bits binder primitive
                  _ -> []
            body <- proof owner integers (M.insert name binder scope) predicate
            pure (T.AllElements scrutinee binder (T.TypedDomain domains body))
          _ -> lift (Left "invalid typed List predicate")
        S.MatchExpr _ _ -> case operands of
          [value] -> do
            scrutinee <- recur value
            branches <- forM (S.typedCases typed) $ \(S.TypedCase tag fields body) -> do
              names <- forM fields $ \(name,_) -> do
                index <- get
                put (index + 1)
                pure (name, C.Id (C.idText owner ++ "::match::" ++ show (index :: Int)))
              branch <- proof owner integers (M.union (M.fromList names) scope) body
              let domains = concat [T.integerAssumptions bits name primitive
                    | ((_,name),(_,ty)) <- zip names fields, S.Named primitive <- [S.baseType ty]]
              pure (constructorTag (effectiveType value) tag,map snd names, T.TypedDomain domains branch)
            pure (case (S.baseType (effectiveType value), [body | (_,[],body) <- branches],
                        [(first,rest,body) | (_,[first,rest],body) <- branches]) of
              (S.Applied "List" _, [nil], [(first,rest,cons)]) -> T.ListMatch scrutinee nil first rest cons
              _ -> T.DataMatch scrutinee branches)
          _ -> lift (Left "invalid typed match")
        S.Unary "!" _ -> case operands of
          [value] -> T.Negated <$> recur value
          _ -> lift (Left "invalid typed negation")
        S.Unary "-" _ -> case operands of
          [value] | exactType integers (effectiveType value) ->
            T.ExactArithmetic C.Subtract (T.Literal (SInteger "Integer" 0)) <$> recur value
          _ -> children
        S.Binary operator _ _ -> case operands of
          [left,right] | operator `elem` ["&&","||"] ->
            T.Logical (if operator == "&&" then C.And else C.Or) <$> recur left <*> recur right
          [left,right] -> do
            op <- lift (binaryOp operator)
            a <- recur left
            b <- recur right
            pure (binary integers typed op a b)
          _ -> lift (Left "invalid typed binary operation")
        S.Apply _ _ -> case application typed of
          (S.Var name, arguments) | Just builtin <- stripPrefix "prelude." name -> do
            values <- mapM recur operands
            helper typed integers builtin operands values
          (S.Var name, arguments) | name `elem` operations, M.notMember name scope ->
            T.Sequence <$> mapM recur arguments
          (S.Var name, arguments) -> do
            when (M.member name scope) (lift (Left "higher-order call in a total definition"))
            T.Call (identity name) <$> mapM recur arguments
          _ -> lift (Left "unresolved higher-order definition call")
        _ -> lift (Left "unresolved expression in total-definition proof")
      converted <- case S.requiredConversion typed of
        Nothing -> pure expression
        Just target -> convert integers target (S.expressionType typed) expression
      pure (case effectiveType typed of
        S.Named name | isInteger name || name `elem` integers -> T.Integral converted
        _ -> converted)
      where
        literal value = case S.expressionType typed of
          S.Named name | primitive name /= Nothing ->
            T.Literal <$> lift (convertScalar bits name value)
          _ -> pure (T.Literal value)
    helper :: S.TypedExpr -> [String] -> String -> [S.TypedExpr] -> [T.Proof] -> ProofM T.Proof
    helper typed integers name operands values = case (name, operands, values) of
      (_, [operand], [value]) | isNumeric name ->
        convert integers (S.expressionType typed) (effectiveType operand) value
      ("quot", _, [a,b]) -> pure (binary integers typed C.Quotient a b)
      ("rem", _, [a,b]) -> pure (binary integers typed C.Remainder a b)
      ("pow", _, [a,b]) -> pure (T.ExactArithmetic C.Power a b)
      -- if c then a else b: each branch is checked knowing which way c went.
      ("select", _, [c, a, b]) -> pure (T.Conditional c a b)
      ("concurrently", _, [value]) -> pure value
      -- raise aborts to Fail's handler: an opaque value of any type.
      ("raise", _, _) -> pure (T.Sequence values)
      ("attempt", _, _) -> pure (T.Sequence values)
      ("calls", _, _) -> pure (T.Sequence [])
      ("unreachable", [message], _) | Just name <- literalText (S.expression message) -> pure (T.Absurd name)
      ("unreachable", _, _) -> pure (T.Absurd "a constructor")
      ("isPresent", _, [value]) -> pure (T.IsPresent value)
      ("presentValue", _, [value]) -> pure (T.PresentValue value)
      ("round", [_,scale], [value,scaleValue]) -> do
        checkedScale <- convert integers (S.Named "Int32") (effectiveType scale) scaleValue
        pure (T.Sequence [value,checkedScale])
      _ | name `elem` ["length","real","imag","isNaN","isInfinite","isFinite","isNegativeZero","checked","compare","size","isEmpty","toList"] ->
        pure (T.Sequence values)
      _ -> lift (Left ("unknown total-definition helper: " ++ name))
    binary integers typed op left right
      | op `elem` [C.Divide,C.Quotient,C.Remainder] =
          T.Division (S.expressionType typed `elem` map S.Named ["Float32","Float64","Complex64","Complex128"]) op left right
      | op `elem` [C.Equal,C.NotEqual,C.Less,C.LessEqual,C.Greater,C.GreaterEqual] =
          (if all (exactType integers . effectiveType) (S.operands typed)
            then T.ExactComparison else T.Comparison) op left right
      | op `elem` [C.Add,C.Subtract,C.Multiply], exactType integers (S.expressionType typed) =
          T.ExactArithmetic op left right
      | otherwise = T.Sequence [left,right]
    convert :: [String] -> S.Type -> S.Type -> T.Proof -> ProofM T.Proof
    convert integers target source value
      | target == source = pure value
      | otherwise = do
          to <- lift (coreType target)
          from <- lift (coreType (case source of
            S.Named name | name `elem` integers -> S.Named "Integer"
            _ -> source))
          let literal = case value of T.Literal scalar -> Just scalar; _ -> Nothing
              safe = safeConversionTypes bits to from literal
              narrow = case (to,from) of
                (C.Constructor destination [],C.Constructor source []) -> T.integerConversion bits destination source value
                _ -> Nothing
          pure (if safe && exactType integers source && exactType integers target
            then value else maybe (T.Conversion safe value) id narrow)
    exactType integers (S.Named name) = isExact name || name `elem` integers
    exactType _ _ = False
    effectiveType typed = maybe (S.expressionType typed) id (S.requiredConversion typed)
    application typed = case (S.unlocated (S.expression typed), S.operands typed) of
      (S.Annotate _ _, [value]) -> application value
      (S.Apply _ _, [f,x]) | not (builtinRoot (S.expression typed)) ->
        let (callee,args) = application f in (callee,args ++ [x])
      _ -> (root (S.expression typed), [])
    root expression = case S.unlocated expression of
      S.Apply f _ -> root f
      value -> value
    builtinRoot expression = case root expression of
      S.Var name -> take 8 name == "prelude."
      _ -> False

-- The text of a string literal, through its source location.
literalText :: S.Expr -> Maybe String
literalText e = case e of
  S.Located _ inner -> literalText inner
  S.StringLit text -> Just text
  _ -> Nothing
