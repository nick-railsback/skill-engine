#!/usr/bin/env python3
"""Upstream-drift probe for git-managed sources.

Read-only: for every in-scope `kind: git-managed` source in a
`research/source-paths.json` (`status` in {confirmed, proposed},
`archived` not true, `lifecycle.state` not "removed" — the same
in-scope filter REFRESH's own pre-flight already applies), run one
`git ls-remote` against the source's `url` (its `branch` field when
present, else `HEAD`) and compare the result to the pinned
`lifecycle.last_checked_sha`. Writes one JSON array to stdout, never
writes to the input file, and never exits non-zero on account of any
individual source's probe result — report-only, not a gate.

Usage:
    python3 status_probe.py <source-paths.json>
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

IN_SCOPE_STATUSES = {"confirmed", "proposed"}


def is_in_scope(source: dict) -> bool:
    return (
        source.get("kind") == "git-managed"
        and source.get("status") in IN_SCOPE_STATUSES
        and source.get("archived") is not True
        and source.get("lifecycle", {}).get("state") != "removed"
    )


def probe(source: dict) -> dict:
    source_id = source["id"]
    url = source["url"]
    ref = source.get("branch") or "HEAD"
    recorded_sha = source.get("lifecycle", {}).get("last_checked_sha")

    result = subprocess.run(
        ["git", "ls-remote", "--", url, ref],
        capture_output=True,
        text=True,
    )
    lines = result.stdout.splitlines()
    live_sha = lines[0].split()[0] if lines and lines[0].split() else ""

    # Empty stdout is checked independently of the exit code: `git
    # ls-remote` against a nonexistent branch on a real repo exits 0
    # with nothing printed, not a nonzero exit.
    if result.returncode != 0 or not live_sha:
        error = (
            result.stderr.strip()
            or f"git ls-remote exited {result.returncode} with no matching ref"
        )
        return {
            "source_id": source_id,
            "state": "error",
            "recorded_sha": recorded_sha,
            "live_sha": None,
            "error": error,
        }

    if recorded_sha is None:
        state = "never_probed"
    elif recorded_sha == live_sha:
        state = "match"
    else:
        state = "mismatch"

    return {
        "source_id": source_id,
        "state": state,
        "recorded_sha": recorded_sha,
        "live_sha": live_sha,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_paths", type=Path)
    args = parser.parse_args(argv)

    data = json.loads(args.source_paths.read_text(encoding="utf-8"))
    sources = data.get("sources", [])

    results = [probe(s) for s in sources if is_in_scope(s)]
    json.dump(results, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
