# AgentHearth Codex integration

AgentHearth can read Codex rollout metadata without configuration. The optional
lifecycle hook adds immediate session start, stop, completion, and permission
states. It posts a metadata-only payload to `127.0.0.1:5274`; prompts, responses,
tool inputs, and credentials are never included.

The installer appends an idempotent, clearly marked block to
`~/.codex/config.toml` and stores the bridge at
`~/.config/agenthearth/codex-hook.py`. Codex may ask the user to trust the new
hooks on the next session.
