#!/usr/bin/env bash
# Sole owner of every cache-mutating git invocation the engine's shipped
# recipes perform, plus the since-last-check diff computation those recipes
# feed to discover_inventory.py.
#
# Usage:
#   cache-git.sh clone <source_id> <url> [<ref>]
#   cache-git.sh sparse-clone <source_id> <url> <ref> -- <pattern>...
#   cache-git.sh advance <source_id> <old_sha> <new_sha> <inventory_file>
#   cache-git.sh since-last-check <cache_dir> <old_sha> <new_sha>
#
# Every recipe writes under
# ${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}/git-managed/ --
# resolved once per invocation. `fetch`, `sparse-checkout` and `checkout`
# are doctrine check 4's cache-scoped exception: check 4 scans -C target
# TEXT, not a runtime value, so every such call below spells the override
# expression literally inline at its own -C site rather than through a
# resolved variable -- see plan.md's "Design decision" for why this is not
# optional style. `mkdir -p`, `mv` and `find` are not scanned verbs and use
# the resolved `cache_root` freely.
#
# Invoked with $CLAUDE_PLUGIN_ROOT set (the same convention every reference-
# doc recipe already uses for discover_inventory.py) -- never self-locates
# via $0, since it is always invoked from a doc recipe that already has
# $CLAUDE_PLUGIN_ROOT in scope. `since-last-check` is the one subcommand
# that doesn't need it (no python-file lookup), which is why
# discover_inventory.py's own --last-checked-sha path (invoked directly,
# with no $CLAUDE_PLUGIN_ROOT guarantee) can shell out to it.
#
# `since-last-check`'s <cache_dir> is caller-supplied and needs no
# cache-scope spelling constraint -- `diff` is in doctrine's unconditional
# allow-list, not the cache_exempt set.
set -euo pipefail

cache_root="${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}"

usage() {
  echo "Usage: cache-git.sh {clone|sparse-clone|advance|since-last-check} ..." >&2
  exit 1
}

# install_clone <tmpdir> <dest> — move a finished staging clone into place,
# unless something already occupies <dest>.
#
# The guard is the point: `mv <dir> <existing dir>` moves the source INSIDE
# the destination instead of refusing, so an unguarded mv turns a second
# seed of an already-cached source into
# git-managed/<id>-<sha>/<id>-<sha>.tmp.<pid>/. The outer directory still
# carries a valid .git/, so every warm-cache probe downstream reports a hit
# and the nested duplicate is never noticed. A destination that exists is
# already the same commit -- the directory name carries the SHA this
# invocation just resolved -- so discarding the staging clone is the whole
# correct response.
install_clone() {
  local tmpdir="$1" dest="$2"
  if [ -e "$dest" ]; then
    rm -rf "$tmpdir"
    return 0
  fi
  mv "$tmpdir" "$dest"
}

cmd_clone() {
  local source_id="$1" url="$2" ref="${3:-HEAD}"

  case "$source_id" in
    ""|-*|*[!a-z0-9-]*)
      echo "skill-engine: refusing unsafe source_id '$source_id' -- skipping cache seed for this source" >&2
      exit 1
      ;;
  esac

  local sha
  sha="$(git ls-remote -- "$url" "$ref" | cut -f1)"
  if [ -z "$sha" ]; then
    echo "skill-engine: couldn't resolve $source_id @ $ref (empty ls-remote) -- skipping cache seed for this source" >&2
    exit 1
  fi

  mkdir -p "$cache_root/git-managed/"
  local dest="$cache_root/git-managed/${source_id}-${sha}"
  local tmpdir="${dest}.tmp.$$"

  if [ "$ref" = "HEAD" ]; then
    if git clone --depth=1 --filter=blob:none -- "$url" "$tmpdir"; then
      install_clone "$tmpdir" "$dest"
    else
      rm -rf "$tmpdir"
      exit 1
    fi
  else
    if git clone --depth=1 --filter=blob:none --branch "$ref" -- "$url" "$tmpdir"; then
      install_clone "$tmpdir" "$dest"
    else
      rm -rf "$tmpdir"
      exit 1
    fi
  fi
}

