#!/usr/bin/env python3
"""AgentHearth remote metadata collector.

This helper runs on an SSH host and emits only normalized session metadata.
Prompt bodies, responses, tool payloads, and source files are never serialized.
It uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import hmac
import json
import os
import secrets
import shutil
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterable

SCHEMA_VERSION = 1
VERSION = "0.2.0"
PORT = 5274
HOME = Path.home()
STATE_DIR = HOME / ".local" / "state" / "agenthearth"
DATA_DIR = HOME / ".local" / "share" / "agenthearth"
PID_PATH = STATE_DIR / "collector.pid"
MAX_AGE_SECONDS = 7 * 24 * 60 * 60
STUCK_SECONDS = 15 * 60
HISTORY_RETENTION_DAYS = 90
HISTORY_DB_PATH = STATE_DIR / "history.sqlite"
TOKEN_PATH = HOME / ".config" / "agenthearth" / "ingress-token"
TOKEN_HEADER = "X-AgentHearth-Token"


def now_ms() -> int:
    return int(time.time() * 1000)


def load_or_create_token() -> str:
    """Per-host shared secret the local connectors present to the collector.

    Written 0600 in a 0700 directory. Because a co-resident user cannot read it
    and a browser cannot set the custom header, requiring it closes the
    cross-origin (CSRF) and other-local-user spoofing paths into the collector.
    """
    try:
        existing = TOKEN_PATH.read_text(encoding="utf-8").strip()
        if existing:
            return existing
    except OSError:
        pass
    token = secrets.token_hex(32)
    TOKEN_PATH.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = TOKEN_PATH.with_suffix(".tmp")
    temporary.write_text(token, encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(TOKEN_PATH)
    return token


def milliseconds(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        numeric = float(value)
        return int(numeric if numeric > 10_000_000_000 else numeric * 1000)
    if not isinstance(value, str):
        return None
    try:
        normalized = value.replace("Z", "+00:00")
        return int(dt.datetime.fromisoformat(normalized).timestamp() * 1000)
    except ValueError:
        return None


def safe_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def atomic_json(path: Path, value: Any) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def bounded_jsonl(path: Path, head_limit: int = 64 * 1024, tail_limit: int = 512 * 1024) -> list[dict[str, Any]]:
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            head = handle.read(min(size, head_limit))
            tail_start = max(0, size - tail_limit)
            handle.seek(tail_start)
            tail = handle.read(tail_limit)
    except OSError:
        return []
    if tail_start > 0 and b"\n" in tail:
        tail = tail.split(b"\n", 1)[1]
    chunks = [head]
    if tail_start > len(head):
        chunks.append(tail)
    elif len(tail) > len(head):
        chunks = [tail]
    records: list[dict[str, Any]] = []
    seen: set[bytes] = set()
    for chunk in chunks:
        for line in chunk.splitlines():
            if not line or line in seen:
                continue
            seen.add(line)
            try:
                value = json.loads(line)
            except (UnicodeDecodeError, ValueError):
                continue
            if isinstance(value, dict):
                records.append(value)
    return records


def cache_unknown() -> dict[str, Any]:
    return {
        "temperature": "unknown",
        "remaining_seconds": None,
        "ttl_seconds": None,
        "input_tokens": None,
        "output_tokens": None,
        "cached_read_tokens": None,
        "cache_write_tokens": None,
        "last_confirmed_at": None,
        "confidence": "unknown",
        "reason": None,
    }


def health_snapshot(
    hits: int,
    misses: int,
    cold: int,
    unknown: int,
    measured_at: int,
    observed_input_tokens: int | None = None,
    cached_input_tokens: int | None = None,
) -> dict[str, Any] | None:
    if hits + misses + cold + unknown == 0:
        return None
    return {
        "hit_count": hits,
        "avoidable_miss_count": misses,
        "expected_cold_start_count": cold,
        "unknown_count": unknown,
        "measured_at": measured_at,
        "observed_input_tokens": observed_input_tokens,
        "cached_input_tokens": cached_input_tokens,
    }


def history_connection() -> sqlite3.Connection:
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    connection = sqlite3.connect(HISTORY_DB_PATH, timeout=5)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA synchronous=NORMAL")
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS cache_events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          provider TEXT NOT NULL,
          session_id TEXT NOT NULL,
          title TEXT NOT NULL,
          model TEXT,
          occurred_at_ms INTEGER NOT NULL,
          hits INTEGER NOT NULL,
          misses INTEGER NOT NULL,
          cold_starts INTEGER NOT NULL,
          unknown INTEGER NOT NULL,
          current_hits INTEGER NOT NULL,
          current_misses INTEGER NOT NULL,
          current_cold_starts INTEGER NOT NULL,
          current_unknown INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS cache_events_provider_id
          ON cache_events(provider, id);
        CREATE INDEX IF NOT EXISTS cache_events_time
          ON cache_events(occurred_at_ms);
        CREATE TABLE IF NOT EXISTS session_state (
          session_key TEXT PRIMARY KEY,
          hits INTEGER NOT NULL,
          misses INTEGER NOT NULL,
          cold_starts INTEGER NOT NULL,
          unknown INTEGER NOT NULL,
          updated_at_ms INTEGER NOT NULL
        );
        """
    )
    return connection


def counter_delta(current: int, previous: int | None) -> int:
    if previous is None or current < previous:
        return current
    return current - previous


