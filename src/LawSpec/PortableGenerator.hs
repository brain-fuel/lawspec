-- Native Hypothesis/fast-check generators from resolved scalar/container types.
-- Documents retain legal call, object, and collection breaks for test emitters.
module LawSpec.PortableGenerator (generatorDoc) where

import LawSpec.Backend
import qualified LawSpec.Core as C
import LawSpec.Scalar
import qualified LawSpec.Code.Doc as D
import qualified LawSpec.PythonExpr as Python
import qualified LawSpec.WebExpr as Web
import Data.Aeson (encode, toJSON)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T

generatorDoc :: Bool -> Int -> (Type -> Bool) -> (Type -> D.Doc) -> Type -> D.Doc
generatorDoc py bits structural reference = generate
  where
    quote = if py then Python.quoted else Web.quoted
    number :: Show a => a -> D.Doc
    number = D.text . show
    text = D.text
    call = if py then Python.call else Web.call
    indentation = if py then 4 else 2
    array = D.delimitTrailing indentation "[" "]"
    object fields = D.delimitTrailing indentation "{" "}"
      [text key <> text ": " <> value | (key,value) <- fields]
    lambda name body = D.group (text (if py then "lambda " ++ name ++ ": " else "(" ++ name ++ ") => ") <> body)
    method source name args = source <> text ("." ++ name) <> D.delimitTrailing 4 "(" ")" args
    mapped source name body = method source "map" [lambda name body]
    construct name = call ((if py then "" else "new ") ++ "ls." ++ name)
    integerRange :: Integer -> Integer -> D.Doc
    integerRange low high = if py
      then call "st.integers" [text "min_value=" <> number low, text "max_value=" <> number high]
      else call "fc.integer" [object [("min",number low),("max",number high)]]
    list source = if py then call "st.lists" [source,text "max_size=100"]
      else call "fc.array" [source,object [("maxLength",text "100")]]
    scalarCodePoint = method (integerRange 0 1114111) "filter"
      [lambda "x" (text "x < 55296 || x > 57343")]
    scalarLiteral value = call "ls.literal"
      [if py then call "json.loads" [quote (T.unpack (T.decodeUtf8 (encode value)))]
       else Web.literalValue (toJSON value)]
    boundaries (Applied n t) = SPresent n Nothing : map (SPresent n . Just) (boundaries t)
    boundaries (Named n) = scalarBoundaries bits n
    boundaries _ = []
    bound :: Integer -> String -> D.Doc
    bound value suffix
      | value == 2^(256::Int) = text ("2" ++ suffix ++ " ** 256" ++ suffix)
      | value == -2^(256::Int) = text ("-(2" ++ suffix ++ " ** 256" ++ suffix ++ ")")
      | otherwise = text (show value ++ suffix)
    generate ty | structural ty = call "_lawspec_data_generator" [reference ty]
    generate (Applied "Maybe" inner) =
      let absent = call "ls.construct" [quote ("Maybe::Nothing" :: String),array []]
          present = call "ls.construct" [quote ("Maybe::Just" :: String),array [text "value"]]
      in call (if py then "st.one_of" else "fc.oneof")
        [call (if py then "st.just" else "fc.constant") [absent],mapped (generate inner) "value" present]
    generate (C.Constructor "Either" [C.TypeArgument left,C.TypeArgument right]) =
      let branch tag inner = mapped (generate inner) "value"
            (call "ls.construct" [quote tag,array [text "value"]])
      in call (if py then "st.one_of" else "fc.oneof")
        [branch "Either::Left" left,branch "Either::Right" right]
    generate (Applied "List" inner) = if py
      then call "st.lists" [generate inner,text "max_size=64"]
      else call "fc.array" [generate inner,object [("maxLength",text "64")]]
    generate (Applied n inner) = call (if py then "st.one_of" else "fc.oneof")
      [call (if py then "st.just" else "fc.constant")
        [construct "Presence" [quote n,text (if py then "False" else "false")]],
       mapped (generate inner) "x" (construct "Presence"
        [quote n,text (if py then "True" else "true"),text "x"])]
    generate t@(Named n)
      | isInteger n =
          let bounds = integerBounds bits n
              low = maybe (if n == "BigUInt" then 0 else -2^(256::Int)) fst bounds
              high = maybe (2^(256::Int)) snd bounds
          in if py then call "st.integers"
            [text "min_value=" <> bound low "",text "max_value=" <> bound high ""] else
            mapped (call "fc.bigInt" [object [("min",bound low "n"),("max",bound high "n")]]) "x"
              (call "ls.convert" [text "x",quote n,number bits])
      | n == "Bool" = call (if py then "st.booleans" else "fc.boolean") []
      | n == "Text" = if py then call "st.text" [] else
          mapped (list scalarCodePoint) "xs"
            (method (mapped (text "xs") "x" (call "String.fromCodePoint" [text "x"])) "join" [quote ("" :: String)])
      | n `elem` ["Float32","Float64"] = if py
          then call "st.floats" [text ("width=" ++ if n == "Float32" then "32" else "64")]
          else call (if n == "Float32" then "fc.float" else "fc.double") []
      | n == "Decimal" = mapped (call (if py then "st.tuples" else "fc.tuple")
          [call (if py then "st.integers" else "fc.bigInt") [],integerRange (-20) 20]) "v"
          (call (if py then "ls.make_decimal" else "new ls.Decimal") [text "v[0]",text "v[1]"])
      | n == "Rational" = mapped (call (if py then "st.tuples" else "fc.tuple")
          [call (if py then "st.integers" else "fc.bigInt") [],
           if py then call "st.integers" [text "min_value=1"] else call "fc.bigInt" [object [("min",text "1n")]]]) "v"
          (call (if py then "ls.Fraction" else "new ls.Rational") [text "v[0]",text "v[1]"])
      | n `elem` ["Complex64","Complex128"] =
          let component = generate (Named (if n == "Complex64" then "Float32" else "Float64"))
          in mapped (call (if py then "st.tuples" else "fc.tuple") [component,component]) "v"
            (call (if py then "complex" else "new ls.Complex") [text "v[0]",text "v[1]"])
      | n == "Char" = if py then call "st.characters" [text "blacklist_categories=('Cs',)"]
          else mapped scalarCodePoint "x" (call "String.fromCodePoint" [text "x"])
      | n `elem` ["CodePoint","CodeUnit16"] = integerRange 0 (maximumUnit n)
      | n == "Bytes" = if py then call "st.binary" [text "max_size=100"]
          else mapped (list (integerRange 0 255)) "v" (call "new Uint8Array" [text "v"])
      | n `elem` ["CodePointText","Utf16Text"] = mapped (list (integerRange 0 (maximumUnit n))) "v"
          (construct "Raw" [quote n,if py then call "tuple" [text "v"] else text "v"])
      | n == "Symbol" = if py then method (call "st.text" []) "map" [text "ls.Symbol"]
          else mapped (call "fc.string" []) "x" (call "Symbol" [text "x"])
      | otherwise = if py then call "st.sampled_from" [array (map scalarLiteral (boundaries t))]
          else call "fc.constantFrom" (map scalarLiteral (boundaries t))
    generate _ = error "unsupported portable generator type"
    maximumUnit :: String -> Integer
    maximumUnit n = if n == "Bytes" then 255 else if n `elem` ["CodeUnit16","Utf16Text"] then 65535 else 1114111
