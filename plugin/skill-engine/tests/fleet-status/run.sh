#!/usr/bin/env bash
# Oracle for fleet-wide operation and contextualizer ownership.
#
# THE INVARIANTS.
#   fleet table       — STATUS's fleet section renders one row per
#                       contextualizer the locator enumerates, six columns
#                       wide: root path, source count, last refresh (a date
#                       or `never`), pending proposal (yes/no), review
#                       state, and owner (or an em dash when unowned). An
#                       enumeration that found nothing renders no rows: the
#                       locator's nothing-found sentence goes to stdout, so
#                       neither the capture nor the derivation may treat it
#                       as a root.
#   fleet sweep       — REFRESH and SELF-AUDIT can run their whole workflow
#                       once per enumerated contextualizer, in sequence,
#                       each staging under its own `<slug>-context.proposed/`,
#                       and each printing one summary line per contextualizer.
#   conflicting selectors rejected
#                     — the enumeration flag together with a named
#                       contextualizer is a must-reject input: the run halts
#                       with an error naming both.
#   owner seed        — `source-paths.json` admits an optional root-level
#                       `owner` (non-empty string); bootstrap records the
#                       first owner token of a root `*` rule in a project-root
#                       CODEOWNERS file and omits the field when there is no
#                       root rule; the contract chapter documents it.
#   router purity     — the enumeration flag stays out of the REFRESH and
#                       DISCOVER routers; REFRESH documents its fleet flag in
#                       `refresh/references/drift-detection-and-phases.md`.
#   capability ledger — CAPABILITIES.md states what the fleet layer ships,
#                       still says the engine does not run REFRESH on cron,
#                       and leaves its "what this is *not*" claims alone.
#   nested project level
#                     — the five skills that run the shared locator describe
#                       the project install level as reaching nested roots.
#   preserved pins    — the router byte ceilings a sibling oracle hard-codes,
#                       the two frozen baseline fixtures, the shared-locator
#                       links, the schema's open root, and STATUS's
#                       python-tagged priority fence all still hold.
#
# HOW PROSE IS MATCHED. Most of what this asserts is prose an agent
# executes at run time. Markdown here is hand-wrapped, so every prose
# assertion runs against a normalized blob (newlines and whitespace runs
# collapsed) and windows around a literal anchor with `window`, never with
# a bounded regex repetition: BSD grep refuses an interval above 255 and
# reports the refusal as a non-match, which passes under GNU grep in CI
# with nothing to read. Five of the files carry the same contextualizer-root
# block verbatim, so every such assertion is anchored per file, in that
# file's own blob.
#
# HOW THE EXECUTED HALVES ARE RUN.
#   - The fleet row derivation is the first ```bash or ```python fence in
#     whichever STATUS section's heading names the fleet. It runs with the
#     working directory at a scratch repository holding three
#     contextualizers, HOME at an empty scratch home, CLAUDE_PLUGIN_ROOT at
#     this plugin, and `ctx_roots` pre-set to what the shared locator's
#     enumeration prints there — so it works whether the derivation
#     enumerates for itself or consumes the variable the locator defines.
#   - The CODEOWNERS extraction is the first ```bash fence in the bootstrap
#     intake reference that mentions CODEOWNERS. It runs with the working
#     directory at a scratch project root carrying a CODEOWNERS file and a
#     minimal `research/source-paths.json`; either printing the owner token
#     or writing it to `.owner` satisfies the assertion.
#
# WHY THE MUST-REJECT INPUT IS ASSERTED AS PROSE. The one executable
# surface that already parses both selectors is `shared/locator-block.md`,
# which this change does not own: with a name substituted and
# `--all` in argv it enumerates the named match and exits 0, with no
# rejection anywhere. So the halt is prose the agent follows, asserted
# wrap-normalized on each surface that documents the flag. An executed
# check runs in addition wherever one of those surfaces grows a guard
# fence.
#
# ENV INDIRECTION. Every file under test may be pointed at a scratch copy
# through the variable named beside it below, so a property that already
# holds can be mutated in a copy and the assertion checked for the flip
# without touching the tracked file.
#
# -e is intentionally omitted: every assertion runs and reports, rather
# than the run aborting at the first failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

SKILLS_DIR="$PLUGIN_ROOT/skills"

STATUS_SKILL_MD="${STATUS_SKILL_MD:-$SKILLS_DIR/status/SKILL.md}"
SELF_AUDIT_SKILL_MD="${SELF_AUDIT_SKILL_MD:-$SKILLS_DIR/self-audit/SKILL.md}"
REFRESH_SKILL_MD="${REFRESH_SKILL_MD:-$SKILLS_DIR/refresh/SKILL.md}"
DISCOVER_SKILL_MD="${DISCOVER_SKILL_MD:-$SKILLS_DIR/discover/SKILL.md}"
NEW_REFERENCE_SKILL_MD="${NEW_REFERENCE_SKILL_MD:-$SKILLS_DIR/new-reference/SKILL.md}"
DRIFT_PHASES_MD="${DRIFT_PHASES_MD:-$SKILLS_DIR/refresh/references/drift-detection-and-phases.md}"
INTAKE_MD="${INTAKE_MD:-$SKILLS_DIR/engine-bootstrap/references/intake-and-detection.md}"
SOURCE_PATHS_SCHEMA_JSON="${SOURCE_PATHS_SCHEMA_JSON:-$PLUGIN_ROOT/engine-bootstrap-templates/source-paths.schema.json}"
CONTRACT_MD="${CONTRACT_MD:-$PLUGIN_ROOT/docs/02-artifact-contract.md}"
CAPABILITIES_MD="${CAPABILITIES_MD:-$REPO_ROOT/CAPABILITIES.md}"
DISCOVER_BASELINE_MD="${DISCOVER_BASELINE_MD:-$PLUGIN_ROOT/tests/slice-units/fixtures/baseline/discover-SKILL.md}"
REFRESH_BASELINE_MD="${REFRESH_BASELINE_MD:-$PLUGIN_ROOT/tests/slice-units/fixtures/baseline/refresh-SKILL.md}"

