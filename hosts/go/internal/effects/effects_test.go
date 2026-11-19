package effects

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// call performs one request and decodes the reply.
func call(t *testing.T, e *Effects, request map[string]any) map[string]any {
	t.Helper()
	return callUnder(t, e, open(), request)
}

// open grants everything the tests touch: every path may be read, none
// written (the guard refuses a write root of /).
func open() map[string]any {
	return map[string]any{"read": []string{"/"}, "write": []string{}, "programs": []string{}, "network": true, "listen": true}
}

func callUnder(t *testing.T, e *Effects, policy map[string]any, request map[string]any) map[string]any {
	t.Helper()
	request["abi"] = ABI
	request["policy"] = policy
	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	var reply map[string]any
	if err := json.Unmarshal(e.Perform(encoded), &reply); err != nil {
		t.Fatal(err)
	}
	return reply
}

func ok(t *testing.T, reply map[string]any) map[string]any {
	t.Helper()
	result, found := reply["ok"].(map[string]any)
	if !found {
		t.Fatalf("expected ok, got %v", reply)
	}
	return result
}

func errorKind(reply map[string]any) string {
	failure, _ := reply["error"].(map[string]any)
	kind, _ := failure["kind"].(string)
	return kind
}

func text(s string) string {
	return base64.StdEncoding.EncodeToString([]byte(s))
}

func TestEnvelopeErrors(t *testing.T) {
	e := New(Options{})
	defer e.Close()
	if kind := errorKind(call(t, e, map[string]any{"op": "teleport"})); kind != "unsupported" {
		t.Errorf("unknown operation: got %q", kind)
	}
	var reply map[string]any
	json.Unmarshal(e.Perform([]byte(`{"abi":1,"op":"clock","policy":{"read":[],"write":[],"programs":[],"network":false,"listen":false}}`)), &reply)
	if kind := errorKind(reply); kind != "invalid" {
		t.Errorf("ABI 1: got %q", kind)
	}
	json.Unmarshal(e.Perform([]byte(`{"abi":2,"op":"clock","policy":{"read":[],"write":[],"programs":[],"network":false}}`)), &reply)
	if kind := errorKind(reply); kind != "invalid" {
		t.Errorf("no valid policy: got %q", kind)
	}
	json.Unmarshal(e.Perform([]byte(`not json`)), &reply)
	if kind := errorKind(reply); kind != "invalid" {
		t.Errorf("malformed request: got %q", kind)
	}
}

func TestFetchHTTPS(t *testing.T) {
	var seen http.Header
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		seen = r.Header.Clone()
		// Write the response by hand, so its header order is known.
		conn, buffered, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		reply := fmt.Sprintf("%s %s", r.Method, body)
		fmt.Fprintf(buffered, "HTTP/1.1 301 Moved Permanently\r\nX-B: 1\r\nLocation: /elsewhere\r\nSet-Cookie: a=1\r\nx-a: 2\r\nX-B: 3\r\nContent-Encoding: gzip\r\nContent-Length: %d\r\n\r\n%s", len(reply), reply)
		buffered.Flush()
	}))
	defer server.Close()
	saved := TLSConfig
	TLSConfig = server.Client().Transport.(*http.Transport).TLSClientConfig
	defer func() { TLSConfig = saved }()

	e := New(Options{})
	defer e.Close()
	result := ok(t, call(t, e, map[string]any{
		"op": "fetch", "url": server.URL + "/x?y=1", "method": "POST",
		"headers": [][]string{{"x-request", "hello"}}, "body": text("payload"),
	}))
	if status := result["status"].(float64); status != 301 {
		t.Errorf("status %v: a redirect is returned as it is", status)
	}
	if body, _ := base64.StdEncoding.DecodeString(result["body"].(string)); string(body) != "POST payload" {
		t.Errorf("body %q", body)
	}
	headers, _ := json.Marshal(result["headers"])
	want := `[["x-b","1"],["location","/elsewhere"],["set-cookie","a=1"],["x-a","2"],["x-b","3"],["content-encoding","gzip"],["content-length","12"]]`
	if string(headers) != want {
		t.Errorf("headers %s, want %s", headers, want)
	}
	if seen.Get("X-Request") != "hello" || seen.Get("Accept-Encoding") != "identity" || seen.Values("User-Agent") != nil {
		t.Errorf("request headers %v", seen)
	}
}

