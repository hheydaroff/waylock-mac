// scan — list every BLE advertiser, its name and company id, on a timeline.
//
// The tool behind the findings in FINDINGS.md. Use it to answer, for any
// candidate key device: does it advertise a name, how often, and is that name
// unique around here?
//
//   swiftc -O scan.swift -o /tmp/scan && /tmp/scan 150
//
// A window under 60 s is not worth reasoning about: packet counts look like
// instability when they are only a small sample.

import Foundation
import CoreBluetooth

var seen: [UUID: (name: String, co: String, pkts: Int, first: Date, last: Date, minR: Int, maxR: Int)] = [:]
let t0 = Date()

func hex(_ d: Data, _ n: Int) -> String {
    d.prefix(n).map { String(format: "%02x", $0) }.joined()
}

final class D: NSObject, CBCentralManagerDelegate {
    var cm: CBCentralManager!
    override init() { super.init(); cm = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            print("bluetooth state: \(c.state.rawValue) (not powered on)")
            return
        }
        c.scanForPeripherals(withServices: nil,
                            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        print("scanning")
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData d: [String: Any], rssi R: NSNumber) {
        let r = R.intValue
        guard r != 127, r != 0 else { return }
        let n = p.name ?? (d[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        var co = "-"
        if let m = d[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2 {
            let id = UInt16(m[0]) | (UInt16(m[1]) << 8)
            co = String(format: "%04x", id)
            if m.count > 2 { co += ":" + hex(m.dropFirst(2), 3) }
        }
        if var e = seen[p.identifier] {
            e.pkts += 1; e.last = Date()
            if !n.isEmpty { e.name = n }
            e.minR = min(e.minR, r); e.maxR = max(e.maxR, r)
            seen[p.identifier] = e
        } else {
            seen[p.identifier] = (n, co, 1, Date(), Date(), r, r)
        }
    }
}

let d = D()
let dur = Double(CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 150) : 150)

let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
    let t = Int(Date().timeIntervalSince(t0))
    print("=== t=\(t)s  devices=\(seen.count) ===")
    for (id, e) in seen.sorted(by: { $0.value.pkts > $1.value.pkts }).prefix(18) {
        let nm = e.name.isEmpty ? "-" : e.name
        print(String(format: "  %@ pkts=%3d %4d..%4d  name='%@' co=%@",
                     String(id.uuidString.prefix(8)), e.pkts, e.minR, e.maxR, nm, e.co))
    }
    if Date().timeIntervalSince(t0) >= dur {
        timer.invalidate()
        print("=== FINAL: every device that EVER announced a name ===")
        let named = seen.filter { !$0.value.name.isEmpty }
            .sorted { $0.value.pkts > $1.value.pkts }
        if named.isEmpty {
            print("  (none)")
        }
        for (id, e) in named {
            print("  \(String(id.uuidString.prefix(8))) pkts=\(e.pkts) name='\(e.name)' co=\(e.co)")
        }
        let apples = seen.values.filter { $0.co.hasPrefix("004c") }.count
        print("=== \(apples) of \(seen.count) devices were Apple beacons (company 0x004c) ===")
        exit(0)
    }
}
RunLoop.main.add(timer, forMode: .common)
withExtendedLifetime(d) { RunLoop.main.run() }