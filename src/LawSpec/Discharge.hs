-- | How each law of a checked program is discharged, alongside the contract,
-- construction and adapter obligations of LawSpec.Core.Evidence and the
-- native bindings of a generation request. Strongest first:
--
--   proved                a law over checked definitions only, discharged by the
--                         totality audit's prover, like a definition postcondition
--   exhaustively-checked  every input of a finite domain is checked: by the
--                         compiler when the law calls definitions only (a false
--                         law is then a compile error), otherwise by the
--                         generated tests
--   property-tested       generated cases, boundary cases and examples
--   runtime-checked       contracts and codecs checked at native boundaries
--   assumed               native adapters, bindings and generators on trust
module LawSpec.Discharge
  ( dischargeEvidence, bindingEvidence, lawClaim
  ) where

import Control.Monad (forM)
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Common
import LawSpec.Core
import LawSpec.Core.DefinitionContracts (definitionContracts)
import LawSpec.Core.Definitions (prepareDefinitions)
import LawSpec.Core.Eval (evaluateValueProposition)
import LawSpec.Core.Evidence
import LawSpec.Core.Total (validateDefinitionContracts)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Value (Value(..))
import LawSpec.NativeBinding
import LawSpec.NativeRequest (BindingPlan(..))
import LawSpec.Scalar (Scalar(..), prettyScalar)
import LawSpec.Testing (PlannedProperty(..), lawPlanner)

-- | Laws first, then contracts, constructions and adapters. A law over checked
-- definitions whose finite domain contains a counterexample is refuted here.
dischargeEvidence :: Program -> Either [Diagnostic] [Obligation]
dischargeEvidence program = do
  invoke <- prepareDefinitions program
  plan <- lawPlanner program
  registry <- either (Left . pure . (\m -> Diagnostic "generation" m Nothing)) Right
    (makeRegistry (programDataDeclarations program))
  let bits = programMachineBits program
      -- An orchestration calls adapters, so a law over one relies on them.
      definitions = filter (not . definitionOrchestrates) (concatMap unitDefinitions (programUnits program))
      definitionIds = S.fromList (map (declarationId . definitionDeclaration) definitions)
  laws <- forM [(u, p) | u <- programUnits program, p <- unitProperties u] $ \(u, p) -> do
    let obligation status reason = Obligation (unitId u) (propertyId p) "law" (Just (lawClaim p)) status reason
        called = S.fromList (concatMap callees (propertyExpressions p))
        adapters = S.toList (S.difference called definitionIds)
        closed = null adapters
        count n noun = show n ++ " " ++ noun ++ (if n == 1 then "" else "s")
        settings = propertyGeneration p
        every [_] = "its only case"
        every tuples = "all " ++ show (length tuples) ++ " inputs"
    case plan p of
      Left message -> pure (obligation Assumed ("not executable, so taken on trust: " ++ message))
      Right planned
        | closed, Right () <- proves program definitions p -> pure (obligation Proved
            "proved statically from its input refinements and the definitions it calls")
        | closed, Just tuples <- finiteCases planned -> do
            mapM_ (refute registry bits invoke p) tuples
            pure (obligation ExhaustivelyChecked ("the compiler evaluated " ++ every tuples ++
              "; the generated tests check " ++ (if length tuples == 1 then "it" else "them") ++ " again natively"))
        | Just tuples <- finiteCases planned -> pure (obligation ExhaustivelyChecked
            ("the generated tests check " ++ every tuples ++ relying adapters))
        | otherwise -> pure (obligation PropertyTested
            ("the generated tests check " ++ count (cases settings) "generated case" ++ ", " ++
             count (length (boundaryCases planned)) "boundary case" ++ " and " ++
             count (length (propertyExamples p)) "example" ++ relying adapters))
  pure (laws ++ programEvidence program)
  where
    relying [] = ""
    relying adapters = "; relies on " ++ intercalate ", " (map idText adapters)
    refute registry bits invoke p values = do
      let env = zip (map (binderId . quantifiedBinder) (propertyInputs p)) values
          at = Just (propertyLocation p)
          shown = intercalate ", " [binderName (quantifiedBinder q) ++ " = " ++ showValue v | (q, v) <- zip (propertyInputs p) values]
          input = if null shown then "" else " for " ++ shown
      case evaluateValueProposition registry bits invoke env (propertyBody p) of
        Right True -> pure ()
        Right False -> Left [Diagnostic "refuted" ("law " ++ propertyName p ++ " is false" ++ input) at]
        Left message -> Left [Diagnostic "refuted" ("law " ++ propertyName p ++ " fails" ++ input ++ ": " ++ message) at]

