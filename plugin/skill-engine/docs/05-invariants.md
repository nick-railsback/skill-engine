# 05-Invariants

The conventions in [02-artifact-contract.md](02-artifact-contract.md) are useless if nothing enforces them.
This chapter is the test suite that turns those conventions into checkable invariants - tests-as-spec, where each test is a single-paragraph executable definition of a rule the contextualizer must always satisfy.

The source project's test suite has on the order of 50 tests in 1,600 lines of plain bash.
You don't need that much surface area on day one. Start with the seven core invariants below.
They cover the failure modes that actually corrupt the contextualizer in practice - drift between catalog and filesystem, accidental frontmatter, version-string skew, oversized references, reference content silently changing without notice.

Once those are in place, add invariants as you discover new failure modes.
The pattern is: every convention has a test. Every test fails noisily on violation.
The engine runs the suite before surfacing changes for review.

**On this page:**
* [Test framework primitives](#test-framework-primitives)
* [The seven core invariants](#the-seven-core-invariants)
* [Invariant 1: Byte-equality (with reverse-direction check)](#invariant-1-byte-equality-with-reverse-direction-check)
* [Invariant 2: Catalog bijection](#invariant-2-catalog-bijection)
* [Invariant 3: No frontmatter on references](#invariant-3-no-frontmatter-on-references)
* [Invariant 4: Version consistency across 4 surfaces](#invariant-4-version-consistency-across-4-surfaces)
* [Invariant 5: Reference size constraints](#invariant-5-reference-size-constraints)
* [Invariant 6: Metadata schema after install](#invariant-6-metadata-schema-after-install)
* [Invariant 7: Package zip hygiene](#invariant-7-package-zip-hygiene)
* [Invariant 8: First-5K standing-instruction budget](#invariant-8-first-5k-standing-instruction-budget)
* [Invariant 9: Max-ref-depth (one level)](#invariant-9-max-ref-depth-one-level)
* [Invariant 10: Long-reference TOC presence](#invariant-10-long-reference-toc-presence)
* [Invariant 11: Optional SKILL.json trijection](#invariant-11-optional-skilljson-trijection)
* [README maintenance markers](#readme-maintenance-markers)
* [Hermetic test environment](#hermetic-test-environment)
* [Suggested adoption order](#suggested-adoption-order)

> **Pre-fixture-harness aspirational.** The byte-equality-fixture + `test/test-cli.sh` harness described in this chapter is the fixture-harness contract — not yet implemented in the pre-fixture-harness state. The pre-fixture-harness validation gate is the stamped `verify.sh` (catalog bijection, frontmatter discipline, link integrity, schema). The design below is preserved as the fixture-harness specification; expect Invariants 1 and 4 in particular to shift as the fixture-harness milestone lands.

## Test framework primitives

You don't need a heavyweight framework. A pure-bash harness with a handful of assertion functions is enough:

```bash
# In test/test-cli.sh

assert_eq() {
  local actual="$1" expected="$2" message="$3"
  if [ "$actual" = "$expected" ]; then
    return 0
  fi
  echo "[FAIL] $message"
  echo "  Expected: $expected"
  echo "  Actual:   $actual"
  return 1
}

assert_file_exists() {
  local file="$1" message="$2"
  if [ -f "$file" ]; then return 0; fi
  echo "[FAIL] $message - file missing: $file"
  return 2
}

assert_dir_exists() { [ -d "$1" ] || { echo "[FAIL] $2"; return 1; }; }
assert_file_not_exists() { [ ! -f "$1" ] || { echo "[FAIL] $2"; return 1; }; }
assert_dir_not_exists() { [ ! -d "$1" ] || { echo "[FAIL] $2"; return 1; }; }

assert_contains() {
  if echo "$1" | grep -q "$2"; then return 0; fi
  echo "[FAIL] $3"; return 1
}

run_test() {
  local test_name="$1"
  echo -n "Running $test_name... "
  if "$test_name"; then
    echo "PASS"
    PASS_COUNT=$((PASS_COUNT+1))
  else
    echo "FAIL"
    FAIL_COUNT=$((FAIL_COUNT+1))
  fi
}
```

Six assertions plus a `run_test` runner. That's the whole framework. Add more assertion functions only when you have a specific test pattern that needs one.

## The seven core invariants

| Invariant | What it catches |
|---|---|
| **1. Byte-equality with reverse-direction check** | Reference content silently changing; new files added without checksum tracking |
| **2. Catalog bijection** | Catalog and filesystem drifting apart |
| **3. No frontmatter on references** | Stray YAML breaking the navigator's loading model |
| **4. Version consistency** | Skew across 4 surfaces - CLI/plugin/test/docs claiming different versions |
| **5. Reference size constraints** | References that bloat past the on-demand-loading budget |
| **6. Metadata schema after install** | Install writing malformed metadata |
| **7. Package zip hygiene** | Distribution zip including editor cruft, dotfiles, or wrong path shape |
| **8. First-5K standing-instruction budget** | Navigators silently truncated by auto-compaction when standing instructions exceed the 5K body cap |
| **9. Max-ref-depth (one level)** | Nested reference directories that tempt shallow probes (`head -100` previews instead of full reads) |
| **10. Long-reference TOC presence** | References over 100 lines without a `## Contents` marker in the first 30 lines, forcing top-to-bottom reads |
| **11. Optional SKILL.json trijection** | Drift between SKILL.md catalog, SKILL.json entries, and reference files when a contextualizer opts into the structured sibling |

Each gets its own test below.

## Invariant 1: Byte-equality (with reverse-direction check)

The single most load-bearing test. It pins reference content to a committed checksum fixture so that any unintended content drift fails CI.

### Fixture file

Maintain a single committed file that maps each primary reference filename to its SHA-256:

```text
# test/fixtures/source-body-checksums.txt
# Format: filename<TAB>sha256-hash
# Refresh manually when content legitimately changes.

<area-domain>-sso.md          a1b2c3d4e5f6789...
<area-domain>-mfa.md          8765abcd1234ef9...
<area-domain>-provisioning.md deadbeef0123456...
```

The fixture is the ground truth for "what reference content was last approved by a human." It only changes when you (or the engine, with your approval) decide content should change.

### Forward-direction check

For every fixture entry, recompute the file's SHA-256 and compare:

```bash
test_byte_equality_references() {
  local fail=0
  while IFS=$'\t' read -r filename expected_hash; do
    # Skip blank lines and comments
    if [ -z "$filename" ] || [[ "$filename" == \#* ]]; then
      continue
    fi

    local file="skills/<area-domain>-context/references/$filename"
    if ! assert_file_exists "$file" "Fixture reference missing file: $filename"; then
      fail=1
      continue
    fi

    local actual_hash
    actual_hash=$(sha256sum "$file" | awk '{print $1}')
    
    assert_eq "$actual_hash" "$expected_hash" \
      "$filename content drifted from fixture" || fail=1
      
  done < test/fixtures/source-body-checksums.txt
  
  return $fail
}
```

### Reverse-direction check (the load-bearing one)

The forward check catches content drift. But it doesn't catch a *new* reference file that was committed without a fixture entry - that file simply has no row in the fixture, so the forward loop never visits it.

The reverse-direction check closes that gap:

```bash
test_byte_equality_references() {
  # ... forward check above ...

  # Reverse: every reference file must have a fixture entry
  local fixture_files
  fixture_files=$(awk -F'\t' '/\.md/ {print $1}' \
    test/fixtures/source-body-checksums.txt | sort)

  local actual_files
  actual_files=$(cd skills/<area-domain>-context/references && \
    find . -maxdepth 1 -type f -name '<area-domain>-*.md' 2>/dev/null | sed 's|^\./||' | sort)

  local untracked
  untracked=$(comm -23 \
    <(echo "$actual_files") \
    <(echo "$fixture_files"))

  if [ -n "$untracked" ]; then
    echo "[FAIL] Reference files lack fixture entries:"
    echo "$untracked" | sed 's/^/  - /'
    fail=1
  fi

  return $fail
}
```

`comm -23 A B` prints entries in A that aren't in B. If any actual reference file isn't in the fixture, the test fails with the offending names.

**Why this matters.** Without the reverse check, the failure mode is silent: you commit a new reference, the forward loop doesn't visit it, the test passes, and you ship a contextualizer with a reference file that no one ever validated. The reverse check turns that silent failure into a CI break.

### When the fixture refreshes

The fixture changes when content changes, not on every commit:

* The engine regenerates the fixture for every modified reference as part of its pre-approval validation (see [03-engine.md](03-engine.md)).
* A human author manually regenerates rows when they directly edit a reference (no agent involved).

A simple regenerator script:

```bash
# scripts/refresh-fixture.sh
cd skills/<area-domain>-context/references
find . -maxdepth 1 -type f -name '<area-domain>-*.md' 2>/dev/null | sed 's|^\./||' | while IFS= read -r f; do
  printf "%s\t%s\n" "$f" "$(sha256sum "$f" | awk '{print $1}')"
done | sort > ../../../test/fixtures/source-body-checksums.txt
```

Don't auto-run the regenerator in CI - that defeats the point. The fixture is committed because changing it is the intentional gesture that says "this content change has been reviewed."

## Invariant 2: Catalog bijection

The navigator's Catalog table and the set of primary references must be in 1:1 correspondence. A primary is either a flat file at `references/<area-domain>-<topic>.md` (file form) or the canonical `.md` file inside a `references/<area-domain>-<topic>/` directory whose basename matches the directory's basename (directory form — see [02-artifact-contract.md#reference-depth-one-level](02-artifact-contract.md#reference-depth-one-level)). The bijection's set-equality is computed over canonical reference IDs, so the two forms collapse to one ID per `<slug>`; a same-slug present in both forms surfaces as a duplicate-primary failure.

### Algorithm

1. Extract catalog rows from `SKILL.md` between the `## Catalog` heading and the next `##` heading.
2. From those rows, extract the filename pattern: `references/<area-domain>-*.md`.
3. List actual filesystem primaries: `find references -maxdepth 1 -type f -name '<area-domain>-*.md'`.
4. Both sets, sorted, must be identical.
5. Also: count duplicate rows (a catalog row appearing twice signals copy-paste error).

```bash
test_catalog_bijection() {
  # Extract catalog references
  local catalog_set
  catalog_set=$(awk '/## Catalog/,/## Cross-reference map/' \
    skills/<area-domain>-context/SKILL.md | \
    grep -o 'references/<area-domain>-[a-z0-9-]*\.md' | \
    sed 's/references\///' | \
    sort -u)

  # List filesystem primaries
  local fs_set
  fs_set=$(cd skills/<area-domain>-context/references && \
    find . -maxdepth 1 -type f -name '<area-domain>-*.md' 2>/dev/null | sed 's|^\./||' | sort)

  # Compare
  if [ "$catalog_set" != "$fs_set" ]; then
    echo "[FAIL] Catalog and filesystem differ:"
    diff -u <(echo "$catalog_set") <(echo "$fs_set") | sed 's/^/  /'
    return 1
  fi

  # Detect duplicate rows in the raw catalog
  local raw_count unique_count
  raw_count=$(awk '/## Catalog/,/## Cross-reference map/' \
    skills/<area-domain>-context/SKILL.md | \
    grep -c 'references/<area-domain>-[a-z0-9-]*\.md')
    
  unique_count=$(echo "$catalog_set" | wc -l | tr -d ' ')

  if [ "$raw_count" -ne "$unique_count" ]; then
    echo "[FAIL] Catalog has duplicate rows ($raw_count raw, $unique_count unique)"
    return 1
  fi

  return 0
}
```

The `/## Catalog/,/## Cross-reference map/` pattern bounds the search to just the catalog section - robust against `references/...` URLs appearing elsewhere in the navigator.

The duplicate-detection step is non-obvious but valuable: a catalog row pasted twice creates an inconsistency the diff step won't catch (the *set* still matches the filesystem, the *list* doesn't).

## Invariant 3: No frontmatter on references

Reference files start with a `# Title` Markdown heading. They never start with `---`.

```bash
test_no_frontmatter_references() {
  local fail=0

  while IFS= read -r ref; do
    # Read first non-blank, non-BOM line
    local first_line
    first_line=$(awk 'BEGIN{FS=""} /[^[:space:]]/ {
      # BOM if present, strip UTF-8
      sub(/^\xef\xbb\xbf/, "")
      print; exit
    }' "$ref")

    if [[ "$first_line" == "---"* ]]; then
      echo "[FAIL] $ref starts with YAML frontmatter"
      fail=1
    fi
  done < <(find skills/<area-domain>-context/references -maxdepth 1 -type f -name '*.md' 2>/dev/null)

  return $fail
}
```

The BOM-stripping step is a defensive measure - some editors silently inject a UTF-8 byte-order mark on first save, which changes the first byte of the file and confuses naive line-reads.

## Invariant 4: Version consistency across 4 surfaces

The version string lives in four places (see [04-delivery.md#4-place-version-sync](04-delivery.md)). All four must agree.

```bash
test_version_consistency() {
  # Extract from each surface
  local cli_var cli_comment plugin_json test_assertion

  cli_var=$(grep -E '^VERSION=' bin/<area-domain>-context | \
    head -1 | sed 's/VERSION="\(.*\)"/\1/')
    
  cli_comment=$(grep '# Version: ' bin/<area-domain>-context | \
    head -1 | awk '{print $3}')
    
  plugin_json=$(jq -r '.version' .claude-plugin/plugin.json)
  
  test_assertion=$(grep 'assert_contains "$output" "[0-9]' test/test-cli.sh | \
    grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d ' ')

  # ALL must match
  assert_eq "$cli_var" "$plugin_json" \
    "VERSION var != plugin.json" || return 1
    
  assert_eq "$cli_comment" "$plugin_json" \
    "Version comment != plugin.json" || return 1
    
  assert_eq "$test_assertion" "$plugin_json" \
    "test_assertion != plugin.json" || return 1

  return 0
}
```

When this fails, it's almost always because a release bumped three of the four locations and missed the fourth. The test failure tells you exactly which one drifted.

## Invariant 5: Reference size constraints

Each primary reference must stay under the size budget - the navigator's on-demand-loading promise depends on it.

```bash
test_reference_size_caps() {
  local max_lines=500
  local max_bytes=$((18 * 1024)) # 18 KB
  local fail=0

  while IFS= read -r ref; do
    local line_count byte_count
    
    line_count=$(wc -l < "$ref" | tr -d ' ')
    byte_count=$(wc -c < "$ref" | tr -d ' ')

    if [ "$line_count" -gt "$max_lines" ]; then
      echo "[FAIL] $ref exceeds line cap: $line_count > $max_lines"
      fail=1
    fi
    
    if [ "$byte_count" -gt "$max_bytes" ]; then
      echo "[FAIL] $ref exceeds byte cap: $byte_count > $max_bytes"
      fail=1
    fi
  done < <(find skills/<area-domain>-context/references -maxdepth 1 -type f -name '<area-domain>-*.md' 2>/dev/null)

  return $fail
}
```

Companion files are exempt from this cap - they're optional deep-dives. Apply the cap only to primaries.

## Invariant 6: Metadata schema after install

This test exercises the actual install pipeline end-to-end in a hermetic temp directory. If `create_metadata()` regresses (writes malformed JSON, drops a field), this catches it.

```bash
test_metadata_schema_after_install() {
  local tmpdir
  tmpdir=$(mktemp -d)
  
  pushd "$tmpdir" > /dev/null
  mkdir .claude
  
  <AREA_DOMAIN>_TOOL=claude "$REPO_ROOT/bin/<area-domain>-context" install > /dev/null
  
  local metadata=".claude/.<area-domain>-metadata.json"
  assert_file_exists "$metadata" "metadata file written" || return 2

  # Valid JSON
  jq empty "$metadata" 2>/dev/null || { echo "[FAIL] metadata not valid JSON"; return 1; }

  # Required fields
  assert_eq "$(jq -r '.tool' "$metadata")" "claude" "metadata.tool" || return 1
  assert_eq "$(jq -r '.skills[0]' "$metadata")" "<area-domain>-context" "metadata.skills[0]" || return 1

  # Numeric reference files
  local ref_count
  ref_count=$(jq -r '.reference_files' "$metadata")
  if ! [[ "$ref_count" =~ ^[0-9]+$ ]]; then
    echo "[FAIL] reference_files not numeric: $ref_count"; return 1
  fi

  popd > /dev/null
  rm -rf "$tmpdir"
  return 0
}
```

## Invariant 7: Package zip hygiene

After running `<area-domain>-context package`, the resulting zip should:
* Have `<area-domain>-context/` as the top-level entry (not `skills/<area-domain>-context/`)
* Contain `SKILL.md` and the `references/` directory
* Exclude `.git/`, `.DS_Store`, `.swp`, `.bak`

```bash
test_package_zip_hygiene() {
  local tmpdir
  tmpdir=$(mktemp -d)
  cd "$tmpdir"

  "$REPO_ROOT/bin/<area-domain>-context" package > /dev/null
  local zip
  zip=$(find . -maxdepth 1 -type f -name '<area-domain>-context-*.zip' 2>/dev/null | head -n1)

  # Top-level entry
  local top_entries
  top_entries=$(unzip -l "$zip" | awk 'NR>3 {print $4}' | grep -o '^[^/]\+/' | sort -u)
  
  assert_eq "$top_entries" "<area-domain>-context/" \
    "zip top-level is <area-domain>-context/" || return 1

  # Required entries present
  unzip -l "$zip" | grep -q "<area-domain>-context/SKILL.md" || \
    { echo "[FAIL] zip missing SKILL.md"; return 1; }
    
  unzip -l "$zip" | grep -q "<area-domain>-context/references/" || \
    { echo "[FAIL] zip missing references/"; return 1; }

  # Exclusions
  for cruft in .DS_Store .git/ .swp .bak; do
    if unzip -l "$zip" | grep -q "$cruft"; then
      echo "[FAIL] zip contains forbidden pattern: $cruft"
      return 1
    fi
  done

  cd /
  rm -rf "$tmpdir"
  return 0
}
```

This is what catches a future maintainer's tweak to the package command silently breaking the Desktop upload shape.

## Invariant 8: First-5K standing-instruction budget

The navigator's **standing instructions** - invariants, critical rules, and dispatch logic - must fit in the first 5K bytes of `SKILL.md` body, with frontmatter excluded. The platform constraint is auto-compaction: when the orchestrator re-attaches skills mid-conversation, the budget for all attached skills is roughly 25K bytes; reserving 5K per navigator leaves headroom for multi-skill scenarios. A navigator that exceeds the cap is silently truncated by the platform.

The catalog table is excluded from the budget per the **catalog-as-TOC carve-out**, so multi-domain navigators with large sectioned catalogs are not penalized — the catalog is a router, not standing instructions.

The full rule lives in [02-artifact-contract.md#navigator-size-budget](02-artifact-contract.md#navigator-size-budget). The test body is the `first-5K` named check in the contextualizer-side `verify.sh` (template source: `plugin/skill-engine/engine-bootstrap-templates/verify.sh`); the frontmatter-strip semantics (only the leading `---` block, only when line 1 is `---`, fenced `---` are not terminators, multi-document YAML unsupported) are documented inline in that check's leading comment.

## Invariant 9: Max-ref-depth (one level)

From `SKILL.md`, every reference is one primary deep — the catalog row resolves to a single load target. For a file-form reference, the target is a flat `.md` file at `references/<area-domain>-<topic>.md`; for a directory-form reference, the target is a directory at `references/<area-domain>-<topic>/` whose canonical primary `.md` (same basename as the directory) is what Claude loads. Either way, no further delegation to a sub-directory of references — the primary IS the reference body.

The failure mode is shallow probes: nested references tempt Claude to `head -100` a file to "preview" it instead of reading it fully. The depth-1 rule keeps every reference a single, complete unit. Companion files (bare-named) live alongside primaries in the same `references/` directory and remain depth 1.

When a reference takes the optional directory form (`references/<area-domain>-<topic>/`, containing a canonical primary `.md` of the same basename plus optional non-`.md` assets — see [02-artifact-contract.md#reference-depth-one-level](02-artifact-contract.md#reference-depth-one-level)), the directory itself is the reference: the canonical primary `.md` at depth-2 is permitted because it is part of the directory-form reference, not a nested reference. Any other `.md` at depth-2 is a contract violation; depth-3+ paths fail regardless of extension; and any sub-directory under `references/<area-domain>-<topic>/` is a contract violation regardless of what it contains.

The full rule lives in [02-artifact-contract.md#reference-depth-one-level](02-artifact-contract.md#reference-depth-one-level). The test body is the `max-ref-depth` named check in the contextualizer-side `verify.sh`.

## Invariant 10: Long-reference TOC presence

Any reference body exceeding 100 lines must contain a Markdown TOC marker — typically `## Contents` — within the first 30 lines of the body. The TOC tells Claude where to land when the reference is loaded, instead of forcing a top-to-bottom read of a long file.

Short references (under 100 lines) do not need a TOC; they are short enough to scan directly.

The full rule lives in [02-artifact-contract.md#long-references-must-have-a-toc-100-lines](02-artifact-contract.md#long-references-must-have-a-toc-100-lines). The test body is the `long-ref-toc` named check in the contextualizer-side `verify.sh`.

## Invariant 11: Optional SKILL.json trijection

When a contextualizer opts into the structured machine-readable sibling by shipping a `SKILL.json` file alongside `SKILL.md`, three surfaces must stay in three-way correspondence: the navigator's `## Catalog` rows, the SKILL.json `catalog[]` entries (excluding any entry carrying `"draft": true`), and the `references/<area-domain>-*.md` files on disk. Drift between any pair surfaces as a fail; the orthogonal pairwise `catalog-bijection` check (Invariant 2) continues to enforce the SKILL.md ↔ filesystem correspondence regardless.

The invariant is **conditional**: it fires only when a `SKILL.json` is present in a scanned skill directory. Contextualizers that ship only `SKILL.md` + `references/` (no JSON sibling) get a silent-skip pass — the check is registered but inactive for that scope.

The full rule lives in [02-artifact-contract.md#skilljson-optional-machine-readable-sibling](02-artifact-contract.md#skilljson-optional-machine-readable-sibling). The test body is the `skill-json-trijection` named check in the contextualizer-side `verify.sh`. Fires only when `SKILL.json` is present; silent-skip otherwise.

## README maintenance markers

If you display freshness counters (or any state-driven content) in your main README, fence them with HTML comments so the engine knows where to write:

```markdown
## Maintenance status

| Workflow | Last run | Status | Cadence |
|---|---|---|---|
| REFRESH | 2026-04-27 (1 day ago) | 🟢 Fresh | Manual; weekly |
> Counters reflect `research/.research-state.json` as of the last engine run.
```

The agent regenerates *only* the content between the `start` and `end` markers - never anything outside. The fences are sacred. A test enforces:

```bash
test_readme_maintenance_markers() {
  grep -q "" README.md || \
    { echo "[FAIL] README missing maintenance-status:start marker"; return 1; }
    
  grep -q "" README.md || \
    { echo "[FAIL] README missing maintenance-status:end marker"; return 1; }

  # Content between fences is a valid 4-column markdown table
  awk '//,//' README.md | \
    grep -E '^\|' | head -1 | awk -F'|' 'NF!=6 {exit 1}' || \
    { echo "[FAIL] marker block does not contain a 4-column table"; return 1; }

  return 0
}
```

## Hermetic test environment

Tests must run identically in CI, on a maintainer's laptop, and inside the engine's pre-approval validation. Hermetic isolation:

* **Temp directories.** Tests that exercise install/clean/package run in `mktemp -d`, never against the user's actual `.claude/`.
* **Env var override.** Set the tool-detection env var (e.g., `<AREA_DOMAIN>_TOOL=claude`) at the top of `test/test-cli.sh` so tests never hit the interactive prompt.
* **Cleanup on failure.** Trap exit and remove temp dirs even when tests fail mid-run.
* **No global state.** Tests don't depend on previous tests having run; each is self-contained.

```bash
# At the top of test/test-cli.sh
export <AREA_DOMAIN>_TOOL=claude # non-interactive for CI
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
trap 'rm -rf /tmp/<area-domain>-test-*' EXIT
```

## Suggested adoption order

If you're starting from zero, you don't need all seven invariants on day one. The order that captures the most value soonest:

1. **Catalog bijection:** the most common drift; trivial to write.
2. **No frontmatter on references:** cheap and prevents a load-bearing failure mode.
3. **Version consistency:** the moment you have a release process, you need this.
4. **Byte-equality with reverse-direction:** the moment you have a engine, you need this.
5. **Reference size constraints:** once you have 5+ references and start worrying about budget.
6. **Metadata schema:** when your install logic gets non-trivial.
7. **Package zip hygiene:** when you start producing Desktop zips.
8. **Optional SKILL.json trijection:** when a contextualizer opts into structured metadata for non-Claude consumers.

Don't write tests speculatively for invariants you haven't violated yet. Tests-as-spec means each test was earned by a real failure mode you want to never repeat.

[Next: 06-release-doctrine.md - Release checklist, CHANGELOG conventions, engine doctrine, manual cadence stance](06-release-doctrine.md)