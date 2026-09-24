{-# LANGUAGE ForeignFunctionInterface #-}
module Main (main) where
import qualified Data.ByteString.Lazy as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import GHC.Wasm.Prim (JSString(..), fromJSString, toJSString)
import LawSpec.Api (dispatch)
foreign export javascript "lawspec_call" wasmCall :: JSString -> IO JSString
wasmCall :: JSString -> IO JSString
wasmCall = pure . toJSString . T.unpack . T.decodeUtf8 . B.toStrict . dispatch . B.fromStrict . T.encodeUtf8 . T.pack . fromJSString
main :: IO ()
main = pure ()
