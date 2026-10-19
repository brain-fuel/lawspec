// User-owned LawSpec adapter.
package arithmetic

import "math/big"

func length(row Row) int64 {
	count := int64(0)
	for {
		cell, ok := row.(RowCell)
		if !ok {
			return count
		}
		count++
		row = cell.Value.Tail
	}
}

// Mirror swaps the subtrees of every node.
func Mirror(value0 Perfect) Perfect {
	if node, ok := value0.(PerfectNode); ok {
		return PerfectNode{Value: Recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8{Left: Mirror(node.Value.Right), Right: Mirror(node.Value.Left)}}
	}
	return value0
}

// Area counts the cells of a grid.
func Area(value0 Grid) *LawSpecBigInt {
	return big.NewInt(length(value0.Value.Rows) * length(value0.Value.Columns))
}

// Duplicate uses a row as both halves.
func Duplicate(value0 Row) Halves {
	return Halves{Value: Record90e2e86ad982c9c5e71a6cd286ab605cf2b3d771c37021fb930810c33933eb3d{Back: value0, Front: value0}}
}

// CountPairs groups a row into pairs.
func CountPairs(value0 Row) Pairs {
	return Pairs{Value: value0}
}

// DropFirst keeps a row without its first element.
func DropFirst(value0 Row) Rest {
	return Rest{Value: value0}
}
