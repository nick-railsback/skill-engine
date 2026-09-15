#!/usr/bin/env bash
# Feature-scoped test runner for installed-set mode across the eval harness:
#
#   engine-bootstrap-templates/eval/run-eval.sh.template
#   engine-bootstrap-templates/eval/render-eval-results.sh.template
#   .claude/skills/skill-engine-context/evals/run-eval.sh
#   .claude/skills/skill-engine-context/evals/render-eval-results.sh
#   docs/12-evaluation.md
#
# THE INVARIANTS, grouped by the behaviour that holds them.
#
#   installed-set intake: the harness accepts `--installed-set <roots>`,
#     where <roots> is a file of absolute contextualizer roots one per line
#     or `-` for the same lines on stdin. Both forms are exercised.
#
#   stdin single-read: the root list arriving on stdin is consumed once,
#     before the entry loop — the entry loop reads from a process
#     substitution and the CLI's stdin is redirected from /dev/null
#     precisely so nothing else can eat that stream. A second stdin reader
#     inside the loop makes the harness silently process one entry, so the
#     fixture below spans two roots owning two in-scope entries each and
#     every one of the four is asserted present.
#
#   corpus union: a root whose eval corpus is split contributes the union
#     of evals-train.json and evals-test.json; a root carrying only
#     evals.json contributes that.
#
#   in-scope filter: an entry survives only when its `expected` resolves to
#     a file at <root>/references/<expected>.md.
#
#   fired recording: a navigator has fired on a run when that run's
#     transcript carries a Read whose path matches
#     /<slug>-context/references/ followed by any .md. `slug` throughout is
#     the root's basename with the trailing `-context` removed.
#
#   confusion table: the renderer emits one row per query-owning
#     contextualizer and one column per installed contextualizer —
#     including one that owns no in-scope query and never fires, because
#     the columns come from the recorded installed set and not from
#     observed fires. Every cell, diagonal and off-diagonal alike, is a
#     majority vote over the entry's runs with `error` runs excluded, which
#     is the rule the existing pass count already uses, so the diagonal
#     reproduces that count exactly. Every non-zero off-diagonal cell is
#     flagged. The table is emitted on presence of the installed-set data
#     and never otherwise.
#
#   default path preserved: without `--installed-set` the harness still
#     runs three times per entry and writes none of the installed-set
#     fields, and the renderer emits no table for a results file that
#     carries none of that data.
#
#   dogfood copies re-stamped: the two shipped copies under
#     .claude/skills/skill-engine-context/evals/ are the templates with
#     <area-domain> substituted, and carry the same behaviour.
#
#   documented: docs/12-evaluation.md documents the flag, a worked
#     invocation fed by the locator's `--all` enumeration and the directory
#     to run it from, the cost shape, and the new results-file data as
#     additive optional fields that do not bump that file's schema_version
#     — without disturbing the manual-cadence sentence.
#
# THE RECORDED SHAPE this oracle pins, since nothing upstream pins it yet.
# In the results record written by installed-set mode:
#
#   header  "installed_set": ["alpha","beta","gamma"]   sorted, bare slugs
#   header  "navigator": "installed-set"                fixed sentinel; the
#           field names one navigator, which this mode does not have
#   entry   "owner": "alpha"                            the bare slug whose
#           corpus the entry came from
#   entry   "fired": [["alpha"],["alpha","beta"],[]]    one inner array of
#           sorted bare slugs per run, index-aligned with "runs"; the empty
#           array for a run that produced no transcript
#
# Both entry fields sit BEFORE `"runs": [` on the entry line, so that token
# stays the last one of its kind on the line and the renderer's greedy
# last-occurrence anchor still finds the real runs array.
#
# And in the rendered output:
#
#   Confusion table ...                     section header line
#     owner  alpha  beta  gamma             column header row, first token
#                                           the literal `owner`, then the
#                                           installed slugs in header order
#     alpha      2     1      0             one whitespace-separated row per
#     beta       0     1      0             owning slug: slug then integer
#                                           cells in column order
#     [CONFUSION] alpha -> beta: 1          one line per non-zero
#                                           off-diagonal cell
#
# Hermetic in both halves: no network, no model, no real `claude` binary.
# The runner half prepends a stub `claude` to PATH that emits a canned
# stream-json transcript keyed on the query it is handed; the renderer half
# reads hand-written results files whose outcomes are known by construction
# and counted by hand, never re-derived from what the renderer computes.
#
# -e is intentionally omitted: every assertion must run and report, not
# abort at the first red one.

set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

RUN_TEMPLATE="$PLUGIN_ROOT/engine-bootstrap-templates/eval/run-eval.sh.template"
RENDER_TEMPLATE="$PLUGIN_ROOT/engine-bootstrap-templates/eval/render-eval-results.sh.template"
DOGFOOD_EVALS="$REPO_ROOT/.claude/skills/skill-engine-context/evals"
DOGFOOD_RUN="$DOGFOOD_EVALS/run-eval.sh"
DOGFOOD_RENDER="$DOGFOOD_EVALS/render-eval-results.sh"
EVAL_DOC="$PLUGIN_ROOT/docs/12-evaluation.md"

pass_count=0
fail_count=0

section() {
  printf '\n── %s ──\n' "$1"
}

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

# Setup problems are not assertions: they report on stderr and exit 69, the
# same way the other prose-and-executed suites here do, so a missing
# dependency is never mistaken for a graded outcome.
setup_error() {
  echo "ERROR: $1" >&2
  exit 69
}

for f in "$RUN_TEMPLATE" "$RENDER_TEMPLATE" "$DOGFOOD_RUN" "$DOGFOOD_RENDER" "$EVAL_DOC"; do
  [ -f "$f" ] || setup_error "expected surface is missing entirely: $f"
done
for c in jq awk sed grep; do
  command -v "$c" >/dev/null 2>&1 || setup_error "'$c' is required to run this suite"
done

T="$(mktemp -d "${TMPDIR:-/tmp}/eval-cross-fleet.XXXXXX")"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