LOCATOR_BLOCK_MD="$PLUGIN_ROOT/shared/locator-block.md"
ARCHIVE_RUN_SH="$PLUGIN_ROOT/tests/archive-detection/run.sh"

pass_count=0
fail_count=0
created_dirs=()

cleanup_tmp() {
  local d
  for d in "${created_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup_tmp EXIT

report() {
  local ok="$1" name="$2"
  if [ "$ok" -eq 1 ]; then
    printf '  PASS  %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s\n' "$name"
    fail_count=$((fail_count + 1))
  fi
}

fixture_error() {
  printf '  FAIL  fixture error: %s\n' "$1"
  fail_count=$((fail_count + 1))
}

mktmp() {
  local d
  d="$(mktemp -d -t skill-engine-fleet.XXXXXX)"
  # Canonicalize: on macOS mktemp hands back a /var symlink into
  # /private/var, and a path the locator prints physically would then
  # disagree with the fixture's own spelling by that symlink alone.
  d="$(cd "$d" && pwd -P)"
  created_dirs+=("$d")
  printf '%s\n' "$d"
}

# ────────────────────────────────────────────────────────────────────────
# Text helpers
# ────────────────────────────────────────────────────────────────────────

# normalize <file> — collapse to one line with whitespace runs squeezed,
# so a phrase hand-wrapped across two lines matches as one phrase.
normalize() {
  tr '\n' ' ' < "$1" | tr -s '[:space:]' ' '
}

normalize_stdin() {
  tr '\n' ' ' | tr -s '[:space:]' ' '
}

# window <marker> <before> <after> — reads a normalized blob on stdin and
# prints, one per line, the slice of text around each occurrence of a
# literal marker. Windowing happens here rather than through a bounded
# regex repetition because BSD grep refuses an interval above 255 and
# reports the refusal as a non-match.
window() {
  awk -v m="$1" -v b="$2" -v a="$3" '
    {
      s = $0; start = 1
      while ((p = index(substr(s, start), m)) > 0) {
        abs = start + p - 1
        lo = abs - b; if (lo < 1) lo = 1
        print substr(s, lo, (abs - lo) + length(m) + a)
        start = abs + length(m)
      }
    }'
}

# near_window <blob> <anchor> <before> <after> <ere...> — 1 when some
# window around the anchor matches every extended regex given.
near_window() {
  local blob="$1" anchor="$2" before="$3" after="$4"
  shift 4
  local win re hit
  while IFS= read -r win; do
    [ -n "$win" ] || continue
    hit=1
    for re in "$@"; do
      printf '%s' "$win" | grep -qiE -- "$re" || hit=0
    done
    [ "$hit" -eq 1 ] && return 0
  done < <(printf '%s' "$blob" | window "$anchor" "$before" "$after")
  return 1
}

# h3_section <file> <h2-text> <h3-text> — the body of one `### ` section,
# selected by the `## ` section it sits under. CAPABILITIES.md repeats
# `### What's deliberately not built` four times, so a first-match
# extraction reads the wrong one. The h3 text is matched literally,
# emphasis markers included — the heading on disk is `What this is *not*`,
# and an extraction spelled without the asterisks silently finds nothing.
h3_section() {
  awk -v h2="$2" -v h3="$3" '
    /^### / { cur3 = substr($0, 5); cap = (cur2 == h2 && cur3 == h3) ? 1 : 0; next }
    /^## /  { cur2 = substr($0, 4); cap = 0; next }
    /^# /   { cur2 = ""; cap = 0; next }
    cap { print }
  ' "$1"
}

# ────────────────────────────────────────────────────────────────────────
# Fenced-block helpers
# ────────────────────────────────────────────────────────────────────────

# fleet_fence <file> <what: lang|code> — the first ```bash or ```python
# fence inside whichever `##`/`###` section's heading names the fleet.
fleet_fence() {
  awk -v want="$2" '
    /^##+ / {
      if (cap) exit
      infleet = (tolower($0) ~ /fleet/) ? 1 : 0
      next
    }
    infleet && !cap && /^```[Bb]?[a-zA-Z0-9]*[[:space:]]*$/ {
      tag = tolower($0)
      sub(/^```/, "", tag)
      sub(/[[:space:]]+$/, "", tag)
      if (tag == "bash" || tag == "python") {
        if (want == "lang") { print tag; exit }
        cap = 1
      }
      next
    }
    cap && /^```[[:space:]]*$/ { exit }
    cap { print }
  ' "$1"
}

# codeowners_fence <file> — the first ```bash fence that mentions
# CODEOWNERS.
codeowners_fence() {
  awk '
    /^```bash[[:space:]]*$/ { inf = 1; buf = ""; next }
    inf && /^```[[:space:]]*$/ {
      inf = 0
      if (buf ~ /CODEOWNERS/) { printf "%s", buf; exit }
      next
    }
    inf { buf = buf $0 "\n" }
  ' "$1"
}

# guard_fence <file> — the first ```bash fence that mentions both the
# enumeration flag and a rejection verb, i.e. an executable guard for the
# must-reject input. Absent today on every surface below.
guard_fence() {
  awk '
    /^```bash[[:space:]]*$/ { inf = 1; buf = ""; next }
    inf && /^```[[:space:]]*$/ {
      inf = 0
      if (buf ~ /--all/ && tolower(buf) ~ /halt|error|refus|reject/) { printf "%s", buf; exit }
      next
    }
    inf { buf = buf $0 "\n" }
  ' "$1"
}

# ────────────────────────────────────────────────────────────────────────
# Scratch fixtures
# ────────────────────────────────────────────────────────────────────────

git_q() {
  local repo="$1"; shift
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$repo" \
      -c user.name=fixture -c user.email=fixture@example.invalid \
      -c commit.gpgsign=false -c init.defaultBranch=main \
      "$@"
}

