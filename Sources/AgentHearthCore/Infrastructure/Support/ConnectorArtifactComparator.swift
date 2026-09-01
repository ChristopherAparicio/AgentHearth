import AgentHearthApplication
import AgentHearthDomain
import Foundation

/// Keeps a copy of a user-owned configuration file before an installer
/// rewrites it. One backup per file (`<name>.agenthearth-backup`), overwritten
/// on each install, so the version that preceded the latest rewrite is always
/// recoverable.
public enum ConnectorConfigBackup {
    public static let suffix = ".agenthearth-backup"

    public static func backupURL(for url: URL) -> URL {
        URL(fileURLWithPath: url.path + suffix)
    }

    /// No-op when the file does not exist yet. Permissions of the original are
    /// preserved by copying the file rather than rewriting its bytes.
    public static func preserve(_ url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let destination = backupURL(for: url)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
    }
}

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
