#!/usr/bin/env bash
# Feature-scoped test runner for verify.sh's two coverage heuristics —
# monorepo-coverage (Check 6) and catalog-density (Check 8). Today both
# checks read a source's `path` field only, and every git-managed source
# has `path: null` — so `[ -n "$src_path" ]` is false, the per-source loop
# body `continue`s without opening a single file, and the run still prints
# `[PASS] monorepo-coverage heuristic clean` / `[PASS] catalog-density
# heuristic clean` for that source, having inspected nothing. Check 6 also
# globs only `packages/ apps/ libs/ crates/` under `path`, so a Go, Maven,
# or .NET layout surfaces zero workspace members even when a tree is
# available to read.
#
# This oracle is written black-box against the observable contract: given
# a source-paths.json and (where relevant) a clone-cache tree, what do the
# two checks print, and does the exit code change. It stamps the real
# template verify.sh into synthetic contextualizer fixtures under
# `mktemp -d` and reads its own `SKILL_ENGINE_CACHE_ROOT`-driven cache root
# — never the real `~/.cache/skill-engine` — via env-var override.
#
# Expected RED right now, and why: every fixture below that expects an
# `[N/A]` line naming a git-managed source and a "no local tree" reason
# instead sees the source silently skipped and the aggregate "heuristic
# clean" line, because `path` is null for git-managed sources and no cache
# lookup exists yet. The uncited-member and Go-layout fixtures see zero
# workspace members surfaced at all (same null-path skip, plus the
# four-directory-only glob), so the WARN lines they expect never print.
# The .git/-exclusion fixture can't yet distinguish a spurious floor-clearing
# count from a correct one, because catalog-density never opens a
# git-managed tree in the first place. The ambiguous-cache-directory and
# files_of_interest-scoping fixtures depend on cache-tree resolution that
# doesn't exist yet. The schema fixtures see every reject case validate,
# because `workspace_roots` is today an unconstrained unknown key
# (`additionalProperties: true`). The two doc-consistency greps have
# nothing to find.
#
# Expected GREEN right now: the fixture self-checks (file-count arithmetic
# computed by direct enumeration of the fixture as built, never by
# re-deriving what the checks themselves compute); the local-path
# preservation case (untouched code path, `.path` read exactly as before);
# the schema-accept fixtures (an unconstrained unknown key accepts
# anything today, so this is the accept-side complement to the reject
# cases, not a feature test); and both exit-code assertions happen to hold
# today too, since a silent "clean" pass is still an exit-0 pass — they
# stay meaningful post-implementation because N/A and WARN lines will then
# be doing real work and still must not flip the exit code.
#
# Out of scope for this file, checked by the full local suite instead: the
# five stamped verify.sh copies staying byte-identical after `make sync`
# (doctrine check 7), `tests/dogfood-verify/`, `tests/emission-gates/`
# (which pins catalog-density's nav_ok-unset skip-message text — untouched
# by anything here, since every change under test lives inside the
# nav_ok-is-1 branch), every `examples/*/verify.sh`, and
# `bash scripts/ci-local.sh doctrine`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"

TEMPLATE="$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh"
SCHEMA="$PLUGIN_ROOT/engine-bootstrap-templates/source-paths.schema.json"
ARTIFACT_CONTRACT="$PLUGIN_ROOT/docs/02-artifact-contract.md"
MONOREPO_DOC="$PLUGIN_ROOT/docs/07-monorepo-adapter.md"

pass_count=0
fail_count=0

WORK="$(mktemp -d -t skill-engine-verify-heuristics.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass() {
  printf '  PASS  %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  local label="$1"
  shift
  printf '  FAIL  %s\n' "$label"
  if [ "$#" -gt 0 ]; then
    printf '        %s\n' "$@"
  fi
  fail_count=$((fail_count + 1))
}

section() {
  printf '\n── %s ──\n' "$1"
}

# Collapse every run of whitespace — newlines included — to one space, so a
# phrase assertion against a hard-wrapped reference/doctrine file does not
# depend on where the phrase happened to break across lines.
normalize() {
  printf '%s' "$1" | tr -s '[:space:]' ' '
}

