// User-owned LawSpec adapter.
package indexed

import "math/big"

// Replicate returns value0 copies of value1.
func Replicate(value0 *LawSpecBigInt, value1 int8) Vec[int8] {
	var result Vec[int8] = VecVNil[int8]{}
	for i := new(big.Int); i.Cmp(value0) < 0; i.Add(i, big.NewInt(1)) {
		result = VecVCons[int8]{Value: Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec[int8]{Head: value1, Tail: result}}
	}
	return result
}

// Append concatenates two vectors.
func Append(value0 Vec[int8], value1 Vec[int8]) Vec[int8] {
	cons, ok := value0.(VecVCons[int8])
	if !ok {
		return value1
	}
	return VecVCons[int8]{Value: Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec[int8]{Head: cons.Value.Head, Tail: Append(cons.Value.Tail, value1)}}
}

// Zip keeps the second vector's elements in pairs with the first.
func Zip(value0 Vec[int8], value1 Vec[bool]) Vec[bool] {
	a, ok := value0.(VecVCons[int8])
	b, ok2 := value1.(VecVCons[bool])
	if !ok || !ok2 {
		return VecVNil[bool]{}
	}
	return VecVCons[bool]{Value: Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec[bool]{Head: b.Value.Head, Tail: Zip(a.Value.Tail, b.Value.Tail)}}
}

// Flatten lists the values of a tree in order.
func Flatten(value0 Tree[int8]) Vec[int8] {
	node, ok := value0.(TreeBin[int8])
	if !ok {
		return VecVNil[int8]{}
	}
	right := VecVCons[int8]{Value: Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec[int8]{Head: node.Value.Value, Tail: Flatten(node.Value.Right)}}
	return Append(Flatten(node.Value.Left), right)
}
