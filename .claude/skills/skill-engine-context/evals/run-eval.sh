#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C
export LC_ALL

# run-eval.sh parameterized template for the skill-engine-context navigator.
#
# This is a TEMPLATE. Replace placeholders before use:
# skill-engine           - your domain stem (used in invocation prompt + output header)
#
# See 12-evaluation.md for the schema, methodology, and aggregation contract.
#
# Usage:
#   bash evals/run-eval.sh [<evals-path>] [<results-path>]
#
# Inputs:
#   $1 - (optional) path to evals.json (default: evals/evals.json).
#        Pass evals/evals-train.json or evals/evals-test.json when running
#        against the train or test split per the chapter's separate-file
#        train/test discipline.
#   $2 - (optional) path to results output (default: evals/results-<UTC-timestamp>-<pid>.json).
#
# Output:
#   evals/results-<timestamp>-<pid>.json with the per-run records, in the
#   shape documented in 12-evaluation.md. Each run records one of three
#   outcomes: "pass", "fail", or "error" (the CLI invocation itself failed —
#   an infra condition, not a navigator verdict). The PID suffix prevents
#   two runs invoked in the same UTC second from overwriting each other.
#
# Exit codes:
#   0  - all entries ran (pass/fail recorded per run; non-zero pass count is
#        not a script error).
#   64 - usage error or unsubstituted template placeholders.
#   65 - input file missing or unparseable.
#   69 - required external command not found (claude CLI, jq).
#   70 - runner failure: every invocation errored (expired auth, broken CLI).
#        The results file is still written, but its 0% pass rate measures the
#        runner, not the navigator — fix the runner before reading the report.
#
# Dependencies:
#   bash (POSIX-compatible subset; no [[ ]], no GNU-only flags)
#   claude (the Claude Code CLI, available on PATH; this is the agent platform
#           the engine targets, not a third-party dep on top of it)
#   jq (stream-json parsing for the pass condition; already required by the
#       sibling verify.sh, so it adds no new dependency to a contextualizer)
#   grep, sed, awk, date (POSIX)
#
# Determinism:
#   The harness records results in input-file order. Per-run outcome is
#   non-deterministic at the model layer (this is what variance handling
#   captures); the surrounding bookkeeping is deterministic.

# Belt-and-suspenders: refuse to run if placeholders have not been substituted.
# The placeholder is reassembled at runtime so a naive sed substitution like
#   sed 's/skill-engine/library/g'
# does not rewrite this check (the way it rewrites every other occurrence).
_ph_a='<area'
_ph_b='-domain>'
_PLACEHOLDER="${_ph_a}${_ph_b}"
if grep -qF "${_PLACEHOLDER}" "$0"; then
  echo "ERROR: template placeholder ${_PLACEHOLDER} not substituted; copy and replace before running." >&2
  exit 64
fi
unset _ph_a _ph_b _PLACEHOLDER

# --installed-set is a second ENTRY SOURCE, not a second harness: it changes
# where entries come from and what is recorded alongside them, and leaves
# every code path the default invocation reaches exactly as it was. Pull the
# flag out of the argument list first, so $1 and $2 keep the meaning they
# have without it.
#
# In installed-set mode $1 (the eval-set path) is ignored — the roots supply
# the corpora — and $2 is still the results path. Pass one: the default
# lands an evals/ directory under whatever directory the fleet invocation
# was run from.
INSTALLED_SET_MODE=0
INSTALLED_SET_ARG=""
_argc=$#
_seen=0
while [ "$_seen" -lt "$_argc" ]; do
  _arg="$1"
  shift
  _seen=$((_seen + 1))
  case "$_arg" in
    --installed-set)
      if [ "$_seen" -ge "$_argc" ]; then
        echo "ERROR: --installed-set requires a roots file, or - to read the list from stdin." >&2
        exit 64
      fi
      INSTALLED_SET_MODE=1
      INSTALLED_SET_ARG="$1"
      shift
      _seen=$((_seen + 1))
      ;;
    # Every other argument rotates to the end of the list. After $_argc
    # iterations the non-flag arguments are back in their original order and
    # the flag is gone — rotation rather than an array because this template
    # stays inside the POSIX-flavoured bash subset the rest of the file uses.
    *) set -- "$@" "$_arg" ;;
  esac
