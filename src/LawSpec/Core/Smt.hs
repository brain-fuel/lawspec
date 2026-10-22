-- | Typed SMT-LIB tasks, with no solver or host IO in the compiler. The host
-- executes these tasks using an established prover. ref:DEC-typed-core-boundary
module LawSpec.Core.Smt (ProofTask(..), Encoding(..), Recursion(..), CounterexampleQuery(..), encodingName, proofTasks, taskFingerprint
  , alternativeFingerprint, recursionView, defaultFuel, proofTasksWith, LawProof(..), Unfolding(..), Induction(..)
  , defaultLawProof, InductionPlan(..), InductionCase(..), caseFingerprint
  , counterexampleFingerprint, outerQuantifiers, Catalog, catalog, instantiate, Ground(..), groundQuery) where

import Control.Monad (unless, when, foldM, forM, forM_)
import Control.Monad.State.Strict
import Data.Aeson (ToJSON(..), Value, object, (.=))
import qualified Data.Map.Strict as M
import Data.Graph (SCC(..), stronglyConnComp, flattenSCCs)
import Data.List (intercalate, isInfixOf, isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Binary as Binary
import LawSpec.Common (Diagnostic, InputDomain(..), Location, Quantification(..))
import LawSpec.Core
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Types (builtinDataDeclarations)
import LawSpec.CorePersist ()
import LawSpec.Digest (digest, digestHex, digestString)
import LawSpec.Scalar (Scalar(..), isInteger, integerBounds)

-- This is a task, never completed evidence. Hashes bind source identity, the
-- checked program, machine profile and exact query; execution adds its own
-- prover/version/configuration binding. No caller-supplied solver result is
-- admitted by this module.
data ProofTask = ProofTask
  { taskOwner :: Id, taskLaw :: Id, taskLocation :: Location
  , taskProgram :: String, taskBits :: Int, taskQuery :: Either String String
  , taskEncoding :: Encoding
  -- Asked of a ready task only after Z3 finds its negation satisfiable.
  , taskCounterexample :: Either String CounterexampleQuery
  -- How the task gives Z3 the recursive definitions it calls, if any; and
  -- the same law with the other encoding, tried when this one does not
  -- prove it. ref:DEC-smt-recursive-definitions
  , taskRecursion :: Maybe Recursion
  , taskAlternative :: Maybe (Recursion, String)
  -- Induction on one input: a task per case, each with its own receipt.
  -- ref:DEC-smt-induction
  , taskInduction :: Maybe InductionPlan
  } deriving (Eq, Show)

-- | How lawspec prove proves a law, from its harness (LawSpec.ProofSettings):
-- the encoding of recursive definitions, and induction.
data LawProof = LawProof { proofUnfolding :: Unfolding, proofInduction :: Induction } deriving (Eq, Show)

-- | prove by unfolding step by step [up to n times] (GuardedAxioms n),
-- prove by solver recursion (DefineFunRec), or both in turn: the default.
data Unfolding = Unfold Int | SolverRecursion | UnfoldThenSolver Int deriving (Eq, Show)

-- | When nothing is said, one try on the law's single structural input;
-- or none; or on a named input, citing proved laws as lemmas.
data Induction = DefaultInduction | NoInduction | InductionOn String [Id] deriving (Eq, Show)

defaultLawProof :: LawProof
defaultLawProof = LawProof (UnfoldThenSolver defaultFuel) DefaultInduction

-- | Induction on one of the law's inputs: whether the harness asked for it
-- (else it is the default try), the cited laws, and the cases, each a
-- task whose inputs are the law's, so a model is checked as the law's
-- counterexample.
data InductionPlan = InductionPlan
  { inductionOn :: String, inductionAsked :: Bool, inductionLemmas :: [Id]
  , inductionCases :: Either String [InductionCase] } deriving (Eq, Show)

-- | A case, in the law's first encoding, and in the other one when the law
-- tries both (as for the law itself).
data InductionCase = InductionCase
  { caseName :: String, caseScript :: String, caseInputs :: [String]
  , caseRecursion :: Recursion, caseAlternative :: Maybe (Recursion, String) }
  deriving (Eq, Show)

-- | How recursive definitions reach Z3 (lawspec-smtlib-v2):
--
-- * GuardedAxioms fuel: as Why3's eliminate_recursion, each definition is a
--   declared function with a defining axiom, guarded by its argument
--   domains and preconditions, so it says nothing where termination was not
--   proved. As in Dafny, the functions take a fuel argument: the axiom
--   unfolds f at fuel n+1 into its body at fuel n, a call in the law starts
--   at the given fuel, and fuel 0 is left uninterpreted. Unfolding is
--   bounded and reproducible.
-- * DefineFunRec: SMT-LIB define-funs-rec, the same guarded body, unfolded
--   by Z3 itself. It is sound because admission proved that each definition
--   terminates on its domain; outside the guard the function is an
--   unconstrained declared one.
data Recursion = GuardedAxioms Int | DefineFunRec deriving (Eq, Show)

-- | Dafny's default: a call in the law unfolds twice.
defaultFuel :: Int
defaultFuel = 2

recursionView :: Recursion -> Value
recursionView (GuardedAxioms fuel) = object ["encoding" .= ("guarded-axioms" :: String), "fuel" .= fuel]
recursionView DefineFunRec = object ["encoding" .= ("define-fun-rec" :: String)]

-- | A satisfiable task's model is not a counterexample. The counterexample
-- query declares the law's outer universal inputs as constants and asserts
-- that the rest of the law is not established for them, so the host can ask
-- Z3 for exactly their values with get-value. The compiler then re-checks
-- those values with the reference evaluator (LawSpec.Core.Counterexample).
-- It is always lawspec-smtlib-v2; the v1 task beside it is unchanged.
-- ref:DEC-validated-counterexamples
data CounterexampleQuery = CounterexampleQuery
  { counterexampleInputs :: [(String, Quantifier)], counterexampleScript :: String
  } deriving (Eq, Show)

-- | Each encoding is frozen once released. A task that lawspec-smtlib-v1
-- supports keeps its script and fingerprint byte for byte, so an existing
-- receipt stays current with no re-run; test/fixtures/smt-v1 holds the
-- frozen corpus that checks it. A task needing anything v1 lacks is
-- lawspec-smtlib-v2: the encoder calls `requires SmtLibV2` where it uses a
-- new feature. ref:DEC-smtlib-encoding-versions
data Encoding = SmtLibV1 | SmtLibV2 deriving (Eq, Ord, Show, Enum, Bounded)

encodingName :: Encoding -> String
encodingName SmtLibV1 = "lawspec-smtlib-v1"
encodingName SmtLibV2 = "lawspec-smtlib-v2"

instance ToJSON ProofTask where
  toJSON task = object $
    ["encoding" .= encodingName (taskEncoding task), "owner" .= idText (taskOwner task),
     "declaration" .= idText (taskLaw task), "at" .= taskLocation task,
     "programFingerprint" .= taskProgram task, "machineBits" .= taskBits task] ++
    case taskQuery task of
      Left reason -> ["status" .= ("unsupported"::String), "reason" .= reason]
      Right script -> ["status" .= ("ready"::String), "script" .= script,
        "taskFingerprint" .= taskFingerprint task,
        "trust" .= ("typed LawSpec translation and the selected SMT solver; no kernel-checked proof certificate"::String)] ++
        [ "counterexample" .= object
            [ "encoding" .= encodingName SmtLibV2, "script" .= counterexampleScript query
            , "fingerprint" .= counterexampleFingerprint task query
            , "inputs" .= [object ["name" .= name, "binder" .= binderName (quantifiedBinder q)]
                          | (name, q) <- counterexampleInputs query] ]
        | Right query <- [taskCounterexample task] ] ++
        [ "counterexampleUnsupported" .= reason | Left reason <- [taskCounterexample task] ] ++
        [ "recursion" .= recursionView recursion | Just recursion <- [taskRecursion task] ] ++
        [ "alternative" .= object [ "recursion" .= recursionView recursion, "script" .= script
                                  , "taskFingerprint" .= alternativeFingerprint task script ]
        | Just (recursion, script) <- [taskAlternative task] ] ++
        [ "induction" .= object ([ "on" .= inductionOn plan, "asked" .= inductionAsked plan
                                 , "using" .= map idText (inductionLemmas plan) ] ++
            case inductionCases plan of
              Left reason -> ["status" .= ("unsupported" :: String), "reason" .= reason]
              Right cases -> ["status" .= ("ready" :: String), "cases" .=
                [ object ([ "case" .= caseName c, "script" .= caseScript c, "recursion" .= recursionView (caseRecursion c)
                          , "taskFingerprint" .= caseFingerprint task c, "inputs" .= caseInputs c ] ++
                          [ "alternative" .= object [ "recursion" .= recursionView mode, "script" .= script
                                                    , "taskFingerprint" .= alternativeFingerprint task script ]
                          | Just (mode, script) <- [caseAlternative c] ]) | c <- cases ]])
        | Just plan <- [taskInduction task] ]

taskFingerprint :: ProofTask -> String
taskFingerprint task = digestHex (digestString (concatMap frame
  [encodingName (taskEncoding task),taskProgram task,show (taskBits task),idText (taskOwner task),
   idText (taskLaw task),either id id (taskQuery task)]))
  where frame value = show (B.length (T.encodeUtf8 (T.pack value))) ++ ":" ++ value

-- | The alternative encoding's binding: the task's, with its script.
alternativeFingerprint :: ProofTask -> String -> String
alternativeFingerprint task script = taskFingerprint task{taskQuery = Right script}

-- | An induction case's binding: the task's, with the case's script.
caseFingerprint :: ProofTask -> InductionCase -> String
caseFingerprint task c = taskFingerprint task{taskQuery = Right (caseScript c)}

-- | The counterexample query's own binding, framed as a task's is.
counterexampleFingerprint :: ProofTask -> CounterexampleQuery -> String
counterexampleFingerprint task query = digestHex (digestString (concatMap frame
  [encodingName SmtLibV2,taskProgram task,show (taskBits task),idText (taskOwner task),
   idText (taskLaw task),counterexampleScript query]))
  where frame value = show (B.length (T.encodeUtf8 (T.pack value))) ++ ":" ++ value

proofTasks :: Program -> Either [Diagnostic] [ProofTask]
proofTasks = proofTasksWith M.empty

-- | Each law's tasks, proved as its harness says (defaultLawProof when it
-- says nothing).
proofTasksWith :: M.Map Id LawProof -> Program -> Either [Diagnostic] [ProofTask]
proofTasksWith settings program = do
  validateProgram program
  let fingerprint = digestHex (digest (BL.toStrict (Binary.encode program)))
      lawsById = M.fromList [(propertyId l, l) | u <- programUnits program, l <- unitProperties u]
  pure [ProofTask (unitId owner) (propertyId law) (propertyLocation law)
          fingerprint (programMachineBits program) (scriptOf <$> task)
          -- A refused task names v1, the encoding that refused it.
          (either (const SmtLibV1) encodingOf task)
          (either Left (const (counterexampleQuery program law)) task)
          (either (const Nothing) recursionOf task)
          (either (const Nothing) alternativeOf task)
          (either (const Nothing) (induction lawsById proof law . recursionOf) task)
       | owner <- programUnits program, law <- unitProperties owner
       , let proof = M.findWithDefault defaultLawProof (propertyId law) settings
             task = query program (proofUnfolding proof) law]
  where
    induction lawsById proof law recursion = case proofInduction proof of
      NoInduction -> Nothing
      InductionOn input lemmas -> Just (InductionPlan input True lemmas
        (both (proofUnfolding proof) law input [l | i <- lemmas, Just l <- [M.lookup i lawsById]]))
      -- One try, when the law calls a recursive definition and has a single
      -- input of a recursive data type.
      DefaultInduction -> case (recursion, structuralInputs program law) of
        (Just _, [input]) -> Just (InductionPlan input False [] (both (proofUnfolding proof) law input []))
        _ -> Nothing
    -- Each case in the law's encodings, in order.
    both unfolding law input lemmas = do
      let (first, second) = case unfolding of
            Unfold n -> (GuardedAxioms n, Nothing)
            SolverRecursion -> (DefineFunRec, Nothing)
            UnfoldThenSolver n -> (GuardedAxioms n, Just DefineFunRec)
      cases <- inductionTasks program first law input lemmas
      others <- traverse (\mode -> inductionTasks program mode law input lemmas) second
      pure [ c { caseRecursion = first, caseAlternative = (\(mode, os) -> (mode, caseScript (os !! i))) <$> ((,) <$> second <*> others) }
           | (i, c) <- zip [0 ..] cases ]
    encodingOf (e, _, _, _) = e
    scriptOf (_, script, _, _) = script
    recursionOf (_, _, r, _) = r
    alternativeOf (_, _, _, a) = a

