#!/usr/bin/env python3
"""Report structural facts about the corpus files in a contextualizer's
`research/` directory, for consumption by run.sh.

A "corpus file" is discovered *structurally*, never by filename: a top-level
`.json` file in `research/` whose contents are a JSON object carrying
`schema_version: 1` and a list-valued `prompts` key. That is exactly the shape
`grounded_rate.load_and_validate_prompts` accepts, and it discriminates a corpus
from the other `schema_version: 1` sidecars that live in the same directory
(`source-paths.json`, `review-state.json`, `.research-state.json`, ...), none of
which carry a `prompts` list.

Discovering rather than assuming is deliberate: the train/held-out file naming
is a design choice, not part of the behavioral contract, so a check that
hardcoded the names would assert the design instead of the invariant.

Deep schema validity is delegated to the runner's own validator so this file
cannot drift from "the runner's existing schema_version: 1 contract".

Emits `KEY=value` lines on stdout. Always exits 0; the verdicts are in the
values.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TESTS_DIR))
from grounded_rate import load_and_validate_prompts  # noqa: E402


def discover(research: Path) -> list[Path]:
    found = []
    if not research.is_dir():
        return found
    for p in sorted(research.iterdir()):
        if not p.is_file() or p.suffix != ".json":
            continue
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if (
            isinstance(doc, dict)
            and doc.get("schema_version") == 1
            and isinstance(doc.get("prompts"), list)
        ):
            found.append(p)
    return found


def emit(key: str, value: object) -> None:
    print(f"{key}={value}")


def main(argv: list[str]) -> int:
    research = Path(argv[0])
    expected_union = {f"n{i:02d}" for i in range(1, 11)}

    corpora = discover(research)
    emit("COUNT", len(corpora))
    emit("NAMES", ",".join(p.name for p in corpora) or "(none)")

    if len(corpora) != 2:
        detail = (
            f"expected exactly 2 corpus files in {research}, found {len(corpora)}: "
            + (", ".join(p.name for p in corpora) or "(none)")
        )
        for key in ("VALID", "DISJOINT", "UNION"):
            emit(key, 0)
            emit(f"{key}_DETAIL", detail)
        return 0

    # Each parses under the runner's existing schema_version: 1 contract.
    invalid = []
    id_sets = []
    for p in corpora:
        prompts, err = load_and_validate_prompts(p)
        if err is not None or prompts is None:
            invalid.append(f"{p.name}: {err or 'unreadable'}")
            id_sets.append(set())
        else:
            id_sets.append({str(x["id"]) for x in prompts})
    emit("VALID", 0 if invalid else 1)
    emit("VALID_DETAIL", "; ".join(invalid) or "both parse under schema_version: 1")

    overlap = sorted(id_sets[0] & id_sets[1])
    emit("DISJOINT", 0 if overlap else 1)
    emit(
        "DISJOINT_DETAIL",
        f"ids shared by {corpora[0].name} and {corpora[1].name}: {', '.join(overlap)}"
        if overlap
        else "no shared prompt ids",
    )

    union = id_sets[0] | id_sets[1]
    emit("UNION", 1 if union == expected_union else 0)
    emit(
        "UNION_DETAIL",
        "union is exactly n01-n10"
        if union == expected_union
        else "union is {"
        + ", ".join(sorted(union))
        + "}, want n01-n10 (missing: "
        + (", ".join(sorted(expected_union - union)) or "none")
        + "; extra: "
        + (", ".join(sorted(union - expected_union)) or "none")
        + ")",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
