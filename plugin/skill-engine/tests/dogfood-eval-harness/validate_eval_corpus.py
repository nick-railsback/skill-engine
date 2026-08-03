#!/usr/bin/env python3
"""Schema, split-arithmetic, referential-integrity, persona-balance,
template-staging, and results-artifact validator for an eval corpus tree
shaped like ``<navigator>/references/`` + ``<navigator>/evals/``.

Each subcommand checks exactly one invariant family and stays silent about
every other one, so a caller can isolate a single failure mode instead of
tripping every check at once. Every subcommand prints ``OK: ...`` on success
or one or more ``ERROR: ...`` lines naming the specific problem found, and
returns exit code 0 or 1 accordingly. No subcommand ever shells out to a
model, invokes the harness itself, or raises an uncaught exception for a
malformed or missing input.

Usage:
  validate_eval_corpus.py schema <evals-file.json>
  validate_eval_corpus.py split <train.json> <test.json>
  validate_eval_corpus.py references <train.json> <test.json> <references-dir>
  validate_eval_corpus.py persona <train.json> <test.json>
  validate_eval_corpus.py templates <evals-dir>
  validate_eval_corpus.py results <evals-dir> <note-file>
"""

import json
import math
import os
import stat
import sys

PERSONAS = ("domain-expert", "domain-naive-technical", "non-technical")
RUN_OUTCOMES = ("pass", "fail", "error")

# The two shell templates must carry the executable bit once staged; the
# HTML viewer does not need it.
TEMPLATE_FILES = (
    ("run-eval.sh", True),
    ("render-eval-results.sh", True),
    ("eval-viewer.html", False),
)

# Reassembled at runtime, the way the shipped templates guard their own
# placeholder check, so this file does not itself look like an
# unsubstituted template to a naive substitution pass over the tree.
_ph_a = "<area"
_ph_b = "-domain>"
PLACEHOLDER = _ph_a + _ph_b


def load_json(path):
    """Return (data, None) on success or (None, error-string) on failure.
    Never raises -- a missing file or invalid JSON is reported, not thrown."""
    if not os.path.isfile(path):
        return None, "file not found: {}".format(path)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        return None, "could not read {}: {}".format(path, exc)
    try:
        return json.loads(text), None
    except json.JSONDecodeError as exc:
        return None, "invalid JSON in {}: {}".format(path, exc)


def _entries_of(doc):
    """Return doc['entries'] if it is a list, else None."""
    if not isinstance(doc, dict):
        return None
    entries = doc.get("entries")
    return entries if isinstance(entries, list) else None


def check_entry_strings(entry, index, source):
    """Required non-empty string fields on one entries[] object."""
    if not isinstance(entry, dict):
        return ["{}: entries[{}] is not a JSON object".format(source, index)]
    errors = []
    for field in ("query", "expected", "notes"):
        if field not in entry:
            errors.append(
                "{}: entries[{}] is missing required field '{}'".format(source, index, field)
            )
            continue
        value = entry[field]
        if not isinstance(value, str):
            errors.append(
                "{}: entries[{}].{} must be a string, got {}".format(
                    source, index, field, type(value).__name__
                )
            )
        elif value.strip() == "":
            errors.append("{}: entries[{}].{} is an empty string".format(source, index, field))
    return errors


def validate_schema_document(data, source):
    """Errors for one evals JSON document: top-level schema_version and
    entries shape, plus every entry's required non-empty string fields."""
    if not isinstance(data, dict):
        return ["{}: top-level JSON value is not an object".format(source)]

    errors = []

    if "schema_version" not in data:
        errors.append("{}: missing top-level 'schema_version' field".format(source))
    else:
        sv = data["schema_version"]
        # bool is a subclass of int in Python; JSON true/false must not pass
        # as an integer schema_version.
        if isinstance(sv, bool) or not isinstance(sv, int):
            errors.append(
                "{}: schema_version must be a JSON integer >= 1, got {} ({!r})".format(
                    source, type(sv).__name__, sv
                )
            )
        elif sv < 1:
            errors.append("{}: schema_version must be >= 1, got {}".format(source, sv))

    if "entries" not in data:
        errors.append("{}: missing top-level 'entries' array".format(source))
    elif not isinstance(data["entries"], list):
        errors.append(
            "{}: 'entries' must be an array, got {}".format(
                source, type(data["entries"]).__name__
            )
        )
    else:
        for i, entry in enumerate(data["entries"]):
            errors.extend(check_entry_strings(entry, i, source))

    return errors


