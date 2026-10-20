-- | Typed SMT-LIB tasks, with no solver or host IO in the compiler. The host
-- executes these tasks using an established prover. ref:DEC-typed-core-boundary
module LawSpec.Core.Smt (ProofTask(..), Encoding(..), encodingName, proofTasks, taskFingerprint) where

import Control.Monad (unless, when, foldM, forM)
import Control.Monad.State.Strict
import Data.Aeson (ToJSON(..), object, (.=))
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Binary as Binary
import LawSpec.Common (Diagnostic, InputDomain(..), Location, Quantification(..))
import LawSpec.Core
import LawSpec.Core.Validate (validateProgram)
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
        "trust" .= ("typed LawSpec translation and the selected SMT solver; no kernel-checked proof certificate"::String)]

taskFingerprint :: ProofTask -> String
taskFingerprint task = digestHex (digestString (concatMap frame
  [encodingName (taskEncoding task),taskProgram task,show (taskBits task),idText (taskOwner task),
   idText (taskLaw task),either id id (taskQuery task)]))
  where frame value = show (B.length (T.encodeUtf8 (T.pack value))) ++ ":" ++ value

proofTasks :: Program -> Either [Diagnostic] [ProofTask]
proofTasks program = do
  validateProgram program
  let fingerprint = digestHex (digest (BL.toStrict (Binary.encode program)))
  pure [ProofTask (unitId owner) (propertyId law) (propertyLocation law)
          fingerprint (programMachineBits program) (snd <$> task)
          -- A refused task names v1, the encoding that refused it.
          (either (const SmtLibV1) fst task)
       | owner <- programUnits program, law <- unitProperties owner
       , let task = query program law]

data Sort = BooleanSort | IntegerSort | RealSort | UnitSort deriving (Eq,Show)
data Term = Term { termSort :: Sort, value :: String, defined :: String }
data Certificate = Certificate { positive :: String, negative :: String }
-- The encoding a task needs so far: the newest any feature it uses requires.
data Work = Work { nextName :: Int, visited :: Int, required :: Encoding }

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
sortText :: Sort -> String
sortText BooleanSort = "Bool"
sortText UnitSort = "Bool"
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
  s <- sort ty
  pure $ case (s,ty) of
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
  (certificate, work) <- runStateT (proposition program [] M.empty
    (foldr (Quantified ForEvery) (propertyBody law) (propertyParameters law ++ propertyInputs law))) (Work 0 0 SmtLibV1)
  let script = "; " ++ encodingName (required work) ++ "; negate a positive certificate, including definedness\n" ++
        "(assert " ++ no (positive certificate) ++ ")\n"
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
      s <- lift (quantifierSort (binderType binder))
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
  expected <- lift (sort (expressionType source))
  term <- node
  unless (termSort term == expected) (lift (Left "SMT expression carrier mismatch"))
  valid <- lift (domain (programMachineBits program) (expressionType source) (value term))
  pure term{defined=both [defined term,valid]}
  where
    recurse=expression program active scope
    node=case expressionNode source of
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
        s <- lift (sort target)
        case (termSort term,s) of
          (a,b) | a==b -> pure term
          (IntegerSort,RealSort) -> pure term{termSort=s,value=app "to_real" [value term]}
          (RealSort,IntegerSort) -> pure term{termSort=s,value=app "to_int" [value term],
            defined=both [defined term,app "is_int" [value term]]}
          _ -> lift (Left "unsupported SMT conversion")
      ExternalCall name arguments -> call program active scope name arguments
      Helper Unreachable [] -> do
        s <- lift (sort (expressionType source))
        pure (Term s (case s of BooleanSort -> "false"; UnitSort -> "false"; _ -> "0") "false")
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