# The templates refuse to run until <area-domain> is substituted, so both are
# materialised once, exactly the way engine-bootstrap stamps them.
RUN_SUT="$T/run-eval.sh"
RENDER_SUT="$T/render-eval-results.sh"
sed 's/<area-domain>/fixture/g' "$RUN_TEMPLATE" > "$RUN_SUT"
sed 's/<area-domain>/fixture/g' "$RENDER_TEMPLATE" > "$RENDER_SUT"

# ---------------------------------------------------------------------------
# Text helpers for the prose assertions.
#
# Every match below is wrap-normalized: these are hand-wrapped markdown
# files, and a line-oriented grep reads a phrase that happens to cross a line
# break as absent. Emphasis markers are stripped too, so a phrase split by a
# bold or code span still matches. The underscore is deliberately NOT
# stripped: this chapter uses asterisks for emphasis, and stripping `_` would
# rewrite schema_version to schemaversion and make that needle unmatchable.
# ---------------------------------------------------------------------------

normalize() {
  tr '\n' ' ' | sed -e 's/[*`]//g' | tr -s ' '
}

# within <text> <anchor> <width> <needle> — true when <needle> appears within
# <width> characters after SOME occurrence of <anchor>. Every occurrence is
# tested, not only the first: an anchor that repeats would otherwise have its
# own later mention silently skipped. Deliberately a shell helper rather than
# a bounded regex repetition — BSD grep refuses an interval above 255 and
# reports the refusal as a non-match rather than an error.
within() {
  local text="$1" anchor="$2" width="$3" needle="$4"
  local rest="$text" prefix idx window
  while :; do
    prefix="${rest%%"$anchor"*}"
    [ "$prefix" = "$rest" ] && return 1
    idx=${#prefix}
    window="${rest:$idx:$((${#anchor} + width))}"
    case "$window" in
      *"$needle"*) return 0 ;;
    esac
    rest="${rest:$((idx + ${#anchor}))}"
  done
}

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------
# Fixture fleet: three contextualizer roots.
#
#   alpha  split corpus (train + test, no evals.json): two in-scope entries
#          and one whose expected names no file on disk.
#   beta   unsplit corpus (evals.json only): two in-scope entries.
#   gamma  owns no in-scope entry at all and never fires — the column the
#          table has to carry anyway.
# ---------------------------------------------------------------------------

FLEET="$T/fleet"
mkdir -p "$FLEET/alpha-context/references" "$FLEET/alpha-context/evals" \
         "$FLEET/beta-context/references" "$FLEET/beta-context/evals" \
         "$FLEET/gamma-context/references" "$FLEET/gamma-context/evals"

for r in alpha-one alpha-two; do
  printf '# %s\n\nfixture reference.\n' "$r" > "$FLEET/alpha-context/references/$r.md"
done
for r in beta-one beta-two; do
  printf '# %s\n\nfixture reference.\n' "$r" > "$FLEET/beta-context/references/$r.md"
done
printf '# gamma-one\n\nfixture reference.\n' > "$FLEET/gamma-context/references/gamma-one.md"

cat > "$FLEET/alpha-context/evals/evals-train.json" <<'JSON'
{
  "schema_version": 1,
  "entries": [
    {
      "query": "alpha train query",
      "expected": "alpha-one",
      "notes": "in scope: alpha-one.md exists.",
      "persona": "domain-expert"
    }
  ]
}
JSON

cat > "$FLEET/alpha-context/evals/evals-test.json" <<'JSON'
{
  "schema_version": 1,
  "entries": [
    {
      "query": "alpha test query",
      "expected": "alpha-two",
      "notes": "in scope: alpha-two.md exists.",
      "persona": "non-technical"
    },
    {
      "query": "alpha ghost query",
      "expected": "alpha-missing",
      "notes": "out of scope: alpha-missing.md is not on disk.",
      "persona": "domain-expert"
    }
  ]
}
JSON

cat > "$FLEET/beta-context/evals/evals.json" <<'JSON'
{
  "schema_version": 1,
  "entries": [
    {
      "query": "beta first query",
      "expected": "beta-one",
      "notes": "in scope.",
      "persona": "domain-expert"
    },
    {
      "query": "beta second query",
      "expected": "beta-two",
      "notes": "in scope; the stub errors on one of its three runs.",
      "persona": "domain-naive-technical"
    }
  ]
}
JSON

cat > "$FLEET/gamma-context/evals/evals.json" <<'JSON'
{
  "schema_version": 1,
  "entries": [
    {
      "query": "gamma ghost query",
      "expected": "gamma-missing",
      "notes": "out of scope: gamma owns nothing the filter keeps.",
      "persona": "domain-expert"
    }
  ]
}
JSON

# ---------------------------------------------------------------------------
# Fixture fleet 2: two roots that own a reference of the SAME NAME.
#
# `references/shared.md` exists under both. The query belongs to one-context
# and expects `shared`; the stub answers it by reading TWO-context's
# `shared.md` — the sibling won, and the owner read nothing of its own. A
# pass predicate that matches `references/shared.md` anywhere on the path
# scores that as a pass for one-context.
#
# Collisions are not exotic in a fleet: `overview`, `getting-started`,
# `configuration` and `testing` are what reference files get called, and
# installed-set mode is the one mode where several roots' corpora are in
# play at once.
# ---------------------------------------------------------------------------

COLLIDE="$T/collide"
mkdir -p "$COLLIDE/one-context/references" "$COLLIDE/one-context/evals" \
         "$COLLIDE/two-context/references" "$COLLIDE/two-context/evals"
for r in "$COLLIDE/one-context" "$COLLIDE/two-context"; do
  printf '# shared\n\nfixture reference.\n' > "$r/references/shared.md"
done

cat > "$COLLIDE/one-context/evals/evals.json" <<'JSON'
{
  "schema_version": 1,
  "entries": [
    {
      "query": "collide query",
      "expected": "shared",
      "notes": "in scope; the stub answers it from the sibling root.",
      "persona": "domain-expert"
    }
  ]
}
JSON

