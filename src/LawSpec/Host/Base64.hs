-- | RFC 4648 section 4 base64, with padding, for byte payloads in the host
-- envelope. JSON strings carry text only; file contents and process output
-- are arbitrary bytes. Every host decodes this with its standard library
-- (Node's Buffer, Go's encoding/base64, Java's java.util.Base64).
-- ref:DEC-host-effect-abi
module LawSpec.Host.Base64 (encodeBase64, decodeBase64) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Unsafe as BU

alphabet :: B.ByteString
alphabet = BC.pack "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- | ASCII base64 text.
encodeBase64 :: B.ByteString -> B.ByteString
encodeBase64 bytes = fst (B.unfoldrN size step 0)
  where
    count = B.length bytes
    size = 4 * ((count + 2) `div` 3)
    byte i = if i < count then fromIntegral (BU.unsafeIndex bytes i) else 0 :: Int
    step position =
      let start = 3 * (position `div` 4)
          slot = position `mod` 4
          word = (byte start `shiftL` 16) .|. (byte (start + 1) `shiftL` 8) .|. byte (start + 2)
          sextet = (word `shiftR` (18 - 6 * slot)) .&. 63
       in Just
            ( if slot > count - start then 61 else BU.unsafeIndex alphabet sextet,
              position + 1
            )

-- | Strict decoding: padding only at the end, no whitespace.
decodeBase64 :: B.ByteString -> Either String B.ByteString
decodeBase64 text
  | B.length text `mod` 4 /= 0 = Left "base64 length is not a multiple of 4"
  | B.any (\c -> c >= 128 || table c < 0) body = Left "invalid base64 character"
  | padding > 2 || B.any (== 61) body = Left "misplaced base64 padding"
  | otherwise = Right (fst (B.unfoldrN size step 0))
  where
    padding = B.length (B.takeWhileEnd (== 61) text)
    body = B.take (B.length text - padding) text
    size = 3 * (B.length text `div` 4) - padding
    table c
      | c >= 65 && c <= 90 = fromIntegral c - 65
      | c >= 97 && c <= 122 = fromIntegral c - 71
      | c >= 48 && c <= 57 = fromIntegral c + 4
      | c == 43 = 62
      | c == 47 = 63
      | otherwise = -1 :: Int
    value i = if i < B.length body then table (BU.unsafeIndex body i) else 0
    step position =
      let start = 4 * (position `div` 3)
          slot = position `mod` 3
          word =
            (value start `shiftL` 18)
              .|. (value (start + 1) `shiftL` 12)
              .|. (value (start + 2) `shiftL` 6)
              .|. value (start + 3)
       in Just (fromIntegral ((word `shiftR` (16 - 8 * slot)) .&. 255), position + 1)
