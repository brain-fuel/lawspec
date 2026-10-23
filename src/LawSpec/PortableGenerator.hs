-- | Native Hypothesis generators from resolved scalar/container types.
-- Documents retain legal call, object, and collection breaks for test emitters.
-- (JavaScript's fast-check generators are LawSpec.WebTests'.)
module LawSpec.PortableGenerator (generatorDoc, generatorDocWithin) where

import LawSpec.Backend
import qualified LawSpec.Core as C
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.PythonExpr as Python
import Data.Aeson (encode)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T

-- | Python draws values with Hypothesis, from the same plan as every
-- target's framework. ref:DEC-native-property-frameworks
generatorDoc :: Int -> (Type -> Bool) -> (Type -> D.Doc) -> Type -> D.Doc
generatorDoc bits structural reference = generatorDocWithin bits structural reference Nothing

-- | The generator, with an integer drawn from a refinement's range when one
-- is given.
generatorDocWithin :: Int -> (Type -> Bool) -> (Type -> D.Doc) -> Maybe (Integer, Integer) -> Type -> D.Doc
generatorDocWithin bits structural reference within = generate
  where
    quote = Python.quoted
    number :: Show a => a -> D.Doc
    number = D.text . show
    text = D.text
    call = Python.call
    array = D.delimitTrailing 4 "[" "]"
    lambda name body = D.group (text ("lambda " ++ name ++ ": ") <> body)
    method source name args = source <> text ("." ++ name) <> D.delimitTrailing 4 "(" ")" args
    mapped source name body = method source "map" [lambda name body]
    construct name = call ("ls." ++ name)
    integerRange :: Integer -> Integer -> D.Doc
    integerRange low high = call "st.integers" [text "min_value=" <> number low, text "max_value=" <> number high]
    list source = call "st.lists" [source,text "max_size=100"]
    scalarLiteral value = call "ls.literal"
      [call "json.loads" [quote (T.unpack (T.decodeUtf8 (encode value)))]]
    boundaries (Applied n t) = SPresent n Nothing : map (SPresent n . Just) (boundaries t)
    boundaries (Named n) = scalarBoundaries bits n
    boundaries _ = []
    -- Python names the unbounded integers' draw limit once per test module.
    bound :: Integer -> D.Doc
    bound value
      | value == 2^(256::Int) = text "INTEGER_DRAW_LIMIT"
      | value == -2^(256::Int) = text "-INTEGER_DRAW_LIMIT"
      | otherwise = text (show value)
    generate ty | structural ty = call "_lawspec_data_generator" [reference ty]
    generate (Applied "Maybe" inner) =
      let absent = call "ls.construct" [quote ("Maybe::Absent" :: String),array []]
          present = call "ls.construct" [quote ("Maybe::Present" :: String),array [text "value"]]
      in call "st.one_of" [call "st.just" [absent],mapped (generate inner) "value" present]
    generate (C.Constructor "Either" [C.TypeArgument left,C.TypeArgument right]) =
      let branch tag inner = mapped (generate inner) "value"
            (call "ls.construct" [quote tag,array [text "value"]])
      in call "st.one_of" [branch "Either::Left" left,branch "Either::Right" right]
    generate (Applied "List" inner) = call "st.lists" [generate inner,text "max_size=64"]
    generate (Applied n inner) = call "st.one_of"
      [call "st.just" [construct "Presence" [quote n,text "False"]],
       mapped (generate inner) "x" (construct "Presence" [quote n,text "True",text "x"])]
    generate t@(Named n)
      | isInteger n =
          let bounds = maybe (integerBounds bits n) Just within
              low = maybe (if n == "BigUInt" then 0 else -2^(256::Int)) fst bounds
              high = maybe (2^(256::Int)) snd bounds
          in call "st.integers" [text "min_value=" <> bound low,text "max_value=" <> bound high]
      | n == "Bool" = call "st.booleans" []
      | n == "Text" = call "st.text" []
      | n `elem` ["Float32","Float64"] = call "st.floats" [text ("width=" ++ if n == "Float32" then "32" else "64")]
      | n == "Decimal" = mapped (call "st.tuples" [call "st.integers" [],integerRange (-20) 20]) "v"
          (call "ls.make_decimal" [text "v[0]",text "v[1]"])
      | n == "Rational" = mapped (call "st.tuples" [call "st.integers" [],call "st.integers" [text "min_value=1"]]) "v"
          (call "ls.Fraction" [text "v[0]",text "v[1]"])
      | n `elem` ["Complex64","Complex128"] =
          let component = generate (Named (if n == "Complex64" then "Float32" else "Float64"))
          in mapped (call "st.tuples" [component,component]) "v" (call "complex" [text "v[0]",text "v[1]"])
      | n == "Char" = call "st.characters" [text "blacklist_categories=(\"Cs\",)"]
      | n `elem` ["CodePoint","CodeUnit16"] = integerRange 0 (maximumUnit n)
      | n == "Bytes" = call "st.binary" [text "max_size=100"]
      | n `elem` ["CodePointText","Utf16Text"] = mapped (list (integerRange 0 (maximumUnit n))) "v"
          (construct "Raw" [quote n,call "tuple" [text "v"]])
      | n == "Symbol" = method (call "st.text" []) "map" [text "ls.Symbol"]
      | otherwise = call "st.sampled_from" [array (map scalarLiteral (boundaries t))]
    generate _ = error "unsupported portable generator type"
    maximumUnit :: String -> Integer
    maximumUnit n = if n == "Bytes" then 255 else if n `elem` ["CodeUnit16","Utf16Text"] then 65535 else 1114111
