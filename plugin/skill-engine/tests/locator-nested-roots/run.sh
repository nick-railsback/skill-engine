#!/usr/bin/env bash
# Feature-scoped test runner for the shared contextualizer locator —
# `shared/locator-block.md`'s root-resolution script, the surfaces that
# resolve an install root, and the router prose that describes them.
#
# Three kinds of cases:
#   - executed cases extract the locator's fenced bash into a scratch file
#     and run it against a scratch git repository the fixture builds itself
#     (real `git init`/`add`/`commit`, so a fixture can say what git does
#     and does not track)
#     with HOME pointed at an empty scratch home, so nothing about the
#     developer's machine or this repository's own git state can leak in.
#   - extraction cases pull the root-resolution assignment out on its own,
#     exactly the way `discover`'s cross-root collision guard pulls it out
#     at run time, and compare what it resolves against what the whole
#     script resolves.
#   - document-text cases assert structural facts about prose an agent
#     executes at runtime, by normalizing the text (hand-wrapped Markdown
#     splits phrases across lines) and matching against the normalized
#     blob — the convention this repo uses for behavior that is prose.
#
# LOCATOR_BLOCK_MD may point the executed and extraction cases at a scratch
# copy of the block, so a preserved property can be mutated and the
# assertion checked for the flip without touching the tracked file.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BLOCK_MD="${LOCATOR_BLOCK_MD:-$PLUGIN_ROOT/shared/locator-block.md}"
DOCTRINE="$PLUGIN_ROOT/tests/doctrine.sh"
SKILLS_DIR="$PLUGIN_ROOT/skills"
ROUTER_MD="$SKILLS_DIR/using-skill-engine/SKILL.md"
GUARD_MD="$SKILLS_DIR/discover/references/proposal-and-post-run.md"

pass_count=0
fail_count=0
created_dirs=()

cleanup_tmp() {
  local d
  for d in "${created_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && chmod -R u+w "$d" 2>/dev/null
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
  d="$(mktemp -d -t skill-engine-locator.XXXXXX)"
  # Canonicalize: on macOS mktemp hands back a /var symlink into
  # /private/var. A resolution that reports physical paths and one that
  # reports $PWD-relative paths then disagree by that symlink alone, which
  # is not a property under test.
  d="$(cd "$d" && pwd -P)"
  created_dirs+=("$d")
  printf '%s\n' "$d"
}

# ────────────────────────────────────────────────────────────────────────
# Fixture helpers
# ────────────────────────────────────────────────────────────────────────

# mk_ctx <parent-skills-dir> <slug> [nomarker] — a contextualizer
# directory. `research/.research-state.json` is the canonical setup-state
# marker; `nomarker` builds a lookalike that carries everything but it.
mk_ctx() {
  local skills_dir="$1" slug="$2" marker="${3:-marker}"
  mkdir -p "$skills_dir/$slug-context/research"
  printf -- '---\nname: %s-context\ndescription: x\n---\n\n# %s\n' \
    "$slug" "$slug" > "$skills_dir/$slug-context/SKILL.md"
  if [ "$marker" != "nomarker" ]; then
    printf '{"schema_version":1}\n' \
      > "$skills_dir/$slug-context/research/.research-state.json"
  fi
}

# git_q <repo> <args...> — git with the developer's global/system config
# and any commit signing kept out of the fixture.
git_q() {
  local repo="$1"; shift
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$repo" \
      -c user.name=fixture -c user.email=fixture@example.invalid \
      -c commit.gpgsign=false -c init.defaultBranch=main \
      "$@"
}

# build_scratch_repo — a real git repository with contextualizers spread
# across nesting depths, plus the shapes that must NOT be counted:
#   included: .claude/skills/a-context                       (repo root)
#             packages/billing/.claude/skills/b-context      (depth 4)
#             services/x/y/.claude/skills/c-context          (depth 6)
#             ignored/…/i-context          (git check-ignore reports it —
#                                            counted anyway: whether git
#                                            tracks a directory says
#                                            nothing about whether a
#                                            contextualizer is installed
#                                            in it, and the sibling
#                                            `cwd independence` section
#                                            is what that rule exists for)
#   excluded: node_modules/pkg/…/n-context  (tracked, NOT gitignored — so
#                                            only a node_modules skip
#                                            excludes it)
#             .git/stash/…/g-context      (inside the git directory)
#             packages/ui/…/u-context     (no .research-state.json marker)
#             one/two/three/four/…/d-context  (one level past the bound)
build_scratch_repo() {
  local repo="$1"
  git_q "$repo" init -q

  printf 'ignored/\n' > "$repo/.gitignore"

  mk_ctx "$repo/.claude/skills" a
  mk_ctx "$repo/packages/billing/.claude/skills" b
  mk_ctx "$repo/services/x/y/.claude/skills" c

  mk_ctx "$repo/ignored/.claude/skills" i
  mk_ctx "$repo/node_modules/pkg/.claude/skills" n
  mk_ctx "$repo/.git/stash/.claude/skills" g
  mk_ctx "$repo/packages/ui/.claude/skills" u nomarker
  mk_ctx "$repo/one/two/three/four/.claude/skills" d

  # One marker-carrying decoy per pruned build/vendor directory name, so
  # the prune list is asserted by name rather than by however many names
  # the expression happens to carry. Each is at a depth the walk would
  # otherwise reach.
  local pruned
  for pruned in $PRUNED_DIR_NAMES; do
    mk_ctx "$repo/$pruned/.claude/skills" "p${pruned}"
  done

  printf 'fixture\n' > "$repo/README.md"
  git_q "$repo" add -A -f -- . ':!ignored' >/dev/null 2>&1
  git_q "$repo" commit -q -m fixture >/dev/null 2>&1
}