# mk_source <id> <last-checked-or-empty> — one registry entry.
mk_source() {
  local id="$1" checked="$2"
  if [ -n "$checked" ]; then
    printf '{"id":"%s","kind":"git-managed","url":"https://example.invalid/%s","status":"confirmed","lifecycle":{"state":"reachable","last_checked":"%s"}}' \
      "$id" "$id" "$checked"
  else
    printf '{"id":"%s","kind":"git-managed","url":"https://example.invalid/%s","status":"confirmed","lifecycle":{"state":"reachable"}}' \
      "$id" "$id"
  fi
}

# mk_ctx <skills-dir> <slug> <sources-json-array> [owner]
mk_ctx() {
  local skills_dir="$1" slug="$2" sources="$3" owner="${4:-}"
  local root="$skills_dir/$slug-context"
  mkdir -p "$root/research" "$root/references"
  printf -- '---\nname: %s-context\ndescription: x\n---\n\n# %s\n' "$slug" "$slug" \
    > "$root/SKILL.md"
  printf '{"schema_version": 1}\n' > "$root/research/.research-state.json"
  if [ -n "$owner" ]; then
    printf '{"schema_version":1,"owner":"%s","sources":[%s]}\n' "$owner" "$sources" \
      > "$root/research/source-paths.json"
  else
    printf '{"schema_version":1,"sources":[%s]}\n' "$sources" \
      > "$root/research/source-paths.json"
  fi
}

# mk_proposal <skills-dir> <slug> — a staged, Step-2-populated proposal
# beside the live tree, the shape STATUS already reports on.
mk_proposal() {
  local skills_dir="$1" slug="$2"
  local prop="$skills_dir/$slug-context.proposed"
  mkdir -p "$prop/.review" "$prop/references"
  printf '{"entries":[{"path":"references/a.md","status":"added"}]}\n' \
    > "$prop/.review/manifest.json"
  {
    printf '# Review — `%s-context.proposed/`\n\n' "$slug"
    printf '## Step 1 — Predictions (fill these before reading the diff)\n\n'
    printf -- '- *"This skill is for building things"*\n\n'
    printf '## Step 2 — Disagreement set\n\n'
    printf 'One reference the draft adds that the prediction did not name.\n\n'
    printf '## Step 3 — Sign-off\n\n'
    printf -- '- [ ] reviewed\n- [ ] provisional\n- [ ] reject\n'
  } > "$prop/.review/REVIEW.md"
}

# mk_proposal_from_template <skills-dir> <slug> — a staged proposal whose
# REVIEW.md is the SHIPPED template with `<name>` substituted and Step 1
# filled, and nothing else touched. This is the state `review`'s first pass
# leaves behind and `review`'s second pass has not yet acted on.
#
# Built from the template rather than written by hand on purpose: the whole
# of finding 7 is that the reader's literal and the template's line had
# drifted apart, and a hand-written fixture would carry whichever spelling
# the fixture author reached for — which is exactly how the drift stayed
# invisible.
REVIEW_TEMPLATE_MD="${REVIEW_TEMPLATE_MD:-$PLUGIN_ROOT/engine-bootstrap-templates/REVIEW.md.template}"

mk_proposal_from_template() {
  local skills_dir="$1" slug="$2"
  local prop="$skills_dir/$slug-context.proposed"
  mkdir -p "$prop/.review" "$prop/references"
  printf '{"entries":[{"path":"references/a.md","status":"added"}]}\n' \
    > "$prop/.review/manifest.json"
  # `<name>` as bootstrap substitutes it, then the three Step-1 blanks
  # filled the way a reviewer fills them. Step 2 is left exactly as the
  # template ships it.
  sed -e "s|<name>|$slug|g" -e 's|___|a filled prediction|g' \
    "$REVIEW_TEMPLATE_MD" > "$prop/.review/REVIEW.md"
}

# ────────────────────────────────────────────────────────────────────────
# Blobs
# ────────────────────────────────────────────────────────────────────────

for f in "$STATUS_SKILL_MD" "$SELF_AUDIT_SKILL_MD" "$REFRESH_SKILL_MD" \
         "$DISCOVER_SKILL_MD" "$NEW_REFERENCE_SKILL_MD" "$DRIFT_PHASES_MD" \
         "$INTAKE_MD" "$SOURCE_PATHS_SCHEMA_JSON" "$CONTRACT_MD" \
         "$CAPABILITIES_MD" "$DISCOVER_BASELINE_MD" "$REFRESH_BASELINE_MD"; do
  [ -s "$f" ] || fixture_error "a file under test is missing or empty: $f"
done

STATUS_N="$(normalize "$STATUS_SKILL_MD")"
SELF_AUDIT_N="$(normalize "$SELF_AUDIT_SKILL_MD")"
DRIFT_N="$(normalize "$DRIFT_PHASES_MD")"
INTAKE_N="$(normalize "$INTAKE_MD")"
CONTRACT_N="$(normalize "$CONTRACT_MD")"
CAPABILITIES_N="$(normalize "$CAPABILITIES_MD")"

# ════════════════════════════════════════════════════════════════════════
# fleet table — one row per enumerated contextualizer, six columns
# ════════════════════════════════════════════════════════════════════════

FLEET_CODE="$(fleet_fence "$STATUS_SKILL_MD" code)"
FLEET_LANG="$(fleet_fence "$STATUS_SKILL_MD" lang)"

ok=1
[ -n "$FLEET_CODE" ] || ok=0
report "$ok" "fleet table: STATUS carries a fleet section with an executable row derivation"

ok=1
near_window "$STATUS_N" '--all' 400 400 'row|table' || ok=0
report "$ok" "fleet table: STATUS documents the enumeration flag as printing one row per contextualizer"

