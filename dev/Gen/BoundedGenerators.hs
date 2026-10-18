-- | Render the real compiler generators into native range/shrink regressions.
-- The native assertions check their output against these independent inputs.
-- ref:REQ-refined-generation-bounds ref:DEC-shrink-within-domain
module Gen.BoundedGenerators (kotlinBoundedCases,scalaBoundedCases) where

import qualified LawSpec.Core as C
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.KotlinTestHelpers as Kotlin
import qualified LawSpec.ScalaTestHelpers as Scala

ranges :: Int -> [(String,Integer,Integer)]
ranges bits =
  [("Int64",1,2^63-1),("Int64",negate (2^63),2^63-1)
  ,("Int64",negate (2^63),-1)
  ,("Int64",negate (2^63)+8,negate (2^63)+13)
  ,("Int64",2^63-8,2^63-2),("Int64",negate (5*10^18),8*10^18)
  ,("UInt64",2^64-616,2^64-1),("UInt64",0,2^64-1)
  ,("Integer",2^100+17,2^100+21)
  ,("Integer",negate (2^100)-21,negate (2^100)-17)
  ,("Integer",negate (2^100),2^100)
  ,("Int64",negate (2^63),negate (2^63))
  ,("IntSize",1,2^(bits-1)-1)]

kotlinBoundedCases,scalaBoundedCases :: String
kotlinBoundedCases = cases True
scalaBoundedCases = cases False

cases :: Bool -> String
cases kotlin = unlines $ concat
  [ ["RangeCase(" ++ show name ++ ", " ++ show bits ++ ", " ++ integer lo ++ ", " ++ integer hi ++ ","] ++
    map ("  " ++) (lines (D.render (D.Pretty 80) expression)) ++ ["),"]
  | bits <- [32,64],(name,lo,hi) <- ranges bits
  , let helper = if kotlin then Kotlin.generatorDocWithin else Scala.generatorDocWithin
        expression = helper (Just (lo,hi)) bits 64 (const False)
          (const (error "bounded regression requires a scalar")) (const name) (C.scalarType name)]
  where integer value = "java.math.BigInteger(" ++ show (show value) ++ ")"
