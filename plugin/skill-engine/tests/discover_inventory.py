#!/usr/bin/env python3
"""Deterministic pre-flight corpus-shape inventory for DISCOVER.

Computes, for a single `git-managed` source, the four signals `§
Discovering essence` today re-derives in-window at full token cost every
run: a file count keyed by directory (rolled up past depth 3), the 20
largest files by byte size, which canonical doc-root paths exist at the
source root, and — when a prior checked SHA is known and a local git
checkout is available — a per-file change summary since that SHA. The
script is pure and read-only: it never writes anywhere. Persisting the
result under `research/` is entirely the caller's decision (see
`discover/references/cache-and-clone.md` pre-flight step 7), not this
script's.

Two independent input modes select what's inventoried:

  1. Positional directory mode (what the frozen test oracle exercises):

         discover_inventory.py <source-root> [--last-checked-sha <sha>]

     Walks the real local directory at `<source-root>` with `os.walk`.
     `.git/` internals never contribute to any of the three tree-shape
     signals — an identical tree reports byte-identical output whether
     or not it's a git working copy. `since_last_check` is computed via
     `git log --numstat` only when `--last-checked-sha` was supplied
     *and* `<source-root>/.git` exists; otherwise the key is omitted
     from the output entirely (never null, never a placeholder).

  2. Additive `--tree-json <file>` mode (the real no-local-cache
     production path; not exercised by the frozen oracle — see this
     chunk's plan.md § Risks): reads a JSON array of
     `{"path", "bytes", "type": "blob"|"tree"}` — the shape
     `gh api .../git/trees/<ref>?recursive=1` returns, modulo key
     renaming — and computes the three tree-shape signals from it with
     no filesystem access at all. Mutually exclusive with the
     positional `<source-root>`.

`--since-json <file>` is independent of which primary mode is active:
when supplied, its content is emitted verbatim as `since_last_check`,
overriding any local-git-log computation. This is how the `--tree-json`
mode gets a since-last-check signal, since it has no local `.git` to
query (see cache-and-clone.md step 7's `gh api compare` fetch).

Output: exactly one JSON object on stdout, nothing else, exit 0 on
success. Exit non-zero with a stderr diagnostic if `<source-root>` does
not exist (positional mode) or a required input file can't be read.

Usage:
    python3 discover_inventory.py <source-root> [--last-checked-sha <sha>]
    python3 discover_inventory.py --tree-json <file> [--since-json <file>]

Exit codes: 0 = success. 1 = source root missing, input file unreadable,
or malformed arguments.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# Single source of truth for the two calibration constants criteria 2 and
# 3 fix: the directory-rollup depth ceiling and the largest-files cap.
DEPTH_CEILING = 3
LARGEST_FILES_LIMIT = 20

README_RE = re.compile(r"^readme", re.IGNORECASE)
CHANGELOG_RE = re.compile(r"^changelog", re.IGNORECASE)
DOC_DIR_NAMES = {"docs", "doc"}

GIT_DIRNAME = ".git"


def _dir_key(rel_path: str) -> str:
    """The `file_counts_by_dir` key for a file at `rel_path` (posix-style,
    relative to the source root): its containing directory's path, rolled
    up to at most `DEPTH_CEILING` segments. `""` for a root-level file."""
    parts = rel_path.split("/")
    dir_parts = parts[:-1]
    if len(dir_parts) > DEPTH_CEILING:
        dir_parts = dir_parts[:DEPTH_CEILING]
    return "/".join(dir_parts)


def compute_dir_counts(files: list[tuple[str, int]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for rel_path, _bytes in files:
        key = _dir_key(rel_path)
        counts[key] = counts.get(key, 0) + 1
    return counts


def compute_largest_files(files: list[tuple[str, int]]) -> list[dict]:
    ranked = sorted(files, key=lambda t: t[1], reverse=True)[:LARGEST_FILES_LIMIT]
    return [{"path": path, "bytes": size} for path, size in ranked]


def _is_doc_file_name(name: str) -> bool:
    return bool(README_RE.match(name) or CHANGELOG_RE.match(name))


def _is_doc_dir_name(name: str) -> bool:
    return name.lower() in DOC_DIR_NAMES


def walk_directory(root: Path) -> list[tuple[str, int]]:
    """Every file under `root`, as (posix relative path, byte size),
    with any `.git/` subtree excluded entirely — at any depth, not only
    at the root — from the walk."""
    files: list[tuple[str, int]] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != GIT_DIRNAME]
        for filename in filenames:
            full = Path(dirpath) / filename
            try:
                size = full.stat().st_size
            except OSError:
                continue
            rel = full.relative_to(root).as_posix()
            files.append((rel, size))
    return files


def compute_doc_roots_dir(root: Path) -> list[str]:
    roots: list[str] = []
    for entry in sorted(os.listdir(root)):
        full = root / entry
        if full.is_dir():
            if _is_doc_dir_name(entry):
                roots.append(entry)
        elif _is_doc_file_name(entry):
            roots.append(entry)
    return roots


def compute_doc_roots_tree(entries: list[dict]) -> list[str]:
    roots: list[str] = []
    for entry in entries:
        path = entry.get("path", "")
        if not path or "/" in path:
            continue  # top-level only, no recursion
        name = path
        if entry.get("type") == "tree":
            if _is_doc_dir_name(name):
                roots.append(name)
        elif _is_doc_file_name(name):
            roots.append(name)
    return roots


def compute_since_last_check_git(root: Path, last_checked_sha: str) -> dict | None:
    """`since_last_check` via a real local `git log --numstat`, or `None`
    when `root` is not itself a local git working tree or the git calls
    fail for any reason (never raises — the caller treats `None` as
    "omit the key")."""
    if not (root / GIT_DIRNAME).exists():
        return None
    try:
        head_sha = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        log_output = subprocess.run(
            ["git", "-C", str(root), "log", "--numstat",
             "--pretty=format:%H", f"{last_checked_sha}..HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, OSError):
        return None

    changes: dict[str, int] = {}
    order: list[str] = []
    for line in log_output.splitlines():
        fields = line.split("\t")
        if len(fields) != 3:
            continue  # commit-hash line, blank separator, or malformed row
        added_s, deleted_s, path = fields
        added = int(added_s) if added_s.isdigit() else 0
        deleted = int(deleted_s) if deleted_s.isdigit() else 0
        if path not in changes:
            changes[path] = 0
            order.append(path)
        changes[path] += added + deleted

    return {
        "from_sha": last_checked_sha,
        "to_sha": head_sha,
        "files": [{"path": path, "changes": changes[path]} for path in order],
    }


def _read_json(path_str: str) -> object:
    return json.loads(Path(path_str).read_text(encoding="utf-8"))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Deterministic pre-flight corpus-shape inventory for DISCOVER."
    )
    parser.add_argument("source_root", nargs="?", default=None,
                         help="Local directory to walk. Mutually exclusive with --tree-json.")
    parser.add_argument("--last-checked-sha", dest="last_checked_sha", default=None,
                         help="Prior lifecycle.last_checked_sha; enables since_last_check "
                         "when <source-root> is a real local git checkout.")
    parser.add_argument("--tree-json", dest="tree_json", default=None,
                         help="JSON array of {path, bytes, type} tree entries in place of "
                         "walking a local directory.")
    parser.add_argument("--since-json", dest="since_json", default=None,
                         help="JSON object emitted verbatim as since_last_check, overriding "
                         "any local git-log computation.")
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.tree_json and args.source_root:
        parser.error("<source-root> and --tree-json are mutually exclusive")
    if not args.tree_json and not args.source_root:
        parser.error("either <source-root> or --tree-json is required")

    result: dict = {}

    if args.tree_json:
        try:
            entries = _read_json(args.tree_json)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"discover_inventory: could not read --tree-json {args.tree_json}: {exc}",
                  file=sys.stderr)
            return 1
        blobs = [
            (e["path"], int(e.get("bytes") or 0))
            for e in entries
            if e.get("type") == "blob" and e.get("path")
        ]
        result["file_counts_by_dir"] = compute_dir_counts(blobs)
        result["largest_files"] = compute_largest_files(blobs)
        result["doc_roots"] = compute_doc_roots_tree(entries)
    else:
        root = Path(args.source_root)
        if not root.is_dir():
            print(f"discover_inventory: source root not found: {root}", file=sys.stderr)
            return 1
        files = walk_directory(root)
        result["file_counts_by_dir"] = compute_dir_counts(files)
        result["largest_files"] = compute_largest_files(files)
        result["doc_roots"] = compute_doc_roots_dir(root)

    since_last_check = None
    if args.since_json:
        try:
            since_last_check = _read_json(args.since_json)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"discover_inventory: could not read --since-json {args.since_json}: {exc}",
                  file=sys.stderr)
            return 1
    elif args.source_root and args.last_checked_sha:
        since_last_check = compute_since_last_check_git(Path(args.source_root),
                                                          args.last_checked_sha)

    if since_last_check is not None:
        result["since_last_check"] = since_last_check

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
