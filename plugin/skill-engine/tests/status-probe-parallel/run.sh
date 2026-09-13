#!/usr/bin/env bash
# Black-box test runner for concurrent upstream-drift probing: the
# `status_probe.py` script that answers "does the pinned sha still match
# upstream?" per git-managed source, and the REFRESH reference prose that
# describes the same probe as REFRESH's own Phase 1.
#
# The invariants asserted here:
#
#   - Probing is concurrent and bounded. Many in-scope sources are probed
#     with more than one probe in flight at a time, and never more than ten
#     in flight at a time.
#   - The JSON array on stdout carries one object per in-scope source, in
#     the order the sources appear in the input file — not in the order
#     their probes happen to finish.
#   - Each object has exactly the keys `source_id`, `state`,
#     `recorded_sha`, `live_sha`, plus `error` when and only when
#     `state == "error"`.
#   - A source whose probe fails is reported `error` in its own object, the
#     other sources are reported normally, and the run still exits 0. Three
#     distinct mechanisms produce a failed probe and all three are covered:
#     git exiting non-zero (an unreachable url), git exiting zero with no
#     matching ref printed (a real repository, a ref that is not there), and
#     an exception raised inside the probe itself before git is ever reached.
#     The third is the one that only matters once probes overlap — an
#     exception escaping a worker discards every result the run had already
#     collected, where the other two never leave the probe — so it is
#     asserted directly rather than left to the mutation hook below.
#   - Every `git` invocation a run makes is `ls-remote`, and a run writes
#     nothing: the input file, the fixture tree it points at, and the
#     working directory are byte-identical afterwards. The claim is scoped
#     to `git`: a `PATH` shim can only observe the executable it shadows, so
#     a call to some other program is outside what this can see.
#   - The REFRESH reference's HEAD-probe phase states that its `git-managed`
#     probes may run concurrently up to ten at a time, that neither the
#     order results are promoted in nor per-source isolation changes
#     because of it, and that the `web-doc` HTTP HEAD path is unaffected.
#     The phase is kind-dispatched, so the concurrency claim being scoped to
#     one kind is part of the claim, not decoration.
#
# Fixture style: throwaway local git repositories built under a tmpdir
# (`git init` plus a local commit, then `git clone --bare`) and used
# directly as `git ls-remote`'s `<url>` argument, exactly the way a real
# remote url would be — fully offline, nothing here touches the network.
# Four cases instead put a `git` wrapper script first on `PATH` for the
# duration of that one invocation: a wrapper that sleeps a per-url delay
# (result order), one that records how many probes are in flight
# (concurrency bound), one that always takes a second to answer (wall
# clock), and one that logs its own argv and then delegates to the real git
# (verb allow-list). Only those cases shadow git; every other case runs
# real git.
#
# --- Calibration hooks -----------------------------------------------------
#
# Several of the invariants above are *preservation* invariants: they are
# already true of the script as it stands, so a red-to-green transition
# cannot demonstrate that the assertion detects their absence. Set
# STATUS_PROBE_PY to a scratch copy of the script to calibrate them by
# mutation — the copy is mutated, the tracked file is never touched, and
# the named assertion is required to flip to FAIL:
#
#   reverse the result list before dumping       -> file order FAILs
#   delete a key from a returned object          -> object shape FAILs
#   return an error object where it raises      -> raised-failure FAILs
#   re-raise instead of returning an error object-> error isolation FAILs
#   add any second git verb to the probe call    -> verb allow-list FAILs
#   write the input path back out after reading  -> read-only FAILs
#   raise the worker bound above ten             -> in-flight bound FAILs
#
# DRIFT_PHASES_MD does the same for the reference document: point it at a
# scratch copy with a sentence removed and the matching prose assertion
# must flip to FAIL.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ ! -f "$PLUGIN_ROOT/tests/status_probe.py" ]; then
  # The runner is being executed from a staging location rather than from
  # beside its siblings; find the plugin root by walking up instead.
  _d="$SCRIPT_DIR"
  while [ "$_d" != "/" ]; do
    if [ -d "$_d/plugin/skill-engine" ]; then
      PLUGIN_ROOT="$_d/plugin/skill-engine"
      break
    fi
    _d="$(dirname "$_d")"
  done
fi

PROBE_SCRIPT="${STATUS_PROBE_PY:-$PLUGIN_ROOT/tests/status_probe.py}"
PHASES_MD="${DRIFT_PHASES_MD:-$PLUGIN_ROOT/skills/refresh/references/drift-detection-and-phases.md}"

FAKE_SHA="0123456789abcdef0123456789abcdef01234567"

pass_count=0
fail_count=0

TMPROOT="$(mktemp -d -t skill-engine-probe-parallel.XXXXXX)"
cleanup() { rm -rf "$TMPROOT"; }
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

