-- | Structural termination and definedness auditing over typed Core only.
module LawSpec.Core.Total (validateDefinitions, validateDefinitionContracts, deferNonlinearPostconditions, deferProgramPostconditions, constructorProofContracts, safeConversionTypes) where

import LawSpec.IndexTerm (FamilyIndex(..), ConstructorIndex(..), IndexGuard(..), termFields)
import Control.Monad (unless, forM_, forM)
import Data.List (nub)
import qualified Data.Map.Strict as M
import LawSpec.Common
import LawSpec.Core
import qualified LawSpec.Core.Types as Types
import qualified LawSpec.Core.Totality as T
import qualified LawSpec.Core.PayloadPlan as Payload
import LawSpec.Core.Expression (validateExpressionWithRegistry)
import LawSpec.Core.Semantics (convertValue)
import LawSpec.Scalar (Scalar(..), isInteger, isExact, isNumeric, integerBounds)

-- | Definitions without contracts take the same audit with none.
-- ref:DEC-total-definitions
validateDefinitions :: Int -> [DataDeclaration] -> [Definition] -> Either [Diagnostic] ()
validateDefinitions bits dataDeclarations definitions = validateDefinitionContracts bits dataDeclarations definitions []

-- | The shared admission audit verifies definedness and termination under checked
-- preconditions, proves result contracts, and checks closed call obligations.
-- Native bridges enforce these domains on every entry point.
validateDefinitionContracts :: Int -> [DataDeclaration] -> [Definition] -> [Contract] -> Either [Diagnostic] ()
validateDefinitionContracts bits dataDeclarations definitions contracts = do
  -- Every remaining postcondition must be proved; only the frontend defers.
  deferred <- auditDefinitionContracts bits dataDeclarations definitions contracts
  case deferred of
    [] -> pure ()
    (owner, _) : _ -> Left [Diagnostic "total" (idText owner ++ ": definition result refinement could not be proved") Nothing]

-- | Moves each postcondition the prover defers (non-linear index arithmetic)
-- into the contract's runtime postconditions; every other claim stays proved.
deferNonlinearPostconditions :: Int -> [DataDeclaration] -> [Definition] -> [Contract] -> Either [Diagnostic] [Contract]
deferNonlinearPostconditions bits dataDeclarations definitions contracts = do
  deferred <- auditDefinitionContracts bits dataDeclarations definitions contracts
  pure [ contract { contractPostconditions = [p | (i, p) <- numbered, (owner, i) `notElem` deferred]
                  , contractRuntimePostconditions = contractRuntimePostconditions contract ++
                      [p | (i, p) <- numbered, (owner, i) `elem` deferred] }
       | contract <- contracts
       , let owner = contractDeclaration contract
             numbered = zip [0..] (contractPostconditions contract) ]

-- | Applies the deferral to every definition contract of a program; adapter
-- contracts are untouched.
deferProgramPostconditions :: Program -> Either [Diagnostic] Program
deferProgramPostconditions program = do
  let definitions = concatMap unitDefinitions (programUnits program)
      owned = [declarationId (definitionDeclaration d) | d <- definitions]
      own = [c | u <- programUnits program, c <- unitContracts u, contractDeclaration c `elem` owned]
  deferred <- deferNonlinearPostconditions (programMachineBits program) (programDataDeclarations program) definitions own
  let replaced c = maybe c id (lookup (contractDeclaration c) [(contractDeclaration d, d) | d <- deferred])
  pure program { programUnits = [u { unitContracts = map replaced (unitContracts u) } | u <- programUnits program] }

