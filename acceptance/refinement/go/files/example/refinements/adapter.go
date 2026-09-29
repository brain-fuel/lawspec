package refinements
import "unicode/utf8"
func Add(a,b int8) any {return int16(a)+int16(b)}
func Successor(a int8) any {return int16(a)+1}
func Count(a string) any {return utf8.RuneCountInString(a)}
func Preserve(a uint64) any {return a}
func Positive(a int8) int8 {return a}
func AbstractEcho(a *LawSpecBigInt) any {return a}
