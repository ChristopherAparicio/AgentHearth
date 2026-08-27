/**
 * AgentHearth OpenCode connector v0.1.0
 *
 * Sends local, metadata-only session snapshots to AgentHearth. It never sends
 * prompts, message bodies, tool input/output, source code, or secret values.
 */

import type { Plugin } from "@opencode-ai/plugin"
import { readFile } from "node:fs/promises"
import { homedir, hostname } from "node:os"
import { join } from "node:path"

const PLUGIN_VERSION = "0.2.0"
const SCHEMA_VERSION = 1
const CONFIG_PATH = join(homedir(), ".config", "agenthearth", "opencode.json")
const TOKEN_PATH = join(homedir(), ".config", "agenthearth", "ingress-token")

const loadToken = async (): Promise<string | undefined> => {
	const token = await readFile(TOKEN_PATH, "utf8").then((text) => text.trim()).catch(() => "")
	return token || undefined
}

const DEFAULTS = {
	appUrl: "http://127.0.0.1:5274",
	checkIntervalSeconds: 15,
	maxSessionAgeMinutes: 120,
	stuckMinutes: 15,
	cacheTtlMinutes: { anthropic: 5, openai: 5, google: 5 } as Record<string, number>,
	cacheTtlMinutesByModel: { "gpt-5.6": 30 } as Record<string, number>,
	cacheDefaultTtlMinutes: 5,
	cacheWarnLeadMinutes: 1,
}

type Config = typeof DEFAULTS
type OpenCodeStatus = { type: "idle" } | { type: "busy" } | { type: "retry" }
type AssistantInfo = {
	role?: string
	providerID?: string
	modelID?: string
	time?: { created?: number; completed?: number }
	error?: unknown
	tokens?: { cache?: { read?: number; write?: number } }
}

const lastChunkAt = new Map<string, number>()
const statuses = new Map<string, OpenCodeStatus>()
const pendingApprovals = new Set<string>()

const loadConfig = async (): Promise<Config> => {
	const raw = (await readFile(CONFIG_PATH, "utf8")
		.then((text) => JSON.parse(text) as Partial<Config>)
		.catch(() => ({}))) as Partial<Config>
	return {
		...DEFAULTS,
		...raw,
		cacheTtlMinutes: { ...DEFAULTS.cacheTtlMinutes, ...(raw.cacheTtlMinutes ?? {}) },
		cacheTtlMinutesByModel: {
			...DEFAULTS.cacheTtlMinutesByModel,
			...(raw.cacheTtlMinutesByModel ?? {}),
		},
	}
}

const cacheTTL = (config: Config, provider: string | undefined, model: string | undefined) => {
	const modelMatch = Object.entries(config.cacheTtlMinutesByModel)
		.find(([prefix]) => model?.toLowerCase().startsWith(prefix.toLowerCase()))
	if (modelMatch) return modelMatch[1]
	return config.cacheTtlMinutes[provider ?? "unknown"] ?? config.cacheDefaultTtlMinutes
}

const health = (turns: AssistantInfo[], config: Config) => {
	let hitCount = 0
	let avoidableMissCount = 0
	let expectedColdStartCount = 0
	let unknownCount = 0
	let previous: AssistantInfo | undefined

	for (const turn of turns) {
		if (!turn.tokens) {
			unknownCount++
			previous = turn
			continue
		}
		const read = turn.tokens?.cache?.read ?? 0
		if (read > 0) {
			hitCount++
			previous = turn
			continue
		}

		const previousCompleted = previous?.time?.completed
		const currentCreated = turn.time?.created
		const sameModel = previous?.modelID === turn.modelID && previous?.providerID === turn.providerID
		const eligible = Boolean(
			previousCompleted &&
			currentCreated &&
			sameModel &&
			currentCreated! - previousCompleted! <= cacheTTL(config, turn.providerID, turn.modelID) * 60_000,
		)

		if (!eligible) expectedColdStartCount++
		else avoidableMissCount++
		previous = turn
	}

	return { hitCount, avoidableMissCount, expectedColdStartCount, unknownCount }
}

