package lawspec

import (
	"errors"
	"path/filepath"
	"reflect"
	"testing"
)

// A Canon bundle the caller names is used as given, its executable and
// presets directory, with no download. Hosts must run the Canon the caller
// supplied, not fetch another.
// ref:REQ-go-host ref:DEC-native-canon
func TestCanonToolPrefersTheBundle(t *testing.T) {
	bundle := t.TempDir()
	got, err := canonTool(bundle, "linux", "amd64", func() (string, error) { return "/cache", nil })
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"command": []string{filepath.Join(bundle, "canon")},
		"presets": filepath.Join(bundle, "presets"),
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

// Without a bundle, each supported platform names its npm package platform
// and the user cache directory for the core to download into. The host only
// names them, so the core's digest-checked download stays the one source of
// Canon.
// ref:REQ-go-host ref:DEC-native-canon
func TestCanonToolDownloadsWithoutABundle(t *testing.T) {
	cases := map[string]string{
		"darwin/arm64": "darwin-arm64",
		"darwin/amd64": "darwin-x64",
		"linux/arm64":  "linux-arm64",
		"linux/amd64":  "linux-x64",
	}
	for system, platform := range cases {
		goos, goarch := filepath.Split(system)
		got, err := canonTool("", filepath.Clean(goos), goarch, func() (string, error) { return "/home/u/.cache", nil })
		if err != nil {
			t.Fatal(err)
		}
		want := map[string]any{"download": map[string]string{"platform": platform, "cache": "/home/u/.cache/lawspec"}}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: got %v, want %v", system, got, want)
		}
	}
}

// A platform with no Canon package, or a machine with no user cache
// directory, gets no Canon tool at all, so Canon reports itself incomplete
// rather than the host running something unverified.
// ref:REQ-go-host ref:DEC-native-canon
func TestCanonToolHasNoneElsewhere(t *testing.T) {
	cache := func() (string, error) { return "/c", nil }
	if got, _ := canonTool("", "windows", "amd64", cache); got != nil {
		t.Errorf("windows/amd64: got %v, want none", got)
	}
	if got, _ := canonTool("", "linux", "amd64", func() (string, error) { return "", errors.New("no home") }); got != nil {
		t.Errorf("no cache directory: got %v, want none", got)
	}
}