auditDefinitionContracts :: Int -> [DataDeclaration] -> [Definition] -> [Contract] -> Either [Diagnostic] [(Id, Int)]
auditDefinitionContracts bits dataDeclarations allDefinitions allContracts = do
  -- Orchestrations call adapters; they are run natively, not proved.
  let definitions = filter (not . definitionOrchestrates) allDefinitions
      orchestrated = [declarationId (definitionDeclaration d) | d <- allDefinitions, definitionOrchestrates d]
      contracts = [c | c <- allContracts, contractDeclaration c `notElem` orchestrated]
  registry <- diagnostic Nothing (Types.makeRegistry dataDeclarations)
  diagnostic Nothing $ unless (bits `elem` [32,64]) (Left "machineBits must be 32 or 64")
  let signatures = M.fromList [(declarationId d, declarationType d) |
        definition <- definitions, let d = definitionDeclaration definition]
  forM_ definitions $ \definition -> do
    let declaration = definitionDeclaration definition
        arguments = definitionArguments definition
        body = definitionBody definition
        (parameters, resultType) = functionType (declarationType declaration)
        scope = M.fromList [(binderId b, binderType b) | b <- arguments]
    diagnostic (location declaration) $ prefix (declarationName declaration) $ do
      unless (map binderType arguments == parameters && expressionType body == resultType)
        (Left "definition arguments or result do not match its signature")
      validateExpressionWithRegistry registry bits signatures scope body
  -- Proof extraction can inspect constant numeric values. Validate the complete
  -- typed Core first, including malformed values supplied through internal APIs.
  proofs <- forM contracts $ \contract -> diagnostic Nothing $ do
    definition <- maybe (Left "contract names an unknown definition") Right
      (lookup (contractDeclaration contract) [(declarationId (definitionDeclaration d),d) | d <- definitions])
    let arguments = contractArguments contract
        result = contractResult contract
        expected = definitionDeclaration definition
        (argumentTypes,resultType) = functionType (declarationType expected)
        ids = map binderId (arguments ++ [result])
        argumentScope = M.fromList [(binderId b,binderType b) | b <- arguments]
        resultScope = M.insert (binderId result) (binderType result) argumentScope
        check scope expression = do
          validateExpressionWithRegistry registry bits signatures scope expression
          unless (expressionType expression == scalarType "Bool") (Left "definition refinement must be Bool")
    unless (length ids == length (nub ids)) (Left "duplicate definition contract binder")
    unless (map binderType arguments == argumentTypes && binderType result == resultType)
      (Left "definition contract signature mismatch")
    mapM_ (check argumentScope) (contractPreconditions contract)
    mapM_ (check resultScope) (contractPostconditions contract)
    let parameters = map binderId (definitionArguments definition)
        freshResult = head [Id (idText (contractDeclaration contract) ++ "::proofResult::" ++ show n)
          | n <- [0::Int ..], Id (idText (contractDeclaration contract) ++ "::proofResult::" ++ show n) `notElem` parameters]
        aliases = M.fromList (zip (map binderId arguments) (map T.Variable parameters) ++
          [(binderId result,T.Variable freshResult)])
        lower = T.substituteProof aliases . proofExpression (Payload.fromRegistry registry) bits
    pure (T.ProofContract (contractDeclaration contract) freshResult
      (map lower (contractPreconditions contract)) (map lower (contractPostconditions contract)))
  constructorProofs <- constructorProofContracts bits dataDeclarations
  T.auditDeferring constructorProofs proofs (map (proofDefinition (Payload.fromRegistry registry)) definitions)
  where
    location declaration = case declarationOrigin declaration of
      SourceSpan span -> Just (spanStart span)
      GeneratedFrom _ -> Nothing
    diagnostic at = either (Left . pure . (\message -> Diagnostic "total" message at)) Right
    prefix name = either (Left . ((name ++ ": ") ++)) Right
    proofDefinition schema definition =
      let declaration = definitionDeclaration definition
      in T.ProofDefinition (declarationId declaration) (declarationName declaration)
        (location declaration) (map binderId (definitionArguments definition))
        (proofExpression schema bits (definitionBody definition))
        (concat [T.integerAssumptions bits (binderId argument) name
          | argument <- definitionArguments definition, Constructor name [] <- [binderType argument]])

