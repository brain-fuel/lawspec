-- | The language gaps a large dependency contract (LawTwin's Kafka contract)
-- found: fields, failing operations, handlers of several abilities, sets of
-- handlers, natives made with a resource, handler clause forms, sequences,
-- bounded arithmetic, integer recursion, the checker's facts, regex-shaped
-- generation and Python packages.
module LanguageGapsSpec (test_languageGapsClose) where

import FixtureSource (extendUnit)
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf, isSuffixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.CoreEmit (emitPlan)
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Regex (parseRegex, regexMatches, regexSamples)
import LawSpec.Testing (planTesting)

program :: String -> Either [Diagnostic] C.Program
program source = compileCore 64 defaultGeneration [Source "gaps.lawspec" source]

programs :: [(String, String)] -> Either [Diagnostic] C.Program
programs sources = compileCore 64 defaultGeneration [Source path text | (path, text) <- sources]

failsWith :: String -> Either [Diagnostic] a -> Bool
failsWith needle = either (any ((needle `isInfixOf`) . message)) (const False)

-- A unit whose closed laws the compiler evaluates: a false one fails.
evaluated :: [String] -> Either [Diagnostic] [()]
evaluated body = program (unlines (["unit gaps.eval"] ++ body ++ ["end unit"])) >>= dischargeEvidence >>= \_ -> pure []

names :: C.Program -> [String]
names compiled = [C.propertyName p | u <- C.programUnits compiled, p <- C.unitProperties u]

handlersOf :: String -> C.Program -> Maybe [String]
handlersOf law compiled = lookup law
  [(C.propertyName p, map (show . snd) (C.propertyHandlers p)) | u <- C.programUnits compiled, p <- C.unitProperties u]

store :: String
store = unlines
  [ "unit gaps.store"
   ++ "\n", ""
  , "type Problem is one of | Missing end type\n"
  , "handle Disk"
  , "openDisk :: Unit -> Disk"
  , "closeDisk :: Disk -> Unit"
  , "resource Disk is acquire is openDisk unitValue end acquire release d is closeDisk d end release end resource"
  , "ability Logs with Disk is"
  , "  create :: Text -> Unit"
  , "  append :: Text -> Int32 -> Int64 fails with Problem"
  , "laws"
  , "  law \"|an unknown log refuses appends| is"
  , "    definition : for all (t :: Text) (v :: Int32) => append t v fails with Missing end for all end definition"
  , "  end law"
  , "\nend laws"
  , "end ability"
  , "ability Reader with Disk is"
  , "  size :: Text -> Maybe Int64"
  , "end ability"
  , "handler memory for Logs, Reader with state logs :: KeyVal Text (List Int32) start prelude.keyValOf [] is"
  , "   operation create t is ~logs := prelude.put t [] logs; unitValue end operation"
  , "   operation append t v is"
  , "    first matching case of prelude.lookup t logs :"
  , "    when Absent then raise Missing"
  , "    when Present l then ~logs := prelude.put t (Cons v l) logs; prelude.Int64 (prelude.length l)"
  , "    end case"
  , "  end operation"
  , "   operation size t is first matching case of prelude.lookup t logs : when Absent then Absent when Present l then Present (prelude.Int64 (prelude.length l)) end case end operation"
  , "end handler"
  , "\nend unit" ]

-- | Each gap LawTwin's Kafka contract reported closes, with its checks.
-- ref:REQ-language-gaps
test_languageGapsClose :: Spec
test_languageGapsClose = describe "the language gaps a dependency contract found" $ do
  describe "fields" $ do
    it "reads and replaces fields of a single-constructor type" $
      evaluated
        [ "type Point is a record{  x :: Int32 y :: Int32} end type\n"
        , "function moved (p :: Point) -> Point is if p.x < 100 then p with x = prelude.Int32 (p.x + 1) else p end if end function\n"
        , "law \"|moves| is definition : (moved (Point record{ x = 1 , y = 2})).x = 2 and (moved (Point record{ x = 1 , y = 2})).y = 2 end definition end law" ]
        `shouldSatisfy` isRight
    it "refuses a field of a sum" $
      program (unlines
        [ "unit gaps.sum"
         ++ "\n", ""
        , "type Shape is one of | Dot | Line  of type Int32 end type\n"
        , "function f (s :: Shape) -> Int32 is s.from end function\n"
        , "\nend unit" ])
        `shouldSatisfy` failsWith "more than one constructor"
    it "refuses a field a type does not have" $
      program (unlines
        [ "unit gaps.field"
         ++ "\n", ""
        , "type Point is a record{  x :: Int32} end type\n"
        , "function f (p :: Point) -> Int32 is p.z end function\n"
        , "\nend unit" ])
        `shouldSatisfy` failsWith "has no field called z"
  describe "literals" $
    it "gives a literal branch the type of the other branches" $
      evaluated
        [ "function first (g :: Maybe Int64) -> Int64 is let from = (first matching case of g : when Absent then 0 when Present x then x end case) in from end let  end function"
        , "law \"|zero| is definition : first Absent = 0 end definition end law" ]
        `shouldSatisfy` isRight
  describe "handlers" $ do
    it "lets an operation fail and a clause raise" $
      program store `shouldSatisfy` isRight
    it "refuses a clause that raises what its operation does not fail with" $
      program (unlines
        [ "unit gaps.raise"
         ++ "\n", ""
        , "type Problem is one of | Missing end type\n"
        , "ability Logs is"
        , "  size :: Int32"
        , "end ability"
        , "handler broken for Logs is  operation size is raise Missing end operation end handler"
        , "\nend unit" ])
        `shouldSatisfy` isLeft
    it "runs a handler of several abilities for each, once" $ do
      let Right compiled = program (extendUnit store $ "law \"|sizes count| is definition : for all (t :: Text) (v :: Int32) => (create t; append t v; size t) = Present 1 end for all end definition end law\n")
      names compiled `shouldSatisfy` elem "\"|sizes count| [memory]"
      handlersOf "\"|sizes count| [memory]" compiled `shouldSatisfy` maybe False (\hs -> length (filter ("memory" `isInfixOf`) hs) == 2)
    it "gives a law that runs a native made with a resource that resource" $ do
      let Right compiled = program (extendUnit store $ "law \"|sizes count| is definition : for all (t :: Text) => (create t; size t) = Present 0 end for all end definition end law\n")
          resources = [length (C.propertyResources p) | u <- C.programUnits compiled, p <- C.unitProperties u, "[native" `isInfixOf` C.propertyName p]
      resources `shouldSatisfy` (\rs -> not (null rs) && all (== 1) rs)
    it "runs every law of a set's abilities under the whole set" $ do
      let Right compiled = program (extendUnit store $ unlines
            [ "ability Writer is"
            , "  write :: Text -> Int32 -> Bool"
            , "laws"
            , "  law \"|a write is read| is"
            , "    definition : for all (t :: Text) (v :: Int32) => (create t; write t v; size t) = Present 1 end for all end definition"
            , "  end law"
            , "\nend laws"
            , "end ability"
            , "handler client for Writer is  operation write t v is prelude.isRight (prelude.attempt (append t v)) end operation end handler"
            , "handlers reference is memory, client end handlers" ])
      names compiled `shouldSatisfy` elem "Writer: \"|a write is read| [reference]"
    it "starts a handler from a computed value and writes clauses by definitions" $
      evaluated
        [ "ability Counter is"
        , "  bump :: Bool"
        , "  total :: Int64"
        , "end ability"
        , "function start (u :: Unit) -> Int64 is 0 end function"
        , ""
        , "function bumped (n :: Int64) -> Pair Bool Int64 is if n < 1000 && n >= 0 then Pair record{first = true, second = prelude.Int64 (n + 1)} else Pair record{first = false, second = n} end if end function"
        , "function totalOf (n :: Int64) -> Pair Int64 Int64 is Pair record{ first = n , second = n} end function"
        , ""
        , "handler counting for Counter with state n :: Int64 start start unitValue is"
        , "  operation bump by bumped end operation"
        , "  operation total by totalOf end operation"
        , "end handler"
        , "handler branching for Counter with state n :: Int64 start 0 is"
        , "  operation bump is if n < 1000 && n >= 0 then (~n := prelude.Int64 (n + 1); true) else false end if end operation"
        , "  operation total is n end operation"
        , "end handler"
        , "law \"|bumps count| using counting is definition : (bump; bump; total) = 2 end definition end law\n"
        , ""
        , "law \"|branches count| using branching is definition : (bump; bump; total) = 2 end definition end law\n"
        , "" ]
        `shouldSatisfy` isRight
  describe "prelude helpers in ability laws" $
    it "rewrites isRight inside an ability's laws" $
      program (unlines
        [ "unit gaps.railway"
         ++ "\n", ""
        , "type E is one of | Bad end type\n"
        , "ability Store is"
        , "  get :: Int32 -> Either E Int32"
        , "laws"
        , "  law \"|get succeeds| is definition : for all (x :: Int32) => prelude.isRight (get x) = true end for all end definition end law"
        , "\nend laws"
        , "end ability"
        , "handler ok for Store is  operation get x is Right x end operation end handler"
        , "\nend unit" ])
        `shouldSatisfy` isRight
  describe "sequences and bounded arithmetic" $ do
    it "joins, slices, indexes and encodes" $
      evaluated
        [ "law \"|sequences| is definition :"
        , "  \"a\" ++ \"b\" = \"ab\" and prelude.slice 1 3 \"kafka\" = \"af\" and prelude.at 1 [10, 20] = Present 20"
        , "    and prelude.range 0 3 = [0, 1, 2] and prelude.utf8 \"é\" = prelude.bytesOf [195, 169]"
        , "    and prelude.textOf 42 = \"42\" and prelude.join \", \" [\"a\", \"b\"] = \"a, b\""
        , "end definition end law" ]
        `shouldSatisfy` isRight
    it "refutes a false sequence law" $
      evaluated [ "law \"|wrong| is definition : prelude.slice 0 2 \"abc\" = \"abc\" end definition end law" ]
        `shouldSatisfy` isLeft
    it "wraps, saturates and bounds into the type the context wants" $
      evaluated
        [ "function next (e :: Int16) -> Int16 is prelude.wrapping (e + 1) end function\n"
        , "function up (l :: UInt8) -> UInt8 is prelude.saturating (l + 10) end function\n"
        , "function sum (a :: Int32) (b :: Int32) -> Maybe Int32 is prelude.bounded (a + b) end function\n"
        , "law \"|bounded| is definition : next 32767 = -32768 and up 250 = 255 and sum 2147483647 1 = Absent and sum 1 2 = Present 3 end definition end law" ]
        `shouldSatisfy` isRight
  describe "totality" $ do
    it "accepts recursion that counts an integer down or up to a bound" $
      program (unlines
        [ "unit gaps.recursion"
         ++ "\n", ""
        , "function down (n :: Whole) -> List Whole is if n = 0 then [] else Cons n (down (n - 1)) end if end function\n"
        , "function up (i :: Int32) (n :: Int32) -> List Int32 is if i >= n || i < 0 then [] else Cons i (up (prelude.Int32 (i + 1)) n) end if end function\n"
        , "\nend unit" ])
        `shouldSatisfy` isRight
    it "rejects recursion that moves away from every bound" $
      program (unlines
        [ "unit gaps.forever"
         ++ "\n", ""
        , "function grow (n :: Integer) -> List Integer is if n = 0 then [] else Cons n (grow (n + 1)) end if end function\n"
        , "\nend unit" ])
        `shouldSatisfy` failsWith "no integer argument moves strictly toward a bound"
    it "uses guards on lengths, call results and remainders" $
      program (unlines
        [ "unit gaps.facts"
         ++ "\n", ""
        , "function dec (n :: Int32) -> Int32 is if n > Int32.min then prelude.Int32 (n - 1) else n end if end function\n"
        , "function clip (xs :: List Int32) -> Int32 is if prelude.length xs <= 100 then prelude.Int32 (prelude.length xs) else 100 end if end function\n"
        , "function clip2 (n :: Int32) -> Int32 is let m = dec n in if m >= 1 then prelude.Int32 (m - 1) else 0 end if end let  end function"
        , "function owner (p :: Int32) (k :: Int32) -> Int32 is if k >= 1 && p >= 0 then prelude.Int32 (prelude.rem p k) else 0 end if end function\n"
        , "\nend unit" ])
        `shouldSatisfy` isRight
  describe "generation" $ do
    it "samples texts a regex matches" $ do
      let Right regex = parseRegex "[a-zA-Z0-9._-]+"
          samples = regexSamples 24 regex
      length samples `shouldSatisfy` (> 10)
      samples `shouldSatisfy` all (regexMatches regex . map fromEnum)
    it "gives a text refined through a definition regex hints" $ do
      files <- either (\ds -> fail (show ds)) pure (program (unlines
        [ "unit gaps.regex"
         ++ "\n", ""
        , "function valid (name :: Text) -> Bool is let n = prelude.length name in n >= 1 && name matches regex \"[a-z]+\" end let  end function"
        , "law \"|named| is definition : for all (t :: Text where valid t) => prelude.length t >= 1 end for all end definition end law"
        , "\nend unit" ])
        >>= planTesting >>= emitPlan "python")
      let tests = [artifactContent f | f <- files, "test_gaps_regex_lawspec.py" `isSuffixOf` artifactPath f]
      tests `shouldSatisfy` any ("\"type\": \"Text\", \"units\": [" `isInfixOf`)
    it "mixes regex hints into laws that also draw records" $ do
      let source = unlines
            [ "unit gaps.mixed"
             ++ "\n", ""
            , "type Box is a record{  size :: Int32} end type\n"
            , "function valid (name :: Text) -> Bool is name matches regex \"id-[0-9]{3}\" end function\n"
            , "law \"|boxed| is definition : for all (b :: Box) (t :: Text where valid t) => valid t && b.size = b.size end for all end definition end law"
            , "\nend unit" ]
          emitted target = either (\ds -> fail (show ds)) pure (program source >>= planTesting >>= emitPlan target)
          -- Whitespace aside, so the checks do not depend on layout.
          contents files = filter (`notElem` (" \n" :: String)) (concatMap artifactContent files)
      python <- contents <$> emitted "python"
      python `shouldSatisfy` ("st.sampled_from((lambdasymbols:" `isInfixOf`)
      go <- contents <$> emitted "go"
      go `shouldSatisfy` ("rapid.OneOf(rapid.SampledFrom" `isInfixOf`)
      kotlin <- contents <$> emitted "kotlin"
      kotlin `shouldSatisfy` ("lawspecChoice(Arb.element(run{" `isInfixOf`)
      haskell <- contents <$> emitted "haskell"
      haskell `shouldSatisfy` ("(Gen.choice([Gen.element" `isInfixOf`)
      java <- contents <$> emitted "java"
      java `shouldSatisfy` ("Generator.<Value>anyOf(Generator.<Value>sampledFrom" `isInfixOf`)
  describe "Python packages" $
    it "makes a unit with units inside it its package's __init__.py" $ do
      files <- either (\ds -> fail (show ds)) pure (programs
        [ ("a.lawspec", "unit gaps.pkg\nimport gaps.pkg.sub as sub\nfunction twice (x :: Int32) -> Integer is sub.base x * 2 end function\nend unit\n")
        , ("b.lawspec", "unit gaps.pkg.sub\n\nfunction base (x :: Int32) -> Int64 is prelude.Int64 x end function\nend unit\n") ]
        >>= planTesting >>= emitPlan "python")
      map artifactPath files `shouldSatisfy` (\ps -> "src/lawspec_definitions/gaps/pkg/__init__.py" `elem` ps && "src/lawspec_definitions/gaps/pkg/sub.py" `elem` ps)
  describe "the gaps LawTwin's contracts and importer found next" $ do
    it "brings bounded arithmetic with an import's copies (20)" $
      programs
        [ ("a.lawspec", "unit gaps.inner\n\nfunction bump (x :: Int64) -> Int64 is prelude.saturating (x + 1) end function\nend unit\n")
        , ("b.lawspec", "unit gaps.outer\nimport gaps.inner as inner\nfunction twice (x :: Int64) -> Int64 is inner.bump (inner.bump x) end function\nend unit\n") ]
        `shouldSatisfy` isRight
    it "generates Java and Kotlin for a field named record (21)" $ do
      let source = "unit gaps.rec\n\ntype Fetched is a record{  record :: Int64} end type\nfunction at (f :: Fetched) -> Int64 is f.record end function\nend unit\n"
      mapM_ (\target -> (program source >>= planTesting >>= emitPlan target) `shouldSatisfy` isRight) ["java", "kotlin"]
    it "proves a regex field through a record update (23)" $
      program (unlines
        [ "unit gaps.pet"
         ++ "\n", ""
        , "type Pet is a record{  id :: Maybe Int64 name :: (v :: Text where v matches regex \"[a-z]+\")} end type\n"
        , "function withId (body :: Pet) (key :: Int64) -> Pet is body with id = Present key end function\n"
        , "\nend unit" ])
        `shouldSatisfy` isRight
    it "takes a failing row from a signature that never raises (24)" $
      program (unlines
        [ "unit gaps.by"
        , ""
        , "type Refusal is one of | Negative end type\n"
        , "procedure peek (total :: Int64) -> Pair Int64 Int64 fails with Refusal is Pair record{ first = total , second = total} end procedure\n"
        , "ability Counter is"
        , "  current :: Int64 fails with Refusal"
        , "end ability"
        , "handler tally for Counter with state total :: Int64 start 0 is"
        , "  operation current by peek end operation"
        , "end handler"
        , "end unit" ])
        `shouldSatisfy` isRight
    it "lets a field refinement call a checked definition (25)" $
      program (unlines
        [ "unit gaps.tag"
         ++ "\n", ""
        , "function validName (name :: Text) -> Bool is name matches regex \"[a-z]+\" end function\n"
        , "type Tag is a record{  label :: (v :: Text where validName v)} end type\n"
        , "law \"|a tag keeps its label| is definition : for all (t :: Tag) => validName t.label = true end for all end definition end law"
        , "\nend unit" ])
        `shouldSatisfy` isRight
    it "names a spec handler apart from the ability it is named like (26)" $ do
      files <- either (\ds -> fail (show ds)) pure (program (unlines
        [ "unit gaps.counter"
         ++ "\n", ""
        , "ability Counter is"
        , "  add :: Int64 -> Int64"
        , "end ability"
        , "handler counter for Counter is"
        , "   operation add n is n end operation"
        , "end handler"
        , "\nend unit" ]) >>= planTesting >>= emitPlan "rust")
      concatMap artifactContent files `shouldSatisfy` isInfixOf "pub struct CounterSpec"