done
unset _argc _seen _arg

EVALS_PATH="${1:-evals/evals.json}"
RESULTS_PATH="${2:-evals/results-$(date -u +%Y%m%dT%H%M%SZ)-$$.json}"
RUNS_PER_QUERY=3

# The header's "navigator" field names one navigator, which installed-set
# mode does not have. The sentinel keeps it a non-empty string, which every
# consumer of a results file (including the engine's own corpus validator)
# requires.
NAVIGATOR="skill-engine-context"
if [ "$INSTALLED_SET_MODE" -eq 1 ]; then
  NAVIGATOR="installed-set"
fi

# Skipped in installed-set mode: the roots carry the corpora, and the
# default evals/evals.json does not exist in a fleet invocation.
if [ "$INSTALLED_SET_MODE" -eq 0 ] && [ ! -f "$EVALS_PATH" ]; then
  echo "ERROR: evals file not found at $EVALS_PATH" >&2
  exit 65
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: 'claude' CLI not found on PATH (required for navigator invocation)." >&2
  exit 69
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: 'jq' not found on PATH (required to scope pass detection to Read tool calls)." >&2
  exit 69
fi

# Strict integer schema_version check.
# Extracts the top-level "schema_version" field; rejects strings, floats,
# null, and boolean. Absent field defaults to v1.
#
# A function because installed-set mode reads up to two corpus files per
# root: one silently unchecked corpus is exactly the hole this check exists
# to close. The offending file is named, since the caller may have handed it
# several.
check_schema_version() {
  local file="$1"
  local schema_version_raw schema_version
  schema_version_raw=$(grep -E '^[[:space:]]*"schema_version"[[:space:]]*:' "$file" \
    | head -n 1 \
    | sed -E 's/^[[:space:]]*"schema_version"[[:space:]]*:[[:space:]]*//; s/[[:space:]]*,?[[:space:]]*$//' \
    || true)

  if [ -z "${schema_version_raw:-}" ]; then
    schema_version=1
  elif printf '%s' "$schema_version_raw" | grep -qE '^[1-9][0-9]*$'; then
    schema_version=$schema_version_raw
  else
    echo "ERROR: schema_version must be a JSON integer >= 1; got: $schema_version_raw ($file)" >&2
    exit 65
  fi

  if [ "$schema_version" != "1" ]; then
    echo "ERROR: this harness understands schema_version 1; got: $schema_version ($file)" >&2
    exit 65
  fi
}

if [ "$INSTALLED_SET_MODE" -eq 0 ]; then
  check_schema_version "$EVALS_PATH"
fi

# Field separator for the entries record stream: ASCII Unit Separator (US,
# 0x1F). Picked because it is illegal in JSON strings, so it cannot appear
# inside a value parsed out of evals.json. Tab was unsafe (a literal tab in
# a query/expected/persona value would corrupt the IFS-split read).
US=$(printf '\037')