FLEET_OUT=""
FLEET_RC=1
if [ -n "$FLEET_CODE" ] && command -v git >/dev/null 2>&1; then
  FLEET_HOME="$(mktmp)"
  FLEET_REPO="$(mktmp)"
  git_q "$FLEET_REPO" init -q
  # alpha: two sources, one carrying an upstream check timestamp, no
  # proposal, no owner.  beta: one source, never checked, a staged
  # proposal.  gamma: three sources, never checked, an owner on record.
  mk_ctx "$FLEET_REPO/.claude/skills" alpha \
    "$(mk_source a1 2026-05-11T14:23:00Z),$(mk_source a2 2026-05-11T14:23:00Z)"
  mk_ctx "$FLEET_REPO/.claude/skills" beta "$(mk_source b1 '')"
  mk_proposal "$FLEET_REPO/.claude/skills" beta
  mk_ctx "$FLEET_REPO/.claude/skills" gamma \
    "$(mk_source g1 ''),$(mk_source g2 ''),$(mk_source g3 '')" '@org/team-g'
  printf 'fixture\n' > "$FLEET_REPO/README.md"
  git_q "$FLEET_REPO" add -A >/dev/null 2>&1
  git_q "$FLEET_REPO" commit -q -m fixture >/dev/null 2>&1

  # The roots the shared locator's own enumeration prints in that
  # repository, handed to the derivation as the variable the locator
  # defines — so a derivation that enumerates for itself and one that
  # consumes the locator's result are both runnable here.
  FLEET_ROOTS="$(
    awk '/^```bash$/ && !f { f = 1; next } f && /^```$/ { exit } f { print }' \
      "$LOCATOR_BLOCK_MD" | sed 's|^name="<name>"$|name=""|' \
      > "$FLEET_REPO/.locator.sh"
    cd "$FLEET_REPO" && HOME="$FLEET_HOME" LC_ALL=C bash "$FLEET_REPO/.locator.sh" --all 2>/dev/null
  )"
  rm -f "$FLEET_REPO/.locator.sh"

  if [ "$FLEET_LANG" = python ]; then
    FLEET_OUT="$(cd "$FLEET_REPO" && HOME="$FLEET_HOME" LC_ALL=C \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" ctx_roots="$FLEET_ROOTS" \
      python3 -c "$FLEET_CODE" 2>&1)"
    FLEET_RC=$?
  else
    FLEET_OUT="$(cd "$FLEET_REPO" && HOME="$FLEET_HOME" LC_ALL=C \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" ctx_roots="$FLEET_ROOTS" \
      bash -c "$FLEET_CODE" 2>&1)"
    FLEET_RC=$?
  fi
fi

# row_for <needle> — the first table row naming that contextualizer.
row_for() {
  printf '%s\n' "$FLEET_OUT" | grep -F -- "$1" | grep '|' | head -n1
}
# cell <row> <n> — the nth cell of a pipe-delimited row, trimmed, with the
# optional leading and trailing pipes discarded first.
cell() {
  printf '%s' "$1" \
    | sed -e 's/^[[:space:]]*|//' -e 's/|[[:space:]]*$//' \
    | awk -F'|' -v n="$2" '{ v = $n; gsub(/^[ \t]+/, "", v); gsub(/[ \t]+$/, "", v); print v }'
}
ncells() {
  printf '%s' "$1" \
    | sed -e 's/^[[:space:]]*|//' -e 's/|[[:space:]]*$//' \
    | awk -F'|' '{ print NF }'
}

alpha_row="$(row_for 'alpha-context')"
beta_row="$(row_for 'beta-context')"
gamma_row="$(row_for 'gamma-context')"

ok=1
[ "$FLEET_RC" -eq 0 ] || ok=0
[ -n "$alpha_row" ] && [ -n "$beta_row" ] && [ -n "$gamma_row" ] || ok=0
report "$ok" "fleet table: three installed contextualizers yield three rows, one each"

ok=1
for r in "$alpha_row" "$beta_row" "$gamma_row"; do
  [ -n "$r" ] || { ok=0; continue; }
  [ "$(ncells "$r")" -eq 6 ] || ok=0
done
report "$ok" "fleet table: every row is six columns wide"

ok=1
[ -n "$alpha_row" ] || ok=0
[ -n "$alpha_row" ] && case "$(cell "$alpha_row" 1)" in *alpha-context*) ;; *) ok=0 ;; esac
[ -n "$beta_row" ] && [ "$(cell "$beta_row" 1)" != "$(cell "$alpha_row" 1)" ] || ok=0
report "$ok" "fleet table: the first column names the contextualizer's own root"

ok=1
[ "$(cell "$alpha_row" 2)" = "2" ] || ok=0
[ "$(cell "$beta_row" 2)" = "1" ] || ok=0
[ "$(cell "$gamma_row" 2)" = "3" ] || ok=0
report "$ok" "fleet table: the second column counts each contextualizer's registered sources"

# A date where the registry carries an upstream-check timestamp, the
# literal `never` where it carries none. The cell is matched by shape,
# not by an exact string, so the derivation may read the stamp from
# wherever REFRESH records it.
ok=1
printf '%s' "$(cell "$alpha_row" 3)" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || ok=0
[ "$(cell "$gamma_row" 3)" = "never" ] || ok=0
report "$ok" "fleet table: the third column is a date when the contextualizer has been refreshed and \`never\` when it has not"

ok=1
[ "$(cell "$beta_row" 4)" = "yes" ] || ok=0
[ "$(cell "$alpha_row" 4)" = "no" ] || ok=0
[ "$(cell "$gamma_row" 4)" = "no" ] || ok=0
report "$ok" "fleet table: the fourth column says yes only for the contextualizer with a staged proposal"

# Differential rather than literal: the wording of a review state is the
# implementation's to choose, but a contextualizer with a populated
# Step 2 cannot read the same as one with no proposal at all.
ok=1
[ -n "$(cell "$beta_row" 5)" ] || ok=0
[ "$(cell "$beta_row" 5)" != "$(cell "$alpha_row" 5)" ] || ok=0
report "$ok" "fleet table: the fifth column distinguishes a proposal whose review has progressed from a contextualizer with none"

ok=1
case "$(cell "$gamma_row" 6)" in *'@org/team-g'*) ;; *) ok=0 ;; esac
[ "$(cell "$alpha_row" 6)" = "—" ] || ok=0
[ "$(cell "$beta_row" 6)" = "—" ] || ok=0
report "$ok" "fleet table: the sixth column shows the recorded owner and an em dash when none is recorded"

