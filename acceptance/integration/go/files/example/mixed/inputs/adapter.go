package inputs
import "strings"
func Normalize(x string) string { return strings.ReplaceAll(x, " ", "-") }
func Identity(x int32) int32 { return x }
