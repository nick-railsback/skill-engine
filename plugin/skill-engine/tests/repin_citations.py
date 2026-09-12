#!/usr/bin/env python3
"""Re-pin a reference corpus's permalinks from one commit to the next,
mechanically, wherever the cited text did not change — and hand the model
exactly the citations that need a reader.

Why. A REFRESH against a git-managed source that advanced from <old_sha>
to <new_sha> has to move every permalink to the new SHA, or the corpus
stops being single-SHA. On 2026-09-09 the dogfood corpus carried 215
permalinks: 160 pointed into files unchanged between the two commits, 46
sat in changed files but shifted by a whole-line offset with byte-identical
cited text, and 9 overlapped a hunk and needed a human to read old against
new. 206 of 215 were arithmetic, and an hour of a refresh cycle went on
arithmetic. This is that arithmetic.

What it does, per citation carrying <old_sha>:

  unchanged file    Neither the path nor (for a directory citation) anything
                    under it changed between the two commits: the SHA is
                    swapped. Nothing else in the citation moves.
  remapped range    The file changed, and the citation carries a line range
                    that no hunk of `git diff -U0 <old> <new> -- <path>`
                    touches. Every hunk that lies wholly above the range
                    shifts it by that hunk's net line delta; the cited lines
                    at <old_sha> are then byte-compared with the shifted
                    range at <new_sha>, and only an exact match is
                    accepted. The SHA and the range are rewritten.
  needs review      Everything else: a range that overlaps a hunk, a
                    whole-file or directory citation whose target changed, a
                    deleted path, a shifted range whose text nonetheless
                    differs. The citation is left exactly as it was, at the
                    old SHA, and listed in the report with a reason. The
                    report is the model's worklist: every entry here is a
                    place the cited claim may no longer hold.

A citation pinned to any other SHA, or to a tag, is not this source's
advance and is left alone (counted under "other").

The grammar is permalink_density.py's per-forge, path-capturing one — the
same extraction cited_paths.py and the density lint use — so what counts as
a citation is decided in one place. citation_labels.build_labeled_res widens
that grammar's *span* to admit an optional enclosing `[label](` prefix,
without changing what it considers a citation. Line fragments are read in
the `#L<start>-L<end>`, `#L<start>-<end>`, `#L<start>` and bare
`#<start>-<end>` spellings; a fragment in any other shape is treated as "no
range", which degrades to whole-file handling rather than guessing.

Labels. A citation can render its line range twice — once in the fragment,
once in the markdown link label a human actually reads. In the
`remapped_range` bucket, and only there, the label is renumbered alongside
the fragment, spelling preserved; this tool repairs what it moved and
nothing else. Every label on a citation pinned to this source's advance
that arrived disagreeing with its own fragment is reported under
`label_disagreements` whether or not this run repaired it, because a refresh
that silently normalized one would erase the only evidence the two had
drifted. A citation at some other SHA is not this advance and is not
label-checked here; the corpus-wide gate covers it. A label rendering two
range tokens is not guessed at: the citation goes to needs review with the
fragment left where it is, so label and URL stay in agreement by moving
neither. The agreement itself is gated corpus-wide, independently of this
tool, by `tests/citation-labels/run.sh`.

Output: one JSON object on stdout with corpus-wide counts, per-reference
counts, and the needs-review list. With --out-dir, every reference whose
text changed is written under that directory at its own relative path —
a sparse copy-on-write, the shape a `.proposed/` staging tree has. The
input references directory is never written to. Without --out-dir the run
is a dry report.

Read-only over the repository: `git diff`, `git show` and `git cat-file`
only, no network I/O, no checkout. Stdlib only, aside from the sibling
citation_labels and permalink_density imports.

Usage:
    python3 repin_citations.py <references_dir> --repo <clone> \\
        --old-sha <sha> --new-sha <sha> [--out-dir <dir>]

<clone> must hold both commits — the cache directory `cache-git.sh advance`
leaves behind does, and so does the repository itself for a dogfood corpus.

Exit code: 0 when the run completed, whether or not anything needs review
(the report says); 1 on a usage error — a missing directory, or a SHA that
does not resolve in <clone>.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

from citation_labels import (
    AMBIGUOUS,
    agree,
    build_labeled_res,
    label_range,
    parse_fragment,
    rewrite_fragment,
    rewrite_label,
)
from permalink_density import accepted_hosts

# Trailing characters that end a sentence or a markdown span but cannot end
# a repository path. Mirrors cited_paths._clean_path's trailer set so the two
# scripts agree on where a cited path stops.
_PATH_TRAILERS = ",.;:!?'\"`*_>"

_HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def _git(repo: Path, *args: str) -> bytes | None:
    """stdout bytes of the git invocation, or None when it exits non-zero."""
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return proc.stdout if proc.returncode == 0 else None


def _sha_resolves(repo: Path, sha: str) -> bool:
    return _git(repo, "cat-file", "-e", f"{sha}^{{commit}}") is not None


def changed_paths(repo: Path, old_sha: str, new_sha: str) -> dict[str, str]:
    """{path: status} for every path that differs between the two commits.
    --no-renames so a moved file reads as a delete plus an add: the citation
    names the old path, and the old path is gone."""
    out = _git(repo, "-c", "core.quotePath=false", "diff", "--name-status",
               "--no-renames", old_sha, new_sha)
    result: dict[str, str] = {}
    for line in (out or b"").decode("utf-8", errors="replace").splitlines():
        parts = line.split("\t", 1)
        if len(parts) == 2:
            result[parts[1]] = parts[0][:1]
    return result


def hunks(repo: Path, old_sha: str, new_sha: str, path: str) -> list[tuple[int, int, int, int]]:
    """(old_start, old_count, new_start, new_count) per hunk of the zero-
    context diff of <path> between the two commits."""
    out = _git(repo, "diff", "-U0", "--no-renames", old_sha, new_sha, "--", path)
    found: list[tuple[int, int, int, int]] = []
    for line in (out or b"").decode("utf-8", errors="replace").splitlines():
        m = _HUNK_RE.match(line)
        if m:
            a, b, c, d = m.groups()
            found.append((int(a), int(b) if b is not None else 1,
                          int(c), int(d) if d is not None else 1))
    return found


def remap_range(start: int, end: int, diff_hunks: list[tuple[int, int, int, int]]) -> tuple[int, int] | str:
    """The cited range's position at the new commit, or a reason string when
    no hunk-free remap exists.

    A hunk with old_count == 0 is a pure insertion *after* old line
    old_start (old_start may be 0: insertion at the top of the file). It
    shifts the range when it lands above it, leaves it alone when it lands
    at or after the range's last line, and breaks it — the cited lines are
    no longer contiguous — when it lands strictly inside.
    """
    offset = 0
    for old_start, old_count, _new_start, new_count in diff_hunks:
        if old_count == 0:
            if old_start < start:
                offset += new_count
            elif old_start < end:
                return f"lines inserted inside the cited range after old line {old_start}"
            continue
        old_end = old_start + old_count - 1
        if old_end < start:
            offset += new_count - old_count
        elif old_start > end:
            continue
        else:
            return f"hunk at old lines {old_start}-{old_end} overlaps the cited range"
    return start + offset, end + offset


def _lines_at(repo: Path, sha: str, path: str, start: int, end: int) -> list[bytes] | None:
    blob = _git(repo, "show", f"{sha}:{path}")
    if blob is None:
        return None
    lines = blob.split(b"\n")
    if end > len(lines) or start < 1:
        return None
    return lines[start - 1:end]


def _clean_path(raw: str) -> str:
    path = raw.split("#", 1)[0].split("?", 1)[0]
    return path.rstrip(_PATH_TRAILERS).strip("/")


def _affected(path: str, changed: dict[str, str]) -> str | None:
    """The status of the change touching <path> or anything under it, or
    None when nothing did. A directory citation is affected by any change
    beneath it; 'D' is reported only when the path itself is gone."""
    if path in changed:
        return changed[path]
    prefix = path + "/"
    for changed_path, status in changed.items():
        if changed_path.startswith(prefix):
            return status
    return None


class Repinner:
    def __init__(self, repo: Path, old_sha: str, new_sha: str) -> None:
        self.repo = repo
        self.old_sha = old_sha
        self.new_sha = new_sha
        self.changed = changed_paths(repo, old_sha, new_sha)
        self._hunks: dict[str, list[tuple[int, int, int, int]]] = {}
        self.needs_review: list[dict] = []
        self.counts = {"unchanged_file": 0, "remapped_range": 0, "needs_review": 0, "other": 0}
        self.per_reference: dict[str, dict[str, int]] = {}
        # Label bookkeeping, kept beside the four buckets rather than inside
        # them: a label is a property of a citation, not a fifth outcome, and
        # the bucket names are a frozen contract.
        self.label_rewritten = 0
        self.label_disagreements: list[dict] = []

    def _hunks_for(self, path: str) -> list[tuple[int, int, int, int]]:
        if path not in self._hunks:
            self._hunks[path] = hunks(self.repo, self.old_sha, self.new_sha, path)
        return self._hunks[path]

    def _tally(self, ref: str, bucket: str) -> None:
        self.counts[bucket] += 1
        self.per_reference.setdefault(
            ref, {"unchanged_file": 0, "remapped_range": 0, "needs_review": 0, "other": 0}
        )[bucket] += 1

    def _defer(self, ref: str, path: str, rng: tuple[int, int] | None, reason: str) -> None:
        self._tally(ref, "needs_review")
        self.needs_review.append({
            "reference": ref,
            "path": path,
            "start": rng[0] if rng else None,
            "end": rng[1] if rng else None,
            "reason": reason,
        })

    def _emit(self, label: str | None, url: str) -> str:
        """The replacement text for a whole matched span. build_labeled_res's
        span stops short of the closing paren, so neither does this."""
        return url if label is None else f"[{label}]({url}"

    def _label_check(self, ref: str, path: str, label: str | None,
                     rng: tuple[int, int] | None):
        """The label's rendered range, having first recorded any disagreement
        it arrived with.

        Every input disagreement is reported, including one this run is about
        to repair. The repair is the output and the report is the record; a
        reader wants both, and a refresh that silently normalized the label
        would erase the only evidence that the two had drifted apart."""
        got = label_range(label)
        if got is None or got is AMBIGUOUS or rng is None:
            return got
        lstart, lend, _m = got
        if not agree(lstart, lend, rng):
            self.label_disagreements.append({
                "reference": ref,
                "path": path,
                "label": label,
                "label_range": [lstart, lend],
                "fragment_range": list(rng),
            })
        return got

    def rewrite_citation(self, ref: str, label: str | None, url: str, raw_path: str) -> str:
        """The citation text to write in place of the whole matched span,
        which may be that span itself. Tallies the outcome."""
        if self.old_sha not in url:
            self._tally(ref, "other")
            return self._emit(label, url)
        path = _clean_path(raw_path)
        rng = parse_fragment(raw_path)
        got = self._label_check(ref, path, label, rng)
        status = _affected(path, self.changed)

        if status is None:
            self._tally(ref, "unchanged_file")
            return self._emit(label, url.replace(self.old_sha, self.new_sha))
        if status == "D" and path in self.changed:
            self._defer(ref, path, rng, f"path deleted at {self.new_sha[:12]}")
            return self._emit(label, url)
        if rng is None:
            what = "directory" if path not in self.changed else "whole file"
            self._defer(ref, path, None, f"{what} citation and its target changed")
            return self._emit(label, url)
        if got is AMBIGUOUS:
            # Two range tokens in one label: renumbering one of them is how a
            # tool invents a fact. The fragment is left where it is too, so
            # label and URL stay in agreement by moving neither.
            self._defer(ref, path, rng, "label renders more than one line range")
            return self._emit(label, url)

        remapped = remap_range(rng[0], rng[1], self._hunks_for(path))
        if isinstance(remapped, str):
            self._defer(ref, path, rng, remapped)
            return self._emit(label, url)
        old_lines = _lines_at(self.repo, self.old_sha, path, rng[0], rng[1])
        new_lines = _lines_at(self.repo, self.new_sha, path, remapped[0], remapped[1])
        if old_lines is None or new_lines is None or old_lines != new_lines:
            self._defer(ref, path, rng,
                        f"cited text differs at the remapped range L{remapped[0]}-L{remapped[1]}")
            return self._emit(label, url)

        self._tally(ref, "remapped_range")
        new_raw = rewrite_fragment(raw_path, remapped[0], remapped[1])
        new_url = url.replace(self.old_sha, self.new_sha).replace(raw_path, new_raw, 1)
        new_label = label
        if got is not None:
            new_label = rewrite_label(label, remapped[0], remapped[1])
            if new_label != label:
                self.label_rewritten += 1
        return self._emit(new_label, new_url)


def repin_corpus(references_dir: Path, repinner: Repinner) -> dict[str, str]:
    """{relative reference path: rewritten text} for every reference whose
    text changed. References are never modified in place."""
    patterns = build_labeled_res(accepted_hosts(references_dir))
    rewritten: dict[str, str] = {}
    for md in sorted(references_dir.rglob("*.md")):
        rel = md.relative_to(references_dir).as_posix()
        text = md.read_text(encoding="utf-8", errors="replace")
        updated = text
        for _forge, pattern in patterns:
            def sub(m: re.Match[str], _rel: str = rel) -> str:
                raw_path = m.groupdict().get("path")
                label = m.groupdict().get("label")
                if not raw_path:
                    # A repo-wide pin with no path (Azure DevOps without
                    # ?path=): nothing to compare, so a reader decides.
                    if repinner.old_sha in m.group(0):
                        repinner._defer(_rel, "", None, "citation carries no path")
                    else:
                        repinner._tally(_rel, "other")
                    return m.group(0)
                # m.group(0) carries the `[label](` prefix when there is one,
                # so the url is the rest of the span -- not the whole match.
                # `[` + label + `](` is exactly len(label) + 3 characters.
                url = m.group(0) if label is None else m.group(0)[len(label) + 3:]
                return repinner.rewrite_citation(_rel, label, url, raw_path)
            updated = pattern.sub(sub, updated)
        if updated != text:
            rewritten[rel] = updated
    return rewritten


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Re-pin a corpus's permalinks from one commit to the next "
                    "wherever the cited text is unchanged; list the rest."
    )
    parser.add_argument("references_dir", type=Path)
    parser.add_argument("--repo", type=Path, required=True,
                        help="A clone holding both commits (the advanced cache directory).")
    parser.add_argument("--old-sha", required=True)
    parser.add_argument("--new-sha", required=True)
    parser.add_argument("--out-dir", type=Path, default=None,
                        help="Write each rewritten reference here at its own "
                             "relative path (the proposed tree). Omit for a dry report.")
    args = parser.parse_args(argv)

    if not args.references_dir.is_dir():
        print(f"repin_citations: not a directory: {args.references_dir}", file=sys.stderr)
        return 1
    if not (args.repo / ".git").exists() and not (args.repo / "HEAD").exists():
        print(f"repin_citations: not a git repository: {args.repo}", file=sys.stderr)
        return 1
    old_sha, new_sha = args.old_sha.lower(), args.new_sha.lower()
    for sha in (old_sha, new_sha):
        if not _sha_resolves(args.repo, sha):
            print(f"repin_citations: {sha} does not resolve to a commit in {args.repo}",
                  file=sys.stderr)
            return 1

    repinner = Repinner(args.repo, old_sha, new_sha)
    rewritten = repin_corpus(args.references_dir, repinner)

    written: list[str] = []
    if args.out_dir is not None:
        for rel, text in rewritten.items():
            target = args.out_dir / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
            written.append(rel)

    total = sum(repinner.counts.values())
    repinned = repinner.counts["unchanged_file"] + repinner.counts["remapped_range"]
    print(json.dumps({
        "old_sha": old_sha,
        "new_sha": new_sha,
        "citations": total,
        "at_old_sha": repinned + repinner.counts["needs_review"],
        "repinned": repinned,
        "counts": repinner.counts,
        "all_repinned": repinner.counts["needs_review"] == 0,
        "label_rewritten": repinner.label_rewritten,
        "label_disagreements": repinner.label_disagreements,
        "per_reference": repinner.per_reference,
        "needs_review": repinner.needs_review,
        "rewritten": sorted(rewritten),
        "written": sorted(written),
        "out_dir": str(args.out_dir) if args.out_dir is not None else None,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
