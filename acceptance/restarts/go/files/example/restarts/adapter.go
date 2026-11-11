// User-owned LawSpec adapter: a tab's handlers, run inside an actor.
package restarts

// OpenTab makes an empty tab.
func OpenTab(value0 LawSpecValue) Tab {
	return Tab{Total: 0}
}

// Add adds the amount and replies with the new total.
func Add(value0 Tab, value1 uint8) Pair[int64, Tab] {
	after := value0.Total + int64(value1)
	return Pair[int64, Tab]{First: after, Second: Tab{Total: after}}
}

// Total replies with the total.
func Total(value0 Tab) Pair[int64, Tab] {
	return Pair[int64, Tab]{First: value0.Total, Second: value0}
}

// KeepsTotal starts the bar, adds to the tab, crashes the tab and reads its
// total through the same handle.
func KeepsTotal(value0 uint8) int64 {
	bar := StartBarSupervisor()
	defer bar.Stop()
	if _, err := bar.Tab.Add(value0); err != nil {
		panic(err)
	}
	if err := bar.Tab.Crash(); err != nil {
		panic(err)
	}
	total, err := bar.Tab.Total()
	if err != nil {
		panic(err)
	}
	return total
}
