// scan — list every BLE advertiser, its name and company id, on a timeline.
//
// Produced the 150 s survey of named versus anonymous advertisers: 5 devices
// ever announced a name, and every Apple beacon was nameless. The numbers are in
// FINDINGS.md, "Phones and watches — visible, but anonymous". Use it to answer,
// for any candidate key device: does it advertise a name, how often, and is that
// name unique around here?
//
//   swift run waylock-scan 150
//
// The argument is the scan length in seconds (default 150). A window under 60 s
// is not worth reasoning about: packet counts look like instability when they
// are only a small sample.
//
// Run from a terminal that has Bluetooth permission; without it the radio never
// powers on and this prints the CoreBluetooth state and waits.

import Foundation
import CoreBluetooth

// Everything the callbacks write lives in one main-actor object. The manager is
// created with queue: nil, so CoreBluetooth delivers its callbacks on the main
// queue; the delegate methods are nonisolated only because the protocol is, and
// each one steps back onto the main actor with assumeIsolated.
typealias Seen = (name: String, co: String, pkts: Int, first: Date, last: Date, minR: Int, maxR: Int)

func hex(_ d: Data, _ n: Int) -> String {
    d.prefix(n).map { String(format: "%02x", $0) }.joined()
}

@MainActor
final class Survey {
    var seen: [UUID: Seen] = [:]
    let t0 = Date()
    let dur: Double

    init(dur: Double) { self.dur = dur }

    func record(id: UUID, name n: String, mfr: Data?, rssi r: Int) {
        var co = "-"
        if let m = mfr, m.count >= 2 {
            let id = UInt16(m[0]) | (UInt16(m[1]) << 8)
            co = String(format: "%04x", id)
            if m.count > 2 { co += ":" + hex(m.dropFirst(2), 3) }
        }
        if var e = seen[id] {
            e.pkts += 1; e.last = Date()
            if !n.isEmpty { e.name = n }
            e.minR = min(e.minR, r); e.maxR = max(e.maxR, r)
            seen[id] = e
        } else {
            seen[id] = (n, co, 1, Date(), Date(), r, r)
        }
    }

    /// Prints one tick. Returns true once the window is over and the summary is out.
    func report() -> Bool {
        let t = Int(Date().timeIntervalSince(t0))
        print("=== t=\(t)s  devices=\(seen.count) ===")
        for (id, e) in seen.sorted(by: { $0.value.pkts > $1.value.pkts }).prefix(18) {
            let nm = e.name.isEmpty ? "-" : e.name
            print(String(format: "  %@ pkts=%3d %4d..%4d  name='%@' co=%@",
                         String(id.uuidString.prefix(8)), e.pkts, e.minR, e.maxR, nm, e.co))
        }
        if Date().timeIntervalSince(t0) >= dur {
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
            return true
        }
        return false
    }
}

@MainActor
final class D: NSObject, CBCentralManagerDelegate {
    let survey: Survey
    var cm: CBCentralManager!

    init(survey: Survey) {
        self.survey = survey
        super.init()
        cm = CBCentralManager(delegate: self, queue: nil)
    }

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        // The manager that calls back is our own `cm`, so use that inside the hop
        // and carry only the Sendable state across.
        let state = c.state
        // Sound: queue: nil delivers delegate callbacks on the main thread.
        MainActor.assumeIsolated {
            guard state == .poweredOn else {
                print("bluetooth state: \(state.rawValue) (not powered on)")
                return
            }
            cm.scanForPeripherals(withServices: nil,
                                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            print("scanning")
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
            survey.record(id: id, name: n, mfr: mfr, rssi: r)
        }
    }
}

let dur = Double(CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 150) : 150)
let survey = Survey(dur: dur)
let d = D(survey: survey)

let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { timer in
    // Sound: the timer is scheduled on the main run loop.
    if MainActor.assumeIsolated({ survey.report() }) {
        timer.invalidate()
        exit(0)
    }
}
RunLoop.main.add(timer, forMode: .common)
withExtendedLifetime(d) { RunLoop.main.run() }
