import CodexSessionTransferCore
import Foundation
import Network

private final class SendState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var ready = false

    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    func markReady() {
        lock.lock()
        ready = true
        lock.unlock()
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }
}

enum TransferClient {
    static func send(zip: Data, pairingCode: String, to endpoint: NWEndpoint) async throws -> String {
        if zip.count > SessionTransfer.maxPackageBytes {
            throw TransferError.invalidPackage("This session is larger than 1 GB.")
        }
        let payload = HTTPCodec.encode(
            startLine: "POST /v1/sessions HTTP/1.1",
            headers: [
                "Host": "codex-session-transfer",
                "Content-Type": "application/zip",
                "Content-Length": String(zip.count),
                "X-Pairing-Code": pairingCode,
                "Connection": "close"
            ],
            body: zip
        )
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let queue = DispatchQueue(label: "codex-session-transfer.client")
            let progress = SendState()

            let finish: (Result<String, Error>) -> Void = { result in
                guard progress.markFinished() else { return }
                connection.cancel()
                switch result {
                case .success(let message):
                    continuation.resume(returning: message)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            func read(buffer: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                    if let error {
                        finish(.failure(TransferError.remote("Could not reach that Mac (\(error.localizedDescription)).")))
                        return
                    }
                    var buffer = buffer
                    if let data {
                        buffer.append(data)
                    }
                    do {
                        if let message = try HTTPCodec.decode(buffer, maxBodyBytes: 1024 * 1024) {
                            finish(.success(try interpret(message)))
                            return
                        }
                    } catch let error as TransferError {
                        finish(.failure(error))
                        return
                    } catch {
                        finish(.failure(TransferError.remote("The other Mac sent an unexpected response.")))
                        return
                    }
                    if isComplete {
                        finish(.failure(TransferError.remote("The connection to the other Mac closed.")))
                        return
                    }
                    read(buffer: buffer)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    progress.markReady()
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(TransferError.remote("Could not reach that Mac (\(error.localizedDescription)).")))
                            return
                        }
                        read(buffer: Data())
                    })
                case .failed(let error):
                    finish(.failure(TransferError.remote("Could not reach that Mac (\(error.localizedDescription)).")))
                case .cancelled:
                    if !progress.isReady {
                        finish(.failure(TransferError.remote("The connection to the other Mac closed.")))
                    }
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + 180) {
                finish(.failure(TransferError.remote("Timed out while sending the session.")))
            }
            connection.start(queue: queue)
        }
    }

    private static func interpret(_ message: HTTPMessage) throws -> String {
        let parts = message.startLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw TransferError.remote("The other Mac sent an unexpected response.")
        }
        let ack = try? JSONDecoder().decode(TransferAck.self, from: message.body)
        if status == 200 {
            return ack?.message ?? "Imported the session into ~/.codex."
        }
        throw TransferError.remote(ack?.message ?? "The other Mac rejected the session.")
    }
}
