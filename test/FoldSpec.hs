-- | A left or right fold over a list takes its step where it is written: a
-- named definition, a partial application or a composition. It is one Core
-- node, which the reference evaluator runs. ref:DEC-capability-instances
module FoldSpec (test_listsFold) where

import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.CoreEmit (emitPlan)
import LawSpec.Frontend (compileCore)
import LawSpec.Targets (programTargets)
import LawSpec.Testing (planTesting)

program :: [String] -> Either [Diagnostic] C.Program
program body = compileCore 64 defaultGeneration
  [Source "folds.lawspec" (unlines (["unit folds.checked"] ++ helpers ++ body ++ ["end unit"]))]

evaluated :: [String] -> Either [Diagnostic] ()
evaluated body = program body >>= dischargeEvidence >>= \_ -> pure ()

failsWith :: String -> Either [Diagnostic] a -> Bool
failsWith needle = either (any ((needle `isInfixOf`) . message)) (const False)

law :: [String] -> [String]
law statement = ["law \"|folded| is definition :"] ++ statement ++ ["end definition end law"]

helpers :: [String]
helpers =
  [ "function add (a :: Integer) (b :: Integer) -> Integer is a + b end function"
  , "function minus (a :: Integer) (b :: Integer) -> Integer is a - b end function"
  , "function double (n :: Integer) -> Integer is n * 2 end function"
  , "function isEven (n :: Integer) -> Bool is prelude.rem n 2 = 0 end function"
  , "function before (x :: Integer) (xs :: List Integer) -> List Integer is Cons x xs end function"
  , "function after (xs :: List Integer) (x :: Integer) -> List Integer is Cons x xs end function"
  , "function weighted (factor :: Integer) (total :: Integer) (x :: Integer) -> Integer is total + factor * x end function"
  , "function tally (count :: Integer) (flag :: Bool) -> Integer is if flag then count + 1 else count end if end function" ]

-- | Every expression of the program's laws and definitions.
expressions :: C.Program -> [C.Expr]
expressions compiled = concatMap every
  ([C.definitionBody d | u <- C.programUnits compiled, d <- C.unitDefinitions u] ++
   [e | u <- C.programUnits compiled, p <- C.unitProperties u, e <- C.propositionExpressions (C.propertyBody p)])
  where every e = e : concatMap every (C.children e)

folds :: C.Program -> [(Bool, C.Expr)]
folds compiled = [(fromLeft, e) | e <- expressions compiled, C.FoldElements fromLeft _ _ _ _ _ <- [C.expressionNode e]]

