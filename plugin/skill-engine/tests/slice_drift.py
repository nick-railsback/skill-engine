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

Stdlib-only. Read-only against the cache -- the pattern matcher writes
only to a disposable scratch repository of its own. Exits 0 on success;
exits 1 with a stderr message naming the offending value when --config is
unreadable or is not valid JSON, when the config is malformed (monorepos or
slices not an array, a slice missing a non-empty string id, a slice whose
paths is not a non-empty array of non-empty strings), when --old or --new
is not resolvable in <cache_dir>, or when a git invocation fails after that
resolvability check already passed. Never a traceback: REFRESH's prose
prescribes what to do with a non-zero exit and nothing with a stack trace.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile

def _run(args: list[str], stdin: bytes = b"") -> subprocess.CompletedProcess:
    """Run a git invocation, capturing stdout and stderr as BYTES.

    Never `text=True`. Git's `-z` output is raw pathnames, which are not
    guaranteed to be valid UTF-8 -- strict decoding raised
    UnicodeDecodeError on one such file anywhere under a slice, killing a
    run in which nothing had even changed. `text=True` additionally applies
    universal-newline translation, so a pathname containing CR came back
    with LF silently substituted and a path that does not exist was handed
    to Re-read scoping. `repin_citations.py` already ships this hardened
    shape; the lesson is inherited here rather than relearned.

    Pathnames stay bytes for the whole pipeline and are decoded once, at
    the JSON boundary, with errors="replace" -- so an undecodable name is
    reported readably without ever being matched or compared in its
    lossy form.
    """
    return subprocess.run(args, input=stdin, capture_output=True, check=False)


def _err(raw: bytes) -> str:
    return raw.decode("utf-8", errors="replace")


def _empty_tree(cache_dir: str) -> str:
    """The empty-tree OID *of this repository*.

    Hardcoding SHA-1's 4b825dc6... made every SHA-256 repository exit 1
    with `fatal: bad revision`, after both --old and --new had already
    passed the resolvability gate -- so the operator was told only that
    some unnamed revision was bad.
    """
    result = _run(["git", "-C", cache_dir, "hash-object", "-t", "tree", "/dev/null"])
    if result.returncode != 0:
        sys.stderr.write(_err(result.stderr))
        sys.exit(1)
    return result.stdout.decode().strip()


def _matched_subset(patterns: list[str], candidates: list[bytes]) -> list[bytes]:
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
            sys.stderr.write(_err(init.stderr))
            sys.exit(1)

        blob = _run(["git", "-C", scratch, "hash-object", "-w", "-t", "blob", "--stdin"])
        if blob.returncode != 0:
            sys.stderr.write(_err(blob.stderr))
            sys.exit(1)
        empty_blob = blob.stdout.decode().strip()

        # -z, so a path carrying a newline or a quote cannot desynchronize
        # the record stream the way a line-oriented --index-info would.
        prefix = f"100644 {empty_blob}\t".encode()
        index_info = b"".join(prefix + path + b"\0" for path in candidates)
        add = _run(
            ["git", "-C", scratch, "update-index", "-z", "--add", "--index-info"],
            stdin=index_info,
        )
        if add.returncode != 0:
            sys.stderr.write(_err(add.stderr))
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
            sys.stderr.write(_err(applied.stderr))
            sys.exit(1)

        listed = _run(["git", "-C", scratch, "ls-files", "-v", "-z"])
        if listed.returncode != 0:
            sys.stderr.write(_err(listed.stderr))
            sys.exit(1)
        # Each record is "<tag> <path>". A tag of "S" is skip-worktree,
        # i.e. outside the sparse patterns; everything else is inside.
        inside = {
            record[2:]
            for record in listed.stdout.split(b"\0")
            if record and record[:1] != b"S"
        }

    return [path for path in candidates if path in inside]


def _bad_config(message: str) -> None:
    """Exit 1 naming the offending value, which is what the contract promises.

    `.get(k, [])` returns None for a present-but-null key, so `monorepos:
    null` raised TypeError; a slice missing `id` or `paths` raised
    KeyError; and every shape verify.sh's monorepo-config check used to
    bless raised TypeError. REFRESH prescribes what to do with a non-zero
    exit but nothing with a stack trace, so each of these reached the model
    as an unhandled traceback.
    """
    sys.stderr.write(f"error: {message}\n")
    sys.exit(1)


