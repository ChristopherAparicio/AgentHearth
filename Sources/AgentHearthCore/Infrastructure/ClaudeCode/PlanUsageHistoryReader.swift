import AgentHearthApplication
import AgentHearthDomain
import Foundation

/// The newest 5h/7d utilization sample the Claude desktop app has recorded.
struct PlanUsageSample: Equatable {
    let fiveHourFraction: Double?
    let sevenDayFraction: Double?
    let measuredAt: Date
}

/// Reads Claude Desktop's local, account-global usage journal.
///
/// The desktop app writes the `anthropic-ratelimit-unified-*` values it sees on
/// its own API responses to `~/Library/Application Support/Claude/
/// plan-usage-history.json` as `{ "t": <ms>, "u": { "fh": <5h %>, "sd": <7d %> } }`
/// samples. Reading the newest sample gives AgentHearth the real 5h/7d numbers
/// without any network request, credential, or active terminal session — the
/// figures simply refresh whenever the desktop app or a CLI session is active.
public enum PlanUsageHistoryReader {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Claude/plan-usage-history.json")

    // Claude Desktop appends to this file on every API response, so it grows
    // without bound. Only the newest sample is ever needed, so read a bounded
    // tail first and fall back to a full decode only if that fails.
    private static let tailByteLimit = 32 * 1_024

    static func latestSample(at url: URL) -> PlanUsageSample? {
        if let sample = latestSampleFromTail(at: url) { return sample }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return latestSample(in: data)
    }

    private static func latestSample(in data: Data) -> PlanUsageSample? {
        guard let file = try? JSONDecoder().decode(PlanUsageHistoryFile.self, from: data) else { return nil }
        let newest = file.samples
            .filter { $0.u?.fh != nil || $0.u?.sd != nil }
            .max { $0.t < $1.t }
        return newest.flatMap(sample(from:))
    }

    /// Parses just the last complete sample object from the end of the file.
    /// Samples are appended in time order and contain no nested braces beyond a
    /// single `"u"` object, so a bare brace scan from the last `{"t":` isolates
    /// the newest sample without decoding the whole (ever-growing) array.
    private static func latestSampleFromTail(at url: URL) -> PlanUsageSample? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        let start = size > UInt64(tailByteLimit) ? size - UInt64(tailByteLimit) : 0
        try? handle.seek(toOffset: start)
        guard let tail = try? handle.readToEnd(),
              let text = String(data: tail, encoding: .utf8)
        else { return nil }

        let marker = "{\"t\":"
        var searchEnd = text.endIndex
        while let range = text.range(of: marker, options: .backwards, range: text.startIndex..<searchEnd) {
            if let object = balancedObject(in: text, from: range.lowerBound),
               let data = object.data(using: .utf8),
               let sample = (try? JSONDecoder().decode(PlanUsageHistoryFile.Sample.self, from: data)),
               sample.u?.fh != nil || sample.u?.sd != nil {
                return self.sample(from: sample)
            }
            searchEnd = range.lowerBound // truncated/invalid: try the previous one
        }
        return nil
    }

    /// Returns the substring of a balanced `{...}` object starting at `start`,
    /// or nil if the braces do not close within the given text (truncated tail).
    private static func balancedObject(in text: String, from start: String.Index) -> String? {
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func sample(from raw: PlanUsageHistoryFile.Sample) -> PlanUsageSample? {
        guard let usage = raw.u else { return nil }
        return PlanUsageSample(
            fiveHourFraction: usage.fh.map { $0 / 100 },
            sevenDayFraction: usage.sd.map { $0 / 100 },
            measuredAt: Date(timeIntervalSince1970: raw.t / 1_000)
        )
    }
}

private struct PlanUsageHistoryFile: Decodable {
    let samples: [Sample]

    struct Sample: Decodable {
        let t: Double
        let u: Usage?

        struct Usage: Decodable {
            let fh: Double?
            let sd: Double?
        }
    }
}
