# AgentHearth — AI Coding Agent Monitor for macOS

**Monitor Claude Code, OpenAI Codex, and OpenCode sessions from one native macOS menu bar app.**

AgentHearth is a local-first AI agent usage monitor for session activity,
prompt-cache health, usage limits, native notifications, and intelligent sleep
management. It helps developers see which coding agents are working, waiting,
stuck, or losing a warm prompt cache—without uploading conversations or source
code to an AgentHearth service.

## Why AgentHearth

- One adaptive menu bar for OpenCode, Codex, and Claude Code.
- A composable menu-bar label: add items (session counts, usage windows,
  cache reuse, warm caches, expiring caches) scoped to one provider or all, each with its
  own color and prefix, with a live preview in Settings. The default is the
  flame alone.
- Live session state with project and model context.
- Prompt-cache temperature and cache-hit health per session.
- Cache Insights dashboard with request-level hits, misses, cold starts, daily
  charts, and per-session/provider/machine breakdowns.
- Bounded local history with 7/30/90/365-day retention and optional daily or
  weekly macOS reports.
- Provider/machine-scoped cache-expiry countdowns with a configurable warning window.
- Native macOS alerts for attention, completion, cache expiry, and usage limits.
- Priority sessions: star sessions to focus notifications on them, or pin every
  session whose cache is still warm in one action (star menu, ⇧⌘P, or Settings).
- One-click session resume in Terminal from a card or notification.
- Monitor sessions on SSH machines with the same provider cards and host badges.
- Combine provider tabs with an `All machines / This Mac / SSH host` dropdown.
- Register several loopback OpenCode servers per machine and filter the menu by
  `All servers` or a named runtime.
- Smart Sleep keeps macOS awake only while an agent is actively working, with
  no limit, a countdown, or a target clock time.
- Night mode keeps jobs alive while silencing ordinary notification sounds.
- Local-only, provider-neutral architecture designed for additional connectors.

## Connector status

| Provider | Status | Integration |
|---|---|---|
| OpenCode | Testable | Local SQLite analysis + bundled metadata-only plugin |
| OpenAI Codex | Testable | Bounded rollout analysis + optional lifecycle hooks |
| Claude Code | Testable | Automatic transcript scan + optional hooks/status-line relay |

The same three providers can run on SSH hosts. AgentHearth installs one small
Python remote agent per host, then reads normalized snapshots through the system
SSH client and the user's existing `~/.ssh/config`.

The remote agent keeps a metadata-only 90-day cache-event journal and samples
provider counters once per minute. If the Mac is asleep or powered off, events
continue accumulating on the SSH host and are replayed idempotently when
AgentHearth reconnects. No prompt, response, source file, or tool payload enters
that journal.

The menu bar keeps provider and machine as independent filters. For example,
select **Codex** with **All machines** to compare every Codex task, or select
**RTX 5090** to show every provider running on that host. Counts, usage bars,
cache state, and session lists follow the combined scope. Smart Sleep remains
global so changing a visual filter cannot accidentally release an active job.

The **Caches expiring soon** panel follows the same provider and machine scope.
Settings controls whether the panel starts at 1, 2, 5, 10, or 15 minutes before
expiry; the same threshold drives native cache-expiry notifications.

### Test an SSH host

1. Open **Settings → Remote Hosts**.
2. Enter an SSH config alias such as `rtx-server` and choose **Add SSH Host**.
3. Choose **Install / Update Agent**. This installs a standard-library Python
   helper, starts its loopback receiver, and installs the bundled OpenCode
   plugin on the remote host.
4. Run Codex, OpenCode, or Claude Code remotely. Their sessions appear in the
   normal provider cards with an SSH host badge.

**Test Connection** also shows an inline provider summary and up to six detected
remote sessions directly in Settings, including state, project, and cache
temperature. **Uninstall Agent** is a separate confirmed action; removing the
host from the macOS list never deletes remote files.

The OpenCode plugin posts to `127.0.0.1:5274` there, where the shared remote
agent is listening. Claude Code remote hook installation follows in the next
connector milestone; its local transcript analysis already works. Clicking a
remote session runs the provider's resume command through `ssh -t` in the remote
project directory.

