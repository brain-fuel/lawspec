package codecs

import "pgregory.net/rapid"

func NativeParcels[T any](child *rapid.Generator[T]) *rapid.Generator[NativeParcel[T]] {
	return rapid.Map(child, func(value T) NativeParcel[T] { return NativeParcel[T]{&value} })
}
func NativePositives() *rapid.Generator[NativePositive] {
	return rapid.Map(rapid.Int8Range(1, 100), func(value int8) NativePositive { return NativePositive{value} })
}
