#!/usr/bin/env python3
"""Assert -- and mechanically maintain -- agreement between the line range a
citation *renders* and the line range its URL actually *points at*.

Why. A permalink can carry the same fact twice. Once in the URL fragment,
`#L1312-L1387`, which is where every tool reads it. Once in the markdown
link label, `[L1028-L1103](...)`, which is where every human reads it. On
2026-09-12 a REFRESH of this repo's own corpus moved 91 citations' fragments
to a new commit and left all 91 labels behind; 14 of them had rendered a
range, so 14 citations then displayed one range and resolved to another.
Every gate stayed green. permalink_scan.py resolves URLs against the git
object store and a lying label resolves perfectly; verify.sh parses no link
labels in any check; the density lint counts paragraphs, not agreement.

Nothing owned the relationship between the two renderings. This module owns
it, for any writer -- repin_citations.py, a future rewriter, or a hand edit.

Two grammars, deliberately different:

  FRAGMENT_RE     The URL side. `#L12-L20` (GitHub), `#L12-20` (GitLab),
                  `#L12`, and Bitbucket Server's bare `#12-20`. ASCII
                  hyphen only -- a URL fragment never carries a dash the
                  author chose. Anchored at the end of the raw path so a
                  `?plain=1` query is not mistaken for part of it.
  LABEL_RANGE_RE  The prose side, where an author's typography shows up.
                  Accepts the ASCII hyphen, the en dash and the em dash,
                  an optional leading `#` for the in-label fragment
                  spelling `` [`docs/tasks.md#L126`] ``, and an optional
                  second `L`. All four spellings are live in this repo's
                  corpora.

The label range is found *anywhere inside* the label, not anchored to
either end: a corpus writes `[L260-L279]`, `` [`README.md` L15-L27] ``, and
`` [`server.py` L129-L160 `MCPServer.__init__`] `` -- leading, trailing and
enclosed. A label carrying two range tokens is reported ambiguous and never
guessed at, because picking one of them is how a tool invents a fact.

Equivalence, not equality: a single-sided label `L3` against a degenerate
fragment `#L3-L3` is the same range in two spellings, not drift. Treating
those as mismatches produces false positives across every corpus that
cites a single line.

The citation grammar is permalink_density.py's per-forge, path-capturing
one -- the same extraction cited_paths.py, repin_citations.py and the
density lint use -- widened here to admit an optional enclosing label. What
counts as a citation stays one decision in one place; this module only
widens the span it is read over.

Usage:
    python3 citation_labels.py <references_dir> [--json]

Output: a `[PASS]`/`[FAIL]`/`[N/A]` line plus one detail line per
disagreement, or the whole scan as JSON with --json.

Exit code: 1 when any label disagrees with its fragment; 0 otherwise.
Ambiguous labels are reported as `[NOTE]` and do not gate -- they are
unverifiable by this grammar, not known-wrong, and a reader decides.

Read-only. Stdlib only, aside from the sibling permalink_density import.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from permalink_density import accepted_hosts, build_path_capturing_res

# The URL side. Mirrors the spelling set repin_citations.py reads, and is
# the single definition of it -- that module imports this one.
FRAGMENT_RE = re.compile(r"#(L?)(\d+)(?:(-L?)(\d+))?$")

# The prose side. `–` en dash, `—` em dash. No whitespace is
# admitted around the separator: every range token observed in the wild is
# written tight, and a looser grammar would start matching prose like
# "L12 - the second clause".
LABEL_RANGE_RE = re.compile(
    r"(?P<hash>#?)L(?P<start>\d+)"
    r"(?:(?P<sep>[-–—])(?P<lend>L?)(?P<end>\d+))?"
)

# A label carrying more than one range token. Distinct from None ("renders
# no range, nothing to agree with") because the two need opposite handling:
# None is skipped, this is surfaced.
AMBIGUOUS = "ambiguous"


def parse_fragment(raw: str) -> tuple[int, int] | None:
    """(start, end) for the raw path's line fragment, or None when it
    carries none or an inverted one. A single-line fragment reads as a
    degenerate range, so callers compare ranges and never special-case."""
    m = FRAGMENT_RE.search(raw)
    if not m:
        return None
    start = int(m.group(2))
    end = int(m.group(4)) if m.group(4) is not None else start
    return (start, end) if start <= end else None


def rewrite_fragment(raw: str, start: int, end: int) -> str:
    """The raw path with its fragment's numbers replaced, spelling kept."""
    def sub(m: re.Match[str]) -> str:
        if m.group(4) is None:
            return f"#{m.group(1)}{start}"
        return f"#{m.group(1)}{start}{m.group(3)}{end}"
    return FRAGMENT_RE.sub(sub, raw)


def label_range(label: str | None) -> tuple[int, int | None, re.Match[str]] | str | None:
    """(start, end-or-None, the matched token) when the label renders
    exactly one line range; None when it renders none; AMBIGUOUS when it
    renders more than one.

    `end` is None for a single-sided `L84`, preserved rather than expanded
    so rewrite_label can put back the spelling the author chose."""
    if label is None:
        return None
    found = list(LABEL_RANGE_RE.finditer(label))
    if not found:
        return None
    if len(found) > 1:
        return AMBIGUOUS
    m = found[0]
    end = int(m.group("end")) if m.group("end") is not None else None
    return (int(m.group("start")), end, m)


