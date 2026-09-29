package shapes

type Wrapped[T any] struct{ Stored T }
type Link[T any] interface{ link(T) }
type End[T any] struct{}
type Next[T any] struct {
	Item      T
	Remainder LawSpecMaybe[Link[T]]
}

func (End[T]) link(T)  {}
func (Next[T]) link(T) {}

type Forest[T any] interface{ forest(T) }
type Item[T any] struct{ Datum T }
type Group[T any] struct{ Trees []Forest[T] }

func (Item[T]) forest(T)  {}
func (Group[T]) forest(T) {}

type Seal struct{}

func Copy[T any](value T) T { return value }
