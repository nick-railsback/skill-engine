#!/usr/bin/env python3
"""Dogfood-corpus pin staleness lint.

Reads the named source's `lifecycle.last_checked_sha` out of a
`source-paths.json`, runs `git rev-list --count <sha>..HEAD` from the repo
root, and prints how many commits behind HEAD the pin is.

Report-only: always exits 0. There is no gate mode; this tool measures and
prints, it does not fail a build. Wired into `scripts/ci-local.sh`'s
`run_examples` for this repo's own `skill-engine-context` dogfood instance —
scoped to that one source, not a generic per-source staleness lint over any
contextualizer's pins.

Usage:
    python3 dogfood_pin_staleness.py <source-paths.json path> \
        [--source-id nick-railsback-skill-engine]

Exit codes: always 0.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

DEFAULT_SOURCE_ID = "nick-railsback-skill-engine"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Dogfood-corpus pin staleness lint (report-only)."
    )
    parser.add_argument("source_paths_json", type=Path)
    parser.add_argument("--source-id", default=DEFAULT_SOURCE_ID,
                         help=f"Source id to check. Default {DEFAULT_SOURCE_ID}.")
    args = parser.parse_args(argv)

    if not args.source_paths_json.is_file():
        print(f"[N/A]  dogfood-pin-staleness: {args.source_paths_json} not found")
        return 0

    try:
        data = json.loads(args.source_paths_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"[N/A]  dogfood-pin-staleness: {args.source_paths_json} did not parse as JSON ({exc})")
        return 0

    sources = data.get("sources", []) if isinstance(data, dict) else []
    entry = next((s for s in sources if isinstance(s, dict) and s.get("id") == args.source_id), None)
    if entry is None:
        print(f"[N/A]  dogfood-pin-staleness: source-id {args.source_id!r} not found in {args.source_paths_json}")
        return 0

    sha = (entry.get("lifecycle") or {}).get("last_checked_sha")
    if not sha:
        print(f"[N/A]  dogfood-pin-staleness: {args.source_id} has no lifecycle.last_checked_sha recorded")
        return 0

    repo_root = args.source_paths_json.resolve().parent
    proc = subprocess.run(
        ["git", "rev-list", "--count", f"{sha}..HEAD"],
        cwd=str(repo_root),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip().isdigit():
        print(f"[N/A]  dogfood-pin-staleness: git rev-list against {sha[:12]} failed ({proc.stderr.strip()})")
        return 0

    n = int(proc.stdout.strip())
    # Commit count comes first in the printed line, ahead of the truncated
    # SHA — a caller scraping "the first digit run in stdout" for the metric
    # must not pick up a SHA-prefix digit instead (navigator_budget.py's own
    # header comment names this exact footgun; same fix, byte count before
    # path there, commit count before SHA here).
    print(f"[INFO] dogfood-pin-staleness: {n} commit(s) behind HEAD — {args.source_id} pinned at {sha[:12]}")
    return 0  # report-only: never gates the caller's exit code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
