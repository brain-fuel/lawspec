// The harness plane at run time (see docs/reference/language/harness.md):
// how a law's tests run, never what the law means. Generated tests call it
// for strategies (frequency, one of, such that), adequacy (cover, classify,
// label), run metadata (skip, known failing, timeout, repeat, retry flaky)
// and benchmarks.
//
// A test the harness runs is a function of rapid.TB, so it can run under a
// recorder: a failure stops it (FailNow panics) and is reported once the
// harness has decided, for instance after a retry. Statistics go to the
// test log, and, when LAWSPEC_STATS names a directory, to one JSON file per
// test there, which lawspec test reads.
package RUNTIME_PACKAGE

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"pgregory.net/rapid"
)

type lsHarnessFailure struct{ message string }

func (f lsHarnessFailure) Error() string { return f.message }

func lsHarnessRecord(name string, entry map[string]any) {
	directory := os.Getenv("LAWSPEC_STATS")
	if directory == "" {
		return
	}
	_ = os.MkdirAll(directory, 0o755)
	safe := strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' {
			return r
		}
		return '_'
	}, name)
	if bytes, err := json.Marshal(entry); err == nil {
		_ = os.WriteFile(filepath.Join(directory, safe+".json"), bytes, 0o644)
	}
}

// Strategies, drawn through rapid so failures shrink.

type lsHarnessWeighted struct {
	weight int
	draw   func() LawSpecValue
}

// A choice among n: a wide draw, reduced, so the weights hold.
func lsHarnessChoose(t *rapid.T, n int) int {
	return int(rapid.Uint32().Draw(t, "choice") % uint32(n))
}

func lsHarnessFrequency(t *rapid.T, alternatives []lsHarnessWeighted) LawSpecValue {
	total := 0
	for _, a := range alternatives {
		total += a.weight
	}
	pick := lsHarnessChoose(t, total)
	for _, a := range alternatives {
		if pick < a.weight {
			return a.draw()
		}
		pick -= a.weight
	}
	return alternatives[len(alternatives)-1].draw()
}

func lsHarnessOneOf(t *rapid.T, values []func() LawSpecValue) LawSpecValue {
	return values[lsHarnessChoose(t, len(values))]()
}

func lsHarnessSuchThat(draw func() LawSpecValue, predicate func(LawSpecValue) bool, limit int, strategy string) LawSpecValue {
	for i := 0; i <= limit; i++ {
		if value := draw(); predicate(value) {
			return value
		}
	}
	panic(lsHarnessFailure{fmt.Sprintf("the strategy %s discarded more than %d values; draw closer to what `such that` keeps, or allow more discards", strategy, limit)})
}

// A drawn value must satisfy its input's refinements: a strategy may only
// produce values the law is about.
func lsHarnessCheckDrawn(strategy, name string, holds func(LawSpecValue) bool, value LawSpecValue) LawSpecValue {
	if !holds(value) {
		panic(lsHarnessFailure{fmt.Sprintf("the strategy %s produced %v for %s, which is outside the input's refinement; a strategy may only produce values of its type", strategy, value.Data, name)})
	}
	return value
}

// Adequacy: what the generated cases covered.

type lsHarnessStats struct {
	cases   int
	cover   map[string]int
	classes map[string]int
	labels  map[string]int
	best    *float64
}

var lsHarnessCases = struct {
	sync.Mutex
	laws map[string]*lsHarnessStats
}{laws: map[string]*lsHarnessStats{}}

type lsHarnessPair struct {
	label string
	holds bool
}

type lsHarnessCover struct {
	percent int
	label   string
}

func lsHarnessStatsOf(law string) *lsHarnessStats {
	stats, ok := lsHarnessCases.laws[law]
	if !ok {
		stats = &lsHarnessStats{cover: map[string]int{}, classes: map[string]int{}, labels: map[string]int{}}
		lsHarnessCases.laws[law] = stats
	}
	return stats
}

func lsHarnessObserve(law string, covers, classes []lsHarnessPair, labels []LawSpecValue) {
	lsHarnessCases.Lock()
	defer lsHarnessCases.Unlock()
	stats := lsHarnessStatsOf(law)
	stats.cases++
	for _, c := range covers {
		if c.holds {
			stats.cover[c.label]++
		}
	}
	for _, c := range classes {
		if c.holds {
			stats.classes[c.label]++
		}
	}
	for _, l := range labels {
		stats.labels[fmt.Sprint(lsToNative("Text", l, 64))]++
	}
}

// target maximize: rapid has no targeted search, so the best score is
// reported with the law's statistics.
func lsHarnessTarget(score LawSpecValue, law string) {
	value := lsHarnessNumber(score)
	lsHarnessCases.Lock()
	defer lsHarnessCases.Unlock()
	stats := lsHarnessStatsOf(law)
	if stats.best == nil || value > *stats.best {
		stats.best = &value
	}
}

