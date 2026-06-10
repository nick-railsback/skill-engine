#!/usr/bin/env bash
# Contextualizer verify.sh — audits a stamped contextualizer's own
# artifacts. Stamped by /skill-engine:engine-bootstrap into the
# contextualizer root; the editing copy ships in the plugin's
# engine-bootstrap-templates/ bundle (see its README.md), with
# byte-identical copies in each bundled example enforced by
# doctrine.sh check 7.
#
# Invariants audited (when applicable):
#
#   1. research/source-paths.json parses with schema_version: 1
#   2. Each sources[i] entry has the expected shape (object, with string
#      id and object lifecycle if present), required fields, valid enum
#      values, and url-or-path mutual presence. Citations resolve by
#      path+content-hash; no per-source chunks granularity layer is
#      enforced.
#   3. Navigator file <slug>-context/SKILL.md exists with valid
#      frontmatter (both opening and closing --- delimiters; BOM-tolerant)
#   4. Catalog rows ↔ references/ files bijection — strict 1:1 (catalog
#      duplicates surface as failures); HTML-comment example links in
#      stamped templates are filtered before regex extraction
#   5. Each references/*.md carries NO YAML frontmatter — name:/description:
#      are scoped to the navigator SKILL.md only; a reference whose first
#      non-blank line is `---` fails the check (BOM-tolerant)
#
# Skip-with-pass cases (mark [N/A], not [FAIL]):
#
#   - sources: [] (fresh bootstrap with no inputs — vanishingly rare)
#   - references/ absent (no references emitted yet — typical between
#     bootstrap and first DISCOVER emit pass)
#
# This script audits only the contextualizer it sits in. Engine-repo
# invariants (doctrine greps, template/example sync, version parity) are
# audited separately by plugin/skill-engine/tests/doctrine.sh in the
# engine repo's CI — the two surfaces are intentionally disjoint.
#
# Tool surface: bash + jq + standard POSIX utilities. No third-party deps.

set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CTX_ROOT="${CTX_ROOT:-$SCRIPT_DIR}"

passed=0
failed=0

pass() {
  passed=$((passed + 1))
  printf '  [PASS] %s\n' "$1"
}

fail() {
  failed=$((failed + 1))
  printf '  [FAIL] %s\n' "$1"
}

skip() {
  passed=$((passed + 1))
  printf '  [N/A]  %s\n' "$1"
}

warn() {
  printf '  [WARN] %s\n' "$1" >&2
}

run_check() {
  printf '\n=== %s ===\n' "$1"
}

# Strip HTML comments from markdown on stdin, comment-robustly. Used by the
# catalog-bijection (Check 4) and skill-json-trijection (Check 9) checks so a
# `(references/foo.md)` link inside a comment is not counted as a catalog row —
# and, just as important, so a *live* catalog row is never dropped by a stray
# comment marker. It handles:
#   - same-line `<!-- ... -->`, several per line and comments flanking a link,
#     via a shortest-match index() loop (a greedy `s/<!--.*-->//` would eat the
#     link sitting between two comments);
#   - genuine multi-line `<!-- ... -->` blocks (e.g. a commented-out draft row),
#     tracked across lines with an in_block flag.
# A dangling `<!--` (no closing `-->` on its line) opens a block only when it
# begins the line (modulo leading whitespace); a dangling `<!--` appearing
# mid-line — e.g. literal text in a table cell — is left as-is, so that row and
# every row after it survive. The single shape this does not catch (a block
# opener placed mid-line *after* a complete inline comment on the same line) is
# never emitted by the engine, and catching it would re-drop the stray-marker
# rows this exists to preserve. POSIX awk only (index/substr/sub) for portability.
strip_md_comments() {
  awk '
  {
    line = $0
    if (in_block) {
      idx = index(line, "-->")
      if (idx == 0) { next }
      line = substr(line, idx + 3)
      in_block = 0
    }
    while ((s = index(line, "<!--")) > 0) {
      rest = substr(line, s + 4)
      e = index(rest, "-->")
      if (e == 0) break
      line = substr(line, 1, s - 1) substr(rest, e + 3)
    }
    if (line ~ /^[[:space:]]*<!--/ && index(line, "-->") == 0) {
      sub(/<!--.*/, "", line)
      in_block = 1
    }
    print line
  }
  '
}

if ! command -v jq >/dev/null 2>&1; then
  printf 'verify.sh requires jq. Install via your package manager (brew install jq; apt install jq).\n' >&2
  exit 2
fi

# Helper: extract frontmatter content + signal opening/closing-delimiter
# state via exit code:
#   0 = valid (both --- delimiters present)
#   1 = no opening --- at start
#   2 = opened but never closed (no second ---)
#
# Strips an optional UTF-8 BOM from the first line before checking, so
# files authored with a BOM don't fail the --- match incorrectly.
extract_frontmatter() {
  awk '
    BEGIN { state = 0; saw_close = 0 }
    NR == 1 { sub(/^\xef\xbb\xbf/, "") }
    /^---$/ {
      state++
      if (state == 2) { saw_close = 1; exit 0 }
      next
    }
    state == 1 { print }
    END {
      if (state == 0) exit 1
      if (saw_close == 0) exit 2
    }
  ' "$1" 2>/dev/null
}

# Extract scheme + host + port from a URL. POSIX-portable.
url_origin() {
  printf '%s' "$1" | sed -E 's#^(https?://[^/]+).*#\1#'
}

# Escape ERE metacharacters in a literal string so it can be interpolated
# into a grep -E pattern as a fixed substring. Source ids / member names /
# component ids come from source-paths.json and may carry metacharacters
# (e.g. 'my.pkg', 'c++'); unescaped, '.' or '+' would match arbitrarily and
# wrongly suppress an uncited-* warning.
ere_escape() {
  printf '%s' "$1" | sed 's/[][(){}.*+?^$|\\]/\\&/g'
}

# ────────────────────────────────────────────────────────────────────────
# Check 1 — source-paths.json shape (source-paths-shape)
# ────────────────────────────────────────────────────────────────────────
run_check "source-paths.json shape (source-paths-shape)"

sp_file="$CTX_ROOT/research/source-paths.json"

if [ ! -f "$sp_file" ]; then
  fail "research/source-paths.json missing — bootstrap did not complete or the file was deleted"
else
  if ! jq empty "$sp_file" >/dev/null 2>&1; then
    fail "research/source-paths.json is not valid JSON"
  elif ! jq -e '(.schema_version | type) == "number" and .schema_version == 1' "$sp_file" >/dev/null 2>&1; then
    fail "research/source-paths.json: schema_version must be integer 1 (additive evolution; v1 still current)"
  elif ! jq -e '(.sources | type) == "array"' "$sp_file" >/dev/null 2>&1; then
    fail "research/source-paths.json: sources must be an array"
  else
    pass "research/source-paths.json parses with schema_version: 1 and sources[] array"
  fi
fi

