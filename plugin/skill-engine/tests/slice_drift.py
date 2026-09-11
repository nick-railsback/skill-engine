#!/usr/bin/env python3
"""Report, per declared monorepo slice, whether anything under that slice's
own path patterns differs between two commits already resident in one cache
directory — so REFRESH's Phase 1 can promote only the slices that actually
moved instead of re-reading an entire monorepo on every run.

Matching reuses git's own gitignore plumbing (`git check-ignore`) rather
than hand-rolling glob semantics in Python, and rather than pathspec
matching, which answers a different question. `slice_paths` is fed to
`git sparse-checkout set --no-cone`, which is GITIGNORE matching: a pattern
that matches a directory pulls in that directory's whole subtree, a
slashless pattern matches at any depth, and a `!` entry carves a subtree
back out. Pathspec matching (`:(glob)`, fnmatch with FNM_PATHNAME) does
none of those. Matching with the wrong engine does not merely miscount: a
slice declaring `packages/billing/*` is checked out WITH its nested files
and then reports `changed: false` when one of them changes, so it is
crawled once and never refreshed again, silently.

The engine consulted is `git sparse-checkout set --no-cone` ITSELF, run
against a disposable scratch index holding the candidate paths, not a
second implementation of its rules. `git check-ignore` is close but not
equivalent: it enforces gitignore's "a file cannot be re-included when a
parent directory is excluded" rule, which sparse-checkout does not, so a
slice declaring `["packages/**", "!packages/vendor/**"]` would wrongly
count packages/vendor/v.py as its own. Asking the real engine costs one
`git init` plus one index write per slice and cannot drift from what the
checkout does, because it is what the checkout does.

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
import tempfile

EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def _run(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, check=False)


def _matched_subset(patterns: list[str], candidates: list[str]) -> list[str]:
    """The subset of `candidates` a `--no-cone` checkout of `patterns` carries.

    Asks git's own sparse-checkout machinery rather than reimplementing
    it: a scratch repository is given an index holding exactly the
    candidate paths (all pointing at one empty blob -- no content is
    needed to answer a pattern question), the patterns are applied with
    `sparse-checkout set --no-cone`, and the entries git did NOT mark
    skip-worktree are the ones inside the slice.

    Nothing here touches the cache. The scratch repository is disposable
    and is the only thing written to.
    """
    if not candidates or not patterns:
        return []
    with tempfile.TemporaryDirectory(prefix="slice-drift-match-") as scratch:
        init = _run(["git", "init", "-q", scratch])
        if init.returncode != 0:
            sys.stderr.write(init.stderr)
            sys.exit(1)

        blob = subprocess.run(
            ["git", "-C", scratch, "hash-object", "-w", "-t", "blob", "--stdin"],
            input=b"", capture_output=True, check=False,
        )
        if blob.returncode != 0:
            sys.stderr.write(blob.stderr.decode(errors="replace"))
            sys.exit(1)
        empty_blob = blob.stdout.decode().strip()

        # -z, so a path carrying a newline or a quote cannot desynchronize
        # the record stream the way a line-oriented --index-info would.
        index_info = b"".join(
            f"100644 {empty_blob}\t{path}\0".encode() for path in candidates
        )
        add = subprocess.run(
            ["git", "-C", scratch, "update-index", "-z", "--add", "--index-info"],
            input=index_info, capture_output=True, check=False,
        )
        if add.returncode != 0:
            sys.stderr.write(add.stderr.decode(errors="replace"))
            sys.exit(1)

        # --skip-checks suppresses the "this looks like a leading-slash
        # mistake" advice on patterns the maintainer meant literally. It
        # is git >= 2.36; without it the same call still works, so an
        # older git falls back rather than failing.
        applied = _run(["git", "-C", scratch, "sparse-checkout", "set",
                        "--no-cone", "--skip-checks", *patterns])
        if applied.returncode != 0:
            applied = _run(["git", "-C", scratch, "sparse-checkout", "set",
                            "--no-cone", *patterns])
        if applied.returncode != 0:
            sys.stderr.write(applied.stderr)
            sys.exit(1)

        listed = subprocess.run(
            ["git", "-C", scratch, "ls-files", "-v", "-z"],
            capture_output=True, check=False,
        )
        if listed.returncode != 0:
            sys.stderr.write(listed.stderr.decode(errors="replace"))
            sys.exit(1)
        # Each record is "<tag> <path>". A tag of "S" is skip-worktree,
        # i.e. outside the sparse patterns; everything else is inside.
        inside = {
            record[2:].decode(errors="replace")
            for record in listed.stdout.split(b"\0")
            if record and record[:1] != b"S"
        }

    return [path for path in candidates if path in inside]


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


def _diff_names(cache_dir: str, old: str, new: str) -> list[str]:
    """Every path differing between two commits, unfiltered.

    No pathspec: which of these paths belongs to a slice is decided by
    `_matched_subset`, with the engine sparse-checkout itself uses.
    """
    result = _run(["git", "-C", cache_dir, "diff", "--name-only", "-z", old, new])
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

    # The three path sets are the same for every slice -- only the pattern
    # filter differs -- so they are computed once rather than once per
    # slice.
    all_old = _diff_names(args.cache_dir, EMPTY_TREE, args.old)
    all_new = _diff_names(args.cache_dir, EMPTY_TREE, args.new)
    all_changed = _diff_names(args.cache_dir, args.old, args.new)

    results = []
    for slice_id, paths in slices:
        existed_old = bool(_matched_subset(paths, all_old))
        existed_new = bool(_matched_subset(paths, all_new))
        changed_paths = sorted(_matched_subset(paths, all_changed))
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