func TestFetchInvalidURL(t *testing.T) {
	e := New(Options{})
	defer e.Close()
	reply := call(t, e, map[string]any{"op": "fetch", "url": "https://[::1", "method": "GET", "headers": [][]string{}, "body": nil})
	if kind := errorKind(reply); kind != "invalid" {
		t.Errorf("got %v", reply)
	}
}

func TestFetchRefusesPlainHTTP(t *testing.T) {
	e := New(Options{})
	defer e.Close()
	reply := call(t, e, map[string]any{"op": "fetch", "url": "http://127.0.0.1:9/", "method": "GET", "headers": [][]string{}, "body": nil})
	if kind := errorKind(reply); kind != "denied" {
		t.Errorf("got %v", reply)
	}
}

func TestServeAcceptRespond(t *testing.T) {
	e := New(Options{})
	defer e.Close()
	served := ok(t, call(t, e, map[string]any{"op": "serve", "port": 0}))
	listener, port := served["listener"], int(served["port"].(float64))
	conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	reader := bufio.NewReader(conn)

	// Two requests on one connection, the second after the first's answer.
	exchanges := []struct {
		raw, path, headers, body string
	}{
		{
			"POST /p?q=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Z: 1\r\nContent-Type: text/plain\r\nx-z: 2\r\nContent-Length: 4\r\n\r\nsent",
			"/p?q=1",
			`[["host","127.0.0.1"],["x-z","1"],["content-type","text/plain"],["x-z","2"],["content-length","4"]]`,
			"sent",
		},
		{
			"PUT /again HTTP/1.1\r\nTransfer-Encoding: chunked\r\nHost: h\r\n\r\n2\r\nab\r\n0\r\nX-Trailer: t\r\n\r\n",
			"/again",
			`[["transfer-encoding","chunked"],["host","h"]]`,
			"ab",
		},
		// A malformed escape reaches the core as received, as Node's parser
		// passes it on.
		{
			"GET /a%zz?b HTTP/1.1\r\nHost: h\r\n\r\n",
			"/a%zz?b",
			`[["host","h"]]`,
			"",
		},
	}
	for _, exchange := range exchanges {
		if _, err := io.WriteString(conn, exchange.raw); err != nil {
			t.Fatal(err)
		}
		accepted := ok(t, call(t, e, map[string]any{"op": "accept", "listener": listener, "timeoutMs": 10000}))
		request, found := accepted["request"].(map[string]any)
		if !found {
			t.Fatalf("no request: %v", accepted)
		}
		if request["path"] != exchange.path {
			t.Errorf("request %v", request)
		}
		if body, _ := base64.StdEncoding.DecodeString(request["body"].(string)); string(body) != exchange.body {
			t.Errorf("request body %q", body)
		}
		if headers, _ := json.Marshal(request["headers"]); string(headers) != exchange.headers {
			t.Errorf("request headers %s, want %s", headers, exchange.headers)
		}
		ok(t, call(t, e, map[string]any{
			"op": "respond", "request": request["id"], "status": 202,
			"headers": [][]string{{"x-reply", "r"}}, "body": text("done"),
		}))
		response, err := http.ReadResponse(reader, nil)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(response.Body)
		if response.StatusCode != 202 || string(body) != "done" || response.Header.Get("X-Reply") != "r" {
			t.Errorf("response %v %q", response, body)
		}
		if kind := errorKind(call(t, e, map[string]any{
			"op": "respond", "request": request["id"], "status": 200, "headers": [][]string{}, "body": "",
		})); kind != "invalid" {
			t.Errorf("a second respond: got %q", kind)
		}
	}
	timedOut := ok(t, call(t, e, map[string]any{"op": "accept", "listener": listener, "timeoutMs": 10}))
	if timedOut["request"] != nil {
		t.Errorf("accept with no client: %v", timedOut)
	}
}