cat > "$COLLIDE/two-context/evals/evals.json" <<'JSON'
{
  "schema_version": 1,
  "entries": [
    {
      "query": "two ghost query",
      "expected": "two-missing",
      "notes": "out of scope: two owns nothing the filter keeps.",
      "persona": "domain-expert"
    }
  ]
}
JSON

# ---------------------------------------------------------------------------
# The stub `claude`. No extension, so the shellcheck inventory leaves it
# alone; it is a plain executable on PATH exactly like the real CLI.
#
# It varies its canned transcript by the value passed to -p, so a confusion
# case — one root's navigator reading another root's reference on another
# root's query — is produced end to end and not only in a hand-written
# results file. A per-query counter makes one run of one entry an infra
# error, which is the outcome the vote has to exclude.
# ---------------------------------------------------------------------------

mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -u
query=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) query="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
key=$(printf '%s' "$query" | tr -c 'a-zA-Z0-9' '_')
n=0
if [ -f "$STUB_STATE/$key" ]; then n=$(cat "$STUB_STATE/$key"); fi
n=$((n + 1))
printf '%s' "$n" > "$STUB_STATE/$key"
emit_read() {
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"%s"}}]}}\n' "$1"
}
case "$query" in
  "alpha train query")
    emit_read "$STUB_FLEET/alpha-context/references/alpha-one.md"
    ;;
  "alpha test query")
    emit_read "$STUB_FLEET/alpha-context/references/alpha-two.md"
    emit_read "$STUB_FLEET/beta-context/references/beta-one.md"
    ;;
  "beta first query")
    emit_read "$STUB_FLEET/beta-context/references/beta-one.md"
    ;;
  "collide query")
    emit_read "$STUB_COLLIDE/two-context/references/shared.md"
    ;;
  "beta second query")
    if [ "$n" -eq 2 ]; then
      echo "stub: simulated CLI failure" >&2
      exit 3
    fi
    emit_read "$STUB_FLEET/beta-context/references/beta-two.md"
    ;;
  *)
    ;;
esac
exit 0
STUB
chmod +x "$T/bin/claude"

export STUB_FLEET="$FLEET"
export STUB_COLLIDE="$COLLIDE"