# Finding 7: the review-state cell's "Step 2 not generated" branch. The
# fixture below is the shipped template with Step 1 filled — the one state
# that branch exists to name — and the cell must not read as signed off or
# as merely unsigned, because `apply`'s pre-promotion gate refuses exactly
# this proposal and the fleet table would be telling a platform team it is
# ready.
TEMPLATE_OUT=""
TEMPLATE_RC=1
if [ -n "$FLEET_CODE" ] && [ -s "$REVIEW_TEMPLATE_MD" ]; then
  TEMPLATE_HOME="$(mktmp)"
  TEMPLATE_REPO="$(mktmp)"
  git_q "$TEMPLATE_REPO" init -q
  mk_ctx "$TEMPLATE_REPO/.claude/skills" delta "$(mk_source d1 '')"
  mk_proposal_from_template "$TEMPLATE_REPO/.claude/skills" delta
  printf 'fixture\n' > "$TEMPLATE_REPO/README.md"
  git_q "$TEMPLATE_REPO" add -A >/dev/null 2>&1
  git_q "$TEMPLATE_REPO" commit -q -m fixture >/dev/null 2>&1

  if [ "$FLEET_LANG" = python ]; then
    TEMPLATE_OUT="$(cd "$TEMPLATE_REPO" && HOME="$TEMPLATE_HOME" LC_ALL=C \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      ctx_roots="$TEMPLATE_REPO/.claude/skills/delta-context" \
      python3 -c "$FLEET_CODE" 2>&1)"
    TEMPLATE_RC=$?
  else
    TEMPLATE_OUT="$(cd "$TEMPLATE_REPO" && HOME="$TEMPLATE_HOME" LC_ALL=C \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      ctx_roots="$TEMPLATE_REPO/.claude/skills/delta-context" \
      bash -c "$FLEET_CODE" 2>&1)"
    TEMPLATE_RC=$?
  fi
fi

delta_row="$(printf '%s\n' "$TEMPLATE_OUT" | grep -F -- 'delta-context' | grep '|' | head -n1)"
ok=1
[ "$TEMPLATE_RC" -eq 0 ] || ok=0
[ -n "$delta_row" ] || ok=0
[ -n "$delta_row" ] && [ "$(cell "$delta_row" 4)" = "yes" ] || ok=0
report "$ok" "fleet table: fixture — a proposal staged from the shipped REVIEW template is reported as pending"

ok=1
[ -n "$delta_row" ] || ok=0
case "$(cell "$delta_row" 5)" in
  *"Step 2"*) ;;
  *) ok=0 ;;
esac
report "$ok" "fleet table: a REVIEW.md carrying the shipped template's unpopulated Step 2 reads as an ungenerated Step 2, not as a sign-off state"

# Three readers, one template line. The fleet cell re-implements in Python
# the reading STATUS already does in bash, and `apply`'s pre-promotion gate
# states it a third time in prose — which is how a literal that matched
# nothing got copied twice instead of noticed once. Asserted across all four
# files so a fix to one of them cannot leave the others behind.
APPLY_GATES_MD="${APPLY_GATES_MD:-$SKILLS_DIR/apply/references/pre-promotion-gates.md}"
STEP2_NEEDLE='again after filling Step 1'

ok=1
grep -qF "$STEP2_NEEDLE" "$REVIEW_TEMPLATE_MD" || ok=0
report "$ok" "fleet table: the shipped REVIEW template carries the unpopulated-Step-2 line every reader keys on"

for pair in "STATUS python cell:$STATUS_SKILL_MD" \
            "STATUS bash reading:$STATUS_SKILL_MD" \
            "apply pre-promotion gate:$APPLY_GATES_MD"; do
  label="${pair%%:*}"
  file="${pair#*:}"
  ok=1
  grep -qF "$STEP2_NEEDLE" "$file" || ok=0
  report "$ok" "fleet table: the $label reads Step 2 by a substring the template actually contains"
done

# Both of STATUS's own readers, matched as the constructs they are — the
# Python membership test and the bash fixed-string grep — rather than by
# counting occurrences, which the explanatory comment beside them inflates.
ok=1
grep -qF "\"$STEP2_NEEDLE\" in text" "$STATUS_SKILL_MD" || ok=0
grep -qF "grep -qF '$STEP2_NEEDLE'" "$STATUS_SKILL_MD" || ok=0
report "$ok" "fleet table: both of STATUS's review-state readers key on that same substring"

# An enumeration that found nothing is not a fleet of one. The locator
# writes its nothing-found diagnostic to *stdout* and exits 1, so a caller
# that captures stdout without testing the status hands the derivation a
# sentence where it expects absolute paths. Both ends are asserted: the
# derivation must reject a line that is not a root, and the capture the
# fleet section shows must not be the form that masks the locator's exit
# status. The empty output is taken from the locator itself rather than
# transcribed, so a reworded diagnostic cannot quietly stop being covered.
EMPTY_ROOTS=""
EMPTY_LOCATOR_RC=0
if command -v git >/dev/null 2>&1; then
  EMPTY_HOME="$(mktmp)"
  EMPTY_CWD="$(mktmp)"
  awk '/^```bash$/ && !f { f = 1; next } f && /^```$/ { exit } f { print }' \
    "$LOCATOR_BLOCK_MD" | sed 's|^name="<name>"$|name=""|' \
    > "$EMPTY_HOME/.locator.sh"
  EMPTY_ROOTS="$(
    cd "$EMPTY_CWD" && HOME="$EMPTY_HOME" LC_ALL=C \
      bash "$EMPTY_HOME/.locator.sh" --all 2>/dev/null
  )"
  EMPTY_LOCATOR_RC=$?
fi

ok=1
[ "$EMPTY_LOCATOR_RC" -ne 0 ] || ok=0
[ -n "$EMPTY_ROOTS" ] || ok=0
report "$ok" "fleet table: fixture — the locator's nothing-found path exits non-zero with its diagnostic on stdout"

