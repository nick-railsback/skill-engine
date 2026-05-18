#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C
export LC_ALL

# render-eval-results.sh parameterized template for the library-context
# navigator's eval-results renderer.
#
# This is a TEMPLATE. Replace placeholders before use:
# library           - your domain stem (used in output header)
#
# See 12-evaluation.md for the schema and aggregation contract.
#
# Usage:
#   bash evals/render-eval-results.sh <results-path> [<baseline-results-path>]
#
# Inputs:
#   $1 - path to a results-*.json produced by run-eval.sh
#   $2 - (optional) path to a baseline results-*.json; if provided, the
#        renderer reports per-query deltas (regressions, gains, flicker
#        stabilisation, new flicker) against the baseline.
#
# Output:
#   Aggregated text on stdout. Sections (in order):
#     1. Header (navigator, run timestamps).
#     2. Per-persona pass rates AND overall pass rate.
#     3. Per-entry results: query, expected reference, runs, majority vote,
#        flicker flag.
#     4. (If baseline provided) Delta section: regressions, gains, stabilised,
#        newly flickering.
#
# Determinism:
#   Same input file -> identical output bytes on rerun. LC_ALL=C is pinned at
#   the top so sort/awk ordering does not vary by locale. Entries are emitted
#   in input-file order; no timestamps in the output body, no random ordering.
#
# Portability:
#   POSIX awk (no asorti/PROCINFO/gensub). Stock macOS awk and gawk both work.
#
# Exit codes:
#   0  - rendered successfully.
#   64 - usage error or unsubstituted template placeholders.
#   65 - results file missing or malformed.

# Belt-and-suspenders: refuse to run if placeholders have not been substituted.
# The placeholder is reassembled at runtime so a naive sed substitution like
#   sed 's/library/library/g'
# does not rewrite this check (the way it rewrites every other occurrence).
_ph_a='<area'
_ph_b='-domain>'
_PLACEHOLDER="${_ph_a}${_ph_b}"
if grep -qF "${_PLACEHOLDER}" "$0"; then
  echo "ERROR: template placeholder ${_PLACEHOLDER} not substituted; copy and replace before running." >&2
  exit 64
fi
unset _ph_a _ph_b _PLACEHOLDER

if [ -z "${1:-}" ]; then
  echo "usage: $0 <results-path> [<baseline-results-path>]" >&2
  exit 64
fi

RESULTS_PATH="$1"
BASELINE_PATH="${2:-}"

if [ ! -f "$RESULTS_PATH" ]; then
  echo "ERROR: results file not found at $RESULTS_PATH" >&2
  exit 65
fi

# Strict integer schema_version check.
schema_version_raw=$(grep -E '^[[:space:]]*"schema_version"[[:space:]]*:' "$RESULTS_PATH" \
  | head -n 1 \
  | sed -E 's/^[[:space:]]*"schema_version"[[:space:]]*:[[:space:]]*//; s/[[:space:]]*,?[[:space:]]*$//' \
  || true)

if [ -z "${schema_version_raw:-}" ]; then
  schema_version=1
elif printf '%s' "$schema_version_raw" | grep -qE '^[1-9][0-9]*$'; then
  schema_version=$schema_version_raw
else
  echo "ERROR: schema_version must be a JSON integer >= 1; got: $schema_version_raw" >&2
  exit 65
fi

if [ "$schema_version" != "1" ]; then
  echo "ERROR: renderer understands schema_version 1; got: $schema_version" >&2
  exit 65
fi

# Field separator for record streams: ASCII Unit Separator (US, 0x1F). Picked
# because it is illegal in JSON strings, so it cannot appear inside a value
# parsed out of evals.json or results-*.json. Tab was unsafe (a literal tab
# in any value would corrupt the stream; literal-tab parameter expansions
# also broke if an editor converted them to spaces).
US=$(printf '\037')

