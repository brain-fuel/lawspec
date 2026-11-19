package effects

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// TLSConfig is the TLS configuration fetch dials with; nil checks
// certificates against the host's trust store. Tests replace it to trust a
// local certificate.
var TLSConfig *tls.Config

// fetchTimeout is how long fetch waits on an idle connection, as Node's
// socket timeout does.
const fetchTimeout = 60 * time.Second

// headerLimit bounds a request's or response's header block.
const headerLimit = 64 << 10

var errHeaderTooLarge = errors.New("the header block is larger than 64 KiB")

// Both directions read and write HTTP/1.1 messages themselves, on Go's own
// parser: net/http's server and client keep headers in a map, which loses
// the order the ABI reports. The raw header block is read from the buffered
// connection with Peek, so it is seen exactly as received. A response is
// then consumed by http.ReadResponse, which handles framing
// (Content-Length, chunked, close-delimited); a request's head is parsed
// from a copy (readHead) and its body read as its headers frame it
// (readBody). ref:go-http-read-request

// headerEnd returns the length of the header block at the start of data,
// through its empty line, or -1 when the block is not complete.
func headerEnd(data []byte) int {
	position := 0
	for {
		index := bytes.IndexByte(data[position:], '\n')
		if index < 0 {
			return -1
		}
		line := data[position : position+index]
		position += index + 1
		if len(line) == 0 || (len(line) == 1 && line[0] == '\r') {
			return position
		}
	}
}

// peekHeader returns the next message's start line and header block without
// consuming it.
func peekHeader(reader *bufio.Reader) ([]byte, error) {
	for {
		data, _ := reader.Peek(reader.Buffered())
		if end := headerEnd(data); end >= 0 {
			return data[:end], nil
		}
		if reader.Buffered() >= reader.Size() {
			return nil, errHeaderTooLarge
		}
		if _, err := reader.Peek(reader.Buffered() + 1); err != nil {
			return nil, err
		}
	}
}

// headerPairs lists a raw header block's fields after its start line, in
// the order received and with repeats, names in lower case. An obsolete
// folded line continues the previous value, as Go's parser reads it.
func headerPairs(block []byte) [][]string {
	lines := strings.Split(latin1(block), "\n")
	pairs := [][]string{}
	for _, line := range lines[1:] {
		line = strings.TrimSuffix(line, "\r")
		if line == "" {
			break
		}
		if (line[0] == ' ' || line[0] == '\t') && len(pairs) > 0 {
			last := pairs[len(pairs)-1]
			last[1] = strings.Trim(last[1]+" "+strings.Trim(line, " \t"), " \t")
			continue
		}
		name, value, _ := strings.Cut(line, ":")
		pairs = append(pairs, []string{strings.ToLower(name), strings.Trim(value, " \t")})
	}
	return pairs
}

// latin1 decodes header bytes as Latin-1, as the ABI's header text is.
func latin1(data []byte) string {
	ascii := true
	for _, b := range data {
		if b >= 0x80 {
			ascii = false
			break
		}
	}
	if ascii {
		return string(data)
	}
	runes := make([]rune, len(data))
	for i, b := range data {
		runes[i] = rune(b)
	}
	return string(runes)
}

// headerLine encodes one [name, value] pair as Latin-1, refusing what
// Node's HTTP module refuses: a name that is not a token, or a value with a
// control character other than tab, or a character beyond Latin-1.
func headerLine(pair []string) ([]byte, error) {
	if len(pair) != 2 {
		return nil, newError(kindInvalid, "headers entries must be [name, value] string pairs")
	}
	name, value := pair[0], pair[1]
	if !isToken(name) {
		return nil, newError(kindFailed, "invalid header name %q", name)
	}
	line := append([]byte(name), ':', ' ')
	for _, c := range value {
		if c > 0xFF || c == 0x7F || (c < 0x20 && c != '\t') {
			return nil, newError(kindFailed, "invalid character in header %s", name)
		}
		line = append(line, byte(c))
	}
	return append(line, '\r', '\n'), nil
}

func isToken(text string) bool {
	if text == "" {
		return false
	}
	for _, c := range text {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case strings.ContainsRune("!#$%&'*+-.^_`|~", c):
		default:
			return false
		}
	}
	return true
}

