import CodexSessionTransferCore
import Foundation
import Network

enum ServerEvent: Sendable {
    case ready(UInt16)
    case failed(String)
    case imported(String)
    case notice(String)
}

final class TransferServer: @unchecked Sendable {
    var onEvent: ((ServerEvent) -> Void)?

    private let serviceName: String
    private let queue = DispatchQueue(label: "codex-session-transfer.listener")
    private let importQueue = DispatchQueue(label: "codex-session-transfer.import")
    private let codeLock = NSLock()
    private var listener: NWListener?
    private var startToken = UUID()
    private var pairingCode = ""

    init(serviceName: String) {
        self.serviceName = serviceName
    }

    func start() {
        stop()
        let token = UUID()
        startToken = token
        let code = Self.makeCode()
        codeLock.lock()
        pairingCode = code
        codeLock.unlock()
        do {
            let listener = try makeListener()
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.startToken == token else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port?.rawValue, port != 0 else {
                        self.emit(.failed("Could not open a port for incoming sessions."))
                        return
                    }
                    self.emit(.ready(port))
                case .failed(let error):
                    self.emit(.failed("Could not listen for sessions (\(error.localizedDescription))."))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.startToken == token else {
                    connection.cancel()
                    return
                }
                self.handle(connection)
            }
            listener.start(queue: queue)
        } catch {
            emit(.failed("Could not listen for sessions (\(error.localizedDescription))."))
        }
    }

    func stop() {
        startToken = UUID()
        listener?.cancel()
        listener = nil
    }

    func currentCode() -> String {
        codeLock.lock()
        defer { codeLock.unlock() }
        return pairingCode
    }

    func regenerateCode() -> String {
        let code = Self.makeCode()
        codeLock.lock()
        pairingCode = code
        codeLock.unlock()
        return code
    }

    private func makeListener() throws -> NWListener {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        listener.service = NWListener.Service(name: serviceName, type: "_codexsession._tcp")
        return listener
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: importQueue)
        read(connection: connection, buffer: Data())
    }

    private func read(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            do {
                if let message = try HTTPCodec.decode(buffer, maxBodyBytes: SessionTransfer.maxPackageBytes) {
                    self.finish(connection: connection, message: message)
                    return
                }
            } catch let error as HTTPCodecError {
                switch error {
                case .tooLarge:
                    self.respond(connection: connection, status: 413, message: "That session is larger than 1 GB.", threadID: nil)
                case .malformed:
                    self.respond(connection: connection, status: 400, message: "Could not read the upload.", threadID: nil)
                }
                return
            } catch {
                self.respond(connection: connection, status: 400, message: "Could not read the upload.", threadID: nil)
                return
            }
            if isComplete {
                self.respond(connection: connection, status: 400, message: "The upload ended early.", threadID: nil)
                return
            }
            self.read(connection: connection, buffer: buffer)
        }
    }

    private func finish(connection: NWConnection, message: HTTPMessage) {
        let parts = message.startLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST", parts[1] == "/v1/sessions" else {
            respond(connection: connection, status: 404, message: "Not found.", threadID: nil)
            return
        }
        let provided = message.headers["x-pairing-code"] ?? ""
        guard secureEqual(provided, currentCode()) else {
            respond(connection: connection, status: 401, message: "Pairing code doesn't match.", threadID: nil)
            emit(.notice("Rejected a transfer because the pairing code did not match."))
            return
        }
        do {
            let result = try SessionTransfer.importPackage(message.body, into: CodexHomes.current.personal)
            let text = "Imported \"\(result.title)\" (\(result.threadID)) into ~/.codex."
            respond(connection: connection, status: 200, message: text, threadID: result.threadID)
            emit(.imported(text))
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            respond(connection: connection, status: statusCode(error), message: text, threadID: nil)
            emit(.notice(text))
        }
    }

    private func respond(connection: NWConnection, status: Int, message: String, threadID: String?) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        let ack = TransferAck(ok: status == 200, message: message, threadId: threadID)
        let body = (try? JSONEncoder().encode(ack)) ?? Data("{\"ok\":false,\"message\":\"Error\"}".utf8)
        let data = HTTPCodec.encode(
            startLine: "HTTP/1.1 \(status) \(reason)",
            headers: [
                "Content-Type": "application/json",
                "Content-Length": String(body.count),
                "Connection": "close"
            ],
            body: body
        )
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func statusCode(_ error: Error) -> Int {
        guard let error = error as? TransferError else { return 500 }
        switch error {
        case .alreadyExists, .rolloutDiffers, .schemaMismatch:
            return 409
        case .invalidPackage, .rolloutOutsideHome, .rolloutMissing:
            return 400
        default:
            return 500
        }
    }

    private func emit(_ event: ServerEvent) {
        onEvent?(event)
    }

    private func secureEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        if left.count != right.count { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private static func makeCode() -> String {
        String(format: "%06d", Int.random(in: 0...999999))
    }
}