// A target that is not visible ASCII is refused with 400, as Node's parser
// refuses it, and a port in use is already-exists.
func TestServeRefusals(t *testing.T) {
	e := New(Options{})
	defer e.Close()
	served := ok(t, call(t, e, map[string]any{"op": "serve", "port": 0}))
	listener, port := served["listener"], int(served["port"].(float64))
	conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := io.WriteString(conn, "GET /caf\xe9 HTTP/1.1\r\nHost: h\r\n\r\n"); err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != 400 {
		t.Errorf("a non-ASCII target: %v", response)
	}
	timedOut := ok(t, call(t, e, map[string]any{"op": "accept", "listener": listener, "timeoutMs": 10}))
	if timedOut["request"] != nil {
		t.Errorf("a refused request was accepted: %v", timedOut)
	}
	if kind := errorKind(call(t, e, map[string]any{"op": "serve", "port": port})); kind != "already-exists" {
		t.Errorf("serve on a port in use: got %q", kind)
	}
}

func TestConfinement(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	inside := filepath.Join(root, "inside")
	os.WriteFile(filepath.Join(outside, "secret"), []byte("s"), 0o666)
	os.WriteFile(filepath.Join(root, "granted"), []byte("g"), 0o666)
	os.Symlink(outside, inside)
	narrow := map[string]any{"read": []string{root}, "write": []string{}, "programs": []string{}, "network": false, "listen": false}
	e := New(Options{})
	defer e.Close()
	for _, check := range []struct {
		name    string
		request map[string]any
		kind    string
	}{
		{"granted read", map[string]any{"op": "read", "path": filepath.Join(root, "granted")}, ""},
		{"read outside", map[string]any{"op": "read", "path": filepath.Join(outside, "secret")}, "denied"},
		{"read through a link", map[string]any{"op": "read", "path": filepath.Join(inside, "secret")}, "denied"},
		{"a link's own stat", map[string]any{"op": "stat", "path": inside, "follow": false}, ""},
		{"a link's target stat", map[string]any{"op": "stat", "path": inside, "follow": true}, "denied"},
		{"write to a read root", map[string]any{"op": "write", "path": filepath.Join(root, "x"), "data": "", "mode": "replace"}, "denied"},
		{"a relative path", map[string]any{"op": "read", "path": "granted"}, "invalid"},
		{"a missing file", map[string]any{"op": "read", "path": filepath.Join(root, "no", "such")}, "not-found"},
		{"spawn", map[string]any{"op": "spawn", "argv": []string{"/bin/echo"}, "cwd": root, "env": nil, "stdin": nil}, "denied"},
		{"serve", map[string]any{"op": "serve", "port": 0}, "denied"},
		{"fetch", map[string]any{"op": "fetch", "url": "https://127.0.0.1:9/", "method": "GET", "headers": [][]string{}, "body": nil}, "denied"},
		{"clock", map[string]any{"op": "clock"}, ""},
		{"realpath in a root", map[string]any{"op": "realpath", "path": root}, ""},
		{"realpath through a link", map[string]any{"op": "realpath", "path": filepath.Join(inside, "secret")}, "denied"},
	} {
		reply := callUnder(t, e, narrow, check.request)
		if kind := errorKind(reply); kind != check.kind {
			t.Errorf("%s: got %v", check.name, reply)
		}
	}
}

func TestInput(t *testing.T) {
	e := New(Options{Stdin: strings.NewReader("abc")})
	defer e.Close()
	first := ok(t, call(t, e, map[string]any{"op": "input", "max": 2}))
	if first["data"] != text("ab") || first["eof"] != false {
		t.Errorf("first %v", first)
	}
	second := ok(t, call(t, e, map[string]any{"op": "input", "max": 0}))
	if second["data"] != text("c") {
		t.Errorf("second %v", second)
	}
	last := ok(t, call(t, e, map[string]any{"op": "input", "max": 10}))
	if last["data"] != "" || last["eof"] != true {
		t.Errorf("last %v", last)
	}
}

func TestOutput(t *testing.T) {
	var stdout, stderr bytes.Buffer
	e := New(Options{Stdout: &stdout, Stderr: &stderr})
	defer e.Close()
	ok(t, call(t, e, map[string]any{"op": "output", "stream": "stdout", "data": text("o")}))
	ok(t, call(t, e, map[string]any{"op": "output", "stream": "stderr", "data": text("e")}))
	if stdout.String() != "o" || stderr.String() != "e" {
		t.Errorf("stdout %q stderr %q", stdout.String(), stderr.String())
	}
}

