package codecs

import (
	"fixture/model"
	"fmt"
)

func ToParcel[A, B any](value Parcel[A], convert func(A) B) (model.Parcel[B], error) {
	item := convert(value.(ParcelParcel[A]).Item)
	return model.NewParcel(item), nil
}
func FromParcel[A, B any](value model.Parcel[B], convert func(B) A) (Parcel[A], error) {
	return ParcelParcel[A]{Item: convert(value.Unpack())}, nil
}
func ToChain[A, B any](value Chain[A], convert func(A) B) (model.FlatChain[B], error) {
	items := []B{}
	for {
		switch part := value.(type) {
		case ChainStop[A]:
			return model.NewChain(items, true), nil
		case ChainMore[A]:
			items = append(items, convert(part.Item))
			if !part.Tail.present {
				return model.NewChain(items, false), nil
			}
			value = part.Tail.value
		default:
			return model.FlatChain[B]{}, fmt.Errorf("unknown chain")
		}
	}
}
func FromChain[A, B any](value model.FlatChain[B], convert func(B) A) (Chain[A], error) {
	tail := LawSpecMaybe[Chain[A]]{}
	if value.Ended() {
		tail = LawSpecMaybe[Chain[A]]{present: true, value: ChainStop[A]{}}
	}
	for i := len(value.Items()) - 1; i >= 0; i-- {
		tail = LawSpecMaybe[Chain[A]]{present: true, value: ChainMore[A]{Item: convert(value.Items()[i]), Tail: tail}}
	}
	if !tail.present {
		return nil, fmt.Errorf("empty chain without Stop has no logical value")
	}
	return tail.value, nil
}
func ToPositive(value Positive) (model.Positive, error) {
	return model.NewPositive(value.(PositivePositive).Value), nil
}
func FromPositive(value model.Positive) (Positive, error) {
	return PositivePositive{Value: value.Unpack()}, nil
}