# Single-run invocation: send <query> to the agent and decide the outcome by
# whether references/<expected>.md was Read during the response.
#
# Pass condition: a Read tool_use whose input.file_path ends at
# references/<expected>.md appears in the stream-json output. The match is
# scoped to Read tool calls only — an unscoped grep over the whole transcript
# false-passes whenever the navigator catalog (which must name every
# reference, per the bijection check) flows through it, grading "skill
# triggered" as "correct reference read". The expected stem is regex-escaped
# and the path is end-anchored so expected="auth" does not match
# references/auth-mfa.md.
#
# Fail condition: the CLI ran but no Read against the expected reference
# appears (no Read at all, or Read against a different reference).
#
# Error condition: the CLI invocation itself failed (non-zero exit). The
# exit code and last stderr lines are surfaced on the harness's stderr, and
# the run records "error" — an infra outcome the renderer excludes from the
# pass-vs-fail vote, so an expired token is not misread as a navigator
# regression.
#
# A third argument, the owning contextualizer's slug, scopes the pass
# predicate to that root's own references/ directory. Installed-set mode
# supplies it; the default path passes nothing and the predicate stays the
# root-relative one it has always been. Without it, a fleet whose roots
# both carry `references/overview.md` — and `overview`, `configuration`,
# `testing` are exactly what reference files get called — scores the owner
# a pass for a run in which some sibling's navigator answered.
#
# The maintainer can override this function (e.g., to assert against catalog
# row text, or to use a different CLI) by editing the body below.
#
# When RUN_ONE_READS names a file, run_one also writes that run's Read file
# paths there, one per line — the raw material installed-set mode derives its
# fired set from, and empty for a run that produced no transcript. The
# default path leaves the variable empty and nothing is written.
RUN_ONE_READS=""
run_one() {
  local query="$1"
  local expected="$2"
  local owner_slug="${3:-}"
  local exp_re owner_re expect_path out rc err_tmp
  exp_re=$(printf '%s' "$expected" | sed -e 's/[][\.*^$+?(){}|\\\/]/\\&/g')
  if [ -n "$owner_slug" ]; then
    owner_re=$(printf '%s' "$owner_slug" | sed -e 's/[][\.*^$+?(){}|\\\/]/\\&/g')
    expect_path="/${owner_re}-context/references/${exp_re}\\.md\$"
  else
    expect_path="(^|/)references/${exp_re}\\.md\$"
  fi
  err_tmp=$(mktemp "${TMPDIR:-/tmp}/run-eval-stderr.XXXXXX")
  # Redirect stdin from /dev/null so claude does not consume the
  # process-substitution feeding the outer while-read loop. Without this,
  # only the first entry is processed and subsequent entries are silently
  # swallowed by claude's stdin read.
  rc=0
  out=$(claude --print --output-format=stream-json --verbose -p "$query" </dev/null 2>"$err_tmp") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  claude exited $rc for query: $query" >&2
    sed 's/^/    stderr: /' "$err_tmp" | tail -n 3 >&2
    rm -f "$err_tmp"
    if [ -n "$RUN_ONE_READS" ]; then : > "$RUN_ONE_READS"; fi
    echo "error"
    return 0
  fi
  rm -f "$err_tmp"
  # Parse stream-json line by line; fromjson? makes non-JSON lines a no-op.
  # Two stages, not one pipeline into grep -q: under pipefail, grep -q's
  # exit-at-first-match can SIGPIPE the upstream jq (status 141) on a
  # Read-heavy transcript and record a false "fail" for a passing run.
  # Capturing jq's output first, then counting with grep -c (which always
  # reads its whole input), leaves no early-exiting pipe reader anywhere.
  local read_paths hits
  read_paths=$(printf '%s\n' "$out" \
    | jq -Rr 'fromjson? | select(.type == "assistant")
              | .message.content[]?
              | select(.type == "tool_use" and .name == "Read")
              | (.input.file_path // empty)' 2>/dev/null) || read_paths=""
  if [ -n "$RUN_ONE_READS" ]; then printf '%s\n' "$read_paths" > "$RUN_ONE_READS"; fi
  hits=$(printf '%s\n' "$read_paths" \
    | grep -cE "$expect_path") || true
  if [ "${hits:-0}" -gt 0 ]; then
    echo "pass"
  else
    echo "fail"
  fi
}

# Iterate entries. evals.json is parsed with grep+sed+awk (no jq dependency);
# the supported shape is a top-level "entries" array of objects with at least
# "query" and "expected" string fields. Newlines inside string values are not
# supported (single-line entries only). Embedded \" inside a value is
# preserved by the unescape pass; embedded backslashes are also preserved.
emit_entries() {
  awk -v US="$US" '
    function extract(line, key,    out) {
      gsub(/\\"/, "\001", line)
      sub("^.*\"" key "\"[[:space:]]*:[[:space:]]*\"", "", line)
      sub(/".*$/, "", line)
      gsub(/\\\\/, "\\", line)
      gsub(/\001/, "\"", line)
      return line
    }
    function flush() {
      if (q != "" && e != "") {
        if (p == "") p = "domain-expert"
        printf "%s%s%s%s%s\n", q, US, e, US, p
      }
      in_entry = 0; q = ""; e = ""; p = ""
    }
    /"query"[[:space:]]*:[[:space:]]*"/ {
      if (in_entry && q != "") flush()
      in_entry = 1
      q = extract($0, "query")
    }
    /"expected"[[:space:]]*:[[:space:]]*"/ {
      if (in_entry && e != "") flush()
      if (!in_entry) in_entry = 1
      e = extract($0, "expected")
    }
    /"persona"[[:space:]]*:[[:space:]]*"/ {
      if (in_entry && p != "") flush()
      if (!in_entry) in_entry = 1
      p = extract($0, "persona")
    }
    in_entry && /^[[:space:]]*[\}]/ { flush() }
    END { if (in_entry) flush() }
  ' "$1"
}

