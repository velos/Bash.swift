# CLAUDE.md

Guidance for AI coding agents working in this repository.

## What this is

`Bash.swift` is an in-process, stateful bash-like shell for Swift apps. A `BashSession` runs shell command strings entirely inside the host process (no subprocesses) against a jailed filesystem root, returning structured `stdout`, `stderr`, and `exitCode`. It is beta software and explicitly **not** a hardened isolation boundary.

## Build and test

The package targets Apple platforms only (macOS 13+, iOS 16+, Mac Catalyst 16+, tvOS 16+, watchOS 9+). It does not build on Linux — the `Git` and `Python` traits depend on prebuilt `Clibgit2.xcframework` / `CPython.xcframework` binary targets, and other targets link Apple frameworks.

```bash
swift build --build-tests                          # default traits (all optional features off)
swift test                                         # core suite
swift test --traits Git,Python,SQLite,Secrets      # full suite with all optional features
```

Optional feature sets are gated by SwiftPM **traits** (`Git`, `Python`, `SQLite`, `Secrets`), all default-off. Feature code and tests are guarded with `#if <TraitName>` (e.g. `#if Python`). When touching trait-gated code, make sure the package still compiles with traits disabled *and* enabled — CI builds default traits and tests with all traits.

## Target layout

- `Sources/BashCore` — shell machinery: `ShellLexer`, `ShellParser`, `ShellExecutor`, `ArithmeticEvaluator`, `JobControl` (in `Core/`); permissions, execution limits, and the jailed `ShellPermissionedFileSystem` (in `Support/`). Filesystem primitives come from the external [`Workspace`](https://github.com/velos/Workspace) package.
- `Sources/BashTools` — built-in commands (file, text, data, compression, navigation, network), registered via `BashCompiledCommands`.
- `Sources/Bash` — the public `BashSession` API (session state, expansion, control flow, tool registration) plus `Exports.swift`, which re-exports everything so downstream code only needs `import Bash`.
- `Sources/BashGit`, `Sources/BashPython`, `Sources/BashSQLite`, `Sources/BashSecrets` — trait-gated feature targets (`BashGitFeature`, `BashPythonFeature`, etc. in `Package.swift`).
- `Sources/BashEvalRunner` — executable used to run the eval task banks in `docs/evals/`.
- `Example/BashExample.xcodeproj` — SwiftUI demo app wired to the local package.

## Tests

Tests use **swift-testing** (`import Testing`, `@Suite`/`@Test`/`#expect`), not XCTest. Shared helpers live in `Tests/BashTests/TestSupport.swift` — use `TestSupport.makeSession(...)` to get a `BashSession` in a temp root and clean up with `removeDirectory`. Trait-specific suites (`BashGitTests`, `BashPythonTests`, `BashSQLiteTests`, `BashSecretsTests`) are wrapped in `#if <Trait>` so they compile away when the trait is off.

## Conventions and gotchas

- Swift tools version 6.2 with strict concurrency; `BashSession` is an actor-style async API — new command implementations must be `Sendable`-clean.
- Built-in commands parse their own flags; match the option-handling style of neighboring commands in `Sources/BashTools/Commands/`.
- Network access is default-off and mediated by `ShellNetworkPolicy` plus an optional permission handler. Don't add commands that bypass it.
- Known behavior gaps vs real bash are tracked in `docs/command-parity-gaps.md` — update it when closing or discovering a gap.
- Eval profiles and the failure taxonomy for measuring shell parity live in `docs/evals/`.
- Release engineering for the binary artifacts (CPython, libgit2) lives in `scripts/` and `.github/workflows/publish-*.yml`; see `docs/cpython-apple-runtime.md` and `docs/libgit2-apple-runtime.md`.
