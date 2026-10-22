-- | Positional products share checked structural elaboration and ordered
-- matching; parameter patterns keep mandatory irrefutability and contracts.
-- ref:DEC-readable-notation ref:DEC-total-definitions
module SourceTupleSpec (test_positionalProducts,checkOutcomes) where

import Test.Hspec
import Control.Monad (forM_)
import Control.Exception (evaluate)
import Data.IORef
import System.IO.Unsafe (unsafePerformIO)
import Data.Either (isRight)
import qualified LawSpec.Model as S
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCoreCanonical)
import LawSpec.Core.Validate (validateProgram)
import LawSpec.Core.Types (makeRegistry)
import LawSpec.Core.Definitions (prepareDefinitions,prepareHookedDefinitions)
import LawSpec.Core.Value (Value(..))
import LawSpec.Scalar (Scalar(..))
import LawSpec.Core.Eval (evaluateValue,evaluateValueProposition)
import LawSpec.CoreEmit (emitPlan,targets)
import LawSpec.Testing (planTesting)
import LawSpec.SourceText (formatSource)

compile body=compileCoreCanonical 64 S.defaultGeneration [S.Source "tuples.lawspec" ("unit products\n\n"++body ++ "\nend unit\n")]
checkOutcomes candidate=do
  validateProgram candidate `shouldBe` Right ()
  case (makeRegistry (C.programDataDeclarations candidate),prepareDefinitions candidate,planTesting candidate) of
    (Right registry,Right invoke,Right plan)->do
      forM_ (concatMap C.unitProperties (C.programUnits candidate)) $ \law -> do
        if null (C.propertyInputs law) then evaluateValueProposition registry (C.programMachineBits candidate) invoke [] (C.propertyBody law) `shouldBe` Right True else pure ()
        forM_ (C.propertyExamples law) $ \example -> do
          bindings<-either (fail.show) pure (mapM (\(name,value)->(,) name <$> evaluateValue registry (C.programMachineBits candidate) invoke [] value) (C.exampleBindings example))
          forM_ (C.exampleExpectations example) $ \expectation ->
            evaluateValueProposition registry (C.programMachineBits candidate) invoke bindings expectation `shouldBe` Right True
      [(target,diagnostics) | target<-targets,Left diagnostics<-[emitPlan target plan]] `shouldBe` []
    _ -> expectationFailure "tuple program did not reach the checked evaluator"
checked body=either (expectationFailure.show) checkOutcomes (compile body)
rejects body=case compile body of Left _ -> pure (); Right _ -> expectationFailure ("expected rejection: "++body)

observePosition :: IORef [Integer] -> [Value] -> Either String Value
observePosition trace [value@(ScalarValue (SInteger _ position))]=unsafePerformIO $ do
  modifyIORef' trace (++[position])
  pure (Right value)
