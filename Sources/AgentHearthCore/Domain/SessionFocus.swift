import Foundation

/// A durable reference to a session the user pinned as a priority. Sessions
/// are host-scoped exactly like `CacheNotificationRule` matching, so a pin
/// never bleeds onto an unrelated remote session that reuses the same id.
public struct PrioritySessionRef: Codable, Hashable, Sendable {
    public let providerID: AgentProviderID
    public let hostID: String
    public let sessionID: String

    public init(providerID: AgentProviderID, hostID: String, sessionID: String) {
        self.providerID = providerID
        self.hostID = hostID
        self.sessionID = sessionID
    }

    public init(session: AgentSession) {
        self.init(providerID: session.providerID, hostID: session.host.id, sessionID: session.id)
    }

    public init(target: SessionTarget) {
        self.init(providerID: target.providerID, hostID: target.host.id, sessionID: target.sessionID)
    }

    /// Stable key used for the `lastSeenAt` bookkeeping.
    public var key: String {
        "\(providerID.rawValue)|\(hostID)|\(sessionID)"
    }

    public func matches(_ session: AgentSession) -> Bool {
        providerID == session.providerID
            && hostID == session.host.id
            && sessionID == session.id
    }
}

/// Which sessions may raise session-scoped notifications. Usage-limit alerts
/// are account-wide and are never narrowed by this mode.
public enum NotificationFocusMode: String, Codable, Sendable {
    case all
    case priorityOnly
}

/// The user's priority-session choices: the notification focus mode, the
/// promote-on-new-session ask, and the pinned refs with their last-seen
/// bookkeeping. Decoding is backward compatible: missing keys fall back to
/// the documented defaults, same style as `AlertPreferences`.
public struct SessionFocusPreferences: Codable, Equatable, Sendable {
    /// Pins that stop matching any observed session are dropped after this
    /// interval, so refs to deleted sessions cannot accumulate forever.
    public static let pruneInterval: TimeInterval = 7 * 24 * 60 * 60
    /// Minimum spacing between two persisted `lastSeenAt` updates for a live pin.
    public static let lastSeenGranularity: TimeInterval = 60

    public var mode: NotificationFocusMode
    public var askOnNewSession: Bool
    public var pinned: [PrioritySessionRef]
    /// Keyed by `PrioritySessionRef.key`; used only for pruning stale pins.
    public var lastSeenAt: [String: Date]

    public init(
        mode: NotificationFocusMode = .all,
        askOnNewSession: Bool = true,
        pinned: [PrioritySessionRef] = [],
        lastSeenAt: [String: Date] = [:]
    ) {
        self.mode = mode
        self.askOnNewSession = askOnNewSession
        self.pinned = pinned
        self.lastSeenAt = lastSeenAt
    }

    private enum CodingKeys: String, CodingKey {
        case mode, askOnNewSession, pinned, lastSeenAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decodeIfPresent(NotificationFocusMode.self, forKey: .mode) ?? .all
        self.askOnNewSession = try container.decodeIfPresent(Bool.self, forKey: .askOnNewSession) ?? true
        self.pinned = try container.decodeIfPresent([PrioritySessionRef].self, forKey: .pinned) ?? []
        self.lastSeenAt = try container.decodeIfPresent([String: Date].self, forKey: .lastSeenAt) ?? [:]
    }

    public func isPinned(_ session: AgentSession) -> Bool {
        pinned.contains { $0.matches(session) }
    }

    public func isPinned(_ ref: PrioritySessionRef) -> Bool {
        pinned.contains(ref)
    }

    public func isPinned(_ target: SessionTarget) -> Bool {
        isPinned(PrioritySessionRef(target: target))
    }

    public mutating func pin(_ ref: PrioritySessionRef, now: Date = .now) {
        guard !pinned.contains(ref) else { return }
        pinned.append(ref)
        lastSeenAt[ref.key] = now
    }

    public mutating func pin(_ session: AgentSession, now: Date = .now) {
        pin(PrioritySessionRef(session: session), now: now)
    }

    public mutating func unpin(_ ref: PrioritySessionRef) {
        pinned.removeAll { $0 == ref }
        lastSeenAt.removeValue(forKey: ref.key)
    }

    public mutating func unpin(_ session: AgentSession) {
        unpin(PrioritySessionRef(session: session))
    }

    public mutating func togglePin(_ session: AgentSession, now: Date = .now) {
        let ref = PrioritySessionRef(session: session)
        if pinned.contains(ref) {
            unpin(ref)
        } else {
            pin(ref, now: now)
        }
    }

    /// Reconciles the pins against the currently observed sessions: refreshes
    /// `lastSeenAt` for pins that match a live session, unpins sessions that
    /// finished (completed or failed) so completed work stops focusing
    /// notifications, and prunes pins unseen for `pruneInterval`. Returns
    /// whether anything changed, so callers persist only real mutations.
    @discardableResult
    public mutating func reconcile(sessions: [AgentSession], now: Date) -> Bool {
        var changed = false
        var keptPins: [PrioritySessionRef] = []

        for ref in pinned {
            if let session = sessions.first(where: ref.matches) {
                if session.status == .completed || session.status == .failed {
                    lastSeenAt.removeValue(forKey: ref.key)
                    changed = true
                    continue
                }
                // The last-seen clock only feeds the seven-day prune, so it is
                // advanced at minute granularity: refreshing it on every 5 s
                // poll re-encoded and rewrote the whole preference each time.
                let isFresh = lastSeenAt[ref.key].map { seen in
                    now >= seen && now.timeIntervalSince(seen) < Self.lastSeenGranularity
                } ?? false
                if !isFresh {
                    lastSeenAt[ref.key] = now
                    changed = true
                }
                keptPins.append(ref)
            } else if let lastSeen = lastSeenAt[ref.key] {
                if now.timeIntervalSince(lastSeen) >= Self.pruneInterval {
                    lastSeenAt.removeValue(forKey: ref.key)
                    changed = true
                } else {
                    keptPins.append(ref)
                }
            } else {
                // A pin restored without bookkeeping (older persisted data):
                // seed it now so the seven-day prune clock starts ticking.
                lastSeenAt[ref.key] = now
                changed = true
                keptPins.append(ref)
            }
        }

        if keptPins != pinned {
            pinned = keptPins
            changed = true
        }

        // Drop bookkeeping whose pin no longer exists.
        let validKeys = Set(pinned.map(\.key))
        let orphanKeys = lastSeenAt.keys.filter { !validKeys.contains($0) }
        if !orphanKeys.isEmpty {
            for key in orphanKeys { lastSeenAt.removeValue(forKey: key) }
            changed = true
        }

        return changed
    }
}
