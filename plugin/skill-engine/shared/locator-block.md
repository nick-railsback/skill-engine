# Contextualizer locator

Root-resolution script shared by `discover`, `refresh`, `status`,
`self-audit`, and `new-reference`. Edit it here — every citing skill reads
this one copy, so there is nothing else to keep in sync.

```bash
set -euo pipefail
# <name> resolves per this skill's "Selecting a contextualizer" section;
# substitute the empty string when no contextualizer was named.
name="<name>"
ctx_roots=$(
  for root in "$HOME/.claude/skills" "$HOME/.claude/local/skills" "$PWD/.claude/skills"; do
    [ -d "$root" ] || continue
    # Quoted "${name:-*}" reaches find unexpanded: a named invocation
    # matches exactly <name>-context, a bare one globs *-context.
    find "$root" -mindepth 1 -maxdepth 1 -type d -name "${name:-*}-context" 2>/dev/null
  done
)
# `|| true`: grep -c prints 0 but exits 1 on zero matches; without the
# guard, pipefail+errexit abort the block right here and the zero-match
# diagnostics below are dead code (a bare exit 1, no message).
n=$(printf '%s\n' "$ctx_roots" | grep -c . || true)
if [ "$n" -eq 0 ] && [ -n "$name" ]; then
  echo "No contextualizer named ${name}-context under any of ~/.claude/skills/, ~/.claude/local/skills/, or .claude/skills/. Rerun with no name to list what is installed."
  exit 1
elif [ "$n" -eq 0 ]; then
  echo "No contextualizer found under any of ~/.claude/skills/, ~/.claude/local/skills/, or .claude/skills/. Run /skill-engine:engine-bootstrap first."
  exit 1
elif [ "$n" -gt 1 ] && [ -n "$name" ]; then
  # Same slug installed at more than one level: the first root in the
  # search order above wins (user, then local-user, then project).
  CTX_ROOT=$(printf '%s\n' "$ctx_roots" | head -n1)
elif [ "$n" -gt 1 ]; then
  echo "Multiple contextualizers found; rerun naming one (see 'Selecting a contextualizer' in this skill):"
  printf '%s\n' "$ctx_roots"
  exit 1
else
  CTX_ROOT="$ctx_roots"
fi
```