observePosition _ _=Left "invalid observed position"
{-# NOINLINE observePosition #-}

test_positionalProducts=describe "canonical positional products" $ do
  it "executes the positional-products demonstration and emits every target at both widths" $ do
    source<-readFile "test/fixtures/canonical-positional-products.lawspec"
    forM_ [32,64] $ \bits -> either (expectationFailure.show) checkOutcomes
      (compileCoreCanonical bits S.defaultGeneration [S.Source "positional.lawspec" source])
  it "constructs, annotates and matches heterogeneous tuples without Eq on generic fields" $ checked $ unlines
    [ "function first (pair of type (a, b)) -> a is first matching case of pair: when (left, _) then left end case end function\n"
    , "function second (pair of type (a, b)) -> b is first matching case of pair: when (_, right) then right end case end function\n"
    , "law selected is definition: first (7, false) = 7 and second (7, false) = false and ((3, true) :: (Integer, Bool)) = (3, true) end definition end law" ]
  it "composes tuple, record and alternative patterns recursively with ordered guards" $ checked $ unlines
    [ "type Packet is one of | Empty | Wrapped of type (record{flag of type Bool}, (Integer, Text)) end type\n"
    , "function selected (packet of type Packet) -> Integer is first matching case of packet:"
    , "when Wrapped (record{flag = true}, (number, _)) if number > 0 then number"
    , "when Wrapped (_, (number, _)) then 0 when Empty then -1 end case end function"
    , "law outcomes is definition: selected (Wrapped (record{flag = true}, (7, \"yes\"))) = 7 and selected (Wrapped (record{flag = false}, (7, \"no\"))) = 0 and selected Empty = -1 end definition end law" ]
  it "keeps positions above nine independent of canonical structural field sorting" $ checked $ unlines
    [ "function tenth (values of type (Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Bool, Text)) -> Bool is"
    , "first matching case of values: when (_, _, _, _, _, _, _, _, _, tenth, _) then tenth end case end function"
    , "law outcome is definition: tenth (1, 2, 3, 4, 5, 6, 7, 8, 9, true, \"eleven\") = true end definition end law" ]
  it "evaluates all tuple components once in source order before destructuring" $ do
    let source=unlines
          [ "ability Trace is mark :: Integer -> Integer end ability"
          , "function selected ((_, _, _, _, _, _, _, _, _, tenth, _) of type (Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer)) -> Integer is tenth end function\n"
          , "procedure observed (ignored of type ()) -> Integer is selected (mark 1, mark 2, mark 3, mark 4, mark 5, mark 6, mark 7, mark 8, mark 9, mark 10, mark 11) end procedure\n" ]
    program<-either (fail.show) pure (compile source)
    trace<-newIORef []
    invoke<-either (fail.show) pure (prepareHookedDefinitions program)
    let hook _ identity | C.idText identity=="products::ability::Trace::mark"=Just (observePosition trace)
                        | otherwise=Nothing
        answer=invoke hook (C.Id "products::observed") [ScalarValue (SAbsent "Unit")]
    _<-evaluate (length (show answer))
    answer `shouldBe` Right (ScalarValue (SInteger "Integer" 10))
    readIORef trace `shouldReturn` [1..11]
  it "rejects wrong tuple arity, positional types, grouping and nominal unwrapping" $ do
    let first="function first (value of type (Integer, Bool)) -> Integer is first matching case of value: when (left, _) then left end case end function\n"
    forM_ ["(true, 3)","(3, true, false)","record{first = 3, second = true}","()"] $ \value ->
      rejects (first++"law invalid is definition: first "++value++" = 3 end definition end law")
    rejects "function invalid (value of type (Integer, Bool, Text)) -> Bool is first matching case of value: when (_, _) then true end case end function\n"
    rejects "function invalid (value of type (Integer, (Bool, Text))) -> Bool is first matching case of value: when ((_, _), _) then true end case end function\n"
    rejects "type Pair is a record{first of type Integer second of type Bool} end type\nfunction invalid (value of type Pair) -> Bool is first matching case of value: when (_, _) then true end case end function\n"
  it "checks tuple shapes hidden by previous rows and retains exhaustiveness" $ do
    rejects "function invalid (value of type (Bool, Bool, Bool)) -> Bool is first matching case of value: when #any then true when (_, _) then false end case end function\n"
    rejects "function invalid (value of type (Bool, Bool)) -> Bool is first matching case of value: when (true, _) then true end case end function\n"
    compile "function selected (value of type (Bool, Bool)) -> Bool is first matching case of value: when (true, _) then true when (false, _) then false end case end function\n" `shouldSatisfy` isRight
  it "destructures nested tuple and record parameters once" $ checked $ unlines
    [ "function selected ((first, record{child = (flag, _)}) of type (Integer, record{child of type (Bool, Text)})) -> Integer is if flag then first else 0 end if end function\n"
    , "law outcome is definition: selected (7, record{child = (true, \"yes\")}) = 7 and selected (7, record{child = (false, \"no\")}) = 0 end definition end law" ]
  it "keeps destructured names in own restrictions, later parameters and return contracts" $ checked $ unlines
    [ "function bounded ((lower, upper) of type (Integer, Integer) where lower <= upper) (value of type (number of type Integer where number >= lower)) -> (result of type Integer where result >= lower) is value end function\n"
    , "law outcome is definition: bounded (2, 4) 3 = 3 end definition end law" ]
  it "retains intrinsic positive component guarantees in parameter patterns" $ checked $ unlines
    [ "function width ((width, _) of type (Nat, Nat)) -> Nat is width end function\n"
    , "law outcome is definition: width (12, 8) = 12 end definition end law" ]
  it "retains mandatory definedness checks and uses a destructured denominator restriction" $ do
    rejects "function invalid ((number, denominator) of type (Integer, Integer)) -> Integer is prelude.quot number denominator end function\n"
    checked $ unlines
      [ "function quotient ((number, denominator) of type (Integer, Integer) where denominator != 0) -> Integer is prelude.quot number denominator end function\n"
      , "law outcome is definition: quotient (7, 1) = 7 end definition end law" ]
  it "orders tuples lexicographically by position even beyond nine components" $ checked
    "law ordered is definition: prelude.compare (false, false, false, false, false, false, false, false, false, true, false) (true, false, false, false, false, false, false, false, false, false, false) must be Less end definition end law\n"
  it "rejects refutable or repeated parameter bindings and invalid dependent inputs" $ do
    forM_ ["((true, _) of type (Bool, Bool))","((same, same) of type (Integer, Integer))","(Present value of type Maybe Integer)"] $ \parameter ->
      rejects ("function invalid "++parameter++" -> Bool is true end function")
    rejects "function invalid ((first, second) of type (Integer, Integer)) (first of type Bool) -> Bool is true end function"
    let bounded="function bounded ((lower, upper) of type (Integer, Integer) where lower <= upper) (value of type (number of type Integer where number >= lower)) -> Integer is value end function\n"
    rejects (bounded++"function invalid (ignored of type ()) -> Integer is bounded (4, 2) 5 end function\n")
    rejects (bounded++"function invalid (ignored of type ()) -> Integer is bounded (2, 4) 1 end function\n")
  it "keeps uppercase parameter bindings ahead of prelude conversions" $ checked
    "function echo (Int32 of type Bool) -> Bool is Int32 end function\nlaw outcome is definition: echo true = true end definition end law\n"
  it "requires payload-free constructor parameter patterns to be irrefutable" $ do
    checked "type Flag is one of | Ready end type\nfunction ready ((Ready) of type Flag) -> Bool is true end function\nlaw outcome is definition: ready Ready = true end definition end law\n"
    rejects "type Flag is one of | Ready | Waiting end type\nfunction invalid ((Ready) of type Flag) -> Bool is true end function\n"
  it "reports generic phrase-name collisions instead of publishing allocator suffixes" $ do
    program<-either (fail.show) pure (compile (unlines
      [ "function \"|same value| (value of type a) -> a is value end function\n"
      , "function sameValue (value of type a) -> a is value end function\n"
      , "law usage is definition: \"|same value| true = true and sameValue true = true end definition end law" ]))
    plan<-either (fail.show) pure (planTesting program)
    forM_ targets $ \target -> case emitPlan target plan of
      Left diagnostics -> map S.code diagnostics `shouldBe` ["native-name-collision"]
      Right _ -> expectationFailure (target++" silently published a specialization suffix")
  it "keeps tuple literals in examples and typed table inputs" $ checked $ unlines
    [ "function first ((left, _) of type (Integer, Bool)) -> Integer is left end function\n"
    , "law rows is definition: for all (value of type (Integer, Bool)) => first value = first value end for all end definition"
    , "expect first value = expected in table (value, expected): row (1, true), 1 row (-2, false), -2 end table end law" ]
  it "formats nested tuple notation idempotently and preserves contextual exact scalar bounds" $ do
    let body="function first ((left, _) of type (UInt8, Bool)) -> UInt8 is left end function\nlaw outcome is definition: first (255, true) = 255 end definition end law\n"
        source=S.Source "tuples.lawspec" ("unit products\n\n"++body ++ "\nend unit\n")
        formatted=formatSource source
    formatSource formatted `shouldBe` formatted
    compileCoreCanonical 64 S.defaultGeneration [formatted] `shouldSatisfy` isRight
    rejects (body++"\nlaw invalid is definition: first (256, false) = 0 end definition end law\n")