def cmd_schema(argv):
    if len(argv) != 1:
        print("ERROR: usage: schema <evals-file.json>")
        return 1
    path = argv[0]
    data, err = load_json(path)
    if err:
        print("ERROR: {}".format(err))
        return 1
    errors = validate_schema_document(data, path)
    if errors:
        for e in errors:
            print("ERROR: {}".format(e))
        return 1
    print(
        "OK: {} is a schema-valid eval document ({} entries)".format(
            path, len(data["entries"])
        )
    )
    return 0


def _round_half_up(x):
    return math.floor(x + 0.5)


def cmd_split(argv):
    if len(argv) != 2:
        print("ERROR: usage: split <train.json> <test.json>")
        return 1
    train_path, test_path = argv
    train, err_t = load_json(train_path)
    test, err_e = load_json(test_path)
    if err_t or err_e:
        for e in (err_t, err_e):
            if e:
                print("ERROR: {}".format(e))
        return 1

    train_entries = _entries_of(train)
    test_entries = _entries_of(test)
    if train_entries is None or test_entries is None:
        print("ERROR: both files must carry an 'entries' array before split arithmetic can be checked")
        return 1

    def queries(entries):
        return [
            e.get("query")
            for e in entries
            if isinstance(e, dict) and isinstance(e.get("query"), str)
        ]

    train_queries = queries(train_entries)
    test_queries = queries(test_entries)

    dupes = sorted(set(train_queries) & set(test_queries))
    problems = []
    for q in dupes:
        problems.append(
            "query appears in both train and test files (not disjoint): {!r}".format(q)
        )

    combined = len(train_entries) + len(test_entries)
    if combined <= 10:
        problems.append(
            "combined entry count {} does not exceed the ten-entry split threshold".format(
                combined
            )
        )

    expected_test_count = _round_half_up(0.3 * combined)
    if len(test_entries) != expected_test_count:
        problems.append(
            "test file has {} entries; expected {} (nearest-integer rounding of 30% of {} combined)".format(
                len(test_entries), expected_test_count, combined
            )
        )

    if problems:
        for p in problems:
            print("ERROR: {}".format(p))
        return 1
    print(
        "OK: {} train + {} test = {} combined, disjoint, test count matches the 30% split".format(
            len(train_entries), len(test_entries), combined
        )
    )
    return 0


def cmd_references(argv):
    if len(argv) != 3:
        print("ERROR: usage: references <train.json> <test.json> <references-dir>")
        return 1
    train_path, test_path, refs_dir = argv
    train, err_t = load_json(train_path)
    test, err_e = load_json(test_path)
    if err_t or err_e:
        for e in (err_t, err_e):
            if e:
                print("ERROR: {}".format(e))
        return 1
    if not os.path.isdir(refs_dir):
        print("ERROR: references directory not found: {}".format(refs_dir))
        return 1

    on_disk = set()
    for name in os.listdir(refs_dir):
        if name.endswith(".md"):
            on_disk.add(name[: -len(".md")])

    errors = []
    for source, doc in (("train", train), ("test", test)):
        entries = _entries_of(doc)
        if entries is None:
            errors.append("{}: no 'entries' array to check".format(source))
            continue
        for i, entry in enumerate(entries):
            if not isinstance(entry, dict):
                continue
            expected = entry.get("expected")
            if not isinstance(expected, str) or expected not in on_disk:
                errors.append(
                    "{} entries[{}]: expected {!r} has no matching references/<name>.md on disk".format(
                        source, i, expected
                    )
                )

    if errors:
        for e in errors:
            print("ERROR: {}".format(e))
        return 1
    print("OK: every expected value across train and test matches a references/*.md file")
    return 0


def cmd_persona(argv):
    if len(argv) != 2:
        print("ERROR: usage: persona <train.json> <test.json>")
        return 1
    train_path, test_path = argv
    train, err_t = load_json(train_path)
    test, err_e = load_json(test_path)
    if err_t or err_e:
        for e in (err_t, err_e):
            if e:
                print("ERROR: {}".format(e))
        return 1

    errors = []
    counts = {p: 0 for p in PERSONAS}
    combined = 0
    for source, doc in (("train", train), ("test", test)):
        entries = _entries_of(doc)
        if entries is None:
            errors.append("{}: no 'entries' array to check".format(source))
            continue
        for i, entry in enumerate(entries):
            if not isinstance(entry, dict):
                continue
            combined += 1
            persona = entry.get("persona")
            if persona not in PERSONAS:
                errors.append(
                    "{} entries[{}]: persona {!r} is not one of {}".format(
                        source, i, persona, PERSONAS
                    )
                )
            else:
                counts[persona] += 1

    if combined == 0:
        errors.append("no entries found across train and test to check persona balance")
    else:
        for persona in PERSONAS:
            count = counts[persona]
            if count > combined / 2.0:
                errors.append(
                    "persona {!r} accounts for {}/{} entries, more than half the combined corpus".format(
                        persona, count, combined
                    )
                )
            if count < 2:
                errors.append(
                    "persona {!r} appears only {} time(s) across the combined corpus; at least 2 required".format(
                        persona, count
                    )
                )

    if errors:
        for e in errors:
            print("ERROR: {}".format(e))
        return 1
    print("OK: persona field valid on every entry and balanced across {}".format(PERSONAS))
    return 0


