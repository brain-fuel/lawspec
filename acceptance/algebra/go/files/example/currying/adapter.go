package currying
import "strconv"
import "strings"
func SumFour(a,b,c,d *LawSpecBigInt) any {return new(LawSpecBigInt).Add(new(LawSpecBigInt).Add(new(LawSpecBigInt).Add(a,b),c),d)}
func Format(prefix string,enabled bool,port int32,suffix string) string {n:=""; if enabled {n=strconv.FormatInt(int64(port),10)}; return prefix+n+suffix}
func ReferenceFormat(prefix string,enabled bool,port int32,suffix string) string {parts:=[]string{prefix}; if enabled {parts=append(parts,strconv.FormatInt(int64(port),10))}; return strings.Join(append(parts,suffix),"")}
func Trim(x string) string {return strings.TrimSpace(x)}
