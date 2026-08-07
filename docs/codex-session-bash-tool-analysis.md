# Model Shell Tool Transcript Analysis

Snapshot: 2026-08-07

This analysis mines structured shell-tool calls from local Codex and Claude transcripts and compares the observed command/syntax surface with Bash.swift. It supersedes the Codex-only snapshot from 2026-05-09.

The analysis is reproducible with:

```bash
python3 scripts/analyze_model_shell_transcripts.py \
  --exclude-session 019fdcfe-7026-7a30-a66f-b164fe52b630
```

The extractor reads tool calls only. It excludes assistant/user prose and command output, removes here-document bodies before tokenizing shell commands, understands legacy and current Codex formats (including the newer JavaScript `exec` wrapper), and reads Claude `Bash` tool calls with their model identifiers.

## Extraction Scope

| Provider | Transcript files | Structured shell calls |
| --- | ---: | ---: |
| OpenAI / Codex | 3,762 | 139,616 |
| Anthropic / Claude | 149 | 10,002 |

The files are local snapshots rather than a controlled benchmark corpus. Counts reflect this user's mix of projects and tasks, and one tool call can contain several pipelines or chained commands.

### Models represented

| Provider | Model | Shell calls |
| --- | --- | ---: |
| OpenAI | `gpt-5.5` | 92,950 |
| OpenAI | `gpt-5.4` | 19,079 |
| OpenAI | `gpt-5.3-codex` | 11,231 |
| OpenAI | `gpt-5.6-sol` | 7,648 |
| OpenAI | other/unknown | 8,708 |
| Anthropic | `claude-opus-5` | 6,333 |
| Anthropic | `claude-fable-5` | 2,148 |
| Anthropic | `claude-sonnet-5` | 784 |
| Anthropic | `claude-opus-4-8` | 737 |

### Codex tool-call generations

| Shape | Calls |
| --- | ---: |
| `exec_command` | 128,814 |
| JavaScript `exec` wrapper containing `tools.exec_command(...)` | 5,965 |
| older `shell` tool | 4,661 |
| legacy `local_shell_call` | 176 |

The current API still ultimately supplies one shell command string, so Bash.swift's `run(_:)` shape remains aligned with model usage.

## Command Usage

The following counts are command occurrences after splitting pipelines and chains. They are useful for prioritization, not workload comparisons between providers.

### Core commands already covered

| Command | OpenAI | Anthropic | Takeaway |
| --- | ---: | ---: | --- |
| `sed` | 63,450 | 1,589 | Codex's dominant bounded-file-reading/edit inspection tool. |
| `rg` | 24,270 | below top 100 | Strongly OpenAI-weighted. |
| `grep` | 138 | 6,746 | Strongly Anthropic-weighted; its option surface matters. |
| `nl` | 9,033 | below top 100 | OpenAI frequently asks for numbered source excerpts. |
| `head` | 3,768 | 5,347 | Both providers aggressively bound output. |
| `find` | 3,778 | 375 | Both providers use repository inventory and exclusion expressions. |
| `echo` | 780 | 5,611 | Claude uses many chained status/section commands. |
| `cd` | 895 | 2,905 | Claude changes directory inside calls more often. |
| `cat` | 2,699 | 957 | Common direct file read and pipeline source. |
| `ls` | 2,813 | 952 | Common initial reconnaissance. |
| `jq` | 3,539 | below top 100 | OpenAI frequently inspects structured output. |
| `sort` | 2,116 | 380 | Frequently stabilizes inventory/search output. |
| `curl` | 1,827 | 913 | Important, but remains governed by Bash.swift network policy. |

Optional traits also align with frequent model calls: OpenAI used `git` 23,004 times and `python3` 2,323 times; Anthropic used `git` 2,445 times and `python3` 1,168 times.

### External developer tools

These calls are evidence for optional host-tool adapters, not for adding subprocess execution to the core in-process shell.

| Command | OpenAI | Anthropic |
| --- | ---: | ---: |
| `swift` | 6,414 | 841 |
| `bun` | 6,046 | 152 |
| `pnpm` | 3,314 | 923 |
| `gh` | 2,823 | 250 |
| `node` | 1,038 | 199 |
| `xcodebuild` | 743 | 198 |
| `xcrun` | 578 | 104 |
| `npx` | below top 100 | 315 |

