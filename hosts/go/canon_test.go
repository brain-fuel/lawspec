package lawspec

import (
	"errors"
	"path/filepath"
	"reflect"
	"testing"
)

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

func TestCanonToolHasNoneElsewhere(t *testing.T) {
	cache := func() (string, error) { return "/c", nil }
	if got, _ := canonTool("", "windows", "amd64", cache); got != nil {
		t.Errorf("windows/amd64: got %v, want none", got)
	}
	if got, _ := canonTool("", "linux", "amd64", func() (string, error) { return "", errors.New("no home") }); got != nil {
		t.Errorf("no cache directory: got %v, want none", got)
	}
}
