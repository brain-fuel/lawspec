package fixture

import "testing"

func TestNativeData(t *testing.T) {
	var tree Tree[int8] = TreeBranch[int8]{Children: []Tree[int8]{
		TreeLeaf[int8]{Value: 127}, TreeBranch[int8]{Children: nil},
	}}
	branch, ok := tree.(TreeBranch[int8])
	if !ok || branch.Children[0].(TreeLeaf[int8]).Value != 127 {
		t.Fatal("native recursive tree lost its payload")
	}
	var pair Pair[string] = PairPair[string]{First: "🙂", Second: ^uint64(0)}
	payload := pair.(PairPair[string])
	if payload.First != "🙂" || payload.Second != 18446744073709551615 {
		t.Fatal("native fields lost precision or Unicode")
	}
	var phantom Phantom[bool] = PhantomTag[bool]{}
	if _, ok := phantom.(PhantomTag[bool]); !ok {
		t.Fatal("phantom parameter lost")
	}
	var chain Chain = ChainNext{Next: LawSpecJust[Chain](ChainStop{})}
	next, ok := chain.(ChainNext).Next.Value()
	if !ok {
		t.Fatal("recursive Maybe lost its constructor")
	}
	if _, ok := next.(ChainStop); !ok {
		t.Fatal("recursive Maybe lost its payload")
	}
	var mutual LeftSide = LeftSideAcross{Right: RightSideBack{
		Left: LawSpecNothing[LeftSide](),
	}}
	if _, ok := mutual.(LeftSideAcross).Right.(RightSideBack).Left.Value(); ok {
		t.Fatal("mutual recursion lost absence")
	}
	var states Presence = PresenceStates{
		Nested: LawSpecNullable[LawSpecOptional[int8]]{
			Present: true, Value: LawSpecOptional[int8]{Present: false},
		},
	}
	nested := states.(PresenceStates).Nested
	if !nested.Present || nested.Value.Present {
		t.Fatal("nested presence collapsed")
	}
}