cmd_sparse_clone() {
  local source_id="$1" url="$2" ref="$3"
  shift 3
  [ "${1:-}" = "--" ] || usage
  shift
  local -a patterns=("$@")

  case "$source_id" in
    ""|-*|*[!a-z0-9-]*)
      echo "skill-engine: refusing unsafe source_id '$source_id' -- skipping cache seed for this source" >&2
      exit 1
      ;;
  esac

  local sha
  sha="$(git ls-remote -- "$url" "$ref" | cut -f1)"
  if [ -z "$sha" ]; then
    echo "skill-engine: couldn't resolve $source_id @ $ref (empty ls-remote) -- skipping cache seed for this source" >&2
    exit 1
  fi

  mkdir -p "$cache_root/git-managed/"
  local dest="$cache_root/git-managed/${source_id}-${sha}"
  local tmpdir="${dest}.tmp.$$"

  local clone_ok=0
  if [ "$ref" = "HEAD" ]; then
    if git clone --filter=blob:none --no-checkout --depth=1 --single-branch -- "$url" "$tmpdir"; then
      clone_ok=1
    fi
  else
    if git clone --filter=blob:none --no-checkout --depth=1 --single-branch --branch "$ref" -- "$url" "$tmpdir"; then
      clone_ok=1
    fi
  fi

  if [ "$clone_ok" -eq 1 ] \
    && git -C "${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}/git-managed/${source_id}-${sha}.tmp.$$" sparse-checkout init --no-cone \
    && git -C "${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}/git-managed/${source_id}-${sha}.tmp.$$" sparse-checkout set "${patterns[@]}" \
    && git -C "${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}/git-managed/${source_id}-${sha}.tmp.$$" checkout ; then
    local missing=0
    local entry
    for entry in "${patterns[@]}"; do
      if [ -z "$(git -C "$tmpdir" ls-files -- "$entry")" ]; then
        local probe="${entry%/\*\*}"
        probe="${probe%/\*}"
        local ancestor="$probe"
        while [ -n "$ancestor" ] && [ ! -d "$tmpdir/$ancestor" ]; do
          case "$ancestor" in
            */*) ancestor="${ancestor%/*}" ;;
            *) ancestor="" ;;
          esac
        done
        local siblings
        siblings=$(find "$tmpdir${ancestor:+/$ancestor}" -mindepth 1 -maxdepth 2 \
          -type d -not -path '*/.git' -not -path '*/.git/*' 2>/dev/null \
          | sed "s#^$tmpdir/##" | sort | sed 's#$#/#' | paste -sd, - | sed 's/,/, /g')
        # A resolved-no-files entry skips only this source's cache seed and
        # continues to the next source; it does not abort the caller's run.
        echo "skill-engine: files_of_interest entry '$entry' resolved no files in checkout; nearest siblings under '${ancestor:-.}/': $siblings" >&2
        missing=1
      fi
    done
    if [ "$missing" -eq 1 ]; then
      rm -rf "$tmpdir"
      exit 1
    else
      install_clone "$tmpdir" "$dest"
    fi
  else
    rm -rf "$tmpdir"
    exit 1
  fi
}

cmd_since_last_check() {
  local cache_dir="$1" old_sha="$2" new_sha="$3"
  git -C "$cache_dir" -c core.quotePath=false diff --name-status --no-renames \
      "$old_sha" "$new_sha" \
    | cut -f2- \
    | jq -R . \
    | jq -s --arg from "$old_sha" --arg to "$new_sha" \
        '{from_sha: $from, to_sha: $to, files: map({path: .})}'
}

cmd_advance() {
  if [ "$#" -ne 4 ]; then
    echo "Usage: cache-git.sh advance <source_id> <old_sha> <new_sha> <inventory_file>" >&2
    exit 1
  fi
  local source_id="$1" old_sha="$2" new_sha="$3" inv_file="$4"

  if [ "$old_sha" = "$new_sha" ]; then
    exit 0
  fi

  # Checked here, before anything is fetched or checked out. This is the one
  # subcommand that needs $CLAUDE_PLUGIN_ROOT (it locates
  # discover_inventory.py), and `set -u` turns an unset one into an abort
  # wherever it is first dereferenced. Dereferenced at its point of use, that
  # abort lands after `checkout --detach` has already moved the tree, leaving
  # <id>-<old_sha>/ holding new_sha's content -- and DISCOVER's pre-flight
  # trusts that directory's SHA suffix (PR #15 review, finding 4). A set-but-
  # wrong value is not detectable until the script it names is invoked; the
  # trap below is what keeps that case from leaking.
  if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf 'skill-engine: advance needs CLAUDE_PLUGIN_ROOT set (it locates discover_inventory.py) -- nothing fetched, %s-%s untouched\n' \
      "$source_id" "$old_sha" >&2
    exit 1
  fi

  if ! git -C "${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}/git-managed/${source_id}-${old_sha}" fetch --depth=1 origin "$new_sha"; then
    printf 'skill-engine: failed to fetch %s for %s -- advance aborted, %s-%s left intact\n' \
      "$new_sha" "$source_id" "$source_id" "$old_sha" >&2
    exit 1
  fi

  git -C "${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}/git-managed/${source_id}-${old_sha}" checkout --detach "$new_sha"

  local cache_dir="$cache_root/git-managed/${source_id}-${old_sha}"

  # An explicit template, not a bare `mktemp`: BSD mktemp (macOS) ignores
  # TMPDIR without one and always writes under the per-user confstr dir, so
  # the two platforms would put this file in different places. The trap is
  # what makes every abort between here and the removal -- a
  # CLAUDE_PLUGIN_ROOT pointing at no install, a failed diff, an interrupt --
  # clean up after itself instead of leaving the scratch file behind.
  local since_tmpfile="" inventory_json
  trap 'rm -f "${since_tmpfile:-}" 2>/dev/null || :' EXIT
  since_tmpfile="$(mktemp "${TMPDIR:-/tmp}/skill-engine-advance.XXXXXX")"
  cmd_since_last_check "$cache_dir" "$old_sha" "$new_sha" > "$since_tmpfile"
  inventory_json="$(python3 "$CLAUDE_PLUGIN_ROOT/tests/discover_inventory.py" "$cache_dir" --since-json "$since_tmpfile")"

  # The inventory merge happens HERE, before the rename, because the rename
  # is the only step that changes what the next session sees: once
  # <id>-<old_sha>/ is gone, the SHA the registry still records names
  # nothing on disk, and the next advance fetches from a directory that no
  # longer exists -- "advance aborted", every session, until someone
  # hand-edits the registry. Ordering the fallible work first makes the
  # whole subcommand replayable instead: any failure up to this point
  # leaves the cache exactly where the recorded SHA says it is, so running
  # the identical advance again just works. The caller used to own this
  # write and ran it after the helper had already renamed, which is what
  # opened that window.
  mkdir -p "$(dirname "$inv_file")"
  local existing="{}"
  [ -f "$inv_file" ] && existing="$(cat "$inv_file")"
  printf '%s' "$existing" \
    | jq --arg sid "$source_id" --argjson entry "$inventory_json" '.[$sid] = $entry' \
    > "${inv_file}.tmp"
  mv "${inv_file}.tmp" "$inv_file"

  mv "$cache_dir" "$cache_root/git-managed/${source_id}-${new_sha}"

  find "$cache_root/git-managed" -mindepth 1 -maxdepth 1 -type d \
    -name "${source_id}-*" ! -name "${source_id}-${new_sha}" -exec rm -rf {} +

  printf '%s\n' "$inventory_json"
}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift

case "$cmd" in
  clone) cmd_clone "$@" ;;
  sparse-clone) cmd_sparse_clone "$@" ;;
  advance) cmd_advance "$@" ;;
  since-last-check) cmd_since_last_check "$@" ;;
  *) usage ;;
esac
