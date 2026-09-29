package model

import "pgregory.net/rapid"

func Boxes[T any](child *rapid.Generator[T]) *rapid.Generator[Box[T]] {
	return rapid.Map(child, func(value T) Box[T] { return Box[T]{Stored: value} })
}
