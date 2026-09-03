import AgentHearthApplication
import AgentHearthDomain
import Darwin
import Foundation

/// One parsed HTTP/1.1 request read from a client socket.
struct LocalHTTPRequest {
    let method: String
    let path: String
    /// Header names are lowercased for case-insensitive lookup.
    let headers: [String: String]
    let body: Data
}

/// Reads a single HTTP/1.1 request (request line, headers, `Content-Length`
/// body) from a blocking socket. The caller is responsible for setting a
/// receive timeout on the socket; a stalling or under-sending peer is bounded
/// by that timeout, and any request larger than `maximumRequestSize` is
/// rejected outright.
struct LocalHTTPRequestReader {
    let maximumRequestSize = 1_048_576

    /// The declared body length of a request, or the reason none can be trusted.
    private enum ContentLength: Equatable {
        case absent
        case declared(Int)
        /// Non-numeric, negative, or larger than `maximumRequestSize`. Such a
        /// request is rejected before any body byte is read: a negative value
        /// used to build an inverted `Range` and trap the whole process.
        case invalid
    }

    func readRequest(from socket: Int32) -> LocalHTTPRequest? {
        let headerDelimiter = Data("\r\n\r\n".utf8)
        var data = Data()
        var contentLength: Int?
        var headerEnd: Data.Index?

        while data.count <= maximumRequestSize {
            var buffer = [UInt8](repeating: 0, count: 8_192)
            let bytesRead = Darwin.recv(socket, &buffer, buffer.count, 0)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)

            if headerEnd == nil, let delimiterRange = data.range(of: headerDelimiter) {
                headerEnd = delimiterRange.upperBound
                let headerData = data[..<delimiterRange.lowerBound]
                guard let header = String(data: headerData, encoding: .utf8) else { return nil }
                switch parseContentLength(from: header) {
                case .absent: contentLength = 0
                case let .declared(length): contentLength = length
                case .invalid: return nil
                }
            }

            if let headerEnd, let contentLength, data.count - headerEnd >= contentLength {
                break
            }
        }

        guard data.count <= maximumRequestSize,
              let delimiterRange = data.range(of: headerDelimiter),
              let header = String(data: data[..<delimiterRange.lowerBound], encoding: .utf8)
        else {
            return nil
        }

        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }

        let expectedBodyLength: Int
        switch parseContentLength(from: header) {
        case .absent: expectedBodyLength = 0
        case let .declared(length): expectedBodyLength = length
        case .invalid: return nil
        }
        let bodyStart = delimiterRange.upperBound
        guard data.count - bodyStart >= expectedBodyLength else { return nil }
        let bodyEnd = bodyStart + expectedBodyLength

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        return LocalHTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: data.subdata(in: bodyStart..<bodyEnd)
        )
    }

    private func parseContentLength(from header: String) -> ContentLength {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("Content-Length") == .orderedSame
            else {
                continue
            }
            guard let length = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  (0...maximumRequestSize).contains(length)
            else {
                return .invalid
            }
            return .declared(length)
        }
        return .absent
    }
}
