{-# LANGUAGE ForeignFunctionInterface #-}
module Main (main) where
import qualified Data.ByteString.Internal as Strict
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.ByteString.Unsafe as Strict
import Foreign.C.Types (CChar)
import Foreign.Ptr (Ptr, castPtr)
import GHC.Wasm.Prim (JSString(..))
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
foreign import javascript unsafe "(new TextDecoder('utf-8', {fatal: true})).decode(new Uint8Array(__exports.memory.buffer, $1 >>> 0, $2))"
  decodeUtf8 :: Ptr CChar -> Int -> IO JSString
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
  -- TextDecoder synchronously reads this exact-length view; it neither mutates
  -- nor retains it. Keep the ByteString alive for that call without making the
  -- extra, NUL-terminated copy used by useAsCStringLen.
  Strict.unsafeUseAsCStringLen (Lazy.toStrict (dispatch (Lazy.fromStrict request))) $ uncurry decodeUtf8
main :: IO ()
main = pure ()
