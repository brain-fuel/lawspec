module Main where
import qualified Data.ByteString.Lazy.Char8 as B
import LawSpec.Api (dispatch)

-- | The native compiler: one JSON request on stdin, one response on stdout.
main :: IO ()
main = B.getContents >>= B.putStrLn . dispatch
