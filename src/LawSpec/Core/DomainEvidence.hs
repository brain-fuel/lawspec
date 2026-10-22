-- | Input-domain facts, independent of the law's proposition and selected law
-- verification layers. Every candidate uses the existing closed evaluator and
-- ordinary value/refinement validation. Bounded misses never prove emptiness.
module LawSpec.Core.DomainEvidence
  ( DomainStatus(..), DomainEvidence(..), inputDomainEvidence ) where

import LawSpec.Core
import LawSpec.Core.Value
import LawSpec.Core.Types (TypeRegistry,registryDeclarations,freeExistentials)
import LawSpec.Core.Eval (evaluateValue)
import LawSpec.Core.Search (Candidate(..),applyCandidate)
import LawSpec.Core.QuantifierDomain (finiteQuantifierTerms)
import Control.Monad.State.Strict
import Control.Monad (forM,unless)
import qualified LawSpec.Testing as T
import qualified LawSpec.Dependencies as Dependencies
import qualified Data.Set as Set
import LawSpec.Scalar (Scalar(..))
import LawSpec.Common (Generation(..))
import Data.List (nub)

data DomainStatus = VerifiedInputTuple [Value] | CompleteEmptyDomain
  | VerifiedFiniteParameterInputs [([Value],[Value])]
  | CompleteEmptyParameterDomain | CompleteEmptyInputForParameter [Value]
  | InconclusiveDomain String | UnsupportedInputDomain String deriving (Eq,Show)
data DomainEvidence = DomainEvidence
  { domainStatus :: DomainStatus, domainSearch :: String
  , domainCandidateChecks :: Int, domainSearchLimit :: Int
  , domainFiniteLimit :: Int, domainNotes :: [String]
  } deriving (Eq,Show)

type ParameterSearch a = StateT Int (Either (DomainStatus,Int,String)) a

inputDomainEvidence :: TypeRegistry -> Int -> (Id -> [Value] -> Either String Value)
  -> [Definition] -> Property -> DomainEvidence
