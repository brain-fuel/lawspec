// User-owned LawSpec adapters for the tables example.
package tables

import "fmt"

// ShippingCost implements shippingCost :: (Int32 -> (Int32 -> Int32)).
func ShippingCost(value0 int32, value1 int32) int32 {
	return value0*value1 + 5*value0
}

// Label implements label :: (Int32 -> Text).
func Label(value0 int32) string {
	return fmt.Sprintf("parcel %d", value0)
}
