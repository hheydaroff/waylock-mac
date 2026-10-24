// watch — per-packet BLE trace for one device, with gap detection.
//
// Complements `scan`: scan answers "what is out there", watch answers "is this
// one device still emitting, and what does its signal do when it moves".
//
//   swiftc -O watch.swift -o /tmp/watch && /tmp/watch iPhone 120
//
// Prints one line per packet: elapsed seconds, RSSI, payload. Gaps over 2 s are
// called out explicitly, because a gap that a cache hides is exactly the thing
// that makes proximity detection silently fail.

import Foundation
import CoreBluetooth

let needle = (CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "").lowercased()
let duration = Double(CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 60) : 60)
let t0 = Date()
var last: Date?
var count = 0

func ts() -> String {
    String(format: "%7.2f", Date().timeIntervalSince(t0))
}

final class D: NSObject, CBCentralManagerDelegate {
    var cm: CBCentralManager!
    override init() { super.init(); cm = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: nil,
                            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        print("scanning for '\(needle)' for \(Int(duration))s")
        fflush(stdout)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData d: [String: Any], rssi R: NSNumber) {
        let r = R.intValue
        guard r != 127, r != 0 else { return }
        let n = (p.name ?? (d[CBAdvertisementDataLocalNameKey] as? String) ?? "")
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
        if let m = d[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2 {
            co = String(format: "%04x:", UInt16(m[0]) | (UInt16(m[1]) << 8))
                + m.dropFirst(2).prefix(3).map { String(format: "%02x", $0) }.joined()
        }
        print("\(ts())s  rssi=\(r)  \(String(p.identifier.uuidString.prefix(8)))  co=\(co)\(gap)")
        fflush(stdout)
    }
}

let d = D()
withExtendedLifetime(d) {
    RunLoop.main.run(until: t0.addingTimeInterval(duration))
}
print("done: \(count) packets in \(Int(duration))s")