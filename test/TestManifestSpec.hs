module TestManifestSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (Value(..), decode, encode, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (isInfixOf, isSuffixOf, sort)
import qualified Data.Text as T
import qualified Data.Vector as V
import System.Directory (listDirectory)
import Test.Hspec
import LawSpec.Api (dispatch)

-- Every bundled example, planned for each target in one program.
planned :: String -> Maybe String -> IO (KM.KeyMap Value)
planned target testDir = do
  names <- sort . filter (".lawspec" `isSuffixOf`) <$> listDirectory "examples/specs"
  sources <- mapM (\name -> (\content -> object ["path" .= name, "content" .= content]) <$> readFile ("examples/specs/" ++ name)) names
  let request = object (["method" .= ("planGeneration" :: String), "target" .= target, "sources" .= sources] ++
        ["testDir" .= d | Just d <- [testDir]])
  case decode (dispatch (encode request)) of
    Just (Object response) -> pure response
    _ -> fail "no response"

field :: String -> KM.KeyMap Value -> Value
field name = maybe Null id . KM.lookup (K.fromString name)

text :: Value -> String
text (String s) = T.unpack s
text _ = ""


-- Long labels are emitted as concatenated string literals: 'a ' + 'b'.
joined :: String -> String
joined ('\'' : rest) | ('+' : after) <- dropWhile (== ' ') rest, ('\'' : more) <- dropWhile (`elem` (" \n" :: String)) after = joined more
joined (c : rest) = c : joined rest
joined [] = []

-- How each target names the tests of law n.
-- A law's tests are named after its label (LawSpec.TestNames); the manifest
-- carries that name.
named :: String -> String -> String
named target name = case target of
  "python" -> "def " ++ name ++ "__"
  "go" -> "func " ++ name ++ "_"
  "rust" -> "fn " ++ name ++ "()"
  "haskell" -> "\"" ++ name ++ "_"
  "kotlin" -> "\"" ++ name ++ "_"
  _ -> name ++ "_"

spec :: Spec
spec = describe "the test manifest" $ do
  forM_ ["python", "javascript", "typescript", "go", "java", "kotlin", "rust", "haskell"] $ \target ->
    it ("names each law's generated test file and tests in " ++ target) $ do
      response <- planned target Nothing
      let Array files = field "files" response
          contents = [ (text (field "path" f), text (field "content" f)) | Object f <- V.toList files ]
          Array tests = field "tests" response
      V.length tests `shouldSatisfy` (> 100)
      forM_ [ t | Object t <- V.toList tests ] $ \t -> do
        let file = text (field "file" t)
            name = text (field "name" t)
        case lookup file contents of
          Nothing -> expectationFailure (target ++ ": no generated test file " ++ file)
          Just content
            | target `elem` ["javascript", "typescript"] ->
                -- Labels are single-quoted string literals there.
                joined content `shouldSatisfy` isInfixOf (concatMap (\c -> if c == '\'' then "\\'" else [c]) (text (field "label" t)))
            | otherwise -> content `shouldSatisfy` isInfixOf (named target name)
  it "follows a custom test directory" $ do
    response <- planned "python" (Just "checks")
    let Array files = field "files" response
        paths = [ text (field "path" f) | Object f <- V.toList files ]
        Array tests = field "tests" response
    forM_ [ t | Object t <- V.toList tests ] $ \t -> do
      let file = text (field "file" t)
      take 7 file `shouldBe` "checks/"
      paths `shouldSatisfy` elem file
