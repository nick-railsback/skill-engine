#!/usr/bin/env python3
"""Fixture generation and probe helpers for the cache-git-helper oracle.

Test scaffolding only — never imported by shipped skill-engine code. `run.sh`
shells out to this file's subcommands (each prints one JSON object on
stdout) instead of duplicating registry/permalink-fixture construction in
bash, and instead of reaching into any private symbol of the scripts under
test: every subcommand below drives `accepted_hosts()` (a named public
function of `permalink_density.py`) or `cited_paths.py`'s own CLI, never a
private helper.

Subcommands:
  registry-resolution-fixture <root>
                              a live registry plus a sibling `.proposed`
                              override whose `sources` field is present but
                              not a list, for comparing accepted_hosts()
                              against cited_paths.py's own git-managed-source
                              resolution — plus a no-override positive
                              control sharing the same live registry
  probe-accepted-hosts <refs-dir>
                              accepted_hosts(refs_dir) -> which extra host,
                              if any, leaked in from a registry this call had
                              to read past a malformed proposed override to
                              see
  candidate-set-timing-fixture <root> <n_refs> <n_cites> <n_changed>
                              disjoint-cites/disjoint-changed-paths fixture
                              for the candidate-set timing measurement
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

TESTS_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TESTS_ROOT))

SHA_A = "a" * 40
SHA_B = "b" * 40

# ---------------------------------------------------------------------------
# registry-resolution-fixture / probe-accepted-hosts
# ---------------------------------------------------------------------------

# A live git-managed entry "acme" at github.com/acme/widgets — github.com is
# always in accepted_hosts()'s built-in default set, so a citation against it
# is extractable regardless of which registry a caller resolved against; only
# whether it maps to a source_id at all depends on that resolution. Used for
# the cited_paths.py candidate-resolution half of the agreement check.
LIVE_SOURCES_MAIN = {
    "schema_version": 1,
    "sources": [
        {
            "id": "acme",
            "kind": "git-managed",
            "url": "https://github.com/acme/widgets",
            "status": "confirmed",
            "archived": False,
            "lifecycle": {
                "state": "reachable",
                "last_checked": "2026-09-01T00:00:00Z",
                "last_checked_sha": SHA_A,
                "proposed_url": None,
            },
            "discovered_via": None,
        },
        # A second source on a host that is NEVER in accepted_hosts()'s
        # built-in default (only github.com is default-seeded) and that no
        # reference ever cites. Its sole job is to make "did this call read
        # the live registry, or stop at the malformed proposed override"
        # directly observable from accepted_hosts()'s own return value,
        # without touching cited_paths.py's citation-extraction path at all
        # (which is itself gated by accepted_hosts() and would confound a
        # probe host that doubled as a citation target).
        {
            "id": "probe-src",
            "kind": "git-managed",
            "url": "https://github.enterprise.example.com/acme/probe",
            "forge": "github",
            "status": "confirmed",
            "archived": False,
            "lifecycle": {
                "state": "reachable",
                "last_checked": "2026-09-01T00:00:00Z",
                "last_checked_sha": SHA_A,
                "proposed_url": None,
            },
            "discovered_via": None,
        },
    ],
}

# sources present, but not a list (a dict instead of an array) — the
# malformed-but-parseable shape a caller might silently read past.
PROPOSED_SOURCES_MALFORMED = {"sources": {}}

PROBE_HOST = "github.enterprise.example.com"
WIDGET_CITED_PATH = "lib/foo.py"


def _write_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def _write_widget_reference(references_dir: Path) -> None:
    references_dir.mkdir(parents=True, exist_ok=True)
    body = (
        "# Widget reference\n\n"
        "Widgets are documented in the upstream repository.\n\n"
        f"Source: https://github.com/acme/widgets/blob/{SHA_A}/{WIDGET_CITED_PATH}#L1-L2\n"
    )
    (references_dir / "widget-ref.md").write_text(body, encoding="utf-8")


def _write_inventory(path: Path) -> None:
    _write_json(
        path,
        {
            "acme": {
                "since_last_check": {
                    "from_sha": SHA_A,
                    "to_sha": SHA_B,
                    "files": [{"path": WIDGET_CITED_PATH, "changes": 1}],
                }
            }
        },
    )


def cmd_registry_resolution_fixture(root: str) -> dict:
    """Build the malformed-proposed-override case plus a no-proposed positive
    control, sharing the same live registry contents.

    Layout:
      <root>/malformed/foo-context/research/source-paths.json      (live)
      <root>/malformed/foo-context.proposed/research/source-paths.json
                                                                    ({"sources": {}})
      <root>/malformed/foo-context.proposed/references/widget-ref.md
      <root>/malformed/inventory.json
      <root>/control/bar-context/research/source-paths.json        (live, same content)
      <root>/control/bar-context/references/widget-ref.md
      <root>/control/inventory.json
    """
    root_path = Path(root)

    malformed_ctx = root_path / "malformed" / "foo-context"
    malformed_proposed = root_path / "malformed" / "foo-context.proposed"
    _write_json(malformed_ctx / "research" / "source-paths.json", LIVE_SOURCES_MAIN)
    _write_json(malformed_proposed / "research" / "source-paths.json", PROPOSED_SOURCES_MALFORMED)
    _write_widget_reference(malformed_proposed / "references")
    malformed_inventory = root_path / "malformed" / "inventory.json"
    _write_inventory(malformed_inventory)

    control_ctx = root_path / "control" / "bar-context"
    _write_json(control_ctx / "research" / "source-paths.json", LIVE_SOURCES_MAIN)
    _write_widget_reference(control_ctx / "references")
    control_inventory = root_path / "control" / "inventory.json"
    _write_inventory(control_inventory)

    return {
        "malformed_references_dir": str(malformed_proposed / "references"),
        "malformed_inventory": str(malformed_inventory),
        "control_references_dir": str(control_ctx / "references"),
        "control_inventory": str(control_inventory),
        "probe_host": PROBE_HOST,
        "cited_path": WIDGET_CITED_PATH,
    }


def cmd_probe_accepted_hosts(references_dir: str) -> dict:
    """accepted_hosts(references_dir) -> whether PROBE_HOST is present.

    PROBE_HOST only ever appears in the LIVE registry (never in a proposed
    override), so its presence in the returned host map means this call
    read past the proposed override to the live registry; its absence means
    it stopped at the proposed override (or found no override at all, and
    the live registry happened to be unreachable some other way).
    """
    from permalink_density import accepted_hosts  # noqa: PLC0415 (deliberate: see module docstring)

    hosts = accepted_hosts(Path(references_dir))
    return {
        "hosts": hosts,
        "probe_host_present": PROBE_HOST in hosts,
    }


# ---------------------------------------------------------------------------
# candidate-set-timing-fixture
# ---------------------------------------------------------------------------


def cmd_candidate_set_timing_fixture(root: str, n_refs: int, n_cites: int, n_changed: int) -> dict:
    """A registry with one big git-managed source, `n_refs` reference files
    each citing `n_cites` distinct paths, and an inventory listing `n_changed`
    distinct changed paths for that source.

    Cited paths and changed paths are drawn from disjoint namespaces
    (`refs/<i>/cite-<j>.py` vs. `changed/<k>.py`) on purpose: `_matches` is
    checked inside an `any(...)` that short-circuits on the first hit, so a
    fixture where cites and changed paths routinely overlap would let most
    (ref, changed-path) pairs exit early and understate the O(refs x changed
    x cites) cost this fixture is meant to expose. Zero overlap forces every
    comparison to run to completion — the worst case.
    """
    root_path = Path(root)
    ctx = root_path / "big-context"
    references_dir = ctx / "references"
    references_dir.mkdir(parents=True, exist_ok=True)

    _write_json(
        ctx / "research" / "source-paths.json",
        {
            "schema_version": 1,
            "sources": [
                {
                    "id": "bigrepo",
                    "kind": "git-managed",
                    "url": "https://github.com/acme/bigrepo",
                    "status": "confirmed",
                    "archived": False,
                    "lifecycle": {
                        "state": "reachable",
                        "last_checked": "2026-09-01T00:00:00Z",
                        "last_checked_sha": SHA_A,
                        "proposed_url": None,
                    },
                    "discovered_via": None,
                }
            ],
        },
    )

    sha = "c" * 40
    for i in range(n_refs):
        lines = ["# Ref", ""]
        for j in range(n_cites):
            path = f"refs/{i}/cite-{j}.py"
            lines.append(
                f"Source: https://github.com/acme/bigrepo/blob/{sha}/{path}#L1-L2"
            )
        (references_dir / f"ref-{i:05d}.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    inventory_path = root_path / "inventory.json"
    changed_files = [{"path": f"changed/{k}.py", "changes": 1} for k in range(n_changed)]
    _write_json(
        inventory_path,
        {
            "bigrepo": {
                "since_last_check": {
                    "from_sha": SHA_A,
                    "to_sha": SHA_B,
                    "files": changed_files,
                }
            }
        },
    )

    return {
        "references_dir": str(references_dir),
        "inventory": str(inventory_path),
        "n_refs": n_refs,
        "n_cites": n_cites,
        "n_changed": n_changed,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("registry-resolution-fixture")
    p.add_argument("root")

    p = sub.add_parser("probe-accepted-hosts")
    p.add_argument("references_dir")

    p = sub.add_parser("candidate-set-timing-fixture")
    p.add_argument("root")
    p.add_argument("n_refs", type=int)
    p.add_argument("n_cites", type=int)
    p.add_argument("n_changed", type=int)

    args = parser.parse_args(argv)

    if args.cmd == "registry-resolution-fixture":
        result = cmd_registry_resolution_fixture(args.root)
    elif args.cmd == "probe-accepted-hosts":
        result = cmd_probe_accepted_hosts(args.references_dir)
    elif args.cmd == "candidate-set-timing-fixture":
        result = cmd_candidate_set_timing_fixture(args.root, args.n_refs, args.n_cites, args.n_changed)
    else:  # pragma: no cover - argparse enforces choices
        parser.error(f"unknown subcommand {args.cmd!r}")
        return 2

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
