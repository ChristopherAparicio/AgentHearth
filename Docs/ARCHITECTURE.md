# Architecture

AgentHearth follows a ports-and-adapters structure with domain-oriented boundaries.

```text
Presentation (SwiftUI / AppKit)
              |
Application use cases and ports
              |
Provider-neutral domain model
              ^
Infrastructure adapters (Codex, Claude Code, OpenCode, macOS)
```

## Local and remote topology

Provider, host, and runtime source are independent dimensions. A `ProviderConnector` describes
Codex, Claude Code, or OpenCode; `AgentHost` describes where its session lives.
`AgentSource` distinguishes several runtimes of the same provider on one host.
This prevents SSH mechanics from leaking into cache health, alerts, usage, or
Smart Sleep.

```text
AgentHearth macOS
  ├─ local provider connectors
  └─ SystemSSHCommandRunner (existing ~/.ssh/config)
       ├─ RemoteAgentClient · RTX
       │    ├─ Codex rollout + hooks
       │    ├─ OpenCode SQLite + plugin
       │    └─ Claude transcripts + hooks/status
       └─ RemoteAgentClient · server B
            └─ the same provider ports
```

The bundled, standard-library Python remote agent is installed at
`~/.local/share/agenthearth/agenthearth_remote.py`. It has two responsibilities:

1. normalize bounded local provider stores into schema-versioned snapshots;
2. receive metadata-only hooks/plugins on remote loopback port `5274`;
3. retain a bounded 90-day cache-counter event journal for offline replay.

AgentHearth invokes snapshots over outbound SSH. It stores no private key or
password and honors aliases, ProxyJump, and identities from the system SSH
configuration. The remote receiver is never exposed beyond `127.0.0.1`.

Session display IDs are scoped as `host:provider[:source]:session`; provider resume IDs
remain unchanged in `SessionTarget`. Opening a remote target launches the
provider resume command inside `ssh -t` and its remote working directory.

`ProviderMonitor` may own several connectors for one provider and merges their
snapshots after collection. This makes adding a host an application-composition
change, not a provider-domain change.

## Bounded concepts

- **Providers**: Codex, Claude Code, and OpenCode integrations.
- **Hosts**: this Mac or an SSH destination resolved through OpenSSH.
- **Sources**: named provider runtimes, such as two OpenCode servers on one host.
- **Sessions**: normalized lifecycle, project, cache, and navigation target.
- **Usage**: provider-defined quota windows and measurement freshness.
- **Health**: literal cache hits over observed provider requests, with cold
  starts classified separately but included as misses and low-sample states
  represented explicitly.
- **Alerts**: actionable events and delivery policy. An alert source is not necessarily a provider.
- **Power**: Smart Sleep mode, optional persisted deadline, and the macOS
  idle-sleep assertion. Expiration always releases the assertion, independently
  of provider session state.

## Primary ports

- `ProviderConnector`: selects an automatic, local-only, or realtime-only
  strategy and returns a provider snapshot without leaking provider payloads.
- `ProviderHistoryConnector`: optionally replays stable, normalized cache-event
  IDs from a collector that remained online while the Mac was unavailable.
- `SleepAssertionControlling`: owns the macOS power assertion.
- `SessionOpening`: focuses or resumes a provider session when an adapter can provide a stable target.
- `SnapshotAlertDetector`: compares provider-neutral snapshots and emits alerts only when a configured threshold or lifecycle transition is crossed.
- Future `AlertIngesting`: accepts normalized local alerts from sources such as AI5.

## OpenCode adapter

OpenCode has two sources. `OpenCodeLocalStore` reads recent metadata and token
counters from the local SQLite database in read-only mode. The bundled
TypeScript plugin reads OpenCode's normalized session/cache metadata and pushes
schema version `1` snapshots to a loopback-only HTTP receiver on port `5274`.

The `OpenCodeConnector` actor owns provider-specific ingestion, freshness,
deduplication, and normalization. `ProviderMonitor` and the UI only see
`ProviderSnapshot`; they do not know the wire format. Payloads older than 75
seconds are dropped, causing the provider to disappear from the adaptive view.

When explicit servers are configured, `OpenCodeServerConnector` polls the
official loopback HTTP API and assigns a stable `AgentSource` to every session.
For SSH hosts, `RemoteOpenCodeServerConnector` asks the bundled remote agent to
query the same loopback API on that machine. The configured port is never bound
or forwarded by AgentHearth. Message metadata is cached until the OpenCode
session update timestamp changes, avoiding repeated full-history reads.

The plugin is bundled with the app and installed only after an explicit action
in Settings. It is separate from the older AI Usage Bar plugin and does not use
port `5199`.