-- | One assertion of a ground query: a proposition the query requires to be
-- established (true and defined), or not established.
data Ground = Established Proposition | NotEstablished Proposition

-- | A ground lawspec-smtlib-v2 query over named constants, for the law-set
-- analysis (Core.LawAnalysis): each constant is declared and kept in its
-- type's domain, and each assertion is encoded as a law's propositions are.
-- A model gives the constants' values, which the compiler then confirms
-- with the reference evaluator. It returns the script and the constants'
-- names, in order.
groundQuery :: Program -> String -> [Binder] -> [Ground] -> Either String (String, [String])
groundQuery program purpose binders assertions = do
  let bits = programMachineBits program
  ((rows, certificates, prelude), _) <- runStateT (do
      rows <- forM (zip [0 :: Int ..] binders) $ \(index, binder) -> do
        s <- quantifierSortOf program (binderType binder)
        let name = "lawspec_input_" ++ show index
        base <- lift (domain bits (binderType binder) name)
        pure (binder, name, s, base)
      let scope = M.fromList [(binderId binder, Term s name "true") | (binder, name, s, _) <- rows]
      certificates <- forM assertions $ \assertion -> case assertion of
        Established claim -> positive <$> proposition program [] scope claim
        NotEstablished claim -> no . positive <$> proposition program [] scope claim
      prelude <- datatypePreamble program
      functions <- gets recursiveText
      pure (rows, certificates, fst functions ++ prelude ++ snd functions)) (start SmtLibV2 program (GuardedAxioms defaultFuel))
  let script = "; " ++ encodingName SmtLibV2 ++ "; " ++ purpose ++ "\n" ++ prelude ++
        concat ["(declare-const " ++ name ++ " " ++ sortText s ++ ")\n" | (_, name, s, _) <- rows] ++
        concat ["(assert " ++ base ++ ")\n" | (_, _, _, base) <- rows] ++
        concat ["(assert " ++ certificate ++ ")\n" | certificate <- certificates]
  unless (length (take 1048577 script) <= 1048576) (Left "SMT query exceeds its output budget")
  pure (script, [name | (_, name, _, _) <- rows])

-- | A law's outer universal inputs, in order: its parameters, its inputs and
-- the universal quantifiers that open its body; and the rest of the body.
outerQuantifiers :: Property -> ([Quantifier], Proposition)
outerQuantifiers law = peel (propertyParameters law ++ propertyInputs law) (propertyBody law)
  where
    peel found (Quantified ForEvery q body) = peel (found ++ [q]) body
    peel found body = (found, body)

counterexampleQuery :: Program -> Property -> Either String CounterexampleQuery
counterexampleQuery program law = do
  let (outer, rest) = outerQuantifiers law
      bits = programMachineBits program
      constant (scope, rows) (index, q) = do
        let binder = quantifiedBinder q
            name = "lawspec_input_" ++ show (index :: Int)
        s <- quantifierSortOf program (binderType binder)
        let local = M.insert (binderId binder) (Term s name "true") scope
        base <- lift (domain bits (binderType binder) name)
        restricted <- restrictions program [] local (quantifiedPredicates q)
        pure (local, rows ++ [(name, q, s, both [base, positive restricted])])
  ((rows, result, prelude), _) <- runStateT (do
      (scope, rows) <- foldM constant (M.empty, []) (zip [0 ..] outer)
      result <- proposition program [] scope rest
      prelude <- datatypePreamble program
      functions <- gets recursiveText
      -- Z3 unfolds recursive definitions itself here, and searches for a
      -- model freely; the evaluator checks whatever it gives.
      pure (rows, result, fst functions ++ prelude ++ snd functions)) ((start SmtLibV2 program DefineFunRec){bounded = False, ranges = False})
  let script = "; " ++ encodingName SmtLibV2 ++ "; counterexample: the law's outer inputs as constants\n" ++ prelude ++
        concat ["(declare-const " ++ name ++ " " ++ sortText s ++ ")\n" | (name, _, s, _) <- rows] ++
        concat ["(assert " ++ condition ++ ")\n" | (_, _, _, condition) <- rows] ++
        "(assert " ++ no (positive result) ++ ")\n"
  unless (length (take 1048577 script) <= 1048576) (Left "SMT query exceeds its output budget")
  pure (CounterexampleQuery [(name, q) | (name, q, _, _) <- rows] script)