-- | The law as a Boolean claim over its inputs: implications become disjunctions.
-- `p = true` is shown as p; other equations are shown as written.
lawClaim :: Property -> Expr
lawClaim = claimWith False

-- | For the prover, a Boolean equation between two predicates becomes their
-- equivalence, which linear arithmetic can decide.
proofClaim :: Property -> Expr
proofClaim = claimWith True

claimWith :: Bool -> Property -> Expr
claimWith forProof p = claim (propertyBody p)
  where
    origin = GeneratedFrom (propertyId p)
    bool = scalarType "Bool"
    claim (Equation evidence a b)
      | expressionType a == bool = case (expressionNode a, expressionNode b) of
          (_, Constant (SBool True)) -> a
          (Constant (SBool True), _) -> b
          (_, Constant (SBool False)) -> negation a
          (Constant (SBool False), _) -> negation b
          _ | forProof -> Expr bool (ShortCircuit Or (Expr bool (ShortCircuit And a b) origin)
                 (Expr bool (ShortCircuit And (negation a) (negation b)) origin)) origin
          _ -> Expr bool (Binary Equal evidence a b) origin
      | otherwise = Expr bool (Binary Equal evidence a b) origin
    claim (Implication guard body) =
      Expr bool (ShortCircuit Or (negation guard) (claim body)) origin
    claim (Conjunction []) = Expr bool (Constant (SBool True)) origin
    claim (Conjunction ps) = foldr1 (\a b -> Expr bool (ShortCircuit And a b) origin) (map claim ps)
    negation e = Expr bool (Unary Not e) origin

-- | A law over definitions only is proved when the totality audit proves it as
-- the result contract of a synthetic definition whose body is the claim and
-- whose preconditions are the input refinements.
proves :: Program -> [Definition] -> Property -> Either String ()
proves program definitions p =
  let proof = Id (idText (propertyId p) ++ "::proof")
      result = Binder (Id (idText proof ++ "::result")) "result" bool
      inputs = map quantifiedBinder (propertyInputs p)
      bool = scalarType "Bool"
      origin = GeneratedFrom (propertyId p)
      claim = inline program definitions (proofClaim p)
      -- The claim is the postcondition itself: the prover must derive it from
      -- the input refinements alone. The body only has to be defined.
      synthetic = Definition (Declaration proof ("proof of " ++ propertyName p)
        (foldr (Arrow . binderType) bool inputs) origin) inputs claim
      contract = Contract proof inputs result (concatMap quantifiedPredicates (propertyInputs p)) [claim] []
      table = M.fromList [(declarationId (definitionDeclaration d), d) | d <- definitions]
      reachable = close S.empty (concatMap callees (definitionBody synthetic : contractPreconditions contract))
      close seen [] = seen
      close seen (n : rest)
        | n `S.member` seen = close seen rest
        | Just d <- M.lookup n table = close (S.insert n seen) (callees (definitionBody d) ++ rest)
        | otherwise = close seen rest
      used = [d | d <- definitions, declarationId (definitionDeclaration d) `S.member` reachable]
      contracts = [c | c <- definitionContracts (programUnits program), contractDeclaration c `S.member` reachable]
  in either (Left . show) (const (Right ()))
       (validateDefinitionContracts (programMachineBits program) (programDataDeclarations program)
         (used ++ [synthetic]) (contracts ++ [contract]))

-- | The prover reasons about calls through their contracts. A definition without
-- preconditions and without recursion has no contract of its own to rely on,
-- so its body is unfolded, a bounded number of times. Definitions with
-- preconditions stay calls, so the audit still checks their arguments.
inline :: Program -> [Definition] -> Expr -> Expr
inline program definitions = go (8 :: Int)
  where
    guarded = S.fromList [contractDeclaration c | c <- definitionContracts (programUnits program), not (null (contractPreconditions c))]
    table = M.fromList [(declarationId (definitionDeclaration d), d) | d <- definitions,
      not (declarationId (definitionDeclaration d) `S.member` guarded), not (recursive d)]
    recursive d = reaches (declarationId (definitionDeclaration d)) S.empty (callees (definitionBody d))
    reaches _ _ [] = False
    reaches target seen (n : rest)
      | n == target = True
      | n `S.member` seen = reaches target seen rest
      | otherwise = reaches target (S.insert n seen)
          (maybe [] (callees . definitionBody) (lookupDefinition n) ++ rest)
    lookupDefinition n = case [d | d <- definitions, declarationId (definitionDeclaration d) == n] of
      d : _ -> Just d
      [] -> Nothing
    go depth e = rebuild (go depth) e $ case expressionNode e of
      ExternalCall n args | depth > 0, Just d <- M.lookup n table, length args == length (definitionArguments d) ->
        Just (go (depth - 1) (substitute (M.fromList (zip (map binderId (definitionArguments d)) (map (go depth) args))) (definitionBody d)))
      _ -> Nothing

