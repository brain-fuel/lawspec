package domain

type Box[T any] struct{ Payload T }
type Tree[T any] interface{ tree(T) }
type Leaf[T any] struct{ Value T }
type Branch[T any] struct{ Children []Tree[T] }

func (Leaf[T]) tree(T)   {}
func (Branch[T]) tree(T) {}

type Currency int

const (
	Dollars Currency = iota
	Euros
)

func Copy[T any](value T) T             { return value }
func CopyBox(value Box[int8]) Box[int8] { return value }