# ────────────────────────────────────────────────────────────────────────
# Check 2 — Source entries: thin per-source schema (source-entries)
# ────────────────────────────────────────────────────────────────────────
#
# Pre-shape predicate guards against entries that aren't objects, ids
# that aren't strings, or lifecycle that isn't an object — failure modes
# that field extraction would silently swallow.
#
# Required fields per entry: id (non-empty string), kind, status,
# lifecycle.state, AND at least one of url-or-path must be non-empty.
# archived and other additive fields are tolerated but not required at
# this check (additive schema evolution). The chunks granularity layer
# retires entirely — Check 2 does NOT inspect or require
# sources[i].chunks[]; legacy files carrying chunks[] are migrated
# transparently by REFRESH.
#
# Enum constraints:
#   kind             ∈ {git-managed, external-doc, local-path}
#   lifecycle.state  ∈ {reachable, moved, removed, unknown}
#   status           ∈ {intake, proposed, confirmed, rejected}
#
# Optional `branch` field (additive, git-managed only): when present,
# must match git-ref-safe regex ^[A-Za-z0-9._/-]+$ and must pair with
# kind == git-managed. Specifying a branch on an external-doc or
# local-path source is a schema violation (the field is meaningless on
# non-git kinds). Absent ⇒ downstream code uses HEAD.
#
run_check "Source entries: thin per-source schema (source-entries)"

# Short-circuit when Check 1 has already detected a fatal upstream
# defect (file missing, non-JSON, or sources is not an array). The
# guard prevents Check 2 from emitting a false [PASS] line based on
# garbage extraction when .sources is e.g. a string ("not-an-array")
# whose jq length yields a positive integer but whose to_entries[]
# iteration silently fails.
if [ ! -f "$sp_file" ] || ! jq empty "$sp_file" >/dev/null 2>&1; then
  skip "Cannot validate source entries — source-paths.json missing or unparseable (see Check 1)"
elif ! jq -e '(.sources | type) == "array"' "$sp_file" >/dev/null 2>&1; then
  skip "Cannot validate source entries — .sources is not a JSON array (see Check 1)"
