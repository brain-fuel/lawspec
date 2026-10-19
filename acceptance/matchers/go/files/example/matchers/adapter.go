// User-owned LawSpec adapters for the matchers example.
package matchers

import (
	"regexp"
	"sort"
	"strings"
)

// SortItems implements sortItems :: (List (Int32) -> List (Int32)).
func SortItems(value0 []int32) []int32 {
	items := append([]int32(nil), value0...)
	sort.Slice(items, func(i, j int) bool { return items[i] < items[j] })
	return items
}

// UniqueTags implements uniqueTags :: (List (Text) -> List (Text)).
func UniqueTags(value0 []string) []string {
	seen := map[string]bool{}
	tags := []string{}
	for _, tag := range value0 {
		if !seen[tag] {
			seen[tag] = true
			tags = append(tags, tag)
		}
	}
	return tags
}

// Average implements average :: (Int32 -> (Int32 -> Float64)).
func Average(value0 int32, value1 int32) float64 {
	return (float64(value0) + float64(value1)) / 2
}

var words = regexp.MustCompile(`[a-z0-9]+`)

// Slug implements slug :: (Text -> Text).
func Slug(value0 string) string {
	return strings.Join(words.FindAllString(strings.ToLower(value0), -1), "-")
}

// Ship implements ship :: (Int32 -> example.matchers::type::Order).
func Ship(value0 int32) Order {
	return OrderShipped{Value: Recordaaeb2c3925832586ac7d5e3c9a9cd234d3a26f7d9d0e264664a4ae58c6f71911{Carrier: "post", Id: value0}}
}
