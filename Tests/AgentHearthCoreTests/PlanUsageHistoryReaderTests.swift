import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class PlanUsageHistoryReaderTests: XCTestCase {
    private func write(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "AgentHearth-PlanUsage-\(UUID().uuidString).json")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsNewestSampleFromTailOfLargeFile() throws {
        // Thousands of samples so the newest is far past any bounded tail window;
        // the tail parser must still isolate the last sample.
        var samples: [String] = []
        for i in 0..<5_000 {
            samples.append("{\"t\":\(1_000_000 + i * 1000),\"org\":\"o\",\"u\":{\"fh\":\(i % 100),\"sd\":\(i % 50)}}")
        }
        let url = try write("{\"version\":2,\"samples\":[" + samples.joined(separator: ",") + "]}")

        let sample = try XCTUnwrap(PlanUsageHistoryReader.latestSample(at: url))
        // Last sample: i = 4999 -> fh = 99, sd = 49.
        XCTAssertEqual(try XCTUnwrap(sample.fiveHourFraction), 0.99, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(sample.sevenDayFraction), 0.49, accuracy: 0.0001)
        XCTAssertEqual(sample.measuredAt, Date(timeIntervalSince1970: (1_000_000 + 4_999 * 1000) / 1_000))
    }

    func testSingleSampleFile() throws {
        let url = try write("{\"version\":2,\"samples\":[{\"t\":1900000,\"org\":\"o\",\"u\":{\"fh\":18,\"sd\":49}}]}")
        let sample = try XCTUnwrap(PlanUsageHistoryReader.latestSample(at: url))
        XCTAssertEqual(try XCTUnwrap(sample.fiveHourFraction), 0.18, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(sample.sevenDayFraction), 0.49, accuracy: 0.0001)
    }

    func testEmptySamplesReturnsNil() throws {
        let url = try write("{\"version\":2,\"samples\":[]}")
        XCTAssertNil(PlanUsageHistoryReader.latestSample(at: url))
    }

    func testMalformedFileReturnsNil() throws {
        let url = try write("{ not json ")
        XCTAssertNil(PlanUsageHistoryReader.latestSample(at: url))
    }
}