else
  shape_violation=$(jq -r '
    .sources
    | to_entries[]
    | select(
        (.value | type != "object")
        or ((.value | has("id")) and ((.value.id | type) != "string"))
        or ((.value | has("lifecycle")) and ((.value.lifecycle | type) != "object"))
      )
    | .key | tostring
  ' "$sp_file" 2>/dev/null | head -1)

  if [ -n "$shape_violation" ]; then
    fail "sources[$shape_violation]: entry has wrong shape (not an object, or id is not string, or lifecycle is not object)"
  else
    src_count=$(jq -r '.sources | length' "$sp_file" 2>/dev/null)
    if [ "$src_count" = "0" ]; then
      skip "sources[] is empty — no sources registered yet (re-run /skill-engine:engine-bootstrap with at least one source)"
    else
      entries_ok=1

      # Line-separated records via 0x1f field separator. Field values
      # (id, kind, status, lifecycle.state) are short kebab-case / URL /
      # path strings without embedded newlines.
      while IFS=$'\x1f' read -r idx id kind src_status state url src_path branch crawl_mode; do
        [ -n "${idx:-}" ] || continue
        if [ -z "$id" ]; then
          fail "sources[$idx] missing required field: id"
          entries_ok=0
          continue
        fi
        case "$kind" in
          git-managed|external-doc|local-path|web-doc) ;;
          *) fail "sources[$idx] ($id): kind '$kind' not in {git-managed, external-doc, local-path, web-doc}"; entries_ok=0 ;;
        esac
        case "$state" in
          reachable|moved|removed|unknown) ;;
          *) fail "sources[$idx] ($id): lifecycle.state '$state' not in {reachable, moved, removed, unknown}"; entries_ok=0 ;;
        esac
        if [ -z "$src_status" ]; then
          fail "sources[$idx] ($id) missing required field: status"
          entries_ok=0
        else
          case "$src_status" in
            intake|proposed|confirmed|rejected) ;;
            *) fail "sources[$idx] ($id): status '$src_status' not in {intake, proposed, confirmed, rejected}"; entries_ok=0 ;;
          esac
        fi
        case "$kind" in
          git-managed)
            if [ -z "$url" ]; then
              fail "sources[$idx] ($id): url is required when kind is git-managed"
              entries_ok=0
            fi
            ;;
          web-doc)
            if [ -z "$url" ]; then
              fail "sources[$idx] ($id): url is required when kind is web-doc"
              entries_ok=0
            fi
            if [ -n "$src_path" ]; then
              fail "sources[$idx] ($id): path '$src_path' set on kind 'web-doc' — web-doc sources are URL-addressed, not path-addressed"
              entries_ok=0
            fi
            ;;
          external-doc)
            if [ -z "$src_path" ]; then
              fail "sources[$idx] ($id): path is required when kind is external-doc"
              entries_ok=0
            fi
            if [ -n "$url" ]; then
              fail "sources[$idx] ($id): url '$url' set on kind 'external-doc' — external-doc sources are path-addressed (pre-curated local markdown), not URL-addressed"
              entries_ok=0
            fi
            ;;
          local-path)
            if [ -z "$src_path" ]; then
              fail "sources[$idx] ($id): path is required when kind is local-path"
              entries_ok=0
            fi
            if [ -n "$url" ]; then
              fail "sources[$idx] ($id): url '$url' set on kind 'local-path' — local-path sources are filesystem-addressed, not URL-addressed"
              entries_ok=0
            fi
            ;;
        esac
        if [ -n "$branch" ]; then
          if [ "$kind" != "git-managed" ]; then
            fail "sources[$idx] ($id): branch '$branch' set on kind '$kind' — branch is git-managed only"
            entries_ok=0
          fi
          case "$branch" in
            *[!A-Za-z0-9._/-]*)
              fail "sources[$idx] ($id): branch '$branch' contains characters outside [A-Za-z0-9._/-]"
              entries_ok=0
              ;;
          esac
        fi
        if [ "$kind" = "web-doc" ]; then
          if [ -z "$crawl_mode" ]; then
            fail "sources[$idx] ($id): crawl_mode is required when kind is web-doc"
            entries_ok=0
          else
            case "$crawl_mode" in
              sitemap|list) ;;
              *) fail "sources[$idx] ($id): crawl_mode '$crawl_mode' not in {sitemap, list}"; entries_ok=0 ;;
            esac
          fi
          sitemap_url="$(jq -r ".sources[$idx].sitemap_url // \"\"" "$sp_file" 2>/dev/null)"
          page_list_len="$(jq -r ".sources[$idx].page_list | if . == null then 0 else length end" "$sp_file" 2>/dev/null)"

          if [ "$crawl_mode" = "list" ]; then
            if [ -n "$sitemap_url" ]; then
              fail "sources[$idx] ($id): sitemap_url is not allowed when crawl_mode is 'list'"
              entries_ok=0
            fi
            if [ "$page_list_len" = "0" ]; then
              if jq -e ".sources[$idx] | has(\"page_list\")" "$sp_file" >/dev/null 2>&1; then
                fail "sources[$idx] ($id): page_list must contain at least one URL"
              else
                fail "sources[$idx] ($id): crawl_mode 'list' requires page_list[]"
              fi
              entries_ok=0
            fi
            if [ "$page_list_len" -gt 0 ]; then
              source_origin="$(url_origin "$url")"
              cross_origin_url=""
              while IFS= read -r page_url; do
                [ -n "$page_url" ] || continue
                page_origin="$(url_origin "$page_url")"
                if [ "$page_origin" != "$source_origin" ]; then
                  cross_origin_url="$page_url"
                  break
                fi
              done < <(jq -r ".sources[$idx].page_list[]" "$sp_file" 2>/dev/null)
              if [ -n "$cross_origin_url" ]; then
                fail "sources[$idx] ($id): page_list URL '$cross_origin_url' is cross-origin (must share origin with source url '$url')"
                entries_ok=0
              fi
            fi
          elif [ "$crawl_mode" = "sitemap" ]; then
            if [ "$page_list_len" != "0" ]; then
              fail "sources[$idx] ($id): page_list is not allowed when crawl_mode is 'sitemap'"
              entries_ok=0
            fi
          fi
        elif [ -n "$crawl_mode" ]; then
          fail "sources[$idx] ($id): crawl_mode '$crawl_mode' set on kind '$kind' — crawl_mode is web-doc only"
          entries_ok=0
        fi
        # crawl_budget bounds apply whenever the key is present, on ANY
        # kind — matching the schema, which bounds the property globally.
        # (Only meaningful for web-doc, but a 9999 budget on a git-managed
        # entry must not pass here while failing schema validation; the two
        # enforcers stay equivalent.)
        if jq -e ".sources[$idx] | has(\"crawl_budget\")" "$sp_file" >/dev/null 2>&1; then
          budget_raw="$(jq -r ".sources[$idx].crawl_budget" "$sp_file" 2>/dev/null)"
          if ! printf '%s' "$budget_raw" | grep -qE '^[0-9]+$'; then
            fail "sources[$idx] ($id): crawl_budget '$budget_raw' is not an integer"
            entries_ok=0
          elif [ "$budget_raw" -lt 1 ] || [ "$budget_raw" -gt 5000 ]; then
            fail "sources[$idx] ($id): crawl_budget '$budget_raw' is not in [1, 5000]"
            entries_ok=0
          fi
        fi
      done < <(jq -r '
        .sources
        | to_entries[]
        | [
            (.key | tostring),
            (.value.id // ""),
            (.value.kind // ""),
            (.value.status // ""),
            (.value.lifecycle.state // ""),
            (.value.url // ""),
            (.value.path // ""),
            (.value.branch // ""),
            (.value.crawl_mode // "")
          ]
        | join("")
      ' "$sp_file" 2>/dev/null)

      if [ "$entries_ok" -eq 1 ]; then
        noun="entries"
        [ "$src_count" -eq 1 ] && noun="entry"
        pass "$src_count source $noun with valid thin per-source schema (id, kind, status, lifecycle.state, url-or-path)"
      fi
    fi
  fi
fi


# ────────────────────────────────────────────────────────────────────────
# Check 3 — Navigator SKILL.md exists with frontmatter (navigator-skill)
# ────────────────────────────────────────────────────────────────────────
#
# The contextualizer is installed as a self-contained Claude Code project
# skill at .claude/skills/<slug>-context/. The navigator SKILL.md sits
# directly at the contextualizer root (which is CTX_ROOT) — not in a
# nested subdirectory. nav_ok records the result for Checks 4 and 8 to
# short-circuit on.
#
run_check "Navigator SKILL.md exists with frontmatter (navigator-skill)"

nav_skill="$CTX_ROOT/SKILL.md"
nav_rel="SKILL.md"
nav_ok=0
if [ ! -f "$nav_skill" ]; then
  fail "$nav_rel missing at contextualizer root — bootstrap did not stamp the navigator, or the file was deleted"
else
  fm=$(extract_frontmatter "$nav_skill")
  fm_rc=$?
  if [ "$fm_rc" -eq 1 ]; then
    fail "$nav_rel missing frontmatter (no --- delimited block at top)"
  elif [ "$fm_rc" -eq 2 ]; then
    fail "$nav_rel frontmatter opened with --- but never closed (no matching second ---)"
  elif ! printf '%s\n' "$fm" | grep -qE '^name:[[:space:]]+'; then
    fail "$nav_rel frontmatter missing required key: name"
  elif ! printf '%s\n' "$fm" | grep -qE '^description:[[:space:]]+'; then
    fail "$nav_rel frontmatter missing required key: description"
  else
    pass "$nav_rel exists with valid frontmatter (name + description)"
    nav_ok=1
  fi
fi

# ────────────────────────────────────────────────────────────────────────
# Check 4 — Catalog ↔ references bijection (catalog-bijection)
# ────────────────────────────────────────────────────────────────────────
#
# Strips HTML comments from the navigator before regex-extracting catalog
# links — stamped templates legitimately carry example links inside
# <!-- ... --> blocks documenting the post-DISCOVER catalog shape.
#
# Detects duplicate catalog rows (no sort -u) — strict 1:1 bijection.
#
# References scan: file form `references/<slug>.md` AND directory form
# `references/<slug>/` (containing a canonical primary `.md` of the same
# basename) are both first-class. Catalog targets are form-tracked
# (FILE: vs DIR: prefix on the extracted slug) so that a catalog row's
# declared form is compared against the on-disk reference's actual form
# — a form mismatch produces a broken rendered link and is surfaced
# explicitly. Nested paths (depth ≥ 3 file, depth-2 `.md` whose
# basename does not match its parent directory, or any sub-directory at
# depth ≥ 2) remain explicit contract violations. Malformed catalog
# targets (missing both `.md` and `/`, consecutive `/`, depth-violating
# slugs, canonical-primary-inside-directory mistakes) surface specific
# diagnostics rather than silently dropping out of the bijection set.
#
run_check "Catalog ↔ references bijection (catalog-bijection)"

if [ ! -d "$CTX_ROOT/references" ]; then
  skip "references/ directory absent — no references emitted yet (run /skill-engine:discover to populate the catalog)"
elif [ "$nav_ok" -ne 1 ]; then
  skip "Catalog bijection requires navigator SKILL.md (see Check 3)"
else
  nav_skill="$CTX_ROOT/SKILL.md"

  # Remove HTML comments before harvesting catalog links, so a commented-out
  # row does not count and an inline annotation (e.g. a trailing
  # `<!-- nosemgrep: ... -->`) does not drop the live row it sits on. See
  # strip_md_comments above for why this is an awk state machine and not a
  # `sed s/<!--.*-->//g; /<!--/,/-->/d` (greedy same-line match, and a range
  # that over-deletes to EOF on an inline comment).
  nav_stripped=$(strip_md_comments < "$nav_skill" 2>/dev/null)

  # Catalog targets: extract `(references/<inner>)`, trim whitespace,
  # classify into FILE:<slug> / DIR:<slug>, and emit specific diagnostics
  # for malformed shapes (collected here, emitted from inside the bijection
  # block so they're attributed to the check rather than firing during the
  # silent-skip empty-state guard).
  cat_targets=()              # FILE:<slug> or DIR:<slug>
  malformed_target_lines=()   # diagnostic strings for malformed catalog targets
  while IFS= read -r target; do
    [ -n "$target" ] || continue

    # Trim leading + trailing whitespace (a stray space inside the parens
    # would otherwise cause the suffix discrimination to fall through and
    # the entire row to silently disappear from the bijection set).
    target="${target#"${target%%[![:space:]]*}"}"
    target="${target%"${target##*[![:space:]]}"}"
    [ -n "$target" ] || continue

    # Consecutive `/` anywhere in the target is a typo class (`foo//`,
    # `foo//bar/`, etc.). Surface as a specific diagnostic rather than
    # silently normalizing.
    case "$target" in
      *//*)
        malformed_target_lines+=("Catalog row target references/$target contains consecutive '/' characters — likely typo; expected file form references/<slug>.md or directory form references/<slug>/")
        continue
        ;;
    esac

    case "$target" in
      */)
        # Directory-form candidate. Strip the trailing `/`; if any internal
        # `/` remains, the target encodes a depth-violating path and is
        # rejected with a specific diagnostic.
        slug="${target%/}"
        case "$slug" in
          */*)
            malformed_target_lines+=("Catalog row target references/$target encodes a nested path; references are at depth-1 only (file form references/<slug>.md or directory form references/<slug>/)")
            continue
            ;;
        esac
        if [ -z "$slug" ]; then
          malformed_target_lines+=("Catalog row target references/$target has an empty slug")
          continue
        fi
        cat_targets+=("DIR:$slug")
        ;;
      *.md)
        # File-form candidate, or the canonical-primary-inside-directory
        # mistake (e.g., `(references/foo/foo.md)` instead of
        # `(references/foo/)`), or a generic nested-path target.
        case "$target" in
          */*.md)
            dir_part="${target%/*}"
            inner_full="${target##*/}"
            inner_slug="${inner_full%.md}"
            if [ "$dir_part" = "$inner_slug" ]; then
              malformed_target_lines+=("Catalog row references/$target points at the canonical primary inside a directory-form reference; the directory-form catalog target should be references/$dir_part/ (trailing-slash to disambiguate from file form)")
            else
              malformed_target_lines+=("Catalog row target references/$target encodes a nested path; references are at depth-1 only (file form references/<slug>.md or directory form references/<slug>/)")
            fi
            continue
            ;;
        esac
        slug="${target%.md}"
        if [ -z "$slug" ]; then
          malformed_target_lines+=("Catalog row target references/$target has an empty slug")
          continue
        fi
        cat_targets+=("FILE:$slug")
        ;;
      *)
        malformed_target_lines+=("Catalog row target references/$target has neither a .md suffix nor a trailing / — file form requires .md, directory form requires trailing /")
        continue
        ;;
    esac
  done < <(printf '%s\n' "$nav_stripped" \
    | grep -oE '\(references/[^()]+\)' 2>/dev/null \
    | sed -E 's|^\(references/(.+)\)$|\1|')

  # File-form refs: top-level `*.md` directly under references/.
  file_form_slugs=()
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    fname=$(basename "$f")
    file_form_slugs+=("${fname%.md}")
  done < <(find -L "$CTX_ROOT/references" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)

  # Directory-form refs: top-level subdirectories under references/ (dotfile-
  # prefixed names filtered out — `.git`, `.cache`, etc. inside references/
  # are clearly authoring accidents, not directory-form references). A
  # directory qualifies as a primary iff it contains a canonical primary
  # `.md` of the same basename; directories lacking that canonical primary
  # surface as a specific failure further down — they are NOT silently
  # skipped.
  dir_form_valid_slugs=()
  dir_form_broken_slugs=()
  while IFS= read -r -d '' d; do
    [ -n "$d" ] || continue
    dname=$(basename "$d")
    if [ -f "$d/$dname.md" ]; then
      dir_form_valid_slugs+=("$dname")
    else
      dir_form_broken_slugs+=("$dname")
    fi
  done < <(find -L "$CTX_ROOT/references" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 2>/dev/null)

  # Nested-path scan: any `.md` at depth ≥ 3, OR any `.md` at depth-2 whose
  # basename does NOT match its parent directory's basename. The canonical
  # primary at depth-2 (basename matches directory) is permitted under the
  # directory-form contract; anything else at depth-2 is a contract violation.
  nested_refs=()
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    rel="${f#"$CTX_ROOT/references/"}"
    seg_count=$(awk -F/ '{print NF}' <<<"$rel")
    if [ "$seg_count" -ge 3 ]; then
      nested_refs+=("$rel")
    elif [ "$seg_count" -eq 2 ]; then
      parent=$(dirname "$rel")
      base=$(basename "$rel" .md)
      if [ "$parent" != "$base" ]; then
        nested_refs+=("$rel")
      fi
    fi
  done < <(find -L "$CTX_ROOT/references" -mindepth 2 -type f -name '*.md' -print0 2>/dev/null)

  # Sub-directory scan: any directory at depth ≥ 2 under references/ is a
  # contract violation regardless of contents. The `.md`-only nested scan
  # above misses empty sub-directories and sub-directories carrying only
  # non-`.md` assets, both of which the depth-1 doctrine explicitly forbids.
  nested_dirs=()
  while IFS= read -r -d '' d; do
    [ -n "$d" ] || continue
    nested_dirs+=("${d#"$CTX_ROOT/references/"}")
  done < <(find -L "$CTX_ROOT/references" -mindepth 2 -type d -print0 2>/dev/null)

  if [ "${#file_form_slugs[@]}" -eq 0 ] \
      && [ "${#dir_form_valid_slugs[@]}" -eq 0 ] \
      && [ "${#dir_form_broken_slugs[@]}" -eq 0 ] \
      && [ "${#cat_targets[@]}" -eq 0 ] \
      && [ "${#malformed_target_lines[@]}" -eq 0 ] \
      && [ "${#nested_refs[@]}" -eq 0 ] \
      && [ "${#nested_dirs[@]}" -eq 0 ]; then
    skip "references/ exists but no *.md files yet (catalog also empty — consistent)"
  else
    bij_ok=1

    # Surface malformed catalog targets first — they're the user-input layer
    # and their diagnostics are usually the most actionable.
    for line in "${malformed_target_lines[@]:-}"; do
      [ -n "$line" ] || continue
      fail "$line"
      bij_ok=0
    done

    # Duplicate-form detection: a slug appearing as BOTH file form AND
    # directory form (valid OR broken) is a duplicate-primary violation
    # (a reference may not exist in both forms simultaneously). The
    # duplicated slug is recorded but kept in the canonical slug set
    # exactly once (counted via its file-form entry).
    duplicate_form_slugs=()
    canonical_fs_slugs=()
    for slug in "${file_form_slugs[@]:-}"; do
      [ -n "$slug" ] || continue
      canonical_fs_slugs+=("$slug")
    done
    for slug in "${dir_form_valid_slugs[@]:-}"; do
      [ -n "$slug" ] || continue
      dup=0
      for s in "${file_form_slugs[@]:-}"; do
        if [ "$s" = "$slug" ]; then dup=1; break; fi
      done
      if [ "$dup" -eq 1 ]; then
        duplicate_form_slugs+=("$slug")
      else
        canonical_fs_slugs+=("$slug")
      fi
    done
    # A broken directory-form whose slug ALSO has a file-form is still a
    # duplicate-primary violation regardless of the broken side's canonical
    # primary status — the invariant fires on the cross-form presence, not
    # the validity of each side.
    for slug in "${dir_form_broken_slugs[@]:-}"; do
      [ -n "$slug" ] || continue
      for s in "${file_form_slugs[@]:-}"; do
        if [ "$s" = "$slug" ]; then
          duplicate_form_slugs+=("$slug")
          break
        fi
      done
    done

    for dup in "${duplicate_form_slugs[@]:-}"; do
      [ -n "$dup" ] || continue
      fail "duplicate primary for reference $dup: file form references/$dup.md AND directory form references/$dup/ both present"
      bij_ok=0
    done

    for nr in "${nested_refs[@]:-}"; do
      [ -n "$nr" ] || continue
      fail "references/$nr is at a nested path that violates the depth-1 contract (only the canonical primary <slug>/<slug>.md is permitted at depth-2 inside a directory-form reference)"
      bij_ok=0
    done

    for brk in "${dir_form_broken_slugs[@]:-}"; do
      [ -n "$brk" ] || continue
      fail "references/$brk/ is a directory but the canonical primary references/$brk/$brk.md is missing"
      bij_ok=0
    done

    for nd in "${nested_dirs[@]:-}"; do
      [ -n "$nd" ] || continue
      fail "references/$nd/ is a sub-directory under a directory-form reference — sub-directories are forbidden (depth-2+ paths fail regardless of file extension)"
      bij_ok=0
    done

    # Duplicate-row detection: a catalog row repeated for the same canonical
    # slug across all forms (file form OR directory form OR both).
    cat_slugs_only=()
    for entry in "${cat_targets[@]:-}"; do
      [ -n "$entry" ] || continue
      cat_slugs_only+=("${entry#*:}")
    done
    if [ "${#cat_slugs_only[@]}" -gt 0 ]; then
      dup_list=$(printf '%s\n' "${cat_slugs_only[@]}" | sort | uniq -d)
      if [ -n "$dup_list" ]; then
        while IFS= read -r dup; do
          [ -n "$dup" ] || continue
          fail "Catalog has duplicate rows pointing at references/$dup (strict 1:1 bijection violation)"
          bij_ok=0
        done < <(printf '%s\n' "$dup_list")
      fi
    fi

    # Phantom-row + form-mismatch check: every catalog slug must match a
    # canonical fs slug AND the catalog row's declared form must match the
    # on-disk reference's actual form (a form mismatch produces a broken
    # rendered Markdown link). Slugs already surfaced via a more specific
    # failure (broken directory or duplicate form) are skipped to avoid
    # double-firing.
    for entry in "${cat_targets[@]:-}"; do
      [ -n "$entry" ] || continue
      cat_form="${entry%%:*}"
      slug="${entry#*:}"

      skip_phantom=0
      for brk in "${dir_form_broken_slugs[@]:-}"; do
        if [ "$brk" = "$slug" ]; then skip_phantom=1; break; fi
      done
      if [ "$skip_phantom" -eq 0 ]; then
        for dup in "${duplicate_form_slugs[@]:-}"; do
          if [ "$dup" = "$slug" ]; then skip_phantom=1; break; fi
        done
      fi
      [ "$skip_phantom" -eq 1 ] && continue

      fs_form=""
      for f in "${file_form_slugs[@]:-}"; do
        if [ "$f" = "$slug" ]; then fs_form="FILE"; break; fi
      done
      if [ -z "$fs_form" ]; then
        for d in "${dir_form_valid_slugs[@]:-}"; do
          if [ "$d" = "$slug" ]; then fs_form="DIR"; break; fi
        done
      fi

      if [ -z "$fs_form" ]; then
        if [ "$cat_form" = "DIR" ]; then
          fail "Catalog row points at references/$slug/ but no matching reference exists (file or directory)"
        else
          fail "Catalog row points at references/$slug.md but no matching reference exists (file or directory)"
        fi
        bij_ok=0
      elif [ "$cat_form" != "$fs_form" ]; then
        if [ "$cat_form" = "DIR" ]; then
          fail "Catalog row references/$slug/ declares directory form but the on-disk reference is file form references/$slug.md — link will render broken"
        else
          fail "Catalog row references/$slug.md declares file form but the on-disk reference is directory form references/$slug/ — link will render broken"
        fi
        bij_ok=0
      fi
    done

    # Orphan check: every canonical fs slug must appear in the catalog
    # (in some form — form-mismatch is surfaced by the phantom side). The
    # error message distinguishes file form from directory form for
    # diagnostic clarity.
    for fs in "${canonical_fs_slugs[@]:-}"; do
      [ -n "$fs" ] || continue
      found=0
      for entry in "${cat_targets[@]:-}"; do
        slug="${entry#*:}"
        if [ "$slug" = "$fs" ]; then found=1; break; fi
      done
      if [ "$found" -ne 1 ]; then
        is_dir=0
        for dv in "${dir_form_valid_slugs[@]:-}"; do
          if [ "$dv" = "$fs" ]; then is_dir=1; break; fi
        done
        if [ "$is_dir" -eq 1 ]; then
          fail "references/$fs/ exists with canonical primary but no catalog row points at it (run /skill-engine:self-audit to repair)"
        else
          fail "references/$fs.md exists but no catalog row points at it (run /skill-engine:self-audit to repair)"
        fi
        bij_ok=0
      fi
    done

    if [ "$bij_ok" -eq 1 ]; then
      total=${#canonical_fs_slugs[@]}
      noun="references"
      [ "$total" -eq 1 ] && noun="reference"
      pass "Catalog ↔ references bijection valid ($total $noun, all linked from catalog)"
    fi
  fi
fi

# ────────────────────────────────────────────────────────────────────────
# Check 5 — Reference frontmatter (reference-frontmatter)
# ────────────────────────────────────────────────────────────────────────
run_check "Reference frontmatter (reference-frontmatter)"

if [ ! -d "$CTX_ROOT/references" ]; then
  skip "references/ directory absent — no references to validate (see Check 4)"
else
  ref_count=0
  fm_ok=1
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    ref_count=$((ref_count + 1))
    rel="${f#"$CTX_ROOT/"}"
    # Reference files are pure Markdown with no YAML frontmatter (matches
    # Anthropic's canonical Agent Skills practice — the spec scopes
    # name:/description: to SKILL.md only). Strip an optional UTF-8 BOM
    # before checking so files authored with a BOM don't false-positive.
    #
    # The first non-blank line is matched exactly against a frontmatter
    # opener (`---`, optional trailing space) rather than a loose 3-char
    # prefix: this catches both closed and opened-but-never-closed
    # frontmatter (both start with this line) without false-flagging a
    # `--- some heading` or a `----` thematic break. The opened-but-never-
    # closed / missing-name detection for SKILL.md lives in Check 3
    # (extract_frontmatter), which references intentionally do not need.
    first_line=$(awk 'BEGIN{FS=""} /[^[:space:]]/ {
      sub(/^\xef\xbb\xbf/, "")
      print; exit
    }' "$f" 2>/dev/null)
    if printf '%s' "$first_line" | grep -qE '^---[[:space:]]*$'; then
      fail "$rel starts with YAML frontmatter — references carry no frontmatter (02-artifact-contract.md § No YAML frontmatter on references)"
      fm_ok=0
    fi
  done < <(find -L "$CTX_ROOT/references" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)

  if [ "$ref_count" -eq 0 ]; then
    skip "references/ exists but no *.md files yet"
  elif [ "$fm_ok" -eq 1 ]; then
    noun="references"
    [ "$ref_count" -eq 1 ] && noun="reference"
    pass "$ref_count $noun start with a Markdown body (no YAML frontmatter)"
  fi
fi

# ────────────────────────────────────────────────────────────────────────
# Check 5.5 — External-doc / web-doc provenance frontmatter
#             (external-doc-frontmatter)
# ────────────────────────────────────────────────────────────────────────
#
# Every .md file under an external-doc source's path AND every .md file
# under a web-doc source's cache directory must carry three provenance
# keys: source_url, crawl_date, decay. Pinned regexes per the artifact
# contract (docs/02-artifact-contract.md).
#
# This check walks two roots:
#   - external-doc: <CTX_ROOT>/<source.path>/  (recursive, follow symlinks
#     with realpath containment guard inside the walk loop)
#   - web-doc: ~/.cache/skill-engine/web-doc/<source_id>-<crawl_id>/
#     (recursive, only when source.status == "confirmed" and
#     lifecycle.last_crawl_id is set)
#
run_check "External-doc / web-doc provenance frontmatter (external-doc-frontmatter)"

if [ ! -f "$sp_file" ] || ! jq -e '(.sources | type) == "array"' "$sp_file" >/dev/null 2>&1; then
  skip "Cannot evaluate external-doc-frontmatter — source-paths.json missing or malformed (see Check 1)"
else
  fm_ok=1
  fm_count=0
  walk_roots=()

  # external-doc roots
  while IFS=$'\x1f' read -r ext_kind ext_path; do
    [ "$ext_kind" = "external-doc" ] || continue
    [ -n "$ext_path" ] || continue
    abs="$CTX_ROOT/$ext_path"
    [ -e "$abs" ] || continue
    walk_roots+=("$abs")
  done < <(jq -r '.sources[] | [(.kind // ""), (.path // "")] | join("")' "$sp_file" 2>/dev/null)

  # web-doc cache roots (only when last_crawl_id is set and status confirmed)
  cache_root="${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}"
  while IFS=$'\x1f' read -r wd_kind wd_status wd_sid wd_crawl_id; do
    [ "$wd_kind" = "web-doc" ] || continue
    [ "$wd_status" = "confirmed" ] || continue
    [ -n "$wd_crawl_id" ] || continue
    cache_dir="$cache_root/web-doc/$wd_sid-$wd_crawl_id"
    [ -d "$cache_dir" ] || continue
    walk_roots+=("$cache_dir")
  done < <(jq -r '.sources[] | [(.kind // ""), (.status // ""), (.id // ""), (.lifecycle.last_crawl_id // "")] | join("")' "$sp_file" 2>/dev/null)

  # Empty-array iteration under `set -u` errors on bash < 4.4; the
  # `${walk_roots[@]+…}` guard sidesteps that without changing non-empty
  # semantics. The `fm_count == 0` skip path downstream still fires.
  for root in ${walk_roots[@]+"${walk_roots[@]}"}; do
    while IFS= read -r -d '' f; do
      # Realpath containment guard: skip any file whose canonical path
      # is not inside the walk root. Defends against symlinked escapes
      # under external-doc paths or web-doc cache directories.
      canon="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)/$(basename "$f")"
      root_canon="$(cd "$root" 2>/dev/null && pwd -P)"
      case "$canon" in
        "$root_canon"/*) ;;
        *) continue ;;
      esac
      fm_count=$((fm_count + 1))
      fm=$(extract_frontmatter "$f")
      rc=$?
      rel="${f#"$CTX_ROOT/"}"
      [ "$rel" = "$f" ] && rel="${f#"$cache_root/"}"
      if [ "$rc" -eq 1 ] || [ "$rc" -eq 2 ]; then
        fail "$rel missing or malformed frontmatter"
        fm_ok=0
        continue
      fi
      if ! printf '%s\n' "$fm" | grep -qE '^source_url:[[:space:]]+https?://[^[:space:]]+$'; then
        fail "$rel frontmatter source_url missing or fails regex ^https?://[^[:space:]]+$"
        fm_ok=0
      fi
      if ! printf '%s\n' "$fm" | grep -qE '^crawl_date:[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$'; then
        fail "$rel frontmatter crawl_date missing or not ISO-8601 UTC"
        fm_ok=0
      fi
      if ! printf '%s\n' "$fm" | grep -qE '^decay:[[:space:]]+(none|[1-9][0-9]*[dwmy])$'; then
        fail "$rel frontmatter decay missing or not in {none, Nd, Nw, Nm, Ny}"
        fm_ok=0
      fi
    done < <(find -L "$root" -type f -name '*.md' -print0 2>/dev/null)
  done

  if [ "$fm_count" -eq 0 ]; then
    skip "No external-doc paths or web-doc cache directories present to validate"
  elif [ "$fm_ok" -eq 1 ]; then
    pass "$fm_count provenance file(s) with valid frontmatter"
  fi
fi

# ────────────────────────────────────────────────────────────────────────
# Check 5.6 — web-doc snapshot present (web-doc-snapshot-present)
# ────────────────────────────────────────────────────────────────────────
#
# WARN, not FAIL: gitignored cache may legitimately be missing on a
# fresh clone. Actionable fix is "run /skill-engine:refresh".
#
run_check "Web-doc snapshot present (web-doc-snapshot-present)"

if [ ! -f "$sp_file" ] || ! jq -e '(.sources | type) == "array"' "$sp_file" >/dev/null 2>&1; then
  skip "Cannot evaluate web-doc-snapshot-present — source-paths.json missing or malformed"
else
  cache_root="${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}"
  missing_count=0
  total_count=0
  while IFS=$'\x1f' read -r snap_kind snap_status snap_sid snap_crawl_id; do
    [ "$snap_kind" = "web-doc" ] || continue
    [ "$snap_status" = "confirmed" ] || continue
    total_count=$((total_count + 1))
    if [ -z "$snap_crawl_id" ]; then
      warn "web-doc source '$snap_sid' has no lifecycle.last_crawl_id — run /skill-engine:refresh to seed"
      missing_count=$((missing_count + 1))
      continue
    fi
    cache_dir="$cache_root/web-doc/$snap_sid-$snap_crawl_id"
    if [ ! -d "$cache_dir" ] || [ -z "$(ls -A "$cache_dir" 2>/dev/null)" ]; then
      warn "web-doc source '$snap_sid' snapshot missing at $cache_dir — run /skill-engine:refresh to seed"
      missing_count=$((missing_count + 1))
    fi
  done < <(jq -r '.sources[] | [(.kind // ""), (.status // ""), (.id // ""), (.lifecycle.last_crawl_id // "")] | join("")' "$sp_file" 2>/dev/null)

  if [ "$total_count" -eq 0 ]; then
    skip "No confirmed web-doc sources to check"
  elif [ "$missing_count" -eq 0 ]; then
    pass "$total_count web-doc snapshot(s) present"
  fi
fi

# ────────────────────────────────────────────────────────────────────────
# Check 6 — Monorepo-coverage heuristic (monorepo-coverage)
# ────────────────────────────────────────────────────────────────────────
#
# When a registered source root contains workspace members (packages/*,
# apps/*, libs/*, crates/*), each top-level workspace member SHOULD have
# ≥1 reference file citing it OR an explicit skip-reason in the post-run
# summary. Surfaces "the model missed whole packages" cases without
# rejecting the corpus outright — the model still decides what is
# essential per the goal-given DISCOVER posture.
#
# Failure mode: warn (not fail). The reviewer remains the backstop trust
# mechanism.
#
run_check "Monorepo-coverage heuristic (monorepo-coverage)"

if [ ! -f "$sp_file" ] || ! jq -e '(.sources | type) == "array"' "$sp_file" >/dev/null 2>&1; then
  skip "Cannot evaluate monorepo-coverage — source-paths.json missing or malformed (see Check 1)"
elif [ "$(jq -r '.sources | length' "$sp_file" 2>/dev/null)" = "0" ]; then
  skip "monorepo-coverage heuristic — no sources to inspect"
else
  monorepo_concerns=0
  while IFS=$'\x1f' read -r src_id src_path; do
    [ -n "$src_path" ] || continue
    [ -d "$src_path" ] || continue
    for ws_dir in "$src_path"/packages "$src_path"/apps "$src_path"/libs "$src_path"/crates; do
      [ -d "$ws_dir" ] || continue
      while IFS= read -r -d '' member; do
        member_name=$(basename "$member")
        cited=0
        if [ -d "$CTX_ROOT/references" ]; then
          if grep -rqE "(packages|apps|libs|crates)/$(ere_escape "$member_name")\b" "$CTX_ROOT/references" 2>/dev/null; then
            cited=1
          fi
        fi
        if [ "$cited" -eq 0 ]; then
          monorepo_concerns=$((monorepo_concerns + 1))
          printf '  [WARN] workspace member %s under %s is not cited in any reference (verify post-run summary for an explicit skip-reason)\n' "$member_name" "$src_id"
        fi
      done < <(find "$ws_dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    done
  done < <(jq -r '.sources[]? | [(.id // ""), (.path // "")] | join("\u001f")' "$sp_file" 2>/dev/null)
  if [ "$monorepo_concerns" -eq 0 ]; then
    pass "monorepo-coverage heuristic clean (no workspace members surfaced as uncited)"
  else
    pass "monorepo-coverage heuristic registered $monorepo_concerns warning(s) above (reviewer to disposition)"
  fi
fi

# ────────────────────────────────────────────────────────────────────────
# Check 7 — Companions-coverage heuristic (companions-coverage)
# ────────────────────────────────────────────────────────────────────────
#
# Proposed companion sources (status='proposed' AND discovered_via !=
# null) SHOULD have a corresponding reference OR an explicit skip-reason
# in the post-run summary. Makes the model's exclusion choices legible
# at the reference level.
#
# Failure mode: warn (not fail).
#
run_check "Companions-coverage heuristic (companions-coverage)"

if [ ! -f "$sp_file" ] || ! jq -e '(.sources | type) == "array"' "$sp_file" >/dev/null 2>&1; then
  skip "Cannot evaluate companions-coverage — source-paths.json missing or malformed (see Check 1)"
elif [ "$(jq -r '.sources | length' "$sp_file" 2>/dev/null)" = "0" ]; then
  skip "companions-coverage heuristic — no sources to inspect"
else
  companion_concerns=0
  while IFS= read -r comp_id; do
    [ -n "$comp_id" ] || continue
    cited=0
    if [ -d "$CTX_ROOT/references" ]; then
      if grep -rqE "\b$(ere_escape "$comp_id")\b" "$CTX_ROOT/references" 2>/dev/null; then
        cited=1
      fi
    fi
    if [ "$cited" -eq 0 ]; then
      companion_concerns=$((companion_concerns + 1))
      printf '  [WARN] proposed companion %s has no reference citing it (verify post-run summary for an explicit skip-reason)\n' "$comp_id"
    fi
  done < <(jq -r '.sources[]? | select(.status == "proposed" and (.discovered_via // null) != null) | .id // empty' "$sp_file" 2>/dev/null)
  if [ "$companion_concerns" -eq 0 ]; then
    pass "companions-coverage heuristic clean (no proposed companions surfaced as uncited)"
  else
    pass "companions-coverage heuristic registered $companion_concerns warning(s) above (reviewer to disposition)"
  fi
fi

# ────────────────────────────────────────────────────────────────────────
# Check 8 — Catalog-density floor (catalog-density)
# ────────────────────────────────────────────────────────────────────────
#
# When a source root contains a non-trivial file count (≥ N=20), the
# contextualizer's catalog SHOULD carry ≥ M=3 rows for that source OR an
# explicit minimal-essence justification in the post-run summary.
# Catches "the model wrote one reference for a 300-file codebase" cases
# without dictating partition shape.
#
# Failure mode: warn (not fail).
#
run_check "Catalog-density floor (catalog-density)"

if [ ! -f "$sp_file" ] || ! jq -e '(.sources | type) == "array"' "$sp_file" >/dev/null 2>&1; then
  skip "Cannot evaluate catalog-density — source-paths.json missing or malformed (see Check 1)"
elif [ "$(jq -r '.sources | length' "$sp_file" 2>/dev/null)" = "0" ]; then
  skip "catalog-density heuristic — no sources to inspect"
elif [ "$nav_ok" -ne 1 ]; then
  skip "Cannot evaluate catalog-density — navigator SKILL.md not located (see Check 3)"
else
  density_concerns=0
  nav_skill="$CTX_ROOT/SKILL.md"
  while IFS=$'\x1f' read -r src_id src_path; do
    [ -n "$src_path" ] || continue
    [ -d "$src_path" ] || continue
    file_count=$(find "$src_path" -maxdepth 6 -type f 2>/dev/null | wc -l | tr -d ' ')
    [ "$file_count" -ge 20 ] || continue
    # Per-source row count keyed off the contract invariant that every
    # reference filename is prefixed with its source id (`<src_id>-*.md`).
    # A navigator-wide count silently passed a large source with zero
    # dedicated references whenever another source contributed ≥3 rows.
    # grep -c prints '0' AND exits 1 on no match, so a trailing `|| echo 0`
    # would append a second line -> "0\n0" -> the integer test below errors
    # and the zero-rows worst case silently passes. Capture the count (always
    # a lone integer when the file is readable) and default only the
    # file-missing/error case.
    catalog_rows=$(grep -cE "\(references/$(ere_escape "$src_id")-[^)]*\.md\)" "$nav_skill" 2>/dev/null)
    catalog_rows=${catalog_rows:-0}
    if [ "$catalog_rows" -lt 3 ]; then
      density_concerns=$((density_concerns + 1))
      printf '  [WARN] source %s has %d files but the catalog carries only %d row(s) (<3); verify post-run summary for a minimal-essence justification\n' "$src_id" "$file_count" "$catalog_rows"
    fi
  done < <(jq -r '.sources[]? | [(.id // ""), (.path // "")] | join("\u001f")' "$sp_file" 2>/dev/null)
  if [ "$density_concerns" -eq 0 ]; then
    pass "catalog-density heuristic clean (no sources surfaced below the row floor)"
  else
    pass "catalog-density heuristic registered $density_concerns warning(s) above (reviewer to disposition)"
  fi
fi

# ────────────────────────────────────────────────────────────────────────
# Check 9 — Optional SKILL.json trijection (skill-json-trijection)
# ────────────────────────────────────────────────────────────────────────
#
# Asserts three-way correspondence between SKILL.md catalog rows, SKILL.json
# non-draft catalog entries, and `*-*.md` reference files when a
# contextualizer opts into the structured machine-readable sibling at
# $CTX_ROOT/SKILL.json. Four states (a/b/c/d):
#
#   (a) SKILL.json absent  -> silent-skip pass (the opt-in default state).
#   (b) invalid JSON       -> fail loud with the path.
#   (c) missing required   -> fail per missing key (name / description /
#       top-level key         catalog).
#   (d) valid + complete   -> trijection logic.
#
# Trijection (state d): tags partitioned by `.draft == true` vs `(.draft //
# false) != true`. Stringified "true" is NOT the draft marker; absence of
# the field is equivalent to draft:false. Drafts are excluded from ALL
# three sides — catalog rows or reference files whose JSON counterpart is
# draft do not participate (the orthogonal catalog-bijection check still
# fires on its own). Set equality runs over `tag` values.
#
# Filesystem enumeration uses `*-*.md` glob (any prefixed reference) —
# handles single-domain `<area-domain>-*.md` and multi-domain per-source-
# slug `<source-slug>-*.md` uniformly. Bare-name companion files (no
# dash prefix) are excluded by glob.
#
# Catalog extraction is anchored to the `## Catalog` block (or per-source
# `## Catalog: <slug>` blocks) via awk so `(references/foo.md)` links
# elsewhere in SKILL.md prose don't get harvested as phantom catalog tags.
# HTML comments inside the catalog block are removed by strip_md_comments (the
# same comment-robust helper Check 4 uses), so a commented-out draft row is not
# counted and a live row carrying an inline annotation is not dropped.
#
# All `sort` and `comm` calls run under `LC_ALL=C` for collation
# stability across user locales. `grep -qFx -- "$tag"` uses `--` so a
# JSON tag starting with `-` does not parse as a grep option.
#
# Draft summary: emit one WARN line per contextualizer naming the count of
# draft entries when >=1. `warn` does NOT increment the pass/fail counter.
#
run_check "Optional SKILL.json trijection (skill-json-trijection)"

sj_path="$CTX_ROOT/SKILL.json"

if [ ! -f "$sj_path" ]; then
  skip "SKILL.json absent — skipping (opt-in machine-readable sibling not present)"
elif [ "$nav_ok" -ne 1 ]; then
  skip "SKILL.json trijection requires navigator SKILL.md (see Check 3)"
else
  ctx_slug=$(basename "$CTX_ROOT")
  sj_md="$CTX_ROOT/SKILL.md"
  refs_dir="$CTX_ROOT/references"

  if ! jq -e . "$sj_path" >/dev/null 2>&1; then
    fail "SKILL.json is not valid JSON"
  else
    missing_keys=""
    for k in name description catalog; do
      if ! jq -e "has(\"$k\")" "$sj_path" >/dev/null 2>&1; then
        missing_keys="${missing_keys}${missing_keys:+ }$k"
      fi
    done
    if [ -n "$missing_keys" ]; then
      for k in $missing_keys; do
        fail "SKILL.json missing required top-level key: $k"
      done
    else
      json_draft_tags=$(jq -r '.catalog[]? | select(.draft == true) | .tag' "$sj_path" 2>/dev/null | LC_ALL=C sort -u)
      json_nondraft_tags=$(jq -r '.catalog[]? | select((.draft // false) != true) | .tag' "$sj_path" 2>/dev/null | LC_ALL=C sort -u)
      draft_count=$(printf '%s\n' "$json_draft_tags" | grep -c '^.' 2>/dev/null || true)
      nondraft_count=$(printf '%s\n' "$json_nondraft_tags" | grep -c '^.' 2>/dev/null || true)

      catalog_block=$(awk '
        /^## Catalog/ { in_cat=1; next }
        in_cat && /^## / { in_cat=0; next }
        in_cat { print }
      ' "$sj_md" 2>/dev/null)

      # Same comment-robust strip as Check 4 (see strip_md_comments above). The
      # block fed in here is already scoped to `## Catalog` / `## Catalog: <slug>`
      # by the awk pass above, so a comment that opens inside the catalog and
      # closes in a later `## ` section is bounded to the block — correct within
      # the trijection's scope.
      catalog_stripped=$(printf '%s\n' "$catalog_block" | strip_md_comments)

      md_tags=$(printf '%s\n' "$catalog_stripped" | { grep -oE '\(references/[^)]+\.md\)' 2>/dev/null || true; } | sed -E 's|^\(references/(.+)\.md\)$|\1|' | LC_ALL=C sort -u)

      if [ -d "$refs_dir" ]; then
        fs_tags=$(find "$refs_dir" -maxdepth 1 -type f -name '*-*.md' 2>/dev/null | sed -E 's|.*/(.+)\.md$|\1|' | LC_ALL=C sort -u)
      else
        fs_tags=""
      fi

      if [ -n "$json_draft_tags" ]; then
        md_tags_filtered=$(LC_ALL=C comm -23 <(printf '%s\n' "$md_tags" | grep -v '^$' || true) <(printf '%s\n' "$json_draft_tags"))
        fs_tags_filtered=$(LC_ALL=C comm -23 <(printf '%s\n' "$fs_tags" | grep -v '^$' || true) <(printf '%s\n' "$json_draft_tags"))
      else
        md_tags_filtered="$md_tags"
        fs_tags_filtered="$fs_tags"
      fi

      union_tags=$(printf '%s\n%s\n%s\n' "$json_nondraft_tags" "$md_tags_filtered" "$fs_tags_filtered" | grep -v '^$' | LC_ALL=C sort -u || true)
      mismatch=0
      while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        in_a=0; in_b=0; in_c=0
        if printf '%s\n' "$json_nondraft_tags" | grep -qFx -- "$tag"; then in_a=1; fi
        if printf '%s\n' "$md_tags_filtered"   | grep -qFx -- "$tag"; then in_b=1; fi
        if printf '%s\n' "$fs_tags_filtered"   | grep -qFx -- "$tag"; then in_c=1; fi
        total=$((in_a + in_b + in_c))
        if [ "$total" -ne 3 ]; then
          where=""
          [ "$in_b" = 1 ] && where="${where}${where:+ + }SKILL.md"
          [ "$in_a" = 1 ] && where="${where}${where:+ + }SKILL.json"
          [ "$in_c" = 1 ] && where="${where}${where:+ + }filesystem"
          fail "skill-json-trijection [$ctx_slug]: $tag only in $where"
          mismatch=1
        fi
      done <<< "$union_tags"

      if [ "$mismatch" -eq 0 ]; then
        pass "skill-json-trijection: 3-way correspondence holds for $ctx_slug ($nondraft_count entries; $draft_count draft excluded)"
      fi

      if [ "$draft_count" -ge 1 ]; then
        warn "skill-json-trijection: $draft_count draft entries excluded from trijection"
      fi
    fi
  fi
fi

# ────────────────────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────────────────────

printf '\n=== Summary ===\n'
printf '  Passed: %d\n' "$passed"
printf '  Failed: %d\n' "$failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi
exit 0
