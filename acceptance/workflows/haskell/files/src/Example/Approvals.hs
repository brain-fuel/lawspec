-- User-owned LawSpec adapter: the approve workflow under the real clock.
module Example.Approvals (approvedQuickly, approvalErrors) where

import Data.IORef (readIORef, writeIORef)
import qualified Data.Int as I
import qualified Data.Text as T
import GHC.Clock (getMonotonicTimeNSec)
import qualified LawSpecRuntime as LS
import qualified LawSpecData as Data
import qualified LawSpecWorkflows.Example.Workflows as Workflows
import qualified Example.Workflows as Checks

-- | Approves an order: whether it took less than 550ms.
approvedQuickly :: I.Int64 -> IO Bool
approvedQuickly number = do
  runtime <- LS.newWorkflowRuntime LS.realClock 0
  symbols <- LS.workflowContext runtime
  started <- getMonotonicTimeNSec
  approved <- pure $! case Workflows.approve symbols (Data.Order number) of
    Right (Right _) -> True
    _ -> False
  ended <- approved `seq` getMonotonicTimeNSec
  pure (ended - started < 550000000)

-- | Approves an order: the messages of its failures, as reported.
approvalErrors :: I.Int64 -> IO [T.Text]
approvalErrors number = do
  writeIORef Checks.finished []
  runtime <- LS.newWorkflowRuntime LS.realClock 0
  symbols <- LS.workflowContext runtime
  let messages = case Workflows.approve symbols (Data.Order number) of
        Right (Left (Data.ApproveErrorApproveFailures failures)) -> concatMap message failures
        _ -> []
      message failure = case failure of
        Data.ApproveErrorApproveCheckStockFailed text -> [text]
        Data.ApproveErrorApproveCheckCreditFailed text -> [text]
        _ -> []
  length messages `seq` pure messages
