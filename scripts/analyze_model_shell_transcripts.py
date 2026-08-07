#!/usr/bin/env python3
"""Summarize structured shell calls in local Codex and Claude transcripts.

The script reads tool-call records only. It intentionally ignores prose and tool
output so commands quoted by users or printed by a command are not counted.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import pathlib
import re
import shlex
from typing import Any, Iterable


CODEX_TOOL_NAMES = {"exec_command", "shell", "local_shell_call"}
SEPARATORS = {";", "&&", "||", "|", "&"}
CONTROL_WORDS = {
    "!", "case", "do", "done", "elif", "else", "esac", "fi", "for",
    "function", "if", "in", "select", "then", "time", "until", "while",
}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
EXEC_COMMAND_CALL = re.compile(r"tools\.exec_command\s*\(")


def json_lines(path: pathlib.Path) -> Iterable[dict[str, Any]]:
    try:
        with path.open(errors="replace") as stream:
            for line in stream:
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(value, dict):
                    yield value
    except OSError:
        return


def balanced_json_object(source: str, offset: int) -> dict[str, Any] | None:
    start = source.find("{", offset)
    if start < 0:
        return None
    depth = 0
    quoted = False
    escaped = False
    for index in range(start, len(source)):
        character = source[index]
        if quoted:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                quoted = False
            continue
        if character == '"':
            quoted = True
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                try:
                    value = json.loads(source[start:index + 1])
                except json.JSONDecodeError:
                    return None
                return value if isinstance(value, dict) else None
    return None


def command_from_arguments(arguments: Any) -> str | None:
    if isinstance(arguments, str):
        try:
            arguments = json.loads(arguments)
        except json.JSONDecodeError:
            return None
    if not isinstance(arguments, dict):
        return None
    command = arguments.get("cmd") or arguments.get("command") or arguments.get("cmdline")
    if isinstance(command, str):
        return command
    if isinstance(command, list):
        values = [str(value) for value in command]
        if len(values) >= 3 and os.path.basename(values[0]) in {"bash", "sh", "zsh"} and values[1] in {"-c", "-lc"}:
            return values[2]
        return shlex.join(values)
    return None


def codex_calls(path: pathlib.Path) -> Iterable[tuple[str, str, str]]:
    model = "unknown-openai"
    if path.suffix == ".json":
        try:
            document = json.loads(path.read_text(errors="replace"))
        except (OSError, json.JSONDecodeError):
            return
        for item in document.get("items", []):
            if not isinstance(item, dict) or item.get("type") != "local_shell_call":
                continue
            action = item.get("action", {})
            command = command_from_arguments(action)
            if command:
                yield model, "legacy local_shell_call", command
        return

    for record in json_lines(path):
        payload = record.get("payload")
        if record.get("type") == "turn_context" and isinstance(payload, dict):
            candidate = payload.get("model")
            if isinstance(candidate, str):
                model = candidate
            continue
        if record.get("type") != "response_item" or not isinstance(payload, dict):
            continue
        payload_type = payload.get("type")
        name = payload.get("name")
        if payload_type == "function_call" and name in CODEX_TOOL_NAMES:
            command = command_from_arguments(payload.get("arguments"))
            if command:
                yield model, str(name), command
        elif payload_type == "custom_tool_call" and name == "exec":
            tool_input = payload.get("input")
            if not isinstance(tool_input, str):
                continue
            for match in EXEC_COMMAND_CALL.finditer(tool_input):
                arguments = balanced_json_object(tool_input, match.end())
                command = command_from_arguments(arguments)
                if command:
                    yield model, "exec wrapper", command


def claude_calls(path: pathlib.Path) -> Iterable[tuple[str, str, str]]:
    for record in json_lines(path):
        message = record.get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        model = message.get("model") if isinstance(message.get("model"), str) else "unknown-anthropic"
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict) or item.get("type") != "tool_use":
                continue
            if str(item.get("name", "")).lower() != "bash":
                continue
            tool_input = item.get("input")
            if not isinstance(tool_input, dict):
                continue
            command = tool_input.get("command")
            if isinstance(command, str):
                yield model, "Bash", command


def without_heredoc_bodies(command: str) -> str:
    """Keep heredoc command lines while removing their non-shell payloads."""
    kept: list[str] = []
    delimiters: list[tuple[str, bool]] = []
    for line in command.splitlines():
        if delimiters:
            delimiter, strips_tabs = delimiters[0]
            candidate = line.lstrip("\t") if strips_tabs else line
            if candidate == delimiter:
                delimiters.pop(0)
            continue
        kept.append(line)
        for match in re.finditer(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", line):
            delimiters.append((match.group(3), bool(match.group(1))))
    return "\n".join(kept)


def shell_tokens(command: str) -> list[str]:
    # Newlines delimit commands in shell scripts. Quoted multiline strings can
    # produce a little noise, but structured calls avoid the much larger prose
    # and output contamination found in raw transcript searches.
    prepared = without_heredoc_bodies(command).replace("\n", " ; ")
    try:
        lexer = shlex.shlex(prepared, posix=True, punctuation_chars=";&|<>()")
        lexer.whitespace_split = True
        lexer.commenters = ""
        return list(lexer)
    except ValueError:
        return []


def command_names(command: str) -> list[str]:
    tokens = shell_tokens(command)
    names: list[str] = []
    expecting_command = True
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in SEPARATORS or token in {"(", ")"}:
            expecting_command = True
            index += 1
            continue
        if not expecting_command:
            index += 1
            continue
        if token in CONTROL_WORDS or token.startswith(("<", ">")) or ASSIGNMENT.match(token):
            index += 1
            continue
        if token == "env":
            names.append("env")
            index += 1
            while index < len(tokens) and (ASSIGNMENT.match(tokens[index]) or tokens[index].startswith("-")):
                index += 1
            expecting_command = True
            continue
        names.append(os.path.basename(token))
        expecting_command = False
        index += 1
    return names


SYNTAX_PATTERNS = {
    "pipeline": re.compile(r"(?<!\|)\|(?!\|)"),
    "and-chain": re.compile(r"&&"),
    "or-chain": re.compile(r"\|\|"),
    "semicolon": re.compile(r";"),
    "multiline": re.compile(r"\n"),
    "stdout-redirection": re.compile(r"(?<![0-9>])>{1,2}(?![>&])"),
    "stderr-redirection": re.compile(r"(?:^|\s)2>{1,2}"),
    "stderr-merge": re.compile(r"2>&1"),
    "command-substitution": re.compile(r"\$\("),
    "process-substitution": re.compile(r"[<>]\("),
    "heredoc": re.compile(r"<<-?\s*['\"]?[A-Za-z_]"),
    "here-string": re.compile(r"<<<"),
    "variable-expansion": re.compile(r"\$(?:\{|[A-Za-z_?!#@*0-9])"),
    "assignment-prefix": re.compile(r"(?:^|[;&|]\s*)[A-Za-z_][A-Za-z0-9_]*=[^\s;&|]+\s+[^\s;&|]+"),
    "glob": re.compile(r"(?<!\\)[*?[]"),
    "double-bracket-test": re.compile(r"(?:^|\s)\[\[\s"),
    "single-bracket-test": re.compile(r"(?:^|\s)\[\s"),
    "for-loop": re.compile(r"(?:^|[;\n]\s*)for\s"),
    "if-block": re.compile(r"(?:^|[;\n]\s*)if\s"),
    "brace-expansion": re.compile(r"\{[^{}]*(?:,|\.\.)[^{}]*\}"),
    "background-job": re.compile(r"(?<![>&])&(?![>&])"),
}


def files_under(roots: Iterable[pathlib.Path], suffixes: set[str]) -> list[pathlib.Path]:
    result: set[pathlib.Path] = set()
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if path.is_file() and path.suffix in suffixes:
                result.add(path)
    return sorted(result)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-root", action="append", type=pathlib.Path, default=[])
    parser.add_argument("--claude-root", action="append", type=pathlib.Path, default=[])
    parser.add_argument("--exclude-session", action="append", default=[])
    parser.add_argument("--top", type=int, default=50)
    args = parser.parse_args()

    codex_roots = args.codex_root or [pathlib.Path.home() / ".codex/sessions", pathlib.Path.home() / ".codex/archived_sessions"]
    claude_roots = args.claude_root or [pathlib.Path.home() / ".claude/projects"]
    excluded = set(args.exclude_session)

    providers: dict[str, dict[str, Any]] = {
        "openai": {"files": 0, "calls": 0, "models": collections.Counter(), "shapes": collections.Counter(), "commands": collections.Counter(), "syntax": collections.Counter()},
        "anthropic": {"files": 0, "calls": 0, "models": collections.Counter(), "shapes": collections.Counter(), "commands": collections.Counter(), "syntax": collections.Counter()},
    }

    def record(provider: str, model: str, shape: str, command: str) -> None:
        stats = providers[provider]
        stats["calls"] += 1
        stats["models"][model] += 1
        stats["shapes"][shape] += 1
        scrubbed = without_heredoc_bodies(command)
        for name in command_names(scrubbed):
            stats["commands"][name] += 1
        for syntax, pattern in SYNTAX_PATTERNS.items():
            if pattern.search(scrubbed):
                stats["syntax"][syntax] += 1

    for path in files_under(codex_roots, {".json", ".jsonl"}):
        if any(identifier in path.name for identifier in excluded):
            continue
        providers["openai"]["files"] += 1
        for call in codex_calls(path):
            record("openai", *call)
    for path in files_under(claude_roots, {".jsonl"}):
        if any(identifier in path.name for identifier in excluded):
            continue
        providers["anthropic"]["files"] += 1
        for call in claude_calls(path):
            record("anthropic", *call)

    output: dict[str, Any] = {}
    for provider, stats in providers.items():
        output[provider] = {
            "files": stats["files"],
            "calls": stats["calls"],
            "models": stats["models"].most_common(),
            "tool_shapes": stats["shapes"].most_common(),
            "commands": stats["commands"].most_common(args.top),
            "syntax": stats["syntax"].most_common(),
        }
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
