package factories

import (
	"fixture/model"
	"pgregory.net/rapid"
)

func Parcels[T any](child *rapid.Generator[T]) *rapid.Generator[model.Parcel[T]] {
	return rapid.Map(child, func(value T) model.Parcel[T] { return model.NewParcel(value) })
}
func Positives() *rapid.Generator[model.Positive] {
	return rapid.Map(rapid.Int8Range(1, 100), func(value int8) model.Positive { return model.NewPositive(value) })
}