func hasHeader(pairs [][]string, name string) bool {
	for _, pair := range pairs {
		if len(pair) == 2 && strings.EqualFold(pair[0], name) {
			return true
		}
	}
	return false
}

func headerContains(pairs [][]string, name, token string) bool {
	for _, pair := range pairs {
		if len(pair) == 2 && strings.EqualFold(pair[0], name) && strings.Contains(strings.ToLower(pair[1]), token) {
			return true
		}
	}
	return false
}

// idleConn fails a read or write that waits longer than timeout.
type idleConn struct {
	net.Conn
	timeout time.Duration
}

func (c idleConn) Read(data []byte) (int, error) {
	c.SetDeadline(time.Now().Add(c.timeout))
	return c.Conn.Read(data)
}

func (c idleConn) Write(data []byte) (int, error) {
	c.SetDeadline(time.Now().Add(c.timeout))
	return c.Conn.Write(data)
}

// fetch sends one HTTPS request over its own HTTP/1.1 connection: the
// core's method, headers (in order) and body, plus only the framing headers
// it did not send (Host, Content-Length, Connection) and Accept-Encoding:
// identity when it sent no Accept-Encoding, with no User-Agent. Redirects
// are returned as they are and no content encoding is decoded.
func (e *Effects) fetch(r *request) (object, error) {
	if !strings.HasPrefix(r.URL, "https://") {
		return nil, newError(kindDenied, "only https URLs may be fetched: %s", r.URL)
	}
	target, err := url.Parse(r.URL)
	if err != nil || target.Host == "" || target.Opaque != "" {
		return nil, newError(kindInvalid, "invalid URL %s", r.URL)
	}
	var body []byte
	if r.Body != nil {
		if body, err = decode("body", r.Body); err != nil {
			return nil, err
		}
	}
	if !isToken(r.Method) {
		return nil, newError(kindFailed, "invalid method %q", r.Method)
	}
	message := fmt.Appendf(nil, "%s %s HTTP/1.1\r\n", r.Method, target.RequestURI())
	for _, pair := range r.Headers {
		line, err := headerLine(pair)
		if err != nil {
			return nil, err
		}
		message = append(message, line...)
	}
	hostname := strings.ToLower(target.Hostname())
	port := target.Port()
	if !hasHeader(r.Headers, "host") {
		host := hostname
		if strings.Contains(host, ":") {
			host = "[" + host + "]"
		}
		if port != "" && port != "443" {
			host += ":" + port
		}
		message = fmt.Appendf(message, "Host: %s\r\n", host)
	}
	if body != nil && !hasHeader(r.Headers, "content-length") {
		message = fmt.Appendf(message, "Content-Length: %d\r\n", len(body))
	}
	if !hasHeader(r.Headers, "accept-encoding") {
		message = append(message, "Accept-Encoding: identity\r\n"...)
	}
	if !hasHeader(r.Headers, "connection") {
		message = append(message, "Connection: close\r\n"...)
	}
	message = append(append(message, '\r', '\n'), body...)
	if port == "" {
		port = "443"
	}

	config := &tls.Config{}
	if TLSConfig != nil {
		config = TLSConfig.Clone()
	}
	config.NextProtos = []string{"http/1.1"}
	ctx, cancel := context.WithTimeout(context.Background(), fetchTimeout)
	defer cancel()
	dialer := &tls.Dialer{Config: config}
	socket, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(hostname, port))
	if err != nil {
		return nil, fetchFailure(err)
	}
	defer socket.Close()
	conn := idleConn{socket, fetchTimeout}
	if _, err := conn.Write(message); err != nil {
		return nil, fetchFailure(err)
	}
	reader := bufio.NewReaderSize(conn, headerLimit)
	for {
		block, err := peekHeader(reader)
		if err != nil {
			return nil, fetchFailure(err)
		}
		response, err := http.ReadResponse(reader, &http.Request{Method: r.Method})
		if err != nil {
			return nil, fetchFailure(err)
		}
		// An interim response (100 Continue, 103 Early Hints) precedes the
		// final one.
		if response.StatusCode >= 100 && response.StatusCode < 200 && response.StatusCode != http.StatusSwitchingProtocols {
			continue
		}
		received, err := io.ReadAll(response.Body)
		if err != nil {
			return nil, fetchFailure(err)
		}
		return object{"status": response.StatusCode, "headers": headerPairs(block), "body": encode(received)}, nil
	}
}

