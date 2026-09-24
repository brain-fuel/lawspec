module Main where
import qualified Data.ByteString.Lazy.Char8 as B
import System.Environment (getArgs)
import LawSpec.Api (dispatch)
import LawSpec.Gen (generate)
main :: IO ()
main = getArgs >>= \case
  ["--generate-api"] -> generate
  _ -> B.getContents >>= B.putStrLn . dispatch
