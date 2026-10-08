defmodule Example.BuiltinContext do
  def native_probe(:ok) do
    :lawspec_abilities.with_context(fn _ ->
      clock = Lawspec.Time.clock_handler()
      random = Lawspec.Randomness.random_handler()
      another = Lawspec.Randomness.random_handler()
      same = random.random_below.(1_000_000) == another.random_below.(1_000_000)
      checked = Example.BuiltinContext.Definitions.via_defaults(clock, random, 100)
      files = Lawspec.Host.file_system_handler()
      path = files.temporary_file.("lawspec-native-")
      bytes = <<0, 255, 128>>
      read_back = try do
        :ok = files.write_bytes.(path, bytes)
        files.read_bytes.(path) == {:just, bytes}
      after
        files.remove_path.(path)
      end
      environment = Lawspec.Host.environment_handler()
      no_variable = environment.environment_variable.(<<0>>) == :nothing
      secure_random = Lawspec.Randomness.secure_random_handler()
      secure = byte_size(secure_random.secure_bytes.(32)) == 32
      log = Lawspec.Logging.log_handler()
      :ok = log.log_message.(%LawSpec.Data.LogLevelDebug{}, "native")
      trace = Lawspec.Logging.trace_handler()
      :ok = trace.trace_event.("native")
      async = Lawspec.Concurrent.async_handler()
      :ok = async.pause.()
      same and checked and read_back and no_variable and secure
    end)
  end
end
