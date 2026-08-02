"""Fake Anthropic SDK stand-in for the eval-runs-and-flicker suite.

Provides just enough surface for grounded_rate.py's live code path (the
one taken when neither --dry-run nor --mock-responses is given) to run
end-to-end with zero network I/O and no real credentials: a
messages.create() that returns a canned, permalink-free, no-tool-use
response and appends one line to $FAKE_SDK_CALL_LOG per invocation.

The call-log line count is this suite's only way to observe "how many
model calls did one grading invocation issue" without spending real API
budget — it stands in for a live call the same way a golden file stands
in for a live server response elsewhere.

Loaded by putting this file's directory first on PYTHONPATH, so it
shadows any real `anthropic` package installed in the test environment.
"""
import os

_CALL_LOG = os.environ.get("FAKE_SDK_CALL_LOG")


class APIConnectionError(Exception):
    pass


class RateLimitError(Exception):
    pass


class InternalServerError(Exception):
    pass


class APIStatusError(Exception):
    pass


class _Usage:
    def __init__(self, input_tokens, output_tokens):
        self.input_tokens = input_tokens
        self.output_tokens = output_tokens


class _TextBlock:
    type = "text"

    def __init__(self, text):
        self.text = text


class _Response:
    def __init__(self, text):
        self.usage = _Usage(10, 5)
        self.content = [_TextBlock(text)]
        self.stop_reason = "end_turn"


class _Messages:
    def create(self, **kwargs):
        if _CALL_LOG:
            with open(_CALL_LOG, "a", encoding="utf-8") as f:
                f.write("call\n")
        # Deliberately permalink-free and tool-use-free: this fake only
        # needs to be counted, never graded.
        return _Response("No citation in this canned reply.")


class Anthropic:
    def __init__(self, api_key=None):
        self.api_key = api_key
        self.messages = _Messages()
