#!/usr/bin/env python3
"""Compare a staged proposal's manifest against the live tree's own
manifest.json — the one the most recent promotion left behind — and
report every modified entry whose content has moved since the engine
itself last wrote it: a hand edit, a SELF-AUDIT fix, or any other
change that landed on the live file between promotions.

Usage: hand_edit_check.py <proposal-manifest.json> <live-manifest.json>

Writes a JSON array to stdout: one {"path", "proposal_sha_before",
"live_sha_after"} object per flagged path, [] when none. Read-only;
the live-manifest path may not exist yet (no promotion has ever
happened) or fail to parse, and both degrade to "nothing to compare
against" rather than an error.
"""
import json
import sys


def load_entries(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return {e["path"]: e for e in data.get("entries", [])}


def main():
    proposal_path, live_path = sys.argv[1], sys.argv[2]
    with open(proposal_path) as f:
        proposal = {e["path"]: e for e in json.load(f).get("entries", [])}
    live = load_entries(live_path)

    flagged = []
    for path, entry in proposal.items():
        if entry.get("status") != "modified":
            continue
        live_entry = live.get(path)
        if not live_entry:
            continue
        live_sha_after = live_entry.get("sha_after")
        if live_sha_after is None:
            continue
        proposal_sha_before = entry.get("sha_before")
        if proposal_sha_before != live_sha_after:
            flagged.append({
                "path": path,
                "proposal_sha_before": proposal_sha_before,
                "live_sha_after": live_sha_after,
            })

    print(json.dumps(flagged))


if __name__ == "__main__":
    main()