-- | A data type is its own SMT sort (lawspec-smtlib-v2): a closed instance,
-- such as Maybe Int32, declared with its constructors and selectors.
data Sort = BooleanSort | IntegerSort | RealSort | UnitSort | DataSort Type deriving (Eq,Show)
data Term = Term { termSort :: Sort, value :: String, defined :: String }
data Certificate = Certificate { positive :: String, negative :: String }
-- The encoding a task needs so far: the newest any feature it uses requires.
-- The data types it declares, in the order first used, and the program's
-- data declarations by name.
data Work = Work { nextName :: Int, visited :: Int, required :: Encoding
                 , datatypes :: [Type], known :: Catalog
                 -- Recursive definitions: each one's group (its strongly
                 -- connected component of calls), the encoding, the groups
                 -- declared so far and their text, and the fuel a call
                 -- passes where it is encoded.
                 , groups :: M.Map Id [Definition], recursion :: Recursion
                 , declared :: [Id], functionText :: [String], fuel :: String
                 -- Whether the solver options keep unfolding bounded, and
                 -- whether each result is stated to lie in its type: both,
                 -- except in a counterexample query, which searches for a
                 -- model and states nothing it does not need.
                 , bounded :: Bool, ranges :: Bool
                 -- Assumed quantified laws (induction hypotheses, cited
                 -- laws) name their triggers: the calls to recursive
                 -- definitions made in them, so Z3 never picks a
                 -- well-formedness test, which every datum matches.
                 , patterned :: Bool, triggers :: [String], bound :: [String]
                 -- A recursive call's value with its lets, and the same call
                 -- written out, for triggers.
                 , unshared :: M.Map String String }

start :: Encoding -> Program -> Recursion -> Work
start encoding program mode = Work 0 0 encoding [] (catalog program) (recursiveGroups program) mode [] [] (fuelLiteral mode) True True False [] [] M.empty

-- | With recursive definitions, the solver options that keep unfolding
-- bounded (as Dafny sets them: no model-based quantifier instantiation, so
-- the axioms unfold only through their patterns), and the definitions.
recursiveText :: Work -> (String, String)
recursiveText work
  | null (declared work) = ("", "")
  | not (bounded work) = ("", concat (functionText work))
  | otherwise = ("(set-option :smt.mbqi false)\n(set-option :auto_config false)\n", concat (functionText work))

fuelLiteral :: Recursion -> String
fuelLiteral (GuardedAxioms n) = iterate (\x -> app "lawspec_fuel_next" [x]) "lawspec_fuel_zero" !! n
fuelLiteral DefineFunRec = ""

-- | The pure checked definitions that call themselves, directly or through
-- others, each with its group.
recursiveGroups :: Program -> M.Map Id [Definition]
recursiveGroups program = M.fromList [ (identity d, group) | CyclicSCC group <- stronglyConnComp graph, d <- group ]
  where
    definitions = [d | u <- programUnits program, d <- unitDefinitions u]
    identity = declarationId . definitionDeclaration
    graph = [(d, identity d, callees (definitionBody d)) | d <- definitions]
    callees e = case expressionNode e of
      ExternalCall g arguments -> g : concatMap callees arguments
      _ -> concatMap callees (children e)

-- | A feature of a later encoding. v1 calls this nowhere, which is what keeps
-- every v1 task as it was.
requires :: Encoding -> Encode ()
requires needed = modify (\s -> s{required=max needed (required s)})
type Encode = StateT Work (Either String)
type Scope = M.Map Id Term

app :: String -> [String] -> String
app name values = "(" ++ unwords (name:values) ++ ")"
both, eitherOf :: [String] -> String
both [] = "true"
both [x] = x
both xs = app "and" xs
eitherOf [] = "false"
eitherOf [x] = x
eitherOf xs = app "or" xs
no :: String -> String
no x = app "not" [x]
choose :: String -> String -> String -> String
choose a b c = app "ite" [a,b,c]
integer :: Integer -> String
integer n | n < 0 = app "-" [show (negate n)]
          | otherwise = show n
fresh :: Encode String
fresh = do
  n <- gets nextName
  modify (\s -> s{nextName=n+1})
  pure ("v" ++ show n)
tick :: Encode ()
tick = do
  n <- gets visited
  when (n >= 16384) (lift (Left "SMT translation exceeds its expression budget"))
  modify (\s -> s{visited=n+1})
sort :: Type -> Either String Sort
sort (Constructor "Bool" []) = Right BooleanSort
sort (Constructor "Unit" []) = Right UnitSort
sort (Constructor "Rational" []) = Right RealSort
sort (Constructor name []) | isInteger name = Right IntegerSort
sort ty = Left ("unsupported SMT carrier: " ++ show ty)
-- | Every data declaration the program can use, by type name.
type Catalog = M.Map String DataDeclaration

catalog :: Program -> Catalog
catalog program = M.fromList [(idText (dataId d), d) | d <- builtinDataDeclarations ++ programDataDeclarations program]

-- | A carrier's sort; a data type must be one the encoding can declare.
sortIn :: Catalog -> Type -> Either String Sort
sortIn types ty = case sort ty of
  Right s -> Right s
  Left reason -> case ty of
    Constructor name _ | M.member name types -> do
      admissible types [] ty
      unless (all (inhabited types) (reachable types ty))
        (Left ("unsupported SMT data type " ++ name ++ ": it, or a type it holds, has no finite value, and an SMT datatype must have one"))
      pure (DataSort ty)
    _ -> Left reason

-- | The data types a data type holds, itself included.
reachable :: Catalog -> Type -> [Type]
reachable types root = go [] [root]
  where
    go seen [] = reverse seen
    go seen (t : rest)
      | t `elem` seen = go seen rest
      | otherwise = go (t : seen) (rest ++ [f | f <- fieldTypes types t, Left _ <- [sort f]])

-- | Whether a data type has a finite value: some constructor whose fields
-- all have one. LawSpec admits empty types; SMT datatypes cannot be empty.
inhabited :: Catalog -> Type -> Bool
inhabited types root = root `elem` grow []
  where
    candidates = reachable types root
    grow known = case [t | t <- candidates, t `notElem` known, any (all (has known) . fieldsOf t) (constructorsOf t)] of
      [] -> known
      new -> grow (known ++ new)
    has known f = either (const (f `elem` known)) (const True) (sort f)
    constructorsOf t = either (const []) (dataConstructors . fst) (declarationOf types t)
    fieldsOf t c = [instantiate (either (const []) snd (declarationOf types t)) (binderType f) | f <- constructorFields c]

-- | A declarable data type: a closed instance of a declaration that is not a
-- handle or an indexed family, has no existential or equation constructors,
-- and whose fields are declarable too. A Rational field is refused, since SMT
-- Real would admit irrational values inside a quantified datum.
admissible :: Catalog -> [Type] -> Type -> Either String ()
admissible types seen ty
  | ty `elem` seen = Right ()
  | Constructor name arguments <- ty, Just declaration <- M.lookup name types = do
      let refused why = Left ("unsupported SMT data type " ++ name ++ ": " ++ why)
      when (dataHandle declaration) (refused "a handle has no constructors to reason about")
      when (dataIndex declaration /= Nothing) (refused "indexed families are not encoded yet")
      concrete <- forM arguments $ \argument -> case argument of
        TypeArgument t -> Right t
        _ -> refused "index arguments are not encoded yet"
      unless (length concrete == length (dataParameters declaration)) (refused "wrong number of type arguments")
      when (any (\c -> c == '|' || c == '\\') (typeSymbol ty)) (refused "its name cannot be an SMT symbol")
      forM_ (dataConstructors declaration) $ \c -> do
        unless (null (constructorExistentials c) && null (constructorEquations c))
          (refused "constructors with existential or refined type parameters are not encoded yet")
        forM_ (constructorFields c) $ \field -> do
          let fieldType = instantiate (zip (dataParameters declaration) concrete) (binderType field)
          case sort fieldType of
            Right RealSort -> refused "a Rational field would admit irrational SMT values"
            Right _ -> Right ()
            Left _ -> admissible types (ty : seen) fieldType
  | otherwise = Left ("unsupported SMT carrier: " ++ show ty)

