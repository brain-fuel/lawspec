package slug
import "strings"
func Normalize(x string) string { return strings.ReplaceAll(x, " ", "-") }
func ReferenceNormalize(x string) string { return strings.Join(strings.Split(x, " "), "-") }
