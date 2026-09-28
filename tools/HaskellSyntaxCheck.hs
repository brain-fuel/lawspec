-- Development-only comparison using the installed GHC parser.
module Main where

import Control.Monad (forM_, unless)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Lazy as B
import GHC (getSessionDynFlags, runGhc)
import GHC.Data.FastString (mkFastString)
import GHC.Data.StringBuffer (stringToStringBuffer)
import GHC.Driver.Config.Parser (initParserOpts)
import GHC.Driver.Session (DynFlags, parseDynamicFilePragma)
import GHC.Hs.Dump (BlankEpAnnotations(..), BlankSrcSpan(..), showAstData)
import qualified GHC.Parser as Parser
import GHC.Parser.Header (getOptions)
import GHC.Parser.Lexer (ParseResult(..), initParserState, unP)
import GHC.Types.SrcLoc (mkRealSrcLoc)
import GHC.Driver.Ppr (showSDoc)
import System.Environment (getArgs)

syntax :: DynFlags -> FilePath -> IO String
syntax flags path = do
  source <- readFile path
  let buffer = stringToStringBuffer source
      (_, pragmas) = getOptions (initParserOpts flags) buffer path
  (options, _, _) <- parseDynamicFilePragma flags pragmas
  let state = initParserState (initParserOpts options) buffer
        (mkRealSrcLoc (mkFastString path) 1 1)
  case unP Parser.parseModule state of
    PFailed _ -> error ("Haskell parse failure: " ++ path)
    POk _ parsed -> pure
      (showSDoc options (showAstData BlankSrcSpan BlankEpAnnotations parsed))

main :: IO ()
main = do
  [libdir] <- getArgs
  input <- B.getContents
  pairs <- either fail pure (eitherDecode input :: Either String [[String]])
  runGhc (Just libdir) $ do
    flags <- getSessionDynFlags
    liftIO $ forM_ pairs $ \pair -> case pair of
      [readable, compact] -> do
        first <- syntax flags readable
        second <- syntax flags compact
        unless (first == second)
          (error ("Haskell syntax mismatch: " ++ readable ++ " / " ++ compact))
      _ -> error "expected readable/compact path pairs"
  putStrLn (show (length pairs) ++ " Haskell syntax pairs agree")
