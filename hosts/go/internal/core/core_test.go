package core

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// tarball is an npm package tarball holding the given files.
func tarball(t *testing.T, files map[string][]byte) []byte {
	t.Helper()
	var buffer bytes.Buffer
	zipped := gzip.NewWriter(&buffer)
	archive := tar.NewWriter(zipped)
	for name, content := range files {
		header := &tar.Header{Name: name, Mode: 0o644, Size: int64(len(content)), Typeflag: tar.TypeReg}
		if err := archive.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if _, err := archive.Write(content); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	if err := zipped.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

// registry serves one tarball at the core package's path for version 9.9.9
// over TLS, and counts the requests.
func registry(t *testing.T, body []byte) (*httptest.Server, *int) {
	t.Helper()
	requests := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.URL.Path != "/@goforgedev/core/-/core-9.9.9.tgz" {
			http.NotFound(w, r)
			return
		}
		w.Write(body)
	}))
	t.Cleanup(server.Close)
	return server, &requests
}

// The core is downloaded once from the HTTPS registry, unpacked from its
// package, checked against the pinned SHA-256 and kept in the user cache; a
// second load reads the cache without another request. Every run then gets
// the same bytes without a network.
// ref:REQ-go-host ref:DEC-go-core-download
func TestLoadDownloadsVerifiesAndCaches(t *testing.T) {
	wasm := []byte("\x00asm a core")
	server, requests := registry(t, tarball(t, map[string][]byte{
		"package/package.json":   []byte("{}"),
		"package/host-core.wasm": wasm,
	}))
	source := Source{Cache: t.TempDir(), Registry: server.URL + "/", Client: server.Client()}
	for range 2 {
		got, err := load(context.Background(), source, "9.9.9", digest(wasm))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, wasm) {
			t.Fatalf("load returned %q", got)
		}
	}
	if *requests != 1 {
		t.Fatalf("%d downloads; the second load should use the cache", *requests)
	}
	kept, err := os.ReadFile(Path(source.Cache, "9.9.9"))
	if err != nil || !bytes.Equal(kept, wasm) {
		t.Fatalf("cache holds %q (%v)", kept, err)
	}
}

// A downloaded core whose SHA-256 is not the pinned one is refused and
// nothing is kept, so a tampered or substituted package never runs and never
// reaches the cache.
// ref:REQ-go-host ref:DEC-go-core-download
func TestLoadRefusesAMismatchAndKeepsNothing(t *testing.T) {
	server, _ := registry(t, tarball(t, map[string][]byte{"package/host-core.wasm": []byte("tampered")}))
	source := Source{Cache: t.TempDir(), Registry: server.URL, Client: server.Client()}
	_, err := load(context.Background(), source, "9.9.9", digest([]byte("the real core")))
	if err == nil || !strings.Contains(err.Error(), "SHA-256 mismatch") {
		t.Fatalf("expected a SHA-256 mismatch, got %v", err)
	}
	if _, err := os.Stat(Path(source.Cache, "9.9.9")); !os.IsNotExist(err) {
		t.Fatalf("a mismatched core was kept: %v", err)
	}
}

// A cached core is re-hashed on every start, and one that no longer matches
// the pin is downloaded again and replaced, so a damaged cache cannot run.
// ref:REQ-go-host ref:DEC-go-core-download
func TestLoadReplacesADamagedCacheEntry(t *testing.T) {
	wasm := []byte("\x00asm the core")
	server, requests := registry(t, tarball(t, map[string][]byte{"package/host-core.wasm": wasm}))
	source := Source{Cache: t.TempDir(), Registry: server.URL, Client: server.Client()}
	if err := keep(Path(source.Cache, "9.9.9"), []byte("damaged")); err != nil {
		t.Fatal(err)
	}
	got, err := load(context.Background(), source, "9.9.9", digest(wasm))
	if err != nil || !bytes.Equal(got, wasm) || *requests != 1 {
		t.Fatalf("got %q, %v after %d downloads", got, err, *requests)
	}
}

// A package without package/host-core.wasm is an error, since the host reads
// only that file from the tarball and runs nothing else from it.
// ref:REQ-go-host ref:DEC-go-core-download
func TestLoadNeedsTheCoreInThePackage(t *testing.T) {
	server, _ := registry(t, tarball(t, map[string][]byte{"package/other.wasm": []byte("x")}))
	source := Source{Cache: t.TempDir(), Registry: server.URL, Client: server.Client()}
	_, err := load(context.Background(), source, "9.9.9", digest([]byte("x")))
	if err == nil || !strings.Contains(err.Error(), "holds no package/host-core.wasm") {
		t.Fatalf("expected a missing core, got %v", err)
	}
}

// A registry URL that is not HTTPS is refused before any request, so the
// core is never fetched over an unauthenticated channel.
// ref:REQ-go-host ref:DEC-go-core-download
func TestLoadRefusesAPlainHTTPRegistry(t *testing.T) {
	source := Source{Cache: t.TempDir(), Registry: "http://registry.example"}
	_, err := load(context.Background(), source, "9.9.9", "")
	if err == nil || !strings.Contains(err.Error(), "must be an https URL") {
		t.Fatalf("expected an https refusal, got %v", err)
	}
}

// A registry that does not have the release answers 404, and the error says
// so and names LAWSPEC_HOST_CORE, the way to run a core built from source.
// ref:REQ-go-host ref:DEC-go-core-download
func TestLoadReportsAMissingPackage(t *testing.T) {
	server, _ := registry(t, nil)
	source := Source{Cache: t.TempDir(), Registry: server.URL, Client: server.Client()}
	_, err := load(context.Background(), source, "1.0.0", "")
	if err == nil || !strings.Contains(err.Error(), "404") || !strings.Contains(err.Error(), "LAWSPEC_HOST_CORE") {
		t.Fatalf("expected a 404 naming LAWSPEC_HOST_CORE, got %v", err)
	}
}

// The pin records a release version and a 64-digit SHA-256, so a build that
// lost its pin fails here rather than running an unchecked core.
// ref:REQ-go-host ref:DEC-go-core-download
func TestPinIsAReleaseAndADigest(t *testing.T) {
	if Version == "" || len(SHA256) != 64 {
		t.Fatalf("pin.go records version %q and digest %q", Version, SHA256)
	}
}
