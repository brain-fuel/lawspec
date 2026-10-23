-- | Framework-specific Kotlin generators downstream of checked Core.
module LawSpec.KotlinTestHelpers (generatorDoc, generatorDocWithin, scalarGenerators) where

import qualified LawSpec.Core as C
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.KotlinLayout as L

text = D.text
quoted = L.kotlinString
number :: Show a => a -> D.Doc
number = text . show
call = L.call

-- | Keep native Kotest choices, binding, list budgets and shrinkers unchanged.
generatorDoc :: Int -> Integer -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> D.Doc
generatorDoc bits budget structural reference key = generatorDocBounded (integerBounds bits) bits budget structural reference key

-- | The generator, with a top-level integer drawn from a refinement's range.
generatorDocWithin :: Maybe (Integer, Integer) -> Int -> Integer -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> D.Doc
generatorDocWithin within bits budget structural reference key ty = generatorDocBounded boundsOf bits budget structural reference key ty
  where
    boundsOf name = case (within, ty) of
      (Just range, C.Constructor top []) | top == name -> Just range
      _ -> integerBounds bits name

generatorDocBounded :: (String -> Maybe (Integer, Integer)) -> Int -> Integer -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> D.Doc
generatorDocBounded boundsOf bits budget structural reference key = gen
  where
    -- The runtime's generators (LawSpecScalars), so a test names them only.
    scalars name = L.call ("LawSpecScalars." ++ name)
    gen ty | structural ty = call "LawSpecKotlinStrategies.generator"
      [text "SCHEMA",reference ty,text "MACHINE_BITS",number budget,scalarGenerators]
    gen ty@(C.Constructor "List" [C.TypeArgument inner]) = scalars "list" [quoted (key ty), gen inner]
    gen ty@(C.Constructor "Maybe" [C.TypeArgument inner]) = scalars "maybe" [quoted (key ty), gen inner]
    gen ty@(C.Constructor "Either" [C.TypeArgument a,C.TypeArgument b]) = scalars "either" [quoted (key ty), gen a, gen b]
    gen ty@(C.Constructor _ [C.TypeArgument inner]) = scalars "present" [quoted (key ty), gen inner]
    gen (C.Constructor name []) | Just (lo,hi) <- boundsOf name, Just (lo,hi) /= integerBounds bits name =
      if lo >= -2147483648 && hi <= 2147483647
      then scalars "small" [quoted name, text (show lo ++ ".." ++ show hi)]
      else scalars "bounded" [quoted name, quoted (show lo), quoted (show hi)]
    gen (C.Constructor name []) = scalars "generator" [quoted name, text "MACHINE_BITS"]
    gen ty = error ("unsupported Kotlin structural generator: " ++ show ty)

-- | The runtime's scalar generators, as the strategies take them.
scalarGenerators :: D.Doc
scalarGenerators = L.lambda ["type"] [L.call "LawSpecScalars.generator" [text "type", text "MACHINE_BITS"]]