-- | A declaration's field type at an instance's type arguments.
instantiate :: [(Id, Type)] -> Type -> Type
instantiate table ty = case ty of
  TypeVariable v -> maybe ty id (lookup v table)
  Constructor name arguments -> Constructor name
    [case a of TypeArgument t -> TypeArgument (instantiate table t); other -> other | a <- arguments]
  Arrow a b -> Arrow (instantiate table a) (instantiate table b)

-- Symbols are quoted, so a type, constructor or selector keeps its LawSpec
-- name: Maybe<Int32>, Maybe<Int32>#Just and Maybe<Int32>#Just#0.
typeSymbol :: Type -> String
typeSymbol (Constructor name []) = name
typeSymbol (Constructor name arguments) = name ++ "<" ++ intercalate "," [typeSymbol t | TypeArgument t <- arguments] ++ ">"
typeSymbol other = show other

constructorSymbol :: Type -> DataConstructor -> String
constructorSymbol ty c = "|" ++ typeSymbol ty ++ "#" ++ constructorName c ++ "|"

selectorSymbol :: Type -> DataConstructor -> Int -> String
selectorSymbol ty c i = "|" ++ typeSymbol ty ++ "#" ++ constructorName c ++ "#" ++ show i ++ "|"

wellFormedSymbol :: Type -> String
wellFormedSymbol ty = "|wf#" ++ typeSymbol ty ++ "|"

tester :: Type -> DataConstructor -> String -> String
tester ty c x = app (app "_" ["is", constructorSymbol ty c]) [x]

-- | The declaration and table of an admitted instance.
declarationOf :: Catalog -> Type -> Either String (DataDeclaration, [(Id, Type)])
declarationOf types ty = case ty of
  Constructor name arguments | Just declaration <- M.lookup name types ->
    Right (declaration, zip (dataParameters declaration) [t | TypeArgument t <- arguments])
  _ -> Left ("unsupported SMT data type: " ++ show ty)

constructorOf :: Catalog -> Type -> Id -> Either String DataConstructor
constructorOf types ty tag = do
  (declaration, _) <- declarationOf types ty
  case [c | c <- dataConstructors declaration, constructorId c == tag] of
    c : _ -> Right c
    [] -> Left ("unknown SMT constructor " ++ idText tag)

fieldTypes :: Catalog -> Type -> [Type]
fieldTypes types ty = case declarationOf types ty of
  Right (declaration, table) -> [instantiate table (binderType f) | c <- dataConstructors declaration, f <- constructorFields c]
  Left _ -> []

-- | A carrier's sort, declaring a data type (and the data types of its
-- fields) the first time one is used. A data type makes the task v2.
sortOf :: Program -> Type -> Encode Sort
sortOf program ty = do
  types <- gets known
  s <- lift (sortIn types ty)
  case s of
    DataSort _ -> do
      requires SmtLibV2
      declared <- gets datatypes
      unless (ty `elem` declared) $ do
        modify (\w -> w{datatypes = datatypes w ++ [ty]})
        forM_ (fieldTypes types ty) $ \fieldType -> case sort fieldType of
          Right _ -> pure ()
          Left _ -> () <$ sortOf program fieldType
    _ -> pure ()
  pure s

quantifierSortOf :: Program -> Type -> Encode Sort
quantifierSortOf program ty = do
  s <- sortOf program ty
  unless (s /= RealSort) (lift (Left "SMT Real quantification is not exact Rational quantification"))
  pure s

-- | The declarations of the data types a task used, and their
-- well-formedness: each field in its type's range, nested data well formed,
-- and each constructor's field refinements. Recursive types (List) define it
-- with define-funs-rec, which is sound because a datum is finite.
datatypePreamble :: Program -> Encode String
datatypePreamble program = do
  initial <- gets datatypes
  if null initial then pure "" else do
    bodies <- wellFormed []
    final <- gets datatypes
    types <- gets known
    let bits = programMachineBits program
        constructors ty = either (const []) (dataConstructors . fst) (declarationOf types ty)
        table ty = either (const []) snd (declarationOf types ty)
        field ty c i f = "(" ++ selectorSymbol ty c i ++ " " ++
          either (const "Bool") sortText (sortIn types (instantiate (table ty) (binderType f))) ++ ")"
        constructor ty c = "(" ++ unwords (constructorSymbol ty c : [field ty c i f | (i, f) <- zip [0 ..] (constructorFields c)]) ++ ")"
        declare = "(declare-datatypes (" ++ unwords ["(" ++ sortText (DataSort t) ++ " 0)" | t <- final] ++ ") (" ++
          unwords ["(" ++ unwords (map (constructor t) (constructors t)) ++ ")" | t <- final] ++ "))\n"
        graph = [(t, typeSymbol t, [typeSymbol f | f <- fieldTypes types t, f `elem` final]) | t <- final]
        components = stronglyConnComp graph
        recursive = not (null [() | CyclicSCC _ <- components])
        signature t = "(" ++ wellFormedSymbol t ++ " ((x " ++ sortText (DataSort t) ++ ")) Bool)"
        body t = maybe "true" id (lookup t bodies)
        definitions
          | recursive = "(define-funs-rec (" ++ unwords (map signature final) ++ ") (" ++ unwords (map body final) ++ "))\n"
          | otherwise = concat ["(define-fun " ++ wellFormedSymbol t ++ " ((x " ++ sortText (DataSort t) ++ ")) Bool " ++ body t ++ ")\n"
                              | t <- flattenSCCs components]
    _ <- pure bits
    pure (declare ++ definitions)
  where
    wellFormed done = do
      pending <- gets (filter (`notElem` map fst done) . datatypes)
      if null pending then pure done else do
        new <- forM pending (\ty -> (,) ty <$> wellFormedBody program ty)
        wellFormed (done ++ new)

wellFormedBody :: Program -> Type -> Encode String
wellFormedBody program ty = do
  types <- gets known
  (declaration, table) <- lift (declarationOf types ty)
  conditions <- forM (dataConstructors declaration) $ \c -> do
    fields <- forM (zip [0 ..] (constructorFields c)) $ \(i, f) -> do
      let fieldType = instantiate table (binderType f)
          selected = app (selectorSymbol ty c i) ["x"]
      s <- sortOf program fieldType
      range <- lift (domain (programMachineBits program) fieldType selected)
      pure ((binderId f, Term s selected "true"), range)
    invariant <- restrictions program [] (M.fromList (map fst fields)) (constructorPredicates c)
    pure (app "=>" [tester ty c "x", both (map snd fields ++ [positive invariant])])
  pure (both conditions)

sortText :: Sort -> String
sortText BooleanSort = "Bool"
sortText UnitSort = "Bool"
sortText (DataSort ty) = "|" ++ typeSymbol ty ++ "|"
sortText IntegerSort = "Int"
sortText RealSort = "Real"

-- Rational-valued computations stay rational, since their leaves are integers
-- or rational constants and their operations are rational-closed. Quantifying
-- Rational as SMT Real is deliberately forbidden: an existential could then
-- choose an irrational witness (for example a square root of two).
quantifierSort :: Type -> Either String Sort
quantifierSort ty = do
  s <- sort ty
  unless (s /= RealSort) (Left "SMT Real quantification is not exact Rational quantification")
  pure s

domain :: Int -> Type -> String -> Either String String
domain bits ty x = do
  s <- case (sort ty, ty) of
    (Left _, Constructor _ _) -> Right (DataSort ty)
    (result, _) -> result
  pure $ case (s,ty) of
    (DataSort _,_) -> app (wellFormedSymbol ty) [x]
    (UnitSort,_) -> app "=" [x,"false"]
    (IntegerSort,Constructor name []) -> case integerBounds bits name of
      Just (lo,hi) -> both [app "<=" [integer lo,x],app "<=" [x,integer hi]]
      Nothing | name == "BigUInt" -> app "<=" ["0",x]
      _ -> "true"
    _ -> "true"

