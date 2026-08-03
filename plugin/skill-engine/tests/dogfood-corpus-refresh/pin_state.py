#!/usr/bin/env python3
"""Classify a recorded corpus pin against a repository's history.

The dogfood contextualizer pins its corpus to a commit of the very repo it
describes, and that pin is necessarily written on the feature branch that
harvests the corpus. This repo squash-merges, so the branch commit the pin
names is not an ancestor of main after the merge, and once the branch ref is
gone the commit object is unreachable — a fresh `actions/checkout` of main
cannot see it at all, `fetch-depth: 0` included, because that fetches every
ref and no unreachable object.

`merge-base --is-ancestor <pin> HEAD` therefore answers two different
questions with one bit, and gets the second one wrong: "is this pin foreign
to my history" (a real defect) and "has this pin been squashed away" (an
expected, unavoidable lifecycle state). This splits them:

  ancestor      The object is present and reachable from <rev>. The pin is
                checkable; a caller may assert against it strictly.
  divergent     The object is present but NOT reachable from <rev>. The pin
                names a commit from a foreign or unmerged branch — the
                defect the ancestry check was written to catch.
  unresolvable  The object is absent. Post-squash-merge, or a fabricated
                sha; git cannot tell those apart and neither can this. No
                assertion about the pin's relationship to <rev> is
                available, so a caller must substitute one that does not
                need it.

Read-only: runs `git cat-file` and `git merge-base` and writes nothing.
Stdlib only, no network I/O.

Usage:
    python3 pin_state.py --repo-root <path> --sha <sha> [--rev <rev>]

Exit code is always 0 — this is a classifier, not a pass/fail gate; the
caller applies its own assertions to the emitted JSON.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def _git_ok(repo_root: Path, *args: str) -> bool:
    """True when the git invocation exits 0. Output is discarded — every
    caller here only needs the exit status."""
    return subprocess.run(
        ["git", "-C", str(repo_root), *args],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0


def classify(repo_root: Path, sha: str, rev: str) -> dict:
    # `^{commit}` matters: without it a sha that happens to name a blob or
    # tree would report present, and merge-base would then fail for a
    # reason that has nothing to do with ancestry.
    object_present = _git_ok(repo_root, "cat-file", "-e", f"{sha}^{{commit}}")
    # Guarded, not merely computed and ignored: merge-base exits non-zero
    # both for "not an ancestor" and for "no such object", and conflating
    # those is the whole bug this module exists to avoid.
    is_ancestor = (
        object_present and _git_ok(repo_root, "merge-base", "--is-ancestor", sha, rev)
    )
    if not object_present:
        state = "unresolvable"
    elif is_ancestor:
        state = "ancestor"
    else:
        state = "divergent"
    return {
        "sha": sha,
        "rev": rev,
        "object_present": object_present,
        "is_ancestor": is_ancestor,
        "state": state,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Classify a recorded corpus pin.")
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--rev", default="HEAD",
                        help="Revision the pin is checked against. Default HEAD.")
    args = parser.parse_args(argv)

    print(json.dumps(classify(args.repo_root, args.sha, args.rev)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
