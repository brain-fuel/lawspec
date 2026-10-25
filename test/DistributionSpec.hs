-- | Distribution: content hashes and the secure network handler.
module DistributionSpec (test_distributionIsSecureByDefaultAndContentAddressed) where

import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as LC
import Data.Aeson (eitherDecode)
import Data.Either (isLeft)
import LawSpec.Common (Artifact(..))
import LawSpec.NativeRequest (NativeRequest, networkArtifacts)
import qualified LawSpec.NativeRequest as NR
import qualified LawSpec.TestManifest as Manifest
import qualified LawSpec.Network as Network
import Data.List (isPrefixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.Remote (Remote(..), remoteManifest)
import LawSpec.Sha3 (sha3_256Hex)
import LawSpec.Testing (planTesting)
import LawSpec.CoreEmit (emitPlan, emitPlanWithNativeOptions)
import LawSpec.RuntimeSources (runtimeSource)
import LawSpec.Scaffold (scaffoldFiles, scaffoldFilesWith)
import Control.Monad (forM_)
import Data.List (isInfixOf)

-- | Nodes must talk securely by default and name definitions by an unforgeable
-- content hash, on every target alike. ref:REQ-secure-network
test_distributionIsSecureByDefaultAndContentAddressed :: Spec
test_distributionIsSecureByDefaultAndContentAddressed = describe "distribution" $ do
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
        shifted body = unlines ["unit app.remote\n", "\nfunction shifted (x :: Int32) -> Int64 is " ++ body ++ " end" ++ " function\n", "end unit"]
    it "are named by a semantic content hash that names its algorithm and encoding" $ do
      map remoteDigest (remotes (shifted "x + 1000")) `shouldSatisfy` all (\d -> "blake3-semantic-1:" `isPrefixOf` d && length d == 18 + 64)
    it "distinguish machine-dependent remote functions while fixed-width functions stay portable" $ do
      let hashes bits ty = case compileCore bits defaultGeneration [Source "profile.lawspec" (unlines
            ["unit app.profile", "function identity (value :: " ++ ty ++ ") -> " ++ ty ++ " is value end function", "end unit"])] >>= planTesting of
            Left ds -> error (show ds)
            Right plan -> map remoteDigest (snd (remoteManifest plan))
      forM_ ["IntSize", "UIntSize", "UIntPtr"] $ \ty -> do
        hashes 32 ty `shouldSatisfy` (not . null)
        hashes 32 ty `shouldNotBe` hashes 64 ty
      forM_ ["Int32", "UInt64"] $ \ty -> hashes 32 ty `shouldBe` hashes 64 ty
    it "change hash exactly when the definition does" $ do
      map remoteDigest (remotes (shifted "x + 1000")) `shouldBe` map remoteDigest (remotes (shifted "x + 1000"))
      map remoteDigest (remotes (shifted "x + 1000")) `shouldNotBe` map remoteDigest (remotes (shifted "x + 1001"))
      map (C.idText . remoteId) (remotes (shifted "x + 1")) `shouldBe` ["app.remote::shifted"]
  describe "the secure network handler, only when used" $ do
    let paths target text = case compileCore 64 defaultGeneration [Source "app.lawspec" text] >>= planTesting >>= emitPlan target of
          Right files -> map artifactPath files
          Left ds -> error (show ds)
        program imports = unlines ([ "unit app.nodes" ] ++ imports ++ [ "protocol Ping is send Int32 end protocol"
                                                                    , "function shifted (x :: Int32) -> Int64 is x + 1 end function\n", "end unit" ])
        networkFile p = any (`isInfixOf` p) ["lawspec_network.", "LawSpecNetwork.", "src/lawspec/network.rs"]
        targets = ["python", "javascript", "typescript", "go", "java", "kotlin", "haskell", "rust"]
    it "writes the network module beside the runtime of a program that imports lawspec.network" $
      forM_ targets $ \target -> (target, any networkFile (paths target (program ["import lawspec.network"]))) `shouldBe` (target, True)
    it "leaves it out of every other program" $
      forM_ targets $ \target -> (target, any networkFile (paths target (program []))) `shouldBe` (target, False)
    it "never rewrites an already rendered test while adding network companions" $ do
      compiled <- either (fail . show) pure (compileCore 64 defaultGeneration
        [Source "network.lawspec" (program ["import lawspec.network"])])
      let files = [ Artifact "tests/plain.rs" "mod lawspec_runtime;\nlet ctx = &mut ls::Context::testing();\n" "generated" "test"
                  , Artifact "test/PlainSpec.hs" "runIO (LS.useVirtualClock 0)\n" "generated" "test" ]
      mapM_ (\target -> Network.withNetworkModules target (C.programUnits compiled) files `shouldBe` Right files)
        ["rust","haskell"]
    it "uses checked Go package metadata rather than inspecting runtime source" $ do
      compiled <- either (fail . show) pure (compileCore 64 defaultGeneration
        [Source "network.lawspec" (program ["import lawspec.network"])])
      let runtime = Artifact "app/nodes/lawspec_runtime.go" "package misleading\n" "generated" "source"
      files <- either fail pure (Network.withNetworkModules "go" (C.programUnits compiled) [runtime])
      let companions = map artifactContent (filter ((== "app/nodes/lawspec_network.go") . artifactPath) files)
      length companions `shouldBe` 1
      companions `shouldSatisfy` all (isInfixOf "package nodes")
      Network.withNetworkModules "go" (C.programUnits compiled)
        [runtime { artifactPath = "unknown/lawspec_runtime.go" }] `shouldSatisfy` isLeft
    it "invalidates opaque native results when the program enables its network handler" $ do
      let source imports = unlines (["unit app.context"] ++ imports ++
            [ "opaque :: Bool -> Bool"
            , "law called is definition: for all (value :: Bool) => opaque value = value end for all end definition end law"
            , "law pure is definition: for all (value :: Bool) => value = value end for all end definition end law"
            , "end unit" ])
          keys imports = do
            compiled <- compileCore 64 defaultGeneration [Source "context.lawspec" (source imports)]
            pure [(Manifest.entryLabel entry, Manifest.entryKey entry) | entry <- Manifest.testManifest "rust" Nothing compiled]
      before <- either (fail . show) pure (keys [])
      enabled <- either (fail . show) pure (keys ["import lawspec.network"])
      map fst before `shouldContain` ["app.context::called", "app.context::pure"]
      lookup "app.context::called" enabled `shouldNotBe` lookup "app.context::called" before
      lookup "app.context::pure" enabled `shouldBe` lookup "app.context::pure" before
    it "initializes direct and library-bound Rust tests and benchmarks in their own entry points" $ do
      let source = unlines
            [ "unit app.startup", "import lawspec.network", "opaque :: Bool -> Bool"
            , "law called is definition: for all (value :: Bool) => opaque value = value end for all end definition end law"
            , "end unit" ]
          harness = unlines ["harness app.startup.testing for app.startup is"
            , "benchmark `call opaque` is opaque true end benchmark", "end harness"]
      plan <- either (fail . show) pure (compileCore 64 defaultGeneration
        [Source "startup.lawspec" source, Source "startup-testing.lawspec" harness] >>= planTesting)
      forM_ [Nothing, Just "application"] $ \library -> do
        files <- either (fail . show) pure (emitPlanWithNativeOptions False "rust" Nothing Nothing
          NR.emptyBindingPlan { NR.bindingRustCrate = library } plan)
        body <- case [artifactContent a | a <- files, artifactPath a == "tests/app_startup_lawspec.rs"] of
          [value] -> pure value
          _ -> expectationFailure "missing Rust startup test module" >> pure ""
        body `shouldSatisfy` isInfixOf "fn benchmark_call_opaque"
        -- Each law case and benchmark starts with an explicit install. They
        -- must work as the sole test in a new process, without test ordering.
        length (filter (isInfixOf "lawspec_network::install();") (lines body)) `shouldSatisfy` (>= 2)
        case library of
          Nothing -> body `shouldSatisfy` isInfixOf "../src/lawspec/network.rs"
          Just name -> body `shouldSatisfy` isInfixOf ("use " ++ name ++ "::lawspec_network;")
    it "retains structured Haskell network startup when native bindings regenerate a spec" $ do
      let source = unlines
            [ "unit app.startup", "import lawspec.network", "opaque :: Bool -> Bool"
            , "law called is definition: for all (value :: Bool) => opaque value = value end for all end definition end law"
            , "end unit" ]
      compiled <- either (fail . show) pure (compileCore 64 defaultGeneration [Source "startup.lawspec" source])
      request <- either fail pure (eitherDecode (LC.pack
        "{\"functions\":[{\"declaration\":\"app.startup::opaque\",\"native\":[\"Application\",\"opaque\"]}]}"))
      bindings <- either fail pure (NR.resolveNativeRequest compiled request)
      plan <- either (fail . show) pure (planTesting compiled)
      files <- either (fail . show) pure (emitPlanWithNativeOptions False "haskell" Nothing Nothing bindings plan)
      let specs = [artifactContent a | a <- files, artifactPath a == "test/App/StartupSpec.hs"]
      length specs `shouldBe` 1
      specs `shouldSatisfy` all (isInfixOf "runIO LawSpecNetwork.install")
    it "initializes standalone native model entry points before callbacks" $ do
      let source = unlines
            [ "unit app.startup", "import lawspec.network"
            , "type Counter is a record { id :: Int32 } end type"
            , "newCounter :: Unit -> Counter", "async increment :: Counter -> Int64"
            , "function next (n :: Int64 where n >= 0 && n <= 1000000) -> Pair Int64 Int64 is Pair (n + 1) (n + 1) end function"
            , "model counter :: shared Counter by Int64 is"
            , "start newCounter ~ 0", "increment ~ next", "end model", "end unit" ]
      plan <- either (fail . show) pure (compileCore 64 defaultGeneration [Source "model.lawspec" source] >>= planTesting)
      forM_ [("rust", "tests/app_startup_lawspec.rs", "lawspec_network::install();"),
             ("haskell", "test/App/StartupModelSpec.hs", "runIO LawSpecNetwork.install")] $ \(target, path, startup) -> do
        files <- either (fail . show) pure (emitPlan target plan)
        let specs = [artifactContent a | a <- files, artifactPath a == path]
        length specs `shouldBe` 1
        specs `shouldSatisfy` all (isInfixOf startup)
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
  describe "node identities in lawspec.edn" $ do
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