# section_between <file> <start-ere> <end-ere> — lines from the first line
# matching <start-ere> up to (excluding) the next line matching <end-ere>.
# Patterns travel through ENVIRON, not -v, so a literal `.` in the pattern
# is never escape-processed away before the regex engine sees it.
section_between() {
  SECTION_BETWEEN_START="$2" SECTION_BETWEEN_END="$3" awk '
    $0 ~ ENVIRON["SECTION_BETWEEN_END"] && f { exit }
    $0 ~ ENVIRON["SECTION_BETWEEN_START"] { f=1 }
    f
  ' "$1"
}

# check_section <combined-output> <needle> — the lines of one `=== ... ===`
# run_check block whose header contains <needle>, up to (excluding) the
# next `=== ` header. Isolates one heuristic's own output so a phrase that
# legitimately appears in a NEIGHBORING check (e.g. companions-coverage's
# own "heuristic clean" line) can never be mistaken for this one's.
check_section() {
  CHECK_NEEDLE="$2" awk '
    $0 ~ ENVIRON["CHECK_NEEDLE"] && !found { found=1; print; next }
    found && /^=== / { exit }
    found { print }
  ' <<<"$1"
}

# ---------------------------------------------------------------------------
# Contextualizer fixture builders
# ---------------------------------------------------------------------------

build_nav() {
  local root="$1"
  mkdir -p "$root"
  {
    printf -- '---\n'
    printf 'name: acme-context\n'
    printf 'description: Use when answering questions about the acme corpus.\n'
    printf -- '---\n\n# Acme\n'
  } > "$root/SKILL.md"
}

git_managed_source() {
  local id="$1" url="$2" extra="${3:-null}"
  jq -n --arg id "$id" --arg url "$url" --argjson extra "$extra" '
    {
      id: $id,
      kind: "git-managed",
      url: $url,
      status: "confirmed",
      archived: false,
      lifecycle: {state: "reachable", last_checked: "2026-09-06", last_checked_sha: "abc1234", proposed_url: null},
      discovered_via: null
    } + (if $extra == null then {} else $extra end)
  '
}

local_path_source() {
  local id="$1" fs_path="$2"
  jq -n --arg id "$id" --arg fs_path "$fs_path" '
    {
      id: $id,
      kind: "local-path",
      path: $fs_path,
      status: "confirmed",
      archived: false,
      lifecycle: {state: "reachable"},
      discovered_via: null
    }
  '
}

write_sources() {
  local root="$1" sources_array="$2"
  mkdir -p "$root/research"
  jq -n --argjson sources "$sources_array" '{schema_version: 1, sources: $sources}' > "$root/research/source-paths.json"
}

# shallow_clone_into <dest> <populate-fn> — a real local git repository
# (init + one commit, fully offline via file:// transport), then a real
# `git clone --depth=1` of it into <dest>, so .git/-exclusion math is
# proven against real git plumbing rather than a synthetic file count.
shallow_clone_into() {
  local dest="$1" populate_fn="$2" upstream
  upstream="$(mktemp -d "$WORK/upstream.XXXXXX")"
  git init -q -b main "$upstream" >/dev/null 2>&1
  "$populate_fn" "$upstream"
  git -C "$upstream" add -A >/dev/null 2>&1
  git -C "$upstream" -c user.email=test@example.com -c user.name=Test -c commit.gpgsign=false \
    commit -q -m seed >/dev/null 2>&1
  mkdir -p "$(dirname "$dest")"
  git clone -q --depth=1 "file://$upstream" "$dest" >/dev/null 2>&1
}

run_verify() {
  local root="$1" cache="$2"
  CTX_ROOT="$root" SKILL_ENGINE_CACHE_ROOT="$cache" "$TEMPLATE" 2>&1
}

run_verify_default_cache() {
  local root="$1" home="$2"
  env -u SKILL_ENGINE_CACHE_ROOT HOME="$home" CTX_ROOT="$root" "$TEMPLATE" 2>&1
}

real_file_count() {
  find "$1" -path "$1/.git" -prune -o -type f -print | wc -l | tr -d ' '
}

naive_file_count() {
  find "$1" -maxdepth 6 -type f | wc -l | tr -d ' '
}

# ============================================================================
# No local cache tree at all — both checks say N/A, not clean
# ============================================================================
section "no local tree — both checks name the source and the reason instead of claiming clean"

root_a="$WORK/fx-a"
build_nav "$root_a"
write_sources "$root_a" "[$(git_managed_source widget-src https://example.com/acme/widgets)]"
cache_a="$WORK/cache-a"
mkdir -p "$cache_a"

