module goforge.dev/lawspec

// Go 1.25 is wazero v1.12.0's floor (current Go minus one).
go 1.25.0

require (
	// v1.12.0 (2026-05-28) is wazero's latest release. The Plan B Stage 0
	// engine spike ran the core on it byte-identical with V8 at 1.22x V8's
	// warm time; a later version is adopted by re-running
	// tools/hosts.sh conformance and parity.
	github.com/tetratelabs/wazero v1.12.0
	// The version wazero v1.12.0 requires, for signal names and getcwd.
	golang.org/x/sys v0.44.0
)
