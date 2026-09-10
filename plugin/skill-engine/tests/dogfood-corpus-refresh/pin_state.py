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
  divergent     The object is present, NOT reachable from <rev>, and some
                ref still vouches for it. The pin names a commit from a
                foreign or unmerged branch — the defect the ancestry check
                was written to catch.
  unresolvable  No ref anywhere in the repository contains the object,
                whether or not the object store still holds it.
                Post-squash-merge, or a fabricated sha; git cannot tell
                those apart and neither can this. No assertion about the
                pin's relationship to <rev> is available, so a caller must
                substitute one that does not need it.

Presence in the object store is deliberately NOT what separates the last
two. A deleted branch's commits linger as unreachable objects until gc
runs — `cat-file -e` keeps answering yes for weeks in a maintainer's
clone — while a fresh CI checkout never fetches them at all. Keying on
presence therefore classifies one corpus two ways depending on whose disk
it sits on, which is how the squash-merge case reached the `divergent`
hard-fail arm on main despite this module existing to prevent exactly
that. Reachability from a ref has one answer everywhere.

A second, independent question rides alongside the classification: which
revision the corpus's cited paths should be diffed against to decide whether
the pin is stale *in substance*. Against <rev> itself (HEAD), every commit
to a cited path re-stales the corpus, including the release bump that edits
six cited version surfaces — so the check was red on main after nearly
every push and at both of the last two releases. The property the corpus
actually promises its consumers is "true as of the last release": a consumer
installs the released plugin, and the corpus's own navigator names the
released version. `--tag-match <glob>` therefore selects the latest release
tag reachable from <rev> and reports a `compare_rev`:

  pin precedes the tag      compare_rev = the tag. The window pin..tag is
                            what the caller diffs; a cited path changed in
                            it means the corpus describes something older
                            than what shipped.
  pin at or past the tag    compare_rev = the pin itself, an empty window.
                            The corpus is at least as current as the
                            release. Once the next tag lands the pin
                            precedes it again and the window refills —
                            which is the post-release refresh the release
                            ritual owes, now with a red check naming it.
  no matching tag           compare_rev = <rev>, the strict HEAD-relative
                            comparison — the behavior before this flag.
  pin not an ancestor       compare_rev = <rev>; the state alone decides.

Read-only: runs `git cat-file`, `git merge-base` and `git describe` and
writes nothing. Stdlib only, no network I/O.

Usage:
    python3 pin_state.py --repo-root <path> --sha <sha> [--rev <rev>]
                         [--tag-match <glob>]

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


def _git_out(repo_root: Path, *args: str) -> str:
    """stdout of the git invocation, or "" when it exits non-zero."""
    proc = subprocess.run(
        ["git", "-C", str(repo_root), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if proc.returncode != 0:
        return ""
    return proc.stdout.decode("utf-8", errors="replace")


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
    # `--contains` walks from every ref, so this is "does any branch or tag
    # in this repository still lead to the pin", not "is the object on
    # disk". Only consulted for a non-ancestor: a pin that IS an ancestor of
    # <rev> is in this history by definition, and must classify as such even
    # where no ref happens to name it — a detached-HEAD checkout must never
    # silently downgrade a checkable pin to the substitute tier.
    ref_reachable = object_present and bool(
        _git_out(
            repo_root, "for-each-ref", "--contains", sha, "--format=%(refname)"
        ).strip()
    )
    if not object_present:
        state = "unresolvable"
    elif is_ancestor:
        state = "ancestor"
    elif not ref_reachable:
        # Present but orphaned: the squash-merged branch was deleted and gc
        # has not run yet. Indistinguishable in substance from the state a
        # fresh checkout sees, so it is classified the same way.
        state = "unresolvable"
    else:
        state = "divergent"
    return {
        "sha": sha,
        "rev": rev,
        "object_present": object_present,
        "ref_reachable": ref_reachable,
        "is_ancestor": is_ancestor,
        "state": state,
    }


def latest_tag(repo_root: Path, rev: str, tag_match: str) -> str | None:
    """The nearest tag matching `tag_match` reachable from <rev>, or None.
    `--match` is what keeps a non-release tag (this repo carries
    `pre-monorepo-adapter` and `post-monorepo-adapter`) from being read as
    a release the day one lands on the first-parent line."""
    out = _git_out(
        repo_root, "describe", "--tags", "--abbrev=0", "--match", tag_match, rev
    ).strip()
    return out or None


def comparison(repo_root: Path, classified: dict, tag_match: str | None) -> dict:
    """Which revision the caller should diff the pin against, and why.
    Additive to `classify`'s output: every key it emitted is untouched."""
    sha, rev = classified["sha"], classified["rev"]
    tag = latest_tag(repo_root, rev, tag_match) if tag_match else None
    if classified["state"] != "ancestor":
        compare_rev, reason = rev, "pin is not an ancestor of rev; state decides"
    elif tag_match is None:
        compare_rev, reason = rev, "no tag consulted; comparing against rev"
    elif tag is None:
        compare_rev, reason = rev, "no tag matches; comparing against rev"
    elif _git_ok(repo_root, "merge-base", "--is-ancestor", sha, tag):
        compare_rev, reason = tag, "pin precedes the latest tag"
    elif _git_ok(repo_root, "merge-base", "--is-ancestor", tag, sha):
        compare_rev, reason = sha, "pin is at or past the latest tag; nothing to diff"
    else:
        compare_rev, reason = rev, "pin and latest tag are unrelated; comparing against rev"
    return {
        **classified,
        "latest_tag": tag,
        "compare_rev": compare_rev,
        "compare_reason": reason,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Classify a recorded corpus pin.")
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--rev", default="HEAD",
                        help="Revision the pin is checked against. Default HEAD.")
    parser.add_argument("--tag-match", default=None,
                        help="Glob for release tags (e.g. 'v[0-9]*'). When "
                             "given, the output also names the latest "
                             "matching tag reachable from --rev and the "
                             "revision the pin should be diffed against.")
    args = parser.parse_args(argv)

    result = classify(args.repo_root, args.sha, args.rev)
    print(json.dumps(comparison(args.repo_root, result, args.tag_match)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
