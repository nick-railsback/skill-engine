#!/usr/bin/env python3
"""Black-box, read-only scan of a reference corpus's GitHub permalinks.

Walks the flat *.md files directly under a given references directory,
extracts every SHA-pinned `blob/<40-hex>/<path>#L<start>-L<end>` permalink
pointed at the given owner/repo, and reports (as one JSON object on
stdout):

  - how many permalinks were found in total (a sanity floor so an empty
    or broken scan can never be mistaken for a passing corpus),
  - how many still cite a known-superseded pin,
  - whether every permalink found shares one single sha and that sha
    matches an externally supplied "expected" sha,
  - for every permalink, a purely structural resolution check against the
    local git object store: does `<path>` exist at `<sha>`, and does
    `<end>` fall within that blob's line count (`start <= end`, `end <=
    line_count`). No semantic / fuzzy content comparison is attempted —
    structural resolution only. `--resolve-at <rev>` moves that resolution
    off the cited sha and onto a revision the caller names, for the case
    where the cited sha no longer resolves locally at all (see below),
  - the sorted set of distinct repo paths the corpus cites, so a caller can
    diff those paths across a commit range and decide whether the pin is
    still current in substance rather than merely in sha.

This repo squash-merges, so a corpus pinned on a feature branch cites a sha
that stops resolving locally the moment the branch is merged and deleted —
the object is unreachable, and `actions/checkout` fetches refs, not
unreachable objects. Resolving every citation at the cited sha is then
impossible for a reason no re-run can fix. `--resolve-at <rev>` is the
substitute a caller in that state uses: a squash-merge leaves the merged
tree equal to the branch tip's, so the same paths and line ranges still have
a real thing to resolve against. The check keeps its teeth — a range that
overruns the file, or a path that no longer exists, still fails — it just
asks the question of a revision that exists. See pin_state.py for the
classifier that decides which of the two modes applies.

Read-only: never writes to the files it scans or to the git repository.
Stdlib only, no network I/O.

Usage:
    python3 permalink_scan.py <references_dir> --repo-root <path> \\
        --expected-sha <sha> [--owner-repo OWNER/REPO] \\
        [--resolve-at REV] [--max-failures N]

Exit code is always 0 — this is a data-gathering scan, not a pass/fail
gate; the caller applies its own assertions to the emitted JSON.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# The pin this corpus is being moved off of. A literal historical fact
# about this repo's own reference corpus, not a placeholder.
OLD_PINNED_SHA = "711e3144e1ad81b50414667b9b5e3c0363989955"

DEFAULT_OWNER_REPO = "nick-railsback/skill-engine"


def permalink_re(owner_repo: str) -> re.Pattern[str]:
    return re.compile(
        r"https://github\.com/"
        + re.escape(owner_repo)
        + r"/blob/([0-9a-fA-F]{40})/([^\s)\]#]+)#L(\d+)-L(\d+)"
    )


def scan_files(references_dir: Path, owner_repo: str) -> list[dict]:
    """Every permalink found in the flat *.md files directly under
    references_dir. Non-recursive: this corpus's contract is a flat
    directory of primaries."""
    pattern = permalink_re(owner_repo)
    hits: list[dict] = []
    for md in sorted(references_dir.glob("*.md")):
        text = md.read_text(encoding="utf-8", errors="replace")
        for m in pattern.finditer(text):
            sha, path, start, end = m.groups()
            hits.append({
                "file": md.name,
                "sha": sha,
                "path": path,
                "start": int(start),
                "end": int(end),
            })
    return hits


def line_count_at(repo_root: Path, sha: str, path: str) -> int | None:
    """Line count of <path> as it exists at <sha>, or None if the blob
    does not exist there. Mirrors `git show <sha>:<path> | wc -l` (a
    newline count, not a "does the file end without a trailing newline"
    adjustment) exactly, via the git plumbing porcelain avoids shelling
    out to a pipeline for."""
    exists = subprocess.run(
        ["git", "-C", str(repo_root), "cat-file", "-e", f"{sha}:{path}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if exists.returncode != 0:
        return None
    content = subprocess.run(
        ["git", "-C", str(repo_root), "cat-file", "-p", f"{sha}:{path}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return content.stdout.count(b"\n")


def structural_check(
    repo_root: Path, hits: list[dict], resolve_at: str | None = None
) -> tuple[int, list[dict]]:
    """Returns (ok_count, failures). failures is a list of dicts adding a
    "reason" key to the offending permalink's own fields.

    resolve_at, when given, is the revision every permalink resolves
    against instead of the sha it cites."""
    cache: dict[tuple[str, str], int | None] = {}
    ok = 0
    failures: list[dict] = []
    for hit in hits:
        rev = resolve_at if resolve_at is not None else hit["sha"]
        # The failure text names where resolution was attempted, so a
        # degraded run's diagnostics can never read as if the cited sha
        # had been consulted.
        where = "cited sha" if resolve_at is None else f"rev {resolve_at}"
        key = (rev, hit["path"])
        if key not in cache:
            cache[key] = line_count_at(repo_root, rev, hit["path"])
        lc = cache[key]
        if lc is None:
            failures.append({**hit, "reason": f"path does not exist at {where}"})
            continue
        if not (1 <= hit["start"] <= hit["end"]):
            failures.append({**hit, "reason": "start does not precede end"})
            continue
        if hit["end"] > lc:
            failures.append({
                **hit,
                "reason": f"end line {hit['end']} exceeds file's {lc} lines at {where}",
            })
            continue
        ok += 1
    return ok, failures


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("references_dir", type=Path)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--owner-repo", default=DEFAULT_OWNER_REPO)
    parser.add_argument("--resolve-at", default=None,
                        help="Resolve every permalink's path and line range "
                             "at this revision instead of at the sha it "
                             "cites. For the post-squash-merge case, where "
                             "the cited sha no longer names a local object.")
    parser.add_argument("--max-failures", type=int, default=20,
                         help="Cap on structural failures included in the "
                         "JSON output (diagnostic only; the count is exact).")
    args = parser.parse_args(argv)

    refs = args.references_dir
    if not refs.is_dir():
        print(json.dumps({"error": f"not a directory: {refs}"}))
        return 0

    hits = scan_files(refs, args.owner_repo)
    distinct_shas = sorted({h["sha"] for h in hits})
    stale_hits = sum(1 for h in hits if h["sha"] == OLD_PINNED_SHA)
    single_consistent_sha = (
        len(distinct_shas) == 1 and distinct_shas[0] == args.expected_sha
    )

    ok_count, failures = structural_check(args.repo_root, hits, args.resolve_at)

    result = {
        "file_count": len(sorted(refs.glob("*.md"))),
        "permalink_count": len(hits),
        # Which revision the structural check actually consulted: the
        # string the caller passed to --resolve-at, or null for the
        # default "each permalink's own cited sha". Emitted so a degraded
        # run is legible in the output itself and cannot be mistaken for a
        # strict one by anything reading this JSON.
        "resolved_at": args.resolve_at,
        "old_pinned_sha": OLD_PINNED_SHA,
        "stale_hits": stale_hits,
        "distinct_shas": distinct_shas,
        "expected_sha": args.expected_sha,
        "single_consistent_sha": single_consistent_sha,
        "structural_ok_count": ok_count,
        "structural_fail_count": len(failures),
        "structural_failures_sample": failures[: args.max_failures],
        # Every distinct repo path the corpus cites. The caller uses this to
        # ask whether the pin is *semantically* current — has any file the
        # corpus actually quotes changed since the pinned commit — which is
        # the question `pin == HEAD` was standing in for and could not
        # answer without being unsatisfiable. Emitted here, not re-derived
        # by the caller, so the permalink regex stays in exactly one place.
        "cited_paths": sorted({h["path"] for h in hits}),
    }
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