def record_history_sessions(provider: str, sessions: list[dict[str, Any]]) -> None:
    try:
        connection = history_connection()
        with connection:
            for session in sessions:
                health = session.get("cache_health")
                session_id = str(session.get("id") or "")
                if not session_id or not isinstance(health, dict):
                    continue
                current = (
                    max(0, int(health.get("hit_count") or 0)),
                    max(0, int(health.get("avoidable_miss_count") or 0)),
                    max(0, int(health.get("expected_cold_start_count") or 0)),
                    max(0, int(health.get("unknown_count") or 0)),
                )
                key = f"{provider}:{session_id}"
                previous = connection.execute(
                    "SELECT hits,misses,cold_starts,unknown FROM session_state WHERE session_key=?",
                    (key,),
                ).fetchone()
                deltas = tuple(
                    counter_delta(value, previous[index] if previous else None)
                    for index, value in enumerate(current)
                )
                occurred_at = int(health.get("measured_at") or session.get("last_activity_at") or now_ms())
                if sum(deltas) > 0:
                    connection.execute(
                        """
                        INSERT INTO cache_events(
                          provider,session_id,title,model,occurred_at_ms,
                          hits,misses,cold_starts,unknown,
                          current_hits,current_misses,current_cold_starts,current_unknown
                        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """,
                        (
                            provider,
                            session_id,
                            str(session.get("title") or session_id),
                            session.get("model"),
                            occurred_at,
                            *deltas,
                            *current,
                        ),
                    )
                connection.execute(
                    """
                    INSERT INTO session_state VALUES(?,?,?,?,?,?)
                    ON CONFLICT(session_key) DO UPDATE SET
                      hits=excluded.hits, misses=excluded.misses,
                      cold_starts=excluded.cold_starts, unknown=excluded.unknown,
                      updated_at_ms=excluded.updated_at_ms
                    """,
                    (key, *current, occurred_at),
                )
            cutoff = now_ms() - HISTORY_RETENTION_DAYS * 86_400_000
            connection.execute("DELETE FROM cache_events WHERE occurred_at_ms < ?", (cutoff,))
            connection.execute("DELETE FROM session_state WHERE updated_at_ms < ?", (cutoff,))
        connection.close()
    except (OSError, sqlite3.Error, TypeError, ValueError):
        # History must never prevent the live collector from answering.
        return


def history_events(provider_argument: str, after_id: int, limit: int) -> dict[str, Any]:
    provider = {
        "codex": "codex",
        "opencode": "openCode",
        "claude-code": "claudeCode",
    }[provider_argument]
    try:
        connection = history_connection()
        rows = connection.execute(
            """
            SELECT id,provider,session_id,title,model,occurred_at_ms,
                   hits,misses,cold_starts,unknown,
                   current_hits,current_misses,current_cold_starts,current_unknown
            FROM cache_events
            WHERE provider=? AND id>?
            ORDER BY id ASC LIMIT ?
            """,
            (provider, max(0, after_id), max(1, min(limit, 5000))),
        ).fetchall()
        connection.close()
    except (OSError, sqlite3.Error):
        rows = []
    events = [
        {
            "id": row[0], "provider": row[1], "session_id": row[2],
            "title": row[3], "model": row[4], "occurred_at": row[5],
            "hit_count": row[6], "miss_count": row[7],
            "cold_start_count": row[8], "unknown_count": row[9],
            "current_hit_count": row[10], "current_miss_count": row[11],
            "current_cold_start_count": row[12], "current_unknown_count": row[13],
        }
        for row in rows
    ]
    return {
        "schema_version": SCHEMA_VERSION,
        "next_cursor": max([after_id] + [event["id"] for event in events]),
        "events": events,
    }


def envelope(provider: str, available: bool, sessions: list[dict[str, Any]], usage: list[dict[str, Any]], message: str | None = None) -> dict[str, Any]:
    updated = max(
        [session.get("last_activity_at", 0) for session in sessions]
        + [window.get("measured_at", 0) for window in usage]
        + [now_ms()]
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "provider": provider,
        "available": available,
        "message": message,
        "sessions": sessions,
        "usage_windows": usage,
        "updated_at": updated,
    }


def process_environments() -> Iterable[dict[str, str]]:
    proc = Path("/proc")
    if not proc.exists():
        return []
    environments: list[dict[str, str]] = []
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            command = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="ignore").lower()
            if "codex" not in command:
                continue
            values: dict[str, str] = {}
            for item in (entry / "environ").read_bytes().split(b"\0"):
                if b"=" not in item:
                    continue
                key, value = item.split(b"=", 1)
                values[key.decode(errors="ignore")] = value.decode(errors="ignore")
            environments.append(values)
        except OSError:
            continue
    return environments


def codex_roots() -> list[Path]:
    candidates = [Path(os.environ.get("CODEX_HOME", "")), HOME / ".codex"]
    candidates.extend(Path(env["CODEX_HOME"]) for env in process_environments() if env.get("CODEX_HOME"))
    roots: list[Path] = []
    for candidate in candidates:
        if not str(candidate) or candidate in roots:
            continue
        if (candidate / "sessions").is_dir():
            roots.append(candidate)
    return roots


def codex_ttl(model: str | None) -> int:
    return 30 * 60 if model and "gpt-5.6" in model.lower() else 5 * 60


