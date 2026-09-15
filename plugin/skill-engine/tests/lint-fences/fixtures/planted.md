# Planted-defect fixture

Not a real reference. Every block below is here to be caught.

## A shell fence with SC2155

`export VAR=$(cmd)` masks `cmd`'s exit status — the defect PR #17's review
found in STATUS's fleet section, and the reason this gate exists.

```bash
export ctx_roots=$(printf 'x\n')
```

## A shell fence with SC2164

```bash
cd /tmp/PLACEHOLDER-that-may-not-exist
printf 'landed\n'
```

## A python fence that does not parse

```python
def broken(:
    return 1
```

## A fence carrying placeholders, which must survive substitution

Distinct placeholders must stay distinct, or a comparison between two of
them collapses into a constant and SC2050 fires on correct code.

```bash
if [ "<old_sha>" = "<new_sha>" ]; then
  exit 0
fi
"$CLAUDE_PLUGIN_ROOT/bin/cache-git.sh" sparse-clone "<source_id>" HEAD -- <files_of_interest entries...>
```

## Real redirections, which must NOT be read as placeholders

```bash
in_file=/dev/null
out_file=/dev/null
sort <"$in_file" >"$out_file"
cat <<'INNER' >"$out_file"
a heredoc body
INNER
```
