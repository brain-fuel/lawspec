-- | Where the compiler cache lives, the doctor's probe of it and the warning
-- a failed write gives, ported from npm/test/compiler-cache.test.mjs when
-- the legacy CLI's compiler-cache.mjs left the package (0.36.0). The core
-- runs on POSIX paths (its hosts run on macOS and Linux), so the legacy
-- test's path.win32 arithmetic and registry reading have no counterpart.
-- ref:DEC-haskell-application-port
module CompilerCacheSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as M
import LawSpec.App.Command
import LawSpec.App.Compiler (cacheWarning)
import LawSpec.App.Doctor (probeCache)
import LawSpec.App.Json
import LawSpec.App.Main (pureCompiler)
import LawSpec.App.Project (CacheLocation (..), cacheLocation)
import Control.Monad.State.Strict (State)
import LawSpec.Host.Fake
import Test.Hspec

build :: String
build = take 64 ("1152cb545a8623ac7fb5" ++ repeat '0')

json :: String -> Json
json = either error id . parseJson

command :: Command (State World) a -> World -> (a, World)
command action world = case runFake (fst <$> runCommand (newSession fakeHost pureCompiler) action) world of
  (Right value, world') -> (value, world')
  (Left problem, _) -> error (show problem)

location :: [(String, String)] -> Bool -> String -> Maybe CacheLocation
location variables noCache config =
  fst (command (cacheLocation noCache (json config) "/work/service" "/work") emptyWorld {worldEnvironment = variables})

text :: String -> Json -> String
text key report = maybe "" jsString (member key report)

below :: FilePath -> World -> [FilePath]
below root world = [path | path <- M.keys (worldFiles world), (root ++ "/") `isPrefixOf` path]

spec :: Spec
spec = describe "the compiler cache" $ do
  it "is chosen by flag, environment, manifest, then the project default" $ do
    location [] False "{}" `shouldBe` Just (CacheLocation "/work/service/.lawspec/cache" True "default")
    location [] False "{\"cacheDirectory\": \"../c\"}" `shouldBe` Just (CacheLocation "/work/c" False ":cache-directory")
    location [("LAWSPEC_COMPILER_CACHE", "/lc")] False "{\"cacheDirectory\": \"../c\"}" `shouldBe` Just (CacheLocation "/lc" False "LAWSPEC_COMPILER_CACHE")
    -- A relative LAWSPEC_COMPILER_CACHE is relative to the working directory.
    fmap cacheFolder (location [("LAWSPEC_COMPILER_CACHE", "lc")] False "{}") `shouldBe` Just "/work/lc"
    -- The package cache's variable is not the compiler cache's.
    fmap cacheSource (location [("LAWSPEC_CACHE_DIR", "/packages")] False "{}") `shouldBe` Just "default"
    [location [("LAWSPEC_COMPILER_CACHE", "/lc")] noCache config | (noCache, config) <- [(True, "{}"), (False, "{\"cache\": false}"), (False, "{\"cache\": false, \"cacheDirectory\": \"c\"}")]]
      `shouldBe` [Nothing, Nothing, Nothing]
  it "warns once of a failed write, with the reason and the path's length" $ do
    let warning = cacheWarning (json "{\"path\": \"/c/x\", \"reason\": \"permission denied\"}")
    warning `shouldSatisfy` ("the compiler cache is not being written" `isInfixOf`)
    warning `shouldSatisfy` ("permission denied (path of 4 characters: /c/x)" `isInfixOf`)
    warning `shouldSatisfy` ("lawspec doctor" `isInfixOf`)
    warning `shouldSatisfy` (not . ("LongPathsEnabled" `isInfixOf`))
  describe "the doctor's probe" $ do
    it "writes the deepest entry, at most 54 characters below the directory, and leaves nothing behind" $ do
      let (ready, world) = command (probeCache (CacheLocation "/r/cache" True "default") build) (withDirectory "/r" emptyWorld)
      member "ok" ready `shouldBe` Just (JBool True)
      text "target" ready `shouldBe` "compiler cache"
      member "pathLength" ready `shouldBe` Just (JNumber 62)
      text "detail" ready `shouldSatisfy` ("deepest entry 62 characters" `isInfixOf`)
      below "/r" world `shouldBe` []
    it "reports a directory it cannot write, with what to do" $ do
      let (blocked, world) = command (probeCache (CacheLocation "/r/cache" False ":cache-directory") build) (withFile "/r/cache" BC.empty (withDirectory "/r" emptyWorld))
      member "ok" blocked `shouldBe` Just (JBool False)
      text "message" blocked `shouldSatisfy` ("cannot be written" `isInfixOf`)
      text "message" blocked `shouldSatisfy` ("path of 62 characters" `isInfixOf`)
      text "instructions" blocked `shouldSatisfy` ("LAWSPEC_COMPILER_CACHE" `isInfixOf`)
      below "/r" world `shouldBe` ["/r/cache"]
    it "keeps an existing build folder and its entries" $ do
      let kept = "/r/" ++ take 16 build ++ "/zzz/kept"
          (report, world) = command (probeCache (CacheLocation "/r" True "default") build) (withFile kept (BC.pack "entry") (withDirectory "/r" emptyWorld))
      member "ok" report `shouldBe` Just (JBool True)
      [path | path <- below ("/r/" ++ take 16 build ++ "/zzz") world] `shouldBe` [kept]
