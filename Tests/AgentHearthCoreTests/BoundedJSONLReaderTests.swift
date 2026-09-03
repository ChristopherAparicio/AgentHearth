import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

private struct Row: Decodable, Equatable {
    let n: Int
}

final class BoundedJSONLReaderTests: XCTestCase {
    private func write(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "AgentHearth-JSONL-\(UUID().uuidString).jsonl")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsAllLinesForSmallFile() throws {
        let url = try write("{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n")
        let rows = BoundedJSONLReader.decode(Row.self, from: url)
        XCTAssertEqual(rows, [Row(n: 1), Row(n: 2), Row(n: 3)])
    }

    func testSkipsTrailingPartialLineIsHandled() throws {
        // No trailing newline: the last line is still complete JSON here.
        let url = try write("{\"n\":1}\n{\"n\":2}")
        let rows = BoundedJSONLReader.decode(Row.self, from: url)
        XCTAssertEqual(rows, [Row(n: 1), Row(n: 2)])
    }

    func testDropsPartialLineAfterTailCut() throws {
        // A big first line then many small ones. With a tiny tail limit the tail
        // window starts mid-line; that partial leading fragment must be dropped,
        // not mis-decoded.
        var text = "{\"n\":0,\"pad\":\"" + String(repeating: "x", count: 2_000) + "\"}\n"
        for i in 1...50 { text += "{\"n\":\(i)}\n" }
        let url = try write(text)
        let rows = BoundedJSONLReader.decode(Row.self, from: url, headByteLimit: 16, tailByteLimit: 64)
        // Head window (16 B) yields no complete line; tail window yields the last
        // few complete lines, none garbled.
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.last, Row(n: 50))
        XCTAssertTrue(rows.allSatisfy { $0.n >= 1 && $0.n <= 50 })
    }

    /// Regression: when the file is larger than the tail limit but smaller than
    /// head + tail, the two windows overlap and the reader used the tail alone,
    /// dropping the first line (Codex's `session_meta`, hence the session ID).
    func testKeepsFirstLineWhenHeadAndTailWindowsOverlap() throws {
        let headLimit = 64
        let tailLimit = 512
        // Each line is 9-10 bytes; sizes probe below, inside, and above the
        // overlap band (tailLimit, tailLimit + headLimit].
        for lineCount in [40, 55, 56, 60, 70, 200] {
            var text = "{\"n\":0}\n"
            for i in 1..<lineCount { text += String(format: "{\"n\":%3d}\n", i) }
            let url = try write(text)
            let rows = BoundedJSONLReader.decode(Row.self, from: url, headByteLimit: headLimit, tailByteLimit: tailLimit)
            XCTAssertEqual(rows.first, Row(n: 0), "first line lost for \(text.utf8.count) bytes")
            XCTAssertEqual(rows.last, Row(n: lineCount - 1))
            if text.utf8.count <= headLimit + tailLimit {
                XCTAssertEqual(rows.count, lineCount, "small file must be read whole (\(text.utf8.count) bytes)")
            }
        }
    }

    func testEmptyFileReturnsNoRows() throws {
        let url = try write("")
        XCTAssertTrue(BoundedJSONLReader.decode(Row.self, from: url).isEmpty)
    }

    func testMissingFileReturnsNoRows() {
        let url = FileManager.default.temporaryDirectory.appending(path: "does-not-exist-\(UUID().uuidString).jsonl")
        XCTAssertTrue(BoundedJSONLReader.decode(Row.self, from: url).isEmpty)
    }
}
