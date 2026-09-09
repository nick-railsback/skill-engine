#!/usr/bin/env bash
# Black-box oracle for staged archive detection: REFRESH's forge-dispatched
# archive check that reads whether a git-managed source has been archived
# upstream and stages the transition for review rather than writing it live
# or flagging it by hand.
#
# THE BEHAVIOR UNDER TEST:
#   1. For each in-scope git-managed source whose URL host is github.com, a
#      GitHub Enterprise host, or a GitLab host, one read-only API call reads
#      the forge's archived flag; every other host is treated as unknown.
#   2. A true flag stages `archived: true` into the proposed
#      research/source-paths.json, the proposal's manifest lists that file
#      as modified, and the live file is untouched until apply.
#   3. A false flag, or an unknown host, stages no transition; the post-run
#      summary states how many sources were checked and how many were
#      unknown. Bitbucket and Azure DevOps are the named unknown-host
#      examples and must never produce a staged transition.
#   4. Preservation: a source already `archived: true` in the live file
#      stays excluded from the Phase 1 probe exactly as today, and this
#      holds for a pending (not yet applied) proposal too, because the
#      unapplied-proposal guard already refuses to start a second REFRESH
#      before the first proposal is resolved.
#   5. Both routers' "user sets archived by hand" sentences are replaced by
#      a sentence naming the staged transition, neither router grows past
#      its pre-change byte count, and the shipped router-size doctrine
#      checks for both files keep passing.
#   6. The GitHub read is `gh api`; the GitLab read carries no non-HEAD curl
#      invocation if it is expressed as a fenced command at all; no auth
#      token is plumbed anywhere in the reference; the two doctrine checks
#      that forbid a non-HEAD curl and auth-token plumbing in engine shell
#      scripts keep passing (their own scan scope never reaches this
#      reference doc, so this is a preservation check, not a shape check on
#      the new prose — the fenced-block check above covers the shape).
#
# This is prose-only, matching how this reference doc is read and acted on:
# the model executes REFRESH by reading drift-detection-and-phases.md and
# the two router SKILL.md files, not this harness, so every check here is a
# wrap-normalized text-presence or text-absence assertion against those
# files (plus one direct run of the doctrine grep suite for the two router
# byte-ceiling checks, since that suite is the actual enforcement mechanism
# named for that half of the behavior). Nothing here executes a forge API
# call or a git recipe.
#
# WINDOW-SIZE NOTE: this platform's grep -E rejects a `{0,N}` interval bound
# above roughly 255, so every proximity window below is capped at 250 —
# never a single self-bounded regex spanning more.
#
# ANCHOR-SAFETY NOTE: every anchor/needle pair below was checked by hand
# against the CURRENT file content before being written, specifically to
# rule out an existing, unrelated occurrence of the same words producing a
# false PASS before the real behavior exists. Two traps found and worked
# around this way:
#   - `archived: true` already occurs once today, in the "zero in-scope
#     sources" render message, with `research/source-paths.json` only ~135
#     normalized characters after it — inside a naive 250-char window. The
#     staged-transition checks below anchor on `archived: true` but require
#     `CTX_PROPOSED` nearby, which does not appear near that existing
#     occurrence, so they cannot false-PASS against it.
#   - `unknown` already occurs four times today (lifecycle states, a Phase 1
#     probe table cell); one of those already sits within 250 characters of
#     the word `checked` (the Phase 1 probe table's `last_checked_sha`
#     column, unrelated to a summary count). The summary-count check below
#     requires a count phrase (`how many`/`count of`/`number of`)
#     IMMEDIATELY PRECEDING `checked`, not just co-occurring with it, so a
#     bare `checked` inside an unrelated field name can never satisfy it.
#
# JUDGMENT CALLS (this oracle's own choices — not pinned anywhere else —
# flagged for the human, not silently baked in):
#   - "One read-only API call per source" is checked as a whole-word
#     `one`/`single` within 250 chars of `github.com` and, separately,
#     `read-only`-ish wording within 250 chars of the same anchor — not
#     required adjacent to each other, since the eventual sentence's exact
#     shape isn't known.
#   - The must-name-Bitbucket-and-Azure-DevOps check requires both forge
#     names to appear near a no-transition/unknown phrase, reading the
#     "named as the extension point in the reference" requirement as a hard
#     requirement on the prose (both names must actually appear in the
#     text), not merely on the design intent.
#   - The GitLab read is checked ONLY inside fenced bash/sh/shell/jq blocks
#     that mention "gitlab" — a bare-prose curl mention is not scanned,
#     matching the stated scope of this check ("if the reference carries
#     the GitLab read as a fenced command"). When no such fenced block
#     exists (true today), that assertion passes vacuously — there is
#     nothing yet for it to reject.
#   - The post-run summary's exact rendering (a fixed sentence vs. a
#     templated count line, e.g. "<N> sources checked, <M> unknown-host")
#     is not pinned anywhere; the count-phrase check below could go red on
#     a correct implementation that renders counts without the words "how
#     many"/"count of"/"number of". Flagged, not resolved, here.
#   - Router byte ceilings are pinned against TODAY's measured byte counts
#     (8,200 for refresh/SKILL.md, 8,186 for discover/SKILL.md), not the
#     shared 8,204-byte doctrine ceiling both already sit under — a
#     tighter, "byte-neutral or smaller" bar than the doctrine ceiling
#     alone would enforce.
#   - The "not redirected to the proposed dir" check below can tell
#     `$CTX_PROPOSED` apart from its absence near the in-scope filter, but
#     cannot tell "reads the live file" apart from "explicitly states it
#     does not read the proposed file" — both leave the same trace. It is
#     a regression guard, not full coverage of the pending-proposal clause;
#     that clause's real backing is structural (see the preservation
#     section below).
#
# EXPECTED RED RIGHT NOW: neither router SKILL.md's manual-flagging sentence
# has been replaced, and drift-detection-and-phases.md has no Phase 0.5
# section, no mention of github.com/GitHub Enterprise/GitLab/Bitbucket/Azure
# DevOps/gh api anywhere, and no staged-transition or summary-count prose —
# confirmed by hand before writing this file. Every existence/replacement
# check below is expected to fail for genuine absence. The preservation
# checks (in-scope filter sentence, unapplied-proposal guard, byte
# ceilings, the two router-size doctrine checks, absence of auth-token
# strings, the vacuous GitLab-curl-shape check) are expected to PASS right
# now, because they assert on behavior that already holds and must keep
# holding — that is the point of a preservation check, not a bug in this
# oracle.
#
# -e is intentionally omitted: every assertion runs and reports, not abort
# at the first red one.
set -uo pipefail