inputDomainEvidence registry bits invoke definitions property
  | parameterDependent = finiteParameters
  | otherwise =
  case firstExample 0 [] (take budget (propertyExamples property)) of
    (Just tuple,checks,notes) -> result (VerifiedInputTuple tuple) "example-input" checks notes
    (Nothing,checks,notes) -> case finiteDomain of
      Right (Just tuples) -> complete checks notes tuples
      finite -> let notes' = notes ++ [message | Left message <- [finite]]
                    (found,remaining,errors) = search budget [] quantifiers
                in case found of
                  Just tuple -> result (VerifiedInputTuple tuple) "bounded-input-search" (checks+budget-remaining) (notes'++errors)
                  Nothing | remaining==budget && not (null (notes'++errors)) ->
                    result (UnsupportedInputDomain "input-domain candidate generation was unsupported; no emptiness result was established")
                      "unsupported-input-search" checks (notes'++errors)
                  Nothing -> result (InconclusiveDomain "no verified input tuple was found within the bounded search; emptiness is not established")
                    "bounded-input-search" (checks+budget-remaining) (notes'++errors)
  where
    quantifiers=propertyInputs property
    parameters=Set.fromList (map (binderId.quantifiedBinder) (propertyParameters property))
    parameterDependent=any (`Set.member` parameters)
      (concat [typeVariables (binderType (quantifiedBinder q))++
        concatMap freeBinders (quantifiedPredicates q++map snd (quantifiedBounds q)) | q<-quantifiers])
    typeVariables value=case value of
      TypeVariable name -> [name]
      Arrow a b -> typeVariables a++typeVariables b
      Constructor _ arguments -> concat [case argument of
        TypeArgument ty -> typeVariables ty
        IndexArgument (IndexVariable name) -> [name]
        _ -> [] | argument<-arguments]
    settings=propertyGeneration property
    budget=max 1 (min (cases settings) (maxAttempts settings))
    finiteLimit=max 1 (exhaustiveLimit settings)
    origin=GeneratedFrom (propertyId property)
    result status mode checks notes=DomainEvidence status mode checks budget finiteLimit (take 4 (nub notes))
    valid qs= T.validTupleWithDefinitions registry bits invoke qs
    -- Complete finite forall-parameters / exists-inputs analysis, reusing the
    -- logical cover, evaluator and tuple checker. The law body is irrelevant.
    -- Every cover is obtained in its actual earlier-value environment; all
    -- restrictions are then rechecked. Errors and limits never prove absence.
    finiteParameters=case runStateT analyze 0 of
      Right (status,checks)->result status "complete-finite-parameter-input-domains" checks []
      Left (status,checks,message)->result status (case status of
        UnsupportedInputDomain _->"unsupported-uniform-input-search"
        _->"incomplete-parameter-input-domains") checks [message]
    analyze=do
      tuples<-enumerate (propertyParameters property) []
      if null tuples then pure CompleteEmptyParameterDomain else witnesses [] tuples
    witnesses found []=pure (VerifiedFiniteParameterInputs (reverse found))
    witnesses found (parameters':rest)=do
      tuples<-enumerate quantifiers parameters'
      case tuples of
        []->pure (CompleteEmptyInputForParameter (map snd parameters'))
        tuple:_->witnesses ((map snd parameters',map snd (drop (length parameters') tuple)):found) rest
    failure :: DomainStatus -> String -> ParameterSearch a
    failure status message=do
      checks<-get
      lift (Left (status,checks,message))
    checked :: Either String a -> ParameterSearch a
    checked action=case action of
      Right value->pure value
      Left message->failure (InconclusiveDomain
        "parameter-domain candidate evaluation failed; uniform population and nonexistence are not established") message
    enumerate :: [Quantifier] -> [(Id,Value)] -> ParameterSearch [[(Id,Value)]]
    enumerate [] prefix=pure [prefix]
    enumerate (q:rest) prefix=do
      let ty=binderType (quantifiedBinder q)
      unless (closedType ty && not (opaque ty)) $ failure (UnsupportedInputDomain
        "complete parameter analysis requires closed types and indices without opaque handles or existential witness pools")
        "the parameter/input type has no supported complete finite cover"
      predicates<-checked (mapM (close prefix) (quantifiedPredicates q))
      cover<-case finiteQuantifierTerms bits finiteLimit (T.finiteValuesWithRegistry registry bits finiteLimit)
          q{quantifiedPredicates=predicates} of
        Right (Just terms)->pure terms
        outcome->failure (UnsupportedInputDomain
          "a uniform witness or complete parameter analysis is required; one sampled parameter tuple is insufficient")
          (case outcome of Left message->message;_->"no complete finite parameter/input cover within the configured limit")
      fmap concat $ forM cover $ \term->do
        checks<-get
        unless (checks<finiteLimit) $ failure (InconclusiveDomain
          "complete parameter analysis exceeded its candidate limit; uniform population and nonexistence are not established")
          "the combined parameter/input enumeration exhausted its finite limit"
        put (checks+1)
        value<-checked (evaluateValue registry bits invoke prefix term)
        let next=prefix++[(binderId (quantifiedBinder q),value)]
            allQuantifiers=propertyParameters property++quantifiers
        accepted<-checked (valid (take (length next) allQuantifiers) (map snd next))
        if accepted then enumerate rest next else pure []
    -- Core admission prohibits a nested binder from reusing an in-scope ID.
    -- Replacements are closed values, so this cannot capture another binder.
    close prefix expression=case expressionNode expression of
      Local name | Just value<-lookup name prefix->do
        term<-valueTerm value
        if expressionType term==expressionType expression
          then pure term{expressionOrigin=expressionOrigin expression}
          else Left "formal-domain substitution has inconsistent local types"
      _->traverseChildren (close prefix) expression
    firstExample checks notes []=(Nothing,checks,notes)
    firstExample checks notes (example:rest)=case do
      bindings <- mapM (\(name,value) -> (,) name <$> evaluateValue registry bits invoke [] value) (exampleBindings example)
      tuple <- mapM (\q -> maybe (Left "an example input is unavailable") Right
        (lookup (binderId (quantifiedBinder q)) bindings)) quantifiers
      accepted <- valid quantifiers tuple
      pure (accepted,tuple) of
        Right (True,tuple) -> (Just tuple,checks+1,notes)
        Right (False,_) -> firstExample (checks+1) notes rest
        Left message -> firstExample (checks+1) (message:notes) rest
    -- Enumerate underlying finite types, not a pruned/sample cover inferred
    -- from restrictions. Emptiness requires visiting the complete product and
    -- observing only valid Boolean rejection, never an evaluation error.
    finiteDomain = do
      domains <- mapM (\q -> if closedType (binderType (quantifiedBinder q)) && not (opaque (binderType (quantifiedBinder q)))
        then T.finiteValuesWithRegistry registry bits finiteLimit (binderType (quantifiedBinder q))
        else Left "complete input-domain enumeration requires closed types and indices without opaque handles or existential witness pools") quantifiers
      case sequence domains of
        Just sets | product (map (toInteger . length) sets)<=toInteger finiteLimit -> pure (Just (sequence sets))
        _ -> pure Nothing
    complete checks notes tuples = walk checks [] tuples
      where
        walk count errors []
          | null errors = result CompleteEmptyDomain "complete-finite-input-domain" count notes
          | otherwise = result (InconclusiveDomain "candidate evaluation failed in a complete finite input domain; emptiness is not established")
              "complete-finite-input-domain" count (notes++errors)
        walk count errors (tuple:rest)=case valid quantifiers tuple of
          Right True -> result (VerifiedInputTuple tuple) "complete-finite-input-domain" (count+1) (notes++errors)
          Right False -> walk (count+1) errors rest
          Left message -> walk (count+1) (take 4 (errors++[message])) rest
    search remaining prefix []=(Just (map snd prefix),remaining,[])
    search remaining _ _ | remaining<=0=(Nothing,0,[])
    search remaining prefix (q:rest)=
      let (choices,notes)=candidates q
          qs=take (length prefix+1) quantifiers
          try count errors []=(Nothing,count,errors)
          try count errors _ | count<=0=(Nothing,0,errors)
          try count errors (candidate:more)=case evaluateCandidate prefix q candidate of
            Left message -> try (count-1) (take 4 (errors++[message])) more
            Right Nothing -> try (count-1) errors more
            Right (Just value) -> let next=prefix++[(binderId (quantifiedBinder q),value)] in
              case valid qs (map snd next) of
                Left message -> try (count-1) (take 4 (errors++[message])) more
                Right False -> try (count-1) errors more
                Right True -> case search (count-1) next rest of
                  (Just tuple,left,notes') -> (Just tuple,left,take 4 (errors++notes'))
                  (Nothing,left,notes') -> try left (take 4 (errors++notes')) more
      in try remaining notes choices
    candidates q =
      let ty=binderType (quantifiedBinder q)
          -- Domain facts do not depend on a selected test strategy or on
          -- literals in the law body. Reuse the planner's ordinary boundaries,
          -- restriction hints and checked pattern candidates instead.
          harness=(propertyHarness property){harnessSearches=[],harnessWitnesses=[]}
          source=property{propertyHarness=harness}
          truth=Expr (scalarType "Bool") (Constant (SBool True)) origin
          pool=T.boundedLawSearch registry bits source q (Equation (Structural (scalarType "Bool")) truth truth)
          patterns=T.patternValues definitions q ++ case T.boundariesWithRegistry registry bits ty of
            Right base -> T.fieldPatternValues definitions q base
            Left _ -> []
          extras=[Candidate term | value<-patterns,Right term<-[valueTerm value]]
      in case pool of
        Right values -> (take budget (extras++values),[])
        Left message -> (take budget extras,[message])
    evaluateCandidate prefix q candidate = do
      let ty=binderType (quantifiedBinder q)
          optional=Constructor "Maybe" [TypeArgument ty]
          accepted value=Expr optional (Construct (Id "Maybe::Present") [value]) origin
          rejected=Expr optional (Construct (Id "Maybe::Absent") []) origin
      value <- evaluateValue registry bits invoke prefix (applyCandidate candidate accepted rejected)
      case value of
        DataValue _ (Id "Maybe::Present") [witness] -> pure (Just witness)
        DataValue _ (Id "Maybe::Absent") [] -> pure Nothing
        _ -> Left "malformed input-domain candidate result"
    valueTerm value = case value of
      ScalarValue scalar -> pure (Expr (valueType value) (Constant scalar) origin)
      DataValue ty tag fields -> (\terms -> Expr ty (Construct tag terms) origin) <$> mapM valueTerm fields
      PresenceValue ty _ -> (\scalar -> Expr ty (Constant scalar) origin) <$> toScalarValue value
    closedType ty=case ty of
      TypeVariable _ -> False
      Arrow a b -> closedType a && closedType b
      Constructor _ arguments -> all closedArgument arguments
    closedArgument (TypeArgument ty)=closedType ty
    closedArgument (IndexArgument (IndexVariable _))=False
    closedArgument _=True
    -- A native handle's missing source constructors do not prove that it has
    -- no values. Follow nominal fields as well as explicit type arguments.
    handleIds=Set.fromList [dataId declaration | declaration<-registryDeclarations registry,
      dataHandle declaration || any (not . null . freeExistentials declaration) (dataConstructors declaration)]
    graph=Dependencies.dependencyGraph (registryDeclarations registry) []
    opaque ty=case ty of
      Constructor name arguments -> any (\reference -> case reference of
          Dependencies.TypeNode identity -> identity `Set.member` handleIds
          _ -> False) (Dependencies.closure graph [Dependencies.TypeNode (Id name)]) ||
        any (\argument -> case argument of TypeArgument value -> opaque value; _ -> False) arguments
      Arrow a b -> opaque a || opaque b
      _ -> False
