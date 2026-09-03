# Claude Code connector

AgentHearth reads recent `~/.claude/projects/**/*.jsonl` transcripts with a
bounded metadata-only parser for cache counters, model, project and session
freshness. It ignores prompt and response content.

For live states, Settings can install the bundled hook bridge into
`~/.claude/settings.json`. Installation merges AgentHearth commands with
existing hooks and never replaces unrelated entries. The bridge posts only a
small allowlist of metadata to `127.0.0.1:5274`.

Restart Claude Code or open a new session after installation so `SessionStart`
and subsequent events are emitted.