out_a="$(run_verify "$root_a" "$cache_a")"
rc_a=$?
c6_a="$(check_section "$out_a" 'Monorepo-coverage')"
c8_a="$(check_section "$out_a" 'Catalog-density')"

if printf '%s' "$c6_a" | grep -q '\[N/A\]' && printf '%s' "$c6_a" | grep -qF 'widget-src'; then
  pass "monorepo-coverage: a git-managed source with no matching cache directory prints [N/A] naming the source"
else
  fail "monorepo-coverage: a git-managed source with no matching cache directory prints [N/A] naming the source" \
    "monorepo-coverage section: ${c6_a:-<empty>}"
fi
if printf '%s' "$c6_a" | grep -qi 'heuristic clean'; then
  fail "monorepo-coverage: does not claim 'heuristic clean' when it never opened a tree"
else
  pass "monorepo-coverage: does not claim 'heuristic clean' when it never opened a tree"
fi

if printf '%s' "$c8_a" | grep -q '\[N/A\]' && printf '%s' "$c8_a" | grep -qF 'widget-src'; then
  pass "catalog-density: a git-managed source with no matching cache directory prints [N/A] naming the source"
else
  fail "catalog-density: a git-managed source with no matching cache directory prints [N/A] naming the source" \
    "catalog-density section: ${c8_a:-<empty>}"
fi
if printf '%s' "$c8_a" | grep -qi 'heuristic clean'; then
  fail "catalog-density: does not claim 'heuristic clean' when it never counted a file"
else
  pass "catalog-density: does not claim 'heuristic clean' when it never counted a file"
fi

# ============================================================================
# A resolvable cache tree — enumerate members, uncited member warns
# (also the .git/-exclusion negative case: a real corpus this small must
# not clear the density floor even though .git/ alone would)
# ============================================================================
section "resolvable cache tree — uncited member warns; .git/ plumbing never inflates the file count"

populate_small() {
  mkdir -p "$1/packages/foo"
  printf 'one\n' > "$1/packages/foo/a.txt"
  printf 'two\n' > "$1/packages/foo/b.txt"
  printf 'three\n' > "$1/root.txt"
}

root_b="$WORK/fx-b"
build_nav "$root_b"
write_sources "$root_b" "[$(git_managed_source acme-repo https://example.com/acme/repo)]"
cache_b="$WORK/cache-b"
dest_b="$cache_b/git-managed/acme-repo-a1b2c3d4"
shallow_clone_into "$dest_b" populate_small

real_b="$(real_file_count "$dest_b")"
naive_b="$(naive_file_count "$dest_b")"
if [ "$naive_b" -ge 20 ] && [ "$real_b" -lt 20 ]; then
  pass "fixture self-check: the small fixture's real corpus ($real_b files) stays under the density floor while .git/ alone would clear it ($naive_b files counted naively)"
else
  fail "fixture self-check: the small fixture's real corpus ($real_b files) stays under the density floor while .git/ alone would clear it ($naive_b files counted naively)"
fi

out_b="$(run_verify "$root_b" "$cache_b")"
rc_b=$?
c6_b="$(check_section "$out_b" 'Monorepo-coverage')"
c8_b="$(check_section "$out_b" 'Catalog-density')"

if printf '%s' "$c6_b" | grep -qE '\[WARN\].*\bfoo\b' && printf '%s' "$c6_b" | grep -qF 'acme-repo'; then
  pass "monorepo-coverage: a member the resolved tree contains but no reference cites warns, naming the member and the source"
else
  fail "monorepo-coverage: a member the resolved tree contains but no reference cites warns, naming the member and the source" \
    "monorepo-coverage section: ${c6_b:-<empty>}"
fi

if printf '%s' "$c8_b" | grep -q '\[WARN\]'; then
  fail "catalog-density: does not spuriously warn on a real corpus below the floor even though .git/ alone ($naive_b files) would clear it" \
    "catalog-density section: ${c8_b:-<empty>}"
else
  pass "catalog-density: does not spuriously warn on a real corpus below the floor even though .git/ alone ($naive_b files) would clear it"
fi

