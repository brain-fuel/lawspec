-- | lawspec-dev capability-receipts [--check]: the receipts of the capability
-- laws' proofs (src/LawSpec/CapabilityReceipts.hs). A receipt binds a law to
-- every script its proof runs and to the solver that ran them. Without
-- --check, each law whose receipt is not current is proved again with Z3,
-- and the file is rewritten; a law Z3 does not prove gets no receipt, so it
-- cannot be cited. With --check, nothing is proved: the command fails when
-- a receipt is missing or not current. ref:DEC-capability-laws
module CapabilityReceipts (capabilityReceiptsCommand) where

import Control.Monad (forM, unless, when)
import Data.Aeson (Value (..), toJSON)
import qualified Data.Aeson.KeyMap as K
import Data.Foldable (toList)
import Data.List (intercalate)
import qualified Data.Text as T
import qualified LawSpec.Core as C
import LawSpec.CapabilityReceipts (capabilityReceipts, capabilityReceiptsProver)
import qualified LawSpec.Core.Smt as Smt
import LawSpec.ProofSettings (capabilityLawKey, capabilityLawTasks)
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), die)
import System.Process (readProcess, readProcessWithExitCode)

receiptsFile :: FilePath
receiptsFile = "src/LawSpec/CapabilityReceipts.hs"

capabilityReceiptsCommand :: [String] -> IO ()
capabilityReceiptsCommand options = do
  check <- case options of
    [] -> pure False
    ["--check"] -> pure True
    _ -> die "usage: lawspec-dev capability-receipts [--check]"
  tasks <- either die pure capabilityLawTasks
  explicit <- lookupEnv "LAWSPEC_Z3"
  z3 <- maybe (findExecutable "z3") (pure . Just) explicit
  prover <- traverse (\binary -> takeWhile (/= '\n') <$> readProcess binary ["--version"] "") z3
  let sameProver = maybe True (== capabilityReceiptsProver) prover
      current task = sameProver && lookup (name task) capabilityReceipts == Just (capabilityLawKey task)
      stale = filter (not . current) tasks
      name = C.idText . Smt.taskLaw
  if check
    then do
      unless (null stale) $ die ("capability receipts are not current for: " ++ intercalate ", " (map name stale)
        ++ maybe "" (\found -> if sameProver then "" else " (they are " ++ show capabilityReceiptsProver ++ "'s; this is " ++ show found ++ ")") prover
        ++ "; run lawspec-dev capability-receipts")
      putStrLn ("All " ++ show (length tasks) ++ " capability receipts are current" ++ maybe "; Z3 is not installed, so its version was not compared." (const ".") prover)
    else case (stale, z3, prover) of
      ([], _, _) -> putStrLn ("All " ++ show (length tasks) ++ " capability receipts are current; nothing was proved.")
      (_, Just binary, Just version) -> do
        results <- forM tasks $ \task ->
          if current task then pure (task, True) else do
            proved <- prove binary (toJSON task)
            putStrLn ((if proved then "proved      " else "NOT PROVED  ") ++ name task)
            pure (task, proved)
        writeFile receiptsFile (render version [(name task, capabilityLawKey task) | (task, True) <- results])
        let failed = [name task | (task, False) <- results]
        when (not (null failed)) $ die ("no receipt for: " ++ intercalate ", " failed)
        putStrLn ("Wrote " ++ receiptsFile ++ ": " ++ show (length results) ++ " receipts, " ++ show (length stale) ++ " proved now.")
      _ -> die "capability receipts are not current, and Z3 is not installed (or set LAWSPEC_Z3)"

-- | Proved outright, or in every case of its induction; each in its first
-- encoding or, failing that, its other one.
prove :: FilePath -> Value -> IO Bool
prove z3 task = do
  direct <- outcome task
  if direct then pure True else case field "induction" task >>= field "cases" of
    Just (Array cases) | not (null cases) -> and <$> mapM outcome (toList cases)
    _ -> pure False
  where
    outcome scripted = do
      first <- maybe (pure False) solve (text "script" scripted)
      if first then pure True else maybe (pure False) solve (field "alternative" scripted >>= text "script")
    solve script = do
      (status, output, _) <- readProcessWithExitCode z3 ["-in", "-smt2", "-t:10000"] (script ++ "(check-sat)\n")
      pure (status == ExitSuccess && takeWhile (/= '\n') output == "unsat")
    field key value = case value of
      Object fields -> K.lookup key fields
      _ -> Nothing
    text key value = case field key value of
      Just (String found) -> Just (T.unpack found)
      _ -> Nothing

render :: String -> [(String, String)] -> String
render prover receipts = unlines $
  [ "-- | The receipts of the capability laws' proofs. Written by"
  , "-- lawspec-dev capability-receipts; do not edit. ref:DEC-capability-laws"
  , "module LawSpec.CapabilityReceipts (capabilityReceipts, capabilityReceiptsProver) where"
  , ""
  , "-- | The solver that proved them."
  , "capabilityReceiptsProver :: String"
  , "capabilityReceiptsProver = " ++ show prover
  , ""
  , "-- | Each proved law, and what its proof was of (LawSpec.ProofSettings.capabilityLawKey)."
  , "capabilityReceipts :: [(String, String)]"
  , "capabilityReceipts =" ]
  ++ [ (if i == (0 :: Int) then "  [ " else "  , ") ++ show receipt | (i, receipt) <- zip [0 ..] receipts ]
  ++ [ if null receipts then "  [ ]" else "  ]" ]
