# Host Command Adapters

Bash.swift does not discover or execute programs installed on the host. Its
default command registry remains jailed and deterministic. Applications that
need model-generated calls to tools such as `swift`, `bun`, `node`, or `gh` can
register a command adapter explicitly.

```swift
try await session.registerHostCommand(
    HostCommandDescriptor(
        name: "host-swift",
        aliases: ["swift"],
        overview: "Run an approved Swift toolchain operation",
        forwardedEnvironmentKeys: ["SDKROOT"]
    ),
    authorize: { request in
        request.arguments.first == "--version"
            ? .allow
            : .deny(message: "only --version is allowed")
    },
    execute: { request in
        // The app owns process creation. Pass request.arguments as an argv
        // array; do not concatenate them into `sh -c` or another shell string.
        try await appHostExecutor.runSwift(request)
    }
)
```

The boundary has several deliberate properties:

- Nothing is registered by default, and Bash.swift never imports `Process` or
  spawns a host executable itself.
- Authorization runs for every invocation. A denial returns exit status 126
  without calling the executor.
- Only environment keys named by `forwardedEnvironmentKeys` cross the boundary.
  The default is an empty environment.
- `stdin` and output are byte-preserving `Data` values.
- `virtualCurrentDirectory` belongs to the Bash.swift workspace. It must not be
  treated as a host path without an application-owned mapping and authorization.
- Registering a name or alias already present in the command registry replaces
  that entry, just like `register(_:)`; applications should prefer explicit
  adapter names and narrowly chosen aliases.

Adapters are the appropriate integration point for host-only transcript calls,
including build tools and OS process inspection. They do not change the meaning
of in-process `ps`, `pgrep`, `kill`, or `pkill`, which remain scoped to the
current session's pseudo-processes.
