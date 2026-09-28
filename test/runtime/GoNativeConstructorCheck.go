package fields

import (
	"fmt"
	"strconv"
	"strings"
	"testing"
)

func rejected(t *testing.T, action func()) {
	t.Helper()
	defer func() {
		problem := recover()
		if _, ok := problem.(lawSpecRefinementViolation); !ok ||
			strings.Contains(fmt.Sprint(problem), "division by zero") {
			t.Fatalf("expected contract rejection, got %T: %v", problem, problem)
		}
	}()
	action()
}

func TestNativeConstructorContracts(t *testing.T) {
	symbols := map[string]*LawSpecSymbol{}
	result := LawSpecDefinitions.InverseGap(symbols, GapGap{First: -128, Second: 127})
	if result.RatString() != "1/255" {
		t.Fatalf("lost promoted arithmetic: %s", result)
	}
	rejected(t, func() { LawSpecDefinitions.InverseGap(symbols, GapGap{First: 0, Second: 0}) })
	rejected(t, func() { LawSpecDefinitions.InverseGap(symbols, GapGap{First: 127, Second: -128}) })
	LawSpecDefinitions.EchoBucket(symbols, BucketBucket[int8]{Values: []int8{1}})
	rejected(t, func() { LawSpecDefinitions.EchoBucket(symbols, BucketBucket[int8]{}) })
	LawSpecDefinitions.EchoPositives(symbols, PositivesPositives{Values: []int8{1, 127}})
	rejected(t, func() { LawSpecDefinitions.EchoPositives(symbols, PositivesPositives{Values: []int8{1, 0}}) })
	LawSpecDefinitions.EchoChoice(symbols, ChoiceAccepted{Value: 1})
	LawSpecDefinitions.EchoChoice(symbols, ChoiceRejected{Reason: "no"})
	rejected(t, func() { LawSpecDefinitions.EchoChoice(symbols, ChoiceAccepted{Value: 0}) })
	LawSpecDefinitions.EchoGuarded(symbols, GuardedGuarded{Value: 2})
	rejected(t, func() { LawSpecDefinitions.EchoGuarded(symbols, GuardedGuarded{Value: 0}) })
	rejected(t, func() { LawSpecDefinitions.EchoGuarded(symbols, GuardedGuarded{Value: -1}) })
	identity := lsSymbol("fixture", "same", symbols).Data.(*LawSpecSymbol)
	var box Identity = IdentityIdentity{Value: identity}
	if LawSpecDefinitions.EchoIdentity(symbols, box).(IdentityIdentity).Value != identity {
		t.Fatal("lost symbol identity")
	}
	rejected(t, func() { LawSpecDefinitions.EchoIdentity(map[string]*LawSpecSymbol{}, box) })
	rejected(t, func() { LawSpecDefinitions.EchoIdentity(symbols, IdentityIdentity{Value: &LawSpecSymbol{"same"}}) })
	list := []LawSpecMaybe[Identity]{LawSpecNothing[Identity](), LawSpecJust(box)}
	if len(LawSpecDefinitions.EchoList(symbols, list)) != 2 {
		t.Fatal("lost nested list")
	}
	LawSpecDefinitions.EchoIdentityBucket(symbols, BucketBucket[Identity]{Values: []Identity{box}})
	rejected(t, func() {
		LawSpecDefinitions.EchoIdentityBucket(symbols, BucketBucket[Identity]{
			Values: []Identity{IdentityIdentity{Value: &LawSpecSymbol{"same"}}},
		})
	})
	LawSpecDefinitions.EchoPresent(symbols, PresentPresent[Identity]{Item: LawSpecJust(box)})
	rejected(t, func() {
		LawSpecDefinitions.EchoPresent(symbols, PresentPresent[Identity]{Item: LawSpecNothing[Identity]()})
	})
	for _, value := range []LawSpecOptional[LawSpecNullable[Identity]]{
		{}, {Present: true}, {Present: true, Value: LawSpecNullable[Identity]{Present: true, Value: box}},
	} {
		actual := LawSpecDefinitions.EchoNested(symbols, value)
		if actual.Present != value.Present || actual.Value.Present != value.Value.Present {
			t.Fatal("collapsed presence states")
		}
	}
	if profileBits == strconv.IntSize {
		LawSpecDefinitions.EchoMachine(symbols, MachineMachine{Value: 1})
		rejected(t, func() { LawSpecDefinitions.EchoMachine(symbols, MachineMachine{Value: 0}) })
	} else {
		func() {
			defer func() {
				if p := recover(); p == nil || !strings.Contains(fmt.Sprint(p), "machine") {
					t.Fatalf("expected architecture mismatch, got %v", p)
				}
			}()
			LawSpecDefinitions.EchoMachine(symbols, MachineMachine{Value: 1})
		}()
	}
}
