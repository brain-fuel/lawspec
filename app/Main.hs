module Main where
import qualified Data.ByteString.Lazy.Char8 as B
import System.Environment (getArgs)
import LawSpec.Api (dispatch)
import LawSpec.Gen (generate, generateInto)
import LawSpec.Code.Doc (Layout(..))
main :: IO ()
main = getArgs >>= \case
  ["--generate-api"] -> generate
  ["--generate-api", "--minify"] -> generateInto "npm" Compact
  _ -> B.getContents >>= B.putStrLn . dispatch
