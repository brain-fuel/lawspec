module DistributionSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as LC
import Data.Aeson (eitherDecode)
import Data.Either (isLeft)
import LawSpec.Common (Artifact(..))
import LawSpec.NativeRequest (NativeRequest, networkArtifacts)
import Data.List (isPrefixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Remote (Remote(..), remoteManifest)
import LawSpec.Sha3 (sha3_256Hex)
import LawSpec.Testing (planTesting)
import LawSpec.CoreEmit (emitPlan)
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.Scaffold (scaffoldFiles, scaffoldFilesWith)
import Control.Monad (forM_)
import Data.List (isInfixOf)

spec :: Spec
spec = describe "distribution" $ do
  describe "SHA3-256 (FIPS 202)" $
    it "matches the standard's digests across block boundaries" $ do
      sha3_256Hex (BC.pack "") `shouldBe` "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a"
      sha3_256Hex (BC.pack "abc") `shouldBe` "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532"
      sha3_256Hex (BC.pack (replicate 135 'x')) `shouldBe` "c150125edc74b56fb5cbfdd024fabe20ea5a99bd3c97305bbf7cb55885c106fe"
      sha3_256Hex (BC.pack (replicate 136 'x')) `shouldBe` "5bc276bac9c582508b8fa9b3949e7ed9b6e584ee4d2925b29a426b9931ba1486"
      sha3_256Hex (BC.pack (replicate 200 'a')) `shouldBe` "cce34485baf2bf2aca99b94833892a4f52896d3d153f7b840cc4f9fe695f1387"
  describe "remote definitions" $ do
    let remotes text = case compileCore 64 defaultGeneration [Source "app.lawspec" text] >>= planTesting of
          Right plan -> snd (remoteManifest plan)
          Left _ -> []
        shifted body = unlines ["unit app.remote", "definition shifted (x :: Int32) :: Int64 is " ++ body ++ " end"]
    it "are named by a SHA3-256 content hash that names its algorithm" $ do
      map remoteDigest (remotes (shifted "x + 1000")) `shouldSatisfy` all (\d -> "sha3-256:" `isPrefixOf` d && length d == 9 + 64)
    it "change hash exactly when the definition does" $ do
      map remoteDigest (remotes (shifted "x + 1000")) `shouldBe` map remoteDigest (remotes (shifted "x + 1000"))
      map remoteDigest (remotes (shifted "x + 1000")) `shouldNotBe` map remoteDigest (remotes (shifted "x + 1001"))
      map (C.idText . remoteId) (remotes (shifted "x + 1")) `shouldBe` ["app.remote::shifted"]
  describe "the secure network handler, only when used" $ do
    let paths target text = case compileCore 64 defaultGeneration [Source "app.lawspec" text] >>= planTesting >>= emitPlan target of
          Right files -> map artifactPath files
          Left ds -> error (show ds)
        program imports = unlines (["unit app.nodes"] ++ imports ++ ["protocol Ping is send Int32 end", "definition shifted (x :: Int32) :: Int64 is x + 1 end"])
        networkFile p = any (`isInfixOf` p) ["lawspec_network.", "LawSpecNetwork.", "src/lawspec/network.rs"]
        targets = ["python", "javascript", "typescript", "go", "java", "kotlin", "haskell", "rust"]
    it "writes the network module beside the runtime of a program that imports lawspec.network" $
      forM_ targets $ \target -> (target, any networkFile (paths target (program ["import lawspec.network"]))) `shouldBe` (target, True)
    it "leaves it out of every other program" $
      forM_ targets $ \target -> (target, any networkFile (paths target (program []))) `shouldBe` (target, False)
    it "keeps the crypto libraries out of a project that does not use them" $
      forM_ targets $ \target -> do
        let plain = either error (concatMap snd) (scaffoldFiles False target)
            crypto = either error (concatMap snd) (scaffoldFilesWith True False target)
            libraries = ["cryptography", "noble", "circl", "bouncycastle", "crypton", "mlkem", "ml-kem", "ml-dsa", "aes-gcm"]
        (target, filter (`isInfixOf` plain) libraries) `shouldBe` (target, [])
        (target, any (`isInfixOf` crypto) libraries) `shouldBe` (target, True)
    it "keeps every crypto library out of the main runtimes" $
      forM_ [ ("python", ["cryptography"]), ("javascript", ["@noble"]), ("go", ["circl", "crypto/mlkem", "crypto/sha3"])
            , ("java", ["bouncycastle"]), ("haskell", ["import qualified Crypto", "mlkem", "mldsa"])
            , ("rust", ["ml_kem", "ml_dsa", "sha3::", "aes_gcm", "getrandom"]) ] $ \(target, names) ->
        (target, filter (`isInfixOf` runtimeSource target) names) `shouldBe` (target, [])
  describe "node identities in lawspec.json" $ do
    let parse text = eitherDecode (LC.pack text) :: Either String NativeRequest
    it "bind an identity and trusted peers through lawspec-network.conf" $ do
      let Right request = parse "{\"network\": {\"identity\": \"keys/node.seed\", \"trusted\": \"keys/peers.txt\"}}"
      map artifactPath (networkArtifacts request) `shouldBe` ["lawspec-network.conf"]
      map artifactContent (networkArtifacts request) `shouldSatisfy`
        all (\c -> "identity keys/node.seed\n" `isInfixOf'` c && "trusted keys/peers.txt\n" `isInfixOf'` c)
    it "write nothing without a binding" $ do
      let Right request = parse "{}"
      networkArtifacts request `shouldBe` []
    it "have no setting that turns security off" $
      parse "{\"network\": {\"insecure\": true}}" `shouldSatisfy` isLeft
  where
    isInfixOf' needle haystack = any (needle `isPrefixOf`) (tails' haystack)
    tails' [] = [[]]
    tails' xs@(_ : rest) = xs : tails' rest
