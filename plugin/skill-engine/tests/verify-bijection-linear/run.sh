#!/usr/bin/env bash
# Black-box test runner for the stamped verify.sh's catalog ↔ references
# bijection check, at scale and under authoring disorder. Two concerns:
#
#   - wall-clock cost at a large reference count stays low, isolated from
#     every other check by diffing a full run against a run with the
#     bijection block stubbed to an immediate skip;
#   - every current diagnostic the bijection check can raise still fires,
#     with the same message text, on a handful of small targeted fixtures
#     (this also guards the single-fire suppression that keeps an already-
#     flagged broken-directory or duplicate-form slug from double-failing),
#     and failure lines come out in sorted slug order regardless of
#     authoring order.
#
# Never asserts anything about which lines of code implement the check —
# only its observable stdout/exit-code behavior against the stamped
# verify.sh, so a full rewrite of the check's internals leaves this runner
# meaningful.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY_SH="$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh"

pass_count=0
fail_count=0
created_paths=()

cleanup_tmp() {
  local p
  for p in "${created_paths[@]:-}"; do
    [ -n "$p" ] && [ -e "$p" ] && rm -rf "$p"
  done
}
trap cleanup_tmp EXIT

pass_case() {
  printf '  PASS  %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail_case() {
  printf '  FAIL  %s\n%s\n' "$1" "$2"
  fail_count=$((fail_count + 1))
}

# ── Fixture builders ────────────────────────────────────────────────────

# Minimal valid source-paths.json (empty sources) so only the bijection
# check can produce a [FAIL] line — every other check skips cleanly against
# an empty sources[] array.
seed_ctx() {
  local ctx="$1"
  mkdir -p "$ctx/research" "$ctx/references"
  printf '{"schema_version": 1, "sources": []}\n' > "$ctx/research/source-paths.json"
}

