#!/usr/bin/env python3
"""Navigator standing-instructions byte-budget lint.

Computes the UTF-8 byte length of a navigator SKILL.md's *standing
instructions* — the body with frontmatter, `## Catalog` sections (the
TOC carve-out), and the engine-managed provisional-preamble block all
excluded — per `02-artifact-contract.md` § "Navigator size budget".

Report-only: always exits 0. There is no gate mode; this tool measures
and prints, it does not fail a build. Wired into `scripts/ci-local.sh`'s
`run_examples` for the dogfood navigator and the three bundled examples.

Usage:
    python3 navigator_budget.py <SKILL.md path> [--budget 5120]

Exit codes: always 0.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Single source of truth for the budget — Fork F resolution
# (5,120 = 5×1024, the literal byte-counting reading of "5K").
DEFAULT_BUDGET_BYTES = 5120

FRONTMATTER_DELIM = "---"
HEADING2_RE = re.compile(r"^## ")
CATALOG_HEADING_RE = re.compile(r"^## Catalog\b")
PREAMBLE_BEGIN = (
    "<!-- BEGIN provisional-preamble "
    "(managed by skill-engine; do not hand-edit) -->"
)
PREAMBLE_END = "<!-- END provisional-preamble -->"


def standing_instruction_bytes(path: Path) -> int:
    """UTF-8 byte length of the navigator body, standing instructions only."""
    raw = path.read_text(encoding="utf-8")
    lines = raw.splitlines(keepends=True)

    body_start = 0
    if lines and lines[0].rstrip("\n") == FRONTMATTER_DELIM:
        for i in range(1, len(lines)):
            if lines[i].rstrip("\n") == FRONTMATTER_DELIM:
                body_start = i + 1
                break

    kept: list[str] = []
    skip_catalog = False
    skip_preamble = False
    for line in lines[body_start:]:
        stripped = line.rstrip("\n")

        if skip_preamble:
            if stripped == PREAMBLE_END:
                skip_preamble = False
            continue

        if skip_catalog:
            if HEADING2_RE.match(stripped) and not CATALOG_HEADING_RE.match(stripped):
                skip_catalog = False
                # falls through: this resuming heading line is kept
            else:
                continue

        if stripped == PREAMBLE_BEGIN:
            skip_preamble = True
            continue

        if CATALOG_HEADING_RE.match(stripped):
            skip_catalog = True
            continue

        kept.append(line)

    return sum(len(l.encode("utf-8")) for l in kept)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Navigator standing-instructions byte-budget lint (report-only)."
    )
    parser.add_argument("skill_md", type=Path)
    parser.add_argument("--budget", type=int, default=DEFAULT_BUDGET_BYTES,
                        help=f"Budget in bytes. Default {DEFAULT_BUDGET_BYTES}.")
    args = parser.parse_args(argv)

    if not args.skill_md.is_file():
        print(f"[N/A]  navigator-budget: {args.skill_md} not found")
        return 0

    n = standing_instruction_bytes(args.skill_md)
    over = n > args.budget
    tag = "OVER" if over else "OK"
    verdict = "over budget" if over else "within budget"
    # Byte count comes first in the printed line, ahead of the target path —
    # a path (e.g. a mktemp -d fixture dir) can itself contain digit runs,
    # and callers that scrape "the first number in this line" for the byte
    # count must not pick up a path digit instead.
    print(f"[{tag}]  navigator-budget: {n:,} bytes, {verdict} "
          f"(budget {args.budget:,} bytes) — {args.skill_md}")
    return 0  # report-only: never gates the caller's exit code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
