#!/usr/bin/env python3
"""Paragraph -> permalink density lint for the references corpus.

Walks `<references_dir>/**/*.md` and counts prose paragraphs that have at
least one SHA-pinned (or stable-tag-pinned) GitHub permalink within a
5-line window. Fails when corpus-wide coverage falls below the threshold
(default 80%).

Wired into SELF-AUDIT as Check 7. The script reads files only — it does
not shell out to git or perform network I/O. Stdlib only.

Usage:
    python3 permalink_density.py <references_dir> [--threshold 0.80]
                                                  [--min-paragraphs 5]

Exit codes: 0 = PASS or N/A; 1 = FAIL.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# SHA-pinned permalink (canonical form). Lifted verbatim from the AI-1
# prototype at experiments/ai-1-provenance-smoke/provenance_smoke.py; the
# shape matches the artifact contract's "SHA-pinned permalinks (the
# canonical form)" section.
SHA_PERMALINK_RE = re.compile(
    r"https://github\.com/[^/\s]+/[^/\s]+/(?:blob|tree)/[0-9a-f]{40}/[^\s)\]]+"
)
# Stable-tag-pinned permalink (accepted equivalently per the artifact
# contract's "When to keep an unpinned URL" carve-out).
TAG_PERMALINK_RE = re.compile(
    r"https://github\.com/[^/\s]+/[^/\s]+/(?:blob|tree)/v[0-9]+(?:\.[0-9]+){0,2}[A-Za-z0-9.+\-]*/[^\s)\]]+"
)
NEAR_WINDOW = 5
PREFIX_WIDTH = 60

# Paragraph-detection regexes.
HEADING_RE = re.compile(r"^#{1,6} ")
FENCE_RE = re.compile(r"^(```|~~~)")
TABLE_ROW_RE = re.compile(r"^\s*\|")
TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$")
BULLET_RE = re.compile(r"^(\s*)([-*+])\s+")
NUMBERED_RE = re.compile(r"^(\s*)\d+\.\s+")
BLOCKQUOTE_RE = re.compile(r"^\s*>")


def classify_lines(lines: list[str]) -> list[str]:
    """Return a per-line category tag. Categories:
        'prose'    — eligible for paragraph aggregation
        'blank'    — empty / whitespace-only (paragraph separator)
        'skip'     — heading / code-fence / table / list / blockquote /
                     html-comment / frontmatter (not part of a prose paragraph)
    """
    n = len(lines)
    cats: list[str] = ["prose"] * n

    in_fence = False
    in_html_comment = False
    in_frontmatter = False
    frontmatter_done = False

    # List-block tracking: when a bullet/numbered line is seen, subsequent
    # lines belong to the list until a blank line followed by a non-list
    # line, or a heading / fence / table / blockquote. Continuation lines
    # are those indented at least the list item's indent + 1 column (we use
    # any leading whitespace as a permissive heuristic — Markdown does not
    # require precise alignment).
    in_list = False

    for i, raw in enumerate(lines):
        line = raw.rstrip("\n")
        stripped = line.strip()

        # Frontmatter: leading --- ... --- at top of file.
        if i == 0 and stripped == "---":
            in_frontmatter = True
            cats[i] = "skip"
            continue
        if in_frontmatter:
            cats[i] = "skip"
            if stripped == "---":
                in_frontmatter = False
                frontmatter_done = True
            continue

        # HTML comments (single- or multi-line). Detect <!-- and --> on
        # the same line first, otherwise toggle state.
        if not in_html_comment:
            if "<!--" in line and "-->" in line and line.index("<!--") < line.rindex("-->"):
                # Single-line comment; treat as skip if comment dominates,
                # otherwise leave classification to other rules below.
                # Strip the comment span and re-evaluate the rest.
                line_no_comment = re.sub(r"<!--.*?-->", "", line)
                if not line_no_comment.strip():
                    cats[i] = "skip"
                    continue
                # Fall through with stripped re-evaluated.
                stripped = line_no_comment.strip()
                line = line_no_comment
            elif "<!--" in line:
                in_html_comment = True
                cats[i] = "skip"
                continue
        else:
            cats[i] = "skip"
            if "-->" in line:
                in_html_comment = False
            continue

        # Code fences. Fence lines and contents are skipped.
        if FENCE_RE.match(line):
            in_fence = not in_fence
            cats[i] = "skip"
            continue
        if in_fence:
            cats[i] = "skip"
            continue

        # Blank line.
        if not stripped:
            cats[i] = "blank"
            if in_list:
                # A blank line inside a list is the list's loose-list
                # separator OR the boundary. Look ahead one non-blank line
                # to decide. Done lazily below — for now, stay in_list
                # and let the next non-blank line resolve.
                pass
            continue

        # Heading.
        if HEADING_RE.match(line):
            cats[i] = "skip"
            in_list = False
            continue

        # Table.
        if TABLE_ROW_RE.match(line) or TABLE_SEP_RE.match(line):
            cats[i] = "skip"
            in_list = False
            continue

        # Blockquote.
        if BLOCKQUOTE_RE.match(line):
            cats[i] = "skip"
            in_list = False
            continue

        # List item start.
        if BULLET_RE.match(line) or NUMBERED_RE.match(line):
            cats[i] = "skip"
            in_list = True
            continue

        # List continuation: indented non-blank line while in_list.
        if in_list and line.startswith((" ", "\t")):
            cats[i] = "skip"
            continue

        # Otherwise: prose. Reset list state if we were tracking one.
        in_list = False
        cats[i] = "prose"

    return cats


def find_paragraphs(cats: list[str]) -> list[tuple[int, int]]:
    """Return [(start_line, end_line)] 1-indexed inclusive, for each
    maximal run of consecutive 'prose' lines."""
    spans: list[tuple[int, int]] = []
    start: int | None = None
    for i, c in enumerate(cats):
        if c == "prose":
            if start is None:
                start = i
        else:
            if start is not None:
                spans.append((start + 1, i))  # i is 0-indexed of first non-prose
                start = None
    if start is not None:
        spans.append((start + 1, len(cats)))
    return spans


def find_permalink_lines(lines: list[str]) -> set[int]:
    """Return the set of 1-indexed lines that contain an in-scope
    (SHA-pinned or stable-tag-pinned) GitHub permalink."""
    hit: set[int] = set()
    for i, line in enumerate(lines, start=1):
        if SHA_PERMALINK_RE.search(line) or TAG_PERMALINK_RE.search(line):
            hit.add(i)
    return hit


def analyze_file(path: Path) -> tuple[int, int, list[tuple[int, str]]]:
    """Return (total_paragraphs, covered_paragraphs, uncovered_list).
    uncovered_list is [(start_line, prefix)] for each uncovered paragraph.
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    cats = classify_lines(lines)
    paragraphs = find_paragraphs(cats)
    permalink_lines = find_permalink_lines(lines)

    covered = 0
    uncovered: list[tuple[int, str]] = []
    for start, end in paragraphs:
        lo, hi = start - NEAR_WINDOW, end + NEAR_WINDOW
        if any(lo <= pl <= hi for pl in permalink_lines):
            covered += 1
        else:
            first_line = lines[start - 1].lstrip()
            prefix = first_line[:PREFIX_WIDTH]
            uncovered.append((start, prefix))
    return len(paragraphs), covered, uncovered


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Paragraph -> permalink density lint (SELF-AUDIT Check 7)."
    )
    parser.add_argument("references_dir", type=Path)
    parser.add_argument("--threshold", type=float, default=0.80,
                        help="Coverage threshold in [0,1]. Default 0.80.")
    parser.add_argument("--min-paragraphs", type=int, default=5,
                        help="Skip with N/A when corpus has fewer than this "
                        "many in-scope paragraphs. Default 5.")
    args = parser.parse_args(argv)

    refs = args.references_dir
    if not refs.is_dir():
        print(f"[N/A]  permalink-density: no references emitted yet")
        return 0

    md_files = sorted(refs.rglob("*.md"))
    if not md_files:
        print(f"[N/A]  permalink-density: no references emitted yet")
        return 0

    per_file: list[tuple[Path, int, int, list[tuple[int, str]]]] = []
    total_paragraphs = 0
    total_covered = 0
    for md in md_files:
        total, covered, uncovered = analyze_file(md)
        per_file.append((md, total, covered, uncovered))
        total_paragraphs += total
        total_covered += covered

    if total_paragraphs < args.min_paragraphs:
        print(f"[N/A]  permalink-density: only {total_paragraphs} paragraphs "
              f"in scope (need ≥{args.min_paragraphs} for a meaningful ratio)")
        return 0

    coverage = total_covered / total_paragraphs
    pct = coverage * 100
    threshold_pct = args.threshold * 100

    if coverage >= args.threshold:
        print(f"[PASS] permalink-density: corpus coverage {pct:.1f}% "
              f"({total_covered}/{total_paragraphs} paragraphs) "
              f"≥{threshold_pct:.0f}% threshold")
        return 0

    # FAIL path: header + per-file (sub-threshold only) + per-paragraph.
    print(f"[FAIL] permalink-density: corpus coverage {pct:.1f}% "
          f"({total_covered}/{total_paragraphs} paragraphs) "
          f"below {threshold_pct:.0f}% threshold")

    sub_threshold = [
        (md, total, covered, uncovered)
        for (md, total, covered, uncovered) in per_file
        if total > 0 and (covered / total) < args.threshold
    ]
    sub_threshold.sort(key=lambda r: r[2] / r[1] if r[1] else 1.0)

    for md, total, covered, uncovered in sub_threshold:
        file_pct = (covered / total) * 100 if total else 0.0
        try:
            rel = md.relative_to(refs.parent)
        except ValueError:
            rel = md
        print(f"  {rel}: {file_pct:.1f}% ({covered}/{total} paragraphs covered)")
        for start, prefix in uncovered:
            print(f"    L{start}:  {prefix}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
