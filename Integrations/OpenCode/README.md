# AgentHearth connector for OpenCode

OpenCode runs plugins inside each local process, so this connector pushes a
metadata-only snapshot to AgentHearth on `127.0.0.1:5274` every 15 seconds.

AgentHearth can install the bundled connector from **Settings → OpenCode
Connector**. OpenCode loads global TypeScript plugins from
`~/.config/opencode/plugins/`; restart OpenCode or start a new process after the
first installation.

The payload includes session IDs and titles, project paths, models, lifecycle
states, timestamps, and normalized cache-token counters. It excludes prompts,
message text, tool input/output, source code, and secrets.

Configuration lives at `~/.config/agenthearth/opencode.json`. AgentHearth uses a
dedicated port, so the connector can coexist with the older AI Usage Bar plugin
on port `5199`.

Each plugin process reports a runtime identity made from its hostname, process
ID, and project directory. Multiple OpenCode processes therefore cannot
overwrite each other's live state. For stable named sources, configure each
OpenCode HTTP server under **Settings → OpenCode Servers**; AgentHearth uses the
official loopback API and retains only normalized metadata in its domain model.