export const AgentHearthPlugin: Plugin = async ({ client, directory }) => {
	const instanceID = `${hostname()}:${process.pid}:${directory}`
	const log = (message: string) =>
		client.app.log({
			body: { service: "agenthearth", level: "info", message },
		}).catch(() => {})

	log(`[agenthearth] connector ${PLUGIN_VERSION} loaded (runtime: ${instanceID})`)

	const push = async () => {
		const config = await loadConfig()
		const now = Date.now()
		const maximumAge = config.maxSessionAgeMinutes * 60_000

		const [sessionsResponse, statusesResponse] = await Promise.all([
			client.session.list({ query: { directory } }).catch(() => ({ data: [] })),
			client.session.status({ query: { directory } }).catch(() => ({ data: {} })),
		])

		for (const [sessionID, status] of Object.entries(statusesResponse.data ?? {})) {
			statuses.set(sessionID, status as OpenCodeStatus)
		}

		const sessions = (sessionsResponse.data ?? [])
			.filter((session) => !session.parentID && now - session.time.updated <= maximumAge)

		const reports = await Promise.all(sessions.map(async (session) => {
			const messagesResponse = await client.session.messages({
				path: { id: session.id },
				query: { directory, limit: 100 },
			}).catch(() => ({ data: [] }))
			const turns = (messagesResponse.data ?? [])
				.map((message) => message.info as AssistantInfo)
				.filter((info) => info.role === "assistant")
			const latest = turns.at(-1)
			const latestCompleted = [...turns].reverse().find((turn) => turn.time?.completed)
			const activity = Math.max(
				lastChunkAt.get(session.id) ?? 0,
				latest?.time?.completed ?? latest?.time?.created ?? session.time.updated,
			)
			const idleMilliseconds = Math.max(0, now - activity)
			const status = statuses.get(session.id)
			const isWorking = status?.type === "busy" || status?.type === "retry"
			const reportedStatus = latest?.error
				? "failed"
				: pendingApprovals.has(session.id)
					? "waitingForApproval"
					: isWorking && idleMilliseconds >= config.stuckMinutes * 60_000
						? "stuck"
						: isWorking
							? "working"
							: "idle"

			const provider = latest?.providerID ?? latestCompleted?.providerID
			const ttlMinutes = cacheTTL(config, provider, latest?.modelID ?? latestCompleted?.modelID)
			const cacheActivity = latestCompleted?.time?.completed ?? latestCompleted?.time?.created
			const cacheAge = cacheActivity ? Math.max(0, now - cacheActivity) : undefined
			const remainingSeconds = cacheAge === undefined
				? undefined
				: Math.max(0, Math.ceil((ttlMinutes * 60_000 - cacheAge) / 1_000))
			const temperature = cacheAge === undefined
				? "unknown"
				: cacheAge >= ttlMinutes * 60_000
					? "cold"
					: cacheAge >= (ttlMinutes - config.cacheWarnLeadMinutes) * 60_000
						? "expiring"
						: "warm"

			return {
				id: session.id,
				title: session.title || session.id,
				projectPath: directory,
				model: latest?.modelID ?? latestCompleted?.modelID,
				provider,
				status: reportedStatus,
				lastActivityAt: activity,
				cache: {
					temperature,
					remainingSeconds,
					ttlSeconds: ttlMinutes * 60,
					cachedReadTokens: latest?.tokens?.cache?.read ?? 0,
					cacheWriteTokens: latest?.tokens?.cache?.write ?? 0,
					...health(turns, config),
				},
			}
		}))

		const token = await loadToken()
		const headers: Record<string, string> = { "content-type": "application/json" }
		if (token) headers["X-AgentHearth-Token"] = token
		await fetch(`${config.appUrl}/v1/providers/opencode/snapshots`, {
			method: "POST",
			headers,
			body: JSON.stringify({
				schemaVersion: SCHEMA_VERSION,
				pluginVersion: PLUGIN_VERSION,
				instance: instanceID,
				sentAt: now,
				sessions: reports,
			}),
		}).catch(() => {})
	}

	const intervalSeconds = Math.max(5, (await loadConfig()).checkIntervalSeconds)
	const interval = setInterval(() => push().catch(() => {}), intervalSeconds * 1_000) as unknown as {
		unref?: () => void
	}
	interval.unref?.()
	setTimeout(() => push().catch(() => {}), 1_000)

	return {
		event: async ({ event }) => {
			switch (event.type) {
				case "message.part.updated":
					lastChunkAt.set(event.properties.part.sessionID, Date.now())
					break
				case "session.status":
					statuses.set(event.properties.sessionID, event.properties.status as OpenCodeStatus)
					break
				case "session.idle":
					statuses.set(event.properties.sessionID, { type: "idle" })
					break
				case "permission.updated":
					pendingApprovals.add(event.properties.sessionID)
					break
				case "permission.replied":
					pendingApprovals.delete(event.properties.sessionID)
					break
				case "session.deleted":
					statuses.delete(event.properties.info.id)
					pendingApprovals.delete(event.properties.info.id)
					lastChunkAt.delete(event.properties.info.id)
					break
			}
		},
	}
}