# --- installed-set mode -----------------------------------------------------
#
# Everything below is reached only when --installed-set was supplied.
# emit_entries above is called, never edited: the fleet path unions its
# output across roots and tags each line with the owning contextualizer.

# The corpus files a root contributes: the union of evals-train.json and
# evals-test.json when either exists, else evals.json. A root carrying none
# contributes nothing and is not an error. Basenames only, so a caller can
# iterate them with an unquoted for.
fleet_corpus_bases() {
  local root="$1"
  if [ -f "$root/evals/evals-train.json" ] || [ -f "$root/evals/evals-test.json" ]; then
    [ -f "$root/evals/evals-train.json" ] && printf 'evals-train.json\n'
    [ -f "$root/evals/evals-test.json" ] && printf 'evals-test.json\n'
  elif [ -f "$root/evals/evals.json" ]; then
    printf 'evals.json\n'
  fi
  return 0
}

# Schema-check every corpus the fleet contributes, here in the main shell.
# emit_fleet_entries runs inside the process substitution that feeds the
# entry loop, where check_schema_version's exit 65 would kill only that
# subshell and leave the harness running against a silently truncated
# entry stream.
validate_fleet_corpora() {
  local roots_file="$1" root base
  while IFS= read -r root; do
    root=${root%/}
    [ -n "$root" ] || continue
    # shellcheck disable=SC2046 # word-split is intended: these are basenames, never paths
    for base in $(fleet_corpus_bases "$root"); do
      check_schema_version "$root/evals/$base"
    done
  done < "$roots_file"
}