# Emit <query>US<expected>US<persona>US<run1>US<run2>US<run3> per entry.
#
# Quote-handling: a value containing an escaped quote (\") is preserved by
# rewriting \" as SOH (0x01) before stripping at the next unescaped quote,
# then restoring SOH back to ". Backslash-escapes are then unescaped so the
# rendered query reads the same as it was authored. Newlines inside string
# values are still unsupported (single-line entries only).
emit_records() {
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
      if (q != "" && e != "" && runs != "") {
        if (p == "") p = "domain-expert"
        n = split(runs, parts, ",")
        printf "%s%s%s%s%s", q, US, e, US, p
        for (i = 1; i <= n; i++) printf "%s%s", US, parts[i]
        printf "\n"
      }
      in_entry = 0; q = ""; e = ""; p = ""; runs = ""
    }
    # An entry begins at the first occurrence of any entry-field on a line.
    # Flushing happens when (a) the next entry begins (whichever field comes
    # first), or (b) a closing brace line appears (multi-line entry shape),
    # or (c) at END (last entry).
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
    in_entry && /"runs"[[:space:]]*:[[:space:]]*\[/ {
      line = $0
      sub(/^[^[]*\[/, "", line)
      sub(/\].*$/, "", line)
      gsub(/[" ]/, "", line)
      runs = line
    }
    in_entry && /^[[:space:]]*[\}]/ { flush() }
    END { if (in_entry) flush() }
  ' "$1"
}

# Decide majority vote and flicker flag from a list of run outcomes.
# Inputs: $1 = comma-separated outcomes (e.g., "pass,pass,fail").
# Outputs: "<vote>:<flicker>" on stdout (vote = pass|fail, flicker = yes|no).
# The colon separator avoids the editor-fragility of a literal tab.
decide() {
  local outcomes="$1"
  local pass=0 fail=0
  local IFS=','
  for o in $outcomes; do
    [ "$o" = "pass" ] && pass=$((pass + 1))
    [ "$o" = "fail" ] && fail=$((fail + 1))
  done
  local vote flicker
  if [ "$pass" -gt "$fail" ]; then vote=pass; else vote=fail; fi
  if [ "$pass" -gt 0 ] && [ "$fail" -gt 0 ]; then flicker=yes; else flicker=no; fi
  printf '%s:%s\n' "$vote" "$flicker"
}

# Aggregate per-persona and overall pass rates from the records stream.
# Reads records from $1 (a temp file), writes summary to stdout.
#
# Persona ordering uses external `sort` (LC_ALL=C is pinned at the top of the
# script so the order is locale-stable). POSIX awk lacks asorti, so the
# internal awk emits per-persona rows on stdout and the surrounding pipeline
# sorts them deterministically.
aggregate() {
  local records="$1"
  local total_overall=0 pass_overall=0
  total_overall=$(awk -v US="$US" 'BEGIN{FS=US} { c++ } END{print c+0}' "$records")
  pass_overall=$(awk -v US="$US" '
    BEGIN{FS=US}
    {
      pass = 0; fail = 0
      for (i = 4; i <= NF; i++) {
        if ($i == "pass") pass++
        if ($i == "fail") fail++
      }
      if (pass > fail) c++
    }
    END{print c+0}
  ' "$records")
  printf '  overall: %d / %d\n' "$pass_overall" "$total_overall"

  awk -v US="$US" '
    BEGIN{FS=US}
    {
      persona = $3
      pass = 0; fail = 0
      for (i = 4; i <= NF; i++) {
        if ($i == "pass") pass++
        if ($i == "fail") fail++
      }
      total[persona]++
      if (pass > fail) ok[persona]++
    }
    END {
      for (k in total) printf "%s\t%d\t%d\n", k, ok[k]+0, total[k]+0
    }
  ' "$records" | LC_ALL=C sort | awk -F '\t' '{ printf "  %s: %d / %d\n", $1, $2, $3 }'
}

TMP_RECORDS=$(mktemp eval-records.XXXXXX 2>/dev/null || mktemp)
trap 'rm -f "$TMP_RECORDS"' EXIT
emit_records "$RESULTS_PATH" > "$TMP_RECORDS"

if [ ! -s "$TMP_RECORDS" ]; then
  echo "ERROR: no eval entries parsed from $RESULTS_PATH" >&2
  exit 65
fi

echo "=== library-context eval results ==="
echo "results: $RESULTS_PATH"
echo
echo "Pass rates (majority vote of three runs):"
aggregate "$TMP_RECORDS"
echo
echo "Per-entry detail:"
while IFS="$US" read -r query expected _persona r1 r2 r3; do
  [ -z "$query" ] && continue
  decision=$(decide "$r1,$r2,$r3")
  vote="${decision%%:*}"
  flicker="${decision##*:}"
  if [ "$flicker" = "yes" ]; then
    printf '  [%s] [FLICKER] %s -> %s | %s,%s,%s\n' "$vote" "$query" "$expected" "$r1" "$r2" "$r3"
  else
    printf '  [%s] %s -> %s | %s,%s,%s\n' "$vote" "$query" "$expected" "$r1" "$r2" "$r3"
  fi
done < "$TMP_RECORDS"

if [ -n "$BASELINE_PATH" ]; then
  if [ ! -f "$BASELINE_PATH" ]; then
    echo "ERROR: baseline file not found at $BASELINE_PATH" >&2
    exit 65
  fi
  TMP_BASELINE=$(mktemp eval-baseline.XXXXXX 2>/dev/null || mktemp)
  trap 'rm -f "$TMP_RECORDS" "$TMP_BASELINE"' EXIT
  emit_records "$BASELINE_PATH" > "$TMP_BASELINE"

  echo
  echo "Deltas vs. baseline ($BASELINE_PATH):"
  awk -v US="$US" '
    BEGIN{FS=US}
    function vote_of(r1, r2, r3,    pass) {
      pass = 0
      if (r1 == "pass") pass++
      if (r2 == "pass") pass++
      if (r3 == "pass") pass++
      return (pass >= 2) ? "pass" : "fail"
    }
    function flicker_of(r1, r2, r3,    p, f) {
      p = 0; f = 0
      if (r1 == "pass") p++; else if (r1 == "fail") f++
      if (r2 == "pass") p++; else if (r2 == "fail") f++
      if (r3 == "pass") p++; else if (r3 == "fail") f++
      return (p > 0 && f > 0) ? "yes" : "no"
    }
    NR == FNR {
      base_vote[$1] = vote_of($4, $5, $6)
      base_flicker[$1] = flicker_of($4, $5, $6)
      next
    }
    {
      v = vote_of($4, $5, $6)
      fl = flicker_of($4, $5, $6)
      if (!($1 in base_vote)) {
        printf "  [NEW] %s -> %s (vote=%s, flicker=%s)\n", $1, $2, v, fl
        next
      }
      if (base_vote[$1] == "pass" && v == "fail") {
        printf "  [REGRESSION] %s -> %s\n", $1, $2
      } else if (base_vote[$1] == "fail" && v == "pass") {
        printf "  [GAIN] %s -> %s\n", $1, $2
      } else if (base_flicker[$1] == "yes" && fl == "no") {
        printf "  [STABILISED] %s -> %s (now %s)\n", $1, $2, v
      } else if (base_flicker[$1] == "no" && fl == "yes") {
        printf "  [NEW FLICKER] %s -> %s\n", $1, $2
      }
    }
  ' "$TMP_BASELINE" "$TMP_RECORDS"
fi
