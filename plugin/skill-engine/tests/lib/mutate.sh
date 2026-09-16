#!/usr/bin/env bash
# The mutation-control scaffold shared by the controls under
# tests/check3-paths-comment/mutations/ and
# tests/frontmatter-ceiling-sweep/mutations/.
#
# Sourced, not run. A control shows that a suite of already-holding facts
# can go red. It copies the file under test, breaks the copy, and requires
# the suite red against it. Only the break differs from control to control;
# everything else is here.
#
#   mutation_control <env-var> <target> <runner> <what> <transform> [arg...]
#
#   <env-var>    the variable <runner> reads the file under test from
#   <target>     the pristine file under test; the copy keeps its basename
#   <runner>     the suite that must go red
#   <what>       the broken behaviour as a noun phrase, for the report line
#   <transform>  a command, run with [arg...], that reads the pristine file
#                on stdin and writes the broken one to stdout
#
# Never returns. The exit status is the control's verdict:
#   1  live. <runner> was green on the pristine copy and red on the broken
#      one.
#   0  dead. The pristine copy was already red, the transform changed
#      nothing, or <runner> stayed green on the broken copy.
# A control that cannot run must never read as live, which is why live is
# the non-zero status.

mutation_control() {
  local var="$1" target="$2" runner="$3" what="$4" copy
  shift 4

  mutation_work="$(mktemp -d)"
  trap 'rm -rf "$mutation_work"' EXIT
  copy="$mutation_work/$(basename "$target")"
  cp "$target" "$mutation_work/pristine"
  cp "$target" "$copy"
  chmod +x "$copy"

  if ! env "$var=$copy" bash "$runner" >/dev/null 2>&1; then
    echo "pristine copy is already red"
    exit 0
  fi

  "$@" < "$mutation_work/pristine" > "$copy"

  if cmp -s "$mutation_work/pristine" "$copy"; then
    echo "mutation did not apply"
    exit 0
  fi

  if env "$var=$copy" bash "$runner" >/dev/null 2>&1; then
    echo "$what was accepted"
    exit 0
  fi
  echo "$what was rejected"
  exit 1
}

# swap_line <old> <new> — stdin to stdout, with every line exactly equal to
# <old> replaced by <new>. Both are literal: no regex, no escapes.
swap_line() {
  OLD="$1" NEW="$2" awk '
    $0 == ENVIRON["OLD"] { print ENVIRON["NEW"]; next }
    { print }
  '
}

# insert_after <ere> <line> — stdin to stdout, with <line> added after every
# line matching the extended regex <ere>. <line> is literal.
insert_after() {
  RE="$1" ADD="$2" awk '
    { print }
    $0 ~ ENVIRON["RE"] { print ENVIRON["ADD"] }
  '
}