# ────────────────────────────────────────────────────────────────────────
# The locator script under test
# ────────────────────────────────────────────────────────────────────────

# extract_fence — the first fenced bash block of the locator document.
extract_fence() {
  awk '/^```bash$/ && !f { f = 1; next }
       f && /^```$/ { exit }
       f { print }' "$BLOCK_MD"
}

# PRUNED_DIR_NAMES — the build/vendor directory names the walk prunes,
# read out of the locator's own `-prune` expression rather than
# transcribed here. A name added there without a decoy in the fixture
# would otherwise go untested, and a decoy for a name the expression
# dropped fails loudly instead of quietly passing. `.git` and
# `node_modules` carry their own named assertions and are left out of
# this sweep.
pruned_dir_names() {
  # The parenthesized prune group only. Scanning from the `-prune` token
  # to the `-print` one instead would also sweep up the `-name
  # "${name:-*}-context"` that selects the hits, and a fixture decoy
  # built from that reads as a contextualizer rather than as a decoy.
  extract_fence \
    | tr '\n' ' ' \
    | sed -n 's/.*\\( \(.*\) \\) -prune.*/\1/p' \
    | tr ' ' '\n' \
    | awk 'prev == "-name" { print } { prev = $0 }' \
    | grep -v -x -e '.git' -e 'node_modules' \
    | LC_ALL=C sort -u
}

# prep_script <dest> <name> <echo-ctx-root: yes|no> — the locator script
# with its `<name>` placeholder substituted the way a calling skill
# substitutes it. `yes` appends a line printing the contract variable
# CTX_ROOT, so a resolution that ends in CTX_ROOT is observable; leave it
# off for runs whose whole point is what the script itself prints.
prep_script() {
  local dest="$1" name="$2" echo_root="$3"
  extract_fence | sed "s|^name=\"<name>\"$|name=\"$name\"|" > "$dest"
  if ! grep -q "^name=\"$name\"$" "$dest"; then
    return 1
  fi
  if [ "$echo_root" = yes ]; then
    printf '\nprintf %s\\\\n "$CTX_ROOT"\n' '%s' >> "$dest"
  fi
  return 0
}