# SKILL_ENGINE_CACHE_ROOT is genuinely read, not a fixed/default path: the
# same contextualizer against an EMPTY cache root flips straight to the
# no-local-tree N/A this section's first block exercises.
cache_b_empty="$WORK/cache-b-empty"
mkdir -p "$cache_b_empty"
out_b_empty="$(run_verify "$root_b" "$cache_b_empty")"
c6_b_empty="$(check_section "$out_b_empty" 'Monorepo-coverage')"
if printf '%s' "$c6_b_empty" | grep -q '\[N/A\]' && printf '%s' "$c6_b_empty" | grep -qF 'acme-repo'; then
  pass "SKILL_ENGINE_CACHE_ROOT is genuinely read: pointing the same source at an empty cache root flips the earlier WARN to N/A"
else
  fail "SKILL_ENGINE_CACHE_ROOT is genuinely read: pointing the same source at an empty cache root flips the earlier WARN to N/A" \
    "monorepo-coverage section: ${c6_b_empty:-<empty>}"
fi

# ============================================================================
# catalog-density must actually warn against a git-managed tree, and the
# number it warns with must be the real corpus count, not the .git/-inclusive
# one — the positive half of the .git/-exclusion claim.
# ============================================================================
section "catalog-density warns using the real file count, never the .git/-inclusive one"

populate_big() {
  local i
  mkdir -p "$1/packages/many"
  for i in $(seq 1 25); do
    printf 'x' > "$1/packages/many/file$(printf '%02d' "$i").txt"
  done
}

root_c="$WORK/fx-c"
build_nav "$root_c"
write_sources "$root_c" "[$(git_managed_source bigrepo https://example.com/acme/bigrepo)]"
cache_c="$WORK/cache-c"
dest_c="$cache_c/git-managed/bigrepo-e5f6a7b8"
shallow_clone_into "$dest_c" populate_big

real_c="$(real_file_count "$dest_c")"
naive_c="$(naive_file_count "$dest_c")"
if [ "$real_c" -ge 20 ] && [ "$real_c" -ne "$naive_c" ]; then
  pass "fixture self-check: the big fixture's real corpus ($real_c files) clears the density floor and differs from the .git/-inclusive count ($naive_c files)"
else
  fail "fixture self-check: the big fixture's real corpus ($real_c files) clears the density floor and differs from the .git/-inclusive count ($naive_c files)"
fi

out_c="$(run_verify "$root_c" "$cache_c")"
c8_c="$(check_section "$out_c" 'Catalog-density')"

if printf '%s' "$c8_c" | grep -qF 'bigrepo' && printf '%s' "$c8_c" | grep -qE "(^|[^0-9])${real_c} files"; then
  pass "catalog-density: warns citing the real corpus count ($real_c files), zero catalog rows, on a git-managed tree it had to open to know that"
else
  fail "catalog-density: warns citing the real corpus count ($real_c files), zero catalog rows, on a git-managed tree it had to open to know that" \
    "catalog-density section: ${c8_c:-<empty>}"
fi
if printf '%s' "$c8_c" | grep -qE "(^|[^0-9])${naive_c} files"; then
  fail "catalog-density: the warning must not cite the .git/-inclusive count ($naive_c files)" \
    "catalog-density section: ${c8_c:-<empty>}"
else
  pass "catalog-density: the warning does not cite the .git/-inclusive count ($naive_c files)"
fi

# ============================================================================
# workspace_roots: the widened default list, and an explicit override that
# replaces (not augments) it
# ============================================================================
section "workspace_roots — widened default list surfaces a Go-style layout; an explicit override replaces the defaults"

populate_go() {
  mkdir -p "$1/cmd/billingd" "$1/cmd/authd" "$1/internal/ledger" "$1/internal/auth" "$1/pkg/events"
  printf 'package billingd\n' > "$1/cmd/billingd/main.go"
  printf 'package authd\n' > "$1/cmd/authd/main.go"
  printf 'package ledger\n' > "$1/internal/ledger/ledger.go"
  printf 'package auth\n' > "$1/internal/auth/auth.go"
  printf 'package events\n' > "$1/pkg/events/events.go"
}

root_d="$WORK/fx-d"
build_nav "$root_d"
write_sources "$root_d" "[$(git_managed_source go-svc https://example.com/acme/go-svc)]"
cache_d="$WORK/cache-d"
dest_d="$cache_d/git-managed/go-svc-c9d0e1f2"
shallow_clone_into "$dest_d" populate_go

out_d="$(run_verify "$root_d" "$cache_d")"
c6_d="$(check_section "$out_d" 'Monorepo-coverage')"

