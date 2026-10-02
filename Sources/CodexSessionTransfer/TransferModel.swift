import CodexSessionTransferCore
import Foundation
import Network
import SwiftUI

enum MachineIdentity {
    static var serviceName: String {
        let raw = Foundation.Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Codex Transfer" }
        if trimmed.count <= 63 { return trimmed }
        return String(trimmed.prefix(63))
    }

    static var displayHost: String {
        let host = ProcessInfo.processInfo.hostName
        if host.contains(".") { return host }
        return host + ".local"
    }
}

@MainActor
final class TransferModel: ObservableObject {
    @Published var sessionID = ""
    @Published var preview: SessionPreview?
    @Published var peers: [PeerBrowser.Peer] = []
    @Published var selectedPeerID: String?
    @Published var manualHost = ""
    @Published var pairingCode = ""
    @Published var listening = true
    @Published var localCode = ""
    @Published var listenAddress = ""
    @Published var lastImported: String?
    @Published var status = ""
    @Published var isBusy = false

    private let browser: PeerBrowser
    private let server: TransferServer
    private var listenGeneration = 0

    init() {
        let name = MachineIdentity.serviceName
        browser = PeerBrowser(ignoredName: name)
        server = TransferServer(serviceName: name)
        browser.onPeers = { [weak self] peers in
            Task { @MainActor in
                self?.applyPeers(peers)
            }
        }
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.apply(event)
            }
        }
        browser.start()
        startListening()
    }

    func lookup() {
        let token = sessionID
        let homes = CodexHomes.current
        isBusy = true
        status = ""
        Task.detached {
            let result = Result { try SessionTransfer.lookup(token: token, homes: homes) }
            await MainActor.run {
                self.isBusy = false
                switch result {
                case .success(let preview):
                    self.preview = preview
                    self.status = ""
                case .failure(let error):
                    self.preview = nil
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func send() {
        guard !isBusy else { return }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !code.contains(where: { $0.isNewline }) else {
            status = "Enter the pairing code from the other Mac."
            return
        }
        let endpoint: NWEndpoint
        if let id = selectedPeerID {
            guard let resolved = browser.endpoint(for: id) else {
                status = "That Mac is no longer visible. Choose it again or enter host:port."
                return
            }
            endpoint = resolved
        } else if let parsed = HostPort.parse(manualHost), let port = NWEndpoint.Port(rawValue: parsed.port) {
            endpoint = .hostPort(host: NWEndpoint.Host(parsed.host), port: port)
        } else {
            status = "Choose a Mac, or enter the host and port shown on the other Mac."
            return
        }

        let token = sessionID
        let homes = CodexHomes.current
        isBusy = true
        status = "Packaging session…"
        Task.detached {
            do {
                let preview = try SessionTransfer.lookup(token: token, homes: homes)
                let zip = try SessionTransfer.package(preview)
                let size = ByteCountFormatter.string(fromByteCount: Int64(zip.count), countStyle: .file)
                await MainActor.run {
                    self.preview = preview
                    self.status = "Sending \(size)…"
                }
                let message = try await TransferClient.send(zip: zip, pairingCode: code, to: endpoint)
                await MainActor.run {
                    self.isBusy = false
                    self.status = message
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func setListening(_ on: Bool) {
        if on {
            startListening()
        } else {
            listenGeneration += 1
            server.stop()
            listening = false
            localCode = ""
            listenAddress = ""
        }
    }

    func regenerateCode() {
        guard listening else { return }
        localCode = server.regenerateCode()
        status = "Pairing code updated."
    }

    func togglePeer(_ id: String) {
        selectedPeerID = selectedPeerID == id ? nil : id
    }

    func sizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func startListening() {
        listenGeneration += 1
        let generation = listenGeneration
        listening = true
        server.start()
        if listenGeneration != generation {
            return
        }
    }

    private func applyPeers(_ peers: [PeerBrowser.Peer]) {
        self.peers = peers
        if let selectedPeerID, !peers.contains(where: { $0.id == selectedPeerID }) {
            self.selectedPeerID = nil
        }
    }

    private func apply(_ event: ServerEvent) {
        switch event {
        case .ready(let port):
            guard listening else { return }
            localCode = server.currentCode()
            listenAddress = "\(MachineIdentity.displayHost):\(port)"
        case .failed(let message):
            listening = false
            localCode = ""
            listenAddress = ""
            status = message
        case .imported(let message):
            lastImported = message
            status = message
        case .notice(let message):
            status = message
        }
    }
}