if [ -n "$FLEET_CODE" ] && [ -n "$EMPTY_ROOTS" ]; then
  if [ "$FLEET_LANG" = python ]; then
    EMPTY_OUT="$(cd "$FLEET_REPO" && HOME="$FLEET_HOME" LC_ALL=C \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" ctx_roots="$EMPTY_ROOTS" \
      python3 -c "$FLEET_CODE" 2>&1)"
    EMPTY_RC=$?
  else
    EMPTY_OUT="$(cd "$FLEET_REPO" && HOME="$FLEET_HOME" LC_ALL=C \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" ctx_roots="$EMPTY_ROOTS" \
      bash -c "$FLEET_CODE" 2>&1)"
    EMPTY_RC=$?
  fi
  ok=1
  [ "$EMPTY_RC" -eq 0 ] || ok=0
  [ "$(printf '%s' "$EMPTY_OUT" | grep -c '|' | tr -d ' ')" -eq 0 ] || ok=0
  report "$ok" "fleet table: the locator's nothing-found diagnostic renders no rows rather than one bogus row"
else
  fixture_error "could not run the fleet derivation against the locator's nothing-found output"
fi

# The capture itself, not just the derivation: `export VAR=$(cmd)` always
# exits 0, so the status the locator returns is thrown away before any
# guard downstream can read it. `using-skill-engine` gets this right; the
# fleet section must not show the masking form.
# Matched against the raw file, not the normalized blob: what is banned is
# a *statement* of that shape, and the section is free to quote the form in
# prose while explaining why it is wrong.
ok=1
grep -qE '^[[:space:]]*export[[:space:]]+ctx_roots=\$\(' "$STATUS_SKILL_MD" && ok=0
report "$ok" "fleet table: the enumeration capture does not mask the locator's exit status behind \`export\`"

# The shared block is not runnable as pasted: its third line is
# `name="<name>"`, and a fleet sweep has no name to put there. A surface
# that says "verbatim" and stops has told the model to paste a fence whose
# `find -name "<name>-context"` matches nothing — which is the locator's
# exit-1 path, i.e. the row the assertion above bans, arriving by a second
# route. `using-skill-engine` names the substitution at its own paste; each
# surface that documents the flag must name it too.
for pair in "STATUS:$STATUS_N" "SELF-AUDIT:$SELF_AUDIT_N" "REFRESH:$DRIFT_N"; do
  label="${pair%%:*}"
  blob="${pair#*:}"
  ok=1
  # The substituted spelling itself, not a paraphrase: every one of these
  # files already carries "substitute it (or the empty string) for <name>"
  # in its single-contextualizer section, close enough to the flag to
  # satisfy a looser match without saying anything about the fleet paste.
  near_window "$blob" '--all' 700 700 'name=""' || ok=0
  report "$ok" "fleet table: $label's enumeration paste says the block's \`name\` line is substituted to \`name=\"\"\`"
done

# ════════════════════════════════════════════════════════════════════════
# fleet sweep — the whole workflow, once per enumerated contextualizer
# ════════════════════════════════════════════════════════════════════════

ok=1
near_window "$DRIFT_N" '--all' 500 500 'each|every|in turn|one at a time|sequence' || ok=0
report "$ok" "fleet sweep: REFRESH's fleet flag runs the workflow once per enumerated contextualizer"

ok=1
near_window "$DRIFT_N" '--all' 600 600 '\.proposed' || ok=0
report "$ok" "fleet sweep: each swept contextualizer stages under its own proposed sibling"

ok=1
near_window "$DRIFT_N" '--all' 600 600 'summary|one line per|summar' || ok=0
report "$ok" "fleet sweep: REFRESH prints one summary line per contextualizer at the end of a sweep"

ok=1
near_window "$SELF_AUDIT_N" '--all' 500 500 'each|every|in turn|one at a time|sequence' || ok=0
report "$ok" "fleet sweep: SELF-AUDIT's fleet flag runs its checks once per enumerated contextualizer"

ok=1
near_window "$SELF_AUDIT_N" '--all' 600 600 'summary|one line per|summar' || ok=0
report "$ok" "fleet sweep: SELF-AUDIT prints one summary line per contextualizer at the end of a sweep"

ok=1
printf '%s' "$SELF_AUDIT_N" | grep -qiE 'eight (drift )?checks' || ok=0
report "$ok" "fleet sweep: a swept SELF-AUDIT is still the eight drift checks, unchanged in number"

# ════════════════════════════════════════════════════════════════════════
# conflicting selectors rejected — the must-reject input
# ════════════════════════════════════════════════════════════════════════

# Asserted as prose, per the header: the only surface that already parses
# both selectors is the shared locator definition, which this change does
# not own. Each surface that documents the flag must say the run halts and
# must name both selectors where it says so.
for pair in "STATUS:$STATUS_N" "SELF-AUDIT:$SELF_AUDIT_N" "REFRESH:$DRIFT_N"; do
  label="${pair%%:*}"
  blob="${pair#*:}"
  # One window, not three: the halt verb, the reference to a named
  # contextualizer, and the combining must all land within the same span
  # around the flag. Split across separate windows the assertion goes
  # green on any document that mentions the flag at all, since `<name>`
  # and "error" are ambient in every one of these files.
  ok=1
  near_window "$blob" '--all' 250 250 \
    'halt|error|refus|reject|cannot|mutually exclusive' \
    'named|a name|<name>|positional' \
    'both|together|combined|with a' || ok=0
  report "$ok" "conflicting selectors rejected: $label says the enumeration flag together with a named contextualizer halts with an error naming both"
done

