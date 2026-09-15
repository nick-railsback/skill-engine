# Contextualizer locator

The engine's one root-resolution definition. Every surface that has to
resolve a contextualizer root reaches this script instead of restating
where contextualizers live, so this file is the only place that knows.
Edit it here — there is one copy, and nothing else to keep in sync.

Run it with `--all` to enumerate every contextualizer it can find, one
absolute path per line, instead of resolving a single `CTX_ROOT`.

```bash
set -euo pipefail
# <name> resolves per this skill's "Selecting a contextualizer" section;
# substitute the empty string when no contextualizer was named.
name="<name>"
# --all switches the several-found path from list-and-exit to enumerate-
# and-succeed. A pasted fence has no argv, so a caller that wants the
# enumeration supplies it deliberately (`set -- --all` before the paste,
# or `bash -s -- --all <<'EOF'`); with no argv at all this stays empty.
all=""
case "${1:-}" in --all) all=1 ;; esac
ctx_roots=$(
  for root in "$HOME/.claude/skills" "$HOME/.claude/local/skills" "$PWD/.claude/skills"; do
    [ -d "$root" ] || continue
    # Quoted "${name:-*}" reaches find unexpanded: a named invocation
    # matches exactly <name>-context, a bare one globs *-context.
    find "$root" -mindepth 1 -maxdepth 1 -type d -name "${name:-*}-context" 2>/dev/null
  done
  # Contextualizers installed beside the slice of the repository they
  # describe: any .claude/skills/ below the repository root, bounded at
  # six levels. Appended after the loop above, so for a named match the
  # search order is unchanged and the first hit still wins.
  # `|| true`: a working directory that is not a repository resolves
  # normally rather than aborting the whole block under errexit.
  base=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$base" ]; then
    # No -mindepth here: it suppresses expression evaluation for shallow
    # entries, which silently defeats -prune on a top-level node_modules.
    nested=$(find "$base" -maxdepth 6 \
      \( -name .git -o -name node_modules \) -prune -o \
      -type d -name "${name:-*}-context" -print 2>/dev/null || true)
    printf '%s\n' "$nested" | while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      parent=${hit%/*}
      # Only a real install root, and never one the loop above already
      # returned — the enumeration below promises no path twice.
      # Leading "(" on each arm: this case sits inside a $( ) command
      # substitution, where a bare pattern-closing ")" is read as the end
      # of the substitution and the parse fails.
      case "$parent" in
        ("$HOME/.claude/skills"|"$HOME/.claude/local/skills"|"$PWD/.claude/skills") continue ;;
        (*/.claude/skills) ;;
        (*) continue ;;
      esac
      # research/.research-state.json is the canonical setup-state marker:
      # a lookalike directory without it is not a contextualizer. It is
      # the only per-hit filter here, deliberately. A git check-ignore
      # test used to run beside it, and `.claude/` in .gitignore -- the
      # ordinary way a team keeps per-developer agent config out of the
      # repository -- turned that test from a decoy skip into a change of
      # answer: the fixed-root arm above filters $PWD/.claude/skills by
      # nothing, so the same directory was enumerated or skipped
      # depending on which directory the session happened to sit in, and
      # a nested contextualizer under an ignored .claude/ was unreachable
      # from anywhere but its own subtree. Decoys are kept out by this
      # marker and by the prune list above, both of which answer a
      # question about the directory rather than about git's index.
      [ -f "$hit/research/.research-state.json" ] || continue
      printf '%s\n' "$hit"
    done | LC_ALL=C sort
  fi
)
# `|| true`: grep -c prints 0 but exits 1 on zero matches; without the
# guard, pipefail+errexit abort the block right here and the zero-match
# diagnostics below are dead code (a bare exit 1, no message).
n=$(printf '%s\n' "$ctx_roots" | grep -c . || true)
if [ -n "$all" ] && [ "$n" -ge 1 ]; then
  # Enumeration: everything found, one absolute path per line, sorted,
  # exit 0. The caller reads stdout; CTX_ROOT is not set on this path.
  printf '%s\n' "$ctx_roots" | grep . | LC_ALL=C sort
  exit 0
fi
if [ "$n" -eq 0 ] && [ -n "$name" ]; then
  echo "No contextualizer named ${name}-context under ~/.claude/skills/, ~/.claude/local/skills/, or any .claude/skills/ in this repository. Rerun with no name to list what is installed."
  exit 1
elif [ "$n" -eq 0 ]; then
  echo "No contextualizer found under ~/.claude/skills/, ~/.claude/local/skills/, or any .claude/skills/ in this repository. Run /skill-engine:engine-bootstrap first."
  exit 1
elif [ "$n" -gt 1 ] && [ -n "$name" ]; then
  # Same slug installed at more than one level: the first root in the
  # search order above wins (user, then local-user, then project).
  CTX_ROOT=$(printf '%s\n' "$ctx_roots" | head -n1)
elif [ "$n" -gt 1 ]; then
  echo "Multiple contextualizers found; rerun naming one (see 'Selecting a contextualizer' in this skill), or rerun with --all to operate on every one of them:"
  printf '%s\n' "$ctx_roots"
  exit 1
else
  CTX_ROOT="$ctx_roots"
fi
```
