#!/usr/bin/env python3
"""Deterministic pre-flight corpus-shape inventory for DISCOVER.

Computes, for a single `git-managed` source, the four signals `§
Discovering essence` today re-derives in-window at full token cost every
run: a file count keyed by directory (rolled up adaptively — see
`compute_dir_counts` — rather than a fixed depth), the 20 largest files by
byte size, which canonical doc-root paths exist at the source root, and —
when a prior checked SHA is known and a local git checkout is available —
a per-file change summary since that SHA. `inventory_source` names which
of the two modes below produced the result (`cache` or `tree-json`). The
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
     a two-tree `git diff --name-status` between `--last-checked-sha`
     and `HEAD` — not a `git log` range walk, which cannot succeed when
     the two commits share no history (an in-place-advanced shallow
     cache) — only when `--last-checked-sha` was supplied, it resolves
     in `<source-root>`'s object store, *and* `<source-root>/.git`
     exists; otherwise the key is omitted from the output entirely
     (never null, never a placeholder).

  2. Additive `--tree-json <file>` mode (the real no-local-cache
     production path; not exercised by the frozen oracle — see this
     chunk's plan.md § Risks): reads either a bare JSON array of
     `{"path", "bytes", "type": "blob"|"tree"}` entries, or a top-level
     object `{"truncated": bool, "tree": [...those same entries...]}` —
     the shape `gh api .../git/trees/<ref>?recursive=1` returns, modulo
     key renaming — and computes the three tree-shape signals from it
     with no filesystem access at all. A `truncated: true` envelope
     surfaces as `partial: true` plus a `notice` string in the output;
     the bare-array shape (no truncation information available) and an
     absent or `false` `truncated` key both read as `partial: false`.
     Mutually exclusive with the positional `<source-root>`.

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

# Single source of truth for the three calibration constants: the starting
# directory-rollup depth ceiling, the bucket count `compute_dir_counts`
# grows that ceiling to reach, and the largest-files cap.
DEPTH_CEILING = 3
TARGET_BUCKET_COUNT = 20
LARGEST_FILES_LIMIT = 20

README_RE = re.compile(r"^readme", re.IGNORECASE)
CHANGELOG_RE = re.compile(r"^changelog", re.IGNORECASE)
DOC_DIR_NAMES = {"docs", "doc"}

GIT_DIRNAME = ".git"

TRUNCATION_NOTICE = (
    "tree listing truncated by the source API; corpus shape below is incomplete"
)


def _dir_key_at(rel_path: str, ceiling: int) -> str:
    """The `file_counts_by_dir` key for a file at `rel_path` (posix-style,
    relative to the source root) at a given rollup `ceiling`: its
    containing directory's path, rolled up to at most `ceiling` segments.
    `""` for a root-level file."""
    dir_parts = rel_path.split("/")[:-1]
    if len(dir_parts) > ceiling:
        dir_parts = dir_parts[:ceiling]
    return "/".join(dir_parts)


def _counts_at_ceiling(files: list[tuple[str, int]], ceiling: int) -> dict[str, int]:
    counts: dict[str, int] = {}
    for rel_path, _bytes in files:
        key = _dir_key_at(rel_path, ceiling)
        counts[key] = counts.get(key, 0) + 1
    return counts


def compute_dir_counts(files: list[tuple[str, int]]) -> dict[str, int]:
    """Roll `file_counts_by_dir` up to the shallowest ceiling, starting from
    `DEPTH_CEILING`, that reaches at least `TARGET_BUCKET_COUNT` distinct
    directories — deepening one segment at a time only while some file's
    directory is deeper than the current ceiling (there is more structure
    left to reveal). A tree too small or flat to ever reach the target
    (every file's directory depth exhausted first) falls back to
    `DEPTH_CEILING` itself, not to the deepest ceiling explored, so a
    genuinely flat corpus rolls up exactly as it always has."""
    ceiling = DEPTH_CEILING
    counts = _counts_at_ceiling(files, ceiling)
    while len(counts) < TARGET_BUCKET_COUNT:
        if not any(len(rel_path.split("/")) - 1 > ceiling for rel_path, _ in files):
            return _counts_at_ceiling(files, DEPTH_CEILING)
        ceiling += 1
        counts = _counts_at_ceiling(files, ceiling)
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
    """`since_last_check` via a two-tree `git diff`, or `None` when `root`
    is not itself a local git working tree, `last_checked_sha` is absent
    from its object store, or any git call fails for any reason (never
    raises — the caller treats `None` as "omit the key").

    Diffs the two trees directly (`git diff <sha> HEAD`) rather than
    walking the commit range between them (`git log <sha>..HEAD`): a
    shallow cache advanced in place by re-cloning at a new SHA (chunk
    02-cache-advance-in-place) holds two commits with no connecting
    history between them, and a range walk cannot succeed against that —
    a two-tree diff needs no shared history at all."""
    if not (root / GIT_DIRNAME).exists():
        return None
    try:
        # The shallow-cache failure mode this preserves: `last_checked_sha`
        # was never fetched into this object store. Checked explicitly,
        # rather than relying on `diff` to fail the same way, so the
        # omission doesn't depend on one git subcommand's error behavior
        # for a missing object matching another's.
        sha_present = subprocess.run(
            ["git", "-C", str(root), "cat-file", "-e", last_checked_sha],
            capture_output=True, text=True,
        )
        if sha_present.returncode != 0:
            return None
        head_sha = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        # --name-status prints paths for a human by default, and two of its
        # display forms are not paths at all: a rename collapses to the
        # single field `dir/{old.md => new.md}`, and anything outside ASCII
        # is C-quoted and octal-escaped to `"docs/caf\303\251.md"`. Both
        # reach the caller as a `path` that matches nothing in the corpus
        # shape it is meant to be intersected with — the changed files drop
        # out of the re-harvest and the corpus keeps stale content for
        # them, silently.
        #
        # --no-renames splits a rename back into its delete and its add,
        # each a plain path and each one a real thing the consumer can act
        # on. core.quotePath=false turns off the escaping. Set with -c
        # rather than assumed from the environment: this must not depend on
        # the user's git config.
        diff_output = subprocess.run(
            ["git", "-C", str(root), "-c", "core.quotePath=false",
             "diff", "--name-status", "--no-renames",
             last_checked_sha, "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, OSError):
        return None

    paths: list[str] = []
    for line in diff_output.splitlines():
        fields = line.split("\t")
        if len(fields) != 2:
            continue  # blank line or malformed row
        _status, path = fields
        paths.append(path)

    return {
        "from_sha": last_checked_sha,
        "to_sha": head_sha,
        "files": [{"path": path, "changes": 1} for path in paths],
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
                         help="Bare JSON array of {path, bytes, type} tree entries, or an "
                         "object {truncated, tree: [...those entries...]}, in place of "
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
            parsed = _read_json(args.tree_json)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"discover_inventory: could not read --tree-json {args.tree_json}: {exc}",
                  file=sys.stderr)
            return 1
        # Additive envelope: a top-level object carrying `tree` (the entry
        # list) alongside `truncated`, mirroring the upstream tree API's own
        # shape. The old bare-array shape (no envelope at all) still works —
        # every existing caller/fixture keeps parsing, just with no
        # truncation signal available (chunk 03-inventory-calibration).
        if isinstance(parsed, dict):
            entries = parsed.get("tree") or []
            truncated = bool(parsed.get("truncated", False))
        else:
            entries = parsed
            truncated = False
        blobs = [
            (e["path"], int(e.get("bytes") or 0))
            for e in entries
            if e.get("type") == "blob" and e.get("path")
        ]
        result["file_counts_by_dir"] = compute_dir_counts(blobs)
        result["largest_files"] = compute_largest_files(blobs)
        result["doc_roots"] = compute_doc_roots_tree(entries)
        result["partial"] = truncated
        if truncated:
            result["notice"] = TRUNCATION_NOTICE
        result["inventory_source"] = "tree-json"
    else:
        root = Path(args.source_root)
        if not root.is_dir():
            print(f"discover_inventory: source root not found: {root}", file=sys.stderr)
            return 1
        files = walk_directory(root)
        result["file_counts_by_dir"] = compute_dir_counts(files)
        result["largest_files"] = compute_largest_files(files)
        result["doc_roots"] = compute_doc_roots_dir(root)
        result["inventory_source"] = "cache"

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