-- | Shared checked constructor guarantees for Core and typed source templates.
constructorProofContracts :: Int -> [DataDeclaration] -> Either [Diagnostic] [T.ProofConstructorContract]
constructorProofContracts bits dataDeclarations = do
  registry <- diagnostic Nothing (Types.makeRegistry dataDeclarations)
  diagnostic Nothing $ unless (bits `elem` [32,64]) (Left "machineBits must be 32 or 64")
  constructorProofs <- forM
    [(c, guards) | d <- dataDeclarations, c <- dataConstructors d, let guards = indexGuards d c
                 , not (null (constructorPredicates c)) || not (null guards)] $ \(c, guards) ->
      diagnostic (case constructorOrigin c of SourceSpan range -> Just (spanStart range); _ -> Nothing) $
      prefix (constructorName c) $ do
        let fields = constructorFields c
            scope = M.fromList [(binderId field,binderType field) | field <- fields]
        forM_ (constructorPredicates c) $ \predicate -> do
          validateExpressionWithRegistry registry bits M.empty scope predicate
          unless (expressionType predicate == scalarType "Bool")
            (Left "constructor field refinement must be Bool")
        let domains = concat [T.integerAssumptions bits (binderId field) name
              | field <- fields, Constructor name [] <- [binderType field]]
        pure (T.ProofConstructorContract (constructorId c) (map binderId fields)
          (domains ++ map (proofExpression (Payload.fromRegistry registry) bits) (constructorPredicates c)) guards)
  T.auditWithConstructorContracts constructorProofs [] []
  pure constructorProofs
  where
    -- Index guards with each field reference's measure name (<index>Of<Family>).
    indexGuards d c =
      [ (guard, measures)
      | Just index <- [dataIndex d]
      , Just (ConstructorIndex _ guards) <- [lookup (idText (constructorId c)) (familyIndexConstructors index)]
      , guard@(IndexGuard _ left right) <- guards
      , let references = nub (termFields left ++ termFields right)
            measures = [((p, i), name) | (p, i) <- references, Just name <- [measureNameAt c p i]]
      , length measures == length references ]
    measureNameAt c p i = do
      field <- case drop p (constructorFields c) of f : _ -> Just f; [] -> Nothing
      Constructor familyName _ <- Just (binderType field)
      family <- case [f | f <- dataDeclarations, dataId f == Id familyName] of f : _ -> Just f; [] -> Nothing
      familyIndex <- dataIndex family
      indexName <- case drop i (familyIndexNames familyIndex) of n : _ -> Just n; [] -> Nothing
      Just (indexName ++ "Of" ++ dataName family)
    diagnostic at = either (Left . pure . (\message -> Diagnostic "total" message at)) Right
    prefix name = either (Left . ((name ++ ": ") ++)) Right

