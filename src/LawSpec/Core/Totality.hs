-- Shared totality obligations after typing. This proof view contains no surface
-- syntax, runtime representation choices, or executable code-generation nodes.
module LawSpec.Core.Totality (Proof(..), ProofDefinition(..), ProofContract(..), ProofConstructorContract(..), audit, auditWithContracts, auditWithConstructorContracts, substituteProof, integerAssumptions, integerConversion, payloadPredicate) where

import Control.Monad (unless, forM_, foldM)
import Control.Monad.State.Strict (State, evalState, get, put)
import Data.Graph (SCC(..), stronglyConnComp)
import Data.List (nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import LawSpec.Common
import LawSpec.Core (Id(..), BinaryOp(..), LogicalOp(..))
import LawSpec.Scalar (Scalar(..), exactValue, integerBounds, isInteger)
import qualified LawSpec.Core.RefinementProof as R
import Data.Ratio (denominator)
import qualified LawSpec.Core.PayloadPlan as P

data Proof
  = Literal Scalar
  | Variable Id
  | Sequence [Proof]
  | Call Id [Proof]
  | LetCall Id Id [Proof] Proof
  | Match Proof [([Id], Proof)]
  | Construct Id [Proof]
  | DataMatch Proof [(Id,[Id],Proof)]
  | ListMatch Proof Proof Id Id Proof
  | AllElements Proof Id Proof
  | AllPayloads P.Schema String Proof [(Id,Proof)]
  | ListNil
  | ListCons Proof Proof
  | Logical LogicalOp Proof Proof
  | Negated Proof
  | Comparison BinaryOp Proof Proof
  | ExactComparison BinaryOp Proof Proof
  | ExactArithmetic BinaryOp Proof Proof
  | Division Bool Proof Proof
  | Conversion Bool Proof
  | NarrowInteger (Maybe Integer) (Maybe Integer) Proof
  | Integral Proof
  | TypedDomain [Proof] Proof
  | IsPresent Proof
  | PresentValue Proof
  deriving (Eq, Show)

data ProofDefinition = ProofDefinition
  { proofId :: Id, proofName :: String, proofLocation :: Maybe Location
  , proofArguments :: [Id], proofBody :: Proof, proofArgumentDomains :: [Proof]
  } deriving (Eq, Show)

-- Contract argument identities are the definition's argument identities. The
-- result binder is fresh and visible only in postconditions. Typed lowering is
-- responsible for Boolean types; this audit checks scope, totality, and truth.
data ProofContract = ProofContract
  { contractOwner :: Id, contractResult :: Id
  , preconditions :: [Proof], postconditions :: [Proof]
  } deriving (Eq, Show)

-- Ordered field predicates are checked before becoming constructor invariants.
-- Identities belong to the declaration, and are substituted at construction and
-- freshly renamed at each pattern. These primitive predicates cannot call user
-- definitions until constructor/definition dependency cycles are audited.
data ProofConstructorContract = ProofConstructorContract
  { constructorOwner :: Id, constructorParameters :: [Id]
  , constructorConditions :: [Proof]
  } deriving (Eq, Show)

audit :: [ProofDefinition] -> Either [Diagnostic] ()
audit = auditWithContracts []

auditWithContracts :: [ProofContract] -> [ProofDefinition] -> Either [Diagnostic] ()
auditWithContracts = auditWithConstructorContracts []

auditWithConstructorContracts :: [ProofConstructorContract] -> [ProofContract]
  -> [ProofDefinition] -> Either [Diagnostic] ()
auditWithConstructorContracts constructors contracts definitions = do
  let ids = map proofId definitions
      known = S.fromList ids
      signatures = M.fromList [(proofId d,proofArguments d) | d <- definitions]
      constructorTable = M.fromList [(constructorOwner c,c) | c <- constructors]
      unfoldable = M.fromList [(proofId d,(argument,branches)) | d <- definitions,
        [argument] <- [proofArguments d], DataMatch (Variable subject) branches <- [stripDomains (proofBody d)],
        subject == argument]
      initialFacts = emptyFacts{constructorContracts=constructorTable,unfoldings=unfoldable,
        naturalMeasures=S.fromList [name | (name,(_,branches)) <- M.toList unfoldable,
          all (naturalBranch name . (\(_,_,body) -> body)) branches]}
      contractTable = M.fromList [(contractOwner c,c) | c <- contracts]
      expressions d = proofBody d : proofArgumentDomains d ++ case M.lookup (proofId d) contractTable of
        Nothing -> []
        Just c -> preconditions c ++ postconditions c
  diagnostic Nothing $ do
    unless (length constructors == M.size constructorTable) (Left "duplicate constructor contract")
    forM_ (stronglyConnComp [(c,constructorOwner c,
      concatMap constructorReferences (constructorConditions c)) | c <- constructors]) $ \component ->
        case component of
          AcyclicSCC _ -> pure ()
          CyclicSCC _ -> Left "cyclic constructor predicates require an inductive proof"
    forM_ constructors $ \c -> do
      let parameters = constructorParameters c
          conditions = constructorConditions c
          roots = M.fromList [(name,(index,False)) | (index,name) <- zip [0..] parameters]
      unless (length parameters == length (nub parameters)) (Left "duplicate constructor field identity")
      unless (all (`elem` parameters) (concatMap freeVariables conditions))
        (Left "constructor predicate has an out-of-scope variable")
      unless (null (concatMap calls conditions))
        (Left "constructor predicate calls require dependency auditing")
      -- Cycles were rejected above: matching may use another constructor's
      -- invariant, but cannot circularly establish this constructor's own one.
      -- Within a declaration, only earlier predicates establish definedness.
      _ <- foldM (\facts condition -> do
        _ <- walk M.empty M.empty (constructorOwner c) roots facts condition
        pure (assume True condition facts)) initialFacts conditions
      pure ()
    unless (length ids == length (nub ids)) (Left "duplicate total definition identity")
    unless (length contracts == M.size contractTable) (Left "duplicate definition contract")
    forM_ contracts $ \c -> do
      arguments <- maybe (Left "contract names an unknown definition") Right (M.lookup (contractOwner c) signatures)
      unless (contractResult c `notElem` arguments) (Left "contract result must have a fresh identity")
      unless (all (`elem` arguments) (concatMap freeVariables (preconditions c)))
        (Left "definition precondition has an out-of-scope variable")
      unless (all (`elem` (contractResult c : arguments)) (concatMap freeVariables (postconditions c)))
        (Left "definition postcondition has an out-of-scope variable")
      unless (contractOwner c `notElem` concatMap calls (preconditions c ++ postconditions c))
        (Left "a definition contract cannot call its own definition")
    forM_ (stronglyConnComp [(d, proofId d,
      filter (/= proofId d) (concatMap calls (expressions d))) | d <- definitions]) $ \component ->
        case component of
          AcyclicSCC _ -> pure ()
          CyclicSCC group -> Left ("mutually recursive total definitions are not supported: " ++
            unwords (map proofName group))
  forM_ definitions $ \d -> diagnostic (proofLocation d) $ prefix (proofName d) $ do
    unless (length (proofArguments d) == length (nub (proofArguments d)))
      (Left "duplicate definition argument identity")
    unless (all (`elem` proofArguments d) (concatMap freeVariables (proofArgumentDomains d)))
      (Left "argument domain contains an out-of-scope variable")
    forM_ (concatMap calls (expressions d)) $ \callee -> unless (callee `S.member` known)
      (Left ("total definition calls an adapter or unknown definition: " ++ idText callee))
    let roots = M.fromList [(name, (index, False)) | (index,name) <- zip [0..] (proofArguments d)]
        visit facts expression = walk signatures contractTable (proofId d) roots facts
          (normalizeCalls (M.keys roots ++ S.toList (usedVariables facts)) expression)
        contract = M.lookup (proofId d) contractTable
    domains <- foldM (\facts condition -> do
      _ <- visit facts condition
      pure (assume True condition facts)) initialFacts (proofArgumentDomains d)
    facts <- foldM (\facts condition -> do
      _ <- visit facts condition
      pure (assume True condition facts)) domains (maybe [] preconditions contract)
    let body = normalizeCalls (M.keys roots ++ S.toList (usedVariables facts)) (proofBody d)
    decreases <- walk signatures contractTable (proofId d) roots facts body
    unless (null decreases || not (S.null (foldl1 S.intersection decreases)))
      (Left "no single parameter strictly decreases in every recursive call")
    forM_ contract $ \c ->
      forM_ (resultCases signatures contractTable roots facts body) $ \(scope,branchFacts,result) ->
        forM_ (postconditions c) $ \condition -> do
          -- Definedness is checked with each possible result substituted. Local
          -- field domains stay in their branch and never strengthen a sibling.
          let substituted = substituteProof (M.singleton (contractResult c) result) condition
              checked = normalizeCalls (M.keys scope ++ S.toList (usedVariables branchFacts)) substituted
          _ <- walk signatures contractTable (proofId d) scope branchFacts checked
          unless (provesResult signatures contractTable scope branchFacts checked)
            (Left "definition result refinement could not be proved")
  where
    diagnostic at = either (Left . pure . (\message -> Diagnostic "total" message at)) Right
    prefix name = either (Left . ((name ++ ": ") ++)) Right

-- These facts come from validated argument types, not executable user
-- preconditions. Callers need not restate a primitive's range in a signature.
integerAssumptions :: Int -> Id -> String -> [Proof]
integerAssumptions bits name primitive = case integerBounds bits primitive of
  Just (lo,hi) -> [bound GreaterEqual lo,bound LessEqual hi]
  Nothing | primitive == "BigUInt" -> [bound GreaterEqual 0]
          | otherwise -> []
  where bound op value = ExactComparison op (Variable name) (Literal (SInteger "Integer" value))

-- Integer-to-integer conversions need range evidence but never a fractional
-- check. Exact fractions and IEEE inputs must keep their separate obligations.
integerConversion :: Int -> String -> String -> Proof -> Maybe Proof
integerConversion bits target source value
  | not (isInteger source && isInteger target) = Nothing
  | Just (lo,hi) <- integerBounds bits target = Just (NarrowInteger (Just lo) (Just hi) value)
  | target == "BigUInt" = Just (NarrowInteger (Just 0) Nothing value)
  | target `elem` ["Integer","BigInt"] = Just (NarrowInteger Nothing Nothing value)
  | otherwise = Nothing

children :: Proof -> [Proof]
children expression = case expression of
  ListNil -> []
  ListCons first rest -> [first,rest]
  Construct _ fields -> fields
  DataMatch value branches -> value : [body | (_,_,body) <- branches]
  Literal _ -> []
  Variable _ -> []
  Sequence values -> values
  Call _ arguments -> arguments
  LetCall _ _ arguments body -> arguments ++ [body]
  AllElements value _ body -> [value,body]
  AllPayloads _ _ value predicates -> value : map snd predicates
  ListMatch value nil _ _ cons -> [value,nil,cons]
  Match value branches -> value : map snd branches
  Logical _ a b -> [a,b]
  Negated value -> [value]
  Comparison _ a b -> [a,b]
  ExactComparison _ a b -> [a,b]
  ExactArithmetic _ a b -> [a,b]
  Division _ a b -> [a,b]
  Conversion _ value -> [value]
  NarrowInteger _ _ value -> [value]
  Integral value -> [value]
  TypedDomain facts value -> facts ++ [value]
  IsPresent value -> [value]
  PresentValue value -> [value]

constructorReferences :: Proof -> [Id]
-- Traversal itself inspects stored fields, without borrowing their constructor
-- invariants. Callback matches and constructions do borrow invariants and must
-- remain dependency edges, including when nested under a payload quantifier.
constructorReferences expression = local ++ concatMap constructorReferences (children expression)
  where local = case expression of
          Construct tag _ -> [tag]
          DataMatch _ branches -> [tag | (tag,_,_) <- branches]
          _ -> []

calls :: Proof -> [Id]
calls expression = case expression of
  Call identity arguments -> identity : concatMap calls arguments
  LetCall _ identity arguments body -> identity : concatMap calls (body:arguments)
  _ -> concatMap calls (children expression)

type Provenance = M.Map Id (Int, Bool)
data Facts = Facts
  { nonzero :: S.Set Id, present :: S.Set Id, constraints :: [R.Predicate]
  , universal :: [(Proof,Id,Proof)], truths :: [Proof], usedVariables :: S.Set Id
  , payloads :: [(P.Schema,String,Proof,[(Id,Proof)])]
  , presenceConditions :: [(Proof,Proof)]
  , constructorValues :: M.Map Id (Id,[Proof])
  , constructorPredicates :: [(Id,Id,[Id],Proof)]
  , constructorContracts :: M.Map Id ProofConstructorContract
  , emptyLists :: S.Set Id
  -- Single-argument definitions that match on their argument. A call whose
  -- argument has a known constructor equals the selected branch (unfolding).
  , unfoldings :: M.Map Id (Id,[(Id,[Id],Proof)])
  -- Definitions whose every branch is a non-negative constant plus calls of
  -- the same definition: their results are natural numbers (index measures).
  , naturalMeasures :: S.Set Id
  }
emptyFacts :: Facts
emptyFacts = Facts S.empty S.empty [] [] [] S.empty [] [] M.empty [] M.empty S.empty M.empty S.empty

walk :: M.Map Id [Id] -> M.Map Id ProofContract -> Id -> Provenance -> Facts -> Proof -> Either String [S.Set Int]
walk signatures contracts self provenance facts expression = case expression of
  Construct tag fields -> do
    nested <- concat <$> mapM recur fields
    forM_ (M.lookup tag (constructorContracts facts)) $ \contract -> do
      unless (length fields == length (constructorParameters contract))
        (Left "constructor contract arity mismatch")
      _ <- foldM (\known condition -> do
        unless (provesResult signatures contracts provenance known condition)
          (Left ("constructor field refinement could not be proved: " ++ idText tag))
        pure (assume True condition known)) facts (instantiateConstructor contract fields)
      pure ()
    pure nested
  LetCall result callee arguments body -> do
    unless (result `M.notMember` provenance && result `S.notMember` usedVariables facts)
      (Left "call result binder must be fresh")
    before <- recur (Call callee arguments)
    let known = callResultFacts signatures contracts facts result callee arguments
    after <- walk signatures contracts self (M.delete result provenance) known body
    pure (before ++ after)
  TypedDomain domains body -> do
    scoped <- foldM (\current domain -> do
      _ <- walk signatures contracts self provenance current domain
      pure (assume True domain current)) facts domains
    walk signatures contracts self provenance scoped body
  AllPayloads schema name value predicates -> do
    count <- P.arity schema name
    unless (count == length predicates && length predicates == length (nub (map fst predicates)))
      (Left "invalid payload predicate arity or binders")
    before <- recur value
    positions <- P.storedParameters schema name
    after <- concat <$> mapM (\index -> do
      let (binder,body) = predicates !! index
          (fresh,renamed) = freshElement (M.keys provenance) facts value binder body
          scoped = payloadMemberFacts facts schema name value index fresh
      walk signatures contracts self (branchProvenance provenance value [fresh]) scoped renamed) positions
    pure (before ++ after)
  AllElements value _ _ | knownEmpty facts value -> pure []
  AllElements value binder body -> do
    before <- recur value
    let (fresh,renamed) = freshElement (M.keys provenance) facts value binder body
        scoped = elementFacts facts value fresh
    after <- walk signatures contracts self
      (branchProvenance provenance value [fresh]) scoped renamed
    pure (before ++ after)
  ListMatch value nil headName tailName cons -> do
    unless (headName /= tailName) (Left "duplicate List pattern binder")
    before <- recur value
    empty <- walk signatures contracts self provenance (nilFacts facts value) nil
    let (headFresh,tailFresh,renamed) = freshListPattern (M.keys provenance) facts value headName tailName cons
        scoped = consFacts facts value headFresh tailFresh
    nonempty <- walk signatures contracts self
      (branchProvenance provenance value [headFresh,tailFresh]) scoped renamed
    pure (before ++ empty ++ nonempty)
  DataMatch value branches -> do
    unless (not (null branches) && length branches == length (nub [tag | (tag,_,_) <- branches]))
      (Left "invalid constructor match alternatives")
    forM_ branches $ \(tag,binders,_) -> do
      unless (length binders == length (nub binders))
        (Left "duplicate constructor pattern binder")
      forM_ (M.lookup tag (constructorContracts facts)) $ \contract ->
        unless (length binders == length (constructorParameters contract))
          (Left "constructor pattern contract arity mismatch")
    before <- recur value
    let choices = dataBranches provenance facts value branches
    unless (not (null choices)) (Left "known constructor has no matching branch")
    after <- concat <$> mapM (\(scope,known,body) -> walk signatures contracts self scope known body) choices
    pure (before ++ after)
  Match value branches -> do
    before <- recur value
    after <- concat <$> mapM (branch value) branches
    pure (before ++ after)
  Call callee arguments -> do
    nested <- concat <$> mapM recur arguments
    parameters <- maybe (Left "unknown definition call") Right (M.lookup callee signatures)
    unless (length parameters == length arguments) (Left "definition call arity mismatch")
    forM_ (M.lookup callee contracts) $ \contract ->
      forM_ (preconditions contract) $ \condition ->
        unless (entails facts (substituteProof (M.fromList (zip parameters arguments)) condition))
          (Left ("definition call precondition could not be proved: " ++ idText callee))
    let smaller index value = valueProvenance provenance value == Just (index, True)
        descending = S.fromList [index | (index,argument) <- zip [0..] arguments, smaller index argument]
    if callee /= self then pure nested
    else if S.null descending then Left "recursive call has no strict structural descent"
    else pure (descending : nested)
  Logical op left right -> do
    before <- recur left
    let skips = case left of Literal (SBool value) -> value /= (op == And); _ -> False
    after <- if skips then pure [] else walk signatures contracts self provenance (assume (op == And) left facts) right
    pure (before ++ after)
  Division ieee left denominator -> do
    unless (ieee || knownNonzero facts denominator)
      (Left "exact division/quotient/remainder requires a proven nonzero denominator")
    (++) <$> recur left <*> recur denominator
  Conversion total value -> do
    unless total (Left "conversion may fail for values in the declared domain")
    recur value
  NarrowInteger lower upper value -> do
    before <- recur value
    let bound op n = entails facts (ExactComparison op value (Literal (SInteger "Integer" n)))
    unless (maybe True (bound GreaterEqual) lower && maybe True (bound LessEqual) upper)
      (Left "integer conversion range could not be proved")
    pure before
  PresentValue value -> do
    unless (knownPresent facts value) (Left "presentValue requires proven presence")
    recur value
  _ -> concat <$> mapM recur (children expression)
  where
    recur = walk signatures contracts self provenance facts
    branch value (binders, body) =
      walk signatures contracts self (branchProvenance provenance value binders) facts body

-- Guard auditing precedes call auditing, so a presentValue projection is a
-- genuine strict subterm. Results of calls still have no argument provenance.
valueProvenance :: Provenance -> Proof -> Maybe (Int,Bool)
valueProvenance scope value = case value of
  Variable name -> M.lookup name scope
  Integral inner -> valueProvenance scope inner
  PresentValue inner -> (\(index,_) -> (index,True)) <$> valueProvenance scope inner
  _ -> Nothing

branchProvenance :: Provenance -> Proof -> [Id] -> Provenance
branchProvenance provenance value binders = foldl extend provenance binders
  where
    source = valueProvenance provenance value
    extend scope name = case source of
      Just (index, _) -> M.insert name (index, True) scope
      Nothing -> M.delete name scope

-- The body has already passed definedness and termination auditing. Enumerate
-- its explicit result branches for postconditions without pretending that a
-- match is an affine expression, or losing the domains of its bound fields.
resultCases :: M.Map Id [Id] -> M.Map Id ProofContract -> Provenance -> Facts -> Proof -> [(Provenance,Facts,Proof)]
resultCases signatures contracts scope facts expression = case expression of
  LetCall result callee arguments body ->
    recur (M.delete result scope) (callResultFacts signatures contracts facts result callee arguments) body
  ListMatch value nil headName tailName cons ->
    let (headFresh,tailFresh,renamed) = freshListPattern (M.keys scope) facts value headName tailName cons
    in recur scope (nilFacts facts value) nil ++
       recur (branchProvenance scope value [headFresh,tailFresh])
         (consFacts facts value headFresh tailFresh) renamed
  DataMatch value branches -> concat
    [recur local known body | (local,known,body) <- dataBranches scope facts value branches]
  Match value branches -> concat
    [recur (branchProvenance scope value binders) facts body | (binders,body) <- branches]
  TypedDomain domains body -> recur scope (foldl (flip (assume True)) facts domains) body
  Integral body -> [(s,f,Integral value) | (s,f,value) <- recur scope facts body]
  Logical op left right -> concat
    [ (s,assume (op /= And) value known,Literal (SBool (op /= And))) :
        recur s (assume (op == And) value known) right
    | (s,known,value) <- recur scope facts left]
  _ -> [(scope,facts,expression)]
  where recur = resultCases signatures contracts

-- Definedness has already been audited. Each result branch supplies only the
-- guarantees of calls evaluated in that branch. Universal predicates introduce
-- a hypothetical member, without claiming that the List is inhabited.
provesResult :: M.Map Id [Id] -> M.Map Id ProofContract -> Provenance -> Facts -> Proof -> Bool
provesResult signatures contracts scope facts expression =
  all prove (resultCases signatures contracts scope facts expression)
  where
    prove (local,known,value) = case value of
      AllPayloads schema name source predicates ->
        provePayload (\facts body -> provesResult signatures contracts local facts body)
          (M.keys local) known schema name source predicates
      AllElements list _ _ | knownEmpty known list -> True
      AllElements (ListCons first rest) binder body ->
        provesResult signatures contracts local known
          (substituteProof (M.singleton binder first) body) &&
        provesResult signatures contracts local known (AllElements rest binder body)
      AllElements list binder body ->
        let (fresh,renamed) = freshElement (M.keys local) known list binder body
        in provesResult signatures contracts local (elementFacts known list fresh) renamed
      _ -> entails known value

instantiateConstructor :: ProofConstructorContract -> [Proof] -> [Proof]
instantiateConstructor contract fields =
  map (substituteProof (M.fromList (zip (constructorParameters contract) fields)))
    (constructorConditions contract)

constructorFacts :: Facts -> Id -> [Proof] -> Facts
constructorFacts facts tag fields = case M.lookup tag (constructorContracts facts) of
  Just contract | length fields == length (constructorParameters contract) ->
    foldl (flip (assume True)) facts (instantiateConstructor contract fields)
  _ -> facts

-- Bind only fields of the selected constructor. Stored refinement matches are
-- instantiated with fresh branch binders and remain local to this alternative.
dataBranches :: Provenance -> Facts -> Proof -> [(Id,[Id],Proof)] -> [(Provenance,Facts,Proof)]
dataBranches scope facts value branches = case known of
  Just (tag,fields) ->
    [(scope,payloadConstructorFacts (constructorFacts facts tag fields) value tag fields,substituteProof (M.fromList (zip binders fields)) body)
      | (candidate,binders,body) <- branches, candidate == tag, length fields == length binders]
  Nothing -> map unknown branches
  where
    known = case value of
      Construct tag fields -> Just (tag,fields)
      _ -> variableIdentity value >>= (`M.lookup` constructorValues facts)
    unknown (tag,binders,body) =
      let allocate (fresh,aliases,taken) binder =
            let (name,_) = freshElement taken facts value binder body
            in (fresh ++ [name],M.insert binder (Variable name) aliases,name:taken)
          (names,aliases,_) = foldl allocate ([],M.empty,binders ++ M.keys scope) binders
          renamed = substituteProof aliases body
          fields = map Variable names
          local = branchProvenance scope value names
          selected = case variableIdentity value of
            Just identity -> facts{constructorValues=M.insert identity (tag,fields) (constructorValues facts)}
            Nothing -> facts
          tracked = selected{usedVariables=S.union (S.fromList names) (usedVariables selected)}
          conditions = [substituteProof (M.fromList (zip parameters fields)) predicate
            | (identity,candidate,parameters,predicate) <- constructorPredicates facts,
              Just identity == variableIdentity value, candidate == tag, length parameters == length fields]
      in (local,foldl (flip (assume True)) (payloadConstructorFacts (constructorFacts tracked tag fields) value tag fields) conditions,renamed)

knownNonzero :: Facts -> Proof -> Bool
knownNonzero facts expression = direct || case linear expression of
  Just value -> R.prove 10000 (constraints facts) (R.Compare R.NotEqualTo value (R.constant 0)) == R.Proven
  Nothing -> False
  where
    direct = case expression of
      Integral value -> knownNonzero facts value
      Variable name -> name `S.member` nonzero facts
      Literal scalar -> either (const False) (/= 0) (exactValue scalar)
      _ -> False

knownPresent :: Facts -> Proof -> Bool
knownPresent facts expression =
  (faithful expression && IsPresent expression `elem` truths facts) || case expression of
    Variable name -> name `S.member` present facts
    Literal (SPresent _ (Just _)) -> True
    _ -> False

assume :: Bool -> Proof -> Facts -> Facts
assume truth expression facts =
  let tracked = facts{usedVariables=S.union (usedVariables facts) (S.fromList (allVariables expression))}
      remembered = if truth && faithful expression
        then tracked{truths=nub (expression : truths tracked)} else tracked
      result = assumeSimple truth expression remembered
      constrained = case predicate expression of
        Just p -> result{constraints=nub ((if truth then p else R.Not p) : constraints result)}
        Nothing -> result
  in activatePresence constrained

-- Presence guards are implications, not unconditional payload facts. Consume
-- each pending implication only after its exact subject is known present.
activatePresence :: Facts -> Facts
activatePresence facts =
  let active = [(value,body) | (value,body) <- presenceConditions facts, knownPresent facts value]
      pending = filter (`notElem` active) (presenceConditions facts)
  in foldl (flip (assume True)) facts{presenceConditions=pending} (map snd active)

assumeSimple :: Bool -> Proof -> Facts -> Facts
assumeSimple truth expression facts = case expression of
  DataMatch value branches | Just identity <- variableIdentity value ->
    facts{constructorPredicates=nub (constructorPredicates facts ++
      [(identity,tag,binders,if truth then body else Negated body) | (tag,binders,body) <- branches])}
  AllPayloads schema name value predicates | truth ->
    facts{payloads=nub ((schema,name,value,predicates) : payloads facts)}
  AllElements value binder body | truth ->
    facts{universal=nub ((value,binder,body) : universal facts)}
  TypedDomain domains body -> assume truth body (foldl (flip (assume True)) facts domains)
  Negated value -> assume (not truth) value facts
  Logical Or (Negated (IsPresent value)) body | truth ->
    facts{presenceConditions=nub ((value,body) : presenceConditions facts)}
  Logical Or body (Negated (IsPresent value)) | truth ->
    facts{presenceConditions=nub ((value,body) : presenceConditions facts)}
  Logical And left right | truth -> assume True right (assume True left facts)
  Logical Or left right | not truth -> assume False right (assume False left facts)
  IsPresent (Variable name) | truth -> facts { present = S.insert name (present facts) }
  ExactComparison op left right -> assumeSimple truth (Comparison op left right) facts
  Comparison op left right
    | (truth && op `elem` [NotEqual,Less,Greater]) ||
      (not truth && op `elem` [Equal,LessEqual,GreaterEqual]) ->
        case nonzeroVariable left right of
          Just name -> facts { nonzero = S.insert name (nonzero facts) }
          Nothing -> facts
  _ -> facts
  where
    nonzeroVariable (Variable name) (Literal scalar)
      | either (const False) (== 0) (exactValue scalar) = Just name
    nonzeroVariable left@(Literal _) right@(Variable _) = nonzeroVariable right left
    nonzeroVariable (Integral left) right = nonzeroVariable left right
    nonzeroVariable left (Integral right) = nonzeroVariable left right
    nonzeroVariable _ _ = Nothing

-- Only the exact arithmetic constructors enter rational proof normalization.
-- IEEE comparisons deliberately retain Comparison and cannot acquire rational
-- identities such as x - x = 0 or x == x in the presence of NaN/infinity.
linear :: Proof -> Maybe R.Linear
linear expression = case expression of
  Variable name -> Just (R.variable name)
  Literal scalar -> either (const Nothing) (Just . R.constant) (exactValue scalar)
  ExactArithmetic Add a b -> R.plus <$> linear a <*> linear b
  ExactArithmetic Subtract a b -> R.plus <$> linear a <*> (R.scale (-1) <$> linear b)
  -- A constant factor may carry its integer typing: Integral (Literal 2).
  ExactArithmetic Multiply a b
    | Just coefficient <- constantFactor a -> R.scale coefficient <$> linear b
    | Just coefficient <- constantFactor b -> R.scale coefficient <$> linear a
  NarrowInteger _ _ value -> linear value
  Integral value -> linear value
  Call callee arguments -> Just (R.variable (callAtom callee arguments))
  _ -> Nothing

constantFactor :: Proof -> Maybe Rational
constantFactor expression = case expression of
  Literal scalar -> either (const Nothing) Just (exactValue scalar)
  Integral value -> constantFactor value
  _ -> Nothing

predicate :: Proof -> Maybe R.Predicate
predicate expression = case expression of
  Literal (SBool value) -> Just (R.Truth value)
  Variable name -> Just (R.Atom name)
  ExactComparison op a b -> do
    relation <- lookup op [(Equal,R.EqualTo),(NotEqual,R.NotEqualTo),(Less,R.LessThan),
      (LessEqual,R.AtMost),(Greater,R.GreaterThan),(GreaterEqual,R.AtLeast)]
    (if integral a && integral b then R.IntegerCompare else R.Compare) relation <$> linear a <*> linear b
  Logical And a b -> R.All <$> mapM predicate [a,b]
  Logical Or a b -> R.Any <$> mapM predicate [a,b]
  Negated a -> R.Not <$> predicate a
  _ -> Nothing

integral :: Proof -> Bool
integral expression = case expression of
  Integral _ -> True
  NarrowInteger _ _ _ -> True
  Literal scalar -> either (const False) ((== 1) . denominator) (exactValue scalar)
  ExactArithmetic _ a b -> integral a && integral b
  _ -> False

variableIdentity :: Proof -> Maybe Id
variableIdentity (Variable name) = Just name
variableIdentity (Integral value) = variableIdentity value
variableIdentity _ = Nothing


entails :: Facts -> Proof -> Bool
entails facts expression
  | faithful expression && expression `elem` truths facts = True
  | otherwise = case expression of
    AllPayloads schema name value predicates ->
      provePayload entails [] facts schema name value predicates
    AllElements value _ _ | knownEmpty facts value -> True
    AllElements (ListCons first rest) binder body ->
      entails facts (substituteProof (M.singleton binder first) body) &&
        entails facts (AllElements rest binder body)
    AllElements value binder body ->
      let (fresh,renamed) = freshElement [] facts value binder body
      in entails (elementFacts facts value fresh) renamed
    DataMatch value branches -> all (\(_,known,body) -> entails known body)
      (dataBranches M.empty facts value branches)
    TypedDomain domains body -> entails (foldl (flip (assume True)) facts domains) body
    IsPresent value -> knownPresent facts value
    Logical And a b -> entails facts a && entails facts b
    _ -> case predicate expression of
      Just condition -> R.prove 10000 (constraints facts) condition == R.Proven
      Nothing -> False

freeVariables :: Proof -> [Id]
freeVariables expression = case expression of
  Variable name -> [name]
  LetCall result _ arguments body -> concatMap freeVariables arguments ++ filter (/= result) (freeVariables body)
  AllElements value binder body -> freeVariables value ++ filter (/= binder) (freeVariables body)
  AllPayloads _ _ value predicates -> freeVariables value ++ concat
    [filter (/= binder) (freeVariables body) | (binder,body) <- predicates]
  ListMatch value nil headName tailName cons -> freeVariables value ++ freeVariables nil ++
    filter (`notElem` [headName,tailName]) (freeVariables cons)
  DataMatch value branches -> freeVariables value ++ concat
    [[name | name <- freeVariables body, name `notElem` binders] | (_,binders,body) <- branches]
  Match value branches -> freeVariables value ++ concat
    [[name | name <- freeVariables body, name `notElem` binders] | (binders,body) <- branches]
  _ -> concatMap freeVariables (children expression)

-- Capture-avoiding substitution is required even though ordinary compiler IDs
-- are unique: independently supplied Core may reuse binder IDs across scopes.
substituteProof :: M.Map Id Proof -> Proof -> Proof
substituteProof replacements expression = case expression of
  Variable name -> M.findWithDefault expression name replacements
  AllElements value binder body -> case branch ([binder],body) of
    ([renamed],result) -> AllElements (recur value) renamed result
    _ -> error "invalid universal binder substitution"
  AllPayloads schema name value predicates -> AllPayloads schema name (recur value)
    [(fresh,renamed) | (binder,body) <- predicates,
      let ([fresh],renamed) = branch ([binder],body)]
  ListMatch value nil headName tailName cons -> case branch ([headName,tailName],cons) of
    ([headFresh,tailFresh],body) -> ListMatch (recur value) (recur nil) headFresh tailFresh body
    _ -> error "invalid List pattern substitution"
  Construct tag fields -> Construct tag (map recur fields)
  DataMatch value branches -> DataMatch (recur value)
    [(tag,names,body') | (tag,binders,body) <- branches, let (names,body') = branch (binders,body)]
  Match value branches -> Match (recur value) (map branch branches)
  ListNil -> ListNil
  ListCons first rest -> ListCons (recur first) (recur rest)
  Literal _ -> expression
  Sequence values -> Sequence (map recur values)
  Call name values -> Call name (map recur values)
  LetCall result callee arguments body -> case branch ([result],body) of
    ([fresh],renamed) -> LetCall fresh callee (map recur arguments) renamed
    _ -> error "invalid call result substitution"
  Logical op a b -> Logical op (recur a) (recur b)
  Negated value -> Negated (recur value)
  Comparison op a b -> Comparison op (recur a) (recur b)
  ExactComparison op a b -> ExactComparison op (recur a) (recur b)
  ExactArithmetic op a b -> ExactArithmetic op (recur a) (recur b)
  Division ieee a b -> Division ieee (recur a) (recur b)
  Conversion total value -> Conversion total (recur value)
  NarrowInteger lower upper value -> NarrowInteger lower upper (recur value)
  Integral value -> Integral (recur value)
  TypedDomain domains value -> TypedDomain (map recur domains) (recur value)
  IsPresent value -> IsPresent (recur value)
  PresentValue value -> PresentValue (recur value)
  where
    recur = substituteProof replacements
    branch (binders,body) =
      let visible = foldr M.delete replacements binders
          captured = concatMap freeVariables (M.elems visible)
          used = S.fromList (allVariables body ++ binders ++ M.keys replacements ++
            concatMap allVariables (M.elems replacements))
          rename (names,aliases,taken) name
            | name `notElem` captured = (names ++ [name],aliases,taken)
            | otherwise =
                let fresh = head [Id (idText name ++ "::proof::" ++ show n) | n <- [0::Int ..],
                      Id (idText name ++ "::proof::" ++ show n) `S.notMember` taken]
                in (names ++ [fresh],M.insert name (Variable fresh) aliases,S.insert fresh taken)
          (names,aliases,_) = foldl rename ([],M.empty,used) binders
      in (names, substituteProof (M.union aliases visible) body)

allVariables :: Proof -> [Id]
allVariables term = case term of
  Variable name -> [name]
  LetCall result _ arguments body -> result : concatMap allVariables (body:arguments)
  AllElements value binder body -> allVariables value ++ binder : allVariables body
  AllPayloads _ _ value predicates -> allVariables value ++ concat
    [binder : allVariables body | (binder,body) <- predicates]
  ListMatch value nil headName tailName cons -> allVariables value ++ allVariables nil ++
    [headName,tailName] ++ allVariables cons
  DataMatch value branches -> allVariables value ++ concat
    [binders ++ allVariables body | (_,binders,body) <- branches]
  Match value branches -> allVariables value ++ concat
    [binders ++ allVariables body | (binders,body) <- branches]
  _ -> concatMap allVariables (children term)

-- A universal fact says nothing about an arbitrary outer value, nor that the
-- list is inhabited. Instantiate it only while proving a property of a fresh,
-- hypothetical member of that exact list variable.
freshElement :: [Id] -> Facts -> Proof -> Id -> Proof -> (Id,Proof)
freshElement scope facts value binder body =
  let used = S.unions [usedVariables facts,S.fromList (scope ++ allVariables value ++ allVariables body)]
      fresh = head [Id (idText binder ++ "::member::" ++ show n) | n <- [0::Int ..],
        Id (idText binder ++ "::member::" ++ show n) `S.notMember` used]
  in (fresh,substituteProof (M.singleton binder (Variable fresh)) body)

elementFacts :: Facts -> Proof -> Id -> Facts
elementFacts facts value member = foldl (flip (assume True)) facts
  [substituteProof (M.singleton binder (Variable member)) body
    | (source,binder,body) <- universal facts,
      Just identity <- [variableIdentity value], variableIdentity source == Just identity]

-- Only remember Boolean expressions whose proof view preserves their identity.
-- Sequence/Match/Division are deliberately excluded: the proof extraction
-- erases runtime distinctions there (e.g. quotient versus exact division).
faithful :: Proof -> Bool
faithful expression = case expression of
  ListNil -> True
  ListCons first rest -> faithful first && faithful rest
  Literal _ -> True
  Variable _ -> True
  Construct _ fields -> all faithful fields
  Call _ arguments -> all faithful arguments
  Logical _ a b -> faithful a && faithful b
  Negated value -> faithful value
  Comparison _ a b -> faithful a && faithful b
  ExactComparison _ a b -> faithful a && faithful b
  ExactArithmetic _ a b -> faithful a && faithful b
  Integral value -> faithful value
  IsPresent value -> faithful value
  PresentValue value -> faithful value
  _ -> False


freshListPattern :: [Id] -> Facts -> Proof -> Id -> Id -> Proof -> (Id,Id,Proof)
freshListPattern scope facts value headName tailName body =
  let bound = headName : tailName : scope
      (headFresh,withHead) = freshElement bound facts value headName body
      (tailFresh,renamed) = freshElement (headFresh:bound) facts value tailName withHead
  in (headFresh,tailFresh,renamed)

knownEmpty :: Facts -> Proof -> Bool
knownEmpty facts value = case value of
  ListNil -> True
  Variable name -> name `S.member` emptyLists facts
  _ -> False

nilFacts :: Facts -> Proof -> Facts
nilFacts facts value = case variableIdentity value of
  Just name -> facts{emptyLists=S.insert name (emptyLists facts),
    usedVariables=S.insert name (usedVariables facts)}
  Nothing -> facts

consFacts :: Facts -> Proof -> Id -> Id -> Facts
consFacts facts value headName tailName = foldl (flip (assume True))
  (elementFacts facts value headName)
  [AllElements (Variable tailName) binder body
    | (source,binder,body) <- universal facts,
      Just identity <- [variableIdentity value], variableIdentity source == Just identity]


-- Calls are evaluated before the enclosing strict operation. Branch-local and
-- short-circuited calls stay in their branch. This is a proof-only A-normal form:
-- it neither rewrites executable Core nor assumes a callee's postconditions.
normalizeCalls :: [Id] -> Proof -> Proof
normalizeCalls scope expression = evalState (go expression pure)
  (0,S.fromList (scope ++ allVariables expression))
  where
    fresh :: State (Int,S.Set Id) Id
    fresh = do
      (next,used) <- get
      let choices = [(n,Id ("::call-result::" ++ show n)) | n <- [next..]]
          (index,name) = head [(n,name) | (n,name) <- choices, name `S.notMember` used]
      put (index + 1,S.insert name used)
      pure name
    values [] continuation = continuation []
    values (first:rest) continuation = go first $ \value ->
      values rest (continuation . (value:))
    pair constructor left right continuation = go left $ \a -> go right $ \b -> continuation (constructor a b)
    go term continuation = case term of
      Call callee arguments -> values arguments $ \arguments' -> do
        name <- fresh
        body <- continuation (Variable name)
        pure (LetCall name callee arguments' body)
      LetCall name callee arguments body -> values arguments $ \arguments' -> do
        body' <- go body pure
        continuation (LetCall name callee arguments' body')
      Construct tag fields -> values fields (continuation . Construct tag)
      DataMatch value branches -> go value $ \value' -> do
        branches' <- mapM (\(tag,binders,body) -> (\body' -> (tag,binders,body')) <$> go body pure) branches
        continuation (DataMatch value' branches')
      Match value branches -> go value $ \value' -> do
        branches' <- mapM (\(binders,body) -> (,) binders <$> go body pure) branches
        continuation (Match value' branches')
      ListMatch value nil first rest cons -> go value $ \value' -> do
        nil' <- go nil pure
        cons' <- go cons pure
        continuation (ListMatch value' nil' first rest cons')
      AllPayloads schema name value predicates -> go value $ \value' -> do
        predicates' <- mapM (\(binder,body) -> (,) binder <$> go body pure) predicates
        continuation (AllPayloads schema name value' predicates')
      AllElements value binder body -> go value $ \value' -> do
        body' <- go body pure
        continuation (AllElements value' binder body')
      Logical op left right -> go left $ \left' -> do
        right' <- go right pure
        continuation (Logical op left' right')
      TypedDomain domains body -> do
        domains' <- mapM (\value -> go value pure) domains
        body' <- go body pure
        continuation (TypedDomain domains' body')
      Sequence terms -> values terms (continuation . Sequence)
      ListCons first rest -> pair ListCons first rest continuation
      Comparison op a b -> pair (Comparison op) a b continuation
      ExactComparison op a b -> pair (ExactComparison op) a b continuation
      ExactArithmetic op a b -> pair (ExactArithmetic op) a b continuation
      Division ieee a b -> pair (Division ieee) a b continuation
      Negated value -> go value (continuation . Negated)
      Conversion total value -> go value (continuation . Conversion total)
      NarrowInteger lo hi value -> go value (continuation . NarrowInteger lo hi)
      Integral value -> go value (continuation . Integral)
      IsPresent value -> go value (continuation . IsPresent)
      PresentValue value -> go value (continuation . PresentValue)
      _ -> continuation term

-- Only walk's successful call case may make these guarantees available. A
-- recursive call has already proved strict descent, so this is induction on
-- the same structural measure checked for the entire definition. The new result
-- never inherits argument provenance: an arbitrary returned List is not a
-- structural subterm merely because its producer took one as input.
callResultFacts :: M.Map Id [Id] -> M.Map Id ProofContract -> Facts -> Id -> Id -> [Proof] -> Facts
callResultFacts signatures contracts facts result callee arguments =
  let parameters = M.findWithDefault [] callee signatures
      substitutions = M.fromList (zip parameters arguments)
      guarantees = case M.lookup callee contracts of
        Nothing -> []
        Just contract -> map (substituteProof
          (M.insert (contractResult contract) (Variable result) substitutions)) (postconditions contract)
      existing = Call callee arguments
      remembered | entails facts existing = assume True (Variable result) facts
                 | entails facts (Negated existing) = assume False (Variable result) facts
                 | otherwise = facts
      initial = remembered{usedVariables=S.insert result (usedVariables remembered)}
      -- Checked definitions are pure: equal calls have equal results, and a call
      -- on a known constructor equals the selected branch of its definition.
      equal value = ExactComparison Equal (Variable result) value
      evidence = equal existing : [equal unfolded | Just unfolded <- [unfold facts callee arguments]] ++
        [ExactComparison GreaterEqual (Variable result) (Literal (SInteger "Integer" 0))
          | callee `S.member` naturalMeasures facts]
  in foldl (flip (assume True)) initial (map (expandKnown facts) guarantees ++ evidence)

-- Expanding is bounded by the finite constructor terms and known constructor
-- values it follows; each step removes one known constructor from an argument.
unfold :: Facts -> Id -> [Proof] -> Maybe Proof
unfold facts callee arguments = do
  (parameter,branches) <- M.lookup callee (unfoldings facts)
  [argument] <- pure arguments
  (tag,fields) <- case argument of
    Construct tag fields -> Just (tag,fields)
    _ -> variableIdentity argument >>= (`M.lookup` constructorValues facts)
  (binders,body) <- case [(binders,body) | (candidate,binders,body) <- branches, candidate == tag] of
    found:_ -> Just found
    [] -> Nothing
  if length binders /= length fields then Nothing
  else Just (expandKnown facts (substituteProof (M.fromList ((parameter,argument) : zip binders fields)) (stripDomains body)))

-- Replace calls on known constructors by their unfolded branches, through the
-- arithmetic and logic that the linear prover reads.
expandKnown :: Facts -> Proof -> Proof
expandKnown facts term = case term of
  Call name values | Just unfolded <- unfold facts name (map expand values) -> unfolded
  Call name values -> Call name (map expand values)
  ExactArithmetic op a b -> ExactArithmetic op (expand a) (expand b)
  ExactComparison op a b -> ExactComparison op (expand a) (expand b)
  Logical op a b -> Logical op (expand a) (expand b)
  Negated value -> Negated (expand value)
  NarrowInteger lower upper value -> NarrowInteger lower upper (expand value)
  Integral value -> Integral (expand value)
  Conversion total value -> Conversion total (expand value)
  _ -> term
  where expand = expandKnown facts

-- Proof bodies carry typed domains and integral evidence around the match.
-- Neither changes the value, so both are transparent when unfolding.
stripDomains :: Proof -> Proof
stripDomains (TypedDomain _ body) = stripDomains body
stripDomains (Integral body) = stripDomains body
stripDomains body = body

naturalBranch :: Id -> Proof -> Bool
naturalBranch self body = case stripDomains body of
  Literal scalar -> either (const False) (>= 0) (exactValue scalar)
  Call name _ -> name == self
  ExactArithmetic Add a b -> naturalBranch self a && naturalBranch self b
  NarrowInteger _ _ value -> naturalBranch self value
  Integral value -> naturalBranch self value
  Conversion _ value -> naturalBranch self value
  _ -> False

-- Calls of checked definitions are pure, so a call is a linear atom: equal
-- callee and arguments denote the same value in every fact.
callAtom :: Id -> [Proof] -> Id
callAtom callee arguments = Id ("::call::" ++ idText callee ++ show arguments)

-- Canonicalize every named step to one predicate per current type argument.
-- Composed recipes become scoped List/presence/named predicates, allowing a
-- growing recursive application to match its callee's ordinary contract.
payloadPredicate :: P.Schema -> P.Plan -> [(Id,Proof)] -> Proof -> Proof
payloadPredicate schema plan predicates value = case plan of
  P.Ignore -> Literal (SBool True)
  P.Parameter index -> case drop index predicates of
    (binder,body):_ | index >= 0 -> substituteProof (M.singleton binder value) body
    _ -> Conversion False (Sequence [])
  P.Applied "List" [element] ->
    let binder = fresh "element"
    in AllElements value binder (payloadPredicate schema element predicates (Variable binder))
  P.Applied name [element] | name `elem` ["Nullable","Optional"] ->
    Logical Or (Negated (IsPresent value))
      (payloadPredicate schema element predicates (PresentValue value))
  P.Applied name arguments -> AllPayloads schema name value
    [(binder,payloadPredicate schema argument predicates (Variable binder))
      | (index,argument) <- zip [0::Int ..] arguments, let binder = fresh (show index)]
  where
    used = allVariables value ++ concat [binder : allVariables body | (binder,body) <- predicates]
    fresh label = head [Id ("::payload::" ++ label ++ "::" ++ show n) | n <- [0::Int ..],
      Id ("::payload::" ++ label ++ "::" ++ show n) `notElem` used]

samePayloadSource :: Proof -> Proof -> Bool
samePayloadSource left right = case (variableIdentity left,variableIdentity right) of
  (Just a,Just b) -> a == b
  _ -> faithful left && left == right

payloadMemberFacts :: Facts -> P.Schema -> String -> Proof -> Int -> Id -> Facts
payloadMemberFacts facts schema name value index member = foldl (flip (assume True)) facts
  [substituteProof (M.singleton binder (Variable member)) body
    | (other,candidate,source,predicates) <- payloads facts,
      other == schema, candidate == name, samePayloadSource value source,
      (binder,body) <- take 1 (drop index predicates)]

payloadConditions :: P.Schema -> String -> Id -> [Proof] -> [(Id,Proof)]
  -> Either String [Proof]
payloadConditions schema name tag values predicates = do
  plans <- P.fields schema name tag (map P.Parameter [0 .. length predicates - 1])
  unless (length plans == length values) (Left "payload constructor field arity mismatch")
  pure (zipWith (\plan value -> payloadPredicate schema plan predicates value) plans values)

payloadConstructorFacts :: Facts -> Proof -> Id -> [Proof] -> Facts
payloadConstructorFacts facts value tag values = foldl (flip (assume True)) facts
  (concat [either (const []) id (payloadConditions schema name tag values predicates)
    | (schema,name,source,predicates) <- payloads facts, samePayloadSource value source])

provePayload :: (Facts -> Proof -> Bool) -> [Id] -> Facts -> P.Schema -> String
  -> Proof -> [(Id,Proof)] -> Bool
provePayload prove scope facts schema name value predicates =
  case P.arity schema name of
    Right count | count == length predicates -> case known of
      Just (tag,values) -> either (const False) (all (prove facts))
        (payloadConditions schema name tag values predicates)
      Nothing -> case P.storedParameters schema name of
        Left _ -> False
        Right positions -> all (\index ->
          let (binder,body) = predicates !! index
              (fresh,renamed) = freshElement scope facts value binder body
          in prove (payloadMemberFacts facts schema name value index fresh) renamed) positions
    _ -> False
  where
    known = case value of
      Construct tag values -> Just (tag,values)
      _ -> variableIdentity value >>= (`M.lookup` constructorValues facts)