query :: Program -> Unfolding -> Property -> Either String (Encoding, String, Maybe Recursion, Maybe (Recursion, String))
query program unfolding law = do
  unless (propertyInputDomain law == UniversalDomain)
    (Left "SMT law tasks require the canonical universal input-domain policy")
  unless (null (propertyResources law)) (Left "SMT translation does not execute resources")
  unless (null (propertyHandlers law)) (Left "SMT translation does not execute ability handlers")
  let encode mode = do
        ((certificate, prelude), work) <- runStateT (do
            certificate <- proposition program [] M.empty
              (foldr (Quantified ForEvery) (propertyBody law) (propertyParameters law ++ propertyInputs law))
            prelude <- datatypePreamble program
            pure (certificate, prelude)) (start SmtLibV1 program mode)
        let script = "; " ++ encodingName (required work) ++ "; negate a positive certificate, including definedness\n" ++
              fst (recursiveText work) ++ prelude ++ snd (recursiveText work) ++ "(assert " ++ no (positive certificate) ++ ")\n"
        unless (length (take 1048577 script) <= 1048576) (Left "SMT query exceeds its output budget")
        pure (required work, script, not (null (declared work)))
  let (first, second) = case unfolding of
        Unfold n -> (GuardedAxioms n, Nothing)
        SolverRecursion -> (DefineFunRec, Nothing)
        UnfoldThenSolver n -> (GuardedAxioms n, Just DefineFunRec)
  (encoding, script, recursive) <- encode first
  if not recursive then pure (encoding, script, Nothing, Nothing) else do
    alternative <- traverse (\mode -> (\(_, text, _) -> (mode, text)) <$> encode mode) second
    pure (encoding, script, Just first, alternative)

truth :: Term -> Certificate
truth term = Certificate (both [defined term,value term]) (both [defined term,no (value term)])

-- Ordered conjunction retains short-circuit definedness. A later false value
-- cannot conceal failure while evaluating an earlier operand.
conjoin :: Certificate -> Certificate -> Certificate
conjoin a b = Certificate (both [positive a,positive b])
  (eitherOf [negative a,both [positive a,negative b]])
restrictions :: Program -> [Id] -> Scope -> [Expr] -> Encode Certificate
restrictions program active scope predicates = foldM
  (\before predicate -> conjoin before . truth <$> expression program active scope predicate)
  (Certificate "true" "false") predicates

proposition :: Program -> [Id] -> Scope -> Proposition -> Encode Certificate
proposition program active scope claim = do
  tick
  case claim of
    Equation evidence a b -> do
      term <- expression program active scope (Expr (scalarType "Bool")
        (Binary Equal evidence a b) (expressionOrigin a))
      pure (truth term)
    Implication guard body -> do
      test <- expression program active scope guard
      result <- proposition program active scope body
      pure (Certificate (both [defined test,eitherOf [no (value test),positive result]])
        (both [defined test,value test,negative result]))
    Conjunction claims -> foldM
      (\before item -> conjoin before <$> proposition program active scope item)
      (Certificate "true" "false") claims
    Negation body -> do
      result <- proposition program active scope body
      pure (Certificate (negative result) (positive result))
    Quantified kind q body -> do
      let binder=quantifiedBinder q
      s <- quantifierSortOf program (binderType binder)
      name <- fresh
      before <- gets (length . triggers)
      modify (\w -> w{bound = name : bound w})
      let local=M.insert (binderId binder) (Term s name "true") scope
      base <- lift (domain (programMachineBits program) (binderType binder) name)
      restricted <- restrictions program active local (quantifiedPredicates q)
      result <- proposition program active local body
      made <- gets (drop before . triggers)
      inScope <- gets bound
      modify (\w -> w{bound = drop 1 (bound w)})
      let spaced c = if c `elem` ("()" :: String) then ' ' else c
          -- A trigger may name only quantified variables, never a let's.
          local token = case token of
            'v' : digits -> not (null digits) && all (`elem` ("0123456789" :: String)) digits
            _ -> False
          closed t = all (`elem` inScope) (filter local (words (map spaced t)))
          chosen = take 3 [t | (i, t) <- zip [0 :: Int ..] made, t `notElem` take i made, name `elem` words (map spaced t), closed t]
          patterns = concat [" :pattern (" ++ t ++ ")" | t <- chosen]
          quantify keyword formula
            | null chosen = "(" ++ keyword ++ " ((" ++ name ++ " " ++ sortText s ++ ")) " ++ formula ++ ")"
            | otherwise = "(" ++ keyword ++ " ((" ++ name ++ " " ++ sortText s ++ ")) (! " ++ formula ++ patterns ++ "))"
          allOf bodyCertificate = quantify "forall" (eitherOf [no base,negative restricted,
            both [positive restricted,bodyCertificate]])
          someOf bodyCertificate = quantify "exists" (both [base,positive restricted,bodyCertificate])
      pure $ case kind of
        ForEvery -> Certificate (allOf (positive result)) (someOf (negative result))
        ForSome -> Certificate (someOf (positive result)) (allOf (negative result))

expression :: Program -> [Id] -> Scope -> Expr -> Encode Term
expression program active scope source = do
  tick
  expected <- sortOf program (expressionType source)
  types <- gets known
  term <- node expected types
  unless (termSort term == expected) (lift (Left "SMT expression carrier mismatch"))
  valid <- lift (domain (programMachineBits program) (expressionType source) (value term))
  pure term{defined=both [defined term,valid]}
  where
    recurse=expression program active scope
    node expected types=case expressionNode source of
      -- Data (lawspec-smtlib-v2). A construction is defined when its fields
      -- are and the datum is well formed: its field refinements hold.
      Construct tag fields -> do
        let ty = expressionType source
        c <- lift (constructorOf types ty tag)
        terms <- mapM recurse fields
        let built = if null terms then constructorSymbol ty c else app (constructorSymbol ty c) (map value terms)
        pure (Term expected built (both (map defined terms ++ [app (wellFormedSymbol ty) [built]])))
      -- A match selects the case whose constructor built the value; its
      -- binders are that constructor's selectors, so no field is read from
      -- another constructor.
      Match scrutinee cases -> do
        subject <- recurse scrutinee
        let ty = expressionType scrutinee
        name <- fresh
        branches <- forM cases $ \matched -> do
          c <- lift (constructorOf types ty (caseConstructor matched))
          bound <- forM (zip [0 ..] (caseBinders matched)) $ \(i, binder) -> do
            s <- sortOf program (binderType binder)
            pure (binderId binder, Term s (app (selectorSymbol ty c i) [name]) "true")
          body <- expression program active (M.union (M.fromList bound) scope) (caseBody matched)
          pure (tester ty c name, body)
        case reverse branches of
          [] -> lift (Left "SMT match has no cases")
          (_, final) : _ -> do
            let bind x = app "let" ["((" ++ name ++ " " ++ value subject ++ "))", x]
                chosen = foldr (\(test, body) rest -> choose test (value body) rest) (value final) (init branches)
                guarded = foldr (\(test, body) rest -> choose test (defined body) rest) "false" branches
            pure (Term expected (bind chosen) (both [defined subject, bind guarded]))
      -- b.f reads a field of the constructor that built b, and only that one:
      -- a read from another constructor is undefined, never Z3's arbitrary
      -- selector value.
      Project tag index argument -> do
        subject <- recurse argument
        let ty = expressionType argument
        c <- lift (constructorOf types ty tag)
        pure (Term expected (app (selectorSymbol ty c index) [value subject])
          (both [defined subject, tester ty c (value subject)]))
      Update tag index argument replacement -> do
        subject <- recurse argument
        new <- recurse replacement
        let ty = expressionType argument
        c <- lift (constructorOf types ty tag)
        let built = app (constructorSymbol ty c)
              [if k == index then value new else app (selectorSymbol ty c k) [value subject] | k <- [0 .. length (constructorFields c) - 1]]
        pure (Term expected built (both [defined subject, tester ty c (value subject), defined new, app (wellFormedSymbol ty) [built]]))
      Constant scalar -> case scalar of
        SBool x -> pure (Term BooleanSort (if x then "true" else "false") "true")
        SInteger _ n -> pure (Term IntegerSort (integer n) "true")
        SRational n d -> pure (Term RealSort (app "/" [app "to_real" [integer n],app "to_real" [integer d]]) "true")
        SAbsent "Unit" -> pure (Term UnitSort "false" "true")
        _ -> lift (Left "unsupported SMT scalar constant")
      Local name -> maybe (lift (Left "unbound SMT local")) pure (M.lookup name scope)
      Let binder argument body -> do
        term <- recurse argument
        name <- fresh
        result <- expression program active (M.insert (binderId binder) term{value=name,defined="true"} scope) body
        let bind x=app "let" ["((" ++ name ++ " " ++ value term ++ "))",x]
        pure result{value=bind (value result),defined=both [defined term,bind (defined result)]}
      If condition yes unlessTrue -> do
        test <- recurse condition
        a <- recurse yes
        b <- recurse unlessTrue
        pure a{value=choose (value test) (value a) (value b),
          defined=both [defined test,choose (value test) (defined a) (defined b)]}
      ShortCircuit op left right -> do
        a <- recurse left
        b <- recurse right
        let result=case op of And -> choose (value a) (value b) "false"; Or -> choose (value a) "true" (value b)
            valid=case op of And -> choose (value a) (defined b) "true"; Or -> choose (value a) "true" (defined b)
        pure (Term BooleanSort result (both [defined a,valid]))
      Unary op argument -> do
        term <- recurse argument
        pure term{value=app (case op of Not -> "not"; Negate -> "-") [value term]}
      Binary op _ left right -> do
        a <- recurse left
        b <- recurse right
        lift (binary op a b)
      Convert _ target argument -> do
        term <- recurse argument
        s <- sortOf program target
        case (termSort term,s) of
          (a,b) | a==b -> pure term
          (IntegerSort,RealSort) -> pure term{termSort=s,value=app "to_real" [value term]}
          (RealSort,IntegerSort) -> pure term{termSort=s,value=app "to_int" [value term],
            defined=both [defined term,app "is_int" [value term]]}
          _ -> lift (Left "unsupported SMT conversion")
      ExternalCall name arguments -> call program active scope name arguments
      Helper Unreachable [] -> do
        s <- sortOf program (expressionType source)
        case s of
          DataSort _ -> lift (Left "unsupported SMT expression; no uninterpreted replacement was introduced")
          _ -> pure (Term s (case s of BooleanSort -> "false"; UnitSort -> "false"; _ -> "0") "false")
      Helper Checked [argument] -> do
        term <- recurse argument
        pure (Term BooleanSort "true" (defined term))
      _ -> lift (Left "unsupported SMT expression; no uninterpreted replacement was introduced")

