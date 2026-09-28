package total

import (
	"math/big"
	"strconv"
	"strings"
	"testing"
)

func TestNativeDefinitions(t *testing.T) {
	symbols := map[string]*LawSpecSymbol{}
	if LawSpecDefinitions.Size(symbols, nil).Sign() != 0 || LawSpecDefinitions.Forward(symbols, []int8{1, 2, 3}).Int64() != 3 {
		t.Fatal("recursive length or forward call")
	}
	if LawSpecDefinitions.SumList(symbols, []int8{127, 127}).Int64() != 254 || LawSpecDefinitions.Increment(symbols, 127).Int64() != 128 {
		t.Fatal("integer promotion")
	}
	if LawSpecDefinitions.Divisible(symbols, big.NewInt(5), big.NewInt(0)) ||
		!LawSpecDefinitions.Divisible(symbols, big.NewInt(-6), big.NewInt(3)) ||
		LawSpecDefinitions.Divisible(symbols, big.NewInt(-5), big.NewInt(3)) {
		t.Fatal("short circuit or signed remainder")
	}
	if LawSpecDefinitions.SumTree(symbols, TreeBranch{Left: TreeLeaf{Value: 127}, Right: TreeLeaf{Value: 127}}).Int64() != 254 {
		t.Fatal("recursive product")
	}
	if LawSpecDefinitions.MaybeDefault(symbols, LawSpecNothing[int8]()) != 0 || LawSpecDefinitions.MaybeDefault(symbols, LawSpecJust[int8](127)) != 127 {
		t.Fatal("algebraic absence")
	}
	raw := []uint16{0xd800, 0xdc00, 0xffff}
	copied := LawSpecDefinitions.Raw(symbols, raw)
	raw[0] = 0
	if copied[0] != 0xd800 || copied[1] != 0xdc00 || copied[2] != 0xffff {
		t.Fatal("raw units or native copy")
	}
	for _, value := range []LawSpecOptional[LawSpecNullable[int8]]{
		{}, {Present: true}, {Present: true, Value: LawSpecNullable[int8]{Present: true, Value: 127}},
	} {
		if actual := LawSpecDefinitions.Absent(symbols, value); actual != value {
			t.Fatal("collapsed absence")
		}
	}
	if LawSpecDefinitions.Symbol(symbols, LawSpecUnit{}) != LawSpecDefinitions.Symbol(symbols, LawSpecUnit{}) ||
		LawSpecDefinitions.Symbol(map[string]*LawSpecSymbol{}, LawSpecUnit{}) == LawSpecDefinitions.Symbol(map[string]*LawSpecSymbol{}, LawSpecUnit{}) {
		t.Fatal("Symbol identity")
	}
	decimal := LawSpecDefinitions.Exact(symbols, LawSpecDecimal{coefficient: big.NewInt(1), exponent: -1})
	if decimal.coefficient.Cmp(big.NewInt(3)) != 0 || decimal.exponent != -1 {
		t.Fatal("exact decimal")
	}
	if value, ok := LawSpecDefinitions.Either(symbols, LawSpecLeft[int8, bool](127)).Left(); !ok || value != 127 {
		t.Fatal("Left payload")
	}
	if value, ok := LawSpecDefinitions.Either(symbols, LawSpecRight[int8, bool](true)).Right(); !ok || !value {
		t.Fatal("Right payload")
	}
	if strconv.IntSize == profileBits {
		maximum := int(^uint(0) >> 1)
		if LawSpecDefinitions.Machine(symbols, maximum) != maximum || LawSpecDefinitions.Architecture(symbols, ArchitectureNative{Size: maximum}).(ArchitectureNative).Size != maximum {
			t.Fatal("native machine boundary")
		}
	} else {
		wantPanic(t, "example.total::machine", "machineBits", func() { LawSpecDefinitions.Machine(symbols, 1) })
		wantPanic(t, "example.total::architecture", "machineBits", func() { LawSpecDefinitions.Architecture(symbols, ArchitectureUnused{}) })
	}
	wantPanic(t, "example.total::sumTree", "", func() { LawSpecDefinitions.SumTree(symbols, nil) })
	wantPanic(t, "example.total::either", "", func() { LawSpecDefinitions.Either(symbols, LawSpecEither[int8, bool]{}) })
	wantPanic(t, "example.total::divisible", "", func() { LawSpecDefinitions.Divisible(symbols, nil, big.NewInt(1)) })
}

func wantPanic(t *testing.T, context, detail string, operation func()) {
	t.Helper()
	defer func() {
		failure := recover()
		if failure == nil {
			t.Errorf("expected rejection: %s", context)
			return
		}
		message, ok := failure.(string)
		if !ok || !strings.Contains(message, context) || !strings.Contains(message, detail) {
			t.Errorf("missing context: %v", failure)
		}
	}()
	operation()
}