go_members_ok=1
for member in billingd authd ledger auth events; do
  if ! printf '%s' "$c6_d" | grep -qE "workspace member ${member}([[:space:]]|\$)"; then
    go_members_ok=0
  fi
done
if [ "$go_members_ok" -eq 1 ]; then
  pass "monorepo-coverage: a Go-style tree (cmd/, internal/, pkg/) surfaces all five members with no configuration"
else
  fail "monorepo-coverage: a Go-style tree (cmd/, internal/, pkg/) surfaces all five members with no configuration" \
    "monorepo-coverage section: ${c6_d:-<empty>}"
fi
go_warn_count="$(printf '%s' "$c6_d" | grep -c '\[WARN\]')"
if [ "$go_warn_count" -eq 5 ]; then
  pass "monorepo-coverage: exactly five members surfaced for the Go-style tree, none extra"
else
  fail "monorepo-coverage: exactly five members surfaced for the Go-style tree, none extra" \
    "got $go_warn_count WARN line(s): ${c6_d:-<empty>}"
fi

populate_override() {
  mkdir -p "$1/custom_root/thing1" "$1/custom_root/thing2" "$1/packages/ignored-pkg"
  printf 'a\n' > "$1/custom_root/thing1/a.txt"
  printf 'b\n' > "$1/custom_root/thing2/b.txt"
  printf 'c\n' > "$1/packages/ignored-pkg/c.txt"
}

root_e="$WORK/fx-e"
build_nav "$root_e"
write_sources "$root_e" "[$(git_managed_source custom-svc https://example.com/acme/custom-svc '{"workspace_roots": ["custom_root"]}')]"
cache_e="$WORK/cache-e"
dest_e="$cache_e/git-managed/custom-svc-11223344"
shallow_clone_into "$dest_e" populate_override

out_e="$(run_verify "$root_e" "$cache_e")"
c6_e="$(check_section "$out_e" 'Monorepo-coverage')"

override_ok=1
printf '%s' "$c6_e" | grep -qE "workspace member thing1([[:space:]]|\$)" || override_ok=0
printf '%s' "$c6_e" | grep -qE "workspace member thing2([[:space:]]|\$)" || override_ok=0
if [ "$override_ok" -eq 1 ]; then
  pass "monorepo-coverage: an explicit workspace_roots override surfaces its own roots' members"
else
  fail "monorepo-coverage: an explicit workspace_roots override surfaces its own roots' members" \
    "monorepo-coverage section: ${c6_e:-<empty>}"
fi
if printf '%s' "$out_e" | grep -qF 'ignored-pkg'; then
  fail "monorepo-coverage: workspace_roots override replaces the default root list — packages/ must not also be scanned" \
    "full output mentioned ignored-pkg: ${out_e:-<empty>}"
else
  pass "monorepo-coverage: workspace_roots override replaces the default root list — packages/ignored-pkg never surfaces"
fi

# ============================================================================
# A stray sibling cache directory: the most-recently-modified candidate
# wins, with no warning about the ambiguity itself
# ============================================================================
section "two candidate cache directories — the newer one wins silently"

populate_amb_old() {
  mkdir -p "$1/packages/stale-only"
  printf 'x\n' > "$1/packages/stale-only/x.txt"
}
populate_amb_new() {
  mkdir -p "$1/packages/fresh-member"
  printf 'y\n' > "$1/packages/fresh-member/y.txt"
}

root_f="$WORK/fx-f"
build_nav "$root_f"
write_sources "$root_f" "[$(git_managed_source amb-src https://example.com/acme/amb-src)]"
cache_f="$WORK/cache-f"
dest_f_old="$cache_f/git-managed/amb-src-aaaaaaaa"
dest_f_new="$cache_f/git-managed/amb-src-bbbbbbbb"
shallow_clone_into "$dest_f_old" populate_amb_old
shallow_clone_into "$dest_f_new" populate_amb_new
# Force the mtime gap explicitly and recursively (directory and every entry
# inside it), both stamps in the past, rather than relying on the natural
# few-milliseconds gap between the two clone operations above.
find "$dest_f_old" -exec touch -t 202001010000 {} +
find "$dest_f_new" -exec touch -t 202501010000 {} +

out_f="$(run_verify "$root_f" "$cache_f")"
c6_f="$(check_section "$out_f" 'Monorepo-coverage')"
c8_f="$(check_section "$out_f" 'Catalog-density')"

