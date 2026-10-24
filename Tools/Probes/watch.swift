// watch — per-packet BLE trace for one device, with gap detection.
//
// Produced the per-packet RSSI trace used to test the bonded iPhone: does a
// phone paired to the Mac keep emitting, or does macOS replay it from a cache so
// that its absence is never seen. The bonded-phone question is still open; see
// FINDINGS.md, "Phones and watches — visible, but anonymous" and "Open
// questions". Complements `scan`: scan answers "what is out there", watch
// answers "is this one device still emitting".
//
//   swift run waylock-watch iPhone 120
//
// Arguments: a case-insensitive name fragment, then the duration in seconds
// (default 60). Prints one line per packet: elapsed seconds, RSSI, payload. Gaps
// over 2 s are called out explicitly, because a gap that a cache hides is exactly
// the thing that makes proximity detection silently fail.

import Foundation
import CoreBluetooth

// The trace state lives in one main-actor object. The manager is created with
// queue: nil, so CoreBluetooth delivers its callbacks on the main queue; the
// delegate methods are nonisolated only because the protocol is, and each one
// steps back onto the main actor with assumeIsolated.
@MainActor
final class Trace {
    let needle: String
    let duration: Double
    let t0 = Date()
    var last: Date?
    var count = 0

    init(needle: String, duration: Double) {
        self.needle = needle
        self.duration = duration
    }

    func ts() -> String {
        String(format: "%7.2f", Date().timeIntervalSince(t0))
    }

    func packet(id: UUID, name n: String, mfr: Data?, rssi r: Int) {
        guard !needle.isEmpty, n.lowercased().contains(needle) else { return }

        count += 1
        let now = Date()
        var gap = ""
        if let l = last {
            let g = now.timeIntervalSince(l)
            if g > 2 { gap = String(format: "   <-- GAP %.1fs", g) }
        }
        last = now

        var co = "-"
        if let m = mfr, m.count >= 2 {
            co = String(format: "%04x:", UInt16(m[0]) | (UInt16(m[1]) << 8))
                + m.dropFirst(2).prefix(3).map { String(format: "%02x", $0) }.joined()
        }
        print("\(ts())s  rssi=\(r)  \(String(id.uuidString.prefix(8)))  co=\(co)\(gap)")
        fflush(stdout)
    }
}

@MainActor
final class D: NSObject, CBCentralManagerDelegate {
    let trace: Trace
    var cm: CBCentralManager!

    init(trace: Trace) {
        self.trace = trace
        super.init()
        cm = CBCentralManager(delegate: self, queue: nil)
    }

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        // The manager that calls back is our own `cm`, so use that inside the hop
        // and carry only the Sendable state across.
        let state = c.state
        // Sound: queue: nil delivers delegate callbacks on the main thread.
        MainActor.assumeIsolated {
            guard state == .poweredOn else { return }
            cm.scanForPeripherals(withServices: nil,
                                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            print("scanning for '\(trace.needle)' for \(Int(trace.duration))s")
            fflush(stdout)
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData d: [String: Any], rssi R: NSNumber) {
        let r = R.intValue
        guard r != 127, r != 0 else { return }
        // Only Sendable values (UUID, String, Data) cross the boundary; the
        // peripheral and the advertisement dictionary stay on this side.
        let id = p.identifier
        let n = p.name ?? (d[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let mfr = d[CBAdvertisementDataManufacturerDataKey] as? Data
        // Sound: queue: nil delivers delegate callbacks on the main thread.
        MainActor.assumeIsolated {
            trace.packet(id: id, name: n, mfr: mfr, rssi: r)
        }
    }
}

let needle = (CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "").lowercased()
let duration = Double(CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 60) : 60)
let trace = Trace(needle: needle, duration: duration)
let d = D(trace: trace)
withExtendedLifetime(d) {
    RunLoop.main.run(until: trace.t0.addingTimeInterval(duration))
}
print("done: \(trace.count) packets in \(Int(duration))s")
