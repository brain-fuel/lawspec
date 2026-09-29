// User-owned LawSpec adapter.
package indexed

import "math/big"

// Replicate returns value0 copies of value1.
func Replicate(value0 *LawSpecBigInt, value1 int8) Vec[int8] {
	var result Vec[int8] = VecVNil[int8]{}
	for i := new(big.Int); i.Cmp(value0) < 0; i.Add(i, big.NewInt(1)) {
		result = VecVCons[int8]{Head: value1, Tail: result}
	}
	return result
}

// Append concatenates two vectors.
func Append(value0 Vec[int8], value1 Vec[int8]) Vec[int8] {
	cons, ok := value0.(VecVCons[int8])
	if !ok {
		return value1
	}
	return VecVCons[int8]{Head: cons.Head, Tail: Append(cons.Tail, value1)}
}

// Zip keeps the second vector's elements in pairs with the first.
func Zip(value0 Vec[int8], value1 Vec[bool]) Vec[bool] {
	a, ok := value0.(VecVCons[int8])
	b, ok2 := value1.(VecVCons[bool])
	if !ok || !ok2 {
		return VecVNil[bool]{}
	}
	return VecVCons[bool]{Head: b.Head, Tail: Zip(a.Tail, b.Tail)}
}

// Flatten lists the values of a tree in order.
func Flatten(value0 Tree[int8]) Vec[int8] {
	node, ok := value0.(TreeBin[int8])
	if !ok {
		return VecVNil[int8]{}
	}
	right := VecVCons[int8]{Head: node.Value, Tail: Flatten(node.Right)}
	return Append(Flatten(node.Left), right)
}
