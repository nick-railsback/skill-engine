"""Fake httpx stand-in, paired with the fake anthropic.py in this directory.

grounded_rate.py references exactly two names from httpx (both exception
classes used to classify retriable transport failures). The fake
Anthropic client's canned response never raises them; these exist purely
so the module-level `import httpx` succeeds offline.
"""


class NetworkError(Exception):
    pass


class TimeoutException(Exception):
    pass
