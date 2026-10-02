import Foundation

public enum HTTPCodecError: Error, Equatable, Sendable {
    case malformed
    case tooLarge
}

public struct HTTPMessage: Equatable, Sendable {
    public var startLine: String
    public var headers: [String: String]
    public var body: Data

    public init(startLine: String, headers: [String: String], body: Data) {
        self.startLine = startLine
        self.headers = headers
        self.body = body
    }
}

public enum HTTPCodec {
    private static let maxHeaderBytes = 64 * 1024

    public static func encode(startLine: String, headers: [String: String], body: Data) -> Data {
        var text = startLine + "\r\n"
        for key in headers.keys.sorted() {
            text += "\(key): \(headers[key] ?? "")\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    /// Returns nil when more bytes are required. Throws once the headers are complete and invalid.
    public static func decode(_ data: Data, maxBodyBytes: Int) throws -> HTTPMessage? {
        let separator = Data([13, 10, 13, 10])
        guard let range = data.range(of: separator) else {
            if data.count > maxHeaderBytes {
                throw HTTPCodecError.malformed
            }
            return nil
        }
        let headerData = data.subdata(in: data.startIndex..<range.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPCodecError.malformed
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let startLine = lines.first, !startLine.isEmpty else {
            throw HTTPCodecError.malformed
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPCodecError.malformed
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name.isEmpty || headers[name] != nil {
                throw HTTPCodecError.malformed
            }
            headers[name] = value
        }
        guard let lengthText = headers["content-length"], let length = Int(lengthText), length >= 0 else {
            throw HTTPCodecError.malformed
        }
        if length > maxBodyBytes {
            throw HTTPCodecError.tooLarge
        }
        let headerEnd = data.distance(from: data.startIndex, to: range.upperBound)
        if data.count < headerEnd + length {
            return nil
        }
        let bodyStart = data.index(data.startIndex, offsetBy: headerEnd)
        let bodyEnd = data.index(bodyStart, offsetBy: length)
        return HTTPMessage(startLine: startLine, headers: headers, body: data.subdata(in: bodyStart..<bodyEnd))
    }
}
