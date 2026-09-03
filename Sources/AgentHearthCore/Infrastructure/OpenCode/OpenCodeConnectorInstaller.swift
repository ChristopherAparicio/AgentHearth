import AgentHearthApplication
import AgentHearthDomain
import Foundation

public struct OpenCodeConnectorInstaller {
    public let pluginURL: URL
    public let configURL: URL

    public init(
        pluginURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/opencode/plugins/agenthearth.ts"),
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/agenthearth/opencode.json")
    ) {
        self.pluginURL = pluginURL
        self.configURL = configURL
    }

    public func state(comparedWith sourceURL: URL?) -> ConnectorInstallationState {
        guard FileManager.default.fileExists(atPath: pluginURL.path) else {
            return .notInstalled
        }
        return ConnectorArtifactComparator.state(
            installedAt: pluginURL,
            bundledAt: sourceURL,
            missingBundleReason: "Bundled OpenCode connector is missing",
            whenUnreadable: .unavailable(reason: "OpenCode connector cannot be read")
        )
    }

    public func install(from sourceURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: pluginURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pluginData = try Data(contentsOf: sourceURL)
        try pluginData.write(to: pluginURL, options: .atomic)

        // The TTL facts live in `CacheTTLPolicy`; the generated JSON only
        // restates them in minutes.
        let fallbackTTLMinutes = CacheTTLPolicy.fallbackTTLSeconds / 60
        let documentedTTLMinutes = CacheTTLPolicy.documentedOpenAITTLSeconds / 60
        let documentedModelID = CacheTTLPolicy.documentedOpenAIModelID

        if !fileManager.fileExists(atPath: configURL.path) {
            try fileManager.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let defaults = """
            {
              "appUrl" : "http://127.0.0.1:5274",
              "cacheDefaultTtlMinutes" : \(fallbackTTLMinutes),
              "cacheTtlMinutes" : {
                "anthropic" : \(fallbackTTLMinutes),
                "google" : \(fallbackTTLMinutes),
                "openai" : \(fallbackTTLMinutes)
              },
              "cacheTtlMinutesByModel" : {
                "\(documentedModelID)" : \(documentedTTLMinutes)
              },
              "cacheWarnLeadMinutes" : 1,
              "checkIntervalSeconds" : 15,
              "maxSessionAgeMinutes" : 120
            }
            """
            try Data(defaults.utf8).write(to: configURL, options: .atomic)
        } else if let data = try? Data(contentsOf: configURL),
                  var config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  config["cacheTtlMinutesByModel"] == nil {
            config["cacheTtlMinutesByModel"] = [documentedModelID: documentedTTLMinutes]
            let updated = try JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .sortedKeys]
            )
            try updated.write(to: configURL, options: .atomic)
        }
    }
}