# $1 = ctx root, $2... = catalog body lines (already markdown table rows)
write_nav() {
  local ctx="$1"; shift
  {
    printf -- '---\n'
    printf 'name: test-context\n'
    printf 'description: Fixture navigator for bijection-linear tests.\n'
    printf -- '---\n\n'
    printf '# Context navigator\n\n## Catalog\n\n'
    printf '| Reference | Description |\n|---|---|\n'
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$ctx/SKILL.md"
}

# $1 = ctx root, $2 = slug — file-form reference, no frontmatter
write_ref() {
  printf '# %s\n\nReference body for %s.\n' "$2" "$2" > "$1/references/$2.md"
}

# $1 = ctx root, $2 = slug — valid directory-form reference (canonical
# primary <slug>/<slug>.md present)
write_dir_ref() {
  mkdir -p "$1/references/$2"
  printf '# %s\n\nDirectory-form primary for %s.\n' "$2" "$2" > "$1/references/$2/$2.md"
}

# $1 = ctx root, $2 = slug — directory-form reference MISSING its
# canonical primary. Deliberately empty (no companion file at all) so this
# fixture exercises only the missing-canonical-primary defect, not also
# the nested-path scan (which fires on any *.md file at depth-2 whose
# basename doesn't match its parent directory).
write_broken_dir_ref() {
  mkdir -p "$1/references/$2"
}

# $1 = ctx root; run the stamped verify.sh against it. Sets OUT and RC.
run_verify() {
  OUT="$(CTX_ROOT="$1" bash "$VERIFY_SH" 2>&1)" && RC=0 || RC=$?
}

new_ctx() {
  local ctx
  ctx="$(mktemp -d -t skill-engine-bijection-linear.XXXXXX)"
  created_paths+=("$ctx")
  seed_ctx "$ctx"
  printf '%s' "$ctx"
}

# ══════════════════════════════════════════════════════════════════════
# Timing: Check 4's own wall-clock contribution at 2,000 references
# ══════════════════════════════════════════════════════════════════════
#
# Builds the audit's synthetic tree (N one-paragraph references, N catalog
# rows under the table header, real markdown link syntax so the extraction
# regex actually harvests every row) and measures Check 4's own
# contribution by diffing a full run against a run with the check's block
# stubbed to an immediate skip. The stub is located by matching the
# check's own run_check label and everything up to (not including) the
# next run_check line, so it survives the block moving or shrinking.

REF_COUNT=2000

build_large_tree() {
  local ctx="$1" n="$2" i slug
  mkdir -p "$ctx/references" "$ctx/research"
  printf '{"schema_version": 1, "sources": [{"id": "synthetic-src", "kind": "git-managed", "url": "https://github.com/example/synthetic", "status": "confirmed", "lifecycle": {"state": "reachable"}}]}\n' \
    > "$ctx/research/source-paths.json"

  {
    printf -- '---\n'
    printf 'name: perf-fixture-context\n'
    printf 'description: Synthetic large-catalog fixture for Check 4 timing isolation.\n'
    printf -- '---\n\n'
    printf '# Perf fixture navigator\n\n## Catalog\n\n'
    printf '| Reference | Description |\n|---|---|\n'
    for ((i = 1; i <= n; i++)); do
      printf -v slug 'ref%05d' "$i"
      printf '| [%s](references/%s.md) | One-paragraph synthetic reference %s. |\n' "$slug" "$slug" "$slug"
    done
  } > "$ctx/SKILL.md"

  for ((i = 1; i <= n; i++)); do
    printf -v slug 'ref%05d' "$i"
    printf '# %s\n\nSynthetic one-paragraph reference body for %s, present only to exercise the catalog ↔ references bijection at scale.\n' \
      "$slug" "$slug" > "$ctx/references/$slug.md"
  done
}

# Writes a stubbed copy of verify.sh with the bijection check's block
# (from its run_check line up to, not including, the next run_check line)
# replaced by a single immediate skip. Substring match (not regex) so the
# multi-byte "↔" in the label needs no escaping.
build_stubbed_verify() {
  local src="$1" dst="$2"
  awk -v marker='run_check "Catalog ↔ references bijection (catalog-bijection)"' '
    index($0, marker) == 1 {
      print
      print "skip \"catalog-bijection stubbed out for timing isolation\""
      skipping = 1
      next
    }
    skipping && index($0, "run_check \"") == 1 { skipping = 0 }
    skipping { next }
    { print }
  ' "$src" > "$dst"
}

run_timing_ac() {
  local big_ctx stub_verify t0 t1 full_out full_rc t_full t2 t3 stub_out t_stub diff_s

  big_ctx="$(mktemp -d -t skill-engine-bijection-linear-perf.XXXXXX)"
  created_paths+=("$big_ctx")
  build_large_tree "$big_ctx" "$REF_COUNT"

  stub_verify="$(mktemp -t skill-engine-bijection-linear-stub.XXXXXX)"
  created_paths+=("$stub_verify")
  build_stubbed_verify "$VERIFY_SH" "$stub_verify"
  chmod +x "$stub_verify"

  t0=$(date +%s)
  full_out="$(CTX_ROOT="$big_ctx" bash "$VERIFY_SH" 2>&1)" && full_rc=0 || full_rc=$?
  t1=$(date +%s)
  t_full=$((t1 - t0))

  t2=$(date +%s)
  stub_out="$(CTX_ROOT="$big_ctx" bash "$stub_verify" 2>&1)"
  t3=$(date +%s)
  t_stub=$((t3 - t2))

  diff_s=$((t_full - t_stub))

  printf '  -- timing: full=%ss stubbed=%ss check4-contribution=%ss (N=%d)\n' \
    "$t_full" "$t_stub" "$diff_s" "$REF_COUNT"

  if [ "$full_rc" -eq 0 ] && printf '%s' "$full_out" | grep -qF 'Failed: 0'; then
    pass_case "2,000-reference contextualizer passes all checks"
  else
    fail_case "2,000-reference contextualizer passes all checks" "$full_out"
  fi

  if [ "$diff_s" -lt 3 ]; then
    pass_case "Check 4's own wall-clock contribution at N=2,000 is under 3s (got ${diff_s}s)"
  else
    fail_case "Check 4's own wall-clock contribution at N=2,000 is under 3s (got ${diff_s}s)" \
      "full run: ${t_full}s, stubbed run: ${t_stub}s, difference: ${diff_s}s"
  fi

  # Sanity: the stub must not have broken the script — it should still run
  # to completion and skip the bijection check cleanly rather than crash.
  if printf '%s' "$stub_out" | grep -qF 'catalog-bijection stubbed out for timing isolation'; then
    pass_case "stubbed copy runs to completion and skips the bijection check as intended"
  else
    fail_case "stubbed copy runs to completion and skips the bijection check as intended" "$stub_out"
  fi
}

run_timing_ac

# ══════════════════════════════════════════════════════════════════════
# Diagnostic preservation: every current fail() class, verbatim text
# ══════════════════════════════════════════════════════════════════════
#
# One small, targeted fixture per class. Message text is copied verbatim
# from the current Check 4 block so a rewrite that renames or reflows a
# diagnostic is caught, not just one that removes it outright.

# phantom row: catalog cites a file-form target that exists nowhere on disk
build_phantom_file() {
  write_nav "$1" '| [ghost1](references/ghost1.md) | Phantom, file form declared. |'
}
{
  ctx="$(new_ctx)"; build_phantom_file "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'Catalog row points at references/ghost1.md but no matching reference exists (file or directory)'; then
    pass_case "phantom row: file-form declared, nothing on disk"
  else
    fail_case "phantom row: file-form declared, nothing on disk" "$OUT"
  fi
}

# phantom row: catalog cites a directory-form target that exists nowhere on disk
build_phantom_dir() {
  write_nav "$1" '| [ghost2](references/ghost2/) | Phantom, directory form declared. |'
}
{
  ctx="$(new_ctx)"; build_phantom_dir "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'Catalog row points at references/ghost2/ but no matching reference exists (file or directory)'; then
    pass_case "phantom row: dir-form declared, nothing on disk"
  else
    fail_case "phantom row: dir-form declared, nothing on disk" "$OUT"
  fi
}

# orphan reference: a file-form reference on disk with no catalog row at all
build_orphan_file() {
  write_ref "$1" orph1
  write_nav "$1"
}
{
  ctx="$(new_ctx)"; build_orphan_file "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'references/orph1.md exists but no catalog row points at it (run /skill-engine:self-audit to repair)'; then
    pass_case "orphan reference: file form, no catalog row"
  else
    fail_case "orphan reference: file form, no catalog row" "$OUT"
  fi
}

# orphan reference: a valid directory-form reference on disk with no catalog row
build_orphan_dir() {
  write_dir_ref "$1" orph2
  write_nav "$1"
}
{
  ctx="$(new_ctx)"; build_orphan_dir "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'references/orph2/ exists with canonical primary but no catalog row points at it (run /skill-engine:self-audit to repair)'; then
    pass_case "orphan reference: dir form, no catalog row"
  else
    fail_case "orphan reference: dir form, no catalog row" "$OUT"
  fi
}

# duplicate-form: one slug present as both file-form and directory-form
build_duplicate_form() {
  write_ref "$1" dupform
  write_dir_ref "$1" dupform
  write_nav "$1" '| [dupform](references/dupform.md) | file-form catalog row. |'
}
{
  ctx="$(new_ctx)"; build_duplicate_form "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'duplicate primary for reference dupform: file form references/dupform.md AND directory form references/dupform/ both present'; then
    pass_case "duplicate-form: file and directory both present"
  else
    fail_case "duplicate-form: file and directory both present" "$OUT"
  fi
}

# form mismatch: catalog declares file form, on-disk reference is directory form
build_mismatch_file_declared() {
  write_dir_ref "$1" mm1
  write_nav "$1" '| [mm1](references/mm1.md) | declared file form. |'
}
{
  ctx="$(new_ctx)"; build_mismatch_file_declared "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'Catalog row references/mm1.md declares file form but the on-disk reference is directory form references/mm1/ — link will render broken'; then
    pass_case "form mismatch: catalog declares file, on-disk is directory"
  else
    fail_case "form mismatch: catalog declares file, on-disk is directory" "$OUT"
  fi
}

# form mismatch: catalog declares directory form, on-disk reference is file form
build_mismatch_dir_declared() {
  write_ref "$1" mm2
  write_nav "$1" '| [mm2](references/mm2/) | declared directory form. |'
}
{
  ctx="$(new_ctx)"; build_mismatch_dir_declared "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'Catalog row references/mm2/ declares directory form but the on-disk reference is file form references/mm2.md — link will render broken'; then
    pass_case "form mismatch: catalog declares directory, on-disk is file"
  else
    fail_case "form mismatch: catalog declares directory, on-disk is file" "$OUT"
  fi
}

# catalog duplicate-rows: two rows citing the same file
build_catalog_dup_rows() {
  write_ref "$1" dup
  write_nav "$1" \
    '| [dup](references/dup.md) | Dup row one. |' \
    '| [dup](references/dup.md) | Dup row two. |'
}
{
  ctx="$(new_ctx)"; build_catalog_dup_rows "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'Catalog has duplicate rows pointing at references/dup (strict 1:1 bijection violation)'; then
    pass_case "catalog duplicate-rows: two rows citing one file"
  else
    fail_case "catalog duplicate-rows: two rows citing one file" "$OUT"
  fi
}

# malformed catalog target: consecutive '/' characters
build_malformed_consecutive_slash() {
  write_nav "$1" '| [bad](references/foo//bar) | Malformed: consecutive slash. |'
}
{
  ctx="$(new_ctx)"; build_malformed_consecutive_slash "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    "Catalog row target references/foo//bar contains consecutive '/' characters — likely typo; expected file form references/<slug>.md or directory form references/<slug>/"; then
    pass_case "malformed catalog target: consecutive '/' characters"
  else
    fail_case "malformed catalog target: consecutive '/' characters" "$OUT"
  fi
}

# malformed catalog target: nested directory-form target
build_malformed_nested_dir() {
  write_nav "$1" '| [bad](references/foo/bar/) | Malformed: nested directory form. |'
}
{
  ctx="$(new_ctx)"; build_malformed_nested_dir "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'Catalog row target references/foo/bar/ encodes a nested path; references are at depth-1 only (file form references/<slug>.md or directory form references/<slug>/)'; then
    pass_case "malformed catalog target: nested directory-form target"
  else
    fail_case "malformed catalog target: nested directory-form target" "$OUT"
  fi
}

# malformed catalog target: nested file-form target
build_malformed_nested_file() {
  write_nav "$1" '| [bad](references/foo/bar.md) | Malformed: nested file form. |'
}
{
  ctx="$(new_ctx)"; build_malformed_nested_file "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'Catalog row target references/foo/bar.md encodes a nested path; references are at depth-1 only (file form references/<slug>.md or directory form references/<slug>/)'; then
    pass_case "malformed catalog target: nested file-form target"
  else
    fail_case "malformed catalog target: nested file-form target" "$OUT"
  fi
}

# malformed catalog target: canonical primary cited directly inside a directory-form reference
build_malformed_canonical_inside_dir() {
  write_nav "$1" '| [bad](references/foo/foo.md) | Malformed: canonical primary cited directly. |'
}
{
  ctx="$(new_ctx)"; build_malformed_canonical_inside_dir "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'Catalog row references/foo/foo.md points at the canonical primary inside a directory-form reference; the directory-form catalog target should be references/foo/ (trailing-slash to disambiguate from file form)'; then
    pass_case "malformed catalog target: canonical-primary-inside-directory"
  else
    fail_case "malformed catalog target: canonical-primary-inside-directory" "$OUT"
  fi
}

# malformed catalog target: neither a .md suffix nor a trailing slash
build_malformed_missing_suffix() {
  write_nav "$1" '| [bad](references/foo) | Malformed: no .md, no trailing slash. |'
}
{
  ctx="$(new_ctx)"; build_malformed_missing_suffix "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'Catalog row target references/foo has neither a .md suffix nor a trailing / — file form requires .md, directory form requires trailing /'; then
    pass_case "malformed catalog target: missing .md suffix and trailing slash"
  else
    fail_case "malformed catalog target: missing .md suffix and trailing slash" "$OUT"
  fi
}

# nested-path/depth violation: a stray .md sits inside a directory-form
# reference whose basename does not match the directory (the canonical
# primary itself is present and valid, so only the stray file is at fault)
build_nested_path() {
  write_dir_ref "$1" nst
  printf '# extra\n\nStray nested file, not the canonical primary.\n' > "$1/references/nst/extra.md"
  write_nav "$1" '| [nst](references/nst/) | Directory-form with a stray nested file. |'
}
{
  ctx="$(new_ctx)"; build_nested_path "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'references/nst/extra.md is at a nested path that violates the depth-1 contract (only the canonical primary <slug>/<slug>.md is permitted at depth-2 inside a directory-form reference)'; then
    pass_case "nested path: stray .md beside a valid canonical primary"
  else
    fail_case "nested path: stray .md beside a valid canonical primary" "$OUT"
  fi
}

# sub-directory-under-a-directory-form ban: any sub-directory at depth ≥ 2
# is forbidden regardless of contents, even alongside a valid canonical primary
build_sub_directory_ban() {
  write_dir_ref "$1" subdirban
  mkdir -p "$1/references/subdirban/nested"
  write_nav "$1" '| [subdirban](references/subdirban/) | Directory-form with a forbidden sub-directory. |'
}
{
  ctx="$(new_ctx)"; build_sub_directory_ban "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'references/subdirban/nested/ is a sub-directory under a directory-form reference — sub-directories are forbidden (depth-2+ paths fail regardless of file extension)'; then
    pass_case "sub-directory under a directory-form reference is banned"
  else
    fail_case "sub-directory under a directory-form reference is banned" "$OUT"
  fi
}

# broken directory: missing canonical primary, message text preserved
build_broken_directory_message() {
  write_broken_dir_ref "$1" brkmsg
  write_nav "$1"
}
{
  ctx="$(new_ctx)"; build_broken_directory_message "$ctx"; run_verify "$ctx"
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF \
    'references/brkmsg/ is a directory but the canonical primary references/brkmsg/brkmsg.md is missing'; then
    pass_case "broken directory: canonical primary missing"
  else
    fail_case "broken directory: canonical primary missing" "$OUT"
  fi
}

# ══════════════════════════════════════════════════════════════════════
# Single-fire suppression: an already-flagged slug fails exactly once
# ══════════════════════════════════════════════════════════════════════
#
# A slug already reported broken-directory or duplicate-form must produce
# exactly one Check 4 failure line for it — even when its catalog row's
# declared form disagrees with the slug's on-disk form, which would
# otherwise be an independent, additional trigger for a failure. Both
# fixtures below deliberately create that disagreement so a rewrite that
# drops the suppression shows up as a second failure line for the slug.

# a broken-directory slug, cited from the catalog in directory form: an
# un-suppressed phantom loop would additionally report it as unmatched
build_broken_directory_suppression() {
  write_broken_dir_ref "$1" brk1
  write_nav "$1" '| [brk1](references/brk1/) | Directory-form row for a broken directory. |'
}
{
  ctx="$(new_ctx)"; build_broken_directory_suppression "$ctx"; run_verify "$ctx"
  brk1_count=$(printf '%s\n' "$OUT" | grep -c '\[FAIL\].*brk1' || true)
  if [ "$RC" -eq 1 ] && [ "$brk1_count" -eq 1 ] \
    && printf '%s' "$OUT" | grep -qF 'canonical primary references/brk1/brk1.md is missing' \
    && ! printf '%s' "$OUT" | grep -qF 'references/brk1/ but no matching reference exists'; then
    pass_case "broken-directory suppression: exactly one failure line, not two"
  else
    fail_case "broken-directory suppression: exactly one failure line, not two" \
      "failure-line count for brk1: $brk1_count
$OUT"
  fi
}

# a duplicate-form slug, cited from the catalog in directory form: an
# un-suppressed mismatch check would additionally report a form mismatch
# against the file-form side
build_duplicate_form_suppression() {
  write_ref "$1" dupform2
  write_dir_ref "$1" dupform2
  write_nav "$1" '| [dupform2](references/dupform2/) | Directory-form row for a duplicate-form slug. |'
}
{
  ctx="$(new_ctx)"; build_duplicate_form_suppression "$ctx"; run_verify "$ctx"
  dupform2_count=$(printf '%s\n' "$OUT" | grep -c '\[FAIL\].*dupform2' || true)
  if [ "$RC" -eq 1 ] && [ "$dupform2_count" -eq 1 ] \
    && printf '%s' "$OUT" | grep -qF 'duplicate primary for reference dupform2' \
    && ! printf '%s' "$OUT" | grep -qF 'on-disk reference is file form references/dupform2.md'; then
    pass_case "duplicate-form suppression: exactly one failure line, not two"
  else
    fail_case "duplicate-form suppression: exactly one failure line, not two" \
      "failure-line count for dupform2: $dupform2_count
$OUT"
  fi
}

# ══════════════════════════════════════════════════════════════════════
# Sorted output order
# ══════════════════════════════════════════════════════════════════════
#
# Catalog rows for three phantom slugs are authored out of alphabetical
# order (zzz, aaa, mmm); a naive iteration-order implementation prints
# failures in that authored order, but the bijection check's contract is
# sorted-slug output so two runs over the same tree print identical output.
build_sorted_order() {
  write_nav "$1" \
    '| [zzz](references/zzz.md) | Phantom z. |' \
    '| [aaa](references/aaa.md) | Phantom a. |' \
    '| [mmm](references/mmm.md) | Phantom m. |'
}
{
  ctx="$(new_ctx)"; build_sorted_order "$ctx"; run_verify "$ctx"
  got_order=$(printf '%s\n' "$OUT" \
    | grep -oE '\[FAIL\] Catalog row points at references/[a-z]+\.md but no matching reference exists' \
    | grep -oE 'references/[a-z]+\.md' \
    | sed -E 's#references/([a-z]+)\.md#\1#' \
    | tr '\n' ' ')
  got_order="${got_order% }"
  if [ "$RC" -eq 1 ] && [ "$got_order" = "aaa mmm zzz" ]; then
    pass_case "phantom-row failures emit in sorted slug order (got: $got_order)"
  else
    fail_case "phantom-row failures emit in sorted slug order" \
      "expected order: aaa mmm zzz
got order: $got_order
$OUT"
  fi
}

# Orphan order is driven by a filesystem walk, not catalog-row order — an
# independent code path from the phantom case above, so it needs its own
# check: files are created out of alphabetical order (zzz, aaa, mmm) and
# the catalog stays empty so all three surface as orphans.
build_sorted_order_orphan() {
  write_ref "$1" zzz
  write_ref "$1" aaa
  write_ref "$1" mmm
  write_nav "$1"
}
{
  ctx="$(new_ctx)"; build_sorted_order_orphan "$ctx"; run_verify "$ctx"
  got_order=$(printf '%s\n' "$OUT" \
    | grep -oE '\[FAIL\] references/[a-z]+\.md exists but no catalog row points at it' \
    | grep -oE 'references/[a-z]+\.md' \
    | sed -E 's#references/([a-z]+)\.md#\1#' \
    | tr '\n' ' ')
  got_order="${got_order% }"
  if [ "$RC" -eq 1 ] && [ "$got_order" = "aaa mmm zzz" ]; then
    pass_case "orphan failures emit in sorted slug order (got: $got_order)"
  else
    fail_case "orphan failures emit in sorted slug order" \
      "expected order: aaa mmm zzz
got order: $got_order
$OUT"
  fi
}

# ── Summary ──────────────────────────────────────────────────────────────
printf '\nverify-bijection-linear: %d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
