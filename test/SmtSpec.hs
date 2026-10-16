-- | Check the compiler's encoding with the real solver, including failures
-- that a total SMT arithmetic interpretation would otherwise conceal.
module SmtSpec (test_smtTasks) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import Data.Either (isLeft)
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
import Test.Hspec
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Testing (planTesting)
import Data.Either (isRight)
import qualified LawSpec.Model as S
import qualified LawSpec.Core.Smt as SMT
import qualified LawSpec.Core as C
import qualified LawSpec.Api as API
import Data.Aeson (Value(..),object,(.=),decode,encode,toJSON)
import qualified Data.Aeson.KeyMap as K
import Data.Foldable (toList)

compile bits body=compileCoreCanonical bits S.defaultGeneration
  [S.Source "smt.lawspec" ("unit smt\n"++body)]
tasks bits body=compile bits body >>= SMT.proofTasks
law text="law selected is definition: "++text++" end end"
solver action=do
  explicit<-lookupEnv "LAWSPEC_Z3"
  installed<-maybe (findExecutable "z3") (pure . Just) explicit
  case installed of
    Nothing->pendingWith "install Z3 or set LAWSPEC_Z3 for solver integration checks"
    Just binary->action binary
checkResult expected body=forM_ [32,64] $ \bits -> checkAt bits expected body
checkAt bits expected body=solver $ \binary -> do
  program<-either (fail . show) pure (tasks bits body)
  length program `shouldBe` 1
  script<-either fail pure (SMT.taskQuery (head program))
  (status,output,errors)<-readProcessWithExitCode binary ["-in","-smt2","-t:5000"] (script++"(check-sat)\n")
  (status,words output,errors) `shouldBe` (ExitSuccess,[expected],"")

