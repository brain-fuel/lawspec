package RUNTIME_PACKAGE

import "pgregory.net/rapid"

var nativeByteDraws int

func NativeBytes() *rapid.Generator[int8] {
	return rapid.Map(rapid.IntRange(6, 20), func(value int) int8 {
		nativeByteDraws++
		return int8(value)
	})
}

func NativeTexts() *rapid.Generator[string] { return rapid.Just("application text") }
