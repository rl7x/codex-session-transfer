import Foundation

public enum TransferError: Error, Equatable, LocalizedError, Sendable {
    case emptyToken
    case databaseMissing(String)
    case sessionNotFound
    case ambiguousName(String)
    case rolloutMissing(String)
    case rolloutOutsideHome
    case rolloutDiffers(String)
    case alreadyExists(String)
    case schemaMismatch(String)
    case invalidPackage(String)
    case sqlite(String)
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "Enter a session id."
        case .databaseMissing(let path):
            return "Codex database is missing: \(path)"
        case .sessionNotFound:
            return "No session with that id was found in ~/.codex-work or ~/.codex."
        case .ambiguousName(let name):
            return "More than one session is named \(name). Paste the session id instead."
        case .rolloutMissing(let path):
            return "Rollout file is missing: \(path)"
        case .rolloutOutsideHome:
            return "The rollout file is outside the Codex home, so it was not packaged."
        case .rolloutDiffers(let path):
            return "A different rollout file already exists at \(path)."
        case .alreadyExists(let id):
            return "Session \(id) is already in ~/.codex."
        case .schemaMismatch(let table):
            return "Codex database schema differs for \(table). Update Codex on both Macs so this table matches."
        case .invalidPackage(let reason):
            return reason
        case .sqlite(let message):
            return message
        case .remote(let message):
            return message
        }
    }
}