func fetchFailure(err error) error {
	if errors.Is(err, os.ErrDeadlineExceeded) || errors.Is(err, context.DeadlineExceeded) {
		return newError(kindFailed, "no response within 60 seconds")
	}
	return newError(kindFailed, "%v", err)
}

// listener is one loopback HTTP server, its open connections and its
// complete requests not yet accepted.
type listener struct {
	socket net.Listener
	conns  map[net.Conn]struct{}
	queue  []object
}

// pending is a request the core has accepted and not yet answered.
type pending struct {
	reply  chan reply
	cancel chan struct{}
}

type reply struct {
	status  int
	headers [][]string
	lines   []byte
	body    []byte
}

// serve listens for HTTP on 127.0.0.1.
func (e *Effects) serve(r *request) (object, error) {
	socket, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(r.Port)))
	if err != nil {
		return nil, err
	}
	l := &listener{socket: socket, conns: map[net.Conn]struct{}{}}
	e.mu.Lock()
	id := e.nextID()
	e.listeners[id] = l
	e.mu.Unlock()
	go func() {
		for {
			conn, err := socket.Accept()
			if err != nil {
				return
			}
			e.mu.Lock()
			if e.closed {
				e.mu.Unlock()
				conn.Close()
				return
			}
			l.conns[conn] = struct{}{}
			e.mu.Unlock()
			go e.serveConn(l, conn)
		}
	}()
	return object{"listener": id, "port": socket.Addr().(*net.TCPAddr).Port}, nil
}