## Shell Syntax Usage

Counts below are tool calls containing each form at least once.

| Syntax form | OpenAI | Anthropic | Bash.swift status |
| --- | ---: | ---: | --- |
| Pipeline | 35,776 | 7,175 | Supported and covered by transcript scenarios. |
| Glob | 16,532 | 2,944 | Supported; deeper bash glob grammar remains incomplete. |
| `&&` chain | 7,363 | 3,548 | Supported. |
| Semicolon separator | 4,345 | 4,422 | Supported. |
| Here-document | 2,626 | 1,213 | Supported; payloads are excluded from command counts. |
| Variable expansion | 2,304 | 1,351 | Practical forms supported. |
| Inline assignment | 1,899 | 632 | Supported. |
| stderr redirection (`2>`) | 1,261 | 4,535 | Supported. |
| stderr merge (`2>&1`) | 240 | 3,317 | Supported; especially important for Claude workflows. |
| `||` chain | 1,081 | 370 | Supported. |
| Command substitution | 549 | 622 | Supported. |
| `for` loop | 682 | 490 | Supported. |
| Single-bracket test | 220 | 106 | Supported in conditions and now as a standalone command. |
| Process substitution | 143 | 27 | Input `<(...)` supported; output `>(...)` is not. |
| Here-string (`<<<`) | 272 | 0 | Unsupported; the clearest remaining syntax candidate. |

Claude's much higher rate of `2>/dev/null`, `2>&1`, pipelines, and chained commands means isolated command unit tests are insufficient. Composite workflow tests now preserve representative patterns from both providers.

## Gaps Closed From This Snapshot

### Claude-style `grep`

A targeted scan found 3,674 literal Claude `grep` invocations. Frequent signatures included:

| Form | Observed Claude invocations |
| --- | ---: |
| `grep -v` | 588 |
| `grep -n` | 528 |
| `grep -n ... -A N` | 347 |
| `grep -rn` | 315 |
| `grep -rn ... --include=GLOB` | 122 |
| `grep -rn ... --include=GLOB --include=GLOB` | 27 |
| `grep -q` | 39 |

Bash.swift now covers recursive `-r`/`-R`, quiet `-q`, forced filename prefixes with `-H`, `-A`/`-B`/`-C` context, and repeatable `--include`, `--exclude`, and `--exclude-dir` filters. `ModelShellTranscriptScenariosTests` and the expanded integration test exercise the combined forms rather than each flag in isolation. The project-wide convention reserves a lone `-h` for help, so GNU grep's filename-suppression meaning is intentionally not adopted.

### Standalone `test` and `[`

OpenAI emitted `test` as a command 218 times. Bash.swift previously recognized `test`/`[` only while interpreting control-flow conditions. They are now registered built-ins, so model-generated chains such as `test -f file && ...`, `[ -d dir ] || ...`, `test -s file`, and negation work outside `if`/`while`.

### `find -not -path`

Claude commonly uses reconnaissance commands shaped like:

```bash
find . -type f -not -path '*/vendor/*' | head -200
```

The transcript scenario exposed that `find -path` reused shell pathname globbing, where `*` does not cross `/`. `find` path patterns do allow that, so matching now uses whole-path semantics and has a dedicated regression test.

## Prioritized Remaining Work

1. Add here-string (`<<<`) parsing and tests. It appeared in 272 OpenAI calls and remains a genuine language gap, though samples should be reviewed to separate scripts from patch-content noise.
2. Evaluate in-process `pgrep`/`pkill`/`lsof`-style introspection only against Bash.swift's pseudo-job model. Observed usage (`pgrep`: OpenAI 222, Anthropic 80; `lsof`: OpenAI 165, Anthropic 12) often targets host processes that an in-process shell cannot truthfully expose.
3. Extend `grep` only from concrete signatures. Remaining likely candidates include long options, binary-file behavior, and full GNU context-group separators; avoid broad GNU parity without transcript evidence.
4. Keep external runtimes/build tools out of core. If applications need `swift`, `bun`, `pnpm`, `node`, `gh`, or Xcode commands, design an explicit permissioned host-command adapter rather than weakening the jailed default.
5. Re-run the extractor periodically and retain provider/model splits. A single combined ranking would hide the important `rg` versus `grep` and redirection-style differences between OpenAI and Anthropic models.
