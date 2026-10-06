# Files, environment and ports

`lawspec.host` has three abilities for the machine a program runs on:
`FileSystem`, `Environment` and `Ports`. It is one of the [built-in
abilities](builtins.md).

```lawspec
unit guide.notes

import lawspec.host

-- Keep a note in a file, read it back, and remove the file.
definition remember (note :: Bytes) :: Maybe Bytes uses FileSystem is
  writeBytes ".guide-note" note; let read = readBytes ".guide-note" in removePath ".guide-note"; read
end

law `a remembered note reads back` is
  definition is `for all` (note :: Bytes) . remember note = Just note end
end

law `an empty environment has no variables` using emptyEnvironment is
  definition is `for all` (name :: Text) . environmentVariable name = Nothing end
end
```

## FileSystem

```lawspec fragment
ability FileSystem is
  readBytes :: Text -> Maybe Bytes
  writeBytes :: Text -> Bytes -> Unit
  pathExists :: Text -> Bool
  removePath :: Text -> Unit
  temporaryDirectory :: Text -> Text
  temporaryFile :: Text -> Text
end
```

- `readBytes path` is the file's bytes, or `Nothing` when it cannot be read.
- `writeBytes path b` writes the file, replacing it.
- `pathExists path` holds for a file, directory or link at the path.
- `removePath path` removes a file, or a directory and what it holds; a path
  with nothing at it is left alone.
- `temporaryDirectory prefix` makes a new empty directory whose name starts
  with the prefix, in the system's temporary directory, and is its path;
  `temporaryFile prefix` does the same for an empty file.
- Laws: a written file reads back, and a removed file is gone. Each law uses
  a file of its own in the working directory (`.lawspec-law-read`,
  `.lawspec-law-removed`), as test runners may run laws at once.

The **default handler** is the process's file system; a relative path is
from the working directory.

## Environment

```lawspec fragment
ability Environment is
  environmentVariable :: Text -> Maybe Text
  environmentSnapshot :: Text
  restoreEnvironment :: Text -> Unit
end
```

`environmentVariable name` is the variable's value, or `Nothing`. A name
that cannot be a variable's (empty, or with `=` or NUL in it) has none.
`environmentSnapshot` saves the whole environment as text, and
`restoreEnvironment saved` puts it back as saved. Law: a variable has one
value. The **default handler** reads and restores the process's environment
(on Java and Kotlin, whose process environment cannot change, the system
properties); the spec handler `emptyEnvironment` has no variables, and saves
and restores nothing.

## Ports

```lawspec fragment
ability Ports is
  freePort :: (p :: Int32 where p >= 1 && p <= 65535)
end
```

`freePort` is a TCP port on 127.0.0.1 that the operating system reported
free when asked; another process may take it before it is used. Every
handler owes the refinement on its result. The **default handler** binds a
socket to port 0 and reads the port the system chose (Node, which binds only
asynchronously, asks a child process).

## Resources

The built-in [resources](resources.md#built-in-resources) build on these
abilities: `TemporaryDirectory` and `TemporaryFile` acquire through
`temporaryDirectory` and `temporaryFile` and release through `removePath`,
`SavedEnvironment` through `environmentSnapshot` and `restoreEnvironment`,
and `FreePort` through `freePort`. A law that takes one runs those
operations under the ability's production handler: the default one, or the
one `lawspec.json` binds. A program that names a built-in resource gets
`lawspec.host` without importing it.
