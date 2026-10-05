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
            (digestHex (digestString (show (bits, dataDigest, S.unitName u, S.functions u, p))))
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
          bindings = [(S.inputId i,C.Id (C.idText pid ++ "::input::" ++ show index)) | (index,i) <- zip [0::Int ..] (S.inputs p)]
          env = S.functions u ++ [(S.inputId i,S.inputType i) | i <- S.inputs p]
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
      pure C.Property
        { C.propertyId=pid, C.propertyName=S.name p, C.propertyLocation=S.location original
        , C.propertyInputs=qs, C.propertyBody=body, C.propertyExamples=examples
        , C.propertyGeneration=S.generation p, C.propertyDescription=S.description original
        , C.propertyRationale=S.rationale original, C.propertyReferences=S.references original
        , C.propertyTrace=S.trace p, C.propertyHandlers=[] }
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
  , C.propertyExamples = [e { C.exampleBindings = [(i, f v) | (i, v) <- C.exampleBindings e]
                            , C.exampleExpectations = map proposition (C.exampleExpectations e) } | e <- C.propertyExamples p] }
  where
    proposition (C.Equation ev a b) = C.Equation ev (f a) (f b)
    proposition (C.Implication g body) = C.Implication (f g) (proposition body)
    proposition (C.Conjunction ps) = C.Conjunction (map proposition ps)

-- Quoted law names may contain separators. Escape them before composing IDs so
-- a display name cannot masquerade as a binder segment in target accessors.
escapeIdentity :: String -> String
escapeIdentity = concatMap (\c -> case c of ':' -> "%3A"; '%' -> "%25"; _ -> [c])

elaborationTable :: Table (Either String C.Property)
elaborationTable = unsafePerformIO (newPersistentTable "elaborate" 4096 (const 1))
{-# NOINLINE elaborationTable #-}
