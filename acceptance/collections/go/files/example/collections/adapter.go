// User-owned LawSpec adapter.
package collections

import (
	"math/big"
	"slices"
)

// Dedupe returns the distinct values; a Set is a slice in any order.
func Dedupe(value0 []int32) []int32 {
	distinct := slices.Clone(value0)
	slices.Sort(distinct)
	return slices.Compact(distinct)
}

// WordCounts counts each word; a KeyVal is a slice of entries.
func WordCounts(value0 []string) []Entry[string, *LawSpecBigInt] {
	counts := map[string]*big.Int{}
	for _, word := range value0 {
		if counts[word] == nil {
			counts[word] = big.NewInt(0)
		}
		counts[word].Add(counts[word], big.NewInt(1))
	}
	entries := []Entry[string, *LawSpecBigInt]{}
	for word, count := range counts {
		entries = append(entries, Entry[string, *LawSpecBigInt]{Key: word, Value: count})
	}
	return entries
}

// Fifo keeps the values in order, front first.
func Fifo(value0 []int8) []int8 {
	return slices.Clone(value0)
}

// Lifo pushes the values in order: a Stack's top is its last item.
func Lifo(value0 []int8) []int8 {
	return slices.Clone(value0)
}

// Rotate moves the front item to the back.
func Rotate(value0 []int8) []int8 {
	if len(value0) == 0 {
		return value0
	}
	return append(slices.Clone(value0[1:]), value0[0])
}

// DistinctRows returns the distinct rows.
func DistinctRows(value0 [][]int8) [][]int8 {
	distinct := [][]int8{}
	for _, row := range value0 {
		if !slices.ContainsFunc(distinct, func(seen []int8) bool { return slices.Equal(seen, row) }) {
			distinct = append(distinct, row)
		}
	}
	return distinct
}
