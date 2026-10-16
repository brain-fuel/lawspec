-- | Lower already-typed templates to the same proof obligations used by Core.
-- This view is never executable IR and is never consumed by target generators.
module LawSpec.DefinitionTotality (auditTemplates, auditTemplatesWithContext, auditTemplatesWithDeferrals) where

import Control.Monad.State.Strict
import Control.Monad (foldM, forM, forM_, when)
import Data.List (stripPrefix, isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as M
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import qualified LawSpec.Core.Totality as T
import qualified LawSpec.Core.PayloadPlan as P
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Inference (dataIndex)
import LawSpec.Core.Total (safeConversionTypes, constructorProofContracts, resultBounds)
import qualified LawSpec.Core.Total as Total
import LawSpec.Core.RecordNormalize (normalizeProgramRecords,normalizeExpressionRecordsWithViews,withRecordViewDefinitions)
import LawSpec.Elaboration (collectSourceRecords,collectType)
import LawSpec.Elaboration (coreTypeWithSourceRecords, binaryOp)
import qualified LawSpec.SourceContext as Source
import LawSpec.SourceRecords (recordDeclarationsWithContext,typedTypeReferences)
import LawSpec.Core.RecordIdentity (internRecordDeclarations)
import qualified LawSpec.Core.Validate as CoreValidate
import LawSpec.Refinement (definitionContractFor)
import LawSpec.Scalar
import LawSpec.Common

data ProofState = ProofState
  { proofSite :: Int, proofViews :: M.Map C.Id C.Definition, proofRecords :: [C.DataDeclaration] }
type ProofM = StateT ProofState (Either String)

nextProofSite :: ProofM Int
nextProofSite=do
  state<-get
  put state{proofSite=proofSite state+1}
  pure (proofSite state)


-- | Generic definitions are audited before specialisation, so a body that is
-- never used at any type is still proved total. ref:DEC-total-definitions
auditTemplates :: [C.DataDeclaration] -> Int -> S.Unit -> [(S.FunctionDefinition, S.TypedExpr, [S.TypedExpr], [S.TypedExpr])] -> Either [Diagnostic] ()
auditTemplates = auditTemplatesWithContext Source.emptyContext

auditTemplatesWithContext :: Source.SourceContext -> [C.DataDeclaration] -> Int -> S.Unit -> [(S.FunctionDefinition,S.TypedExpr,[S.TypedExpr],[S.TypedExpr])] -> Either [Diagnostic] ()
auditTemplatesWithContext context initial bits unit templates =
  () <$ auditTemplatesWithDeferrals context initial bits unit templates

-- Preserve the existing deferral report for transformations that must not
-- erase a checked call's runtime contract enforcement.
auditTemplatesWithDeferrals :: Source.SourceContext -> [C.DataDeclaration] -> Int -> S.Unit -> [(S.FunctionDefinition,S.TypedExpr,[S.TypedExpr],[S.TypedExpr])] -> Either [Diagnostic] [(C.Id,Int)]
auditTemplatesWithDeferrals context initial bits unit templates = do
  records <- either (Left . pure . (\message -> Diagnostic "total" message Nothing)) Right
    (recordDeclarationsWithContext context initial bits (concat [concatMap typedTypeReferences (body:pre ++ post) |
      (_,body,pre,post) <- templates]))
  let occurrences=if null records then initial else initial ++ records
  normalized <- normalizeProgramRecords (C.Program bits occurrences [])
  constructors <- constructorProofContracts bits (C.programDataDeclarations normalized)
  declarations <- either (Left . pure . (\message -> Diagnostic "total" message Nothing)) Right
    (if null records then pure initial else internRecordDeclarations occurrences)
  auditCollected context declarations constructors bits unit templates

auditCollected context declarations constructors bits unit templates = do
  lowered <- mapM lower templates
  extraViews<-foldM addView M.empty [definition | (_,_,state)<-lowered,definition<-M.elems (proofViews state)]
  (guarantees,extraProofs)<-if M.null extraViews then pure (constructors,[]) else do
    occurrences<-either (Left . pure . (\message -> Diagnostic "total" message Nothing)) Right
      (uniqueNominals (declarations++concat [proofRecords state | (_,_,state)<-lowered]))
    known<-either (Left . pure . (\message -> Diagnostic "total" message Nothing)) Right
      (internRecordDeclarations occurrences)
    program<-either (Left . pure . (\message -> Diagnostic "total" message Nothing)) Right
      (withRecordViewDefinitions (C.Program bits known []) (M.elems extraViews))
    CoreValidate.validateProgram program
    registry<-either (Left . pure . (\message -> Diagnostic "total" message Nothing)) Right (makeRegistry known)
    guarantees<-constructorProofContracts bits known
    pure (guarantees,map (Total.definitionProof (P.fromRegistry registry) bits) (M.elems extraViews))
  -- Non-linear postconditions the prover defers become runtime checks in Core.
  T.auditDeferringWithResults guarantees [contract | (_,contract,_)<-lowered]
    ([definition | (definition,_,_)<-lowered]++extraProofs)
    (M.fromList [ (identity (S.functionName d), bounds)
                | (d, _, _, _) <- templates
                , let bounds = case S.baseType (S.functionResult d) of
                        S.Named primitive -> resultBounds bits (C.Constructor primitive [])
                        _ -> (Nothing, Nothing) ])
  where
    -- Standalone normalizations each return the complete nominal catalog.
    -- Repeated identical nominal declarations are one identity; retain every
    -- structural occurrence for descriptor admission and reject disagreements.
    uniqueNominals supplied = reverse . snd <$> foldM collect (M.empty,[]) supplied
      where
        collect (known,ordered) declaration
          | C.dataStructural declaration/=Nothing = pure (known,declaration:ordered)
          | otherwise = case M.lookup (C.dataId declaration) known of
              Nothing -> pure (M.insert (C.dataId declaration) declaration known,declaration:ordered)
              Just old | old==declaration -> pure (known,ordered)
                       | otherwise -> Left "structural proof declarations disagree for a nominal type"
    addView known definition = case M.lookup identity known of
      Nothing -> pure (M.insert identity definition known)
      Just old | old==definition -> pure known
               | otherwise -> Left [Diagnostic "total" "structural proof definition identity collision" Nothing]
      where identity=C.declarationId (C.definitionDeclaration definition)
    constructorTag ty name
      | "::" `isInfixOf` name = C.Id name
      | otherwise = C.Id (parent (S.baseType ty) ++ "::" ++ name)
      where
        parent (S.Named name) = name
        parent (S.Applied name _) = name
        parent (S.Application name _) = name
        parent _ = "invalid-constructor"
    identity name = C.Id (S.unitName unit ++ "::" ++ name)
    -- The single constructor of a record type, from the declarations.
    coreType ty = fst <$> coreTypeWithSourceRecords context declarations bits ty
    recordOf ty = case S.baseType ty of
      S.Record _ -> do
        lowered <- coreType ty
        case lowered of
          C.Constructor name _ -> lookupRecord name
          _ -> Left "invalid structural record type"
      S.Named name -> lookupRecord name
      S.Applied name _ -> lookupRecord name
      S.Application name _ -> lookupRecord name
      _ -> Left "a field of a value that is not a record"
    lookupRecord name = case M.lookup name (fst (dataIndex declarations)) of
      Just [d] | [c] <- C.dataConstructors d -> Right c
      _ -> Left ("no record type " ++ name)
    fieldOf ty field = do
      c <- recordOf ty
      case [(k, C.binderType b) | (k, b) <- zip [0 ..] (C.constructorFields c), C.binderName b == field] of
        (k, fieldType) : _ -> Right (C.constructorId c, k, fieldType)
        [] -> Left ("no field " ++ field)
    fieldsOf ty = map C.binderType . C.constructorFields <$> recordOf ty
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
      ((expression,pre,post),state) <- flip runStateT (ProofState 0 M.empty []) $ (,,)
        <$> proof name integerVariables argumentScope body
        <*> mapM (proof name integerVariables argumentScope) preconditions
        <*> mapM (proof name integerVariables resultScope) postconditions
      pure (T.ProofDefinition name (S.functionName definition)
        (Just (spanStart (S.functionSpan definition))) (map snd parameters) expression
        (concat [T.integerAssumptions bits name primitive
          | ((_,name),(_,ty)) <- zip parameters (S.functionArguments definition)
          , S.Named primitive <- [S.baseType ty]]),
        T.ProofContract name result pre post,state)
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
        S.ConstructLit tag _ -> do
          values<-mapM recur operands
          if hasProducts then structuralProof owner typed operands values
            (\_ children -> Right (C.Construct (constructorTag (S.expressionType typed) tag) children))
            else pure (T.Construct (constructorTag (S.expressionType typed) tag) values)
        S.RecordLit fields -> do
          constructor <- lift (recordOf (S.expressionType typed))
          values <- mapM recur operands
          bindings <- forM (zip (map fst fields) values) $ \(label,value) -> do
            index <- nextProofSite
            pure (label,(C.Id (C.idText owner ++ "::record::" ++ show index),value))
          ordered <- forM (C.constructorFields constructor) $ \field ->
            maybe (lift (Left "invalid typed record literal field")) (pure . T.Variable . fst)
              (lookup (C.binderName field) bindings)
          make<-if hasProducts then structuralProof owner typed operands values
            (\_ children -> Right (C.Construct (C.constructorId constructor)
              [child | field<-C.constructorFields constructor,
                (label,child)<-zip (map fst fields) children,C.binderName field==label]))
            else pure (T.Construct (C.constructorId constructor) ordered)
          pure (foldr (\(_,(binder,value)) body -> T.Match value
            [([],T.substituteProof (M.singleton binder value) body)]) make bindings)
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
                index <- nextProofSite
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
            index <- nextProofSite
            let binder = C.Id (C.idText owner ++ "::element::" ++ show (index :: Int))
                domains = case S.baseType ty of
                  S.Named primitive -> T.integerAssumptions bits binder primitive
                  _ -> []
            body <- proof owner integers (M.insert name binder scope) predicate
            pure (T.AllElements scrutinee binder (T.TypedDomain domains body))
          _ -> lift (Left "invalid typed List predicate")
        -- let x = e in body: e is checked, and the body knows x is e.
        S.MatchExpr _ [S.MatchBranch tag _ _] | tag == S.letTag, [value] <- operands,
          [S.TypedCase _ [(name, _)] body] <- S.typedCases typed -> do
            bound <- recur value
            index <- nextProofSite
            let binder = C.Id (C.idText owner ++ "::let::" ++ show (index :: Int))
            inner <- proof owner integers (M.insert name binder scope) body
            pure (T.Match bound [([], T.substituteProof (M.singleton binder bound) inner)])
        S.Apply (S.Apply (S.Var n) _) _ | n == S.tuplePatternCheckName, [value,_] <- operands -> do
          subject <- recur value
          pure (T.Sequence [subject,T.Literal (SBool True)])
        S.Apply (S.Var n) _ | n == S.recordPatternCheckName, [value] <- operands -> do
          subject <- recur value
          pure (T.Sequence [subject,T.Literal (SBool True)])
        -- b.f as a field node (LawSpec.Inference): the field, as an atom.
        S.Apply (S.Var n) _ | Just field <- stripPrefix S.fieldAccessPrefix n, [value] <- operands -> do
          scrutinee <- recur value
          (tag, index, fieldType) <- lift (fieldOf (effectiveType value) field)
          if hasProducts then structuralProof owner typed [value] [scrutinee]
            (projection tag index)
            else pure (T.Field tag index (resultBounds bits fieldType) scrutinee)
        -- b with f = v: the value built again from b's other fields and v.
        S.Apply (S.Apply (S.Var n) _) _ | Just field <- stripPrefix S.fieldUpdatePrefix n, [value, replacement] <- operands -> do
          new <- recur replacement
          scrutinee <- recur value
          (tag, index, _) <- lift (fieldOf (effectiveType value) field)
          if hasProducts then structuralProof owner typed operands [scrutinee,new]
            (\_ children -> case children of
              [subject,field] -> Right (C.Update tag index subject field)
              _ -> Left "invalid typed structural update arity")
            else do
              fields <- lift (fieldsOf (effectiveType value))
              -- As the match it stands for: the other fields are bound, with
              -- what the constructor's contract says of them.
              names <- forM fields $ \_ -> do
                index' <- nextProofSite
                pure (C.Id (C.idText owner ++ "::match::" ++ show (index' :: Int)))
              let domains = concat [T.integerAssumptions bits name primitive | (name, C.Constructor primitive []) <- zip names fields]
                  rebuilt = T.Construct tag [ if k == index then new else T.Variable name | (k, name) <- zip [0 ..] names ]
              pure (T.DataMatch scrutinee [(tag, names, T.TypedDomain domains rebuilt)])
        -- b.f (LawSpec.Inference.fieldDesugar): the field, as an atom.
        S.MatchExpr _ [S.MatchBranch tag names _] | [value] <- operands
          , [S.TypedCase _ fields body] <- S.typedCases typed
          , not (null names), all (isPrefixOf "lawspecField") names
          , S.Var chosen <- S.unlocated (S.expression body)
          , (index, (_, fieldType)) : _ <- filter ((== chosen) . fst . snd) (zip [0 ..] fields) -> do
            scrutinee <- recur value
            let bounds = case S.baseType fieldType of
                  S.Named primitive -> resultBounds bits (C.Constructor primitive [])
                  _ -> (Nothing, Nothing)
            if hasProducts then structuralProof owner typed [value] [scrutinee]
              (projection (constructorTag (effectiveType value) tag) index)
              else pure (T.Field (constructorTag (effectiveType value) tag) index bounds scrutinee)
        S.MatchExpr _ _ -> case operands of
          [value] -> do
            scrutinee <- recur value
            branches <- forM (S.typedCases typed) $ \(S.TypedCase tag fields body) -> do
              names <- forM fields $ \(name,_) -> do
                index <- nextProofSite
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
    hasProducts=any ((/=Nothing) . C.dataStructural) declarations
    projection tag index _ children=case children of
      [value] -> Right (C.Project tag index value)
      _ -> Left "invalid typed structural projection arity"

    -- Representation changes are the same ordinary checked Core matches used
    -- by executable definitions. Source proof operands remain opaque locals
    -- until that view is normalized; their existing proof terms are then
    -- substituted back. This keeps generic admission aligned with execution
    -- without inventing a second conversion or evaluation mechanism.
    structuralProof owner typed inputs values build = do
      site<-nextProofSite
      (types,records)<-lift (collectSourceRecords context declarations
        (mapM (collectType bits) (S.expressionType typed:map effectiveType inputs)))
      case types of
        result:arguments -> do
          let identities=[C.Id (C.idText owner++"::structural-proof::"++show site++"::"++show index) | index<-[0..length arguments-1]]
              origin=C.GeneratedFrom owner
              children=[C.Expr ty (C.Local name) origin | (name,ty)<-zip identities arguments]
              known=if null records then declarations else declarations++records
          node<-lift (build result children)
          let expression=C.Expr result node origin
          (normalized,complete,views)<-lift (either (Left . unlines . map message) Right
            (normalizeExpressionRecordsWithViews bits known expression))
          forM_ views $ \definition -> do
            let identity=C.declarationId (C.definitionDeclaration definition)
            previous<-gets (M.lookup identity . proofViews)
            when (maybe False (/=definition) previous) (lift (Left "structural proof definition identity collision"))
            modify (\state -> state{proofViews=M.insert identity definition (proofViews state)})
          when (not (null views)) (modify (\state -> state{proofRecords=complete++proofRecords state}))
          registry<-lift (makeRegistry complete)
          pure (T.substituteProof (M.fromList (zip identities values))
            (Total.proofExpression (P.fromRegistry registry) bits normalized))
        [] -> lift (Left "missing structural proof result type")

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
      -- handle e with h end is e, run with h.
      (_, _, [value]) | take 7 name == "handle:" -> pure value
      ("unreachable", [message], _) | Just name <- literalText (S.expression message) -> pure (T.Absurd name)
      ("unreachable", _, _) -> pure (T.Absurd "a constructor")
      ("isPresent", _, [value]) -> pure (T.IsPresent value)
      ("presentValue", _, [value]) -> pure (T.PresentValue value)
      ("round", [_,scale], [value,scaleValue]) -> do
        checkedScale <- convert integers (S.Named "Int32") (effectiveType scale) scaleValue
        pure (T.Sequence [value,checkedScale])
      ("length", _, [value]) -> pure (T.Opaque "length" [value])
      -- Sequence helpers are total.
      _ | name `elem` ["append","slice","take","drop","at","range","octets","bytesOf","utf8","textOf","join","wrapping","saturating","bounded"] ->
        pure (T.Sequence values)
      ("size", _, [value]) -> pure (T.Opaque "size" [value])
      _ | name `elem` ["length","real","imag","isNaN","isInfinite","isFinite","isNegativeZero","checked","compare","size","isEmpty","toList"] ->
        pure (T.Sequence values)
      -- Matchers are total predicates (LawSpec.Matchers).
      _ | name `elem` ["member","contains","startsWith","endsWith","regexMatches","within","messageContains"] ->
        pure (T.Sequence values)
      ("recorded", _, _) -> lift (Left "a recording is compared by a law, not inside a definition")
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

-- | The text of a string literal, through its source location.
literalText :: S.Expr -> Maybe String
literalText e = case e of
  S.Located _ inner -> literalText inner
  S.StringLit text -> Just text
  _ -> Nothing
