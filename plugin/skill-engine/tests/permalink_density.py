#!/usr/bin/env python3
"""Paragraph -> permalink density lint for the references corpus.

Walks `<references_dir>/**/*.md` and counts prose paragraphs that have at
least one SHA-pinned (or stable-tag-pinned) permalink within a 5-line
window. Fails when corpus-wide coverage falls below the threshold
(default 80%).

Which hosts count is resolved per run from the contextualizer's own
`research/source-paths.json`, so a tenant on GitHub Enterprise, GitLab,
Bitbucket or Azure DevOps is credited for citing its own forge. github.com
is always accepted.

Wired into SELF-AUDIT as Check 7. The script reads files only — it does
not shell out to git or perform network I/O. Stdlib only.

Usage:
    python3 permalink_density.py <references_dir> [--threshold 0.80]
                                                  [--min-paragraphs 5]

Exit codes: 0 = PASS or N/A; 1 = FAIL.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

NEAR_WINDOW = 5
PREFIX_WIDTH = 60

# Single source of truth for the coverage bar. grounded_rate.py (Check 8)
# imports this so Checks 7 and 8 share one threshold; retune it here, not in
# the scattered call sites (SKILL.md invocations inherit it by omitting
# --threshold; the docs reference this value).
DEFAULT_COVERAGE_THRESHOLD = 0.80

# Paragraph-detection regexes.
HEADING_RE = re.compile(r"^#{1,6} ")
# CommonMark allows a code fence to be indented up to 3 spaces; the leading-
# whitespace tolerance also lets a fence be detected after an inline HTML
# comment is stripped (the strip leaves the fence preceded by a space).
FENCE_RE = re.compile(r"^[ \t]{0,3}(```|~~~)")
TABLE_ROW_RE = re.compile(r"^\s*\|")
TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$")
BULLET_RE = re.compile(r"^(\s*)([-*+])\s+")
NUMBERED_RE = re.compile(r"^(\s*)\d+\.\s+")
BLOCKQUOTE_RE = re.compile(r"^\s*>")


def _load_registry(path: Path) -> dict | None:
    """Parse a source-paths registry, or None if it is absent or unusable.

    Every failure here is a None, never an exception: this lint is Check 7 of
    SELF-AUDIT and is invoked from five call sites, so a JSONDecodeError
    escaping would break all five at once over a malformed file that only
    affects which *extra* hosts get credit.
    """
    try:
        with path.open(encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


# The five forges build_permalink_res knows a grammar for. A source's
# `forge` field must be one of these to scope its host; anything else is
# treated the same as an absent field.
KNOWN_FORGES = frozenset(
    {"github", "gitlab", "bitbucket-server", "bitbucket-cloud", "azure-devops"}
)

# Hostnames whose forge is unambiguous from the hostname alone, so a source
# registered on one of these without an explicit `forge` field is still
# scoped correctly rather than falling back to the permissive default.
WELL_KNOWN_FORGE_HOSTS = {
    "github.com": "github",
    "gitlab.com": "gitlab",
    "bitbucket.org": "bitbucket-cloud",
    "dev.azure.com": "azure-devops",
}


def resolve_registry(references_dir: Path) -> dict | None:
    """The sources registry to use for `references_dir`: its own
    `research/source-paths.json` when present and usable, else the live
    sibling's registry when `references_dir` sits under a `.proposed`
    staging directory, else `None`.

    The registry is found by where it sits — beside the references directory
    handed in — never by what that directory is called: DISCOVER lints an
    ephemeral merged tree whose name is a mktemp string, and a "-context"
    check would leave that surface crediting nothing.

    A staged proposal (`<name>.proposed/`) is a sparse copy-on-write, so it
    may or may not carry a registry of its own. When it does, that copy
    governs; when it does not (missing, unparseable, *or* a `sources` field
    that isn't a list — a proposal doesn't get read as "intentionally zero
    sources," it gets read as "this registry is unusable"), the live skill
    beside it does. The staged registry replaces rather than unions, which
    is what lets a proposal that *drops* a source stop crediting it before
    promotion.
    """
    root = references_dir.parent
    registry = _load_registry(root / "research" / "source-paths.json")
    malformed = registry is None or not isinstance(registry.get("sources"), list)
    if malformed and root.name.endswith(".proposed"):
        live = root.with_name(root.name[: -len(".proposed")])
        live_registry = _load_registry(live / "research" / "source-paths.json")
        if live_registry is not None:
            registry = live_registry
    return registry


def accepted_hosts(references_dir: Path) -> dict[str, str | None]:
    """Hostnames whose permalinks this corpus may be credited for, mapped
    to the forge grammar each is scoped to (`None` = unscoped: credited
    under any of the five grammars).

    Resolves its registry via `resolve_registry()` — see that function for
    the live/staged fallback rule.

    github.com is always accepted and is always scoped to the github
    grammar, so a bare corpus with no registry in sight grades exactly as
    it did before this resolution existed — except that a citation shaped
    like a different forge's grammar on github.com is no longer credited,
    which was never a github.com permalink to begin with.

    A host with no `forge` field (every source-paths.json predating this
    field) stays unscoped: it keeps matching all five grammars, so an
    existing installation's grading does not change under it.
    """
    hosts: dict[str, str | None] = {"github.com": "github"}

    registry = resolve_registry(references_dir)
    if registry is None:
        return hosts

    sources = registry.get("sources")
    if not isinstance(sources, list):
        return hosts

    for source in sources:
        # Only git-managed sources contribute a forge. A web-doc source is a
        # documentation site, not a place permalinks are served from, and
        # crediting its host would let any docs URL read as pinned.
        # `status` and `archived` are deliberately not filtered on: archiving
        # a source does not un-cite it from a reference already written.
        if not isinstance(source, dict) or source.get("kind") != "git-managed":
            continue
        url = source.get("url")
        if not isinstance(url, str):
            continue
        try:
            netloc = urlsplit(url).netloc
        except ValueError:
            continue
        # Strip any userinfo@; keep the port, which is part of the authority.
        # An scp-form remote (git@host:group/repo.git) yields no netloc at
        # all and so contributes nothing — see plan.md § Questions item 3.
        host = netloc.rpartition("@")[2].lower()
        if not host:
            continue
        declared = source.get("forge")
        forge = declared if declared in KNOWN_FORGES else WELL_KNOWN_FORGE_HOSTS.get(host)
        # A later source for an already-seen host only sharpens the scope
        # (unscoped -> a specific forge); it never widens a already-scoped
        # host back to unscoped.
        if host not in hosts or forge is not None:
            hosts[host] = forge
    return hosts


# Grammar template per forge, in the order the artifact contract's table
# lists them. Each takes the forge's own host alternation `H` — scoped to
# only the hosts registered for that forge, plus any unscoped host — so a
# host registered for one forge is never credited for another forge's URL
# shape.
_FORGE_GRAMMARS: tuple[tuple[str, str], ...] = (
    # GitHub family (github.com and GitHub Enterprise Server)
    ("github", r"https://{H}/[^/\s]+/[^/\s]+/(?:blob|tree)/{S}/{T}"),
    # GitLab — a group may nest arbitrarily before the /-/ separator
    ("gitlab", r"https://{H}/[^\s]+?/-/(?:blob|tree)/{S}/{T}"),
    # Bitbucket Server — pins in a query parameter, not a path segment. The
    # path segment itself is optional: a repo-root citation (the whole
    # repository, not one file, at that commit) omits it entirely.
    ("bitbucket-server", r"https://{H}/projects/[^/\s]+/repos/[^/\s]+/browse(?:/[^\s?)\]]*)?\?at={S}\b"),
    # Bitbucket Cloud
    ("bitbucket-cloud", r"https://{H}/[^/\s]+/[^/\s]+/src/{S}/{T}"),
    # Azure DevOps — org/project sit before _git, and the pin is GC<sha>
    ("azure-devops", r"https://{H}/[^\s]+/_git/[^\s?)\]]+\?[^\s)\]]*\bversion=GC{S}\b"),
)


def build_permalink_res(hosts: dict[str, str | None]) -> tuple[re.Pattern[str], re.Pattern[str]]:
    """Return (sha_re, tag_re) for the given accepted host map.

    `hosts` maps hostname -> forge ("github", "gitlab", "bitbucket-server",
    "bitbucket-cloud", "azure-devops", or None for unscoped). Each of the
    five grammars below matches only hosts scoped to that forge plus any
    unscoped host — never a host scoped to a *different* forge, so
    registering a GitLab host does not also credit it for a Bitbucket-
    shaped citation.

    The SHA-pinned shape tracks the artifact contract's "SHA-pinned
    permalinks (the canonical form)" section, now across the five forge
    grammars rather than github.com's alone. Each grammar pins exactly
    [0-9a-f]{40} at its own position, so branch names, short SHAs,
    `?at=refs/heads/main` and `version=GBmain` all fail to match without a
    single negative rule: a rejection written as an exclusion list is one a
    sixth spelling gets past.

    The tag-pinned shape stays github.com-only. Nothing in the contract
    extends stable-tag semantics to the other four forges, and inventing a
    per-forge tag grammar would assert a design nobody asked for.
    """
    if not hosts:
        # The resolver always seeds github.com, so an empty map means a
        # caller bypassed it. Failing loudly beats compiling an empty
        # alternation, which would match `https:///...` and credit anything.
        raise ValueError("build_permalink_res: host set is empty")

    S = "[0-9a-f]{40}"
    T = r"[^\s)\]]+"

    grammars = []
    for forge, template in _FORGE_GRAMMARS:
        scoped = {h for h, f in hosts.items() if f == forge or f is None}
        if not scoped:
            continue
        # Longest-first so a registered `acme.com` cannot shadow a
        # registered `git.acme.com`; re.escape so a dot stays a dot.
        alternation = "|".join(re.escape(h) for h in sorted(scoped, key=lambda h: (-len(h), h)))
        H = f"(?:{alternation})"
        grammars.append(template.format(H=H, S=S, T=T))
    # One compiled alternation, not N compiled patterns in a Python loop:
    # this is .search()ed on every line of every reference.
    sha_re = re.compile("|".join(f"(?:{g})" for g in grammars))

    # Stable-tag-pinned permalink (accepted equivalently per the artifact
    # contract's "When to keep an unpinned URL" carve-out). github.com only.
    tag_re = re.compile(
        r"https://github\.com/[^/\s]+/[^/\s]+/(?:blob|tree)/"
        r"v[0-9]+(?:\.[0-9]+){0,2}[A-Za-z0-9.+\-]*/[^\s)\]]+"
    )
    return sha_re, tag_re


def build_path_capturing_res(hosts: dict[str, str | None]) -> list[tuple[str, re.Pattern[str]]]:
    """Return one compiled pattern per forge (not a merged alternation, unlike
    `build_permalink_res`), each with named groups `host`, `repo` and — when
    the forge's citation shape contributes one — `path`.

    Additive alongside `build_permalink_res`: every existing caller of that
    function, and its own shape, are untouched. A caller needs to know which
    forge matched (to know whether a `path` group can exist at all) and needs
    the matched host/repo text (to resolve a citation to a registered source
    by comparing against that source's own `url`, per
    `cited_paths.py` — not merely by host, since two sources can share one),
    which a single merged alternation across all five forges cannot expose.

    `path` is present (though possibly empty, e.g. Bitbucket Server's
    optional repo-root segment) whenever the forge's URL shape carries a
    path/directory; it is absent (no group, not an empty one) when the shape
    has nowhere for a path to live in this match — Azure DevOps's citation
    without a `?path=` query parameter, a genuine repo-wide pin. Extracted
    paths carry any `#L...` fragment and (Azure DevOps's `?path=/a/b`
    parameter only) a leading `/` verbatim; stripping both is the caller's
    job, not this grammar's.

    github's pin additionally accepts the stable-tag shape `build_permalink_res`
    tracks separately as `tag_re` — the artifact contract extends stable-tag
    semantics to github.com only, so no other forge gets a tag alternative.
    """
    if not hosts:
        raise ValueError("build_path_capturing_res: host set is empty")

    S = "[0-9a-f]{40}"
    T = r"[^\s)\]]+"
    V = r"v[0-9]+(?:\.[0-9]+){0,2}[A-Za-z0-9.+\-]*"
    P = f"(?:{S}|{V})"

    # Each template captures `host` and `repo` (the citation's own repo
    # locator, compared against a registered source's `url`) plus `path`
    # where the forge's shape has one. Azure DevOps has no `{T}`-shaped path
    # slot in its URL path at all — its path lives in a `?path=` query
    # parameter, order-independent of `version=GC<sha>`, asserted via a
    # lookahead so the required pin can appear on either side of `path=`.
    templates: tuple[tuple[str, str], ...] = (
        ("github", r"https://(?P<host>{H})/(?P<repo>[^/\s]+/[^/\s]+)/(?:blob|tree)/{P}/(?P<path>{T})"),
        ("gitlab", r"https://(?P<host>{H})/(?P<repo>[^\s]+?)/-/(?:blob|tree)/{S}/(?P<path>{T})"),
        ("bitbucket-server",
         r"https://(?P<host>{H})/(?P<repo>projects/[^/\s]+/repos/[^/\s]+)/browse"
         r"(?:/(?P<path>[^\s?)\]]*))?\?at={S}\b"),
        ("bitbucket-cloud", r"https://(?P<host>{H})/(?P<repo>[^/\s]+/[^/\s]+)/src/{S}/(?P<path>{T})"),
        ("azure-devops",
         r"https://(?P<host>{H})/(?P<repo>[^\s]+/_git/[^\s?)\]]+)"
         r"\?(?=[^\s)\]]*\bversion=GC{S}\b)"
         r"(?:[^\s)\]]*\bpath=(?P<path>[^&\s)\]]+))?[^\s)\]]*"),
    )

    result: list[tuple[str, re.Pattern[str]]] = []
    for forge, template in templates:
        scoped = {h for h, f in hosts.items() if f == forge or f is None}
        if not scoped:
            continue
        alternation = "|".join(re.escape(h) for h in sorted(scoped, key=lambda h: (-len(h), h)))
        H = f"(?:{alternation})"
        result.append((forge, re.compile(template.format(H=H, S=S, T=T, P=P))))
    return result


def classify_lines(lines: list[str], res: tuple[re.Pattern[str], re.Pattern[str]]) -> list[str]:
    """Return a per-line category tag. Categories:
        'prose'    — eligible for paragraph aggregation
        'blank'    — empty / whitespace-only (paragraph separator)
        'link'     — a line that is only a bare permalink (a citation, not
                     prose: excluded from paragraph counts, but still scanned
                     by find_permalink_lines so it covers nearby prose)
        'skip'     — heading / code-fence / table / list / blockquote /
                     html-comment / frontmatter (not part of a prose paragraph)

    `res` is the (sha_re, tag_re) pair from build_permalink_res, resolved
    once per run by the caller.
    """
    sha_re, tag_re = res
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

        # HTML comments (single- or multi-line). Remove complete <!-- ... -->
        # spans on this line, then handle an opener or closer that straddles
        # the line boundary.
        if not in_html_comment:
            if "<!--" in line:
                line_no_comment = re.sub(r"<!--.*?-->", "", line)
                # A '<!--' that survives complete-span removal opens a comment
                # not closed on this line; everything from it onward belongs to
                # the (now multi-line) comment. Keep any real text before it.
                if "<!--" in line_no_comment:
                    in_html_comment = True
                    line_no_comment = line_no_comment[: line_no_comment.index("<!--")]
                if not line_no_comment.strip():
                    cats[i] = "skip"
                    continue
                # Re-evaluate the surviving text against the rules below.
                stripped = line_no_comment.strip()
                line = line_no_comment
        else:
            cats[i] = "skip"
            if "-->" in line:
                in_html_comment = False
                # The closing '-->' may be followed by a new '<!--' that
                # re-opens a comment on the same line (e.g. "done --> x <!-- y").
                # If that re-opener is itself unclosed, stay in comment state.
                tail = line[line.rindex("-->") + 3:]
                if "<!--" in tail and "-->" not in tail[tail.index("<!--"):]:
                    in_html_comment = True
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

        # A line that is *only* a bare permalink is a citation, not prose:
        # don't let it become its own self-covering paragraph or pad the
        # denominator (which would inflate corpus coverage). find_permalink_lines
        # still scans it, so it continues to cover nearby real prose.
        if sha_re.fullmatch(stripped) or tag_re.fullmatch(stripped):
            in_list = False
            cats[i] = "link"
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


def find_permalink_lines(
    lines: list[str], res: tuple[re.Pattern[str], re.Pattern[str]]
) -> set[int]:
    """Return the set of 1-indexed lines that contain an in-scope
    (SHA-pinned or stable-tag-pinned) permalink on an accepted host."""
    sha_re, tag_re = res
    hit: set[int] = set()
    for i, line in enumerate(lines, start=1):
        if sha_re.search(line) or tag_re.search(line):
            hit.add(i)
    return hit


def analyze_file(
    path: Path, res: tuple[re.Pattern[str], re.Pattern[str]]
) -> tuple[int, int, list[tuple[int, str]]]:
    """Return (total_paragraphs, covered_paragraphs, uncovered_list).
    uncovered_list is [(start_line, prefix)] for each uncovered paragraph.
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    cats = classify_lines(lines, res)
    paragraphs = find_paragraphs(cats)
    permalink_lines = find_permalink_lines(lines, res)

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
    parser.add_argument("--threshold", type=float, default=DEFAULT_COVERAGE_THRESHOLD,
                        help=f"Coverage threshold in [0,1]. Default {DEFAULT_COVERAGE_THRESHOLD}.")
    parser.add_argument("--min-paragraphs", type=int, default=5,
                        help="Skip with N/A when corpus has fewer than this "
                        "many in-scope paragraphs. Default 5.")
    parser.add_argument("--require-min-paragraphs", action="store_true",
                        help="Fail (instead of N/A pass) when the corpus has "
                        "fewer than --min-paragraphs in-scope paragraphs. Use for "
                        "curated corpora expected to clear the bar (e.g. the "
                        "bundled examples) so an unexpectedly thin corpus cannot "
                        "pass the gate vacuously.")
    args = parser.parse_args(argv)

    refs = args.references_dir
    if not refs.is_dir():
        print(f"[N/A]  permalink-density: no references emitted yet")
        return 0

    # Resolved once per run — not per file and not per line: the compiled
    # alternation is .search()ed over every line of every reference.
    res = build_permalink_res(accepted_hosts(refs))

    md_files = sorted(refs.rglob("*.md"))
    if not md_files:
        print(f"[N/A]  permalink-density: no references emitted yet")
        return 0

    per_file: list[tuple[Path, int, int, list[tuple[int, str]]]] = []
    total_paragraphs = 0
    total_covered = 0
    for md in md_files:
        total, covered, uncovered = analyze_file(md, res)
        per_file.append((md, total, covered, uncovered))
        total_paragraphs += total
        total_covered += covered

    if total_paragraphs < args.min_paragraphs:
        if args.require_min_paragraphs:
            print(f"[FAIL] permalink-density: only {total_paragraphs} paragraphs "
                  f"in scope (need ≥{args.min_paragraphs}); --require-min-paragraphs "
                  f"is set, so a corpus this thin fails rather than passing N/A")
            return 1
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
