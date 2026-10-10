-- | The language gaps a large dependency contract (LawTwin's Kafka contract)
-- found: fields, failing operations, handlers of several abilities, sets of
-- handlers, natives made with a resource, handler clause forms, sequences,
-- bounded arithmetic, integer recursion, the checker's facts, regex-shaped
-- generation and Python packages. ref:REQ-language-gaps
module LanguageGapsSpec (test_languageGapsClose) where

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
evaluated body = program (unlines ("unit gaps.eval" : body)) >>= dischargeEvidence >>= \_ -> pure []

names :: C.Program -> [String]
names compiled = [C.propertyName p | u <- C.programUnits compiled, p <- C.unitProperties u]

handlersOf :: String -> C.Program -> Maybe [String]
handlersOf law compiled = lookup law
  [(C.propertyName p, map (show . snd) (C.propertyHandlers p)) | u <- C.programUnits compiled, p <- C.unitProperties u]

store :: String
store = unlines
  [ "unit gaps.store"
  , "type Problem is | Missing end"
  , "handle Disk"
  , "openDisk :: Unit -> Disk"
  , "closeDisk :: Disk -> Unit"
  , "resource Disk is acquire is openDisk unitValue end release d is closeDisk d end end"
  , "ability Logs with Disk is"
  , "  create :: Text -> Unit"
  , "  append :: Text -> Int32 -> Int64 fails with Problem"
  , "laws"
  , "  law `an unknown log refuses appends` is"
  , "    definition is `for all` (t :: Text) (v :: Int32) . append t v fails with Missing end"
  , "  end"
  , "end"
  , "ability Reader with Disk is"
  , "  size :: Text -> Maybe Int64"
  , "end"
  , "handler memory for Logs, Reader with state logs :: KeyVal Text (List Int32) start prelude.keyValOf [] is"
  , "  create t is ~logs := prelude.put t [] logs; unitValue end"
  , "  append t v is"
  , "    match prelude.lookup t logs with"
  , "    | Nothing -> raise Missing"
  , "    | Just l -> ~logs := prelude.put t (Cons v l) logs; prelude.Int64 (prelude.length l)"
  , "    end"
  , "  end"
  , "  size t is match prelude.lookup t logs with | Nothing -> Nothing | Just l -> Just (prelude.Int64 (prelude.length l)) end end"
  , "end" ]

test_languageGapsClose :: Spec
test_languageGapsClose = describe "the language gaps a dependency contract found" $ do
  describe "fields" $ do
    it "reads and replaces fields of a single-constructor type" $
      evaluated
        [ "type Point is Point x :: Int32 y :: Int32 end"
        , "definition moved (p :: Point) :: Point is if p.x < 100 then p with x = prelude.Int32 (p.x + 1) else p end"
        , "law `moves` is definition is (moved (Point 1 2)).x = 2 and (moved (Point 1 2)).y = 2 end end" ]
        `shouldSatisfy` isRight
    it "refuses a field of a sum" $
      program (unlines
        [ "unit gaps.sum", "type Shape is | Dot | Line from :: Int32 end"
        , "definition f (s :: Shape) :: Int32 is s.from end" ])
        `shouldSatisfy` failsWith "more than one constructor"
    it "refuses a field a type does not have" $
      program (unlines
        [ "unit gaps.field", "type Point is Point x :: Int32 end"
        , "definition f (p :: Point) :: Int32 is p.z end" ])
        `shouldSatisfy` failsWith "has no field called z"
  describe "literals" $
    it "gives a literal branch the type of the other branches" $
      evaluated
        [ "definition first (g :: Maybe Int64) :: Int64 is let from = (match g with | Nothing -> 0 | Just x -> x end) in from end"
        , "law `zero` is definition is first Nothing = 0 end end" ]
        `shouldSatisfy` isRight
  describe "handlers" $ do
    it "lets an operation fail and a clause raise" $
      program store `shouldSatisfy` isRight
    it "refuses a clause that raises what its operation does not fail with" $
      program (unlines
        [ "unit gaps.raise", "type Problem is | Missing end"
        , "ability Logs is", "  size :: Int32", "end"
        , "handler broken for Logs is size is raise Missing end end" ])
        `shouldSatisfy` isLeft
    it "runs a handler of several abilities for each, once" $ do
      let Right compiled = program (store ++ "law `sizes count` is definition is `for all` (t :: Text) (v :: Int32) . (create t; append t v; size t) = Just 1 end end\n")
      names compiled `shouldSatisfy` elem "sizes count [memory]"
      handlersOf "sizes count [memory]" compiled `shouldSatisfy` maybe False (\hs -> length (filter ("memory" `isInfixOf`) hs) == 2)
    it "gives a law that runs a native made with a resource that resource" $ do
      let Right compiled = program (store ++ "law `sizes count` is definition is `for all` (t :: Text) . (create t; size t) = Just 0 end end\n")
          resources = [length (C.propertyResources p) | u <- C.programUnits compiled, p <- C.unitProperties u, "[native" `isInfixOf` C.propertyName p]
      resources `shouldSatisfy` (\rs -> not (null rs) && all (== 1) rs)
    it "runs every law of a set's abilities under the whole set" $ do
      let Right compiled = program (store ++ unlines
            [ "ability Writer is", "  write :: Text -> Int32 -> Bool"
            , "laws", "  law `a write is read` is"
            , "    definition is `for all` (t :: Text) (v :: Int32) . (create t; write t v; size t) = Just 1 end"
            , "  end", "end"
            , "handler client for Writer is write t v is prelude.isRight (prelude.attempt (append t v)) end end"
            , "handlers reference is memory, client end" ])
      names compiled `shouldSatisfy` elem "Writer: a write is read [reference]"
    it "starts a handler from a computed value and writes clauses by definitions" $
      evaluated
        [ "ability Counter is", "  bump :: Bool", "  total :: Int64", "end"
        , "definition start (u :: Unit) :: Int64 is 0 end"
        , "definition bumped (n :: Int64) :: Pair Bool Int64 is if n < 1000 && n >= 0 then Pair true (prelude.Int64 (n + 1)) else Pair false n end"
        , "definition totalOf (n :: Int64) :: Pair Int64 Int64 is Pair n n end"
        , "handler counting for Counter with state n :: Int64 start start unitValue is"
        , "  bump by bumped", "  total by totalOf", "end"
        , "handler branching for Counter with state n :: Int64 start 0 is"
        , "  bump is if n < 1000 && n >= 0 then (~n := prelude.Int64 (n + 1); true) else false end"
        , "  total is n end", "end"
        , "law `bumps count` using counting is definition is (bump; bump; total) = 2 end end"
        , "law `branches count` using branching is definition is (bump; bump; total) = 2 end end" ]
        `shouldSatisfy` isRight
  describe "prelude helpers in ability laws" $
    it "rewrites isRight inside an ability's laws" $
      program (unlines
        [ "unit gaps.railway", "type E is | Bad end"
        , "ability Store is", "  get :: Int32 -> Either E Int32"
        , "laws", "  law `get succeeds` is definition is `for all` (x :: Int32) . prelude.isRight (get x) = true end end", "end"
        , "handler ok for Store is get x is Right x end end" ])
        `shouldSatisfy` isRight
  describe "sequences and bounded arithmetic" $ do
    it "joins, slices, indexes and encodes" $
      evaluated
        [ "law `sequences` is definition is"
        , "  \"a\" ++ \"b\" = \"ab\" and prelude.slice 1 3 \"kafka\" = \"af\" and prelude.at 1 [10, 20] = Just 20"
        , "    and prelude.range 0 3 = [0, 1, 2] and prelude.utf8 \"é\" = prelude.bytesOf [195, 169]"
        , "    and prelude.textOf 42 = \"42\" and prelude.join \", \" [\"a\", \"b\"] = \"a, b\""
        , "end end" ]
        `shouldSatisfy` isRight
    it "refutes a false sequence law" $
      evaluated ["law `wrong` is definition is prelude.slice 0 2 \"abc\" = \"abc\" end end"]
        `shouldSatisfy` isLeft
    it "wraps, saturates and bounds into the type the context wants" $
      evaluated
        [ "definition next (e :: Int16) :: Int16 is prelude.wrapping (e + 1) end"
        , "definition up (l :: UInt8) :: UInt8 is prelude.saturating (l + 10) end"
        , "definition sum (a :: Int32) (b :: Int32) :: Maybe Int32 is prelude.bounded (a + b) end"
        , "law `bounded` is definition is next 32767 = -32768 and up 250 = 255 and sum 2147483647 1 = Nothing and sum 1 2 = Just 3 end end" ]
        `shouldSatisfy` isRight
  describe "totality" $ do
    it "accepts recursion that counts an integer down or up to a bound" $
      program (unlines
        [ "unit gaps.recursion"
        , "definition down (n :: Natural) :: List Natural is if n == 0 then [] else Cons n (down (n - 1)) end"
        , "definition up (i :: Int32) (n :: Int32) :: List Int32 is if i >= n || i < 0 then [] else Cons i (up (prelude.Int32 (i + 1)) n) end" ])
        `shouldSatisfy` isRight
    it "rejects recursion that moves away from every bound" $
      program (unlines
        [ "unit gaps.forever"
        , "definition grow (n :: Integer) :: List Integer is if n == 0 then [] else Cons n (grow (n + 1)) end" ])
        `shouldSatisfy` failsWith "no integer argument moves strictly toward a bound"
    it "uses guards on lengths, call results and remainders" $
      program (unlines
        [ "unit gaps.facts"
        , "definition dec (n :: Int32) :: Int32 is if n > Int32.min then prelude.Int32 (n - 1) else n end"
        , "definition clip (xs :: List Int32) :: Int32 is if prelude.length xs <= 100 then prelude.Int32 (prelude.length xs) else 100 end"
        , "definition clip2 (n :: Int32) :: Int32 is let m = dec n in if m >= 1 then prelude.Int32 (m - 1) else 0 end"
        , "definition owner (p :: Int32) (k :: Int32) :: Int32 is if k >= 1 && p >= 0 then prelude.Int32 (prelude.rem p k) else 0 end" ])
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
        , "definition valid (name :: Text) :: Bool is let n = prelude.length name in n >= 1 && name matches regex \"[a-z]+\" end"
        , "law `named` is definition is `for all` (t :: Text where valid t) . prelude.length t >= 1 end end" ])
        >>= planTesting >>= emitPlan "python")
      let tests = [artifactContent f | f <- files, "test_gaps_regex_lawspec.py" `isSuffixOf` artifactPath f]
      tests `shouldSatisfy` any ("\"type\": \"Text\", \"units\": [" `isInfixOf`)
  describe "Python packages" $
    it "makes a unit with units inside it its package's __init__.py" $ do
      files <- either (\ds -> fail (show ds)) pure (programs
        [ ("a.lawspec", "unit gaps.pkg\nimport gaps.pkg.sub as sub\ndefinition twice (x :: Int32) :: Integer is sub.base x * 2 end\n")
        , ("b.lawspec", "unit gaps.pkg.sub\ndefinition base (x :: Int32) :: Int64 is prelude.Int64 x end\n") ]
        >>= planTesting >>= emitPlan "python")
      map artifactPath files `shouldSatisfy` (\ps -> "src/lawspec_definitions/gaps/pkg/__init__.py" `elem` ps && "src/lawspec_definitions/gaps/pkg/sub.py" `elem` ps)