Each provider can use **Automatic** (recommended), **Local only**, or
**Realtime only** in Settings. Automatic reconciles local history with live
events so restarts and missed hooks do not create gaps.

### Test the OpenCode connector

1. Build and launch AgentHearth.
2. Open **Settings → OpenCode Connector** and choose **Install Connector**.
3. Restart OpenCode or start a new OpenCode process.
4. Run a prompt. The OpenCode card appears automatically while the session is
   working or its prompt cache is still warm.

The bundled plugin is installed at
`~/.config/opencode/plugins/agenthearth.ts`. It posts metadata to the
loopback-only AgentHearth receiver on port `5274`; it can coexist with AI Usage
Bar on port `5199`.

### Monitor several OpenCode servers

1. Open **Settings → OpenCode Servers**.
2. Add a friendly name, choose **This Mac** or an existing SSH host, and enter
   the loopback port used by that OpenCode server (for example `4096`).
3. Use **Test** to verify the endpoint. In the OpenCode tab, use the compact
   source menu to show all configured servers or one server only.

OpenCode ports remain bound to `127.0.0.1`. For an SSH machine, the bundled
remote agent reads that machine's loopback endpoint and returns normalized
metadata through the existing SSH connection; no port-forward or public bind is
required.

### Test the Codex connector

1. Launch AgentHearth and use Codex normally from the desktop app or CLI.
2. No installation is required. Recent `~/.codex/sessions` rollout files are
   scanned with strict byte and file-count limits.
3. AgentHearth displays active tasks, model/project metadata, observed cache
   reads/writes, cache health, and the quota windows Codex exposes locally.
4. Optionally choose **Install Live Hooks** to receive session start, stop, and
   permission states immediately. Codex may ask you to trust the hook when the
   next session starts.

AgentHearth ignores content-bearing rollout records. The optional installer
appends one idempotent, clearly marked block to `~/.codex/config.toml` and
preserves existing settings and hooks. Its bridge sends only whitelisted
session metadata to the loopback receiver.

### Test the Claude Code connector

1. Launch AgentHearth. Recent sessions and cache counters are detected from
   `~/.claude/projects` without installation.
2. For precise live states and 5-hour/7-day usage windows, open
   **Settings → Claude Code Connector** and choose **Install Live Hooks**.
3. Start a new Claude Code session, then run a prompt or trigger a permission
   request.

Hook installation merges AgentHearth entries into `~/.claude/settings.json`
and preserves existing hooks. It also installs a transparent status-line relay:
if another status-line command already exists, AgentHearth forwards the same
input to it and preserves its output. Claude exposes rate-limit fields only
after the first API response in a session. The bundled bridge sends only
whitelisted metadata to the loopback receiver; prompts, responses, tool
arguments, and transcript contents are never posted.

### Claude usage limits and the Keychain prompts

**Settings → Claude Usage Limits → Fetch reset times from Anthropic** is off
by default. When you turn it on, AgentHearth reads the OAuth token that Claude
Code already stores in your login keychain (items named `Claude Code-credentials`,
plain or suffixed with a profile id as Claude Code 2.1 does; the freshest
usable token wins, with `~/.claude/.credentials.json` as a last resort)
and calls Anthropic's usage endpoint to get the exact 5-hour and 7-day reset
times, plus Anthropic's per-model weekly limits (shown as an extra bar named after
the model under the 7-day one, often the binding limit; toggle them in the
same section). The token is
read once per launch, kept in memory, and read again only
after it expires or rotates. It is never written, refreshed, or sent anywhere
but `api.anthropic.com`.

Because that item was created by Claude Code, macOS asks for your consent the
first time, and you may see **two** dialogs in a row. That is expected:

1. *AgentHearth wants to access the "login" keychain* — shown only while the
   keychain is locked (for example after "Lock after N minutes of inactivity"
   in Keychain Access). Unlocking the keychain does not by itself grant access
   to the item, hence the second dialog.
