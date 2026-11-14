-- | The capability instances' operations: the built-in unit lawspec.instances.
-- ref:DEC-capability-instances
module InstancesSpec (test_instanceOperationsAreCheckedDefinitions) where

import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Frontend (compileCore)

evaluated :: [String] -> Either [Diagnostic] ()
evaluated body = compileCore 64 defaultGeneration
  [Source "probe.lawspec" (unlines (["unit probe.instances"] ++ body ++ ["end unit"]))]
  >>= dischargeEvidence >>= \_ -> pure ()

helpers :: [String]
helpers =
  [ "function double (n :: Integer) -> Integer is n * 2 end function"
  , "function isEven (n :: Integer) -> Bool is prelude.rem n 2 = 0 end function"
  , "function minus (a :: Integer) (b :: Integer) -> Integer is a - b end function" ]

test_instanceOperationsAreCheckedDefinitions :: Spec
test_instanceOperationsAreCheckedDefinitions = describe "capability instance definitions" $ do
  it "the shipped example compiles and its laws hold in the evaluator" $ do
    source <- readFile "examples/specs/native_agreement.lawspec"
    (compileCore 64 defaultGeneration [Source "native_agreement.lawspec" source] >>= dischargeEvidence >>= \_ -> pure ())
      `shouldSatisfy` isRight
  it "are available to a unit that imports lawspec.instances" $
    evaluated (["import lawspec.instances (mapList, filterList, foldRightList)"] ++ helpers ++
      [ "law \"|used| is definition :"
      , "  mapList double [1, 2] = [2, 4] and filterList isEven [1, 2] = [2] and foldRightList minus 10 [1, 2, 3] = -8"
      , "end definition end law" ])
      `shouldSatisfy` isRight
  it "refute a native operation that disagrees" $
    evaluated (["import lawspec.instances (foldLeftList)"] ++ helpers ++
      [ "law \"|wrong| is definition : prelude.foldRight minus 10 [1, 2, 3] = foldLeftList minus 10 [1, 2, 3] end definition end law" ])
      `shouldSatisfy` isLeft
  it "are not added to a unit that does not import them" $
    evaluated (helpers ++ ["law \"|absent| is definition : mapList double [1] = [2] end definition end law"])
      `shouldSatisfy` isLeft
  it "reserve the unit name" $
    case compileCore 64 defaultGeneration [Source "taken.lawspec" "unit lawspec.instances\n\ntype T is one of | A end type\nend unit\n"] of
      Left problems -> concatMap message problems `shouldSatisfy` isInfixOf "reserved"
      Right compiled -> expectationFailure ("expected the unit name to be reserved, got " ++ show (length (C.programUnits compiled)) ++ " units")
