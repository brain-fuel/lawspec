{-# LANGUAGE OverloadedStrings #-}
module NamedBlocksSpec (test_namedBlocks) where

import Test.Hspec
import Data.Either (isRight)
import Data.List (isInfixOf,sort,intercalate)
import LawSpec.Blocks (blockKinds,blockLabel)
import LawSpec.Parser (parseSourceCanonical)
import LawSpec.Compile (compileCanonical)
import LawSpec.Model

source :: String -> Source
source = Source "named-blocks.lawspec"

codes :: Either [Diagnostic] a -> [String]
codes = either (map code) (const [])

test_namedBlocks :: Spec
test_namedBlocks = describe "named-block grammar" $ do
  it "covers the complete public block catalogue" $
    sort [label | (label,_,_)<-blockContexts] `shouldBe` sort (map blockLabel blockKinds)

  mapM_ (\(label,before,after) -> describe ("end "++label) $ do
    let authored ending=source ((if label=="unit" then "" else "unit catalogue\n")++before++ending++after++
          (if label=="unit" then "\n" else "\nend unit\n"))
        parse= parseSourceCanonical . authored
    it "accepts the designated closer with horizontal whitespace and a trailing comment" $ do
      parse ("end "++label) `shouldSatisfy` isRight
      parse ("end\t"++intercalate "\t" (words label)++" -- closing this block\n") `shouldSatisfy` isRight
    it "rejects a bare end or a label on the next physical line" $ do
      codes (parse "end\n") `shouldBe` ["block-close-label-required"]
      codes (parse ("end\n"++label)) `shouldBe` ["block-close-label-required"]
    it "rejects an unknown, mismatched or missing closer" $ do
      codes (parse "end spaceship") `shouldBe` ["block-close-unknown"]
      codes (parse (if label=="unit" then "end function" else "end unit")) `shouldBe` ["block-close-mismatch"]
      codes (parse "") `shouldSatisfy` any (`elem` ["block-close-mismatch","block-unclosed"])
    ) blockContexts

  it "rejects an extra closer after the unit" $
    codes (parseSourceCanonical (source "unit empty\nend unit\nend unit\n"))
      `shouldBe` ["block-close-unexpected"]

  it "requires a named ending even for an empty unit" $ do
    parseSourceCanonical (source "unit empty\nend unit\n") `shouldSatisfy` isRight
    codes (parseSourceCanonical (source "unit empty\nend\n"))
      `shouldBe` ["block-close-label-required"]
    codes (parseSourceCanonical (source "unit empty\n"))
      `shouldBe` ["block-unclosed"]

  it "never borrows a label from the following physical line" $ do
    codes (parseSourceCanonical (source "unit empty\nend\nunit\n"))
      `shouldBe` ["block-close-label-required"]

  it "locates the actual opener after leading documentary text and a tab" $ do
    let input="-- 😀 has end unit in a comment\n\tunit coordinates\nend function"
    case parseSourceCanonical (source input) of
      Left [BlockDiagnostic{diagnosticOpener=Just opener}] -> do
        line (spanStart opener) `shouldBe` 2
        column (spanStart opener) `shouldBe` 9
        column (spanEnd opener) `shouldBe` 13
      other -> expectationFailure (show other)

  it "reports the innermost quantifier and its actual opener" $ do
    let input = unlines
          ["unit nested", "law requirement is", "definition:",
           "for all (value :: Bool) =>", "there exists (answer :: Bool) such that",
           "answer = value", "end for all", "end definition", "end law", "end unit"]
    case parseSourceCanonical (source input) of
      Left [BlockDiagnostic{code=kind,message=message,at=Just location,
          diagnosticOpener=Just opener}] -> do
        kind `shouldBe` "block-close-mismatch"
        message `shouldSatisfy` isInfixOf "Expected end exists"
        line location `shouldBe` 7
        line (spanStart opener) `shouldBe` 5
      other -> expectationFailure (show other)

  it "closes positive, normative and negative existentials uniformly" $ do
    mapM_ (\wording -> compileCanonical [source (unlines
      ["unit existence", "law requirement is", "definition:",
       wording ++ " (value :: Bool) such that", "value = value", "end exists",
       "end definition", "end law", "end unit"]) ] `shouldSatisfy` isRight)
      ["there exists","there must exist","there does not exist","there must not exist"]

  it "preserves scoped lets, given restrictions and readable quantifiers" $ do
    compileCanonical [source (unlines
      ["unit arithmetic", "function twice (value :: Integer) -> Integer is",
       "let first = value + 1 in", "let second = first + 1 in",
       "second - 2 + value", "end let", "end let", "end function",
       "law doubled is", "definition:", "given (value :: Integer) when value >= 0 then",
       "twice value = value + value", "end given", "end definition", "end law", "end unit"])]
      `shouldSatisfy` isRight

  it "requires explicit operation openers and endings for delegation too" $ do
    let input = unlines
          ["unit readings", "function increment (value :: Integer) -> Integer is",
           "value + 1", "end function", "ability Meter is",
           "next :: Integer -> Integer", "end ability", "handler meter for Meter is",
           "operation next by increment end operation", "end handler", "end unit"]
    compileCanonical [source input] `shouldSatisfy` isRight
    let old = unlines
          ["unit readings", "ability Meter is", "next :: Integer -> Integer", "end ability",
           "handler meter for Meter is", "next value is value end operation", "end handler", "end unit"]
    parseSourceCanonical (source old) `shouldSatisfy` either (const True) (const False)

  it "treats closing words inside text, comments and phrase names as content" $ do
    compileCanonical [source (unlines
      ["unit words", "-- end law end exists end unit",
       "function \"|end for all| (value :: Text) -> Text is",
       "\"end operation\\nend let\"", "end function -- end unit",
       "law \"|end exists| is", "description:", "\"end law\"", "end description",
       "definition:", "true", "end definition", "end law", "end unit"])]
      `shouldSatisfy` isRight

-- Independently authored contexts for every keyword block. The designated
-- closer is inserted between the two halves; other closers stay valid so a
-- mutation exercises that particular production and its opener.
blockContexts :: [(String,String,String)]
blockContexts =
  [ ("unit","unit catalogue\n","")
  , ("function","function same (value :: Bool) -> Bool is value\n","")
  , ("procedure","procedure same (value :: Bool) -> Bool is value\n","")
  , ("type","type Flag is one of Enabled | Disabled\n","")
  , ("refinement","refinement Positive is (value :: Integer where value > 0)\n","")
  , ("wrapper","wrapper Flag is Bool\n","")
  , ("law","law requirement is definition: true end definition\n","")
  , ("definition","law requirement is definition: true\n","\nend law")
  , ("description","law requirement is description: \"A requirement.\"\n",documentaryTail)
  , ("rationale","law requirement is rationale: \"A reason.\"\n",documentaryTail)
  , ("references","law requirement is references: \"https://example.org/requirement\"\n",documentaryTail)
  , ("example",lawPrefix ++ "example observed: flag = true expect flag = true\n","\nend law")
  , ("table",lawPrefix ++ "expect flag = true in table (flag): row true\n","\nend law")
  , ("for all","law requirement is definition: for all (flag :: Bool) => flag = flag\n",lawTail)
  , ("exists","law requirement is definition: there exists (flag :: Bool) such that flag\n",lawTail)
  , ("given","law requirement is definition: given (flag :: Bool) then flag = flag\n",lawTail)
  , ("case",functionPrefix ++ "first matching case of value: when true then true when false then false\n","\nend function")
  , ("if",functionPrefix ++ "if value then true else false\n","\nend function")
  , ("let",functionPrefix ++ "let result = value in result\n","\nend function")
  , ("mapping","mapping label of type Bool -> Text is row true, \"yes\" row false, \"no\"\n","")
  , ("workflow","workflow flow :: Bool -> Bool is step :: Bool -> Bool\n","")
  , ("all","combineFlags :: Bool -> Bool -> Bool\nworkflow flow :: Bool -> Bool is all first :: Bool -> Bool second :: Bool -> Bool\n","\ncombine combineFlags end workflow")
  , ("protocol","protocol Receipt is send Bool\n","")
  , ("property","function ready (b :: Bool) -> Bool is b end function\nproperty \"|always ready| is always ready\n","")
  , ("scenario",modelPrefix ++ "scenario `a process` in state is\n","")
  , ("par",modelPrefix ++ "scenario `two processes` in state is par\n","\nend scenario")
  , ("or else",modelPrefix ++ "protocol Receipt is send Bool end protocol\nscenario `recover` in state is channel receipt :: Receipt par send receipt true with receive receipt result or else\n","\nend par end scenario")
  , ("model","model state :: Bool by Bool is\n","")
  , ("actor","actor process :: Bool by Bool is\n","")
  , ("supervisor","startProcess :: () -> Bool\nactor process :: Bool by Bool is start startProcess by false end actor\nsupervisor processes is permanent process\n","")
  , ("ability","ability Signal is signal :: Bool -> Bool\n","")
  , ("laws","ability Signal is signal :: Bool -> Bool laws law requirement is definition: true end definition end law\n","\nend ability")
  , ("handler","handler echo for Signal is operation signal value is value end operation\n","")
  , ("handlers","handlers observations is echo\n","")
  , ("operation","handler echo for Signal is operation signal value is value\n","\nend handler")
  , ("handle",functionPrefix ++ "handle value with echo\n","\nend function")
  , ("resource","resource Scratch is acquire is openScratch () end acquire release scratch is closeScratch scratch end release\n","")
  , ("acquire","resource Scratch is acquire is openScratch ()\n","\nrelease scratch is closeScratch scratch end release end resource")
  , ("release","resource Scratch is acquire is openScratch () end acquire release scratch is closeScratch scratch\n","\nend resource")
  , ("reset","resource Scratch is acquire is openScratch () end acquire release scratch is closeScratch scratch end release reset scratch is resetScratch scratch\n","\nend resource")
  , ("harness","harness settings for catalogue is\n","")
  , ("for law","harness settings for catalogue is for law requirement\n","\nend harness")
  , ("for laws","harness settings for catalogue is for laws first, second\n","\nend harness")
  , ("strategy","harness settings for catalogue is strategy flags :: Bool is any Bool\n","\nend harness")
  , ("bind","harness settings for catalogue is strategy flags :: Bool is bind flag :: Bool from any Bool in any Bool\n","\nend strategy end harness")
  , ("benchmark","harness settings for catalogue is benchmark `an observation` is true\n","\nend harness")
  ]
  where
    modelPrefix="model state :: shared Bool by Bool is end model\n"
    functionPrefix="function same (value :: Bool) -> Bool is "
    lawPrefix="law requirement is definition: for all (flag :: Bool) => flag = flag end for all end definition\n"
    lawTail="\nend definition end law"
    documentaryTail="\ndefinition: true end definition end law"