# The executed half, wherever one of those surfaces grows a guard fence:
# fed the rejectable input, the guard must exit non-zero and say both.
for pair in "STATUS:$STATUS_SKILL_MD" "SELF-AUDIT:$SELF_AUDIT_SKILL_MD" "REFRESH:$DRIFT_PHASES_MD"; do
  label="${pair%%:*}"
  file="${pair#*:}"
  guard="$(guard_fence "$file")"
  [ -n "$guard" ] || continue
  # A guard copied from the shared root-resolution definition carries that
  # definition's `name="<name>"` placeholder line, which would overwrite an
  # inherited value; substitute it the way a calling skill substitutes it.
  guard="$(printf '%s' "$guard" | sed 's|^name="<name>"$|name="acme"|')"
  guard_out="$(name=acme LC_ALL=C bash -c "$guard" -- --all 2>&1)"
  guard_rc=$?
  ok=1
  [ "$guard_rc" -ne 0 ] || ok=0
  printf '%s' "$guard_out" | grep -qF -- '--all' || ok=0
  printf '%s' "$guard_out" | grep -qF -- 'acme' || ok=0
  report "$ok" "conflicting selectors rejected: $label's guard, given both selectors, exits non-zero naming both"
done

# ════════════════════════════════════════════════════════════════════════
# owner seed — an optional root-level owner, seeded from CODEOWNERS
# ════════════════════════════════════════════════════════════════════════

if ! command -v jq >/dev/null 2>&1; then
  fixture_error "jq is not available; the registry schema cannot be read"
else
  ok=1
  jq -e '.properties.owner.type == "string"' "$SOURCE_PATHS_SCHEMA_JSON" >/dev/null 2>&1 || ok=0
  jq -e '(.properties.owner.minLength == 1) or (.properties.owner.minLength == 1.0)' \
    "$SOURCE_PATHS_SCHEMA_JSON" >/dev/null 2>&1 || ok=0
  report "$ok" "owner seed: the registry schema declares a root-level owner that is a non-empty string"

  # Preserved: the root stays open, so the field is purely additive and
  # a registry written before it still validates.
  ok=1
  jq -e '.additionalProperties == true' "$SOURCE_PATHS_SCHEMA_JSON" >/dev/null 2>&1 || ok=0
  report "$ok" "owner seed: the registry root still admits additional properties"
fi

ok=1
near_window "$CONTRACT_N" 'CODEOWNERS' 500 500 'owner' || ok=0
printf '%s' "$CONTRACT_N" | grep -qE 'root-level `owner`|`owner`' || ok=0
report "$ok" "owner seed: the contract chapter documents the root-level owner field and where it comes from"

ok=1
near_window "$INTAKE_N" 'CODEOWNERS' 500 500 'owner' || ok=0
near_window "$INTAKE_N" 'CODEOWNERS' 500 500 'root|\*' || ok=0
report "$ok" "owner seed: bootstrap intake documents reading the root rule of a project-root CODEOWNERS file"

CO_CODE="$(codeowners_fence "$INTAKE_MD")"

ok=1
[ -n "$CO_CODE" ] || ok=0
report "$ok" "owner seed: bootstrap intake carries an executable CODEOWNERS extraction"

# run_codeowners <codeowners-body> — the extraction run at a scratch
# project root. Either printing the token or writing it into the registry
# satisfies the caller; both are read back.
CO_STDOUT=""
CO_FIELD=""
run_codeowners() {
  local body="$1" d
  d="$(mktmp)"
  mkdir -p "$d/research"
  printf '%s' "$body" > "$d/CODEOWNERS"
  printf '{"schema_version":1,"sources":[]}\n' > "$d/research/source-paths.json"
  CO_STDOUT="$(cd "$d" && HOME="$d" LC_ALL=C CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash -c "$CO_CODE" 2>&1)"
  CO_FIELD="$(jq -r '.owner // empty' "$d/research/source-paths.json" 2>/dev/null)"
}

if [ -n "$CO_CODE" ] && command -v jq >/dev/null 2>&1; then
  # A root rule preceded by a comment and a non-root rule: the answer is
  # the first token on the `*` line, not the first owner token in the file.
  run_codeowners '# ownership
docs/ @org/docs-team
*   @org/team-a @person
src/ @org/src-team
'
  ok=0
  printf '%s' "$CO_STDOUT" | grep -qF -- '@org/team-a' && ok=1
  [ "$CO_FIELD" = '@org/team-a' ] && ok=1
  # ...and it is not the earlier, non-root rule's owner.
  [ "$CO_FIELD" = '@org/docs-team' ] && ok=0
  report "$ok" "owner seed: a CODEOWNERS root rule yields its first owner token"

  # No root rule at all: the field is left off rather than guessed from a
  # path-scoped rule.
  run_codeowners '# no root rule here
docs/ @org/docs-team
'
  ok=1
  [ -n "$CO_FIELD" ] && ok=0
  printf '%s' "$CO_STDOUT" | grep -qF -- '@org/docs-team' && ok=0
  report "$ok" "owner seed: a CODEOWNERS file with no root rule yields no owner"
fi

# ════════════════════════════════════════════════════════════════════════
# router purity — the enumeration flag stays out of the two routers
# ════════════════════════════════════════════════════════════════════════

ok=1
[ "$(grep -cF -- '--all' "$REFRESH_SKILL_MD")" -eq 0 ] || ok=0
report "$ok" "router purity: the REFRESH router never names the enumeration flag"

ok=1
[ "$(grep -cF -- '--all' "$DISCOVER_SKILL_MD")" -eq 0 ] || ok=0
report "$ok" "router purity: the DISCOVER router never names the enumeration flag"

ok=1
[ "$(grep -cF -- '--all' "$DRIFT_PHASES_MD")" -ge 1 ] || ok=0
report "$ok" "router purity: REFRESH's fleet flag is documented in its drift-and-phases reference instead"

# ════════════════════════════════════════════════════════════════════════
# capability ledger — what the fleet layer ships, and what still does not
# ════════════════════════════════════════════════════════════════════════

ok=1
near_window "$CAPABILITIES_N" '--all' 700 700 'status' || ok=0
near_window "$CAPABILITIES_N" '--all' 700 700 'refresh' || ok=0
near_window "$CAPABILITIES_N" '--all' 700 700 'self-audit' || ok=0
report "$ok" "capability ledger: the enumeration flag is stated for STATUS, REFRESH and SELF-AUDIT"

ok=1
near_window "$CAPABILITIES_N" '--all' 900 900 'table' || ok=0
report "$ok" "capability ledger: the fleet table is stated as shipping"