# ---------------------------------------------------------------------------
# Setup: locate the repo, load the surfaces under test.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT_MARKER="plugin/skill-engine/docs/02-artifact-contract.md"
find_root() {
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/$ROOT_MARKER" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}
REPO_ROOT="$(find_root "$SCRIPT_DIR" || find_root "$PWD")"
if [ -z "$REPO_ROOT" ]; then
  echo "ERROR: cannot locate the repository root — no $ROOT_MARKER above $SCRIPT_DIR or $PWD." >&2
  exit 69
fi
PLUGIN_ROOT="$REPO_ROOT/plugin/skill-engine"

DRIFT_MD="$PLUGIN_ROOT/skills/refresh/references/drift-detection-and-phases.md"
REFRESH_SKILL="$PLUGIN_ROOT/skills/refresh/SKILL.md"
DISCOVER_SKILL="$PLUGIN_ROOT/skills/discover/SKILL.md"
DOCTRINE_SH="$PLUGIN_ROOT/tests/doctrine.sh"

for f in "$DRIFT_MD" "$REFRESH_SKILL" "$DISCOVER_SKILL" "$DOCTRINE_SH"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: expected surface is missing entirely: $f" >&2
    exit 69
  fi
done

pass_count=0
fail_count=0

banner() { printf '\n== %s ==\n' "$1"; }

pass() {
  printf '  PASS  %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  local label="$1"
  shift
  printf '  FAIL  %s\n' "$label"
  local detail
  for detail in "$@"; do
    printf '%s\n' "$detail" | sed 's/^/        /'
  done
  fail_count=$((fail_count + 1))
}

# norm — collapse every run of whitespace, newlines included, to one space,
# then trim the ends. Every multi-word phrase assertion below runs against
# normalized text so a hand-wrapped line break can never hide a phrase from
# a naive line-oriented grep.
norm() { tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }
norm_str() { printf '%s' "$1" | norm; }

assert_str() {
  local label="$1" text="$2" lit="$3"
  if printf '%s' "$text" | grep -qF -- "$lit"; then
    pass "$label"
  else
    fail "$label" "string not found: $lit"
  fi
}

assert_str_i() {
  local label="$1" text="$2" lit="$3"
  if printf '%s' "$text" | grep -qiF -- "$lit"; then
    pass "$label"
  else
    fail "$label" "string not found (case-insensitive): $lit"
  fi
}

assert_absent() {
  local label="$1" text="$2" lit="$3"
  if printf '%s' "$text" | grep -qF -- "$lit"; then
    fail "$label" "old sentence still present: $lit"
  else
    pass "$label"
  fi
}

line_of() {
  local file="$1" pat="$2"
  grep -n -E -- "$pat" "$file" | head -n1 | cut -d: -f1
}

# section_lines <file> <start-ere> [<end-ere>] — lines from the first line
# matching <start-ere> (inclusive) to the line before the first subsequent
# match of <end-ere> (exclusive); to EOF when <end-ere> is omitted or has no
# later match. Empty output when <start-ere> is not found.
section_lines() {
  local file="$1" start_pat="$2" end_pat="${3:-}"
  local start_line end_line
  start_line="$(line_of "$file" "$start_pat")"
  [ -n "${start_line:-}" ] || return 1
  end_line=""
  if [ -n "$end_pat" ]; then
    end_line="$(grep -n -E -- "$end_pat" "$file" | awk -F: -v s="$start_line" '$1 > s {print $1; exit}')"
  fi
  if [ -n "${end_line:-}" ]; then
    sed -n "${start_line},$((end_line - 1))p" "$file"
  else
    sed -n "${start_line},\$p" "$file"
  fi
}

# near <text> <anchor-ere> <needle-ere> <window> — true when <needle> occurs
# within <window> characters of some occurrence of <anchor> in <text>.
# Never above 250 (see WINDOW-SIZE NOTE above).
near() {
  local text="$1" anchor="$2" needle="$3" window="$4"
  printf '%s' "$text" \
    | grep -oiE ".{0,${window}}${anchor}.{0,${window}}" \
    | grep -qiE -- "$needle"
}

# near_all <text> <anchor-ere> <window> <needle-ere>... — every given needle
# occurs somewhere within <window> characters of some occurrence of <anchor>
# (not necessarily the same occurrence).
near_all() {
  local text="$1" anchor="$2" window="$3"
  shift 3
  local needle
  for needle in "$@"; do
    near "$text" "$anchor" "$needle" "$window" || return 1
  done
  return 0
}

# gitlab_fence_check <file> — scans every fenced bash/sh/shell/jq block for
# a case-insensitive mention of "gitlab"; when found, checks every line
# inside that block for a `curl` invocation lacking `--head`/`-I`. Prints
# two lines: FOUND|NOTFOUND, then BAD|OK.
gitlab_fence_check() {
  awk '
    /^[[:space:]]*```(bash|sh|shell|jq)[[:space:]]*$/ { infence=1; buf=""; next }
    /^[[:space:]]*```[[:space:]]*$/ {
      if (infence) {
        lower = tolower(buf)
        if (index(lower, "gitlab") > 0) {
          found = 1
          n = split(buf, lines, "\n")
          for (i = 1; i <= n; i++) {
            line = lines[i]
            sub(/[ \t]#.*$/, "", line)
            if (line ~ /(^|[^A-Za-z0-9_-])curl([ \t]|$)/) {
              if (line !~ /--head/ && line !~ /[ \t]-[A-Za-z]*I[A-Za-z]*([ \t]|$)/) {
                bad = 1
              }
            }
          }
        }
        infence = 0
      }
      next
    }
    infence { buf = buf $0 "\n" }
    END {
      print (found ? "FOUND" : "NOTFOUND")
      print (bad ? "BAD" : "OK")
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# Load surfaces.
# ---------------------------------------------------------------------------

DRIFT_RAW="$(cat "$DRIFT_MD")"
DRIFT_N="$(norm_str "$DRIFT_RAW")"

REFRESH_NOTDO_RAW="$(section_lines "$REFRESH_SKILL" '^## What this skill does NOT do' '^## ')"
if [ -z "${REFRESH_NOTDO_RAW:-}" ]; then
  echo "ERROR: cannot locate '## What this skill does NOT do' in $REFRESH_SKILL" >&2
  exit 69
fi
REFRESH_NOTDO_N="$(norm_str "$REFRESH_NOTDO_RAW")"

DISCOVER_NOTDO_RAW="$(section_lines "$DISCOVER_SKILL" '^## What this skill does NOT do' '^## ')"
if [ -z "${DISCOVER_NOTDO_RAW:-}" ]; then
  echo "ERROR: cannot locate '## What this skill does NOT do' in $DISCOVER_SKILL" >&2
  exit 69
fi
DISCOVER_NOTDO_N="$(norm_str "$DISCOVER_NOTDO_RAW")"

# ===========================================================================
# Forge dispatch and call cardinality.
# ===========================================================================

banner "forge dispatch: github.com / GitHub Enterprise / GitLab read; every other host is unknown"

if grep -qE '^###[[:space:]]+Phase 0\.5' "$DRIFT_MD"; then
  pass "phase_0_5_section_present"
else
  fail "phase_0_5_section_present" \
    "no '### Phase 0.5' heading found in $DRIFT_MD"
fi

assert_str_i "archive_check_names_github_com" "$DRIFT_N" "github.com"
assert_str_i "archive_check_names_github_enterprise" "$DRIFT_N" "github enterprise"
assert_str_i "archive_check_names_gitlab" "$DRIFT_N" "gitlab"

if near "$DRIFT_N" 'github\.com' '(\bone\b|\bsingle\b)[^.]{0,40}(api )?call' 250; then
  pass "archive_check_one_call_per_source"
else
  fail "archive_check_one_call_per_source" \
    "expected 'one'/'single' ... 'call' documented within 250 chars of 'github.com'"
fi

if near "$DRIFT_N" 'github\.com' 'read.only' 250; then
  pass "archive_check_call_is_read_only"
else
  fail "archive_check_call_is_read_only" \
    "expected 'read-only' documented within 250 chars of 'github.com'"
fi

if near_all "$DRIFT_N" 'gitlab' 250 '(other|any)' 'unknown'; then
  pass "archive_check_other_hosts_map_to_unknown"
else
  fail "archive_check_other_hosts_map_to_unknown" \
    "expected '(other|any)' and 'unknown' each documented within 250 chars of 'gitlab'"
fi

# ===========================================================================
# Staged transition mechanics: proposed source-paths.json, manifest,
# live file untouched until apply.
# ===========================================================================

banner "a true archived flag stages archived: true, not a live write"

if near_all "$DRIFT_N" 'archived: true' 250 'CTX_PROPOSED'; then
  pass "archived_true_staged_to_proposed_source_paths"
else
  fail "archived_true_staged_to_proposed_source_paths" \
    "expected 'CTX_PROPOSED' documented within 250 chars of an 'archived: true' mention"
fi

if near_all "$DRIFT_N" 'archived: true' 250 'manifest' 'modified'; then
  pass "archived_true_manifest_entry_modified"
else
  fail "archived_true_manifest_entry_modified" \
    "expected 'manifest' and 'modified' each documented within 250 chars of an 'archived: true' mention"
fi

if near_all "$DRIFT_N" 'archived: true' 250 '(live|CTX_ROOT)' 'apply'; then
  pass "live_source_paths_untouched_until_apply"
else
  fail "live_source_paths_untouched_until_apply" \
    "expected '(live|CTX_ROOT)' and 'apply' each documented within 250 chars of an 'archived: true' mention"
fi

# ===========================================================================
# False flag / unknown host: no staged transition; post-run counts;
# Bitbucket and Azure DevOps as the must-reject unknown-host examples.
# ===========================================================================

banner "a false flag or an unknown host stages nothing, and the summary counts both"

if near_all "$DRIFT_N" '\bfalse\b' 250 '(no transition|not staged|no staged)'; then
  pass "false_flag_stages_no_transition"
else
  fail "false_flag_stages_no_transition" \
    "expected a no-transition/not-staged phrase documented within 250 chars of 'false'"
fi

if near_all "$DRIFT_N" 'unknown' 250 '(no transition|not staged|no staged|never stages)'; then
  pass "unknown_host_stages_no_transition"
else
  fail "unknown_host_stages_no_transition" \
    "expected a no-transition/not-staged/never-stages phrase documented within 250 chars of 'unknown'"
fi

if near "$DRIFT_N" 'unknown' '(how many|count of|number of)[^.]{0,40}checked' 250; then
  pass "summary_reports_checked_and_unknown_counts"
else
  fail "summary_reports_checked_and_unknown_counts" \
    "expected a 'how many'/'count of'/'number of' phrase immediately preceding 'checked', documented within 250 chars of 'unknown'"
fi

assert_str_i "bitbucket_named_as_unknown_forge" "$DRIFT_N" "bitbucket"
assert_str_i "azure_devops_named_as_unknown_forge" "$DRIFT_N" "azure devops"

if near_all "$DRIFT_N" '(bitbucket|azure devops)' 250 '(unknown|never|no transition|not staged)'; then
  pass "unknown_forge_example_never_stages_transition"
else
  fail "unknown_forge_example_never_stages_transition" \
    "expected 'unknown'/'never'/'no transition'/'not staged' documented within 250 chars of 'Bitbucket' or 'Azure DevOps'"
fi

# ===========================================================================
# Phase 0.5's dispatch is by table order, its `gh api` calls are not
# unauthenticated, and a call that fails is `unknown` (PR #15 review,
# finding 9).
# ===========================================================================

banner "Phase 0.5 dispatch order, auth claim, and failed-call rule"

# The table IS the dispatch: the doc tells the model to read it top-down and
# take the first matching row. With the GitLab row below "any other host gh
# resolves", a host like gitlab.company.com matches the catch-all first and
# gets `GH_HOST=gitlab.company.com gh api repos/...`, which cannot work.
# Asserted on the raw section, not the wrap-normalized copy, because row
# order is the property and normalization destroys it.
PHASE05_RAW="$(awk '/^### Phase 0\.5/,/^### Phase 1/' "$DRIFT_MD")"
gl_row="$(printf '%s\n' "$PHASE05_RAW" | grep -niE '^\|[^|]*gitlab' | head -n1 | cut -d: -f1)"
ghe_row="$(printf '%s\n' "$PHASE05_RAW" | grep -niE '^\|[^|]*any other host' | head -n1 | cut -d: -f1)"
if [ -z "${gl_row:-}" ] || [ -z "${ghe_row:-}" ]; then
  fail "phase05_gitlab_row_precedes_gh_catchall" \
    "could not locate both rows in the Phase 0.5 table (gitlab row: ${gl_row:-<none>}, catch-all row: ${ghe_row:-<none>})"
elif [ "$gl_row" -lt "$ghe_row" ]; then
  pass "phase05_gitlab_row_precedes_gh_catchall"
else
  fail "phase05_gitlab_row_precedes_gh_catchall" \
    "the GitLab row is at table line $gl_row, below the 'any other host gh resolves' catch-all at line $ghe_row" \
    "a self-hosted GitLab host matches the catch-all first and is dispatched to gh"
fi

# `gh api` reads GH_TOKEN/GITHUB_TOKEN or the gh auth keychain. Not passing
# a token on the command line does not make the call unauthenticated, and
# the difference is not cosmetic: github.com's genuinely unauthenticated
# limit is 60 requests/hour, inside the range this feature exists to serve.
if printf '%s' "$DRIFT_N" | grep -qiE 'reads are unauthenticated|unauthenticated: no token'; then
  fail "phase05_no_false_unauthenticated_claim" \
    "Phase 0.5 still claims its reads are unauthenticated; gh api uses whatever ambient credentials are present"
else
  pass "phase05_no_false_unauthenticated_claim"
fi

if near "$DRIFT_N" 'gh api' '(GH_TOKEN|GITHUB_TOKEN|gh auth|ambient)' 250; then
  pass "phase05_names_ambient_credentials"
else
  fail "phase05_names_ambient_credentials" \
    "expected the ambient-credential behaviour (GH_TOKEN / GITHUB_TOKEN / gh auth) documented within 250 chars of 'gh api'"
fi

# Without a rule, a model reading a missing .archived field off a 403 or a
# 404 body has nothing telling it that is not `false`, and reports the
# source as confirmed-live.
if near_all "$DRIFT_N" 'unknown' 250 '(non-2xx|rate limit|429|403)'; then
  pass "phase05_failed_call_maps_to_unknown"
else
  fail "phase05_failed_call_maps_to_unknown" \
    "expected a failed-call rule (non-2xx / rate limit / 403 / 429) documented within 250 chars of 'unknown'"
fi

# ===========================================================================
# Preservation: archived sources stay excluded from Phase 1 exactly as
# today, including one staged by a proposal still awaiting apply.
# ===========================================================================

banner "archived sources already excluded from the Phase 1 probe stay excluded"

assert_str "in_scope_filter_archived_false_sentence_preserved" "$DRIFT_N" \
  '`archived: false` (or field absent — defaults to false)'

if near "$DRIFT_N" 'archived: false' 'CTX_PROPOSED' 200; then
  fail "in_scope_filter_not_redirected_to_proposed_dir" \
    "found 'CTX_PROPOSED' within 200 chars of the in-scope 'archived: false' filter — the filter should read the live file, not a pending proposal"
else
  pass "in_scope_filter_not_redirected_to_proposed_dir"
fi

assert_str "unapplied_proposal_guard_preserved" "$DRIFT_N" \
  'a prior DISCOVER/REFRESH proposal is staged and not yet applied'

# ===========================================================================
# Both routers replace their manual-flagging sentence with one naming the
# staged transition, neither grows past its pre-change byte count, and the
# shipped router-size doctrine checks for both files keep passing.
# ===========================================================================

banner "both routers replace their manual-archiving sentence and stay within their byte ceiling"

assert_absent "refresh_skill_old_manual_flag_sentence_gone" "$REFRESH_NOTDO_N" \
  "does not detect upstream archival automatically"

assert_absent "discover_skill_old_manual_flag_sentence_gone" "$DISCOVER_NOTDO_N" \
  'does not auto-detect "archived" upstream state'

if near_all "$REFRESH_NOTDO_N" 'archiv' 250 'stag'; then
  pass "refresh_skill_names_staged_transition"
else
  fail "refresh_skill_names_staged_transition" \
    "expected a word starting 'stag' (staged/stages/staging) within 250 chars of 'archiv' in refresh/SKILL.md's 'What this skill does NOT do' section"
fi

if near_all "$DISCOVER_NOTDO_N" 'archiv' 250 'stag'; then
  pass "discover_skill_names_staged_transition"
else
  fail "discover_skill_names_staged_transition" \
    "expected a word starting 'stag' (staged/stages/staging) within 250 chars of 'archiv' in discover/SKILL.md's 'What this skill does NOT do' section"
fi

REFRESH_SKILL_MD_BASELINE_BYTES=8200
DISCOVER_SKILL_MD_BASELINE_BYTES=8186

refresh_skill_bytes="$(wc -c < "$REFRESH_SKILL" | tr -d ' ')"
if [ "$refresh_skill_bytes" -le "$REFRESH_SKILL_MD_BASELINE_BYTES" ]; then
  pass "refresh_skill_md_within_baseline_bytes"
else
  fail "refresh_skill_md_within_baseline_bytes" \
    "refresh/SKILL.md is $refresh_skill_bytes bytes — over the $REFRESH_SKILL_MD_BASELINE_BYTES-byte pre-change baseline"
fi

discover_skill_bytes="$(wc -c < "$DISCOVER_SKILL" | tr -d ' ')"
if [ "$discover_skill_bytes" -le "$DISCOVER_SKILL_MD_BASELINE_BYTES" ]; then
  pass "discover_skill_md_within_baseline_bytes"
else
  fail "discover_skill_md_within_baseline_bytes" \
    "discover/SKILL.md is $discover_skill_bytes bytes — over the $DISCOVER_SKILL_MD_BASELINE_BYTES-byte pre-change baseline"
fi

DOCTRINE_OUT="$(bash "$DOCTRINE_SH" 2>&1)"

if printf '%s' "$DOCTRINE_OUT" | grep -qE 'skills/discover/SKILL\.md is [0-9]+ bytes'; then
  fail "doctrine_discover_skill_size_check_passes" \
    "$(printf '%s' "$DOCTRINE_OUT" | grep -E 'skills/discover/SKILL\.md is [0-9]+ bytes')"
else
  pass "doctrine_discover_skill_size_check_passes"
fi

if printf '%s' "$DOCTRINE_OUT" | grep -qE 'skills/refresh/SKILL\.md is [0-9]+ bytes'; then
  fail "doctrine_refresh_skill_size_check_passes" \
    "$(printf '%s' "$DOCTRINE_OUT" | grep -E 'skills/refresh/SKILL\.md is [0-9]+ bytes')"
else
  pass "doctrine_refresh_skill_size_check_passes"
fi

# ===========================================================================
# Read mechanism: gh api for GitHub-shaped hosts, no non-HEAD curl for the
# GitLab read, no auth token plumbed anywhere in the reference.
# ===========================================================================

banner "the read itself: gh api, a HEAD-shaped GitLab call if any, and no token handling"

assert_str "github_read_uses_gh_api" "$DRIFT_N" "gh api"

if near "$DRIFT_N" 'gitlab' '(api|read.only|read only)' 200; then
  pass "gitlab_read_documented"
else
  fail "gitlab_read_documented" \
    "expected 'api'/'read-only' documented within 200 chars of 'gitlab'"
fi

GITLAB_FENCE_RESULT="$(gitlab_fence_check "$DRIFT_MD")"
GITLAB_FENCE_BAD="$(printf '%s\n' "$GITLAB_FENCE_RESULT" | sed -n '2p')"
if [ "$GITLAB_FENCE_BAD" = "BAD" ]; then
  fail "gitlab_read_has_no_non_head_curl_form" \
    "a fenced bash/sh/shell/jq block mentioning gitlab contains a curl invocation without --head/-I"
else
  pass "gitlab_read_has_no_non_head_curl_form"
fi

if printf '%s' "$DRIFT_RAW" | grep -qiE 'authorization:[[:space:]]*bearer|GITHUB_TOKEN|PRIVATE-TOKEN'; then
  fail "no_auth_token_strings_present" \
    "found an auth-token string (Authorization: Bearer / GITHUB_TOKEN / PRIVATE-TOKEN) in $DRIFT_MD"
else
  pass "no_auth_token_strings_present"
fi

if printf '%s' "$DOCTRINE_OUT" | grep -qF 'non-HEAD curl invocation'; then
  fail "doctrine_no_non_head_curl_in_engine_scripts" \
    "$(printf '%s' "$DOCTRINE_OUT" | grep -F 'non-HEAD curl invocation')"
else
  pass "doctrine_no_non_head_curl_in_engine_scripts"
fi

if printf '%s' "$DOCTRINE_OUT" | grep -qF 'auth-token plumbing detected'; then
  fail "doctrine_no_auth_token_plumbing_in_engine_scripts" \
    "$(printf '%s' "$DOCTRINE_OUT" | grep -F 'auth-token plumbing detected')"
else
  pass "doctrine_no_auth_token_plumbing_in_engine_scripts"
fi

if near "$DRIFT_N" 'gh api' '(no token|without[^.]{0,15}token|token[^.]{0,15}(not|never))' 250; then
  pass "no_token_handling_stated"
else
  fail "no_token_handling_stated" \
    "expected a no-token-handling phrase documented within 250 chars of 'gh api'"
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------

banner "summary"
printf 'passed: %d   failed: %d\n' "$pass_count" "$fail_count"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