# run_harness <workdir> <state-tag> [args...] — invoke the substituted
# harness with the stub CLI on PATH, capturing stdout and stderr to files.
# The SUT's own ERROR: lines stay in those files; this suite prints its own
# verdicts rather than re-emitting them.
HARNESS_RC=0
HARNESS_OUT=""
HARNESS_ERR=""
HARNESS_RESULTS=""
run_harness() {
  local workdir="$1" tag="$2"
  shift 2
  mkdir -p "$workdir" "$T/state-$tag"
  HARNESS_OUT="$T/harness-$tag.out"
  HARNESS_ERR="$T/harness-$tag.err"
  HARNESS_RC=0
  (
    cd "$workdir" || exit 70
    PATH="$T/bin:$PATH" STUB_STATE="$T/state-$tag" \
      bash "$RUN_SUT" "$@" >"$HARNESS_OUT" 2>"$HARNESS_ERR"
  ) || HARNESS_RC=$?
  # The harness announces the file it wrote on stderr; reading that line
  # avoids pinning an argv position for the results path.
  HARNESS_RESULTS="$(sed -n 's/^wrote: //p' "$HARNESS_ERR" | tail -n 1)"
  if [ -n "$HARNESS_RESULTS" ]; then
    case "$HARNESS_RESULTS" in
      /*) ;;
      *) HARNESS_RESULTS="$workdir/$HARNESS_RESULTS" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# Runner: roots on stdin.
# ---------------------------------------------------------------------------

section "installed-set intake: the root list arrives on stdin"

STDIN_WORK="$T/work-stdin"
mkdir -p "$STDIN_WORK"
# Deliberately unsorted, so the recorded set's sortedness is a real assertion
# rather than an echo of the input order.
ROOTS_FILE="$T/roots.txt"
cat > "$ROOTS_FILE" <<EOF
$FLEET/gamma-context
$FLEET/beta-context
$FLEET/alpha-context
EOF

mkdir -p "$STDIN_WORK" "$T/state-stdin"
STDIN_RC=0
(
  cd "$STDIN_WORK" || exit 70
  PATH="$T/bin:$PATH" STUB_STATE="$T/state-stdin" \
    bash "$RUN_SUT" --installed-set - <"$ROOTS_FILE" \
    >"$T/harness-stdin.out" 2>"$T/harness-stdin.err"
) || STDIN_RC=$?
STDIN_RESULTS="$(sed -n 's/^wrote: //p' "$T/harness-stdin.err" | tail -n 1)"
case "$STDIN_RESULTS" in
  "") ;;
  /*) ;;
  *) STDIN_RESULTS="$STDIN_WORK/$STDIN_RESULTS" ;;
esac

INSTALLED_SET_OK=0
if [ "$STDIN_RC" -eq 0 ] && [ -n "$STDIN_RESULTS" ] && [ -f "$STDIN_RESULTS" ] \
   && jq -e . "$STDIN_RESULTS" >/dev/null 2>&1; then
  INSTALLED_SET_OK=1
  pass "a root list on stdin is accepted and a parseable results record is written"
else
  fail "a root list on stdin is accepted and a parseable results record is written" \
    "exit=$STDIN_RC results='${STDIN_RESULTS:-<none>}'; harness stderr in $T/harness-stdin.err"
fi

# assert_installed_set <label> <jq-filter> <expected> — graded only when the
# stdin run produced a record. Without the mode there is nothing to read, and
# an absence check over a missing file would otherwise read as satisfied.
assert_jq() {
  local label="$1" filter="$2" want="$3"
  local got
  if [ "$INSTALLED_SET_OK" -ne 1 ]; then
    fail "$label" "installed-set mode produced no results record to inspect"
    return
  fi
  got="$(jq -c "$filter" "$STDIN_RESULTS" 2>&1)"
  if [ "$got" = "$want" ]; then
    pass "$label"
  else
    fail "$label" "want $want, got $got"
  fi
}

assert_jq "the recorded installed set is every supplied root's slug, sorted, regardless of input order" \
  '.installed_set' '["alpha","beta","gamma"]'

assert_jq "the navigator field carries the installed-set sentinel rather than one navigator's name" \
  '.navigator' '"installed-set"'

assert_jq "the record still declares schema_version 1: the new data is additive" \
  '.schema_version' '1'

section "stdin single-read: every entry of every root is processed"

assert_jq "all four in-scope queries across two roots are present, in no fewer than one root's worth" \
  '[.entries[].query] | sort' \
  '["alpha test query","alpha train query","beta first query","beta second query"]'

assert_jq "each root's entries are attributed to that root's slug" \
  '[.entries[] | {q: .query, o: .owner}] | sort_by(.q) | map(.o)' \
  '["alpha","alpha","beta","beta"]'

section "corpus union and the in-scope filter"

assert_jq "a split corpus contributes the union of its train and test files" \
  '[.entries[] | select(.owner == "alpha") | .query] | sort' \
  '["alpha test query","alpha train query"]'

assert_jq "a root carrying only evals.json contributes that file's entries" \
  '[.entries[] | select(.owner == "beta") | .query] | sort' \
  '["beta first query","beta second query"]'

assert_jq "an entry whose expected names no references/<expected>.md is dropped" \
  '[.entries[] | select(.query | test("ghost"))] | length' '0'

assert_jq "a root that owns no in-scope entry contributes no entries at all" \
  '[.entries[] | select(.owner == "gamma")] | length' '0'

section "fired recording: which navigators read a reference on each run"

assert_jq "every entry runs the usual three times and records one fired set per run" \
  '[.entries[] | (.runs | length), (.fired | length)] | unique' '[3]'

assert_jq "a query its own navigator answers records that navigator on every run" \
  '.entries[] | select(.query == "alpha train query") | .fired' \
  '[["alpha"],["alpha"],["alpha"]]'

assert_jq "a sibling navigator reading its own reference on another root's query is recorded on that run" \
  '.entries[] | select(.query == "alpha test query") | [.fired[] | index("beta") != null] | unique' \
  '[true]'

assert_jq "a run whose CLI invocation failed records the error outcome and an empty fired set at that index" \
  '.entries[] | select(.query == "beta second query") | [(.runs[1]), (.fired[1])]' \
  '["error",[]]'

assert_jq "a navigator that never reads a reference is never recorded as fired" \
  '[.entries[].fired[][]] | unique | index("gamma")' 'null'

section "entry-line shape: the runs anchor stays the last of its kind"

if [ "$INSTALLED_SET_OK" -ne 1 ]; then
  fail "the owning slug and the per-run fired data sit before the entry line's runs array" \
    "installed-set mode produced no results record to inspect"
else
  order_why="$(awk '
    function last_idx(s, t,   i, p, last) {
      last = 0; i = 1
      while ((p = index(substr(s, i), t)) > 0) { last = i + p - 1; i = last + 1 }
      return last
    }
    /"runs"[[:space:]]*:[[:space:]]*\[/ {
      r = last_idx($0, "\"runs\"")
      o = index($0, "\"owner\"")
      f = index($0, "\"fired\"")
      if (o == 0) { printf "line %d carries no owner field; ", NR; next }
      if (f == 0) { printf "line %d carries no fired field; ", NR; next }
      if (o > r) printf "line %d puts owner after the runs anchor; ", NR
      if (f > r) printf "line %d puts fired after the runs anchor; ", NR
      seen++
    }
    END { if (seen + 0 == 0) printf "no entry line carried a runs array; " }
  ' "$STDIN_RESULTS")"
  if [ -z "$order_why" ]; then
    pass "the owning slug and the per-run fired data sit before the entry line's runs array"
  else
    fail "the owning slug and the per-run fired data sit before the entry line's runs array" "$order_why"
  fi
fi

# ---------------------------------------------------------------------------
# Runner: the same list from a file.
# ---------------------------------------------------------------------------

section "installed-set intake: the same root list from a file"

run_harness "$T/work-file" file --installed-set "$ROOTS_FILE"
if [ "$HARNESS_RC" -eq 0 ] && [ -n "$HARNESS_RESULTS" ] && [ -f "$HARNESS_RESULTS" ]; then
  file_queries="$(jq -c '[.entries[].query] | sort' "$HARNESS_RESULTS" 2>&1)"
  file_set="$(jq -c '.installed_set' "$HARNESS_RESULTS" 2>&1)"
  if [ "$file_queries" = '["alpha test query","alpha train query","beta first query","beta second query"]' ] \
     && [ "$file_set" = '["alpha","beta","gamma"]' ]; then
    pass "a file of roots produces the same installed set and the same in-scope entries as stdin does"
  else
    fail "a file of roots produces the same installed set and the same in-scope entries as stdin does" \
      "installed_set=$file_set queries=$file_queries"
  fi
else
  fail "a file of roots produces the same installed set and the same in-scope entries as stdin does" \
    "exit=$HARNESS_RC results='${HARNESS_RESULTS:-<none>}'; harness stderr in ${HARNESS_ERR:-<none>}"
fi

# ---------------------------------------------------------------------------
# Runner: the default path.
#
# Graded against the installed-set capability on purpose. "The default path
# writes none of the new fields" is trivially true of a harness that has no
# installed-set mode at all, so the pair is asserted together: the mode
# exists AND the default path is untouched by it.
# ---------------------------------------------------------------------------

section "default path preserved: no flag, no installed-set data"

run_harness "$T/work-default" default "$FLEET/beta-context/evals/evals.json"
default_why=""
if [ "$INSTALLED_SET_OK" -ne 1 ]; then
  default_why="installed-set mode is absent, so the pairing cannot be graded;"
fi
if [ "$HARNESS_RC" -ne 0 ]; then
  default_why="$default_why default invocation exited $HARNESS_RC;"
elif [ -z "$HARNESS_RESULTS" ] || [ ! -f "$HARNESS_RESULTS" ]; then
  default_why="$default_why default invocation wrote no results file;"
else
  default_keys="$(jq -c '[paths | .[-1]] | map(select(type == "string")) | unique' "$HARNESS_RESULTS" 2>&1)"
  for k in installed_set owner fired; do
    case "$default_keys" in
      *"\"$k\""*) default_why="$default_why default results record carries $k;" ;;
    esac
  done
  default_runs="$(jq -c '[.entries[].runs | length] | unique' "$HARNESS_RESULTS" 2>&1)"
  [ "$default_runs" = '[3]' ] || default_why="$default_why default run count per entry is $default_runs, want [3];"
  default_nav="$(jq -c '.navigator' "$HARNESS_RESULTS" 2>&1)"
  [ "$default_nav" = '"fixture-context"' ] || default_why="$default_why default navigator field is $default_nav;"
fi
if [ -z "$default_why" ]; then
  pass "the default invocation still names its one navigator, still runs three times per entry, and writes none of the installed-set fields"
else
  fail "the default invocation still names its one navigator, still runs three times per entry, and writes none of the installed-set fields" \
    "$default_why"
fi

# ---------------------------------------------------------------------------
# Renderer half. Hand-written results files; every expected count below is
# counted by hand from the fixture.
# ---------------------------------------------------------------------------

CONFUSED="$T/results-confused.json"
cat > "$CONFUSED" <<'JSON'
{
  "navigator": "installed-set",
  "schema_version": 1,
  "installed_set": ["alpha", "beta", "gamma"],
  "started_at": "2026-01-01T00:00:00Z",
  "runs_per_query": 3,
  "entries": [
    {"query": "alpha q1", "expected": "alpha-one", "persona": "domain-expert", "owner": "alpha", "fired": [["alpha"], ["alpha"], ["alpha"]], "runs": ["pass", "pass", "pass"]},
    {"query": "alpha q2", "expected": "alpha-two", "persona": "domain-expert", "owner": "alpha", "fired": [["alpha", "beta"], ["alpha", "beta"], ["alpha"]], "runs": ["pass", "pass", "pass"]},
    {"query": "beta q1", "expected": "beta-one", "persona": "non-technical", "owner": "beta", "fired": [["beta"], ["beta"], ["beta"]], "runs": ["pass", "pass", "pass"]}
  ],
  "ended_at": "2026-01-01T00:05:00Z"
}
JSON

CLEAN="$T/results-clean.json"
cat > "$CLEAN" <<'JSON'
{
  "navigator": "installed-set",
  "schema_version": 1,
  "installed_set": ["alpha", "beta", "gamma"],
  "started_at": "2026-01-01T00:00:00Z",
  "runs_per_query": 3,
  "entries": [
    {"query": "alpha q1", "expected": "alpha-one", "persona": "domain-expert", "owner": "alpha", "fired": [["alpha"], ["alpha"], ["alpha"]], "runs": ["pass", "pass", "pass"]},
    {"query": "alpha q2", "expected": "alpha-two", "persona": "domain-expert", "owner": "alpha", "fired": [["alpha"], ["alpha"], ["alpha"]], "runs": ["pass", "pass", "pass"]},
    {"query": "beta q1", "expected": "beta-one", "persona": "non-technical", "owner": "beta", "fired": [["beta"], ["beta"], ["beta"]], "runs": ["pass", "pass", "pass"]}
  ],
  "ended_at": "2026-01-01T00:05:00Z"
}
JSON

# The arithmetic discriminator. Every entry is owned by alpha:
#
#   a1  runs pass,pass,fail   fired alpha,alpha,beta
#       diagonal counted (2 of 3); alpha->beta fired on 1 of 3 — a minority,
#       so the off-diagonal cell stays 0 under a majority vote and would be 1
#       under any-fired.
#   a2  runs pass,fail,fail   fired alpha,beta,beta
#       diagonal NOT counted (1 of 3); alpha->beta a majority, cell 1.
#   a3  runs pass,error,error fired alpha+gamma,-,-
#       error runs excluded, so the single surviving run is the whole vote:
#       diagonal counted, and alpha->gamma flagged at 1.
#
# By hand: row alpha = 2 (alpha), 1 (beta), 1 (gamma); two flagged cells; and
# the renderer's own pass-rate numerator for these three entries is 2, which
# is what the diagonal has to reproduce.
ARITH="$T/results-arithmetic.json"
cat > "$ARITH" <<'JSON'
{
  "navigator": "installed-set",
  "schema_version": 1,
  "installed_set": ["alpha", "beta", "gamma"],
  "started_at": "2026-01-01T00:00:00Z",
  "runs_per_query": 3,
  "entries": [
    {"query": "a1", "expected": "alpha-one", "persona": "domain-expert", "owner": "alpha", "fired": [["alpha"], ["alpha"], ["beta"]], "runs": ["pass", "pass", "fail"]},
    {"query": "a2", "expected": "alpha-two", "persona": "domain-expert", "owner": "alpha", "fired": [["alpha"], ["beta"], ["beta"]], "runs": ["pass", "fail", "fail"]},
    {"query": "a3", "expected": "alpha-one", "persona": "domain-expert", "owner": "alpha", "fired": [["alpha", "gamma"], [], []], "runs": ["pass", "error", "error"]}
  ],
  "ended_at": "2026-01-01T00:05:00Z"
}
JSON

# The "right skill, wrong reference" discriminator — the case the ARITH
# fixture cannot express, because its `fired` and `runs` fields are
# hand-aligned and the harness only produces that pairing by coincidence.
# Both entries are owned by alpha and alpha's navigator fires on every run
# of both; the difference is which reference it then reads.
#
#   w1  runs fail,fail,fail   fired alpha,alpha,alpha
#       Alpha activated every time and read the wrong file every time —
#       the ordinary failure a per-navigator eval exists to catch. Its
#       diagonal contribution is 0, because the entry did not pass.
#   w2  runs pass,pass,pass   fired alpha,alpha,alpha
#       The contrast: same firing, right reference, contributes 1.
#
# Row alpha is therefore 1 0 0 against a pass count of 1. Voting the
# diagonal on "fired" instead reads 2 0 0 against the same pass count of 1,
# i.e. a contextualizer that always activates and always picks the wrong
# file renders as a perfect diagonal beside a 0% pass rate.
WRONGREF="$T/results-wrong-reference.json"
cat > "$WRONGREF" <<'JSON'
{
  "navigator": "installed-set",
  "schema_version": 1,
  "installed_set": ["alpha", "beta", "gamma"],
  "started_at": "2026-01-01T00:00:00Z",
  "runs_per_query": 3,
  "entries": [
    {"query": "w1", "expected": "alpha-one", "persona": "domain-expert", "owner": "alpha", "fired": [["alpha"], ["alpha"], ["alpha"]], "runs": ["fail", "fail", "fail"]},
    {"query": "w2", "expected": "alpha-two", "persona": "domain-expert", "owner": "alpha", "fired": [["alpha"], ["alpha"], ["alpha"]], "runs": ["pass", "pass", "pass"]}
  ],
  "ended_at": "2026-01-01T00:05:00Z"
}
JSON

PLAIN="$T/results-plain.json"
cat > "$PLAIN" <<'JSON'
{
  "navigator": "fixture-context",
  "schema_version": 1,
  "started_at": "2026-01-01T00:00:00Z",
  "runs_per_query": 3,
  "entries": [
    {"query": "plain q1", "expected": "alpha-one", "persona": "domain-expert", "runs": ["pass", "pass", "pass"]},
    {"query": "plain q2", "expected": "alpha-two", "persona": "non-technical", "runs": ["pass", "fail", "fail"]}
  ],
  "ended_at": "2026-01-01T00:05:00Z"
}
JSON

render_one() {
  bash "$1" "$2" 2>/dev/null || printf ''
}

# each_renderer <label> <results> <predicate> — the predicate is run against
# both the substituted template and the shipped copy, recorded as one
# assertion, so a fix landing in only one of them cannot go green.
each_renderer() {
  local label="$1" results="$2" predicate="$3"
  local r out why=""
  for r in "$RENDER_SUT" "$DOGFOOD_RENDER"; do
    if [ ! -f "$r" ]; then
      why="$why [${r##*/}: renderer not present]"
      continue
    fi
    out="$(render_one "$r" "$results")"
    if ! "$predicate" "$out"; then
      why="$why [${r##*/}: $(printf '%s' "$out" | tr '\n' '~')]"
    fi
  done
  if [ -z "$why" ]; then
    pass "$label"
  else
    fail "$label" "$why"
  fi
}

