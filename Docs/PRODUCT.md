# Product brief

AgentHearth is the local control center for coding agents on macOS.

It answers four questions:

1. Which agents are still working?
2. Which sessions require human attention?
3. Which prompt caches are warm or about to expire?
4. Can macOS sleep without interrupting active work?

## Initial scope

- Adaptive view: hide unavailable providers and show an `All` filter only when multiple providers are active.
- Normalized sessions for Codex, Claude Code, and OpenCode.
- Provider-specific quota windows without assuming fixed 5-hour or 7-day periods.
- Explicit cache confidence: exact, observed, inferred, or unknown.
- Native macOS notifications with session navigation.
- Smart Sleep that prevents idle system sleep only while eligible work is
  active, optionally bounded by a remaining duration or target clock time.
- Night mode that keeps work alive while silencing ordinary notification sounds.
- Per-provider source strategy: automatic reconciliation, local-only analysis,
  or realtime-only hooks/plugins.
- Optional SSH hosts with one remote agent shared by Codex, Claude Code, and
  OpenCode; sessions show their host and resume on that host.
- Orthogonal provider and machine filters: all providers or one provider across
  all machines, this Mac, or a selected SSH host.
- Named OpenCode server sources per local or SSH machine, with an `All servers`
  filter and loopback-only connectivity.
- A live cache-expiry queue scoped by those filters, with per-session countdowns,
  quick resume, and one warning lead time shared with native notifications.
- A local Cache Insights dashboard with bounded retention, per-session cache
  outcomes, and configurable daily/weekly summaries.
- Offline SSH continuity through a metadata-only remote event journal.

## Delivery order

1. OpenCode: bundled push connector, live session/cache cards, and Smart Sleep.
2. OpenAI Codex: normalized local session and usage adapter.
3. Claude Code: normalized local session and usage adapter.
4. Native alert delivery, click-to-session navigation, and richer quota windows. **Implemented.**
5. SSH remote host monitoring and remote session resume. **Implemented as an MVP.**
6. Bounded cache history, Cache Insights, and scheduled reports. **Implemented.**
7. AI5/custom alert ingestion.

AI5/custom alerts remain a separate extension point so their domain does not
leak into provider adapters.

## Session cache health

Each session can expose a request-level cache-health band. A hit is an observed
provider request with cached input tokens; an observed request with zero cached
input tokens is a miss:

- Green: at least 70% cache hits.
- Yellow: 30% to 69% cache hits.
- Red: below 30% cache hits.
- Gray: fewer than five observed requests or insufficient provider data.

The displayed score is `hits / observed requests`: nine requests with cached
tokens followed by one request without cached tokens is displayed as
`Hits 9/10 · 90%`. Expected
cold starts—such as returning after the provider TTL—remain a separate
diagnostic category, but still count as misses in this literal request hit rate.
Requests for which the provider exposes no usable cache telemetry are unknown
and excluded from the denominator. Exact token totals are retained separately
for future efficiency diagnostics but do not replace the request hit rate.

Connectors must report confidence and evidence. AgentHearth must not label a
request as an avoidable miss when the provider data cannot establish that reuse
was possible.

## Cache expiry queue

The menu bar and Settings expose sessions whose cache will expire within the
configured 1–15 minute warning interval. The queue follows the current provider
and machine filters, sorts sessions by soonest expiry, shows provider and host,
updates countdowns once per second, and preserves one-click session resume.

An exact countdown is shown only when the adapter can establish the provider's
TTL. Estimated countdowns use a `~` prefix. The queue remains visible when macOS
notifications are disabled; the cache-expiry notification toggle only controls
delivery.

## Cache insight reports

The implemented dashboard includes request hits, avoidable misses, expected
cold starts, daily buckets, and per-session/provider/machine summaries. Its
event store records only counter deltas and supports 7, 30, 90, or 365 days of
retention. Daily and weekly notification summaries are optional and use a
configurable delivery hour.

Future recommendation reports may additionally include:

- average and peak concurrently working sessions, measured from activity
  intervals rather than merely loaded histories;
- request cache-hit rate and avoidable misses by provider and project;
- expected cold starts, shown separately;
- time spent working, waiting for input, waiting for approval, and stuck;
- the relationship between high concurrency and avoidable cache misses;
- concise, evidence-based recommendations.

AgentHearth may recommend trying fewer simultaneous sessions only when the data
shows both repeated avoidable misses and a meaningful deterioration during
high-concurrency periods. Otherwise it should describe the observation without
claiming causality.

## Deferred scope

- AI5 and custom alert ingestion.
- Concurrency recommendations and usage forecasting.
- Cloud synchronization. SSH monitoring remains direct and local-first.
- Accessibility-based navigation into third-party desktop applications.
