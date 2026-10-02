module IncrementalSpec (spec) where

import Data.Aeson (Value, decode, encode, object, (.=))
import qualified Data.ByteString.Lazy as B
import Test.Hspec
import LawSpec.Api (dispatch)

-- Two programs that differ only in one law of their second unit. The compiler
-- memoizes stages by content, so a missing input in any key would make one
-- program's result depend on whether the other was compiled first.
programs :: String -> ([(String, String)], [(String, String)])
programs tag = (render "x + 0 = x", render "0 + x = x")
  where
    render law =
      [ ("first.lawspec", unlines
          [ "unit incremental." ++ tag ++ ".first"
          , "double :: Int32 -> Int32"
          , "law `double is deterministic` is definition is `for all` (x :: Int32) . double x = double x end end" ])
      , ("second.lawspec", unlines
          [ "unit incremental." ++ tag ++ ".second"
          , "identity :: Int32 -> Int32"
          , "law `zero is neutral` is definition is `for all` (x :: Int32) . " ++ law ++ " end end" ]) ]

request :: String -> String -> [(String, String)] -> B.ByteString
request method target sources = encode (object
  [ "method" .= method, "target" .= target
  , "sources" .= [object ["path" .= path, "content" .= content] | (path, content) <- sources] ])

response :: B.ByteString -> Maybe Value
response = decode . dispatch

spec :: Spec
spec = describe "incremental compilation" $ do
  it "gives each program the same result whatever was compiled before" $ do
    let (one, two) = programs "order"
        targets = ["python", "java", "haskell"]
        runs programs' = [response (request "planGeneration" t p) | p <- programs', t <- targets]
        forwards = runs [one, two, one]
        backwards = runs [two, one, two]
    forwards `shouldSatisfy` all (maybe False (const True))
    take 3 forwards `shouldBe` take 3 (drop 3 backwards)
    take 3 (drop 3 forwards) `shouldBe` take 3 backwards
    drop 6 forwards `shouldBe` take 3 forwards
    take 3 forwards `shouldNotBe` take 3 (drop 3 forwards)
  it "answers every method and target from the same compiled program" $ do
    let (one, _) = programs "methods"
        check = response (request "check" "" one)
    check `shouldSatisfy` maybe False (const True)
    response (request "check" "python" one) `shouldBe` check
