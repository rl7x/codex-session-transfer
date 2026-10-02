import Foundation

public enum HostPort {
    public static func parse(_ raw: String) -> (host: String, port: UInt16)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let host: String
        let portText: String
        if trimmed.hasPrefix("[") {
            guard let end = trimmed.firstIndex(of: "]") else { return nil }
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            let rest = trimmed[trimmed.index(after: end)...]
            guard rest.first == ":" else { return nil }
            portText = String(rest.dropFirst())
        } else {
            guard let colon = trimmed.lastIndex(of: ":"), colon != trimmed.startIndex else { return nil }
            host = String(trimmed[..<colon])
            portText = String(trimmed[trimmed.index(after: colon)...])
        }
        guard !host.isEmpty, let port = UInt16(portText), port > 0 else { return nil }
        return (host, port)
    }
}
