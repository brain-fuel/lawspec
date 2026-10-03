// User-owned LawSpec adapter. A Duration is a time.Duration.
package durations

import "time"

// Remaining is the time left of a budget, never negative.
func Remaining(value0 time.Duration, value1 time.Duration) time.Duration {
	if value1 >= value0 {
		return 0
	}
	return value0 - value1
}
