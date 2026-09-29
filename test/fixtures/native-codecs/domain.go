package codecs

type NativeParcel[T any] struct{ item *T }
type NativeFlatChain[T any] struct {
	items []T
	ended bool
}
type NativePositive struct{ value int8 }

func NativeCopy[T any](value T) T { return value }