fixture_error() {
  printf '  FAIL  fixture error: %s\n' "$1"
  fail_count=$((fail_count + 1))
}

# jq_check <json> <jq-boolean-program> [--arg name value ...] — true (rc 0)
# only when the input is valid JSON AND the boolean program evaluates true.
jq_check() {
  local json="$1" program="$2"
  shift 2
  printf '%s' "$json" | jq -e "$@" "$program" >/dev/null 2>&1
}

now_epoch() {
  python3 -c 'import time; print(repr(time.time()))'
}

# float_ge <a> <b> — rc 0 when float a >= float b.
float_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'
}

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# tree_fingerprint <dir> — one line per regular file: relative path plus
# content hash, sorted. Catches a new file, a deleted file and an edited
# file alike.
tree_fingerprint() {
  local root="$1" f
  find "$root" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "${f#"$root"/}" "$(sha256_of_file "$f")"
  done
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

new_bare_repo() {
  # new_bare_repo <working-dir> <bare-dir> — a bare repository with one
  # commit on `main`, the shape a remote url really points at.
  local work="$1" bare="$2"
  mkdir -p "$work" || return 1
  git -C "$work" init -q -b main >/dev/null 2>&1 || return 1
  git -C "$work" config user.email "skill-engine-tests@example.com" || return 1
  git -C "$work" config user.name "skill-engine tests" || return 1
  printf 'v1\n' > "$work/content.txt" || return 1
  git -C "$work" add -A >/dev/null 2>&1 || return 1
  git -C "$work" commit -q -m "first" >/dev/null 2>&1 || return 1
  git clone -q --bare "$work" "$bare" >/dev/null 2>&1 || return 1
}

# source_entry <id> <url> [branch] — one source-paths.json entry, in scope,
# never previously probed.
source_entry() {
  local id="$1" url="$2" branch="${3:-}"
  if [ -n "$branch" ]; then
    jq -n --arg id "$id" --arg url "$url" --arg branch "$branch" \
      '{id:$id, kind:"git-managed", url:$url, branch:$branch, status:"confirmed",
        archived:false,
        lifecycle:{state:"reachable", last_checked:null, last_checked_sha:null,
                   proposed_url:null},
        discovered_via:null}'
  else
    jq -n --arg id "$id" --arg url "$url" \
      '{id:$id, kind:"git-managed", url:$url, status:"confirmed",
        archived:false,
        lifecycle:{state:"reachable", last_checked:null, last_checked_sha:null,
                   proposed_url:null},
        discovered_via:null}'
  fi
}

write_sources_file() {
  local out="$1"
  shift
  printf '%s\n' "$@" | jq -s '{schema_version: 1, sources: .}' > "$out"
}

run_probe() {
  # run_probe <source-paths.json> [extra-path-prefix] — invokes the script
  # under test, capturing stdout into PROBE_OUT and the exit code into
  # PROBE_RC. A missing or broken script collapses to empty stdout; every
  # assertion below independently requires specific JSON, so that always
  # reads as a failure rather than a vacuous pass.
  local fixture="$1" prefix="${2:-}"
  if [ -n "$prefix" ]; then
    PROBE_OUT="$(PATH="$prefix:$PATH" python3 "$PROBE_SCRIPT" "$fixture" 2>/dev/null)"
  else
    PROBE_OUT="$(python3 "$PROBE_SCRIPT" "$fixture" 2>/dev/null)"
  fi
  PROBE_RC=$?
}

# ---------------------------------------------------------------------------
# Wrapper builders. Each writes a `git` shim into its own directory, which
# is prepended to PATH for exactly one probe invocation.
# ---------------------------------------------------------------------------

make_delay_git() {
  # A remote that answers after a delay encoded in the last path segment of
  # the url (`.../delay-0.40`). Lets the fixture make completion order
  # differ from file order on purpose.
  local dir="$1"
  mkdir -p "$dir" || return 1
  cat > "$dir/git" <<'SHIM'
#!/usr/bin/env bash
url=""
for a in "$@"; do
  case "$a" in
    */delay-*) url="$a" ;;
  esac
done
delay="${url##*/delay-}"
case "$delay" in
  ''|*[!0-9.]*) delay="0" ;;
esac
sleep "$delay"
printf '%s\tHEAD\n' "${PROBE_FIXTURE_SHA:-0000000000000000000000000000000000000000}"
SHIM
  chmod +x "$dir/git" || return 1
}

