-- | Scala generators for the scalars and structural types, downstream of
-- checked Core, on LawSpec's shrink trees (lawspec.testing.Arb). The scalar
-- generators are the runtime's (LawSpecScalars), so a test names them only.
module LawSpec.ScalaTestHelpers (generatorReceiver, generatorReceiverWithin, generatorDoc, generatorDocWithin, scalarGenerators) where

import qualified LawSpec.Core as C
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.ScalaLayout as L

text :: String -> D.Doc
text = D.text

quoted :: String -> D.Doc
quoted = L.scalaString

number :: Show a => a -> D.Doc
number = text . show

-- | The generator of a type: scalars from the runtime's generators, data and
-- other structural types from the schema (LawSpecScalaStrategies).
generatorDoc :: Int -> Integer -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> D.Doc
generatorDoc bits budget structural reference key = L.receiverDoc . generatorReceiver bits budget structural reference key

generatorReceiver :: Int -> Integer -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> L.Receiver
generatorReceiver bits budget structural reference key = generatorReceiverBounded (integerBounds bits) bits budget structural reference key

-- | The generator, with a top-level integer drawn from a refinement's range.
generatorDocWithin :: Maybe (Integer, Integer) -> Int -> Integer -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> D.Doc
generatorDocWithin within bits budget structural reference key = L.receiverDoc . generatorReceiverWithin within bits budget structural reference key

generatorReceiverWithin :: Maybe (Integer,Integer) -> Int -> Integer -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> L.Receiver
generatorReceiverWithin within bits budget structural reference key ty = generatorReceiverBounded boundsOf bits budget structural reference key ty
  where
    boundsOf name = case (within, ty) of
      (Just range, C.Constructor top []) | top == name -> Just range
      _ -> integerBounds bits name

generatorReceiverBounded :: (String -> Maybe (Integer, Integer)) -> Int -> Integer -> (C.Type -> Bool) -> (C.Type -> D.Doc)
  -> (C.Type -> String) -> C.Type -> L.Receiver
generatorReceiverBounded boundsOf bits budget structural reference key = gen
  where
    scalars name = L.callReceiver ("LawSpecScalars." ++ name)
    gen ty | structural ty = L.callReceiver "LawSpecScalaStrategies.generator"
      [text "Schema", reference ty, text "MachineBits", number budget, scalarGenerators]
    gen ty@(C.Constructor "List" [C.TypeArgument inner]) = scalars "list" [quoted (key ty), L.receiverDoc (gen inner)]
    gen ty@(C.Constructor "Maybe" [C.TypeArgument inner]) = scalars "maybe" [quoted (key ty), L.receiverDoc (gen inner)]
    gen ty@(C.Constructor "Either" [C.TypeArgument a, C.TypeArgument b]) = scalars "either" [quoted (key ty), L.receiverDoc (gen a), L.receiverDoc (gen b)]
    gen ty@(C.Constructor _ [C.TypeArgument inner]) = scalars "present" [quoted (key ty), L.receiverDoc (gen inner)]
    gen (C.Constructor name []) | Just (lo, hi) <- boundsOf name, Just (lo, hi) /= integerBounds bits name =
      if lo >= -2147483648 && hi <= 2147483647
      then scalars "small" [quoted name, text (show lo ++ " to " ++ show hi)]
      else scalars "bounded" [quoted name, quoted (show lo), quoted (show hi)]
    gen (C.Constructor name []) = scalars "generator" [quoted name, text "MachineBits"]
    gen ty = error ("unsupported Scala structural generator: " ++ show ty)

-- | The runtime's scalar generators, as the strategies take them.
scalarGenerators :: D.Doc
scalarGenerators = text "LawSpecScalars.generator(_, MachineBits)"