binary :: BinaryOp -> Term -> Term -> Either String Term
binary op a b = do
  let numeric term=termSort term `elem` [IntegerSort,RealSort]
      real term | termSort term==IntegerSort = app "to_real" [value term]
                | otherwise = value term
      mixed=termSort a==RealSort || termSort b==RealSort
      x=if mixed then real a else value a
      y=if mixed then real b else value b
      total=both [defined a,defined b]
      arithmetic name s left right valid=Term s (app name [left,right]) (both [total,valid])
  case op of
    Equal -> equality "=" x y total
    NotEqual -> equality "distinct" x y total
    _ -> do
      unless (numeric a && numeric b) (Left "SMT arithmetic requires numeric operands")
      case op of
        Less -> pure (arithmetic "<" BooleanSort x y "true")
        LessEqual -> pure (arithmetic "<=" BooleanSort x y "true")
        Greater -> pure (arithmetic ">" BooleanSort x y "true")
        GreaterEqual -> pure (arithmetic ">=" BooleanSort x y "true")
        Add -> pure (arithmetic "+" (if mixed then RealSort else IntegerSort) x y "true")
        Subtract -> pure (arithmetic "-" (if mixed then RealSort else IntegerSort) x y "true")
        Multiply -> pure (arithmetic "*" (if mixed then RealSort else IntegerSort) x y "true")
        Divide -> pure (arithmetic "/" RealSort (real a) (real b) (app "distinct" [y,"0"]))
        Quotient -> quotient x y total
        Remainder -> do
          q <- quotient x y total
          pure q{value=app "-" [x,app "*" [y,value q]]}
        _ -> Left "unsupported SMT arithmetic operation"
  where
    equality operator x y total = do
      unless (termSort a==termSort b || all (\t -> termSort t `elem` [IntegerSort,RealSort]) [a,b])
        (Left "SMT equality carrier mismatch")
      pure (Term BooleanSort (app operator [x,y]) total)
    quotient x y total = do
      unless (termSort a==IntegerSort && termSort b==IntegerSort) (Left "SMT quotient requires integers")
      let absolute n=choose (app "<" [n,"0"]) (app "-" [n]) n
          magnitude=app "div" [absolute x,absolute y]
          q=choose (app "xor" [app "<" [x,"0"],app "<" [y,"0"]]) (app "-" [magnitude]) magnitude
      pure (Term IntegerSort q (both [total,app "distinct" [y,"0"]]))

call :: Program -> [Id] -> Scope -> Id -> [Expr] -> Encode Term
call program active scope name arguments = do
  recursive <- gets (M.member name . groups)
  if recursive then recursiveCall program active scope name arguments else inlineCall program active scope name arguments

-- | A call to a recursive definition: its declared function, at the
-- current fuel. Mandatory admission proved that the body is total on the
-- definition's domain (argument types and preconditions), and that its
-- result lies in the result type, by induction over the calls it proved
-- terminate. So the call is defined exactly when its arguments are defined
-- and in that domain, and the callee's runtime postconditions hold; Z3 does
-- not re-derive definedness by unfolding. ref:DEC-smt-recursive-definitions
recursiveCall :: Program -> [Id] -> Scope -> Id -> [Expr] -> Encode Term
recursiveCall program active scope name arguments = do
  requires SmtLibV2
  group <- gets (M.findWithDefault [] name . groups)
  definition <- lift $ case [d | d <- group, declarationId (definitionDeclaration d) == name] of
    [d] | not (definitionOrchestrates d), null (declarationUses (definitionDeclaration d)) -> Right d
    _ -> Left "SMT calls require a pure checked definition; native implementations stay unsupported"
  declareGroup program group
  values <- mapM (expression program active scope) arguments
  unless (length values==length (definitionArguments definition)) (lift (Left "SMT call arity mismatch"))
  s <- sortOf program (snd (functionType (declarationType (definitionDeclaration definition))))
  names <- mapM (const fresh) values
  current <- gets fuel
  ranges <- lift (mapM (\(n, b) -> domain (programMachineBits program) (binderType b) n) (zip names (definitionArguments definition)))
  let stored=zipWith (\n term -> term{value=n,defined="true"}) names values
      bind text | null values = text
                | otherwise = app "let" ["(" ++ unwords ["(" ++ n ++ " " ++ value term ++ ")" | (n,term)<-zip names values] ++ ")",text]
      called | null current = app (functionSymbol name) names
             | otherwise = app (fuelSymbol name) (current : names)
      result = Term s called "true"
  valid <- contractChecks program active name stored result
  wanted <- gets patterned
  written <- gets unshared
  let plainArguments = [M.findWithDefault (value v) (value v) written | v <- values]
      outright | null current = app (functionSymbol name) plainArguments
               | otherwise = app (fuelSymbol name) (current : plainArguments)
  when (wanted && not (any (`elem` words (map spaced outright)) ["let", "ite", "forall", "exists"])) $
    modify (\w -> w{triggers = triggers w ++ [outright], unshared = M.insert (bind (value result)) outright (unshared w)})
  pure result{value=bind (value result),defined=both (map defined values ++ [bind (both (ranges ++ valid))])}
  where spaced c = if c `elem` ("()" :: String) then ' ' else c

-- | A recursive definition's function, the same at every fuel; and, with
-- guarded axioms, the function at a given fuel, linked to it by an axiom.
-- Hypotheses and cited laws use the first, so they match whatever fuel a
-- term was unfolded at.
functionSymbol, fuelSymbol :: Id -> String
functionSymbol name = "|lawspec_function " ++ idText name ++ "|"
fuelSymbol name = "|lawspec_function_fuel " ++ idText name ++ "|"

