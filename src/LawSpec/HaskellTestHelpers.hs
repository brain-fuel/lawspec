-- | Native Hedgehog strategies downstream of checked Core.
module LawSpec.HaskellTestHelpers (generatorDoc, generatorDocWithin) where

import qualified LawSpec.Core as C
import LawSpec.Scalar
import qualified LawSpec.Code.Haskell as H
import LawSpec.Code.Haskell (Expr, call, var, string, integer, operator, lambda)

-- | Preserve Hedgehog's native list/maybe/choice trees and integral shrinking.
generatorDoc :: Int -> Integer -> (C.Type -> Bool) -> (C.Type -> Expr)
  -> (C.Type -> String) -> C.Type -> Expr
generatorDoc bits budget structural reference key = generatorDocBounded (integerBounds bits) budget structural reference key

-- | The generator, with a top-level integer drawn from a refinement's range.
generatorDocWithin :: Maybe (Integer, Integer) -> Int -> Integer -> (C.Type -> Bool) -> (C.Type -> Expr)
  -> (C.Type -> String) -> C.Type -> Expr
generatorDocWithin within bits budget structural reference key ty = generatorDocBounded boundsOf budget structural reference key ty
  where
    boundsOf name = case (within, ty) of
      (Just range, C.Constructor top []) | top == name -> Just range
      _ -> integerBounds bits name

generatorDocBounded :: (String -> Maybe (Integer, Integer)) -> Integer -> (C.Type -> Bool) -> (C.Type -> Expr)
  -> (C.Type -> String) -> C.Type -> Expr
generatorDocBounded boundsOf budget structural reference key = gen
  where
    orFail x = call "P.either" [var "P.error", var "P.id", x]
    gen ty | structural ty = orFail (call "Strategies.strategy"
      [var "schema", reference ty, var "machineBits", integer budget,
       call "Strategies.primitiveStrategy" [var "machineBits"]])
    gen (C.Constructor "List" [C.TypeArgument inner]) =
      operator "<$>" [var "SList", call "Gen.list" [call "Range.linear" [integer 0, integer 64], gen inner]]
    gen (C.Constructor "Maybe" [C.TypeArgument inner]) =
      operator "<$>" [call "maybe" [call "SData" [string "Maybe::Absent", H.List []], lambda ["value"] (call "SData" [string "Maybe::Present", H.List [var "value"]])],
        call "Gen.maybe" [gen inner]]
    gen (C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) = call "Gen.choice"
      [H.List [sumGen "Either::Left" a,sumGen "Either::Right" b]]
    gen (C.Constructor wrapper [C.TypeArgument inner]) =
      operator "<$>" [call "SPresent" [string wrapper], call "Gen.maybe" [gen inner]]
    -- An unbounded integer is drawn within integerLimit (2^256), named once
    -- in the test module.
    gen (C.Constructor name []) | isInteger name =
      let limit = var "integerLimit"
          (origin, lo, hi) = case boundsOf name of
            Just (l, h) -> (integer (max l (min h 0)), integer l, integer h)
            Nothing | name == "BigUInt" -> (integer 0, integer 0, limit)
                    | otherwise -> (integer 0, call "P.negate" [limit], limit)
      in operator "<$>" [call "SInteger" [string name],
        call "Gen.integral" [call "Range.linearFrom" [origin, lo, hi]]]
    gen (C.Constructor "Bool" []) = operator "<$>" [var "SBool", var "Gen.bool"]
    gen ty = orFail (call "Strategies.primitiveStrategy" [var "machineBits", string (key ty)])
    sumGen tag inner = operator "<$>" [lambda ["value"] (call "SData" [string tag, H.List [var "value"]]), gen inner]
