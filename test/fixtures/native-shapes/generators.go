package shapes

import (
	"testing"

	"pgregory.net/rapid"
)

func NativeBoxes[T any](child *rapid.Generator[T]) *rapid.Generator[Wrapped[T]] {
	return rapid.Map(child, func(value T) Wrapped[T] { return Wrapped[T]{value} })
}

func NativeSeals() *rapid.Generator[Seal] { panic("finite Seal must not invoke its generator") }

func TestNativeRefinedFactory(t *testing.T) {
	nativeByteDraws = 0
	TestLaw5Property(t)
	if nativeByteDraws == 0 {
		t.Fatal("refined scalar bypassed the native factory")
	}
}

func TestNativeFiniteFactory(t *testing.T) { TestLaw4Boundary0(t) }