func lsHarnessNumber(v LawSpecValue) float64 {
	switch x := v.Data.(type) {
	case float64:
		return x
	case float32:
		return float64(x)
	default:
		var f float64
		if _, err := fmt.Sscan(fmt.Sprint(x), &f); err == nil {
			return f
		}
		return math.NaN()
	}
}

func lsHarnessAdequacy(t testing.TB, law string, covers []lsHarnessCover) map[string]any {
	lsHarnessCases.Lock()
	stats := lsHarnessStatsOf(law)
	delete(lsHarnessCases.laws, law)
	lsHarnessCases.Unlock()
	results := []map[string]any{}
	lines := []string{fmt.Sprintf("%s: %d generated case(s)", law, stats.cases)}
	for _, c := range covers {
		observed := 0.0
		if stats.cases > 0 {
			observed = math.Round(10000*float64(stats.cover[c.label])/float64(stats.cases)) / 100
		}
		met := stats.cases > 0 && observed >= float64(c.percent)
		results = append(results, map[string]any{"label": c.label, "required": c.percent, "observed": observed, "met": met})
		suffix := ""
		if !met {
			suffix = " (not met)"
		}
		lines = append(lines, fmt.Sprintf("  cover %d%% %q: %v%%%s", c.percent, c.label, observed, suffix))
	}
	for i, table := range []map[string]int{stats.classes, stats.labels} {
		keys := make([]string, 0, len(table))
		for k := range table {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			prefix := ""
			if i == 1 {
				prefix = "label "
			}
			lines = append(lines, fmt.Sprintf("  %s%s: %.1f%%", prefix, k, 100*float64(table[k])/math.Max(1, float64(stats.cases))))
		}
	}
	report := map[string]any{"law": law, "cases": stats.cases, "cover": results, "classes": stats.classes, "labels": stats.labels}
	if stats.best != nil {
		report["best"] = *stats.best
		lines = append(lines, fmt.Sprintf("  best target score: %v", *stats.best))
	}
	t.Log(strings.Join(lines, "\n"))
	return report
}

// A recorder for one run of a test: rapid.TB, whose failures stop the run.
type lsHarnessT struct {
	name     string
	failed   bool
	messages []string
}

type lsHarnessStop struct{}

func (r *lsHarnessT) Helper()                         {}
func (r *lsHarnessT) Name() string                    { return r.name }
func (r *lsHarnessT) Logf(format string, args ...any) { r.messages = append(r.messages, fmt.Sprintf(format, args...)) }
func (r *lsHarnessT) Log(args ...any)                 { r.messages = append(r.messages, fmt.Sprint(args...)) }
func (r *lsHarnessT) Skipf(format string, args ...any) { r.Logf(format, args...); panic(lsHarnessStop{}) }
func (r *lsHarnessT) Skip(args ...any)                { r.Log(args...); panic(lsHarnessStop{}) }
func (r *lsHarnessT) SkipNow()                        { panic(lsHarnessStop{}) }
func (r *lsHarnessT) Errorf(format string, args ...any) {
	r.failed = true
	r.Logf(format, args...)
}
func (r *lsHarnessT) Error(args ...any) { r.failed = true; r.Log(args...) }
func (r *lsHarnessT) Fatalf(format string, args ...any) {
	r.Errorf(format, args...)
	panic(lsHarnessStop{})
}
func (r *lsHarnessT) Fatal(args ...any) { r.Error(args...); panic(lsHarnessStop{}) }
func (r *lsHarnessT) FailNow()          { r.failed = true; panic(lsHarnessStop{}) }
func (r *lsHarnessT) Fail()             { r.failed = true }
func (r *lsHarnessT) Failed() bool      { return r.failed }

// One run of a test under a recorder, within a timeout (0: none). It gives
// the failure, if any, and whether the harness itself failed.
func lsHarnessOnce(name string, timeout int, test func(rapid.TB)) (string, bool) {
	recorder := &lsHarnessT{name: name}
	type outcome struct {
		message string
		harness bool
	}
	done := make(chan outcome, 1)
	go func() {
		defer func() {
			if err := recover(); err != nil {
				if failure, ok := err.(lsHarnessFailure); ok {
					done <- outcome{failure.message, true}
					return
				}
				if _, ok := err.(lsHarnessStop); !ok {
					recorder.failed = true
					recorder.messages = append(recorder.messages, fmt.Sprint(err))
				}
			}
			if recorder.failed {
				done <- outcome{strings.Join(recorder.messages, "\n"), lsHarnessHarnessMessage(recorder.messages)}
			} else {
				done <- outcome{"", false}
			}
		}()
		test(recorder)
	}()
	if timeout <= 0 {
		o := <-done
		return o.message, o.harness
	}
	select {
	case o := <-done:
		return o.message, o.harness
	case <-time.After(time.Duration(timeout) * time.Millisecond):
		return fmt.Sprintf("took longer than its timeout of %d ms", timeout), true
	}
}

