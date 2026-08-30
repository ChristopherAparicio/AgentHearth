import AgentHearthApplication
import AgentHearthDomain
import Foundation

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
        var tail = (try? handle.readToEnd()) ?? Data()
        if tailStart > 0, let firstNewline = tail.firstIndex(of: 0x0A) {
            tail.removeSubrange(tail.startIndex...firstNewline)
        }

        var lines = completeLines(in: head)
        if tailStart > headLength {
            lines.append(contentsOf: completeLines(in: tail))
        } else if tail.count > head.count {
            lines = completeLines(in: tail)
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
