package atoi_codec
import "strconv"
func Itoa(value int32) string { return strconv.FormatInt(int64(value),10) }
func Atoi(value string) int32 { n,err := strconv.ParseInt(value,10,32); if err != nil { panic(err) }; return int32(n) }
