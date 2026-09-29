package canonical_url
import "strings"
func Canonicalize(x string) string { return strings.TrimRight(x, "/") }
