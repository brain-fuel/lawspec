{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The LawSpec core as a plain WASI preview1 reactor with no JavaScript FFI,
-- so every host (Node/V8, Go/wazero) loads the same module. The ABI is
-- specified in docs/reference/host-effects.md:
--
--   lawspec_init()                    start the runtime (host_core.c)
--   lawspec_alloc(len) -> ptr         malloc, for request and reply buffers
--   lawspec_free(ptr)                 free
--   lawspec_main(ptr, len) -> ptr     run one CLI invocation
--   lawspec_call(ptr, len) -> ptr     one compiler API request (LawSpec.Api)
--   import lawspec_host.perform(ptr, len) -> ptr
--
-- Every returned pointer is a malloc'd u32 little-endian length followed by
-- that many bytes; the receiver frees it with lawspec_free.
-- ref:DEC-host-effect-abi ref:ghc-wasm
module Main (main) where

import qualified Data.Aeson as JSON
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import Data.Word (Word32, Word8)
import Foreign.Ptr (Ptr, castPtr)
import LawSpec.Api (dispatch)
import LawSpec.App.Main (Outcome (..), decodeInvocation, encodeOutcome, hostCompiler, lawspecMain)
import LawSpec.Host.Conformance (conformance, conformant, renderVerdicts)
import LawSpec.Host.Effect (Effect (..), Stream (..), perform)
import LawSpec.Host.Path (isAbsolute, normalise)
import LawSpec.Host.Wasm (wasmHost, writeBuffer)
import System.Mem (performMajorGC)

foreign export ccall "lawspec_main" lawspecMainExport :: Ptr Word8 -> Word32 -> IO (Ptr Word8)

foreign export ccall "lawspec_call" lawspecCall :: Ptr Word8 -> Word32 -> IO (Ptr Word8)

request :: Ptr Word8 -> Word32 -> IO B.ByteString
request pointer size = do
  -- Calls are serialised by the host; reclaim the previous call's buffers
  -- before allocating another potentially large one.
  performMajorGC
  B.packCStringLen (castPtr pointer, fromIntegral size)

lawspecCall :: Ptr Word8 -> Word32 -> IO (Ptr Word8)
lawspecCall pointer size = do
  bytes <- request pointer size
  writeBuffer (BL.toChunks (dispatch (BL.fromStrict bytes)))

-- | A CLI invocation, or the host conformance suite when the invocation is
-- @{"abi":1,"conformance":"/absolute/scratch"}@.
lawspecMainExport :: Ptr Word8 -> Word32 -> IO (Ptr Word8)
lawspecMainExport pointer size = do
  bytes <- request pointer size
  case conformanceDirectory bytes of
    Just scratch -> do
      checks <- conformance wasmHost scratch
      _ <- perform wasmHost (WriteOutput Stdout (BC.pack (renderVerdicts checks)))
      writeBuffer [encodeOutcome (Right (exitOf (conformant checks)))]
    Nothing -> do
      outcome <- either (pure . Left) (fmap Right . lawspecMain wasmHost hostCompiler) (decodeInvocation bytes)
      writeBuffer [encodeOutcome outcome]
  where
    exitOf passed = Completed (if passed then 0 else 1)

conformanceDirectory :: B.ByteString -> Maybe FilePath
conformanceDirectory bytes = case JSON.decodeStrict bytes of
  Just (JSON.Object fields)
    | Just (JSON.String path) <- KM.lookup "conformance" fields,
      isAbsolute (T.unpack path) ->
        Just (normalise (T.unpack path))
  _ -> Nothing

main :: IO ()
main = pure ()
