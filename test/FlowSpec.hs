module FlowSpec (spec) where

import Data.Either (isRight)
import Data.List (isInfixOf, isPrefixOf, tails)
import Test.Hspec
import LawSpec.Compile
import LawSpec.Frontend (compileCore)
import LawSpec.Model hiding (Expectation)
import LawSpec.Parser (parseSource)

stack :: [String] -> String
stack extra = unlines $
  [ "unit example.flow"
  , "type Stack (n :: Natural) is"
  , "  | Empty where n = 0"
  , "  | Push top :: Int8 rest :: Stack m where n = m + 1"
  , "end"
  , "push :: (x :: Int8) -> Stack n / Stack (n + 1) -> Unit"
  , "pop :: Stack (n + 1) / Stack n -> Int8"
  , "size :: Stack n -> BigInt"
  ] ++ extra

law :: String -> String
law body = "law `l` is definition is " ++ body ++ " end end"

source :: [String] -> Source
source = Source "flow.lawspec" . stack

accepts :: [String] -> Expectation
accepts extra = compileCore 64 defaultGeneration [source extra] `shouldSatisfy` isRight

rejects :: String -> [String] -> Expectation
rejects fragment extra = case compile [source extra] of
  Left diagnostics -> concatMap show diagnostics `shouldSatisfy` isInfixOf fragment
  Right _ -> expectationFailure ("expected rejection mentioning " ++ show fragment)

-- The positions at which each needle first occurs, in order.
ordered :: [String] -> String -> Bool
ordered needles haystack = increasing (map position needles)
  where
    position needle = lookup True [(needle `isPrefixOf` rest, i) | (i, rest) <- zip [0 :: Int ..] (tails haystack)]
    increasing ps = all (/= Nothing) ps && and (zipWith (<) ps (drop 1 ps))

spec :: Spec
spec = describe "flow typing" $ do
  describe "typestate" $ do
    it "accepts a pop after a push" $
      accepts [law "`for all` (x :: Int8) (s :: Stack n) . (push x ~s; pop ~s) = x"]
    it "inverts the index pattern of the quantifier" $
      accepts [law "`for all` (s :: Stack (k + 2)) . (pop ~s; pop ~s; size s) = k"]
    it "rejects a pop the state cannot take, suggesting a bound" $
      rejects "add `where n >= 1`" [law "`for all` (s :: Stack n) . pop ~s = 0"]
    it "tracks each call: a second pop after one push is rejected" $
      rejects "pop needs Stack (n + 1)"
        [law "`for all` (x :: Int8) (s :: Stack n) . (push x ~s; pop ~s; pop ~s) = x"]
    it "evaluates left to right" $ do
      let Right u = parseSource (source [law "`for all` (x :: Int8) (y :: Int8) (s :: Stack n) . (push x ~s; push y ~s; pop ~s) = y"])
      show (laws u) `shouldSatisfy` ordered ["(Var \"x\"))) (Var \"s\")", "(Var \"y\"))) (Var \"s_flow0\")", "(Var \"pop\") (Var \"s_flow2\")"]
  describe "linearity" $ do
    it "requires ~ to pass a state to a flow parameter" $
      rejects "write ~s" [law "`for all` (s :: Stack (k + 1)) . pop s = 0"]
    it "rejects ~ on an argument that is not a flow parameter" $
      rejects "does not take a flow parameter" [law "`for all` (x :: Int8) (s :: Stack n) . (push ~x ~s; size s) = 1"]
    it "rejects ~ on a name that is not a quantified variable" $
      rejects "is not a quantified variable" [law "`for all` (s :: Stack (k + 1)) . pop ~t = 0"]
    it "accepts a flow call in each branch of an if that leaves the state at one type" $
      accepts [law "`for all` (x :: Int8) (s :: Stack n) . ((if x > 0 then push x ~s else push 0 ~s); pop ~s) = x"]
    it "accepts flow calls in a match branch that leave the state where they found it" $
      accepts [law "`for all` (x :: Int8) (s :: Stack n) . (match s with | Empty -> prelude.Int8 0 | Push t r -> (push x ~s; pop ~s) end) = 0"]
    it "rejects using a state the branches left at different types, naming each branch" $
      rejects "is Stack (n + 1) in the then branch, but Stack n in the else branch"
        [law "`for all` (x :: Int8) (s :: Stack n) . ((if x > 0 then push x ~s else unitValue); pop ~s) = x"]
    it "rejects a flow call after && where it may not run" $
      rejects "cannot appear after && / ||"
        [law "`for all` (x :: Int8) (s :: Stack (k + 1)) . (x > 0 && pop ~s == x) = true"]
    it "rejects ~ outside a call" $
      rejects "allowed only as an argument" ["f :: (n :: Int8 where ~n > 0) -> Int8"]
  describe "signatures" $ do
    it "accepts several flow parameters, each rebound by its own state" $
      accepts
        [ "definition pushBoth (x :: Int8) (a :: Stack n / Stack (n + 1)) (b :: Stack m / Stack (m + 1)) :: Unit is ~a := Push x a; ~b := Push x b end"
        , law "`for all` (x :: Int8) (a :: Stack n) (b :: Stack m) . (pushBoth x ~a ~b; pop ~a; pop ~b) = x" ]
    it "rejects passing one state to two flow parameters" $
      rejects "given the same state twice"
        [ "swap :: Stack n / Stack n -> Stack m / Stack m -> Unit"
        , law "`for all` (s :: Stack n) . (swap ~s ~s; size s) = 0" ]
    it "rejects a flow type outside an argument" $
      rejects "legal only as" ["make :: Int8 -> Stack n / Stack n"]
  describe "desugaring" $ do
    it "returns a generated product from each flow function" $ do
      let Right u = parseSource (source [])
      lookup "pop" (functions u) `shouldSatisfy` maybe False (isInfixOf "PopFlow" . show)
      map dataTypeName (dataTypes u) `shouldSatisfy` (\names -> "PushFlow" `elem` names && "PopFlow" `elem` names)
    it "binds each call's result and state by matching its product" $ do
      let Right u = parseSource (source [law "`for all` (x :: Int8) (s :: Stack n) . (push x ~s; pop ~s) = x"])
      show (laws u) `shouldSatisfy` ordered ["MatchBranch \"PushFlow\"", "MatchBranch \"PopFlow\""]
  describe "definitions" $ do
    it "updates the flow parameter with :=" $
      accepts
        [ "definition pushed (x :: Int8) (s :: Stack n / Stack (n + 1)) :: Unit is ~s := Push x s end"
        , law "`for all` (x :: Int8) (s :: Stack n) . (pushed x ~s; pop ~s) = x" ]
    it "checks the final state's index with the index prover" $
      case compileCore 64 defaultGeneration [source ["definition keep (x :: Int8) (s :: Stack n / Stack (n + 1)) :: Unit is ~s := s end"]] of
        Left _ -> pure ()
        Right _ -> expectationFailure "expected the unchanged stack to be rejected"
    it "updates only its own flow parameter" $
      rejects "updates only one of the definition's own flow parameters"
        ["definition other (x :: Int8) (s :: Stack n / Stack (n + 1)) :: Unit is ~t := Push x s end"]
