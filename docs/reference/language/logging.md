# Logs and traces

`lawspec.logging` has two abilities: `Log`, for messages at a level, and
`Trace`, for events. It is one of the [built-in abilities](builtins.md).

```lawspec
unit guide.billing

import lawspec.logging (LogLevel)

-- A native adapter that logs what it charges.
charge :: Int32 -> Bool uses Log

-- A law that inspects what was logged records the log.
law `a charge is logged once` using recording Log is
  definition is
    `for all` (cents :: Int32 where cents >= 0 && cents <= 1000) .
      (if charge cents then calls of logMessage == 1 else calls of logMessage == 0) = true
  end
end
```

## Log

```lawspec fragment
type LogLevel is | Debug | Info | Warning | Error end

ability Log is
  logMessage :: LogLevel -> Text -> Unit
end
```

`logMessage level text` logs `text` at `level`. Any logger is lawful: `Log`
has no laws. The **default handler** is the target's standard logger:

| Target | Logger |
| --- | --- |
| Python | `logging.getLogger("lawspec")` |
| JavaScript, TypeScript | `console.debug`, `info`, `warn` and `error` |
| Go | `log/slog`'s default logger |
| Java, Kotlin | `System.getLogger("lawspec")` |
| Haskell, Rust | a line on standard error, with its level |

The spec handler `silentLog` drops every message.

## Trace

```lawspec fragment
ability Trace is
  traceEvent :: Text -> Unit
end
```

`traceEvent name` records an event. The **default handler** logs it at
debug level, as `trace: name`; `silentTrace` drops it.

## Inspecting what was logged

A law that says what was logged uses `recording Log` (see
[handlers](handlers.md#counting-calls)): `calls of logMessage` counts every
message, and `calls of logMessage with (Info, "charged")` counts those with
that level and text. The recording passes each message on to the handler it
records, so the default logger still prints it.
