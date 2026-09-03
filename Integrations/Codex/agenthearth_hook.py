#!/usr/bin/python3
"""Metadata-only Codex lifecycle hook bridge for AgentHearth."""

import json
import os
import sys
import time
import urllib.request

TOKEN_PATH = os.path.expanduser("~/.config/agenthearth/ingress-token")


def optional_string(value):
    if isinstance(value, str) and value:
        return value
    return None


def ingress_token():
    try:
        with open(TOKEN_PATH, "r", encoding="utf-8") as handle:
            return handle.read().strip() or None
    except OSError:
        return None


def main():
    try:
        incoming = json.load(sys.stdin)
        session_id = optional_string(incoming.get("session_id"))
        event_name = optional_string(incoming.get("hook_event_name"))
        if not session_id or not event_name:
            return

        # Deliberately omit prompts, messages, tool names, tool inputs and
        # permission details. Only session metadata reaches the loopback app.
        payload = {
            "schemaVersion": 1,
            "eventName": event_name,
            "sessionID": session_id,
            "transcriptPath": optional_string(incoming.get("transcript_path")),
            "workingDirectory": optional_string(incoming.get("cwd")),
            "model": optional_string(incoming.get("model")),
            "sentAt": int(time.time() * 1000),
        }
        body = json.dumps({key: value for key, value in payload.items() if value is not None}).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        token = ingress_token()
        if token:
            headers["X-AgentHearth-Token"] = token
        request = urllib.request.Request(
            "http://127.0.0.1:5274/v1/providers/codex/events",
            data=body,
            headers=headers,
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=1.0):
            pass
    except Exception:
        # Monitoring must never interrupt Codex.
        pass


if __name__ == "__main__":
    main()
