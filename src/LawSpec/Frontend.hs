-- The only bridge from checked surface syntax to the typed core. Targets never
-- receive TypedExpr's source tree or perform contextual literal inference.
module LawSpec.Frontend (compileCore, elaborate, elaborateExpression) where
import qualified LawSpec.Model as S
import qualified LawSpec.Compile as S
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Data (elaborateDataDeclarationsWithProfile)
import LawSpec.Elaboration (coreType, elaborateExpression, elaborateResolvedWithData, equationWithData, binaryOp, elaborateDefinitionUnit, elaborateContract, abilityReference, unitOperations, performOperations)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Total (deferProgramPostconditions)
import Control.Monad (forM)
import System.IO.Unsafe (unsafePerformIO)
import LawSpec.Digest (digestHex, digestString)
import LawSpec.Memo (Table, newPersistentTable, memoized)
import LawSpec.Persist ()
import LawSpec.Resources (builtinResourceKind)
import LawSpec.Scalar (Scalar(..))

compileCore :: Int -> Generation -> [Source] -> Either [Diagnostic] C.Program
compileCore bits settings sources = do
  (units,properties) <- S.compileWithSettings bits settings sources
  elaborate bits units properties

elaborate :: Int -> [S.Unit] -> [S.Expanded] -> Either [Diagnostic] C.Program
elaborate bits units properties = do
  dataDeclarations <- elaborateDataDeclarationsWithProfile bits units
  elaborated <- C.Program bits dataDeclarations <$> mapM (unit dataDeclarations) units
  -- Postconditions over non-linear index arithmetic become runtime checks.
  core <- deferProgramPostconditions elaborated
  validateProgram core
  pure core
  where
    unit dataDeclarations u = contextual Nothing $ do
      closed <- elaborateDefinitionUnit dataDeclarations bits u
      cs <- mapM (elaborateContract dataDeclarations bits u) (S.contracts u)
      -- A law's Core depends on it, its unit's signatures and the data types.
      let dataDigest = digestHex (digestString (show dataDeclarations))
          elaborated p = memoized elaborationTable
            (digestHex (digestString (show (bits, dataDigest, S.unitName u, S.functions u, S.resourceDeclarations u, p))))
            (property dataDeclarations u p)
      ps <- mapM elaborated (filter ((== S.unitName u) . S.owner) properties)
      -- Calls to ability operations are Perform; each law gets the handlers
      -- the abilities pass chose for it.
      (_, operations) <- unitOperations u
      handled <- forM ps $ \p -> do
        assignment <- forM (maybe [] id (lookup (C.propertyName p) (S.lawAssignments u))) $ \(ability, choice) ->
          (,) <$> abilityReference u ability <*> pure (handlerRef u choice)
        pure (mapProperty (performOperations operations) p) { C.propertyHandlers = assignment }
      pure closed{C.unitContracts=cs,C.unitProperties=handled}
    declarationId u n = C.Id (S.unitName u ++ "::" ++ n)
    property dataDeclarations u p = do
      let pid = C.Id (S.unitName u ++ "::law::" ++ escapeIdentity (S.name p))
          original = S.original p
          resourceIds = [(n,C.Id (C.idText pid ++ "::resource::" ++ show index)) | (index,(n,_)) <- zip [0::Int ..] (S.lawResources original)]
          bindings = [(S.inputId i,C.Id (C.idText pid ++ "::input::" ++ show index)) | (index,i) <- zip [0::Int ..] (S.inputs p)] ++ resourceIds
          env = S.functions u ++ [(S.inputId i,S.inputType i) | i <- S.inputs p] ++ S.lawResources original
          resolve n = maybe (declarationId u n) id (lookup n bindings)
          term = elaborateResolvedWithData dataDeclarations [declarationId u n | (n,_) <- S.functions u] bits pid resolve env
          equal a b = equationWithData dataDeclarations [declarationId u n | (n,_) <- S.functions u] bits pid resolve env a b
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
      resources <- forM (zip resourceIds (S.lawResources original)) $ \((n, rid), (_, ty)) -> do
        t <- coreType ty
        let binder = C.Binder rid n t
            self = C.Expr t (C.Local rid) (C.GeneratedFrom rid)
            text value = C.Expr (C.scalarType "Text") (C.Constant (SSequence "Text" (map fromEnum value))) (C.GeneratedFrom rid)
            helper result builtin args = C.Expr result (C.Helper builtin args) (C.GeneratedFrom rid)
        case t of
          -- A built-in resource: its runtime acquires and releases it.
          C.Constructor typeName [] | Just kind <- builtinResourceKind typeName -> do
            let constructor = C.Id (typeName ++ "::" ++ baseName typeName)
                fieldType = if kind == "freePort" then C.scalarType "Int32" else C.scalarType "Text"
                field = C.Binder (C.Id (C.idText rid ++ "::match::field")) "value" fieldType
                acquired = if kind == "freePort" then helper fieldType C.FreePort [text kind]
                  else helper fieldType C.AcquireResource [text kind]
                release = if kind == "freePort" then C.Expr (C.scalarType "Bool") (C.Constant (SBool True)) (C.GeneratedFrom rid)
                  else C.Expr (C.scalarType "Bool") (C.Match self [C.MatchCase constructor [field]
                    (helper (C.scalarType "Bool") C.ReleaseResource [text kind, C.Expr fieldType (C.Local (C.binderId field)) (C.GeneratedFrom rid)])]) (C.GeneratedFrom rid)
            pure (C.Resource binder (C.Expr t (C.Construct constructor [acquired]) (C.GeneratedFrom rid)) release)
          _ -> case [r | r <- S.resourceDeclarations u, S.resourceType r == ty] of
            [declaration] -> do
              acquire <- term (S.Annotate (S.resourceAcquire declaration) ty)
              let (parameter, releaseBody) = S.resourceRelease declaration
                  resolveRelease name = if name == parameter then rid else resolve name
              release <- elaborateResolvedWithData dataDeclarations [declarationId u n' | (n',_) <- S.functions u] bits pid resolveRelease
                ((parameter, ty) : S.functions u) releaseBody
              -- The law's cases end by releasing the resource, so the law
              -- never releases it itself: it could use it afterwards.
              let releasing = [callee | C.Expr { C.expressionNode = C.ExternalCall callee args } <- [release], any ((== C.Local rid) . C.expressionNode) args]
                  callsRelease e = case C.expressionNode e of
                    C.ExternalCall callee args | callee `elem` releasing, any ((== C.Local rid) . C.expressionNode) args -> True
                    _ -> any callsRelease (C.children e)
              if any callsRelease (C.propositionExpressions body ++ concatMap (concatMap C.propositionExpressions . C.exampleExpectations) examples)
                then Left (S.name p ++ " releases " ++ n ++ ", but a law's resources are released after each case, so it could use " ++ n ++ " after its release")
                else pure (C.Resource binder acquire release)
            [] -> Left (S.name p ++ " takes " ++ n ++ " :: " ++ S.prettyType ty ++ ", but no resource is declared for " ++ S.prettyType ty ++ "; declare resource " ++ S.prettyType ty ++ " is acquire ... release ... end")
            _ -> Left ("more than one resource is declared for " ++ S.prettyType ty)
      pure C.Property
        { C.propertyId=pid, C.propertyName=S.name p, C.propertyLocation=S.location original
        , C.propertyInputs=qs, C.propertyBody=body, C.propertyExamples=examples
        , C.propertyGeneration=S.generation p, C.propertyDescription=S.description original
        , C.propertyRationale=S.rationale original, C.propertyReferences=S.references original
        , C.propertyTrace=S.trace p, C.propertyHandlers=[], C.propertyResources=resources }
    contextual at = either (Left . pure . (\msg -> Diagnostic "elaboration" msg at)) Right

