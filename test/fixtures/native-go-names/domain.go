package model

type Box[T any] struct{ Stored T }
type Tree[T any] interface{ appTree(T) }
type Leaf[T any] struct{ Stored T }
type Branch[T any] struct{ Children []Tree[T] }

func (Leaf[T]) appTree(T)   {}
func (Branch[T]) appTree(T) {}
func Copy[T any](value T) T { return value }