ok=1
printf '%s' "$CAPABILITIES_N" | grep -qE 'root-level `owner`|`owner` field|root `owner`' || ok=0
report "$ok" "capability ledger: the root-level owner field is stated as shipping"

# Preserved. `### What's deliberately not built` occurs four times; this
# is the one under `## How it stays accurate`, which is where the cadence
# claim lives.
CADENCE_N="$(h3_section "$CAPABILITIES_MD" 'How it stays accurate' "What's deliberately not built" | normalize_stdin)"
ok=1
[ -n "$CADENCE_N" ] || ok=0
printf '%s' "$CADENCE_N" | grep -qiE 'does not run REFRESH on cron' || ok=0
report "$ok" "capability ledger: the accuracy chapter still says the engine does not run REFRESH on cron"

# Preserved. The heading carries markdown emphasis — `What this is *not*` —
# and is matched with the asterisks in place. Its three claims are
# naming conventions, conflict auto-resolution, and federation; none of
# them is about a fleet layer, and none of them changes here.
NOT_N="$(h3_section "$CAPABILITIES_MD" 'How it synthesizes across sources' 'What this is *not*' | normalize_stdin)"
ok=1
[ -n "$NOT_N" ] || ok=0
printf '%s' "$NOT_N" | grep -qiE 'naming conventions across forks' || ok=0
printf '%s' "$NOT_N" | grep -qiE 'auto-resolve conflicts' || ok=0
printf '%s' "$NOT_N" | grep -qiE 'federation layer' || ok=0
report "$ok" "capability ledger: the what-this-is-not section keeps its three claims"

ok=1
printf '%s' "$NOT_N" | grep -qiE 'fleet' && ok=0
printf '%s' "$NOT_N" | grep -qF -- '--all' && ok=0
report "$ok" "capability ledger: the what-this-is-not section is not the site of a fleet claim"

# ════════════════════════════════════════════════════════════════════════
# nested project level — the project install level reaches nested roots
# ════════════════════════════════════════════════════════════════════════

# The five skills that run the shared locator, asserted one at a time by
# path. Two further skills link the same block without carrying this
# bullet, so this is not expressed as a property of everything that links
# it.
for pair in "DISCOVER:$DISCOVER_SKILL_MD" \
            "REFRESH:$REFRESH_SKILL_MD" \
            "STATUS:$STATUS_SKILL_MD" \
            "SELF-AUDIT:$SELF_AUDIT_SKILL_MD" \
            "NEW-REFERENCE:$NEW_REFERENCE_SKILL_MD"; do
  label="${pair%%:*}"
  file="${pair#*:}"

  ok=1
  grep -qF -- '<repo>/**/.claude/skills/<slug>-context/' "$file" || ok=0
  report "$ok" "nested project level: $label describes the project level as any .claude/skills/ below the repository root"

  ok=1
  grep -qF -- '<repo>/.claude/skills/<slug>-context/' "$file" && ok=0
  report "$ok" "nested project level: $label no longer states the single repository-root path the locator has outgrown"

  # Preserved: each still reaches the one shared root-resolution
  # definition rather than restating it.
  ok=1
  grep -qF -- 'shared/locator-block.md' "$file" || ok=0
  report "$ok" "nested project level: $label still links the one shared root-resolution definition"
done

# ════════════════════════════════════════════════════════════════════════
# preserved pins — ceilings and frozen copies a sibling oracle owns
# ════════════════════════════════════════════════════════════════════════

# The two byte ceilings are read out of the oracle that hard-codes them,
# not retyped here, so the two cannot drift apart.
refresh_pin="$(sed -n 's/^REFRESH_SKILL_MD_BASELINE_BYTES=\([0-9]*\)$/\1/p' "$ARCHIVE_RUN_SH" | head -n1)"
discover_pin="$(sed -n 's/^DISCOVER_SKILL_MD_BASELINE_BYTES=\([0-9]*\)$/\1/p' "$ARCHIVE_RUN_SH" | head -n1)"

if [ -z "$refresh_pin" ] || [ -z "$discover_pin" ]; then
  fixture_error "could not read the two router byte ceilings out of $ARCHIVE_RUN_SH"
else
  ok=1
  [ "$(wc -c < "$REFRESH_SKILL_MD" | tr -d ' ')" -le "$refresh_pin" ] || ok=0
  report "$ok" "preserved pins: the REFRESH router stays within the byte ceiling a sibling oracle hard-codes"

  ok=1
  [ "$(wc -c < "$DISCOVER_SKILL_MD" | tr -d ' ')" -le "$discover_pin" ] || ok=0
  report "$ok" "preserved pins: the DISCOVER router stays within the byte ceiling a sibling oracle hard-codes"
fi

ok=1
cmp -s "$DISCOVER_SKILL_MD" "$DISCOVER_BASELINE_MD" || ok=0
report "$ok" "preserved pins: the DISCOVER router is byte-identical to its frozen baseline copy"

ok=1
cmp -s "$REFRESH_SKILL_MD" "$REFRESH_BASELINE_MD" || ok=0
report "$ok" "preserved pins: the REFRESH router is byte-identical to its frozen baseline copy"

# STATUS's importance fence is tagged `python` on purpose: a sibling
# oracle sweeps every ```bash fence in this file outside the section whose
# heading mentions "probe" into one script and runs it, so a bash tag here
# is swept in and breaks that oracle.
priority_bash="$(awk '
  /^## / { inp = (tolower($0) ~ /priority/) ? 1 : 0; next }
  inp && /^```bash[[:space:]]*$/ { print "bash" }
  inp && /^```python[[:space:]]*$/ { print "python" }
' "$STATUS_SKILL_MD")"
ok=1
printf '%s\n' "$priority_bash" | grep -qx 'python' || ok=0
printf '%s\n' "$priority_bash" | grep -qx 'bash' && ok=0
report "$ok" "preserved pins: STATUS's priority fence stays tagged python, out of the sibling oracle's bash-fence sweep"

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