// rapid reports a panic in a draw as text; a harness failure stays one.
func lsHarnessHarnessMessage(messages []string) bool {
	for _, m := range messages {
		if strings.Contains(m, "outside the input's refinement") || strings.Contains(m, "discarded more than") {
			return true
		}
	}
	return false
}

// Run one generated test of a law under its harness settings.
func lsHarnessRun(t *testing.T, law, name string, timeout, repeat, retries int, covers []lsHarnessCover, observed bool, test func(rapid.TB)) {
	t.Helper()
	attempts := 0
	flaky := false
	var report map[string]any
	for {
		attempts++
		failure, harness := "", false
		for i := 0; i < repeat && failure == ""; i++ {
			lsHarnessCases.Lock()
			delete(lsHarnessCases.laws, law)
			lsHarnessCases.Unlock()
			failure, harness = lsHarnessOnce(t.Name(), timeout, test)
			if failure == "" && observed {
				report = lsHarnessAdequacy(t, law, covers)
				unmet := []string{}
				for _, r := range report["cover"].([]map[string]any) {
					if !r["met"].(bool) {
						unmet = append(unmet, fmt.Sprintf("%s: cover %d%% %q was not met (%v%% of %d generated cases)", law, r["required"], r["label"], r["observed"], report["cases"]))
					}
				}
				if len(unmet) > 0 {
					failure, harness = strings.Join(unmet, "; "), true
				}
			}
		}
		if failure == "" {
			break
		}
		if harness || attempts > retries {
			lsHarnessRecord(name, map[string]any{"law": law, "test": name, "outcome": "failed", "attempts": attempts})
			t.Fatalf("%s", failure)
			return
		}
		flaky = true
	}
	entry := map[string]any{"law": law, "test": name, "outcome": "passed", "attempts": attempts}
	if flaky {
		entry["outcome"] = "flaky"
		t.Logf("%s is flaky: it failed, then passed on attempt %d", law, attempts)
	}
	for k, v := range report {
		entry[k] = v
	}
	lsHarnessRecord(name, entry)
}

func lsHarnessSkip(t *testing.T, law, reason string) {
	lsHarnessRecord(law, map[string]any{"law": law, "outcome": "skipped", "reason": reason})
	t.Skipf("%s: %s", law, reason)
}

// A known-failing law's tests must fail. One that passes is reported: the
// harness should no longer say it is known to fail.
func lsHarnessKnownFailing(t *testing.T, law, name, reason string, tests []func(rapid.TB)) {
	for _, test := range tests {
		if failure, _ := lsHarnessOnce(t.Name(), 0, test); failure != "" {
			lsHarnessRecord(name, map[string]any{"law": law, "test": name, "outcome": "known-failing", "reason": reason})
			t.Logf("%s is known to fail (%s): %s", law, reason, strings.SplitN(failure, "\n", 2)[0])
			return
		}
	}
	lsHarnessRecord(name, map[string]any{"law": law, "test": name, "outcome": "known-failing-passed", "reason": reason})
	t.Fatalf("%s is marked known failing (%s), but it passes; remove `known failing` from its harness", law, reason)
}

// Measured, never asserted, with Go's own benchmark harness.
func lsHarnessBenchmark(t *testing.T, name string, body func()) {
	result := testing.Benchmark(func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			body()
		}
	})
	t.Logf("benchmark %s: %d iteration(s), mean %.2f us", name, result.N, float64(result.NsPerOp())/1000)
	lsHarnessRecord("benchmark "+name, map[string]any{"benchmark": name, "iterations": result.N, "mean_ns": result.NsPerOp()})
}

// lsHarnessShuffle is order random: go test runs the package's tests in an
// order -test.shuffle chooses, here the run's seed (LAWSPEC_SEED), or the
// clock. A -test.shuffle given on the command line wins.
func lsHarnessShuffle() {
	if !flag.Parsed() {
		flag.Parse()
	}
	if f := flag.Lookup("test.shuffle"); f != nil && f.Value.String() == "off" {
		seed := os.Getenv("LAWSPEC_SEED")
		if seed == "" {
			seed = fmt.Sprint(time.Now().UnixNano() % 2147483647)
		}
		_ = flag.Set("test.shuffle", seed)
		fmt.Printf("order random seed %s: LAWSPEC_SEED=%s replays this order\n", seed, seed)
	}
}

// lsHarnessParallelism records how a parallel unit's tests run: each calls
// t.Parallel, so go test runs them on goroutines across GOMAXPROCS threads.
func lsHarnessParallelism(unit string) {
	workers := runtime.GOMAXPROCS(0)
	mode := "goroutines (t.Parallel)"
	lsHarnessRecord("parallel "+unit, map[string]any{"parallel": unit, "mode": mode, "workers": workers})
	fmt.Printf("%s runs in parallel: %s, %d worker(s)\n", unit, mode, workers)
}