# run_script <script> <cwd> [argv...] — run the locator from <cwd> with a
# scratch HOME. Prints combined stdout+stderr and exits with the script's
# own status, so a caller capturing the output in a command substitution
# still reads the real exit code from $?.
run_script() {
  local script="$1" cwd="$2"
  shift 2
  local out rc
  out="$(cd "$cwd" && HOME="$SCRATCH_HOME" LC_ALL=C bash "$script" "$@" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

# window <marker> <before> <after> — reads a normalized blob on stdin and
# prints, one per line, the slice of text around each occurrence of a
# literal marker. Windowing is done here rather than with a bounded
# regex repetition because that repetition has a low ceiling on BSD grep.
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

# abs_lines — keep only the absolute paths out of a run's output, so a
# diagnostic sentence printed alongside them does not join the set.
abs_lines() {
  grep '^/' || true
}

# ────────────────────────────────────────────────────────────────────────
# Shared scratch state
# ────────────────────────────────────────────────────────────────────────

SCRATCH_HOME="$(mktmp)"
WORK="$(mktmp)"
REPO="$WORK/repo"
mkdir -p "$REPO"

fence_ok=1
[ -s "$BLOCK_MD" ] || fence_ok=0
if [ "$fence_ok" -eq 1 ] && [ -z "$(extract_fence)" ]; then
  fence_ok=0
fi
if [ "$fence_ok" -eq 0 ]; then
  fixture_error "could not extract a fenced bash block from $BLOCK_MD"
fi

if ! command -v git >/dev/null 2>&1; then
  fixture_error "git is not available; the scratch repository cannot be built"
  fence_ok=0
fi

PRUNED_DIR_NAMES=""
if [ "$fence_ok" -eq 1 ]; then
  PRUNED_DIR_NAMES="$(pruned_dir_names)"
  if [ -z "$PRUNED_DIR_NAMES" ]; then
    fixture_error "the locator's -prune expression names no build/vendor directory beyond .git and node_modules"
  fi
  build_scratch_repo "$REPO"
  if ! GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      git -C "$REPO" check-ignore -q ignored 2>/dev/null; then
    fixture_error "the scratch repository's .gitignore is not in force (check-ignore does not report the ignored directory)"
    fence_ok=0
  fi
fi

SCRIPT_ALL="$WORK/locator-all.sh"
SCRIPT_BARE="$WORK/locator-bare.sh"
SCRIPT_BARE_ECHO="$WORK/locator-bare-echo.sh"
SCRIPT_B="$WORK/locator-b.sh"

if [ "$fence_ok" -eq 1 ]; then
  if ! prep_script "$SCRIPT_ALL" "" no \
    || ! prep_script "$SCRIPT_BARE" "" no \
    || ! prep_script "$SCRIPT_BARE_ECHO" "" yes \
    || ! prep_script "$SCRIPT_B" "b" yes; then
    fixture_error "the script's name placeholder could not be substituted — its \`name=\"<name>\"\` line has changed shape"
    fence_ok=0
  fi
fi

# ════════════════════════════════════════════════════════════════════════
# nested discovery — contextualizers that sit beside the code they
# describe, anywhere under the repository, are found
# ════════════════════════════════════════════════════════════════════════

expected_nested="$REPO/.claude/skills/a-context
$REPO/ignored/.claude/skills/i-context
$REPO/packages/billing/.claude/skills/b-context
$REPO/services/x/y/.claude/skills/c-context"
expected_nested="$(printf '%s\n' "$expected_nested" | LC_ALL=C sort)"

all_out=""
all_rc=1
all_paths=""
if [ "$fence_ok" -eq 1 ]; then
  all_out="$(run_script "$SCRIPT_ALL" "$REPO" --all)"
  all_rc=$?
  all_paths="$(printf '%s\n' "$all_out" | abs_lines)"
fi

if [ "$fence_ok" -eq 1 ]; then
  ok=1
  [ "$all_rc" -eq 0 ] || ok=0
  [ "$(printf '%s\n' "$all_paths" | grep -c . || true)" -eq 4 ] || ok=0
  [ "$(printf '%s\n' "$all_paths" | LC_ALL=C sort)" = "$expected_nested" ] || ok=0
  report "$ok" "nested discovery: contextualizers at the repo root, at packages/billing/, at services/x/y/ and under a gitignored directory are all located"

  # Every line an absolute path, and the whole listing already in sorted
  # order as printed — not merely sortable. A duplicate (the repo-root
  # contextualizer is reachable both as a fixed root and by the nested
  # walk) shows up here as a count mismatch above.
  ok=1
  [ -n "$all_paths" ] || ok=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in /*) ;; *) ok=0 ;; esac
  done <<< "$all_paths"
  [ "$all_paths" = "$(printf '%s\n' "$all_paths" | LC_ALL=C sort)" ] || ok=0
  [ "$all_paths" = "$(printf '%s\n' "$all_paths" | LC_ALL=C sort -u)" ] || ok=0
  report "$ok" "--all enumeration: one absolute path per line, sorted, with no path listed twice"

  ok=1
  [ "$all_rc" -eq 0 ] || ok=0
  report "$ok" "--all enumeration: exits 0 instead of listing and exiting non-zero"

  # ── inputs that must be rejected. Each pairs the rejection with a
  # positive sibling, so the assertion cannot pass merely because nothing
  # was discovered at all.
  ok=1
  printf '%s\n' "$all_paths" | grep -qF "$REPO/packages/billing/.claude/skills/b-context" || ok=0
  printf '%s\n' "$all_paths" | grep -q '/\.git/' && ok=0
  report "$ok" "nested discovery: a contextualizer-shaped directory inside .git/ is not counted"

  ok=1
  printf '%s\n' "$all_paths" | grep -qF "$REPO/packages/billing/.claude/skills/b-context" || ok=0
  printf '%s\n' "$all_paths" | grep -q 'node_modules' && ok=0
  report "$ok" "nested discovery: a tracked, non-ignored contextualizer under node_modules/ is not counted"

  # The walk reaches six levels of the whole working repository and runs
  # on the hot path of every engine surface, read-only ones included. The
  # names below are where a large repository keeps the files nobody
  # installs a contextualizer into, and skipping them is the difference
  # between a stat storm and a bounded scan on the monorepo topology the
  # fleet layer is aimed at.
  ok=1
  printf '%s\n' "$all_paths" | grep -qF "$REPO/packages/billing/.claude/skills/b-context" || ok=0
  while IFS= read -r pruned; do
    [ -n "$pruned" ] || continue
    printf '%s\n' "$all_paths" | grep -qF "$REPO/$pruned/" && ok=0
  done <<< "$PRUNED_DIR_NAMES"
  report "$ok" "nested discovery: a marker-carrying contextualizer under each pruned build/vendor directory is not counted"

  ok=1
  printf '%s\n' "$all_paths" | grep -qF "$REPO/packages/billing/.claude/skills/b-context" || ok=0
  printf '%s\n' "$all_paths" | grep -qF 'u-context' && ok=0
  report "$ok" "nested discovery: a directory without the research/.research-state.json marker is not counted"

  ok=1
  printf '%s\n' "$all_paths" | grep -qF "$REPO/services/x/y/.claude/skills/c-context" || ok=0
  printf '%s\n' "$all_paths" | grep -qF 'd-context' && ok=0
  report "$ok" "nested discovery: the walk is bounded — a contextualizer one level past the deepest included fixture is not counted"

  # ── the fixed roots are enumerated alongside the nested ones.
  home_repo="$(mktmp)"
  mkdir -p "$home_repo"
  mk_ctx "$home_repo/.claude/skills" h
  saved_home="$SCRATCH_HOME"
  SCRATCH_HOME="$home_repo"
  all_out_h="$(run_script "$SCRIPT_ALL" "$REPO" --all)"
  all_rc_h=$?
  SCRATCH_HOME="$saved_home"
  all_paths_h="$(printf '%s\n' "$all_out_h" | abs_lines)"
  expected_h="$(printf '%s\n%s\n' "$expected_nested" "$home_repo/.claude/skills/h-context" | LC_ALL=C sort)"
  ok=1
  [ "$all_rc_h" -eq 0 ] || ok=0
  [ "$(printf '%s\n' "$all_paths_h" | LC_ALL=C sort)" = "$expected_h" ] || ok=0
  [ "$all_paths_h" = "$(printf '%s\n' "$all_paths_h" | LC_ALL=C sort)" ] || ok=0
  report "$ok" "--all enumeration: a user-level contextualizer and the nested ones appear in one sorted listing"

  # ── a named nested contextualizer resolves to its nested path.
  b_out="$(run_script "$SCRIPT_B" "$REPO")"
  b_rc=$?
  ok=1
  [ "$b_rc" -eq 0 ] || ok=0
  [ "$(printf '%s\n' "$b_out" | abs_lines | tail -n1)" = "$REPO/packages/billing/.claude/skills/b-context" ] || ok=0
  report "$ok" "named lookup: a name that matches only a nested contextualizer resolves to its nested path"

  # ── with several found and no name and no --all, the list-and-exit
  # behavior is what remains.
  bare_out="$(run_script "$SCRIPT_BARE" "$REPO")"
  bare_rc=$?
  bare_paths="$(printf '%s\n' "$bare_out" | abs_lines)"
  ok=1
  [ "$bare_rc" -ne 0 ] || ok=0
  [ "$(printf '%s\n' "$bare_paths" | LC_ALL=C sort)" = "$expected_nested" ] || ok=0
  report "$ok" "nested discovery: several found across nested roots, none named and no enumeration requested, still lists them and exits non-zero"
fi

# ════════════════════════════════════════════════════════════════════════
# cwd independence — the same repository enumerates the same set from
# every directory inside it, including when `.claude/` is gitignored
# ════════════════════════════════════════════════════════════════════════

# `.claude/` in `.gitignore` is an ordinary setup: it is how a team keeps
# per-developer agent config out of the repository. The fixture above
# cannot exercise what that does to the enumeration — its ignored decoy is
# a directory named `ignored/`, so an ignore filter only ever skips a
# contextualizer that was never wanted. Under a gitignored `.claude/` the
# same filter changes the *answer*, and asymmetrically: the fixed-root arm
# resolves `$PWD/.claude/skills` with no filter at all, so which
# contextualizers exist depends on which directory the session happens to
# be sitting in.

if [ "$fence_ok" -eq 1 ]; then
  IGN_REPO="$WORK/ignored-claude-repo"
  mkdir -p "$IGN_REPO"
  git_q "$IGN_REPO" init -q
  printf '.claude/\n' > "$IGN_REPO/.gitignore"
  mk_ctx "$IGN_REPO/.claude/skills" root
  mk_ctx "$IGN_REPO/packages/billing/.claude/skills" billing
  printf 'fixture\n' > "$IGN_REPO/README.md"
  git_q "$IGN_REPO" add -A >/dev/null 2>&1
  git_q "$IGN_REPO" commit -q -m fixture >/dev/null 2>&1

  ign_fixture_ok=1
  if ! GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      git -C "$IGN_REPO" check-ignore -q .claude 2>/dev/null; then
    fixture_error "the gitignored-.claude fixture's .gitignore is not in force"
    ign_fixture_ok=0
  fi

  if [ "$ign_fixture_ok" -eq 1 ]; then
    ign_expected="$(printf '%s\n%s\n' \
      "$IGN_REPO/.claude/skills/root-context" \
      "$IGN_REPO/packages/billing/.claude/skills/billing-context" \
      | LC_ALL=C sort)"

    ign_from_root="$(run_script "$SCRIPT_ALL" "$IGN_REPO" --all | abs_lines)"
    ign_from_sub="$(run_script "$SCRIPT_ALL" "$IGN_REPO/packages/billing" --all | abs_lines)"

    ok=1
    [ "$(printf '%s\n' "$ign_from_root" | LC_ALL=C sort)" = "$ign_expected" ] || ok=0
    report "$ok" "cwd independence: with \`.claude/\` gitignored, an enumeration from the repository root finds both the root and the nested contextualizer"

    ok=1
    [ "$(printf '%s\n' "$ign_from_sub" | LC_ALL=C sort)" = "$ign_expected" ] || ok=0
    report "$ok" "cwd independence: with \`.claude/\` gitignored, an enumeration from a package subdirectory finds the same two"

    ok=1
    [ "$(printf '%s\n' "$ign_from_root" | LC_ALL=C sort)" = "$(printf '%s\n' "$ign_from_sub" | LC_ALL=C sort)" ] || ok=0
    report "$ok" "cwd independence: the set a fleet sweep operates on does not change with the invocation directory"
  fi
fi

# ════════════════════════════════════════════════════════════════════════
# symlinked installs — the distribution recipe's second shape: a clone
# kept elsewhere, with one symlink per contextualizer into a root
# ════════════════════════════════════════════════════════════════════════

# `find` defaults to -P, so a symlink pointing at a directory has type `l`,
# not `d`. A locator that asks only for `-type d` sees none of the
# contextualizers installed the way `docs/recipes/distribute.md` recommends
# for a repository holding anything besides contextualizers.

if [ "$fence_ok" -eq 1 ]; then
  LINK_CLONE="$WORK/clone"
  LINK_HOME="$(mktmp)"
  LINK_REPO="$(mktmp)"
  mkdir -p "$LINK_CLONE" "$LINK_HOME/.claude/skills" "$LINK_REPO"
  git_q "$LINK_REPO" init -q
  printf 'fixture\n' > "$LINK_REPO/README.md"

  # The working copy, kept wherever repositories are kept.
  mk_ctx "$LINK_CLONE" linked
  mk_ctx "$LINK_CLONE" nested-linked
  # One symlink per contextualizer into the user-level root, plus one left
  # dangling by a clone that moved.
  ln -s "$LINK_CLONE/linked-context" "$LINK_HOME/.claude/skills/linked-context"
  ln -s "$LINK_CLONE/gone-context"   "$LINK_HOME/.claude/skills/gone-context"
  # And the same gesture at the project level, beside the slice it describes.
  mkdir -p "$LINK_REPO/packages/billing/.claude/skills"
  ln -s "$LINK_CLONE/nested-linked-context" \
    "$LINK_REPO/packages/billing/.claude/skills/nested-linked-context"

  saved_home="$SCRATCH_HOME"
  SCRATCH_HOME="$LINK_HOME"
  link_out="$(run_script "$SCRIPT_ALL" "$LINK_REPO" --all)"
  link_rc=$?
  SCRATCH_HOME="$saved_home"
  link_paths="$(printf '%s\n' "$link_out" | abs_lines)"

  ok=1
  [ "$link_rc" -eq 0 ] || ok=0
  printf '%s\n' "$link_paths" \
    | grep -qF "$LINK_HOME/.claude/skills/linked-context" || ok=0
  report "$ok" "symlinked installs: a user-level contextualizer installed as a symlink into the root is enumerated"

  ok=1
  printf '%s\n' "$link_paths" \
    | grep -qF "$LINK_REPO/packages/billing/.claude/skills/nested-linked-context" || ok=0
  report "$ok" "symlinked installs: a nested project-level contextualizer installed as a symlink is enumerated"

  ok=1
  printf '%s\n' "$link_paths" | grep -qF 'gone-context' && ok=0
  report "$ok" "symlinked installs: a symlink left dangling by a moved or deleted clone is not counted as an install"

  # And the named path, not only the enumeration: every workflow that
  # resolves a single CTX_ROOT goes through the same find.
  link_named_script="$WORK/locator-linked.sh"
  if prep_script "$link_named_script" "linked" yes; then
    SCRATCH_HOME="$LINK_HOME"
    link_named_out="$(run_script "$link_named_script" "$LINK_REPO")"
    link_named_rc=$?
    SCRATCH_HOME="$saved_home"
    ok=1
    [ "$link_named_rc" -eq 0 ] || ok=0
    [ "$(printf '%s\n' "$link_named_out" | abs_lines | tail -n1)" \
      = "$LINK_HOME/.claude/skills/linked-context" ] || ok=0
    report "$ok" "symlinked installs: a named lookup resolves CTX_ROOT to the symlink path"
  else
    fixture_error "the locator's name placeholder could not be substituted for the symlink case"
  fi
fi

# ════════════════════════════════════════════════════════════════════════
# named lookup preserved — behavior for the three fixed roots, the
# single-match case, and the zero-match diagnostics is untouched
# ════════════════════════════════════════════════════════════════════════

# The zero-match sentences are not retyped here: they are read out of the
# check that pins them, so the script's diagnostics and that check's pinned
# text cannot drift apart no matter how the roots are worded.
sentence_1_raw="$(sed -n "s/^locator_sentence_1='\(.*\)'$/\1/p" "$DOCTRINE" | head -n1)"
sentence_2_raw="$(sed -n "s/^locator_sentence_2='\(.*\)'$/\1/p" "$DOCTRINE" | head -n1)"

if [ -z "$sentence_1_raw" ] || [ -z "$sentence_2_raw" ]; then
  fixture_error "could not read the two pinned zero-match sentences out of $DOCTRINE"
elif [ "$fence_ok" -eq 1 ]; then
  empty_repo="$(mktmp)"
  empty_home="$(mktmp)"
  mkdir -p "$empty_repo" "$empty_home"
  saved_home="$SCRATCH_HOME"
  SCRATCH_HOME="$empty_home"

  zero_named_out="$(run_script "$SCRIPT_B" "$empty_repo")"
  zero_named_rc=$?
  zero_bare_out="$(run_script "$SCRIPT_BARE" "$empty_repo")"
  zero_bare_rc=$?
  SCRATCH_HOME="$saved_home"

  expected_s1="${sentence_1_raw//\$\{name\}/b}"
  ok=1
  [ "$zero_named_rc" -eq 1 ] || ok=0
  printf '%s\n' "$zero_named_out" | grep -qF -- "$expected_s1" || ok=0
  report "$ok" "zero-match diagnostics preserved: a named lookup that matches nothing exits 1 with the sentence the doctrine check pins"

  ok=1
  [ "$zero_bare_rc" -eq 1 ] || ok=0
  printf '%s\n' "$zero_bare_out" | grep -qF -- "$sentence_2_raw" || ok=0
  report "$ok" "zero-match diagnostics preserved: a bare lookup that matches nothing exits 1 with the sentence the doctrine check pins"
fi

if [ "$fence_ok" -eq 1 ]; then
  # Named lookup under each of the three fixed roots, one at a time.
  for level in user local-user project; do
    lvl_home="$(mktmp)"
    lvl_cwd="$(mktmp)"
    mkdir -p "$lvl_home" "$lvl_cwd"
    case "$level" in
      user)       mk_ctx "$lvl_home/.claude/skills" b
                  want="$lvl_home/.claude/skills/b-context" ;;
      local-user) mk_ctx "$lvl_home/.claude/local/skills" b
                  want="$lvl_home/.claude/local/skills/b-context" ;;
      project)    mk_ctx "$lvl_cwd/.claude/skills" b
                  want="$lvl_cwd/.claude/skills/b-context" ;;
    esac
    saved_home="$SCRATCH_HOME"
    SCRATCH_HOME="$lvl_home"
    lvl_out="$(run_script "$SCRIPT_B" "$lvl_cwd")"
    lvl_rc=$?
    SCRATCH_HOME="$saved_home"
    ok=1
    [ "$lvl_rc" -eq 0 ] || ok=0
    [ "$(printf '%s\n' "$lvl_out" | abs_lines | tail -n1)" = "$want" ] || ok=0
    report "$ok" "named lookup preserved: a contextualizer installed at the $level level resolves to its own path, exit 0"

    # The project-level case above ran in a directory that is not a git
    # repository at all. A resolution that consults git without guarding
    # for that regresses here, and nowhere else.
    if [ "$level" = project ]; then
      ok=1
      [ "$lvl_rc" -eq 0 ] || ok=0
      printf '%s\n' "$lvl_out" | grep -qi 'not a git repository' && ok=0
      report "$ok" "named lookup preserved: resolution in a working directory that is not a git repository still succeeds, with no git diagnostics"
    fi
  done

  # Single match, no name: resolves rather than listing.
  one_home="$(mktmp)"
  one_cwd="$(mktmp)"
  mkdir -p "$one_home" "$one_cwd"
  mk_ctx "$one_cwd/.claude/skills" solo
  saved_home="$SCRATCH_HOME"
  SCRATCH_HOME="$one_home"
  one_out="$(run_script "$SCRIPT_BARE_ECHO" "$one_cwd")"
  one_rc=$?
  SCRATCH_HOME="$saved_home"
  ok=1
  [ "$one_rc" -eq 0 ] || ok=0
  [ "$(printf '%s\n' "$one_out" | abs_lines | tail -n1)" = "$one_cwd/.claude/skills/solo-context" ] || ok=0
  report "$ok" "single-match preserved: exactly one contextualizer and no name given resolves it and exits 0"

  # Same slug at two levels: the search order decides, and the search
  # order is not alphabetical order.
  dup_home="$(mktmp)"
  dup_cwd="$(mktmp)"
  mkdir -p "$dup_home" "$dup_cwd"
  mk_ctx "$dup_home/.claude/skills" b
  mk_ctx "$dup_cwd/.claude/skills" b
  saved_home="$SCRATCH_HOME"
  SCRATCH_HOME="$dup_home"
  dup_out="$(run_script "$SCRIPT_B" "$dup_cwd")"
  dup_rc=$?
  SCRATCH_HOME="$saved_home"
  ok=1
  [ "$dup_rc" -eq 0 ] || ok=0
  [ "$(printf '%s\n' "$dup_out" | abs_lines | tail -n1)" = "$dup_home/.claude/skills/b-context" ] || ok=0
  report "$ok" "search order preserved: the same slug installed at the user and project levels resolves to the user-level copy"

  # Two contextualizers under fixed roots only, no name: list and exit.
  two_home="$(mktmp)"
  two_cwd="$(mktmp)"
  mkdir -p "$two_home" "$two_cwd"
  mk_ctx "$two_home/.claude/skills" alpha
  mk_ctx "$two_cwd/.claude/skills" beta
  saved_home="$SCRATCH_HOME"
  SCRATCH_HOME="$two_home"
  two_out="$(run_script "$SCRIPT_BARE" "$two_cwd")"
  two_rc=$?
  SCRATCH_HOME="$saved_home"
  two_paths="$(printf '%s\n' "$two_out" | abs_lines | LC_ALL=C sort)"
  two_want="$(printf '%s\n%s\n' "$two_home/.claude/skills/alpha-context" "$two_cwd/.claude/skills/beta-context" | LC_ALL=C sort)"
  ok=1
  [ "$two_rc" -eq 1 ] || ok=0
  [ "$two_paths" = "$two_want" ] || ok=0
  printf '%s\n' "$two_out" | grep -qi 'rerun naming one' || ok=0
  report "$ok" "list-and-exit preserved: two contextualizers under the fixed roots and no name lists both, with the rerun instruction, exit 1"
fi

# ════════════════════════════════════════════════════════════════════════
# assignment extractable — the root-resolution assignment resolves the
# same set on its own as it does inside the whole script, because a
# consumer outside this file pulls it out and evaluates it at run time
# ════════════════════════════════════════════════════════════════════════

# The extraction command is not reinvented here: it is read out of the
# consumer that performs it, so a change to the assignment's shape that
# breaks that consumer breaks this assertion too.
guard_extract_cmd="$(grep -F 'ctx_roots=\$\($' "$GUARD_MD" | grep -F 'awk' | head -n1)"

if [ -z "$guard_extract_cmd" ]; then
  fixture_error "could not find the run-time extraction command in $GUARD_MD"
elif [ "$fence_ok" -eq 1 ]; then
  # Reproduce the consumer's extraction verbatim, against the document
  # under test, and evaluate it with only `name` set — the state the
  # consumer has when it evaluates it.
  eval_fragment() { # <name> <cwd> -> resolved paths, one per line
    local frag_name="$1" frag_cwd="$2"
    local awk_prog='/^ctx_roots=\$\($/{f=1} f{print} f&&/^\)$/{exit}'
    ( cd "$frag_cwd" && HOME="$SCRATCH_HOME" LC_ALL=C BLOCK="$BLOCK_MD" \
        AWK_PROG="$awk_prog" name="$frag_name" bash -c '
          eval "$(awk "$AWK_PROG" "$BLOCK")"
          printf "%s\n" "$ctx_roots"
        ' 2>&1 )
  }

  # A named invocation whose match sits under a fixed root: the fragment
  # has to actually resolve something here, so the comparison is not
  # satisfied by two empty sets.
  frag_home="$(mktmp)"
  frag_cwd="$(mktmp)"
  mkdir -p "$frag_home" "$frag_cwd"
  mk_ctx "$frag_home/.claude/skills" b
  saved_home="$SCRATCH_HOME"
  SCRATCH_HOME="$frag_home"
  frag_fixed="$(eval_fragment b "$frag_cwd" | abs_lines | LC_ALL=C sort)"
  whole_fixed="$(run_script "$SCRIPT_B" "$frag_cwd" | abs_lines | LC_ALL=C sort)"
  SCRATCH_HOME="$saved_home"
  ok=1
  [ "$frag_fixed" = "$frag_home/.claude/skills/b-context" ] || ok=0
  [ "$frag_fixed" = "$whole_fixed" ] || ok=0
  report "$ok" "assignment extractable: pulled out on its own and evaluated with only a name set, it resolves exactly what the whole script resolves for that name"

  # The same comparison in the repository that has contextualizers beside
  # the code they describe: whatever the whole script resolves for a name,
  # the fragment resolves on its own.
  frag_named="$(eval_fragment b "$REPO" | abs_lines | LC_ALL=C sort)"
  whole_named="$(run_script "$SCRIPT_B" "$REPO" | abs_lines | LC_ALL=C sort)"
  ok=1
  [ "$frag_named" = "$whole_named" ] || ok=0
  report "$ok" "assignment extractable: a named invocation in a repository with contextualizers beside the code resolves the same set from the fragment as from the whole script"

  frag_bare="$(eval_fragment "" "$REPO" | abs_lines | LC_ALL=C sort)"
  whole_bare="$(run_script "$SCRIPT_BARE_ECHO" "$REPO" | abs_lines | LC_ALL=C sort)"
  ok=1
  [ -n "$frag_bare" ] || ok=0
  [ "$frag_bare" = "$whole_bare" ] || ok=0
  [ "$frag_bare" = "$(printf '%s\n' "$frag_bare" | LC_ALL=C sort -u)" ] || ok=0
  report "$ok" "assignment extractable: pulled out on its own for a bare invocation, it resolves exactly the set the whole script resolves"
fi

# ════════════════════════════════════════════════════════════════════════
# document text — one definition, and prose that matches it
# ════════════════════════════════════════════════════════════════════════

# normalize — collapse the document to a single line with runs of
# whitespace squeezed, so a phrase hand-wrapped across two lines still
# matches as one phrase.
normalize() {
  tr '\n' ' ' < "$1" | tr -s '[:space:]' ' '
}

# The two sentences the doctrine check pins are the script's own
# diagnostics: whatever they say about roots, the script must say the
# same, so the pin cannot survive a root change as stale text.
if [ -n "$sentence_1_raw" ] && [ -n "$sentence_2_raw" ]; then
  ok=1
  grep -qF -- "$sentence_1_raw" "$BLOCK_MD" || ok=0
  grep -qF -- "$sentence_2_raw" "$BLOCK_MD" || ok=0
  report "$ok" "pinned sentences move with the script: both sentences the doctrine check greps for appear verbatim in the shared definition"
fi

# The shared definition's own prose must not name a fixed set of consumers
# — an enumeration there is a second place to keep in sync every time a
# skill starts or stops running it.
block_prose="$(awk '/^```/ { f = !f; next } !f { print }' "$BLOCK_MD" | tr -s '[:space:]' ' ')"
consumer_hits=0
for slug in discover refresh status self-audit new-reference review using-skill-engine; do
  case "$block_prose" in
    *"\`$slug\`"*) consumer_hits=$((consumer_hits + 1)) ;;
  esac
done
ok=1
[ "$consumer_hits" -ge 3 ] && ok=0
report "$ok" "one definition: the shared definition's prose does not name a fixed set of consuming skills"

# No other surface resolves an install root by naming a root set of its
# own and walking it. A passage that lists install destinations without
# walking them is a different claim and is not flagged: the window must
# name all three roots AND carry a traversal.
scan_hits=""
while IFS= read -r md; do
  case "$md" in
    "$SCRIPT_DIR"/*) continue ;;
  esac
  blob="$(normalize "$md")"
  while IFS= read -r win; do
    [ -n "$win" ] || continue
    printf '%s' "$win" | grep -qE '(~|\$HOME|\$\{HOME\})/\.claude/skills' || continue
    printf '%s' "$win" | grep -qE '(<repo>|\$PWD|\$\{PWD\})/\.claude/skills' || continue
    printf '%s' "$win" | grep -qE 'for root in|find "\$|[Ii]terat|[Ww]alk|[Ll]oop|first match wins|each of the three' || continue
    scan_hits="$scan_hits
${md#"$PLUGIN_ROOT"/}"
  done < <(printf '%s' "$blob" | window 'local/skills' 260 260)
done < <(find "$SKILLS_DIR" -type f -name '*.md' | LC_ALL=C sort)

scan_hits="$(printf '%s\n' "$scan_hits" | grep -v '^$' | LC_ALL=C sort -u)"
ok=1
[ -n "$scan_hits" ] && ok=0
report "$ok" "one definition: no skill surface resolves an install root by naming a root set of its own and walking it"
if [ -n "$scan_hits" ]; then
  printf '%s\n' "$scan_hits" | sed 's|^|          |'
fi

# ════════════════════════════════════════════════════════════════════════
# router prose — what the entry-point skill tells the agent about
# several installed contextualizers, and about where they live
# ════════════════════════════════════════════════════════════════════════

if [ ! -f "$ROUTER_MD" ]; then
  fixture_error "the entry-point skill is missing at $ROUTER_MD"
else
  router_blob="$(normalize "$ROUTER_MD")"

  # Case 3 — several installed, none named — offers operating on all of
  # them, rather than only listing and asking. Any passage that makes the
  # claim satisfies it; the document may talk about the case more than
  # once, and which occurrence comes first is not the property.
  ok=0
  while IFS= read -r win; do
    [ -n "$win" ] || continue
    printf '%s' "$win" | grep -qF -- '--all' && ok=1
  done < <(printf '%s' "$router_blob" | window 'Multiple contextualizer' 0 700)
  report "$ok" "router prose: the several-installed case names the enumeration flag as the way to operate on all of them"

  # The install-levels passage widens the project level to reach nested
  # roots rather than adding a fourth level.
  ok=0
  while IFS= read -r win; do
    [ -n "$win" ] || continue
    printf '%s' "$win" | grep -qiE 'nested|subdirector|anywhere (in|under) the repo|below the repo root' && ok=1
  done < <(printf '%s' "$router_blob" | window 'install levels' 200 900)
  report "$ok" "router prose: the install-levels passage describes the project level as reaching nested roots"

  ok=1
  printf '%s' "$router_blob" | grep -qiE 'four install levels|fourth install level' && ok=0
  report "$ok" "router prose: no fourth install level is introduced"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