def codex_local() -> tuple[bool, list[dict[str, Any]], list[dict[str, Any]]]:
    roots = codex_roots()
    cutoff = time.time() - MAX_AGE_SECONDS
    candidates: list[Path] = []
    for root in roots:
        for path_text in glob.iglob(str(root / "sessions" / "**" / "*.jsonl"), recursive=True):
            path = Path(path_text)
            try:
                if path.stat().st_mtime >= cutoff:
                    candidates.append(path)
            except OSError:
                pass
    candidates = sorted(candidates, key=lambda item: item.stat().st_mtime, reverse=True)[:50]
    sessions: list[dict[str, Any]] = []
    newest_usage: tuple[int, list[dict[str, Any]]] | None = None
    for path in candidates:
        records = bounded_jsonl(path)
        session_id: str | None = None
        cwd: str | None = None
        model: str | None = None
        lifecycle: str | None = None
        lifecycle_reason: str | None = None
        lifecycle_at = 0
        token_at = 0
        latest_usage: dict[str, Any] | None = None
        latest_limits: dict[str, Any] | None = None
        hits = misses = cold = unknown = 0
        observed_input_tokens = cached_input_tokens = 0
        previous_at: int | None = None
        previous_signature: str | None = None
        for record in records:
            payload = record.get("payload") if isinstance(record.get("payload"), dict) else {}
            timestamp = milliseconds(record.get("timestamp")) or 0
            record_type = record.get("type")
            if record_type == "session_meta":
                session_id = payload.get("id") or session_id
                cwd = payload.get("cwd") or cwd
            elif record_type == "turn_context":
                cwd = payload.get("cwd") or cwd
                model = payload.get("model") or model
            elif record_type == "event_msg":
                event_type = payload.get("type")
                if event_type in {"task_started", "task_complete", "turn_aborted"}:
                    lifecycle = event_type
                    lifecycle_reason = payload.get("reason")
                    lifecycle_at = timestamp or lifecycle_at
                if event_type == "token_count" and isinstance(payload.get("info"), dict):
                    usage = payload["info"].get("last_token_usage")
                    if isinstance(usage, dict):
                        latest_usage = usage
                        token_at = timestamp
                        signature = "|".join(str(usage.get(key, 0)) for key in ("input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens"))
                        if signature != previous_signature:
                            cached = max(0, int(usage.get("cached_input_tokens") or 0))
                            observed_input_tokens += max(0, int(usage.get("input_tokens") or 0))
                            cached_input_tokens += cached
                            if cached > 0:
                                hits += 1
                            else:
                                if previous_at and timestamp - previous_at <= codex_ttl(model) * 1000:
                                    misses += 1
                                else:
                                    cold += 1
                            previous_at = timestamp
                            previous_signature = signature
                    if isinstance(payload.get("rate_limits"), dict):
                        latest_limits = payload["rate_limits"]
        try:
            modified_at = int(path.stat().st_mtime * 1000)
        except OSError:
            modified_at = 0
        activity_at = max(lifecycle_at, token_at, modified_at)
        age_seconds = max(0, (now_ms() - activity_at) // 1000)
        if lifecycle == "task_started":
            status = "stuck" if age_seconds >= STUCK_SECONDS else "working"
        elif lifecycle == "turn_aborted":
            status = "idle" if lifecycle_reason == "interrupted" else "failed"
        else:
            status = "idle"
        cache = cache_unknown()
        if latest_usage and token_at:
            cached = max(0, int(latest_usage.get("cached_input_tokens") or 0))
            written = max(0, int(latest_usage.get("cache_write_input_tokens") or 0))
            # Codex/OpenAI report input_tokens INCLUDING the cached portion, so
            # subtract it to make input_tokens mean fresh/uncached — matching the
            # local CodexConnector. Otherwise remote reuse double-counts the cache.
            fresh_input = max(0, int(latest_usage.get("input_tokens") or 0) - cached)
            ttl = codex_ttl(model)
            exact_ttl = "gpt-5.6" in (model or "").lower()
            remaining = max(0, ttl - max(0, (now_ms() - token_at) // 1000))
            temperature = "cold" if remaining == 0 else "expiring" if remaining <= 60 else "warm" if cached or written else "unknown"
            cache = {
                "temperature": temperature,
                "remaining_seconds": remaining if temperature != "unknown" else None,
                "ttl_seconds": ttl,
                "input_tokens": fresh_input,
                "output_tokens": max(0, int(latest_usage.get("output_tokens") or 0)),
                "cached_read_tokens": cached,
                "cache_write_tokens": written,
                "last_confirmed_at": token_at if cached else None,
                "confidence": "exactPolicy" if exact_ttl else "observed" if cached else "inferred",
                "reason": "Remote Codex rollout telemetry; GPT-5.6 uses the documented 30-minute cache TTL" if exact_ttl else "Remote Codex rollout token telemetry; expiry is inferred from the model family",
            }
        resolved_id = session_id or path.stem
        project = Path(cwd).name if cwd else None
        sessions.append({
            "id": resolved_id,
            "title": f"Codex · {project}" if project else "Codex session",
            "project_name": project,
            "model": model,
            "status": status,
            "last_activity_at": activity_at,
            "cache": cache,
            "cache_health": health_snapshot(
                hits,
                misses,
                cold,
                unknown,
                activity_at,
                observed_input_tokens,
                cached_input_tokens,
            ),
            "working_directory": cwd,
        })
        if latest_limits and token_at:
            windows: list[dict[str, Any]] = []
            for key in ("primary", "secondary"):
                window = latest_limits.get(key)
                if not isinstance(window, dict) or window.get("used_percent") is None:
                    continue
                minutes = int(window.get("window_minutes") or 0)
                label = "5 hours" if minutes == 300 else "7 days" if minutes == 10080 else f"{minutes} minutes" if minutes else "Usage"
                reset = milliseconds(window.get("resets_at"))
                windows.append({
                    "id": f"codex-{minutes}",
                    "label": label,
                    "used_fraction": max(0, min(1, float(window["used_percent"]) / 100)),
                    "resets_at": reset,
                    "measured_at": token_at,
                })
            if windows and (newest_usage is None or token_at > newest_usage[0]):
                newest_usage = (token_at, windows)
    sessions.sort(key=lambda item: (item["status"] != "working", -item["last_activity_at"]))
    return bool(roots), sessions, newest_usage[1] if newest_usage else []


def opencode_database() -> Path:
    base = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local" / "share"))
    directory = base / "opencode"
    candidates = list(directory.glob("opencode*.db")) if directory.is_dir() else []
    if candidates:
        return max(candidates, key=lambda path: path.stat().st_mtime)
    return directory / "opencode.db"


def opencode_ttl(provider: str | None, model: str | None) -> int:
    if provider and provider.lower() == "openai" and model and "gpt-5.6" in model.lower():
        return 30 * 60
    return 5 * 60


def opencode_server_request(port: int, path: str) -> Any:
    if port < 1 or port > 65535:
        raise ValueError(f"invalid OpenCode port: {port}")
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        headers={"Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=3) as response:
        return json.loads(response.read())


def opencode_server(port: int) -> tuple[bool, list[dict[str, Any]], list[dict[str, Any]]]:
    """Read one explicit loopback OpenCode server and emit metadata only."""
    try:
        raw_sessions = opencode_server_request(port, "/session")
        raw_statuses = opencode_server_request(port, "/session/status")
    except (OSError, ValueError, urllib.error.URLError, json.JSONDecodeError):
        return False, [], []
    if not isinstance(raw_sessions, list):
        return False, [], []
    statuses = raw_statuses if isinstance(raw_statuses, dict) else {}
    cutoff = now_ms() - MAX_AGE_SECONDS * 1000
    candidates = [
        value for value in raw_sessions
        if isinstance(value, dict)
        and not value.get("parentID")
        and (
            int((value.get("time") or {}).get("updated") or 0) >= cutoff
            or (
                isinstance(statuses.get(str(value.get("id") or "")), dict)
                and statuses[str(value.get("id") or "")].get("type") in {"busy", "retry"}
            )
        )
    ]
    candidates.sort(key=lambda item: int((item.get("time") or {}).get("updated") or 0), reverse=True)
    sessions: list[dict[str, Any]] = []
    for session in candidates[:50]:
        session_id = str(session.get("id") or "")
        if not session_id:
            continue
        try:
            raw_messages = opencode_server_request(
                port,
                f"/session/{urllib.parse.quote(session_id, safe='')}/message",
            )
        except (OSError, ValueError, urllib.error.URLError, json.JSONDecodeError):
            raw_messages = []
        infos = [
            value.get("info") for value in raw_messages
            if isinstance(value, dict) and isinstance(value.get("info"), dict)
        ] if isinstance(raw_messages, list) else []
        assistants = [value for value in infos if value.get("role") == "assistant"]
        latest = infos[-1] if infos else {}
        latest_assistant = assistants[-1] if assistants else {}
        session_time = session.get("time") if isinstance(session.get("time"), dict) else {}
        latest_time = latest.get("time") if isinstance(latest.get("time"), dict) else {}
        activity = max(
            int(session_time.get("updated") or 0),
            int(latest_time.get("completed") or latest_time.get("created") or 0),
        )
        state = statuses.get(session_id) if isinstance(statuses.get(session_id), dict) else {}
        if latest_assistant.get("error") or latest_assistant.get("finish") == "error":
            status = "failed"
        elif state.get("type") in {"busy", "retry"}:
            status = "stuck" if now_ms() - activity >= STUCK_SECONDS * 1000 else "working"
        else:
            status = "idle"

        session_model = session.get("model") if isinstance(session.get("model"), dict) else {}
        model = latest_assistant.get("modelID") or session_model.get("id")
        provider = latest_assistant.get("providerID") or session_model.get("providerID")
        assistant_time = latest_assistant.get("time") if isinstance(latest_assistant.get("time"), dict) else {}
        confirmed = int(assistant_time.get("completed") or assistant_time.get("created") or 0)
        tokens = latest_assistant.get("tokens") if isinstance(latest_assistant.get("tokens"), dict) else {}
        cache_tokens = tokens.get("cache") if isinstance(tokens.get("cache"), dict) else {}
        read = max(0, int(cache_tokens.get("read") or 0))
        write = max(0, int(cache_tokens.get("write") or 0))
        ttl = opencode_ttl(provider, model)
        remaining = max(0, ttl - max(0, (now_ms() - confirmed) // 1000)) if confirmed else None
        temperature = "unknown" if remaining is None else "cold" if remaining == 0 else "expiring" if remaining <= 60 else "warm"

        hits = misses = cold = unknown = 0
        previous: dict[str, Any] | None = None
        for message in assistants:
            message_tokens = message.get("tokens") if isinstance(message.get("tokens"), dict) else None
            if message_tokens is None:
                unknown += 1
                previous = message
                continue
            message_cache = message_tokens.get("cache") if isinstance(message_tokens.get("cache"), dict) else {}
            if int(message_cache.get("read") or 0) > 0:
                hits += 1
            else:
                message_time = message.get("time") if isinstance(message.get("time"), dict) else {}
                created = int(message_time.get("created") or 0)
                previous_time = previous.get("time") if previous and isinstance(previous.get("time"), dict) else {}
                previous_completed = int(previous_time.get("completed") or 0)
                same_model = bool(
                    previous
                    and previous.get("modelID") == message.get("modelID")
                    and previous.get("providerID") == message.get("providerID")
                )
                if previous_completed and created - previous_completed <= opencode_ttl(message.get("providerID"), message.get("modelID")) * 1000 and same_model:
                    misses += 1
                else:
                    cold += 1
            previous = message

        cache = {
            "temperature": temperature,
            "remaining_seconds": remaining,
            "ttl_seconds": ttl,
            "input_tokens": max(0, int(tokens.get("input") or 0)),
            "output_tokens": max(0, int(tokens.get("output") or 0)),
            "cached_read_tokens": read,
            "cache_write_tokens": write,
            "last_confirmed_at": confirmed if read else None,
            "confidence": "observed" if read else "inferred",
            "reason": f"OpenCode server telemetry from 127.0.0.1:{port}",
        }
        directory = str(session.get("directory") or "")
        sessions.append({
            "id": session_id,
            "title": session.get("title") or session_id,
            "project_name": Path(directory).name if directory else None,
            "model": model,
            "status": status,
            "last_activity_at": activity,
            "cache": cache,
            "cache_health": health_snapshot(hits, misses, cold, unknown, activity),
            "working_directory": directory or None,
        })
    sessions.sort(key=lambda item: (item["status"] != "working", -item["last_activity_at"]))
    return True, sessions, []


def opencode_local() -> tuple[bool, list[dict[str, Any]], list[dict[str, Any]]]:
    database = opencode_database()
    if not database.exists():
        return False, [], []
    sessions: list[dict[str, Any]] = []
    try:
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=0.25)
        cutoff = now_ms() - MAX_AGE_SECONDS * 1000
        rows = connection.execute(
            "SELECT id, title, directory, time_updated FROM session WHERE parent_id IS NULL AND time_updated >= ? ORDER BY time_updated DESC LIMIT 50",
            (cutoff,),
        ).fetchall()
        for session_id, title, directory, updated in rows:
            messages = connection.execute(
                "SELECT data FROM message WHERE session_id = ? ORDER BY time_created ASC, id ASC LIMIT 100",
                (session_id,),
            ).fetchall()
            decoded = []
            for (raw,) in messages:
                try:
                    value = json.loads(raw)
                    if isinstance(value, dict):
                        decoded.append(value)
                except (TypeError, ValueError):
                    pass
            latest = decoded[-1] if decoded else {}
            assistants = [message for message in decoded if message.get("role") == "assistant"]
            latest_assistant = assistants[-1] if assistants else {}
            timing = latest.get("time") if isinstance(latest.get("time"), dict) else {}
            activity = max(int(updated or 0), int(timing.get("completed") or timing.get("created") or 0))
            finish = latest.get("finish")
            if finish == "error" or latest.get("error"):
                status = "failed"
            elif latest.get("role") == "user" or (latest.get("role") == "assistant" and not timing.get("completed")):
                status = "stuck" if now_ms() - activity >= STUCK_SECONDS * 1000 else "working"
            else:
                status = "idle"
            model = latest_assistant.get("modelID")
            provider = latest_assistant.get("providerID")
            tokens = latest_assistant.get("tokens") if isinstance(latest_assistant.get("tokens"), dict) else {}
            cache_tokens = tokens.get("cache") if isinstance(tokens.get("cache"), dict) else {}
            read = max(0, int(cache_tokens.get("read") or 0))
            write = max(0, int(cache_tokens.get("write") or 0))
            latest_time = latest_assistant.get("time") if isinstance(latest_assistant.get("time"), dict) else {}
            confirmed = int(latest_time.get("completed") or latest_time.get("created") or 0)
            ttl = opencode_ttl(provider, model)
            remaining = max(0, ttl - max(0, (now_ms() - confirmed) // 1000)) if confirmed else None
            temperature = "unknown" if remaining is None else "cold" if remaining == 0 else "expiring" if remaining <= 60 else "warm"
            hits = misses = cold = unknown = 0
            previous: dict[str, Any] | None = None
            for message in assistants:
                message_tokens = message.get("tokens") if isinstance(message.get("tokens"), dict) else {}
                message_cache = message_tokens.get("cache") if isinstance(message_tokens.get("cache"), dict) else {}
                cached = int(message_cache.get("read") or 0)
                message_time = message.get("time") if isinstance(message.get("time"), dict) else {}
                created = int(message_time.get("created") or 0)
                if cached > 0:
                    hits += 1
                else:
                    previous_time = previous.get("time") if previous and isinstance(previous.get("time"), dict) else {}
                    previous_completed = int(previous_time.get("completed") or 0)
                    same_model = bool(previous and previous.get("modelID") == message.get("modelID") and previous.get("providerID") == message.get("providerID"))
                    if previous_completed and created - previous_completed <= opencode_ttl(message.get("providerID"), message.get("modelID")) * 1000 and same_model:
                        misses += 1
                    else:
                        cold += 1
                previous = message
            cache = {
                "temperature": temperature,
                "remaining_seconds": remaining,
                "ttl_seconds": ttl,
                "input_tokens": max(0, int(tokens.get("input") or 0)),
                "output_tokens": max(0, int(tokens.get("output") or 0)),
                "cached_read_tokens": read,
                "cache_write_tokens": write,
                "last_confirmed_at": confirmed if read else None,
                "confidence": "observed" if read else "inferred",
                "reason": "Remote OpenCode SQLite token telemetry; expiry is inferred",
            }
            sessions.append({
                "id": session_id,
                "title": title or session_id,
                "project_name": Path(directory).name,
                "model": model,
                "status": status,
                "last_activity_at": activity,
                "cache": cache,
                "cache_health": health_snapshot(hits, misses, cold, unknown, activity),
                "working_directory": directory,
            })
        connection.close()
    except (OSError, sqlite3.Error) as error:
        return True, [], []
    sessions.sort(key=lambda item: (item["status"] != "working", -item["last_activity_at"]))
    return True, sessions, []


def claude_local() -> tuple[bool, list[dict[str, Any]], list[dict[str, Any]]]:
    root = HOME / ".claude" / "projects"
    if not root.is_dir():
        return False, [], []
    cutoff = time.time() - MAX_AGE_SECONDS
    candidates = []
    for path_text in glob.iglob(str(root / "**" / "*.jsonl"), recursive=True):
        path = Path(path_text)
        try:
            if path.stat().st_mtime >= cutoff:
                candidates.append(path)
        except OSError:
            pass
    candidates = sorted(candidates, key=lambda item: item.stat().st_mtime, reverse=True)[:50]
    sessions: list[dict[str, Any]] = []
    for path in candidates:
        session_id: str | None = None
        cwd: str | None = None
        model: str | None = None
        activity = int(path.stat().st_mtime * 1000)
        status = "idle"
        latest_cache = cache_unknown()
        hits = misses = cold = unknown = 0
        previous_at: int | None = None
        previous_ttl = 300
        for record in bounded_jsonl(path):
            timestamp = milliseconds(record.get("timestamp")) or activity
            activity = max(activity, timestamp)
            session_id = record.get("sessionId") or session_id
            cwd = record.get("cwd") or cwd
            if record.get("type") == "assistant" and isinstance(record.get("message"), dict):
                message = record["message"]
                model = message.get("model") or model
                usage = message.get("usage") if isinstance(message.get("usage"), dict) else None
                status = "working" if message.get("stop_reason") is None else "idle"
                if usage:
                    cached = max(0, int(usage.get("cache_read_input_tokens") or 0))
                    written = max(0, int(usage.get("cache_creation_input_tokens") or 0))
                    creation = usage.get("cache_creation") if isinstance(usage.get("cache_creation"), dict) else {}
                    ttl = 3600 if int(creation.get("ephemeral_1h_input_tokens") or 0) > 0 else 300
                    if cached > 0:
                        hits += 1
                    else:
                        if previous_at and timestamp - previous_at <= previous_ttl * 1000:
                            misses += 1
                        else:
                            cold += 1
                    previous_at = timestamp
                    previous_ttl = ttl
                    remaining = max(0, ttl - max(0, (now_ms() - timestamp) // 1000))
                    temperature = "cold" if remaining == 0 else "expiring" if remaining <= 60 else "warm" if cached or written else "unknown"
                    latest_cache = {
                        "temperature": temperature,
                        "remaining_seconds": remaining if temperature != "unknown" else None,
                        "ttl_seconds": ttl,
                        "input_tokens": max(0, int(usage.get("input_tokens") or 0)),
                        "output_tokens": max(0, int(usage.get("output_tokens") or 0)),
                        "cached_read_tokens": cached,
                        "cache_write_tokens": written,
                        "last_confirmed_at": timestamp if cached else None,
                        "confidence": "exactPolicy" if creation else "observed" if cached else "inferred",
                        "reason": "Remote Claude Code transcript cache telemetry",
                    }
            elif record.get("type") == "user":
                status = "working"
        if status == "working" and now_ms() - activity >= STUCK_SECONDS * 1000:
            status = "stuck"
        resolved_id = session_id or path.stem
        project = Path(cwd).name if cwd else None
        sessions.append({
            "id": resolved_id,
            "title": f"Claude Code · {project}" if project else "Claude Code session",
            "project_name": project,
            "model": model,
            "status": status,
            "last_activity_at": activity,
            "cache": latest_cache,
            "cache_health": health_snapshot(hits, misses, cold, unknown, activity),
            "working_directory": cwd,
        })
    return True, sessions, []


def live_state(name: str) -> Any:
    return safe_json(STATE_DIR / f"{name}.json")


def merge_live(provider: str, sessions: list[dict[str, Any]], usage: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if provider == "openCode":
        stored = live_state("opencode")
        if isinstance(stored, dict) and isinstance(stored.get("instances"), dict):
            payloads = list(stored["instances"].values())
        else:
            payloads = [stored]
        for payload in payloads:
            if not isinstance(payload, dict) or now_ms() - int(payload.get("sentAt") or 0) > 75_000:
                continue
            by_id = {session["id"]: session for session in sessions}
            for report in payload.get("sessions", []):
                if not isinstance(report, dict):
                    continue
                cache_report = report.get("cache") if isinstance(report.get("cache"), dict) else {}
                activity = int(report.get("lastActivityAt") or payload.get("sentAt") or now_ms())
                directory = report.get("projectPath")
                by_id[report.get("id", "")] = {
                    "id": report.get("id", ""),
                    "title": report.get("title") or report.get("id") or "OpenCode session",
                    "project_name": Path(directory).name if directory else None,
                    "model": report.get("model"),
                    "status": report.get("status", "idle"),
                    "last_activity_at": activity,
                    "cache": {
                        "temperature": cache_report.get("temperature", "unknown"),
                        "remaining_seconds": cache_report.get("remainingSeconds"),
                        "ttl_seconds": cache_report.get("ttlSeconds"),
                        "input_tokens": cache_report.get("inputTokens"),
                        "output_tokens": cache_report.get("outputTokens"),
                        "cached_read_tokens": cache_report.get("cachedReadTokens", 0),
                        "cache_write_tokens": cache_report.get("cacheWriteTokens", 0),
                        "last_confirmed_at": activity if cache_report.get("cachedReadTokens", 0) else None,
                        "confidence": "observed" if cache_report.get("cachedReadTokens", 0) else "inferred",
                        "reason": "Remote OpenCode plugin telemetry",
                    },
                    "cache_health": health_snapshot(
                        int(cache_report.get("hitCount", 0)),
                        int(cache_report.get("avoidableMissCount", 0)),
                        int(cache_report.get("expectedColdStartCount", 0)),
                        int(cache_report.get("unknownCount", 0)),
                        activity,
                    ),
                    "working_directory": directory,
                }
            sessions = list(by_id.values())
    else:
        events = live_state(f"{provider}-events")
        if isinstance(events, dict):
            by_id = {session["id"]: session for session in sessions}
            for session_id, event in events.items():
                if not isinstance(event, dict) or now_ms() - int(event.get("sentAt") or 0) > MAX_AGE_SECONDS * 1000:
                    continue
                event_name = event.get("eventName")
                if event_name in {"SessionStart", "UserPromptSubmit", "PreToolUse"}:
                    status = "working"
                elif event_name in {"PermissionRequest"}:
                    status = "waitingForApproval"
                elif event_name in {"Notification"} and event.get("notificationType") in {"idle_prompt", "elicitation_dialog"}:
                    status = "waitingForInput"
                elif event_name in {"SessionEnd"}:
                    status = "completed"
                else:
                    status = "idle"
                existing = by_id.get(session_id)
                activity = int(event.get("sentAt") or now_ms())
                if existing:
                    existing["status"] = status
                    existing["last_activity_at"] = max(existing["last_activity_at"], activity)
                elif status in {"working", "waitingForApproval", "waitingForInput"}:
                    directory = event.get("workingDirectory")
                    label = "Codex" if provider == "codex" else "Claude Code"
                    by_id[session_id] = {
                        "id": session_id,
                        "title": f"{label} · {Path(directory).name}" if directory else f"{label} session",
                        "project_name": Path(directory).name if directory else None,
                        "model": event.get("model"),
                        "status": status,
                        "last_activity_at": activity,
                        "cache": cache_unknown(),
                        "cache_health": None,
                        "working_directory": directory,
                    }
            sessions = list(by_id.values())
        if provider == "claudeCode":
            status_payload = live_state("claudeCode-status")
            if isinstance(status_payload, dict):
                measured = int(status_payload.get("sentAt") or now_ms())
                usage = []
                for key, label, identifier in (("fiveHour", "5 hours", "claude-5h"), ("sevenDay", "7 days", "claude-7d")):
                    window = status_payload.get(key)
                    if not isinstance(window, dict):
                        continue
                    usage.append({
                        "id": identifier,
                        "label": label,
                        "used_fraction": max(0, min(1, float(window.get("usedPercentage", 0)) / 100)),
                        "resets_at": milliseconds(window.get("resetsAt")),
                        "measured_at": measured,
                    })
    return sessions, usage


def snapshot(provider_argument: str, source: str, opencode_port: int | None = None) -> dict[str, Any]:
    if provider_argument == "codex":
        provider = "codex"
        available, sessions, usage = codex_local() if source != "realtimeOnly" else (False, [], [])
    elif provider_argument == "opencode":
        provider = "openCode"
        if opencode_port is not None:
            available, sessions, usage = opencode_server(opencode_port)
        else:
            available, sessions, usage = opencode_local() if source != "realtimeOnly" else (False, [], [])
    else:
        provider = "claudeCode"
        available, sessions, usage = claude_local() if source != "realtimeOnly" else (False, [], [])
    if source != "localOnly" and opencode_port is None:
        sessions, usage = merge_live(provider, sessions, usage)
        state_available = bool(sessions or usage or live_state("opencode" if provider == "openCode" else f"{provider}-events"))
        available = available or state_available
    record_history_sessions(provider, sessions)
    return envelope(provider, available, sessions, usage, None if available else "No local provider data was found")


class CollectorHandler(BaseHTTPRequestHandler):
    server_version = "AgentHearthRemote/0.1"
    token = ""

    def _authorized(self) -> bool:
        # Browsers always attach an Origin header on cross-origin (and
        # cross-port) requests; the local connectors never do. Rejecting it
        # closes the DNS-rebinding / CSRF path from a browser on this host.
        if self.headers.get("Origin") is not None:
            self.respond(403, {"error": "forbidden"})
            return False
        if self.token:
            presented = self.headers.get(TOKEN_HEADER, "")
            if not hmac.compare_digest(presented, self.token):
                self.respond(401, {"error": "unauthorized"})
                return False
        return True

    def do_GET(self) -> None:
        if not self._authorized():
            return
        if self.path != "/health":
            self.respond(404, {"error": "not found"})
            return
        self.respond(200, health())

    def do_POST(self) -> None:
        if not self._authorized():
            return
        length = min(int(self.headers.get("Content-Length", "0")), 1_048_576)
        try:
            payload = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, ValueError):
            self.respond(400, {"error": "invalid JSON"})
            return
        if not isinstance(payload, dict) or payload.get("schemaVersion") != SCHEMA_VERSION:
            self.respond(409, {"error": "unsupported schema"})
            return
        if self.path == "/v1/providers/opencode/snapshots":
            path = STATE_DIR / "opencode.json"
            stored = safe_json(path)
            instances = stored.get("instances", {}) if isinstance(stored, dict) else {}
            instances = instances if isinstance(instances, dict) else {}
            instance = str(payload.get("instance") or "")
            if not instance:
                self.respond(400, {"error": "missing instance"})
                return
            instances[instance] = payload
            cutoff = now_ms() - 75_000
            instances = {
                key: value for key, value in instances.items()
                if isinstance(value, dict) and int(value.get("sentAt") or 0) >= cutoff
            }
            atomic_json(path, {"instances": instances})
            live_sessions, _ = merge_live("openCode", [], [])
            record_history_sessions("openCode", live_sessions)
        elif self.path in {"/v1/providers/codex/events", "/v1/providers/claude-code/events"}:
            provider = "codex" if "/codex/" in self.path else "claudeCode"
            path = STATE_DIR / f"{provider}-events.json"
            events = safe_json(path)
            events = events if isinstance(events, dict) else {}
            session_id = str(payload.get("sessionID") or "")
            if not session_id:
                self.respond(400, {"error": "missing session"})
                return
            events[session_id] = payload
            # Bound growth: drop entries older than the retention window and cap
            # the count, so a burst of unique session IDs cannot fill the disk.
            cutoff = now_ms() - MAX_AGE_SECONDS * 1000
            events = {
                key: value for key, value in events.items()
                if isinstance(value, dict) and int(value.get("sentAt") or 0) >= cutoff
            }
            if len(events) > 1000:
                events = dict(
                    sorted(events.items(), key=lambda item: int(item[1].get("sentAt") or 0))[-1000:]
                )
            atomic_json(path, events)
        elif self.path == "/v1/providers/claude-code/status":
            atomic_json(STATE_DIR / "claudeCode-status.json", payload)
        else:
            self.respond(404, {"error": "not found"})
            return
        self.respond(202, {"accepted": True})

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def respond(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def collector_running() -> bool:
    try:
        with socket.create_connection(("127.0.0.1", PORT), timeout=0.25):
            return True
    except OSError:
        return False


def health() -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "service": "AgentHearth Remote",
        "status": "collector running" if collector_running() else "snapshot ready",
        "version": VERSION,
    }


def serve() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    PID_PATH.write_text(str(os.getpid()), encoding="utf-8")
    CollectorHandler.token = load_or_create_token()
    try:
        threading.Thread(target=history_sampler, daemon=True, name="agenthearth-history").start()
        server = ThreadingHTTPServer(("127.0.0.1", PORT), CollectorHandler)
        server.serve_forever()
    finally:
        try:
            if PID_PATH.read_text(encoding="utf-8").strip() == str(os.getpid()):
                PID_PATH.unlink(missing_ok=True)
        except OSError:
            pass


def history_sampler() -> None:
    """Keep a bounded cache journal while the controlling Mac is offline."""
    while True:
        for provider, loader in (
            ("codex", codex_local),
            ("claudeCode", claude_local),
            ("openCode", opencode_local),
        ):
            try:
                _, sessions, _ = loader()
                record_history_sessions(provider, sessions)
            except Exception:
                # A malformed provider file must not stop the other samplers.
                continue
        time.sleep(60)


def install_service() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    load_or_create_token()
    script = DATA_DIR / "agenthearth_remote.py"
    systemctl = shutil.which("systemctl")
    if systemctl:
        unit_dir = HOME / ".config" / "systemd" / "user"
        unit_dir.mkdir(parents=True, exist_ok=True)
        unit = unit_dir / "agenthearth-remote.service"
        unit.write_text(
            "[Unit]\nDescription=AgentHearth remote metadata collector\n\n"
            "[Service]\nType=simple\nExecStart=/usr/bin/env python3 %h/.local/share/agenthearth/agenthearth_remote.py serve\nRestart=on-failure\nRestartSec=2\n\n"
            "[Install]\nWantedBy=default.target\n",
            encoding="utf-8",
        )
        subprocess.run([systemctl, "--user", "daemon-reload"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        result = subprocess.run([systemctl, "--user", "enable", "--now", "agenthearth-remote.service"], check=False)
        if result.returncode == 0:
            subprocess.run(
                [systemctl, "--user", "restart", "agenthearth-remote.service"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return
    if not collector_running():
        log = (STATE_DIR / "collector.log").open("ab")
        subprocess.Popen(
            [sys.executable, str(script), "serve"],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            start_new_session=True,
            close_fds=True,
        )
        time.sleep(0.2)


def uninstall() -> None:
    systemctl = shutil.which("systemctl")
    if systemctl:
        subprocess.run(
            [systemctl, "--user", "disable", "--now", "agenthearth-remote.service"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        unit = HOME / ".config" / "systemd" / "user" / "agenthearth-remote.service"
        unit.unlink(missing_ok=True)
        subprocess.run(
            [systemctl, "--user", "daemon-reload"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    try:
        pid = int(PID_PATH.read_text(encoding="utf-8").strip())
        command_path = Path(f"/proc/{pid}/cmdline")
        command = command_path.read_bytes().replace(b"\0", b" ").decode(errors="ignore") if command_path.exists() else ""
        if "agenthearth_remote.py" in command and " serve" in command:
            os.kill(pid, 15)
    except (OSError, ValueError):
        pass
    (HOME / ".config" / "opencode" / "plugins" / "agenthearth.ts").unlink(missing_ok=True)
    for path in STATE_DIR.glob("*.json") if STATE_DIR.exists() else []:
        path.unlink(missing_ok=True)
    for name in ("collector.log", "collector.pid"):
        (STATE_DIR / name).unlink(missing_ok=True)
    for name in ("history.sqlite", "history.sqlite-wal", "history.sqlite-shm"):
        (STATE_DIR / name).unlink(missing_ok=True)
    try:
        STATE_DIR.rmdir()
    except OSError:
        pass


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("health")
    subparsers.add_parser("serve")
    subparsers.add_parser("install-service")
    subparsers.add_parser("uninstall")
    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument("--provider", choices=["codex", "opencode", "claude-code"], required=True)
    snapshot_parser.add_argument("--source", choices=["automatic", "localOnly", "realtimeOnly"], default="automatic")
    snapshot_parser.add_argument("--opencode-port", type=int)
    history_parser = subparsers.add_parser("history")
    history_parser.add_argument("--provider", choices=["codex", "opencode", "claude-code"], required=True)
    history_parser.add_argument("--after-id", type=int, default=0)
    history_parser.add_argument("--limit", type=int, default=2000)
    arguments = parser.parse_args()
    if arguments.command == "serve":
        serve()
    elif arguments.command == "install-service":
        install_service()
    elif arguments.command == "uninstall":
        uninstall()
    elif arguments.command == "health":
        print(json.dumps(health(), separators=(",", ":")))
    elif arguments.command == "history":
        print(json.dumps(history_events(arguments.provider, arguments.after_id, arguments.limit), separators=(",", ":")))
    else:
        print(json.dumps(snapshot(arguments.provider, arguments.source, arguments.opencode_port), separators=(",", ":")))


if __name__ == "__main__":
    main()