-- | A group's functions, declared and defined once per task, after the
-- groups their bodies call. Each definition holds where admission proved
-- the body total: on its argument domains and preconditions (the guard).
-- There its result also lies in its result type.
declareGroup :: Program -> [Definition] -> Encode ()
declareGroup program group = do
  let ids = map (declarationId . definitionDeclaration) group
  done <- gets declared
  unless (any (`elem` done) ids) $ do
    modify (\w -> w{declared = declared w ++ ids})
    mode <- gets recursion
    outer <- gets fuel
    let bits = programMachineBits program
        fuelSort = "LawspecFuel"
        fuelVariable = "lawspec_fuel"
    modify (\w -> w{fuel = case mode of GuardedAxioms _ -> fuelVariable; DefineFunRec -> ""})
    members <- forM group $ \d -> do
      let name = declarationId (definitionDeclaration d)
          resultType = snd (functionType (declarationType (definitionDeclaration d)))
          parameters = [("lawspec_argument_" ++ show i, b) | (i, b) <- zip [0 :: Int ..] (definitionArguments d)]
      sorts <- mapM (sortOf program . binderType . snd) parameters
      resultSort <- sortOf program resultType
      let terms = [Term s n "true" | ((n, _), s) <- zip parameters sorts]
          scope = M.fromList (zip (map (binderId . snd) parameters) terms)
      ranges <- lift (mapM (\(n, b) -> domain bits (binderType b) n) parameters)
      preconditions <- forM [c | u <- programUnits program, c <- unitContracts u, contractDeclaration c == name] $ \c ->
        positive <$> restrictions program [] (M.fromList (zip (map binderId (contractArguments c)) terms)) (contractPreconditions c)
      body <- expression program [] scope (definitionBody d)
      pure (name, parameters, sorts, resultSort, resultType, both (ranges ++ preconditions), value body)
    modify (\w -> w{fuel = outer})
    let typed ps ss = [(n, sortText so) | ((n, _), so) <- zip ps ss]
        binders ps ss = unwords ["(" ++ n ++ " " ++ t ++ ")" | (n, t) <- typed ps ss]
        outside n = "|lawspec_outside " ++ idText n ++ "|"
        fuelDeclaration = case mode of
          GuardedAxioms _ ->
            "(declare-datatypes ((" ++ fuelSort ++ " 0)) (((lawspec_fuel_zero) (lawspec_fuel_next (lawspec_fuel_previous " ++ fuelSort ++ ")))))\n"
          DefineFunRec -> ""
    keepRanges <- gets ranges
    inRange <- if not keepRanges then pure [] else forM members $ \(n, ps, ss, _, resultType, guard, _) -> do
      let call = app (functionSymbol n) (map fst ps)
      range <- lift (domain bits resultType call)
      pure ("(assert (forall (" ++ binders ps ss ++ ") (! " ++ app "=>" [guard, range] ++ " :pattern (" ++ call ++ "))))\n")
    let declarations = concat
          [ case mode of
              GuardedAxioms _ -> "(declare-fun " ++ fuelSymbol n ++ " (" ++ unwords (fuelSort : map snd (typed ps ss)) ++ ") " ++ sortText r ++ ")\n" ++
                "(declare-fun " ++ functionSymbol n ++ " (" ++ unwords (map snd (typed ps ss)) ++ ") " ++ sortText r ++ ")\n"
              DefineFunRec -> "(declare-fun " ++ outside n ++ " (" ++ unwords (map snd (typed ps ss)) ++ ") " ++ sortText r ++ ")\n"
          | (n, ps, ss, r, _, _, _) <- members ]
        definitions = case mode of
          GuardedAxioms _ -> concat
            [ "(assert (forall ((" ++ fuelVariable ++ " " ++ fuelSort ++ ") " ++ binders ps ss ++ ") (! " ++
                app "=>" [guard, app "=" [app f next, body]] ++ " :pattern (" ++ app f next ++ "))))\n" ++
              -- A call with fuel left is the function; the function, where
              -- a hypothesis or a cited law names it, unfolds once. A call
              -- with no fuel left links to nothing, so no unfolding makes
              -- new calls without end.
              "(assert (forall ((" ++ fuelVariable ++ " " ++ fuelSort ++ ") " ++ binders ps ss ++ ") (! " ++
                app "=" [app f next, app (functionSymbol n) (map fst ps)] ++ " :pattern (" ++ app f next ++ "))))\n" ++
              "(assert (forall (" ++ binders ps ss ++ ") (! " ++
                app "=" [app (functionSymbol n) (map fst ps), app f (app "lawspec_fuel_next" ["lawspec_fuel_zero"] : map fst ps)] ++
                " :pattern (" ++ app (functionSymbol n) (map fst ps) ++ "))))\n"
            | (n, ps, ss, _, _, guard, body) <- members, let f = fuelSymbol n
            , let next = app "lawspec_fuel_next" [fuelVariable] : map fst ps ]
          DefineFunRec ->
            "(define-funs-rec (" ++ unwords
              [ "(" ++ functionSymbol n ++ " (" ++ binders ps ss ++ ") " ++ sortText r ++ ")" | (n, ps, ss, r, _, _, _) <- members ] ++ ") (" ++
            unwords [ choose guard body (app (outside n) (map fst ps)) | (n, ps, _, _, _, guard, body) <- members ] ++ "))\n"
    fuelDeclared <- gets (any ("(declare-datatypes ((LawspecFuel" `isPrefixOf`) . functionText)
    modify (\w -> w{functionText = functionText w ++ [if fuelDeclared then "" else fuelDeclaration] ++ [declarations ++ definitions ++ concat inRange]})

-- | The callee's preconditions and runtime postconditions, at a call.
contractChecks :: Program -> [Id] -> Id -> [Term] -> Term -> Encode [String]
contractChecks program active name stored result = do
  let contracts=[c | u<-programUnits program,c<-unitContracts u,contractDeclaration c==name]
      nested=name:active
  forM contracts $ \contract -> do
    let before=M.fromList (zip (map binderId (contractArguments contract)) stored)
        after=M.insert (binderId (contractResult contract)) result{defined="true"} before
    pre <- restrictions program nested before (contractPreconditions contract)
    post <- restrictions program nested after (contractRuntimePostconditions contract)
    pure (both [positive pre,positive post])

inlineCall :: Program -> [Id] -> Scope -> Id -> [Expr] -> Encode Term
inlineCall program active scope name arguments = do
  when (name `elem` active) (lift (Left "recursive checked definitions require an SMT induction encoding"))
  definition <- lift $ case [d | u <- programUnits program,d <- unitDefinitions u,
      declarationId (definitionDeclaration d)==name,not (definitionOrchestrates d),
      null (declarationUses (definitionDeclaration d))] of
    [d] -> Right d
    _ -> Left "SMT calls require a pure checked definition; native implementations stay unsupported"
  values <- mapM (expression program active scope) arguments
  unless (length values==length (definitionArguments definition)) (lift (Left "SMT call arity mismatch"))
  names <- mapM (const fresh) values
  let stored=zipWith (\name term -> term{value=name,defined="true"}) names values
      bind text | null values = text
                | otherwise = app "let" ["(" ++ unwords ["(" ++ name ++ " " ++ value term ++ ")" | (name,term)<-zip names values] ++ ")",text]
      local=M.fromList (zip (map binderId (definitionArguments definition)) stored)
      contracts=[c | u<-programUnits program,c<-unitContracts u,contractDeclaration c==name]
      nested=name:active
  result <- expression program nested local (definitionBody definition)
  valid <- forM contracts $ \contract -> do
    let before=M.fromList (zip (map binderId (contractArguments contract)) stored)
        after=M.insert (binderId (contractResult contract)) result{defined="true"} before
    pre <- restrictions program nested before (contractPreconditions contract)
    post <- restrictions program nested after (contractRuntimePostconditions contract)
    pure (both [positive pre,positive post])
  pure result{value=bind (value result),defined=both (map defined values ++ [bind (both (defined result:valid))])}

-- | The law's inputs whose type is a recursive data type (List, a tree):
-- the candidates for the default induction try.
structuralInputs :: Program -> Property -> [String]
structuralInputs program law =
  [ binderName (quantifiedBinder q) | q <- fst (outerQuantifiers law), recursiveType (binderType (quantifiedBinder q)) ]
  where
    types = catalog program
    recursiveType ty = case declarationOf types ty of
      Right (declaration, table) -> or [instantiate table (binderType f) == ty | c <- dataConstructors declaration, f <- constructorFields c]
      Left _ -> False

-- | One case of induction on an input x.
data Shape = DataCase DataConstructor [Type] | IntegerBase Integer | IntegerStep Integer

