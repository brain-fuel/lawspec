module Example.Algebra where
import Data.Int (Int32)
import LawSpecRuntime (IntegerValue,integerValue)
add, multiply, maximumValue, subtractValue, divideLeft, divideRight :: Integer -> Integer -> IntegerValue
add x y = integerValue (x+y)
multiply x y = integerValue (x*y)
maximumValue x y = integerValue (max x y)
subtractValue x y = integerValue (x-y)
divideLeft x y = integerValue (x-y)
divideRight x y = integerValue (x+y)
negateValue :: Integer -> IntegerValue
negateValue x = integerValue (-x)
