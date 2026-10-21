-- | Typed SMT-LIB tasks, with no solver or host IO in the compiler. The host
-- executes these tasks using an established prover. ref:DEC-typed-core-boundary
module LawSpec.Core.Smt (ProofTask(..), Encoding(..), CounterexampleQuery(..), encodingName, proofTasks, taskFingerprint
  , counterexampleFingerprint, outerQuantifiers, Catalog, catalog, instantiate) where

import Control.Monad (unless, when, foldM, forM, forM_)
import Control.Monad.State.Strict
import Data.Aeson (ToJSON(..), object, (.=))
import qualified Data.Map.Strict as M
import Data.Graph (SCC(..), stronglyConnComp, flattenSCCs)
import Data.List (intercalate)
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
  } deriving (Eq, Show)

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
        [ "counterexampleUnsupported" .= reason | Left reason <- [taskCounterexample task] ]

taskFingerprint :: ProofTask -> String
taskFingerprint task = digestHex (digestString (concatMap frame
  [encodingName (taskEncoding task),taskProgram task,show (taskBits task),idText (taskOwner task),
   idText (taskLaw task),either id id (taskQuery task)]))
  where frame value = show (B.length (T.encodeUtf8 (T.pack value))) ++ ":" ++ value

-- | The counterexample query's own binding, framed as a task's is.
counterexampleFingerprint :: ProofTask -> CounterexampleQuery -> String
counterexampleFingerprint task query = digestHex (digestString (concatMap frame
  [encodingName SmtLibV2,taskProgram task,show (taskBits task),idText (taskOwner task),
   idText (taskLaw task),counterexampleScript query]))
  where frame value = show (B.length (T.encodeUtf8 (T.pack value))) ++ ":" ++ value

proofTasks :: Program -> Either [Diagnostic] [ProofTask]
proofTasks program = do
  validateProgram program
  let fingerprint = digestHex (digest (BL.toStrict (Binary.encode program)))
  pure [ProofTask (unitId owner) (propertyId law) (propertyLocation law)
          fingerprint (programMachineBits program) (snd <$> task)
          -- A refused task names v1, the encoding that refused it.
          (either (const SmtLibV1) fst task)
          (either Left (const (counterexampleQuery program law)) task)
       | owner <- programUnits program, law <- unitProperties owner
       , let task = query program law]

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
      pure (rows, result, prelude)) (Work 0 0 SmtLibV2 [] (catalog program))
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
                 , datatypes :: [Type], known :: Catalog }

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

query :: Program -> Property -> Either String (Encoding, String)
query program law = do
  unless (propertyInputDomain law == UniversalDomain)
    (Left "SMT law tasks require the canonical universal input-domain policy")
  unless (null (propertyResources law)) (Left "SMT translation does not execute resources")
  unless (null (propertyHandlers law)) (Left "SMT translation does not execute ability handlers")
  ((certificate, prelude), work) <- runStateT (do
      certificate <- proposition program [] M.empty
        (foldr (Quantified ForEvery) (propertyBody law) (propertyParameters law ++ propertyInputs law))
      prelude <- datatypePreamble program
      pure (certificate, prelude)) (Work 0 0 SmtLibV1 [] (catalog program))
  let script = "; " ++ encodingName (required work) ++ "; negate a positive certificate, including definedness\n" ++
        prelude ++ "(assert " ++ no (positive certificate) ++ ")\n"
  unless (length (take 1048577 script) <= 1048576) (Left "SMT query exceeds its output budget")
  pure (required work, script)

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
      let local=M.insert (binderId binder) (Term s name "true") scope
      base <- lift (domain (programMachineBits program) (binderType binder) name)
      restricted <- restrictions program active local (quantifiedPredicates q)
      result <- proposition program active local body
      let quantify keyword formula = "(" ++ keyword ++ " ((" ++ name ++ " " ++ sortText s ++ ")) " ++ formula ++ ")"
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