# table_row <output> <slug> — the whitespace-separated cells of that slug's
# row in the confusion table, or empty when the slug has no row.
table_row() {
  printf '%s\n' "$1" | awk -v want="$2" '
    /^[[:space:]]*Confusion table/ { intable = 1; next }
    intable && NF == 0 { intable = 0 }
    intable && $1 == want { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }
  '
}

table_header() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*Confusion table/ { intable = 1; next }
    intable && NF == 0 { intable = 0 }
    intable && $1 == "owner" { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }
  '
}

flag_count() {
  printf '%s\n' "$1" | grep -c '\[CONFUSION\]'
}

section "confusion table: a sibling firing on another root's query is flagged"

RENDERER_OK=0
confused_out="$(render_one "$RENDER_SUT" "$CONFUSED")"
dogfood_confused_out="$(render_one "$DOGFOOD_RENDER" "$CONFUSED")"
if contains "$confused_out" "Confusion table" && contains "$dogfood_confused_out" "Confusion table"; then
  RENDERER_OK=1
fi

has_table() { contains "$1" "Confusion table"; }
each_renderer "a results record carrying installed-set data renders a confusion table" \
  "$CONFUSED" has_table

header_has_every_installed_slug() {
  [ "$(table_header "$1")" = "alpha beta gamma" ]
}
each_renderer "the columns are the recorded installed set — including a contextualizer that owns nothing and never fires" \
  "$CONFUSED" header_has_every_installed_slug