def cmd_templates(argv):
    if len(argv) != 1:
        print("ERROR: usage: templates <evals-dir>")
        return 1
    evals_dir = argv[0]
    errors = []
    for filename, must_be_executable in TEMPLATE_FILES:
        path = os.path.join(evals_dir, filename)
        if not os.path.isfile(path):
            errors.append("missing staged template: {}".format(filename))
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                content = fh.read()
        except OSError as exc:
            errors.append("could not read {}: {}".format(filename, exc))
            continue
        if PLACEHOLDER in content:
            errors.append(
                "{} still contains the unsubstituted {} placeholder".format(filename, PLACEHOLDER)
            )
        if must_be_executable:
            mode = os.stat(path).st_mode
            if not (mode & stat.S_IXUSR):
                errors.append("{} is not executable (owner execute bit is not set)".format(filename))

    if errors:
        for e in errors:
            print("ERROR: {}".format(e))
        return 1
    print("OK: all three templates are staged, placeholder-free, and correctly executable")
    return 0


def _validate_results_shape(data, source):
    if not isinstance(data, dict):
        return ["{}: top-level JSON value is not an object".format(source)]

    errors = []
    navigator = data.get("navigator")
    if not isinstance(navigator, str) or navigator.strip() == "":
        errors.append("{}: missing or empty 'navigator' identifier".format(source))

    entries = data.get("entries")
    if not isinstance(entries, list) or len(entries) == 0:
        errors.append("{}: missing or empty per-entry 'entries' run-record array".format(source))
        return errors

    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            errors.append("{}: entries[{}] is not a JSON object".format(source, i))
            continue
        query = entry.get("query")
        if not isinstance(query, str) or query.strip() == "":
            errors.append("{}: entries[{}] is missing a non-empty 'query'".format(source, i))
        runs = entry.get("runs")
        if not isinstance(runs, list) or len(runs) == 0:
            errors.append("{}: entries[{}] is missing a non-empty 'runs' record array".format(source, i))
        else:
            for j, outcome in enumerate(runs):
                if outcome not in RUN_OUTCOMES:
                    errors.append(
                        "{}: entries[{}].runs[{}] is {!r}, not one of {}".format(
                            source, i, j, outcome, RUN_OUTCOMES
                        )
                    )
    return errors


def cmd_results(argv):
    if len(argv) != 2:
        print("ERROR: usage: results <evals-dir> <note-file>")
        return 1
    evals_dir, note_path = argv
    errors = []

    if not os.path.isdir(evals_dir):
        print("ERROR: evals directory not found: {}".format(evals_dir))
        return 1

    matches = sorted(
        name
        for name in os.listdir(evals_dir)
        if name.startswith("results-") and name.endswith(".json")
    )
    if not matches:
        errors.append("no results-*.json file found under {}".format(evals_dir))
    else:
        results_path = os.path.join(evals_dir, matches[0])
        data, err = load_json(results_path)
        if err:
            errors.append(err)
        else:
            errors.extend(_validate_results_shape(data, matches[0]))

    if not os.path.isfile(note_path):
        errors.append("no run note found at {}".format(note_path))
    else:
        note_text = None
        try:
            with open(note_path, "r", encoding="utf-8") as fh:
                note_text = fh.read()
        except (OSError, UnicodeDecodeError) as exc:
            errors.append("run note at {} is not parseable text: {}".format(note_path, exc))
        if note_text is not None and note_text.strip() == "":
            errors.append("run note at {} is empty".format(note_path))

    if errors:
        for e in errors:
            print("ERROR: {}".format(e))
        return 1
    print("OK: a parseable results-*.json and a non-empty run note both exist under {}".format(evals_dir))
    return 0


COMMANDS = {
    "schema": cmd_schema,
    "split": cmd_split,
    "references": cmd_references,
    "persona": cmd_persona,
    "templates": cmd_templates,
    "results": cmd_results,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print("ERROR: usage: validate_eval_corpus.py <{}> ...".format("|".join(COMMANDS)))
        return 1
    try:
        return COMMANDS[argv[0]](argv[1:])
    except Exception as exc:  # last-resort: never let a bug surface as a bare traceback
        print("ERROR: unexpected validator failure: {}: {}".format(type(exc).__name__, exc))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