f_warn_count="$(printf '%s' "$c6_f" | grep -c '\[WARN\]')"
if [ "$f_warn_count" -eq 1 ] && printf '%s' "$c6_f" | grep -qF 'fresh-member'; then
  pass "monorepo-coverage: with two candidate cache directories, exactly one WARN fires, naming the newer directory's member"
else
  fail "monorepo-coverage: with two candidate cache directories, exactly one WARN fires, naming the newer directory's member" \
    "monorepo-coverage section: ${c6_f:-<empty>}"
fi
if printf '%s' "$out_f" | grep -qF 'stale-only'; then
  fail "the stale sibling's member (stale-only) never surfaces anywhere in the run" \
    "full output mentioned stale-only: ${out_f:-<empty>}"
else
  pass "the stale sibling's member (stale-only) never surfaces anywhere in the run"
fi
if printf '%s' "$c8_f" | grep -q '\[WARN\]'; then
  fail "catalog-density: raises no warning while resolving the ambiguous-candidate source" \
    "catalog-density section: ${c8_f:-<empty>}"
else
  pass "catalog-density: raises no warning while resolving the ambiguous-candidate source"
fi

# ============================================================================
# files_of_interest scoping: an absent workspace root gets a scoping N/A,
# not a silent clean; a present one behaves exactly as the plain
# uncited-member case above
# ============================================================================
section "files_of_interest scoping — an absent workspace root is named, not silently clean"

populate_scoped() {
  mkdir -p "$1/packages/foo"
  printf 'x\n' > "$1/packages/foo/x.txt"
}

