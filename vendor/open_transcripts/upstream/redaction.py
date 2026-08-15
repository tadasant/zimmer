"""Secret-redaction for OpenTranscripts.

Patterns are deliberately conservative — false positives are preferable to leaking
credentials into a JSON document that downstream tools, browsers, or LLMs will see.

Provenance: derived from the patterns shipped in
pulsemcp/agentic-engineering-infra's transcript-export.py.
"""

from __future__ import annotations

import re
from typing import Any

# Each entry is (label, compiled_regex). Order matters only for overlapping matches;
# the highest-signal patterns come first so they win when redaction summaries are
# tallied by label.
_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    # Anthropic
    ("ANTHROPIC_API_KEY", re.compile(r"sk-ant-[A-Za-z0-9_\-]{32,}")),
    # OpenAI
    ("OPENAI_API_KEY", re.compile(r"sk-(?:proj-)?[A-Za-z0-9_\-]{20,}")),
    # GitHub (PAT, fine-grained, OAuth, app, server-side)
    ("GITHUB_TOKEN", re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}")),
    ("GITHUB_TOKEN", re.compile(r"github_pat_[A-Za-z0-9_]{20,}")),
    # AWS
    ("AWS_ACCESS_KEY_ID", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    (
        "AWS_SECRET_ACCESS_KEY",
        re.compile(
            r"(?i)aws_secret_access_key\s*[:=]\s*[\"']?([A-Za-z0-9/+=]{40})[\"']?"
        ),
    ),
    # Google
    ("GOOGLE_API_KEY", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    # Stripe
    ("STRIPE_KEY", re.compile(r"\b(?:sk|rk|pk)_(?:live|test)_[0-9a-zA-Z]{16,}\b")),
    # Slack
    ("SLACK_TOKEN", re.compile(r"\bxox[abprs]-[A-Za-z0-9\-]{10,}\b")),
    # npm
    ("NPM_TOKEN", re.compile(r"\bnpm_[A-Za-z0-9]{30,}\b")),
    # JWT (three dot-separated base64url chunks; the middle one decodes to JSON)
    (
        "JWT",
        re.compile(r"\bey[A-Za-z0-9_\-]{10,}\.ey[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"),
    ),
    # Bearer tokens in Authorization headers
    ("BEARER_TOKEN", re.compile(r"(?i)\bbearer\s+[A-Za-z0-9_\-\.=]{20,}")),
    # PEM private keys (preserve the header so it's obvious what was scrubbed)
    (
        "PRIVATE_KEY",
        re.compile(
            r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----[\s\S]+?-----END (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"
        ),
    ),
    # Generic env-var-style secrets — only when the *name* looks sensitive and the
    # *value* looks high-entropy. Capture group 1 is the value; group 0 is rewritten.
    (
        "ENV_SECRET",
        re.compile(
            r"(?i)\b(?:api[_-]?key|secret(?:[_-]?key)?|password|passwd|token|access[_-]?key|private[_-]?key|client[_-]?secret|auth[_-]?token|session[_-]?token)\s*[:=]\s*[\"']?([A-Za-z0-9+/=_\-]{16,})[\"']?"
        ),
    ),
    # Database connection strings with embedded passwords
    (
        "DB_CONNECTION_STRING",
        re.compile(
            r"(?i)\b(?:postgres|postgresql|mysql|mongodb(?:\+srv)?|redis|amqp|amqps)://[^:\s]+:[^@\s]+@[^\s]+"
        ),
    ),
]


def redact_string(s: str, summary: dict[str, int] | None = None) -> str:
    """Apply every pattern; return the redacted string.

    If ``summary`` is provided, increment its counts by pattern label.
    """
    if not s:
        return s
    out = s
    for label, pattern in _PATTERNS:
        def _replace(m: re.Match[str], _label: str = label) -> str:
            if summary is not None:
                summary[_label] = summary.get(_label, 0) + 1
            if _label == "ENV_SECRET":
                # Preserve the env var name; redact only the value (group 1).
                value = m.group(1)
                return m.group(0).replace(value, f"<REDACTED:{_label}>")
            if _label == "DB_CONNECTION_STRING":
                # Keep scheme + host for debuggability; scrub credentials.
                return re.sub(r"://[^:\s]+:[^@\s]+@", "://<REDACTED:DB_CREDS>@", m.group(0))
            return f"<REDACTED:{_label}>"

        out = pattern.sub(_replace, out)
    return out


def redact(value: Any, summary: dict[str, int] | None = None) -> Any:
    """Recursively redact every string in a JSON-like value.

    Dict keys are preserved as-is; only values are redacted. ``summary`` is updated
    in place if provided.
    """
    if isinstance(value, str):
        return redact_string(value, summary)
    if isinstance(value, list):
        return [redact(v, summary) for v in value]
    if isinstance(value, dict):
        return {k: redact(v, summary) for k, v in value.items()}
    return value


__all__ = ["redact", "redact_string"]
