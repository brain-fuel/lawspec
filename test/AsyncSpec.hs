-- | Asynchronous adapters through Core, evidence, scaffolds and native bindings.
module AsyncSpec (test_asyncAdaptersAreMarkedReportedAndBoundToEachTargetsTask) where

import Control.Monad (forM_)
import Data.Either (isRight)
import Data.List (isInfixOf)
import Test.Hspec
import qualified LawSpec.Core as C
import LawSpec.Common
import LawSpec.Core.Evidence (Obligation(..))
import LawSpec.CoreEmit (emitPlan)
import LawSpec.Discharge (dischargeEvidence)
import LawSpec.Frontend (compileCore)
import LawSpec.Model (Source(..), defaultGeneration)
import LawSpec.NativeBinding (NativeRef(..))
import LawSpec.NativeRequest
import LawSpec.Testing (planTesting)

orders :: String
orders = unlines
  [ "unit example.orders"
  , "async price :: Text -> Int32"
  , "quote :: Text -> Int32"
  , "law `prices agree` is definition is `for all` (sku :: Text) . price sku = quote sku end end" ]

program :: String -> Either [Diagnostic] C.Program
program source = compileCore 64 defaultGeneration [Source "orders.lawspec" source]

-- | The user-owned adapter stub a target scaffolds.
stub :: String -> String -> Either [Diagnostic] String
stub target source = do
  files <- program source >>= planTesting >>= emitPlan target
  pure (concat [artifactContent f | f <- files, ownership f == "user"])

-- | An adapter that returns a task must be awaited by the generated tests on
-- each target's own concurrency, or a law would check an unresolved task
-- instead of its result. ref:DEC-async-native-tasks ref:REQ-async-adapters
test_asyncAdaptersAreMarkedReportedAndBoundToEachTargetsTask :: Spec
test_asyncAdaptersAreMarkedReportedAndBoundToEachTargetsTask = describe "async adapters" $ do
  it "marks async declarations in Core" $ do
    let Right compiled = program orders
        declarations = [(C.declarationName d, C.declarationAsync d) | u <- C.programUnits compiled, d <- C.unitDeclarations u]
    lookup "price" declarations `shouldBe` Just True
    lookup "quote" declarations `shouldBe` Just False
  describe "as the Async ability" $ do
    let sugared = unlines
          [ "unit example.orders"
          , "price :: Text -> Int32 uses Async"
          , "quote :: Text -> Int32"
          , "law `prices agree` is definition is `for all` (sku :: Text) . price sku = quote sku end end" ]
    it "reads `uses Async` on a signature as `async`" $ do
      let shape source = [ [(C.declarationName d, C.declarationType d, C.declarationAsync d, C.declarationUses d) | d <- C.unitDeclarations u]
                         | Right compiled <- [program source], u <- C.programUnits compiled ]
      shape sugared `shouldBe` shape orders
    it "generates the same code on every target" $
      forM_ ["python", "javascript", "typescript", "go", "java", "kotlin", "haskell", "rust"] $ \target ->
        (program sugared >>= planTesting >>= emitPlan target) `shouldBe` (program orders >>= planTesting >>= emitPlan target)
    it "keeps the other abilities a signature uses" $ do
      let Right compiled = program (unlines
            [ "unit example.pay"
            , "ability Gateway is fee :: Int32 end"
            , "charge :: Int32 -> Bool uses Async, Gateway" ])
      [(C.declarationAsync d, map C.abilityKey (C.declarationUses d)) | u <- C.programUnits compiled, d <- C.unitDeclarations u, C.declarationName d == "charge"]
        `shouldBe` [(True, ["example.pay::ability::Gateway"])]
    it "leaves a unit's own ability called Async alone" $ do
      let Right compiled = program (unlines
            [ "unit example.own"
            , "ability Async is tick :: Int32 end"
            , "ticks :: Int32 -> Int32 uses Async" ])
      [C.declarationAsync d | u <- C.programUnits compiled, d <- C.unitDeclarations u, C.declarationName d == "ticks"] `shouldBe` [False]
  it "keeps async usable as a name" $
    program (unlines ["unit example.names", "async :: Int32 -> Int32"]) `shouldSatisfy` either (const False) (const True)
  it "reports an async adapter's evidence as asynchronous" $ do
    let Right obligations = program orders >>= dischargeEvidence
    [obligationReason o | o <- obligations, obligationStage o == "adapter", "price" `isInfixOf` C.idText (obligationDeclaration o)]
      `shouldSatisfy` all ("asynchronous" `isInfixOf`)
  it "binds a native function returning the target's task" $ do
    let Right compiled = program orders
        request = emptyNativeRequest { requestFunctions =
          [FunctionBinding (C.Id "example.orders::price") (StaticCall (NativeRef ["pricing", "price"])),
           FunctionBinding (C.Id "example.orders::quote") (StaticCall (NativeRef ["pricing", "quote"]))] }
    resolveNativeRequest compiled request `shouldSatisfy` isRight
  describe "scaffolds each target's task" $
    forM_ [ ("python", "async def price"), ("javascript", "export async function price")
          , ("typescript", "export async function price"), ("java", "CompletableFuture<java.lang.Integer> price")
          , ("kotlin", "suspend fun price"), ("go", "LawSpecTask[int32]"), ("haskell", "price :: T.Text -> P.IO I.Int32")
          , ("rust", "pub async fn price") ] $ \(target, expected) ->
      it target $ stub target orders `shouldSatisfy` either (const False) (isInfixOf expected)