confused_rows() {
  [ "$(table_row "$1" alpha)" = "2 1 0" ] && [ "$(table_row "$1" beta)" = "0 1 0" ]
}
each_renderer "each cell counts the queries whose column navigator won the majority vote" \
  "$CONFUSED" confused_rows

dormant_has_no_row() {
  contains "$1" "Confusion table" && [ -z "$(table_row "$1" gamma)" ]
}
each_renderer "a contextualizer owning no query has a column but no row" \
  "$CONFUSED" dormant_has_no_row

exactly_one_flag() {
  [ "$(flag_count "$1")" = "1" ] && contains "$1" "[CONFUSION] alpha -> beta: 1"
}
each_renderer "exactly one off-diagonal cell is flagged, naming the owner, the intruder, and the count" \
  "$CONFUSED" exactly_one_flag

section "confusion table: no confusion, nothing flagged"

no_flags_but_a_table() {
  contains "$1" "Confusion table" && [ "$(flag_count "$1")" = "0" ]
}
each_renderer "a results record with no cross-firing renders the table and flags nothing" \
  "$CLEAN" no_flags_but_a_table

clean_rows_are_diagonal() {
  [ "$(table_row "$1" alpha)" = "2 0 0" ] && [ "$(table_row "$1" beta)" = "0 1 0" ]
}
each_renderer "with no cross-firing every off-diagonal cell is zero" \
  "$CLEAN" clean_rows_are_diagonal

section "confusion table: majority vote with error runs excluded, on both diagonals"

arith_row() {
  [ "$(table_row "$1" alpha)" = "2 1 1" ]
}
each_renderer "a minority fire does not raise a cell, a majority fire does, and a single surviving run decides an entry whose other runs errored" \
  "$ARITH" arith_row

