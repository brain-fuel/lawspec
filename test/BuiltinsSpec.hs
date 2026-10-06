module BuiltinsSpec (spec) where

import Control.Monad (forM_)
import Data.Either (isRight)
import Data.List (isInfixOf, isPrefixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Core.Evidence (Obligation(..), Status(..), statusName)
import LawSpec.CoreEmit (emitPlan, emitPlanWithNativeOptions)
import LawSpec.Discharge (defaultHandlerEvidence, dischargeEvidence)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.NativeBinding (NativeRef(..))
import LawSpec.NativeRequest
import LawSpec.Testing (planTesting)
import LawSpec.BuiltinDefaults (adapterPath, vectorTestPath)

program :: String -> Either [Diagnostic] C.Program
program source = compileCore 64 defaultGeneration [Source "app.lawspec" source]

failsWith :: String -> Either [Diagnostic] a -> Bool
failsWith needle = either (any ((needle `isInfixOf`) . message)) (const False)

source :: [String] -> String
source rest = unlines ("unit app.main" : rest)

files :: String -> String -> Either [Diagnostic] [Artifact]
files target text = program text >>= planTesting >>= emitPlan target

targets :: [String]
targets = ["python", "javascript", "typescript", "go", "java", "kotlin", "haskell", "rust"]

spec :: Spec
spec = describe "built-in abilities" $ do
  describe "importing" $ do
    it "adds a built-in unit to a program that imports it" $ do
      let Right compiled = program (source ["import lawspec.crypto", "fingerprint :: Bytes -> Bytes uses Hash"])
      map (C.idText . C.unitId) (C.programUnits compiled) `shouldSatisfy` elem "lawspec.crypto"
    it "leaves out the units a program does not import" $ do
      let Right compiled = program (source ["twice :: Int32 -> Int32"])
      filter ("lawspec." `isPrefixOf`) (map (C.idText . C.unitId) (C.programUnits compiled)) `shouldBe` []
    it "adds the clock to lawspec.time only when it is imported" $ do
      let Right durations = program (source ["wait :: Int32 -> Duration"])
          Right clock = program (source ["import lawspec.time (Instant)", "stamp :: Int32 -> Instant uses Clock"])
          abilities compiled = [C.abilityName a | u <- C.programUnits compiled, a <- C.unitAbilities u, C.idText (C.abilityOwner a) == "lawspec.time"]
      abilities durations `shouldBe` []
      abilities clock `shouldSatisfy` elem "Clock"
    it "compiles every built-in unit at once" $
      program (source (map ("import lawspec." ++) ["time", "randomness", "crypto", "host", "logging", "concurrent"])) `shouldSatisfy` isRight

  describe "instants" $ do
    it "add durations, subtract instants and compare" $
      program (source
        [ "import lawspec.time (Instant)"
        , "definition later (t :: Instant) (d :: Duration) :: Instant is t + d end"
        , "definition earlier (t :: Instant) (d :: Duration) :: Instant is t - d end"
        , "definition between (a :: Instant) (b :: Instant) :: Duration is b - a end"
        , "definition before (a :: Instant) (b :: Instant) :: Bool is a < b end" ]) `shouldSatisfy` isRight
    it "do not multiply" $
      program (source ["import lawspec.time (Instant)", "definition twice (t :: Instant) :: Instant is t * 2 end"])
        `shouldSatisfy` failsWith "instants support"

  describe "seeded and secure randomness" $ do
    it "accepts seeded random where Random is used" $
      program (source
        [ "import lawspec.randomness"
        , "definition pick (n :: Int64) :: Int64 is randomBelow n end"
        , "law `picks are below` using seeded random 7 is"
        , "  definition is `for all` (n :: Int64 where n >= 1) . (pick n < n) = true end"
        , "end" ]) `shouldSatisfy` isRight
    it "rejects seeded random where SecureRandom is needed" $
      program (source
        [ "import lawspec.randomness"
        , "definition token (n :: Int32) :: Bytes is secureBytes n end"
        , "law `tokens have their length` using seeded random 7 is"
        , "  definition is `for all` (n :: Int32 where n >= 0 && n <= 64) . prelude.length (token n) = n end"
        , "end" ]) `shouldSatisfy` failsWith "needs SecureRandom, which a seeded Random cannot answer"
    it "rejects handling SecureRandom code with the seeded handler" $
      program (source
        [ "import lawspec.randomness"
        , "definition token (n :: Int32) :: Bytes is handle secureBytes n with seededRandom end end" ])
        `shouldSatisfy` failsWith "needs SecureRandom, which a seeded Random cannot answer"
    it "rejects spec handlers for SecureRandom" $
      program (source
        [ "import lawspec.randomness"
        , "handler fixedSecure for SecureRandom is"
        , "  secureBytes n is bytes([1]) end"
        , "  secureBelow n is 0 end"
        , "  secureToken is \"0\" end"
        , "end" ]) `shouldSatisfy` failsWith "SecureRandom has no spec handlers"
    it "names each seed's handler apart" $ do
      let Right compiled = program (source
            [ "import lawspec.randomness"
            , "definition pick (n :: Int64) :: Int64 is randomBelow n end"
            , "law `seven` using seeded random 7 is definition is (pick 10 >= 0) = true end end"
            , "law `eight` using seeded random 8 is definition is (pick 10 >= 0) = true end end" ])
      [C.handlerName h | u <- C.programUnits compiled, C.idText (C.unitId u) == "app.main", h <- C.unitHandlers u]
        `shouldSatisfy` (\names -> all (`elem` names) ["seededRandom7", "seededRandom8"])
    it "takes a seed in handle ... with seededRandom n end" $ do
      let Right compiled = program (source
            [ "import lawspec.randomness"
            , "definition draw (n :: Int64) :: Int64 is handle randomBelow n with seededRandom 42 end end"
            , "definition other (n :: Int64) :: Int64 is handle randomBelow n with seeded random 7 end end" ])
      [C.handlerName h | u <- C.programUnits compiled, C.idText (C.unitId u) == "app.main", h <- C.unitHandlers u]
        `shouldSatisfy` (\names -> all (`elem` names) ["seededRandom42", "seededRandom7"])
    it "rejects a seed for another handler" $
      program (source
        [ "import lawspec.time (Instant)"
        , "definition stamp (n :: Int32) :: Instant is handle now with virtualClock 3 end end" ])
        `shouldSatisfy` failsWith "only seededRandom takes a seed"
    it "needs lawspec.randomness for seeded random" $
      program (source
        [ "ability Dice is roll :: Int32 end"
        , "definition throw (n :: Int32) :: Int32 is roll end"
        , "law `a throw` using seeded random 3 is definition is (throw 1 >= 0) = true end end" ])
        `shouldSatisfy` failsWith "seeded random needs lawspec.randomness"

  describe "laws of the spec handlers" $ do
    it "checks the virtual clock against Clock's laws at compile time" $ do
      let Right compiled = program (source ["import lawspec.time (Instant)", "stamp :: Int32 -> Instant uses Clock"])
          Right evidence = dischargeEvidence compiled
      [obligationStatus o | o <- evidence, "time does not go back [virtualClock]" `isInfixOf` C.idText (obligationDeclaration o)]
        `shouldBe` [ExhaustivelyChecked]

  describe "default handlers" $ do
    let crypto = source
          [ "import lawspec.crypto"
          , "import lawspec.time (Instant)"
          , "import lawspec.randomness"
          , "import lawspec.host"
          , "import lawspec.logging (LogLevel)"
          , "import lawspec.concurrent"
          , "fingerprint :: Bytes -> Bytes uses Hash" ]
    forM_ targets $ \target -> it ("are generated and owned by the compiler on " ++ target) $ do
      let Right emitted = files target crypto
          owned path = [ownership f | f <- emitted, artifactPath f == path]
      forM_ ["lawspec.time", "lawspec.randomness", "lawspec.crypto", "lawspec.host", "lawspec.logging", "lawspec.concurrent"] $ \unit ->
        owned (adapterPath target unit) `shouldBe` ["generated"]
      let Just vectors = vectorTestPath target
      owned vectors `shouldBe` ["generated"]
      concatMap artifactContent emitted `shouldNotSatisfy` ("@@" `isInfixOf`)
    it "carries NIST's vectors into the vector test" $ do
      let Right emitted = files "python" crypto
          Just vectors = vectorTestPath "python"
      concat [artifactContent f | f <- emitted, artifactPath f == vectors] `shouldSatisfy` ("mlkem768-keygen" `isInfixOf`)
    it "name the unit's types as the target does" $ do
      let Right emitted = files "python" (crypto ++ "type Digest is Digest bytes :: Bytes end\n")
      concat [artifactContent f | f <- emitted, artifactPath f == adapterPath "python" "lawspec.crypto"]
        `shouldSatisfy` ("data.LawspecCryptoDigest" `isInfixOf`)
    it "leave Go's adapter stub without the built-in handlers" $ do
      let Right emitted = files "go" crypto
      concat [artifactContent f | f <- emitted, artifactPath f == "app/main/adapter.go"] `shouldNotSatisfy` ("HashHandler" `isInfixOf`)
      [artifactPath f | f <- emitted, artifactPath f == "app/main/lawspec_defaults_crypto.go"] `shouldBe` ["app/main/lawspec_defaults_crypto.go"]
    it "let a program's own ability share a built-in one's name in Go" $ do
      let sources =
            [ Source "journal.lawspec" (unlines
                [ "unit app.journal", "ability Log is note :: Text -> Unit end"
                , "definition remember (n :: Int32) :: Int32 uses Log is note \"kept\"; n end" ])
            , Source "audit.lawspec" (unlines
                [ "unit app.audit", "import lawspec.logging (LogLevel)"
                , "definition shout (n :: Int32) :: Int32 uses Log is logMessage Info \"shout\"; n end" ]) ]
          Right emitted = compileCore 64 defaultGeneration sources >>= planTesting >>= emitPlan "go"
          abilitiesOf path = concat [artifactContent f | f <- emitted, artifactPath f == path]
      abilitiesOf "app/journal/lawspec_abilities.go" `shouldSatisfy` ("type AppJournalLog interface" `isInfixOf`)
      abilitiesOf "app/journal/lawspec_abilities.go" `shouldSatisfy` ("type Log interface" `isInfixOf`)
    it "are reported as default-handler, or assumed when bound" $ do
      let Right compiled = program crypto
          statusOf name evidence = [obligationStatus o | o <- evidence, C.idText (obligationDeclaration o) == name]
          bound = emptyBindingPlan { bindingHandlers = [(C.Id "lawspec.crypto::ability::Signature", NativeRef ["app", "Signer"])] }
      statusName DefaultHandler `shouldBe` "default-handler"
      statusOf "lawspec.crypto::ability::Signature" (defaultHandlerEvidence compiled emptyBindingPlan) `shouldBe` [DefaultHandler]
      statusOf "lawspec.crypto::ability::Signature" (defaultHandlerEvidence compiled bound) `shouldBe` [Assumed]
      statusOf "lawspec.time::ability::Clock" (defaultHandlerEvidence compiled emptyBindingPlan) `shouldBe` [DefaultHandler]
    it "give way to a handler bound in lawspec.json" $ do
      let bound = emptyBindingPlan { bindingHandlers = [(C.Id "lawspec.crypto::ability::Signature", NativeRef ["app", "signers", "Signer"])] }
          Right emitted = program crypto >>= planTesting >>= emitPlanWithNativeOptions False "python" Nothing Nothing bound
      concat [artifactContent f | f <- emitted, "test_lawspec_crypto_lawspec" `isInfixOf` artifactPath f]
        `shouldSatisfy` ("ls.native_handler(\"app.signers\", \"Signer\")" `isInfixOf`)
