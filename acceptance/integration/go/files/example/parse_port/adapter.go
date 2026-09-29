package parse_port
import "strconv"
func ValidPort(x int32) bool { return x >= 1 && x <= 65535 }
func Render(x int32) string { if !ValidPort(x) { panic("invalid port") }; return strconv.FormatInt(int64(x), 10) }
func Parse(x string) int32 { n, err := strconv.ParseInt(x, 10, 32); if err != nil { panic(err) }; return int32(n) }
