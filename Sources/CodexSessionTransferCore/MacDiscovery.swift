import Foundation

public struct DiscoveredMac: Equatable, Identifiable, Sendable {
    public var name: String
    public var receiving: Bool

    public var id: String { name }

    public init(name: String, receiving: Bool) {
        self.name = name
        self.receiving = receiving
    }
}

public enum MacDiscovery {
    public static func localNames(serviceName: String, hostName: String) -> Set<String> {
        var names = Set([serviceName, hostName])
        if let dot = hostName.firstIndex(of: ".") {
            names.insert(String(hostName[..<dot]))
        }
        names.remove("")
        return names
    }

    /// Nearby names come from machines advertising on the LAN. Receivers are Macs running this app.
    public static func merge(localNames: Set<String>, receivers: Set<String>, nearby: Set<String>) -> [DiscoveredMac] {
        let local = Set(localNames.map(normalize))
        var macs: [String: DiscoveredMac] = [:]

        for name in receivers {
            guard let clean = accepted(name, local: local, allowPhones: true) else { continue }
            macs[normalize(clean)] = DiscoveredMac(name: clean, receiving: true)
        }
        for name in nearby {
            guard let clean = accepted(name, local: local, allowPhones: false) else { continue }
            let key = normalize(clean)
            if macs[key] == nil {
                macs[key] = DiscoveredMac(name: clean, receiving: false)
            }
        }

        return macs.values.sorted { lhs, rhs in
            if lhs.receiving != rhs.receiving {
                return lhs.receiving
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Picks the only Mac that can receive a session. If none are receiving, picks the only other Mac.
    public static func automaticSelection(in macs: [DiscoveredMac]) -> DiscoveredMac? {
        let receivers = macs.filter(\.receiving)
        if receivers.count == 1 {
            return receivers[0]
        }
        if macs.count == 1 {
            return macs[0]
        }
        return nil
    }

    private static let phoneFragments = ["ipad", "iphone", "ipod", "apple watch", "apple tv", "appletv", "airpods", "homepod"]

    private static func accepted(_ name: String, local: Set<String>, allowPhones: Bool) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || local.contains(normalize(clean)) {
            return nil
        }
        if !allowPhones {
            let folded = normalize(clean)
            if phoneFragments.contains(where: { folded.contains($0) }) {
                return nil
            }
        }
        return clean
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
