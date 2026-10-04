module AsyncSpec (spec) where

import Control.Monad (forM_)
import Data.Either (isLeft)
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

-- The user-owned adapter stub a target scaffolds.
stub :: String -> String -> Either [Diagnostic] String
stub target source = do
  files <- program source >>= planTesting >>= emitPlan target
  pure (concat [artifactContent f | f <- files, ownership f == "user"])

spec :: Spec
spec = describe "async adapters" $ do
  it "marks async declarations in Core" $ do
    let Right compiled = program orders
        declarations = [(C.declarationName d, C.declarationAsync d) | u <- C.programUnits compiled, d <- C.unitDeclarations u]
    lookup "price" declarations `shouldBe` Just True
    lookup "quote" declarations `shouldBe` Just False
  it "keeps async usable as a name" $
    program (unlines ["unit example.names", "async :: Int32 -> Int32"]) `shouldSatisfy` either (const False) (const True)
  it "reports an async adapter's evidence as asynchronous" $ do
    let Right obligations = program orders >>= dischargeEvidence
    [obligationReason o | o <- obligations, obligationStage o == "adapter", "price" `isInfixOf` C.idText (obligationDeclaration o)]
      `shouldSatisfy` all ("asynchronous" `isInfixOf`)
  it "cannot bind a native function yet" $ do
    let Right compiled = program orders
        request = emptyNativeRequest { requestFunctions =
          [FunctionBinding (C.Id "example.orders::price") (StaticCall (NativeRef ["pricing", "price"]))] }
    resolveNativeRequest compiled request `shouldSatisfy` isLeft
  describe "scaffolds each target's task" $
    forM_ [ ("python", "async def price"), ("javascript", "export async function price")
          , ("typescript", "export async function price"), ("java", "CompletableFuture<java.lang.Integer> price")
          , ("kotlin", "suspend fun price"), ("go", "LawSpecTask[int32]"), ("haskell", "price :: T.Text -> P.IO I.Int32")
          , ("rust", "pub async fn price") ] $ \(target, expected) ->
      it target $ stub target orders `shouldSatisfy` either (const False) (isInfixOf expected)
