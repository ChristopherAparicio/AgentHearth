import AgentHearthApplication
import AgentHearthDomain
import Foundation

/// A per-install shared secret that authenticates local provider plugins to the
/// loopback ingress server.
///
/// The token is written once to a user-only file (mode 0600 in a 0700 directory)
/// and read by the Claude Code / Codex hooks and the OpenCode plugin. Because a
/// browser cannot read this file and same-origin policy prevents it from setting
/// the custom header, requiring the token closes both the cross-origin (CSRF) and
/// the co-resident-process spoofing paths against the ingress.
public enum AgentHearthIngressToken {
    /// The HTTP header the plugins use to present the token.
    public static let headerName = "X-AgentHearth-Token"

    /// Default on-disk location, shared with the Python/TypeScript connectors.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/agenthearth/ingress-token")
    }

    /// Returns the existing token, or generates and persists a fresh one.
    ///
    /// Any read failure or empty/oversized file is treated as "no token yet" and
    /// replaced, so a corrupted file self-heals rather than disabling monitoring.
    @discardableResult
    public static func loadOrCreate(at url: URL = defaultURL) throws -> String {
        if let existing = try? read(at: url) { return existing }
        let token = generate()
        try persist(token, at: url)
        return token
    }

    private static func read(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= 4_096,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    private static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        // 32 bytes of CSPRNG output rendered as 64 hex characters.
        return (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
            .joined()
    }

    private static func persist(_ token: String, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(token.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
