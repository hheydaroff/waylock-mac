import Foundation

/// One advertisement, as the radio saw it.
struct Sighting: Equatable {
    var name: String
    var address: UUID
    var rssi: Int
}

struct Channel: Equatable {
    var name: String
    var lastSeen: Date
    var lastRSSI: Int
    var packets: Int
}

/// Any advertiser that announced a name, whether or not it is the key.
struct NamedDevice: Equatable {
    var name: String
    var address: UUID
    var firstSeen: Date
    var lastSeen: Date
    var rssi: Int
    var packets: Int

    /// Packets per minute since first sighting; `nil` for the first 30 s. Drives
    /// the picker's warning: a device heard every 11 s cannot support a tight
    /// window, and finding that out by walking away and back is a bad way to learn.
    func perMinute() -> Double? {
        let span = lastSeen.timeIntervalSince(firstSeen)
        guard span >= 30 else { return nil }
        return Double(packets) / span * 60
    }
}

/// Everything the app knows about the key device, built from sightings alone.
///
/// No radio, no clock of its own, no persistence: it is handed a sighting and a
/// time, and reports what changed. That is what makes an impostor testable —
/// staging one for real is not possible.
struct Tracker {
    /// Something worth telling the user or the log. Returned rather than written,
    /// so the decision stays testable and the wording stays in one place.
    enum Event: Equatable {
        case learnedAddress(address: String, first: Bool)
        case ignoredImpostor(name: String, address: String)
        case newChannel(name: String, address: String)
    }

    static let channelLifetime: TimeInterval = 600
    static let namedLifetime: TimeInterval = 120
    private static let matchLifetime: TimeInterval = 60

    private(set) var channels: [UUID: Channel] = [:]
    private(set) var named: [String: NamedDevice] = [:]
    private(set) var arrivals = Arrivals()
    private(set) var identity: KeyIdentity
    /// Same-named addresses heard recently, ours or not: the rival evidence.
    private var heard: [UUID: Date] = [:]

    init(keyName: String, known: [String] = []) {
        identity = KeyIdentity(keyName: keyName, known: known)
    }

    var knownAddresses: [String] { identity.known }

    mutating func sight(_ sighting: Sighting, now: Date) -> [Event] {
        guard !sighting.name.isEmpty else { return [] }
        remember(sighting, now: now)          // the menu offers every named advertiser

        heard[sighting.address] = now
        heard = heard.filter { now.timeIntervalSince($0.value) < Self.matchLifetime }
        let rival = heard.contains {
            $0.key != sighting.address && now.timeIntervalSince($0.value) < KeyIdentity.rivalWindow
        }

        let address = sighting.address.uuidString
        var events: [Event] = []
        switch identity.classify(name: sighting.name, address: address, rival: rival) {
        case .notKey:
            return []
        case .impostor:
            return [.ignoredImpostor(name: sighting.name, address: address)]
        case .firstAddress:
            events.append(.learnedAddress(address: address, first: true))
        case .rotation:
            events.append(.learnedAddress(address: address, first: false))
        case .ours:
            break
        }

        arrivals.record(now: now)
        if var channel = channels[sighting.address] {
            channel.lastSeen = now
            channel.lastRSSI = sighting.rssi
            channel.packets += 1
            channel.name = sighting.name
            channels[sighting.address] = channel
        } else {
            channels[sighting.address] = Channel(name: sighting.name, lastSeen: now,
                                                 lastRSSI: sighting.rssi, packets: 1)
            events.append(.newChannel(name: sighting.name, address: address))
        }
        return events
    }

    private mutating func remember(_ sighting: Sighting, now: Date) {
        if var device = named[sighting.name] {
            device.lastSeen = now
            device.rssi = sighting.rssi
            device.address = sighting.address
            device.packets += 1
            named[sighting.name] = device
        } else {
            named[sighting.name] = NamedDevice(name: sighting.name, address: sighting.address,
                                               firstSeen: now, lastSeen: now,
                                               rssi: sighting.rssi, packets: 1)
        }
    }

    mutating func prune(now: Date) {
        channels = channels.filter { now.timeIntervalSince($0.value.lastSeen) < Self.channelLifetime }
        named = named.filter { now.timeIntervalSince($0.value.lastSeen) < Self.namedLifetime }
    }

    /// A new key device invalidates every channel; otherwise the old device keeps
    /// the Mac "present" and it never locks again.
    mutating func setKey(_ name: String) {
        identity = KeyIdentity(keyName: name)
        channels.removeAll()
        heard.removeAll()
        arrivals.reset()
    }

    /// Throw away the measured gaps but keep the channels: the key is still here,
    /// we just no longer trust the history as evidence for a window.
    mutating func restartLearning() {
        arrivals.reset()
    }

    /// Seconds since the most recent packet from ANY channel; `nil` means the key
    /// has never been seen.
    func absent(now: Date) -> Double? {
        guard let newest = channels.values.map(\.lastSeen).max() else { return nil }
        return now.timeIntervalSince(newest)
    }

    func bestChannel() -> Channel? {
        channels.values.max { $0.lastSeen < $1.lastSeen }
    }
}