# The fleet entry stream: query US expected US persona US owning-slug. An
# entry survives only when its expected resolves to a real reference under
# the root it came from — the in-scope filter, which is what makes a
# cross-fleet run measure confusion rather than coverage.
emit_fleet_entries() {
  local roots_file="$1"
  local root slug base query expected persona
  while IFS= read -r root; do
    root=${root%/}
    [ -n "$root" ] || continue
    slug=${root##*/}
    slug=${slug%-context}
    # shellcheck disable=SC2046 # word-split is intended: these are basenames, never paths
    for base in $(fleet_corpus_bases "$root"); do
      while IFS="$US" read -r query expected persona; do
        [ -z "$query" ] && continue
        [ -f "$root/references/$expected.md" ] || continue
        printf '%s%s%s%s%s%s%s\n' "$query" "$US" "$expected" "$US" "$persona" "$US" "$slug"
      done < <(emit_entries "$root/evals/$base")
    done
  done < "$roots_file"
}

# The installed slugs that fired on one run. A navigator has fired when the
# run's transcript carries a Read of a reference under that navigator's own
# references/ directory; the slug is regex-escaped and the path end-anchored
# the same way run_one escapes and anchors `expected`. INSTALLED_SLUGS is
# already sorted, so the emitted array is too.
fired_slugs() {
  local reads_file="$1"
  local slug slug_re out=""
  # shellcheck disable=SC2086 # word-split is intended: one slug per line
  for slug in $INSTALLED_SLUGS; do
    slug_re=$(printf '%s' "$slug" | sed -e 's/[][\.*^$+?(){}|\\\/]/\\&/g')
    if grep -qE "/${slug_re}-context/references/[^/]*\\.md\$" "$reads_file"; then
      if [ -n "$out" ]; then out="$out, \"$slug\""; else out="\"$slug\""; fi
    fi
  done
  printf '%s' "$out"
}

# The entry stream the loop below consumes. Installed-set mode unions every
# root's corpus and tags each line with its owning slug; the default path
# emits exactly what it always has.
emit_run_entries() {
  if [ "$INSTALLED_SET_MODE" -eq 1 ]; then
    emit_fleet_entries "$ROOTS_FILE"
  else
    emit_entries "$EVALS_PATH"
  fi
}

ROOTS_FILE=""
READS_TMP=""
INSTALLED_SLUGS=""
INSTALLED_SET_JSON=""

# Every scratch file this script creates, removed in one place. Guarded
# expansions throughout: it is installed as an EXIT trap before some of
# these variables are set, and runs under `set -u`.
clean_scratch() {
  rm -f ${TMP_RESULTS:+"$TMP_RESULTS"} \
        ${ROOTS_FILE:+"$ROOTS_FILE"} \
        ${READS_TMP:+"$READS_TMP"}
}
TMP_RESULTS=""
if [ "$INSTALLED_SET_MODE" -eq 1 ]; then
  # Consume the root list ONCE, into a file, before the entry loop exists.
  # That loop reads from a process substitution and run_one redirects the
  # CLI's stdin from /dev/null precisely so nothing else can eat that
  # stream; a second stdin reader running inside or after the loop makes the
  # harness silently process one entry.
  ROOTS_FILE=$(mktemp "${TMPDIR:-/tmp}/run-eval-roots.XXXXXX")
  READS_TMP=$(mktemp "${TMPDIR:-/tmp}/run-eval-reads.XXXXXX")
  # Installed immediately, and with an EXIT arm. Everything between here
  # and the results-file trap below can leave the script: the corpus
  # validation a few lines down calls check_schema_version, whose failure
  # path is `exit 65` in the main shell -- deliberately, so a rejected
  # corpus cannot be half-processed -- and an `exit` runs no INT/TERM
  # trap. Without EXIT, both files above survived every refused run. The
  # results-file trap below adds to this rather than replacing it; `trap`
  # is per-signal, and clean_scratch is idempotent.
  trap clean_scratch EXIT
  # `grep .` drops blank lines: the locator's --all enumeration ends with a
  # newline, and a trailing empty line would become an empty slug.
  if [ "$INSTALLED_SET_ARG" = "-" ]; then
    grep . > "$ROOTS_FILE" || true
  elif [ -f "$INSTALLED_SET_ARG" ]; then
    grep . "$INSTALLED_SET_ARG" > "$ROOTS_FILE" || true
  else
    echo "ERROR: installed-set roots file not found at $INSTALLED_SET_ARG" >&2
    exit 65
  fi
  if [ ! -s "$ROOTS_FILE" ]; then
    echo "ERROR: --installed-set was supplied no contextualizer roots." >&2
    exit 65
  fi

  # The installed set: every supplied root's bare slug, sorted, regardless
  # of the order they arrived in. A root that owns no in-scope query is in
  # here too — it still gets a column in the confusion table.
  INSTALLED_SLUGS=$(while IFS= read -r _root; do
      _root=${_root%/}
      _base=${_root##*/}
      printf '%s\n' "${_base%-context}"
    done < "$ROOTS_FILE" | LC_ALL=C sort -u)
  unset _root _base
  INSTALLED_SET_JSON=$(printf '%s\n' "$INSTALLED_SLUGS" | awk '
    NF { s = $0; gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
         printf "%s\"%s\"", (n++ ? ", " : ""), s }')

  validate_fleet_corpora "$ROOTS_FILE"
fi

# --- end installed-set mode -------------------------------------------------

mkdir -p "$(dirname "$RESULTS_PATH")"
TMP_RESULTS="${RESULTS_PATH}.tmp"
# Don't strand the half-written .tmp on Ctrl-C / kill; normal completion
# renames it away before the trap could matter. The exit is load-bearing:
# without it bash resumes the script after the trap, the >> appends
# recreate the deleted file without its JSON header or earlier entries,
# and the final mv publishes the corrupt results file with exit 0.
#
# Re-armed here rather than replaced: installed-set mode already set an
# EXIT trap beside its first mktemp, and this pair adds TMP_RESULTS to
# what the same function removes. The default path reaches these two
# without having set the earlier one, which is why EXIT is repeated.
trap 'clean_scratch; exit 130' INT TERM
trap clean_scratch EXIT

start_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  printf '{\n'
  printf '  "navigator": "%s",\n' "$NAVIGATOR"
  printf '  "schema_version": 1,\n'
  if [ "$INSTALLED_SET_MODE" -eq 1 ]; then
    printf '  "installed_set": [%s],\n' "$INSTALLED_SET_JSON"
  fi
  printf '  "started_at": "%s",\n' "$start_iso"
  printf '  "runs_per_query": %d,\n' "$RUNS_PER_QUERY"
  printf '  "entries": [\n'
} > "$TMP_RESULTS"

first=1
total_runs=0
error_runs=0
# `owner` is empty on a default-mode line, which carries three fields; one
# loop serves both modes. RUN_ONE_READS is empty in default mode too, so
# run_one records nothing and `fired` stays unbuilt.
while IFS="$US" read -r query expected persona owner; do
  [ -z "$query" ] && continue
  echo "running: $query (expected: $expected, persona: $persona)" >&2
  runs=""
  fired=""
  i=1
  while [ "$i" -le "$RUNS_PER_QUERY" ]; do
    RUN_ONE_READS="$READS_TMP"
    outcome=$(run_one "$query" "$expected" "$owner")
    if [ -n "$runs" ]; then runs="$runs, \"$outcome\""; else runs="\"$outcome\""; fi
    if [ "$INSTALLED_SET_MODE" -eq 1 ]; then
      fired_run=$(fired_slugs "$READS_TMP")
      if [ -n "$fired" ]; then fired="$fired, [$fired_run]"; else fired="[$fired_run]"; fi
    fi
    total_runs=$((total_runs + 1))
    [ "$outcome" = "error" ] && error_runs=$((error_runs + 1))
    i=$((i + 1))
  done

  if [ "$first" -eq 0 ]; then printf ',\n' >> "$TMP_RESULTS"; fi
  first=0

  # Escape minimal JSON metacharacters (\ and ") in query.
  # printf %s avoids echo's flag-eating on values starting with -e/-E/-n.
  esc_query=$(printf '%s' "$query"    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  esc_expected=$(printf '%s' "$expected" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  esc_persona=$(printf '%s' "$persona" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')

  # "owner" and "fired" are written BEFORE the runs array so that `"runs": [`
  # stays the last occurrence of that token on the line: the renderer anchors
  # on it greedily, and it being the final field written is what that anchor
  # relies on.
  if [ "$INSTALLED_SET_MODE" -eq 1 ]; then
    esc_owner=$(printf '%s' "$owner" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf '    {"query": "%s", "expected": "%s", "persona": "%s", "owner": "%s", "fired": [%s], "runs": [%s]}' \
      "$esc_query" "$esc_expected" "$esc_persona" "$esc_owner" "$fired" "$runs" >> "$TMP_RESULTS"
  else
    printf '    {"query": "%s", "expected": "%s", "persona": "%s", "runs": [%s]}' \
      "$esc_query" "$esc_expected" "$esc_persona" "$runs" >> "$TMP_RESULTS"
  fi
done < <(emit_run_entries)

rm -f ${ROOTS_FILE:+"$ROOTS_FILE"} ${READS_TMP:+"$READS_TMP"}

end_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  printf '\n'
  printf '  ],\n'
  printf '  "ended_at": "%s"\n' "$end_iso"
  printf '}\n'
} >> "$TMP_RESULTS"

mv "$TMP_RESULTS" "$RESULTS_PATH"
echo "wrote: $RESULTS_PATH" >&2

# Runner-failure detection (mirrors grounded_rate.py's exit-2 contract):
# when EVERY invocation errored, the report measures the runner, not the
# navigator. Surface that loudly instead of rendering a misleading 0%.
if [ "$total_runs" -gt 0 ] && [ "$error_runs" -eq "$total_runs" ]; then
  echo "ERROR: runner failure — all $total_runs invocations errored (expired auth or broken CLI likely). Fix the runner before reading the report." >&2
  exit 70
fi

# Render summary inline if the renderer is available.
if [ -x "$(dirname "$0")/render-eval-results.sh" ]; then
  bash "$(dirname "$0")/render-eval-results.sh" "$RESULTS_PATH"
fi
