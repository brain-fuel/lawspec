import example/builtin_context/definitions
import gleam/bit_array
import gleam/option.{None, Some}
import lawspec/abilities/lawspec/concurrent as async_interface
import lawspec/abilities/lawspec/host as host_interface
import lawspec/abilities/lawspec/logging as log_interface
import lawspec/abilities/lawspec/randomness as random_interface
import lawspec/concurrent
import lawspec/data
import lawspec/effects
import lawspec/host
import lawspec/logging
import lawspec/randomness
import lawspec/time

pub fn native_probe(_unit: Nil) -> Bool {
  effects.with_context(fn(_) {
    let clock = time.clock_handler()
    let random = randomness.random_handler()
    let another = randomness.random_handler()
    let same = random_interface.random_random_below(random, 1_000_000) == random_interface.random_random_below(another, 1_000_000)
    let checked = definitions.via_defaults(clock, random, 100)
    let files = host.file_system_handler()
    let path = host_interface.file_system_temporary_file(files, "lawspec-native-")
    let bytes = <<0, 255, 128>>
    host_interface.file_system_write_bytes(files, path, bytes)
    let read_back = host_interface.file_system_read_bytes(files, path) == Some(bytes)
    host_interface.file_system_remove_path(files, path)
    let environment = host.environment_handler()
    let no_variable = host_interface.environment_environment_variable(environment, "\u{0000}") == None
    let secure_random = randomness.secure_random_handler()
    let secure = bit_array.byte_size(random_interface.secure_random_secure_bytes(secure_random, 32)) == 32
    let log = logging.log_handler()
    log_interface.log_log_message(log, data.LogLevelDebug, "native")
    let trace = logging.trace_handler()
    log_interface.trace_trace_event(trace, "native")
    let async = concurrent.async_handler()
    async_interface.async_pause(async)
    same && checked && read_back && no_variable && secure
  })
}
