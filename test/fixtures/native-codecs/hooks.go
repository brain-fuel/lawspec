package codecs

import "fmt"

func ToParcel[A, B any](value Parcel[A], convert func(A) B) (NativeParcel[B], error) {
	item := convert(value.Item)
	return NativeParcel[B]{&item}, nil
}
func FromParcel[A, B any](value NativeParcel[B], convert func(B) A) (Parcel[A], error) {
	return Parcel[A]{Item: convert(*value.item)}, nil
}
func ToChain[A, B any](value Chain[A], convert func(A) B) (NativeFlatChain[B], error) {
	items := []B{}
	for {
		switch part := value.(type) {
		case ChainStop[A]:
			return NativeFlatChain[B]{items, true}, nil
		case ChainMore[A]:
			items = append(items, convert(part.Item))
			if !part.Tail.present {
				return NativeFlatChain[B]{items, false}, nil
			}
			value = part.Tail.value
		default:
			return NativeFlatChain[B]{}, fmt.Errorf("unknown chain")
		}
	}
}
func FromChain[A, B any](value NativeFlatChain[B], convert func(B) A) (Chain[A], error) {
	tail := LawSpecMaybe[Chain[A]]{}
	if value.ended {
		tail = LawSpecMaybe[Chain[A]]{present: true, value: ChainStop[A]{}}
	}
	for i := len(value.items) - 1; i >= 0; i-- {
		tail = LawSpecMaybe[Chain[A]]{present: true, value: ChainMore[A]{Item: convert(value.items[i]), Tail: tail}}
	}
	if !tail.present {
		return nil, fmt.Errorf("empty chain without Stop has no logical value")
	}
	return tail.value, nil
}
func ToPositive(value Positive) (NativePositive, error) {
	return NativePositive{value.Value}, nil
}
func FromPositive(value NativePositive) (Positive, error) {
	return Positive{Value: value.value}, nil
}
