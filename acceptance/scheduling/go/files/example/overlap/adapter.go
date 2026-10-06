// User-owned LawSpec adapter: nap notes when it starts and ends a sleep.
package overlap

import (
	"fmt"
	"os"
	"time"
)

func note(event string, n int32) {
	path := os.Getenv("LAWSPEC_SCHEDULE_LOG")
	if path == "" {
		return
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer file.Close()
	fmt.Fprintf(file, "%s %d %.3f\n", event, n, float64(time.Now().UnixNano())/1e6)
}

// Nap implements nap :: (Int32 -> Bool).
func Nap(value0 int32) LawSpecTask[bool] {
	return LawSpecGo(func() bool {
		note("start", value0)
		time.Sleep(300 * time.Millisecond)
		note("end", value0)
		return true
	})
}
