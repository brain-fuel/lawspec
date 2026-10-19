-- Optional authoring warnings reuse ordered-pattern specialization.
module MatchWarningSpec (test_matchWarnings) where
import Control.Monad (forM_)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Test.Hspec
import LawSpec.Api (dispatch)

source body="unit matchWarnings\nfunction selected (value :: Bool) -> Integer is\n"++body++"\nend function\n\nend unit\n"
shadowed="first matching case of value: when #any then 1 when false then 2 otherwise 3 end case"
guarded="first matching case of value: when #any if it then 1 otherwise 2 end case"
request :: Int -> Maybe Bool -> String -> String -> String -> Value
request bits enabled method target body=object
  (["schemaVersion" .= (5::Int),"languageProfile" .= ("1.0-rc.2"::String),
    "verification" .= object ["layers" .= ([]::[String])],"machineBits" .= bits,
    "method" .= method,"target" .= target,"sources" .= [object ["path" .= ("warning-😀.lawspec"::String),"content" .= source body]]]++
   ["warnMatches" .= value | Just value<- [enabled]])
run input=case eitherDecode (dispatch (encode input)) of Right value->value;Left problem->error problem
field key (Object value)=maybe Null id (KM.lookup key value)
field _ _=Null
withoutWarnings (Object value)=Object (KM.delete "warnings" (KM.delete "warningAnalysis" value))
withoutWarnings value=value
codes value=case fromJSON (field "warnings" value) of
  Success warnings->[field "code" warning | warning<-warnings]
  Error problem->error problem

test_matchWarnings=describe "optional structural match warnings" $ do
 forM_ [32::Int,64] $ \bits->do
  it ("reports shadowed branches and fallback without changing default results at "++show bits++" bits") $ do
   let before=run (request bits Nothing ("check"::String) (""::String) shadowed)
       warned=run (request bits (Just True) ("check"::String) (""::String) shadowed)
   field "diagnostics" warned `shouldBe` toJSON ([]::[Value])
   codes warned `shouldBe` [String "case-unreachable",String "case-unnecessary-fallback"]
   field "complete" (field "warningAnalysis" warned) `shouldBe` Bool False
   field "warnings" before `shouldBe` Null
   withoutWarnings warned `shouldBe` before
   run (request bits (Just False) ("check"::String) (""::String) shadowed) `shouldBe` before
  it ("does not let a guard establish coverage at "++show bits++" bits") $ do
   let result=run (request bits (Just True) ("check"::String) (""::String) guarded)
   field "diagnostics" result `shouldBe` toJSON ([]::[Value])
   codes result `shouldBe` []
  it ("preserves all target artifacts when warnings are selected at "++show bits++" bits") $
   forM_ ["java","python","javascript","typescript","go","haskell","kotlin","rust","erlang","elixir","gleam","fsharp","csharp","scala","groovy","clojure","swift"] $ \target->do
    let before=run (request bits Nothing ("planGeneration"::String) target shadowed)
        after=run (request bits (Just True) ("planGeneration"::String) target shadowed)
    field "diagnostics" after `shouldBe` toJSON ([]::[Value])
    withoutWarnings after `shouldBe` before
 it "does not conceal admission errors in discarded branches" $ do
  let before=run (request (64::Int) Nothing ("check"::String) (""::String)
        "first matching case of value: when #any then 1 when false then missing end case")
      after=run (request (64::Int) (Just True) ("check"::String) (""::String)
        "first matching case of value: when #any then 1 when false then missing end case")
  field "diagnostics" after `shouldNotBe` toJSON ([]::[Value])
  after `shouldBe` before
 it "recognizes complete Boolean coverage without treating a guarded row as coverage" $ do
  let complete=run (request 64 (Just True) "check" ""
        "first matching case of value: when true then 1 when false then 2 otherwise 3 end case")
      guardedFirst=run (request 64 (Just True) "check" ""
        "first matching case of value: when true if it then 1 when false then 2 otherwise 3 end case")
  field "diagnostics" complete `shouldBe` toJSON ([]::[Value])
  codes complete `shouldBe` [String "case-unnecessary-fallback"]
  codes guardedFirst `shouldBe` []
 it "retains nested case warnings once, with their original source spans" $ do
  let result=run (request 64 (Just True) "check" ""
        ("first matching case of value: when #any then\n"++
         "first matching case of it: when #any then 1 when false then 2 end case\n"++
         "when false then 3 end case"))
  field "diagnostics" result `shouldBe` toJSON ([]::[Value])
  codes result `shouldBe` replicate 2 (String "case-unreachable")
  case fromJSON (field "warnings" result) of
   Success [inner,outer]->do
    field "line" (field "at" inner) `shouldBe` Number 4
    field "line" (field "at" outer) `shouldBe` Number 5
    field "file" (field "at" inner) `shouldBe` String "warning-😀.lawspec"
   _->expectationFailure "expected exactly the two authored branch spans"
 it "preserves mandatory incomplete-match errors with no law layers selected" $ do
  let body="first matching case of value: when true then 1 end case"
      before=run (request 64 Nothing "check" "" body)
      after=run (request 64 (Just True) "check" "" body)
  field "diagnostics" after `shouldNotBe` toJSON ([]::[Value])
  after `shouldBe` before
 it "rejects non-Boolean warning selection rather than silently disabling it" $ do
  let Object input=request 64 Nothing "check" "" shadowed
      result=run (Object (KM.insert "warnMatches" (String "true") input))
  field "diagnostics" result `shouldNotBe` toJSON ([]::[Value])

 it "reuses recursive constructor, record and tuple specialization for shadowing" $ do
  forM_ [
    ("List Bool","first matching case of value: when Cons #any #any then 1 when Cons false Nil then 2 when Nil then 0 end case"),
    ("record{enabled :: Bool, count :: Integer}","first matching case of value: when record{enabled = _} then 1 when record{enabled = false, count = _} then 2 end case"),
    ("(Bool, Bool)","first matching case of value: when (_, _) then 1 when (true, false) then 2 end case")
    ] $ \(ty,body)->do
      let replaceSource (Object fields)=Object (KM.insert "sources" (toJSON [object [
            "path" .= ("patterns.lawspec"::String), "content" .=
              ("unit patterns\nfunction selected (value :: "++ty++") -> Integer is "++body++" end function\nend unit\n")]]) fields)
          replaceSource value=value
          before=run (replaceSource (request 64 Nothing "check" "" ""))
          warned=run (replaceSource (request 64 (Just True) "check" "" ""))
      field "diagnostics" warned `shouldBe` toJSON ([]::[Value])
      codes warned `shouldBe` [String "case-unreachable"]
      withoutWarnings warned `shouldBe` before
