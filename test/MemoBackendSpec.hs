-- | A capability cache has the same binary admission rules and restores its scope.
-- ref:DEC-host-sdk-independent-consumer
module MemoBackendSpec (spec) where

import Control.Exception (evaluate)
import qualified Data.ByteString as Strict
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.ByteString.Lazy.Char8 as Bytes
import Data.IORef
import qualified Data.Map.Strict as Map
import LawSpec.Memo
import Test.Hspec

spec :: Spec
spec = describe "capability cache backend" $ do
  it "restores the enclosing provider after failure and reads persisted binary entries" $ do
    outer <- newIORef Map.empty
    inner <- newIORef Map.empty
    let provider store =
          CacheBackend
            { cacheRead = \key -> do
                entries <- readIORef store
                maybe (ioError (userError "missing")) pure (Map.lookup key entries),
              cacheWrite = \key bytes -> modifyIORef' store (Map.insert key (Lazy.toStrict bytes))
            }
        run key fallback = do
          table <- newPersistentTable "backend" 100 length
          let result = withCacheDirectory (Just "logical") (Bytes.pack (memoized table key fallback))
          _ <- evaluate (Lazy.length result)
          pure (Bytes.unpack result)
    withCacheBackend (Just (provider outer)) $ do
      run "first" "outer" `shouldReturn` "outer"
      withCacheBackend
        (Just (provider inner))
        ( do
            run "first" "inner" `shouldReturn` "inner"
            ioError (userError "deliberate")
        )
        `shouldThrow` anyIOException
      run "first" (error "persisted outer entry not restored") `shouldReturn` "outer"
      run "second" "after" `shouldReturn` "after"
    Map.size <$> readIORef outer `shouldReturn` 2
    Map.size <$> readIORef inner `shouldReturn` 1
    modifyIORef' outer (Map.map (const (Strict.pack [255])))
    withCacheBackend (Just (provider outer)) (run "first" "recomputed") `shouldReturn` "recomputed"
