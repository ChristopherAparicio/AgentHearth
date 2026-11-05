import Foundation

/// Turns live hook events into a refresh, instead of leaving them unseen until
/// the next poll: a permission prompt then reaches the menu and notifications
/// within a moment. Events come in bursts (a prompt, then its notification), so
/// those arriving while a refresh is pending share it.
///
/// It exists before the model does — the connector server that feeds it is one
/// of the model's dependencies — so `refresh` is wired up afterwards.
@MainActor
final class LiveEventRefresher {
    var refresh: () async -> Void = {}
    private let delay: Duration
    private var pending: Task<Void, Never>?

    init(delay: Duration = .milliseconds(500)) {
        self.delay = delay
    }

    func eventArrived() {
        guard pending == nil else { return }
        pending = Task {
            try? await Task.sleep(for: delay)
            pending = nil
            await refresh()
        }
    }
}
