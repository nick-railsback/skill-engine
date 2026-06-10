#!/usr/bin/env python3
"""Grounded-citation rate eval (SELF-AUDIT Check 8).

For each `needs_reference` prompt in `$CTX_ROOT/research/eval-prompts.json`,
run the contextualizer's SKILL.md as the system prompt against Claude Haiku
4.5 with a single `read_reference` tool. Grade each response on whether the
model (a) opened ≥1 reference AND (b) emitted a SHA-pinned or tag-pinned
GitHub permalink in its final response text. Surface `grounded_rate` as a
single SELF-AUDIT findings-table row.

Opt-in: SELF-AUDIT's bash entry checks `SKILL_ENGINE_RUN_EVAL` before
invoking this script. The script itself does not check the env var — it
runs whenever invoked.

Permalink regex shared with Check 7 via import from `permalink_density`.

Exit codes:
    0  PASS or N/A (no prompts, missing file, opt-in surfaced as N/A row)
    1  FAIL (grounded_rate < threshold OR schema invalid)
    2  Runner failure (every prompt errored — API key, network, etc.)
    3  ImportError on `anthropic` SDK (dependency missing)
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

# Import the canonical permalink regexes from Check 7 (single source of truth).
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from permalink_density import (  # noqa: E402
    SHA_PERMALINK_RE,
    TAG_PERMALINK_RE,
    DEFAULT_COVERAGE_THRESHOLD,
)

DEFAULT_MODEL = "claude-haiku-4-5-20251001"
DEFAULT_MAX_TOKENS = 1024
DEFAULT_MAX_TOOL_TURNS = 5
DEFAULT_PER_PROMPT_TIMEOUT_S = 60.0
# Shared with Check 7 (permalink_density) so the two coverage gates retune in
# lockstep from one constant rather than 8 scattered literals.
DEFAULT_THRESHOLD = DEFAULT_COVERAGE_THRESHOLD

# Haiku 4.5 pricing as of 2026-01.
PRICE_INPUT_PER_MTOK = 1.0
PRICE_OUTPUT_PER_MTOK = 5.0

PROMPT_PREFIX_WIDTH = 60

# Producer-side error sentinels shared with grade_record. Module-level so a
# rewording in one site can't silently demote a marker in the other.
ERR_TIMEOUT = "per-prompt timeout"
ERR_TURN_CAP = "tool-turn cap exceeded"


# ----- API key loading ---------------------------------------------------

def load_api_key(source: str) -> str:
    if source == "keychain":
        result = subprocess.run(
            ["security", "find-generic-password", "-s", "anthropic-api-key", "-w"],
            capture_output=True, text=True, check=True,
        )
        return result.stdout.strip()
    if source == "env":
        import os
        key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
        if not key:
            raise RuntimeError("ANTHROPIC_API_KEY env var is empty or unset")
        return key
    raise ValueError(f"unknown --api-key-source: {source!r}")


# ----- Schema validation -------------------------------------------------

def load_and_validate_prompts(prompts_path: Path) -> tuple[list[dict] | None, str | None]:
    """Return (prompts, error_reason).

    - (None, None)            -> file absent (N/A)
    - ([], None)              -> file present but empty prompts list (N/A)
    - (list-of-prompts, None) -> valid
    - (None, "reason")        -> schema invalid (FAIL)
    """
    if not prompts_path.is_file():
        return (None, None)
    try:
        raw = prompts_path.read_text(encoding="utf-8")
        doc = json.loads(raw)
    except (OSError, json.JSONDecodeError) as e:
        return (None, f"could not parse {prompts_path.name}: {e}")

    if not isinstance(doc, dict):
        return (None, "top-level value must be a JSON object")
    if doc.get("schema_version") != 1:
        return (None, f"missing or unsupported schema_version (got {doc.get('schema_version')!r}, want 1)")
    prompts = doc.get("prompts")
    if not isinstance(prompts, list):
        return (None, "missing 'prompts' key or 'prompts' is not a list")
    for i, p in enumerate(prompts):
        if not isinstance(p, dict):
            return (None, f"prompts[{i}] is not an object")
        for field in ("id", "category", "text"):
            if field not in p or not isinstance(p[field], str) or not p[field].strip():
                return (None, f"prompts[{i}] missing or whitespace-only field {field!r}")
    return (prompts, None)


# ----- Tool surface ------------------------------------------------------

def list_allowed_references(refs_dir: Path) -> list[str]:
    if not refs_dir.is_dir():
        return []
    # Identify references by their refs_dir-relative path, not bare basename:
    # two files with the same basename in different subdirs (references/a.md
    # and references/sub/a.md) would otherwise both surface as "a.md" in the
    # tool enum, and read_reference's first-match-wins lookup would return one
    # of them regardless of which the model intended.
    return sorted(p.relative_to(refs_dir).as_posix() for p in refs_dir.rglob("*.md"))


def build_tool_def(allowed: list[str]) -> dict[str, Any]:
    return {
        "name": "read_reference",
        "description": (
            "Read one of the on-demand reference files for this contextualizer. "
            "Use this when SKILL.md alone is insufficient. "
            "Pass the references/-relative path exactly as listed in the enum."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "filename": {
                    "type": "string",
                    "enum": allowed,
                    "description": "A references/-relative path (e.g. 'foo.md' or 'sub/bar.md').",
                }
            },
            "required": ["filename"],
        },
    }


def read_reference(refs_dir: Path, filename: str) -> str:
    """Tool implementation. `filename` is a references/-relative path (POSIX
    separators, as emitted by list_allowed_references). Rejects absolute paths,
    Windows separators, and parent-traversal, and rejects symlinks that resolve
    outside the references tree. Resolves the path directly (no rglob), so a
    duplicate basename in another subdir can no longer shadow the intended file."""
    if not filename or filename.startswith("/") or "\\" in filename:
        return f"ERROR: invalid filename: {filename!r}"
    if any(seg in ("", ".", "..") for seg in filename.split("/")):
        return f"ERROR: invalid filename: {filename!r}"
    refs_resolved = refs_dir.resolve()
    candidate = refs_dir / filename
    if not candidate.is_file():
        return f"ERROR: not a reference file: {filename!r}"
    try:
        resolved = candidate.resolve()
        resolved.relative_to(refs_resolved)
    except (OSError, ValueError):
        return f"ERROR: symlink escapes references tree: {filename!r}"
    return resolved.read_text(encoding="utf-8", errors="replace")


def build_system_prompt(library: str, skill_md: str) -> str:
    return (
        f"You are answering technical questions about {library} using the "
        f"following SKILL.md as your primary navigator. You may call the "
        f"`read_reference` tool to load specific reference files when SKILL.md "
        f"alone is insufficient. Only open references when genuinely needed.\n\n"
        "=== SKILL.md ===\n"
        f"{skill_md}\n"
        "=== end SKILL.md ==="
    )


# ----- Per-prompt loop ---------------------------------------------------

def run_prompt(
    client,
    refs_dir: Path,
    system_prompt: str,
    tool_def: dict,
    prompt: dict,
    model: str,
    max_tokens: int,
    max_tool_turns: int,
    per_prompt_timeout_s: float,
) -> dict:
    # Lazy import (not module-level): keeps the SDK off the --dry-run /
    # --mock-responses paths and preserves the exit-3 "SDK missing" contract.
    # The live path in main() already imported these, so this is a cached bind.
    import anthropic
    import httpx

    messages: list[dict[str, Any]] = [{"role": "user", "content": prompt["text"]}]
    references_opened: list[str] = []
    turns = 0
    total_input = 0
    total_output = 0
    final_text = ""
    error: str | None = None
    start = time.monotonic()
    # Single per-prompt deadline. Both the in-flight SDK timeout and the retry
    # sleep are clamped to the remaining budget so a hung call plus one retry
    # can no longer overrun per_prompt_timeout_s by ~2×+1s.
    deadline = start + per_prompt_timeout_s

    # Retry only transient failures. anthropic.APIStatusError (the prior entry)
    # is the base of every 4xx, so a bad key / malformed request (401/403/422)
    # was being retried once with an identical, never-succeeding request — a
    # wasted billable call. APIConnectionError already covers APITimeoutError.
    retriable = (
        httpx.NetworkError,
        httpx.TimeoutException,
        anthropic.APIConnectionError,
        anthropic.RateLimitError,
        anthropic.InternalServerError,
    )

    def call_api():
        attempts = 0
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise httpx.TimeoutException("per-prompt deadline exceeded")
            try:
                return client.messages.create(
                    model=model,
                    max_tokens=max_tokens,
                    system=system_prompt,
                    tools=[tool_def],
                    messages=messages,
                    timeout=remaining,
                )
            except retriable:
                attempts += 1
                # Stop if attempts are exhausted or the budget is spent.
                if attempts >= 2 or (deadline - time.monotonic()) <= 0:
                    raise
                time.sleep(min(1.0, max(0.0, deadline - time.monotonic())))

    try:
        while True:
            if time.monotonic() >= deadline:
                error = ERR_TIMEOUT
                break
            response = call_api()
            total_input += response.usage.input_tokens
            total_output += response.usage.output_tokens

            text_parts = [b.text for b in response.content if b.type == "text"]
            tool_uses = [b for b in response.content if b.type == "tool_use"]
            current_text = "\n".join(text_parts).strip()

            if response.stop_reason == "end_turn" or not tool_uses:
                final_text = current_text
                break

            turns += 1
            if turns > max_tool_turns:
                error = ERR_TURN_CAP
                final_text = current_text
                break

            messages.append({"role": "assistant", "content": response.content})
            tool_results = []
            for tu in tool_uses:
                fname = (tu.input or {}).get("filename", "")
                content = read_reference(refs_dir, fname)
                if not content.startswith("ERROR:"):
                    references_opened.append(fname)
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": tu.id,
                    "content": content,
                })
            messages.append({"role": "user", "content": tool_results})
    except Exception as e:  # noqa: BLE001
        error = f"{type(e).__name__}: {e}"

    record = {
        "prompt_id": prompt["id"],
        "category": prompt["category"],
        "prompt_text": prompt["text"],
        "references_opened": references_opened,
        "turns_used": turns,
        "final_response_text": final_text,
        "input_tokens": total_input,
        "output_tokens": total_output,
    }
    if error:
        record["error"] = error
    return record


# ----- Mock-response loop (test harness only) ----------------------------

def run_prompt_mocked(
    refs_dir: Path,
    prompt: dict,
    mock_record: dict,
) -> dict:
    """Replay a pre-recorded prompt record. Used by the test harness via
    --mock-responses; never invoked in real SELF-AUDIT runs.

    The mock record carries the same shape `run_prompt` produces. We re-key
    it onto the live prompt so prompt_id/category/text reflect the file
    under evaluation; the references_opened, final_response_text, token
    counts, turns, and optional error pass through verbatim.
    """
    record = {
        "prompt_id": prompt["id"],
        "category": prompt["category"],
        "prompt_text": prompt["text"],
        "references_opened": list(mock_record.get("references_opened", [])),
        "turns_used": int(mock_record.get("turns_used", 0)),
        "final_response_text": str(mock_record.get("final_response_text", "")),
        "input_tokens": int(mock_record.get("input_tokens", 0)),
        "output_tokens": int(mock_record.get("output_tokens", 0)),
    }
    if "error" in mock_record:
        record["error"] = str(mock_record["error"])
    return record


# ----- Grading -----------------------------------------------------------

def grade_record(record: dict) -> tuple[bool, str | None]:
    """Return (grounded, failure_marker).

    failure_marker is one of:
        None                         -> grounded
        "api-error"                  -> error field present
        "per-prompt-timeout"         -> timeout-specific
        "tool-turn-cap-exceeded"     -> turns capped
        "no-reference-opened"        -> didn't open any reference
        "no-permalink-in-response"   -> opened ≥1 ref but final text had no permalink

    Marker precedence is "timeout precedes grading; api-error precedes
    timeout" — by design. The two parts are not in tension here: `run_prompt` sets exactly one
    `error` value per record (timeout, turn-cap, or an exception string),
    so each record maps to a single marker via direct string match.
    """
    err = record.get("error")
    if err == ERR_TIMEOUT:
        return (False, "per-prompt-timeout")
    if err == ERR_TURN_CAP:
        return (False, "tool-turn-cap-exceeded")
    if err:
        return (False, "api-error")

    opened = bool(record.get("references_opened"))
    if not opened:
        return (False, "no-reference-opened")

    text = record.get("final_response_text", "")
    has_permalink = bool(SHA_PERMALINK_RE.search(text) or TAG_PERMALINK_RE.search(text))
    if not has_permalink:
        return (False, "no-permalink-in-response")

    return (True, None)


def estimate_cost(records: list[dict]) -> float:
    total_in = sum(r.get("input_tokens", 0) for r in records)
    total_out = sum(r.get("output_tokens", 0) for r in records)
    return (total_in / 1_000_000) * PRICE_INPUT_PER_MTOK + (total_out / 1_000_000) * PRICE_OUTPUT_PER_MTOK


# ----- Main --------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Grounded-citation rate eval (SELF-AUDIT Check 8).",
    )
    parser.add_argument("ctx_root", type=Path,
                        help="Contextualizer root directory (the .claude/skills/<slug>-context/ path)")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    parser.add_argument("--max-tool-turns", type=int, default=DEFAULT_MAX_TOOL_TURNS)
    parser.add_argument("--per-prompt-timeout-s", type=float, default=DEFAULT_PER_PROMPT_TIMEOUT_S)
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD,
                        help=f"grounded_rate ≥ threshold = PASS. Default {DEFAULT_THRESHOLD}.")
    parser.add_argument("--api-key-source", choices=("keychain", "env"), default="keychain")
    parser.add_argument("--dry-run", action="store_true",
                        help="Validate prompts file and exit; do not call the API.")
    parser.add_argument("--results-json", type=Path, default=None,
                        help="Write full per-prompt records to PATH.")
    # Internal-only flag for the test harness — replays pre-recorded responses.
    parser.add_argument("--mock-responses", type=Path, default=None,
                        help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    ctx_root: Path = args.ctx_root
    if not ctx_root.is_dir():
        print(f"[FAIL] grounded-rate: CTX_ROOT is not a directory: {ctx_root}")
        return 1

    prompts_path = ctx_root / "research" / "eval-prompts.json"
    refs_dir = ctx_root / "references"
    skill_md_path = ctx_root / "SKILL.md"

    # Schema validation / N/A paths.
    prompts, err = load_and_validate_prompts(prompts_path)
    if err is not None:
        print(f"[FAIL] grounded-rate: eval-prompts.json schema invalid — {err}")
        return 1
    if prompts is None:
        print("[N/A]  grounded-rate: no eval prompts defined (research/eval-prompts.json absent)")
        return 0
    if len(prompts) == 0:
        print("[N/A]  grounded-rate: eval-prompts.json has 0 prompts")
        return 0

    # --dry-run short-circuit (no API key, no network).
    if args.dry_run:
        print(f"[DRY-RUN] grounded-rate: {len(prompts)} prompt(s) parsed from {prompts_path}")
        for p in prompts:
            text_prefix = p["text"][:PROMPT_PREFIX_WIDTH]
            print(f"  {p['id']} [{p['category']}]:  {text_prefix}")
        return 0

    # Library slug for system prompt.
    library = ctx_root.name
    if library.endswith("-context"):
        library = library[: -len("-context")]

    # Skill.md presence required for live runs.
    if not skill_md_path.is_file():
        print(f"[FAIL] grounded-rate: SKILL.md not found at {skill_md_path}")
        return 1
    skill_md = skill_md_path.read_text(encoding="utf-8", errors="replace")
    allowed = list_allowed_references(refs_dir)
    if not allowed and args.mock_responses is None:
        print(f"[N/A]  grounded-rate: no .md files under {refs_dir.name}/")
        return 0

    # Mock-response path (test-harness only).
    if args.mock_responses is not None:
        try:
            mocks_doc = json.loads(args.mock_responses.read_text(encoding="utf-8"))
            mocks = mocks_doc["records"]
            if len(mocks) != len(prompts):
                print(f"[FAIL] grounded-rate: --mock-responses has {len(mocks)} records, "
                      f"expected {len(prompts)}")
                return 1
        except (OSError, json.JSONDecodeError, KeyError, TypeError) as e:
            print(f"[FAIL] grounded-rate: could not load --mock-responses: {e}")
            return 1
        records = [run_prompt_mocked(refs_dir, p, m) for p, m in zip(prompts, mocks)]
    else:
        # Live API path. Import here so --dry-run / --mock-responses don't require the SDK.
        try:
            import anthropic
            import httpx  # noqa: F401
        except ImportError:
            print("[FAIL] grounded-rate: Check 8 requires the `anthropic` Python SDK. "
                  "Install with `pip install anthropic` or skip the check by not setting "
                  "SKILL_ENGINE_RUN_EVAL.")
            return 3

        client = anthropic.Anthropic(api_key=load_api_key(args.api_key_source))

        tool_def = build_tool_def(allowed)
        system_prompt = build_system_prompt(library, skill_md)

        records: list[dict] = []
        for prompt in prompts:
            rec = run_prompt(
                client, refs_dir, system_prompt, tool_def, prompt,
                model=args.model,
                max_tokens=args.max_tokens,
                max_tool_turns=args.max_tool_turns,
                per_prompt_timeout_s=args.per_prompt_timeout_s,
            )
            records.append(rec)

    # All-errored runner-failure path: "no prompts gradable" — implemented
    # as: every record carries an `error`. An outage
    # where each prompt opens a reference and *then* errors (timeout / turn-cap
    # / APIError) is still a runner failure; the prior `not references_opened`
    # conjunct mis-reported it as a content FAIL (exit 1). Token counts don't
    # gate this.
    if records and all("error" in r for r in records):
        print("[FAIL] grounded-rate: all prompts errored — runner failure")
        for r in records:
            _, marker = grade_record(r)
            text_prefix = r["prompt_text"][:PROMPT_PREFIX_WIDTH]
            print(f"  {r['prompt_id']} [{marker}]:  {text_prefix}")
        return 2

    # Grade.
    graded: list[tuple[dict, bool, str | None]] = []
    for r in records:
        grounded, marker = grade_record(r)
        graded.append((r, grounded, marker))

    grounded_count = sum(1 for (_, g, _) in graded if g)
    total = len(records)
    rate = grounded_count / total if total else 0.0
    cost = estimate_cost(records)
    rate_pct = rate * 100
    threshold_pct = args.threshold * 100

    # Optional results sidecar. Write failures must not mask the verdict
    # line below — the API run already cost money.
    if args.results_json is not None:
        summary = {
            "grounded_rate": round(rate, 4),
            "grounded_count": grounded_count,
            "total": total,
            "threshold": args.threshold,
            "estimated_cost_usd": round(cost, 4),
        }
        try:
            args.results_json.parent.mkdir(parents=True, exist_ok=True)
            # 0o600: prompt corpora may contain sensitive questions; the
            # default umask would publish them.
            import os
            fd = os.open(
                str(args.results_json),
                os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
                0o600,
            )
            with os.fdopen(fd, "w", encoding="utf-8") as fp:
                json.dump({"summary": summary, "records": records}, fp, indent=2)
        except OSError as e:
            print(f"warning: could not write --results-json {args.results_json}: {e}",
                  file=sys.stderr)

    if rate >= args.threshold:
        print(f"[PASS] grounded-rate: {rate_pct:.1f}% ({grounded_count}/{total} prompts grounded) "
              f"≥{threshold_pct:.0f}% threshold (cost: ${cost:.2f})")
        return 0

    print(f"[FAIL] grounded-rate: {rate_pct:.1f}% ({grounded_count}/{total} prompts grounded) "
          f"below {threshold_pct:.0f}% threshold (cost: ${cost:.2f})")
    for r, grounded, marker in graded:
        if grounded:
            continue
        text_prefix = r["prompt_text"][:PROMPT_PREFIX_WIDTH]
        print(f"  {r['prompt_id']} [{marker}]:  {text_prefix}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
