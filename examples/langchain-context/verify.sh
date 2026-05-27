#!/usr/bin/env bash
# Contextualizer verify.sh
#
# Audits the stamped contextualizer's own artifacts — NOT the engine-
# authoring repo. Stamped by /skill-engine:engine-bootstrap into the
# contextualizer root; ships with the plugin's engine-bootstrap-templates/
# bundle.
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
#   5. Each references/*.md has required frontmatter (both delimiters;
#      BOM-tolerant)
#
# Skip-with-pass cases (mark [N/A], not [FAIL]):
#
#   - sources: [] (fresh bootstrap with no inputs — vanishingly rare)
#   - references/ absent (no references emitted yet — typical between
#     bootstrap and first DISCOVER emit pass)
#
# This script is NOT the engine-authoring verify.sh (which lives in the
# engine repo's templates/verify.sh and audits engine-development
# invariants — chapter ordering, template SHA, worker-prompt mirror, etc.).
# The two scripts have intentionally disjoint scopes.
#
# Tool surface: bash + jq + standard POSIX utilities. No third-party deps.

set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CTX_ROOT="$SCRIPT_DIR"

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

run_check() {
  printf '\n=== %s ===\n' "$1"
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
      while IFS=$'\x1f' read -r idx id kind status state url path; do
        [ -n "${idx:-}" ] || continue
        if [ -z "$id" ]; then
          fail "sources[$idx] missing required field: id"
          entries_ok=0
          continue
        fi
        case "$kind" in
          git-managed|external-doc|local-path) ;;
          *) fail "sources[$idx] ($id): kind '$kind' not in {git-managed, external-doc, local-path}"; entries_ok=0 ;;
        esac
        case "$state" in
          reachable|moved|removed|unknown) ;;
          *) fail "sources[$idx] ($id): lifecycle.state '$state' not in {reachable, moved, removed, unknown}"; entries_ok=0 ;;
        esac
        if [ -z "$status" ]; then
          fail "sources[$idx] ($id) missing required field: status"
          entries_ok=0
        else
          case "$status" in
            intake|proposed|confirmed|rejected) ;;
            *) fail "sources[$idx] ($id): status '$status' not in {intake, proposed, confirmed, rejected}"; entries_ok=0 ;;
          esac
        fi
        if [ -z "$url" ] && [ -z "$path" ]; then
          fail "sources[$idx] ($id): neither url nor path is set — at least one is required"
          entries_ok=0
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
            (.value.path // "")
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
# References scan: flat references/ contract; nested paths surface as
# explicit contract violations.
#
run_check "Catalog ↔ references bijection (catalog-bijection)"

if [ ! -d "$CTX_ROOT/references" ]; then
  skip "references/ directory absent — no references emitted yet (run /skill-engine:discover to populate the catalog)"
elif [ "$nav_ok" -ne 1 ]; then
  skip "Catalog bijection requires navigator SKILL.md (see Check 3)"
else
  nav_skill="$CTX_ROOT/SKILL.md"

  nav_stripped=$(sed -E '/<!--/,/-->/d' "$nav_skill" 2>/dev/null)

  cat_files=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cat_files+=("$f")
  done < <(printf '%s\n' "$nav_stripped" | grep -oE '\(references/[^)]+\.md\)' 2>/dev/null | sed -E 's|^\(references/(.+)\.md\)$|\1.md|')

  ref_files=()
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    ref_files+=("$(basename "$f")")
  done < <(find -L "$CTX_ROOT/references" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)

  nested_refs=()
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    nested_refs+=("${f#"$CTX_ROOT/references/"}")
  done < <(find -L "$CTX_ROOT/references" -mindepth 2 -type f -name '*.md' -print0 2>/dev/null)

  if [ "${#ref_files[@]}" -eq 0 ] && [ "${#cat_files[@]}" -eq 0 ] && [ "${#nested_refs[@]}" -eq 0 ]; then
    skip "references/ exists but no *.md files yet (catalog also empty — consistent)"
  else
    bij_ok=1

    for nr in "${nested_refs[@]:-}"; do
      [ -n "$nr" ] || continue
      fail "references/$nr is at a nested path — references must be flat (top-level *.md files only)"
      bij_ok=0
    done

    if [ "${#cat_files[@]}" -gt 0 ]; then
      dup_list=$(printf '%s\n' "${cat_files[@]}" | sort | uniq -d)
      if [ -n "$dup_list" ]; then
        while IFS= read -r dup; do
          [ -n "$dup" ] || continue
          fail "Catalog has duplicate rows pointing at references/$dup (strict 1:1 bijection violation)"
          bij_ok=0
        done < <(printf '%s\n' "$dup_list")
      fi
    fi

    for f in "${cat_files[@]:-}"; do
      [ -n "$f" ] || continue
      found=0
      for r in "${ref_files[@]:-}"; do
        if [ "$f" = "$r" ]; then found=1; break; fi
      done
      if [ "$found" -ne 1 ]; then
        fail "Catalog row points at references/$f but the file does not exist (flat references/ only)"
        bij_ok=0
      fi
    done

    for r in "${ref_files[@]:-}"; do
      [ -n "$r" ] || continue
      count=0
      for c in "${cat_files[@]:-}"; do
        if [ "$r" = "$c" ]; then count=$((count + 1)); fi
      done
      if [ "$count" -eq 0 ]; then
        fail "references/$r exists but no catalog row points at it (run /skill-engine:self-audit to repair)"
        bij_ok=0
      fi
    done

    if [ "$bij_ok" -eq 1 ]; then
      noun="references"
      [ "${#ref_files[@]}" -eq 1 ] && noun="reference"
      pass "Catalog ↔ references bijection valid (${#ref_files[@]} $noun, all linked from catalog)"
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
    fm=$(extract_frontmatter "$f")
    rc=$?
    if [ "$rc" -eq 1 ]; then
      fail "$rel missing frontmatter (no --- delimited block at top)"
      fm_ok=0
      continue
    elif [ "$rc" -eq 2 ]; then
      fail "$rel frontmatter opened with --- but never closed (no matching second ---)"
      fm_ok=0
      continue
    fi
    if ! printf '%s\n' "$fm" | grep -qE '^name:[[:space:]]+'; then
      fail "$rel frontmatter missing required key: name"
      fm_ok=0
    fi
  done < <(find -L "$CTX_ROOT/references" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)

  if [ "$ref_count" -eq 0 ]; then
    skip "references/ exists but no *.md files yet"
  elif [ "$fm_ok" -eq 1 ]; then
    noun="references"
    [ "$ref_count" -eq 1 ] && noun="reference"
    pass "$ref_count $noun with valid frontmatter"
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
          if grep -rqE "(packages|apps|libs|crates)/${member_name}\b" "$CTX_ROOT/references" 2>/dev/null; then
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
      if grep -rqE "\b${comp_id}\b" "$CTX_ROOT/references" 2>/dev/null; then
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
    catalog_rows=$(grep -cE "\(references/[^)]*\.md\)" "$nav_skill" 2>/dev/null || echo 0)
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
# Summary
# ────────────────────────────────────────────────────────────────────────

printf '\n=== Summary ===\n'
printf '  Passed: %d\n' "$passed"
printf '  Failed: %d\n' "$failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi
exit 0
