import AgentHearthCore
import Foundation
import Observation

/// Owns the priority-sessions feature: the persisted `SessionFocusPreferences`
/// value — the single write path to its `PreferencesStore` key — and every pin,
/// focus-mode, and promote-ask mutation. Reconciliation after each snapshot
/// refresh unpins finished sessions and prunes pins that stopped matching any
/// observed session.
@MainActor
@Observable
final class SessionFocusService {
    private let store: PreferencesStore

    private(set) var preferences: SessionFocusPreferences {
        didSet {
            guard preferences != oldValue else { return }
            store.sessionFocusPreferences = preferences
        }
    }

    init(preferences store: PreferencesStore) {
        self.store = store
        self.preferences = store.sessionFocusPreferences
    }

    var mode: NotificationFocusMode { preferences.mode }
    var isPriorityOnly: Bool { preferences.mode == .priorityOnly }
    var askOnNewSession: Bool { preferences.askOnNewSession }
    var pinnedCount: Int { preferences.pinned.count }
    var pinnedRefs: Set<PrioritySessionRef> { Set(preferences.pinned) }

    func isPinned(_ session: AgentSession) -> Bool {
        preferences.isPinned(session)
    }

    func togglePin(_ session: AgentSession) {
        preferences.togglePin(session)
    }

    /// Pins from a macOS notification action, where only the delivered
    /// `SessionTarget` is available.
    func pin(target: SessionTarget) {
        preferences.pin(PrioritySessionRef(target: target))
    }

    func unpin(_ ref: PrioritySessionRef) {
        preferences.unpin(ref)
    }

    func setMode(_ mode: NotificationFocusMode) {
        preferences.mode = mode
    }

    func setAskOnNewSession(_ enabled: Bool) {
        preferences.askOnNewSession = enabled
    }

    /// Called after every snapshot refresh with all observed sessions (hidden
    /// providers included). Persistence happens through the property's didSet
    /// only when the domain reconcile actually changed something.
    func reconcile(sessions: [AgentSession]) {
        preferences.reconcile(sessions: sessions, now: .now)
    }
}
