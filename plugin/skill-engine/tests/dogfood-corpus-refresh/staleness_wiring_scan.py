#!/usr/bin/env python3
"""Black-box, read-only check for a report-only staleness/drift script wired
into scripts/ci-local.sh's run_examples function.

Nothing pins the eventual script's name or location ahead of time, so this
does not hardcode one. Instead it:

  1. Extracts the run_examples() function body from ci-local.sh.
  2. Searches it for an invocation (a `python3 ...` or `bash ...` line,
     with shell line-continuations joined) whose path token is under
     plugin/skill-engine/tests/ and whose own name plausibly names a
     staleness/pin/drift concern (case-insensitive substring match on
     "stale", "staleness", "drift", or "pin").
  3. If found, runs that exact command (verbatim, via a shell, from the
     repo root — the same invocation ci-local.sh itself would run) and
     records its exit code and stdout.

Emits one JSON object to stdout describing what it found (and, if it ran
something, what happened). Read-only over ci-local.sh itself; the
discovered command is executed only if found, and only as ci-local.sh
would already run it as part of `make ci-local` / `bash scripts/ci-local.sh
examples`.

Usage:
    python3 staleness_wiring_scan.py <ci_local_sh_path> --repo-root <path>

Exit code is always 0 — data-gathering only; the caller applies its own
assertions to the emitted JSON.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

FUNCTION_START_RE = re.compile(r"^run_examples\(\)\s*\{")
FUNCTION_END_RE = re.compile(r"^\}")

INVOCATION_RE = re.compile(
    r"\b(python3|bash)\s+\S*plugin/skill-engine/tests/\S*"
    r"(stale|staleness|drift|pin)\S*",
    re.IGNORECASE,
)


def extract_run_examples_body(ci_local_text: str) -> list[str]:
    lines = ci_local_text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if FUNCTION_START_RE.match(line):
            start = i
            break
    if start is None:
        return []
    for j in range(start, len(lines)):
        if FUNCTION_END_RE.match(lines[j]):
            return lines[start : j + 1]
    return lines[start:]


def find_invocation(body_lines: list[str]) -> tuple[str, int] | None:
    """Returns (matched_line, index) for the first line in body_lines whose
    text matches INVOCATION_RE, or None."""
    for idx, line in enumerate(body_lines):
        if INVOCATION_RE.search(line):
            return line, idx
    return None


def join_continuation(body_lines: list[str], start_idx: int) -> str:
    """Joins a shell line-continuation (trailing backslash) starting at
    start_idx into one logical command string."""
    parts: list[str] = []
    i = start_idx
    while i < len(body_lines):
        stripped = body_lines[i].rstrip()
        if stripped.endswith("\\"):
            parts.append(stripped[:-1].strip())
            i += 1
        else:
            parts.append(stripped.strip())
            break
    return " ".join(p for p in parts if p)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ci_local_sh", type=Path)
    parser.add_argument("--repo-root", type=Path, required=True)
    args = parser.parse_args(argv)

    if not args.ci_local_sh.is_file():
        print(json.dumps({"error": f"not a file: {args.ci_local_sh}"}))
        return 0

    text = args.ci_local_sh.read_text(encoding="utf-8", errors="replace")
    body_lines = extract_run_examples_body(text)

    result: dict = {
        "run_examples_found": bool(body_lines),
        "wired": False,
        "matched_line": None,
        "command": None,
        "ran": False,
        "exit_code": None,
        "stdout": None,
        "stdout_has_digit": False,
    }

    if not body_lines:
        print(json.dumps(result))
        return 0

    found = find_invocation(body_lines)
    if found is None:
        print(json.dumps(result))
        return 0

    matched_line, idx = found
    command = join_continuation(body_lines, idx)
    result["wired"] = True
    result["matched_line"] = matched_line.strip()
    result["command"] = command

    proc = subprocess.run(
        command,
        shell=True,
        cwd=str(args.repo_root),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    result["ran"] = True
    result["exit_code"] = proc.returncode
    result["stdout"] = proc.stdout[:2000]
    result["stdout_has_digit"] = bool(re.search(r"\d", proc.stdout))

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
