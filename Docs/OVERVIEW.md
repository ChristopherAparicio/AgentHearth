# Overview

A plain-language description of what AgentHearth is for and what it shows you.
[The product brief](PRODUCT.md) covers scope and delivery order;
[the architecture](ARCHITECTURE.md) covers how it is built. This page is the
one to read first.

## Why this exists

A coding agent has no memory. Every time you send a message, the entire
conversation is packaged and sent again from the top. Your twentieth message
does not cost what you typed — it costs everything above it, one more time.

Providers soften this with a prompt cache: the unchanged prefix of the
conversation is read back at a fraction of the price of processing it fresh.
That cache is the only reason long sessions remain affordable, and it is
fragile in ways nothing tells you about:

- **It expires.** A warm session left alone goes cold, and the next turn pays
  full price for the whole conversation.
- **The model is part of its key.** Switching model mid-session — including to
  a *cheaper* one, and including a minor version bump within the same family —
  means nothing matches any more. The next turn reprocesses everything.
- **It never announces itself.** A cache miss looks exactly like an ordinary
  expensive turn. Nothing in any agent's interface distinguishes the two.

So the expensive part of agent work is usually not what you asked for. It is
re-reading what you already sent, and paying full price for it at moments you
cannot see. AgentHearth's job is to make those moments visible.

## What it shows you

**Which agents are working.** One menu bar for Claude Code, OpenAI Codex, and
OpenCode, with live session state, project, and model. Sessions on SSH machines
appear beside local ones with a host badge, so a workstation and a remote server
read the same way. Provider and machine are independent filters.

**Whether your cache is healthy.** A temperature and hit rate per session, and a
Cache Insights dashboard over 24 hours to 90 days: request-level hits, avoidable
misses, expected cold starts counted separately, daily charts, and breakdowns by
session, project, provider, and machine.

**Where tokens actually went.** Cold starts you could not avoid are separated
from misses you could. Projects are ranked by uncached input, so the one
quietly costing the most is at the top rather than buried.

**Mid-session model changes.** Every switch that broke your cache, with the
input tokens the following turn had to reprocess. Measured from the session's
own record, not estimated. This is the clearest example of the whole idea: a
real, repeated, entirely invisible cost that no other tool surfaces.

**When a cache is about to expire.** A countdown per provider and machine, with
a warning window you choose, so you can finish a session while it is still warm
instead of discovering it went cold.

**When something needs you.** Native alerts for a session waiting on input, a
job finishing, a cache about to expire, and usage limits approaching — each
category and sound configurable, so the notifications you keep are the ones you
act on.

**Sleep that follows the work.** Smart Sleep keeps macOS awake only while an
agent is actually working, with no limit, a countdown, or a target clock time.
Night mode keeps jobs alive while silencing ordinary sounds.

**A way back into any session.** One click from a card or a notification
reopens the session in Terminal or in the provider's own app, your choice per
provider. Remote sessions reopen on their source machine.

## What it deliberately does not do

The boundary is as much the product as the features:

- **No prompts, no responses, no source code, no tool payloads, no secrets.**
  Only the metadata needed for status, cache, usage, and navigation enters the
  model. This is what makes it installable without a conversation about
  what it might be reading.
- **No cloud.** History lives in a local database with a retention period you
  set. SSH monitoring is direct and local-first; nothing is uploaded to an
  AgentHearth service, because there isn't one.
- **No claimed causality it cannot show.** Where the data supports only an
  observation, it reports the observation. Recommendations appear where the
  evidence is actually there.
- **It observes; it does not act.** It will not edit your configuration, change
  your model, or run anything on your behalf.

## Where Ai5 fits

That last boundary is deliberate, and it leaves room for a companion.
[Ai5 (aisync)](https://github.com/ChristopherAparicio/aisync) captures agent
sessions and links them to branches, commits, and files — it sees content, and
it can act. AgentHearth detects the symptom continuously; Ai5 can diagnose and
correct. Normalized alerts from external tools such as Ai5 are a planned
ingestion point, so both ends can meet in one notification surface.

## At a glance

| Capability | What you get |
|---|---|
| Providers | Claude Code, OpenAI Codex, OpenCode — local and over SSH |
| Live view | Session state, project, model, host; provider and machine filters |
| Cache health | Temperature and hit rate per session |
| Cache Insights | 24h–90d dashboard: hits, avoidable misses, cold starts, daily charts |
| Waste attribution | Projects ranked by uncached input; mid-session model changes with measured cost |
| Expiry | Per-provider and per-machine countdowns with a configurable warning window |
| Alerts | Attention, completion, cache expiry, usage limits — individually configurable |
| Navigation | One-click resume in Terminal or the provider app, local or remote |
| Sleep | Smart Sleep with limit, countdown, or target time; Night mode |
| History | 7/30/90/365-day retention, optional daily or weekly reports |
| Privacy | Metadata only, local-first, no service to upload to |
| Platform | macOS 14+, menu bar app, MIT licensed |
