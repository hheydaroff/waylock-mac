import Foundation

/// Which advertiser addresses belong to your key device.
///
/// A name alone fails open: a colleague with the same model in range counts as
/// present and keeps this Mac unlocked after you leave. So a name must also carry
/// an address this Mac has learned — and an unfamiliar address is adopted only
/// when no *other* same-named device is in range, which is what a genuine address
/// rotation looks like and what an impostor never looks like.
struct KeyIdentity: Equatable {
    static let maxKnown = 8
    /// How recent a rival sighting has to be to count as "in range".
    static let rivalWindow: TimeInterval = 10

    var keyName: String
    private(set) var known: [String]

    init(keyName: String, known: [String] = []) {
        self.keyName = keyName
        self.known = known
    }

    enum Verdict: Equatable {
        /// The name is not ours.
        case notKey
        /// A known address.
        case ours
        /// Nothing learned yet: adopt the first address seen.
        case firstAddress
        /// Unknown address, but nothing else same-named is in range.
        case rotation
        /// Unknown address with a same-named competitor present.
        case impostor
    }

    /// `rival` means another same-named address was heard within `rivalWindow`.
    mutating func classify(name: String, address: String, rival: Bool) -> Verdict {
        guard name.localizedCaseInsensitiveContains(keyName) else { return .notKey }
        if known.isEmpty {
            adopt(address)
            return .firstAddress
        }
        if known.contains(address) { return .ours }
        if rival { return .impostor }
        adopt(address)
        return .rotation
    }

    private mutating func adopt(_ address: String) {
        known.append(address)
        if known.count > Self.maxKnown { known.removeFirst(known.count - Self.maxKnown) }
    }
}

extension KeyIdentity.Verdict: CustomStringConvertible {
    var description: String {
        switch self {
        case .notKey: return "notKey"
        case .ours: return "ours"
        case .firstAddress: return "firstAddress"
        case .rotation: return "rotation"
        case .impostor: return "impostor"
        }
    }
}