func TestRealpath(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "Dir"), 0o777)
	os.WriteFile(filepath.Join(root, "Dir", "File.txt"), []byte("f"), 0o666)
	os.Symlink("Dir", filepath.Join(root, "link"))
	os.Symlink("missing", filepath.Join(root, "dangling"))
	e := New(Options{})
	defer e.Close()
	realpath := func(file string) map[string]any {
		return call(t, e, map[string]any{"op": "realpath", "path": file})
	}
	base, _ := ok(t, realpath(root))["path"].(string)
	if real, _ := ok(t, realpath(base))["path"].(string); real != base {
		t.Errorf("a canonical path: got %q, want %q", real, base)
	}
	if strings.HasPrefix(root, "/var/") && !strings.HasPrefix(base, "/private/var/") {
		t.Errorf("the temporary directory's link: got %q", base)
	}
	want := filepath.Join(base, "Dir", "File.txt")
	if real, _ := ok(t, realpath(filepath.Join(root, "link", "File.txt")))["path"].(string); real != want {
		t.Errorf("through a link: got %q, want %q", real, want)
	}
	for _, check := range []struct{ name, path, kind string }{
		{"a missing path", filepath.Join(root, "missing"), "not-found"},
		{"a dangling link", filepath.Join(root, "dangling"), "not-found"},
		{"through a file", filepath.Join(root, "Dir", "File.txt", "x"), "not-a-directory"},
		{"a relative path", "Dir", "invalid"},
	} {
		if kind := errorKind(realpath(check.path)); kind != check.kind {
			t.Errorf("%s: got %q, want %q", check.name, kind, check.kind)
		}
	}
	// On a case-insensitive volume (the macOS default) each name comes back
	// in its stored case, as the C library's realpath gives it.
	if _, err := os.Stat(filepath.Join(root, "dir", "file.txt")); err == nil {
		if real, _ := ok(t, realpath(filepath.Join(root, "LINK", "file.TXT")))["path"].(string); real != want {
			t.Errorf("stored case: got %q, want %q", real, want)
		}
	}
}

func TestTerminal(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	var buffer bytes.Buffer
	e := New(Options{Stdin: reader, Stdout: writer, Stderr: &buffer})
	defer e.Close()
	for _, stream := range []string{"stdin", "stdout", "stderr"} {
		result := ok(t, call(t, e, map[string]any{"op": "terminal", "stream": stream}))
		if result["terminal"] != false || result["columns"] != nil {
			t.Errorf("%s: got %v", stream, result)
		}
	}
	if kind := errorKind(call(t, e, map[string]any{"op": "terminal", "stream": "stdtty"})); kind != "invalid" {
		t.Errorf("an unknown stream: got %q", kind)
	}
	narrow := map[string]any{"read": []string{}, "write": []string{}, "programs": []string{}, "network": false, "listen": false}
	if kind := errorKind(callUnder(t, e, narrow, map[string]any{"op": "terminal", "stream": "stderr"})); kind != "" {
		t.Errorf("a closed policy: got %q", kind)
	}
}

