import CodexSessionTransferCore
import Foundation
import Network

final class PeerBrowser: @unchecked Sendable {
    var onPeers: (([DiscoveredMac]) -> Void)?
    var onStatus: ((String?) -> Void)?

    private let localNames: Set<String>
    private let queue = DispatchQueue(label: "codex-session-transfer.browse")
    private let lock = NSLock()
    private var browsers: [NWBrowser] = []
    private var receiverEndpoints: [String: NWEndpoint] = [:]
    private var receiverNames = Set<String>()
    private var nearbyNames = Set<String>()
    private var receiverReady = false
    private var nearbyReady = false

    init(localNames: Set<String>) {
        self.localNames = localNames
    }

    func start() {
        startBrowser(type: "_codexsession._tcp", receivers: true)
        startBrowser(type: "_companion-link._tcp", receivers: false)
    }

    func endpoint(for name: String) -> NWEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        return receiverEndpoints[name]
    }

    private func startBrowser(type: String, receivers: Bool) {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            self?.note(state, receivers: receivers)
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.replace(results, receivers: receivers)
        }
        browser.start(queue: queue)
        lock.lock()
        browsers.append(browser)
        lock.unlock()
    }

    private func note(_ state: NWBrowser.State, receivers: Bool) {
        lock.lock()
        if receivers {
            receiverReady = state == .ready
        } else {
            nearbyReady = state == .ready
        }
        let blocked = !receiverReady && !nearbyReady
        lock.unlock()
        let message: String?
        if case .waiting = state, blocked {
            message = "Allow Local Network access in System Settings to detect other Macs."
        } else if case .failed = state, blocked {
            message = "Couldn't look for other Macs on the network."
        } else {
            message = nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(message)
        }
    }

    private func replace(_ results: Set<NWBrowser.Result>, receivers: Bool) {
        var names = Set<String>()
        var endpoints: [String: NWEndpoint] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { continue }
            names.insert(clean)
            endpoints[clean] = result.endpoint
        }

        lock.lock()
        if receivers {
            receiverNames = names
            receiverEndpoints = endpoints
        } else {
            nearbyNames = names
        }
        let macs = MacDiscovery.merge(
            localNames: localNames,
            receivers: receiverNames,
            nearby: nearbyNames
        )
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onPeers?(macs)
        }
    }
}
