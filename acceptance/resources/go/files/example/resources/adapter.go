// User-owned LawSpec adapters for the resources example.
package resources

import (
	"net"
	"os"
	"path/filepath"
	"strconv"
)

// store is an in-memory store. At most three may be open at once, so a
// store that is never closed is noticed.
type store struct {
	items map[int32]int32
	open  bool
}

var openCount = 0

// OpenStore implements openStore :: (Unit -> example.resources::type::Store).
func OpenStore(value0 LawSpecValue) any {
	if openCount >= 3 {
		panic("too many open stores: one was never closed")
	}
	openCount++
	return &store{items: map[int32]int32{}, open: true}
}

// CloseStore implements closeStore :: (example.resources::type::Store -> Unit).
func CloseStore(value0 any) {
	s := value0.(*store)
	if s.open {
		s.open = false
		openCount--
	}
}

// ClearStore implements clearStore :: (example.resources::type::Store -> Unit).
func ClearStore(value0 any) {
	value0.(*store).items = map[int32]int32{}
}

// Put implements put :: (example.resources::type::Store -> (Int32 -> (Int32 -> Unit))).
func Put(value0 any, value1 int32, value2 int32) {
	s := value0.(*store)
	if !s.open {
		panic("the store is closed")
	}
	s.items[value1] = value2
}

// Get implements get :: (example.resources::type::Store -> (Int32 -> Maybe (Int32))).
func Get(value0 any, value1 int32) LawSpecMaybe[int32] {
	s := value0.(*store)
	if !s.open {
		panic("the store is closed")
	}
	if v, ok := s.items[value1]; ok {
		return LawSpecJust(v)
	}
	return LawSpecNothing[int32]()
}

// IsOpen implements isOpen :: (example.resources::type::Store -> Bool).
func IsOpen(value0 any) bool {
	return value0.(*store).open
}

// WriteNote implements writeNote :: (Text -> (Int32 -> Unit)).
func WriteNote(value0 string, value1 int32) {
	if err := os.WriteFile(filepath.Join(value0, "note.txt"), []byte(strconv.Itoa(int(value1))), 0o644); err != nil {
		panic(err)
	}
}

// ReadNote implements readNote :: (Text -> Maybe (Int32)).
func ReadNote(value0 string) LawSpecMaybe[int32] {
	text, err := os.ReadFile(filepath.Join(value0, "note.txt"))
	if err != nil {
		return LawSpecNothing[int32]()
	}
	n, _ := strconv.Atoi(string(text))
	return LawSpecJust(int32(n))
}

// CanListen implements canListen :: (Int32 -> Bool).
func CanListen(value0 int32) bool {
	listener, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(int(value0)))
	if err != nil {
		return false
	}
	listener.Close()
	return true
}

// SetGreeting implements setGreeting :: (Int32 -> Unit).
func SetGreeting(value0 int32) {
	os.Setenv("LAWSPEC_EXAMPLE_GREETING", strconv.Itoa(int(value0)))
}

// Greeting implements greeting :: (Unit -> Maybe (Int32)).
func Greeting(value0 LawSpecValue) LawSpecMaybe[int32] {
	text, ok := os.LookupEnv("LAWSPEC_EXAMPLE_GREETING")
	if !ok {
		return LawSpecNothing[int32]()
	}
	n, _ := strconv.Atoi(text)
	return LawSpecJust(int32(n))
}
