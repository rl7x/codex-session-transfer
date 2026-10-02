import Foundation
import Network

final class PeerBrowser: @unchecked Sendable {
    struct Peer: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
    }

    var onPeers: (([Peer]) -> Void)?

    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "codex-session-transfer.browse")
    private let lock = NSLock()
    private var endpoints: [String: NWEndpoint] = [:]
    private let ignoredName: String

    init(ignoredName: String) {
        self.ignoredName = ignoredName
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        browser = NWBrowser(for: .bonjour(type: "_codexsession._tcp", domain: nil), using: parameters)
    }

    func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.update(results)
        }
        browser.start(queue: queue)
    }

    func endpoint(for id: String) -> NWEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        return endpoints[id]
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var peers: [Peer] = []
        var map: [String: NWEndpoint] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            if name == ignoredName { continue }
            map[name] = result.endpoint
            peers.append(Peer(id: name, name: name))
        }
        peers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lock.lock()
        endpoints = map
        lock.unlock()
        let snapshot = peers
        DispatchQueue.main.async { [weak self] in
            self?.onPeers?(snapshot)
        }
    }
}
