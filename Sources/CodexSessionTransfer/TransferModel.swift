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
    @Published var peers: [DiscoveredMac] = []
    @Published var selectedPeerID: String?
    @Published var discoveryNote: String?
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
    private var selectionIsManual = false

    init() {
        let name = MachineIdentity.serviceName
        browser = PeerBrowser(localNames: MacDiscovery.localNames(
            serviceName: name,
            hostName: ProcessInfo.processInfo.hostName
        ))
        server = TransferServer(serviceName: name)
        browser.onPeers = { [weak self] peers in
            Task { @MainActor in
                self?.applyPeers(peers)
            }
        }
        browser.onStatus = { [weak self] note in
            Task { @MainActor in
                self?.discoveryNote = note
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
        guard let id = selectedPeerID else {
            status = peers.isEmpty ? "Still looking for other Macs." : "Choose the Mac to send to."
            return
        }
        let endpoint: NWEndpoint
        if let resolved = browser.endpoint(for: id) {
            endpoint = resolved
        } else if let peer = peers.first(where: { $0.id == id }), !peer.receiving {
            status = "\(peer.name) is on the network, but Codex Session Transfer isn't open there."
            return
        } else {
            status = "That Mac is no longer visible. Choose it again."
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

    func selectPeer(_ id: String) {
        selectionIsManual = true
        selectedPeerID = id
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

    private func applyPeers(_ peers: [DiscoveredMac]) {
        self.peers = peers
        if let selectedPeerID, !peers.contains(where: { $0.id == selectedPeerID }) {
            self.selectedPeerID = nil
            selectionIsManual = false
        }
        guard !selectionIsManual else { return }
        selectedPeerID = MacDiscovery.automaticSelection(in: peers)?.id
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