def _collect_slices(config: dict) -> list[tuple[str, list[str]]]:
    if not isinstance(config, dict):
        _bad_config(f"config root must be a JSON object, got {type(config).__name__}")
    # Absent and null are both rejected, matching what verify.sh's
    # monorepo-config check rejects (`.monorepos | type` is "null" for
    # each). Coercing either to [] would turn a malformed config into a
    # clean "no slices moved" verdict.
    monorepos = config.get("monorepos")
    if not isinstance(monorepos, list):
        _bad_config(f"monorepos must be an array, got {type(monorepos).__name__}")

    slices: list[tuple[str, list[str]]] = []
    seen: set[str] = set()
    for m_index, monorepo in enumerate(monorepos):
        if not isinstance(monorepo, dict):
            _bad_config(f"monorepos[{m_index}] must be an object, "
                        f"got {type(monorepo).__name__}")
        # slices ABSENT is valid (a monorepo declaring none); slices null
        # is not — again matching the config check, whose rule is "slices,
        # when present, is an array".
        declared = monorepo.get("slices", [])
        if not isinstance(declared, list):
            _bad_config(f"monorepos[{m_index}].slices must be an array, "
                        f"got {type(declared).__name__}")
        for s_index, slice_decl in enumerate(declared):
            where = f"monorepos[{m_index}].slices[{s_index}]"
            if not isinstance(slice_decl, dict):
                _bad_config(f"{where} must be an object, "
                            f"got {type(slice_decl).__name__}")
            slice_id = slice_decl.get("id")
            if not isinstance(slice_id, str) or not slice_id:
                _bad_config(f"{where} needs a non-empty string id, got {slice_id!r}")
            paths = slice_decl.get("paths")
            if not isinstance(paths, list) or not paths:
                _bad_config(f"slice '{slice_id}': paths must be a non-empty array, "
                            f"got {paths!r}")
            if not all(isinstance(entry, str) and entry for entry in paths):
                _bad_config(f"slice '{slice_id}': every paths entry must be a "
                            f"non-empty string, got {paths!r}")
            if slice_id in seen:
                continue
            seen.add(slice_id)
            slices.append((slice_id, paths))
    return slices


def _resolvable(cache_dir: str, sha: str, flag: str) -> bool:
    result = _run(["git", "-C", cache_dir, "rev-parse", "--verify", "--quiet", f"{sha}^{{commit}}"])
    if result.returncode != 0 or not result.stdout.strip():
        print(f"error: --{flag} SHA '{sha}' is not resolvable in {cache_dir}", file=sys.stderr)
        return False
    return True


def _diff_names(cache_dir: str, old: str, new: str) -> list[bytes]:
    """Every path differing between two commits, unfiltered.

    No pathspec: which of these paths belongs to a slice is decided by
    `_matched_subset`, with the engine sparse-checkout itself uses.
    """
    result = _run(["git", "-C", cache_dir, "diff", "--name-only", "-z", old, new])
    if result.returncode != 0:
        sys.stderr.write(_err(result.stderr))
        sys.exit(1)
    return [p for p in result.stdout.split(b"\0") if p]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("cache_dir")
    parser.add_argument("--old", required=True)
    parser.add_argument("--new", required=True)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

    try:
        with open(args.config, encoding="utf-8") as fh:
            config = json.load(fh)
    except OSError as exc:
        _bad_config(f"cannot read --config {args.config}: {exc.strerror or exc}")
    except json.JSONDecodeError as exc:
        _bad_config(f"--config {args.config} is not valid JSON: {exc}")
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
    empty_tree = _empty_tree(args.cache_dir)
    all_old = _diff_names(args.cache_dir, empty_tree, args.old)
    all_new = _diff_names(args.cache_dir, empty_tree, args.new)
    all_changed = _diff_names(args.cache_dir, args.old, args.new)

    results = []
    for slice_id, paths in slices:
        existed_old = bool(_matched_subset(paths, all_old))
        existed_new = bool(_matched_subset(paths, all_new))
        # Decoded once, here, at the JSON boundary -- never before
        # matching, so a lossy replacement can never affect a verdict.
        changed_paths = sorted(
            raw.decode("utf-8", errors="replace")
            for raw in _matched_subset(paths, all_changed)
        )
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