proofExpression :: Payload.Schema -> Int -> Expr -> T.Proof
proofExpression schema bits = proof
  where
    proof expression = mark expression $ case expressionNode expression of
      Constant value -> T.Literal value
      Local name -> T.Variable name
      Construct (Id "List::Nil") [] -> T.ListNil
      Construct (Id "List::Cons") [first,rest] -> T.ListCons (proof first) (proof rest)
      Construct tag fields -> T.Construct tag (map proof fields)
      Match value branches ->
        let lowered = [(caseConstructor branch,map binderId (caseBinders branch), T.TypedDomain
              (concat [T.integerAssumptions bits (binderId field) name
                | field <- caseBinders branch, Constructor name [] <- [binderType field]])
              (proof (caseBody branch))) | branch <- branches]
        in case (expressionType value, [body | (_,[],body) <- lowered],
                 [(first,rest,body) | (_,[first,rest],body) <- lowered]) of
          (Constructor "List" _, [nil], [(first,rest,cons)]) -> T.ListMatch (proof value) nil first rest cons
          _ -> T.DataMatch (proof value) lowered
      AllPayloads value predicates ->
        let callbacks = [(binderId binder,T.TypedDomain (case binderType binder of
                Constructor name [] -> T.integerAssumptions bits (binderId binder) name
                _ -> []) (proof predicate)) | (binder,predicate) <- predicates]
        in case expressionType value of
          Constructor name _ -> T.payloadPredicate schema
            (Payload.Applied name (map Payload.Parameter [0 .. length callbacks - 1])) callbacks (proof value)
          _ -> T.Conversion False (T.Sequence [])
      AllElements value binder predicate -> T.AllElements (proof value) (binderId binder)
        (T.TypedDomain (case binderType binder of
          Constructor name [] -> T.integerAssumptions bits (binderId binder) name
          _ -> []) (proof predicate))
      ExternalCall identity arguments -> T.Call identity (map proof arguments)
      ShortCircuit op left right -> T.Logical op (proof left) (proof right)
      If c a b -> T.Conditional (proof c) (proof a) (proof b)
      Unary Not value -> T.Negated (proof value)
      Binary op evidence left right | op `elem` [Divide, Quotient, Remainder] ->
        let ieee = case evidence of
              Numeric (Constructor name []) -> name `elem` ["Float32","Float64","Complex64","Complex128"]
              _ -> False
        in T.Division ieee op (proof left) (proof right)
      Binary op (Numeric (Constructor name [])) left right
        | isExact name, op `elem` [Equal,NotEqual,Less,LessEqual,Greater,GreaterEqual] ->
          T.ExactComparison op (proof left) (proof right)
        | isExact name, op `elem` [Add,Subtract,Multiply,Power] ->
          T.ExactArithmetic op (proof left) (proof right)
      Unary Negate value | exact (expressionType value) ->
        T.ExactArithmetic Subtract (T.Literal (SInteger "Integer" 0)) (proof value)
      Binary op _ left right | op `elem` [Equal,NotEqual,Less,LessEqual,Greater,GreaterEqual] ->
        T.Comparison op (proof left) (proof right)
      Convert _ target value | target == expressionType value -> proof value
                             | exact target && exact (expressionType value), safeConversion bits target value -> proof value
                             | Constructor destination [] <- target, Constructor source [] <- expressionType value
                             , Just conversion <- T.integerConversion bits destination source (proof value) -> conversion
                             | otherwise -> T.Conversion (safeConversion bits target value) (proof value)
      -- let x = e in body: e is checked, and the body knows x is e.
      Let binder value body -> T.Match (proof value) [([], T.substituteProof (M.singleton (binderId binder) (proof value)) (proof body))]
      Helper Unreachable [Expr _ (Constant (SSequence _ points)) _] -> T.Absurd (map toEnum points)
      Helper Unreachable _ -> T.Absurd "a constructor"
      Helper IsPresent [value] -> T.IsPresent (proof value)
      Helper PresentValue [value] -> T.PresentValue (proof value)
      _ -> T.Sequence (map proof (children expression))
    exact (Constructor name []) = isExact name
    exact _ = False
    mark expression value = case expressionType expression of
      Constructor name [] | isInteger name -> T.Integral value
      _ -> value

safeConversion :: Int -> Type -> Expr -> Bool
safeConversion bits target value = safeConversionTypes bits target (expressionType value)
  (case expressionNode value of Constant scalar -> Just scalar; _ -> Nothing)

-- | A conversion is safe when the target type holds every source value, or when
-- the converted literal fits, so it needs no runtime check.
safeConversionTypes :: Int -> Type -> Type -> Maybe Scalar -> Bool
safeConversionTypes bits target sourceType literal
  | target == sourceType = True
  | Just scalar <- literal = either (const False) (const True)
      (convertValue bits target scalar)
  | Constructor destination [] <- target, Constructor source [] <- sourceType =
      case destination of
        "Integer" -> isInteger source
        "BigInt" -> isInteger source
        "BigUInt" -> isInteger source && nonnegative source
        "Decimal" -> isInteger source
        "Rational" -> isExact source
        _ | destination `elem` ["Float32","Float64"] ->
              isExact source || source `elem` ["Float32","Float64"]
          | destination `elem` ["Complex64","Complex128"] -> isNumeric source
          | isInteger destination, Just (lo,hi) <- integerBounds bits destination,
            Just (from,to) <- integerBounds bits source -> lo <= from && to <= hi
          | otherwise -> False
  | otherwise = False
  where
    nonnegative source = source == "BigUInt" || maybe False ((>= 0) . fst) (integerBounds bits source)

