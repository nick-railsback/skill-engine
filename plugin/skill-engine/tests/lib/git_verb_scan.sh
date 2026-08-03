#!/usr/bin/env bash
# Candidate git-invocation extractor behind doctrine check 4.
#
# Usage: git_verb_scan.sh --root <prefix> <file>...
#
# Writes one line per candidate git invocation:
#
#   <path-with-prefix-stripped>:<line-number>:<verb>
#
# "Candidate" is the operative word: this answers "what token follows a git
# invocation", not "is that token a mutating verb". doctrine.sh owns the
# known-verbs set and the read-only allow-list that turn candidates into
# violations, so a prose noun phrase like "no git mutations" comes out of
# here as the candidate `mutations` and is dropped there. Keeping the two
# apart is what lets this half be exercised against fixtures — see
# tests/doctrine-git-verbs/run.sh — instead of only against whatever the
# repo happens to contain today.
#
# One awk invocation over the whole file list, not one per file: the caller
# hands it dozens of files across skills/, bin/, tests/ and the templates,
# and a fork apiece was a measurable share of every CI run.
#
# Read-only. Reads the named files, writes only to stdout.
set -euo pipefail

root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      root="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [ "$#" -eq 0 ]; then
  exit 0
fi

awk -v root="$root" '
  FNR == 1 { rel = (root == "" ? FILENAME : substr(FILENAME, length(root) + 1)) }
  {
    line = $0
    # Strip single-line HTML comments.
    gsub(/<!--[^>]*-->/, "", line)
    # Strip Markdown code spans (paired backticks on the same line).
    gsub(/`[^`]*`/, "", line)
    # Strip shell line comments. Engine shell files legitimately describe
    # git verbs in prose ("...the global/system git config..."), and a
    # comment cannot invoke anything. Applied after the code-span strip so
    # a span containing "#" has already gone.
    sub(/#.*$/, "", line)
    # Strip double-quoted literals carrying no command substitution, so a
    # verb named inside a diagnostic message is not read as an invocation.
    # Forms that can actually run something -- $(...) and backticks -- are
    # deliberately left in place and still scanned. Known limit, pinned
    # rather than implied away: `bash -c "git push"` is not caught here.
    while (match(line, /"[^"$`]*"/)) {
      line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH)
    }
    # Extract executable git verbs: \<git\>, then any of git'"'"'s OWN options,
    # then the verb.
    #
    # The option run is what this pattern exists for. Requiring a lowercase
    # letter immediately after "git " matched `git push` and missed
    # `git -C "$repo" push` — and with it every form carrying -C, -c,
    # --git-dir= or --no-pager, which is to say every form that names the
    # repository being mutated. That is exactly the form worth catching: a
    # bare `git push` acts on the current directory, while `git -C <dir>`
    # reaches into somebody else'"'"'s tree.
    #
    # Three option shapes, kept narrow on purpose:
    #   -C <arg> / -c <arg>   the two that take a separate value
    #   --long=value          value attached, no following token
    #   -x / --long           no value
    # A blanket "option optionally followed by any token" would let the
    # longest-match rule swallow the verb as an option'"'"'s value
    # (`git --no-pager reset` reporting nothing), which is the same blind
    # spot in a new place.
    while (match(line, /(^|[[:space:]]|[(;&|])git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--[^[:space:]=]+=[^[:space:]]*|--?[A-Za-z][A-Za-z-]*))*[[:space:]]+[a-z][a-z-]*/)) {
      token = substr(line, RSTART, RLENGTH)
      # The verb is the final whitespace-separated token of the match,
      # whatever ran before it.
      sub(/^.*[[:space:]]/, "", token)
      print rel ":" FNR ":" token
      line = substr(line, RSTART + RLENGTH)
    }
  }
' "$@"
