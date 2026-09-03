#!/usr/bin/python3
"""Metadata-only Claude Code hook bridge for AgentHearth."""

import json
import os
import subprocess
import sys
import time
import urllib.request


def optional_string(value):
    if isinstance(value, str) and value:
        return value
    return None


def model_name(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return optional_string(value.get("id")) or optional_string(value.get("display_name"))
    return None


CONFIG_PATH = os.path.expanduser("~/.config/agenthearth/claude-code.json")
TOKEN_PATH = os.path.expanduser("~/.config/agenthearth/ingress-token")


def ingress_token():
    try:
        with open(TOKEN_PATH, "r", encoding="utf-8") as handle:
            return handle.read().strip() or None
    except OSError:
        return None


def post(path, payload):
    body = json.dumps({key: value for key, value in payload.items() if value is not None}).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    token = ingress_token()
    if token:
        headers["X-AgentHearth-Token"] = token
    request = urllib.request.Request(
        "http://127.0.0.1:5274" + path,
        data=body,
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=1.0):
        pass


def rate_limit_window(value):
    if not isinstance(value, dict) or not isinstance(value.get("used_percentage"), (int, float)):
        return None
    result = {"usedPercentage": float(value["used_percentage"])}
    if isinstance(value.get("resets_at"), (int, float)):
        result["resetsAt"] = float(value["resets_at"])
    return result


def relay_status_line(raw):
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as handle:
            command = json.load(handle).get("previousStatusLineCommand")
        if not isinstance(command, str) or not command:
            return
        result = subprocess.run(
            command,
            input=raw,
            text=True,
            shell=True,
            capture_output=True,
            timeout=2.0,
            check=False,
        )
        if result.stdout:
            sys.stdout.write(result.stdout)
    except Exception:
        return


def main():
    raw = sys.stdin.read()
    try:
        incoming = json.loads(raw)
        session_id = optional_string(incoming.get("session_id"))
        event_name = optional_string(incoming.get("hook_event_name"))
        if not session_id:
            return

        if event_name:
            # Deliberately whitelist metadata. Prompt, tool input/output,
            # messages and permission details never leave this process.
            post("/v1/providers/claude-code/events", {
                "schemaVersion": 1,
                "eventName": event_name,
                "sessionID": session_id,
                "transcriptPath": optional_string(incoming.get("transcript_path")),
                "workingDirectory": optional_string(incoming.get("cwd")),
                "model": model_name(incoming.get("model")),
                "notificationType": optional_string(incoming.get("notification_type")),
                "sentAt": int(time.time() * 1000),
            })
        else:
            limits = incoming.get("rate_limits") if isinstance(incoming.get("rate_limits"), dict) else {}
            post("/v1/providers/claude-code/status", {
                "schemaVersion": 1,
                "sessionID": session_id,
                "workingDirectory": optional_string(incoming.get("cwd")),
                "model": model_name(incoming.get("model")),
                "fiveHour": rate_limit_window(limits.get("five_hour")),
                "sevenDay": rate_limit_window(limits.get("seven_day")),
                "sentAt": int(time.time() * 1000),
            })
    except Exception:
        # Monitoring must never interrupt Claude Code.
        pass
    finally:
        if raw and '"hook_event_name"' not in raw:
            relay_status_line(raw)


if __name__ == "__main__":
    main()
