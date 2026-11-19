{-# LANGUAGE ForeignFunctionInterface #-}

-- | The WebAssembly interpreter of the host effects: each request is encoded
-- in the versioned JSON envelope, with the policy the host must enforce
-- again, and passed to the host's synchronous @lawspec_host.perform@ import.
-- Built only into the WebAssembly core.
-- ref:DEC-host-effect-abi
module LawSpec.Host.Wasm (wasmHost, readBuffer, writeBuffer) where

import Control.Monad (foldM_)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word32, Word8)
import Foreign.Marshal.Alloc (free, mallocBytes)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr, plusPtr)
import Foreign.Storable (peek, poke)
import LawSpec.Host.Codec (decodeResultBytes, encodeEffectBytes)
import LawSpec.Host.Effect
import LawSpec.Host.Policy (Policy, closed)

foreign import ccall unsafe "lawspec_host_perform"
  hostPerform :: Ptr Word8 -> Word32 -> IO (Ptr Word8)

-- | The host, confined to 'closed' until a command confines it to its
-- policy.
wasmHost :: Host IO
wasmHost = confinedTo closed

confinedTo :: Policy -> Host IO
confinedTo policy = Host (performUnder policy) confinedTo

performUnder :: Policy -> Effect a -> IO (Either HostError a)
performUnder policy effect = do
  reply <- BU.unsafeUseAsCStringLen (encodeEffectBytes policy effect) $ \(bytes, size) ->
    hostPerform (castPtr bytes) (fromIntegral size)
  if reply == nullPtr
    then pure (Left (HostError Failed ("the host returned no reply to " ++ effectName effect)))
    else do
      body <- readBuffer reply
      free reply
      pure $ case decodeResultBytes effect body of
        Right result -> result
        Left problem -> Left (HostError Failed ("malformed host reply to " ++ effectName effect ++ ": " ++ problem))

-- | A length-prefixed buffer's bytes: a little-endian u32, then the bytes.
readBuffer :: Ptr Word8 -> IO B.ByteString
readBuffer pointer = do
  size <- littleEndian <$> mapM (\offset -> peek (pointer `plusPtr` offset) :: IO Word8) [0 .. 3]
  B.packCStringLen (castPtr (pointer `plusPtr` 4), fromIntegral size)
  where
    littleEndian = foldr (\byte total -> total * 256 + fromIntegral byte) (0 :: Word32)

-- | A malloc'd length-prefixed copy, freed by whoever receives it.
writeBuffer :: [B.ByteString] -> IO (Ptr Word8)
writeBuffer chunks = do
  let total = sum (map B.length chunks)
  out <- mallocBytes (4 + total)
  mapM_ (\offset -> poke (out `plusPtr` offset) (fromIntegral ((total `div` (256 ^ offset)) `mod` 256) :: Word8)) [0 .. 3]
  let copy offset chunk = BU.unsafeUseAsCStringLen chunk $ \(bytes, size) -> do
        copyBytes (out `plusPtr` offset) (castPtr bytes) size
        pure (offset + size)
  foldM_ copy 4 chunks
  pure out