// TestGuard checks the guard (docs/reference/host-effects.md, Guard). The
// refusals that name real protected paths go to enforce alone, which
// performs nothing; only requests inside the test's own directory are
// performed, and the sentinel there must survive them.
func TestGuard(t *testing.T) {
	work := filepath.Join(t.TempDir(), "work")
	cwd := filepath.Join(work, "project", "cwd")
	os.MkdirAll(cwd, 0o777)
	sentinel := filepath.Join(work, "sentinel")
	os.WriteFile(sentinel, []byte("keep"), 0o666)
	os.WriteFile(filepath.Join(work, "doomed"), []byte("d"), 0o666)
	home, _ := os.UserHomeDir()
	os.Symlink("/", filepath.Join(work, "rootlink"))
	os.Symlink(work, filepath.Join(work, "project", "worklink"))
	if home != "" {
		os.Symlink(home, filepath.Join(work, "homelink"))
	}
	under := func(write []string, cwd string, projects ...string) *policy {
		read, programs, no := []string{}, []string{}, false
		return &policy{Read: &read, Write: &write, Programs: &programs, Network: &no, Listen: &no, Cwd: &cwd, Projects: projects}
	}
	// work is the project root, which may be a write root although it
	// contains the working directory.
	narrow := under([]string{work}, cwd, work)
	file := func(op, file string) *request {
		return &request{Op: op, Path: &file, Recursive: true}
	}
	move := func(from, to string) *request {
		return &request{Op: "rename", From: &from, To: &to}
	}
	for _, check := range []struct {
		name    string
		policy  *policy
		request *request
		denied  bool
	}{
		{"remove of /", narrow, file("remove", "/"), true},
		{"remove of the temporary root", narrow, file("remove", os.TempDir()), true},
		{"remove of /private/tmp", narrow, file("remove", "/private/tmp"), true},
		{"remove of /private", narrow, file("remove", "/private"), true},
		{"remove of a per-user temporary directory", narrow, file("remove", "/var/folders/ab/cdef/T"), true},
		{"remove of its parent", narrow, file("remove", "/private/var/folders/ab/cdef"), true},
		{"mkdirs at /", narrow, file("mkdirs", "/"), true},
		{"remove of home", narrow, file("remove", home), true},
		{"write to an ancestor of the working directory", narrow, file("write", filepath.Join(work, "project")), true},
		{"mkdirs of the working directory", narrow, file("mkdirs", cwd), true},
		{"a write root of /", under([]string{work, "/"}, cwd, work), file("write", filepath.Join(work, "new")), true},
		{"a write root of home", under([]string{work, home}, cwd, work), file("write", filepath.Join(work, "new")), true},
		{"a write root of the temporary root", under([]string{work, os.TempDir()}, cwd, work), file("read", sentinel), true},
		{"a write root containing the working directory", under([]string{work}, cwd), file("write", filepath.Join(work, "new")), true},
		{"a write root linked to /", under([]string{filepath.Join(work, "rootlink")}, cwd), file("write", filepath.Join(work, "rootlink", "x")), true},
		{"a write root linked to an ancestor of the working directory", under([]string{filepath.Join(work, "project", "worklink")}, cwd), file("write", filepath.Join(work, "project", "worklink", "x")), true},
		{"mkdirs through a link to home", narrow, file("mkdirs", filepath.Join(work, "homelink")), true},
		{"remove of a link to home removes only the link", narrow, file("remove", filepath.Join(work, "homelink")), false},
		{"remove of the write root itself", narrow, file("remove", work), true},
		{"remove strictly inside the write root", narrow, file("remove", filepath.Join(work, "doomed")), false},
		{"remove of a plain write root itself", under([]string{filepath.Join(work, "sub")}, cwd), file("remove", filepath.Join(work, "sub")), true},
		{"remove strictly inside a plain write root", under([]string{filepath.Join(work, "sub")}, cwd), file("remove", filepath.Join(work, "sub", "x")), false},
		{"a write inside a project root", narrow, file("write", filepath.Join(work, "new")), false},
		{"mkdirs of a project root", narrow, file("mkdirs", work), true},
		{"rename strictly inside the write root", narrow, move(filepath.Join(work, "doomed"), filepath.Join(work, "moved")), false},
		{"rename of the write root itself", narrow, move(work, filepath.Join(work, "moved")), true},
		{"rename over the write root", narrow, move(filepath.Join(work, "doomed"), work), true},
		{"rename of an ancestor of the working directory", narrow, move(filepath.Join(work, "project"), filepath.Join(work, "moved")), true},
		{"rename over the working directory", narrow, move(sentinel, cwd), true},
		{"rename through a link to home", narrow, move(sentinel, filepath.Join(work, "homelink", "x")), true},
		{"rename out of the write root", narrow, move(sentinel, filepath.Join(filepath.Dir(work), "x")), true},
	} {
		if home == "" && strings.Contains(check.name, "home") {
			continue
		}
		err := enforce(check.policy, check.request)
		if denied := err != nil && kindOf(err) == kindDenied; denied != check.denied {
			t.Errorf("%s: got %v", check.name, err)
		}
	}
	// Performed: only paths inside work, and only once enforce refuses them.
	e := New(Options{})
	defer e.Close()
	allow := map[string]any{"read": []string{}, "write": []string{work}, "programs": []string{}, "network": false, "listen": false, "cwd": cwd, "projects": []string{work}}
	for _, check := range []struct {
		name    string
		policy  map[string]any
		request map[string]any
	}{
		{"remove of the write root itself", allow, map[string]any{"op": "remove", "path": work, "recursive": true}},
		{"write to an ancestor of the working directory", allow, map[string]any{"op": "write", "path": filepath.Join(work, "project"), "data": "", "mode": "replace"}},
		{"a write root of /", map[string]any{"read": []string{}, "write": []string{work, "/"}, "programs": []string{}, "network": false, "listen": false}, map[string]any{"op": "write", "path": filepath.Join(work, "new"), "data": "", "mode": "replace"}},
	} {
		if kind := errorKind(callUnder(t, e, check.policy, check.request)); kind != "denied" {
			t.Errorf("performed %s: got %q", check.name, kind)
		}
	}
	ok(t, callUnder(t, e, allow, map[string]any{"op": "remove", "path": filepath.Join(work, "doomed"), "recursive": false}))
	if data, err := os.ReadFile(sentinel); err != nil || string(data) != "keep" {
		t.Errorf("the sentinel: %q, %v", data, err)
	}
	if _, err := os.Stat(filepath.Join(work, "new")); err == nil {
		t.Errorf("a refused write left a file")
	}
}

