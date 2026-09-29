package model

type Parcel[T any] struct{ item *T }

func NewParcel[T any](item T) Parcel[T] { return Parcel[T]{&item} }
func (value Parcel[T]) Unpack() T       { return *value.item }

type FlatChain[T any] struct {
	items []T
	ended bool
}

func NewChain[T any](items []T, ended bool) FlatChain[T] {
	return FlatChain[T]{append([]T(nil), items...), ended}
}
func (value FlatChain[T]) Items() []T  { return append([]T(nil), value.items...) }
func (value FlatChain[T]) Ended() bool { return value.ended }

type Positive struct{ value int8 }

func NewPositive(value int8) Positive { return Positive{value} }
func (value Positive) Unpack() int8   { return value.value }
func Copy[T any](value T) T           { return value }
