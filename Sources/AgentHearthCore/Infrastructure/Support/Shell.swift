import AgentHearthApplication
import AgentHearthDomain
import Foundation

/// POSIX shell quoting shared by every component that assembles a command line.
public enum Shell {
    /// Wraps a value in single quotes, escaping embedded single quotes with the
    /// standard `'\''` sequence, so the result is always one literal word.
    public static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
