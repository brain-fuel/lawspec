// Finite covers preserve the planner's ordered observations, using fresh
// values on each attempt. ref:DEC-planned-generation
package RUNTIME_PACKAGE

import (
	"math/big"
	"reflect"
	"testing"
)

func TestFiniteCases(t *testing.T) {
	complete := &lsFiniteCover{Copies: 1}
	interval := func(kind, first, last string, suffix *lsFiniteCover) *lsFiniteCover {
		return &lsFiniteCover{Branches: []lsFiniteBranch{{
			Domain: lsFiniteDomain{Type: kind, First: first, Last: last}, Suffix: suffix,
		}}}
	}
	decode := func(cover *lsFiniteCover) [][]string {
		rows := [][]string{}
		lsFiniteCases(cover, func(index int, values []lsFiniteValue) bool {
			if index != len(rows) {
				t.Fatalf("case index %d, wanted %d", index, len(rows))
			}
			row := []string{}
			for _, value := range values {
				row = append(row, value(nil).Data.(*big.Int).String())
			}
			rows = append(rows, row)
			return true
		})
		return rows
	}
	if got := decode(&lsFiniteCover{}); len(got) != 0 {
		t.Fatal(got)
	}
	if got := decode(&lsFiniteCover{Copies: 2}); !reflect.DeepEqual(got, [][]string{{}, {}}) {
		t.Fatal(got)
	}
	product := interval("Int8", "-1", "1", interval("UInt8", "254", "255", complete))
	wanted := [][]string{{"-1", "254"}, {"-1", "255"}, {"0", "254"}, {"0", "255"}, {"1", "254"}, {"1", "255"}}
	if got := decode(product); !reflect.DeepEqual(got, wanted) {
		t.Fatalf("ordered product: %v", got)
	}
	dependent := &lsFiniteCover{Branches: []lsFiniteBranch{
		{Domain: lsFiniteDomain{Type: "Integer", First: "0", Last: "0"}, Suffix: interval("Integer", "0", "0", complete)},
		{Domain: lsFiniteDomain{Type: "Integer", First: "1", Last: "1"}, Suffix: interval("Integer", "0", "1", complete)},
		{Domain: lsFiniteDomain{Type: "Integer", First: "0", Last: "0"}, Suffix: interval("Integer", "0", "0", complete)},
	}}
	if got := decode(dependent); !reflect.DeepEqual(got, [][]string{{"0", "0"}, {"1", "0"}, {"1", "1"}, {"0", "0"}}) {
		t.Fatalf("dependent prefixes and duplicates: %v", got)
	}
	maximum := "18446744073709551615"
	if got := decode(interval("UInt64", maximum, maximum, complete)); !reflect.DeepEqual(got, [][]string{{maximum}}) {
		t.Fatal(got)
	}
	visited := 0
	lsFiniteCases(interval("Integer", "0", "10000000000000000000000000000000000000000", complete),
		func(index int, values []lsFiniteValue) bool {
			visited++
			if values[0](nil).Data.(*big.Int).Int64() != int64(index) {
				t.Fatal(index)
			}
			return visited < 2
		})
	if visited != 2 {
		t.Fatal("traversal ignored early stop")
	}
	var captured []lsFiniteValue
	lsFiniteCases(interval("Integer", "3", "4", complete), func(_ int, values []lsFiniteValue) bool {
		captured = append(captured, values[0])
		return true
	})
	first := captured[0](nil).Data.(*big.Int)
	first.SetInt64(99)
	if captured[0](nil).Data.(*big.Int).Int64() != 3 || captured[1](nil).Data.(*big.Int).Int64() != 4 {
		t.Fatal("range values or factories share mutable state")
	}
	symbol := func(scope map[string]*lawSpecSymbol) LawSpecValue { return lsSymbol("shared", "value", scope) }
	scope := map[string]*lawSpecSymbol{}
	if symbol(scope).Data != symbol(scope).Data || symbol(scope).Data == symbol(map[string]*lawSpecSymbol{}).Data {
		t.Fatal("symbols must share exactly their attempt's scope")
	}
}