arith_flags() {
  [ "$(flag_count "$1")" = "2" ] \
    && contains "$1" "[CONFUSION] alpha -> beta: 1" \
    && contains "$1" "[CONFUSION] alpha -> gamma: 1"
}
each_renderer "both non-zero off-diagonal cells are flagged and the zero one is not" \
  "$ARITH" arith_flags

arith_diagonal_matches_pass_count() {
  local numerator
  numerator="$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*overall:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\/.*$/\1/p' | head -n 1)"
  [ -n "$numerator" ] && [ "$(table_row "$1" alpha | awk '{print $1}')" = "$numerator" ]
}
each_renderer "the diagonal cell reproduces the entry's existing pass count exactly" \
  "$ARITH" arith_diagonal_matches_pass_count

section "confusion table: the diagonal votes on the pass predicate, not on whether the owner fired"

wrongref_row() {
  [ "$(table_row "$1" alpha)" = "1 0 0" ]
}
each_renderer "a navigator that fires on every run but reads the wrong reference does not fill its own diagonal" \
  "$WRONGREF" wrongref_row

wrongref_diagonal_matches_pass_count() {
  local numerator
  numerator="$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*overall:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\/.*$/\1/p' | head -n 1)"
  [ -n "$numerator" ] && [ "$(table_row "$1" alpha | awk '{print $1}')" = "$numerator" ]
}
each_renderer "the diagonal still reproduces the pass count when \`fired\` and \`runs\` disagree" \
  "$WRONGREF" wrongref_diagonal_matches_pass_count

wrongref_no_flags() {
  [ "$(flag_count "$1")" = "0" ]
}
each_renderer "no sibling fired, so nothing off-diagonal is flagged" \
  "$WRONGREF" wrongref_no_flags

section "installed-set mode: the pass predicate is scoped to the owning root"

COLLIDE_ROOTS="$T/collide-roots.txt"
cat > "$COLLIDE_ROOTS" <<EOF
$COLLIDE/one-context
$COLLIDE/two-context
EOF
run_harness "$T/work-collide" collide --installed-set "$COLLIDE_ROOTS" ignored \
  "$T/work-collide/results-collide.json"

collide_why=""
if [ "$HARNESS_RC" -ne 0 ] || [ -z "$HARNESS_RESULTS" ] || [ ! -f "$HARNESS_RESULTS" ]; then
  collide_why="the harness did not write a results file (exit=$HARNESS_RC); stderr in $HARNESS_ERR;"
else
  collide_runs="$(jq -r '[.entries[] | select(.owner == "one") | .runs[]] | join(",")' \
    "$HARNESS_RESULTS" 2>/dev/null)"
  collide_fired="$(jq -r '[.entries[] | select(.owner == "one") | .fired[][]] | unique | join(",")' \
    "$HARNESS_RESULTS" 2>/dev/null)"
  case "$collide_runs" in
    *pass*) collide_why="$collide_why one-context scored a pass on a run that read the SIBLING root's identically-named reference (runs: $collide_runs);" ;;
    "") collide_why="$collide_why no entry owned by one-context was recorded;" ;;
  esac
  [ "$collide_fired" = "two" ] || collide_why="$collide_why the fired set for that entry is '$collide_fired', not the sibling that actually read;"
fi
if [ -z "$collide_why" ]; then
  pass "a sibling root's identically-named reference does not score a pass for the owner"
else
  fail "a sibling root's identically-named reference does not score a pass for the owner" "$collide_why"
fi

section "presence detection: no installed-set data, no table"

presence_why=""
if [ "$RENDERER_OK" -ne 1 ]; then
  presence_why="the renderer emits no table for installed-set data at all, so its absence elsewhere grades nothing;"
fi
for r in "$RENDER_SUT" "$DOGFOOD_RENDER"; do
  out="$(render_one "$r" "$PLAIN")"
  contains "$out" "Confusion table" && presence_why="$presence_why ${r##*/} renders a table for a record with no installed-set data;"
  contains "$out" "[CONFUSION]" && presence_why="$presence_why ${r##*/} flags a cell for a record with no installed-set data;"
  contains "$out" "overall: 1 / 2" || presence_why="$presence_why ${r##*/} no longer reports the plain record's pass rate;"
done
for f in "$DOGFOOD_EVALS"/results-*.json; do
  [ -f "$f" ] || continue
  out="$(render_one "$DOGFOOD_RENDER" "$f")"
  contains "$out" "Confusion table" && presence_why="$presence_why the shipped results artifact renders a table it has no data for;"
done
if [ -z "$presence_why" ]; then
  pass "a results record carrying no installed-set data renders exactly as before — no table, no flags, same pass rate"
else
  fail "a results record carrying no installed-set data renders exactly as before — no table, no flags, same pass rate" \
    "$presence_why"
fi

# ---------------------------------------------------------------------------
# The shipped copies.
# ---------------------------------------------------------------------------

section "dogfood copies are the templates, substituted, and carry the same behaviour"

stamp_why=""
if ! diff -q <(sed 's/<area-domain>/skill-engine/g' "$RUN_TEMPLATE") "$DOGFOOD_RUN" >/dev/null 2>&1; then
  stamp_why="$stamp_why run-eval.sh is not the template with <area-domain> substituted;"
fi
if [ "$INSTALLED_SET_OK" -ne 1 ]; then
  stamp_why="$stamp_why the harness template has no installed-set mode to re-stamp;"
fi
if [ -z "$stamp_why" ]; then
  pass "the shipped harness is the template with <area-domain> substituted, carrying installed-set mode with it"
else
  fail "the shipped harness is the template with <area-domain> substituted, carrying installed-set mode with it" "$stamp_why"
fi

render_stamp_why=""
if ! diff -q <(sed 's/<area-domain>/skill-engine/g' "$RENDER_TEMPLATE") "$DOGFOOD_RENDER" >/dev/null 2>&1; then
  render_stamp_why="$render_stamp_why render-eval-results.sh is not the template with <area-domain> substituted;"
fi
if [ "$RENDERER_OK" -ne 1 ]; then
  render_stamp_why="$render_stamp_why the renderer template emits no confusion table to re-stamp;"