// serveConn reads the requests of one connection in turn, queues each
// complete one for accept and writes the response the core gives it with
// respond.
func (e *Effects) serveConn(l *listener, conn net.Conn) {
	defer func() {
		e.mu.Lock()
		delete(l.conns, conn)
		e.mu.Unlock()
		conn.Close()
	}()
	reader := bufio.NewReaderSize(conn, headerLimit)
	writer := bufio.NewWriter(conn)
	for {
		block, err := peekHeader(reader)
		if errors.Is(err, errHeaderTooLarge) {
			io.WriteString(conn, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
			return
		}
		if err != nil {
			return
		}
		target, incoming, err := readHead(block)
		if err != nil {
			io.WriteString(conn, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
			return
		}
		if _, err := reader.Discard(len(block)); err != nil {
			return
		}
		if incoming.ProtoAtLeast(1, 1) && strings.EqualFold(incoming.Header.Get("Expect"), "100-continue") {
			if _, err := io.WriteString(conn, "HTTP/1.1 100 Continue\r\n\r\n"); err != nil {
				return
			}
		}
		body, err := readBody(reader, incoming)
		if err != nil {
			io.WriteString(conn, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
			return
		}
		p := &pending{reply: make(chan reply, 1), cancel: make(chan struct{})}
		e.mu.Lock()
		if e.closed {
			e.mu.Unlock()
			return
		}
		id := e.nextID()
		e.requests[id] = p
		l.queue = append(l.queue, object{
			"id":      id,
			"method":  incoming.Method,
			"path":    target,
			"headers": headerPairs(block),
			"body":    encode(body),
		})
		e.wake()
		e.mu.Unlock()
		var answer reply
		select {
		case answer = <-p.reply:
		case <-p.cancel:
			return
		}
		closing := incoming.Close || headerContains(answer.headers, "connection", "close")
		writeResponse(writer, incoming.Method, closing, answer)
		if writer.Flush() != nil || closing {
			return
		}
	}
}

// readHead parses a request's start line and header block. The target is
// taken as received, as Node's parser takes it: any visible ASCII, so a
// malformed percent escape reaches the core, which answers it, while a
// target with a space, a control character or a byte above 0x7E is
// refused, as Node refuses it. Go's parser would also check the target as
// a URL, so it parses the block with the target replaced by "/"; the body
// is then framed from the request's headers (readBody).
func readHead(block []byte) (string, *http.Request, error) {
	end := bytes.IndexByte(block, '\n')
	line := strings.TrimSuffix(string(block[:end]), "\r")
	method, rest, found := strings.Cut(line, " ")
	target, proto, found2 := strings.Cut(rest, " ")
	if !found || !found2 || target == "" {
		return "", nil, errors.New("malformed request line")
	}
	for i := 0; i < len(target); i++ {
		if target[i] < 0x21 || target[i] > 0x7E {
			return "", nil, errors.New("invalid character in the request target")
		}
	}
	head := append([]byte(method+" / "+proto), block[end:]...)
	incoming, err := http.ReadRequest(bufio.NewReaderSize(bytes.NewReader(head), len(head)+16))
	if err != nil {
		return "", nil, err
	}
	return target, incoming, nil
}

// readBody reads a request's body from the connection as its headers frame
// it: chunked, with any trailer fields after the last chunk, or a
// Content-Length, or none.
func readBody(reader *bufio.Reader, incoming *http.Request) ([]byte, error) {
	switch {
	case len(incoming.TransferEncoding) > 0:
		body, err := io.ReadAll(httputil.NewChunkedReader(reader))
		if err != nil {
			return nil, err
		}
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				return nil, err
			}
			if line == "\r\n" || line == "\n" {
				return body, nil
			}
		}
	case incoming.ContentLength > 0:
		body := make([]byte, incoming.ContentLength)
		_, err := io.ReadFull(reader, body)
		return body, err
	default:
		return []byte{}, nil
	}
}

// writeResponse writes the core's status, headers in its order and body,
// adding Date, Content-Length and Connection: close only when the core did
// not give them and the framing needs them.
func writeResponse(w *bufio.Writer, method string, closing bool, answer reply) {
	reason := http.StatusText(answer.status)
	if reason == "" {
		reason = "unknown"
	}
	fmt.Fprintf(w, "HTTP/1.1 %d %s\r\n", answer.status, reason)
	w.Write(answer.lines)
	if !hasHeader(answer.headers, "date") {
		fmt.Fprintf(w, "Date: %s\r\n", time.Now().UTC().Format(http.TimeFormat))
	}
	noBody := method == http.MethodHead || answer.status < 200 || answer.status == http.StatusNoContent || answer.status == http.StatusNotModified
	chunked := headerContains(answer.headers, "transfer-encoding", "chunked")
	if !noBody && !chunked && !hasHeader(answer.headers, "content-length") {
		fmt.Fprintf(w, "Content-Length: %d\r\n", len(answer.body))
	}
	if closing && !hasHeader(answer.headers, "connection") {
		w.WriteString("Connection: close\r\n")
	}
	w.WriteString("\r\n")
	switch {
	case noBody:
	case chunked:
		if len(answer.body) > 0 {
			fmt.Fprintf(w, "%x\r\n", len(answer.body))
			w.Write(answer.body)
			w.WriteString("\r\n")
		}
		w.WriteString("0\r\n\r\n")
	default:
		w.Write(answer.body)
	}
}

// accept returns the next complete request, or null after timeoutMs.
func (e *Effects) accept(r *request) (object, error) {
	e.mu.Lock()
	l, found := e.listeners[r.Listener]
	e.mu.Unlock()
	if !found {
		return nil, newError(kindInvalid, "unknown listener %d", r.Listener)
	}
	e.waitFor(func() bool { return len(l.queue) > 0 }, milliseconds(r.TimeoutMs))
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(l.queue) == 0 {
		return object{"request": nil}, nil
	}
	next := l.queue[0]
	l.queue = l.queue[1:]
	return object{"request": next}, nil
}

// respond answers an accepted request once.
func (e *Effects) respond(r *request) (object, error) {
	body, err := decode("body", r.Body)
	if err != nil {
		return nil, err
	}
	var lines []byte
	for _, pair := range r.Headers {
		line, err := headerLine(pair)
		if err != nil {
			return nil, err
		}
		lines = append(lines, line...)
	}
	if r.Status < 100 || r.Status > 999 {
		return nil, newError(kindInvalid, "invalid status code %d", r.Status)
	}
	e.mu.Lock()
	p, found := e.requests[r.Request]
	delete(e.requests, r.Request)
	e.mu.Unlock()
	if !found {
		return nil, newError(kindInvalid, "unknown request %d", r.Request)
	}
	p.reply <- reply{status: r.Status, headers: r.Headers, lines: lines, body: body}
	return object{}, nil
}
