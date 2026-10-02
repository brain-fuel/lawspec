module IncrementalSpec (spec) where

import Data.Aeson (Value, decode, encode, object, (.=))
import qualified Data.ByteString.Lazy as B
import Data.List (find, isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Api (dispatch)
import LawSpec.Dependencies (dependencyGraph, keyOf, lawReferences)
import LawSpec.Digest (digestHex, digestString)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Testing (Plan(..), PlannedUnit(..), PlannedProperty(..), planTesting)

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

  describe "dependency keys" $ do
    it "digests with SHA-256" $ do
      digestHex (digestString "") `shouldBe` "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      digestHex (digestString "abc") `shouldBe` "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    it "changes a law's key exactly when something it reaches changes" $ do
      let before = keys "x * 3"
          after = keys "x + x + x"
      lookup "doubles" after `shouldBe` lookup "doubles" before
      lookup "triples" after `shouldNotBe` lookup "triples" before
    it "plans a law from the types it reaches" $ do
      let alone = planOf "score" [wrapper "Score" "0"]
          beside = planOf "score" [wrapper "Score" "0", wrapper "Wide" "1234"]
      beside `shouldBe` alone
      fmap (isInfixOf "1234" . show) beside `shouldBe` Just False
  where
    compiled text = either (error . show) id (compileCore 64 defaultGeneration [Source "keys.lawspec" text])
    keys body =
      let program = compiled $ unlines
            [ "unit incremental.keys"
            , "definition double (x :: BigInt) :: BigInt is x + x end"
            , "definition triple (x :: BigInt) :: BigInt is " ++ body ++ " end"
            , "law `doubles` is definition is `for all` (x :: BigInt) . double x = x * 2 end end"
            , "law `triples` is definition is `for all` (x :: BigInt) . triple x = x * 3 end end" ]
          graph = dependencyGraph (C.programDataDeclarations program) (C.programUnits program)
      in [ (C.propertyName p, keyOf graph (show p) (lawReferences graph p))
         | u <- C.programUnits program, p <- C.unitProperties u ]
    wrapper name bound = "wrapper " ++ name ++ " is Int32 where value > " ++ bound ++ " end"
    planOf law declarations = do
      let program = compiled $ unlines (["unit incremental.locality"] ++ declarations ++
            ["law `" ++ law ++ "` is definition is `for all` (s :: Score) . s = s end end"])
      plan <- either (const Nothing) Just (planTesting program)
      fmap boundaryCases (find ((== law) . C.propertyName . plannedProperty) (concatMap plannedProperties (plannedUnits plan)))
