#!/usr/bin/env python3
"""Report, per declared monorepo slice, whether anything under that slice's
own path patterns differs between two commits already resident in one cache
directory — so REFRESH's Phase 1 can promote only the slices that actually
moved instead of re-reading an entire monorepo on every run.

Matching reuses git's own pathspec plumbing (`git diff --name-only`) rather
than hand-rolling gitignore/sparse-checkout glob semantics in Python. Every
slice pattern is passed with the `:(glob)` pathspec magic prefix: git's
default (non-magic) pathspec matching does not distinguish a bare `*` from
`**` the way `git sparse-checkout --no-cone` does, and this script's
contract requires that distinction. `git diff` is used for every
pattern-matching call — never `git ls-tree`, which rejects `:(glob)`
outright.

Usage:
    python3 slice_drift.py <cache_dir> --old <sha> --new <sha> \
      --config <monorepo-config.json>

<cache_dir> is a single clone's own working directory (the one holding
.git) with both <old> and <new> resolvable in it. --config is a
monorepo-config.json; every slice across every entry in its top-level
`monorepos[]` array is reported on, flattened into one list (a slice_id
repeated across entries keeps its first occurrence).

Prints a bare JSON array to stdout, one object per slice:
`{"slice_id": ..., "changed": <bool>, "changed_paths": [<sorted paths>]}`.
`changed_paths` includes deletions and renames, not only modifications — a
path present in one tree and absent in the other differs exactly as much as
one that is merely edited. A slice whose patterns match no path in either
tree instead carries `"changed": false, "changed_paths": [], "notice":
"..."` naming the slice.

Stdlib-only. Read-only against the cache. Exits 0 on success; exits 1 with
a stderr message naming the offending value when --old or --new is not
resolvable in <cache_dir>, or when a git invocation fails after that
resolvability check already passed.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys

EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def _run(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, check=False)


def _collect_slices(config: dict) -> list[tuple[str, list[str]]]:
    slices: list[tuple[str, list[str]]] = []
    seen: set[str] = set()
    for monorepo in config.get("monorepos", []):
        for slice_decl in monorepo.get("slices", []):
            slice_id = slice_decl["id"]
            if slice_id in seen:
                continue
            seen.add(slice_id)
            slices.append((slice_id, slice_decl["paths"]))
    return slices


def _resolvable(cache_dir: str, sha: str, flag: str) -> bool:
    result = _run(["git", "-C", cache_dir, "rev-parse", "--verify", "--quiet", f"{sha}^{{commit}}"])
    if result.returncode != 0 or not result.stdout.strip():
        print(f"error: --{flag} SHA '{sha}' is not resolvable in {cache_dir}", file=sys.stderr)
        return False
    return True


def _diff_names(cache_dir: str, old: str, new: str, pathspecs: list[str]) -> list[str]:
    result = _run(["git", "-C", cache_dir, "diff", "--name-only", "-z", old, new, "--", *pathspecs])
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        sys.exit(1)
    return [p for p in result.stdout.split("\0") if p]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("cache_dir")
    parser.add_argument("--old", required=True)
    parser.add_argument("--new", required=True)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

    with open(args.config, encoding="utf-8") as fh:
        config = json.load(fh)
    slices = _collect_slices(config)

    # Check both before proceeding, so a simultaneously-bad --old and --new
    # still names one of them rather than crashing on the first subprocess
    # call with no diagnostic.
    old_ok = _resolvable(args.cache_dir, args.old, "old")
    new_ok = _resolvable(args.cache_dir, args.new, "new")
    if not old_ok or not new_ok:
        sys.exit(1)

    results = []
    for slice_id, paths in slices:
        pathspecs = [":(glob)" + p for p in paths]
        existed_old = bool(_diff_names(args.cache_dir, EMPTY_TREE, args.old, pathspecs))
        existed_new = bool(_diff_names(args.cache_dir, EMPTY_TREE, args.new, pathspecs))
        changed_paths = sorted(_diff_names(args.cache_dir, args.old, args.new, pathspecs))
        if not existed_old and not existed_new:
            results.append({
                "slice_id": slice_id,
                "changed": False,
                "changed_paths": [],
                "notice": f"slice '{slice_id}' patterns match no path in either commit",
            })
        else:
            results.append({
                "slice_id": slice_id,
                "changed": bool(changed_paths),
                "changed_paths": changed_paths,
            })

    print(json.dumps(results))
    sys.exit(0)


if __name__ == "__main__":
    main()
