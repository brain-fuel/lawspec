---
id: lawspec.how-to.use-mcp
kind: how-to
title: Use the MCP server
---
# Use the MCP server

LawSpec's MCP server lets an MCP host inspect and explain the project it starts
in. It uses the same compiler API and project manifest as the CLI.

## Start it

Install LawSpec in the project, then launch it from that project's directory:

```sh
npx lawspec mcp
```

For a project whose manifest is elsewhere, pass its path:

```sh
npx lawspec mcp --config ../contracts/lawspec.edn
```

The server uses MCP stdio: the host starts the process and exchanges protocol
messages through its standard input and output. When configuring a host, set the
command to `npx` and the arguments to `lawspec`, `mcp`; set the working
directory to the project. Or set arguments to `lawspec`, `mcp`, `--config`,
`/absolute/path/to/lawspec.edn`.

To browse the tools without configuring a host, use the MCP Inspector:

```sh
npx @modelcontextprotocol/inspector npx lawspec mcp
```

## Available tools

- `lawspec_check` runs compiler definition validation and the law verification
  layers selected by the manifest. It returns the compiler result, including
  the verification selection and evidence statuses.
- `lawspec_list_laws` validates the project and returns each law's identity,
  description, and source location. Listing a law does not establish that it
  has been proved or tested.
- `lawspec_explain` explains a law in `eng`, `math`, or `dev` form. Supply an
  identity such as `example.codec::round trip`; the default view is `eng`.

Each tool reads the current manifest and sources when called. The server does
not write project files. Definition validation remains mandatory. Optional law
verification follows `verification.layers`, and evidence outcomes such as
`pending`, `unsupported`, and `incomplete` retain their distinct meanings.
