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

## Cookbook

Treat every registered command as a small API, not as general shell access. A
good adapter has a fixed executable, validates the argument vector before any
host work begins, forwards only named environment values, and maps virtual paths
explicitly when the command needs a working directory.

### Read-only tool information

Version and help probes are common in model transcripts and are a useful first
adapter because their policy can be exact:

```swift
let allowedSwiftQueries: Set<[String]> = [
    ["--version"],
    ["package", "--version"],
]

try await session.registerHostCommand(
    HostCommandDescriptor(name: "swift", overview: "Inspect the Swift toolchain"),
    authorize: { request in
        allowedSwiftQueries.contains(request.arguments)
            ? .allow
            : .deny(message: "only toolchain version queries are allowed")
    },
    execute: { request in
        try await hostProcesses.run(
            executable: URL(fileURLWithPath: "/usr/bin/swift"),
            arguments: request.arguments,
            stdin: request.stdin,
            environment: [:],
            currentDirectory: nil
        )
    }
)
```

The executor API above is application-owned. Its implementation should assign
`Process.executableURL` and `Process.arguments` independently. Do not use
`/bin/sh -c`, interpolate an argument string, search `PATH`, or inherit the
application's entire environment.

### Scoped build tools

Build adapters usually need a host checkout. Keep that mapping outside
Bash.swift and ignore arbitrary virtual paths:

```swift
let approvedCheckout = URL(fileURLWithPath: "/srv/checkouts/example", isDirectory: true)
let allowedBuilds: Set<[String]> = [
    ["test"],
    ["run", "check-types"],
]

try await session.registerHostCommand(
    HostCommandDescriptor(
        name: "bun",
        overview: "Run approved project checks",
        forwardedEnvironmentKeys: ["CI"]
    ),
    authorize: { request in
        request.virtualCurrentDirectory == "/workspace/project"
            && allowedBuilds.contains(request.arguments)
            ? .allow
            : .deny(message: "command or workspace is outside the build policy")
    },
    execute: { request in
        try await hostProcesses.run(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/bun"),
            arguments: request.arguments,
            stdin: request.stdin,
            environment: request.environment,
            currentDirectory: approvedCheckout
        )
    }
)
```

Prefer exact argument vectors or a parsed subcommand policy. Prefix checks such
as `arguments.first == "run"` are too broad if arbitrary script names or flags
remain possible.

### Read-only GitHub inspection

For `gh`, validate the complete subcommand shape and repository independently.
For example, an inspection adapter can accept only `pr view`, `pr checks`, and
`run view`, require `--repo owner/name`, and reject flags that write files or
open a browser. Keep mutating forms such as `pr merge`, `issue create`, and
`api --method POST` in a separate adapter and authorization flow.

```swift
authorize: { request in
    guard let operation = GHReadPolicy.parse(request.arguments) else {
        return .deny(message: "unsupported gh invocation")
    }
    return operation.repository == "owner/name" ? .allow : .deny(message: "repository not allowed")
}
```

Parsing into an application-owned value such as `GHReadPolicy` makes the review
boundary explicit and testable; the raw model arguments still pass unchanged to
the fixed `gh` executable after authorization.

### Listener checks with `lsof`

`lsof` cannot be emulated truthfully from Bash.swift's pseudo-job table. A host
adapter can expose only the transcript-common listener check while rejecting
general host process discovery:

```swift
func allowedListenerQuery(_ arguments: [String]) -> Bool {
    guard arguments.count == 3,
          arguments[0] == "-nP",
          arguments[2] == "-sTCP:LISTEN",
          arguments[1].hasPrefix("-iTCP:")
    else { return false }

    let port = arguments[1].dropFirst("-iTCP:".count)
    return Int(port).map { (1...65_535).contains($0) } ?? false
}
```

If a product only needs to know whether one of its own servers is listening,
an application-native socket probe is narrower than exposing `lsof` at all.

### Result and resource limits

The app-owned executor should also:

- cap stdout and stderr independently and report truncation;
- enforce a wall-clock deadline and terminate the child on cancellation;
- close stdin after writing the provided bytes;
- return the actual termination status in `CommandResult.exitCode`;
- avoid logging forwarded environment values or unredacted process output;
- serialize or cap concurrent adapters when model calls could exhaust host
  processes.

Adapter denial and executor failure both return status 126 through
`registerHostCommand`. A successfully launched tool should preserve its own
exit code, including nonzero statuses used for ordinary query results.

## Policy tests

Test the policy closure separately from process creation. At minimum cover the
exact allowed vector, lookalike flags, an extra operand, a disallowed virtual
directory, withheld environment keys, binary stdin/output, executor failure,
and each alias. The Bash.swift integration suite demonstrates the boundary in
`SessionIntegrationTests.hostCommandAdaptersRequireAuthorizationAndExplicitEnvironmentForwarding`.
