#!/usr/bin/env python3
"""Map each reference's SHA-pinned (or stable-tag-pinned) permalinks to the
repository paths they cite, and — with --changed — intersect those paths
per source against a since_last_check changed-path list to print the
re-emit candidate set.

Extraction reuses permalink_density.py's per-forge grammar
(build_path_capturing_res, an additive export alongside build_permalink_res)
so a cited path is parsed with the same grammar the density lint already
credits — never a second, divergent notion of what counts as a citation.

A citation resolves to a registered source by matching its host+repo
against research/source-paths.json's own `url` field (the same registry
permalink_density.accepted_hosts() reads), not merely by host — two
sources could share a host.

Usage:
    python3 cited_paths.py <references_dir>
    python3 cited_paths.py <references_dir> --changed <inventory.json>

Bare invocation prints {"<ref relative path>": [<sorted cited paths>], ...}
for every *.md under <references_dir> — including an empty list for a
reference whose only citations contribute no path (an Azure DevOps
permalink with no `?path=`, a Bitbucket Server repo-root citation).

--changed reads the multi-source `research/.discover-inventory.json`
shape — an object keyed by source_id, each value carrying its own
since_last_check — and replaces the bare mapping entirely with:
    {"candidates": {<ref>: {<source_id>: [<sorted matching changed paths>]}},
     "uncited_changes": {"count": <int>, "paths": [<sorted changed paths>]}}
A reference is a key of "candidates" only when at least one of its cited
paths/directories matches a changed path in the source it resolves to
(exact match, or a cited directory that is a "/"-bounded prefix of the
changed path). "uncited_changes" is the flat, corpus-wide set of changed
paths no reference's citation matches, in any source.

Stdlib only, aside from the sibling permalink_density import. Read-only.
Exits 0 on an empty references directory with an empty object; exits
non-zero with a "cited_paths: ..." stderr message when --changed points at
a file that carries no source's since_last_check at all (the shape a
DISCOVER-only inventory has).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from urllib.parse import urlsplit

from permalink_density import accepted_hosts, build_path_capturing_res


def _load_json(path: Path) -> object:
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def _normalize_host_repo(url: str) -> tuple[str, str] | None:
    """(lowercased host, repo path with no leading/trailing '/'), the same
    normalization applied to both a registered source's `url` and a
    citation's own matched host+repo — comparable only once both sides go
    through it."""
    try:
        parts = urlsplit(url)
    except ValueError:
        return None
    host = parts.netloc.rpartition("@")[2].lower()
    if not host:
        return None
    return host, parts.path.strip("/")


def _load_git_managed_sources(references_dir: Path) -> dict[tuple[str, str], str]:
    """{(host, repo): source_id} for every git-managed source in the same
    registry accepted_hosts() would read for this references_dir — same
    resolution order (a staged `.proposed` registry, when present, replaces
    the live one beside it rather than merging with it)."""
    root = references_dir.parent
    registries = [root / "research" / "source-paths.json"]
    if root.name.endswith(".proposed"):
        live = root.with_name(root.name[: -len(".proposed")])
        registries.append(live / "research" / "source-paths.json")

    for registry_path in registries:
        try:
            data = _load_json(registry_path)
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict):
            continue
        sources = data.get("sources")
        if not isinstance(sources, list):
            continue
        by_repo: dict[tuple[str, str], str] = {}
        for source in sources:
            if not isinstance(source, dict) or source.get("kind") != "git-managed":
                continue
            source_id = source.get("id")
            url = source.get("url")
            if not isinstance(source_id, str) or not isinstance(url, str):
                continue
            key = _normalize_host_repo(url)
            if key is not None:
                by_repo[key] = source_id
        return by_repo
    return {}


def _clean_path(raw: str) -> str:
    """Strip a leading '/' (Azure DevOps's `?path=/src/file.py` carries one;
    since_last_check's repo-relative paths never do) and any trailing
    '#L...' fragment."""
    return raw.lstrip("/").split("#", 1)[0]


def _scan(references_dir: Path) -> tuple[dict[str, list[str]], dict[str, dict[str, list[str]]]]:
    """Walk every *.md under references_dir. Return (base_paths,
    source_paths): base_paths maps each reference's POSIX-relative path to
    its full sorted set of cited paths, forge- and source-agnostic
    (criterion 1); source_paths maps the same key to {source_id: sorted
    cited paths}, restricted to citations that resolve to a registered
    git-managed source — the input to --changed's per-source intersection.
    """
    hosts = accepted_hosts(references_dir)
    patterns = build_path_capturing_res(hosts)
    sources_by_repo = _load_git_managed_sources(references_dir)

    base_paths: dict[str, set[str]] = {}
    source_paths: dict[str, dict[str, set[str]]] = {}

    for md in sorted(references_dir.rglob("*.md")):
        rel = md.relative_to(references_dir).as_posix()
        base_paths[rel] = set()
        source_paths[rel] = {}

        text = md.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            for _forge, pattern in patterns:
                for match in pattern.finditer(line):
                    raw_path = match.groupdict().get("path")
                    if not raw_path:
                        continue
                    path = _clean_path(raw_path)
                    if not path:
                        continue
                    base_paths[rel].add(path)

                    host = (match.group("host") or "").lower()
                    repo = (match.group("repo") or "").strip("/")
                    source_id = sources_by_repo.get((host, repo))
                    if source_id is not None:
                        source_paths[rel].setdefault(source_id, set()).add(path)

    base_out = {ref: sorted(paths) for ref, paths in base_paths.items()}
    source_out = {
        ref: {sid: sorted(paths) for sid, paths in by_source.items()}
        for ref, by_source in source_paths.items()
    }
    return base_out, source_out


def _matches(cited: str, changed: str) -> bool:
    """Exact match, or changed is properly nested under the cited directory
    — a '/'-bounded prefix, never a bare string prefix (cited "src" must not
    swallow changed "srcbackup/file.py")."""
    return changed == cited or changed.startswith(cited + "/")


def _changed_paths_by_source(inventory: dict) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    for source_id, entry in inventory.items():
        if not isinstance(entry, dict):
            continue
        since = entry.get("since_last_check")
        if not isinstance(since, dict):
            continue
        files = since.get("files")
        if not isinstance(files, list):
            continue
        paths = sorted(
            {f["path"] for f in files if isinstance(f, dict) and isinstance(f.get("path"), str)}
        )
        result[source_id] = paths
    return result


def _build_candidate_set(
    source_paths: dict[str, dict[str, list[str]]],
    changed_by_source: dict[str, list[str]],
) -> tuple[dict[str, dict[str, list[str]]], dict[str, object]]:
    candidates: dict[str, dict[str, list[str]]] = {}
    covered: dict[str, set[str]] = {sid: set() for sid in changed_by_source}

    for ref, by_source in source_paths.items():
        for source_id, cited in by_source.items():
            changed = changed_by_source.get(source_id)
            if not changed:
                continue
            matched = sorted({c for c in changed if any(_matches(cite, c) for cite in cited)})
            if matched:
                candidates.setdefault(ref, {})[source_id] = matched
                covered[source_id].update(matched)

    uncited: set[str] = set()
    for source_id, changed in changed_by_source.items():
        uncited.update(p for p in changed if p not in covered.get(source_id, set()))

    return candidates, {"count": len(uncited), "paths": sorted(uncited)}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Map each reference's permalinks to the repository paths "
        "it cites; with --changed, print the re-emit candidate set."
    )
    parser.add_argument("references_dir", type=Path)
    parser.add_argument(
        "--changed",
        type=Path,
        default=None,
        help="research/.discover-inventory.json (multi-source shape) to "
        "intersect cited paths against.",
    )
    args = parser.parse_args(argv)

    base_paths, source_paths = _scan(args.references_dir)

    if args.changed is None:
        print(json.dumps(base_paths, sort_keys=True))
        return 0

    try:
        inventory = _load_json(args.changed)
    except (OSError, ValueError) as exc:
        print(f"cited_paths: could not read --changed file {args.changed}: {exc}", file=sys.stderr)
        return 1
    if not isinstance(inventory, dict):
        print(f"cited_paths: --changed file {args.changed} is not a JSON object", file=sys.stderr)
        return 1

    changed_by_source = _changed_paths_by_source(inventory)
    if not changed_by_source:
        print(
            f"cited_paths: --changed file {args.changed} carries no "
            "since_last_check for any source",
            file=sys.stderr,
        )
        return 1

    candidates, uncited_changes = _build_candidate_set(source_paths, changed_by_source)
    print(json.dumps({"candidates": candidates, "uncited_changes": uncited_changes}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