test_listsFold :: Spec
test_listsFold =
  describe "folds over a list" $ do
    it "sums from the left and from the right" $
      evaluated (law
        [ "  prelude.foldLeft add 0 [1, 2, 3] = 6 and prelude.foldRight add 0 [1, 2, 3] = 6" ])
        `shouldSatisfy` isRight
    it "groups a left fold from the first element and a right fold from the last" $
      evaluated (law
        [ "  prelude.foldLeft minus 10 [1, 2, 3] = 4 and prelude.foldRight minus 10 [1, 2, 3] = -8" ])
        `shouldSatisfy` isRight
    it "rebuilds a list from the right and reverses it from the left" $
      evaluated (law
        [ "  prelude.foldRight before [] [1, 2, 3] = [1, 2, 3] and prelude.foldLeft after [] [1, 2, 3] = [3, 2, 1]" ])
        `shouldSatisfy` isRight
    it "gives the initial value for an empty list" $
      evaluated (law
        [ "  prelude.foldLeft add 7 [] = 7 and prelude.foldRight add 7 [] = 7"
        , "    and prelude.foldRight before [4] [] = [4]" ])
        `shouldSatisfy` isRight
    it "accumulates a type other than the element's" $
      evaluated (law
        [ "  prelude.foldLeft tally 0 [true, false, true] = 2" ])
        `shouldSatisfy` isRight
    it "takes a partial application, whose argument is an expression" $
      evaluated (law
        [ "  prelude.foldLeft (weighted (1 + 1)) 0 [1, 2, 3] = 12 and prelude.foldLeft (weighted 3) 1 [1] = 4" ])
        `shouldSatisfy` isRight
    it "takes a composition" $
      evaluated (law
        [ "  prelude.foldLeft (add . double) 1 [1, 1] = 7" ])
        `shouldSatisfy` isRight
    it "folds a list that is not a literal, with an initial value that is computed" $
      evaluated
        ([ "function sum (xs :: List Integer) -> Integer is prelude.foldLeft add (double 0) xs end function"
         , "function sumOfDoubles (xs :: List Integer) -> Integer is prelude.foldRight add 0 (prelude.map double xs) end function" ] ++ law
        [ "  sum [1, 2, 3] = 6 and sum [] = 0 and sumOfDoubles [1, 2, 3] = 12" ])
        `shouldSatisfy` isRight
    it "folds with the enclosing definition's own function parameter" $
      evaluated
        ([ "function total (f :: Integer -> Integer -> Integer) (xs :: List Integer) -> Integer is prelude.foldLeft f 0 xs end function"
         , "function totalRight (f :: Integer -> Integer -> Integer) (start :: Integer) (xs :: List Integer) -> Integer is"
         , "  prelude.foldRight f start xs end function" ] ++ law
        [ "  total add [1, 2, 3] = 6 and total minus [1, 2, 3] = -6 and totalRight minus 10 [1, 2, 3] = -8" ])
        `shouldSatisfy` isRight
    it "takes its literals' types from the step" $
      evaluated
        ([ "function larger (a :: Int32) (b :: Int32) -> Int32 is if a > b then a else b end if end function" ] ++ law
        [ "  prelude.foldLeft larger 0 [1, 3, 2] = 3 and prelude.foldRight larger 5 [1, 3, 2] = 5" ])
        `shouldSatisfy` isRight
    it "works without the prelude qualifier" $
      evaluated (law
        [ "  foldLeft add 0 [1, 2, 3] = 6 and foldRight minus 10 [1, 2, 3] = -8" ])
        `shouldSatisfy` isRight
    it "refutes a wrong result" $ do
      evaluated (law ["  prelude.foldLeft add 0 [1, 2] = 4"]) `shouldSatisfy` isLeft
      evaluated (law ["  prelude.foldRight minus 10 [1, 2, 3] = 4"]) `shouldSatisfy` isLeft
      evaluated (law ["  prelude.foldLeft after [] [1, 2, 3] = [1, 2, 3]"]) `shouldSatisfy` isLeft
    it "rejects a step of the wrong type" $ do
      program (law ["  prelude.foldLeft isEven 0 [1, 2] = 0"]) `shouldSatisfy` isLeft
      program (law ["  prelude.foldLeft tally 0 [1, 2] = 0"]) `shouldSatisfy` isLeft
      -- A right fold's step takes the element first.
      program (law ["  prelude.foldRight tally 0 [true] = 1"]) `shouldSatisfy` isLeft
    it "rejects an operand that is not a list, saying so" $
      program
        ([ "function sumOf (n :: Integer) -> Integer is prelude.foldLeft add 0 n end function" ] ++ law
        [ "  sumOf 1 = 1" ])
        `shouldSatisfy` failsWith "fold requires a List"
    it "lowers each fold to one Core node that keeps its direction" $
      case program (law ["  prelude.foldLeft add 0 [1] = 1 and prelude.foldRight add 0 [1] = 1"]) of
        Left problems -> expectationFailure (show problems)
        Right compiled -> map fst (folds compiled) `shouldMatchList` [True, False]
    it "binds the accumulator and the element in the body alone" $
      case program (law ["  prelude.foldLeft add 0 [1] = 1"]) of
        Left problems -> expectationFailure (show problems)
        Right compiled -> case [C.expressionNode e | (_, e) <- folds compiled] of
          [C.FoldElements _ value initial accumulator binder body] -> do
            C.binderId accumulator `shouldNotBe` C.binderId binder
            C.freeBinders body `shouldMatchList` [C.binderId accumulator, C.binderId binder]
            C.freeBinders value ++ C.freeBinders initial `shouldBe` []
          other -> expectationFailure ("expected one fold, found " ++ show (length other))
    it "evaluates a step's captured argument once, before the fold" $
      case program (law ["  prelude.foldLeft (weighted (1 + 1)) 0 [1, 2] = 6"]) of
        Left problems -> expectationFailure (show problems)
        Right compiled ->
          [() | e <- expressions compiled, C.Let _ _ rest <- [C.expressionNode e], C.FoldElements {} <- [C.expressionNode rest]]
            `shouldBe` [()]
    -- Each target runs the fold itself, with its own loop or library fold.
    it "is emitted by every target, in both directions" $ do
      let source =
            [ "function sum (xs :: List Integer) -> Integer is prelude.foldLeft add 0 xs end function"
            , "function rebuilt (xs :: List Integer) -> List Integer is prelude.foldRight before [] (prelude.map double xs) end function" ] ++ law
            [ "  sum [1, 2, 3] = 6 and rebuilt [1, 2] = [2, 4] and prelude.foldLeft (weighted (1 + 1)) 0 [1, 2] = 6" ]
          outcome target = case program source >>= planTesting >>= emitPlan target of
            Right _ -> []
            Left problems -> [(target, take 200 (unwords (map message problems)))]
      concatMap outcome programTargets `shouldBe` []
