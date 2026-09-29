package generators

import (
	"example.invalid/native/domain"
	"pgregory.net/rapid"
)

func Boxes[T any](child *rapid.Generator[T]) *rapid.Generator[domain.Box[T]] {
	return rapid.Custom(func(t *rapid.T) domain.Box[T] {
		return domain.Box[T]{Payload: child.Draw(t, "payload")}
	})
}
