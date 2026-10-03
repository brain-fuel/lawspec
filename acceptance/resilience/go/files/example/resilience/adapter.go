// User-owned LawSpec adapter: the workflow runtime under test.
package resilience

import "math/big"

// RuntimeExponentialDelay is the runtime's exponential delay.
func RuntimeExponentialDelay(value0 *LawSpecBigInt, value1 *LawSpecBigInt, value2 *LawSpecBigInt) any {
	retry := &lawSpecRetry{Strategy: "exponential", Delay: value0.Int64(), Factor: value1.Int64(), Cap: -1}
	return big.NewInt(lsRetryDelay(retry, value2.Int64()))
}

// RuntimeLinearDelay is the runtime's linear delay.
func RuntimeLinearDelay(value0 *LawSpecBigInt, value1 *LawSpecBigInt, value2 *LawSpecBigInt) any {
	retry := &lawSpecRetry{Strategy: "linear", Delay: value0.Int64(), Step: value1.Int64(), Cap: -1}
	return big.NewInt(lsRetryDelay(retry, value2.Int64()))
}

// RuntimeFibonacciDelay is the runtime's fibonacci delay.
func RuntimeFibonacciDelay(value0 *LawSpecBigInt, value1 *LawSpecBigInt) any {
	retry := &lawSpecRetry{Strategy: "fibonacci", Delay: value0.Int64(), Cap: -1}
	return big.NewInt(lsRetryDelay(retry, value1.Int64()))
}

// SplitMix gives the first outputs for a seed.
func SplitMix(value0 uint64, value1 int32) []uint64 {
	random := LawSpecSplitMix64{value0}
	result := make([]uint64, value1)
	for i := range result {
		result[i] = random.Next()
	}
	return result
}

// FullJitter jitters a delay with a fresh source.
func FullJitter(value0 uint64, value1 *LawSpecBigInt) any {
	random := LawSpecSplitMix64{value0}
	return big.NewInt(lsJittered("full", value1.Int64(), 0, 0, &random))
}

func waits(attempts int32, when func(LawSpecValue) bool) []*LawSpecBigInt {
	runtime := NewLawSpecWorkflowRuntime(&LawSpecVirtualClock{}, 0)
	retry := &lawSpecRetry{Strategy: "exponential", Delay: 100000, Factor: 2, Cap: -1, Attempts: int64(attempts), Jitter: "none", When: when}
	lsRunStage(runtime.Context(nil), lawSpecStagePolicy{Stage: "stage", Retry: retry, Timeout: -1}, func() LawSpecValue {
		return LawSpecValue{"Either", lawSpecData{"Either::Left", []LawSpecValue{lsInteger64(0)}}}
	})
	result := []*LawSpecBigInt{}
	for _, event := range runtime.Trace {
		if event.Kind == "sleep" {
			result = append(result, big.NewInt(event.Number))
		}
	}
	return result
}

// RetriedWaits are the waits between a failing stage's attempts.
func RetriedWaits(value0 int32) []*LawSpecBigInt { return waits(value0, nil) }

// RejectedWaits are the waits when the error is not retried.
func RejectedWaits(value0 int32) []*LawSpecBigInt {
	return waits(value0, func(LawSpecValue) bool { return false })
}
