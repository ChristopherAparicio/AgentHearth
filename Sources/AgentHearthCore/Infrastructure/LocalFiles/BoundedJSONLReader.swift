import AgentHearthApplication
import AgentHearthDomain
import Foundation

/// Decodes a JSONL file while reading at most `headByteLimit + tailByteLimit`
/// bytes: the beginning (where providers write session metadata) and the end
/// (where the latest turns live). Everything in between is skipped for large
/// files; small files are read whole.
enum BoundedJSONLReader {
    static func decode<Record: Decodable>(
        _ type: Record.Type,
        from url: URL,
        headByteLimit: Int = 64 * 1_024,
        tailByteLimit: Int = 512 * 1_024
    ) -> [Record] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return [] }

        let headLength = min(UInt64(headByteLimit), size)
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: Int(headLength))) ?? Data()

        let tailStart = size > UInt64(tailByteLimit) ? size - UInt64(tailByteLimit) : 0
        try? handle.seek(toOffset: tailStart)
        let tail = (try? handle.readToEnd()) ?? Data()

        let lines: [Data]
        if tailStart > headLength {
            // A real gap between the two windows: the tail starts mid-line, so
            // drop its leading fragment rather than mis-decode it.
            var trimmedTail = tail
            if let firstNewline = trimmedTail.firstIndex(of: 0x0A) {
                trimmedTail.removeSubrange(trimmedTail.startIndex...firstNewline)
            }
            lines = completeLines(in: head) + completeLines(in: trimmedTail)
        } else {
            // The windows overlap (or the tail is the whole file): splice them
            // into the complete file instead of discarding the head. Dropping
            // the head here used to lose the first line — Codex's
            // `session_meta` — for files between the two limits.
            let overlap = Int(headLength - tailStart)
            lines = completeLines(in: head + tail.dropFirst(min(overlap, tail.count)))
        }

        let decoder = JSONDecoder()
        return lines.compactMap { try? decoder.decode(type, from: $0) }
    }

    private static func completeLines(in data: Data) -> [Data] {
        Array(data)
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { Data($0) }
    }
}
