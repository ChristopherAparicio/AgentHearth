import AgentHearthApplication
import AgentHearthDomain
import Foundation

public enum ConnectorInstallationState: Equatable, Sendable {
    case notInstalled
    case installed
    case updateAvailable
    case unavailable(reason: String)
}

/// Shared bundled-vs-installed detection for the connector installers: an
/// installer is up to date exactly when the installed artifact's bytes match
/// the bundled source. Each installer decides beforehand whether its
/// configuration is present at all (`.notInstalled`), and supplies its own
/// fallback for an unreadable artifact.
enum ConnectorArtifactComparator {
    static func state(
        installedAt installedURL: URL,
        bundledAt sourceURL: URL?,
        missingBundleReason: String,
        whenUnreadable: ConnectorInstallationState
    ) -> ConnectorInstallationState {
        guard let sourceURL else {
            return .unavailable(reason: missingBundleReason)
        }
        guard let installed = try? Data(contentsOf: installedURL),
              let bundled = try? Data(contentsOf: sourceURL)
        else {
            return whenUnreadable
        }
        return installed == bundled ? .installed : .updateAvailable
    }
}
