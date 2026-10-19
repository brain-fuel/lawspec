{-# LANGUAGE ForeignFunctionInterface #-}
module Main (main) where
import qualified Data.ByteString.Internal as Strict
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.ByteString.Unsafe as Strict
import Control.Monad (forM_)
import Foreign.C.Types (CChar)
import Foreign.Ptr (Ptr, castPtr)
import GHC.Wasm.Prim (JSVal, JSString(..))
import LawSpec.Api (dispatch)
import System.Mem (performMajorGC)

-- GHC's documented WASM JSFFI exposes linear memory through __exports.memory.
-- https://ghc.gitlab.haskell.org/ghc/doc/users_guide/wasm.html#javascript-ffi
-- Transfer UTF-8 directly: a character-list intermediate for a large generated
-- project can exceed wasm32's address space before its bytes reach JavaScript.
-- Pointers are unsigned addresses, including allocations above 2 GiB.
foreign import javascript unsafe "$1.length"
  stringLength :: JSString -> IO Int
foreign import javascript unsafe "(new TextEncoder()).encodeInto($1, new Uint8Array(__exports.memory.buffer, $2 >>> 0, $3)).written"
  encodeUtf8 :: JSString -> Ptr CChar -> Int -> IO Int
foreign import javascript unsafe "({decoder: new TextDecoder('utf-8', {fatal: true}), parts: []})"
  newResponse :: IO JSVal
foreign import javascript unsafe "$1.parts.push($1.decoder.decode(new Uint8Array(__exports.memory.buffer, $2 >>> 0, $3), {stream: true}))"
  appendResponse :: JSVal -> Ptr CChar -> Int -> IO ()
foreign import javascript unsafe "($1.parts.push($1.decoder.decode()), $1.parts.join(''))"
  finishResponse :: JSVal -> IO JSString
foreign export javascript "lawspec_call" wasmCall :: JSString -> IO JSString
wasmCall :: JSString -> IO JSString
wasmCall input = do
  -- Calls are serialized by the host. Reclaim the previous request's transport
  -- buffers before allocating another potentially large generated project.
  -- Compiler caches remain ordinary live roots and are preserved by collection.
  performMajorGC
  units <- stringLength input
  -- Three bytes per UTF-16 code unit also bounds supplementary characters.
  let capacity = 3 * units
  request <- Strict.createAndTrim capacity $ \pointer -> encodeUtf8 input (castPtr pointer) capacity
  response <- newResponse
  -- Decode the existing lazy chunks rather than allocating a contiguous copy
  -- of the complete response in wasm32 memory. Streaming preserves Unicode
  -- characters even when their UTF-8 bytes cross a ByteString chunk boundary.
  -- TextDecoder synchronously reads each exact-length view without mutating or
  -- retaining it; unsafeUseAsCStringLen keeps that chunk alive for the call.
  forM_ (Lazy.toChunks (dispatch (Lazy.fromStrict request))) $ \chunk ->
    Strict.unsafeUseAsCStringLen chunk $ \(pointer,size) -> appendResponse response pointer size
  finishResponse response
main :: IO ()
main = pure ()