-- | Replace locals by expressions. Core identities are unique, so a definition's
-- binders never capture a law's inputs.
substitute :: M.Map Id Expr -> Expr -> Expr
substitute table e = case expressionNode e of
  Local n | Just value <- M.lookup n table -> value
  _ -> rebuildWith (substitute table) e

-- | Apply a replacement at the root, or else rebuild the children with f.
rebuild :: (Expr -> Expr) -> Expr -> Maybe Expr -> Expr
rebuild _ _ (Just replaced) = replaced
rebuild f e Nothing = rebuildWith f e

rebuildWith :: (Expr -> Expr) -> Expr -> Expr
rebuildWith f e = e { expressionNode = case expressionNode e of
  Construct n args -> Construct n (map f args)
  Match value cases -> Match (f value) [c { caseBody = f (caseBody c) } | c <- cases]
  AllElements value binder body -> AllElements (f value) binder (f body)
  AllPayloads value predicates -> AllPayloads (f value) [(b, f x) | (b, x) <- predicates]
  ExternalCall n args -> ExternalCall n (map f args)
  Binary op evidence a b -> Binary op evidence (f a) (f b)
  Unary op a -> Unary op (f a)
  ShortCircuit op a b -> ShortCircuit op (f a) (f b)
  If c a b -> If (f c) (f a) (f b)
  Convert conversion ty a -> Convert conversion ty (f a)
  Helper name args -> Helper name (map f args)
  other -> other }

-- | Native bindings of a generation request.
bindingEvidence :: BindingPlan -> [Obligation]
bindingEvidence plan =
  concat
    [ [ Obligation (dataId declaration) (dataId declaration) "binding" Nothing RuntimeChecked
          "native values are decoded through checked codecs and validated against the declaration"
      ] ++
      [ Obligation (dataId declaration) (dataId declaration) "codec" Nothing Assumed
          "user conversion functions taken on trust; their results are validated"
      | Just _ <- [resolvedCodec binding] ]
    | binding <- resolvedTypes (bindingRepresentations plan), let declaration = resolvedDeclaration binding ] ++
  [ Obligation (resolvedGeneratorType generator) (resolvedGeneratorType generator) "generator" Nothing Assumed
      "custom generator's coverage taken on trust; its values and shrinks are validated"
  | generator <- resolvedGenerators (bindingRepresentations plan) ] ++
  [ Obligation (declarationId declaration) (declarationId declaration) "native-function" Nothing Assumed
      "external native function taken on trust; tested by the laws that call it"
  | (declaration, _) <- bindingFunctions plan ] ++
  [ Obligation (declarationId declaration) (declarationId declaration) "native-function" Nothing Assumed
      "external native method or constructor taken on trust; tested by the laws and models that call it"
  | (declaration, _) <- bindingCalls plan ]

callees :: Expr -> [Id]
callees e = case expressionNode e of
  ExternalCall n args -> n : concatMap callees args
  Construct _ args -> concatMap callees args
  Match value cases -> callees value ++ concatMap (callees . caseBody) cases
  AllElements value _ body -> callees value ++ callees body
  AllPayloads value predicates -> callees value ++ concatMap (callees . snd) predicates
  Binary _ _ a b -> callees a ++ callees b
  Unary _ a -> callees a
  ShortCircuit _ a b -> callees a ++ callees b
  If c a b -> callees c ++ callees a ++ callees b
  Convert _ _ a -> callees a
  Helper _ args -> concatMap callees args
  _ -> []

showValue :: Value -> String
showValue (ScalarValue s) = prettyScalar s
showValue (DataValue _ tag []) = constructorLabel tag
showValue (DataValue _ tag fields) = "(" ++ unwords (constructorLabel tag : map showValue fields) ++ ")"
showValue (PresenceValue _ Nothing) = "absent"
showValue (PresenceValue _ (Just v)) = showValue v

constructorLabel :: Id -> String
constructorLabel = reverse . takeWhile (/= ':') . reverse . idText