make_counting_git() {
  # Records, for every probe, how many probes were in flight when it
  # started. The count can never exceed the number of probes actually
  # running at once, so its maximum is a lower bound on real concurrency
  # and can never exceed a worker bound.
  local dir="$1"
  mkdir -p "$dir" || return 1
  cat > "$dir/git" <<'SHIM'
#!/usr/bin/env bash
marker="$PROBE_INFLIGHT_DIR/$$"
: > "$marker"
set -- "$PROBE_INFLIGHT_DIR"/*
if [ -e "$1" ]; then n=$#; else n=0; fi
printf '%s\n' "$n" >> "$PROBE_CONCURRENCY_LOG"
sleep "${PROBE_SHIM_DELAY:-0.25}"
rm -f "$marker"
printf '%s\tHEAD\n' "${PROBE_FIXTURE_SHA:-0000000000000000000000000000000000000000}"
SHIM
  chmod +x "$dir/git" || return 1
}

make_sleeping_git() {
  # A remote that takes one second to answer, whatever it is asked.
  local dir="$1"
  mkdir -p "$dir" || return 1
  cat > "$dir/git" <<'SHIM'
#!/usr/bin/env bash
sleep 1
printf '%s\tHEAD\n' "${PROBE_FIXTURE_SHA:-0000000000000000000000000000000000000000}"
SHIM
  chmod +x "$dir/git" || return 1
}

make_logging_git() {
  # Logs its own argument vector, then hands the call to the real git, so
  # the run stays truthful while every verb it used is recoverable.
  local dir="$1" real_git="$2"
  mkdir -p "$dir" || return 1
  cat > "$dir/git" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$PROBE_ARGV_LOG"
exec "$real_git" "\$@"
SHIM
  chmod +x "$dir/git" || return 1
}

# ===========================================================================
echo
echo "── results are ordered as the sources appear in the file ──"
# ===========================================================================
# Five sources whose remotes answer at deliberately different speeds, with
# the slowest first. Under any collect-as-each-finishes scheme the array
# comes back in roughly the reverse of this order; only a run that keeps
# submission order reports it unchanged.

order_dir="$TMPROOT/order"
order_shim="$order_dir/bin"
if ! make_delay_git "$order_shim"; then
  fixture_error "could not build the delaying git shim"
else
  mkdir -p "$order_dir"
  order_fp="$order_dir/sources.json"
  write_sources_file "$order_fp" \
    "$(source_entry "src-1-slowest" "$order_dir/remote/delay-0.60")" \
    "$(source_entry "src-2" "$order_dir/remote/delay-0.05")" \
    "$(source_entry "src-3" "$order_dir/remote/delay-0.40")" \
    "$(source_entry "src-4-fastest" "$order_dir/remote/delay-0.01")" \
    "$(source_entry "src-5" "$order_dir/remote/delay-0.25")"
  PROBE_FIXTURE_SHA="$FAKE_SHA"
  export PROBE_FIXTURE_SHA
  run_probe "$order_fp" "$order_shim"
  if jq_check "$PROBE_OUT" '
      [.[].source_id]
      == ["src-1-slowest", "src-2", "src-3", "src-4-fastest", "src-5"]
  '; then
    pass "file order: results come back in the order the sources are written, not the order their probes finish"
  else
    fail "file order: results come back in the order the sources are written, not the order their probes finish" \
      "stdout: ${PROBE_OUT:-<empty>}"
  fi
  unset PROBE_FIXTURE_SHA
fi

# ===========================================================================
echo
echo "── more than one probe in flight, and never more than ten ──"
# ===========================================================================
# Twenty sources against a remote that takes a quarter second each. A run
# that probes one at a time records a maximum in-flight count of 1; a run
# with a bound of ten saturates it. The two halves are deliberately paired:
# "at most ten" is satisfied by a sequential run as well, so on its own it
# proves nothing, and it is the half a mutation (a raised worker bound on a
# scratch copy) has to be able to break.

conc_dir="$TMPROOT/concurrency"
conc_shim="$conc_dir/bin"
PROBE_INFLIGHT_DIR="$conc_dir/inflight"
PROBE_CONCURRENCY_LOG="$conc_dir/counts.log"
mkdir -p "$PROBE_INFLIGHT_DIR"
: > "$PROBE_CONCURRENCY_LOG"
if ! make_counting_git "$conc_shim"; then
  fixture_error "could not build the counting git shim"
else
  conc_entries=()
  conc_i=1
  while [ "$conc_i" -le 20 ]; do
    conc_entries+=("$(source_entry "conc-$conc_i" "$conc_dir/remote-$conc_i")")
    conc_i=$((conc_i + 1))
  done
  conc_fp="$conc_dir/sources.json"
  write_sources_file "$conc_fp" "${conc_entries[@]}"
  export PROBE_INFLIGHT_DIR PROBE_CONCURRENCY_LOG
  PROBE_SHIM_DELAY="0.25"
  PROBE_FIXTURE_SHA="$FAKE_SHA"
  export PROBE_SHIM_DELAY PROBE_FIXTURE_SHA
  run_probe "$conc_fp" "$conc_shim"
  unset PROBE_SHIM_DELAY PROBE_FIXTURE_SHA
  max_inflight="$(LC_ALL=C sort -n "$PROBE_CONCURRENCY_LOG" 2>/dev/null | tail -1)"
  probe_calls="$(wc -l < "$PROBE_CONCURRENCY_LOG" | tr -d ' ')"
  : "${max_inflight:=0}"

  if [ "$probe_calls" -eq 20 ]; then
    pass "concurrency fixture: every one of the twenty sources was probed exactly once"
  else
    fail "concurrency fixture: every one of the twenty sources was probed exactly once" \
      "probe invocations recorded: $probe_calls (expected 20)"
  fi

  if [ "$max_inflight" -ge 2 ]; then
    pass "concurrency: probes overlap — more than one is in flight at a time"
  else
    fail "concurrency: probes overlap — more than one is in flight at a time" \
      "peak probes in flight: $max_inflight (1 means one-at-a-time)"
  fi

  if [ "$max_inflight" -le 10 ]; then
    pass "concurrency bound: no more than ten probes are ever in flight at once"
  else
    fail "concurrency bound: no more than ten probes are ever in flight at once" \
      "peak probes in flight: $max_inflight"
  fi
  unset PROBE_INFLIGHT_DIR PROBE_CONCURRENCY_LOG
fi

# ===========================================================================
echo
echo "── eight one-second probes finish well inside the sequential cost ──"
# ===========================================================================
# A wall-clock bound, and wall-clock bounds are the flakiest assertion
# there is, so what this one does and does not establish, plainly:
#
#   It establishes that eight probes against a remote taking one second
#   each did not run one after another. Overlapped, they cost a little over
#   one second; one at a time they cost at least eight. The four-second
#   bound sits roughly two and a half seconds clear of both, which is the
#   margin — it is not a performance budget and a change that made probing
#   three times slower while keeping it concurrent would still pass.
#
#   It does not establish a worker count, a scheduling policy, or anything
#   about a real network.
#
# A slow machine and a return to one-at-a-time both break the bound, so the
# failure message separates them: a single probe is timed first as this
# machine's baseline, and eight probes costing near eight baselines is
# sequential, while eight probes costing far less than that but still over
# four seconds is a loaded machine.

time_dir="$TMPROOT/timing"
time_shim="$time_dir/bin"
if ! make_sleeping_git "$time_shim"; then
  fixture_error "could not build the sleeping git shim"
else
  mkdir -p "$time_dir"
  PROBE_FIXTURE_SHA="$FAKE_SHA"
  export PROBE_FIXTURE_SHA

  one_fp="$time_dir/one.json"
  write_sources_file "$one_fp" "$(source_entry "slow-1" "$time_dir/remote-1")"
  t0="$(now_epoch)"
  run_probe "$one_fp" "$time_shim"
  t1="$(now_epoch)"
  baseline="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')"

  eight_entries=()
  time_i=1
  while [ "$time_i" -le 8 ]; do
    eight_entries+=("$(source_entry "slow-$time_i" "$time_dir/remote-$time_i")")
    time_i=$((time_i + 1))
  done
  eight_fp="$time_dir/eight.json"
  write_sources_file "$eight_fp" "${eight_entries[@]}"
  t0="$(now_epoch)"
  run_probe "$eight_fp" "$time_shim"
  t1="$(now_epoch)"
  elapsed8="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')"
  unset PROBE_FIXTURE_SHA

  results8="$(printf '%s' "$PROBE_OUT" | jq 'length' 2>/dev/null)"
  : "${results8:=0}"
  if [ "$results8" -ne 8 ]; then
    fail "wall clock: eight probes against a one-second remote finish in under four seconds" \
      "the run did not report eight results (reported: $results8) — timing is not meaningful"
  elif ! float_ge "$elapsed8" "4.0"; then
    pass "wall clock: eight probes against a one-second remote finish in under four seconds"
  else
    sequential_floor="$(awk -v b="$baseline" 'BEGIN { printf "%.2f", 0.75 * 8 * b }')"
    if float_ge "$elapsed8" "$sequential_floor"; then
      verdict="cost scales with the number of probes — this is one-at-a-time probing"
    else
      verdict="cost is well under the one-at-a-time figure — a loaded or slow machine, not a loss of concurrency"
    fi
    fail "wall clock: eight probes against a one-second remote finish in under four seconds" \
      "eight probes: ${elapsed8}s; one probe on this machine: ${baseline}s; one-at-a-time would be about $(awk -v b="$baseline" 'BEGIN { printf "%.2f", 8 * b }')s" \
      "$verdict"
  fi
fi

# ===========================================================================
echo
echo "── an unreachable source is reported in its own object, run exits 0 ──"
# ===========================================================================
# Four real bare repositories and one path that is not a repository, the
# bad one third so that file order and completion order cannot agree by
# accident: a nonexistent path fails in about a millisecond, so a run that
# reported results as they completed would surface it first.

iso_dir="$TMPROOT/isolation"
mkdir -p "$iso_dir"
iso_ok=1
iso_i=1
while [ "$iso_i" -le 4 ]; do
  if ! new_bare_repo "$iso_dir/work-$iso_i" "$iso_dir/bare-$iso_i.git"; then
    iso_ok=0
    break
  fi
  iso_i=$((iso_i + 1))
done

if [ "$iso_ok" -ne 1 ]; then
  fixture_error "could not build the four bare fixture repositories"
else
  iso_fp="$iso_dir/sources.json"
  write_sources_file "$iso_fp" \
    "$(source_entry "repo-a" "$iso_dir/bare-1.git")" \
    "$(source_entry "repo-b" "$iso_dir/bare-2.git")" \
    "$(source_entry "no-such-repo" "$iso_dir/nothing-here.git")" \
    "$(source_entry "repo-c" "$iso_dir/bare-3.git")" \
    "$(source_entry "repo-d" "$iso_dir/bare-4.git")"
  run_probe "$iso_fp"

  if [ "$PROBE_RC" -eq 0 ]; then
    pass "error isolation: the run exits 0 even though one of its five sources is unreachable"
  else
    fail "error isolation: the run exits 0 even though one of its five sources is unreachable" \
      "exit code: $PROBE_RC"
  fi

  if jq_check "$PROBE_OUT" '
      [.[].source_id]
      == ["repo-a", "repo-b", "no-such-repo", "repo-c", "repo-d"]
  '; then
    pass "error isolation: all five sources are reported, in file order, with the failing one in its own place"
  else
    fail "error isolation: all five sources are reported, in file order, with the failing one in its own place" \
      "stdout: ${PROBE_OUT:-<empty>}"
  fi

  if jq_check "$PROBE_OUT" '
      (first(.[] | select(.source_id == "no-such-repo"))) as $bad
      | $bad != null and $bad.state == "error" and $bad.live_sha == null
      and ($bad | has("error")) and ($bad.error | type == "string")
      and ($bad.error | length) > 0
  '; then
    pass "error isolation: a url git cannot reach is reported \"error\" with a non-empty diagnostic"
  else
    fail "error isolation: a url git cannot reach is reported \"error\" with a non-empty diagnostic" \
      "stdout: ${PROBE_OUT:-<empty>}"
  fi

  if jq_check "$PROBE_OUT" '
      [.[] | select(.source_id != "no-such-repo")] as $good
      | ($good | length) == 4
      and ($good | all(.state == "never_probed"))
      and ($good | all(.live_sha | type == "string" and (length == 40)))
      and ($good | all(has("error") | not))
  '; then
    pass "error isolation: the four reachable sources alongside the failing one report their own live sha, unaffected"
  else
    fail "error isolation: the four reachable sources alongside the failing one report their own live sha, unaffected" \
      "stdout: ${PROBE_OUT:-<empty>}"
  fi

  if jq_check "$PROBE_OUT" '
      all(
        (keys_unsorted | sort) as $k
        | if .state == "error"
          then $k == ["error", "live_sha", "recorded_sha", "source_id", "state"]
          else $k == ["live_sha", "recorded_sha", "source_id", "state"]
          end
      )
  '; then
    pass "object shape: every result carries source_id, state, recorded_sha and live_sha, and carries error only when it errored"
  else
    fail "object shape: every result carries source_id, state, recorded_sha and live_sha, and carries error only when it errored" \
      "stdout: ${PROBE_OUT:-<empty>}"
  fi
fi

# ===========================================================================
echo
echo "── a probe that exits 0 with no matching ref is an error too ──"
# ===========================================================================
# The second mechanism by which a probe fails. `git ls-remote` against a
# real repository and a branch that does not exist exits 0 and prints
# nothing; a run that only notices non-zero exits reports that source as a
# success with an empty sha.

empty_dir="$TMPROOT/empty-ref"
mkdir -p "$empty_dir"
if ! new_bare_repo "$empty_dir/work" "$empty_dir/bare.git"; then
  fixture_error "could not build the fixture repository for the missing-ref case"
else
  empty_fp="$empty_dir/sources.json"
  write_sources_file "$empty_fp" \
    "$(source_entry "missing-ref" "$empty_dir/bare.git" "no-such-branch")" \
    "$(source_entry "present-ref" "$empty_dir/bare.git" "main")"
  run_probe "$empty_fp"

  if jq_check "$PROBE_OUT" '
      (first(.[] | select(.source_id == "missing-ref"))) as $m
      | $m != null and $m.state == "error" and $m.live_sha == null
      and ($m | has("error")) and ($m.error | length) > 0
  '; then
    pass "error isolation: a ref that does not exist is an error, not a success carrying an empty sha"
  else
    fail "error isolation: a ref that does not exist is an error, not a success carrying an empty sha" \
      "stdout: ${PROBE_OUT:-<empty>}"
  fi

  if jq_check "$PROBE_OUT" '
      [.[].source_id] == ["missing-ref", "present-ref"]
      and ((first(.[] | select(.source_id == "present-ref"))) as $p
           | $p.state == "never_probed" and ($p.live_sha | length) == 40)
  '; then
    pass "error isolation: the source sharing a repository with a missing ref still reports its own live sha, in place"
  else
    fail "error isolation: the source sharing a repository with a missing ref still reports its own live sha, in place" \
      "stdout: ${PROBE_OUT:-<empty>}"
  fi
fi

# ===========================================================================
echo
echo "── a probe that raises is contained the same way a failing one is ──"
# ===========================================================================
# The third way a probe fails, and the only one whose containment is not
# free: an exception raised inside the probe before git is ever invoked.
# It is raised per source, from the input file, because a machine-level
# trick (removing git from PATH, making it non-executable) would break
# every probe at once and prove containment of nothing.
#
# Two entries trigger it by two different mechanisms — one carries no url
# at all, the other a url with a ref that is not a string — so a run that
# guards one attribute lookup rather than the probe as a whole is still
# caught. Each sits between healthy sources, which is the whole point: the
# assertion is that the neighbours survive, not merely that the run ends.

raise_dir="$TMPROOT/raising"
mkdir -p "$raise_dir"
if ! new_bare_repo "$raise_dir/work" "$raise_dir/bare.git"; then
  fixture_error "could not build the fixture repository for the raising-probe case"
else
  raise_fp="$raise_dir/sources.json"
  # Two malformed entries that are in scope by every filter the report
  # applies, and that the probe itself cannot get through.
  raise_no_url="$(jq -n '
    {id:"raise-no-url", kind:"git-managed", status:"confirmed", archived:false,
     lifecycle:{state:"reachable", last_checked:null, last_checked_sha:null,
                proposed_url:null},
     discovered_via:null}')"
  raise_bad_ref="$(jq -n --arg url "$raise_dir/bare.git" '
    {id:"raise-bad-ref", kind:"git-managed", url:$url, branch:7,
     status:"confirmed", archived:false,
     lifecycle:{state:"reachable", last_checked:null, last_checked_sha:null,
                proposed_url:null},
     discovered_via:null}')"
  write_sources_file "$raise_fp" \
    "$(source_entry "raise-ok-1" "$raise_dir/bare.git")" \
    "$raise_no_url" \
    "$(source_entry "raise-ok-2" "$raise_dir/bare.git")" \
    "$raise_bad_ref" \
    "$(source_entry "raise-ok-3" "$raise_dir/bare.git")"
  run_probe "$raise_fp"

  if [ "$PROBE_RC" -eq 0 ] && jq_check "$PROBE_OUT" '
      [.[].source_id]
      == ["raise-ok-1", "raise-no-url", "raise-ok-2", "raise-bad-ref",
          "raise-ok-3"]
  '; then
    pass "raised failure: a probe that raises still yields a complete report, in file order, and the run exits 0"
  else
    fail "raised failure: a probe that raises still yields a complete report, in file order, and the run exits 0" \
      "rc=$PROBE_RC stdout: ${PROBE_OUT:-<empty>}"
  fi

  if jq_check "$PROBE_OUT" '
      [.[] | select(.source_id == "raise-no-url" or .source_id == "raise-bad-ref")] as $bad
      | ($bad | length) == 2
      and ($bad | all(.state == "error"))
      and ($bad | all(.live_sha == null))
      and ($bad | all(has("error")))
      and ($bad | all(.error | type == "string" and (length > 0)))
  '; then
    pass "raised failure: each source whose probe raises is reported \"error\" in its own object with a non-empty diagnostic"
  else
    fail "raised failure: each source whose probe raises is reported \"error\" in its own object with a non-empty diagnostic" \
      "stdout: ${PROBE_OUT:-<empty>}"
  fi

  if jq_check "$PROBE_OUT" '
      [.[] | select(.source_id | startswith("raise-ok"))] as $good
      | ($good | length) == 3
      and ($good | all(.state == "never_probed"))
      and ($good | all(.live_sha | type == "string" and (length == 40)))
      and ($good | all(has("error") | not))
  '; then
    pass "raised failure: the healthy sources on either side of a raising one report their own live sha, none of them discarded"
  else
    fail "raised failure: the healthy sources on either side of a raising one report their own live sha, none of them discarded" \
      "stdout: ${PROBE_OUT:-<empty>}"
  fi
fi

# ===========================================================================
echo
echo "── ls-remote is the only git verb a probe run invokes ──"
# ===========================================================================

verb_dir="$TMPROOT/verbs"
verb_shim="$verb_dir/bin"
PROBE_ARGV_LOG="$verb_dir/argv.log"
real_git="$(command -v git)"
mkdir -p "$verb_dir"
: > "$PROBE_ARGV_LOG"
if [ -z "$real_git" ]; then
  fixture_error "git is not on PATH"
elif ! new_bare_repo "$verb_dir/work" "$verb_dir/bare.git"; then
  fixture_error "could not build the fixture repository for the git-verb case"
elif ! make_logging_git "$verb_shim" "$real_git"; then
  fixture_error "could not build the logging git shim"
else
  verb_fp="$verb_dir/sources.json"
  write_sources_file "$verb_fp" \
    "$(source_entry "verb-a" "$verb_dir/bare.git")" \
    "$(source_entry "verb-b" "$verb_dir/bare.git")" \
    "$(source_entry "verb-c" "$verb_dir/nothing-here.git")"
  export PROBE_ARGV_LOG
  run_probe "$verb_fp" "$verb_shim"
  unset PROBE_ARGV_LOG

  logged="$(wc -l < "$verb_dir/argv.log" | tr -d ' ')"
  other_verbs="$(awk '{ if ($1 != "ls-remote") print $1 }' "$verb_dir/argv.log" | LC_ALL=C sort -u | tr '\n' ' ')"
  if [ "$logged" -ge 1 ] && [ -z "$other_verbs" ]; then
    pass "git verbs: every git invocation a probe run makes is ls-remote, and it does make some"
  else
    fail "git verbs: every git invocation a probe run makes is ls-remote, and it does make some" \
      "git invocations recorded: $logged; verbs other than ls-remote: ${other_verbs:-<none>}"
  fi
fi

# ===========================================================================
echo
echo "── a probe run writes nothing ──"
# ===========================================================================
# "Writes nothing" is a universal claim and no test can cover every path on
# the machine. What is covered: the input file it was handed, the whole
# fixture tree that file points at (a new file, a deleted file and an
# edited file all move the fingerprint), and the working directory the run
# is started from. Real git throughout — the shimmed cases run somewhere
# else precisely so their own logs cannot be mistaken for a write.

ro_dir="$TMPROOT/readonly"
ro_cwd="$TMPROOT/readonly-cwd"
mkdir -p "$ro_dir" "$ro_cwd"
if ! new_bare_repo "$ro_dir/work" "$ro_dir/bare.git"; then
  fixture_error "could not build the fixture repository for the read-only case"
else
  ro_fp="$ro_dir/sources.json"
  write_sources_file "$ro_fp" \
    "$(source_entry "ro-a" "$ro_dir/bare.git")" \
    "$(source_entry "ro-b" "$ro_dir/bare.git" "main")" \
    "$(source_entry "ro-bad" "$ro_dir/nothing-here.git")"
  before="$(tree_fingerprint "$ro_dir")"
  (cd "$ro_cwd" && python3 "$PROBE_SCRIPT" "$ro_fp" >/dev/null 2>&1)
  after="$(tree_fingerprint "$ro_dir")"

  if [ "$before" = "$after" ]; then
    pass "read-only: the input file and the whole fixture tree it names are byte-identical after a run"
  else
    fail "read-only: the input file and the whole fixture tree it names are byte-identical after a run" \
      "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -20)"
  fi

  cwd_entries="$(find "$ro_cwd" -mindepth 1 | head -20)"
  if [ -z "$cwd_entries" ]; then
    pass "read-only: the run leaves nothing behind in the directory it was started from"
  else
    fail "read-only: the run leaves nothing behind in the directory it was started from" \
      "$cwd_entries"
  fi
fi

# ===========================================================================
echo
echo "── the HEAD-probe phase documents bounded, order-preserving concurrency ──"
# ===========================================================================
# Prose an agent reads and follows at run time, so the assertions are made
# against the document. The text is hand-wrapped Markdown: every phrase
# here is matched against a whitespace-normalized blob, never line by line,
# or a correct sentence that happens to wrap fails anyway.
#
# Each claim is checked as a pair of matches rather than one, and the pair
# is what makes it an assertion. The phase already discusses ordering (it
# promotes sources in a stated order), already names every source kind it
# dispatches on, and already contains the digits 10 inside version strings,
# so any single one of these tokens is satisfied by text that says nothing
# about concurrency at all. The first match of each pair is the claim; the
# second requires the claim to sit beside the thing it is about.
#
# The claim matches use `[^.]` runs, so a claim has to be made inside one
# sentence. The co-location matches use `.` runs, because a passage that
# states the concurrency and its consequence in two sentences is making the
# same point and a sentence-bounded window would reject it for punctuation.
# No repetition bound here goes above 250: BSD grep refuses a bounded
# repetition over 255 outright, and the refusal reads as a non-match, so a
# wider window would silently fail every one of these on a Mac while
# passing on GNU grep.
#
# The phase is kind-dispatched: it probes `git-managed` sources with
# ls-remote and `web-doc` sources with an HTTP HEAD. Only the first is at
# stake, so the concurrency claim has to name it, and the HTTP HEAD path
# has to be said to be unaffected — otherwise prose licensing concurrency
# for the whole phase reads as satisfying this.

if [ ! -f "$PHASES_MD" ]; then
  fixture_error "the drift-detection reference is not where this expects it: $PHASES_MD"
else
  phase_section="$(
    awk '
      /^### Phase 1/ { inside = 1; print; next }
      inside && /^(##|###) / { exit }
      inside { print }
    ' "$PHASES_MD"
  )"
  phase_norm="$(printf '%s' "$phase_section" | tr '\n' ' ' | tr -s '[:space:]' ' ')"

  # phase_has <extended-regex> — true when the normalized phase text
  # matches, case-insensitively.
  phase_has() {
    printf '%s' "$phase_norm" | grep -qiE "$1"
  }

  if [ -z "$phase_norm" ]; then
    fixture_error "could not extract the HEAD-probe phase section from the reference"
  else
    cap_claim='(up to|at most|no more than|bounded (at|to)|limit(ed)? to) (ten|10)[^.]{0,60}(at a time|concurrent|in parallel|in flight|worker|probe)|(ten|10) (concurrent|parallel)[^.]{0,40}(probe|request|worker)|(concurrent|parallel|in flight)[^.]{0,60}(up to|at most|no more than) (ten|10)'
    cap_kind='git-managed[^.]{0,120}(concurren|parallel|at a time|in flight)'
    cap_kind_rev='(concurren|parallel|at a time|in flight)[^.]{0,120}git-managed'
    if phase_has "$cap_claim" && { phase_has "$cap_kind" || phase_has "$cap_kind_rev"; }; then
      pass "HEAD-probe phase: the text permits the git-managed probes, by name, to run concurrently up to ten at a time"
    else
      fail "HEAD-probe phase: the text permits the git-managed probes, by name, to run concurrently up to ten at a time" \
        "either no sentence names a concurrency limit of ten, or the limit is stated without scoping it to git-managed"
    fi

    order_claim='(order|promot)[^.]{0,120}(unchanged|unaffected|preserved|the same)'
    order_conc='(concurren|parallel|at a time|in flight).{0,250}(order|promot)'
    order_conc_rev='(order|promot).{0,250}(concurren|parallel|at a time|in flight)'
    if phase_has "$order_claim" && { phase_has "$order_conc" || phase_has "$order_conc_rev"; }; then
      pass "HEAD-probe phase: the text states that running probes concurrently leaves the order results are promoted in unchanged"
    else
      fail "HEAD-probe phase: the text states that running probes concurrently leaves the order results are promoted in unchanged" \
        "the phase discusses ordering, but not that concurrency leaves it unchanged"
    fi

    isol_claim='(per[- ]source|each source|one source|a single source)[^.]{0,160}(isolat|unchanged|unaffected|only itself|does not (stop|abort|block|affect))|isolat[^.]{0,120}(per[- ]source|each source|unchanged)'
    isol_conc='(concurren|parallel|at a time|in flight).{0,250}(per[- ]source|isolat)'
    isol_conc_rev='(per[- ]source|isolat).{0,250}(concurren|parallel|at a time|in flight)'
    if phase_has "$isol_claim" && { phase_has "$isol_conc" || phase_has "$isol_conc_rev"; }; then
      pass "HEAD-probe phase: the text states that per-source isolation is unchanged under concurrency"
    else
      fail "HEAD-probe phase: the text states that per-source isolation is unchanged under concurrency" \
        "the phase does not say a failing source still affects only itself when probes run concurrently"
    fi

    # Sentence-bounded, unlike the three above: the paragraph that grants
    # concurrency ends on an "unchanged", and the phase's existing
    # `web-doc` guidance begins a couple of sentences later, so a
    # paragraph-width window reads the one as qualifying the other and the
    # assertion passes on text that never mentions the HTTP HEAD path.
    web_claim='web-doc[^.]{0,160}(unchanged|unaffected|not affected|no change|left alone|stays sequential|remains sequential|not run concurrently)'
    web_claim_rev='(unchanged|unaffected|not affected|no change|left alone|stays sequential|remains sequential|not run concurrently)[^.]{0,160}web-doc'
    web_head='web-doc[^.]{0,160}head|head[^.]{0,160}web-doc'
    if { phase_has "$web_claim" || phase_has "$web_claim_rev"; } && phase_has "$web_head"; then
      pass "HEAD-probe phase: the text states that the web-doc HTTP HEAD path is left as it is"
    else
      fail "HEAD-probe phase: the text states that the web-doc HTTP HEAD path is left as it is" \
        "nothing in the phase says the HTTP HEAD path is unaffected by the change to the git-managed one"
    fi
  fi
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
