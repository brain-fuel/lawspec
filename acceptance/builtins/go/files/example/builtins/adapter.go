// User-owned LawSpec adapter: native code that gets the built-in abilities'
// handlers as arguments.
package builtins

import (
	"fmt"
	"net"
	"time"
)

// Elapsed implements elapsed :: (Int32 -> lawspec.time::type::Duration).
func Elapsed(clock Clock, value0 int32) LawSpecDuration {
	start := clock.Now()
	for i := int32(0); i < value0; i++ {
		clock.Now()
	}
	return LawSpecDuration(time.Duration(clock.Now().Value-start.Value) * time.Microsecond)
}

// Token implements token :: (Int32 -> Bytes).
func Token(secureRandom SecureRandom, value0 int32) []byte {
	return secureRandom.SecureBytes(value0)
}

// Listening implements listening :: (Int32 -> Bool).
func Listening(ports Ports, value0 int32) bool {
	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", ports.FreePort()))
	if err != nil {
		return false
	}
	return listener.Close() == nil
}

// Charge implements charge :: (Int32 -> Bool).
func Charge(log Log, value0 int32) bool {
	if value0%2 == 0 {
		log.LogMessage(LogLevelInfo{}, fmt.Sprintf("charged %d", value0))
		return true
	}
	return false
}
