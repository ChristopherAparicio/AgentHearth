import AgentHearthDomain
import Foundation

public struct NotificationPolicy: Codable, Equatable, Sendable {
    public var soundsEnabled: Bool
    public var silenceSoundsInNightMode: Bool
    public var allowCriticalSoundsInNightMode: Bool

    public init(
        soundsEnabled: Bool = true,
        silenceSoundsInNightMode: Bool = true,
        allowCriticalSoundsInNightMode: Bool = true
    ) {
        self.soundsEnabled = soundsEnabled
        self.silenceSoundsInNightMode = silenceSoundsInNightMode
        self.allowCriticalSoundsInNightMode = allowCriticalSoundsInNightMode
    }

    public func shouldPlaySound(for severity: AlertSeverity, smartSleepMode: SmartSleepMode) -> Bool {
        guard soundsEnabled else { return false }
        guard smartSleepMode == .night, silenceSoundsInNightMode else { return true }
        return severity == .critical && allowCriticalSoundsInNightMode
    }
}