handlerRef :: S.Unit -> S.HandlerChoice -> C.HandlerRef
handlerRef u choice = case choice of
  S.ChooseProduction -> C.ProductionHandler
  S.ChooseSpec h -> C.SpecHandler (C.Id (S.unitName u ++ "::handler::" ++ h))
  S.ChooseRecording c -> C.RecordingHandler (handlerRef u c)

-- Every expression of a property.
mapProperty :: (C.Expr -> C.Expr) -> C.Property -> C.Property
mapProperty f p = p
  { C.propertyInputs = [q { C.quantifiedPredicates = map f (C.quantifiedPredicates q)
                          , C.quantifiedBounds = [(op, f e) | (op, e) <- C.quantifiedBounds q] } | q <- C.propertyInputs p]
  , C.propertyBody = proposition (C.propertyBody p)
  , C.propertyResources = [r { C.resourceAcquire = f (C.resourceAcquire r), C.resourceRelease = f (C.resourceRelease r) } | r <- C.propertyResources p]
  , C.propertyExamples = [e { C.exampleBindings = [(i, f v) | (i, v) <- C.exampleBindings e]
                            , C.exampleExpectations = map proposition (C.exampleExpectations e) } | e <- C.propertyExamples p] }
  where
    proposition (C.Equation ev a b) = C.Equation ev (f a) (f b)
    proposition (C.Implication g body) = C.Implication (f g) (proposition body)
    proposition (C.Conjunction ps) = C.Conjunction (map proposition ps)

-- Quoted law names may contain separators. Escape them before composing IDs so
-- a display name cannot masquerade as a binder segment in target accessors.
-- The last part of a qualified name: lawspec.resources::type::FreePort gives FreePort.
baseName :: String -> String
baseName name = case break (== ':') name of
  (_, ':' : ':' : rest) -> baseName rest
  (n, _) -> n

escapeIdentity :: String -> String
escapeIdentity = concatMap (\c -> case c of ':' -> "%3A"; '%' -> "%25"; _ -> [c])

elaborationTable :: Table (Either String C.Property)
elaborationTable = unsafePerformIO (newPersistentTable "elaborate" 4096 (const 1))
{-# NOINLINE elaborationTable #-}