-- | Induction on input x of law P, as Why3's induction_ty_lex and
-- induction_int_lex do: structural for a data type (one case per
-- constructor, a hypothesis for each field of x's own type), or from an
-- integer type's lower bound (the bound, then n from n - 1). In each case
-- the law's inputs are constants named as in its counterexample query, so a
-- model of a case is checked as the law's counterexample; the goal is P
-- there, the hypotheses are P at each smaller value (for those same other
-- inputs, and for all of them), and each cited law is assumed.
-- ref:DEC-smt-induction
inductionTasks :: Program -> Recursion -> Property -> String -> [Property] -> Either String [InductionCase]
inductionTasks program mode law input lemmas = do
  let (outer, rest) = outerQuantifiers law
      bits = programMachineBits program
      types = catalog program
  (index, q) <- case [(i, o) | (i, o) <- zip [0 :: Int ..] outer, binderName (quantifiedBinder o) == input] of
    [found] -> Right found
    _ -> Left ("induction on " ++ input ++ ": the law has no input " ++ input)
  let x = quantifiedBinder q
      ty = binderType x
      others = [o | (i, o) <- zip [0 ..] outer, i /= index]
      otherIds = map (binderId . quantifiedBinder) others
      xName = "lawspec_input_" ++ show index
  when (any (any (`elem` otherIds) . locals) (quantifiedPredicates q))
    (Left ("induction on " ++ input ++ ": its refinement uses another input"))
  shapes <- case (sort ty, ty) of
    (Right IntegerSort, Constructor name []) -> case integerBounds bits name of
      Just (lo, _) -> Right [IntegerBase lo, IntegerStep lo]
      Nothing | name == "BigUInt" -> Right [IntegerBase 0, IntegerStep 0]
      _ -> Left ("induction on " ++ input ++ ": an integer needs a lower bound to count down to")
    _ -> case declarationOf types ty of
      Right (declaration, table) -> Right [DataCase c [instantiate table (binderType f) | f <- constructorFields c] | c <- dataConstructors declaration]
      Left _ -> Left ("induction on " ++ input ++ ": its type is neither a data type nor a bounded integer")
  forM shapes $ \shape -> do
    ((name, body), _) <- runStateT (do
        rows <- forM (zip [0 :: Int ..] outer) $ \(j, o) -> do
          s <- quantifierSortOf program (binderType (quantifiedBinder o))
          pure ("lawspec_input_" ++ show j, o, s)
        let scope = M.fromList [(binderId (quantifiedBinder o), Term s n "true") | (n, o, s) <- rows]
        xSort <- sortOf program ty
        (label, fields, equation, smaller) <- case shape of
          DataCase c fieldTypes -> do
            fs <- forM (zip [0 :: Int ..] fieldTypes) $ \(k, ft) -> do
              s <- sortOf program ft
              let n = "lawspec_field_" ++ show k
              base <- lift (domain bits ft n)
              pure (n, s, base, ft)
            let built = if null fs then constructorSymbol ty c else app (constructorSymbol ty c) [n | (n, _, _, _) <- fs]
            pure ( input ++ " = " ++ shortName (constructorId c), fs, [app "=" [xName, built]]
                 , [Term xSort n "true" | (n, _, _, ft) <- fs, ft == ty] )
          IntegerBase lo -> pure (input ++ " = " ++ show lo, [], [app "=" [xName, integer lo]], [])
          IntegerStep lo -> pure (input ++ " > " ++ show lo, [], [app ">" [xName, integer lo]], [Term IntegerSort (app "-" [xName, "1"]) "true"])
        ranges <- lift (mapM (\(n, o, _) -> domain bits (binderType (quantifiedBinder o)) n) rows)
        restricted <- forM rows $ \(_, o, _) -> positive <$> restrictions program [] scope (quantifiedPredicates o)
        goal <- proposition program [] scope rest
        hypotheses <- plain $ fmap concat $ forM smaller $ \p -> do
          range <- lift (domain bits ty (value p))
          -- For every other input,
          let alone = M.singleton (binderId x) p
          guardAlone <- restrictions program [] alone (quantifiedPredicates q)
          general <- closure program alone others rest
          -- and for these other inputs.
          let here = M.insert (binderId x) p scope
          guardHere <- forM outer $ \o -> positive <$> restrictions program [] here (quantifiedPredicates o)
          specific <- proposition program [] here rest
          pure [ app "=>" [both [range, positive guardAlone], general]
               , app "=>" [both (range : guardHere), positive specific] ]
        cited <- plain $ forM lemmas $ \l -> closure program M.empty (propertyParameters l ++ propertyInputs l) (propertyBody l)
        prelude <- datatypePreamble program
        (options, functions) <- gets recursiveText
        let text = "; " ++ encodingName SmtLibV2 ++ "; induction on " ++ input ++ ": case " ++ label ++ "\n" ++
              options ++ prelude ++ functions ++
              concat ["(declare-const " ++ n ++ " " ++ sortText s ++ ")\n" | (n, _, s) <- rows] ++
              concat ["(declare-const " ++ n ++ " " ++ sortText s ++ ")\n" | (n, s, _, _) <- fields] ++
              concat ["(assert " ++ a ++ ")\n" | a <- [base | (_, _, base, _) <- fields] ++ equation ++ ranges ++ restricted ++ hypotheses ++ cited] ++
              "(assert " ++ no (positive goal) ++ ")\n"
        pure (label, text)) (start SmtLibV2 program mode)
    unless (length (take 1048577 body) <= 1048576) (Left "SMT query exceeds its output budget")
    pure (InductionCase name body ["lawspec_input_" ++ show j | j <- [0 .. length outer - 1]] mode Nothing)
  where
    -- Calls with no fuel: the function the same at every fuel.
    plain :: Encode a -> Encode a
    plain action = do
      outer <- gets fuel
      modify (\w -> w{fuel = "", patterned = True})
      result <- action
      modify (\w -> w{fuel = outer, patterned = False})
      pure result
    locals e = case expressionNode e of
      Local i -> [i]
      _ -> concatMap locals (children e)
    shortName (Id text) = reverse (takeWhile (/= ':') (reverse text))

-- | The universal closure of a law over some of its inputs, assumed as one
-- quantifier over all of them, as a positive certificate: for each input in
-- its type and refinement, the law holds. Prenex form is equivalent, since
-- each input's type and refinement use only the inputs before it and every
-- SMT sort has a value. Its triggers are the calls to recursive definitions
-- made in it that name every input (or a set of them that does together).
closure :: Program -> Scope -> [Quantifier] -> Proposition -> Encode String
closure program scope quantifiers body = do
  before <- gets (length . triggers)
  rows <- forM quantifiers $ \q -> do
    let binder = quantifiedBinder q
    s <- quantifierSortOf program (binderType binder)
    name <- fresh
    pure (q, binder, s, name)
  let local = foldl (\m (_, b, s, n) -> M.insert (binderId b) (Term s n "true") m) scope rows
  modify (\w -> w{bound = [n | (_, _, _, n) <- rows] ++ bound w})
  guards <- forM rows $ \(q, b, _, n) -> do
    base <- lift (domain (programMachineBits program) (binderType b) n)
    restricted <- restrictions program [] local (quantifiedPredicates q)
    pure (base, restricted)
  result <- proposition program [] local body
  made <- gets (drop before . triggers)
  inScope <- gets bound
  modify (\w -> w{bound = drop (length rows) (bound w)})
  let names = [n | (_, _, _, n) <- rows]
      spaced c = if c `elem` ("()" :: String) then ' ' else c
      tokens t = words (map spaced t)
      local' token = case token of
        'v' : digits -> not (null digits) && all (`elem` ("0123456789" :: String)) digits
        _ -> False
      closed t = all (`elem` inScope) (filter local' (tokens t))
      usable = [t | (i, t) <- zip [0 :: Int ..] made, t `notElem` take i made, closed t, any (`elem` tokens t) names]
      -- The largest calls: a call inside another would match too often,
      -- and each match would make new calls to match (a matching loop).
      whole = [t | t <- covering, not (any (\u -> u /= t && t `isInfixOf` u) covering)
                 , not (any nested covering) || nested t]
      nested t = length (filter ("|lawspec_function" `isPrefixOf`) (tokens t)) >= 2
      covering = [t | t <- usable, all (`elem` tokens t) names]
      -- Otherwise a multi-pattern: triggers that together name every input.
      cover chosen pending = case pending of
        [] -> Just (reverse chosen)
        n : _ -> case [t | t <- usable, n `elem` tokens t] of
          t : _ -> cover (t : chosen) [m | m <- pending, m `notElem` tokens t]
          [] -> Nothing
      patterns = case (whole, cover [] names) of
        -- The first, as written: an equation's left side. A trigger on
        -- each side of an equation such as associativity rewrites back and
        -- forth without end.
        (t : _, _) -> " :pattern (" ++ t ++ ")"
        ([], Just ts) -> " :pattern (" ++ unwords ts ++ ")"
        _ -> ""
      formula = foldr (\(base, restricted) inner -> eitherOf [no base, negative restricted, both [positive restricted, inner]])
        (positive result) guards
  pure $ if null rows then positive result
    else "(forall (" ++ unwords ["(" ++ n ++ " " ++ sortText s ++ ")" | (_, _, s, n) <- rows] ++ ") " ++
         (if null patterns then formula else "(! " ++ formula ++ patterns ++ ")") ++ ")"