## Codex adapter

`CodexConnector` scans a bounded set of recently modified rollout JSONL files
under `~/.codex/sessions`. Its decoder declares only lifecycle, model, project,
cache-token, and rate-limit fields, so prompt and response payloads are ignored
by construction. An optional stable Codex lifecycle hook posts metadata-only
events for session start/end, prompt submission, permission requests, and stop.
The installer owns one marked block in `~/.codex/config.toml`, remains
idempotent, and preserves unrelated configuration.

An unmatched `task_started` is normalized as working (or stuck after the local
threshold). `token_count` records provide observed cache reads/writes and the
quota windows exposed by Codex. Because rollout telemetry does not expose the
effective prompt-cache option for earlier models, their expiry remains marked
as inferred. GPT-5.6-family observations use the documented exact 30-minute
policy; unknown and earlier models use a conservative five-minute fallback.

Codex cache health displays a literal request hit rate: a unique request with
`cached_input_tokens > 0` is a hit and one with zero cached input tokens is a
miss. Cold starts remain classified separately for diagnosis but stay in the
denominator. Exact token reuse (`cached_input_tokens / input_tokens`) is retained
as secondary telemetry and does not drive the `Hits` badge.

`AppModel.expiringCacheItems` is a presentation projection over
`displayedSnapshots`. It therefore inherits provider and host filtering without
adding those concerns to provider adapters. Each expiry is anchored to the
refresh that produced `remainingSeconds`; `TimelineView` updates the visible
countdown without resetting that anchor. The same `cacheWarningSeconds` setting
drives both this projection and `SnapshotAlertDetector`.

## Claude Code adapter

`ClaudeCodeConnector` combines two local sources:

- a bounded scan of recent `~/.claude/projects/**/*.jsonl` transcripts for
  session identity, project/model metadata, cache counters, and cache TTL
  evidence;
- optional Claude Code hooks for precise lifecycle, permission, waiting, and
  failure states;
- the Claude Code status-line JSON stream for Pro/Max 5-hour and 7-day usage
  windows.

The installer prunes only commands managed by AgentHearth and merges its hook
entries into every configured event, preserving all unrelated settings and
hooks. Its status-line bridge preserves and proxies an existing status-line
command instead of replacing the user's output. The bundled Python bridge uses
an explicit metadata allowlist before posting to the loopback HTTP server.

## Source strategy

Every connector supports `automatic`, `localOnly`, and `realtimeOnly`.
Automatic is the product default: local observations provide cache/token
evidence and recovery after restarts, while hooks/plugins take precedence for
fresh lifecycle states. Local-only ignores pushed events. Realtime-only never
opens provider history and therefore intentionally shows unknown cache data
when the provider hook does not include token counters.

## Alerts and navigation adapters

`SnapshotAlertDetector` owns transition detection and remains independent of
UserNotifications. `MacNotificationCenter` owns authorization, delivery, sound
policy, and click handling. `TerminalSessionOpener` maps normalized session
targets either to the selected provider-app URL route or to the provider's CLI
resume command. Apple Events are used only to open commands in Terminal.

## Dependency rule

Provider adapters depend on `AgentHearthCore`; the core never imports or references a concrete provider SDK. SwiftUI remains in the app target. This allows connector contract tests and provider-independent application logic.

## Privacy rule

The normalized model must not contain raw prompts, transcript bodies, source-file contents, or secret values. A security alert may contain a rule identifier and source location, but never the detected secret.

## Health event retention

`HistoryStore` owns `~/Library/Application Support/AgentHearth/history.sqlite`.
It persists normalized counter deltas, timestamps, provider, host, source, model,
and session title. Re-reading the same cumulative provider counters creates no
new event. A stable `external_id` makes SSH replay idempotent, while imported
cumulative counters advance `session_state` before the live snapshot is
ingested, preventing reconnect double counting.

Raw rows are pruned according to the user's 7/30/90/365-day policy. SQLite pages
are reused after pruning; **Clear History** performs an explicit vacuum. Provider
archives do not delete analytics because retention belongs to this bounded
context, not to provider session lifecycle.

For SSH hosts, filtering happens on the remote machine. Raw JSONL and SQLite
rows are not copied to the Mac; only the normalized allowlisted envelope crosses
the SSH channel. The remote standard-library collector samples once per minute,
stores only changed counters for at most 90 days, and exposes paged replay IDs.

Live polling is governed by `AdaptivePollingPolicy`: 5 seconds for working,
10 seconds for attention, 20 seconds for visible idle/warm sessions, and 30
seconds with no sessions. Historical reports have their own daily/weekly
schedule and do not change connector polling.
