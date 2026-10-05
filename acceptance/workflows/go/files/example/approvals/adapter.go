// User-owned LawSpec adapter: the approve workflow under the real clock.
package approvals

import (
	"time"

	"example.com/lawspec-example/example/workflows"
)

// ApprovedQuickly approves an order: whether it took less than 550ms.
func ApprovedQuickly(value0 int64) LawSpecTask[bool] {
	return LawSpecGo(func() bool {
		runtime := workflows.NewLawSpecWorkflowRuntime(nil, 0)
		started := time.Now()
		workflows.LawSpecDefinitions.Approve(runtime.Context(nil), workflows.Order{Number: value0})
		return time.Since(started) < 550*time.Millisecond
	})
}

// ApprovalErrors approves an order: the messages of its failures, as
// reported.
func ApprovalErrors(value0 int64) LawSpecTask[[]string] {
	return LawSpecGo(func() []string {
		workflows.ResetFinished()
		runtime := workflows.NewLawSpecWorkflowRuntime(nil, 0)
		failure, failed := workflows.LawSpecDefinitions.Approve(runtime.Context(nil), workflows.Order{Number: value0}).Left()
		messages := []string{}
		if !failed {
			return messages
		}
		for _, each := range failure.(workflows.ApproveErrorApproveFailures).Error {
			switch step := each.(type) {
			case workflows.ApproveErrorApproveCheckStockFailed:
				messages = append(messages, step.Error)
			case workflows.ApproveErrorApproveCheckCreditFailed:
				messages = append(messages, step.Error)
			}
		}
		return messages
	})
}
