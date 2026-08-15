"""Claude Code JSONL utilities — parsing + subagent file resolution.

Pure stdlib. Knows the on-disk layout of `~/.claude/projects/<project>/...` and the
4-field subagent linkage chain documented in
`references/open-transcripts/mappings/claude-code.md`.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterator


@dataclass
class SubagentRef:
    """Resolved subagent linkage."""

    agent_id: str
    jsonl_path: Path
    meta_path: Path | None
    agent_type: str | None
    description: str | None
    spawn_tool_use_id: str | None  # toolu_xxx from the parent's Task tool_use
    spawn_line_uuid: str | None  # parent JSONL line uuid carrying the spawn


@dataclass
class ParsedSession:
    """A parent session JSONL + all linked subagent JSONLs."""

    session_id: str
    jsonl_path: Path
    sidecar_dir: Path | None
    parent_lines: list[dict[str, Any]] = field(default_factory=list)
    subagents: list["ParsedSubagent"] = field(default_factory=list)


@dataclass
class ParsedSubagent:
    """A subagent's transcript + its linkage to the parent."""

    ref: SubagentRef
    lines: list[dict[str, Any]] = field(default_factory=list)


def iter_jsonl(path: Path) -> Iterator[dict[str, Any]]:
    """Yield parsed JSON objects from a JSONL file, skipping malformed lines."""
    with path.open("r", encoding="utf-8") as f:
        for n, raw in enumerate(f, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                yield json.loads(raw)
            except json.JSONDecodeError as e:
                print(f"WARN: {path}:{n}: skipping malformed JSON ({e})", flush=True)
                continue


def project_root() -> Path:
    """Return ``~/.claude/projects/`` (the root of all CC project session dirs)."""
    return Path.home() / ".claude" / "projects"


def list_sessions(root: Path | None = None) -> list[dict[str, Any]]:
    """Enumerate all session JSONLs across all project dirs.

    Each entry: ``{project_slug, session_id, jsonl_path, size_bytes, mtime}``.
    Sorted by mtime descending so newer sessions float to the top.
    """
    root = root or project_root()
    results: list[dict[str, Any]] = []
    if not root.exists():
        return results
    for project_dir in root.iterdir():
        if not project_dir.is_dir():
            continue
        for jsonl in project_dir.glob("*.jsonl"):
            try:
                st = jsonl.stat()
            except OSError:
                continue
            results.append(
                {
                    "project_slug": project_dir.name,
                    "session_id": jsonl.stem,
                    "jsonl_path": str(jsonl),
                    "size_bytes": st.st_size,
                    "mtime": st.st_mtime,
                }
            )
    results.sort(key=lambda r: r["mtime"], reverse=True)
    return results


def resolve_subagent_path(parent_jsonl: Path, agent_id: str) -> tuple[Path | None, Path | None]:
    """Return ``(jsonl_path, meta_path)`` for a subagent, or ``(None, None)`` if not found.

    Tries the current layout first (``<session-uuid>/subagents/agent-<id>.jsonl``)
    then falls back to the legacy sibling layout (``<agent-id>.jsonl``).
    """
    session_id = parent_jsonl.stem
    sidecar = parent_jsonl.parent / session_id / "subagents"
    candidate = sidecar / f"agent-{agent_id}.jsonl"
    if candidate.exists():
        meta = sidecar / f"agent-{agent_id}.meta.json"
        return candidate, meta if meta.exists() else None
    legacy = parent_jsonl.parent / f"{agent_id}.jsonl"
    if legacy.exists():
        return legacy, None
    legacy_prefixed = parent_jsonl.parent / f"agent-{agent_id}.jsonl"
    if legacy_prefixed.exists():
        return legacy_prefixed, None
    return None, None


def _iter_content_blocks(line: dict[str, Any]) -> Iterator[dict[str, Any]]:
    msg = line.get("message")
    if not isinstance(msg, dict):
        return
    content = msg.get("content")
    if isinstance(content, list):
        for c in content:
            if isinstance(c, dict):
                yield c
    elif isinstance(content, str):
        # Older CC sometimes wrote bare strings as content.
        yield {"type": "text", "text": content}


def discover_subagents(parent_jsonl: Path) -> list[SubagentRef]:
    """Walk the parent JSONL once and resolve every Task → subagent linkage.

    Builds ``toolu_xxx → SubagentRef`` from the canonical 4-field chain:
      1. assistant ``tool_use`` with ``name="Task"`` and ``id=toolu_xxx``
      2. user ``tool_result`` with ``tool_use_id=toolu_xxx``; sibling
         ``toolUseResult.agentId`` on the same line names the agent.
      3. ``<session-uuid>/subagents/agent-<agentId>.jsonl`` is the child file.
      4. Every line in that file carries ``agentId=<agentId>``.

    Returns one ``SubagentRef`` per resolved spawn, in the order they appear in the parent.
    """
    pending: dict[str, dict[str, Any]] = {}  # toolu_xxx → {description, agent_type, spawn_line_uuid}
    refs: list[SubagentRef] = []
    seen_agent_ids: set[str] = set()

    for line in iter_jsonl(parent_jsonl):
        line_uuid = line.get("uuid")
        for block in _iter_content_blocks(line):
            btype = block.get("type")
            if btype == "tool_use" and block.get("name") in ("Task", "Agent"):
                tool_use_id = block.get("id")
                inp = block.get("input") or {}
                if isinstance(tool_use_id, str):
                    pending[tool_use_id] = {
                        "agent_type": inp.get("subagent_type"),
                        "description": inp.get("description"),
                        "spawn_line_uuid": line_uuid,
                    }
            elif btype == "tool_result":
                tool_use_id = block.get("tool_use_id")
                if not isinstance(tool_use_id, str):
                    continue
                tur = line.get("toolUseResult")
                if not isinstance(tur, dict):
                    continue
                agent_id = tur.get("agentId")
                if not isinstance(agent_id, str) or agent_id in seen_agent_ids:
                    continue
                seen_agent_ids.add(agent_id)
                meta_from_pending = pending.get(tool_use_id, {})
                jsonl_path, meta_path = resolve_subagent_path(parent_jsonl, agent_id)
                if jsonl_path is None:
                    print(
                        f"WARN: subagent {agent_id} referenced by {tool_use_id} but no JSONL found",
                        flush=True,
                    )
                    continue
                agent_type = tur.get("agentType") or meta_from_pending.get("agent_type")
                description = meta_from_pending.get("description")
                if meta_path and meta_path.exists():
                    try:
                        with meta_path.open("r", encoding="utf-8") as f:
                            meta_doc = json.load(f)
                        agent_type = meta_doc.get("agentType") or agent_type
                        description = meta_doc.get("description") or description
                    except (OSError, json.JSONDecodeError):
                        pass
                refs.append(
                    SubagentRef(
                        agent_id=agent_id,
                        jsonl_path=jsonl_path,
                        meta_path=meta_path,
                        agent_type=agent_type,
                        description=description,
                        spawn_tool_use_id=tool_use_id,
                        spawn_line_uuid=meta_from_pending.get("spawn_line_uuid"),
                    )
                )
    return refs


def parse_session(parent_jsonl: Path, *, recursive: bool = True) -> ParsedSession:
    """Load a parent JSONL and every linked subagent JSONL into a single in-memory tree."""
    session = ParsedSession(
        session_id=parent_jsonl.stem,
        jsonl_path=parent_jsonl,
        sidecar_dir=(parent_jsonl.parent / parent_jsonl.stem)
        if (parent_jsonl.parent / parent_jsonl.stem).is_dir()
        else None,
        parent_lines=list(iter_jsonl(parent_jsonl)),
    )
    if recursive:
        for ref in discover_subagents(parent_jsonl):
            sub = ParsedSubagent(ref=ref, lines=list(iter_jsonl(ref.jsonl_path)))
            session.subagents.append(sub)
    return session


def load_spilled_tool_result(parent_jsonl: Path, tool_use_id: str) -> str | None:
    """If a tool_result body was spilled to ``<session-uuid>/tool-results/<id>.txt``,
    return its contents. Otherwise ``None``."""
    spillover = parent_jsonl.parent / parent_jsonl.stem / "tool-results" / f"{tool_use_id}.txt"
    if not spillover.exists():
        return None
    try:
        return spillover.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


__all__ = [
    "SubagentRef",
    "ParsedSession",
    "ParsedSubagent",
    "iter_jsonl",
    "project_root",
    "list_sessions",
    "resolve_subagent_path",
    "discover_subagents",
    "parse_session",
    "load_spilled_tool_result",
]