def agree(label_start: int, label_end: int | None, frag: tuple[int, int]) -> bool:
    """Whether a label's range and a fragment's range name the same lines.

    Equal starts, and either equal ends or a single-sided label against a
    degenerate fragment -- `L3` and `#L3-L3` are one range, two spellings."""
    frag_start, frag_end = frag
    if label_start != frag_start:
        return False
    if label_end is None:
        return frag_end == frag_start
    return label_end == frag_end


def rewrite_label(label: str, start: int, end: int) -> str:
    """<label> with its single range token renumbered, spelling preserved:
    the `#` prefix if it had one, the separator character the author used,
    and whether a second `L` was written.

    The one case with nothing to preserve is a single-sided label that
    becomes a genuine range: it renders `L<start>-L<end>`, the spelling
    every corpus in this repo uses for a two-sided range. A single-sided
    label stays single-sided while the range stays degenerate."""
    got = label_range(label)
    if got is None or got is AMBIGUOUS:
        return label
    _start, _end, m = got
    if m.group("end") is None:
        body = f"L{start}" if start == end else f"L{start}-L{end}"
    else:
        body = f"L{start}{m.group('sep')}{m.group('lend')}{end}"
    return label[:m.start()] + m.group("hash") + body + label[m.end():]


def build_labeled_res(hosts: dict[str, str | None]) -> list[tuple[str, re.Pattern[str]]]:
    """build_path_capturing_res's per-forge patterns, each widened with an
    OPTIONAL enclosing `[label](` prefix captured as `label`.

    Optional, not required, so one pass over a document visits every
    citation exactly once and `label` is None for a bare URL. Note the
    asymmetry this buys: when a label is present the match spans
    `[label](url` and stops short of the closing paren, because the shared
    grammar's path class already stops the URL before `)`. A caller
    rebuilding the match must not re-add that paren."""
    return [
        (forge, re.compile(r"(?:\[(?P<label>[^\]]*)\]\()?" + pattern.pattern))
        for forge, pattern in build_path_capturing_res(hosts)
    ]


def scan(references_dir: Path) -> dict:
    """Every citation in the corpus whose URL renders a line range, with the
    verdict on its label. References are read, never written."""
    patterns = build_labeled_res(accepted_hosts(references_dir))
    result = {
        "references_dir": str(references_dir),
        "files": 0,
        "citations_with_range": 0,
        "labels_with_range": 0,
        "agree": 0,
        "disagree": 0,
        "ambiguous": 0,
        "disagreements": [],
        "ambiguous_labels": [],
    }
    for md in sorted(references_dir.rglob("*.md")):
        result["files"] += 1
        rel = md.relative_to(references_dir).as_posix()
        text = md.read_text(encoding="utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            for _forge, pattern in patterns:
                for m in pattern.finditer(line):
                    raw_path = m.groupdict().get("path")
                    if not raw_path:
                        continue
                    frag = parse_fragment(raw_path)
                    if frag is None:
                        continue
                    result["citations_with_range"] += 1
                    label = m.groupdict().get("label")
                    got = label_range(label)
                    if got is None:
                        continue
                    if got is AMBIGUOUS:
                        result["ambiguous"] += 1
                        result["ambiguous_labels"].append(
                            {"reference": rel, "line": lineno, "label": label})
                        continue
                    result["labels_with_range"] += 1
                    lstart, lend, _m = got
                    if agree(lstart, lend, frag):
                        result["agree"] += 1
                    else:
                        result["disagree"] += 1
                        result["disagreements"].append({
                            "reference": rel,
                            "line": lineno,
                            "label": label,
                            "label_range": [lstart, lend],
                            "fragment_range": list(frag),
                        })
    return result


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Check that every citation's rendered line range agrees "
                    "with the line range its URL points at.")
    parser.add_argument("references_dir", type=Path)
    parser.add_argument("--json", action="store_true",
                        help="write the whole scan as JSON instead of a report line")
    args = parser.parse_args(argv)

    if not args.references_dir.is_dir():
        print(f"citation_labels: not a directory: {args.references_dir}", file=sys.stderr)
        return 1

    report = scan(args.references_dir)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return 1 if report["disagree"] else 0

    where = report["references_dir"]
    if report["citations_with_range"] == 0:
        print(f"[N/A] label<->fragment agreement: no citation renders a line range ({where})")
        return 0

    summary = (f"{report['citations_with_range']} citations carry a line range, "
               f"{report['labels_with_range']} labels render one, "
               f"{report['disagree']} disagree ({where})")
    if report["disagree"]:
        print(f"[FAIL] label<->fragment agreement: {summary}")
        for d in report["disagreements"]:
            lo, hi = d["label_range"]
            rendered = f"L{lo}" if hi is None else f"L{lo}-L{hi}"
            fs, fe = d["fragment_range"]
            print(f"       {d['reference']}:{d['line']}  label renders {rendered}, "
                  f"url resolves #L{fs}-L{fe}")
    else:
        print(f"[PASS] label<->fragment agreement: {summary}")
    for a in report["ambiguous_labels"]:
        print(f"[NOTE] {a['reference']}:{a['line']}  label renders more than one line "
              f"range, agreement not decidable: {a['label']}")
    return 1 if report["disagree"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
