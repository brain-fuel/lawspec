-module(example_builtin_context).
-export([native_probe/1]).

native_probe(ok) ->
    lawspec_abilities:with_context(fun(_) ->
        Clock = lawspec_time:clock_handler(),
        Random = lawspec_randomness:random_handler(),
        Another = lawspec_randomness:random_handler(),
        #{random_below := Draw} = Random,
        #{random_below := OtherDraw} = Another,
        Same = Draw(1000000) =:= OtherDraw(1000000),
        Checked = example_builtin_context_definitions:via_defaults(Clock, Random, 100),
        #{temporary_file := Temporary, write_bytes := Write, read_bytes := Read, remove_path := Remove} = lawspec_host:file_system_handler(),
        Path = Temporary(<<"lawspec-native-">>),
        Bytes = <<0, 255, 128>>,
        ReadBack = try
            ok = Write(Path, Bytes), Read(Path) =:= {just, Bytes}
        after Remove(Path) end,
        #{environment_variable := Variable} = lawspec_host:environment_handler(),
        NoVariable = Variable(<<0>>) =:= nothing,
        #{secure_bytes := SecureBytes} = lawspec_randomness:secure_random_handler(),
        Secure = byte_size(SecureBytes(32)) =:= 32,
        #{log_message := Log} = lawspec_logging:log_handler(),
        ok = Log(log_level_debug, <<"native">>),
        #{trace_event := Trace} = lawspec_logging:trace_handler(),
        ok = Trace(<<"native">>),
        #{pause := Pause} = lawspec_concurrent:async_handler(),
        ok = Pause(),
        Same andalso Checked andalso ReadBack andalso NoVariable andalso Secure
    end).