2. *AgentHearth wants to use your confidential information stored in
   "Claude Code-credentials"* — the item's own access list. Choose
   **Always Allow** to record the choice; AgentHearth is signed with a stable
   Developer ID identity, so the choice survives reinstalls via `task install`.

To stop the first dialog from coming back, open Keychain Access, right-click
the *login* keychain, choose *Change Settings*, and disable automatic locking.
Leaving the feature off avoids the Keychain entirely; usage windows then come
from the Claude Code status line while a session is open.

## Alerts and session navigation

Notification categories and sounds are independently configurable in Settings.
Smart Sleep's Night mode keeps active work awake while muting ordinary sounds;
critical sounds can remain enabled. Choose **For** to allow sleep after 30
minutes to 8 hours, or **Until** to select a clock time; a time already passed
means the following day. At the deadline AgentHearth releases its macOS sleep
assertion even if an agent is still working. In **Settings → Opening Sessions**,
choose Terminal or the provider app for each local provider. Clicking a session
notification or the arrow on a session row uses that choice. Claude resumes the
exact session in its Code interface; Terminal uses the provider's stable CLI
session identifier. Remote SSH sessions always resume in Terminal on their
source machine.

## Cache Insights and storage

Choose **Insights** in the menu bar footer, or **Settings → History & Reports →
Open Cache Insights**, to inspect cache outcomes over 24 hours, 7 days, 30 days,
or 90 days. AgentHearth stores only counter deltas, so repeatedly polling an
unchanged session does not add rows or inflate totals. Archiving a provider
session does not erase its AgentHearth analytics; rows expire according to the
selected retention period, or immediately when **Clear History** is confirmed.

Polling is adaptive: 5 seconds while an agent is working, 10 seconds when an
action is required, 20 seconds for visible idle/warm sessions, and 30 seconds
when no session is visible. Daily/weekly reports and their notification hour
are configured independently from this live refresh cadence.

## Development

Requirements:

- macOS 14 or later
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [Task](https://taskfile.dev)

```bash
task bootstrap
task test
task open
```

Install a release build into `/Applications` (or remove it):

```bash
task install
task uninstall
```

## Architecture

- `AgentHearthCore`: provider-neutral domain and application services.
- `AgentHearth`: SwiftUI/AppKit presentation and composition root.
- `Integrations/OpenCode`: bundled OpenCode plugin and connector documentation.
- `Integrations/Codex`: bundled metadata-only lifecycle hook bridge.
- `Integrations/ClaudeCode`: bundled metadata-only live hook bridge.
- `Integrations/Remote`: shared SSH-host collector and snapshot normalizer.
- Provider adapters implement `ProviderConnector`; no provider payload leaks
  into the UI or domain model.
- AI5 and other external tools will later integrate through a separate custom
  alert-ingestion port.

See [the architecture](Docs/ARCHITECTURE.md),
[product brief](Docs/PRODUCT.md), and
[OpenCode connector guide](Integrations/OpenCode/README.md).

## Privacy

AgentHearth collects only the metadata required for status, cache, usage, and
session navigation. Raw prompts, response bodies, tool input/output, source
code, and secret values never enter its normalized model.

## Project name

**AgentHearth** is the brand; **AI Coding Agent Monitor for macOS** is the
descriptive subtitle used for discovery. This keeps the name distinctive while
making Claude Code, Codex, OpenCode, prompt caching, and token usage explicit to
search engines and GitHub search.

## Secret hygiene

CI runs [gitleaks](https://github.com/gitleaks/gitleaks) on every push and pull
request (`.github/workflows/gitleaks.yml`), scanning the full git history for
leaked credentials. Known-public strings (the Apple Team ID, notarization
placeholder docs) are allowlisted in `.gitleaks.toml`.

To get the same protection locally before anything reaches CI, install the
[pre-commit](https://pre-commit.com) hook once after cloning:

```bash
brew install pre-commit gitleaks
pre-commit install
```

Every commit is then scanned for secrets before it is created.

## License

AgentHearth is released under the [MIT License](LICENSE).
