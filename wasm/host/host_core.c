// The C half of the host-effect ABI (docs/reference/host-effects.md).
// Allocation is plain libc so a host can allocate a reply while the core is
// suspended in perform, without re-entering the Haskell runtime.
// ref:DEC-host-effect-abi
#include <stdint.h>
#include <stdlib.h>

#include "HsFFI.h"
#include "Rts.h"

// GHC gives a foreign import no WebAssembly import module, so the import is
// declared here with its module and name, and Haskell calls the wrapper.
__attribute__((import_module("lawspec_host"), import_name("perform")))
extern uint8_t *lawspec_host_perform_import(const uint8_t *pointer,
                                            uint32_t length);

uint8_t *lawspec_host_perform(const uint8_t *pointer, uint32_t length)
{
  return lawspec_host_perform_import(pointer, length);
}

void *lawspec_alloc(uint32_t length)
{
  return malloc(length);
}

void lawspec_free(void *pointer)
{
  free(pointer);
}

// Start the runtime once, after the reactor's _initialize. The arguments
// match the npm launcher's: bound the heap below wasm32's address ceiling and
// compact the oldest generation in place.
void lawspec_init(void)
{
  static int started = 0;
  if (started)
  {
    return;
  }
  started = 1;
  static char *arguments[] = {"lawspec", "+RTS", "-M3584m", "-c", "-RTS",
                              NULL};
  int count = 5;
  char **vector = arguments;
  RtsConfig config = defaultRtsConfig;
  config.rts_opts_enabled = RtsOptsAll;
  hs_init_ghc(&count, &vector, config);
}