func TestRenameAndPermissions(t *testing.T) {
	root := t.TempDir()
	e := New(Options{})
	defer e.Close()
	policy := map[string]any{"read": []string{}, "write": []string{root}, "programs": []string{}, "network": false, "listen": false}
	in := func(name string) string { return filepath.Join(root, name) }
	ok(t, callUnder(t, e, policy, map[string]any{"op": "write", "path": in("a"), "data": text("a"), "mode": "replace", "permissions": 0o700}))
	ok(t, callUnder(t, e, policy, map[string]any{"op": "write", "path": in("b"), "data": text("b"), "mode": "replace"}))
	if bits := ok(t, callUnder(t, e, policy, map[string]any{"op": "stat", "path": in("a"), "follow": false}))["permissions"]; bits != float64(0o700) {
		t.Errorf("permissions of a: %v", bits)
	}
	ok(t, callUnder(t, e, policy, map[string]any{"op": "rename", "from": in("a"), "to": in("b")}))
	if data, err := os.ReadFile(in("b")); err != nil || string(data) != "a" {
		t.Errorf("renamed file: %q, %v", data, err)
	}
	ok(t, callUnder(t, e, policy, map[string]any{"op": "mkdirs", "path": in("d/e"), "permissions": 0o700}))
	os.WriteFile(in("d/e/x"), []byte("x"), 0o666)
	os.Mkdir(in("empty"), 0o777)
	// rename(2) replaces an empty directory, which os.Rename refuses.
	ok(t, callUnder(t, e, policy, map[string]any{"op": "rename", "from": in("d"), "to": in("empty")}))
	if info, err := os.Stat(in("empty/e")); err != nil || info.Mode().Perm() != 0o700 {
		t.Errorf("renamed directory: %v, %v", info, err)
	}
	for _, check := range []struct {
		name    string
		request map[string]any
		kind    string
	}{
		{"a missing source", map[string]any{"op": "rename", "from": in("missing"), "to": in("c")}, "not-found"},
		{"a file over a directory", map[string]any{"op": "rename", "from": in("b"), "to": in("empty")}, "is-a-directory"},
		{"a relative path", map[string]any{"op": "rename", "from": "b", "to": in("c")}, "invalid"},
		{"permissions out of range", map[string]any{"op": "write", "path": in("c"), "data": "", "mode": "replace", "permissions": 0o10000}, "invalid"},
	} {
		if kind := errorKind(callUnder(t, e, policy, check.request)); kind != check.kind {
			t.Errorf("%s: got %q", check.name, kind)
		}
	}
}