test_smtTasks=describe "typed SMT obligations" $ do
  it "proves nonlinear checked definitions with Z3 rather than a custom arithmetic extension" $
    checkResult "unsat" $ unlines [
      "function square (n :: Integer) -> Integer is n * n end function",
      law "for all (n :: Integer) => square n >= 0 end"]
  it "retains the order of dependent universal and existential binders" $ do
    checkResult "unsat" (law "for all (n :: Integer) => there exists (next :: Integer where next > n) such that next = n + 1 end end")
    checkResult "sat" (law "there exists (next :: Integer) such that for all (n :: Integer) => next > n end end")
  it "proves nonexistence separately from failure to find a candidate" $
    checkResult "unsat" (law "there does not exist (n :: Integer) such that n * n < 0 end")
  it "keeps empty universal and existential domains distinct" $ do
    checkResult "unsat" (law "for all (n :: Integer where false) => false end")
    checkResult "sat" (law "there exists (n :: Integer where false) such that true end")
  it "includes unsigned and profile-sized carrier bounds" $ do
    checkResult "sat" (law "for all (n :: Whole) => n > 0 end")
    checkResult "unsat" (law "for all (n :: Whole) => n >= 0 end")
    checkResult "sat" (law "for all (n :: UInt8) => n < 255 end")
    checkResult "unsat" (law "for all (n :: UInt8) => n >= 0 and n <= 255 end")
    checkResult "unsat" (law "for all (n :: UIntSize) => n >= 0 end")
    checkAt 32 "unsat" (law "for all (n :: UIntSize) => n <= 4294967295 end")
    checkAt 64 "sat" (law "for all (n :: UIntSize) => n <= 4294967295 end")
  it "does not prove a reflexive equality whose operands divide by zero" $
    checkResult "sat" (law "1 / 0 = 1 / 0")
  it "preserves short-circuit and conditional definedness" $ do
    checkResult "unsat" (law "not (false and 1 / 0 = 1)")
    checkResult "unsat" (law "(if false then 1 / 0 else rational(1, 2) end if) = rational(1, 2)")
    checkResult "sat" (law "for all (n :: Integer) => not (n / (n - n) = 0 and false) end")
  it "does not prove nonexistence by treating undefined candidates as false" $
    checkResult "sat" (law "there does not exist (n :: Integer) such that n / (n - n) = 0 end")
  it "does not discard an undefined unused argument" $
    checkResult "sat" ("function keep (n :: Rational) -> Bool is true end function\n"++law "keep (1 / 0) must be true")
  it "checks a callee's refined precondition instead of assuming it" $
    checkResult "sat" ("function keep (n :: Nat) -> Bool is true end function\n"++law "keep 0 must be true")
  it "preserves deferred runtime result enforcement" $
    checkResult "sat" ("function broken (n :: Integer) -> (r :: Integer where r > n * n) is 0 end function\n"++law "broken 0 must be 0")
  it "encodes truncating integer quotient and remainder for both operand signs" $ do
    checkResult "unsat" (law "prelude.quot (-7) 3 = -2 and prelude.rem (-7) 3 = -1 and prelude.quot 7 (-3) = -2 and prelude.rem 7 (-3) = 1")
    checkResult "sat" (law "prelude.quot (-7) 3 = -3")
  it "requires lossless in-range exact conversions" $ do
    checkResult "sat" (law "for all (n :: Integer) => n = 256 implies prelude.UInt8 n = prelude.UInt8 n end")
    checkResult "sat" (law "for all (n :: Integer) => n = 1 implies prelude.Integer (n / 2) = 0 end")
    checkResult "unsat" (law "prelude.Integer (rational(-4, 2)) = -2")
  it "never quantifies Rational as Real and thereby invents an irrational witness" $
    case tasks 64 (law "there exists (n :: Rational) such that n * n = 2 end") of
      Left ds->expectationFailure (show ds)
      Right [task]->SMT.taskQuery task `shouldSatisfy` either (isInfixOf "Rational quantification") (const False)
      Right _->expectationFailure "missing Rational task"
  it "does not reinterpret IEEE values as exact arithmetic" $
    case tasks 64 (law "for all (n :: Float64) => n = n end") of
      Left ds->expectationFailure (show ds)
      Right [task]->SMT.taskQuery task `shouldSatisfy` isLeft
      Right _->expectationFailure "missing IEEE task"
  it "does not invent implementations for native declarations" $
    case tasks 64 ("external :: Integer -> Integer\n"++law "for all (n :: Integer) => external n = external n end") of
      Left ds->expectationFailure (show ds)
      Right [task]->SMT.taskQuery task `shouldSatisfy` isLeft
      Right _->expectationFailure "missing native task"
  it "binds tasks to the exact typed program, law, query and machine profile" $ do
    a<-either (fail . show) (pure . head) (tasks 64 (law "for all (n :: Integer) => n + 1 > n end"))
    b<-either (fail . show) (pure . head) (tasks 32 (law "for all (n :: Integer) => n + 1 > n end"))
    c<-either (fail . show) (pure . head) (tasks 64 (law "for all (n :: Integer) => n + 2 > n end"))
    SMT.taskFingerprint a `shouldNotBe` SMT.taskFingerprint b
    SMT.taskFingerprint a `shouldNotBe` SMT.taskFingerprint c
    SMT.taskFingerprint a `shouldNotBe` SMT.taskFingerprint a{SMT.taskLaw=C.Id "other"}
    SMT.taskFingerprint a `shouldNotBe` SMT.taskFingerprint a{SMT.taskQuery=Right "(assert false)\n"}
  it "shares typed call arguments instead of duplicating their source terms exponentially" $ do
    let repeated=iterate (\body->"twice ("++body++")") "n" !! 40
        source="function twice (n :: Integer) -> Integer is n + n end function\n"++
          law ("for all (n :: Integer) => "++repeated++" = n * 1099511627776 end")
    checkResult "unsat" source
    result<-either (fail . show) (pure . head) (tasks 64 source)
    script<-either fail pure (SMT.taskQuery result)
    length script `shouldSatisfy` (<100000)
  it "leaves no-layer requests unverified and still performs mandatory definition validation" $ do
    let request content=object ["schemaVersion".= (5::Int),"languageProfile".= ("1.0-rc.1"::String),
          "method".= ("proofTasks"::String),"verification".=object ["layers".= ([]::[String])],
          "sources".=[object ["path".= ("smt.lawspec"::String),"content".=content]]]
        response body=decode (API.dispatch (encode (request ("unit smt\n"++body))))::Maybe Value
    case response (law "true") of
      Just (Object result)->K.lookup "proofTasks" result `shouldBe` Just (toJSON ([]::[Int]))
      _->expectationFailure "missing proof task response"
    case response "function broken (n :: Integer) -> Rational is 1 / 0 end function" of
      Just (Object result)->K.lookup "diagnostics" result `shouldSatisfy` maybe False (/=toJSON ([]::[Int]))
      _->expectationFailure "missing mandatory failure"
  it "does not let prepared tasks reuse or overwrite completed optional proof cache entries" $ do
    let request method=object ["schemaVersion".= (5::Int),"languageProfile".= ("1.0-rc.1"::String),
          "method".= (method::String),"verification".=object ["layers".= ["proof"::String]],
          "sources".=[object ["path".= ("smt-cache.lawspec"::String),"content".= ("unit smt\n"++law "true")]]]
        status method=case decode (API.dispatch (encode (request method)))::Maybe Value of
          Just (Object result) | Just (Array rows)<-K.lookup "evidence" result ->
            [K.lookup "status" row | Object row<-toList rows,K.lookup "stage" row==Just (String "law")]
          _ -> []
    status "check" `shouldBe` [Just (String "proved")]
    status "proofTasks" `shouldBe` [Just (String "planned")]
    status "check" `shouldBe` [Just (String "proved")]
  it "agrees with independent finite existential and dependent-domain oracles" $ do
    forM_ [0..12::Integer] $ \target -> do
      let exists=any (\n->n*n==target) [-3..3]
          body="(n :: Int8 where n >= -3 and n <= 3) such that n * n = "++show target++" end"
      checkResult (if exists then "unsat" else "sat") (law ("there exists "++body))
      checkResult (if exists then "sat" else "unsat") (law ("there does not exist "++body))
    let forallExists predicate=all (\x -> any (predicate x) [x,x+1]) [-3..3::Integer]
        body relationship=law ("for all (x :: Int8 where x >= -3 and x <= 3) => "++
          "there exists (y :: Int8 where y >= x and y <= x + 1) such that "++relationship++" end end")
    checkResult (if forallExists (\x y->y*y>=x*x) then "unsat" else "sat") (body "y * y >= x * x")
    checkResult (if forallExists (\x y->y>x && y*y>=x*x) then "unsat" else "sat") (body "y > x and y * y >= x * x")
  it "prepares the four-law arithmetic demonstration for Z3 and every native target" $ solver $ \binary -> do
    source<-readFile "test/fixtures/canonical-smt-arithmetic.lawspec"
    forM_ [32,64] $ \bits -> do
      program<-either (fail . show) pure (compileCoreCanonical bits S.defaultGeneration [S.Source "arithmetic.lawspec" source])
      prepared<-either (fail . show) pure (SMT.proofTasks program)
      length prepared `shouldBe` 4
      sum [length (C.propertyExamples property) | owner<-C.programUnits program,property<-C.unitProperties owner] `shouldBe` 7
      forM_ prepared $ \task -> do
        script<-either fail pure (SMT.taskQuery task)
        (status,output,errors)<-readProcessWithExitCode binary ["-in","-smt2","-t:5000"] (script++"(check-sat)\n")
        (status,words output,errors) `shouldBe` (ExitSuccess,["unsat"],"")
      plan<-either (fail . show) pure (planTesting program)
      forM_ targets $ \target -> emitPlan target plan `shouldSatisfy` isRight