fi
if [ -z "$render_stamp_why" ]; then
  pass "the shipped renderer is the template with <area-domain> substituted, carrying the confusion table with it"
else
  fail "the shipped renderer is the template with <area-domain> substituted, carrying the confusion table with it" "$render_stamp_why"
fi

# ---------------------------------------------------------------------------
# The documentation.
# ---------------------------------------------------------------------------

section "documented: the mode, its cost, its directory, and its results fields"

DOC_TEXT="$(normalize < "$EVAL_DOC")"

doc_flag_named=0
if contains "$DOC_TEXT" "--installed-set"; then
  doc_flag_named=1
  pass "the evaluation chapter names the --installed-set flag"
else
  fail "the evaluation chapter names the --installed-set flag"
fi

# Checked in both directions: a worked invocation naturally pipes the
# enumeration INTO the flag, so --all precedes it on the line.
if within "$DOC_TEXT" "--installed-set" 250 "--all" || within "$DOC_TEXT" "--all" 250 "--installed-set"; then
  pass "a worked invocation shows the locator's --all enumeration feeding the flag"
else
  fail "a worked invocation shows the locator's --all enumeration feeding the flag" \
    "no --all within 250 characters of any --installed-set mention"
fi

cwd_why=""
if ! within "$DOC_TEXT" "--installed-set" 250 "working directory" \
   && ! within "$DOC_TEXT" "--installed-set" 250 "directory to run" \
   && ! within "$DOC_TEXT" "working directory" 250 "--installed-set" \
   && ! within "$DOC_TEXT" "directory to run" 250 "--installed-set"; then
  cwd_why="the worked invocation does not say which directory to run it from;"
fi
if [ -z "$cwd_why" ]; then
  pass "the worked invocation says which directory to run it from"
else
  fail "the worked invocation says which directory to run it from" "$cwd_why"
fi

cost_why=""
if ! within "$DOC_TEXT" "--installed-set" 250 "three runs" \
   && ! within "$DOC_TEXT" "three runs" 250 "--installed-set"; then
  cost_why="$cost_why no three-runs-per-query cost statement near the flag;"
fi
if ! within "$DOC_TEXT" "--installed-set" 250 "fleet" \
   && ! within "$DOC_TEXT" "fleet" 250 "--installed-set" \
   && ! within "$DOC_TEXT" "--installed-set" 250 "installed set"; then
  cost_why="$cost_why the cost statement does not scale with the size of the fleet;"
fi
if [ -z "$cost_why" ]; then
  pass "the cost is documented as scaling with the fleet size times three runs per query"
else
  fail "the cost is documented as scaling with the fleet size times three runs per query" "$cost_why"
fi

predicate_why=""
if ! within "$DOC_TEXT" "diagonal" 400 "pass" && ! within "$DOC_TEXT" "pass" 400 "diagonal"; then
  predicate_why="$predicate_why the chapter does not say the diagonal votes on the pass predicate;"
fi
if ! within "$DOC_TEXT" "off-diagonal" 400 "fire" && ! within "$DOC_TEXT" "fire" 400 "off-diagonal"; then
  predicate_why="$predicate_why the chapter does not say off-diagonal cells vote on whether the column navigator fired;"
fi
if [ -z "$predicate_why" ]; then
  pass "the chapter states which predicate each half of the table votes on, rather than claiming one vote for both"
else
  fail "the chapter states which predicate each half of the table votes on, rather than claiming one vote for both" \
    "$predicate_why"
fi

fields_why=""
contains "$DOC_TEXT" "additive" || fields_why="$fields_why the new results-file data is not described as additive;"
contains "$DOC_TEXT" "optional" || fields_why="$fields_why the new results-file data is not described as optional;"
if ! within "$DOC_TEXT" "additive" 250 "schema_version"; then
  fields_why="$fields_why nothing near the additive-fields statement says the results file's schema_version does not bump;"
fi
if ! within "$DOC_TEXT" "additive" 250 "results-"; then
  fields_why="$fields_why the additive-fields statement does not name results-*.json as the file it is about;"
fi
if [ -z "$fields_why" ]; then
  pass "the new results-file data is documented as additive optional fields that do not bump that file's schema_version"
else
  fail "the new results-file data is documented as additive optional fields that do not bump that file's schema_version" "$fields_why"
fi

pieces_why=""
contains "$DOC_TEXT" "installed set" || pieces_why="$pieces_why the header's installed set is not documented;"
if ! contains "$DOC_TEXT" "owning slug" && ! contains "$DOC_TEXT" "owning contextualizer"; then
  pieces_why="$pieces_why the per-entry owning slug is not documented;"
fi
contains "$DOC_TEXT" "fired" || pieces_why="$pieces_why the per-run fired slugs are not documented;"
if [ -z "$pieces_why" ]; then
  pass "all three new pieces of recorded data are named: the header's installed set, the per-entry owning slug, and the per-run fired slugs"
else
  fail "all three new pieces of recorded data are named: the header's installed set, the per-entry owning slug, and the per-run fired slugs" \
    "$pieces_why"
fi

# The manual-cadence sentence is already true today, so it is graded against
# the new prose landing: on its own it would report green for a chapter that
# documents none of the above.
cadence_why=""
# No trailing period in the needle: the sentence continues past
# "auto-trigger" with an em dash in the chapter as written.
if ! contains "$DOC_TEXT" "The framework does not run on a schedule. There is no CI step, no daemon, no auto-trigger"; then
  cadence_why="$cadence_why the manual-cadence sentence no longer survives verbatim;"
fi
if [ "$doc_flag_named" -ne 1 ]; then
  cadence_why="$cadence_why the chapter documents no installed-set mode, so its survival grades nothing;"
fi
if [ -z "$cadence_why" ]; then
  pass "the chapter's manual-cadence sentence survives the new prose verbatim"
else
  fail "the chapter's manual-cadence sentence survives the new prose verbatim" "$cadence_why"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
exit 0