root_g="$WORK/fx-g"
build_nav "$root_g"
write_sources "$root_g" "[$(git_managed_source scoped-src https://example.com/acme/scoped-src \
  '{"files_of_interest": ["packages/**"], "workspace_roots": ["packages", "apps"]}')]"
cache_g="$WORK/cache-g"
dest_g="$cache_g/git-managed/scoped-src-55667788"
shallow_clone_into "$dest_g" populate_scoped

out_g="$(run_verify "$root_g" "$cache_g")"
c6_g="$(check_section "$out_g" 'Monorepo-coverage')"
c8_g="$(check_section "$out_g" 'Catalog-density')"

g_warn_count="$(printf '%s' "$c6_g" | grep -c '\[WARN\]')"
if [ "$g_warn_count" -eq 1 ] && printf '%s' "$c6_g" | grep -qF 'foo'; then
  pass "monorepo-coverage: the workspace root the sparse checkout DOES carry (packages) runs its normal uncited-member check"
else
  fail "monorepo-coverage: the workspace root the sparse checkout DOES carry (packages) runs its normal uncited-member check" \
    "monorepo-coverage section: ${c6_g:-<empty>}"
fi
if printf '%s' "$c6_g" | grep -qE '\[N/A\]' && printf '%s' "$c6_g" | grep -qF 'scoped-src' && printf '%s' "$c6_g" | grep -qF 'apps'; then
  pass "monorepo-coverage: the workspace root files_of_interest scopes out (apps) gets an N/A naming the source and the root, not a silent clean"
else
  fail "monorepo-coverage: the workspace root files_of_interest scopes out (apps) gets an N/A naming the source and the root, not a silent clean" \
    "monorepo-coverage section: ${c6_g:-<empty>}"
fi
if printf '%s' "$c6_g" | grep -qE '\[N/A\].*\bpackages\b'; then
  fail "monorepo-coverage: the present root (packages) must not itself be reported as scoped out" \
    "monorepo-coverage section: ${c6_g:-<empty>}"
else
  pass "monorepo-coverage: the present root (packages) is not reported as scoped out"
fi

c8_g_ok=1
printf '%s' "$c8_g" | grep -q '\[N/A\]' || c8_g_ok=0
printf '%s' "$c8_g" | grep -qF 'scoped-src' || c8_g_ok=0
printf '%s' "$c8_g" | grep -qiE 'apps|scop|files_of_interest' || c8_g_ok=0
if [ "$c8_g_ok" -eq 1 ]; then
  pass "catalog-density: also surfaces an N/A naming the source and the scoping reason rather than silently passing it"
else
  fail "catalog-density: also surfaces an N/A naming the source and the scoping reason rather than silently passing it" \
    "catalog-density section: ${c8_g:-<empty>}"
fi

# ============================================================================
# SKILL_ENGINE_CACHE_ROOT: documented default fallback, and a local-path
# source's existing .path-based behavior is unaffected
# ============================================================================
section "cache-root resolution — default fallback to \$HOME/.cache/skill-engine; local-path preservation"

populate_fallback() {
  mkdir -p "$1/packages/only-member"
  printf 'x\n' > "$1/packages/only-member/x.txt"
}

root_i="$WORK/fx-i"
build_nav "$root_i"
write_sources "$root_i" "[$(git_managed_source fallback-src https://example.com/acme/fallback-src)]"
home_i="$WORK/home-i"
mkdir -p "$home_i"
dest_i="$home_i/.cache/skill-engine/git-managed/fallback-src-99887766"
shallow_clone_into "$dest_i" populate_fallback

out_i="$(run_verify_default_cache "$root_i" "$home_i")"
c6_i="$(check_section "$out_i" 'Monorepo-coverage')"
if printf '%s' "$c6_i" | grep -qE '\[WARN\].*\bonly-member\b'; then
  pass "SKILL_ENGINE_CACHE_ROOT unset falls back to \$HOME/.cache/skill-engine, matching the documented default"
else
  fail "SKILL_ENGINE_CACHE_ROOT unset falls back to \$HOME/.cache/skill-engine, matching the documented default" \
    "monorepo-coverage section: ${c6_i:-<empty>}"
fi

root_h="$WORK/fx-h"
build_nav "$root_h"
vendor_dir="$root_h/vendor-src"
mkdir -p "$vendor_dir/packages/bar-vendor"
printf 'x\n' > "$vendor_dir/packages/bar-vendor/x.txt"
write_sources "$root_h" "[$(local_path_source vendor-src "$vendor_dir")]"
cache_h="$WORK/cache-h-unrelated"
mkdir -p "$cache_h"

out_h="$(run_verify "$root_h" "$cache_h")"
rc_h=$?
c6_h="$(check_section "$out_h" 'Monorepo-coverage')"

if printf '%s' "$c6_h" | grep -qE '\[WARN\].*\bbar-vendor\b'; then
  pass "local-path preservation: a local-path source still enumerates members via its existing .path field"
else
  fail "local-path preservation: a local-path source still enumerates members via its existing .path field" \
    "monorepo-coverage section: ${c6_h:-<empty>}"
fi
if printf '%s' "$c6_h" | grep -q '\[N/A\]'; then
  fail "local-path preservation: a local-path source must not be redirected into the git-managed cache-tree N/A branch" \
    "monorepo-coverage section: ${c6_h:-<empty>}"
else
  pass "local-path preservation: a local-path source is not redirected into the git-managed cache-tree N/A branch"
fi
if [ "$rc_h" -eq 0 ]; then
  pass "local-path preservation: an unrelated SKILL_ENGINE_CACHE_ROOT value has no effect on a local-path source's exit code"
else
  fail "local-path preservation: an unrelated SKILL_ENGINE_CACHE_ROOT value has no effect on a local-path source's exit code" "rc=$rc_h"
fi

# ============================================================================
# [N/A] and [WARN] never change the exit code
# ============================================================================
section "exit code — [N/A] and [WARN] output never fails the run"

if [ "$rc_a" -eq 0 ]; then
  pass "an all-[N/A] run (no local tree) still exits 0"
else
  fail "an all-[N/A] run (no local tree) still exits 0" "rc=$rc_a"
fi
if [ "$rc_b" -eq 0 ]; then
  pass "a run containing a [WARN] (uncited member) still exits 0"
else
  fail "a run containing a [WARN] (uncited member) still exits 0" "rc=$rc_b"
fi

# ============================================================================
# Doc consistency: the entry-shape section documents workspace_roots; the
# monorepo chapter's description of the coverage heuristic names the
# widened default root list and the override
# ============================================================================
section "doc consistency — workspace_roots documented where the entry shape and the coverage heuristic live"

entry_shape_flat="$(normalize "$(section_between "$ARTIFACT_CONTRACT" '^### source-paths\.json entry shape' '^### Body')")"
if [ -n "$entry_shape_flat" ]; then
  pass "02-artifact-contract.md's source-paths.json entry shape section is present"
  if printf '%s' "$entry_shape_flat" | grep -qF 'workspace_roots'; then
    pass "02-artifact-contract.md's entry shape section documents workspace_roots"
  else
    fail "02-artifact-contract.md's entry shape section documents workspace_roots"
  fi
else
  fail "02-artifact-contract.md's source-paths.json entry shape section is present"
  fail "02-artifact-contract.md's entry shape section documents workspace_roots" "prerequisite section not found"
fi

monorepo_flat="$(normalize "$(cat "$MONOREPO_DOC")")"
if printf '%s' "$monorepo_flat" | grep -qF 'workspace_roots'; then
  pass "07-monorepo-adapter.md names workspace_roots"
else
  fail "07-monorepo-adapter.md names workspace_roots"
fi
new_roots_ok=1
for root_name in cmd internal pkg services modules; do
  printf '%s' "$monorepo_flat" | grep -qF "$root_name" || new_roots_ok=0
done
if [ "$new_roots_ok" -eq 1 ]; then
  pass "07-monorepo-adapter.md names the widened default root list, not just the original packages/apps/libs/crates four"
else
  fail "07-monorepo-adapter.md names the widened default root list, not just the original packages/apps/libs/crates four"
fi

# ============================================================================
# Schema: workspace_roots accepts an array of non-empty strings, rejects a
# non-array value and an array containing an empty string
# ============================================================================
section "schema — workspace_roots shape"

HAVE_CJS=0
if command -v check-jsonschema >/dev/null 2>&1; then
  HAVE_CJS=1
else
  echo "NOTE: check-jsonschema not on PATH — skipping schema validation locally." >&2
  echo "      CI runs it (pip install check-jsonschema==0.37.2); install it to match CI exactly." >&2
fi

write_wr_doc() {
  local out="$1" extra="${2:-null}"
  jq -n --argjson extra "$extra" '
    {
      schema_version: 1,
      sources: [
        ({
          id: "widget-src",
          kind: "git-managed",
          url: "https://example.com/acme/widgets",
          status: "confirmed",
          archived: false,
          lifecycle: {state: "reachable", last_checked: "2026-09-06", last_checked_sha: "abc1234", proposed_url: null},
          discovered_via: null
        } + (if $extra == null then {} else $extra end))
      ]
    }
  ' > "$out"
}

schema_accepts() {
  local label="$1" f="$2" out
  if out="$(check-jsonschema --schemafile "$SCHEMA" "$f" 2>&1)"; then
    pass "$label"
  else
    fail "$label" "$out"
  fi
}

schema_rejects() {
  local label="$1" f="$2"
  if check-jsonschema --schemafile "$SCHEMA" "$f" >/dev/null 2>&1; then
    fail "$label" "expected schema validation to reject $f, but it passed"
  else
    pass "$label"
  fi
}

write_wr_doc "$WORK/wr-absent.json" 'null'
write_wr_doc "$WORK/wr-empty-array.json" '{"workspace_roots": []}'
write_wr_doc "$WORK/wr-populated.json" '{"workspace_roots": ["cmd", "internal"]}'
write_wr_doc "$WORK/wr-bad-string.json" '{"workspace_roots": "cmd"}'
write_wr_doc "$WORK/wr-bad-object.json" '{"workspace_roots": {}}'
write_wr_doc "$WORK/wr-bad-empty-entry.json" '{"workspace_roots": ["cmd", ""]}'

fixture_ok=true
for f in wr-absent wr-empty-array wr-populated wr-bad-string wr-bad-object wr-bad-empty-entry; do
  if ! jq empty "$WORK/$f.json" 2>/dev/null; then
    fixture_ok=false
    fail "fixture $f.json is well-formed JSON"
  fi
done
$fixture_ok && pass "every schema fixture is well-formed JSON"

if [ "$HAVE_CJS" -eq 1 ]; then
  schema_accepts "workspace_roots absent still validates" "$WORK/wr-absent.json"
  schema_accepts "workspace_roots: [] (empty array) validates" "$WORK/wr-empty-array.json"
  schema_accepts "workspace_roots: [non-empty strings] validates" "$WORK/wr-populated.json"
  schema_rejects "workspace_roots as a bare string (non-array) is rejected" "$WORK/wr-bad-string.json"
  schema_rejects "workspace_roots as an object (non-array) is rejected" "$WORK/wr-bad-object.json"
  schema_rejects "workspace_roots containing an empty string is rejected" "$WORK/wr-bad-empty-entry.json"
fi

# ----- summary -------------------------------------------------------------

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
