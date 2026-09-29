package alternatives
import "strconv"
import "fmt"
func Render(x int32) string { return strconv.FormatInt(int64(x), 10) }
func ReferenceRender(x int32) string { return fmt.Sprintf("%d", x) }
func Clamp(x int32) int32 { return max(0, x) }
func ReferenceClamp(x int32) int32 { if x < 0 { return 0 }; return x }
