"""OpenTranscripts v0.1 builders — turn a parsed CC session into an OT Transcript.

Spec: see ``references/open-transcripts/schemas/{transcript,events}.md`` and the
field-by-field CC → OT mapping in ``references/open-transcripts/mappings/claude-code.md``.

Conventions enforced here:
- Empty optional fields are omitted (not ``undefined``).
- Lists are always ``[]`` when empty.
- ``provider_raw`` carries the original CC line, redacted, minus fields hoisted to base.
- Event ids are stable: the CC line uuid for the first event from a line, and
  ``<uuid>:thinking:N`` / ``<uuid>:tool:N`` / ``<uuid>:spawn:N`` for sub-events when
  one CC assistant line expands into multiple OT events.
"""

from __future__ import annotations

from functools import partial
from typing import Any

from cc_jsonl import ParsedSession, ParsedSubagent
from redaction import redact

SCHEMA_VERSION = "0.1"


def _content_parts_from_blocks(blocks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Map CC content blocks to OT ContentPart[]. Only text + image blocks come through;
    tool_use / tool_result / thinking blocks are promoted to their own events upstream."""
    parts: list[dict[str, Any]] = []
    for b in blocks:
        if not isinstance(b, dict):
            continue
        t = b.get("type")
        if t == "text":
            parts.append({"type": "text", "text": b.get("text", "")})
        elif t == "image":
            src = b.get("source") or {}
            parts.append(
                {
                    "type": "image",
                    "data": src.get("data", ""),
                    "mime_type": src.get("media_type") or src.get("mime_type", ""),
                }
            )
    return parts


def _redact_line(line: dict[str, Any]) -> dict[str, Any]:
    """Strip CC fields hoisted to OT base (id, parent_id, ts), then redact the rest."""
    cleaned = {k: v for k, v in line.items() if k not in ("uuid", "parentUuid", "timestamp")}
    return redact(cleaned)


def _usage_from_assistant(message: dict[str, Any]) -> dict[str, Any] | None:
    usage = message.get("usage")
    if not isinstance(usage, dict):
        return None
    return {
        "input_tokens": usage.get("input_tokens", 0),
        "output_tokens": usage.get("output_tokens", 0),
        "cache_read_tokens": usage.get("cache_read_input_tokens"),
        "cache_write_tokens": usage.get("cache_creation_input_tokens"),
    }


def _base_event(
    line: dict[str, Any],
    event_type: str,
    *,
    id_suffix: str = "",
    parent_override: str | None = None,
    fallback_id: str = "",
    ts_override: str | None = None,
) -> dict[str, Any]:
    """Build the {id, parent_id, ts, type} base every OT event shares.

    ``fallback_id`` / ``ts_override`` cover CC lines that carry no ``uuid`` /
    ``timestamp`` (ai-title, last-prompt, pr-link, …): without them every such
    event collapsed to ``id == ""`` and ``ts == null``, breaking the schema's
    unique-id and sortable-ts invariants. The caller supplies a stable,
    deterministic fallback id and the carried-forward timestamp.
    """
    line_uuid = line.get("uuid") or fallback_id
    event_id = f"{line_uuid}{':' + id_suffix if id_suffix else ''}"
    ts = line.get("timestamp")
    if not (isinstance(ts, str) and ts):
        ts = ts_override
    return {
        "id": event_id,
        "parent_id": parent_override if parent_override is not None else line.get("parentUuid"),
        "ts": ts,
        "type": event_type,
    }


def _lines_to_events(
    lines: list[dict[str, Any]],
    subagents_by_tool_use_id: dict[str, str],
    subagent_meta_by_id: dict[str, dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Walk CC lines and emit OT events. Multiple events per assistant line when it
    contains thinking/tool_use/Task blocks.

    Returns ``(events, unmapped_lines)``. ``unmapped_lines`` is the drift signal
    the skill is meant to surface: it holds the redacted original of every line
    whose CC ``type`` the mapper could not recognize *at all*. A line that maps
    cleanly is never listed — including one that maps to a ``SystemEvent`` named
    after a known-but-event-less CC line type (``ai-title``, ``pr-link``, …).
    That distinction is the whole point: a populated ``unmapped_lines`` should
    mean the CC format actually drifted, not that the session contained routine
    metadata lines.
    """
    events: list[dict[str, Any]] = []
    unmapped_lines: list[dict[str, Any]] = []
    last_ts: str | None = None

    for idx, line in enumerate(lines):
        line_type = line.get("type")
        message = line.get("message")
        if not isinstance(message, dict):
            message = {}
        raw_content = message.get("content")
        blocks: list[dict[str, Any]]
        if isinstance(raw_content, list):
            blocks = [b for b in raw_content if isinstance(b, dict)]
        elif isinstance(raw_content, str):
            blocks = [{"type": "text", "text": raw_content}]
        else:
            blocks = []

        # Carry the last real timestamp forward: CC writes some metadata lines
        # (ai-title, last-prompt, pr-link, …) with no ``timestamp``, and an event
        # with a null ``ts`` can't be ordered. ``cc-line-<idx>`` is the matching
        # stable id fallback — those same lines also lack a ``uuid``.
        line_ts = line.get("timestamp")
        if isinstance(line_ts, str) and line_ts:
            last_ts = line_ts
        base = partial(
            _base_event, line, fallback_id=f"cc-line-{idx}", ts_override=last_ts
        )

        if line_type == "user":
            # Either a regular UserMessage or one or more ToolResults — never both.
            tool_results = [b for b in blocks if b.get("type") == "tool_result"]
            if tool_results:
                tur = line.get("toolUseResult")
                for i, b in enumerate(tool_results):
                    suffix = "" if i == 0 else f"toolresult:{i}"
                    evt = base("ToolResult", id_suffix=suffix)
                    raw_output = b.get("content")
                    if isinstance(raw_output, str):
                        output = [{"type": "text", "text": raw_output}]
                    elif isinstance(raw_output, list):
                        output = _content_parts_from_blocks(raw_output) or [
                            {"type": "text", "text": str(raw_output)}
                        ]
                    else:
                        output = []
                    evt["tool_call_id"] = b.get("tool_use_id", "")
                    evt["output"] = redact(output)
                    evt["is_error"] = bool(b.get("is_error", False))
                    evt["provider_raw"] = _redact_line(
                        {**line, "_toolUseResult": tur} if tur is not None else line
                    )
                    events.append(evt)
            else:
                evt = base("UserMessage")
                evt["content"] = redact(_content_parts_from_blocks(blocks))
                evt["provider_raw"] = _redact_line(line)
                events.append(evt)

        elif line_type == "assistant":
            text_blocks = [b for b in blocks if b.get("type") == "text"]
            thinking_blocks = [b for b in blocks if b.get("type") == "thinking"]
            tool_use_blocks = [b for b in blocks if b.get("type") == "tool_use"]

            # Always emit the AssistantMessage (carries the text content + usage + stop_reason).
            am = base("AssistantMessage")
            am["content"] = redact(_content_parts_from_blocks(text_blocks))
            am["model"] = message.get("model")
            am["stop_reason"] = message.get("stop_reason")
            usage = _usage_from_assistant(message)
            if usage is not None:
                am["usage"] = usage
            am["cost_usd"] = None
            am["provider_raw"] = _redact_line(line)
            events.append(am)
            am_id = am["id"]

            for i, b in enumerate(thinking_blocks):
                t = base("Thinking", id_suffix=f"thinking:{i}", parent_override=am_id)
                t["text"] = redact(b.get("thinking", b.get("text", "")))
                t["signature"] = b.get("signature")
                t["redacted"] = b.get("type") == "redacted_thinking" or bool(b.get("redacted", False))
                t["provider_raw"] = None
                events.append(t)

            for i, b in enumerate(tool_use_blocks):
                call = base("ToolCall", id_suffix=f"tool:{i}", parent_override=am_id)
                tool_use_id = b.get("id", "")
                call["tool_call_id"] = tool_use_id
                call["tool_name"] = b.get("name", "")
                call["arguments"] = redact(b.get("input", {}))
                call["provider_raw"] = None
                events.append(call)

                if b.get("name") in ("Task", "Agent"):
                    inp = b.get("input") or {}
                    spawn = base("SubagentSpawn", id_suffix=f"spawn:{i}", parent_override=am_id)
                    spawn["tool_call_id"] = tool_use_id
                    spawned_agent_id = subagents_by_tool_use_id.get(tool_use_id)
                    spawn["spawned_transcript_id"] = spawned_agent_id
                    meta = subagent_meta_by_id.get(spawned_agent_id or "", {})
                    spawn["subagent_type"] = meta.get("agent_type") or inp.get("subagent_type")
                    spawn["description"] = meta.get("description") or inp.get("description")
                    spawn["prompt"] = redact(inp.get("prompt", ""))
                    spawn["provider_raw"] = None
                    events.append(spawn)

        elif line_type == "system":
            if line.get("subtype") == "compact_boundary":
                # CC's auto/manual context-compaction marker is a first-class OT
                # event, not a generic SystemEvent: downstream decomposition keys
                # its "ran out of context mid-Goal" failure heuristic on
                # Compaction events, so they must actually be emitted as such.
                cm = line.get("compactMetadata")
                cm = cm if isinstance(cm, dict) else {}
                evt = base("Compaction")
                evt["summary"] = redact(str(line.get("content") or ""))
                evt["first_kept_event_id"] = None
                evt["tokens_before"] = cm.get("preTokens")
                evt["tokens_after"] = cm.get("postTokens")
                trig = cm.get("trigger")
                evt["trigger"] = trig if trig in ("auto", "manual") else None
                evt["provider_raw"] = _redact_line(line)
                events.append(evt)
            else:
                text = ""
                content_val = message.get("content")
                if isinstance(content_val, str):
                    text = content_val
                elif isinstance(content_val, list):
                    text = " ".join(
                        b.get("text", "") for b in content_val if isinstance(b, dict)
                    )
                looks_like_error = isinstance(text, str) and (
                    text.startswith("API Error") or "error" in text.lower()[:200]
                )
                if looks_like_error:
                    evt = base("Error")
                    evt["code"] = None
                    evt["message"] = redact(text)
                    evt["recoverable"] = True
                    evt["related_event_id"] = None
                    evt["provider_raw"] = _redact_line(line)
                else:
                    evt = base("SystemEvent")
                    evt["subtype"] = "system"
                    evt["payload"] = _redact_line(line)
                    evt["provider_raw"] = None
                events.append(evt)

        else:
            # A CC line with no dedicated OT event. If it carries a recognizable
            # ``type``, that's a clean map to a SystemEvent named after the type
            # — not drift. Only a line with no usable ``type`` at all is
            # "unmapped", and only that case feeds provider.raw.unmapped_lines[].
            evt = base("SystemEvent")
            if isinstance(line_type, str) and line_type:
                evt["subtype"] = line_type
            else:
                evt["subtype"] = "unmapped"
                unmapped_lines.append(redact(line))
            evt["payload"] = _redact_line(line)
            evt["provider_raw"] = None
            events.append(evt)

    # Events from leading lines that preceded the first real timestamp still
    # carry a null ``ts``; back-fill them with the earliest real one so the
    # whole array is orderable.
    first_real_ts = next((e["ts"] for e in events if e["ts"]), None)
    if first_real_ts is not None:
        for e in events:
            if e["ts"]:
                break
            e["ts"] = first_real_ts

    return events, unmapped_lines


def _final_metrics(events: list[dict[str, Any]], subagents: list[dict[str, Any]]) -> dict[str, Any]:
    in_tot = 0
    out_tot = 0
    for e in events:
        if e.get("type") == "AssistantMessage":
            u = e.get("usage") or {}
            in_tot += int(u.get("input_tokens") or 0)
            out_tot += int(u.get("output_tokens") or 0)
    for sub in subagents:
        m = sub.get("final_metrics") or {}
        in_tot += int(m.get("total_tokens_in") or 0)
        out_tot += int(m.get("total_tokens_out") or 0)

    created = None
    ended = None
    walk_targets = [events] + [sub.get("events") or [] for sub in subagents]
    for evs in walk_targets:
        if not evs:
            continue
        first_ts = evs[0].get("ts")
        last_ts = evs[-1].get("ts")
        if first_ts and (created is None or first_ts < created):
            created = first_ts
        if last_ts and (ended is None or last_ts > ended):
            ended = last_ts

    wall = 0
    if created and ended:
        try:
            from datetime import datetime

            def _parse(t: str) -> datetime:
                return datetime.fromisoformat(t.replace("Z", "+00:00"))

            wall = max(0, int((_parse(ended) - _parse(created)).total_seconds()))
        except (ValueError, TypeError):
            wall = 0

    return {
        "total_tokens_in": in_tot,
        "total_tokens_out": out_tot,
        "cost_usd": None,
        "wall_clock_s": wall,
    }


def build_transcript(
    lines: list[dict[str, Any]],
    *,
    transcript_id: str,
    parent: dict[str, str] | None,
    subagent_transcripts: list[dict[str, Any]],
    subagents_by_tool_use_id: dict[str, str],
    subagent_meta_by_id: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    """Assemble one OT Transcript document from a list of CC JSONL lines + already-built
    child transcripts."""
    first_line = lines[0] if lines else {}

    def _first(field: str) -> Any:
        for ln in lines:
            v = ln.get(field)
            if v is not None and v != "":
                return v
        return None

    cwd = _first("cwd")
    version = _first("version")

    model_default = None
    for line in lines:
        if line.get("type") == "assistant":
            msg = line.get("message")
            if isinstance(msg, dict) and isinstance(msg.get("model"), str):
                model_default = msg["model"]
                break

    events, unmapped_lines = _lines_to_events(
        lines, subagents_by_tool_use_id, subagent_meta_by_id
    )
    # Pass 4: events sorted by ts ascending. The sort is stable, so events that
    # share a timestamp — an assistant line that expands into several events, or
    # a metadata line that inherited its ts — keep their document order.
    events.sort(key=lambda e: e.get("ts") or "")

    # created_at / ended_at come from the actual event timeline, not the first
    # and last JSONL lines: CC commonly ends a session file with a metadata line
    # (ai-title, last-prompt) that has no timestamp, which would otherwise
    # collapse ended_at onto created_at.
    event_ts = [e["ts"] for e in events if e.get("ts")]
    created = event_ts[0] if event_ts else (first_line.get("timestamp") or _first("timestamp"))
    ended = event_ts[-1] if event_ts else created

    transcript: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "transcript_id": transcript_id,
        "parent": parent,
        "agent": {
            "name": "claude-code",
            "version": version,
            "model_default": model_default,
        },
        "cwd": cwd,
        "created_at": created,
        "ended_at": ended,
        "events": events,
        "subagents": subagent_transcripts,
        "final_metrics": _final_metrics(events, subagent_transcripts),
        "provider": {
            "vendor": "claude-code",
            "vendor_version": version,
            "raw": {"unmapped_lines": unmapped_lines} if unmapped_lines else None,
        },
    }
    return transcript


def session_to_transcript(session: ParsedSession) -> dict[str, Any]:
    """Top-level: turn a fully parsed CC session (parent + subagents) into one OT Transcript."""
    subagents_by_tool_use_id = {
        sub.ref.spawn_tool_use_id: sub.ref.agent_id
        for sub in session.subagents
        if sub.ref.spawn_tool_use_id
    }
    subagent_meta_by_id = {
        sub.ref.agent_id: {
            "agent_type": sub.ref.agent_type,
            "description": sub.ref.description,
        }
        for sub in session.subagents
    }

    spawn_event_lookup_built = False
    spawn_event_by_agent_id: dict[str, str] = {}

    def _resolve_spawn_event_for(parent_events: list[dict[str, Any]]) -> None:
        nonlocal spawn_event_lookup_built
        if spawn_event_lookup_built:
            return
        for evt in parent_events:
            if evt.get("type") == "SubagentSpawn":
                agent_id = evt.get("spawned_transcript_id")
                if agent_id:
                    spawn_event_by_agent_id[agent_id] = evt["id"]
        spawn_event_lookup_built = True

    # Build subagents first (recursive: but in CC we only have one level via ParsedSession;
    # nested subagents would be discoverable from the subagent JSONL itself, so we recurse
    # if any subagent line carries Task calls of its own).
    child_transcripts: list[dict[str, Any]] = []

    parent_events_preview, _ = _lines_to_events(
        session.parent_lines, subagents_by_tool_use_id, subagent_meta_by_id
    )
    _resolve_spawn_event_for(parent_events_preview)

    for sub in session.subagents:
        nested = _build_nested_session_from_subagent(sub)
        nested_transcript = session_to_transcript(nested) if nested.subagents else _build_leaf_subagent_transcript(sub)
        nested_transcript["parent"] = {
            "transcript_id": session.session_id,
            "spawn_event_id": spawn_event_by_agent_id.get(sub.ref.agent_id, ""),
        }
        child_transcripts.append(nested_transcript)

    return build_transcript(
        session.parent_lines,
        transcript_id=session.session_id,
        parent=None,
        subagent_transcripts=child_transcripts,
        subagents_by_tool_use_id=subagents_by_tool_use_id,
        subagent_meta_by_id=subagent_meta_by_id,
    )


def _build_leaf_subagent_transcript(sub: ParsedSubagent) -> dict[str, Any]:
    """Build an OT Transcript for a subagent that doesn't spawn its own subagents."""
    return build_transcript(
        sub.lines,
        transcript_id=sub.ref.agent_id,
        parent=None,  # caller fills this in
        subagent_transcripts=[],
        subagents_by_tool_use_id={},
        subagent_meta_by_id={},
    )


def _build_nested_session_from_subagent(sub: ParsedSubagent) -> ParsedSession:
    """Wrap a ParsedSubagent's lines back into a ParsedSession so the recursive
    session_to_transcript() can discover nested subagent spawns within it."""
    nested = ParsedSession(
        session_id=sub.ref.agent_id,
        jsonl_path=sub.ref.jsonl_path,
        sidecar_dir=None,
        parent_lines=sub.lines,
        subagents=[],
    )
    # Nested subagents: if the subagent JSONL contains Task tool_uses with matching
    # subagent files on disk, walk them. For v0.1 we keep this best-effort.
    from cc_jsonl import discover_subagents, iter_jsonl

    try:
        for ref in discover_subagents(sub.ref.jsonl_path):
            nested.subagents.append(
                ParsedSubagent(ref=ref, lines=list(iter_jsonl(ref.jsonl_path)))
            )
    except Exception:
        pass
    return nested


def validate_transcript(transcript: dict[str, Any]) -> list[str]:
    """Check the OpenTranscripts invariants from the transcript schema.

    Returns a list of human-readable violation strings (empty == valid) and
    recurses into ``subagents[]``. This is pass 4 of the skill's sequencing
    checklist: running it on every build means a structurally broken transcript
    is caught here, not deep inside a downstream analyzer.
    """
    from collections import Counter

    problems: list[str] = []
    tid = transcript.get("transcript_id", "?")
    events = transcript.get("events") or []

    # events[] sorted by ts ascending, every ts present.
    tss = [e.get("ts") for e in events]
    null_ts = sum(t is None for t in tss)
    if null_ts:
        problems.append(f"{tid}: {null_ts} event(s) with null ts")
    present = [t for t in tss if t is not None]
    if present != sorted(present):
        problems.append(f"{tid}: events[] not sorted by ts ascending")

    # event ids present and unique.
    ids = [e.get("id") for e in events]
    empty_ids = sum(not i for i in ids)
    if empty_ids:
        problems.append(f"{tid}: {empty_ids} event(s) with empty id")
    counts = Counter(ids)
    dupes = [i for i, n in counts.items() if i and n > 1]
    if dupes:
        problems.append(
            f"{tid}: {len(dupes)} duplicated event id(s) "
            f"(e.g. {dupes[0]!r} ×{counts[dupes[0]]})"
        )

    # every SubagentSpawn ↔ a subagents[] entry, and vice versa.
    spawn_ids = {
        e.get("spawned_transcript_id")
        for e in events
        if e.get("type") == "SubagentSpawn"
    } - {None}
    sub_ids = {s.get("transcript_id") for s in transcript.get("subagents") or []} - {None}
    if spawn_ids - sub_ids:
        problems.append(
            f"{tid}: SubagentSpawn with no subagents[] entry: {sorted(spawn_ids - sub_ids)}"
        )
    if sub_ids - spawn_ids:
        problems.append(
            f"{tid}: subagents[] entry with no SubagentSpawn: {sorted(sub_ids - spawn_ids)}"
        )

    for sub in transcript.get("subagents") or []:
        problems.extend(validate_transcript(sub))
    return problems


__all__ = [
    "session_to_transcript",
    "build_transcript",
    "validate_transcript",
    "SCHEMA_VERSION",
]
