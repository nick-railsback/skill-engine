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
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

from permalink_density import accepted_hosts, build_path_capturing_res, resolve_registry


def _load_json(path: Path) -> object:
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


# scp-style SSH remote: [user@]host:path, as `git@github.com:acme/repo.git`.
# `intake-and-detection.md` accepts this form at bootstrap and
# `stamping-and-templates.md` records the url verbatim, so a source can be
# registered this way. urlsplit gives it no netloc at all, so without this
# it never resolves to a host/repo pair and every change under such a
# source is reported uncited. The negative lookahead keeps `https://...` --
# whose scheme also ends in ':' -- out of this branch.
_SCP_LIKE = re.compile(r"^(?:[^@/]+@)?(?P<host>[^:/]+):(?!//)(?P<path>.+)$")


def _normalize_repo(repo: str) -> str:
    """A repo locator comparable across the spellings the same repository is
    written in: surrounding '/' dropped, a '.git' suffix dropped (accepted
    at intake, never present in a web citation), and case folded (the forges
    this tool credits treat owner/repo case-insensitively, and a citation
    routinely differs in case from the registered url)."""
    repo = repo.strip("/")
    if repo.lower().endswith(".git"):
        repo = repo[: -len(".git")]
    return repo.lower()


def _normalize_host_repo(url: str) -> tuple[str, str] | None:
    """(lowercased host, normalized repo path) — the same normalization
    applied to both a registered source's `url` and a citation's own matched
    host+repo, which are comparable only once both sides go through it."""
    scp = _SCP_LIKE.match(url)
    if scp is not None:
        host = scp.group("host").rpartition("@")[2].lower()
        return (host, _normalize_repo(scp.group("path"))) if host else None
    try:
        parts = urlsplit(url)
    except ValueError:
        return None
    host = parts.netloc.rpartition("@")[2].lower()
    if not host:
        return None
    return host, _normalize_repo(parts.path)


def _load_git_managed_sources(references_dir: Path) -> dict[tuple[str, str], str]:
    """{(host, repo): source_id} for every git-managed source registered for
    this references_dir.

    Resolves the registry via permalink_density.resolve_registry() — the
    same live/staged fallback accepted_hosts() uses, so the two never
    disagree on which registry governs."""
    registry = resolve_registry(references_dir)
    if not isinstance(registry, dict):
        return {}
    sources = registry.get("sources")
    if not isinstance(sources, list):
        return {}
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


# Trailing characters that end a sentence or a markdown span but cannot end
# a repository path. The capturing regex stops only at whitespace, ')' and
# ']', so everything else a citation is written next to survives the match.
_PATH_TRAILERS = ",.;:!?'\"`*_>"


def _clean_path(raw: str) -> str:
    """A cited path reduced to the repo-relative form since_last_check emits,
    so the two are comparable.

    Removes, in order: a '#L...' line fragment; a '?...' query string (a
    '?plain=1' or '?raw=1' suffix is routine on a forge permalink); trailing
    prose or markup punctuation; and surrounding '/'. The leading slash is
    Azure DevOps's (`?path=/src/file.py` carries one, and since_last_check's
    repo-relative paths never do); the trailing slash is how a directory
    tree URL is habitually written, and left in place it made a nested-path
    comparison compare against 'packages/core//'.
    """
    path = raw.split("#", 1)[0].split("?", 1)[0]
    return path.rstrip(_PATH_TRAILERS).strip("/")


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
                    repo = _normalize_repo(match.group("repo") or "")
                    source_id = sources_by_repo.get((host, repo))
                    if source_id is not None:
                        source_paths[rel].setdefault(source_id, set()).add(path)

    base_out = {ref: sorted(paths) for ref, paths in base_paths.items()}
    source_out = {
        ref: {sid: sorted(paths) for sid, paths in by_source.items()}
        for ref, by_source in source_paths.items()
    }
    return base_out, source_out


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


def _index_cited_paths(
    source_paths: dict[str, dict[str, list[str]]],
) -> dict[str, dict[str, set[str]]]:
    """source_id -> {cited_path: {refs citing it}}, built once from every
    (ref, source, cited-path) triple — not re-derived per changed path. A
    citation matches a changed path on an exact match, or on being a
    '/'-bounded prefix of it (a cited directory containing the changed
    path) — never a bare string prefix (cited "src" must not swallow
    changed "srcbackup/file.py"). Every path this index is queried against
    is therefore a literal key here: an exact hit is the changed path
    itself, and a directory hit is one of its own "/"-truncated ancestors,
    so a lookup never needs to scan cited entries linearly (see
    `_ancestor_chain`)."""
    index: dict[str, dict[str, set[str]]] = {}
    for ref, by_source in source_paths.items():
        for source_id, cited in by_source.items():
            by_cited = index.setdefault(source_id, {})
            for cite in cited:
                by_cited.setdefault(cite, set()).add(ref)
    return index


def _ancestor_chain(path: str) -> list[str]:
    """`path` itself, then each '/'-truncated ancestor up to the root —
    every string a citation could match `path` against, since a cited
    directory must be a '/'-bounded prefix of `path`."""
    parts = path.split("/")
    return ["/".join(parts[:i]) for i in range(len(parts), 0, -1)]


def _build_candidate_set(
    source_paths: dict[str, dict[str, list[str]]],
    changed_by_source: dict[str, list[str]],
) -> tuple[dict[str, dict[str, list[str]]], dict[str, object]]:
    index = _index_cited_paths(source_paths)
    candidates: dict[str, dict[str, set[str]]] = {}
    covered: dict[str, set[str]] = {sid: set() for sid in changed_by_source}

    for source_id, changed in changed_by_source.items():
        by_cited = index.get(source_id)
        if not by_cited:
            continue
        for path in changed:
            refs: set[str] = set()
            for ancestor in _ancestor_chain(path):
                hit = by_cited.get(ancestor)
                if hit:
                    refs.update(hit)
            if refs:
                covered[source_id].add(path)
                for ref in refs:
                    candidates.setdefault(ref, {}).setdefault(source_id, set()).add(path)

    candidates_out = {
        ref: {sid: sorted(paths) for sid, paths in by_source.items()}
        for ref, by_source in candidates.items()
    }

    uncited: set[str] = set()
    for source_id, changed in changed_by_source.items():
        uncited.update(p for p in changed if p not in covered.get(source_id, set()))

    return candidates_out, {"count": len(uncited), "paths": sorted(uncited)}


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
