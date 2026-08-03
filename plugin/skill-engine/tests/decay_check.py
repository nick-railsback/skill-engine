#!/usr/bin/env python3
"""Decay-budget visibility for cached web-doc sources.

Read-only: for every in-scope `kind: web-doc` source in a
`research/source-paths.json` (`status: "confirmed"` with a cached
snapshot on disk — the same in-scope filter REFRESH's own Phase 2
decay check already applies), read the cached snapshot's
`_crawl-manifest.json` for `crawl_date` and the first listed snapshot
file's frontmatter for `decay`, compute `expires_at = crawl_date +
decay`, and report whether the source is past its decay budget,
within it, or non-expiring (`decay: "none"`). Writes one JSON array
to stdout, never writes to any input file, and never exits non-zero
on account of any individual source's result — report-only, not a
gate.

Usage:
    python3 decay_check.py <source-paths.json> <cache-root>
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

IN_SCOPE_STATUSES = {"confirmed"}

# Fixed day-ratios, not calendar months/years — see plan.md § Questions 1.
_UNIT_DAYS = {"d": 1, "w": 7, "m": 30, "y": 365}
_DECAY_RE = re.compile(r"^(none|([1-9][0-9]*)([dwmy]))$")
_CRAWL_DATE_RE = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$"
)


def is_in_scope(source: dict) -> bool:
    return (
        source.get("kind") == "web-doc"
        and source.get("status") in IN_SCOPE_STATUSES
    )


def _parse_date(value: str) -> datetime:
    if "T" in value:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    return datetime.strptime(value, "%Y-%m-%d").replace(tzinfo=timezone.utc)


def _read_frontmatter_field(md_path: Path, field: str) -> str | None:
    try:
        lines = md_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    if not lines or lines[0].strip() != "---":
        return None
    for line in lines[1:]:
        if line.strip() == "---":
            break
        match = re.match(rf"^{field}:\s*(\S+)\s*$", line)
        if match:
            return match.group(1)
    return None


def _pick_cache_dir(cache_root: Path, source_id: str) -> Path | None:
    # Newest `crawl_date` wins when more than one `<source_id>-*/`
    # snapshot exists — see plan.md § Questions 2.
    candidates = sorted(cache_root.glob(f"{source_id}-*"))
    best_dir = None
    best_date = None
    for cand in candidates:
        manifest_path = cand / "_crawl-manifest.json"
        if not manifest_path.is_file():
            continue
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            crawl_date = _parse_date(manifest["crawl_date"])
        except (OSError, ValueError, KeyError, json.JSONDecodeError):
            continue
        if best_date is None or crawl_date > best_date:
            best_date = crawl_date
            best_dir = cand
    return best_dir


def check(source: dict, cache_root: Path) -> dict | None:
    source_id = source["id"]
    cache_dir = _pick_cache_dir(cache_root, source_id)
    if cache_dir is None:
        return None

    manifest_path = cache_dir / "_crawl-manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None

    crawl_date_raw = manifest.get("crawl_date")
    pages = manifest.get("pages") or []
    if not crawl_date_raw or not _CRAWL_DATE_RE.match(crawl_date_raw):
        return None
    if not pages:
        return None

    decay_raw = None
    for page in pages:
        page_file = page.get("file")
        if not page_file:
            continue
        decay_raw = _read_frontmatter_field(cache_dir / page_file, "decay")
        if decay_raw is not None:
            break
    if decay_raw is None or not _DECAY_RE.match(decay_raw):
        return None

    crawl_date = _parse_date(crawl_date_raw)
    page_count = len(pages)

    if decay_raw == "none":
        return {
            "source_id": source_id,
            "state": "non_expiring",
            "crawl_id": manifest.get("crawl_id"),
            "page_count": page_count,
            "crawl_date": crawl_date_raw,
            "decay": decay_raw,
            "days": None,
        }

    match = _DECAY_RE.match(decay_raw)
    amount, unit = int(match.group(2)), match.group(3)
    decay_days = amount * _UNIT_DAYS[unit]
    now = datetime.now(timezone.utc)
    elapsed_days = (now - crawl_date).days
    remaining_days = decay_days - elapsed_days

    state = "past_budget" if remaining_days < 0 else "within_budget"
    return {
        "source_id": source_id,
        "state": state,
        "crawl_id": manifest.get("crawl_id"),
        "page_count": page_count,
        "crawl_date": crawl_date_raw,
        "decay": decay_raw,
        "days": abs(remaining_days),
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: decay_check.py <source-paths.json> <cache-root>", file=sys.stderr)
        return 2
    source_paths, cache_root = Path(argv[0]), Path(argv[1]) / "web-doc"

    data = json.loads(source_paths.read_text(encoding="utf-8"))
    sources = data.get("sources", [])

    results = []
    for source in sources:
        if not is_in_scope(source):
            continue
        result = check(source, cache_root)
        if result is not None:
            results.append(result)

    json.dump(results, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
